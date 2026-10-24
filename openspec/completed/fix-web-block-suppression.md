# 修复 TD-12：Web 请求处理纳入自观测抑制

## 当前状态
- 阶段：Phase 4（Review & Document）已完成，计划已归档
- 已确认：方案 ✅（用户 2026-10-24 确认）、计划 ✅（用户 2026-10-24 确认）、独立审查 ✅（plan-reviewer 两轮通过）
- 结果：TD-12 已关闭；`make check-parens` 全绿、`make test` 110 全绿（0 skipped）、`make lint` 零告警
- 提交：代码+测试见 `fix: Web 请求处理纳入自观测抑制（关闭 TD-12）`

## 目标

关闭技术债 TD-12：`el-chronos-web.el` 的请求处理未绑定 `el-chronos-collect--suppress-block-p`，Web 侧重查询（30 天趋势 + 火焰图 + 导出）在主线程同步执行期间会被 1s 心跳判为一条 `slow_events(kind="block")`，形成「观测器自伤」记录，与真实用户卡顿混淆。

## 设计

### 根因（已核实）

| 事实 | 证据 |
|---|---|
| 心跳用 `(bound-and-true-p el-chronos-collect--suppress-block-p)` 读判定 | `el-chronos-collect.el:484` —— 任何模块 `let` 绑定即生效，无需 collect 参与 |
| report 的三层抑制已实现且有测试 | `el-chronos-report.el:78-96`；`test/el-chronos-report-test.el:354` |
| web 全程无反抑制 | `el-chronos-web--handle-request`（`el-chronos-web.el:236`）无绑定 |
| 抑制第 3 层不可省 | 主线程被占期间心跳 timer 不运行，`let` 解除后才补跑、看到整段 gap；必须重置 `--last-heartbeat` 基线 |

### 决策：web 侧内联同款宏（方案 A，用户确认）

在 `el-chronos-web.el` 内新增四个定义（**不新增任何 require**）：

1. `(defvar el-chronos-collect--suppress-block-p nil "<docstring>")`
2. `(defvar el-chronos-collect--last-heartbeat nil "<docstring>")`
3. `(defconst el-chronos-web--suppress-block-threshold-ms 60000 "<docstring>")`
4. `(defmacro el-chronos-web--without-block-events (&rest BODY) ...)` —— 三层同款：
   - 绑定 `el-chronos-collect--suppress-block-p` 为 t
   - 把 `el-chronos-block-threshold-ms` 抬到 `el-chronos-web--suppress-block-threshold-ms`（60s）
   - `unwind-protect` 清理段把 `el-chronos-collect--last-heartbeat` 重设为 `(float-time)`

**为何不抽取共享宏（方案 B 被否）**：report 不 require collect 是既有有意设计（"与采集层的唯一接触点"），抽取公共宏会让 report 与 web 各新增 `(require 'el-chronos-collect)`，改变两处依赖图；本次是缺陷修复，不顺手重构依赖边界。重复约 12 行的风险由「两处 docstring 互相引用 + 端到端测试」兜住。

### 抑制范围

覆盖**整个** `el-chronos-web--handle-request`（解析 → dispatch → 构造响应 → `process-send-string`），而非只包 dispatch：响应序列化与发送同样占主线程。

### 测试设计

新增 1 个端到端用例 `el-chronos-web-test-suppresses-block-events`（放入 `test/el-chronos-web-test.el`）：
- 起真实 server（复用 `--with-server`），用 `cl-letf` 替换 `el-chronos-web--route-summary` 在体内记录 `el-chronos-collect--suppress-block-p` 与 `el-chronos-block-threshold-ms`
- 断言：体内抑制变量 = t、阈值 = 60000；请求返回 200；请求后抑制变量恢复 nil、阈值恢复 2000；`el-chronos-collect--last-heartbeat` 被重置到 ≈now（先把它设为 `(- (float-time) 10)` 再断言）

不新增「抑制期间心跳不记 block」的用例：该行为已有 `el-chronos-collect-test-heartbeat-suppressed-skips-block` 覆盖，重复无收益。

### 证据保留

`openspec/tech-debt.md` 的 TD-12 **保留编号与问题描述列**，只把处置列改为「已关闭」，便于追溯。

## 任务

- [x] **T1 代码：web 侧抑制宏与包裹**
  在 `el-chronos-web.el` 中：① 在变量区新增两个 `defvar` 声明（`el-chronos-collect--suppress-block-p` / `el-chronos-collect--last-heartbeat`，带 docstring 说明「与 collect 侧同名同义，仅声明避免 `void-variable`」）；② 新增 `el-chronos-web--suppress-block-threshold-ms`（60000，docstring 说明是抑制期阈值兜底）；③ 新增宏 `el-chronos-web--without-block-events`（三层机制逐条注释，docstring 注明「与 `el-chronos-report--without-block-events` 同款，改动需同步两处」）；④ 用它包住 `el-chronos-web--handle-request` 的整个函数体（`let` 结构改为宏包 `let` + `send-response`）。
  验收标准：`make check-parens` 通过；`emacs -Q --batch -L . -l el-chronos-web.el --eval '(princ "ok")'` 退出码 0；`grep -c "el-chronos-web--without-block-events" el-chronos-web.el` ≥ 2（定义 + 使用）；`grep -c "require 'el-chronos-collect\|require 'el-chronos-report" el-chronos-web.el` = 0（证明未新增依赖）。
  （依赖：无）

- [x] **T2 测试：端到端抑制用例**
  在 `test/el-chronos-web-test.el` 新增 `el-chronos-web-test-suppresses-block-events`，按「设计 → 测试设计」实现；用 `cl-letf` 替换 route 函数，断言抑制生效 / 阈值抬高 / 结束后恢复 / 基线重置。
  验收标准：`make test` → `Ran 110 tests, 110 results as expected, 0 unexpected`（109 + 1）；`make lint` 零告警；**反向验证**：临时把宏体里的 `(setq el-chronos-collect--last-heartbeat (float-time))` 删掉，确认该用例变红，再还原并确认 110 全绿。
  （依赖：T1）

- [x] **T3 文档同步**
  ① `openspec/tech-debt.md`：TD-12 处置列改为「**已关闭（2026-10-24）**：在 `el-chronos-web--handle-request` 外层复用 report 侧同款三层抑制（web 内联实现，避免新增 web→collect 依赖）；新增 `el-chronos-web-test-suppresses-block-events` 端到端断言。」（描述列不动）
  ② `docs/architecture.org`：自观测抑制节标题与正文改为「报告 / Web 自观测抑制」，补一段说明 Web 侧绑定点（`el-chronos-web--handle-request`）、与 report 的关系（两处内联实现，改动需同步）；同时把引用该节标题的两处改为新标题「报告 / Web 自观测抑制」：`AGENTS.md` 已知边界表的文档引用列、`docs/api.org` 的 `--last-heartbeat` 条目文末。
  ③ `docs/api.org`：`el-chronos-collect--suppress-block-p` 条目把「report 侧绑定」改为「report 与 web 侧各自绑定（两份内联实现）」；另外 `docs/api.org` 的 `el-chronos-collect--last-heartbeat` 条目现写「**跨模块写入点**有两个：report 侧……」，需改为「**跨模块写入点**有三个：report 侧、Web 侧（`el-chronos-web--without-block-events` 的清理段）以及 collect 心跳自身」。
  ④ `AGENTS.md` 已知边界表：把「**局限**：抑制覆盖面只有 report——**Web 侧未纳入抑制**（既有行为，见 TD-12）」改为「**覆盖面**：report 与 Web 均抑制（各自内联一份实现，改动需同步；TD-12 已关闭）」；
  ⑤ `docs/adr/0003-web-only-visualization.md`：在「实施结果」节补一句「后续修复：TD-12（Web 请求处理纳入自观测抑制）已关闭」；
  ⑥ `CHANGELOG.md`：`## [Unreleased]` 的第一个 `### 修复` 段**末尾**新增条目（Web 请求处理纳入抑制 + 用例 109→110）；并把**第二个** `### 修复` 段的全部条目**上移到第一个段末尾**、删除第二个段的标题行——**合并同名段，任何条目文字一字不改**。不要改名为「早期迭代」：该段 17 条绝大多数是现行代码修复（samples 口径 / flush / TD-9 / D1 / profiler 帧名 / 抑制层空转 / Web 500 等），贴「早期」标签会误导读者。
  ⑦ `AGENTS.md` 基线数字同步：① 「当前状态」段的「`make test` 109 用例全绿」→ 110；② 目录结构表 `test/el-chronos-web-test.el` 行「232 行 / 9 用例」→ 实测行数 + 「10 用例」；③ 「当前基线」段：109 → 110 用例、`Ran 110 tests, 110 results as expected, 0 unexpected`、分布中 web 9 → 10（其余不变）、测试文件总行数与「源码 7 模块 X 行 + 测试 7 文件 Y 行 = 合计 Z 行」用 `wc -l` **实测回填**；④ 全文 `grep -n "109"` 逐条核对，凡指用例数者一律改 110；⑤ `AGENTS.md` 目录结构表里 `el-chronos-web.el` 行「712 行（T9）」按 T1 改动后的 `wc -l` 实测回填（预期约 737 行，以实测为准）。
  ⑧ `Readme.org`：两处「109 用例」（约 L129 验证段、L140 当前状态）→ 110。
  验收标准：`grep -c "TD-12" openspec/tech-debt.md` ≥ 1 且该行含「已关闭」；`grep -c "抑制覆盖面只有 report\|Web 侧未纳入抑制" AGENTS.md` = 0；`grep -c "^### 修复$" CHANGELOG.md` = 1；`grep -cF "早期迭代" CHANGELOG.md` = 0（验证目标文件不含该标签，而非验证本计划文件的字面量）；`grep -c "TD-12" docs/adr/0003-web-only-visualization.md` ≥ 1；`grep -n "109" AGENTS.md Readme.org` 不得再出现指代用例数的 109（逐条核对并贴出）；`grep -c "110" AGENTS.md` ≥ 2。
  （依赖：T2）

- [x] **T4 全量验证、提交与归档**
  ① 全量验证：`make check-parens` / `make test`（110 全绿、0 skipped）/ `make lint`（零告警）；`emacs -Q --batch -L . -l el-chronos-web.el` 退出码 0；`grep -rn "el-chronos-web--without-block-events" --include='*.el' .` 命中 2 处；
  ② 提交（两次或一次均可，仓库风格：无 scope conventional commits + 中文）：代码+测试一次、文档一次，或合并为一次 `fix: Web 请求处理纳入自观测抑制（关闭 TD-12）`；
  ③ 计划归档：勾选全部 checkbox、更新「## 当前状态」为已完成、`git mv openspec/active/fix-web-block-suppression.md openspec/completed/`、确认 `openspec/active/` 只剩 `.gitkeep`；
  ④ AGENTS.md 末尾 active 说明同步（当前 active 为空）。
  验收标准：全部命令通过；提交后 `git status --porcelain` 为空；`ls -a openspec/active/` 只有 `.gitkeep`。
  （依赖：T3）

## 执行记录与偏差

| 项 | 计划 | 实际 | 原因 |
|---|---|---|---|
| T2 用例数 | 110 | 110 | 与预期一致（109 + 1） |
| T2 基线断言 | 基线设 now-10、阈值 +50 | 基线设 now-100、阈值 +50 秒，并加「body 内基线未变」断言 | 拉大差异远离计时噪声，并证明第 3 层只在清理段写 |
| T2 反向验证 | 整行删除 | 用净括号数相同的 `nil)))` 替换 | 整行删会破坏括号平衡，导致全部用例红，失去「只有目标用例红」的证明力 |
| T3 文档范围 | 9 处 | 10 处（补 `docs/operations.org` 技术债清单的 TD-12 迁移） | 该清单在 TD-12 关闭后失准 |
| CHANGELOG | 「改名早期迭代」 | 「合并两个 `### 修复` 段」 | 审查指出该段多数是现行修复，贴「早期」标签会误导 |
| 断链修复 | 计划未含 | `docs/architecture.org` §9 标题下加「原名」括注 | CHANGELOG 历史条目引用旧节名，改历史条目违背「不回改历史」 |

## 文档清单

| 产物 | 状态 |
|---|---|
| `el-chronos-web.el` | 需更新（T1） |
| `test/el-chronos-web-test.el` | 需更新（T2） |
| `openspec/tech-debt.md` | TD-12 关闭（T3） |
| `docs/architecture.org` | 抑制节改双形态（T3） |
| `docs/api.org` | 抑制变量条目（T3） |
| `AGENTS.md` | 已知边界表（T3）、基线数字与目录表行数（T3⑦）、active 说明（T4） |
| `Readme.org` | 用例数 109 → 110（T3） |
| `docs/adr/0003-web-only-visualization.md` | 补后续修复（T3） |
| `CHANGELOG.md` | 新增修复条目 + 消除同名段（T3） |
| `docs/ui.org` | 不需更新（性能注意节无抑制描述） |
| `docs/operations.org` | 不需更新（排障表无抑制条目） |
| `openspec/completed/el-chronos-core.md` | **不更新**（历史归档） |

## 验证标准

| 级别 | 方法 | 通过判据 |
|---|---|---|
| L1 | `make check-parens` + `make lint` | 全绿、零告警 |
| L2 | `make test` | `Ran 110 tests, 110 results as expected, 0 unexpected, 0 skipped` |
| L3 | ① 反向验证（删基线重置 → 用例变红 → 还原变绿）；② `emacs -Q --batch -l el-chronos-web.el` 加载成功；③ `grep -c "require 'el-chronos-collect" el-chronos-web.el` = 0（未新增依赖）；④ 文档 grep 判据见 T3 |

## 注意事项

1. 宏必须定义在 `el-chronos-web--handle-request` **之前**（字节编译期需宏已定义）。
2. 抑制范围覆盖整个 `--handle-request`（含 `process-send-string`），不是只包 dispatch。
3. 第 3 层（重置 `--last-heartbeat`）不可省 —— 否则解除抑制后补跑的那一次心跳照样把整段耗时记为阻塞。
4. 不改 `el-chronos-report.el`（其宏保持原样）；不改 `el-chronos-collect.el`（读取侧本来正确）。
5. `grep --include` 必须加单引号（本机 shell glob 坑）。
6. CHANGELOG 处理为**合并同名段**：把第二个 `### 修复` 段的条目整体上移到第一个段末尾、删掉第二个段的标题行；**任何条目文字一字不改**，也不要给该段贴「早期」之类标签。
7. 若 `make test` 数量不是 110，先诊断（用例是否未加载/多加载），不要改用例断言凑数。
