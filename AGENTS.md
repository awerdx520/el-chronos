# el-chronos 仓库地图

## 项目概述

`el-chronos` 是一个在 Emacs 内常驻运行的**低开销性能与用法观测器**：持续采集命令耗时、函数热点、
命令外阻塞与用法统计，落库到 SQLite，并据此回答长期趋势与回归问题。观测而不干预——不做自动调优、
不改变 Emacs 行为语义。

它回答的 6 条目标：

1. 哪些命令/操作慢，慢多久（含被 `C-g` 中断的卡顿）
2. 慢在哪个函数、调用链是什么
3. 归因到哪个 straight 包 / `lisp/init-*.el` 模块 / site-lisp 文件
4. 长期趋势如何、某次改动是否引入回归
5. 哪些高频用法值得优先优化
6. 通过 Emacs 内 ETAF 可视化页面与浏览器 Web dashboard 双形态查看上述全部结论

**非目标**：自动调优/自动禁用功能、跨机器数据汇聚、源码行级采样、记录按键序列与文件内容。

当前状态：**Phase 4（Review & Document）已完成并归档**（Emacs 31.1，`make full-check` 全绿，`make test` 103 用例全绿，`make lint` 零告警）。
8 个源码模块 + 7 个测试文件 + 5 份技术文档齐备；剩余项是仍待实测的性能/覆盖率数字与 D1 的 GUI 实机验证（见 `openspec/tech-debt.md`）。
计划见 `openspec/completed/el-chronos-core.md`（2026-10-24 归档）。

## 目录结构

| 路径 | 用途 | 行数 / 状态 |
|---|---|---|
| `el-chronos.el` | 自定义组、minor mode、启停编排、错误降级 | 307 行（T2） |
| `el-chronos-collect.el` | 命令计时、心跳阻塞检测（含 D1 双跑去重）、profiler 窗口聚合、启动打点 | 699 行（T5a–c） |
| `el-chronos-attrib.el` | 符号→文件→包/模块；命令上下文 | 193 行（T3） |
| `el-chronos-store.el` | SQLite schema、批量 flush、保留策略、top-N 淘汰、purge | 532 行（T4） |
| `el-chronos-analysis.el` | 13 个只读聚合查询（热点/慢命令/阻塞/包归因/趋势/热力/栈/会话/回归） | 482 行（T6） |
| `el-chronos-report.el` | org 报告、周报、CSV/JSON 导出、按需高精度剖析、报告期间自观测抑制 | 830 行（T7、T11） |
| `el-chronos-dashboard.el` | Emacs 内可视化页面（ETAF：组件树 + SVG 图表 + 表格 + 下钻；缺 ETAF 降级 tabulated-list） | 976 行（T8） |
| `el-chronos-web.el` | 最小 HTTP server（13 条只读 GET 路由）+ 内嵌 HTML/CSS/JS dashboard | 709 行（T9） |
| `test/el-chronos-test-helper.el` | ERT 公共夹具（临时库、fixture 数据、断言辅助） | 165 行 |
| `test/el-chronos-analysis-test.el` | analysis 查询与回归判定 fixture 断言 | 354 行 / 15 用例 |
| `test/el-chronos-attrib-test.el` | 归因链与上下文（basename 不出现 `/` 断言） | 140 行 / 14 用例 |
| `test/el-chronos-collect-test.el` | 命令三态、心跳阻塞、采样聚合、TD-9 局部 hook、D1 双跑去重 | 380 行 / 15 用例 |
| `test/el-chronos-report-test.el` | org 报告 10 节、周报、CSV/JSON 导出、单命令剖析 `--invoke` 三形态、Web 500 与端口 0 | 419 行 / 22 用例 |
| `test/el-chronos-store-test.el` | schema/迁移/批量写入/保留策略/top-N 淘汰/purge | 247 行 / 14 用例 |
| `test/el-chronos-ui-test.el` | dashboard（ETAF 与降级两路）与 Web 路由冒烟 | 488 行 / 23 用例 |
| `docs/architecture.org` | 分层、四条采集路径、可视化数据流、**实测结论**、已知偏差 | 已补实 |
| `docs/schema.org` | 最终 DDL（6 表 + 3 索引）、top-N 淘汰 SQL、保留策略、P95 近似说明 | 已补实 |
| `docs/ui.org` | 三形态总览、ETAF 组件树与 10 项能力、快捷键、**ETAF 10 条踩坑**、13 条 Web 路由、org 报告 10 节、性能注意 | 已建（T12） |
| `docs/api.org` | elisp 对外接口索引（8 模块、签名单、defcustom 清单、内部函数约定） | 已建（T12） |
| `docs/operations.org` | 安装/卸载/数据清理/排障/验证步骤/隐私与保留表 | 已建（T12） |
| `docs/adr/` | `0001-observer-architecture.md`、`0002-dual-visualization.md`（含实施结果） | 已完成 |
| `openspec/` | 计划与决策工件（`active/`、`completed/`、`decisions.md`、`tech-debt.md`） | 已建 |
| `Makefile` | 验证入口：`check-parens` / `test` / `lint` / `full-check` | 已建 |
| `Readme.org` / `CHANGELOG.md` | 项目说明与变更日志 | 已建 |

## 编码约定

**文件头/尾**（不变量，机械可检）：

```elisp
;;; el-chronos-xxx.el --- 描述  -*- lexical-binding: t; -*-

;; 正文

;;; el-chronos-xxx.el ends here
```

- 必须含 `lexical-binding: t`；文件末行必须是 `;;; el-chronos-xxx.el ends here`。
- **符号前缀**：对外接口用 `el-chronos-<domain>-<verb>`（如 `el-chronos-store-record-command`）；
  内部实现用 `el-chronos--`（双连字符）。禁止无前缀的公共符号。
- **依赖边界（两档）**：
  - **核心模块**（`collect` / `attrib` / `store` / `analysis` / `report`）仅使用 Emacs 内置库——
    `sqlite`（29+ 内置）、`profiler`、`cl-lib`、`subr-x`、`tabulated-list`、`org`。
    **不引入任何第三方依赖**（不 require straight/use-package/magit 等，不新增 package 安装步骤）。
  - **`el-chronos-dashboard.el` 软依赖** `etaf` + `etaf-ui`：一律 `(require 'etaf nil t)` /
    `(require 'etaf-ui nil t)`，缺失时 `display-warning` 提示安装并降级到内置 `tabulated-list` 简版页面
    （I9）；采集/存储/分析核心**不得**依赖 ETAF。
  - **`el-chronos-web.el` 零依赖**：只用内置 `make-network-process` 自写最小 HTTP server，
    HTML/CSS/JS 以 elisp 字符串内嵌，不引图表库与 CDN（I10）。
- **注释与文档用中文**；符号名与文件名用英文，前缀 `el-chronos-`。
- 采集路径（hook/timer/采样回调）中任何可能失败的调用必须被 `condition-case` 包裹，
  失败降级为 `unknown` 并继续，**不得向宿主抛错**。

## 不变量清单

以下 I1–I11 与 `openspec/completed/el-chronos-core.md` 逐字一致，违反即失败：

- **I1** 采样只用内置 C profiler，不自造采样器、不全量 advice。
- **I2** 主线程阻塞期间不依赖 Lisp 回调（证据由 SIGPROF 留存，事后回溯）。
- **I3** 数据只写 `el-chronos-db-path`（默认 `<user-emacs-directory>/.local/state/chronos/chronos.sqlite`）。
- **I4** 单位统一：API/DB 用毫秒，采样间隔用纳秒。
- **I5** `el-chronos-mode -1` 零残留：timer、hook、profiler、未 flush 缓冲。
- **I6** 归因失败降级 `unknown`，采集路径不得向宿主抛错。
- **I7** 默认不记录**被操作文件**路径、按键序列、buffer 内容与命令参数；函数归因所需的源码路径与项目 basename 除外。
- **I8** Web server 只绑定 `127.0.0.1`，默认关闭，禁止 `0.0.0.0`；只提供只读接口。loopback 仅防 LAN 暴露，不构成本机访问控制（WSL2 mirrored 下 Windows 侧可达），Web 无鉴权。
- **I9** Emacs dashboard 对 ETAF 为软依赖（`require ... nil t`），缺失时必须降级到内置 tabulated-list 并提示安装；采集/存储/分析核心**不得**依赖 ETAF。
- **I10** 可视化资源全部内嵌或本地生成（Emacs 图表用 `etaf-ui-svg-*`，Web 用字符串内嵌 HTML/CSS/JS），不引第三方图表库与 CDN，离线可用。
- **I11** 任一可视化形态不可用时必须可见降级（ETAF 缺失→tabulated-list；SVG 不可用→文本条形；Web 端口占用→明确报错），不得静默失败。

## 隐私边界

- **记录**：命令名、耗时、GC 时长、major-mode、项目 **basename**、函数符号名、函数定义源码路径（归因必需）。
- **不记录**：被操作文件路径、buffer 内容、按键序列、命令参数、剪贴板、环境变量。
- `commands.project` 存 `(file-name-nondirectory (directory-file-name (project-root ...)))`，即 basename，
  **不存绝对路径**；取不到时为 NULL。断言：`commands.project` 中不出现 `/`。
- Web **无鉴权**；loopback 只防 LAN 暴露，不构成本机访问控制（WSL2 mirrored 下 Windows 侧进程可达）。
- 数据生命周期：`commands` / `slow_events` 按 `el-chronos-retention-days`（默认 30）保留；
  `hourly_functions` / `hourly_usage` / `hourly_stacks` **永久保留**，由用户手动 `el-chronos-purge` 清理。

## 错误处理矩阵（摘要）

| 故障 | 行为 | 可见性 |
|---|---|---|
| SQLite 打开失败 | 禁用采集 | `display-warning` |
| 写入/flush 失败（磁盘满、WAL 锁超时） | 丢弃本批、计数、限流告警（每 10 分钟最多一次）、继续采集 | `display-warning` |
| 归因失败 | 返回 `unknown` | 静默 |
| profiler 启动失败 | 禁用采样，命令/心跳采集继续 | `display-warning` |
| ETAF 缺失 | 降级 tabulated-list 简版 | `display-warning` |
| SVG 不可用（terminal） | 文本条形 | 静默 |
| Web 端口占用 | 启动失败，不自动换端口 | `user-error` |
| 迁移失败 | 回滚 `.bak`，不破坏原库 | `display-warning` |

完整矩阵与回归判定阈值见 `openspec/completed/el-chronos-core.md`。

## 验证入口

```sh
make check-parens   # L1：逐文件括号平衡（无 .el 时空跑成功）
make test           # L2：自动发现并加载全部 test/*-test.el（无测试文件时空跑成功）
make lint           # L1 补充：字节编译告警（输出到临时目录，不污染仓库）
make full-check     # check-parens + test
```

全部目标用 `emacs -Q --batch`，不依赖运行中的 daemon。

**当前基线**（实测 2026-10-24）：`make test` = **103 用例全绿**（`Ran 103 tests, 103 results as expected, 0 unexpected`，约 5.7 秒），
分布：report 22 / ui 23 / analysis 15 / collect 15 / store 14 / attrib 14 用例；
行数：report 419 / ui 488 / collect 380 / analysis 354 / store 247 / helper 165 / attrib 140。
源码 8 模块 + 测试 7 文件共 **6921 行**。`make lint` **零告警**（15 个文件逐个字节编译，含 ETAF 缺席环境——dashboard 因此把宏调用写成数据 + `(eval FORM t)`）。
新增或修改行为时基线只准上升，改测试要说明原因。

**测试文件命名**：测试文件必须命名为 `test/*-test.el`；`make test` 通过 `$(sort $(wildcard test/*-test.el))` 自动发现该模式并按排序全部加载（无匹配时输出 `no test files` 并成功退出），禁止在 Makefile 里硬编码单个文件名（否则拆分测试后会静默漏跑）。

**可视化验收（T8 / T9）**：

```sh
# Emacs 页面：10 项能力可见、1/7/3 切时间范围、行 :on-press 下钻、ETAF 缺失降级、terminal frame 不报错
emacs -Q --batch -l el-chronos-dashboard.el --eval '(princ "loaded ok")'

# Web：全部 API 返回合法 JSON（本机 http_proxy 已设而 no_proxy 未设 → 必须 --noproxy '*'）
curl --noproxy '*' -sS http://127.0.0.1:8787/api/summary | python -m json.tool > /dev/null

# Web：只绑 loopback（应只出现 127.0.0.1:8787）
ss -lntH "sport = :8787"
```

**elisp 验证必须走 elisp-dev-mcp 的 `verify` 隔离实例**：

1. `elisp_mcp_set_task(task="verify")`；
2. 隔离实例内 `load-file` / flymake / ERT；
3. 收尾 `elisp_mcp_set_task(task="auto")` + `elisp_mcp_instance(action="stop", instance="verify")`。

> 本机主实例 `thomas` 当前调用超时，**禁止**在 `task=config` 下跑 ERT / 批量字节编译 / 全量 flymake
> （会占住用户 Emacs 主线程）。详见 ECA 全局规则 `rules/elisp-mcp.md`。

## 运行时产物落点

- 数据库与状态文件落 `<user-emacs-directory>/.local/state/chronos/`，默认文件
  `chronos.sqlite`（含 `-wal` / `-shm`）。
- **不在仓库根生成任何运行时文件**；`.gitignore` 已忽略 `.local/`、`chronos.sqlite*`。
- 导出产物（CSV/JSON/org 周报）默认由用户指定路径，不落仓库根。

## 已知边界

实现期确认的边界事实，改动相关代码前先读，避免把「有意为之」当 bug 修：

| 边界 | 事实 | 详见 |
|---|---|---|
| dashboard 体量 | `el-chronos-dashboard.el` **976 行**：ETAF 组件树（含 3 图表 + 5 表 + 卡片 + 弹窗）+ tabulated-list 降级页 + 可测纯函数 | `docs/adr/0002`「实施结果」 |
| ETAF 有 **10 条坑** | 组件非函数、表格名是 `etaf-table` 且 `:row-key` 必填、`text` 内非字面量须 `(expr FORM)`、列表属性须 `(quote ...)`、重挂须先 `etaf-unmount`、`:bindings` 须 `(etaf-value x)` 读、无 polyline（用 `etaf-ui-svg-path`）、batch 可挂载（可用于 ERT）、宏软依赖须 `(eval FORM t)`、tile-grid 单元格文本须单行不超 `:cell-width` | `docs/ui.org`「ETAF 实测踩坑清单」 |
| Web 单线程串行 | 请求在 Emacs 主线程同步处理（短连接 + `Connection: close`），并发请求排队；响应时间 = 查询时间；单请求上限 16KB（413），非 GET 405 | `docs/ui.org`「单线程串行处理的含义」 |
| 采样是 CPU 采样 | 纯静止/纯 `sleep` 不产生样本；阻塞期只能靠心跳证明「停转了」+ 事后栈回溯 | `docs/architecture.org`「实测结论」/「已知偏差」 |
| `total_ms` 口径 | 按栈内去重，与内置 `profiler-report` 的 total **不完全相等**；占比与回归判定一律 self 口径（TD-10） | `docs/architecture.org`「已知偏差」 |
| **`pre-command-hook` 双跑陷阱（D1）** | Emacs 31 起 `pre-command-hook` auto-buffer-local：局部值是列表时**整体遮蔽**全局值，但列表中含 `t` 标记时 `run-hooks` 会**连跑**全局默认值 → 与「全局 + 局部补挂」叠加后每条命令被记两次（`ok` + `aborted`），计数/频次/中断率翻倍。修复后**只在局部值不含 `t` 时补挂**（不含 `t` 的局部值才是完整遮蔽值），并加 **1ms 去重兜底**（同 `(命令 . 时间)` 只记一次） | `docs/architecture.org`「hook 双跑陷阱（D1）」 |
| **报告自观测抑制：只有重置心跳基线有效** | 心跳 timer 在报告生成期间**不会运行**（主线程被占），结束后才补跑一次 → 此刻 `--last-heartbeat` 仍是报告开始前时刻，gap = 报告时长，判定出巨型阻塞。三层防护中①「报告侧绑定 `el-chronos-collect--suppress-block-p`」与②「阈值临时抬到 60s」都拦不住这次**事后**补跑；唯一有效是③ `unwind-protect` 清理段**重置 `el-chronos-collect--last-heartbeat`**。副作用：报告期间若真发生阻塞也不会被记录（已声明接受） | `docs/architecture.org`「报告自观测抑制」 |
| 仍待实测 | 采样开销（TD-3）、阻塞覆盖率（TD-2）、ETAF 重绘性能（TD-5）、P95 精度（TD-7）、`.eln` 归因（TD-1） | `openspec/tech-debt.md` |

## 文档治理

| 产物类型 | 位置 |
|---|---|
| 进行中计划 | `openspec/active/<name>.md`（含「## 当前状态」区块，随进度更新） |
| 已完成计划 | `openspec/completed/`（Phase 3 完成后归档） |
| 架构决策 | `openspec/decisions.md`（表格式，一行一决策）；重要决策另写 `docs/adr/NNNN-*.md` |
| 技术债 | `openspec/tech-debt.md`（表格式，编号 TD-N） |
| 用户文档 | `Readme.org`；变更日志 `CHANGELOG.md`（Keep a Changelog 格式） |
| 技术文档 | `docs/architecture.org`（时序、数据流、实测结论）、`docs/schema.org`（DDL 与查询示例）、`docs/ui.org`（三形态界面、ETAF 组件树与坑、Web 路由）、`docs/api.org`（接口索引）、`docs/operations.org`（装卸、清理、排障） |

> 当前 `openspec/active/` 为空（只有 `.gitkeep`）：Phase 4 已完成，`el-chronos-core.md` 于 2026-10-24 归档到 `openspec/completed/`。

文档与代码同步：改接口/改 schema 必须同时更新 `docs/schema.org` 与 ADR 相关条目；
新增已完成任务须在 `CHANGELOG.md` 的 `[Unreleased]` 段记录。
