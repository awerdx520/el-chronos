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

当前状态：**Phase 4（Review & Document）已完成并归档**（Emacs 31.1，`make full-check` 全绿，`make test` **375** 用例全绿、0 skipped，`make lint` 零告警）。
观测面已从「时间」扩展到「时间 + 内存/GC + 启动 + 配置变更」（ADR-0004）：schema v2 增 4 表、
GC 次数/耗时与堆大小趋势、启动阶段分解、`git-head` / `config-sig` 变更标记、采集器自监控（`hourly_health`）。
**S2（亚秒级「命令外停转」可见）已实现**（ADR-0005）：schema **v3 增 `hourly_drift`（共 11 表）**、
两档阈值（block 2000ms 明细 + drift 500ms 小时聚合）、心跳 1s → **250ms**（block 高估上界 1s → 250ms）、
命令结算后重置心跳基线以**结构性消除双记**。
**启动探针 + 资源观测已落地**（ADR-0006）：schema **v4 增 `hourly_resources`（共 12 表）**——进程 CPU / RSS /
线程数 / 系统负载按小时桶累积；启动探针独立成**零依赖**文件 `el-chronos-startup-probe.el`（由用户在
`early-init.el` 显式 `(load … t)`，因此能测到 init 主体）、资源采集复用既有 10 秒采样 timer（TRAMP 守卫、
逐字段降级）；analysis **22** 个只读分析函数（另有 `names` 作为补全辅助，不计入；口径：
22 = 23 个 public defun 减去 `names` 补全辅助）（新增栈包含归因 `inclusive-functions`、`resource-trend` /
`resource-summary` 与 **GC 归因 `gc-attribution`**）/ Web **19** 条路由（新增 `/api/resources`）/ org 报告 **16 节**
（新增「资源（CPU / 内存 / 负载）」与「**GC 归因（发生在哪条命令之后）**」两节；「栈包含占比 TOP」是
「热点函数」节内的 `**` 子小节，**不增节**；drift 摘要仍嵌在「阻塞事件」节内）。
**GC 归因已完成并归档**（`openspec/completed/gc-attribution.md`，2026-10-26 归档）：schema **v5 增 `hourly_gc_attrib`（共 13 表）**——
`post-gc-hook` 把每次 GC 按 `this-command` × `major-mode` 归因（hook 热路径**零分配**，字符串转换推迟到
10 秒窗口 flush）；表回答「GC **发生在**哪条命令之后」而非「哪条命令**导致** GC」，且
`sum(gc_attrib.gc_count) ≤ hourly_gc.gc_count`（差值 = hook 安装前 / 采集窗口外的 GC，**禁做等式校验**）。
**归因键的实测边界**：GC 时刻没有正在执行的命令时（启动期、batch、命令循环**等待输入**期间，含 idle timer /
进程过滤器回调）`this-command` 为 `nil` → 一律归 `"<none>"`；本机真实库实测 **37/45（88.1%）落 `<none>`**，且集中
在交互会话（`eca-chat-mode` / `fundamental-mode` / `magit-status-mode`）——故命令维度覆盖率有限，只对「命令执行期
GC」有效，mode 维度更稳。真实库副本迁移实测：v4 → v5 后 `user_version=5`、12 → 13 表、既有 12 表一行不变、
`sqlite_master` 与真实库逐字相同；`--migrate` 新增「版本相等即早退」守卫（不 checkpoint、不生成 `.bak`），其守门
用例让总数到 **336**。
**多实例并发写已完成并归档**（`openspec/completed/multi-instance-concurrency.md`，ADR-0007，2026-10-30 归档）：
「两个 Emacs 实例共用同一库」的锁竞争从「当故障丢弃」改为**自愈 + 降竞争**——会话行**延迟补建**
（`--ensure-session` 撞锁不再让 `store-open` 返回 nil）、flush 撞锁**保留重试**（`sqlite-locked-error` 保留明细 +
慢事件 + 九个聚合 hash，连续 6 次才丢弃）、**30 秒撞锁退避**（12 次 flush 累计阻塞 ≈96 s → **9.54 s**）、
7 处写事务改 `BEGIN IMMEDIATE`、`busy_timeout` 启动 2000 ms / 后台写 8000 ms 分层、`--prune` 候选预检 +
1 小时节流、新增 `hourly_health.busy-retries` 自监控（八处消费点同步）。用例总数 **336 → 375**（+39）。
8 个源码模块 + 9 个测试文件 + 5 份技术文档齐备；可视化已收敛为浏览器 Web dashboard + org 报告两形态（ADR-0003）。
剩余项是仍待实测的性能/覆盖率数字与 D1 的 GUI 实机验证（见 `openspec/tech-debt.md`）。
计划见 `openspec/completed/el-chronos-core.md`（2026-10-24 归档）；
观测面扩展计划见 `openspec/completed/expand-observation-surface.md`（2026-10-25 归档，T10c）；
drift 两档阈值计划见 `openspec/completed/add-drift-detection.md`（T1–T4 已完成，2026-10-25 归档）；
use-package 适配计划见 `openspec/completed/add-use-package-support.md`（T1–T8 已完成，2026-10-25 归档）；
启动探针 + 资源观测计划见 `openspec/completed/startup-probe-and-resources.md`（T1–T9 全部完成，ADR-0006，2026-10-26 归档）；
观测能力收敛计划见 `openspec/completed/2026-10-26-compact-observability.md`（栈包含归因 + `kind='command'` 的
`stack_json` 不再记自身栈，T1–T5 全部完成，2026-10-26 归档）。
**当前 `openspec/active/` 为空**（只剩 `.gitkeep`）；GC 归因计划已归档为
`openspec/completed/gc-attribution.md`（C1a / C1b / C1c / 全量验证全部完成，2026-10-26 归档），
多实例并发写计划归档为 `openspec/completed/multi-instance-concurrency.md`（T1–T10 全部完成，ADR-0007，2026-10-30 归档），详见「文档治理」段。

## 目录结构

| 路径 | 用途 | 行数 / 状态 |
|---|---|---|
| `el-chronos.el` | 自定义组、minor mode、启停编排、错误降级 | 421 行 / 21 defcustom（项目合计 23） |
| `el-chronos-collect.el` | 命令计时、心跳「命令外停转」两档判定（含 D1 双跑去重、`--heartbeat-check` 单一判定入口）、profiler 窗口聚合、GC / 堆采样、**`post-gc-hook` GC 归因（内存二级 hash + 零分配热路径）**、**资源采集（CPU / RSS / 线程 / 系统负载）**、启动打点（**含探针交接**）、自监控计数 | 1702 行 |
| `el-chronos-attrib.el` | 符号→文件→包/模块；命令上下文 | 343 行 |
| `el-chronos-store.el` | SQLite schema（v5，13 表 + 3 索引）、批量 flush（**撞锁保留重试 + 30 秒退避 + `BEGIN IMMEDIATE`**）、会话行延迟补建、`busy_timeout` 分层、drift 小时聚合、**资源小时聚合**、**GC 归因小时聚合**、保留策略（**prune 候选预检 + 1 小时节流**）、top-N 淘汰、purge 13 表 | 2241 行 |
| `el-chronos-analysis.el` | 22 个只读分析函数（另有 `names` 作为补全辅助，不计入）（热点/慢命令/阻塞/命令外停转/包归因/趋势/热力/栈/**栈包含归因**/会话/回归/GC/**GC 归因**/启动/健康（含 **`busy-retries`**）/配置变更/**资源趋势与汇总**） | 1261 行 |
| `el-chronos-report.el` | org 报告（16 节，含「阻塞事件」节内的 drift 汇总行、「热点函数」节内的 `** 栈包含占比 TOP` 子小节、「资源」与「**GC 归因**」节）、周报、CSV/JSON 导出（10 个区块）、按需高精度剖析、报告期间自观测抑制 | 1426 行 |
| `el-chronos-web.el` | 最小 HTTP server（19 条路由 = 1 页 + 17 条只读 GET API + 1 CSV）+ 内嵌 Web dashboard（HTML/CSS/JS 字符串） | 1279 行 |
| `el-chronos-startup-probe.el` | **零依赖**启动探针：`early-init` / `after-init` / `startup` 三锚点 + 按库累计的 `after-load-functions` 时间差；只写内存、不开库不写库；三条自证收尾路径（`emacs-startup-hook` / `load-count` 800 / `after-init` 30 秒兜底 timer） | 318 行 |
| `test/el-chronos-test-helper.el` | ERT 公共夹具（临时库、fixture 数据、断言辅助） | 198 行 |
| `test/el-chronos-analysis-test.el` | analysis 查询与回归判定 fixture 断言（含 GC 趋势 / 启动分解 / 健康（含 **`busy-retries` 且 `:ok-p` 不受其影响**） / 配置历史 / drift 趋势 / **栈包含归因 / 资源趋势与汇总 / GC 归因（command 与 mode 两维度）**） | 1296 行 / 58 用例 |
| `test/el-chronos-attrib-test.el` | 归因链与上下文（basename 不出现 `/` 断言） | 371 行 / 28 用例 |
| `test/el-chronos-autoload-test.el` | autoload 契约：cookie 覆盖 16 个 interactive 命令（计数不变量）、生成物让命令 `autoloadp`、库名等于定义文件 | 295 行 / 3 用例 |
| `test/el-chronos-collect-test.el` | 命令三态、心跳阻塞、抑制期间心跳不判定、阻塞提示三取值（nil / `messages` / t）、**命令外两档阈值（block / drift）与 `--finish` 重置基线**、`--pre-command` 补判、采样聚合、TD-9 局部 hook、D1 双跑去重、nil 帧与 C 原语归因、GC / 启动打点 / 自监控、**探针交接与资源采集降级**、**`post-gc-hook` 归因（差值 / 零分配 / 装配拆除）** | 2204 行 / 87 用例 |
| `test/el-chronos-report-test.el` | org 报告 16 节、阻塞事件节内的 drift 汇总行、热点函数节内的栈包含子小节、**资源节与 GC 归因节**、**健康节的 `busy-retries` 与 health CSV 列**、周报、CSV/JSON 导出、单命令剖析 `--invoke` 三形态、`el-chronos-show-event` 交互命令、Web 500 与端口 0、CSV 区块与 Web 输出一致 | 998 行 / 41 用例 |
| `test/el-chronos-startup-probe-test.el` | 探针：三锚点记录、`after-load` 差值、`take` 增量语义（`anchors` 只读、`loads` 取走即清空）、无 `before-init-time` 不崩、异常吞掉 | 342 行 / 16 用例 |
| `test/el-chronos-store-test.el` | schema/迁移（v0→v5、v1→v5、v2→v5、v3→v5、v4→v5 五条守门与回滚，事务语句为 `BEGIN IMMEDIATE`）/批量写入/drift、**撞锁保留重试（`--buffer` + 慢事件 + 九个聚合 hash 全保留）/ streak 上限丢弃 / 退避门不碰库 / close 绕过退避 / 丢弃计入 `dropped-*` / 结果告警不被限流吞掉 / `busy-retries` 上报与 `--pending-p` / `busy_timeout` 分层与恢复 / prune 候选预检与节流**、**资源**与 **GC 归因** 聚合/保留策略/top-N 淘汰/purge 13 表（**COMMIT 后补建会话行撞锁不误报回滚**）/`note-startup-ms` 补写 | 3240 行 / 114 用例 |
| `test/el-chronos-web-test.el` | 内嵌 Web server（启停/路由/边界/loopback/自观测抑制/四个 v2 端点 + `/api/drift` + **`/api/resources`** + **`/api/health` 的 `busy_retries`** /CSV/浏览器自动打开三形态） | 738 行 / 28 用例 |
| `docs/architecture.org` | 分层、七条采集路径（路径 3 = 心跳两档判定 + 三处调用点）、**启动探针（early-init 路径）**、**资源采集（路径 6 扩展）**、**GC 归因支路（post-gc-hook）**、可视化数据流、**实测结论**、已知偏差 | 930 行 |
| `docs/schema.org` | 最终 DDL（**13 表 + 3 索引**）、迁移链 v0/v1/v2/v3/v4 → v5（含迁移链陷阱）、top-N 淘汰 SQL、保留分类、purge 13 表删除顺序、**`hourly_resources` 的 `cpu_pct = 0` 两义（TD-28）**、**`hourly_gc_attrib` 的四元主键与「主键含 NULL 让 upsert 静默失效」** | 855 行 |
| `docs/ui.org` | 两形态总览（浏览器 Web dashboard + org 报告）、**19 条 Web 路由**、org 报告 **16 节**、性能注意与降级规则 | 287 行 |
| `docs/api.org` | elisp 对外接口索引（**8 个模块 / 23 个 defcustom** 清单）、签名单、内部函数约定 | 457 行 |
| `docs/operations.org` | 安装/卸载/数据清理/排障/**drift 调档指引**/验证步骤/隐私与保留表 | 671 行 |
| `docs/adr/` | `0001-observer-architecture.md`、`0002-dual-visualization.md`（**已被 0003 取代**）、`0003-web-only-visualization.md`（可视化收敛为 Web dashboard + org 报告两形态）、`0004-observation-surface-expansion.md`（观测面扩展到内存/GC/启动/配置变更）、`0005-two-tier-block-detection.md`（两档阈值：block 明细 + drift 聚合，v3 schema）、`0006-resource-observation.md`（启动探针提前到 early-init + 资源维度观测，v4 schema）、`0007-multi-process-write-concurrency.md`（多进程共享库的锁竞争：自愈 + 降竞争 + 可量化，2026-10-30 已实施） | 已完成 |
| `openspec/` | 计划与决策工件（`active/`、`completed/`、`decisions.md`、`tech-debt.md`） | 已建 |
| `Makefile` | 验证入口：`check-parens` / `test` / `lint` / `full-check` / `autoloads`（生成 `el-chronos-autoloads.el`，产物不入库、不进 L1/L2） | 已建 |
| `Readme.org` / `CHANGELOG.md` | 项目说明与变更日志 | 393 行 / 187 行 |

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
- **autoload 契约（不变量，机械可检）**：**所有 interactive 命令必须带 `;;;###autoload` cookie**
  （当前 16 个：入口 2 / 归因 1 / 存储 3 / 采集 2 / 报告 5 / Web 3）。cookie 紧贴 `defun` /
  `define-minor-mode` 的上一行；生成入口 `make autoloads`，产物 `el-chronos-autoloads.el`
  **不入库、不进 L1/L2**（`EL_FILES` 的 `find` 显式排除，否则生成后检查范围会随生成物变化）。
  守门用例在 `test/el-chronos-autoload-test.el`：计数不变量（代码中 `(interactive` 出现次数
  + `define-minor-mode` 数 = cookie 数 = 命令清单长度，**不写死数字**，增删命令时用例自动跟随）。
  新增 interactive 命令时须**同一次改动**内补 cookie，否则用例变红。
- **依赖边界（三档）**：
  - **核心模块**（`collect` / `attrib` / `store` / `analysis` / `report`）仅使用 Emacs 内置库——
    `sqlite`（29+ 内置）、`profiler`、`cl-lib`、`subr-x`、`org`。
    **不引入任何第三方依赖**（不 require straight/use-package/magit 等，不新增 package 安装步骤）。
  - **`el-chronos-web.el` 零依赖**：只用内置 `make-network-process` 自写最小 HTTP server（另有内置
    `json` / `url-util` 做序列化与转义），HTML/CSS/JS 以 elisp 字符串内嵌，不引图表库与 CDN（I10）。
  - **`el-chronos-startup-probe.el` 零依赖更严格**：**不得 require 任何 el-chronos 模块**，也**不得**
    require `cl-lib` / `subr-x`，只用内置 subr（`float-time` / `puthash` / `gethash` / `add-hook` /
    `remove-hook` / `run-with-timer` / `condition-case`）——early-init 期 `straight/build-*` 还没建立，
    任何 require 都可能失败并打断启动。它也**不开库、不建库、不写库**：SQLite 与 flush 事务全部留给
    collect，启动路径上不出现任何可能阻塞的 IO。
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

**探针的 I5 例外**（既有取舍，**不是新不变量编号**，见 ADR-0006 D1）：`el-chronos-startup-probe.el`
**不在 `el-chronos-mode` 的生命周期内**——它由用户在 `early-init.el` 里显式 `(load … t)` 加载，
`el-chronos-mode -1` 碰不到它，因此 I5 的「零残留」不覆盖它（要摘它只能重启 Emacs 或显式调
`el-chronos-startup-probe--reset`）。其残留防护靠**三条自证路径**汇到 `--finish`：① 正常路径
`emacs-startup-hook` 回调（自摘 `emacs-startup-hook` / `after-init-hook`，记 `startup` 锚点，登记
0 秒收尾 timer）；② `load-count` 达 **800** 时兜底（只为兜住「`emacs-startup-hook` 永不触发」的
病态情形，**不是业务阈值**，不可配置）；③ `after-init-hook` 里登记的 **30 秒兜底 timer**（init 报错时
`emacs-startup-hook` 不会跑）。`--finish` 自摘全部钩子并 `cancel-timer` 两个 timer，只留内存数据
等 collect `take`。

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
  七张 `hourly_*` 聚合表（`hourly_functions` / `hourly_usage` / `hourly_stacks` / `hourly_gc` /
  `hourly_health` / `hourly_drift` / `hourly_resources`）**永久保留**；会话级的 `startup_phases` /
  `session_meta` 随 `sessions` 行一起保留，全部由用户手动 `el-chronos-purge` 清理（两类的清理粒度不同，见 TD-17）。
- `hourly_resources` 记的是**进程 / 系统级数值**——Emacs 进程 CPU 毫秒、RSS（KB）、线程数、
  系统负载 1/5/15——**不含任何用户内容**（不涉 I7）：只查 `(emacs-pid)` 自己的
  `process-attributes`，不遍历全系统进程、不读命令行、不读 buffer；系统内存（`memory-info`）**明确不采**
  （那是整机内存且 remote `default-directory` 下查的是远端主机，TD-15）。

## 错误处理矩阵（摘要）

| 故障 | 行为 | 可见性 |
|---|---|---|
| SQLite 打开失败 | 禁用采集 | `display-warning` |
| 写入/flush 失败（撞锁 `sqlite-locked-error`） | **保留重试 → 30 秒退避 → 超限（连续 6 次）丢弃**：撞锁时 `ROLLBACK` 后保留命令缓冲 + 慢事件 + 九个聚合 hash，置退避 30 秒（到期前 flush 不碰库）；连续 6 次才按原语义丢弃并计入 `dropped-*`；退避走完后成功则清零 streak（§ADR-0007 D2 / D7） | `display-warning`（过程告警限流每 10 分钟一次；**丢弃结果告警不节流**） |
| 写入/flush 失败（非锁错误：磁盘满、句柄失效等） | **丢弃本批**、计入 `dropped-commands` / `dropped-events` 与 `flush-failures`、限流告警、继续采集（不退避——本批已丢，`--pending-p` 自然清空） | `display-warning`（限流） |
| 打开库时会话行撞锁（`--ensure-session`） | **打开成功、会话行延迟补建**：`store-open` 仍返回句柄并起 flush timer，`session-id` 暂为 nil，下一次 flush 批前补建；补建成功前明细保留、聚合按 record 期口径跳过（TD-36），`sessions.started_at` 取补建时刻（TD-38） | 静默（只累加 `busy-retries`） |
| 归因失败 | 返回 `unknown` | 静默 |
| profiler 启动失败 | 禁用采样，命令/心跳采集继续 | `display-warning` |
| Web 端口占用 | 启动失败，不自动换端口 | `user-error` |
| 迁移失败 | 回滚 `.bak`，不破坏原库 | `display-warning` |
| 堆采样守卫失败（`garbage-collect-heapsize` 不存在） | 该字段不采，`heap_bytes` 为 NULL | 静默（按设计） |
| `process-attributes` / `load-average` 取不到（TRAMP 远端、系统调用失败、字段缺失） | 该字段落 NULL、本窗口不计入对应累加（`load_n` 不加），其余字段照采 | 静默（按设计） |
| 启动打点钩子异常 | `condition-case` 捕获，打点停止，采集其余部分继续 | 静默（按设计） |
| 自监控 flush 失败计数 | 计数器保留，等下一次 flush 补写（eventual） | 下次成功时可见 |

完整矩阵与回归判定阈值见 `openspec/completed/el-chronos-core.md`。

## 验证入口

```sh
make check-parens   # L1：逐文件括号平衡（无 .el 时空跑成功）
make test           # L2：自动发现并加载全部 test/*-test.el（无测试文件时空跑成功）
make lint           # L1 补充：字节编译告警（输出到临时目录，不污染仓库）
make autoloads      # 生成 el-chronos-autoloads.el（按需生成；产物不入库、不进 L1/L2）
make full-check     # check-parens + test
```

全部目标用 `emacs -Q --batch`，不依赖运行中的 daemon。`make autoloads` 在 Emacs 29.1+ 走
`loaddefs-generate`，更早版本回退 `make-directory-autoloads`（ERT 用例同源守卫，不硬编码单一实现）。

**当前基线**（实测 2026-10-30，多实例并发写归档时重测）：`make test` = **375 用例**（`Ran 375 tests, 375 results as expected, 0 unexpected`，**0 skipped**；耗时 **约 5–35 秒**，视机器负载与撞锁用例内的真实等锁/退避等待——本次实测 32.7 秒）；
分布：store 114 / collect 87 / analysis 58 / report 41 / attrib 28 / web 28 / startup-probe 16 / autoload 3 用例（合计 375）；
行数：store 2241 / collect 1702 / report 1426 / web 1279 / analysis 1261 / 入口 421 / attrib 343 / startup-probe 318（源码 8 模块 **8991 行**）；
测试：store 3240 / collect 2204 / analysis 1296 / report 998 / web 738 / attrib 371 / startup-probe 342 / autoload 295 / helper 198（测试 9 文件 **9682 行**）；源码 + 测试合计 **18673 行**。
`make lint` **零告警**（17 个文件逐个字节编译，含 `test/*.el`；`el-chronos-autoloads.el` 由 `EL_FILES` 排除，不在检查范围）。
新增或修改行为时基线只准上升，改测试要说明原因。

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
| **`slow_events.stack_json` 对命令型事件恒 NULL** | `kind='command'` 的慢事件 `stack_json` **恒为 NULL**——原先是「有值但无意义」：`--post-command` 结算时命令帧已弹出，记录的全是采集器自身帧（`--post-command → --finish → --safe-apply → --current-stack → backtrace-frames`）。命令执行期的栈**无法在结算时刻事后取得**，故该字段对 command 类事件不携带信息；命令归属请查 `hourly_stacks` 的同时段样本（按命令窗口切分采样聚合见 TD-26）。`kind='block'` 的 `stack_json` 本来就恒 NULL（TD-2）。**消费该字段的外部脚本会看到差异** | `openspec/completed/2026-10-26-compact-observability.md` T1、TD-26、`CHANGELOG.md`「变更」 |
| **阻塞提示默认静默** | `el-chronos-collect-notify-blocks` 默认 **nil**：心跳判定出阻塞后**只落库**，既不占 echo area 也不写 `*Messages*`。取值 `messages` → `(let ((inhibit-message t)) (message ...))` 只进 `*Messages*`；`t` 才真的 echo（旧语义）。**提示开关不影响采集**：三种取值下 `slow_events(kind="block")` 都照记。默认静默的原因：提示会盖住 minibuffer 候选、打断输入，而阻塞事后在 org 报告 / Web dashboard 里可查——所以「echo area 没出现提示」不是漏记，查库即可 | `docs/operations.org`「阻塞提示」 |
| `total_ms` 口径 | 按栈内去重，与内置 `profiler-report` 的 total **不完全相等**；占比与回归判定一律 self 口径（TD-10） | `docs/architecture.org`「已知偏差」 |
| **`pre-command-hook` 双跑陷阱（D1）** | Emacs 31 起 `pre-command-hook` auto-buffer-local：局部值是列表时**整体遮蔽**全局值，但列表中含 `t` 标记时 `run-hooks` 会**连跑**全局默认值 → 与「全局 + 局部补挂」叠加后每条命令被记两次（`ok` + `aborted`），计数/频次/中断率翻倍。修复后**只在局部值不含 `t` 时补挂**（不含 `t` 的局部值才是完整遮蔽值），并加 **1ms 去重兜底**（同 `(命令 . 时间)` 只记一次） | `docs/architecture.org`「hook 双跑陷阱（D1）」 |
| **命令外停转的语义（v3 两档阈值）** | `hourly_drift` 只记**命令之外**的 500–2000 ms 停转（次数 / 累计 / 最坏，每会话每小时一行）；命令**内**停转由 `commands` 的 `duration_ms` **独占**（≥200 ms 另进 `slow_events(kind='command')`）—— 排除机制不靠判据，而是 `--finish` 结算时把心跳基线重置到当前时刻，命令时间根本不进 `gap`，因此**双记（TD-11 ③）被结构性消除**。**两表不可相加**（不相交集合：命令间隙的停转 vs 命令总耗时）；`block` 的 `command` 列恒 nil 是正确行为（只记命令外，没有命令可归因）。**跨版本注意**：v3 之前的 `slow_events(kind='block')` 含命令内停转（与 `kind='command'` 双记），v3 之后只有命令外 → 趋势对比必须按时间点切开 | `docs/architecture.org`「路径 3：心跳」/「已知偏差」、`docs/schema.org`「hourly_drift」、ADR-0005 |
| **连续命令流中的累计卡顿不可见** | 卡顿分散在几十条 20–50 ms 的连续命令里（总 1.5 s、**单条都不慢**）时：单条都进不了 `slow_events`（<200 ms 阈值）、命令时间又被基线重置切掉 → **block / drift 与 `slow_events` 都看不到** | 方案 B（重置换判据）的结构性能力损失（ADR-0005 备选⑧/⑩ 的取舍）：只能查 `commands` 的时间戳密度人工解读。**不是采集器坏了**，见 `docs/architecture.org`「已知偏差」 |
| **自观测抑制（report / Web，三层 + 心跳侧感知）** | 观测者会观测到自己的重查询，必须抑制。**机制**：`el-chronos-collect--heartbeat-check` 用 `bound-and-true-p` 读取 `el-chronos-collect--suppress-block-p`——抑制期间**推进 `--last-heartbeat` 基线并跳过判定**（**block 与 drift 两档共用这个门**）；report（`el-chronos-report--without-block-events`）与 Web（`el-chronos-web--without-block-events`）在渲染 / 请求处理前各自绑定该抑制变量、把 `el-chronos-block-threshold-ms` 临时抬到 60s，并在 `unwind-protect` 清理段**再重置基线**（这一层不可省：渲染期间没有命令结算，`--finish` 的重置替代不了它）。**结论**：抑制期间不产生 block / drift，解除绑定后也不补记整段 gap。**取舍**：抑制期间若真发生阻塞同样不记（有意接受——用户主动触发的重查询耗时不属待排查卡顿）。**覆盖面**：report 与 Web 均抑制，两份为**内联重复实现**（web 刻意不 require report / collect，保持零额外依赖），改动需同步两处；TD-12 已关闭 | `docs/architecture.org`「自观测抑制（report / Web）」 |
| **内存 / GC 观测口径** | `heap_bytes` 来自 `(garbage-collect-heapsize)`（Emacs **31.1+** 才有，29/30 恒 NULL）；`gc_count` / `gc_ms` 来自 `gcs-done` / `gc-elapsed` 的**增量**（只读全局计数器，**零副作用、不触发 GC**；采集路径**禁止**调 `garbage-collect`，也禁止用 `memory-info`——那是系统内存）；首个采样窗口只建基线（丢 ≤1 窗口增量，故首桶计数可能为 0 而非「没发生 GC」）；`hourly_gc.heap_bytes` 用 `COALESCE` 保留本行最后一次非 NULL 观测值（同会话同小时的稀疏写入，非跨版本问题）；跨 Emacs 版本共用同一库时曲线会空洞，阅读时按 `sessions.emacs_version` 分组（TD-15） | `docs/architecture.org`「路径 6：GC 与自监控」/「已知偏差」、TD-15 |
| **多实例共享库的锁竞争** | **SQLite 单写者 + 多实例共享一个库是设计意图**（`sessions.host` / `hourly_*` 的主键设计只有在多进程写同一库时才有意义，I3 又固定「只写一个库文件」，ADR-0007）。故锁竞争是**正常语义**，按自愈处置：会话行**延迟补建**（open 不因撞锁返回 nil）、flush 撞锁**保留重试**（明细 + 慢事件 + 九个聚合 hash，连续 6 次才丢）、**30 秒退避**、写事务 `BEGIN IMMEDIATE`、`busy_timeout` 启动 2 s / 后台写 8 s 分层、prune 候选预检。**自愈 vs 真丢的判据**：`busy-retries` / `flush-failures` 上升只说明**撞过锁**（两者在「保留重试」与「达上限丢弃」上表现完全一样，**不能**用来区分）；真丢看 **`dropped-commands` / `dropped-events` 是否上升**、以及是否出现「本批已按计划丢弃」这条**结果告警**（`--warn-force`，绕 600 秒限流；过程告警「保留重试（第 N/6 次）」走限流，看到它**不等于**丢数据）。**代价**：撞锁后退避 30 秒，崩溃丢数据窗口从 5 s 放大到 **35 s**（不要为缩回 5 s 取消退避——那会让主线程被 12 × 8.01 s 占满）。**已知口径偏差**：延迟补建期间聚合数据缺一段（TD-36）、`sessions.started_at` 可能等于**补建时刻**而非真实启动（TD-38，会话时长权威下界取 `min(commands.ts)`） | ADR-0007、`docs/architecture.org`「多进程并发写」、`docs/operations.org`（`database is locked` 排障 + 多实例共享库的正常/故障判据）、TD-36 / TD-37 / TD-38 |
| **GC 归因的 command 维度覆盖率有限** | 归因键是 GC 时刻的 `this-command`：**GC 时刻没有正在执行的命令**时它是 `nil` → 记 `"<none>"`——启动期、batch、命令循环**等待输入**期间，含 idle timer / 进程过滤器回调。本机真实库实测 **45 次归因中 37 次（88.1%）落 `<none>`**，且集中在交互会话（`eca-chat-mode` / `fundamental-mode` / `magit-status-mode`），**不是**启动期或 batch。故本表主要给 **mode 维度**与「命令执行期 GC」用；**不要**把 `<none>` 读成采集 bug，也不要写「idle / 进程过滤器里 `this-command` 是上一条命令」（命令循环只在运行命令前才设置它）。`sum(hourly_gc_attrib.gc_count) ≤ hourly_gc.gc_count` 是设计上的不等关系，**禁做等式校验** | `docs/architecture.org`「路径 6：GC 与自监控」、`docs/schema.org`「hourly_gc_attrib」、TD-31 / TD-32 / TD-33 |
| **启动分解覆盖范围（现状路径：未装探针）** | `startup_phases` 的包加载明细基于 `after-load-functions` **相邻两次回调的时间差**（**近似归因**，差值含前一文件的收尾逻辑与它触发的钩子）；**mode 在 `after-init-hook` 之前启用**才记明细，启动已结束时只有 `mode-start` 一个锚点、且**根本不挂** `after-load-functions`（否则启动后的交互式 load 会被记成「启动耗时」）——观测器无法观测自己被加载之前的事；不装探针时这条物理边界与既有行为一致 | `docs/architecture.org`「路径 5：启动打点」/「已知偏差」、`docs/operations.org`「启动分解的物理边界」、TD-16、ADR-0006 |
| **启动分解覆盖范围（探针路径：装了 early-init 探针）** | 在 `early-init.el` 里 `(load "el-chronos-startup-probe" t t t)` 之后，`load:*` 明细覆盖**从 `early-init` 起的完整加载**，并给出 `early-init` / `after-init` / `startup` 三锚点；探针的自摘发生在 `startup` 锚点后 **0 秒 timer** 里，故 load 明细只覆盖到「**最后一次 `take` 时刻**」——`startup` 锚点之后到事件循环之间的少量加载（如用户 `emacs-startup-hook` 里的惰性 require）可能缺失。这是「探针提前到 early-init 也不覆盖最后一毫秒」的残留边界，不是 bug | ADR-0006「决策 / D1」、TD-16、`docs/architecture.org`「路径 5：启动打点」 |
| **探针路径是硬编码的（静默降级）** | `thomas-emacs/early-init.el` 里写死 el-chronos 仓库的**绝对路径**；仓库改名 / 搬迁后 `(load … t)` 按 NOERROR 语义**静默失败**，表现为 `startup_phases` 的 `load:*` 明细又变回 0 条，而其余观测照常工作。**排障口诀**：`load:*` 为 0 → 先确认 `early-init.el` 里那条路径存在、且 `THOMAS_EMACS_INSTANCE` 守卫没跳过它 | ADR-0006 D4、`docs/operations.org`「启动分解的物理边界」 |
| **资源均值的分母是 `load_n`** | `hourly_resources` 的 `rss_kb_sum` / `load1_sum` / `load5_sum` / `load15_sum` 一律除以 **`load_n`**（成功取到 `load-average` 的窗口数），不是窗口总数；`load_n` 为 0 时均值为 **NULL 而不是 0**，报告与 Web 渲染 `-`（I11：不做「0 负载」的假象）。已知后果：负载采集失败的时段里 RSS 均值同样为 NULL（刻意的诚实降级，独立 `rss_n` 列见 TD-27） | `docs/schema.org`「hourly_resources」、TD-27 |
| **autoload 契约（配置侧入口）** | **16 个 interactive 命令**全部带 `;;;###autoload` cookie，`make autoloads` 生成 `el-chronos-autoloads.el`（**不入库、不进 L1/L2**，`EL_FILES` 排除）。**`use-package` 的 `:autoload` / `:commands` 无法声明跨文件入口**（实测：库名恒为包名 `el-chronos`，而 report / web 命令不在 `el-chronos.el` 里 → 首次调用报 `Autoloading file ... failed to define function`），配置侧**推荐用 straight `:local-repo` recipe 并保留 autoloads**（`:build (:not compile native-compile)`）：straight 依 cookie 生成 `build-<ver>/el-chronos/el-chronos-autoloads.el` 并自动加载，16 个命令免配置可 `M-x`（实测 `autoloadp` 全 `t`）；`straight-pull-package` / `straight-checkout-package` 会作用到**开发仓本身**（`:local-repo` 就是那个 git 工作树），**新增 / 改名 interactive 命令后须 `M-x straight-rebuild-package RET el-chronos`** 刷新 autoloads；`:files` 须显式 `(:exclude "el-chronos-autoloads.el")`，否则生成物被软链进 build 目录会穿透写回源仓库；**降级判据须用 `if` 包住整个 `use-package`**——`:if` / `:when` **包不住** `:straight`（实测 `(macroexpand-1 '(use-package el-chronos :if nil :straight …))` 返回 `(progn (straight-use-package '…) (when nil (require …)))`，条件为假照样去 clone 本仓；`(if (file-exists-p …) (use-package …) (display-warning …))` 才把安装调用关进 then 分支）。若仍用 `:load-path` 形态（无 straight），则须在 `:init` 里逐条显式 `(autoload SYM "定义文件")`，且 `:load-path` 只能写字符串字面量（绝对路径最稳、`~` 前缀亦可——实测 `locate-library` 能解析，依赖 HOME 展开；**禁止**相对路径——宏展开期按当时 `user-emacs-directory` 固化——与变量 / sexp 形态——整个 form 静默展开为 `nil`） | `docs/api.org`「autoload 与 use-package 集成」、`docs/operations.org`「静默陷阱」、`test/el-chronos-autoload-test.el` |
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
| 技术文档 | `docs/architecture.org`（时序、数据流、实测结论）、`docs/schema.org`（DDL 与查询示例）、`docs/ui.org`（两形态界面、Web dashboard 路由与降级规则）、`docs/api.org`（接口索引）、`docs/operations.org`（装卸、清理、排障）、`docs/adr/0001`–`0007`（架构决策：0004 = 观测面扩展、0005 = 两档阈值、0006 = 启动探针 + 资源观测、0007 = 多进程共享库的锁竞争自愈） |

> **当前 `openspec/active/` 为空**（只剩 `.gitkeep`）——本批（第 11 份）归档多实例并发写计划：
> - `openspec/completed/multi-instance-concurrency.md`：**多实例共享库的锁竞争自愈 + 降竞争**（ADR-0007，2026-10-30 归档），
>   **T1–T10 全部完成**（会话行延迟补建 / flush 撞锁保留重试 + 30 秒退避 / 7 处 `BEGIN IMMEDIATE` /
>   `busy_timeout` 分层 / prune 候选预检 + 1 小时节流 / `busy-retries` 存储侧 + 八处消费侧 / 双进程 L3 复验 /
>   全量验证 / 文档同步与归档）。一句话结论：**锁竞争是 SQLite 共享库的正常语义，按自愈处置而非当故障丢弃**——
>   对端持锁 3 s 时 `store-open` 由 `OPEN=nil` 变 `OPEN=t`、flush 撞锁后库内行数守恒（100 = 100，改造前定格 420
>   丢掉第 5 批 100 行）、持续持锁 40 s 场景 12 次 flush 累计阻塞 **9.54 s**（无退避时为 12 × 8.01 s ≈ 96 s）。
>   用例 **336 → 375**（+39），`make check-parens` / `make lint`（17 文件零告警）/ `make test`（375 全绿、0 skipped）全通过。
>
> 归档纪律：计划在 Phase 4 完成后移入 `completed/`（文件名不变，便于 cross-reference），并同步更新本段与
> `Readme.org`「当前状态」。
>
> 全部计划均已归档（`openspec/completed/` 共 **11** 份）：`el-chronos-core.md`、`expand-observation-surface.md`、
> `add-drift-detection.md`、`add-use-package-support.md`、`remove-dashboard-web-only.md`、
> `fix-web-block-suppression.md`、`fix-sampling-attribution.md`、`startup-probe-and-resources.md`、
> `2026-10-26-compact-observability.md`、`gc-attribution.md`、`multi-instance-concurrency.md`
> （2026-10-24 / 2026-10-25 / 2026-10-26 / 2026-10-30）。
>
> 上一批（第 10 份）归档的是 GC 归因计划：`openspec/completed/gc-attribution.md`（schema v5 新增 `hourly_gc_attrib`）——
> **回答「GC 发生在哪条命令之后」**，同桶同会话覆盖 100%、真实库副本 v4 → v5 迁移零丢失；但**命令维度覆盖率有限**
> （实测 **37/45 = 88.1% 落 `<none>`**，因为 GC 多发生在命令循环**等待输入**的窗口，不是启动期 / batch），
> 故该表主要给 mode 维度与「命令执行期 GC」用；`sum ≤ total` 是不等关系（**禁做等式校验**，TD-31）。
>
> **技术债现状**：`openspec/tech-debt.md` 编号已到 **TD-39**。本批新增四条 —— **TD-36**（会话行延迟补建期间
> **聚合**数据缺一段：`record-*` 经 `--aggregate-session` 在记录时即按 session 跳过，补建只救回明细；
> `hourly_stacks` 属另一机制，经 `--stack-session` 在 flush 期跳过）、**TD-37**（`--prune` 只由 `store-open` 调用，
> 1 小时节流不引入周期 prune，`el-chronos-retention-days` 的实际生效**仍依赖实例重启**）、**TD-38**（延迟补建使
> `sessions.started_at` = **补建时刻**，会话时长被低估一个窗口、`startup_ms` 置 NULL；会话时长权威下界取
> `min(commands.ts)`）、**TD-39**（`--flush-batch` 的 `let*` 里 `--stack-session` / `--session-known-p` 两处
> `sqlite-select` 在 `condition-case` **之外**，抛错会从 flush 外泄、违反 I6；**未实施**，建议后续单独收口）。
> 上一批的 TD-31~TD-35 口径不变（TD-31 `sum ≤ total` 禁等式校验、TD-32 `<none>` 成因、TD-33 归因键口径、
> TD-34 Org 反斜杠、TD-35 `--post-gc` docstring 措辞）。


文档与代码同步：改接口/改 schema 必须同时更新 `docs/schema.org` 与 ADR 相关条目；
新增已完成任务须在 `CHANGELOG.md` 的 `[Unreleased]` 段记录。
