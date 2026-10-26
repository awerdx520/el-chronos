# el-chronos 观测能力收敛（不含 schema 变更）

## 当前状态

- 阶段：Phase 4（Review & Document）· **已完成并归档**（2026-10-26）
- 已确认：方案 ✅（用户 2026-10-26 确认）、计划 ✅（用户 2026-10-26 确认）、独立审查 ✅（复审通过：首轮 2 项 blocking 全部实质解决，未引入新矛盾）
- **范围排除**（保持）：GC 归因（`post-gc-hook` + 新表 + schema 迁移）不在本计划内——本计划**不改 schema、不加表、不做迁移**，已由 v4 改造独立完成资源维度
- 结果：**T1–T5 全部完成**（T1 / T2 由本移交落盘，T3 / T4 / T5 由本仓 v4 改造流程结清，见下「任务」段与「移交说明」）
- 最终基线：**304 用例全绿、lint 零告警、check-parens 通过**（`make full-check` 实测 `Ran 304 tests, 304 results as expected, 0 unexpected`）
- 归档时已知残留：**TD-26**（命令执行窗口内的采样栈未按命令边界切分——`slow_events.stack_json` 对 `kind='command'` 恒 NULL，`--current-stack` 保留但无生产调用者）、**TD-28**（`cpu_pct = 0` 的两义问题，与本计划的「数据诚实性」主题同源，需 schema v5）

## 目标

用 2026-10-26 那次真实 CPU 排查暴露出的三个缺陷，收敛本包的**归因能力**与**数据诚实性**。本包自身开销实测 0.02–0.2%（TD-3），不是 CPU 元凶，因此本计划**不以降低 CPU 为目标**。

### 缺陷来源（同一次排查的实测）

| 现象 | 实测证据 | 性质 |
|---|---|---|
| `slow_events(kind='command')` 的 `stack_json` 记录了无意义的自身帧 | 299/299 条全是 `el-chronos-collect--post-command → --finish → --safe-apply → --current-stack → backtrace-frames` | **数据不诚实**，会误导分析 |
| 缺「栈包含法」归因能力 | 该次排查的全部真结论来自手工 `substr(stack_json)` 观察；包内只有 self/total 口径，导致 ECA（真实成本 20.2% 栈包含）在 `package-breakdown` 里只显示 6.7% | **能力缺口** |
| `hourly_stacks` 的栈包含查询无入口 | 只能裸 SQL `instr()`，无 analysis 函数、无 report 小节 | 同上 |

## 设计

### T1 — `kind='command'` 的慢事件不再记录自身栈

**现状**：`el-chronos-collect.el:533-535` 在 `--post-command` 结算路径里调 `(el-chronos-collect--current-stack)`。此时栈顶必然是采集器自身（`--post-command → --finish → --safe-apply → --current-stack → backtrace-frames`），**不含任何被观测命令的信息**。

**改法**：`:stack` 改传 `nil`，与 `kind='block'` 的既有口径（TD-2 已定：block 的 `stack_json` 恒 NULL）对齐。在 `--finish` / `el-chronos-store-record-slow-event` 的 docstring 写明：

> 命令型慢事件的 `stack_json` 恒为 NULL。命令执行期间的栈无法在结算时刻事后取得（`--post-command` 时命令帧已弹出，栈顶是采集器自身），因此本字段对 command 类事件不携带信息，命令归属请查 `hourly_stacks` 同时段样本。

**为什么不是「改记命令窗口内的 top 采样栈」**：那需要把 `--accumulate` 的内存聚合按命令边界切分，改动面覆盖采集主循环；且会改变 `stack_json` 的既有语义（原本是「事件瞬间的栈」）。留作后续候选，不在本计划内。

**代价**：失去「慢命令有一个栈快照」的假象——但这本就是假象。真实性提升。

**受影响测试**：`test/el-chronos-collect-test.el:173` 的 `(should (listp (plist-get slow :stack)))` 仍会通过（`nil` 是合法 list），但须改为**显式断言 `(should-not (plist-get slow :stack))`**，否则该用例从「断言有栈」静默退化为「断言 nil 也算 list」，失去守门意义。

**`el-chronos-collect--current-stack` 的去留（审查新增）**：改动后该函数**失去唯一生产调用点**（原调用点就是本次要改的 collect.el:535）。决定：

- **保留函数与 `test/el-chronos-collect-test.el:691` 的归一化用例**，在 docstring 增补一句「当前无生产调用者，保留给『按命令窗口切分采样栈』的后续实现，亦用于栈归一化的单元测试」。
- 理由：删掉它会连带删掉唯一验证「栈归一化（nil 帧裁剪、JSON 序列化）」的用例，而该归一化逻辑仍被 `hourly_stacks` 路径使用；保留成本为零。
- 若将来确认不再需要，再按正常删除流程处理，不在本次计划内。

### T2 — 新增栈包含法归因（`el-chronos-analysis-inclusive-functions`）

**问题**：`el-chronos-analysis-top-functions` 是 self/total 口径。当某函数（如 ECA 的渲染回调）把成本记在被它调用的 built-in 帧上时，self 口径严重低估其真实影响面——本次实测 ECA 的 self 占比 6.7%，而栈包含法 20.2%，差 3 倍。

**设计**：新增函数，签名与返回形态对齐现有 analysis 函数（`--guard` / `--bounds` / `--select` / `--pct`）：

```elisp
(defun el-chronos-analysis-inclusive-functions (range &optional limit)
  "窗口 RANGE 内按「栈包含样本数」降序的函数列表。
元素 `(:function NAME :samples N :pct P :stacks K)'。
判据：`hourly_stacks.stack_json' 里出现该函数名（按 JSON 字符串引号边界精确匹配）。
`:pct' 分母是窗口内全部栈样本数（不受 LIMIT 截断）。")
```

实现要点：

1. **必须按 JSON 引号边界匹配**，不能裸 `instr(stack_json, name)`：否则 `eca-chat--viewing-bottom-p` 会误命中 `eca-chat--viewing-bottom-pos` 之类的同前缀函数。正确形态：`instr(stack_json, '"' || ?1 || '"')`。
2. 候选函数名来源：取窗口内 `hourly_functions` 的**全量 `function` 集**（`GROUP BY function` 本身已去重），**不得过滤 `samples > 0`**。
   - **这是审查指出的关键修正**：`top-functions` 的 docstring 已明确「只作为中间帧 / 根帧出现过的函数 `samples` 恒为 0」，而这类函数**正是在 `hourly_functions` 表里有行**的。包含法要找的恰恰是「自己不吃 CPU、但驱动了大量下游」的函数——它们的 `samples` 就是 0。若沿用 `samples > 0` 过滤，会把包含法的首要目标整体排除，与 T2 的动机自相矛盾。
   - 附带风险（必须写进用例）：现有验证目标 `eca-chat--viewing-bottom-p`（self 2.1%）与 `Automatic GC` **都有 `samples > 0`**，用它们验证会**假绿**。必须额外补一个 `samples = 0` 的中间帧函数作为验证样本。
3. 单次查询而非 N 次往返：用一条 `SELECT ?` + `sum(samples) ... GROUP BY` 形态，或一次取出 `(stack_json, samples)` 在 Lisp 侧统计。**优先 SQL 侧**（用 `instr`），但需实测查询耗时；若 > 200 ms 改为 Lisp 侧单次遍历。
4. 输出同时给 `:stacks`（涉及的不同栈条数），用于区分「少量栈但样本多」与「大量栈各贡献一点」。
5. **已知边界（写进 docstring）**：JSON 序列化会对函数名里的 `"` 与 `\` 做转义，此时 `instr(stack_json, '"' || name || '"')` 匹配失效。Elisp 符号名理论上允许这类字符，实际极少出现；本函数对这类函数**静默漏计**，须在 docstring 声明为已知边界，不得假装完备。

**验证判据**（三个样本，缺一不可）：

| 样本 | 期望 | 验证目的 |
|---|---|---|
| `eca-chat--viewing-bottom-p` | `:pct` ≈ **18–22%**（人工核对 20.2%） | 基本正确性（该函数 `samples > 0`，**单独用它验会假绿**） |
| `Automatic GC` | `:pct` ≈ **29.6%** | 单帧栈路径 |
| **一个 `samples = 0` 的中间帧函数**（实施时从真实库查，候选：`eca--handle-message` / `mapc` / `apply`） | `:pct` 显著 > 0 | **锁住「中间帧不得被过滤」这一修正**，是本次修订的核心守门 |

实施时先跑这条 SQL 找出合适的第三个样本：

```sql
SELECT function, sum(samples) s FROM hourly_functions
WHERE hour_ts >= (strftime('%s','now','-1 day')*1000)
GROUP BY function HAVING s = 0 ORDER BY function LIMIT 30;
```

（查出的名字再手工确认它确实出现在 `hourly_stacks.stack_json` 里，否则样本无意义。）

### T3 — report 暴露包含法（可选子任务）

在 `el-chronos-report.el` 的「热点函数」节后增加一小节「栈包含占比 TOP N」，直接消费 T2。若 report 结构改动超过 40 行则拆为独立任务，本计划只保证 T2 的函数可用。

## 任务

- [x] T1（已完成，未提交）：`el-chronos-collect.el` 的 `:stack` 改传 nil + docstring 说明 + `test/el-chronos-collect-test.el:173` 改为显式断言 nil
  - 验收：`make test` 全绿；新增/修改的用例能捕获「将来有人把 `--current-stack` 加回来」。
  - 依赖：无
- [x] T2（已完成，未提交）：`el-chronos-analysis.el` 新增 `el-chronos-analysis-inclusive-functions` + `test/el-chronos-analysis-test.el` 用例
  - 用例至少覆盖：① 引号边界（构造 `foo` 与 `foo-bar` 两栈，断言 `foo` 不误命中 `foo-bar`）；② 分母是全部栈样本（含未命中的）；③ LIMIT 不影响 `:pct`；④ 空库返回 nil；⑤ **`samples = 0` 的中间帧函数必须被计入**（构造一条栈，其非 leaf 帧函数在 `hourly_functions` 里 `samples = 0`，断言它出现在结果里）——这条锁住审查指出的核心缺陷，缺了它 T2 会假绿。
  - 验收：在 2026-10-26 真实数据上核对三个样本（见「验证判据」表）——`eca-chat--viewing-bottom-p` ≈ 18–22%、`Automatic GC` ≈ 29.6%、**外加一个 `samples = 0` 的中间帧函数且其 `:pct` 显著 > 0**（**需主实例只读打开库验证，不改库**）。
  - 依赖：无（与 T1 不同文件，可并行）
- [x] T3：`el-chronos-report.el` 增加「栈包含占比」小节
  - ✅ **已完成（由本仓 v4 流程完成，2026-10-26）**：落地为「热点函数」节内的 `** 栈包含占比 TOP` 子小节（`**` 级，**刻意不增节**——self 榜与包含榜的差异本身就是结论，两块表必须并排读），直接消费 T2 的 `el-chronos-analysis-inclusive-functions`；报告节数因此保持 15 节不变。`test/el-chronos-report-test.el` 有守门用例。
  - 依赖：T2
- [x] T4：文档——`docs/api.org`（新函数签名与语义）、`docs/architecture.org`（「采样归因口径」节补 `stack_json` 对 command 事件恒 NULL 的理由）、`CHANGELOG.md`、`openspec/tech-debt.md`（T1 的字段语义变更）
  - ✅ **已完成（由本仓 v4 流程完成，2026-10-26）**：五份 `docs/*.org` 全部同步——`docs/api.org`（新函数签名 / 返回形态 / 引号边界判据 / 三条已知边界）、`docs/architecture.org`（「采样归因口径」节补「命令型慢事件 `stack_json` 恒 NULL」的理由与替代路径）、`docs/schema.org`（`slow_events.stack_json` 补「kind='command' 时恒 NULL」）、`docs/ui.org`（报告子小节）、`docs/operations.org`；另同步 `AGENTS.md`（analysis 查询 18 → 21、已知边界行）、`CHANGELOG.md`（新增 / 变更两段）、`openspec/tech-debt.md`（TD-26 登记「命令窗口内的采样栈未按命令切分」）。
  - 依赖：T1–T3
- [x] T5：`make full-check` 全绿（当前 237 用例 + 新增）
  - ✅ **已完成（由本仓 v4 流程完成，2026-10-26）**：`make full-check` 实测 `Ran 304 tests, 304 results as expected, 0 unexpected`（0 skipped），`make lint` 17 个文件零告警，`make check-parens` 通过。

## 文档清单

| 文档 | 动作 |
|---|---|
| `docs/api.org` | 新增 `el-chronos-analysis-inclusive-functions` 签名、返回形态、引号边界判据 |
| `docs/architecture.org` | 「采样归因口径」节补：命令型慢事件 `stack_json` 恒 NULL 的理由与替代路径 |
| `docs/schema.org` | `slow_events.stack_json` 字段说明补「kind='command' 时恒 NULL」 |
| `CHANGELOG.md` | 记录 T1 的字段语义变更（**行为变更，需标注**） |
| `openspec/tech-debt.md` | 登记「命令窗口内的采样栈未按命令切分」为后续候选 |
| `AGENTS.md` | 若新增不变量（如「禁止在结算时刻取栈」）则同步 |
| `test/` | T1 断言改造、T2 新增用例 |

## 验证标准

| 级别 | 方法 |
|---|---|
| L1 | `make check-parens`（若 Makefile 有此目标） |
| L2 | `make test`（ERT 全量，当前 237 用例） |
| L3 | `make full-check`；并在主实例**只读**打开真实库验证 T2 的数值判据 |

**禁止**：任何写库操作。真实库验证必须 `sqlite3 -readonly "file:...?mode=ro"`，或只通过 analysis 函数读取。

## 注意事项

1. **不改 schema**：本计划零迁移、零新表。用户明确 el-chronos 正在改造并以 v4 定稿，任何 DDL 改动都必须等那次改造完成后并入。
2. **T1 是行为变更**：`stack_json` 从「有值但无意义」变为「恒 NULL」。任何消费该字段的外部脚本会看到差异，必须在 CHANGELOG 标注。
3. **T2 的 SQL 性能必须实测**：`instr` 在 `hourly_stacks`（每小时 × 会话 × top-200 行）上做全表扫描，数据积累后可能变慢。若 > 200 ms，改 Lisp 侧单次遍历或考虑在 `analysis--bounds` 内加时间窗约束。
4. **不要动 TD-2 / TD-11 已关闭的口径**：block 事件的 `stack_json` 恒 NULL、drift 与 commands 不可相加，这些是刚收敛的结论，不得顺手「统一」。
5. **T2 的函数命名与既有风格一致**：`el-chronos-analysis-<动词>-<对象>`，返回 plist 列表，走 `--guard` 包装（异常时返回 nil 而非抛出）。
6. **测试用数据要自造**：用例不得依赖真实库内容（既有测试风格如此），真实库只用于 T2 的数值核对。

## 审查处置

独立审查（plan-reviewer）首轮结论：**不通过**，2 项 blocking。逐条处置：

| 编号 | 审查意见 | 处置 |
|---|---|---|
| P1-4 | 候选集 `samples > 0` 过滤会整体排除「中间帧驱动函数」——恰是包含法的首要目标；且现有验证样本都 `samples > 0`，会假绿 | **采纳**：候选集改全量（B3），验证判据补 `samples = 0` 样本（B4） |
| P1-3 | `el-chronos-collect--current-stack` 改动后成 dead code，去留未定 | **采纳**：保留函数与归一化用例，docstring 注明「无生产调用者、保留给按命令切分采样栈」（B2） |
| P1-4（minor） | 函数名含引号/反斜杠时 `instr` 边界匹配失效 | **采纳**：docstring 声明为已知边界（B5） |
| P0-2 / P2-* | （属主计划） | 见 A 的修订 |

## 移交说明（2026-10-26，交给 el-chronos v4 改造流程）

### 为什么移交

用户指示：本仓正在并行改造（定稿 v4），不宜由外部流程继续叠加改动。故把本计划已完成部分与剩余待办整体移交本仓改造流程。**thomas-emacs 侧从此不再改动 el-chronos 的任何文件。**

### 已完成（改动已在工作区落盘，未提交）

| 文件 | 改动 |
|---|---|
| `el-chronos-collect.el` | ① `--current-stack` docstring 增补 4 行（标注当前无生产调用者、保留理由）；② `--finish` docstring 增补 7 行（命令型 stack 恒 NULL 的完整理由）；③ 慢事件记录点 `:stack (el-chronos-collect--current-stack)` → `:stack nil` + 3 行注释 |
| `test/el-chronos-collect-test.el` | ① `el-chronos-collect-test-finish-aborted-slow-command` 的 docstring 增补 1 行（「恒 nil 是设计」）；② `(should (listp (plist-get slow :stack)))` → `(should-not (plist-get slow :stack))` + 3 行注释 |
| `el-chronos-analysis.el` | 新增 `el-chronos-analysis-inclusive-functions`（约 103 行，含完整 docstring 与三条已知边界）；文件头 `;;; Commentary` 的「百分比口径」段补一句 |
| `test/el-chronos-analysis-test.el` | 新增 6 条用例（引号边界 / 分母 / LIMIT 不变性 / 空库 / **samples=0 中间帧** / 同栈同名帧去重） |

### 验证结论（接手方需复验，因并发改动可能已改变基线）

- `el-chronos-collect-test.el` 定向 selector（`finish|frame-name|stack|slow-event|accumulate`）：**14/14 通过**
- 全量 `make test`：T1 完成时 **261/261**；T2 完成时 **280/280**
  - 期间并发改动者新增用例时曾短暂出现 5 条失败，全部落在其新功能 `--collect-resources` / `--startup-take-probe`，与本移交内容无关
- `make check-parens` 通过；`make lint` 零告警

### T2 的三条实现要点（后续维护**不要**「优化」掉）

1. **候选集不得加 `samples > 0` 过滤**：只作为中间帧出现的函数 `samples` 恒为 0，而它们正是包含法的首要目标（这正是首轮审查的 blocking 项）。
2. **候选集不得按数量截断**：匹配成本与候选数无关（候选只进哈希表），截断只引入静默漏计。
3. **匹配按 JSON 双引号字段整名相等**，不是子串匹配——否则 `foo` 会命中 `foo-bar`。

性能实测（真实库 1 天窗口，3305 栈行 / 467,820 样本 / 3897 候选）：

| 方案 | 耗时 | 结论 |
|---|---|---|
| 单条 JOIN + `instr` 边界 | **24,500 ms** | 弃用 |
| 逐候选 `string-search` | 268 ms | 可用但慢 |
| 逐候选 `string-match-p` + `regexp-quote` | 737 ms | 弃用 |
| **采用：Lisp 单遍扫描栈文本** | **29 ms（字节编译）/ 60 ms（解释）** | 采用 |

分量：取栈 16 ms + 取候选 7.8 ms + 单遍匹配 17–25 ms。

### T2 修掉的一个真 bug（务必保留其守门用例）

同一栈内同名帧（递归 / advice 链 / 同名闭包归一）曾被按出现次数重复累加，导致 `apply` 虚高 128,530 vs 真值 109,982，极端情况 `:pct` 可超过 100%。已改为按栈去重（`delete-dups`），并补第 6 条用例 `el-chronos-analysis-test-inclusive-frames-deduped` 锁住。

### 待办（由本仓 v4 流程处理）

> **以上待办已于 2026-10-26 全部完成**（下列条目保留为历史记录，完成情况逐条标注）。

1. **report 小节**：`el-chronos-report.el` 增加「栈包含占比 TOP N」，消费新函数
2. **文档同步**：
   - `docs/api.org`：新函数签名、返回形态、引号边界判据、三条已知边界
   - `docs/architecture.org`「采样归因口径」：补「命令型慢事件 `stack_json` 恒 NULL」的理由与替代路径（查 `hourly_stacks` 同时段）
   - `docs/schema.org`：`slow_events.stack_json` 补「kind='command' 时恒 NULL」
   - `AGENTS.md`：「analysis **18** 个只读聚合查询」→ **19**
3. **CHANGELOG**：标注 `stack_json` 行为变更（从「有值但无意义」→「恒 NULL」）；任何消费该字段的外部脚本会看到差异
4. **tech-debt 登记**：「命令执行窗口内的采样栈未按命令切分」为后续候选（当前 `--current-stack` 保留但无生产调用者，理由见其 docstring）
5. **`make full-check`**：必须在并发改动稳定后跑一次全量
6. **决策项**：新函数是否接入 Web 路由 / org 报告（当前仅 analysis 层可用）

### 交接时的环境事实（接手方必读）

1. **工作区在本次改动入场时已不干净**：`M el-chronos-collect.el`（211 行他人改动）、`M el-chronos-store.el`、`M openspec/decisions.md`、`M test/el-chronos-store-test.el`；未跟踪：`el-chronos-startup-probe.el`、`test/el-chronos-startup-probe-test.el`、`docs/adr/0006-resource-observation.md`、`openspec/active/startup-probe-and-resources.md`。**合入前必须确认这些在途改动与本移交内容无重叠**，重点核对 `--finish` 函数体与 `el-chronos-analysis.el` 的文件尾。

   **移交收尾时的实际快照**（`git status --porcelain`，分支 `master`，`git diff --cached --name-only` 为空 → 全部改动停在 `git add` 之前）：

   - **已修改 8 项**：`el-chronos-analysis.el`、`el-chronos-collect.el`、`el-chronos-store.el`、`el-chronos.el`、`openspec/decisions.md`、`test/el-chronos-analysis-test.el`、`test/el-chronos-collect-test.el`、`test/el-chronos-store-test.el`
   - **未跟踪 8 项**：`chrOFfdW2/`、`chrY5JRkK/`、`el-chronos-web-test-yfbW05/`（三个疑似 Web 测试残留目录）、`docs/adr/0006-resource-observation.md`、`el-chronos-startup-probe.el`、`test/el-chronos-startup-probe-test.el`、`openspec/active/startup-probe-and-resources.md`、**`openspec/active/2026-10-26-compact-observability.md`（本计划文件自身也尚未纳入 git）**
   - **归属**：`analysis` / `analysis-test` / `collect` / `collect-test` 四项中含**本移交**的改动；`el-chronos.el` / `store.el` / `store-test` / `decisions.md`、三个临时目录、`startup-probe*`、`adr/0006` 属**并发改动者**。
   - **待清理**：三个 `chr*` / `el-chronos-web-test-*` 目录是测试残留，建议由接手方确认后删除（本移交未触碰）。
2. **`git checkout -- <file>` 是破坏性操作**：本次改动与在途改动同处几个文件，安全点用快照（`cp` 或 `git stash create`），不要用 `git checkout --` 回滚。
3. **基线数值已漂移（重要）**：本次排查的原始参照（`eca-chat--viewing-bottom-p` 栈包含 20.2%、`Automatic GC` 29.6%）来自**已失效的数据快照**。当前库（1 天窗口，480,036 栈样本）同口径实测为 **5.26% / 34.26%**，且**绝对值也下降**（58,786 → 25,249），说明旧数据已不在库中。新函数的实现本身与独立 `instr` SQL **逐条吻合**（25,249 / 164,439 / 11,429 三个样本全等），故这是环境变化，**不是实现缺陷**。任何用旧数字做验收的做法都会误判。
4. **全部改动未提交**：停在 `git add` 之前，由接手方按其提交流程处理。
