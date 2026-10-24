# ADR-0003：可视化收敛为两形态（浏览器 Web dashboard + org 报告），移除 Emacs 内 ETAF 页面

- **状态**：Accepted（已实施，2026-10-24）
- **日期**：2026-10-24（决策与实施同日完成）
- **决策者**：用户（明确要求「删除 dashboard 只保留 web」）
- **关联**：ADR-0002（**Superseded by 本文**）、`openspec/completed/remove-dashboard-web-only.md`、`AGENTS.md` 不变量 I9 / I11、`docs/ui.org`、`docs/api.org`、`openspec/tech-debt.md` TD-5

## 背景

ADR-0002 决策了「双形态可视化」：Emacs 内 ETAF 页面（`el-chronos-dashboard.el`）+ 浏览器 Web dashboard
（`el-chronos-web.el`），两者共享同一 `el-chronos-analysis` 查询层。实施后两种形态**能力高度重叠**：

| 能力 | Emacs 内 dashboard | 浏览器 Web dashboard |
|---|---|---|
| 概览卡片 / 统计摘要 | ✅ | ✅ |
| 慢命令排行、热点函数排行 | ✅ | ✅ |
| 趋势多线对比 | ✅ | ✅ |
| 用法热力图 | ✅ | ✅ |
| 包 / 模块归因 | ✅ | ✅ |
| 单条事件下钻（栈帧） | ✅ | ✅ |
| 火焰图 / 多会话对比 / 搜索排序分页 / 导出 | ❌ 无 | ✅ |

即：dashboard 能做的，Web 全都能做；Web 能做的，dashboard 有一部分做不了。
但 dashboard 独占了项目的**最高维护成本**：

1. **ETAF 软依赖与双渲染路径**：dashboard 同时维护 ETAF 组件树版与内置 `tabulated-list` 降级版两套渲染，
   同一批能力要实现两遍（I9 要求「ETAF 缺失必须降级」，因此降级版不能省）。
2. **10 条 ETAF 实测坑**：组件不是 `fboundp` 可见的函数、表格注册名是 `etaf-table` 且 `:row-key` 必填、
   `text` 内非字面量必须 `(expr FORM)`、列表属性必须 `(quote ...)`、重挂须先 `etaf-unmount`、
   `:bindings` 须用 `(etaf-value x)` 读、无 polyline 需自算 `d`、宏软依赖须 `(eval FORM t)`、
   `etaf-tile-grid` 单元格文本须单行且不超 `:cell-width`、batch 下可挂载（可用于 ERT）。
   每条坑都意味着「写错不会报错、只是渲染出空/错内容」，新人无法凭直觉写对。
3. **内存与重绘风险**：曾出现重复打开 dashboard 导致内存持续增长（OOM），为此引入
   `el-chronos-dashboard-max-rows` 截断兜底；而 **TD-5（ETAF 页面在大量行 / 多图表重绘下的性能）
   从决策到模块删除始终未实测**——一个连性能数字都拿不到的模块，其风险无法被量化管理。
4. **24 个 ERT 用例**（约占全仓用例的 18%）全部用于覆盖页面结构与降级路径，其中
   `el-chronos-ui-test-dashboard-render-no-truncation` 在 `make test` 下因 ETAF 不在 `load-path`
   始终被 `skip-unless` 跳过——即这部分测试**常态下并非全绿可验**。

相对地，Web 形态：

- **零第三方依赖**（内置 `make-network-process` + 内嵌 HTML/CSS/JS），离线可用（I10）；
- **覆盖全部只读查看需求**，且具备 dashboard 没有的深度分析能力（火焰图、多会话对比、导出）；
- **安全边界明确可声明**：默认关闭、只绑 `127.0.0.1`、只提供只读 GET 路由（I8）；
- 与 org 报告共享同一 `el-chronos-analysis` 查询层，口径不会分裂。

问题因此是：**是否应当删除 dashboard 模块，把可视化收敛为 Web + org 报告两形态？**

## 决策

**删除 `el-chronos-dashboard.el` 与全部 ETAF 依赖**，可视化只保留两形态：

| 形态 | 模块 | 启动 | 定位 |
|---|---|---|---|
| 浏览器 Web dashboard | `el-chronos-web.el`（13 条只读 GET 路由 + 内嵌 HTML/CSS/JS） | `M-x el-chronos-web-start`（默认 `http://127.0.0.1:8787/`） | 交互查看与深度分析（唯一图形化形态） |
| org 报告 | `el-chronos-report.el` | `M-x el-chronos-report` 等 | 快照、周报、CSV/JSON 导出、可存档 |

两者仍共享同一 `el-chronos-analysis` 查询层（D4 的「数据同源」不变）。

### D1 保留 `el-chronos-show-event`，不随 dashboard 一起删

`el-chronos-show-event` 定义在 `el-chronos-report.el`（不是 dashboard），是对单条慢事件做栈帧下钻的公共
interactive 命令，`docs/api.org` 已作为对外接口记录。dashboard 只是它的一个调用者；
删除 dashboard 后该命令对阻塞事件（`kind='block'`）的下钻仍有独立价值，因此**保留定义**，只删调用点。
其测试覆盖原本只来自被删的 dashboard 用例，故新增 2 个专用用例补偿。

### D2 不变量 I9 反转、I11 收缩，I 编号一律不重排

| 不变量 | 改写后 | 理由 |
|---|---|---|
| I9 | **ETAF 已完全移除；可视化层不引入 ETAF（防止回潮）** | 原 I9 是「dashboard 对 ETAF 为软依赖、缺失降级、核心不依赖 ETAF」——模块删除后其前两项失去对象，只剩「不依赖」这一条仍有约束力。改写为**反向禁令**：不是为了记录历史，而是防止未来有人以「加个 Emacs 内页面更好用」为由重新引入 ETAF |
| I11 | 不可用必须**可见降级**，保留「Web 端口占用 → 明确报错，不得静默失败」；去掉 ETAF→tabulated-list 与 SVG→文本条形两个子项 | 降级对象已不存在于代码中，保留条目会让不变量清单与实现脱节（违背「文档与代码同步」） |
| I8 / I10 | **不变** | Web 只绑 `127.0.0.1` / 默认关闭 / 只读；资源内嵌无 CDN——均仍有效 |

**I 编号不重排**（仍为 I1–I11，I9/I11 语义改写）：全仓有大量 `I8–I11`、`I9`、`I11` 的文字引用
（AGENTS.md、ADR-0001/0002、docs/、代码注释、openspec），重编号会引发连锁改动且极易漏改，
收益（编号连续好看）远低于风险（引用错位且难定位）。

### D3 文档按「历史 vs 现状」二分处理，不回改历史

- **历史工件保留原文**：`docs/adr/0001-observer-architecture.md` 一字不改（其「技术债」清单是
  2026-10-24 的时点快照）；`docs/adr/0002-dual-visualization.md` **只改状态行**为
  `Superseded by ADR-0003`，正文含「实施结果」节一字不改；`openspec/completed/el-chronos-core.md`
  与 `CHANGELOG.md` 历史条目一字不改。
- **现状文档同步改写**：`AGENTS.md`、`Readme.org`、`docs/ui.org`、`docs/api.org`、
  `docs/architecture.org`、`docs/operations.org`、`openspec/decisions.md`、`openspec/tech-debt.md`。
- 理由：改历史 ADR 会让「当时的判断依据」消失，后人无法看懂决策演化；而现状文档若停留在三形态，
  会让读者去找一个不存在的模块。

### D4 ETAF 踩坑知识直接删除，不迁移

10 条踩坑清单随模块删除而删除（`docs/ui.org`「ETAF 实测踩坑清单」整节移除），**不迁移到
`thomas-emacs` 仓库、不在本仓库留历史附录**。理由：本仓库不再有 ETAF 代码，保留一份无实现对应的
清单违背「文档与代码同步」；若要服务于 `thomas-emacs` 的 ETAF 使用，它的重构对象与生命周期
应在那个仓库里独立成形，而不是靠本仓库的旁支附录维持。

## 后果

**正面**

- **源码减 1382 行**（8 → 7 个源码模块），删除一个纯 UI 模块而采集/存储/分析零改动。
- **依赖面归零**：核心五模块本就零第三方，Web 侧零依赖——全仓**不再有任何第三方依赖**，
  `make lint` 也不必再处理「ETAF 缺席环境下宏软依赖写成数据 + `(eval FORM t)`」这类技巧。
- **维护面从双渲染路降为单路**：同一能力不再需要实现两遍，也不会出现「ETAF 版对、降级版漏」的分裂。
- **测试面收敛并变可靠**：131 → **109** 用例（删 24 + 补 2）；原常态 skip 的
  `dashboard-render-no-truncation` 随之消失，109 个用例**全部实际执行**。
- **安全/隐私边界更简单**：可视化只剩 org 报告（本地文件）与 Web（loopback + 只读 + 默认关闭）。

**负面 / 代价**

- **失去「不离开 Emacs 顺手看一眼」的形态**：查看需 `M-x el-chronos-web-start` 后切到浏览器。
  这是用户显式接受的代价（「删除 dashboard 只保留 web」）。
- **Web server 是需记得关闭的常驻资源**：默认不自启，端口占用时明确报错（`user-error`，不自动换端口）；
  `M-x el-chronos-web-stop` 干净释放。
- **ETAF 踩坑知识随模块删除**（不迁移，见 D4）：若将来 `thomas-emacs` 侧需要，须重新总结。
- **TD-5 以「关闭」而非「测得」结案**：ETAF 重绘性能**始终没有实测数字**——这不是风险被消除，
  而是测量对象消失。Web 渲染性能若需评估，另立技术债，不复用 TD-5 编号。

**约束（进入不变量）**

I9（ETAF 已移除、不得回潮）、I11（端口占用必须明确报错，不得静默失败）、
I8（只绑 `127.0.0.1`、默认关闭、只读）、I10（可视化资源内嵌、无 CDN、离线可用）——**I8 / I10 不变**。

## 实施结果（2026-10-24 回填）

- **源码**：8 → **7** 模块；`el-chronos-dashboard.el` 删除 **1382 行**
  （`git show c30e32c --stat` 记录 `el-chronos-dashboard.el | 1382 ---------`）。
- **测试**：131 → **109** 用例（删 24 个 dashboard 用例 + 5 项专用夹具，
  `test/el-chronos-ui-test.el`（856 行）→ `test/el-chronos-web-test.el`（232 行，9 个 Web 用例）；
  补 2 个 `el-chronos-show-event` 用例）。原 107（T2 后）→ 109（T2b 后）与计划预期一致。
- **验证**：`make check-parens` 全绿、`make test` **109 全绿（0 unexpected、0 skipped）**、
  `make lint` **零告警**。
- **文档**：`AGENTS.md`、`Readme.org`、`CHANGELOG.md`、`docs/ui.org`、`docs/api.org`、
  `docs/architecture.org`、`docs/operations.org` 需同步为两形态，由 T3 / T4 / T6 三个并行任务负责；
  本文只记录决策与不变量口径，不断言其完成状态。
- **决策工件**：本文 + ADR-0002 状态改 Superseded + `openspec/decisions.md` 新增一行 +
  `openspec/tech-debt.md` 关闭 TD-5（T5）。
- **后续修复**：TD-12（Web 请求处理未纳入自观测抑制）已关闭 —— `el-chronos-web--handle-request` 外层加 `el-chronos-web--without-block-events`（report 侧同款三层内联实现），并新增端到端用例；详见 `openspec/completed/fix-web-block-suppression.md`。

## 替代方案与被否决原因

| 替代方案 | 描述 | 否决原因 |
|---|---|---|
| 保留双形态但停止维护 dashboard | 代码留着，文档标注「不再更新」，只维护 Web | 代码仍在就得继续过 `make lint` / `make check-parens` / ERT，依赖与 lint 环境复杂度一分不减；而「停止维护的模块」必然腐化（依赖升级后静默失效、读者误用），最终仍要删——晚删只是把成本推后并叠加 |
| 保留 dashboard、删除 Web | 只做 Emacs 内页面 | 与用户诉求相反；且 ETAF 软依赖带来的成本高于 Web——dashboard 需要 ETAF 才能看图表，Web 零依赖即可；同时会丢掉火焰图、多会话对比、搜索排序分页与导出能力 |
| 把 ETAF 踩坑清单迁到 `thomas-emacs` 仓库 | 知识不丢，换个仓库保存 | 跨仓库维护：本仓库不再有对应实现，清单无法随代码验证，形同孤儿文档；且 `thomas-emacs` 的 ETAF 用法与 dashboard 的用法不同，机械搬运价值低（用户选择直接删除） |
| 保留 dashboard 的 tabulated-list 降级版（去掉 ETAF） | 摘掉 ETAF，只留内置表格页 | 仍需维护一整套 Emacs 内渲染与交互（快捷键、分页、下钻、宽度策略、主题配色），而这套能力在 Web 侧已完整具备；「纯表格的 Emacs 页面」相对 org 报告的增量收益极低，却有完整的测试与文档成本 |
| 把 Web 页面嵌进 Emacs（xwidget / EWW 内嵌浏览器） | 二者合一：Emacs 里开 Web 页面 | 引入新依赖（xwidget 需图形构建、EWW 渲染交互受限且性能不可控），违背零第三方依赖与低开销定位；内嵌浏览器的 JS 行为不可测，ERT 覆盖不了 |
| 只保留 org 报告，连 Web 也删 | 最小形态，零常驻资源 | 丢全部图形与交互能力（趋势形状、热力分布、下钻、搜索排序），而这正是用户要的「回答问题靠看图的第 6 条目标」；org 报告是快照形态，不能替代交互查看 |

## 关联

- 被本文取代：`docs/adr/0002-dual-visualization.md`（状态改为 `Superseded by ADR-0003`，正文保留原文）
- 保留原文不做修改：`docs/adr/0001-observer-architecture.md`（其「技术债」清单为 2026-10-24 时点快照，
  TD-5 的关闭由本文与 `openspec/tech-debt.md` 承载）
- 计划：`openspec/completed/remove-dashboard-web-only.md`（T5 为本文的落地任务）
- 决策表：`openspec/decisions.md`（2026-10-24 可视化收敛一行；原「双形态可视化」一行保留为历史记录）
- 技术债：`openspec/tech-debt.md` TD-5（**已关闭**，测量对象消失）、TD-11 ④（原拟并入 TD-5，现需独立安排）
- 不变量：`AGENTS.md` I9（ETAF 已移除、不得回潮）/ I11（端口占用明确报错）/ I8 / I10（不变）
- 技术文档：`docs/ui.org`（两形态总览与 Web 路由）、`docs/api.org`（7 个模块）、
  `docs/architecture.org`（分层与可视化数据流）
