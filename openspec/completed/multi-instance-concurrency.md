# 多实例并发写：锁竞争自愈与降竞争

## 当前状态

- 阶段：Phase 4（Review & Document）· **已完成**
- 已确认：方案 ✅（用户 2026-10-30 确认）、计划 ✅（用户 2026-10-30 确认）
- 审查：plan-reviewer 两轮（第二轮无 blocking）✅、code-reviewer 一轮（1 blocking + 1 important，均已修复并复审）✅
- 验证：`make check-parens` / `make lint`（零告警）/ `make test`（375 全绿、0 skipped）；L3 双进程复验通过；真实库副本回归通过
- 下一步：已归档至 `openspec/completed/`

## 目标

消灭「两个 Emacs 实例共用同一 chronos 库时的写失败」。四条可验收结果：

1. 锁竞争不再导致**整个实例不采集**（`el-chronos-store-open` 不因锁失败返回 nil）。
2. 锁竞争不再导致**整批数据丢弃**（瞬时竞争保留重试，仅持续故障与超限才丢弃）。
3. 抢锁点前移到事务起点，后台写允许更长等待（8s），启动路径仍保持 2s。
4. 锁竞争**可量化**（`hourly_health.busy-retries`），修复效果可验证而非「感觉好了」。

## 实测证据（Phase 1 诊断结论，实施与复盘都要对照）

真实库 `/home/thomas/thomas-emacs/.local/state/chronos/chronos.sqlite`（47 MB，schema v5，WAL，`-wal` 4.5 MB）：

| 项 | 实测值 |
|---|---|
| `flush-failures` / `flush-count` | **7 / 48158 = 0.0145%**，落在 3 个小时桶 |
| `commands` 行数 | 118 466 |
| `sessions` 行数 | 83 → 85（观测期间在涨），单 host |
| 同一小时桶内最多并存会话数 | 9 |

三种失败模式（Emacs 32.0.50，`emacs -Q --batch` 双进程实测）：

| # | 模式 | 证据 | busy_timeout 能否救 |
|---|---|---|---|
| ① | 对端单次持写锁 > 2 s | 对端持锁 2.5 s → 本端 `dt=2.003s` 后 `(sqlite-locked-error "database is locked")` | 能（延长时间） |
| ② | 对端零间隙背靠背抢锁，饿死对手 | 每次事务只持 0.2 s；间隙 0.2 s → 双方 0 失败；**间隙归零 → B 连续 4 次等满 2 s 全失败** | 有限（可能永远撞不进空隙） |
| ③ | deferred `BEGIN` 里先读后写 | 升级写失败，**等锁耗时 0.000 s**（busy handler 未被调用，SQLITE_BUSY_SNAPSHOT） | **无效** |

病灶定位（真实函数逐语句探针）：

```
[steps] --open-db 返回=t                              dt=0.001s
[steps] --ensure-session FAIL (database is locked)    dt=2.003s   ← 启动期
[steps] --prune 返回=t                                dt=0.930s
```

- **P1** `--ensure-session` 的 autocommit `INSERT INTO sessions` 撞锁 → `store-open` 返回 nil → **该实例完全不采集**（实测：对端 prune 删 200 万行耗时 2.18 s 时，另一实例 `OPEN=nil sid=nil`）。
- **P2** `flush` 事务首条 INSERT 撞锁 → ROLLBACK + **整批丢弃**（实测库内定格 420 行 = 20 基线 + 4×100，第 5 批 100 行确认丢弃）。

已排除（不是病灶，勿重复排查）：

- `PRAGMA journal_mode=WAL` 在他人持锁时是无锁 no-op（0.000 s 返回，含全新库并发创建，未复现失败）。
- chronos 不存在「读后升级」病理：7 处 `BEGIN`（迁移 4 / flush / prune / purge）首条语句全是写；`--session-known-p` 的 `SELECT` 在 `BEGIN` 之前。
- 启动竞争本身在小库上未复现（全新库双迁移、0/5/50 ms 三种起跑，5 轮全通过）。

## 设计

### D1 会话行延迟补建（消灭「实例不采集」）

- 新增 `el-chronos-store--ensure-session-quiet`（返回 id 或 nil，**从不抛错**）：内部调 `--ensure-session`；`sqlite-locked-error` → `busy-retries` +1 并返回 nil；其他 error → 限流告警（`--warn`）并返回 nil（I6）。
- `el-chronos-store-open` 改用它：会话建不起来也照常返回句柄、起 flush timer、跑 prune。
- `el-chronos-store-flush` 在事务开始**之前**：若 `el-chronos--session-id` 为 nil 或 `--session-known-p` 为假，调 `--ensure-session-quiet` 补建；失败则走既有「`session` 为 nil 时保留命令缓冲 + `--warn-orphan-aggregates`」分支。
- 不变：`el-chronos--session-id` 生命周期仍归 `el-chronos.el`；`store-close` 仍不置 nil。
- **顺序硬约束**：补建必须发生在 `el-chronos-store-flush` 的 `let*` 求值**之前**——`session` / `stack-session` / `session-known` 三个绑定在 `let*` 里一次求值（`el-chronos-store.el:1447-1452`），补建若放在其后，本批仍会用旧的 nil 值，`hourly_stacks` 依旧被跳过。
- **已知口径损失**：session-id 为 nil 期间，六个 `record-*` 聚合入口经 `--aggregate-session`（`el-chronos-store.el:466-483`）在**记录时**即跳过、不入 hash，故补建只能救回**明细**（`commands` / `slow_events`）；聚合数据丢失窗口 ≈ 一个 flush 周期（5 s）。这是「5 s 聚合丢失」vs「整个会话零数据」的取舍，见 TD-36，并在 `docs/architecture.org` 写明。
  另有第二类同类损失、机制不同：`hourly_stacks` 经 `--stack-session`（`el-chronos-store.el:1412-1425`）在 session 缺失时**在 flush 期**被跳过（不是 record 期），故补建成功后本批才可能写入——两者合起来即「补建窗口内聚合维度全线缺失，明细不受影响」。

### D2 flush 按错误类型分流

- `condition-case` 新增 `sqlite-locked-error` 分支（实测该子类型存在）：
  - **分支顺序硬约束**：`sqlite-locked-error` 分支必须排在现有 `(error ...)` 分支**之前**（`el-chronos-store.el:1650`）——`sqlite-locked-error` 是 `sqlite-error` → `error` 的子类型，追加在 `error` 之后会被静默吞掉，锁竞争会走「丢弃整批」而非「保留重试」，且不注入 locked-error 的用例不会变红。
  - `ROLLBACK`；`--flush-failures` +1、`--busy-retries` +1、`--flush-lock-streak` +1。
  - streak < `--max-lock-retries`（6）→ **保留**明细与聚合：`--buffer` 不置 nil、**同时不调** `--clear-aggregates`（即 `--slow-events` 慢事件缓冲 + 九个聚合 hash 一并保留），返回 nil。
  - streak ≥ 6 → 按现行语义丢弃（`--buffer nil` + `--clear-aggregates`）+ 告警，并清零 streak。
- 其他 `error` 分支：语义不变（丢弃整批），同样清零 streak。
- COMMIT 成功后：`--flush-lock-streak` 置 0。
- **告警不节流**（F1，T8 实测暴露）：丢弃那条（「写库连续撞锁 6 次，本批缓冲已按计划丢弃」）必须**绕过** `--warn` 的 10 分钟限流。`--warned-at` 是一条**共享**通道：第 1 次撞锁的「保留重试（第 1/6 次）」就把它占满，于是这条结果消息在生产里**永远不出现** —— 用户只看得到过程，看不到数据真的丢了。修法：新增 `el-chronos-store--warn-force`（不做限流判定，仍更新 `--warned-at`），**只给结果消息**用；「保留重试」那条仍走 `--warn`（过程消息，限流必须保留，否则对端持续持锁时每 5 秒一条告警更吵）。**不要**改用「频繁清空重试计数器」来绕 —— 它会让过程消息刷屏，用户同样只看得到过程、看不到结果。
- **撞锁退避**（F2，T8 实测暴露的 regression）：保留重试让 `--flush-failures` / `--busy-retries` 非零 → `--pending-p` 恒真 → 下一个 5 秒 timer 立刻再撞，而单次撞锁最坏等满 `--busy-timeout-write-ms`（8 秒）→ 实测 8 次 × 8.01 s，主线程被占满，比「失败即丢弃后早退」的老行为**更糟**。修法：新增 `el-chronos-store--flush-backoff-seconds`（defconst 30）与 `--flush-backoff-until`（float-time 或 nil，语义是「下次允许尝试的时刻」）；`el-chronos-store-flush` **最前面**加退避门（到期前早退：不碰库、不打 pragma、返回 nil、缓冲与计数器原样）；撞锁分支的**保留与丢弃两条路径**都置 `now + 30`；COMMIT 成功与非锁错误分支清零；`store-close` 清零（I5）。非锁错误不退避：它本就丢弃本批，`--pending-p' 自然清空，不会每 5 秒白撞。
- 依据（写进 docstring）：ROLLBACK 后库状态与事务前一致，保留不会重复计数；明细有 `--max-buffer-items=50000` 上限；聚合 hash 靠 streak 上限兜底，避免「锁错误持续 + 长期不可写」时无界增长。

### D3 写事务改 BEGIN IMMEDIATE

- 7 处 `"BEGIN"` → `"BEGIN IMMEDIATE"`：迁移 v2/v3/v4/v5、flush、prune、purge。
- 依据：抢锁前移到事务起点（不会「干完半批活才失败」）；防御读后升级病理（模式 ③，加超时无效）。

### D4 busy_timeout 分层

- 新增 `el-chronos-store--busy-timeout-write-ms`（`defconst` 8000）。
- 新增 `el-chronos-store--call-with-write-timeout`（接收 thunk）：进入前 `sqlite-pragma busy_timeout=8000`，`unwind-protect` 恢复默认 2000。
- 用于 `flush` / `--prune` / `purge`；**不用于** `--open-db` 与 `--ensure-session`（启动路径保持 2 s，不拖慢启动）。

### D5 prune 预检 + 节流

- 新增 `el-chronos-store--prune-interval-seconds`（`defconst` 3600）与 `--last-prune-time`（float-time 或 nil）。
- `--prune` 逻辑：① 节流门（首次或距上次 ≥3600 s）；② 对 `commands` 与 `slow_events` 各做一次 `SELECT count(*) ... WHERE ts < ?`（走 `idx_commands_ts` / `idx_slow_events_ts`，读锁不阻塞写者）；③ 两表候选都为 0 → **完全不开写事务**。
- **调用点不变（重要澄清）**：`--prune` 的唯一调用点是 `el-chronos-store-open`（`el-chronos-store.el:866`），**不挂** flush timer 或任何周期 timer。因此本项只节流「同进程反复 open/close」，**不引入周期 prune**；`el-chronos-retention-days` 的实际生效仍依赖实例重启（既有事实，本次不改变）。跨进程各自计时，多实例同时启动时「首次总是执行」，靠候选预检把空转的写事务降为 0。见 TD-37，并在 `docs/operations.org` 更正「保留策略生效延迟」的表述（**不要**写成「1 小时 + 5 s」）。
- `--prune` 的签名改为 `(&optional force)`，供测试绕过节流门。

### D6 busy-retries 自监控

- 新增 `el-chronos-store--busy-retries`（单调累加，进程内），**不放进** `--clear-aggregates` 清空的容器。
- 进 `--health-snapshot` → `hourly_health.key = "busy-retries"`；成功 flush 后按快照扣除已上报部分（与 `flush-failures` 同一机制、同一 `cond` 分支族）。
- **必须进 `--pending-p`**（`el-chronos-store.el:1309`）：否则 D1 路径（open 期 `--ensure-session-quiet` 撞锁 → 计数 +1，此后可能长时间无采集数据）下该计数永不触发 flush、永不上报。
- **不进 `--health-bad-keys`**（`el-chronos-analysis.el:993`）：busy-retries 是**中性度量**（类 `flush-count`），锁竞争被成功自愈也会让它上升；若归入坏消息键，`:ok-p` 会被误判为异常，与「busy-retries 升而 flush-failures 不升 = 自愈生效」的判读矛盾。
- **消费侧八处显式清单**（漏一处只表现为某个界面/导出静默少一行，不报错）：
  1. store 写入：`el-chronos-store--health-snapshot`
  2. analysis 键映射：`el-chronos-analysis--health-keys`（`el-chronos-analysis.el:982`）
  3. analysis 返回值：`el-chronos-analysis-health` 的 plist `:busy-retries`（`:1037-1047`）
  4. web 路由：`/api/health`（`el-chronos-web.el:726-743`）
  5. web CSV：`el-chronos-web--csv-health`（`:430-445`）
  6. web 前端面板：内嵌 JS `healthPanel`（`:1145-1164`）
  7. org 报告：健康节（`el-chronos-report.el:552-565`）
  8. report CSV：`el-chronos-report--csv-health`（`:822-840`）
  - **显式排除**：`el-chronos-analysis--health-bad-keys`（理由见上）。
  - TD-19 已记录「两个 CSV 是内联重复实现、列头漂移无机械约束」——本项必须人工同步两侧。

### 明确不做

| 方向 | 否决理由 |
|---|---|
| 按实例分库 | 破坏「统一汇总」目标，report/web 需跨库聚合，复杂度远超收益 |
| 跨进程 flock 串行化 | Emacs 无原生原语，崩溃遗留锁文件风险大于收益 |
| 降低 flush 频率 | 拉长崩溃丢数据窗口（现为 5 s） |
| 放宽 I3（多库） | 与「数据只写一个库文件」不变量冲突 |

## 任务

- [x] **T1 会话行延迟补建**（D1）：先写失败用例（`--ensure-session` 抛 `sqlite-locked-error` 时 `store-open` 仍返回句柄、session-id 为 nil、flush timer 已起）；再实现 `--ensure-session-quiet` 并接入 `store-open`；再写 flush 批前补建用例（session-id 为 nil → flush 补建成功 → 数据落库）。验收：`make test` 全绿，新用例覆盖四条路径（① 补建成功**且同批落库**——须断言本批 `hourly_stacks` 未被 `--stack-session` 跳过，锁住「补建在 `let*` 之前」的顺序约束；② 补建撞锁保留缓冲；③ 其他错误告警降级；④ 补建窗口内聚合丢失口径）。（依赖：无）
- [x] **T2 flush 锁竞争保留重试**（D2）：先写用例（注入 `sqlite-locked-error` → `--buffer`、`--slow-events` 与九个聚合 hash **全部**保留、`flush-failures`=1、`busy-retries`=1、返回 nil；连续 6 次 → 丢弃且 streak 清零；成功一次 → streak 归 0）；再实现分支。验收：既有 `flush-failures` 相关用例（含「失败丢弃本批」的旧断言）按新语义更新并说明理由。**F1/F2 追加验收**：⑤「丢弃告警在限流窗口内仍可见」——同一窗口内先来一条普通告警，第 6 次撞锁的「本批缓冲已按计划丢弃」仍必须出现在 `display-warning` 收集列表里；⑥「退避期内 flush 不碰库」——`--flush-backoff-until` 非 nil 时 `sqlite-execute` 与 `sqlite-pragma` 均 0 次调用、返回 nil、缓冲原样，把该时刻推到过去后 flush 正常成功且退避清零。（依赖：T1）
- [x] **T3 写事务 BEGIN IMMEDIATE**（D3）：先写用例（捕获 flush / prune / purge 的事务语句，断言为 `BEGIN IMMEDIATE`；迁移 4 步各一次）；再改 7 处。验收：既有迁移用例全绿（注意测试里可能存在对 `"BEGIN"` 的精确匹配断言，需一并更新）。（依赖：无）
- [x] **T4 busy_timeout 分层**（D4）：先写用例（flush 期间句柄 busy_timeout=8000、结束后恢复 2000；抛错路径也恢复）；再实现 wrapper 并接入三处。验收：`--open-db` 仍用 2000（用例断言 open 期间未被抬到 8000）。（依赖：无）
- [x] **T5 prune 预检 + 节流**（D5）：先写用例（无过期行 → 不执行任何写语句；未到间隔 → 跳过；首次总是执行；有过期行 → 照常删）；再实现。验收：既有 prune 用例全绿，新增 3 条。（依赖：无）
- [x] **T6 busy-retries 存储侧**（D6）：先写用例（撞锁 → 计数器 +1；成功 flush 后库内该 key 有值且计数器扣回 0；该变量不被 `--clear-aggregates` 清空）；再实现。验收：`hourly_health` 写入路径与 `flush-failures` 同构。（依赖：T2）
- [x] **T7 busy-retries 消费侧**：先写用例（analysis 健康 plist 含 `:busy-retries` 且 `:ok-p` 不因它变假；web `/api/health` 含 `busy_retries`；web CSV 与 report CSV 的 health 区块均含 `busy_retries` 且两侧列一致；org 报告健康节出现该字段；内嵌 JS 面板渲染该行）；再改 analysis / web（路由 + CSV + 前端 JS 三处）/ report（健康节 + CSV 两处）。验收：五个界面层用例全绿，无「某处漏字段」的静默缺失。（依赖：T6）
- [x] **T8 双进程并发复验（L3）**：写一次性验证脚本（放 /tmp，不入库），复刻 Phase 1 实验 6-⑤/⑥/⑦ 的极端场景（对端持写锁 3 s）：改造后要求 ① flusher 不丢批（保留重试后写入成功，库内行数守恒）② `store-open` 不返回 nil（会话延迟补建）。验收：三段场景各给出前/后对照数据（原始输出贴进报告）。（依赖：T1–T5）
- [x] **T9 全量验证**：`make check-parens`、`make lint`（零告警）、`make test`（基线 336 + 新增，全绿 0 skipped）。验收：三条命令输出原文。（依赖：T1–T8）
- [x] **T10 文档同步与归档**：按「## 文档清单」逐项更新；`openspec/tech-debt.md` 新增 TD-36（补建窗口内聚合数据丢失）与 TD-37（`--prune` 仅 `store-open` 调用、retention 生效依赖重启）；核对 `openspec/decisions.md` 已有决策行（Phase 2 已预写，勿重复追加，仅在新事实推翻它时改写）；ADR-0007 状态改为「已实施」并回填实测结论；计划移入 `openspec/completed/`；`AGENTS.md` 更新错误处理矩阵、已知边界表、测试基线与行数、技术债段。（依赖：T9）

## 文档清单

| 文档 | 需要更新的内容 |
|---|---|
| `docs/architecture.org` | 新增「多进程并发写（锁竞争处置）」小节（三种失败模式 + 分层超时 + 保留重试语义 + streak 上限）；错误处理矩阵两行改写（flush 锁竞争保留重试 / open 会话延迟建）；写明 D1 的已知口径损失（补建窗口内聚合数据丢失，明细保留） |
| `docs/schema.org` | `hourly_health` 的 key 集合增 `busy-retries`（含语义与累加口径） |
| `docs/api.org` | 内部函数约定增 `--ensure-session-quiet` / `--call-with-write-timeout` / `--max-lock-retries` / `--busy-timeout-write-ms` / `--prune-interval-seconds`；analysis 健康函数返回 plist 增 `:busy-retries` |
| `docs/operations.org` | 排障节新增「`database is locked` 怎么判」（含迁移撞锁 / `wal_checkpoint` 静默跳过 / vacuum 三点边界）；多实例共享库说明（何时正常、何时是故障）；**更正「保留策略生效延迟」表述**（prune 仅 open 调用，不随 flush 周期） |
| `docs/ui.org` | Web 健康面板与 org 报告健康节的 `busy-retries` 字段；`/api/health` 路由字段表（`:48` 附近）增 `busy-retries`；两个 CSV 导出区块 |
| `CHANGELOG.md` | `[Unreleased]` 新增本批变更（修复 / 变更两节） |
| `AGENTS.md` | 错误处理矩阵、已知边界表（多实例并发锁）、测试基线与行数、技术债段 |
| `openspec/decisions.md` | 追加决策行（并发写策略） |
| `docs/adr/0007-multi-process-write-concurrency.md` | 新建 ADR（本次由 Phase 2 先建骨架，T10 补实测结论） |
| `Readme.org` | 若「当前状态」段提及并发/多实例，则同步一句 |
| `openspec/tech-debt.md` | 新增 TD-36 / TD-37（见 T10） |
| `openspec/active/multi-instance-concurrency.md` → `completed/` | Phase 4 归档 |

## 验证标准

- **L1**：`make check-parens` 通过；`make lint` 零告警（17 个文件逐个字节编译）。
- **L2**：`make test` 全绿、0 skipped；基线 336 + 新增约 12–16 条；既有断言若因语义变化需改，必须在计划或 CHANGELOG 说明理由。
- **L3**：T8 的双进程极端场景对照（改造前失败 / 改造后不丢批、不返回 nil），原始输出作为证据贴进汇总报告。
- **回归**：真实库副本上跑一次 open + flush（只读副本，不碰生产库），确认 schema v5 不变、无迁移触发。

## 注意事项

1. **测试里的 `"BEGIN"` 字面断言**：`test/el-chronos-store-test.el:546` 等处可能有精确匹配，改 `BEGIN IMMEDIATE` 前先 `grep '"BEGIN"' test/`。
2. **`sqlite-pragma` 改 busy_timeout 必须 `unwind-protect` 恢复**：连接级 pragma 会残留，漏恢复会让后续所有写入都等 8 s，直接拖慢 Emacs。
3. **计数器不得放进 `--clear-aggregates` 清空的容器**（`--busy-retries` / `--flush-lock-streak` 都是标量，天然安全；新增聚合 token 时务必遵守）。
4. **`hourly_health` 的 key 必须同步到 D6 列出的八处**（含两个 CSV 与内嵌 JS 面板）；漏一处只表现为「某个界面/导出少一行」，不报错。`--health-bad-keys` 是**显式排除**项。
5. **不加 defcustom**：`--busy-timeout-write-ms` / `--max-lock-retries` / `--prune-interval-seconds` 一律 `defconst`，避免动 `docs/api.org` 的「23 个 defcustom」清单。
6. **TDD 顺序不可颠倒**：每个任务先写失败用例再实现；改测试要说明原因。
7. **不得触碰生产库**：L3 验证一律在副本或临时库上；`PRAGMA wal_checkpoint` 是写操作，禁止对生产库执行。
8. **迁移 / checkpoint / vacuum 的撞锁边界不在本次修复范围内**（既有行为，注明即可）：`--open-db` 内迁移撞锁仍会使 open 返回 nil（升级后首次启动 + 对端持锁，低概率）；`--migrate` 的 `wal_checkpoint(TRUNCATE)` 在他人持写锁时被 `ignore-errors` 静默跳过（`.bak` 可能不含最新 WAL 数据）；`el-chronos-store-vacuum` 用默认 2000 ms 且不包 D4 wrapper（手动命令，可接受）。三者在 ADR「负向」与 `docs/operations.org` 排障节注明。
9. **`busy-retries` 是中性度量，不是坏消息**：不要加进 `--health-bad-keys`，也不要写进「健康检查失败」的判据。
10. **撞锁退避把崩溃丢数据窗口从 5 s 放大到 35 s**（F2 的代价，**必须写进 `docs/operations.org`**）：撞锁后本批被保留，为免「每 5 秒白撞 8 秒」而退避 30 秒（`--flush-backoff-seconds`），因此撞锁期间崩溃会丢「至多一个 flush 周期 + 一个退避窗口」的数据。取 30 秒的依据：对端大 prune / 迁移实测 0.5–2.2 秒量级，30 秒足以跨过；同时远小于用户「这软件卡住了」的感知阈值。**不要**为了缩回 5 s 而取消退避 —— 那会让主线程被占满（实测 8 次 × 8.01 s），比丢几秒数据严重得多。
