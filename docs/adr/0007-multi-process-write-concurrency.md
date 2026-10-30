# ADR-0007 多进程共享写库采用「锁竞争自愈 + 降竞争」

- **状态**：Accepted（已接受，**已实施**（2026-10-30）—— 落地计划 `openspec/completed/multi-instance-concurrency.md`
  T1–T10 全部完成并归档；实测结论见下文「实施结果（回填）」）
- **日期**：2026-10-30
- **决策者**：用户 + harspower（用户确认方案范围 L1+L2+L3 全量；约定「锁竞争属正常语义、
  应自愈而非当故障丢弃」，并要求修复效果可量化）
- **关联**：`openspec/completed/multi-instance-concurrency.md`（落地计划 T1–T10，已归档）、
  `openspec/decisions.md`（2026-10-30 一行）、
  `docs/architecture.org`（多进程并发写小节 / 已知偏差）、
  `docs/schema.org`（`hourly_health` 的 key 集合）、
  `AGENTS.md` I3 / I6 / I11、前序 `docs/adr/0004-observation-surface-expansion.md`
  （`hourly_health` 表的由来）与 `docs/adr/0005-two-tier-block-detection.md`
  （自监控计数器的既有写法）

## 背景

### 一、设计上刻意多进程共享一个库，而 SQLite 是单写者模型

el-chronos 的数据模型从一开始就是**汇总**：`sessions` 表按会话一行、`sessions.host`
记主机名（用于区分多机），`hourly_*` 聚合表的主键是 `(hour_ts, session_id)` ——
这些设计只有在「多个 Emacs 进程写进同一个库」时才有意义。ADR-0001 的 I3
（数据只写 `el-chronos-db-path`）进一步把「一个库文件」定成不变量。

代价是 SQLite 的单写者模型：同一时刻只允许一个连接持写锁，其他写者要么等
（busy handler 按 `busy_timeout` 轮询）、要么直接失败（`SQLITE_BUSY`）。
本机常态是 GUI 主实例 + 隔离验证实例（`elisp-test`）+ 偶发 `emacs -Q --batch`，
三者共用 `<user-emacs-directory>/.local/state/chronos/chronos.sqlite`。

### 二、实测：失败率很低，但失败的后果不对称且严重

真实库 `/home/thomas/thomas-emacs/.local/state/chronos/chronos.sqlite`
（47 MB，schema v5，WAL，`-wal` 4.5 MB）取证（2026-10-30）：

| 项 | 实测值 |
|---|---|
| `flush-failures` / `flush-count` | **7 / 48158 = 0.0145%**，落在 3 个小时桶 |
| `commands` 行数 | 118 466 |
| `sessions` 行数 | 83 → 85（观测期间在涨），单 host |
| 同一小时桶内最多并存会话数 | 9 |

失败率万分之一点五，按比例看可以忽略；但**失败之后发生什么**不能忽略：

| # | 失败模式（Emacs 32.0.50，`emacs -Q --batch` 双进程实测） | 证据 | `busy_timeout` 能否救 |
|---|---|---|---|
| ① | 对端单次持写锁 > 2 s | 对端持锁 2.5 s → 本端 `dt=2.003s` 后 `(sqlite-locked-error "database is locked")` | 能（延长时间） |
| ② | 对端零间隙背靠背抢锁，饿死对手 | 每次事务只持 0.2 s、间隙 0.2 s → 双方 0 失败；**间隙归零 → B 连续 4 次等满 2 s 全失败** | 有限（可能永远撞不进空隙） |
| ③ | deferred `BEGIN` 里先读后写 | 升级写失败，**等锁耗时 0.000 s**（busy handler 未被调用，`SQLITE_BUSY_SNAPSHOT`） | **无效** |

病灶定位（对真实函数逐语句探针，非推测）：

```
[steps] --open-db 返回=t                              dt=0.001s
[steps] --ensure-session FAIL (database is locked)    dt=2.003s   ← 启动期
[steps] --prune 返回=t                                dt=0.930s
```

- **P1 启动即停摆**：`--ensure-session` 的 autocommit `INSERT INTO sessions` 撞锁 →
  `el-chronos-store-open` 返回 nil → **该实例完全不采集**（实测：对端 `prune` 删 200 万行
  耗时 2.18 s 期间，另一实例 `OPEN=nil sid=nil`）。一次 2 秒的锁竞争换来一整个会话零数据。
- **P2 整批丢弃**：`flush` 事务首条 INSERT 撞锁 → ROLLBACK + **整批丢弃**
  （实测库内定格 420 行 = 20 基线 + 4×100，第 5 批 100 行确认丢弃）。

已排除项（Phase 1 已实测，避免后续重复排查）：`PRAGMA journal_mode=WAL` 在他人持锁时是
**无锁 no-op**（0.000 s 返回，含全新库并发创建也未复现失败）；chronos 不存在「读后升级」
病理（7 处 `BEGIN` —— 迁移 4 / flush / prune / purge —— 首条语句全是写，
`--session-known-p` 的 `SELECT` 在 `BEGIN` 之前）；启动竞争在小库上未复现
（全新库双迁移、0 / 5 / 50 ms 三种起跑，5 轮全通过）。

**核心洞察**：锁竞争本身是 SQLite 共享库的**正常语义**，不是故障；把「正常语义」当成
「故障」处置（丢弃数据、放弃采集）才是设计缺陷。故修法不是「避免竞争」（那要么多库、
要么跨进程串行化），而是**竞争时自愈 + 从源头降竞争 + 让竞争可量化**。

## 决策

**锁竞争按「自愈」处置：`sqlite-locked-error` 保留本批并重试（streak 上限 6）、
会话行延迟补建、7 处写事务改 `BEGIN IMMEDIATE`、`busy_timeout` 启动 2 s / 后台写 8 s 分层、
`prune` 候选预检 + 1 小时节流、新增 `hourly_health.busy-retries` 自监控，
以及撞锁退避（30 s）与丢弃告警不节流（D7）。**
七条具体决策如下。

### D1 会话行延迟补建：`store-open` 不因锁失败停摆

- 新增 `el-chronos-store--ensure-session-quiet`（返回 id 或 nil，**从不抛错**）：
  内部调 `--ensure-session`；`sqlite-locked-error` → `busy-retries` +1 并返回 nil；
  其他 error → 限流告警（`--warn`）并返回 nil（I6）。
- `el-chronos-store-open` 改用它：**会话建不起来也照常返回句柄**、起 flush timer、跑 prune。
- `el-chronos-store-flush` 在事务开始**之前**：若 `el-chronos--session-id` 为 nil 或
  `--session-known-p` 为假，调 `--ensure-session-quiet` 补建；失败则走既有
  「`session` 为 nil 时保留命令缓冲 + `--warn-orphan-aggregates`」分支。
- 不变：`el-chronos--session-id` 生命周期仍归 `el-chronos.el`；`store-close` 仍不置 nil。

理由：会话行只在启动时建一次，而它恰是「对端 `prune` 删 200 万行」这类长事务最容易撞上的
时刻。把「建会话」从 open 的**前置条件**降级为 flush 的**尽力而为**，「一次 2 秒竞争 = 一整个
会话零数据」的最坏结局被结构性消除。

### D2 flush 按错误类型分流：锁竞争保留重试，其他错误维持丢弃

- `condition-case` 新增 `sqlite-locked-error` 分支（实测该子类型存在）：
  - `ROLLBACK`；`--flush-failures` +1、`--busy-retries` +1、`--flush-lock-streak` +1。
  - streak < `--max-lock-retries`（6）→ **保留明细与聚合**：`--buffer` 不置 nil、**同时不调**
    `--clear-aggregates`（即 `--slow-events` 慢事件缓冲 + 九个聚合 hash 一并保留），
    返回 nil，等下个 flush 周期再试。
  - streak ≥ 6 → 按现行语义丢弃（`--buffer nil` + `--clear-aggregates`）+ 告警，并清零 streak。
- 其他 `error` 分支：语义**不变**（丢弃整批），同样清零 streak。
- COMMIT 成功后：`--flush-lock-streak` 置 0。

依据（写进 docstring，不靠注释传递）：`ROLLBACK` 后库状态与事务前一致，保留本批**不会重复计数**；
明细有 `--max-buffer-items`（50000）上限；聚合 hash 靠 streak 上限兜底，
避免「锁错误持续 + 长期不可写」时无界增长。**上限是必需的**：无限重试会让内存在
持续故障下无界增长，那比丢一批数据更糟。

### D3 7 处写事务改 `BEGIN IMMEDIATE`

`"BEGIN"` → `"BEGIN IMMEDIATE"`：迁移 v2 / v3 / v4 / v5、flush、prune、purge，共 7 处。

两条依据：① 抢锁前移到事务起点，不会「干完半批活才失败」；② 防御模式 ③ 的读后升级病理
（`SQLITE_BUSY_SNAPSHOT` 下 busy handler 根本不跑，加超时**无效**，只能靠起手就拿写锁）。
现状虽无「读后升级」病灶，但这是事务边界上的**弱点**而非「现状正确」—— 一旦将来有人在
`BEGIN` 与首条写语句之间插入一条 `SELECT`，模式 ③ 会静默复活且加超时救不回来。

### D4 `busy_timeout` 分层：启动 2000 ms / 后台写 8000 ms

- 新增 `el-chronos-store--busy-timeout-write-ms`（`defconst` 8000）。
- 新增 `el-chronos-store--call-with-write-timeout`（接收 thunk）：进入前
  `sqlite-pragma busy_timeout=8000`，`unwind-protect` 恢复默认 2000。
- 用于 `flush` / `--prune` / `purge`；**不用于** `--open-db` 与 `--ensure-session`。

理由：后台写等 8 秒无人感知（写完才继续采集），启动路径等 8 秒就是**拖慢启动**——
两条路径的容忍度差 4 倍，就按 4 倍分层。`unwind-protect` 是硬约束：连接级 pragma 会残留，
漏恢复会让后续所有写入都等 8 s。

### D5 `prune` 候选预检 + 1 小时节流

- 新增 `el-chronos-store--prune-interval-seconds`（`defconst` 3600）与
  `--last-prune-time`（`float-time` 或 nil）。
- `--prune` 逻辑：① 节流门（首次或距上次 ≥ 3600 s）；② 对 `commands` 与 `slow_events`
  各做一次 `SELECT count(*) ... WHERE ts < ?`（走 `idx_commands_ts` / `idx_slow_events_ts`，
  读锁不阻塞写者）；③ 两表候选都为 0 → **完全不开写事务**。

理由：实测的两次严重撞锁（`--prune` 删 200 万行耗时 2.18 s）都来自「无候选也开事务」的空转，
以及「启动即跑 prune」。读锁不阻塞写者是 WAL 的既有性质，把「要不要写」的判断挪到事务
之外，等于把最容易撞锁的路径反复缩小成一个无锁 `count(*)`。

### D6 新增 `hourly_health.busy-retries` 自监控

- 新增 `el-chronos-store--busy-retries`（单调累加，进程内），
  **不放进** `--clear-aggregates` 清空的容器。
- 进 `--health-snapshot` → `hourly_health.key = "busy-retries"`；成功 flush 后按快照扣除
  已上报部分（与 `flush-failures` **同一机制、同一 `cond` 分支族**）。
- **必须进 `--pending-p`**（`el-chronos-store.el:1309`）：否则 D1 路径（`store-open` 期
  `--ensure-session-quiet` 撞锁 → 计数 +1，此后可能长时间无采集数据）下该计数永不触发 flush、
  永不上报 —— 修复效果反而不可见。
- **不进 `--health-bad-keys`**（`el-chronos-analysis.el:993`）：busy-retries 是**中性度量**
  （类 `flush-count`），锁竞争被成功自愈也会让它上升；若归入坏消息键，`:ok-p` 会被误判为异常，
  与 D1 路径「`busy-retries` 升而 `flush-failures` 不升 = 自愈生效」这一判读自相矛盾。
- 消费侧**八处**显式清单（漏一处只表现为某个界面 / 导出静默少一行，不报错）：
  ① store 写入 `el-chronos-store--health-snapshot`；
  ② analysis 键映射 `el-chronos-analysis--health-keys`（`el-chronos-analysis.el:982`）；
  ③ analysis 返回值 `el-chronos-analysis-health` 的 plist `:busy-retries`（`:1037-1047`）；
  ④ web 路由 `/api/health`（`el-chronos-web.el:726-743`）；
  ⑤ web CSV `el-chronos-web--csv-health`（`:430-445`）；
  ⑥ web 前端面板内嵌 JS `healthPanel`（`:1145-1164`）；
  ⑦ org 报告健康节（`el-chronos-report.el:552-565`）；
  ⑧ report CSV `el-chronos-report--csv-health`（`:822-840`）。
  **显式排除** `el-chronos-analysis--health-bad-keys`（理由见上）。TD-19 已记录「两个 CSV
  是内联重复实现、列头漂移无机械约束」——本项必须人工同步两侧。

理由：`flush-failures` 只能证明「失败过」，不能区分「锁竞争被自愈」与「真故障被丢弃」。
新增 key 让修复本身**可验收**，但**判读口径必须按路径分开**（两条路径的计数器表现不同）：

- **D1 路径**（`--ensure-session-quiet` 建会话行撞锁，不产生采集数据）：`busy-retries` 上升
  而 `flush-failures` **不升** = 自愈生效。这条路径不涉及缓冲，故看这两个数就够。
- **D2 路径**（flush 写批撞锁）：`busy-retries` 与 `flush-failures` **同时上升** —— 保留重试
  与「达到上限丢弃」在它们上面**完全一样**，故它们**不能**作为 D2 的判据。D2 的判据改为
  `dropped-commands` / `dropped-events` 是否上升：
  - **不升** = 本批被保留、下轮重试（自愈，数据没丢）；
  - **升** = 本批真被丢弃，条数就是被丢弃的缓冲长度（`--dropped-*` 在清空缓冲**之前**累加）。
  - 第二信号：丢弃伴随一条「本批已按计划丢弃」的**结果告警**（`--warn-force`，绕 600 秒限流）；
    保留重试只有一条被限流的「过程告警」。看到过程告警 ≠ 丢数据，看到结果告警才是真丢。

一句话口诀：**D1 看 `flush-failures` 是否跟涨；D2 看 `dropped-*` 是否跟涨**。

### D7 撞锁退避（30 s）与告警不节流（T8 双进程实测暴露的两条缺陷）

D1–D6 落地后，T8 的「持续持锁」场景跑出了两个**新**问题，两者都属于「上一版修法的副作用」，
必须同批修掉（D7 是对 D2 的补全，不推翻 D2）。

**F1 丢弃告警被限流吞掉**：撞锁分支原先统一走 `el-chronos-store--warn`（600 秒限流）。
`--warned-at` 是一条**共享**通道 —— 第 1 次撞锁的「保留重试（第 1/6 次）」就把它占满，
于是第 6 次的「写库连续撞锁 6 次，本批缓冲已按计划丢弃」在生产里**永不出现**：
用户只看得到过程（第 1/6 次），看不到结果（数据真的丢了）。

- 修法：新增 `el-chronos-store--warn-force`（不做限流判定，仍更新 `--warned-at`），
  **只给结果类消息**用；「保留重试」那条仍走 `--warn`。
- 反向约束写进 docstring：**不要**用「频繁清空重试计数器」代替 —— 那会让过程消息刷屏，
  用户同样只看得到过程、看不到结果。过程走 `--warn`、结果走 `--warn-force` 是硬划线。
- 为什么不给 `--warn` 加一个位置参数 `force`：现有 15 处调用点全是
  `(el-chronos-store--warn FMT err)` 形态，插入第二个位置参数会让 `err` 绑到 `force` 上
  —— 每条既有告警都变成「不受限流」，症状是刷屏而不是报错，属静默退化。故拆成
  `--warn`（限流）/ `--warn-force`（不节流）/ `--warn-emit`（共同实现）三个函数，
  既有调用点**一行不改**。

**F2 撞锁退避（D2 引入的 regression）**：改为「保留重试」后 `--pending-p` 恒真
（`--flush-failures` / `--busy-retries` 非零也让它为真），于是**每 5 秒 flush 一次、
每次撞锁等满 8 秒**（T8 场景 C 实测 8 次 × 8.01 s），主线程被占满，Emacs 基本无响应 ——
比「失败即丢弃后早退」的老行为更糟。

- 修法：新增 `--flush-backoff-seconds`（`defconst` 30）与 `--flush-backoff-until`
  （`float-time` 或 nil，语义是「**下次允许尝试**的时刻」）；`el-chronos-store-flush`
  **最前面**加退避门（`--flush-backoff-active-p`）：到期前直接返回 nil，
  不碰库、不打 `sqlite-pragma`、缓冲与计数器原样。
- 置位：撞锁分支的**保留与丢弃两条路径都置** `now + 30`。丢弃路径同样要置 —— 否则
  `--pending-p` 因失败计数非零仍为真，会继续每 5 秒白撞 8 秒。
- 清零：COMMIT 成功（抢锁已成功，下一轮不必再等）、非锁错误分支（它本就丢弃本批 →
  `--pending-p` 自然清空，不退避）、`el-chronos-store-close`（I5 零残留）。
- **代价（必须记入 `docs/operations.org`）**：撞锁期间崩溃的丢数据窗口从 **5 s 放大到
  35 s**（一个 flush 周期 + 一个退避窗口）。
- 取 30 秒的依据：对端大 prune / 迁移实测在 0.5–2.2 秒量级，30 秒足以跨过；又远小于
  用户「这软件卡住了」的感知阈值。
- 与 `--max-lock-retries` 的关系：上限仍按**批数**（6）计，内存上界不变；但因退避，
  「连续 6 次撞锁」在墙钟上跨越约 3 分钟（而非 30 秒）。docstring 已据此改写。

## 实施结果（2026-10-30 回填）

- **源码**：`el-chronos-store.el` 1867 → **2241 行**（+374，锁竞争处置的主体）；`busy-retries` 的消费侧同步改动使
  `el-chronos-analysis.el` 1257 → **1261**、`el-chronos-web.el` 1267 → **1279**、`el-chronos-report.el` 1410 → **1426**。
- **测试**：**336 → 375**（+39，无删除用例）——store-test 81 → **114**（+33）、analysis-test 57 → **58**、
  report-test 39 → **41**、web-test 25 → **28**；collect / attrib / autoload / startup-probe 不变。
  既有用例 `flush-failure-clears-buffers` 的断言按新语义更新（非锁错误仍整批丢弃，但 `--pending-p`
  因「有自监控计数未补写」在失败后**仍为真**，旧的 `(should-not (pending-p))` 失效；并新增 `dropped-*`
  记账断言），属**语义变化导致的改测试**，数据层面的旧断言全部保留。
- **验证**：`make check-parens` 全绿；`make test` **375 全绿（0 unexpected、0 skipped，本次实测 32.7 秒）**；
  `make lint` **零告警**（17 个文件逐个字节编译）。三者分别执行、分别报告（`make full-check` 不含 lint）。
- **L3 双进程复验**（一次性脚本放 `/tmp`、不入库；对端持写锁 3 s / 40 s 两类场景）：
  - **D1 生效**：对端持锁 3 s 时 `store-open` 由改造前的 `OPEN=nil`（实例完全不采集）变为 **`OPEN=t`** ——
    会话行走延迟补建，释放锁后下一次 flush 补建成功、本实例的 `commands` 正常落库。
  - **D2 生效**：flush 撞锁后库内行数**守恒（100 = 100）**——保留重试后下一轮写入成功；改造前同场景
    行数定格 420（= 20 基线 + 4×100），**第 5 批 100 行确认丢弃**。
  - **D7 生效**：对端持续持锁 40 s、本端循环 flush 12 次，主线程累计阻塞 **9.54 s**（无退避时为
    12 × 8.01 s ≈ **96 s**）。
- **真实库副本回归**（只读副本，不碰生产库）：`user_version=5`、13 表、**无 `.bak`**（未触发迁移）、
  跑一次 open + flush 后写入 **+5 行**。
- **实施期新发现并修复的两个缺陷**（均为 D1–D6 的副作用，已并入上文 D7）：
  ① `el-chronos-store-close` 在退避窗口内会把保留的缓冲**静默丢弃**（无告警、无计数）；
  ② 「写库连续撞锁 N 次，本批缓冲已按计划丢弃」这条**结果告警**被 `--warn` 的 10 分钟限流吞掉
  （第 1 次撞锁的过程告警占满共享的 `--warned-at` 通道）——用户只看得到过程、看不到数据真的丢了。
- **新增判读信号**：`dropped-commands` / `dropped-events` 的口径从「仅缓冲上限截断」扩展为
  「截断 + 整批写库失败丢弃」，成为「自愈 vs 真丢」的**唯一直接信号**——`busy-retries` / `flush-failures`
  在「保留重试」与「达上限丢弃」两条路径上表现完全一致，无法区分。
- **决策工件**：本文 + `openspec/decisions.md` 2026-10-30 一行（已按最终实现补入 30 s 退避与 `dropped-*`
  判读信号，未新增重复行）+ `openspec/tech-debt.md` 新增 TD-36～TD-39 + 计划移入 `openspec/completed/`。

## 备选方案与被否决原因

| 替代方案 | 描述 | 否决理由 |
|---|---|---|
| ① 按实例分库 | 每个 Emacs 进程（或每个 host）写自己的库，读取时聚合 | **破坏「统一汇总」这一设计目标**：`sessions` / `host` / `hourly_*` 的存在前提就是单库汇总；分库后 report 与 web 需要跨库聚合（SQLite 无跨库 JOIN，只能各库查询后在 Lisp 里归并），`el-chronos-analysis` 的 22 个只读函数、19 条路由、16 节报告全部要重写聚合层，复杂度远超锁竞争本身 |
| ② 跨进程 flock 串行化 | 用文件锁把多进程写操作真正排成队列 | **Emacs 无原生原语**：只能起子进程 `flock` 或自建锁文件协议；崩溃遗留锁文件会让后续实例永久无法写入（比现在丢一批数据更糟），且新增了子进程依赖（违反 I10 的零依赖精神），还需要一套过期判据与清理责任 |
| ③ 降低 flush 频率 | 拉长 flush 间隔，减少事务次数从而减少撞锁概率 | **拉长崩溃丢数据窗口**：现为 5 s，降低频率意味着崩溃时最多丢一个周期以上的数据。用「数据完整性」换「降低冲突概率」方向反了 —— 冲突是可以自愈的（本 ADR），丢数据不能 |
| ④ 无限重试不设上限 | `sqlite-locked-error` 一律保留本批，永不丢弃 | **内存无界**：持续锁错误（对端长事务、库损坏、磁盘满）下 `--buffer` 与九个聚合 hash 会一直增长，`--max-buffer-items` 只约束 `--buffer` 不约束聚合 hash。用 streak 上限 6 兜底：瞬时竞争（实测模式 ①②，秒级）必被覆盖，持续故障按现行语义丢弃并告警 |

## 后果

**正向**

- **实例不再因瞬时竞争停摆**（D1）：`store-open` 交出句柄、timer 照起，会话行在下一次 flush
  之前补建成功即可。实测的 2 秒竞争不再等于「一整个会话零数据」。
- **数据不再因竞争「整批丢弃」**（D2 + D3 + D4）：锁竞争属于「正在发生的事情」，保留明细与聚合
  （`--buffer` / `--slow-events` / 九个聚合 hash 一并保留）+ 8 秒等待 + 起手即拿写锁三者叠加，
  把实测的模式 ①②③ 全部覆盖。**例外**：会话建行撞锁期间（最坏 1 个 flush 周期）的**聚合**数据
  仍会丢失，明细保留（TD-36）——这是「丢 5 秒聚合」与「整个会话零数据」之间的取舍，不是遗漏。
- **竞争可量化**（D6）：`busy-retries` / `flush-failures` / `dropped-commands` / `dropped-events`
  分列，修复效果可验证而不是「感觉好了」——判读口径按路径分开（D6 末段）；
  也能回答「我这台机器上多实例同时用到底有多频繁地撞锁」。
- **撞锁概率本身下降**（D5）：实测两次严重撞锁都源于「无候选也开写事务」，预检后该路径
  变成无锁 `count(*)`。
- **零新增依赖、不动不变量**（I3 / I6 / I11 语义不变，编号不重排）：
  全部改动在既有 `sqlite` 之上，不开新表、不动 schema 版本（`hourly_health` 是既有表，
  只是多一个 `key` 取值）。

**负向 / 代价**

- **瞬时失败时内存多留一批**：锁竞争路径不再 `--clear-aggregates`，最坏多占一个 flush 周期的
  缓冲（`--buffer` 另有 50000 上限、聚合 hash 由 streak 上限 6 兜底）。
- **后台写最坏等 8 s 才失败**：`busy_timeout=8000` 是被 `sqlite` 的 busy handler 阻塞等待，
  期间占住调用它的主线程/采集路径（flush 由 timer 触发，prune 在 open 之后）。
  这是「等 8 秒并成功」与「等 2 秒并失败」之间的取舍，选了前者；实现上因此必须
  `unwind-protect` 恢复，否则 8 s 会残留到后续所有写入。
  **「持续锁竞争下主线程占用叠加」这一风险已由 D7 解决**：退避门让撞锁后的下一轮尝试至少
  隔 30 秒（T8 复验：对端持锁 40 s、B 循环 flush 12 次，主线程累计阻塞 ≈ 8 s / 一次，
  而不是 12 × 8 s）。**残留代价 = 崩溃丢数据窗口从 5 s 放大到 35 s**，已记入
  `docs/operations.org`；不要为了缩回 5 s 而取消退避。
- **`hourly_health` 多一个 key，需八处同步**（store / analysis 键映射 / analysis 返回值 /
  web 路由 / web CSV / web 前端 JS 面板 / report 健康节 / report CSV）：
  漏一处**不报错**，只表现为「某个界面或导出少一行」，靠 T7 的五个界面层一致性用例守门。
- **`store-open` 的语义变宽**：返回句柄不再保证「会话行已存在」。所有依赖
  `el-chronos--session-id` 非 nil 的写入路径都在 flush 内，故行为正确；但**读代码时必须知道这一点**，
  否则会误以为 open 之后 session-id 必然有值。
- **测试语义更新**：既有「flush 失败丢弃本批」的断言要按错误类型拆成两条（锁竞争保留 / 其他错误丢弃），
  属于**语义变化导致的改测试**，须在计划与 `CHANGELOG.md` 说明理由。
- **`BEGIN IMMEDIATE` 的代价**：起手即持写锁，事务内的读也不再与其他读者并发 ——
  对当前 7 处（全是写事务）无实际影响，但若将来把长查询塞进事务，会放大阻塞面。
- **补建窗口内的聚合数据丢失**（D1 的已知口径损失，TD-36）：session-id 为 nil 期间，六个
  `record-*` 聚合入口（gc / drift / resources / gc-attrib / health / startup）经
  `--aggregate-session`（`el-chronos-store.el:466-483`）在**记录时**即跳过、不入 hash，
  故补建只能救回**明细**（`commands` / `slow_events`）；**聚合**数据丢失窗口 ≈ 1 个 flush 周期
  （5 s）。症状：该实例该时段的 `hourly_*` 曲线缺一段而 `commands` 不缺；`hourly_stacks`
  属第二类机制——经 `--stack-session` 在 **flush 期**跳过，而非 record 期。
- **D5 只节流「同进程反复 open/close」，不引入周期 prune**（TD-37）：`--prune` 的唯一调用点是
  `el-chronos-store-open`（`el-chronos-store.el:866`），不挂 flush timer 或任何周期 timer；
  `el-chronos-retention-days` 的实际生效仍依赖实例重启。长期常驻的实例不会主动清理过期明细。
- **迁移 / checkpoint / vacuum 的撞锁边界维持现状**（既有行为，本次不改）：`--open-db` 内迁移
  撞锁仍使 open 返回 nil（升级后首次启动 + 对端持锁，低概率）；`--migrate` 的
  `wal_checkpoint(TRUNCATE)` 在他人持写锁时被 `ignore-errors` **静默跳过**（`.bak` 可能不含最新
  WAL 数据）；`el-chronos-store-vacuum` 仍用默认 2000 ms 且不包 D4 的 wrapper（手动命令，可接受）。

**约束（进入不变量语义的解释，不新增不变量）**

I3（数据仍只写 `el-chronos-db-path` 一个库文件 —— 分库方案正是因此被否决）、
I6（`--ensure-session-quiet` 与其他错误分支一律 `condition-case` 收敛为 nil + 告警，不向宿主抛错）、
I11（锁竞争导致的可观测缺口必须在 `hourly_health` 里可读，不得静默）。
**I1–I11 一条不改、编号不重排。**

## 验证

- **双进程复刻脚本**（T8，一次性、放 `/tmp`、不入库）：复刻 Phase 1 实验 6-⑤/⑥/⑦ 的极端场景
  （对端持写锁 3 s），改造前 / 改造后各跑一遍并保留原始输出 —— 要求 ① flusher 不丢批
  （保留重试后写入成功，库内行数守恒）② `store-open` 不返回 nil（会话延迟补建）。
- **用例覆盖**（守门清单，全部由新增用例锁住）：撞锁保留重试（`--buffer` + 慢事件 + 九个聚合 hash
  全保留、`flush-failures` / `busy-retries` / streak 各 +1）、连续 6 次后丢弃且 streak 清零、
  **退避门不碰库**（`sqlite-execute` 与 `sqlite-pragma` 均 0 次调用、缓冲原样）、**丢弃计入 `dropped-*`**
  而保留重试不计、`store-close` **绕过退避**尽力 flush、结果告警在限流窗口内仍可见（反之过程告警仍被限流）、
  **八处 `busy-retries` 消费点字段一致**（analysis plist / `/api/health` / 两个 CSV / 内嵌 JS / 报告节）、
  `busy-retries` 上升而 `:ok-p` 仍为真。
- **`make check-parens` + `make test`**（即 `make full-check` 的两项；基线 336 → **375**，实际新增 **+39**，
  超出 Phase 2 预估的 12–16 条 —— F1 / F2 的追加验收、八处消费点一致性、`BEGIN IMMEDIATE` 迁移四步
  与 `busy_timeout` 三处接入各占若干条；0 skipped）。
- **`make lint`**（字节编译告警，17 个文件逐个编译，零告警）。
  注：`make full-check` **不含** lint（`Makefile` 的 `full-check: check-parens test`），
  两者必须分别报告（见 `openspec/decisions.md` 2026-10-26 一行）。
- **真实库副本回归**：只读副本上跑一次 open + flush，确认 schema v5 不变、无迁移触发。
  **禁止**对生产库执行 `PRAGMA wal_checkpoint`（那是写操作）。
- **`hourly_health` 的 key 与 `--health-bad-keys` 取舍必须一致**：`busy-retries` 是中性度量，
  **不进** `--health-bad-keys`（否则 `:ok-p` 会被锁竞争自愈误判为异常）；验收时须有用例锁住
  「busy-retries 上升而 `:ok-p` 仍为真」，并核对八处消费点（含两个 CSV 与内嵌 JS 面板）字段齐全。

## 关联

- 落地计划：`openspec/completed/multi-instance-concurrency.md`（T1–T10：会话延迟补建 / flush 分流 /
  `BEGIN IMMEDIATE` / 超时分层 / prune 预检 / busy-retries 存储侧 + 消费侧 / 双进程复验 /
  全量验证 / 文档同步与归档）
- 技术文档：`docs/architecture.org`（多进程并发写小节、已知偏差）、
  `docs/schema.org`（`hourly_health` 的 key 集合与累加口径）、
  `docs/api.org`（`--ensure-session-quiet` / `--call-with-write-timeout` 等内部约定、
  `--busy-timeout-write-ms` / `--max-lock-retries` / `--prune-interval-seconds` 为 `defconst`
  而非 defcustom —— 避免动「23 个 defcustom」清单）、
  `docs/operations.org`（`database is locked` 排障与多实例共享库的正常/故障判据）、
  `docs/ui.org`（Web 健康面板与报告健康节的 `busy-retries`）
- 决策表：`openspec/decisions.md`（2026-10-30 一行）
- 不变量：`AGENTS.md` I3 / I6 / I11（编号与语义均不改）
- 前序 ADR：`docs/adr/0004-observation-surface-expansion.md`（`hourly_health` 表与自监控计数的由来）、
  `docs/adr/0005-two-tier-block-detection.md`（计数器与聚合表口径的既有写法）、
  `docs/adr/0001-observer-architecture.md`（I3 单库写入约束的出处）
