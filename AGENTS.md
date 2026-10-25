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
6. 通过浏览器 Web dashboard 与 org 报告两形态查看上述全部结论

**非目标**：自动调优/自动禁用功能、跨机器数据汇聚、源码行级采样、记录按键序列与文件内容。

当前状态：**Phase 4（Review & Document）已完成并归档**（Emacs 31.1，`make full-check` 全绿，`make test` **200** 用例全绿、0 skipped，`make lint` 零告警）。
观测面已从「时间」扩展到「时间 + 内存/GC + 启动 + 配置变更」（ADR-0004）：schema v2 增 4 表（共 10 表）、
GC 次数/耗时与堆大小趋势、启动阶段分解、`git-head` / `config-sig` 变更标记、采集器自监控（`hourly_health`）。
7 个源码模块 + 7 个测试文件 + 5 份技术文档齐备；可视化已收敛为浏览器 Web dashboard + org 报告两形态（ADR-0003）。
剩余项是仍待实测的性能/覆盖率数字与 D1 的 GUI 实机验证（见 `openspec/tech-debt.md`）。
计划见 `openspec/completed/el-chronos-core.md`（2026-10-24 归档）；
观测面扩展计划见 `openspec/completed/expand-observation-surface.md`（2026-10-25 归档，T10c）。

## 目录结构

| 路径 | 用途 | 行数 / 状态 |
|---|---|---|
| `el-chronos.el` | 自定义组、minor mode、启停编排、错误降级 | 340 行（T2、T3/T4/T6 新增 defcustom） |
| `el-chronos-collect.el` | 命令计时、心跳阻塞检测（含 D1 双跑去重）、profiler 窗口聚合、GC / 堆采样、启动打点、自监控计数 | 1246 行（T5a–c、T4、T5、T6） |
| `el-chronos-attrib.el` | 符号→文件→包/模块；命令上下文 | 342 行（T3） |
| `el-chronos-store.el` | SQLite schema（v2，10 表 + 3 索引）、批量 flush、保留策略、top-N 淘汰、purge | 1335 行（T4、T1–T3） |
| `el-chronos-analysis.el` | 17 个只读聚合查询（热点/慢命令/阻塞/包归因/趋势/热力/栈/会话/回归/GC/启动/健康/配置变更） | 761 行（T6、T7a–b） |
| `el-chronos-report.el` | org 报告（14 节）、周报、CSV/JSON 导出、按需高精度剖析、报告期间自观测抑制 | 1072 行（T7、T8、T11） |
| `el-chronos-web.el` | 最小 HTTP server（17 条路由 = 1 页 + 16 条只读 GET API）+ 内嵌 Web dashboard（HTML/CSS/JS 字符串） | 1022 行（T9） |
| `test/el-chronos-test-helper.el` | ERT 公共夹具（临时库、fixture 数据、断言辅助） | 198 行 |
| `test/el-chronos-analysis-test.el` | analysis 查询与回归判定 fixture 断言（含 GC 趋势 / 启动分解 / 健康 / 配置历史） | 640 行 / 27 用例 |
| `test/el-chronos-attrib-test.el` | 归因链与上下文（basename 不出现 `/` 断言） | 371 行 / 28 用例 |
| `test/el-chronos-collect-test.el` | 命令三态、心跳阻塞、抑制期间心跳不判定、阻塞提示三取值（nil / `messages` / t）、采样聚合、TD-9 局部 hook、D1 双跑去重、nil 帧与 C 原语归因、GC / 启动打点 / 自监控 | 1204 行 / 49 用例 |
| `test/el-chronos-report-test.el` | org 报告 14 节、周报、CSV/JSON 导出、单命令剖析 `--invoke` 三形态、`el-chronos-show-event` 交互命令、Web 500 与端口 0、CSV 区块与 Web 输出一致 | 716 行 / 32 用例 |
| `test/el-chronos-store-test.el` | schema/迁移（v1→v2 与回滚）/批量写入/保留策略/top-N 淘汰/purge 10 表/`note-startup-ms` 补写 | 1269 行 / 47 用例 |
| `test/el-chronos-web-test.el` | 内嵌 Web server（启停/路由/边界/loopback/自观测抑制/四个 v2 端点） | 442 行 / 17 用例 |
| `docs/architecture.org` | 分层、六条采集路径、可视化数据流、**实测结论**、已知偏差 | 568 行 |
| `docs/schema.org` | 最终 DDL（**10 表 + 3 索引**）、迁移 v1→v2、top-N 淘汰 SQL、保留分类、purge 10 表删除顺序 | 515 行 |
| `docs/ui.org` | 两形态总览（浏览器 Web dashboard + org 报告）、**17 条 Web 路由**、org 报告 **14 节**、性能注意与降级规则 | 196 行 |
| `docs/api.org` | elisp 对外接口索引（7 个模块、签名单、defcustom 清单、内部函数约定） | 237 行 |
| `docs/operations.org` | 安装/卸载/数据清理/排障/验证步骤/隐私与保留表 | 249 行 |
| `docs/adr/` | `0001-observer-architecture.md`、`0002-dual-visualization.md`（**已被 0003 取代**）、`0003-web-only-visualization.md`（可视化收敛为 Web dashboard + org 报告两形态）、`0004-observation-surface-expansion.md`（观测面扩展到内存/GC/启动/配置变更） | 已完成 |
| `openspec/` | 计划与决策工件（`active/`、`completed/`、`decisions.md`、`tech-debt.md`） | 已建 |
| `Makefile` | 验证入口：`check-parens` / `test` / `lint` / `full-check` | 已建 |
| `Readme.org` / `CHANGELOG.md` | 项目说明与变更日志 | 182 行 / 138 行 |

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
    `sqlite`（29+ 内置）、`profiler`、`cl-lib`、`subr-x`、`org`。
    **不引入任何第三方依赖**（不 require straight/use-package/magit 等，不新增 package 安装步骤）。
  - **`el-chronos-web.el` 零依赖**：只用内置 `make-network-process` 自写最小 HTTP server（另有内置
    `json` / `url-util` 做序列化与转义），HTML/CSS/JS 以 elisp 字符串内嵌，不引图表库与 CDN（I10）。
- **注释与文档用中文**；符号名与文件名用英文，前缀 `el-chronos-`。
- 采集路径（hook/timer/采样回调）中任何可能失败的调用必须被 `condition-case` 包裹，
  失败降级为 `unknown` 并继续，**不得向宿主抛错**。

## 不变量清单

以下 I1–I11 为**现行**不变量，违反即失败（编号不重排）：I1–I8 与 `openspec/completed/el-chronos-core.md` 逐字一致；
I9 / I11 已按 ADR-0003 改写；I10 仅删除了随 dashboard 下线的实现示例（`etaf-ui-svg-*`），语义不变。
历史版本见 `openspec/completed/el-chronos-core.md`（该文件按「不回改历史」原则保留原文）。

- **I1** 采样只用内置 C profiler，不自造采样器、不全量 advice。
- **I2** 主线程阻塞期间不依赖 Lisp 回调（证据由 SIGPROF 留存，事后回溯）。
- **I3** 数据只写 `el-chronos-db-path`（默认 `<user-emacs-directory>/.local/state/chronos/chronos.sqlite`）。
- **I4** 单位统一：API/DB 用毫秒，采样间隔用纳秒。
- **I5** `el-chronos-mode -1` 零残留：timer、hook、profiler、未 flush 缓冲。
- **I6** 归因失败降级 `unknown`，采集路径不得向宿主抛错。
- **I7** 默认不记录**被操作文件**路径、按键序列、buffer 内容与命令参数；函数归因所需的源码路径与项目 basename 除外。
- **I8** Web server 只绑定 `127.0.0.1`，默认关闭，禁止 `0.0.0.0`；只提供只读接口。loopback 仅防 LAN 暴露，不构成本机访问控制（WSL2 mirrored 下 Windows 侧可达），Web 无鉴权。
- **I9** ETAF 已完全移除：可视化层不引入 ETAF（防止回潮）。`el-chronos-dashboard.el` 与 `etaf` / `etaf-ui` 软依赖已随 ADR-0003 下线，任何"加个 Emacs 内页面"的提案须先推翻本 ADR。
- **I10** 可视化资源全部内嵌或本地生成（Web 用字符串内嵌 HTML/CSS/JS），不引第三方图表库与 CDN，离线可用。
- **I11** 任一可视化形态不可用时必须可见降级，不得静默失败：Web 端口占用 → `user-error` 且不自动换端口；Web 请求处理失败 → 明确的 HTTP 错误响应（不得挂死连接）。

## 隐私边界

- **记录**：命令名、耗时、GC 时长、major-mode、项目 **basename**、函数符号名、函数定义源码路径（归因必需）、
  `git-head`（当前提交 sha）、`config-sig`（配置文件 mtime/size 指纹，**不含文件内容**）、
  `host`（`sessions.host`，`(system-name)` 主机名，用于区分多机数据；**不含**用户名与网络地址）。
- `git-head` / `config-sig` 二者存于 `session_meta`（主键 `(session_id, key)`，每会话每键一行），
  可据此识别配置仓库状态；读法：`git-head` 只读 `.git/HEAD` 与 refs/packed-refs（**不调 git 子进程**），
  `config-sig` 只对 `el-chronos-config-watch-globs` 命中文件取 mtime/size 做 sha1（**不读文件内容**）；
  两者都**取不到就不写行**，`el-chronos-purge` 会删除。
- **不记录**：被操作文件路径、buffer 内容、按键序列、命令参数、剪贴板、环境变量。
- `commands.project` 存 `(file-name-nondirectory (directory-file-name (project-root ...)))`，即 basename，
  **不存绝对路径**；取不到时为 NULL。断言：`commands.project` 中不出现 `/`。
- Web **无鉴权**；loopback 只防 LAN 暴露，不构成本机访问控制（WSL2 mirrored 下 Windows 侧进程可达）。
- 数据生命周期：`commands` / `slow_events` 按 `el-chronos-retention-days`（默认 30）保留；
  五张 `hourly_*` 聚合表（`hourly_functions` / `hourly_usage` / `hourly_stacks` / `hourly_gc` /
  `hourly_health`）**永久保留**；会话级的 `startup_phases` / `session_meta` 随 `sessions` 行一起
  保留，全部由用户手动 `el-chronos-purge` 清理（两类的清理粒度不同，见 TD-17）。

## 错误处理矩阵（摘要）

| 故障 | 行为 | 可见性 |
|---|---|---|
| SQLite 打开失败 | 禁用采集 | `display-warning` |
| 写入/flush 失败（磁盘满、WAL 锁超时） | 丢弃本批、计数、限流告警（每 10 分钟最多一次）、继续采集 | `display-warning` |
| 归因失败 | 返回 `unknown` | 静默 |
| profiler 启动失败 | 禁用采样，命令/心跳采集继续 | `display-warning` |
| Web 端口占用 | 启动失败，不自动换端口 | `user-error` |
| 迁移失败 | 回滚 `.bak`，不破坏原库 | `display-warning` |
| 堆采样守卫失败（`garbage-collect-heapsize` 不存在） | 该字段不采，`heap_bytes` 为 NULL | 静默（按设计） |
| 启动打点钩子异常 | `condition-case` 捕获，打点停止，采集其余部分继续 | 静默（按设计） |
| 自监控 flush 失败计数 | 计数器保留，等下一次 flush 补写（eventual） | 下次成功时可见 |

完整矩阵与回归判定阈值见 `openspec/completed/el-chronos-core.md`。

## 验证入口

```sh
make check-parens   # L1：逐文件括号平衡（无 .el 时空跑成功）
make test           # L2：自动发现并加载全部 test/*-test.el（无测试文件时空跑成功）
make lint           # L1 补充：字节编译告警（输出到临时目录，不污染仓库）
make full-check     # check-parens + test
```

全部目标用 `emacs -Q --batch`，不依赖运行中的 daemon。

**当前基线**（实测 2026-10-25，本次基线回填时重测）：`make test` = **200 用例**（`Ran 200 tests, 200 results as expected, 0 unexpected`，约 12.1 秒，**0 skipped**）；
分布：collect 49 / store 47 / report 32 / attrib 28 / analysis 27 / web 17 用例；
行数：collect 1246 / store 1335 / report 1072 / web 1022 / analysis 761 / attrib 342 / 入口 340（源码 7 模块 **6118 行**）；
测试：store 1269 / collect 1204 / report 716 / analysis 640 / web 442 / attrib 371 / helper 198（测试 7 文件 **4840 行**）；源码 + 测试合计 **10958 行**。
`make lint` **零告警**（14 个文件逐个字节编译）。新增或修改行为时基线只准上升，改测试要说明原因。

**测试文件命名**：测试文件必须命名为 `test/*-test.el`；`make test` 通过 `$(sort $(wildcard test/*-test.el))` 自动发现该模式并按排序全部加载（无匹配时输出 `no test files` 并成功退出），禁止在 Makefile 里硬编码单个文件名（否则拆分测试后会静默漏跑）。

**可视化验收（Web）**：

```sh
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
| Web 单线程串行 | 请求在 Emacs 主线程同步处理（短连接 + `Connection: close`），并发请求排队；响应时间 = 查询时间；单请求上限 16KB（413），非 GET 405 | `docs/ui.org`「单线程串行处理的含义」 |
| 采样是 CPU 采样 | 纯静止/纯 `sleep` 不产生样本；阻塞期只能靠心跳证明「停转了」+ 事后栈回溯 | `docs/architecture.org`「实测结论」/「已知偏差」 |
| **采样归因口径（nil 帧与 C 原语）** | profiler 采样栈里 nil 是**填充/未解析帧**，不是函数：`--accumulate-entry` 的 leaf 与 total 门禁都用 `(and X (symbolp X))` 排除（`(symbolp nil)` 为 t，漏了会造出伪热点 `unknown`——实测曾占 38.8% 样本、total 占 98.7%）；栈序列化前 `--trim-trailing-nils` 裁掉尾部填充，全 nil 栈不写 `hourly_stacks`。**C 原语 / 内置特殊形式 / profiler 伪符号**（`redisplay_internal (C function)`、`Automatic GC`）`symbol-file` 为 nil，由 `el-chronos-attrib--builtin-primitive-p` 判为 `built-in`（实测曾被误判 `unknown`，占 37.1% 样本）（判据排除 `native-comp-function-p`：`subrp` 对 native-comp 函数也为 t，若漏判会把 straight 包的 native-comp 函数短路成 built-in，破坏 `.eln` 反查归因）。**已知不对称**：闭包叶子（非符号）仍被丢弃、不进 `hourly_functions`（只出现在 `hourly_stacks` 作 `anonymous`），未与 nil 帧统一处置（TD-14） | `docs/architecture.org`「采样归因口径」、TD-13 / TD-14 |
| **阻塞提示默认静默** | `el-chronos-collect-notify-blocks` 默认 **nil**：心跳判定出阻塞后**只落库**，既不占 echo area 也不写 `*Messages*`。取值 `messages` → `(let ((inhibit-message t)) (message ...))` 只进 `*Messages*`；`t` 才真的 echo（旧语义）。**提示开关不影响采集**：三种取值下 `slow_events(kind="block")` 都照记。默认静默的原因：提示会盖住 minibuffer 候选、打断输入，而阻塞事后在 org 报告 / Web dashboard 里可查——所以「echo area 没出现提示」不是漏记，查库即可 | `docs/operations.org`「阻塞提示」 |
| `total_ms` 口径 | 按栈内去重，与内置 `profiler-report` 的 total **不完全相等**；占比与回归判定一律 self 口径（TD-10） | `docs/architecture.org`「已知偏差」 |
| **`pre-command-hook` 双跑陷阱（D1）** | Emacs 31 起 `pre-command-hook` auto-buffer-local：局部值是列表时**整体遮蔽**全局值，但列表中含 `t` 标记时 `run-hooks` 会**连跑**全局默认值 → 与「全局 + 局部补挂」叠加后每条命令被记两次（`ok` + `aborted`），计数/频次/中断率翻倍。修复后**只在局部值不含 `t` 时补挂**（不含 `t` 的局部值才是完整遮蔽值），并加 **1ms 去重兜底**（同 `(命令 . 时间)` 只记一次） | `docs/architecture.org`「hook 双跑陷阱（D1）」 |
| **自观测抑制（report / Web，三层 + 心跳侧感知）** | 观测者会观测到自己的重查询，必须抑制。**机制**：`el-chronos-collect--heartbeat` 用 `bound-and-true-p` 读取 `el-chronos-collect--suppress-block-p`——抑制期间**推进 `--last-heartbeat` 基线并跳过判定**；report（`el-chronos-report--without-block-events`）与 Web（`el-chronos-web--without-block-events`）在渲染 / 请求处理前各自绑定该抑制变量、把 `el-chronos-block-threshold-ms` 临时抬到 60s，并在 `unwind-protect` 清理段**再重置基线**。**结论**：抑制期间不产生 block 事件，解除绑定后也不补记整段 gap。**取舍**：抑制期间若真发生阻塞同样不记（有意接受——用户主动触发的重查询耗时不属待排查卡顿）。**覆盖面**：report 与 Web 均抑制，两份为**内联重复实现**（web 刻意不 require report / collect，保持零额外依赖），改动需同步两处；TD-12 已关闭 | `docs/architecture.org`「自观测抑制（report / Web）」 |
| **内存 / GC 观测口径** | `heap_bytes` 来自 `(garbage-collect-heapsize)`（Emacs **31.1+** 才有，29/30 恒 NULL）；`gc_count` / `gc_ms` 来自 `gcs-done` / `gc-elapsed` 的**增量**（只读全局计数器，**零副作用、不触发 GC**；采集路径**禁止**调 `garbage-collect`，也禁止用 `memory-info`——那是系统内存）；首个采样窗口只建基线（丢 ≤1 窗口增量，故首桶计数可能为 0 而非「没发生 GC」）；`hourly_gc.heap_bytes` 用 `COALESCE` 保留本行最后一次非 NULL 观测值（同会话同小时的稀疏写入，非跨版本问题）；跨 Emacs 版本共用同一库时曲线会空洞，阅读时按 `sessions.emacs_version` 分组（TD-15） | `docs/architecture.org`「路径 6：GC 与自监控」/「已知偏差」、TD-15 |
| **启动分解覆盖范围** | `startup_phases` 的包加载明细基于 `after-load-functions` **相邻两次回调的时间差**（**近似归因**，差值含前一文件的收尾逻辑与它触发的钩子）；**mode 在 `after-init-hook` 之前启用**才记明细，启动已结束时只有 `mode-start` 锚点、且**根本不挂** `after-load-functions`（否则启动后的交互式 load 会被记成「启动耗时」）——观测器无法观测自己被加载之前的事，这是物理边界不是 bug；要完整剖析须把 `(el-chronos-mode 1)` 提前到 `early-init.el`（TD-16） | `docs/architecture.org`「路径 5：启动打点」/「已知偏差」、`docs/operations.org`「启动分解的物理边界」、TD-16 |
| 仍待实测 | P95 精度（TD-7）、阻塞捕获残余缺口（TD-11） | `openspec/tech-debt.md` |
| 采样开销 | 10ms 默认间隔的常驻开销**低于本机测量分辨率**（噪声地板 ±0.7–1.1%）：1ms 间隔（采样率约 10×）实测 +0.46%，按单样本成本外推 10ms ≈ 0.02–0.2%，**远低于 0.5% 阈值**，保持 10ms 默认（TD-3 已关闭） | `docs/architecture.org`「实测结论 11」 |

## 文档治理

| 产物类型 | 位置 |
|---|---|
| 进行中计划 | `openspec/active/<name>.md`（含「## 当前状态」区块，随进度更新） |
| 已完成计划 | `openspec/completed/`（Phase 3 完成后归档） |
| 架构决策 | `openspec/decisions.md`（表格式，一行一决策）；重要决策另写 `docs/adr/NNNN-*.md` |
| 技术债 | `openspec/tech-debt.md`（表格式，编号 TD-N） |
| 用户文档 | `Readme.org`；变更日志 `CHANGELOG.md`（Keep a Changelog 格式） |
| 技术文档 | `docs/architecture.org`（时序、数据流、实测结论）、`docs/schema.org`（DDL 与查询示例）、`docs/ui.org`（两形态界面、Web dashboard 路由与降级规则）、`docs/api.org`（接口索引）、`docs/operations.org`（装卸、清理、排障）、`docs/adr/0001`–`0004`（架构决策，0004 = 观测面扩展） |

> 当前 `openspec/active/` **为空**（全部计划已归档）；`expand-observation-surface.md`（Phase 4 已完成，含「实现期勘误」）、`remove-dashboard-web-only.md`、`fix-web-block-suppression.md`、`fix-sampling-attribution.md` 均在 `openspec/completed/`（2026-10-24 / 2026-10-25）。

文档与代码同步：改接口/改 schema 必须同时更新 `docs/schema.org` 与 ADR 相关条目；
新增已完成任务须在 `CHANGELOG.md` 的 `[Unreleased]` 段记录。
