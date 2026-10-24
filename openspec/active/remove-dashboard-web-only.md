# 移除 dashboard，只保留 Web 形态可视化

## 当前状态
- 阶段：Phase 3（Implement）· 进行中
- 已确认：方案 ✅（用户 2026-10-24 确认）、计划 ✅（用户 2026-10-24 确认）、独立审查 ✅（plan-reviewer 2026-10-24 通过；经 3 轮修订，4 个 blocking 全部消除）
- 下一步：T1 → T2 → T2b → T3/T4/T5 并行 → T6 → T7 全量验证与归档

## 目标

删除 `el-chronos-dashboard.el`（1382 行：ETAF 组件树 + tabulated-list 降级页），把可视化收敛为**两形态**（浏览器 Web dashboard + org 报告），并同步清除 ETAF 软依赖、dashboard 专属测试、文档引用、不变量条目与技术债，使仓库**无悬挂引用、无自相矛盾的文档**。

## 设计

### 已核实的依赖事实（Phase 1 探索结论）

| 事实 | 证据 |
|---|---|
| 无任何非测试模块 `require` dashboard | 全仓 `require 'el-chronos-` 清单 |
| dashboard 单向依赖 `analysis` + `report`（用 `el-chronos-show-event`） | dashboard.el:56–57 |
| `el-chronos-show-event` 唯一内部调用者是 dashboard | dashboard.el:1316；定义在 report.el:457 |
| web 模块与 web 测试不依赖 dashboard | web.el 只 require analysis；ui-test 的 9 个 web 用例不碰 dashboard 夹具 |
| ETAF **可视化依赖**只有 dashboard 一个使用点；但 `etaf` 字样另有合法出现 | ① 可视化：dashboard.el + ui-test 的 declare-function + 文档；② **与 ETAF 无关**：`el-chronos-attrib.el:72` 的 `.eln` 文件名示例 `etaf-runtime-….eln`、`test/el-chronos-attrib-test.el:109–179` 的 eln 归因 fixture（包名示例）；③ **过时注释**：`analysis.el:12`、`collect.el:655/673/675` |
| Makefile 自动发现文件 | `find` + `$(wildcard test/*-test.el)`，删文件无需改 Makefile |
| `openspec/active/` 原为空 | 无停滞计划需处置 |

### **五项已确认裁决**（用户 2026-10-24 确认）

| # | 裁决 | 说明 |
|---|---|---|
| 1 | **删除** `docs/ui.org` 的「ETAF 实测踩坑清单」（10 条，约 84 行） | 本仓库已无 ETAF 代码，保留无实现对应的清单违背「文档与代码同步」；不迁移跨仓库 |
| 2 | **保留** `el-chronos-show-event`（report 模块公共命令） | `M-x` 可用、`docs/api.org` 已记录、对阻塞事件下钻有独立价值；只删 dashboard 内的调用点 |
| 3 | 测试文件**重命名** `test/el-chronos-ui-test.el` → `test/el-chronos-web-test.el` | 内容只剩 web，名字需名实相符；Makefile 自动发现不受影响 |
| 4 | 历史工件**保留原文** | `docs/adr/0002` 标 `Superseded by ADR-0003`；`openspec/completed/el-chronos-core.md` 一字不改（历史记录）；新增 `docs/adr/0003-web-only-visualization.md` 记录变更 |
| 5 | `docs/adr/0001-observer-architecture.md` **保留原文** | 其「技术债」清单是 2026-10-24 的时点快照，属历史记录；TD-5 关闭由 ADR-0003 与 `openspec/tech-debt.md` 承载，不回改历史 ADR |

### 不变量改写（关键架构决策）

| 不变量 | 现状 | 改写为 |
|---|---|---|
| I9 | dashboard 对 ETAF 软依赖、缺失时降级 tabulated-list | **ETAF 已完全移除；可视化层不引入 ETAF（防止回潮）** |
| I11 | 不可用必须可见降级（ETAF→tabulated-list、SVG→文本条形、端口占用→报错） | 去掉前两个子项，保留「端口占用 → 明确报错，不得静默失败」 |
| I8 / I10 | Web 只绑 loopback / 资源内嵌无 CDN | **不变**（仍有效） |

保留 I9/I11 编号而非重编号：避免全文 `I8–I11` 引用连锁改动。

### 预期量化结果

- 源码模块 8 → 7；源码行数 8289 → 约 6907（减 1382）
- ERT 用例 131 → **109**：删 24 个 dashboard 用例、**补 2 个** `el-chronos-show-event` 用例（该命令保留，删除 dashboard 后原本唯一的覆盖来自被删用例）
- 用例分布预期：report 24（22+2）/ web 9 / collect 26 / analysis 15 / store 14 / attrib 21 = 109；原唯一 skip 随 dashboard 删除而消失，预期 `0 skipped`
- `make lint` 目标文件 15 → 14，且不再需要在 ETAF 缺席环境下处理宏软依赖
- `openspec/tech-debt.md` TD-5（ETAF 重绘性能实测）失去测量对象 → 关闭

## 任务

- [ ] **T1 代码层：删除 dashboard 模块 + 清理采集层交叉引用**
  删除 `el-chronos-dashboard.el`；修改 `el-chronos-collect.el` 三处文案：① `el-chronos-collect--suppress-block-p` 的 docstring（约 193–201 行）把「由 `el-chronos-report` 与 `el-chronos-dashboard` 在渲染期间 `let` 绑定」改为只提 `el-chronos-report`，并把「两个可视化模块各自 `defvar` 同名声明」改为「report 侧 `defvar` 同名声明」；② 约 152 行「出现在报告与 dashboard 里」→「出现在报告与 Web 页面里」；③ 约 162 行「报告 / dashboard 里可查」→「报告 / Web 页面里可查」。④ `el-chronos-analysis.el:12`「供 org 报告（T7）、ETAF 页面（T8）、Web API（T9）三方共用」→「供 org 报告（T7）、Web API（T9）两方共用」；⑤ `el-chronos-collect.el:655` 的 `--internal-buffer-p` docstring「这类 buffer（ETAF 挂载用的 ` *work*`、`with-temp-buffer` 的临时 buffer 等）」→「这类 buffer（渲染层挂载用的 ` *work*`、`with-temp-buffer` 的临时 buffer 等）」；⑥ `el-chronos-collect.el:673`「跳过**内部 buffer**（名字以空格开头，见 `--internal-buffer-p`）：ETAF 挂载、`with-temp-buffer` 等每次渲染都会新建这类 buffer」→ 去掉「ETAF 挂载、」，把 `el-chronos-collect.el:674` 的「（「打开 dashboard 要碰全部 buffer」的观感来源）」改为「（「每次渲染要碰全部 buffer」的观感来源）」。
  验收标准：`grep -rn "el-chronos-dashboard" --include=*.el /home/thomas/Workspace/el-chronos` 只剩 `test/el-chronos-ui-test.el`（T2 再清）；`emacs -Q --batch -L /home/thomas/Workspace/el-chronos -l el-chronos-web.el --eval '(princ "loaded ok")'` 退出码 0；并确认 `grep -rn "ETAF\|dashboard" --include=*.el /home/thomas/Workspace/el-chronos` 的剩余命中只有四类：① `test/el-chronos-ui-test.el`（T2 再清）；② `el-chronos-attrib.el:72` 与 `test/el-chronos-attrib-test.el:109–179` 的 `etaf-runtime` 归因示例（白名单，`.eln` 文件名与包名 fixture，与 ETAF 可视化无关）；③ `el-chronos.el:137/143` 的「Web dashboard」defcustom docstring 文案（白名单，Web 形态保留，必须保留）；④ `el-chronos-collect.el:99` 的 `dashboard-mode`（白名单，第三方 Emacs dashboard 包的 major-mode 名，属命令名归一的实测数据注释，与本模块 dashboard 无关）。
  （依赖：无）

- [ ] **T2 测试层：删除 dashboard 用例并重命名测试文件**
  在 `test/el-chronos-ui-test.el` 中按**节标题**定位（不要依赖固定行号）：删除「;;; dashboard：形态与内容（降级路径）」「;;; dashboard：`d` 键回归」「;;; dashboard：每页行数上限与重复打开不增长」「;;; dashboard 宽度策略与主题配色」四整节（共 24 个 `ert-deftest`）；删除 dashboard 专用夹具与辅助 `el-chronos-ui-test--with-fallback`、`el-chronos-ui-test--insert-block-event`、`el-chronos-ui-test--count-block-events`、`el-chronos-ui-test--event-buffer-name`、`(require 'el-chronos-dashboard)`，以及 `declare-function etaf-mount/-unmount/-runtime-for-buffer` 与 `ebox-buffer-mount/-mount-root/-node-children/-node-geometry/-node-classes` 共 8 行；**另外删除 `el-chronos-ui-test--walk-nodes` 辅助函数**（依赖 `ebox-node-children`，仅被 `dashboard-render-no-truncation` 用例调用，残留会导致 `make lint` 告警）；保留 9 个 web 用例与 `--with-temp-db` / `--with-server` / `--http` / `--parse-response` / `--json`；文件头注释改为「可视化层测试（内嵌 Web）」；最后 `git mv test/el-chronos-ui-test.el test/el-chronos-web-test.el`。
  验收标准：`make test` 输出 `Ran 107 tests, 107 results as expected, 0 unexpected, 0 skipped`（T2b 补 2 个用例后升到 109）；`make lint` 零告警；`grep -rn "dashboard" test/` 零命中；`grep -rn "etaf" test/` 仅剩 `test/el-chronos-attrib-test.el` 的 `etaf-runtime` 归因 fixture（白名单：那是 `.eln` 文件名示例，与 ETAF 可视化无关，不得删除）。
  （依赖：T1）

- [ ] **T2b 补测试：`el-chronos-show-event` 的覆盖**
  该命令保留在 `el-chronos-report.el`（公共 interactive 命令，`docs/api.org` 有记录），但其现有测试覆盖只来自被删的 dashboard 用例（`ui-test.el` 的 `dashboard-show-event-blocker` / `-requires-blocker`）。在 `test/el-chronos-report-test.el` 末尾（`;;; Web：500 分支与端口显示` 节之前或文件末尾均可）新增 2 个用例：① 事件存在 → `el-chronos-show-event` 渲染出 `*el-chronos-event*` buffer，内容包含 fixture 栈帧名；② 事件 id 不存在 → 抛 `user-error`。fixture 用 `el-chronos-test--insert-slow-event`（test-helper.el:130，插入后**不返回 id**），随后用 `el-chronos-test--scalar "SELECT last_insert_rowid()"` 取事件 id（report-test.el:90 已有同类用法）；`el-chronos-show-event` 的签名是 `(ID)`，事件不存在时需断言 `user-error`（核对 report.el:457 的实际行为再写断言）。
  验收标准：`make test` 总数由 107 变 **109**（这 2 个用例计入 T2 之后的基线）；两个用例名不以 `dashboard` 开头（用 `el-chronos-report-test-show-event-*`）；`make lint` 零告警。
  （依赖：T2）

- [ ] **T3 用户文档同步：Readme.org + CHANGELOG.md**
  `Readme.org`：删「可选：装 ETAF（要 Emacs 内可视化页面时）」整节；「使用（三种形态）」→「使用（两种形态）」并删 Emacs 内页面表格行；「常用快捷键（页面 buffer 内）」段落删除；「三种形态的约束一致」→「两种形态的约束一致」并删 ETAF 降级子项；依赖表删「Emacs 内页面」行；「当前状态」删 ETAF 页面字样并更新用例数；「它回答的 6 条目标」第 6 条改「两种形态：org 报告 / 浏览器 Web dashboard」。另外：「当前状态」节把「ETAF 页面」字样删除、把「ERT 103 用例」更新为「ERT 109 用例」；「技术债」那条删掉「仍待实测项：**ETAF 重绘性能 TD-5**」（保留 TD-7、TD-11）；「决策」那行去掉「ADR-0002 双形态可视化」或改指 ADR-0003（二选一，取更简单的一处改动），并把 ADR-0003 加入链接列表。
  `CHANGELOG.md`：在 `## [Unreleased]` 下新增 `### 移除` 段，记录：删除 `el-chronos-dashboard.el`（1382 行）与 ETAF 软依赖、5 个 dashboard defcustom（`page-size` / `max-rows` / `chart-points` / `chart-width` / `refresh-seconds`，已核实 dashboard.el:144/150/156/158/160）、24 个 ERT 用例、I9/I11 改写、测试文件更名为 `test/el-chronos-web-test.el`、技术债 TD-5 关闭。**历史条目一字不改**。
  验收标准：`grep -n "dashboard\|etaf\|ETAF" Readme.org` 仅剩 Web dashboard 相关表述；CHANGELOG 新增段存在且历史段未变。
  （依赖：T2）

- [ ] **T4 技术文档同步：docs/ui.org + api.org + architecture.org + operations.org**
  `docs/ui.org`：删「ETAF 页面（`M-x el-chronos-dashboard`）」整节（含组件树、10 项能力、快捷键、主题配色、宽度策略、降级规则、ETAF 实测踩坑清单）；「三形态总览」→「两形态总览」；「性能注意」节删 ETAF 重绘相关段与外链引用；「关联」节去掉 ETAF/ADR-0002 双形态表述。
  `docs/api.org`：概览「8 个模块」→「7 个模块」并删页面模块表格行；删「页面模块（`el-chronos-dashboard.el`）」整节（命令、可测纯函数、defcustom 三张表）；「内部函数约定」「关联」节去 dashboard 引用。
  `docs/architecture.org`：分层表删「可视化 dashboard」行；「数据流」句改为「report / web（两种呈现形态）」；重写「可视化数据流」节（删 Emacs 侧 ETAF 段，保留公共前半段 + Web 侧）；「降级矩阵（I11）」删 ETAF 行；「实测结论 9」把「报告生成 / dashboard 渲染」改成只提报告生成，并删 `el-chronos-dashboard--without-block-events` 表述（保留 report 侧三层防护描述）；「已知偏差」表中 dashboard 表格标题那条改为只提 Web/报告口径；「待补」节删 ETAF 性能与 dashboard 每页行数相关行。
  `docs/operations.org`：依赖表删 ETAF 行；删「方式 C：需要 Emacs 内 ETAF 页面时（软依赖）」整节；排障表删「`*el-chronos*` 页面显示表格而非卡片」「`make lint` 报 `void-function etaf-view`」两行；验证步骤删「`M-x el-chronos-dashboard` → 页面可见…」一行；文末参考列表去掉「ETAF 踩坑」字样。
  验收标准：四个文件 `grep -c "el-chronos-dashboard"` 均为 0；`grep -n "ETAF" docs/*.org` 零命中；`grep -n "dashboard" docs/ui.org docs/api.org docs/architecture.org docs/operations.org` 的剩余命中**只能是「Web dashboard」这一合法表述**（不得残留「dashboard 侧」「打开 dashboard」这类指代 Emacs 页面的写法）。
  （依赖：T2）

- [ ] **T5 决策工件：ADR + decisions.md + tech-debt.md**
  新增 `docs/adr/0003-web-only-visualization.md`：状态 Accepted、日期 2026-10-24；背景（dashboard 的成本：ETAF 软依赖 + 双渲染路径 + 10 条踩坑 + 内存/重绘风险 TD-5 + 24 用例）；决策（只保留 Web + org 报告两形态，删除 dashboard 模块与 ETAF 依赖）；后果（正/负）；被否决替代方案表（保留 dashboard 双形态、保留 dashboard 但不再维护、把 ETAF 知识迁到本仓库附录）；关联 ADR-0002（Superseded）。
  `docs/adr/0002-dual-visualization.md`：仅改标题下「状态」行为 `**状态**：Superseded by ADR-0003（2026-10-24）`，正文一字不改。
  `docs/adr/0001-observer-architecture.md`：**保留原文不改**（其「技术债」清单是时点快照，TD-5 的关闭由 ADR-0003 与 `tech-debt.md` 承载）；在 ADR-0003 的「关联」节注明这一点。
  `openspec/decisions.md`：新增一行 `| 2026-10-24 | 可视化收敛为两形态（Web dashboard + org 报告），删除 dashboard 模块与 ETAF 软依赖 | dashboard 与 Web 能力重叠但独占总维护成本（软依赖、双渲染路、10 条踩坑、TD-5 内存/重绘风险、24 个用例）；Web 已覆盖全部只读查看需求 | ADR-0003、I8–I11 改写 |` 新增行关联列写「ADR-0003、I8–I11 改写（I 编号不变，I9/I11 语义见 `AGENTS.md` 不变量清单）」；原「双形态可视化」决策行**保留为历史记录**，不回改。
  `openspec/tech-debt.md`：TD-5 行改为 `**已关闭（2026-10-24）**：dashboard 模块已删除，ETAF 重绘性能不再有测量对象（见 ADR-0003）`；TD-11 的描述里「④ GUI 侧用真实 frame 复测 redisplay 阻塞（可并入 TD-5 的 ETAF 性能实测）」改为「④ GUI 侧用真实 frame 复测 redisplay 阻塞（原计划并入 TD-5，TD-5 已随 dashboard 下线关闭）」，其余 TD 行不动。
  验收标准：三个 ADR 文件存在且状态正确；`decisions.md` 新增行在表内；`tech-debt.md` 中 TD-5 标注已关闭且无残留「T8 完成后…实测」的未完成措辞。
  （依赖：T2）

- [ ] **T6 AGENTS.md 全量同步（含实测基线回填）**
  项目概述：8 个源码模块 → 7 个；「ETAF 可视化页面」相关描述删除。目录结构表：删 `el-chronos-dashboard.el` 行；测试表把 `el-chronos-ui-test.el` 改为 `test/el-chronos-web-test.el` 并更新用例数（web 9；总数 109）；总行数 8289 → 实测值。编码约定：删「`el-chronos-dashboard.el` 软依赖 `etaf` + `etaf-ui`」整段，只留核心模块零第三方 + web 零依赖两档；注释与降级说明去 ETAF。不变量清单：I9 / I11 按本计划「不变量改写」表逐字改写；I8 / I10 不动。已知边界表：删「dashboard 体量」行与「ETAF 有 10 条坑」行；「报告 / dashboard 自观测抑制」行改为只提报告与 Web；「仍待实测」行去掉 TD-5。验证入口：「可视化验收（T8 / T9）」节删 dashboard 的 `emacs -Q --batch -l el-chronos-dashboard.el` 命令，只留 Web 两条；基线段落改为实测的 109 用例并重算分布（report 24 / web 9 / collect 26 / analysis 15 / store 14 / attrib 21 = 109）。
  验收标准：`grep -c "dashboard" AGENTS.md` 只剩 Web dashboard 相关表述（`el-chronos-dashboard` 为 0）；不变量 I9/I11 与 decisions.md / ADR-0003 口径一致；用例数与 `make test` 实测一致。
  （依赖：T2，需 T2 实测结果）

## 文档清单

| 产物 | 状态 |
|---|---|
| `AGENTS.md` | 需更新（T6） |
| `Readme.org` | 需更新（T3） |
| `CHANGELOG.md` | 需更新（T3） |
| `docs/ui.org` | 需更新（T4） |
| `docs/api.org` | 需更新（T4） |
| `docs/architecture.org` | 需更新（T4） |
| `docs/operations.org` | 需更新（T4） |
| `docs/adr/0002-dual-visualization.md` | 状态改 Superseded（T5） |
| `docs/adr/0003-web-only-visualization.md` | 新增（T5） |
| `openspec/decisions.md` | 新增决策行（T5） |
| `openspec/tech-debt.md` | TD-5 关闭、TD-11 ④ 微调（T5） |
| `docs/schema.org` | 不需更新（无 schema / 查询变更） |
| `openspec/completed/el-chronos-core.md` | **不更新**（历史归档，保持原文） |

## 验证标准

| 级别 | 方法 | 通过判据 |
|---|---|---|
| L1 | `make check-parens` + `make lint` | 全绿、零字节编译告警 |
| L2 | `make test` | `Ran 109 tests, 109 results as expected, 0 unexpected, 0 skipped` |
| L3 | ① `grep -rn "el-chronos-dashboard" /home/thomas/Workspace/el-chronos`；② `grep -rn "ETAF\|dashboard" --include=*.el /home/thomas/Workspace/el-chronos`；③ `emacs -Q --batch -L . -l el-chronos-web.el --eval '(princ "loaded ok")'`；④ `el-chronos-mode` 启停幂等与零残留 | ① 仅历史白名单命中（CHANGELOG 历史条目、ADR-0002、ADR-0003、`openspec/completed/el-chronos-core.md`）；② 命中 **仅限四类白名单**（口径与 T1 验收② 逐字一致）：㈠ `el-chronos-attrib.el:72` / `test/el-chronos-attrib-test.el` 的 `etaf-runtime` 归因示例，㈡ `el-chronos.el:137/143` 的「Web dashboard」defcustom 文案，㈢ `el-chronos-collect.el:99` 的 `dashboard-mode` 第三方 major-mode 名（㈣ `test/el-chronos-web-test.el` 不应再命中，T2 已清）；③ 退出码 0；④ 无 timer/hook/profiler 残留 |

## 注意事项

1. **T2 必须按节标题定位删除**，不要用固定行号：T1 改动 `el-chronos-collect.el` 不影响测试文件行号，但任何后续改动都可能使其漂移。
2. **`el-chronos-show-event` 保留**：只删 dashboard 内的调用点，不动 `el-chronos-report.el:457` 的定义与 `docs/api.org` 条目。
3. **`openspec/completed/el-chronos-core.md` 与 `CHANGELOG.md` 历史条目一字不改**：L3 的 grep 白名单正是为它们留的。
4. **ETAF 踩坑清单直接删除**，不要迁移、不要留「历史附录」——本仓库不再有 ETAF 代码。
5. 若 `make test` 的实测用例数与阶段预期不符（**T2 阶段 107、T2b 完成后 109**），**以实测为准**并回填到 AGENTS.md，同时在汇总报告中说明差异原因。
6. 删除 `/home/thomas/Workspace/el-chronos/el-chronos-dashboard.el` 前先确认 `git status` 干净（无未提交改动），否则先报告给 harspower 再动手。
7. **`attrib` 的 `etaf-runtime` 是归因测试数据，不得删**：`el-chronos-attrib.el:72` 与 `test/el-chronos-attrib-test.el:109–179` 用它作 `.eln` 文件名与包名示例（`el-chronos-attrib--classify-eln` 的 fixture），与 ETAF 可视化无关。任何「清理 etaf 字样」的动作都必须跳过这两处。
8. **`el-chronos-show-event` 的覆盖由 T2b 补偿**：不接受「覆盖损失可接受」的处置——该命令保留且是 `docs/api.org` 记录的公共 API，必须有测试。
