# ADR-0004 观测面从「时间」扩展到「时间 + 内存 + 启动 + 配置变更」

- **状态**：Accepted（已接受，**已实施并归档** —— 落地计划 `openspec/completed/expand-observation-surface.md`，2026-10-25）
- **日期**：2026-10-25
- **决策者**：用户（明确要求「内存 / GC / 启动 / 配置变更 / 自监控」五个维度一并补齐）
- **关联**：`openspec/completed/expand-observation-surface.md`（落地计划）、
  `AGENTS.md` I1 / I3 / I5 / I6 / I10、`docs/schema.org`、
  `openspec/completed/fix-sampling-attribution.md`（前置：采样口径地基，已归档）、`openspec/decisions.md`

## 背景

截至 ADR-0003 实施完成，`el-chronos` 有四条采集路径，全部围绕**时间**这一维度：

| 路径 | 频率 | 产出 | 回答的问题 |
|---|---|---|---|
| 启动 | 每会话一次 | `sessions`（含 `startup_ms` 标量、`emacs_version`、`host`、`gc_threshold`） | 这次启动多久 |
| 命令边界 | 每命令一次 | `commands` + `slow_events`（含 `gc_ms` 附带列） | 哪个命令慢、慢多久、是否被中断 |
| 心跳 | 默认 1s | `slow_events(kind='block')` | 命令之外的阻塞 |
| 采样 tick | 默认 10s | `hourly_functions` / `hourly_stacks` / `hourly_usage` | 慢在哪个函数、调用链是什么 |

三条观测结论因此都能成立，但有四个问题无法回答：

1. **内存维度为零**：库里没有任何堆大小序列。`commands.gc_ms` 只记「这条命令期间发生的 GC 花了多久」，
   无法回答「Emacs 越用越胖了吗」「某个改动之后常驻内存是否上升」。
2. **回归无法归因到改动**：`el-chronos-analysis-regressions` 只能判「某函数 self 增长超阈值」，
   但同一时间窗口里 git HEAD 或 init 配置是否变了，库里没有任何记录 —— 结论停在「变慢了」，
   到不了「因为哪天改了什么」。
3. **采集器无法自证可信**：`el-chronos-store--push-event` 触到 `--max-buffer-items` 时用
   `setcdr` **静默截断**最旧项；flush 失败只留一条限流告警（10 分钟最多一次）且本批丢弃；
   采样窗口被主线程占住时窗口直接丢失。三种数据损失**在库里完全不可见** ——
   读者无法区分「这段时间没有活动」与「这段时间的数据被丢了」。
4. **启动耗时是黑盒标量**：`sessions.startup_ms` 一个数，看不出是哪个文件的 `load` 慢。

关键约束是：这些扩展**不能**改变项目的定位（低开销常驻观测器、不改 Emacs 行为语义）、
不能引入第三方依赖、不能让既有 6 张表的口径发生变化。

## 决策

**一次 schema v2 迁移补齐四个维度，全部走新表，零 `ALTER TABLE`。**

| 新表 | 主键 | 内容 | 覆盖问题 |
|---|---|---|---|
| `hourly_gc` | `(hour_ts, session_id)` | `gc_count` / `gc_ms` 累加、`heap_bytes` 稀疏覆盖（本行最后一次非 NULL 值胜出） | 问题 1 |
| `startup_phases` | `(session_id, phase)` | `mode-start` / `after-init` / `startup` / `first-idle` / `load:<library>` 的毫秒 | 问题 4 |
| `hourly_health` | `(hour_ts, session_id, key)` | `dropped-commands` / `dropped-events` / `flush-failures` / `flush-count` / `flush-ms` / `sample-misses` 累加 | 问题 3 |
| `session_meta` | `(session_id, key)` | `git-head` / `config-sig`（KV 形态，未来加键不必再迁移） | 问题 2 |

### D1 GC 与内存：三分支，全部零副作用

| 指标 | 手段 | 备注 |
|---|---|---|
| GC 次数 / 耗时 | `gcs-done` / `gc-elapsed` 差值（全局单调计数器，只读） | 与 `el-chronos-profile-command` 同口径 |
| 堆总量 | `garbage-collect-heapsize` → `Σ (* SIZE USED)` | **Emacs 31 引入**，用 `fboundp` 守卫；29/30 上 `heap_bytes` 恒 NULL |
| 采样频率 | GC 每窗口（10s）、堆每 6 窗口（约 60s） | 堆采样稀疏 → 未采样的窗口写 NULL，`COALESCE` 保旧值 |

实测（2026-10-25，Emacs 31.1）：`(fboundp 'garbage-collect-heapsize)` = t，
返回 9 项 `(NAME SIZE USED FREE)`（与 `garbage-collect` 同形但**不做** GC）；
`(memory-info)` 返回 `(TOTAL-RAM FREE-RAM TOTAL-SWAP FREE-SWAP)`，是系统内存。
该函数**没有短别名**，代码与文档一律写全名。

`heap_bytes` 的 upsert 必须用 `COALESCE(excluded.heap_bytes, heap_bytes)`，即「本行**最后一次
非 NULL 值胜出**」，原因是**同会话同小时的稀疏写入**：堆每 6 个窗口才采一次，其余窗口写 NULL，
普通覆盖会让一个采样点之后的第一个 NULL 就把值抹掉，若该小时最后一次写入恰好是 NULL，
整小时采到的值全部丢失 —— 这是每个会话每小时必然发生的场景。
（曾以为「跨版本共用同一库会让历史堆值被抹平」，该看法**不成立**：`hourly_gc` 主键含
`session_id`，不同进程各自建会话行，29/30 的 NULL 写在自己行上，抹不掉 31+ 会话的历史行；
跨版本混用真正的影响是**曲线空洞**，不是数据丢失。）
代价：`heap_bytes` 的时间戳含义是「本行最后一次有样本的时刻」，同小时多次采样只留最后一个值；
跨版本混图要按 `sessions.emacs_version` 分组阅读，别把「29/30 会话无堆值」读成「内存没长」。

**与 profiler 采样解耦**：`gcs-done` / `gc-elapsed` / `garbage-collect-heapsize` 都不需要 profiler，
所以 GC 采集放在采样 tick 里但**在 `(when el-chronos-collect--sampling-p ...)` 之外**。
理由：profiler 启动失败时项目的降级契约是「禁用采样、命令/心跳继续」，若 GC 采集绑进
`sampling-p`，内存/GC 趋势会跟着陪葬 —— 而它正是判断「越用越胖」的唯一依据，最不该在故障时消失。

### D2 变更标记：零子进程读 `.git` + 配置指纹

- `git-head`：读 `~/.git/HEAD` → loose ref（`refs/heads/X`）→ **`packed-refs` 回退** → detached 裸 sha。
  本机实测 `~/.git/HEAD` = `ref: refs/heads/develop`，且 `.git/refs/heads/` 与 `.git/packed-refs`
  **同时存在**，故 packed-refs 分支是必需路径而非兜底。
- `config-sig`：新 defcustom `el-chronos-config-watch-globs`（默认
  `'("early-init.el" "init.el" "lisp/init-*.el")`），glob 展开后对 `(相对路径 mtime size)` 求 sha1。
  本机实测该 glob 命中 53 个文件（`early-init.el` + `init.el` + 51 个 `lisp/init-*.el`）。
- 采集时机：`el-chronos-store--ensure-session`，每会话一次，零热路径开销。
- **取不到的键不写行**（不写 NULL 值行）：KV 表里的空值没有信息量，且会让「取不到」与
  「取了但为空」在查询层不可区分；将来要区分再加 `source` 列，本期不做。因此
  「无可得变更标记」的会话在 `session_meta` 里是 0 行，而不是 2 行 NULL。

### D3 启动分解：`after-load-functions` 近似归因 + 覆盖范围如实标注

- 钩子收 FILE，记录**相邻两次调用的时间差**作为前一个文件的 load 耗时 —— 这是
  **近似归因**（含前一文件的收尾与钩子执行），docstring 与文档必须写明。
- **内存保存全部 load 记录，写库前按 ms 降序截断到 top-N**（`el-chronos-startup-top-n`，
  默认 50）：一次启动几百条记录的内存可忽略，但全量入库会让 `startup_phases` 膨胀。
- **摘钩用确定性三元条件**（任一满足即摘，不依赖 idle 时机）：① `emacs-startup-hook` 已触发
  （首选锚点）；② 累计 load 次数 ≥ `4 × el-chronos-startup-top-n`；③ 自 mode 启动起超过 30 秒
  （一次性 timer 兜底）。`first-idle` 降为**可选**阶段标记，仅作数据、不作摘钩依据
  （与备选⑩ 否决「用 idle 时机驱动补写」同一条理由：idle 时机受用户活动影响、不可预期）。
  **锚点固定为 3 + 1**：`mode-start` / `after-init` / `startup`（确定性）+ `first-idle`（可选）；
  不设早期启动锚点（mode 启动时它已过去，物理上无法记录）。
  **若 `collect-start` 时启动已结束则不挂 `after-load-functions`**（否则交互期的 load 会被
  记成启动期 load）。
- **覆盖范围限制**：用户通常在 init 末尾才开 mode，此时启动已结束，只能记 mode 之后的 load。
  报告节标题必须标「自 mode 启动起，覆盖 X ms / 总 Y ms」；`docs/operations.org` 给出
  「要完整剖析就把 `(el-chronos-mode 1)` 提前到 `early-init.el`」的指引。

### D4 自监控：eventual 语义并写入决策

`hourly_health` 六键。**已知悖论**：flush 失败时无法把失败计数写进库（写库本身失败），
只能在下一次成功 flush 时补写 —— 属 eventual 语义，滞后上限 = 一次成功 flush 间隔（库长期
不可写时无上限）。因此五个计数各用**独立 defvar**（`--dropped-commands` / `--dropped-events` /
`--flush-failures` / `--flush-count` / `--flush-ms-total`），既不放进 `--clear-aggregates` 清空的
hash、也不挂在 `--buffer` / `--slow-events` 上（ROLLBACK 会一并清掉，失败就永远不可观测）；
并且只有在 COMMIT **成功之后**才把「本次已写入库的那部分」**减去**（不是无条件清零），
ROLLBACK 路径一分不减。截断丢弃按「截断前长度 − 上限」的**差值**计（一次可能丢多条），
并按传入的 SLOT 分流到 commands / events 两个键。

### D5 迁移实现：一次迁移 + 全量 DDL + 幂等分支

`el-chronos-store--ensure-schema` 建完表后**无条件**写 `user_version = --schema-version`，
故 `--schema-ddl` 必须同步更新为全量（旧 6 表 + 新 4 表），否则 version 0 的新库会
「只建旧表却标记为 v2」→ 静默缺表。迁移分支用 `(= from-version 1)` 而非 `(< from-version 2)`
（0 号库已被 `ensure-schema` 覆盖为全量 v2）。

### D6 启动耗时：`after-init` 只**捕获值**，UPDATE 并入下一次 flush 事务

`--ensure-session` 现有实现只在 `after-init-time` 与 `before-init-time` 都存在时才求差写
`startup_ms`。**只要 mode 在 `after-init-hook` 之前启用**（early-init、以及最常见的
`init.el` 末尾写法），建会话行时 `after-init-time` 仍为 nil → `startup_ms` 落 NULL，
「启动耗时的总数」这一维度恰在最需要它的配置下缺失。决策：**两段式，启动期零 IO**。

1. **collect 侧（纯内存）**：若本会话行 `startup_ms` 为 NULL，注册**一次性** `after-init-hook`；
   回调先 `remove-hook` 自摘，然后只算
   `(* 1000 (float-time (time-subtract after-init-time before-init-time)))` 并调
   `el-chronos-store-note-startup-ms`。**不写库、不碰 sqlite**。
2. **store 侧（并入 flush 事务）**：defvar `el-chronos-store--pending-startup-ms`（nil = 无需补写）；
   `note-startup-ms` 仅在 `el-chronos-store--db` 与 `el-chronos--session-id` 非 nil 时 `setq`；
   **pending 必须纳入 `el-chronos-store--pending-p`**（否则空闲会话里它是唯一残留、
   `flush` 会早退）；`el-chronos-store-flush` 在**既有事务内**追加
   `UPDATE sessions SET startup_ms = ? WHERE id = ? AND startup_ms IS NULL`（`IS NULL` 守卫
   防覆盖已正确写入的值）；**COMMIT 成功后**才清 pending，ROLLBACK 保留 pending 等下一轮。

**为什么选这条而不是另两条**：① 启动期零 IO → 彻底消除 `busy_timeout=2000ms` 最坏拖住启动 2s
的风险；② 复用既有 5s flush timer，**不新增 timer**（I5 零残留负担与清理清单不变）；
③ 补写天然获得「与批量写入同一事务」的一致性，沿用 flush 已有的 ROLLBACK / 丢弃本批 /
限流告警语义，不需要新的错误处理路径。代价：延迟 ≤ 一个 flush 周期（默认 5s）。

- **不算「改既有表语义」**：同一字段的延迟写入（NULL → 真实值），列定义、主键、既有行读法、
  分析层 `startup_ms IS NOT NULL AND startup_ms > 0` 过滤全部不变；mode 在 after-init 之后启动的
  会话行为零变化（那条路径本就注册不到钩子）。
- **I5**：钩子进 `collect-stop` 清理清单，且 `collect-stop` / `store-close` 都要清 pending；
  摘钩子放在 `--sample-tick` 收尾**之前**。
- **触发面（不是「early-init 特例」）**：`startup.el` 第 1707 行先 `(setq after-init-time ...)`、
  第 1708 行才 `(run-hooks 'after-init-hook)`，两行都在 init 文件加载**之后** —— 所以
  `init.el` 末尾直接 `(el-chronos-mode 1)` 同样得到 NULL。本机用户配置用
  `emacs-startup-hook`（在 `after-init-hook` 之后），故 19/19 会话非 NULL，**不能据此判断不需要**。
- **实现守卫**：回调内判 `el-chronos--running-p`；`note-startup-ms` 内判
  `el-chronos-store--db` 与 `el-chronos--session-id`（`store-close` 保留 session-id 但把 db 置 nil）。
- **失败边界**：那条 UPDATE 单独 `condition-case`，失败只记录并**保留 pending**、不阻断其余表
  写入；整个事务 ROLLBACK 时 pending 天然保留。
- `session_meta` 的 `mode-start` 键保留为**辅助信息**（报告用来区分「mode 起点」与
  「`after-init` 终点」），**不作** `startup_ms` 的数据来源。

### D7 迁移事务边界：显式 `BEGIN`/`COMMIT`，`.bak` 在 `BEGIN` 之前

`sqlite-execute-batch` 逐条执行、**不自带事务**（实施前须读 `sqlite.el` 复核，EE-1）。故 v2 迁移
显式包事务，顺序硬约束两条：① `.bak` 复制在 `BEGIN` **之前**（否则备份到未提交状态）；
② 失败时 `ROLLBACK` 在 `.bak` 覆盖**之前**（先撤事务再动文件）。失败沿用既有回滚路径
（关句柄 → `.bak` 覆盖 → 删 `-wal`/`-shm` → 告警 → 返回 nil），该路径本身不改。

- 为什么不能只依赖「`CREATE TABLE IF NOT EXISTS` 幂等」而不开事务：不开事务的最坏状态是
  「4 张表只建成 3 张、`user_version` 仍是 1」—— 库对外是半成品：分析层缺表后降级为空结果
  （看起来像「没有数据」而实际是「迁移没做完」），外部 `sqlite3` 读者看到的也是残缺 schema。
  事务把「要么全有、要么全无」变成可推理的前提，回滚测试（T1 第三个用例）负责守住它。

### D8 保留策略：新 4 表归类、`--prune` 不动、`purge` 扩到 10 表（顺序钉死）

| 表 | 分类 | 自动 retention（`--prune`） | `el-chronos-purge` |
|---|---|---|---|
| `hourly_gc` / `hourly_health` | 小时聚合 | **不动** | 删（`hour_ts < ?`） |
| `startup_phases` / `session_meta` | 会话级 | **不动** | 删（`session_id IN (SELECT id FROM sessions WHERE started_at < ?)`，**必须先于 `sessions`**） |

- `hourly_gc` / `hourly_health` 与既有 `hourly_functions` / `hourly_usage` / `hourly_stacks` 同类：
  小时聚合、永久保留、只由 purge 手动清理。
- `startup_phases` / `session_meta` 是会话级数据，生命周期跟随 `sessions`；自动 retention 不碰
  （`--prune` 本就只删 `commands` / `slow_events`）—— 聚合是长期趋势的基础，元数据是回归归因的基础。
- **新表不写外键**（与 `hourly_functions` / `hourly_stacks` 一致）：不把 purge 顺序、级联删除与
  `foreign_keys=ON` 三者耦合；代价是孤儿行只能靠顺序约定消灭，因此顺序必须钉死并有用例。
- **purge 删除顺序（10 步，不许改写）**：`commands` → `slow_events` → `startup_phases` →
  `session_meta` → `hourly_functions` → `hourly_usage` → `hourly_stacks` → `hourly_gc` →
  `hourly_health` → `sessions`。两条**互不相同**的理由：① 外键只约束 `commands`
  （`session_id REFERENCES sessions(id)`）→ 它必须最先；② `startup_phases` / `session_meta`
  的删除条件依赖 `sessions` 子查询 → 必须在删 `sessions` **之前**，否则子查询恒空、
  这两表的行永远删不掉（孤儿残留且不报错）。
- **隐私**：`session_meta` 的 `git-head` / `config-sig` 属用户可识别信息（仓库分支与配置指纹），
  purge 必须删全部，并在 `docs/operations.org` 的隐私/保留表与 `AGENTS.md` 隐私边界里声明。

## 备选方案与被否决原因

| 替代方案 | 描述 | 否决原因 |
|---|---|---|
| ① `ALTER TABLE ADD COLUMN` 给既有表加列 | 在 `sessions` 加 `heap_bytes`、在 `commands` 加 `git_head` 等 | **不幂等**：重试报 `duplicate column name`。迁移脚本在失败恢复、崩溃重启、`.bak` 覆盖后重开时都会重跑，只要有 ALTER 就不可能安全重试；且会把「采集维度」塞进明细表，行宽与索引全面推进 |
| ② 用 `garbage-collect` 采堆 | 直接取 `(garbage-collect)` 的 `Σ(* SIZE USED)` | 它会**真的执行一次 GC** —— 观测器替用户改变了运行时行为（违背「观测而不干预」），并且污染它自己刚记录的 GC 计数/耗时数据 |
| ③ 用 `memory-info` 采堆 | 用 `(memory-info)` 拿内存数字 | 实测返回 `(TOTAL-RAM FREE-RAM TOTAL-SWAP FREE-SWAP)`，是**系统内存**不是 Emacs 堆，与本维度的问题无关；且 `default-directory` 为 remote 时有 TRAMP 远端查询风险，采集热路径不能容忍这种不确定性 |
| ④ 用 `git rev-parse` 子进程取 HEAD | `(shell-command-to-string "git rev-parse HEAD")` | 启动期 fork+exec 阻塞主线程（WSL 下 `/mnt/c` 慢 IO 会放大），且引入外部命令依赖与失败模式（git 不存在、目录不是仓库、被 GPG 签名提示阻塞）。直接读 `.git/HEAD` + `packed-refs` 是纯文件读，零子进程、零网络 |
| ⑤ 每个功能各做一次 schema 迁移 | 加 GC 迁一次、加启动又一次、加健康再一次 | 每次迁移都要复制一次 `.bak`、都多一处易错环节（事务、版本号、回滚），而 4 个维度本就是同一批观测面扩展；一次迁移把风险面从 4 处压到 1 处 |
| ⑥ 复用 `commands.gc_ms` 表达内存趋势 | 不加表，用既有列推断 | `gc_ms` 是「命令期间 GC 耗时」，与「堆常驻大小」是两个不相干的量；且它天然只覆盖有命令执行的时段，空闲期增长完全看不到 |
| ⑦ 用 `session_meta` 记 mode-start 绝对毫秒、由分析层求差当作 `startup_ms` | 不改 `sessions` 行，用新表反推启动耗时 | 反推出来的不是同一个量：`mode-start` 是「观测起点」，`before-init-time` → `after-init-time` 才是 Emacs 官方口径的启动区间；用它当 `startup_ms` 会让**所有**会话的该字段口径漂移（不仅 early-init 场景），并破坏「`startup_ms` 只由 before/after-init-time 决定」这条可验证的语义。故只把它降级为辅助信息（D6） |
| ⑧ 迁移不开显式事务，靠 `CREATE TABLE IF NOT EXISTS` 幂等重跑 | 少写 `BEGIN`/`COMMIT`，失败后重开自动补建 | 最坏状态是「4 张表只建成 3 张而 `user_version` 仍是 1」的半成品库：分析层缺表降级为空结果、外部 `sqlite3` 读者看到残缺 schema，且无法区分「迁移没做完」与「没有数据」。幂等能保证「可重跑」，不能保证「读者看不到中间态」（D7） |
| ⑨ 在 `after-init-hook` 回调里直接 `UPDATE sessions` | 钩子内算完值就写库，最简单直接 | **启动期 IO**：连接 `busy_timeout` 是 2000ms，外部进程（另一个 Emacs / sqlite3 / 备份）持写锁时最坏把启动拖住约 2s，与「启动期不做重 IO」直接冲突；而且它绕过 flush 的事务与错误处理，等于给同一条写路径维护第二套失败语义（D6） |
| ⑩ 新增一个 `first-idle` 一次性 timer 去补写 | 把写操作挪出启动路径，用独立 timer 兜 | **多一个 timer**：`el-chronos--active-timers` 与 I5 的零残留清单都要多管一项，且 idle timer 在「启动后一直有输入」时可能迟迟不触发（`run-with-idle-timer` 的 idle 语义受用户活动影响），补写时机会变得不可预期。复用既有 5s flush 完全不引入这些不确定性（D6）。**注意**：本条否决的是「用 idle 时机做数据补写」；`after-load-functions` 的**摘钩**改用确定性三元条件（startup-hook / 次数上限 / 30s timer），`first-idle` 仅作可选阶段标记，二者不矛盾（D3） |
| ⑪ 把新 4 表排除在 `purge` 之外（只让 `--prune` 或手动删库处理） | 少改 purge 代码，避免顺序风险 | 破坏既有「`el-chronos-purge` 删全部」的约定（用户对「清空」的唯一心智模型）；且 `session_meta` 含 `git-head` / `config-sig` 属**用户可识别信息**，留一份不受 purge 管辖的残留等于给隐私边界开口子。顺序风险用「钉死顺序 + 三个用例」解决，不靠缩小 purge 范围（D8） |

## 后果

**正向**

- **内存维度从零到可观测**：`hourly_gc` 提供堆大小序列与 GC 次数/耗时趋势，能回答
  「越用越胖」与「某次改动后常驻内存上升」；`heap_bytes` 走零 GC 的读取接口，不干扰被观测对象。
- **回归可归因**：`session_meta` 把 git HEAD 与 init 配置指纹写进每个会话，
  `config-history` 能直接列出「哪次会话之间 HEAD / 配置变了」，把「变慢了」接到「什么变了」。
- **采集可信度可自证**：四种数据损失（截断丢弃、flush 失败、采样窗口丢失）全部落库，
  读者能区分「没有活动」与「数据丢了」；这本身也是「观测器不得静默失败」这个既有取向的延伸。
- **启动从标量到分解**：`startup_phases` 给出阶段与逐文件 load 耗时，配合 S3 期的
  「包成本-收益」才有数据基础。
- **启动耗时不再有盲区**（D6）：只要 mode 在 `after-init-hook` 之前启用，`startup_ms` 就由
  「钩子捕获值 + 下一次 flush 事务补写」补齐，于是「覆盖范围标注」所需的两端
  （mode 起点、after-init 终点）都真实可得，而不是靠反推；且启动期零 IO、不新增 timer。
- **迁移具备原子性**（D7）：v2 迁移「要么 10 张表全有、要么仍是 v1 的 6 张表」，
  不存在「表建了一半、版本号还是 1」的中间态；回滚测试把这条从约定变成可执行判据。
- **零第三方依赖不变**：`after-load-functions` / `garbage-collect-heapsize` / `secure-hash` /
  `file-expand-wildcards` / `sqlite` 全部内置（I10 精神不变）。
- **GC/内存趋势不随 profiler 故障消失**（D1 解耦）：profiler 启动失败时降级为「无函数热点」，
  但 `hourly_gc` 仍照常落库 —— 最需要「是不是越用越胖」的时刻不会恰好失去该数据。
- **「清空」仍然是清空**（D8）：`purge` 覆盖 10 张表，`session_meta` 里的仓库名/配置指纹不会
  成为 purge 无法触及的残留；隐私边界因此可以声明为「purge 删全部」。

**负向 / 代价**

- **schema 面积 +4 表**（6 表 3 索引 → 10 表 3 索引）：迁移、备份与文档同步的面向都变大。
- **`heap_bytes` 只在 Emacs 31+ 可用**：29/30 用户永远看到空序列 —— 这是能力缺口不是 bug，
  必须写进文档，否则会被误判成采集失败。
- **启动分解覆盖范围受限且是近似值**：默认配置下只覆盖 mode 启动之后的 load，且相邻差值
  含前一文件的收尾与钩子耗时。**对用 `emacs-startup-hook`（或任何启动结束后）开启 mode 的用户，
  该维度等于不存在（只有 `mode-start` 一个锚点、无包加载明细）—— 这是物理边界：观测器无法
  观测自己被加载之前的事**。两个限制都必须在前端与 `docs/operations.org` 如实标注，
  不能当精确耗时用，也不许藏。
- **健康计数是 eventual 语义**：flush 失败的那批计数要等下一次成功 flush 才可见，
  滞后上限是一次 flush 间隔（默认 5s）——但库长期不可写时这个滞后无上限。
- **`heap_bytes` 的读数有两个坑**：同一小时只保留最后一个采样值（稀疏）；29/30 会话该列恒 NULL，
  跨版本混图会出**空洞**（不是水平平台），读图须按 `sessions.emacs_version` 分组
  （`docs/schema.org` 与 `docs/architecture.org` 必须写明）。
- **`startup_ms` 补写最多延迟一个 flush 周期**（D6）：pending 值要等下一次 flush（默认 5s）才落库，
  在此期间读该列仍是 NULL —— 对「事后报告 / 趋势」无影响，对「刚启动就读 `startup_ms` 的脚本」
  需要知道这 5s 的窗口。可接受，已计入文档。
- **多一份清理责任**（D6）：`after-init-hook` 必须进 `collect-stop` 的清理清单，
  `collect-stop` / `store-close` 都要清 `--pending-startup-ms`（I5）；好在不新增 timer、
  启动期零 IO，代价比「钩子内直接写库」小得多。
- **用例数与测试时长上升**：预计 +28–38 个用例（121 → 约 149–159，以实测为准）。
- **`purge` 顺序是「静默失败型」风险**（D8）：`startup_phases` / `session_meta` 的子查询删除
  若排在删 `sessions` 之后，只会留下孤儿行而**不报错**。缓解：顺序钉死在文档与计划里 +
  三个专用用例（purge 后 10 表全空、带 `before` 不留孤儿、`--prune` 不动新表）；
  新表不写外键也意味着孤儿行没有级联兜底，只能靠这套约定。

**约束（进入不变量语义的解释，不新增不变量）**

I1（只用内置 profiler 采样，不自造采样器）、I3（数据只写 `el-chronos-db-path`）、
I5（`mode -1` 零残留：`after-load-functions` 与条件注册的 `after-init-hook` 都必须摘除）、
I6（采集路径失败降级不抛错：读 `.git`、glob 展开、`garbage-collect-heapsize`、
`startup_ms` 补写 UPDATE 都算采集路径）、
I10（资源与依赖内嵌/内置，不引第三方）。

## 关联

- 落地计划：`openspec/completed/expand-observation-surface.md`（T1–T10，含迁移回滚测试要求）
- 前置计划：`openspec/completed/fix-sampling-attribution.md`（nil 帧占 38.8% 样本，**已归档**；
  它必须先完成，否则本 ADR 的 GC/趋势类查询会被污染口径带偏）
- 决策表：`openspec/decisions.md`（2026-10-25 观测面扩展一行）
- 技术文档：`docs/schema.org`（v2 DDL 与 upsert 语义）、`docs/architecture.org`（采集路径 5/6）、
  `docs/ui.org`（路由 13 → 16）、`docs/operations.org`（early-init 完整启动剖析指引）、
  `docs/api.org`（analysis 13 → 17 个查询）
- 不变量：`AGENTS.md` I1 / I3 / I5 / I6 / I10（**编号与语义均不改**）
- 相关 ADR：`docs/adr/0001-observer-architecture.md`（观测器定位与四条采集路径的原始设计）
