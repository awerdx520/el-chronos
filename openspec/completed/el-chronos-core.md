# el-chronos：Emacs 长期性能与用法观测器

## 当前状态

- 阶段：Phase 4（Review & Document）· **已完成**
- 已确认：方案 ✅（用户 2026-10-24 确认，含双形态可视化 + ETAF）/ 计划 ✅（2026-10-24）
- 归档日期：2026-10-24
- 结果：8 个源码模块 + 7 个测试文件（`test/*-test.el`，**103 个 ERT 用例**），`make full-check` 全绿
  （`Ran 103 tests, 103 results as expected, 0 unexpected`，约 5.7 s），`make lint` 零告警（15 个文件逐个字节编译）；
  文档全集（`docs/architecture.org` / `schema.org` / `ui.org` / `api.org` / `operations.org` +
  两份 ADR）与 `Readme.org` / `AGENTS.md` / `CHANGELOG.md` 已同步。
- 遗留（不阻塞归档，已记 `openspec/tech-debt.md`）：TD-1（native-comp `.eln` 归因）、TD-2（阻塞捕获覆盖率）、
  TD-3（采样开销）、TD-5（ETAF 重绘性能）、TD-6、TD-7（P95 近似精度）、TD-8、TD-10（`total_ms` 口径）；
  D1（`pre-command-hook` 双跑陷阱）修复已有 ERT 覆盖，**GUI 实机验证待做**。
- 已修订：plan-reviewer 独立审查意见已并入（2026-10-24）—— 新增「隐私边界」「数据生命周期」「错误处理矩阵」「回归判定」四节；I7/I8 重写；T5→T5a–c、T8→T8a–d、T9→T9a–d 拆分；T2/T3/T4/T6/T10/T12 验收收紧；文档清单补 `docs/api.org`、`docs/operations.org`；验证标准补隐私/回归/测试发现三条。

## 目标

在 Emacs 内常驻运行一个低开销观测器，回答：

1. 哪些命令/操作慢，慢多久（含被 `C-g` 中断的卡顿）
2. 慢在哪个函数、调用链是什么
3. 归因到哪个 straight 包 / `lisp/init-*.el` 模块 / site-lisp 文件
4. 长期趋势如何、某次改动是否引入回归
5. 哪些高频用法值得优先优化
6. 通过 Emacs 内 ETAF 可视化页面与浏览器 Web dashboard 双形态查看上述全部结论

非目标：自动调优/自动禁用功能、跨机器数据汇聚、源码行级采样、记录按键序列与文件内容。

## 设计

### 分层
采集（collect）→ 归因（attrib）→ 存储（store, SQLite）→ 分析（analysis）→ 呈现（report / dashboard / web）。

### 文件边界
| 文件 | 职责 | 关键对外接口 |
|---|---|---|
| `el-chronos.el` | 自定义组、minor mode、启停编排、错误降级 | `el-chronos-mode`、defcustom 组 |
| `el-chronos-collect.el` | 命令计时、心跳阻塞检测、profiler 窗口聚合、启动打点 | `el-chronos-collect-start/-stop` |
| `el-chronos-attrib.el` | 符号→文件→包/模块；命令上下文 | `el-chronos-attrib-file/-package/-context` |
| `el-chronos-store.el` | SQLite schema、批量 flush、保留策略 | `el-chronos-store-open/-close`、`-record-*` |
| `el-chronos-analysis.el` | 热点/慢命令/阻塞/包归因/趋势查询 | `el-chronos-analysis-*` |
| `el-chronos-report.el` | org 报告、周报、CSV/JSON 导出 | `el-chronos-report`、`el-chronos-profile-command`（T11） |
| `el-chronos-dashboard.el` | Emacs 内可视化页面（ETAF：组件树 + SVG 图表 + 表格 + 下钻） | `el-chronos-dashboard` |
| `el-chronos-web.el` | 最小 HTTP server + 内嵌 HTML/CSS/JS dashboard | `el-chronos-web-start/-stop` |
| `test/*-test.el` | ERT（7 个测试文件 + 公共 helper，共 103 用例；`make test` 自动发现） | — |

### 数据模型（SQLite，PRAGMA user_version 迁移）

6 张表 DDL（Phase 3 落地时以此为准，实测后同步 `docs/schema.org`）：

```sql
PRAGMA user_version = 1;
PRAGMA journal_mode = WAL;

CREATE TABLE IF NOT EXISTS sessions (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  started_at    INTEGER NOT NULL,          -- epoch ms
  emacs_version TEXT,
  host          TEXT,
  startup_ms    REAL,
  gc_threshold  REAL
);

CREATE TABLE IF NOT EXISTS commands (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  ts          INTEGER NOT NULL,            -- epoch ms，命令结束时刻
  session_id  INTEGER NOT NULL REFERENCES sessions(id),
  name        TEXT NOT NULL,               -- 命令符号名
  duration_ms REAL NOT NULL,
  gc_ms       REAL,
  mode        TEXT,                        -- major-mode
  project     TEXT,                        -- 项目 basename（不存绝对路径），未知为 NULL
  outcome     TEXT,                        -- ok / aborted / error
  kind        TEXT                         -- interactive / called
);
CREATE INDEX IF NOT EXISTS idx_commands_ts ON commands(ts);
CREATE INDEX IF NOT EXISTS idx_commands_duration ON commands(duration_ms DESC);

CREATE TABLE IF NOT EXISTS hourly_functions (
  hour_ts    INTEGER NOT NULL,             -- epoch ms，整点
  session_id INTEGER NOT NULL,
  function   TEXT NOT NULL,
  file       TEXT,
  package    TEXT,
  self_ms    REAL NOT NULL DEFAULT 0,
  total_ms   REAL NOT NULL DEFAULT 0,
  samples    INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (hour_ts, session_id, function)
);

CREATE TABLE IF NOT EXISTS slow_events (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  ts           INTEGER NOT NULL,
  duration_ms  REAL NOT NULL,
  kind         TEXT,                       -- block / command
  command      TEXT,
  stack_json   TEXT,                       -- 符号栈（JSON 数组）
  context_json TEXT                        -- mode / project / gc 等
);
CREATE INDEX IF NOT EXISTS idx_slow_events_ts ON slow_events(ts);

CREATE TABLE IF NOT EXISTS hourly_usage (
  hour_ts     INTEGER NOT NULL,
  dimension   TEXT NOT NULL,               -- command / mode / project
  key         TEXT NOT NULL,
  count       INTEGER NOT NULL DEFAULT 0,
  duration_ms REAL NOT NULL DEFAULT 0,
  PRIMARY KEY (hour_ts, dimension, key)
);

CREATE TABLE IF NOT EXISTS hourly_stacks (
  hour_ts INTEGER NOT NULL,
  session_id INTEGER,
  stack_hash TEXT NOT NULL,   -- sha1(stack_json)
  stack_json TEXT NOT NULL,   -- backtrace 向量数组
  samples INTEGER,
  PRIMARY KEY (hour_ts, session_id, stack_hash)
);
```

每小时只保留样本数最高的 200 条栈（`el-chronos-store-stack-top-n`，默认 200），用于火焰图与调用链分析；
超限按 samples 淘汰。

字段要点：

- sessions(id, started_at, emacs_version, host, startup_ms, gc_threshold)
- commands(id, ts, session_id, name, duration_ms, gc_ms, mode, project, outcome, kind)，索引 ts、duration_ms DESC；`project` 存项目 basename
- hourly_functions(hour_ts, session_id, function, file, package, self_ms, total_ms, samples)，主键 (hour_ts, session_id, function)
- slow_events(id, ts, duration_ms, kind, command, stack_json, context_json)，索引 ts
- hourly_usage(hour_ts, dimension, key, count, duration_ms)，主键 (hour_ts, dimension, key)
- hourly_stacks(hour_ts, session_id, stack_hash, stack_json, samples)，主键 (hour_ts, session_id, stack_hash)；每会话每小时按 samples 保留 top-N 栈

### 采集策略
| 信号 | 机制 | 频率 | 开销控制 |
|---|---|---|---|
| 命令耗时 | pre/post-command-hook 计时；下次 pre 仍有未结算 → 记 aborted | 每命令 | 两次 float-time |
| GC 影响 | 命令前后 gcs-done / gc-elapsed 差值 | 每命令 | 无额外开销 |
| 函数热点 | profiler-cpu-start 常驻（默认 10ms），每 10s 取 profiler-cpu-log 聚合后自动重置 | 100 samples/s | 取用即重置；内存聚合、小时落库 |
| 命令外阻塞 | 1s 心跳 timer，间隔漂移 > 2s 记 block | 1/s | 单次 float-time 比较 |
| 启动耗时 | after-init-hook / emacs-startup-hook 打点 | 每会话 | 一次性 |
| 用法统计 | 复用命令钩子，command/mode/project 三维累加 | 每命令 | 哈希表自增 |

### 可视化设计

两种形态共享同一 `el-chronos-analysis` 查询层，互不重复 SQL；任一种不可用都不影响采集与另一种（I11）。

#### Emacs 内页面：ETAF 实现（`M-x el-chronos-dashboard`，buffer `*el-chronos*`）

组件结构：

- 根组件 `el-chronos-dashboard-app`，`:bindings` 持有 `range`（"1d"/"7d"/"30d"）、`page`、`selected-event`、`filter`。
- 顶栏：标题 + 时间范围切换（`etaf-button` ×3）+ 刷新按钮 + 状态（DB 大小、采样状态）。
- 概览卡片行：`etaf-tile-grid` 展示 6 个指标（今日命令数、阻塞总时长、慢命令数、采样样本数、DB 大小、会话启动耗时）。
- 图表区（`etaf-ui-svg-*` 手绘后经 `etaf-ui-svg-image` 渲染）：
  1. 趋势折线图（样本量 / 阻塞事件数 / 慢命令数三条线，随 `range` 变化）
  2. 包/模块 CPU 占比横向条形图
  3. 用法热力图（命令 × 小时）
- 表格区（`etaf-ui-table`，分页，默认每页 20 行）：慢命令 TOP、热点函数 TOP、阻塞事件列表、回归列表、会话列表。
- 下钻：表格行 `:on-press` → `etaf-dialog` 展示该命令/函数/事件的详情（历史趋势、栈样本、归属文件、优化建议）。
- 快捷键（经 `etaf` 键位系统或 buffer 局部键位）：`1`/`7`/`3` 切时间范围，`g` 刷新，`r` 切换自动刷新，`q` 关闭。
- 能力清单（10 项，逐项落实验收）：①概览卡片 ②慢命令排行 ③热点函数排行（含包归属）④包占比条形图 ⑤趋势折线 ⑥阻塞事件列表与详情 ⑦用法热力图 ⑧回归列表 ⑨会话列表与启动曲线 ⑩时间范围切换与下钻。

ETAF 事实依据（实现时直接使用，不另造轮子）：核心 API 为 `etaf-mount` / `etaf-view` /
`etaf-define-component`（`:bindings` / `:view`）、`etaf-ref` / `etaf-value`（响应式状态）、
`:on-press` 等事件属性、`(expr FORM)` 子表达式；表格用 `etaf-ui-table`（`:columns` / `:rows`，
列描述支持 `:key` `:width` `:cell`，`DataGrid` 适配 Data）；图表用 `etaf-ui-svg-rect` / `-circle` /
`-line` / `-path` / `-text` / `-group` 生成 SVG markup，`etaf-ui-svg-image` 返回
`(image :type svg :data STRING)` 描述符并交给 image Host（如 `etaf-tile-grid` 的 `:cell-image`）；
官方组件 `etaf-panel` / `etaf-label` / `etaf-button` / `etaf-checkbox` / `etaf-number-input` /
`etaf-tile-grid` / `etaf-popover` / `etaf-dropdown-menu` / `etaf-dialog` 直接复用。

降级与边界：

- ETAF 为**软依赖**：`(require 'etaf nil t)` + `(require 'etaf-ui nil t)`；任一失败 → `display-warning`
  提示安装（straight recipe 见 thomas-emacs 的 `lisp/init-etaf.el`），并自动降级到内置
  `tabulated-list` 简版页面，核心采集不受影响。
- 图形 frame 下用 SVG；terminal frame 下图表降级为文本条形（`string` 重复字符），不得报错。
- 单页渲染行数上限（默认 20 行/页）与图表采样点上限（默认 60 点），避免 ETAF 重绘变慢。

#### Web dashboard（`M-x el-chronos-web-start`，默认 `http://127.0.0.1:8787/`）

能力清单（10 项）：

1. 同源数据渲染的完整页面（概览卡片 + 排行 + 图表）
2. 折线图 / 柱状图 / 环形图 / 日历热力图
3. 简化火焰图（基于 `hourly_stacks` 聚合）
4. 时间范围切换、搜索过滤、列排序、分页
5. 下钻详情面板（历史趋势、栈样本、归属文件、优化建议）
6. 慢事件详情页（完整栈 + 上下文 JSON）
7. 自动刷新（默认 30s，可关）
8. 导出 CSV / JSON
9. 多会话对比
10. 响应式布局，离线可用（无 CDN）

Web 技术路径：`make-network-process :server t` 自写最小 HTTP server；路由 `GET /`（HTML）、
`GET /api/summary|top-functions|slow-commands|packages|trend|heatmap|stacks|sessions|event/:id`（JSON）、
`GET /api/export.csv`；HTML/CSS/JS 以字符串内嵌 elisp，不引第三方库与 CDN；只绑定 `127.0.0.1`；
默认不自动启动；只读。

### 隐私边界

观测器不得成为隐私风险源。边界按「归因与趋势是否必需」逐项划定，而不是笼统的「不记路径」：

- **记录**：命令名、耗时、GC 时长、major-mode、项目 basename、函数符号名、函数定义源码路径（归因必需）。
- **不记录**：被操作文件路径、buffer 内容、按键序列、命令参数、剪贴板、环境变量。

`commands.project` 存 `(file-name-nondirectory (directory-file-name (project-root ...)))`，
即 **项目 basename，不存绝对路径**；取不到时为 NULL。同理 `hourly_functions.file` 只存函数定义所在源码路径
（用于包/模块归因），不含任何「被操作对象」信息。

Web 无鉴权；loopback 只防 LAN 暴露，**不构成本机访问控制**——WSL2 mirrored 网络下 Windows 侧进程可达。

### 数据生命周期

- `commands` / `slow_events`：按 `el-chronos-retention-days`（默认 30）保留，超期删除。
- `hourly_functions` / `hourly_usage` / `hourly_stacks`：**永久保留**，不纳入 retention 清理。
  行数可控：`hourly_functions` ≤ 24 × 函数数/天，`hourly_usage` 同理，`hourly_stacks` ≤ 24 × 200 × 会话数/天
  （top-N 已在写入侧淘汰）。
- 新增手动接口 `el-chronos-purge (&optional before)`：删除指定日期前的全部数据（含 `hourly_*`），
  供用户主动清空历史；不给 `before` 时按 `el-chronos-retention-days` 计算。
- schema 迁移：`PRAGMA user_version` 逐版本升级；迁移前先把 DB 复制为 `.bak`，迁移失败则回滚文件 +
  `display-warning`，**不破坏原库**。

### 错误处理矩阵

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

### 回归判定

- 窗口：近 `el-chronos-regression-window-days`（默认 7）天 vs 前同长度窗口。
- 判定：`self_ms` 增长 ≥ `el-chronos-regression-threshold`（默认 0.5，即 50%），
  且两窗口样本数均 ≥ `el-chronos-regression-min-samples`（默认 10）。
- 输出须含**增长比例**与**两窗口样本数**，避免小样本噪声被当成回归。

### 关键不变量
- I1 采样只用内置 C profiler，不自造采样器、不全量 advice。
- I2 主线程阻塞期间不依赖 Lisp 回调（证据由 SIGPROF 留存，事后回溯）。
- I3 数据只写 `el-chronos-db-path`（默认 `<user-emacs-directory>/.local/state/chronos/chronos.sqlite`）。
- I4 单位统一：API/DB 用毫秒，采样间隔用纳秒。
- I5 `el-chronos-mode -1` 零残留：timer、hook、profiler、未 flush 缓冲。
- I6 归因失败降级 `unknown`，采集路径不得向宿主抛错。
- I7 默认不记录**被操作文件**路径、按键序列、buffer 内容与命令参数；函数归因所需的源码路径与项目 basename 除外。
- I8 Web server 只绑定 `127.0.0.1`，默认关闭，禁止 `0.0.0.0`；只提供只读接口。loopback 仅防 LAN 暴露，不构成本机访问控制（WSL2 mirrored 下 Windows 侧可达），Web 无鉴权。
- I9 Emacs dashboard 对 ETAF 为软依赖（`require ... nil t`），缺失时必须降级到内置 tabulated-list 并提示安装；采集/存储/分析核心**不得**依赖 ETAF。
- I10 可视化资源全部内嵌或本地生成（Emacs 图表用 `etaf-ui-svg-*`，Web 用字符串内嵌 HTML/CSS/JS），不引第三方图表库与 CDN，离线可用。
- I11 任一可视化形态不可用时必须可见降级（ETAF 缺失→tabulated-list；SVG 不可用→文本条形；Web 端口占用→明确报错），不得静默失败。

## 任务

- [x] T1 仓库骨架与流程基础设施（依赖：无）
  验收：本计划所列文件全部存在；`make check-parens` 在无 .el 时成功退出；`git status --short` 输出已报告。
- [x] T2 入口模块 `el-chronos.el`（依赖：T1）
  内容：defgroup；defcustom `el-chronos-enabled`(t)、`el-chronos-sampling-interval-ns`(10000000)、`el-chronos-sample-window-seconds`(10)、`el-chronos-heartbeat-seconds`(1)、`el-chronos-block-threshold-ms`(2000)、`el-chronos-slow-command-threshold-ms`(200)、`el-chronos-db-path`、`el-chronos-retention-days`(30)、`el-chronos-usage-granularity`('command)、`el-chronos-regression-window-days`(7)、`el-chronos-regression-threshold`(0.5)、`el-chronos-regression-min-samples`(10)；`define-minor-mode el-chronos-mode`（global）；启停编排（幂等）；sqlite 不可用时 `display-warning` 并禁用。
  验收：check-parens 通过；T2 内容所列 defcustom 全部存在（`boundp` 为 t）；`(el-chronos-mode 1)` 幂等（重复调用不重复注册 timer/hook）；`(el-chronos-mode -1)` 后 `(length (el-chronos--active-timers))` 为 0；模拟 sqlite 不可用 → `display-warning` + 模式禁用 + 不抛错。
  （「collect/store timer 存在」的验收移交 T5，本任务只保证启停语义。）
- [x] T3 归因模块 `el-chronos-attrib.el`（依赖：T1）
  内容：`el-chronos-attrib-file`（symbol-file + `.eln` 兜底）、`el-chronos-attrib-package`（路径前缀→straight 包/lisp 模块/site-lisp/built-in）、`el-chronos-attrib-context`（major-mode、project-current 安全调用并只取项目 basename、按 granularity 决定是否记路径）；结果缓存 hash table。
  验收（期望值写死，避免「合理归属」这种不可判定措辞）：`(el-chronos-attrib-package 'save-buffer)` → `built-in`；`+thomas/foo` → `lisp/init-*.el` 模块名；第三方包函数 → 对应 straight 包名；归因失败 → `"unknown"` 且不抛错。
- [x] T4 存储模块 `el-chronos-store.el`（依赖：T1、T2）
  内容：schema 创建幂等；WAL + busy_timeout；批量缓冲 + flush timer；保留策略（只清 `commands`/`slow_events`）；`PRAGMA user_version` 逐版本迁移（迁移前复制 `.bak`，失败回滚文件 + `display-warning`）；`el-chronos-purge`（手动删除指定日期前全部数据）；`el-chronos-store-close` 前 flush；`hourly_stacks` 表与 top-N 淘汰（`el-chronos-store-stack-top-n`，默认 200）。
  验收：重复 open 不报错；1000 条批量写入后行数正确；写入 >200 条不同 stack 后该 `(hour_ts, session_id)` 分组**恰好 200 行且为 samples 前 200**；retention **只删** `commands`/`slow_events`，不动 `hourly_*`；迁移失败回滚 `.bak` 且原库可用。
- [x] T5 采集模块 `el-chronos-collect.el`（依赖：T2、T3、T4）—— 同一任务块拆为 T5a/T5b/T5c（同一文件，可分别验收）
  - [x] T5a 命令计时：`pre-command-hook` / `post-command-hook` 计时 + GC 差值（`gcs-done` / `gc-elapsed`）；结算含 aborted 与 error 两种非正常路径——error 经 `command-error-function` 标记，下次 `pre` 见到未结算再记 `aborted`。
  - [x] T5b 心跳漂移检测：`el-chronos-heartbeat-seconds`（1s）timer 比较实际间隔，漂移超 `el-chronos-block-threshold-ms` 记 `slow_events(kind='block')`。
  - [x] T5c 采样窗口聚合：每 `el-chronos-sample-window-seconds` 取 `profiler-cpu-log` 聚合 self/total，按小时落 `hourly_functions`；采样 tick 同时产出窗口栈聚合供 `hourly_stacks`；启动打点。
  验收：构造抛 error 的命令 → `outcome='error'`；模拟未结算 → `aborted`；模拟 timer 漂移 → `slow_events(kind='block')`；`self_ms` 总和 ≤ 总样本数（聚合自洽）；启用后 `el-chronos--active-timers` 含 collect/store 的 timer，禁用后清零（自 T2 移交的这条在此验收）。
- [x] T6 分析模块 `el-chronos-analysis.el`（依赖：T4）
  内容：top-functions、slow-commands、blocking-events、package-breakdown、trend、regressions；纯查询返回 plist；追加 trend / heatmap / stacks / sessions / regression 查询（供两种可视化形态共用）。
  验收：用 fixture 数据库断言各查询结果；fixture 中**已知回归函数必出现在 regressions 结果集**（按「回归判定」节的阈值判定，不得靠人工目测）。
- [x] T7 报告模块 `el-chronos-report.el`（依赖：T6）—— org 报告、周报、CSV/JSON 导出
  内容：`el-chronos-report`（org buffer：最近 1 天/7 天/30 天）、`el-chronos-weekly-report`（org 文件）、`el-chronos-export`（CSV/JSON）、`el-chronos-show-event`。
  验收：报告 buffer 生成且内容与 fixture 数据一致；导出文件可解析。
- [x] T8 Emacs 内 ETAF 可视化页面 `el-chronos-dashboard.el`（依赖：T6、T7）—— 实现 10 项能力，拆为 T8a–T8d
  - [x] T8a ETAF 探测与降级：`(require 'etaf nil t)` / `(require 'etaf-ui nil t)`；缺失时 `display-warning` + 降级 tabulated-list 简版。**简版最小能力集 = 慢命令表 + 热点函数表 + 时间范围参数**（不得只给空壳页面）。
  - [x] T8b 概览卡片（`etaf-tile-grid` 6 指标）+ 表格区（`etaf-table`：慢命令/热点函数/阻塞事件/回归/会话，分页 20 行）。
  - [x] T8c SVG 图表：趋势折线、包/模块占比条形、用法热力图（`etaf-ui-svg-*` + `etaf-ui-svg-image`）；terminal frame 降级文本条形。
  - [x] T8d 下钻（`etaf-dialog`：历史趋势、栈样本、归属文件、优化建议）+ 快捷键（`1`/`7`/`3`、`g`、`r`、`d`、`q`）。
  验收：`*el-chronos*` 打开后 10 项逐项可见；`1/7/3` 切范围生效；行 `:on-press` 下钻打开详情；ETAF 缺失时降级 tabulated-list 简版且**包含慢命令表与热点函数表两张表、可切时间范围**，不报错；terminal frame 图表降级为文本不报错。
  （实施备注：表格注册名是 `etaf-table` 而非 `etaf-ui-table`；ETAF 的 10 条实测坑与应对见 `docs/ui.org`「ETAF 实测踩坑清单」。）
- [x] T9 Web dashboard `el-chronos-web.el`（依赖：T6、T7）—— 实现 10 项能力，拆为 T9a–T9d
  - [x] T9a server + 端口 + 路由骨架：`make-network-process :server t`，只绑 `127.0.0.1`，默认端口 8787；端口占用 → `user-error` 且**不自动换端口**；`el-chronos-web-stop` 干净释放端口。
  - [x] T9b 内嵌 HTML/CSS/JS 骨架：单页结构 + 时间范围切换 + 导航区，无 CDN。
  - [x] T9c 全部 API：`/api/summary|top-functions|slow-commands|packages|trend|heatmap|stacks|sessions|blocking|regressions|event|export.csv`（共 13 条 GET，含 `/`），只读，返回合法 JSON。
  - [x] T9d 导出 CSV/JSON + 自动刷新（默认 30s，可关）+ 多会话对比。
  验收：`http://127.0.0.1:8787/` 可访问、全部 API 返回合法 JSON、离线可用、`el-chronos-web-stop` 干净释放端口、只绑 loopback；无鉴权与 loopback 的边界见 I8。
- [x] T10 ERT 测试与验证入口（依赖：T2–T9）
  内容：schema/聚合/归因/保留/启停幂等测试 + analysis 查询 fixture + dashboard/web 冒烟（降级路径与路由响应）；接入 `make test`。测试文件一律命名 `test/*-test.el`；Makefile 的 `test` 目标改为**自动发现 `test/*-test.el` 并全部加载**（不再硬编码单个文件名），避免拆分测试后静默漏跑。
  验收：ERT 全绿；check-parens 通过；新增一个 `test/tmp-*-test.el` 时 `make test` 必须执行到它。
  （实测：103 用例，`Ran 103 tests, 103 results as expected, 0 unexpected`，约 5.7s；7 个测试文件 + 公共 helper。）
- [x] T11 单命令高精度剖析（依赖：T7）—— `el-chronos-profile-command`
  内容：`el-chronos-profile-command`（1ms 采样跑一次命令 + 归因摘要）。
  验收：对已知命令得到栈报告。
  （实施备注：profiler 已被常驻采样占用时复用共享模式，不自起自停；`el-chronos-profile-save` 可把结果落 `slow_events(kind="profile")`。）
- [x] T12 文档完善与架构决策沉淀（依赖：T11）
  内容：`docs/architecture.org`（时序与数据流 + 可视化数据流）、`docs/schema.org`（表结构与查询示例）、`docs/ui.org`（ETAF 组件树、页面布局、快捷键、Web API 路由表）、`docs/api.org`（elisp 对外接口索引）、`docs/operations.org`（装卸、数据清理、排障、ETAF recipe 引用）、ADR、CHANGELOG、Readme 更新、计划归档；同步 Readme/AGENTS 的「5 个问题」表述为「6 条目标」；Readme 新增**卸载与数据清理**节（含 `el-chronos-purge` 与直接删 DB 文件两条路径）。
  验收：新人仅凭仓库文档可理解全貌；`docs/api.org` 覆盖所有对外符号。
  （完成情况：`docs/ui.org` / `docs/api.org` / `docs/operations.org` 已新建；`architecture.org` 补「实测结论」「已知偏差」；
  `schema.org` 补最终 DDL、top-N 淘汰 SQL、`session_id` 事实非空约束、P95 近似说明；ADR-0002 转 Accepted 并补「实施结果」；
  `Readme.org` / `AGENTS.md` / `CHANGELOG.md` 同步，Readme 含「卸载与数据清理」节。计划归档待 Phase 4 验收后由 Plan Agent 决定。）

## 文档清单
`Readme.org`、`CHANGELOG.md`、`AGENTS.md`、`docs/architecture.org`、`docs/schema.org`、`docs/ui.org`、`docs/api.org`（elisp 对外接口索引）、`docs/operations.org`（装卸、数据清理、排障、ETAF recipe 引用）、`docs/adr/0001-observer-architecture.md`、`docs/adr/0002-dual-visualization.md`、`openspec/active/`、`openspec/decisions.md`、`openspec/tech-debt.md`。

## 验证标准
- L1：每个 `.el` 文件 `check-parens` 通过 + flymake 无 error。
- L2：`make test` ERT 全绿。
- L3（手动）：`(el-chronos-mode 1)` 后正常运行 10 分钟无错误；`(el-chronos-mode -1)` 后无残留 timer/hook；采样开销实测 < 0.5% CPU（用内置 profiler 自身对比）。
- Emacs 页面：10 项能力可见；ETAF 缺失时降级；terminal frame 不报错。
- Web：`curl --noproxy '*' http://127.0.0.1:8787/api/summary` 返回合法 JSON；断网时页面图表正常；`ss -lntH "sport = :8787"` 只见 `127.0.0.1`。
- 所有 elisp 验证走 elisp-dev-mcp 的 **verify 隔离实例**（本机主实例 `thomas` 当前调用超时）。
- 隐私：`commands.project` 中不出现 `/`（basename 断言）。
- 回归：fixture 断言（已知回归函数必须命中「回归判定」阈值并出现在结果集）。
- 测试发现：新增一个 `test/tmp-*-test.el` 时 `make test` 必须执行到它（验证后删除该临时文件）。

## 注意事项
- 只在 `/home/thomas/Workspace/el-chronos` 内改文件，**不得修改** `/home/thomas/thomas-emacs`。
- 依赖分两档：核心模块（collect/attrib/store/analysis/report）仅用 Emacs 内置库，不引入第三方依赖；`el-chronos-dashboard.el` 对 etaf / etaf-ui 为**软依赖**（`require ... nil t`，缺失降级，见 I9）；`el-chronos-web.el` 零依赖（只用内置 `make-network-process`）。
- 所有注释/文档用中文；文件名与符号前缀 `el-chronos-`。
- 运行时数据落 `.local/state/chronos/`，不在仓库根生成。
- 采样为常驻路径，任何异常必须 `condition-case` 吞掉并降级，不得让观测器本身成为卡顿源。
- 聚合落库必须按小时，禁止逐窗口写库。
- samples 语义：self 口径（leaf 采样次数）；`total_ms` 为出现时间（栈内去重），与 `profiler-report` 不完全相等。
