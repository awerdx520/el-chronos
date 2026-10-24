# 扩展观测面：内存 / GC / 启动 / 配置变更 / 自监控

## 当前状态

- 阶段：Phase 2（Plan）· 进行中
- 修订：2026-10-25 按用户裁决 R1–R10 与「flush 补写」拍板定稿 —— 启动耗时改为
  「`after-init-hook` 只捕获值 + 并入下一次 flush 事务补写」（设计 7
  处置 ③ / T6）、迁移显式事务边界（设计 3 陷阱 2–3 / T1）、自监控计数器独立 defvar 与差值口径
  （设计 6 / T5）、defcustom 统一落 `el-chronos.el`（注意事项 11）、技术债从 TD-15 起（T10）、
  `heap_bytes` 的 carried-forward 语义（设计 2 / T2 / 注意事项 12）
- 复审修订：**plan-reviewer 判「需修订」（1 blocking + 4 major + 5 minor），已按 X1–X10 全部落地** ——
  逐条落点见「设计 10. 修订记录」。其中 blocking 项 X1（新 4 表的保留策略与 purge 扩到 10 表、
  删除顺序钉死）改变了 T1 的范围与用例数（+5 例）；X2 刷新基线为 121 用例 / attrib 28。
- 已确认：方案 ✅（用户 2026-10-25 确认）、计划 ⏳（待确认）
- 前置阻塞：**已解除** —— `fix-sampling-attribution` 已于 2026-10-25 归档到
  `openspec/completed/fix-sampling-attribution.md`（commit 1cece57），基线用例数与采样口径
  已回填 `AGENTS.md`。它必须是前置的原因仍然成立：该计划修复前 nil 帧占 `unknown` 样本的 38.8%、
  其 `total_ms` 占全部样本 98.7%，任何基于 `hourly_functions` 的新增查询（本期 T7 的 GC 趋势、
  T8 的 GC 与内存节）都会被那个污染带偏。
- 下一步：独立审查（plan-reviewer）→ 用户确认计划 → 进入 Phase 3

## 目标

1. **补上「内存 / GC」观测维度** —— 当前数据库里完全不存在堆大小序列，也没有独立的 GC 趋势
   （只有 `commands.gc_ms` 这个「命令期间发生的 GC」附带列，无法回答「越用越胖了吗」）。
2. **让回归结论可归因到「哪天改了什么」** —— 当前 `el-chronos-analysis-regressions` 只能说
   「变慢了」，看不到「同一时期 git HEAD / init 配置变了」。
3. **让采集器能自证数据可信** —— 丢弃事件、flush 失败、采样窗口丢失当前**完全不可见**：
   `--max-buffer-items` 的 `setcdr` 截断静默丢数据、flush 失败只留一条限流告警。
4. **让启动耗时从单个标量变成可分解** —— `sessions.startup_ms` 只有一个总数，
   无法知道「是哪个文件的 load 慢」（受加载时机限制，见设计 7 的覆盖范围约束）。
5. **全部扩展遵循既有约束** —— 低开销、零第三方依赖、不改 Emacs 行为语义，
   I1–I11 **一条不改**（新增能力不得要求放宽任何不变量）。

## 设计

### 0. 事实基线（实测，2026-10-25，Emacs 31.1）

| 事实 | 值 | 影响 |
|---|---|---|
| `(fboundp 'garbage-collect-heapsize)` | **t**（Emacs 31 引入） | 可用；但项目 `Package-Requires` 是 `emacs 29.1`，29/30 上必须守卫 |
| `(garbage-collect-heapsize)` 返回 | 9 项 `(NAME SIZE USED FREE)`，与 `(garbage-collect)` 同形，**不触发 GC** | 堆总量 = `Σ (* SIZE USED)` |
| 名字相近的**短别名** | `fboundp` = **nil** | 只有 `garbage-collect-heapsize` 这一个名字（无短别名）；凭印象写短名会 `void-function`，代码/文档/ADR 一律只写全名 |
| `(memory-info)` | `(32703124 18822788 8388608 8388608)` = `(TOTAL-RAM FREE-RAM TOTAL-SWAP FREE-SWAP)` | 是**系统内存**不是 Emacs 堆，见设计 5 的禁令 |
| 现有 `make test` 基线 | **121 用例**（analysis 15 / attrib 28 / collect 30 / report 24 / store 14 / web 10） | 本计划预计 +28–38 |
| 现有 Web 路由 | 13 条；org 报告 10 节；analysis 13 个查询 | 本期分别到 16 / 13 / 17 |
| `user-emacs-directory`（本机） | `/home/thomas/thomas-emacs`，有 `.git`（`HEAD` = `ref: refs/heads/develop`，同时存在 `packed-refs`）、`early-init.el`、`init.el`、`lisp/init-*.el` × 51 | 设计 4 的 glob 默认值与 packed-refs 回退是**必需**路径，不是理论情况 |

### 1. 总体路线（分期，本期只做 S1）

| 期 | 内容 | 前置条件 |
|---|---|---|
| **S0 前置** | `fix-sampling-attribution` 归档（nil 帧 / C 原语归因 / 栈尾 trim） | —— |
| **S1 本期** | 变更标记（git-head / config-sig）、GC + 内存趋势、采集自监控、启动分解 | S0 完成 |
| **S2 后续** | 亚秒级阻塞（心跳默认 1s，捕获窗口 > 1s 的阻塞看不到） | 须先**实测**心跳降频到 200–500ms 的常驻开销（目标仍 < 0.5%，与 TD-3 同口径） |
| **S3 后续** | 包成本-收益：加载了但从未用到的包（启动时间 vs 使用频次交叉） | S1 的启动分解落地后才有「每包 load 耗时」数据 |
| **S4 后续** | IO 与网络：TRAMP 远端操作、同步 HTTP 请求归因 | 需要新的故障面（远程/网络超时语义不同，I2 的「主线程阻塞」判据要重新论证） |
| **S5 后续** | 命令下钻 + 主动告警 | **优先级已下调**：`hourly_functions` 是小时聚合，按命令切窗只能同小时近似；而 `el-chronos-profile-command` 已能对单命令当场精确剖析，增量收益低 |

### 2. schema v2：4 张新表，零 `ALTER TABLE`

```sql
CREATE TABLE IF NOT EXISTS hourly_gc (
  hour_ts INTEGER NOT NULL, session_id INTEGER NOT NULL,
  gc_count INTEGER NOT NULL DEFAULT 0, gc_ms REAL NOT NULL DEFAULT 0,
  heap_bytes INTEGER, PRIMARY KEY (hour_ts, session_id));
CREATE TABLE IF NOT EXISTS startup_phases (
  session_id INTEGER NOT NULL, phase TEXT NOT NULL, ms REAL NOT NULL,
  PRIMARY KEY (session_id, phase));
CREATE TABLE IF NOT EXISTS hourly_health (
  hour_ts INTEGER NOT NULL, session_id INTEGER NOT NULL, key TEXT NOT NULL,
  value REAL NOT NULL DEFAULT 0, PRIMARY KEY (hour_ts, session_id, key));
CREATE TABLE IF NOT EXISTS session_meta (
  session_id INTEGER NOT NULL, key TEXT NOT NULL, value TEXT,
  PRIMARY KEY (session_id, key));
```

**为什么全部走新表、一条 `ALTER TABLE ADD COLUMN` 都不用**

- `ALTER TABLE ... ADD COLUMN` **不幂等**：第二次执行报 `duplicate column name: xxx`。
  而迁移实现（见 3）在失败重试、`.bak` 恢复后重开、崩溃后重启都会重跑迁移脚本，
  只要有一条 ALTER 就不可能在重试语义下安全。
- 4 条 `CREATE TABLE IF NOT EXISTS` 天然幂等，迁移脚本因此可以**无条件重跑**，
  失败恢复路径不必记录「做到第几步」。
- 附带解耦：新维度不挤进既有的 4 张明细/聚合表，既有 6 表的行宽与索引一个字节不变
  （「不改既有表语义」这条不变量因此机械可检）。

**upsert 语义**（全部 `ON CONFLICT ... DO UPDATE`，与既有 `--sql-upsert-function` 同风格）

| 表 | 冲突键 | 更新方式 |
|---|---|---|
| `hourly_gc` | `(hour_ts, session_id)` | `gc_count` / `gc_ms` **累加**；`heap_bytes` 用 `COALESCE(excluded.heap_bytes, heap_bytes)`（「最后一次非 NULL 值胜出」，理由见下） |
| `hourly_health` | `(hour_ts, session_id, key)` | `value` **累加**（计数与耗时都是单调量） |
| `startup_phases` | `(session_id, phase)` | `DO UPDATE SET ms = excluded.ms`（覆盖：同阶段重复打点取最后一次） |
| `session_meta` | `(session_id, key)` | `DO UPDATE SET value = excluded.value`（覆盖：同一键只保留当前值） |

`session_meta` 选 KV 形态的理由：会话级元数据会继续长（将来可能加 `emacs-build`、
`straight-revision`、`themes`），KV 让「加一个键」不需要再一次 schema 迁移。

**为什么 `heap_bytes` 必须 `COALESCE` 而不能直接覆盖**

- **主因（必现，充分）**：同一会话、同一小时内堆采样是稀疏的（每 `el-chronos-heap-sample-windows`
  个窗口一次），其余窗口都写 NULL。若用普通覆盖 `heap_bytes = excluded.heap_bytes`，
  一个采样点之后的第一个 NULL 窗口就会把它抹成 NULL —— 若该小时最后一次写入恰好是 NULL，
  整小时采到的值全部丢失。这是**每个会话每小时都会发生**的场景，不是防御性设计。
- **被推翻的看法（记录以免后人重犯）**：曾以为「跨版本共用同一个库（31+ 之后回退 29/30）会让
  历史堆值被 NULL 抹平」。这**不成立**：`hourly_gc` 主键是 `(hour_ts, session_id)`，
  而 `session_id` 由 `--ensure-session` 在**每个 Emacs 进程首次打开库时新建**（同进程内才复用），
  所以 29/30 进程写的是它自己那一行，抹不掉 31+ 会话的历史行。跨版本混用真正的影响是
  **曲线出现空洞**（部分会话有堆值、部分全 NULL），不是数据丢失。
- 结论：`COALESCE(excluded.heap_bytes, heap_bytes)` 的语义读作
  **「本次无样本时保留本行最后一次观测值」**（同会话、同小时的 last-observation-carried-forward）；
  它解决的是稀疏写入，与版本无关。
- **代价（必须承认并在文档写明）**：`heap_bytes` 的时间戳含义是「本行最后一次有样本的时刻」，
  不是「本行所属小时的整点」——同一小时内多次采样只留最后一个值，跨小时不携带。
  `docs/schema.org` 与 `docs/architecture.org` 要写明这一点，并说明跨版本混图时应按
  `sessions.emacs_version` 分组阅读，避免把「29/30 会话无堆值」读成「内存没长」。

### 3. 迁移实现（关键陷阱，逐条）

**陷阱 1：`--ensure-schema` 无条件把版本置为当前常量。**
`el-chronos-store.el` 现实现是：

```elisp
(defun el-chronos-store--ensure-schema (db)
  (sqlite-execute-batch db el-chronos-store--schema-ddl)
  (sqlite-pragma db (format "user_version=%d" el-chronos-store--schema-version))
  t)
```

即「建完表就把版本写成 `--schema-version`」。**若只把 `--schema-version` 改成 2 而不把
`--schema-ddl` 补成全量**：version 0 的新库会只建旧 6 表、却被标记为 v2 —— 之后
`--migrate` 不会再跑（版本相等），新表永远不存在，所有新写入静默失败。

**正确改法（四步，缺一不可）**

1. `el-chronos-store--schema-ddl` 更新为**全量**：旧 6 表 + 3 索引 + 新 4 表。
2. 新增 4 个单表 DDL 常量（`--ddl-hourly-gc` / `--ddl-startup-phases` /
   `--ddl-hourly-health` / `--ddl-session-meta`，各含一条 `CREATE TABLE IF NOT EXISTS`），
   再由它们 **concat** 出 `--schema-ddl`（旧串 + 四个新串）与 `--sql-migrate-v2`（四个新串）。
   **避免同一批 DDL 存在两份字面量**——两份必然漂移，而漂移的表现是「新库对、旧库缺列」。
3. `el-chronos-store--schema-version` 改为 `2`。
4. `--migrate` 内保留 `(when (< from-version 1) (el-chronos-store--ensure-schema db))`，
   追加分支：

```elisp
;; from-version 0 已被上面的 ensure-schema 覆盖为全量 v2，故这里必须是 (= 1) 而非 (< 2)：
;; 用 (< from-version 2) 会让 0 号库在 ensure-schema（已是全量 v2）之后再跑一遍迁移脚本
;; —— 虽然 CREATE IF NOT EXISTS 幂等不会报错，但「重跑」让失败恢复路径难以推理。
(when (= from-version 1)
  (sqlite-execute-batch db el-chronos-store--sql-migrate-v2)
  (sqlite-pragma db "user_version=2"))
```

**陷阱 2：`sqlite-execute-batch` 不自带事务。**
Emacs 内置 `sqlite.el` 的 `sqlite-execute-batch` 是逐条执行（`sqlite3_exec` 语义），
脚本里没有 `BEGIN` 时**每条语句各自隐式提交**。故 v2 迁移必须显式包事务：

```elisp
;; 顺序是硬约束：.bak 复制必须在 BEGIN 之前（否则备份到的是未提交/半成品状态）
(ignore-errors (sqlite-execute db "PRAGMA wal_checkpoint(TRUNCATE)"))
(when (file-exists-p path) (copy-file path bak t))
(sqlite-execute db "BEGIN")
(sqlite-execute-batch db el-chronos-store--sql-migrate-v2)
(sqlite-execute db "COMMIT")
```

- 失败分支：先 `(ignore-errors (sqlite-execute db "ROLLBACK"))`，再走既有回滚路径
  （关句柄 → `.bak` 覆盖回原文件 → 删 `-wal` / `-shm` → 告警 → 返回 nil）。
- **为什么不能只靠 `CREATE TABLE IF NOT EXISTS` 幂等而不开事务**：不开事务时最坏状态是
  「4 张表只建成 3 张、`user_version` 仍是 1」—— 库对外是一个**半成品**：
  分析层会因缺表报错降级（返回空结果，看似「无数据」而实际是「迁移没做完」），
  外部 `sqlite3` 读者看到的也是残缺 schema。事务把「要么全有、要么全无」变成可推理的前提。
- 实施时**先读一遍 `sqlite.el` 里 `sqlite-execute-batch` 的实现确认**（EE-1），
  不要按本计划断言；若它自带事务语义，把上面的显式 `BEGIN`/`COMMIT` 去掉并在代码注释里写明依据。

**陷阱 3：失败回滚语义必须与既有 `.bak` 逻辑共存。**
既有 `--migrate` 已做：WAL checkpoint → 复制 `.bak` → 出错时关句柄、`.bak` 覆盖回原文件、
删 `-wal`/`-shm`、告警、返回 nil。本计划**不改这段**，只把新分支加进 `condition-case` 的
保护体内，并在其中插入事务边界与 `ROLLBACK`。两条顺序硬约束：
① `BEGIN` 必须在 `.bak` 复制**之后**——备份要反映迁移前的完整状态；
② `ROLLBACK` 必须在 `.bak` 覆盖**之前**——先撤事务再动文件，否则覆盖时句柄仍持有未回滚事务。
回滚测试是 T1 的强制验收项（L3 ④ 同款）。

### 4. 变更标记（零子进程、零网络）

| 项 | 实现 |
|---|---|
| 存储 | `session_meta` 两个键：`git-head`、`config-sig`（TEXT）。**取不到的键不写行**（不写 NULL 值行）：KV 表里的空值没有信息量，且会让「取不到」与「取了但为空」在查询层变得不可区分；将来真要区分时再加 `source` 列，本期不做 |
| git-head | 读 `<user-emacs-directory>/.git/HEAD`；内容形如 `ref: refs/heads/X` 时再读 `.git/refs/heads/X` 取 sha；该文件不存在（**packed refs**）时扫 `.git/packed-refs` 逐行匹配 ` refs/heads/X$` 取行首 sha；HEAD 本身是裸 sha（detached）时直接用它；任何一步失败 → NULL |
| config-sig | 新增 defcustom `el-chronos-config-watch-globs`（**落 `el-chronos.el`**），默认 `'("early-init.el" "init.el" "lisp/init-*.el")`；`file-expand-wildcards` 相对 `user-emacs-directory` 展开，对 `(相对路径 mtime size)` 排序后的列表做 `secure-hash 'sha1`；无匹配文件 → **不写该键**（不写 NULL 行） |
| 采集时机 | `el-chronos-store--ensure-session` 内，即**每会话一次**；零热路径开销、零 timer |
| 禁令 | **绝不调 git 子进程**：启动期 fork+exec 会阻塞主线程（`/mnt/c` 慢 IO 下更甚），且违背「观测不干预」；也不做 `(shell-command-to-string "git rev-parse")` |

实测依据：本机 `~/.git/HEAD` 为 `ref: refs/heads/develop` 且 `.git/refs/heads/` 与
`.git/packed-refs` **同时存在** —— 只实现 loose ref 分支会在本机就取不到 sha，
packed-refs 回退是必需路径。

### 5. GC 与内存趋势

| 指标 | 手段 | 频率 |
|---|---|---|
| GC 次数 / 耗时 | 采样 tick 内读 `gcs-done` / `gc-elapsed`，与上次基线求差，累加进 `hourly_gc` | 每个采样窗口（默认 10s） |
| 堆大小 | `(fboundp 'garbage-collect-heapsize)` 守卫 → `(cl-loop for (_name size used _free) in 结果 sum (* size used))` | 每 `el-chronos-heap-sample-windows`（默认 6）个采样窗口（约 60s），不与 tick 同步 |

- **与 profiler 采样解耦（必须）**：`gcs-done` / `gc-elapsed` / `garbage-collect-heapsize` 都**不依赖
  profiler**，所以 GC 采集代码放在 `--sample-tick` 里但**在 `(when el-chronos-collect--sampling-p ...)`
  之外**。理由：profiler 启动失败时项目的降级契约是「禁用采样，命令/心跳继续」
  （`AGENTS.md` 错误矩阵），若把 GC 采集绑进 `sampling-p` 内，内存/GC 趋势会跟着陪葬 ——
  而它恰恰是判断「是不是越用越胖」的唯一依据，最不该在故障时消失。
- **零副作用**：`gcs-done` / `gc-elapsed` 是 Emacs 自维护的全局单调计数器，读它们不触发任何
  GC；`garbage-collect-heapsize` 按官方 docstring「may not be fully up to date unless called
  right after a full GC cycle」——即它**只读、不做**，代价可忽略。这与「观测而不干预」一致。
- **禁止调 `garbage-collect`**：它会真的做一次 GC，等于观测器替用户改变了运行时行为
  （也直接污染它自己刚记录的数据）。
- **禁止用 `memory-info`**：实测返回 `(TOTAL-RAM FREE-RAM TOTAL-SWAP FREE-SWAP)`，是**系统内存**
  而非 Emacs 堆，与本维度的问题无关；且 `default-directory` 为 remote 时它有触发远端查询的
  风险（TRAMP 陷阱），在采集热路径上是不可接受的不确定性。
- **Emacs 29/30 上 `heap_bytes` 恒 NULL**：守卫失败即不采，不报错（I6），分析层返回 nil 序列。
- 口径统一：报告 `el-chronos-profile-command` 已用 `gcs-done` / `gc-elapsed` 差值（
  `el-chronos-report.el` 的「GC 差值取 `gcs-done` / `gc-elapsed`（与采集层同口径）」），
  新维度必须沿用同一对计数器，不得自造时钟。

### 6. 自监控

| 计数 | 位置 | 触发条件 |
|---|---|---|
| `dropped-commands` / `dropped-events` | store `--push-event` | 触到 `--max-buffer-items` 而 `setcdr` 截断时，累加**本次丢弃条数 = 截断前长度 − 上限**；按传入的 SLOT 分流：`el-chronos-store--buffer` → `dropped-commands`、`el-chronos-store--slow-events` → `dropped-events`（同一函数服务两个缓冲，不按 SLOT 分会把慢事件混进命令计数）。**口径说明（防御性）**：当前 `--push-event` 每次只 push 一条，差值因此恒为 1，与「每事件 +1」**在当前实现下等价**；采用差值口径是为了将来改成批量 push 时不会静默漏计 |
| `flush-failures` | store `el-chronos-store-flush` 的 error 分支 | 事务 ROLLBACK 后 +1 |
| `flush-count` / `flush-ms` | store flush 成功路径 | COMMIT 之后 +1、累加耗时（`float-time` 差 × 1000） |
| `sample-misses` | collect `--sample-tick` | 相邻两次 tick 时间差 > 2 × `el-chronos-sample-window-seconds` → +1（说明主线程被占住，窗口丢了） |

落 `hourly_health`，键名固定为 `dropped-commands` / `dropped-events` / `flush-failures` /
`flush-count` / `flush-ms` / `sample-misses`（前 5 个是 store 侧，最后一个 collect 侧）。

**已知悖论（必须在文档与 docstring 里写明）**：flush 失败时**无法**把失败计数写进库
——写库本身就是失败的那件事。处置：计数留在内存 defvar 里，**下一次成功 flush 时补写**，
即 eventual 语义，滞后上限 = 一次成功 flush 的间隔（库长期不可写时无上限）。因此：

- 五个计数各用**独立 defvar**：`--dropped-commands` / `--dropped-events` /
  `--flush-failures` / `--flush-count` / `--flush-ms-total`。它们的生命周期与缓冲**彻底解耦**
  —— 既不得放进 `--clear-aggregates` 清空的那批 hash，也不得挂在 `el-chronos-store--buffer` /
  `--slow-events` 上：ROLLBACK 会把那些容器一并清掉，于是「失败了」这件事永远不可观测。
- 归零时机：**只在事务 COMMIT 成功之后**，把「本次已写入库的那部分」减掉
  （`(- 累计 已上报)`，不是无条件清零）——失败期累积的差额必须留给下一次 flush 补写；
  ROLLBACK 路径一分不减。库里该键的累计值 + 内存里的未上报差额 = 真实总量。
- 该约束必须有**反向验证**兜住：把任一计数器塞进被清空的容器 → 对应用例必红 → 还原（T5）。

### 7. 启动分解（含覆盖范围约束，醒目）

- **手段**：`after-load-functions` 的钩子收 FILE 参数，每次 load 触发一次；记录**相邻两次
  调用的时间差**作为「前一个文件的 load 耗时」。
  这是**近似归因**（不是精确归因）：差值里含前一个文件的收尾逻辑与它触发的钩子执行。
  该措辞必须原样出现在函数 docstring 与 `docs/architecture.org`，避免被读成精确耗时。
- **阶段锚点：3 个确定性 + 1 个可选（共 4）**：
  `mode-start` / `after-init` / `startup` 为**确定性锚点**；`first-idle` 为**可选锚点**。
  （不设更早的启动锚点：mode 启动时它已过去，物理上无法记录 —— 见下方处置 ②。）
  - `mode-start`：`el-chronos-collect-start` 里直接记（这是「观测起点」）。
  - `after-init` / `startup`：若 mode 启动时 `after-init-time` / 对应 hook 尚未过，
    分别挂 `after-init-hook` / `emacs-startup-hook` 记一次；**已过则跳过**（不能倒填）。
  - `first-idle`（**可选阶段标记**）：仅在能注册 idle timer 时记一次，**不作为摘钩依据**
    （idle 时机受用户活动影响、不可预期；这正是 ADR 备选⑩ 否决「用 idle 时机做数据补写」的
    同一条理由）。
  - 包加载明细记为 `load:<library>`；**内存中保存全部 load 记录，写库前按 ms 降序截断到 top-N**
    （`el-chronos-startup-top-n`，默认 50）—— 一次启动几百条记录的内存开销可忽略，
    但全量入库会让 `startup_phases` 行数膨胀。
- **关键约束（醒目）**：用户通常在 init 末尾才 `(el-chronos-mode 1)`，此时启动已基本结束 →
  **只能记录 mode 启动之后发生的 load**，前面的全看不到。要覆盖完整启动，必须把
  `(el-chronos-mode 1)` 提前到 `early-init.el`。
  - 处置 ①：把 `mode-start` 锚点存进 `startup_phases`，报告节标题据此标注覆盖范围，
    例如「启动分解（自 mode 启动起，覆盖 X ms / 总 Y ms）」——**不许**把近似数据冒充全程。
  - 处置 ②：`docs/operations.org` 新增「想要完整启动剖析，在 `early-init.el` 末尾开启 mode」
    的操作指引（含副作用说明：early-init 期间很多设施尚未就绪，采集器自身必须能降级）。
    这也是「不设更早启动锚点」的唯一替代路径：想覆盖那一段，就把 mode 放进
    `early-init.el`，此时的「记录起点」就是 `mode-start` 本身，而不是另加一个锚点。
  - 处置 ③（**已定方案：`after-init` 只捕获值，UPDATE 并入下一次 flush 事务** —— 不改
    `--ensure-session` 现有逻辑、不改既有表语义、不新增 timer、启动期零 IO）：
    现状事实是 `--ensure-session` 在**建会话行那一刻**用
    `(when (and after-init-time before-init-time) ...)` 求差写 `startup_ms`；凡「mode 在
    `after-init-hook` 之前启用」，此刻 `after-init-time` 仍是 nil → 落 NULL → 「总 Y ms」无数据来源。
    - 分两段实现：
      ① **collect 侧（纯内存，零 IO）**：`el-chronos-collect-start` 内若本会话行的 `startup_ms`
        为 NULL，注册一次性 `after-init-hook` 回调 —— 先 `remove-hook` 自摘，然后只做一件事：
        `(* 1000 (float-time (time-subtract after-init-time before-init-time)))` 算出毫秒，
        调 `el-chronos-store-note-startup-ms`。**不写库、不碰 sqlite**。
      ② **store 侧（并入 flush 事务）**：defvar `el-chronos-store--pending-startup-ms`（nil = 无需补写）；
        `el-chronos-store-note-startup-ms (MS)` 仅在 `el-chronos-store--db` 与
        `el-chronos--session-id` 非 nil 时 `setq` 之，否则忽略（零 IO）；
        `el-chronos-store-flush` 内若 pending 非 nil，在**既有事务内**追加
        `UPDATE sessions SET startup_ms = ? WHERE id = ? AND startup_ms IS NULL`
        （`IS NULL` 守卫防覆盖已正确写入的值）；**COMMIT 成功之后**才清 pending，
        ROLLBACK 保留 pending 等下一轮补写。
    - **为什么这样最好（优于「钩子内直接 UPDATE」与「新增 first-idle timer」）**：
      ① 启动期零 IO → 彻底消除 `busy_timeout=2000ms` 最坏把启动拖住 2s 的风险；
      ② 复用既有 5s flush timer，**不新增 timer**（I5 零残留负担与清理清单都不变）；
      ③ 补写天然获得「与批量写入同一事务」的一致性，不需要额外错误处理路径 ——
      flush 本就有 ROLLBACK / 丢弃本批 / 限流告警的成熟语义。
      代价：补写延迟 ≤ 一个 flush 周期（默认 5s），在此期间读 `startup_ms` 仍为 NULL。
    - 值从哪来：`before-init-time` → `after-init-time` 现算，**不是**用 idle 时间反推
      —— 因此与「mode 在 after-init 之后启动」路径下的值口径完全一致。
    - **为什么不算「改既有表语义」**：同一字段的**延迟写入**（NULL → 真实值），列定义、主键、
      既有行的读法、分析层 `startup_ms IS NOT NULL AND startup_ms > 0` 的过滤条件全部不变；
      在 after-init 之后启动 mode 的会话行为零变化（那条路径本来就算得出、不会注册钩子）。
    - 失败与边界（实施必须照做）：
      · 三个守卫：回调内判 `el-chronos--running-p`；`note-startup-ms` 内判
        `el-chronos-store--db` 与 `el-chronos--session-id`（`store-close` 会保留 session-id
        但把 db 置 nil，两个都要判）。
      · 该 UPDATE 失败**不阻断** flush 其余部分（包 `condition-case`：记录并保留 pending，
        其余表照常；若整个事务 ROLLBACK 则 pending 天然保留）。
      · `collect-stop` **先摘钩子、再做 `--sample-tick` 收尾**（顺序反过来会让关闭途中的
        回调再置一次 pending）。
    - I5 约束：该 hook 必须进 `el-chronos-collect-stop` 的清理清单（`remove-hook` 幂等，
      回调已自摘时再摘也无副作用）；`collect-stop` 与 `store-close` 都要清
      `el-chronos-store--pending-startup-ms`。
    - 测试：early-init 场景（`after-init-time` 绑 nil 打开 store → 断言 `startup_ms` 为 NULL →
      触发回调 → 断言**库里仍为 NULL、但 pending 已置**）→ 跑一次 flush → 断言 `startup_ms`
      变为非 NULL；外加「已有值不被覆盖」（`IS NULL` 守卫）与「ROLLBACK 后 pending 保留」两例。
    - **触发条件的统一表述（不要写成「early-init 场景」）**：**mode 在 `after-init-hook` 之前启用**
      就会触发补写。实测依据：`startup.el` 第 1707 行先 `(setq after-init-time (current-time))`、
      第 1708 行才 `(run-hooks 'after-init-hook)`，两行都在 init 文件加载**之后**执行 ——
      所以 `init.el` 末尾直接 `(el-chronos-mode 1)` 同样得到 NULL，early-init 只是其中一种写法。
      本机现状（`thomas-emacs/lisp/init-chronos.el:45` 用
      `(add-hook 'emacs-startup-hook #'el-chronos-mode)`，它在 `after-init-hook` 之后）故 19/19
      会话 `startup_ms` 非 NULL —— **不能据此判断补写机制不需要**，收益在换写法/换机器时显现。
  - `session_meta` 的 `mode-start` 键**保留**，但**只作辅助信息**：报告用它区分
    「mode 启动起点」与「`after-init` 终点」，**不作为 `startup_ms` 的数据来源**
    （唯一来源仍是 `before-init-time` → `after-init-time` 的差值）。
- **零残留（I5）与摘钩条件（确定性三元，任一满足即摘）**：`after-load-functions` 的摘除**不依赖
  idle 时机**，而是：
  ① **`emacs-startup-hook` 已触发**（首选确定性锚点 —— mode 在 after-init 之前启用时，
     该 hook 一定会在启动收尾时跑到，摘钩就在它的回调里做）；
  ② **累计 load 次数 ≥ `el-chronos-startup-top-n` 的 4 倍**（防「启动 hook 迟迟不到」时无限累积）；
  ③ **自 mode 启动起超过 30 秒**（一次性普通 timer 兜底，用 `el-chronos--register-timer` 登记
     以便 I5 统一清理）。
- **前置判定：启动已结束就不挂钩子**。若 `collect-start` 执行时 `emacs-startup-hook` 早已触发
  （典型：用户用 `(add-hook 'emacs-startup-hook #'el-chronos-mode)`，本机就是这种），
  **根本不要挂 `after-load-functions`**，只记 `mode-start`。否则那 30 秒兜底窗口里用户
  `require`/打开文件触发的每一次 load 都会被记成「启动期 load」，污染 `startup_phases`（把
  「启动后加载的包」记成「启动耗时」）。这条同时让本机这类配置零额外开销。
  `el-chronos-collect-stop` 里必须摘除本计划新增的**全部**钩子（`after-load-functions`、
  条件注册的 `after-init-hook` / `emacs-startup-hook`）与那个一次性 timer，
  `remove-hook` 幂等、不在列表里也无副作用；同时清空 load 记录、相邻时间戳与
  `el-chronos-store--pending-startup-ms`。

### 8. 保留策略与 `purge`：新 4 表归类 + 10 表删除顺序

**分类裁决**

| 表 | 分类 | 自动 retention（`--prune`） | 手动 `el-chronos-purge` |
|---|---|---|---|
| `hourly_gc` | 小时聚合 | **不动** | **删**（有 `hour_ts`，按列删） |
| `hourly_health` | 小时聚合 | **不动** | **删**（有 `hour_ts`，按列删） |
| `startup_phases` | 会话级 | **不动** | **删**（无时间列，按 `session_id IN (SELECT id FROM sessions WHERE started_at < ?)`） |
| `session_meta` | 会话级 | **不动** | **删**（同上；含 `git-head` / `config-sig`，隐私相关，必须覆盖） |

- `hourly_gc` / `hourly_health` 与既有 `hourly_functions` / `hourly_usage` / `hourly_stacks`
  同类：**小时聚合、永久保留、只由 `el-chronos-purge` 手动清理**。
- `startup_phases` / `session_meta` 是**会话级**数据：生命周期跟随 `sessions` 行，由 purge 一起清；
  自动 retention 不碰（`--prune` 本来就只删 `commands` / `slow_events`）。
- **`--prune` 明确不动新 4 表**：与既有「只删明细、聚合与元数据长期保留」的约定一致 ——
  聚合是长期趋势的基础，元数据是回归归因的基础。

**`el-chronos-purge` 扩到 10 张表：删除顺序（钉死，不许改写）**

| 步骤 | 表 | 删除条件 | 为什么必须在这一步 |
|---|---|---|---|
| 1 | `commands` | `ts < ?` | **唯一带外键的表**（`session_id REFERENCES sessions(id)`，open 时 `foreign_keys=ON`）→ 必须最先，否则后面删 `sessions` 会撞约束 |
| 2 | `slow_events` | `ts < ?` | 无外键，紧跟明细表 |
| 3 | `startup_phases` | `session_id IN (SELECT id FROM sessions WHERE started_at < ?)` | **必须在 `sessions` 之前**：删完 `sessions` 后子查询恒空 → 这两张表永远删不掉，留下孤儿 |
| 4 | `session_meta` | 同上 | 同上（且是隐私表，更不允许残留） |
| 5 | `hourly_functions` | `hour_ts < ?` | 聚合表，按时间列删 |
| 6 | `hourly_usage` | `hour_ts < ?` | 同上 |
| 7 | `hourly_stacks` | `hour_ts < ?` | 同上 |
| 8 | `hourly_gc` | `hour_ts < ?` | 同上（新表） |
| 9 | `hourly_health` | `hour_ts < ?` | 同上（新表） |
| 10 | `sessions` | `started_at < ?` | **最后**：它是第 1 步外键的父表、第 3–4 步子查询的源表 |

两条**互不相同**的理由，不要混为一谈：

- **外键只约束 `commands`**：既有 DDL 里仅 `commands.session_id REFERENCES sessions(id)`；
  `hourly_functions` / `hourly_usage` / `hourly_stacks` 与新 4 表**都没有外键**。
  所以「`commands` 必须最早」由外键驱动。
- **`startup_phases` / `session_meta` 必须在 `sessions` 之前，理由不是外键而是子查询**：
  它们的删除条件依赖 `SELECT id FROM sessions WHERE started_at < ?`。若先删 `sessions`，
  子查询在删完之后恒为空 → 两表的行**永远不会被删**，成为孤儿，直接破坏 purge
  「删掉这段历史」的语义。这是最容易漏的一条。
- `before` 为 nil（清空全部）时 `--delete-rows` 走 `DELETE FROM <table>` 全表清空，
  子查询不参与，顺序此时无关紧要；但仍照上表执行，保持**单一代码路径**（一个顺序，
  两种 `before` 都走）。整个 purge 已在单事务内（`BEGIN` / `COMMIT` / 失败 `ROLLBACK`），
  新增 4 条 DELETE 并入同一事务。
- purge 结束后的既有动作保留：`--ensure-session` 重建当前会话行（否则后续写入撞外键）；
  重建时 `session_meta` 会随 `--ensure-session` 一并重写（T3 的采集点就在那里）。
  **新增一条**：重建后把该行的 `startup_ms` 显式置 NULL —— 因为 `--ensure-session` 会用
  `before-init-time` → `after-init-time` 写「本进程的启动耗时」，而此时 `started_at = now`，
  两者语义矛盾（`started_at` 说「刚启动」、`startup_ms` 说「几小时前启动」）。
  这是既有行为的暴露（purge 扩表后用户会更常触发），顺手在这里修正。

**新表不写外键**（与 `hourly_functions` / `hourly_stacks` 一致）：避免把 purge 顺序、
级联删除与 `foreign_keys=ON` 三者耦合；代价是孤儿行只能靠上面的顺序约定消灭 ——
这正是要把顺序钉死、并为它写用例的原因。

**增长速率（永久保留的代价，写进 `docs/operations.org` 的保留表）**：`hourly_gc` /
`hourly_health` 每会话每小时各 ≤ 1 / ≤ 6 行（与既有 `hourly_*` 同量级，可忽略）；
但 `startup_phases` 是**每会话 ≤ top-N + 3 行**（默认 ≤ 53 行；`first-idle` 可选锚点若记录则 +1）——
比 `sessions` 的 1 行/会话
高两个量级，长期频繁重启的机器上会明显增长。这是本项目最值得留意的一张表，
保留表要写明这个估算。

**隐私**：`session_meta` 的 `git-head`（分支与提交）与 `config-sig`（配置指纹）属
**用户可识别信息**。purge 必须删全部（含当前会话行的 meta），并在 `docs/operations.org`
的隐私/保留表中显式声明；`AGENTS.md` 的隐私边界清单要补上这两个键。

### 9. 分析层新增 4 个查询

全部只读、全部用既有 `el-chronos-analysis--guard`（`el-chronos-analysis.el` 第 83 行的宏，
出错告警并返回 nil），返回 plist，单位遵守 I4（耗时毫秒、时间戳毫秒）：

| 查询 | 签名 | 返回 |
|---|---|---|
| `el-chronos-analysis-gc-trend` | `(RANGE &optional BUCKETS)` | `(:buckets ((:bucket :gc-count :gc-ms :heap-bytes) ...) :heap-latest N :gc-total N)`；`heap-bytes` 无样本为 nil |
| `el-chronos-analysis-startup-breakdown` | `(SESSION-ID)` | `(:session-id N :total-ms X :phases ((:phase "..." :ms X) ...) :loads ((:library "..." :ms X) ...))`，按 ms 降序 |
| `el-chronos-analysis-health` | `(RANGE)` | `(:keys (("dropped-commands" . N) ...) :samples-misses N :flush-failures N)`（键值按小时聚合后求和） |
| `el-chronos-analysis-config-history` | `(RANGE)` | `(:sessions ((:session-id :started-at :git-head :config-sig) ...) :changes ((:at-ms N :key "git-head" :from "..." :to "...") ...))` —— 相邻会话的变化点 |

## 任务

- [ ] **T1 schema v2 迁移（store）**
  改动文件：`/home/thomas/Workspace/el-chronos/el-chronos-store.el`、
  `/home/thomas/Workspace/el-chronos/test/el-chronos-store-test.el`
  步骤：① 新增 4 个单表 DDL 常量（设计 2 的 SQL **逐字**）；② `--schema-ddl` 改为
  「旧 6 表 + 3 索引」串 concat 四个新串（保持 `commands` 在 `sessions` 后，顺序不可改）；
  ③ `--sql-migrate-v2` = 四个新串 concat；④ `--schema-version` 改 2；
  ⑤ `--migrate` 加 `(when (= from-version 1) ...)` 分支 + **显式事务边界**：`.bak` 复制 →
  `BEGIN` → batch → `COMMIT`；失败先 `ROLLBACK`，再走既有回滚路径（关句柄 → `.bak` 覆盖
  → 删 `-wal`/`-shm` → 告警 → 返回 nil）。两条顺序不可颠倒：`.bak` 在 `BEGIN` 之前、
  `ROLLBACK` 在覆盖之前（见设计 3 陷阱 2/3）；
  ⑥ 更新 `--ensure-schema` / `--migrate` / `--schema-version` 的 docstring；
  ⑦ **`el-chronos-purge` 扩到 10 张表**（按设计 8 的顺序表逐条加：`startup_phases` /
  `session_meta` 用 `session_id IN (SELECT id FROM sessions WHERE started_at < ?)`，
  且**必须排在 `sessions` 之前**；`hourly_gc` / `hourly_health` 用 `hour_ts < ?`），
  新表**不写外键**；`--prune` **不加**任何新表。
  注意 `el-chronos-store--delete-rows` 现在的签名只支持 `(TABLE COLUMN BEFORE)` 的
  `COLUMN < ?` 形态，**无法表达子查询删除** → 要么扩签名为可传完整 WHERE 片段，
  要么对这两张表直接 `sqlite-execute`（推荐后者：改动面最小，也避免把表名/列名拼进通用函数）。
  purge 末尾重建会话行后，把新行的 `startup_ms` 显式置 NULL（设计 8 的最后一条）。
  ⑧ **同步修改两个既有用例**（改既有用例属计划内允许，须在 `CHANGELOG.md` 说明原因）：
  · `el-chronos-store-test-user-version-migration`（`test/el-chronos-store-test.el:35-48`）：
    断言表数 `= 6` → `= 10`，`user_version` `= 1` → `= 2`；
  · `el-chronos-store-test-purge-empties-and-rebuilds-session`
    （`test/el-chronos-store-test.el:219-241`）：返回 alist `= 6` 项 → `= 10` 项，
    「6 表清空」→「9 表清空 + `sessions` 重建（≥ 1 行）」。
  ⑨ **purge 用例的 fixture 前置条件（必须写在步骤里，别只写验收）**：purge 相关用例要在
  **临时目录**下运行，且必须 **`let` 绑定 `user-emacs-directory` 到该临时目录**（只造一个空目录
  不够 —— `--git-head` / `--config-sig` 读的是 `user-emacs-directory`，不绑定就会去读真实的
  `~/.git` 与真实 init 文件，让断言必红）。该临时目录**无 `.git`、无 `early-init.el` / `init.el`、
  无 `lisp/init-*.el`** —— 否则 T3 的变更标记会往 `session_meta` 写 1–2 行，
  让「其余表为 0」的断言必红（T3 与 T1 的交叉约束）。
  验收标准：`make check-parens` 通过、`make lint` 零告警；新增**五个**用例
  ——**「v1 库升级后既有数据保留」**（用 v1 旧 DDL 建库 + `user_version=1` + 插 2 行
  `commands` → open → 10 张表齐、`commands` 仍 2 行、`user_version` = 2）、
  **「新库直接建全 10 表」**（空路径 open → `sqlite_master` 中 table 计数 = 10、
  `user_version` = 2）、**「迁移失败整体回滚」**（`cl-letf` 让 `--sql-migrate-v2` 抛错 →
  `--migrate` 返回 nil、`user_version` 仍 1、仍只有 6 表、随后能正常再次打开）、
  **「purge 后 9 表清空 + sessions 重建」**（10 表各插 1 行 → `(el-chronos-purge)` →
  断言 `sessions >= 1`（重建的当前会话行）、**其余 9 表 `count(*) = 0`**、返回 alist 含 10 项；
  在 ⑨ 的 fixture 下 `session_meta` 必为 0 —— 若 fixture 里意外存在 `.git` 或 init 文件，
  该用例的 `session_meta` 断言应显式放宽为 `<= 2` 并注明原因，**不许**改成「差不多空」）、
  **「purge 带 before 时不留孤儿」**（造 2 个会话：旧 + 当前，各自带 `startup_phases` /
  `session_meta` 行 —— 这两类行**手工 INSERT**，不要依赖 T3 写入路径，否则在 ⑨ 的干净
  fixture 下建不出来 → `purge` 到新旧之间 → 旧会话的这两个表行**为 0**，
  即子查询删除确实生效、没被「先删 sessions」毁掉）、以及
  **「`--prune` 不动新表」**（`--prune` 后 `hourly_gc` / `hourly_health` /
  `startup_phases` / `session_meta` 行数不变）；
  `make test` 全绿。
  （依赖：无）

- [ ] **T2 store 写入层（4 个 record + note-startup-ms + flush 扩展）**
  改动文件：`/home/thomas/Workspace/el-chronos/el-chronos-store.el`、
  `/home/thomas/Workspace/el-chronos/test/el-chronos-store-test.el`
  步骤：① 新增内存聚合：`--gc`（键 `"hour|session"` → `[count ms heap]`）、
  `--health`（键 `"hour|session|key"` → 数值）、`--startup`（alist）、`--meta`（alist）；
  ② 4 个对外函数 `el-chronos-store-record-gc (HOUR-TS GC-COUNT GC-MS HEAP-BYTES)`、
  `-record-startup-phase (SESSION-ID PHASE MS)`、`-record-health (HOUR-TS KEY VALUE)`、
  `-record-session-meta (SESSION-ID KEY VALUE)`；③ 4 条 upsert SQL 常量（设计 2 的语义）；
  ④ `--pending-p` 纳入 4 个新容器**以及 `--pending-startup-ms`**（关键：否则待补写的
  `startup_ms` 是唯一残留时 flush 会早退，pending 永远挂到下一次有别的数据要写）；
  ⑤ flush 在**同一** `BEGIN`/`COMMIT` 内写四表；
  ⑥ `--clear-aggregates` 清空 4 个新容器（成功路径与失败路径都要清，与既有取舍一致）；
  ⑦ 新增 defvar `el-chronos-store--pending-startup-ms`（nil = 无需补写）与
  `el-chronos-store-note-startup-ms (MS)`：仅在 `el-chronos-store--db` 与
  `el-chronos--session-id` 非 nil 时 `(setq el-chronos-store--pending-startup-ms MS)`，
  否则静默忽略 —— **零 IO**（不碰 sqlite、不碰 timer），供 T6 的 `after-init-hook` 回调调用；
  ⑧ `el-chronos-store-flush` 内（**既有 `BEGIN`/`COMMIT` 事务内**）若 pending 非 nil，执行
  `UPDATE sessions SET startup_ms = ? WHERE id = ? AND startup_ms IS NULL`
  （**`IS NULL` 守卫必须有**，防覆盖 `--ensure-session` 已正确写入的值）；该语句单独
  `condition-case`：失败只记录并**保留 pending**、不阻断其余表写入；
  **COMMIT 成功之后**才清 pending，ROLLBACK 保留 pending 等下一轮。
  验收标准：两次 `record-gc` 同小时 → 一行、`gc_count` 累加；第二次 `heap-bytes` 传 nil →
  `heap_bytes` 保留首值（`COALESCE`，即「最后一次非 NULL 值胜出」，设计 2 的理由）；
  同一小时内先写非 NULL 再写 NULL 再写非 NULL → 最终值是**最后一个非 NULL**（不是最后写入的 NULL）；
  `record-session-meta` 同键两次 → 后者覆盖；`record-startup-phase` 同 phase 两次 → 后者覆盖；
  **补写四例**：① `note-startup-ms` 在 db 或 session-id 为 nil 时**不置 pending**（零 IO 路径）；
  ② pending 置后 flush 一次 → `startup_ms` 变非 NULL 且 pending 被清；
  ③ `IS NULL` 守卫：会话行已有 `startup_ms` 时 UPDATE 不修改（影响行数 = 0）；
  ④ **ROLLBACK 后 pending 保留**（注入 flush 失败 → pending 仍非 nil → 下一次成功 flush 补上）；
  **外加一例**：pending 是**唯一**残留（其它缓冲全空）时 flush 仍会执行并写库
  （验证 `--pending-p` 已纳入它，否则早期版本会静默早退）；
  `make test` 全绿。
  （依赖：T1）

- [ ] **T3 变更标记采集（git-head / config-sig）**
  改动文件：`/home/thomas/Workspace/el-chronos/el-chronos.el`（defcustom 归 `el-chronos` 组）、
  `/home/thomas/Workspace/el-chronos/el-chronos-store.el`（只放 `--git-head` / `--config-sig`
  实现，**不得新增 defcustom**）、
  `/home/thomas/Workspace/el-chronos/test/el-chronos-store-test.el`
  步骤：① defcustom `el-chronos-config-watch-globs`（string 列表，默认
  `'("early-init.el" "init.el" "lisp/init-*.el")`，docstring 说明「相对 user-emacs-directory 展开」
  与「**取不到的键不写行**」）；② `el-chronos-store--git-head`（loose ref → packed-refs → 裸 sha
  三分支，全 `condition-case` 内）；③ `el-chronos-store--config-sig`（glob 展开 + mtime/size
  sha1）；④ `--ensure-session` 在建会话行后写这两个键 —— **采用直接 `sqlite-execute` 写入，
  不走 flush 缓冲**：变更标记是「每会话一次」的冷路径，立即写库可立即可见、不占缓冲、
  不参与批量事务，且失败可独立告警（不进 `--clear-aggregates` 的丢弃路径）。
  **写入规则：只写取到值的键**（`git-head` 取不到就只写 `config-sig`，反之亦然；都取不到则
  一行都不写）。**绝不写 NULL 值行** —— KV 表存空值无信息量，且让「取不到」与「取了但为空」
  在查询层不可区分。
  验收标准：临时目录伪造 `.git/HEAD` + `refs/heads/main` → 得到该 sha；
  仅 `packed-refs`（无 loose 文件）→ 同样得到 sha；
  **临时目录既无 `.git` 也无 `early-init.el` / `init.el` / `lisp/init-*.el` → `session_meta`
  为 0 行**（且不报错不告警）；只有 `.git`、无 init 文件 → 只 1 行（`git-head`）；
  两个不同内容的 `init.el` → 不同 `config-sig`；
  **写入立即落库**（`--ensure-session` 之后不跑 flush，直接查 `session_meta` 就能读到相应行）；
  `make test` 全绿。
  （依赖：T2）

- [ ] **T4 GC 采集（collect sample-tick + store record）**
  改动文件：`/home/thomas/Workspace/el-chronos/el-chronos.el`（新增 defcustom
  `el-chronos-heap-sample-windows`，默认 6 —— defcustom 一律落此文件）、
  `/home/thomas/Workspace/el-chronos/el-chronos-collect.el`、
  `/home/thomas/Workspace/el-chronos/test/el-chronos-collect-test.el`
  步骤：① defvar `--gc-baseline`（`(gcs-done . gc-elapsed)`）与 `--heap-window-count`；
  ② `--sample-tick` 内新增 `el-chronos-collect--collect-gc`，**放在
  `(when el-chronos-collect--sampling-p ...)` 之外**（与 profiler 采样互不依赖：
  `gcs-done` / `gc-elapsed` / `garbage-collect-heapsize` 都不需要 profiler；
  若绑在 `sampling-p` 内，profiler 启动失败时「禁用采样、命令/心跳继续」的降级契约会让
  GC 与内存趋势一起陪葬，见设计 5）：取差值（负值按 0 处理，同 `--finish` 的既有做法）→
  `-record-gc`；每 `el-chronos-heap-sample-windows`（默认 6）个窗口调
  `--heap-bytes` 取堆大小一并传，其余窗口传 nil（NULL 由 `COALESCE` 保旧值，设计 2）；
  ③ `el-chronos-collect--heap-bytes`：`(fboundp 'garbage-collect-heapsize)` 守卫，
  不可用返回 nil（**只有这一个名字，无短别名**）；④ `collect-start` 初始化基线，`collect-stop` 清空。
  验收标准：`cl-letf` 伪造 `gcs-done` / `gc-elapsed` → 差值正确落库；伪造
  `--heap-bytes` 返回 nil → `heap_bytes` 为 NULL（覆盖「29/30 无该函数」路径）；
  **`el-chronos-collect--sampling-p` 为 nil 时 `--collect-gc` 仍执行并落库**
  （解耦验证：模拟 profiler 启动失败，`hourly_gc` 仍新增行）；
  `grep -c 'garbage-collect\b' el-chronos-collect.el` 中**不得**出现裸调用
  `(garbage-collect)`；`make test` 全绿。
  （依赖：T2）

- [ ] **T5 自监控计数（store flush 路径 + collect 采样窗口）**
  改动文件：`/home/thomas/Workspace/el-chronos/el-chronos-store.el`、
  `/home/thomas/Workspace/el-chronos/el-chronos-collect.el`、
  `/home/thomas/Workspace/el-chronos/test/el-chronos-store-test.el`、
  `/home/thomas/Workspace/el-chronos/test/el-chronos-collect-test.el`
  步骤：① 5 个**独立 defvar** 计数器 —— `--dropped-commands` / `--dropped-events` /
  `--flush-failures` / `--flush-count` / `--flush-ms-total`（不放进 `--clear-aggregates`
  清空的 hash，也不挂在 `--buffer` / `--slow-events` 上，见设计 6 的悖论）；
  ② `--push-event` 截断处累加**差值**（截断前长度 − 上限），按 SLOT 分
  `dropped-commands` / `dropped-events`；
  ③ flush 成功路径：`flush-count` +1、`flush-ms-total` 累加、COMMIT 后把「已上报」部分写成
  `hourly_health` 行并**减去**该部分（不是无条件清零）；失败路径只 `flush-failures` +1（一分不减）；
  ④ collect `--sample-tick` 判定窗口丢失并 `-record-health`；⑤ 键名常量集中定义避免拼写漂移；
  ⑥ **`el-chronos-store-close` 必须清空这 5 个计数器**（`--dropped-commands` /
  `--dropped-events` / `--flush-failures` / `--flush-count` / `--flush-ms-total`），
  且该清理**与 `--clear-aggregates` 分离**：后者是 flush 路径的「本批数据已处理」语义，
  前者是 close 路径的「进程内状态归零」语义；混在一起会让「同进程反复 open/close」
  累积出一份不属于任何会话的历史计数。
  验收标准：`cl-letf` 让 flush 的 `sqlite-execute` 抛错 → `flush-failures` = 1 且库中无 health 行；
  下一次正常 flush → 库中出现 `flush-failures` = 1（eventual 补写）；缓冲超 `--max-buffer-items`
  → `dropped-commands` 等于实际丢弃条数；伪造 tick 间隔 → `sample-misses` +1；
  **`store-close` 后 5 个计数器全部归零**（且 close 不依赖 `--clear-aggregates`：把
  `--clear-aggregates` 整个 `cl-letf` 掉，close 仍能归零）；
  **反向验证**：把计数器塞进 `--clear-aggregates` 清空的 hash → 对应用例必红 → 还原；
  `make test` 全绿。
  （依赖：T2）

- [ ] **T6 启动打点（after-load-functions + 阶段锚点 + top-N）**
  改动文件：`/home/thomas/Workspace/el-chronos/el-chronos.el`（defcustom
  `el-chronos-startup-top-n`）、`/home/thomas/Workspace/el-chronos/el-chronos-collect.el`、
  `/home/thomas/Workspace/el-chronos/test/el-chronos-collect-test.el`
  步骤：① defcustom `el-chronos-startup-top-n` 默认 50（**落 `el-chronos.el`**）；
  ② `--startup-loads` hash + `--startup-last-load-at` 时间戳；
  `el-chronos-collect--note-load (FILE)` 记前一次的差值；
  ③ `collect-start` **先判启动是否已结束**：若 `emacs-startup-hook` 已触发（启动已完成），
  **不挂** `after-load-functions`、只记 `mode-start`；否则挂 `after-load-functions` + 条件注册
  `after-init-hook` / `emacs-startup-hook`（同时写 `session_meta` 的 `mode-start` 键，仅作
  辅助信息），并挂一次性 30s 兜底 timer（见 ④ 的摘钩三元）；
  ④ **摘钩用确定性三元条件**（`el-chronos-collect--maybe-detach-load-hook`，任一满足即摘，
  不依赖 idle 时机）：① `emacs-startup-hook` 已触发；② 累计 load 次数 ≥
  `el-chronos-startup-top-n` × 4；③ 自 mode 启动起超过 30 秒（一次性 timer）。`first-idle`
  仅作**可选**阶段标记（能注册 idle timer 时才记），不作为摘钩依据；
  ⑤ 写库前按 ms 降序取 top-N（`load:<library>`）—— **内存中保存全部 load 记录**，
  只在写库时截断；
  ⑥ **重排 `el-chronos-collect-stop` 的现有顺序**为：**先摘 `after-load-functions` /
  `after-init-hook` / `emacs-startup-hook` 与新登记的一次性 timer → 再 `--sample-tick` 收尾 →
  再摘其余钩子（`pre/post-command-hook`、`buffer-list-update-hook`、advice 等）**。
  现有代码是相反顺序（先 `--sample-tick` 再摘钩子），重排的理由：收尾期间若有 idle/hook
  触发会往 pending 或 load 记录里再塞值，摘得越早越干净；
  ⑦ **`startup_ms` 值捕获（纯内存，零 IO）**（设计 7 处置 ③）：若本会话行的 `startup_ms` 为 NULL
  （即「mode 在 `after-init-hook` 之前启用」），注册一次性 `after-init-hook` 回调 —— 先
  `remove-hook` 自摘，再用 `before-init-time` → `after-init-time` 现算毫秒，调 T2 的
  `el-chronos-store-note-startup-ms`；**回调内不写库、不碰 sqlite**（真正落库由 store 的下一次
  flush 事务完成）；回调整体 `condition-case` 包裹，失败只告警。
  验收标准：手动触发 `--note-load` 三次 → 得两个 `load:*` 阶段项（差值语义）；
  **top-N 只在写库时截断**（内存记录 10 条、设 `el-chronos-startup-top-n` = 2 → 库里只 2 行，
  且断言截断发生在写库前而不是 push 时）；
  **摘钩三元各一例**：① `emacs-startup-hook` 触发 → 钩子被摘；② 累计 load 次数达到
  `4 × top-n` → 钩子被摘（模拟 startup-hook 永不触发）；③ 30 秒兜底 timer → 钩子被摘；
  **启动已结束时根本不挂**：让 `emacs-startup-hook` 先跑完再 `collect-start` →
  断言 `(memq #'el-chronos-collect--note-load after-load-functions)` 立即为 nil
  （本机 `emacs-startup-hook` 配置的保护用例）；
  并断言 **`first-idle` 不参与摘钩**（不注册 idle timer 时，靠 ①/②/③ 仍能摘干净）；
  **mode 在 after-init 之前启用时 `startup_ms` 最终非 NULL**（绑 `after-init-time` 为 nil 开
  store → 断言 NULL → 触发回调 → 断言**库里仍 NULL 且 pending = 差值** → 跑一次 flush →
  断言非 NULL 且值 = before/after-init-time 差值）；
  **回调零 IO**：回调执行期间 `sqlite-execute` 调用次数为 0（`cl-letf` 计数）；
  **`collect-stop` 新顺序**：stop 执行期间再触发一次 `--note-load` / `after-init` 回调，
  断言 pending 与 load 记录**不再变化**（证明钩子先被摘掉）；
  `collect-stop` 后 `(memq #'el-chronos-collect--note-load after-load-functions)` 为 nil、
  `after-init-hook` 不含本模块回调、一次性 timer 不在 `el-chronos--active-timers`、
  hash 与 pending 标志为空（I5）；`make test` 全绿。
  （依赖：T2）

- [ ] **T7 analysis 4 个查询 + 测试**
  改动文件：`/home/thomas/Workspace/el-chronos/el-chronos-analysis.el`、
  `/home/thomas/Workspace/el-chronos/test/el-chronos-analysis-test.el`
  步骤：按设计 9 的签名实现 4 个函数，全部包在 `el-chronos-analysis--guard` 内，
  复用既有 `--bounds` / `--range-buckets` / `--bucket-span` / `--select` 小工具；
  表不存在或无数据时返回空结构（不返回 nil，避免下游判空分叉）。
  验收标准：4 个新查询各 2–3 个用例（有数据 / 空库 / 变化点计算）；空库时返回
  `(:buckets nil ...)` 而非 nil；`make test` 全绿、`make lint` 零告警。
  （依赖：T1）

- [ ] **T8 report 新增 3 节（GC 与内存 / 采集健康 / 启动分解）**
  改动文件：`/home/thomas/Workspace/el-chronos/el-chronos-report.el`、
  `/home/thomas/Workspace/el-chronos/test/el-chronos-report-test.el`
  步骤：① 用现有 `el-chronos-report--table-section` 追加三节，位置：GC 与内存（「趋势」之后）、
  采集健康（「会话」之后）、启动分解（「会话」之后、「调用栈 TOP」之前）；
  ② 启动分解节标题必须动态写出覆盖范围（取 `startup_phases` 的 `mode-start` 与
  `first-idle` —— 后者是**可选**锚点，缺失时退化为「自 mode 启动起，覆盖 X ms」，
  不出现「总 Y ms」半句，格式见设计 7）；③ 空数据节按既有约定渲染空表，不省略标题。
  验收标准：报告节数 10 → 13；三个新标题字符串断言；`heap_bytes` 全 NULL 时该列显示 `-`
  而非 `0`；`make test` 全绿。
  （依赖：T7）

- [ ] **T9 Web 新增路由（/api/gc、/api/health、/api/startup）+ dashboard 面板**
  改动文件：`/home/thomas/Workspace/el-chronos/el-chronos-web.el`、
  `/home/thomas/Workspace/el-chronos/test/el-chronos-web-test.el`
  步骤：① `el-chronos-web--routes` 追加三条（命名与既有 `"/api/top-functions"` 同风格）；
  ② 三个 route 函数走 `--without-block-events` 外层（既有 500 降级路径自动覆盖）；
  ③ 内嵌 HTML/JS 追加对应面板（纯字符串内嵌，不引 CDN/图表库 —— I10）；
  ④ 保持「只读 GET、单线程串行、16KB 上限」不变。
  验收标准：三条新路由返回 200 + 合法 JSON 且键名与 T7 的 plist 一致；
  非 GET → 405；路由数 13 → 16；`make test` 全绿。
  （依赖：T7）

- [ ] **T10 文档同步 + 测试补齐 + 归档**
  改动文件：`/home/thomas/Workspace/el-chronos/docs/schema.org`（表数 **6 → 10**：v2 DDL +
  4 表说明 + **保留分类**（`hourly_gc` / `hourly_health` 属小时聚合、永久保留；
  `startup_phases` / `session_meta` 属会话级、随 `sessions` 由 purge 清理）+
  **purge 10 表删除顺序与两条理由**（commands 外键 / 子查询必须先于 sessions）+
  upsert 与 `COALESCE` 语义（含 last-observation-carried-forward 与该假象的读法）+ 「零 ALTER」理由）、
  `/home/thomas/Workspace/el-chronos/docs/api.org`（分析 13 → 17 个查询、
  5 个新 store 对外函数（4 个 record + `note-startup-ms`）、
  **defcustom 17 → 20**（`el-chronos.el` 15 → 18，另 2 个历史分散项照录、不迁移）、collect 新钩子）、
  `/home/thomas/Workspace/el-chronos/docs/architecture.org`（采集路径由 4 条扩到 6 条：
  路径 5 = 启动分解、路径 6 = GC/内存；**近似归因**措辞；启动覆盖范围约束）、
  `/home/thomas/Workspace/el-chronos/docs/ui.org`（路由 13 → 16 条 + 三个新面板）、
  `/home/thomas/Workspace/el-chronos/docs/operations.org`（early-init 开启 mode 的完整启动剖析指引，
  **并直白写明物理边界**：「若用 `emacs-startup-hook` 或任何启动结束之后开启 mode，
  启动分解只含 `mode-start` 一个锚点、无包加载明细 —— 观测器无法观测自己被加载之前的事；
  要完整剖析请把 `(el-chronos-mode 1)` 提前到 `early-init.el`」，
  **并写明触发条件统一表述**：「mode 在 `after-init-hook` 之前启用（含 `init.el` 末尾写法）时
  `startup_ms` 由 `after-init-hook` 捕获值、下一次 flush 补写，最长延迟一个 flush 周期」；
  **保留策略表新增 4 行**（`hourly_gc` / `hourly_health` 永久保留、只由 purge 清；
  `startup_phases` / `session_meta` 随会话由 purge 清）+ **隐私边界补 `git-head` / `config-sig`
  两键并声明「purge 删全部」**；排障：「heap_bytes 为 NULL」= Emacs < 31 正常、
  「采集健康」页有丢弃计数时的处置）、
  `/home/thomas/Workspace/el-chronos/AGENTS.md`（目录结构行数/用例数（**121 用例 / attrib 28**）、
  基线数字、**隐私边界清单补 `session_meta` 的 `git-head` / `config-sig` 两键与「purge 删全部」**、
  已知边界表新增**两类各一行**：「内存/GC 观测口径（`heap_bytes` 仅 Emacs 31+；稀疏采样下同小时
  只留最后一个非 NULL 值，29/30 会话该列恒 NULL → 跨版本混图出现空洞）」「启动分解覆盖范围（自 mode
  启动起，非全程）」—— **必须与第 172 行既有的「采样归因口径（nil 帧与 C 原语）」
  不重复**，不得改写那一行）、
  `/home/thomas/Workspace/el-chronos/CHANGELOG.md`（`[Unreleased]` → `### 新增`）、
  `/home/thomas/Workspace/el-chronos/openspec/tech-debt.md`（**编号从 TD-15 起** —— TD-13 /
  TD-14 已被前置计划 `fix-sampling-attribution` 占用，且**不得改 TD-1～TD-14 任何既有条目**：
  TD-15「`heap_bytes` 仅 Emacs 31.1+ 可用，29/30 恒 NULL；跨版本混图时曲线出现空洞」、TD-16「启动分解覆盖范围受加载时机限制，默认只能看 mode 之后」、
  可选 TD-17「`hourly_health` 只有小时粒度，flush 失败的具体时刻与 eventual 滞后不可见」
  —— 前两条必写，TD-17 视实施时判断）、
  `/home/thomas/Workspace/el-chronos/Readme.org`（用例数与新增能力概览）
  步骤：逐份增量更新（先读后写），命令/示例必须可复制执行；最后把本计划移入
  `openspec/completed/`。
  验收标准：`make full-check` + `make lint` 全绿；文档 grep 判据（`user_version=2`、16 条路由、
  17 个查询、`garbage-collect-heapsize`、early-init 指引、**`purge` 覆盖 10 张表**、
  **`defcustom` 合计 20**、**隐私边界含 `git-head` / `config-sig`**）全部命中；
  `openspec/active/` 只剩 `.gitkeep`。
  （依赖：T1–T9 全部）

依赖关系汇总：**T2←T1；T3 / T4 / T5 / T6←T2；T7←T1；T8←T7；T9←T7；T10←全部**。

### 影响与代价

- **schema 面积 +4 表**（6 表 3 索引 → 10 表 3 索引）：迁移与备份路径多一处风险面，
  但换来「内存维度可观测」与「回归可归因」。
- **启动分解对一部分用户等于不存在（物理边界，必须直白写明）**：若用 `emacs-startup-hook`
  （或任何启动结束之后）开启 mode，`startup_phases` 只会有 `mode-start` 一个锚点、
  **没有任何包加载明细** —— 观测器无法观测自己被加载之前发生的事，这是物理边界，
  不是 bug。想要完整剖析就把 `(el-chronos-mode 1)` 提前到 `early-init.el`。
  这条要原样写进 `docs/operations.org` 与报告节标题的注释里，**不许藏**。
- **`purge` 的语义面扩大**：6 张表 → **10 张表**，且新增一条**静默失败型**顺序约束
  （`startup_phases` / `session_meta` 的子查询删除必须先于删 `sessions`，否则孤儿行永久残留
  且不报错）；`--prune` 明确不碰新表。因此 T1 必须带「purge 后 10 表全空」「purge 带 before
  不留孤儿」「`--prune` 不动新表」三个用例。
- **报告 10 → 13 节、Web 13 → 16 路由、analysis 13 → 17 查询**：文档与测试同步面扩大。
- **用例 121 → 约 149–159**（预计 +28–38，以实测为准；修订时磁盘实测 121，实施期若再度漂移以当时实测为准）：`make test` 单次运行时间会上升。
- **`heap_bytes` 仅 Emacs 31+ 可用**：29/30 用户永远看到空序列 —— 这是能力缺口不是 bug，
  必须写进文档避免误判为采集失败。
- **启动分解覆盖范围受限**：默认配置下只覆盖 mode 启动之后的 load，前端必须如实标注。
- **健康计数是 eventual 语义**：写库失败的那批计数要等下一次成功 flush 才可见。
- **启动耗时多一条延迟写入路径**：「mode 在 `after-init-hook` 之前启用」的会话，`startup_ms`
  要等下一次 flush 才非 NULL —— 延迟 ≤ 一个 flush 周期（默认 5s），此前读该列为 NULL；
  代价是多一个 hook 的清理责任（I5）与一个 pending 状态，但**不新增 timer、启动期零 IO**。
- **`heap_bytes` 的读数有「稀疏 + 空洞」两个坑**：同一小时只保留最后一个采样值；
  29/30 会话的 `heap_bytes` 恒 NULL，跨版本混图时曲线会出现空洞（不是水平平台）。
  前端与文档都要给出按 `emacs_version` 分组的读法。

### 10. 修订记录（plan-reviewer 复审，X1–X10）

- **X1（blocking）** 新增设计 8「保留策略与 purge」：4 张新表分类裁决、`--prune` 不动新表、
  purge 扩到 10 表并钉死删除顺序与两条理由、新表不写外键、`session_meta` 隐私、
  **增长速率估算**（`startup_phases` 每会话 ≤ 53 行，`first-idle` 记录时 ≤ 54）；联动 T1（步骤⑦ + 五个 purge 用例）、
  T10、文档清单与影响与代价。另补两条实施细节：`--delete-rows` 签名不支持子查询删除
  （这两张表直接 `sqlite-execute`）、purge 重建会话行后把 `startup_ms` 置 NULL（避免
  `started_at=now` 与旧启动耗时自相矛盾）。
- **X2（major）** 基线 120 → **121**（attrib 27 → 28），预估总数 148–158 → **149–159**；
  覆盖设计 §0 基线表、L2、影响与代价、T10/文档清单，并保留「以实施期实测为准」。
- **X3（major）** 设计 5 与 T4 明确 `--collect-gc` 放在 `(when sampling-p ...)` **之外**，
  并加验收「`--sampling-p` 为 nil 时仍执行并落库」。
- **X4（major）** 注意事项 11 改为事实陈述：既有 **17 个** defcustom（`el-chronos.el` 15 +
  collect 1 + report 1）；新 3 个一律落 `el-chronos.el`（→ 18 / 全仓 20），既有 2 个分散项不迁移。
- **X5（major）** 设计 7 与 T6 的摘钩改**确定性三元**（`emacs-startup-hook` 触发 /
  load 次数达 `4 × top-n` / 30s 一次性 timer），`first-idle` 降为**可选**阶段标记、不作摘钩依据；
  ADR 备选⑩ 措辞同步澄清（否决的是「用 idle 时机做数据补写」）。
  **补强（我方发现）**：若 `collect-start` 时启动已结束（`emacs-startup-hook` 已触发，
  如本机 `(add-hook 'emacs-startup-hook #'el-chronos-mode)` 的配置），则**根本不挂**
  `after-load-functions` —— 否则 30s 兜底窗口里用户交互触发的 load 会被记成「启动期 load」，
  污染 `startup_phases`。已写入设计 7 与 T6 步骤③ + 验收。
- **X6（minor）** T6 显式要求**重排 `collect-stop`**：先摘新钩子 → `--sample-tick` 收尾 →
  再摘其余钩子（现有代码是相反顺序），并加顺序验证用例。
- **X7（minor）** 设计 6 的丢弃口径改为**防御性表述**：当前每次 push 一条、差值恒为 1，
  与「+1」等价；采用差值是为将来批量 push 不漏计。用例不变。
- **X8（minor）** 设计 7 与 T6 统一为「**内存保存全部 load 记录，写库前截断到 top-N**」。
- **X9（minor）** T5 新增步骤⑥：`store-close` 清空 5 个自监控计数器，且与
  `--clear-aggregates` **分离**（close 语义 vs flush 语义），加「close 归零」用例。
  补充语义：`store-close` 首行已 `(ignore-errors (el-chronos-store-flush))`，若该次 flush 成功，
  计数已上报、清零无损失；若失败，未上报差额随 close 丢弃 —— 与既有「flush 失败丢弃本批」
  同级，不额外告警。
- **X10（minor）** T3 定案：`--ensure-session` 内**直接 `sqlite-execute` 写入**
  `session_meta`（不走 flush 缓冲），删掉原二选一表述并给出理由与「立即可见」用例。

**第二轮复审（Y1–Y4）**

- **Y1（major）** 语义定案：`session_meta` 的键**取不到一律不写行、不写 NULL 值行**
  （KV 空值无信息量，且让「取不到」与「取了但为空」不可区分；将来要区分再加 `source` 列）。
  落点：设计 4 表格行、T3 步骤④与验收；T1 步骤⑨写明 **fixture 前置条件**（临时
  `user-emacs-directory` 无 `.git`、无 init 文件），验收改为「`sessions >= 1` + **其余 9 表
  为 0**」并给出 fixture 不满足时的放宽写法。
- **Y2（minor）** T1 步骤⑧：同步改两个既有用例
  （`el-chronos-store-test-user-version-migration` 表数 6→10 / version 1→2；
  `el-chronos-store-test-purge-empties-and-rebuilds-session` alist 6→10 项、6 表→9 表清空），
  并注明「改既有用例须在 CHANGELOG 说明原因」。
- **Y3（minor）** 设计 7 锚点列表删掉 `early-init`（mode 启动时它已过，物理上无法记录），
  固定为 **3 个确定性锚点（`mode-start` / `after-init` / `startup`）+ 1 个可选（`first-idle`）**；
  设计 8 与修订记录的增长估算同步改为「top-N + 3（`first-idle` 记录时 +1，≤ 54）」。
- **Y4（minor）** 影响与代价与 T10 的 `docs/operations.org` 各加一条**直白的物理边界声明**：
  「用 `emacs-startup-hook` 或任何启动结束后开启 mode ⇒ 启动分解只有 `mode-start` 一个锚点、
  无包加载明细；要完整剖析请把加载提前到 `early-init.el`」。

## 文档清单

| 产物 | 状态 |
|---|---|
| `docs/schema.org` | 需更新：表数 6 → 10、v2 DDL、4 张新表说明、**保留分类**、**purge 10 表删除顺序**、upsert 与 `COALESCE`（last-observation-carried-forward）、零 ALTER 理由（T10） |
| `docs/api.org` | 需更新：analysis 17 个查询、5 个 store 对外函数（4 record + `note-startup-ms`）、**defcustom 17 → 20**（新 3 个全在 `el-chronos.el`）（T10） |
| `docs/architecture.org` | 需更新：采集路径 5/6、近似归因措辞、启动覆盖范围（T10） |
| `docs/ui.org` | 需更新：路由 13 → 16 条、三个新面板（T10） |
| `docs/operations.org` | 需更新：early-init 指引、**保留策略表 + 4 行**、**隐私边界补 `git-head` / `config-sig`（purge 删全部）**、`heap_bytes` NULL 的正常性、健康页处置（T10） |
| `AGENTS.md` | 需更新：目录结构行数、基线用例数（121 / attrib 28）、**隐私边界补两键**、已知边界新增两行（T10） |
| `CHANGELOG.md` | 需更新：`[Unreleased]` 的 `### 新增`（T10） |
| `openspec/decisions.md` | 需更新：追加一行观测面扩展决策（随 ADR-0004 一起写，已由 ADR 任务完成） |
| `docs/adr/0004-observation-surface-expansion.md` | 需新建：本计划的决策记录（已完成） |
| `Readme.org` | 按需更新：用例数与能力概览（T10） |
| `openspec/tech-debt.md` | 需更新：新增 TD-15（`heap_bytes` 版本依赖 + 跨版本混图空洞）/ TD-16（启动分解覆盖范围）/ 可选 TD-17（健康计数粒度）；**不改 TD-1～TD-14**（T10） |
| `el-chronos.el` / `-store.el` / `-collect.el` / `-analysis.el` / `-report.el` / `-web.el` | 需更新（T1–T9） |
| `test/` 5 个测试文件 | 需更新：新增 28–38 用例（T1–T9） |

## 验证标准

| 级别 | 方法 | 通过判据 |
|---|---|---|
| L1 | `make check-parens` + `make lint` | 全绿、**零告警**（14 个文件逐个字节编译） |
| L2 | `make test` | 全绿、0 unexpected、0 skipped；基线 **121 用例**（修订时磁盘实测，若实施期再度漂移以当时实测为准），本计划预计新增 **28–38**（含迁移回滚 / purge 10 表 / `note-startup-ms` 与 flush 补写五例 / `COALESCE` 三段写入等）→ 约 **149–159** |
| L3 | ① 端到端：真实 `(el-chronos-mode 1)` 跑 **≥90s** 后直查库 —— `hourly_gc` / `startup_phases` / `hourly_health` / `session_meta` **四张新表都有行**（堆采样每 6 个窗口约 60s 一次，跑 30s 必然采不到 `heap_bytes`，判据按 90s 设）；② `heap_bytes` 在 Emacs 31.1 上非 NULL、在 29/30 上为 NULL（守卫路径）；③ 迁移后既有 `commands` 行数不变、`user_version` = 2；④ **迁移回滚验证**：故意让 v2 SQL 报错（如把某条 CREATE 的列名写坏）→ 打开库返回 nil、文件回滚到 v1（`user_version` = 1、仍只有 6 表）、随后用未注入错误的版本能正常打开 | ①②③④ 全部满足；④ 的回滚判据以 `sqlite3` 直查 `PRAGMA user_version` 与 `sqlite_master` 为准 |

## 注意事项

1. **不改任何既有 6 表语义**：`sessions` / `commands` / `hourly_functions` / `slow_events` /
   `hourly_usage` / `hourly_stacks` 的列与主键一字不动，I1–I11 一条不改。
2. **采集路径全部 `condition-case` 包裹**，失败降级不向宿主抛错（I6）：git-head 读文件、
   glob 展开、`garbage-collect-heapsize`、`after-load-functions` 钩子都算采集路径。
3. **`el-chronos-collect-stop` 必须摘除本计划新增的全部钩子并清空计数**：
   `after-load-functions`（`--note-load`）、条件注册的 `after-init-hook`（`startup_ms` 值捕获）
   与 `emacs-startup-hook`，以及 `--gc-baseline` / `--startup-loads` / `--startup-last-load-at` /
   `--sample-misses` / `el-chronos-store--pending-startup-ms`；`remove-hook` 幂等，回调已自摘时
   再摘也无副作用。摘钩子要在 `--sample-tick` 收尾**之前**做。否则违反 I5「`mode -1` 零残留」
   —— 尤其残留的 `after-init-hook` 会在关闭后仍往 pending 里写值。
4. **不新增任何第三方依赖**（I10 精神）：`after-load-functions`、`garbage-collect-heapsize`、
   `secure-hash`、`file-expand-wildcards` 全是内置。
5. **迁移是易错环节**：任何 schema 改动都必须带**回滚测试**（L3 ④）；`.bak` 逻辑保留不动。
6. **禁止在采集热路径调用 `garbage-collect`**：会触发真实 GC，违背「观测不干预」。
7. **禁止用 `memory-info` 采 Emacs 堆**：它返回系统内存（实测 `(TOTAL-RAM FREE-RAM
   TOTAL-SWAP FREE-SWAP)`），且 remote `default-directory` 下有 TRAMP 远端查询风险。
8. **本计划的代码片段只作设计说明**：实施时以真实函数签名为准（EE-1）——尤其
   `sqlite-execute-batch` 的事务语义、`after-load-functions` 的实参、`--push-event` 的 SLOT 形态，
   都必须先读代码/文档再落笔。
9. 计数器不得放进 `--clear-aggregates` 清空的容器（设计 6 的悖论），否则 flush 失败永远不可见。
10. `grep --include` 必须加单引号（本机 shell glob 坑）；Web 探活必须 `--noproxy '*'`
    （本机 `http_proxy` 已设而 `no_proxy` 未设）。
11. **新增 defcustom 一律落 `el-chronos.el`；既有分散项本计划不迁移**。事实：仓库现有
    **17 个** defcustom，其中 `el-chronos.el` **15 个**，另有 2 个历史分散项
    （`el-chronos-collect-notify-blocks` 在 `el-chronos-collect.el`、
    `el-chronos-profile-save` 在 `el-chronos-report.el`）。本计划新增 3 个
    （`el-chronos-config-watch-globs` / `el-chronos-startup-top-n` /
    `el-chronos-heap-sample-windows`）**一律落 `el-chronos.el`**（→ 该类共 18 个，全仓 20 个）；
    那 2 个历史分散项**不迁移**（不扩大范围，迁移会顺手改动无关模块与文档）。
12. `heap_bytes` 的 `COALESCE` 语义是「**本行最后一次非 NULL 值胜出**」：解决的是**同会话同小时
    的稀疏写入**（不是跨版本问题 —— 不同会话各自建行，互不覆盖）。读趋势时按
    `sessions.emacs_version` 分组，避免把「29/30 会话无堆值」读成「内存没长」。
13. **`startup_ms` 补写一律走 flush 事务，禁止在 `after-init-hook` 回调内做任何 IO**：
    钩子只算值并调 `el-chronos-store-note-startup-ms`（纯内存），落库由 store 的下一次 flush
    在既有事务内 `UPDATE ... WHERE startup_ms IS NULL` 完成；COMMIT 成功才清 pending，
    ROLLBACK 保留。**不要**在钩子里直接 `sqlite-execute`（启动期 IO，最坏受
    `busy_timeout=2000ms` 拖累）、**也不要**为此新增 timer。`session_meta` 的 `mode-start`
    只作辅助信息，不得拿来反推 `startup_ms`。
14. **`--pending-startup-ms` 必须进 `el-chronos-store--pending-p`**：否则「启动后没有命令、
    采样也没产出」的空闲会话里 pending 是唯一残留，`flush` 会因 `--pending-p` 为 nil 直接早退，
    补写永远不发生。`store-close` 开头已有 `(ignore-errors (el-chronos-store-flush))`，
    所以纳入 `--pending-p` 后关闭前天然多一次补写机会；仍未消费的 pending 在 `store-close`
    随状态清空即视为丢弃，**不告警**（一个标量、下次启动会重算，告警只会制造噪音）。
