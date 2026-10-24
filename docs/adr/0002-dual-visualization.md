# ADR-0002：双形态可视化（Emacs 内 ETAF 页面 + 浏览器 Web dashboard）

- **状态**：Superseded by [ADR-0003](0003-web-only-visualization.md)（2026-10-24）
- **日期**：2026-10-24（决策）；2026-10-24（实施结果回填）
- **决策者**：用户（方案追加确认）
- **关联**：`openspec/completed/el-chronos-core.md`「可视化设计」节与不变量 I8–I11；`openspec/decisions.md` 对应行；`docs/architecture.org`「可视化数据流」「实测结论」；`docs/schema.org`（`hourly_stacks`）；`docs/ui.org`（ETAF 踩坑清单、13 条路由）；`docs/api.org`（对外接口）

## 背景

ADR-0001 已确定"常驻低开销采集 + SQLite 小时聚合 + 函数级定位"，数据侧能回答前 5 个问题，
但**呈现侧只有一种形态**：`el-chronos-report` 生成的 org buffer（外加一个 tabulated-list 简版）。

实际使用中暴露出三类需求，org 报告单独无法满足：

1. **日常顺手看一眼**：想知道"今天慢在哪、有没有新回归"，不想等 org 报告生成再滚动查找；
   需要卡片式概览、排行表、按时间范围切换，最好不离开 Emacs。
2. **深度分析与交互下钻**：趋势多线对比、包占比、用法热力图、火焰图、搜索过滤、列排序、
   多会话对比——这些在纯文本 org 里表达力很弱，浏览器天然擅长。
3. **图表**：趋势 / 占比 / 热力图需要真正的图形；纯文本表格看不出"形状"。

同时有两个硬约束来自既有不变量与用户环境：

- **不引第三方依赖**（ADR-0001 的"仅内置库"边界）——不能为了 Web 页面引入图表库、框架或 CDN。
- **用户已安装 ETAF**（Emacs Text Application Framework：`ecss` / `ebox` / `etaf` / `etaf-ui`，
  见 thomas-emacs 的 `lisp/init-etaf.el`），它提供组件化布局、响应式状态、表格与 SVG 组合能力。

问题因此是：**呈现层该做成什么形态、Emacs 侧用什么框架实现、如何分工且不破坏"核心零第三方依赖"的边界。**

## 决策

可视化采用**双形态**，两者**共享同一 `el-chronos-analysis` 查询层**：

| 形态 | 模块 | 启动 | 定位 |
|---|---|---|---|
| Emacs 内页面 | `el-chronos-dashboard.el`（**ETAF 实现**） | `M-x el-chronos-dashboard`（buffer `*el-chronos*`） | 日常查看：不离开 Emacs、快捷键切换、行级下钻 |
| 浏览器 Web dashboard | `el-chronos-web.el`（`make-network-process` 最小 HTTP server + 内嵌 HTML/CSS/JS） | `M-x el-chronos-web-start`（默认 `http://127.0.0.1:8787/`） | 深度分析：多图表、搜索排序分页、火焰图、多会话对比、导出 |

### D1 Emacs 侧选用 ETAF，而非内置 `svg.el` + `tabulated-list` 手工拼装

- 复用 `etaf-define-component`（`:bindings` / `:view`）+ `etaf-ref` / `etaf-value` 的响应式状态：
  时间范围切换只需改一个 binding，相关子树自动重渲染，不必手写"清 buffer 再插文本"的刷新逻辑。
- 复用官方组件：`etaf-panel` / `etaf-label` / `etaf-button` / `etaf-tile-grid`（概览卡片）/
  `etaf-ui-table`（排行榜，`:columns` / `:rows` 声明式）/ `etaf-popover` / `etaf-dialog`（下钻）、
  `etaf-dropdown-menu`（过滤）——省掉自造布局与交互层。
- 复用 SVG 生成器：`etaf-ui-svg-rect` / `-circle` / `-line` / `-path` / `-text` / `-group` 输出 SVG markup，
  `etaf-ui-svg-image` 返回 `(image :type svg :data STRING)` 描述符，交给 image Host
  （如 `etaf-tile-grid` 的 `:cell-image`）——图表与卡片可以共存于同一组件树。
- 本机已装 ETAF，无新增安装步骤。

### D2 ETAF 是**软依赖**，不进入核心依赖边界

- `el-chronos-dashboard.el` 一律 `(require 'etaf nil t)` / `(require 'etaf-ui nil t)`；任一失败
  → `display-warning` 提示安装（straight recipe 指向 thomas-emacs 的 `lisp/init-etaf.el`）
  → 自动降级为内置 `tabulated-list` 简版页面。
- **采集 / 归因 / 存储 / 分析 / 报告五个核心模块不得 require ETAF**（I9）；即使 ETAF 全不可用，
  数据仍在正常落库，org 报告与 Web dashboard 照常工作。

### D3 Web 侧零依赖：自写最小 HTTP server + 内嵌前端

- `make-network-process :server t`（内置）实现最小 HTTP/1.1 GET server；只提供只读接口
  （`GET /`、`GET /api/summary|top-functions|slow-commands|packages|trend|heatmap|stacks|sessions|event/:id`、
  `GET /api/export.csv`）。
- HTML/CSS/JS 以 elisp 字符串内嵌，图表用原生 SVG/Canvas 手写，**不引图表库、不引框架、不用 CDN**
  （I10）——断网、离线环境下页面与图表照常工作。
- **只绑定 `127.0.0.1`，默认不自动启动，`el-chronos-web-stop` 干净释放端口**（I8）；
  端口占用时明确报错而非静默失败（I11）。

### D4 双形态分工且数据同源

- 两种形态都只调 `el-chronos-analysis` 的查询函数（返回 plist），不各自写 SQL；
  因此新增一种形态不需要改采集与存储，且两种形态的数字必然一致（对比时不会"两边对不上"）。
- 图表数据需要栈级明细时，新增 `hourly_stacks`（每小时 top-N 栈，默认 200，按 `samples` 淘汰）：
  火焰图与调用链分析由此而来，且行数上界为「小时数 × 会话数 × N」，不随采样频率线性膨胀。

## 后果

**正面**

- 日常查看不离开 Emacs：`M-x el-chronos-dashboard` 一屏看到概览卡片、排行与趋势，快捷键切范围；
- 深度分析有称手工具：浏览器侧多图表、搜索排序分页、火焰图、多会话对比、CSV/JSON 导出；
- 两种形态数据同源（同一 analysis 查询层），不存在口径分裂；
- 离线可用、零第三方依赖（ETAF 为软依赖、Web 侧纯内置），符合 ADR-0001 的依赖边界；
- 降级路径明确：ETAF 缺失→tabulated-list；terminal frame→文本条形；端口占用→明确报错（I11）。

**负面 / 代价**

- dashboard 对 ETAF 形成**软依赖**，需维护两条渲染路径（ETAF 版 + tabulated-list 降级版），
  代码量比单一 org 报告方案增加约 **40%**；
- 需要处理 terminal frame 的 SVG 不可用场景（`etaf-ui-svg.el` 注释已明确该限制）；
- Web server 虽只绑 loopback，仍是需要正确关闭的常驻资源（端口泄漏风险），因此默认不自动启动；
- `hourly_stacks` 增加一处保留策略与 top-N 淘汰逻辑，存储模块复杂度上升；
- 两套 UI 的验收面变大（各 10 项能力），ERT 只能覆盖数据层与降级路径，视觉正确性仍需人工过一遍。

**约束（进入不变量）**

I8（Web 只绑 `127.0.0.1`、默认关闭、只读）、I9（dashboard 对 ETAF 软依赖、缺失降级、核心不依赖 ETAF）、
I10（可视化资源内嵌或本地生成、无 CDN、离线可用）、I11（不可用必须可见降级）。

## 实施结果（2026-10-24 回填）

T8（`el-chronos-dashboard.el`）、T9（`el-chronos-web.el`）、T11（`el-chronos-profile-command`）已落地，
ERT 103 用例全绿（`make test`：`Ran 103 tests, 103 results as expected, 0 unexpected`）。逐项回验本 ADR 的判断：

### D1 ETAF 选型成立

- **组件化可用**：`etaf-define-component` + `:bindings` / `:view` + `etaf-ref` / `etaf-value` 的响应式状态
  确实省掉了「清 buffer 再插文本」的手写刷新；5 张表 + 3 张图 + 6 卡片 + 1 弹窗全部落在同一棵组件树里。
- **`batch` 下可测**（超出决策时的预期）：`emacs -Q --batch` 里 `etaf-mount` 能正常挂载并把组件树渲染成
  buffer 文本（`--graphic-p` 为 nil 时图表走字符图路径），因此 ERT 可直接断言页面内容，**不必依赖真实 GUI**。
  这一点让「两种形态各 10 项能力的验收」从纯人工过一遍变为「数据层 + 降级路径自动化、视觉人工抽查」。
- **SVG 生成器够用**：`etaf-ui-svg-rect` / `-circle` / `-line` / `-path` / `-text` / `-group` 覆盖了趋势折线、
  横向条形、热力格三类图表；`etaf-ui-svg-image` 返回的 image 描述符可交给 `etaf-tile-grid` 的 `:cell-image`。

### 代价确认（比决策时估计的更具体）

- **代码量**：`el-chronos-dashboard.el` **976 行**（含 ETAF 组件树 + tabulated-list 降级页 + 可测纯函数），
  与决策时预判的「比单一 org 报告方案增加约 40%」量级一致。
- **ETAF 有 10 条实测坑**，每条都在实现里留下了对应的写法或注释（详见 `docs/ui.org`「ETAF 实测踩坑清单」）：
  组件不是 fboundp 可见的函数、表格注册名是 `etaf-table` 且 `:row-key` 必填、`text` 内非字面量必须 `(expr FORM)`、
  列表属性必须 `(quote ...)`、重挂同一 buffer 必须先 `etaf-unmount`、`:bindings` 必须用 `(etaf-value x)` 读、
  无 polyline 要自己算 `d`、batch 下可挂载（可用于 ERT）、宏的软依赖必须 `(eval FORM t)` 延迟、
  `etaf-tile-grid` 的单元格文本必须单行且不超 `:cell-width`。
- **两条渲染路径确实要维护**：ETAF 版 + tabulated-list 降级版都要实现「慢命令 + 热点函数 + 切范围」，
  这条代价成立；但也正因如此，ETAF 缺失的用户拿到的不是空壳（I11 的本意）。

### D3 Web 自写 server 可行

- **代码量**：`el-chronos-web.el` **709 行**（含 13 条路由 + 内嵌 CSS/markup/JS + CSV 导出）。
- **单线程串行是特性而非缺陷**：请求在 Emacs 主线程同步处理，短连接（`Connection: close`）+ 一次响应，
  因此不需要 keep-alive / 分块传输 / 长连接超时；代价是并发请求排队、慢查询会占主线程，
  已用 `limit` 上限（默认 20、最大 1000）与 16KB 请求上限兜住。
- **零依赖成立**：`make-network-process` + 字符串内嵌 HTML/CSS/JS 足够做出概览卡片、SVG 趋势/环形图、
  DOM 热力网格、按层聚合的火焰图近似、搜索/排序/分页与下钻侧栏；离线（无 CDN、无外链）可用。
- **边界可验证**：端口占用 → `user-error` 不换端口；非 GET → 405；未知路径 → 404；
  只绑 `127.0.0.1`（常量，不接受 `0.0.0.0`）；`el-chronos-web-stop` 干净释放端口。均有 ERT 覆盖。

### 仍待实测

ETAF 页面在 30 天真实数据下的**重绘性能**（TD-5）仍未实测——功能与降级路径已验证，性能数字待补；
超 1s 的处置预案（下调每页行数与图表采样点、必要时按需渲染）已写入 `docs/ui.org`「性能注意」。

## 替代方案与被否决原因

| 替代方案 | 描述 | 否决原因 |
|---|---|---|
| 仅内置 `svg.el` + `tabulated-list` | 手写图表 SVG 与表格，自己做布局与刷新 | 组件化与交互能力弱：无响应式状态（每次交互要手工重建 buffer）、无布局系统、无下钻/弹层组件，交互代码量反而超过用 ETAF；`svg.el` 只有绘图原语，坐标轴/图例/热力图全部自造 |
| 仅 Web dashboard | 只做浏览器页面，不做 Emacs 内页面 | 日常查看要离开 Emacs、另开浏览器；且 Web server 是常驻资源（需记得停），把"顺手看一眼"变成有成本的动作；与"观测器在 Emacs 内常驻"的定位不符 |
| 仅静态 HTML 导出 | 定期生成一个自包含 HTML 文件，双击打开 | 无交互下钻、无搜索排序分页、无法切时间范围与多会话对比；数据一变就要重新导出，等于把 org 报告的缺点换了个容器 |
| 引第三方前端框架/图表库（Chart.js、ECharts、Vue 等） | 功能现成、开发快 | 违反零第三方依赖与离线可用（I10）；引入 CDN/打包链与版本维护负担；本机为离线可用场景，CDN 不可依赖 |
| 用 ETAF 做 Web 页面（ETAF → HTML 输出） | 一套组件树同时服务 Emacs 与浏览器 | ETAF 的宿主模型围绕 Emacs buffer / image 描述符，导出为浏览器可交互页面仍需补 JS 交互层，复杂且不成熟；两形态各自用擅长的方式成本更低 |
| 用 org 报告 + 表格软件（把 CSV 导入 spreadsheet） | 继续只做 org/CSV，分析交给外部工具 | 丢上下文（无下钻到栈样本、无归属文件联动）、每次都要人工搬运；不能算"可视化形态" |

## 关联

- 计划：`openspec/completed/el-chronos-core.md`「可视化设计」节、I8–I11、T8（dashboard）/ T9（Web）/ T10（测试）/ T12（文档）
- 决策表：`openspec/decisions.md`（2026-10-24 双形态一行）
- 上游 ADR：`docs/adr/0001-observer-architecture.md`（采集/存储/定位/隐私四项结构性决策）
- 数据模型：`docs/schema.org`（`hourly_stacks` 字段表、保留策略、P95 待定）
- 架构：`docs/architecture.org`（分层表新增可视化层、「可视化数据流」与降级矩阵）
- 用户文档：`Readme.org`「可视化（双形态）」节
- 外部依赖来源：thomas-emacs `lisp/init-etaf.el`（ETAF 安装与 recipe）
