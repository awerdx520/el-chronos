# S2：亚秒级卡顿可见（两档阈值 + drift 聚合）

## 当前状态

- 阶段：Phase 4（Review & Document）· **已完成**
- 已确认：方案 ✅（用户确认）、计划 ✅（已确认，进入执行）
- 已完成：T1 ✅ / T2 ✅ / T3 ✅ / T4 ✅（T4a 文档同步 + T4b 基线回填 + T4c 核准归档）
- 下一步：已归档到 `openspec/completed/add-drift-detection.md`（2026-10-25）
- 前置：S1（`expand-observation-surface`）已归档；心跳降频的**开销维度**已实测通过
  （`docs/architecture.org`「实测结论 13」：250ms 档 +0.0357%，距 0.5% 预算余 14 倍），
  故本计划不再需要「先测开销才能开工」的阻塞项。
- 本期只做 S2（见 S1 计划的路线表），S3–S5 不在范围内。
- **修订记录（用户裁决 R1–R4，2026-10-25 定稿后落回）**：
  · **R1（裁决 A）迁移链**：`--migrate` 改为「版本变量逐级推进」（设计 7），
    并明确 `--ensure-schema` 会把 `user_version` 无条件置为当前常量的交互 ——
    v0 新库分支结束后 `version` 必须同步为 `--schema-version`（不是 1，否则会多跑两遍
    幂等脚本）；T1 三条迁移守门用例（v0 / v1 / v2）。
  · **R2（裁决 B）抑制宏**：确认**不**把 `el-chronos-drift-threshold-ms` 一并抬高，
    两个抑制宏只补 docstring 说明、**不改 `let` 绑定**（论证见注意事项 4）。
  · **R3（裁决 C）block 的 command**：~~新增 `--last-command-end-ts` /
    `--last-command-name` 与「最近命令回填」判据，两条路径取「命令内」优先~~
    —— **已被 R5 取代（整条作废）**：两个 defvar、判据逻辑、「block 补 command」目标全部取消。
  · **R4（裁决 D）drift 口径收窄**：drift **只记命令外停转**，命令内 500–2000ms 一律不记
    （`commands` 已有精确记录），于是 `hourly_drift` 的语义是「主线程在命令之外停转
    500–2000ms 的聚合」，且**与 `commands` 不可相加**；目标 1 的措辞从「亚秒级卡顿」
    改为「命令外停转」（设计 2 口径段 + 注意事项 5）。
  · **R5（方案变更，2026-10-25 用户批准）**：**改用「重置基线」方案 B** ——
    在 `post-command-hook`（即 `--finish`）结算后把 `el-chronos-collect--last-heartbeat`
    重置为当前时刻，命令执行时间被**物理切出** gap，block / drift 天然只覆盖命令外停转。
    其效果：**结构性消除 TD-11 缺陷③（双记）**、不需要任何命令归属判据（R3 作废）、
    `block.command` 保持 nil（目标 3 取消）。原 T0（判定逻辑验证）并入 T2，
    任务重排为 T1–T4（依赖 T2←T1←无 / T3←T2 / T4←全部）；用例预估 **23**
    （T1 6 / T2 16 / T3 4），基线 200 → 约 226。方案 B 的固有代价（已知漏检面）见
    注意事项 7 后的专段与设计 8 第 3 条。
  · **R6（补强，2026-10-25 用户批准）**：判定逻辑抽成
    `el-chronos-collect--heartbeat-check (&optional now)`，**三处调用**：
    timer 心跳（判定 + 重置）/ **`--pre-command`（新增，判定 + 重置）** /
    `--finish`（**只重置、绝不调 check**）。`--pre-command` 补判的目的：纯重置方案下
    「停转 → 用户立刻按键 → `--finish` 重置」会把那段停转整段吞掉，而这是最常见的用户
    行为；pre 是「命令外时间」的最后一个可观测时机。落点定死在 `(--finish 'aborted)`
    （417 行）之后、`(if (null name) …)`（418 行）之前（设计 4.3.1）。用例 23 → **26**
    （T1 6 / T2 16 / T3 4），基线 200 → 约 226。

## 目标
1. 让 **0.5–2s 的「命令外停转」可见**（当前完全不进库：`slow_events` 只有 `kind='command'`
   与 `kind='block'`，前者要求命令边界、后者受 2000ms 阈值与相位偏移双重挤压）。
   drift 只服务「主线程在**命令之外**停转」这一当前完全不可见的类别
   （命令外时间由**两条路径**共同覆盖：命令开始前的 `--pre-command` 补判 + 无命令时的
   timer 心跳；命令执行期间的时间则由 `--finish` 的重置切掉，见设计 4.3）。
2. 把 block 事件的**系统性高估上界从 1s 压到 250ms**（心跳 1s → 250ms）。
3. **彻底消除双记**（TD-11 缺陷③）：命令内停转由 `commands` 表**独占**
   （`duration_ms` 已含卡顿、≥200ms 另进 `slow_events(kind='command')`），
   block 与 drift 只覆盖命令外 —— 由「**`post-command-hook` 结算后重置心跳基线**」
   （用户批准的新方案 B）**天然保证**，不引入任何命令归属判据。
   推论：`block` 事件的 `command` 列**保持 nil**（只记命令外停转，没有命令可归因），
   原「block 补 command」目标**整条取消**。
4. **不膨胀明细表、不引入第三方依赖、不改变其它采集语义**（I1–I11 一条不改）。

## 设计

### 0. 事实基线（实测，2026-10-25，Emacs 31.1）

| 事实 | 值 | 来源 |
|---|---|---|
| 现有测试基线 | **200 用例**（analysis 27 / attrib 28 / collect 49 / report 32 / store 47 / web 17） | `grep -c '(ert-deftest' test/*.el` |
| schema | **10 表 + 3 索引**，`user_version=2` | `el-chronos-store--schema-version` |
| Web 路由 / 报告节 / analysis 查询 | **17** / **14** / **17** | `el-chronos-web--routes` 等 |
| defcustom | **20**（`el-chronos.el` 18 + 分散 2） | `grep -c '^(defcustom' el-chronos*.el` |
| 心跳单次唤醒成本 | **87 µs**（3 档同值；与唤醒率近似线性） | 实测结论 13 |
| 心跳 250ms 档外推占比 | **+0.0357%**（4 次/秒）；相对 1s 档净增 **+0.0279%** | 实测结论 13 |
| 心跳 1s / 500ms 档 | +0.00779% / +0.01712% | 实测结论 13 |
| 偏移模型 | 记录值 = 真实停转 + 偏移，偏移 = 阻塞开始 − 上次成功心跳 ∈ **[0, 1 心跳间隔]** | 实测结论 10 |
| 最坏高估实证 | 1.6s 停转（距上次心跳 973.7ms 处开始）→ 记成 **2576.4ms（+61%）** | 实测结论 10（场景 G） |
| 检出下界实证 | 最好相位 ~0.95s；最差相位需真实 > 2s（B2 的 1.5s 在偏移 450ms 时漏记） | 实测结论 10 |

基线数字以实施期磁盘实测为准；本计划预计 `make test` 从 **200** 升到约 **224**
（T1 6 + T2 16 + T3 4 = 26 例；允许实施期 ±2 的偏差）。

### 1. 根本问题（量化自「实测结论 10」）

| 缺陷 | 机制 | 量化 | 后果 |
|---|---|---|---|
| **检出下界高** | 判定是 `gap-ms > block-threshold-ms`（默认 2000），而 `gap-ms = 真实停转 + 偏移`，偏移 ∈ [0, 1000]ms | 真实停转必须 > 2000 − 偏移，即 **真实 > 1.0–2.0s** 才可能被记 | **命令外**的 0.5–2s 停转（timer 回调里的 GC、进程过滤器、`redisplay`、短同步 IO）**完全不可见**——`slow_events` 里没有痕迹，只能从采样表小时聚合间接猜。命令内的同类停转至少还有 `commands` 的精确时长兜底 |
| **系统性高估** | 记录值是「到上一次成功心跳为止的总 gap」，不是停转本身的时长 | 上界 **+1 个心跳间隔（1s）**；实证 1.6s → 2.58s（**+61%**） | 单次卡顿时长偏高；按 block 总时长做的趋势/回归判据整体偏大 |
| **双记** | 命令内停转 ≥2s 既记 `kind='command'`（精确）又记 `kind='block'`（高估） | 实测 A3：command 3000.0 + block 3371.5 | 两类求和当总卡顿时长即**重复计数**；而 `kind='block'` 的 `command` 恒 NULL，没有去重依据 |
| **亚阈值停转不可见** | 见缺陷 1 | <2s 停转零覆盖（实测 E：`garbage-collect` 92ms；F：1.5s 停转只在 `hourly_functions` 留下 1090ms 样本） | 「卡了一下」这类最影响体感的事件在库里不存在 |

**关键结论（决定方案形状）**：**心跳降频只解决「高估」，不解决「检出下界」。**
把间隔从 1s 降到 250ms，offset 上界从 1000ms 降到 250ms（高估收窄 4 倍），
但 `gap-ms > 2000` 这条判定本身不变 —— 真实 1.5s 的停转在多数相位下依然不记。
**要让亚秒级可见必须动阈值**，而直接降 block 阈值会让明细表膨胀（见设计 2 与 ADR-0005 备选①）。

### 2. 两档阈值

| 档 | 阈值（默认） | 落点 | 粒度 | 保留 |
|---|---|---|---|---|
| **block** | `el-chronos-block-threshold-ms` = **2000**（不变） | `slow_events(kind='block')` 明细行 | 逐条（时间戳 + 持续时长 + 上下文） | `el-chronos-retention-days`（默认 30 天） |
| **drift** | `el-chronos-drift-threshold-ms` = **500**（新增） | 新表 `hourly_drift` 小时聚合 | 每小时每会话一行（count / total_ms / max_ms） | **永久**（与五张 `hourly_*` 同类，仅 purge 清理） |

**drift 的口径（方案 B，必须写进 docstring 与文档）**：`hourly_drift` 记录的是
**「主线程在命令之外停转 500–2000ms 的聚合」**。命令内停转**不进 drift**，这个排除**不靠
任何判据**，而是由「`--finish` 结算后重置心跳基线」**天然保证**（设计 4.1）——
命令执行期间的时间根本不进入 gap。命令内停转在 `commands` 表里有精确记录
（`el-chronos-slow-command-threshold-ms` 默认 200ms，超过即进 `slow_events(kind='command')`）。
因为命令内停转根本不进 drift，**两表不存在重复计数，但正因为口径不同，drift 的时长与
`commands` 的耗时不可相加、也不该相加**（前者是「命令间隙的停转」，后者是「命令总耗时」，
两个不相交的集合）。

**为什么亚秒级走聚合而不是明细**：亚秒级卡顿的问题形态是「这个小时发生了 37 次、累计 24 秒、
最坏 1.8 秒」，不是「请看第 12847 行的时间戳」。若把 500ms 级的停转也灌进 `slow_events`：
按 1 次/分钟的中等频率估算，一天 1440 行、30 天保留期 4.3 万行 —— 而 `slow_events` 当前的
语义是「**重要事件簿**」（慢命令 + 长时间阻塞，可逐条点开看栈与上下文，报告里限
`el-chronos-report--blocking-rows`=20 行展示）。掺入亚秒级噪声会让它退化为「噪声日志」，
把真正要排查的 3 秒卡顿埋掉。

**两档互斥**：判定顺序是 if/else-if（设计 4），一次 gap 只进一档，不存在同一段停转既记
block 又记 drift 的情况。

### 3. schema v3

```sql
CREATE TABLE IF NOT EXISTS hourly_drift (
  hour_ts INTEGER NOT NULL, session_id INTEGER NOT NULL,
  count INTEGER NOT NULL DEFAULT 0, total_ms REAL NOT NULL DEFAULT 0,
  max_ms REAL NOT NULL DEFAULT 0,
  PRIMARY KEY (hour_ts, session_id));
```

- **不写外键**：与既有 `hourly_*` 及 v2 新表一致（不与 purge 的删除顺序、级联删除、
  `foreign_keys=ON` 三者耦合）。代价同 S1：孤儿行只能靠 purge 顺序与 flush 前的会话存在性
  校验消灭。
- **upsert**：`ON CONFLICT(hour_ts, session_id) DO UPDATE SET count = count + excluded.count,
  total_ms = total_ms + excluded.total_ms, max_ms = MAX(max_ms, excluded.max_ms)`
  —— 前两列累加，`max_ms` 取标量 `MAX`（两参数，SQLite 支持）。
- **保留策略**：**永久保留**（小时聚合，仅 `el-chronos-purge` 清理），与
  `hourly_functions` / `hourly_usage` / `hourly_stacks` / `hourly_gc` / `hourly_health` 同类。
  `el-chronos-store--prune` **不加** `hourly_drift`（`--prune` 永远只删 `commands` /
  `slow_events` 两张明细表），但其 docstring 与 `el-chronos-retention-days` 的 docstring
  里的「五张 hourly_*」要同步改成「六张」。
- **`--purge-targets` 扩到 11 表**：新增 `("hourly_drift" . hour-ts)`，位置
  **放在 `hourly_health` 之后、`sessions` 之前**（顺序约束的理由与既有五张聚合表完全相同：
  带 `hour_ts` 时间列、按列删、必须早于 `sessions`）。
- **迁移**：`--schema-version` 2 → **3**；`--schema-ddl` 更新为**全量 11 表**（新增
  `--ddl-hourly-drift` 常量并由它 concat 进全量串，避免同一批 DDL 存在两份字面量）；
  新增 `--sql-migrate-v3`（就是那一条 `CREATE TABLE IF NOT EXISTS hourly_drift`）；
  `--migrate` 追加分支。事务边界沿用 S1：`.bak` 复制在 `BEGIN` **之前**，
  `ROLLBACK` 在 `.bak` 覆盖**之前**，`user_version` 在本步内写死为目标版本（3）。

### 4. 心跳与「命令外」判定（方案 B：结算后重置基线）

**defcustom（一处新增、一处改默认值，均落 `el-chronos.el`）**

| 变量 | 改动 | 默认 | type | 位置 |
|---|---|---|---|---|
| `el-chronos-heartbeat-seconds` | 默认 `1` → **`0.25`**；docstring 补开销与理由 | 0.25 | `number`（**已经是 `number`**，无需改 type —— 见注意事项 8） | `el-chronos.el:85` |
| `el-chronos-drift-threshold-ms` | **新增** defcustom | 500 | `natnum` | `el-chronos.el`（defcustom 一律落此文件） |

`el-chronos-heartbeat-seconds` 的 docstring 要写清两件事：
① 默认 250ms 的目的是把 block 的**高估上界压到 250ms**（偏移模型见实测结论 10）；
② 实测开销 **+0.0357%**（`docs/architecture.org`「实测结论 13」，噪声地板 ±0.0003% 的 119 倍，
距 0.5% 预算余 14 倍）—— 且该数字是 **batch 下**的，GUI 主循环未验证（设计 8）。

#### 4.1 核心机制：`--finish` 结算后重置心跳基线

在 `el-chronos-collect--finish` 里，**结算完命令后把心跳基线重置为当前时刻**：

```elisp
;; 位置：`(let ((start ...) (name ...) (gc-start ...))' 之后、清状态 `setq' 之前
;;      （见「4.2 落点」）
(setq el-chronos-collect--last-heartbeat (float-time))
```

**它做了什么**：心跳的 `gap-ms` 是「本次触发 − 上次触发」。基线在每条命令结算时被推进到
「命令刚结束」的时刻，于是**下一条命令执行期间的时间不会进入任何 gap** ——
block 与 drift 因此**只覆盖命令之间的时间**，也就是「命令外停转」。

**为什么采用这个方案（而不是「命令归属判据」）**：

| 维度 | 原方案（`gap-start < --last-command-end-ts` 判据 + 两个 defvar） | **方案 B（重置基线）** |
|---|---|---|
| 命令内外区分手段 | 一个**比较**（反推 gap 起点 vs 命令结算时刻）驱动**两个输出**（`command` 字段 + drift 准入） | **不比较**：基线被物理推进，命令时间根本不进 gap |
| 错法 | 阈值/时间单位写错 → 静默误判，**误判窗口 ≤250ms**（一个心跳间隔），且同时污染两个输出 | 无判据可错；最坏情况只是「漏检阻塞结束后紧邻的那一段」（见注意事项 15 与设计 8） |
| 双记（TD-11 ③） | 需靠 `command` 字段事后去重 | **结构性消除**：命令内停转进不了 block/drift |
| 新增状态 | 2 个 defvar + I5 清理责任 + 判决逻辑 | 1 行 `setq`；`--last-heartbeat` 的唯一语义仍是「上次心跳时刻」 |
| `block.command` | 需回填，且归属靠反推（有误差） | **保持 nil**（诚实：只记命令外停转） |

关键判断：**「一个比较驱动两个输出」是最容易静默出错的形状** —— 它没有可观测的中间量，
写错时数据看起来完全合理（只是 drift 偏多/偏少）。重置基线把「命令内外」从**判定问题**
降级为**基线位置问题**，而基线位置（`--finish`）本来就只有一个自然落点。

#### 4.2 落点：`--finish` 的哪一步（读码后定死）

`el-chronos-collect--finish`（`el-chronos-collect.el:438`）现有顺序：

| 行 | 内容 |
|---|---|
| 450–452 | `(let ((start ...) (name ...) (gc-start ...)))` 绑定快照 |
| 453 | 注释「先清状态再干活：即使下面的记录失败（已被吞掉），也不会留下粘住的 pending」 |
| **454–459** | `setq` **先清状态**（`--pending-p` / `--command-start` / `--command-name` / `--command-gc-*` / `--errored-p`） |
| 460–… | `(when (and (numberp start) name) …)` 做四处写入（`record-command` / usage ×3 / 慢事件） |

**重置语句写在第 452 行之后、`setq` 清状态块（454–459 行）之前**（即 `let` 体内第一句，
可放在 453 行注释「先清状态再干活」之后或之前，但必须在 `setq` 之前）：

- **理由 1（贴住命令真实结束时刻）**：结算里含 `attrib-context` 归因、`--current-stack`
  取栈、多次 `--safe-apply` 写库 —— 越往后放，这些开销越会被「切掉」（它们不该算用户卡顿，
  但也不该被悄悄吞进基线之外）；放在 `let` 之后立刻执行，gap 起点 ≈ 命令体结束时刻。
- **理由 2（满足「早于命令状态清空」）**：若结算过程中心跳被触发（结算里的 `--safe-apply`
  可能产生 IO），此时 `--pending-p` 仍为 t → 兜底门（4.3 第 ② 步）会跳过判定，
  而基线已是 `now` → 即便判定被跳过，也不会在解除兜底后把结算耗时算成 gap。
- **理由 3（早退路径一并覆盖）**：该位置在 `(when (and (numberp start) name) …)` **之外**，
  所以「无主命令」（`--command-name` 为 nil）与 `aborted` 结算路径**同样重置基线** ——
  否则 `aborted`（`pre-command-hook` 里结算上一条）会把「上一条命令 + 命令间隙」整段留给
  下一次心跳，重新引入命令内时间。

#### 4.3 三处调用点：判定逻辑抽成 `--heartbeat-check`，但**只有两处**做判定

把现有 `--heartbeat` 里的「判定 + 重置」抽成
`el-chronos-collect--heartbeat-check (&optional now)`：

- 内部保留全部现有逻辑（抑制门 → `--pending-p` 兜底门 → block / drift 判定 → 末尾
  `(setq el-chronos-collect--last-heartbeat now)`），整体 `condition-case` 包裹（I6）；
- **无参时取 `(float-time)`**，参数 `now` 供测试注入确定性时刻；
- timer 回调 `--heartbeat` 退化为**薄壳**（只调 `--heartbeat-check`），语义与现状一致。

**三个调用点，职责各不相同（写死，不许「统一一下」）**：

| 调用点 | 实际调用 | 行为 | 理由 |
|---|---|---|---|
| 心跳 timer（每 250ms） | `--heartbeat-check` | 判定 + 重置 | 现状语义；覆盖「两条命令之间**迟迟没有下一条命令**」的停转（此时没有 pre 可挂钩） |
| **`--pre-command`（新增）** | `--heartbeat-check` | 判定 + 重置 | **在开始新命令计时之前结清「命令外时间」**。这解决了「停转 → 用户立刻按键 → 停转被 `--finish` 的重置整段吞掉」的漏检（见 4.3.2） |
| **`--finish`** | **只 `setq --last-heartbeat (float-time)`**，**不调 check** | 仅重置（丢弃命令内时间） | 此处若调 check，`gap` 恰是**刚执行完的命令时长** → 会被记成 block/drift，**双记立刻复活**。这是本设计唯一的硬禁令 |

**为什么三处共享一个基线不会重复记录**：timer、`--pre-command` 与 `--finish` 都只有
**一个** `--last-heartbeat`，谁先跑谁推进它。命令间隙内主线程空闲时 timer 每 250ms 推进一次
→ `--pre-command` 看到的 `gap` 只有 ≤250ms，不记；只有间隙内主线程真被占住（timer 跑不了）
时，`--pre-command` 才看到大 `gap` 并记一条。**互斥由共享基线与单一判定函数天然保证**，
不需要额外的去重逻辑。

##### 4.3.1 `--pre-command` 的落点（读码后定死）

`el-chronos-collect--pre-command`（`el-chronos-collect.el:378`）现有顺序：

| 行 | 内容 |
|---|---|
| 409 | `(let ((name (el-chronos-collect--command-label)))` |
| 412–415 | **D1 双跑守卫**：同一命令被同一 hook 双跑时直接返回（不结算、不重置计时） |
| 416–417 | 若 `--pending-p` 为真 → `(--finish 'aborted)` 结算上一条 |
| 418–425 | 命令名为 nil 分支：清状态、不开始计时 |
| 426–431 | 正常分支：写 `--command-start` / `--command-name` / gc 基线 / `--pending-p` t |

**调用写在第 417 行之后、418 行的 `(if (null name) …)` 之前**（一句
`(el-chronos-collect--heartbeat-check)`，放在 `let` 体内、守卫之外）。

**为什么必须在这个位置（顺序不可换）**：

1. **必须在 `(--finish 'aborted)` 之后**：`aborted` 路径上 `--pending-p` 在补判时刻仍为 t
   （`--finish` 还没跑）→ 兜底门会**跳过判定**，补判等于白跑。先让 `--finish` 结算并把基线
   重置到「上一条命令结束」，再用补判度量「上一条结束 → 这一条开始」的命令外间隙，
   语义才正确。
2. **`aborted` 结算自身的耗时会被计入 `gap`（明确接受）**：`--finish` 的写入开销
   （`attrib-context` / `--current-stack` / `--safe-apply`）落在 `gap` 里，量级为
   **µs 级、最坏几 ms**（`--current-stack` 读 profiler 日志），远低于 drift 阈值 500ms，
   因此不影响判定；代价是这一段观测器自身开销被算进「命令外时间」—— 与既有「报告/Web 用
   抑制宏排除自身耗时」相比是更粗的处理，但**只有 aborted 路径**（C-g / 异常中断）才发生，
   频率低且量级可忽略。
3. **必须在 `--command-start` 赋值（426）之前**：补判要度量的是「命令**开始之前**」的时间；
   若放在赋值之后，`--finish` 之外还会把 `--command-start` 之前那几行微秒也算进去（无害），
   但更关键的是**语义混乱** —— 代码读起来会像「命令开始后还做了一次心跳判定」。
4. **在 D1 守卫（412–415）之外**：守卫命中表示「同一条命令被双跑」，此时没有真实间隙，
   补判本来也不会记任何东西（`gap` ≈ 0）；把它放在守卫外可以保持「每条真实命令开始时
   都结清一次」的简单不变式。

##### 4.3.2 `--pre-command` 补判解决的具体序列

纯重置方案（只有 timer + `--finish` 两处）下的漏检：

```
命令外停转 1.2s（timer 回调里忙等）→ 心跳在此期间跑不了
主线程恢复，用户已按键
Emacs 先执行命令（输入优先于 timer）→ post → --finish 重置基线 = now
心跳补跑：gap ≈ 250ms → 那段 1.2s 永远消失
```

加上 `--pre-command` 补判后，同一序列：

```
命令外停转 1.2s → 主线程恢复，用户已按键
pre-command → 补判：last = 停转前最后一次心跳，now = 命令开始前
           → gap ≈ 1200ms + → 记一条 drift（或 block）✓
           → 然后才开始命令计时（命令时长照旧由 --finish 切掉）
```

**这正是用户裁决要求的补强点**：`--pre-command` 是「命令外时间」的**最后一个可观测时机**，
错过它就只能靠 timer 心跳（而 timer 恰好是被阻塞饿死的那个）。

#### 4.4 判定链（三步）

`el-chronos-collect--heartbeat`（`el-chronos-collect.el:502`）现状：

```elisp
(setq el-chronos-collect--last-heartbeat now)          ; ← 基线推进在 unless 之外（保持不变）
(unless (bound-and-true-p el-chronos-collect--suppress-block-p)
  (when-let* ((gap-ms (and (numberp last) (* 1000 (- now last))))
              ((> gap-ms el-chronos-block-threshold-ms)))
    ... 记 slow_events(kind="block") ...))
```

改为：

1. **抑制门**：`--suppress-block-p` 为真 → **只推进基线、不判定**（现状不变；报告 / Web 的
   自观测抑制同样覆盖 drift，见 4.5）；
2. **兜底门**：`--pending-p` 为真 → **跳过判定**（只推进基线）。**这是兜底而非主判据**：
   主判据是 4.1 的基线重置；但「命令中途让出主线程」（`sleep-for` / 同步 IO / 等待输入）
   时心跳会真的跑起来，而此后命令内若又发生停转，`gap` 会从那次心跳算起、**跨过**命令边界
   进入下一个 gap —— `--pending-p` 为真时跳过判定正好拦住这段泄漏。
   两条分工：**重置基线管「正常路径」，`--pending-p` 兜底门管「命令中途让出主线程」的泄漏**。
3. **判定**（`gap-ms` 有效时）：
   - `gap-ms > el-chronos-block-threshold-ms` → 记 `slow_events(kind="block")`
     （`duration_ms` = `gap-ms`、`command` = **nil**、`stack` = nil、`context` = 归因上下文）；
   - **否则** `gap-ms > el-chronos-drift-threshold-ms` → `(el-chronos-store-record-drift
     (el-chronos-collect--hour-ts) gap-ms)`（累加到小时桶），**不写 `slow_events`**；
   - 都不满足 → 什么都不做。

- **drift 与 block 必须同时落在两个门之内**（抑制门 + 兜底门）：两档共用同一条判定路径，
  任何「只给 drift 加门」或「只给 block 加门」的写法都会产生一个能被静默污染的档位。
- **block 的 `command` 恒 nil 是正确行为**（目标 3 已取消）：它只记命令外停转，没有命令可
  归因。**不要**为了「字段有信息」去填上一条命令名 —— 那会把「命令外停转」误导成
  「某条命令内的停转」，读者会去 `commands` 里找一条并不慢的命令。
- 除判定链外**不动**：`(setq --last-heartbeat now)` 的位置（在门之外，抑制期间也必须推进）、
  `condition-case` 包裹、通知分支（`el-chronos-collect-notify-blocks`）都保持现状；
  drift 分支**不发提示**（亚秒级不配占用 echo area，且默认 notify 已是 nil）。

#### 4.5 与既有抑制宏的关系（第 3 层仍然必要）

抑制宏的三层（`el-chronos-report--without-block-events` /
`el-chronos-web--without-block-events`）：

| 层 | 机制 | 方案 B 之后是否仍必要 |
|---|---|---|
| 1 | `let` 绑定 `--suppress-block-p` | **必要**（BODY 期间心跳的抑制门） |
| 2 | `let` 抬高 `el-chronos-block-threshold-ms` 到 60s | **保留但不为 drift 服务**：drift 判定在同一个 `unless` 之内，抑制门已覆盖；抬阈值只对 block 档生效（见注意事项 4） |
| 3 | 收尾 `(setq --last-heartbeat (float-time))` | **仍然必要**：BODY 期间主线程被占，心跳跑不了；BODY 返回时 `let` 已解除，补跑的心跳看到整段 gap。注意新增的 `--finish` 重置**救不了这一场景** —— 报告/Web 渲染期间不会有命令结算 |

**两个重置点并存不冲突**：都是「设为 `now`」，幂等；且它们的触发条件互斥
（抑制宏在 BODY 收尾、`--finish` 在命令结算）。**不要**因为「`--finish` 也会重置」而
删掉抑制宏第 3 层 —— 那会让一次报告生成（几秒）变成一条巨型 block/drift 事件。

#### 4.6 阈值与偏移的合成结果（写给读者，避免把 500ms 读成「精确下界」）

| 档 | 阈值 | 判定条件 | 真实停转被记的下界 | 记录值的高估上界 |
|---|---|---|---|---|
| block | 2000ms | `gap > 2000` | 2000 − 偏移 ∈ **[1750, 2000]ms**（心跳 250ms） | **250ms**（原 1000ms） |
| drift（**仅命令外**） | 500ms | `500 < gap ≤ 2000` | 500 − 偏移 ∈ **[250, 500]ms** | 250ms（`total_ms` 每次累加最多多算 250ms） |
| 命令内（任意时长） | — | 两档都不记（基线被重置） | — | — （由 `commands` + `slow_events(kind='command')` 覆盖） |

**偏移的起点变了**：方案 B 之后，「偏移」相对的不再是「上一次心跳」，而是
「上一次**心跳或命令结算**中较晚的那个」—— 命令外停转前的最后一次事件若是命令结算，
偏移上界仍是 250ms；若紧接一次心跳，同样 ≤250ms。因此上表的区间判据不变。

**边界是相位相关的，不是精确的 2000ms**：一段真实的 1.9s 命令外停转，若偏移 100ms →
`gap` = 2000（不 > 2000）→ 记 drift；若偏移 150ms → `gap` = 2050 > 2000 → 记 block。
同一段停转可能落在 block 也可能落在 drift，取决于它相对上次心跳/命令结算的相位。
这不是缺陷，但文档与 UI 必须提醒：**不要跨档比较「次数」**，也不要假设
「block ⇒ ≥2s 真实停转」。

### 5. store 侧

- 新增 `(defvar el-chronos-store--drift (make-hash-table :test #'equal))`，键
  `"hour|session"`（复用既有 `--session-key-part` 拼法），值 vector
  `[count total-ms max-ms]`。
- 新增 `el-chronos-store-record-drift (hour-ts gap-ms)`：累加进 hash（`max` 取两者较大值）；
  整体 `condition-case` 包裹（I6）；**会话未知时跳过并告警一次** —— 沿用既有
  `--aggregate-orphan-warned` / `--session-known-p` 模式（与 v2 三张新表的孤儿守卫同款：
  `hourly_drift` 无外键，孤儿行 purge 删不掉）。
- `el-chronos-store--pending-p` **纳入 `--drift`**（漏了会让「只有 drift 待写」时 flush
  早退，数据永远不落库且不报错）。
- **`el-chronos-store--aggregates-pending-p`（`el-chronos-store.el:864`）也必须纳入 `--drift`**
  （审查发现的漏项）：它的 docstring 现为「三个新聚合 hash（gc / health / startup）」，
  改「四个（+ drift）」。理由：它是「自监控计数是否搭便车上报」的判据，漏掉 drift 会让
  「只有 drift 待写」时丢弃/失败计数不上报，health 数据出现无法解释的空洞。
- **`el-chronos-store--warn-orphan-aggregates`（`el-chronos-store.el:869`）的文案补上
  `hourly_drift`**（现为「已跳过 hourly_gc / hourly_health / startup_phases 写入」）：
  否则用户看到告警会以为 drift 写成功了，而实际被整批跳过。
- `el-chronos-store--clear-aggregates` 纳入 `--drift`（成功与失败路径同批清空，docstring
  的「六个聚合 hash」改「七个」）；`el-chronos-store-close` 同样清理。
- `el-chronos-store-flush` 在**既有 `BEGIN`/`COMMIT` 事务内**追加一条 `hourly_drift` upsert，
  并纳入「会话行存在性校验」（与 gc / health / startup 三表共用同一处判定与同一次告警）。
- 新增常量 `el-chronos-store--sql-upsert-drift`（含累加与 `MAX` 语义的 docstring）。

### 6. 查询与呈现

**analysis**

```elisp
(defun el-chronos-analysis-drift-trend (range &optional buckets) ...)
```

按桶返回 `(:buckets ((:bucket START-MS :count N :total-ms X :max-ms X) ...) :count-total N
:ms-total X :max-ms X)`；沿用 `el-chronos-analysis--guard`、`el-chronos-analysis--bucket-span`
与 `el-chronos-analysis--range-buckets`（与 `el-chronos-analysis-gc-trend` 同款：SQL 只做窗口
过滤、聚合在 Elisp 层），空桶不返回，单位遵守 I4（毫秒）。

**报告**：在既有「阻塞事件」节**之内**加一行汇总（**不新开一节** —— 报告已有 14 节，
节数膨胀会让 org 报告本身变成阅读负担）：

```
- 命令外漂移：本窗口 37 次 / 累计 24.1 s / 最坏 1.82 s（阈值 500 ms，含 ≤250 ms 高估；
  仅统计命令之外的停转，命令内停转见「慢命令」）
```

**口径必须在文案里出现**（用户裁决 D）：报告的这一行**只能**表述为「命令外漂移」，
并注明「命令内停转不在此列」—— 否则读者会把它与「慢命令」相加，得到重复的总卡顿时长。

具体落点由实施者判断（节首一行 summary，或在既有表格下追加一行说明），但**必须让
「本期 drift 次数 / 累计 / 最坏」可见**，且**必须标注高估口径**（否则读者会把 1.82s 当精确值）。
无数据时输出一句 `- 命令外漂移：本窗口无记录（阈值 500 ms）`，不留空白（I11 精神：可见降级）。

**Web**：新增 `/api/drift` 路由（第 18 条：1 页 + 16 API + 1 CSV），在既有
`el-chronos-web--route-blocking` 对应面板里加一段「命令外漂移（≥500ms）」表格
（小时 / 次数 / 累计 / 最坏），或独立面板 —— 二者取一，**不得新增第三方图表库**（I10）。
新增路由必须同步 `docs/ui.org` 的路由表（该常量 docstring 已写明这条约束）。

### 7. 迁移链陷阱：v1 库升级一次到不了 v3（本次最容易漏的一条）

S1 的 `--migrate` 现状是两个**互斥**的 `when`：

```elisp
(when (< from-version 1) (el-chronos-store--ensure-schema db))   ; 0 号库 → 全量最新 + 版本置最新
(when (= from-version 1)
  (sqlite-execute db "BEGIN")
  (sqlite-execute-batch db el-chronos-store--sql-migrate-v2)
  (sqlite-pragma db "user_version=2")        ; ← 本步只把版本置为 2
  (sqlite-execute db "COMMIT"))
```

若本次**只**追加 `(when (= from-version 2) ...)`，那么 **`from-version = 1` 的库**
（S1 之前建的库，升级过一版但没升到 v3 的用户）会走 v2 分支把版本推到 2，
然后**没有任何分支继续推 v3** → `--migrate` 返回 t、`--open-db` 返回可用句柄，
但库里**没有 `hourly_drift` 表** → 本次会话所有 drift 写入 `no such table` → flush 失败 →
限流告警 + 丢本批；下次启动才补上 v3。这是「静默降级」型缺陷，必须在本次一并解决。

**要求的写法（用户裁决 A：**版本变量逐级推进**，不用 `(= from-version N)` 互斥分支）**：

```elisp
(let ((version from-version))
  (when (< version 1)
    ;; `--ensure-schema' 把 `user_version' **无条件**置为当前常量（3），并把 11 张表全建好。
    ;; 因此这里不能把 version 留在 0（末尾的 pragma 会把已经建全表的库标成版本 0），
    ;; 也不该留在 1（会立刻触发下面的 v2 / v3 分支，让刚建全表的库再迁移两遍）。
    ;; 最干净的写法是把 version 同步为**当前版本常量**，让后续分支自然都不触发。
    (el-chronos-store--ensure-schema db)
    (setq version el-chronos-store--schema-version))
  (when (= version 1)
    (sqlite-execute db "BEGIN")
    (sqlite-execute-batch db el-chronos-store--sql-migrate-v2)
    (sqlite-pragma db "user_version=2")
    (sqlite-execute db "COMMIT")
    (setq version 2))
  (when (= version 2)
    (sqlite-execute db "BEGIN")
    (sqlite-execute-batch db el-chronos-store--sql-migrate-v3)
    (sqlite-pragma db "user_version=3")
    (sqlite-execute db "COMMIT")
    (setq version 3))
  (sqlite-pragma db (format "user_version=%d" version)))
```

三条必须满足的语义（**T1 的三个守门用例逐一对应**）：

| 起始版本 | 必须发生的事 | 最终 |
|---|---|---|
| **0（新库）** | 只走 `--ensure-schema`（建全 11 表 + 版本置 3），**不重跑** v2 / v3 脚本 | 11 表、`user_version=3` |
| **1（S1 之前的老库）** | v2 脚本 → 版本 2 → **继续** v3 脚本 → 版本 3（**一次打开就到位**） | 11 表（含 `hourly_drift`）、`user_version=3` |
| **2（S1 的库）** | 只跑 v3 脚本 | 11 表、`user_version=3` |

- **`--ensure-schema` 的交互是本方案唯一的陷阱**（裁决 A 特意点明）：它在建完表后
  **无条件**写 `user_version = --schema-version`（= 3），所以那次调用返回后库里已是 v3，
  而局部 `version` 变量还停在原值。三种结局只有一种可接受：
  · 留在 **0** → 末尾 pragma 把已经是最新的库标成**版本 0**，下次打开又走一遍迁移
    （幂等但版本号长期失真）—— **禁止**；
  · 置成 **1**（裁决里给的写法）→ 末尾 pragma 写出 ≥1 的正确版本，代价是 v2 / v3 脚本各
    多跑一遍（`CREATE TABLE IF NOT EXISTS` 幂等，不会报错，但「刚建全表又迁移两遍」的语义
    混乱让失败恢复路径难以推理）—— **可行但不推荐**；
  · 置成 **`--schema-version`（3，推荐）** → 后续分支自然都不触发，末尾 pragma 写 3，
    既不重跑也写出正确版本。
  **实施时取第三种**；若坚持第二种，必须在 `--migrate` 的 docstring 里写明「v0 新库会多跑
  两遍幂等脚本」这一事实，否则后人会把它当 bug 排查。
- 每个迁移步骤内部各自 `BEGIN` / `COMMIT`（两步两个事务）：与「每步把版本推进到本步目标
  版本」的既有注释一致，回滚粒度也更清楚；失败时 `ROLLBACK` 仍走外层的既有回滚路径
  （关句柄 → `.bak` 覆盖 → 删 `-wal`/`-shm` → 告警 → 返回 nil）。

### 8. 未知项与外部依赖（必须写清）

| 未知项 | 状态 | 为什么本阶段无法解决 | 对策 |
|---|---|---|---|
| **250ms 心跳在 GUI 主循环的开销** | **未实测** | 实测结论 13 的 250ms 档是在 `emacs -Q --batch` 下用 `accept-process-output` 驱动事件循环测的：batch 无 redisplay、无输入事件队列，唤醒路径更短。**用户已明确拒绝在主实例上跑探针**（会占用其正在使用的 Emacs 主线程），故本阶段无法补测 | 14 倍预算余量（0.0357% vs 0.5%）足以吸收偏差；`el-chronos-heartbeat-seconds` 是 defcustom，GUI 用户若观感异常可自行回调到 0.5 / 1；记入 tech-debt |
| **drift 的真实频率与自然分布** | **未知** | batch 只能注入**人造**延迟（纯 Lisp 忙等），量不出真实工作负载下 500ms–2s 停转的发生率。频率未知 → 无法预判 `hourly_drift` 的增长速率、也无法判断 500ms 这个默认阈值是否合适 | 见下方「调档指引」；T2 的四档用例只验证判定链、**不产出真实频率数据**（验收标准里已声明）；记入 tech-debt |
| **真实停转的检出率（0.5–2s 区间）** | 只能给相位模型预测 | 同上：需要真实工作负载 + 真实 GUI（`redisplay` 阻塞在 batch 恒为 0ms，实测结论 10 的 D2 场景） | 上线观察一周后按 drift 计数与 `commands` 慢命令的比例校准 |
| ~~重置基线的漏检面~~（**已由 4.3 的 `--pre-command` 补判解决**） | 已处置 | 纯重置方案下，「命令外停转结束 → 用户立刻按键 → `--finish` 重置」会把那段停转整段吞掉。加了 `--pre-command` 补判后，命令开始前会先结清命令外时间，该序列被覆盖（设计 4.3.2） | 残余仅两种：① D1 双跑守卫命中时 pre 直接返回（同一命令双跑、无真实间隙，无害）；② 停转后主线程恢复执行的**不是命令**（如另一个 timer 回调）——此时由 timer 心跳在其后捕获。两种残余都不需要额外处置 |
| **连续命令流中的累计卡顿不可见**（方案 B 的**结构性**损失） | **不可在本阶段量化** | 当卡顿分散在几十条 20–50ms 的连续命令里（总 1.5s、**单条都不慢**）时：单条都进不了 block/drift（命令时间被切掉）、也进不了 `slow_events`（都 <200ms 的慢命令阈值）；只有 `commands` 表能靠时间戳聚类看出来。判据方案至少能在命令内记 block，方案 B 不能 | 如实写入 `docs/architecture.org`「已知偏差」与 `docs/operations.org`；登记 tech-debt。要看这类卡顿只能查 `commands` 的时间戳密度（`el-chronos-analysis` 已有按小时聚合，够用但需要人工解读） |
| **`--pre-command` 补判只覆盖「命令开始前」** | 设计边界，非缺陷 | 停转发生在两条命令之间、而**下一条命令迟迟不来**时，补判不会发生（没有 pre 触发）；此时由 timer 心跳捕获（每 250ms 一次，主线程空闲时一直在跑）——这是**正常路径**，不是漏检 | 无需处置；写入文档是为了让读者知道「补判不是万能，只是补上 timer 被饿死的那一类」 |

**调档指引（进 `docs/operations.org`，必须可执行）**：

- `el-chronos-drift-threshold-ms` 默认 **500**：`hourly_drift` 每小时行数过多（噪声感强）→
  上调到 800–1000；「0.3–0.5s 的卡顿也想看见」→ 下调到 300（**注意**：心跳 250ms 时
  `阈值 < 250` 无意义，判定下界受偏移约束，调到 250 以下只会把每一次正常心跳抖动记成 drift）。
- `el-chronos-heartbeat-seconds` 默认 **0.25**：觉得自己机器上 timer 唤醒开销明显（笔记本电池、
  低功耗设备）→ 回调到 0.5（开销约减半，block 高估上界升到 500ms，drift 检出下界相应上移）。
- 两个阈值的关系是**硬约束**：`el-chronos-drift-threshold-ms` 必须
  **> `el-chronos-heartbeat-seconds` × 1000**（否则正常心跳间隔就被判成 drift）。
  代码里不做断言（用户可能在运行中改），但在两个 defcustom 的 docstring 与
  `docs/operations.org` 的调档表里都要写明这条。

## 任务

- [ ] **T1 schema v3（含迁移链修复、purge 扩 11 表、保留策略）+ 测试**

  改动文件：`/home/thomas/Workspace/el-chronos/el-chronos-store.el`、
  `/home/thomas/Workspace/el-chronos/test/el-chronos-store-test.el`

  步骤：① 新增 `el-chronos-store--ddl-hourly-drift`（设计 3 的 SQL **逐字**，docstring 写明
  「不写外键」与 upsert 语义）；② `--schema-ddl` 尾部 concat 该常量（保持既有表顺序不变，
  `commands` 仍在 `sessions` 之后）；③ 新增 `--sql-migrate-v3`（就这一条 DDL）；
  ④ `--schema-version` 改 **3**，docstring 补「版本 3 = 新增 hourly_drift」；
  ⑤ `--migrate` 按**设计 7 的「版本变量逐级推进」方案**重写（`(let ((version from-version)) ...)`
  + `(when (= version N) ...)` 三步 + 末尾统一 `(sqlite-pragma db (format "user_version=%d" version))`），
  **`--ensure-schema` 分支结束后把 `version` 置为 `--schema-version`**（不是置 1 —— 理由见设计 7
  的三种结局对比）；每个步骤内 `BEGIN` → batch → `user_version=N` → `COMMIT`；
  ⑥ `--purge-targets` 加 `("hourly_drift" . hour-ts)`，位置在 `hourly_health` 之后、
  `sessions` 之前，docstring 的「10 张表」改「11 张」；⑦ `--prune` **不加** drift 表，
  但 docstring 的「五张 hourly_*」改「六张」并列出 `hourly_drift`；
  ⑧ `el-chronos-retention-days`（`el-chronos.el`）的 docstring 同步「五张」→「六张」；
  ⑨ 同步修改既有用例（改既有用例须在 `CHANGELOG.md` 说明原因）：
  · `el-chronos-store-test-user-version-migration`：表数断言 → **11**、`user_version` → **3**；
  · `el-chronos-store-test-purge-empties-and-rebuilds-session`：返回 alist 项数 → **11**，
    「N 表清空」的 N 相应 +1（`sessions` 重建后仍有 ≥1 行）。

  验收标准：`make check-parens` 通过、`make lint` 零告警；新增**六个**用例，其中
  **前三个是迁移守门用例**（起始版本 0 / 1 / 2 各一条）——
  **「v0 新库一次到 v3」**（空路径 open → `sqlite_master` 表计数 = **11**、
  `user_version` = **3**；**并断言 v2 / v3 脚本未被额外执行** —— 用 `cl-letf` 在
  `--sql-migrate-v2` / `-v3` 上挂计数器，确保「刚建全表又迁移两遍」不会被当成正常；
  若实施取设计 7 的「置 1」写法，本用例应显式放宽并注明原因）、
  **「v1 老库一次到 v3 且 `hourly_drift` 存在」**（v1 DDL + `user_version=1` → open →
  11 表齐、`hourly_drift` 能 `SELECT count(*)`、`user_version` = **3**；若实现成
  `(= from-version 2)` 的互斥分支，本用例必红）、
  **「v2 库到 v3」**（v2 DDL + `user_version=2` + 插 2 行 `commands` → open → 11 表齐、
  `commands` 仍 2 行、`user_version` = 3）；
  其余三条 ——
  **「v3 迁移失败整体回滚」**（`cl-letf` 让 `--sql-migrate-v3` 抛错 → `--migrate` 返回 nil、
  `user_version` 仍 2、仍只有 10 表、随后能正常再次打开）、
  **「purge 覆盖 11 表」**（11 表各插 1 行 → `(el-chronos-purge)` → `sessions >= 1`、
  其余 10 表 `count(*) = 0`；fixture 仍需 `let` 绑定 `user-emacs-directory` 到无 `.git`、
  无 init 文件的临时目录，否则 `session_meta` 会被 S1 的变更标记写入 1–2 行）、
  **「`--prune` 不动 hourly_drift」**（`--prune` 前后 `hourly_drift` 行数不变）。
  `make test` 全绿。
  （依赖：无）

- [ ] **T2 重置基线 + 心跳 250ms + drift 判定 + 兜底 pending-p + 测试**

  改动文件：`/home/thomas/Workspace/el-chronos/el-chronos.el`（两个 defcustom）、
  `/home/thomas/Workspace/el-chronos/el-chronos-collect.el`（`--finish` 重置基线 +
  心跳三步判定）、
  `/home/thomas/Workspace/el-chronos/el-chronos-store.el`（`--drift` 容器、`-record-drift`、
  `--pending-p`、**`--aggregates-pending-p`**、**`--warn-orphan-aggregates` 文案**、
  `--clear-aggregates`、`store-close`、flush upsert、`--sql-upsert-drift`）、
  `/home/thomas/Workspace/el-chronos/test/el-chronos-collect-test.el`、
  `/home/thomas/Workspace/el-chronos/test/el-chronos-store-test.el`

  步骤：① `el-chronos-heartbeat-seconds` 默认改 **0.25**（type 已是 `number`，不动）；
  docstring 补「高估上界 250ms」与「+0.0357%，见实测结论 13」「batch 未含 GUI」；
  ② 新增 `el-chronos-drift-threshold-ms`（**落 `el-chronos.el`**，`natnum`，默认 500，
  docstring 写明与心跳的硬约束关系与「调档见 `docs/operations.org`」）；
  ③ **把判定逻辑抽成 `el-chronos-collect--heartbeat-check (&optional now)`**（设计 4.3）：
  内部保留抑制门 → 兜底门 → block/drift 判定 → 末尾 `setq --last-heartbeat now`；
  无参取 `(float-time)`；**整体 `condition-case` 必须在 check 内部**（见注意事项 10）；
  `--heartbeat` 退化为薄壳；**`--finish` 里加重置基线**：位置按**设计 4.2 定死** —— 在
  `(let ((start ...) (name ...) (gc-start ...)))` 之后、清状态 `setq`
  （`el-chronos-collect.el:454–459`）**之前**，一句**纯**
  `(setq el-chronos-collect--last-heartbeat (float-time))`（**不调 check**，见注意事项 8）；
  docstring 写明「把命令执行时间从 gap 中切掉，使 block / drift 只覆盖命令外停转；
  `--pending-p` 是兜底门，不是主判据」；
  ③b **`--pre-command` 里加补判**（设计 4.3.1）：`(--finish 'aborted)`（第 417 行）
  **之后**、`(if (null name) …)`（第 418 行）**之前**，一句
  `(el-chronos-collect--heartbeat-check)`（外层再包 `ignore-errors` 双保险）；
  docstring 写明「命令开始前结清命令外时间，补上 timer 被饿死、而 `--finish` 重置又会
  吞掉的那一段」；
  ④ 心跳判定链按**设计 4.3 三步**改（抑制门 → `--pending-p` 兜底门 → block / drift / 不记），
  两档共用同一对门；`block` 的 `:command` **保持 nil**（不要回填）；
  ⑤ store 侧按设计 5 全部落地（含 `--aggregates-pending-p` 纳入 `--drift`、
  `--warn-orphan-aggregates` 文案补 `hourly_drift`、孤儿会话守卫）；
  ⑥ **复核两个抑制宏**：只补 docstring 说明「新增的 `--finish` 重置不替代本宏第 3 层
  （渲染期间没有命令结算）」，**不改 `let` 绑定**。

  验收标准：`make check-parens` + `make lint` 全绿；新增**十六个**用例 ——
  **A. 双记消除守门（本任务最重要的一条）**：「命令内 ≥2s 停转不再记 block」
  （伪造 `--command-start` 使命令耗时 2.5s，命令执行期间不触发心跳，随后调用
  `el-chronos-collect--finish` 模拟结算 → 断言 `slow_events` 里**只有** `kind='command'`
  一行、**没有** `kind='block'` 行）；
  **B. 重置基线本身**：「`--finish` 把 `--last-heartbeat` 推进到当前时刻」
  （先把基线置为 `now − 3s` → 调用 `--finish` → 断言基线距 now < 50ms）；
  **C. 兜底门**：「`--pending-p` 为真时跳过判定」（基线置 `now − 1.2s` +
  `--pending-p` = t → 调 heartbeat → `--drift` 与 `--slow-events` 皆空、基线已推进）；
  **D. 抑制门**：「抑制期间 drift 不记」（`--suppress-block-p` = t + 基线 `now − 1s` →
  调 heartbeat → `--drift` 为空）；
  **E. 四档阈值（命令外，原 T0 并入）**：0.3s **不记** / 0.6s 记 drift / 1.2s 记 drift /
  2.5s 记 block（且不记 drift）—— 四档都要先清 `--pending-p` 并把基线设成偏移 = 0 的
  确定性起点（**不依赖 timer 真实相位**，否则 0.3s / 0.6s 会 flaky）；
  **F. store 侧两例**：drift 同小时两次累加（`count` = 2、`total_ms` 求和）、
  `max_ms` 取较大值（先小后大、先大后小各一次）；
  **G.** 「drift 不写 `slow_events`」（0.6s 档之后 `--slow-events` 仍为空）；
  **H.** 「只有 drift 待写时 flush 不早退」（清空其它缓冲、只留 `--drift` → flush 后库里有行）；
  **I.** 「只有 drift 待写时 `--aggregates-pending-p` 为真」（验证审查发现的漏项已修）；
  **J.** `pre-command-resets-and-detects-pre-command-gap`：基线置 `now − 1.5s` 且
  `--pending-p` = nil → 调 `--pre-command` → 断言记了一条 drift（2.5s 则记 block）
  **且基线被推进到接近 now**；
  **K.** `finish-does-not-record-command-time`（**方案 B 的核心价值守门**）：伪造命令执行
  3s（`--command-start` = `now − 3s`、`--command-name` = `"foo"`、`--pending-p` = t）→
  调 `--finish 'ok` → 断言 `slow_events` 里**只有** `kind='command'` 一行、**没有**
  `kind='block'`，`--drift` 为空、基线已推进；
  **L.** `heartbeat-check-is-single-source-of-truth`：`cl-letf` 在 `--heartbeat-check` 上
  挂计数器 → 依次触发 timer 回调 / `--pre-command` / `--finish` → 断言计数 = **2**
  （timer + pre），即 `--finish` **没有**经过 check。
  `make test` 全绿。
  （依赖：T1）

- [ ] **T3 查询 + 报告 + Web + 测试**

  改动文件：`/home/thomas/Workspace/el-chronos/el-chronos-analysis.el`、
  `/home/thomas/Workspace/el-chronos/el-chronos-report.el`、
  `/home/thomas/Workspace/el-chronos/el-chronos-web.el`、
  `/home/thomas/Workspace/el-chronos/test/el-chronos-analysis-test.el`、
  `/home/thomas/Workspace/el-chronos/test/el-chronos-report-test.el`、
  `/home/thomas/Workspace/el-chronos/test/el-chronos-web-test.el`

  步骤：① `el-chronos-analysis-drift-trend (RANGE &optional BUCKETS)` 按设计 6 落地；
  ② 报告「阻塞事件」节内加 drift 汇总行（含**「命令外」**口径与高估标注、无数据时的降级文案）；
  ③ Web 新增 `/api/drift` 路由 + 面板段（零第三方依赖，只读 GET，措辞统一「命令外漂移」）；
  ④ 更新 `el-chronos-web--routes` 的 docstring（17 → 18 条）。

  验收标准：`make check-parens` + `make lint` 全绿；新增**四个**用例 ——
  `drift-trend` 空库返回 plist（`:buckets` 为 nil 而非报错）；
  两小时各 1 行 fixture → 两个桶、`count-total` 求和正确、`max-ms` 取全局最大；
  **报告含 drift 汇总行**（`(el-chronos-report)` 生成的 org 内容匹配
  `命令外漂移.*次.*累计` 且含「高估」与「命令外」字样）；
  **Web `/api/drift` 返回合法 JSON**（复用 `el-chronos-web-test.el` 既有 loopback 辅助）。
  `make test` 全绿。
  （依赖：T2）

- [ ] **T4 文档同步 + 归档**

  改动文件：`/home/thomas/Workspace/el-chronos/docs/schema.org`、
  `/home/thomas/Workspace/el-chronos/docs/api.org`、
  `/home/thomas/Workspace/el-chronos/docs/architecture.org`、
  `/home/thomas/Workspace/el-chronos/docs/ui.org`、
  `/home/thomas/Workspace/el-chronos/docs/operations.org`、
  `/home/thomas/Workspace/el-chronos/AGENTS.md`、
  `/home/thomas/Workspace/el-chronos/CHANGELOG.md`、
  `/home/thomas/Workspace/el-chronos/Readme.org`、
  `/home/thomas/Workspace/el-chronos/openspec/tech-debt.md`

  步骤：逐份增量更新（**先读后写**，格式风格与既有结构一致，命令可复制执行）——
  · `docs/schema.org`：11 表、v3 DDL、`hourly_drift` 的 upsert 与保留分类、purge 11 表顺序；
  · `docs/api.org`：analysis 18 个查询、`-record-drift`、defcustom 20 → **21**；
  · `docs/architecture.org`：路径 3（心跳）改为「**结算后重置基线** + 三步判定」、
    偏移起点改为「上次心跳或命令结算中较晚者」、`hourly_drift` 作为第二落点且口径为
    **「命令外停转」**（与 `commands` 不可相加）、`block.command` 恒 nil 是正确行为、
    **明确记录 v3 前后 block 语义变化**（命令内 ≥2s 停转 v3 前会记 block、v3 后不会）、
    **已知偏差：连续命令流中的累计卡顿不可见**（分散在几十条 20–50ms 命令里的总卡顿，
    两档与 `slow_events` 都看不到，只有 `commands` 的时间戳密度能反映）、
    三处调用点（timer / `--pre-command` / `--finish`）的职责差异；
  · `docs/ui.org`：路由 17 → **18**、drift 面板/段落、报告节内汇总行（措辞「命令外漂移」）；
  · `docs/operations.org`：**调档指引**（含「drift 阈值必须 > 心跳间隔」）、保留表补
    `hourly_drift`、**block 语义变化与跨版本对比提示**、已知漏检面（设计 8 第 3 条）；
  · `AGENTS.md`：目录结构行数/用例数基线、已知边界新增一行「两档阈值 + 重置基线口径」
    （**不得与既有「阻塞提示默认静默」「采样归因口径」两行重复**）、隐私边界不变；
  · `CHANGELOG.md`：`[Unreleased]` 的 `### 新增` / `### 变更`（**心跳默认值 1s → 0.25s
  与 block 语义变化都是行为变更，必须显眼**；改既有用例的原因也要写明）；
  · `Readme.org`：用例数与能力概览；
  · `openspec/tech-debt.md`：**TD-11 状态更新**（③ 双记**已关闭**（方案 B 结构性消除）、
  ①② 已落地、④⑤ 保留），新增「GUI 心跳开销未实测」「drift 真实频率未知」
  「**连续命令流中的累计卡顿不可见**（方案 B 结构性损失）」「**命令边界钩子开销未实测**
  （`--pre-command` 补判是本项目第一次把判定放进命令边界热路径；实测结论 13 明确把
  『命令边界钩子（每条命令两次）』排除在测试范围外）」「`--pre-command` 补判只覆盖
  命令开始前（设计边界）」，**不改 TD-1～TD-19 的其它条目**。

  验收标准：`make full-check` + `make lint` 全绿；文档 grep 判据全部命中
  （`user_version=3`、`hourly_drift`、`el-chronos-drift-threshold-ms`、`0.25`、
  `命令外`、`调档`、`重置基线`）；`openspec/active/` 只剩 `.gitkeep`（本计划移入
  `openspec/completed/`）。
  （依赖：T1–T3 全部）

依赖关系汇总：**T2←T1；T3←T2；T4←全部**。

## 文档清单

| 产物 | 状态 |
|---|---|
| `docs/schema.org` | 需更新：表数 10 → 11、v3 迁移段、`hourly_drift` DDL 与 upsert（`MAX`）、保留分类、purge 11 表（T1 / T4） |
| `docs/api.org` | 需更新：analysis 17 → 18 个查询、store 新增 `el-chronos-store-record-drift`、defcustom 20 → 21（T2 / T3 / T4） |
| `docs/architecture.org` | 需更新：路径 3 改为「结算后重置基线 + 三步判定」、偏移起点改为「上次心跳或命令结算」、`hourly_drift` 落点与「命令外」口径、`block.command` 恒 nil 是正确行为、**v3 前后 block 语义变化**（T2 / T4） |
| `docs/ui.org` | 需更新：路由 17 → 18、报告「阻塞事件」节内的 drift 汇总行、Web 面板（T3 / T4） |
| `docs/operations.org` | 需更新：**调档指引**（两条 defcustom 的取值含义与硬约束）、保留策略表补 `hourly_drift`（永久）、**block 语义变化与跨版本对比提示**、未实测项与已知漏检面（T4） |
| `AGENTS.md` | 需更新：目录结构行数/用例数基线、已知边界新增「两档阈值与偏移口径」一行（T4） |
| `CHANGELOG.md` | 需更新：`[Unreleased]` 的 `### 新增` / `### 变更`（心跳默认值变更是行为变更）（T4） |
| `Readme.org` | 按需更新：用例数与能力概览（T4） |
| `openspec/tech-debt.md` | 需更新：TD-11（**③ 双记关闭**）、新增未实测项与已知漏检面（T4） |
| `openspec/decisions.md` | **已完成**（随 ADR-0005 一起写入，2026-10-25 一行） |
| `docs/adr/0005-two-tier-block-detection.md` | **已完成**（本计划的决策记录） |
| `el-chronos.el` / `-collect.el` / `-store.el` / `-analysis.el` / `-report.el` / `-web.el` | 需更新（T1–T3） |
| `test/` 5 个测试文件 | 需更新：新增 **26** 用例（T1 6 / T2 16 / T3 4） |

## 验证标准

| 级别 | 方法 | 通过判据 |
|---|---|---|
| L1 | `make check-parens` + `make lint`（`emacs -Q --batch`，不依赖 daemon） | 全绿、**零告警**（14 个文件逐个字节编译） |
| L2 | `make test` | 全绿、0 unexpected、0 skipped；基线 **200 用例**（若实施期漂移以当时实测为准），本计划预计新增 **26**（T1 6 / T2 16 / T3 4）→ 约 **226**（允许 ±2 偏差）；其中**必须**有：**「命令内 ≥2s 不记 block」（双记消除守门）**、**`finish-does-not-record-command-time`（`--finish` 不判定的硬守门）**、**`pre-command-resets-and-detects-pre-command-gap`（pre 补判）**、**`heartbeat-check-is-single-source-of-truth`（三处调用形态）**、**「`--pending-p` 兜底门」**、**v0/v1/v2 三条迁移守门用例**、抑制期间 drift 不记、命令外四档阈值、drift 不写 `slow_events`、只有 drift 待写时 flush 不早退、`--aggregates-pending-p` 纳入 drift、`--prune` 不动 `hourly_drift` |
| L3 | ① 端到端：真实 `(el-chronos-mode 1)`（**在隔离实例 / 临时 `user-emacs-directory` 下，不在用户主编辑器**）跑 ≥10 分钟，直查库确认 `hourly_drift` 有无行并按实际计数判断阈值是否合适；② **命令外停转注入**：必须用 `run-at-time` 回调（**不能**写在 `M-:` 的 `while` 里 —— `M-:` 是 `eval-expression` **命令**，忙等发生在命令内，会被基线重置切掉）：<br>`(run-at-time 0 nil (lambda () (let ((t0 (float-time))) (while (< (- (float-time) t0) 1.2)))))`<br>→ 断言 `hourly_drift` 的 `count` +1 且 `slow_events` 无新行；**反例**：把同样的忙等写成一条命令（如 `(progn (while ...) nil)` 走 M-x 执行）→ `hourly_drift` **不变**（命令内停转由 `commands` 独占）；③ **命令外**注入 2.5s（同样用 `run-at-time`）→ 断言 `slow_events(kind='block')` 新增 1 行且 `duration_ms` 落在 `[2500, 2750]`（高估上界 250ms 的实证）；**反例**：命令内 2.5s 忙等 → **不新增 block 行**（双记消除的端到端证据）；④ `PRAGMA user_version` = 3、`sqlite_master` 表计数 = 11；⑤ **抑制验证**：跑一次 `el-chronos-report` → 前后 `hourly_drift` 行数不变 | ①②③④⑤ 全部满足；③ 的区间判据是「高估上界 1s → 250ms」的唯一硬证据，**不得**改成「差不多 2.5s」；② 的反例与 ③ 的反例共同构成「命令内外分离」的硬证据 |

> L3 ①②③ 需要真实 timer 运行环境。**不得在用户主实例（`thomas`）上执行**：用户已明确拒绝
> 在主实例跑探针（会占用其正在使用的 Emacs）；一律走隔离实例（`elisp_mcp_set_task` 传
> `verify`）或 `emacs -Q --batch` + 临时库。

## 注意事项

1. **心跳是核心路径，任何改动都必须有「抑制期间 drift 不记」与「`--pending-p` 兜底」两条用例**
   （T2 验收项 D / C）。`el-chronos-collect--heartbeat` 在每个 mode 启用的 Emacs 上每 250ms
   跑一次，一次错误的判定逻辑会造成全库污染（每 250ms 一条记录）。
2. **drift 不记明细，不要「顺手」把它加进 `slow_events`**：这是 ADR-0005 备选③ 明确否决的
   做法（明细表膨胀 + 语义退化）。想「顺便留个痕迹」的下场是 `slow_events` 从重要事件簿
   变成噪声日志，`el-chronos-report--blocking-rows` 的 20 行展示区被亚秒级记录占满。
3. **250ms 心跳下 `--last-heartbeat` 的既有重置点必须仍然正确**：抑制宏的第 3 层
   （`unwind-protect` 清理段 `(setq el-chronos-collect--last-heartbeat (float-time))`）
   仍是「报告 / 请求耗时不被下一次心跳补算成阻塞」的**唯一有效手段**（第 1 层动态绑定在
   BODY 返回时已解除，第 2 层抬阈值也随之解除）。**新增的 `--finish` 重置替代不了它** ——
   渲染期间不会有命令结算。**不要**因为「多了一个重置点」就删掉抑制宏第 3 层。
4. **drift 判定与 block 判定必须同时落在两个门之内**（抑制门 `--suppress-block-p` +
   兜底门 `--pending-p`）：两档共用同一条判定路径，任何「只给 drift 加门」或「只给 block
   加门」的写法都会产生一个能被静默污染的档位。抑制宏**只补 docstring、不改 `let` 绑定**
   （抬 `block-threshold-ms` 对 drift 无效，因为 drift 在同一个 `unless` 之内，
   见 ADR-0005 D6）。
5. **`hourly_drift` 的语义是「命令外停转」**：命令内停转**不记 drift** —— 它在 `commands`
   表里有精确 `duration_ms`（且 ≥200ms 时已进 `slow_events(kind='command')`）。
   推论：**`hourly_drift` 的时长与 `commands` 的耗时不可相加、也不该相加**。
   文档、报告、UI 里若出现「总卡顿 = 慢命令 + block + drift」这种求和式，一律视为错误。
6. **`block.command` 恒为 nil 是正确行为，不要回填**：block 只记**命令外**停转，没有命令
   可归因。为了「字段有信息」去填上一条命令名，会把「命令外停转」误导成「某条命令内的停转」，
   读者会去 `commands` 里找一条并不慢的命令 —— 比留空更糟。
7. **重置基线的落点是 `--finish` 的固定一步**（设计 4.2）：`(let ((start ...) (name ...)
   (gc-start ...)))`（450–452）之后、清状态 `setq`（`el-chronos-collect.el:454–459`）**之前**。
   三个理由：贴住命令真实结束时刻（不吞掉结算开销之外的更多时间）、早于状态清空（结算
   期间心跳触发也不会把结算耗时算成 gap）、在 `when` 之外（`aborted` 与无主命令路径同样重置）。
**已知漏检面（方案 B 的固有代价，必须记入文档与 tech-debt）**：若「命令外停转结束」与
   「下一条命令结算」发生在同一轮事件循环里（主线程恢复后用户恰好有输入待处理），
   `--finish` 的重置会先发生 → 那段命令外停转**整段漏记**。这是「用重置换掉判据」的对价，
   概率取决于用户行为（卡顿结束后立刻按键）。可选缓解（**本期不做，留 tech-debt**）：
   在 `--finish` 重置**之前**先跑一次心跳判定（等价于「结算前补判一次」），代价是判定
   逻辑出现在两处、且需保证与兜底门的顺序一致。
8. **`--finish` 里绝对不要调 `el-chronos-collect--heartbeat-check`**：那里调 check 会让
   `gap` 恰好等于**刚执行完的命令时长** → 命令时长被记成 block/drift，**双记立刻复活**，
   方案 B 的全部价值归零。`--finish` 只做纯 `setq` 重置。三处调用点的职责见设计 4.3 的表，
   后来者若想「统一成一处调用」必须先推翻该表并重跑 T2 的
   `finish-does-not-record-command-time` 用例。
9. **`--pre-command` 的补判调用有固定位置**（设计 4.3.1）：`(--finish 'aborted)`（第 417 行）
   **之后**、`(if (null name) …)`（第 418 行）**之前**。放在 aborted 结算之前等于白跑
   （`--pending-p` 仍为 t，兜底门会跳过判定）；放在 `--command-start` 赋值之后则语义混乱。
   `aborted` 结算自身耗时（µs–ms 级）会被计入该次 `gap`，**明确接受**（远低于 500ms 阈值，
   且只在 C-g / 异常中断路径发生）。
10. **`--heartbeat-check` 必须自带 `condition-case`（I6 的硬要求）**：它现在会被
    `--pre-command` 调用，而**既有的 `--pre-command` 本身没有 `condition-case`**
    （`el-chronos-collect.el:378–431` 通读确认）—— 这是历史上第一个可能从
    `pre-command-hook` 向外抛错的调用点。一旦 check 抛错，`pre-command-hook` 会把异常
    抛进命令循环，**直接中断用户正在执行的命令**（比丢一条数据严重得多）。因此
    `condition-case` 要在 **check 内部**（不是留在 `--heartbeat` 薄壳里），且
    `--pre-command` 侧最好再包一层 `ignore-errors`（双保险，成本可忽略）。
11. **抑制验证必须在「无任何输入」的窗口内跑**：`--pre-command` 的补判在抑制期间也会
    **重置基线**（抑制门只跳过判定）。若在验证窗口里按了键，pre 会把基线推到按键时刻 →
    一次真实的抑制失效会被掩盖（**假阴性**）。T2 的 D 组与 L3 ⑤ 都必须在无人操作时执行。
12. **不引入任何第三方依赖**（I10 精神）：本计划用到的一切
   （`run-with-timer` / hash table / `sqlite` / `MAX` SQL 函数 / 纯 Lisp 忙等）全是内置。
13. **`el-chronos-heartbeat-seconds` 的 `:type` 已经是 `number`**（`el-chronos.el:85`），
   不需要「改为 `number`」这一步；只需改默认值与 docstring。新增的
   `el-chronos-drift-threshold-ms` 用 `natnum`（整数毫秒，I4）。
14. **阈值可调、文档必须给调档指引**（设计 8 的三条），且代码里**不做断言**、不做运行时
    校验 —— `el-chronos-drift-threshold-ms` 与心跳的硬约束（必须 > 心跳间隔）写在 docstring
    与 `docs/operations.org` 里，由用户在调档时自行遵守。
15. **迁移链是本计划最容易漏的点**（设计 7）：`from-version 1` 的库必须一次跑到 v3。
    只写 `(when (= from-version 2) ...)` 会让 1 号库「迁移成功但仍缺表」，
    而缺表的后果是 flush 静默失败（限流告警 + 丢本批）—— T1 的「v1 老库一次到 v3」
    用例就是这条的守门用例，**不得省略**。
    **同时注意 `--ensure-schema` 的交互**：它把 `user_version` **无条件**置为当前常量，
    所以 v0 分支结束后局部 `version` 必须同步为 `--schema-version`；若置成 1，
    后续 `(= version 1)` / `(= version 2)` 会立刻各跑一遍（幂等但语义混乱），
    若留在 0，末尾 pragma 会把已经是最新的库标成版本 0。三种结局的对比见设计 7。
16. **迁移的事务与备份顺序不可颠倒**：`.bak` 复制在 `BEGIN` **之前**、`ROLLBACK` 在
    `.bak` 覆盖**之前**（既有实现已如此，新增 v3 步骤必须沿用同一套顺序，不得把小步骤
    挪到 `condition-case` 之外）。
17. **改既有用例须在 `CHANGELOG.md` 说明原因**（表数与版本号断言从 10/2 变 11/3，
    属于计划内允许的同步修改）。
18. **本计划的代码片段只作设计说明**：实施时以真实函数签名为准（EE-1）—— 尤其
    `el-chronos-collect--finish` 的现有行序（450–459 行的 `let` 与 `setq` 位置）、
    `el-chronos-store--pending-p` / `--aggregates-pending-p` 的现有形态、
    `el-chronos-analysis--range-buckets` 的默认桶规则、`el-chronos-web--dispatch`
    的路由注册方式，都必须先读代码再落笔。
19. **L3 不得在用户主实例上跑**（用户已明确拒绝），一律走隔离实例或 `emacs -Q --batch` +
    临时 `user-emacs-directory`；本机 `http_proxy` 已设而 `no_proxy` 未设，Web 探活必须
    `curl --noproxy '*'` 或走 `ctx_execute` 的 `fetch`。
20. **命令外停转的注入只能用 `run-at-time` 回调**，不能写在 `M-:` 的 `while` 里 ——
    `M-:` 是 `eval-expression` **命令**，忙等落在命令内会被基线重置切掉，测出来的必然是
    「未检测到」的假结论（与实测结论 10 的「`sleep-for` 测不出阻塞」同类方法论陷阱）。
21. `grep --include` 必须加单引号（本机 shell glob 坑）；文档 grep 判据要能同时匹配中文与
    数字（避免「18 条」与「18条」的写法差异）。
