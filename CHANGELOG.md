# 变更日志

本项目的所有重要变更都记录在此文件中。

格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [Unreleased]

### 修复

- **修复迁移链缺陷**：`--migrate` 原为互斥分支（`cond` 里逐版本 `return`），v1 老库升级后会停在 v2 且缺 `hourly_drift` 表、写入静默失败；改为版本变量逐级推进（v1→v2→v3 顺序执行）。
- **消除命令内停转的双记**：`--finish` 结算后重置心跳基线，block / drift 只覆盖命令外停转，命令内停转由 `commands.duration_ms` 独占（两表不相交、不可相加，结构性消除而非判据近似）。
- **「采集健康」不再把「没采集」显示成「一切正常」（I11）**：`hourly_health` 一行都没有时
  `el-chronos-analysis-health` 各项为 0 且 `:ok-p` 为 t，报告层原先直接走 `:ok-p` 分支，用户看到
  「本期无采集异常（本期无 flush 记录）」——真实含义是采集器根本没上报。修法：报告层先判 `:rows`，
  为 0 时改显示「本期无采集数据（采集器尚未写入健康指标）」；`:rows` 非 0 时才按 `:ok-p` 决定
  「无异常一行」还是六行指标表。CSV 导出的 `health` 区块补一行 `rows`，让下游同样能区分二者。
  新增用例 `el-chronos-report-test-health-distinguishes-no-data-from-no-problem` 锁住两种状态的
  互斥文案。
- **`el-chronos-purge` 从 6 表扩展到 10 表**：补齐 schema v2 新增的 `hourly_gc` / `startup_phases` / `hourly_health` / `session_meta`，否则这四张表的数据永远无法通过 purge 清理。
- **修复 `el-chronos-purge` 遇「跨界会话」整体回滚**：很早启动、当天仍在运行的会话，其 `started_at` 落在保留窗口之外而子表行落在窗口之内，删除时触发**外键冲突**，导致整个 purge 事务 ROLLBACK、一条数据都没删。
- **`purge` 重建会话行时把 `startup_ms` 置 NULL**：避免出现「新 `started_at` 配旧启动耗时」的自相矛盾数据。
- **五个既有测试改用隔离 fixture**：不再依赖真实的 `~/.emacs.d/.git`，测试在无 `.git` 或无真实配置的环境下同样可重复通过。
- **采样归因两处失真：nil 帧被当成伪函数、C 原语被当成 unknown 包**：① profiler 采样栈里的 `nil`（尾部填充与未解析帧）因 `(symbolp nil)` 为 t 被计入 self / total，落库后伪装成函数 `unknown`——实测 295,509 样本（38.8%）、其 `total_ms` 占全部样本 98.7%，长期占据热点表第 1；修法：`el-chronos-collect--accumulate-entry` 的 leaf 与 total 两处门禁都改用 `(and X (symbolp X))`，nil 帧不再计入。② `hourly_stacks` 里 93.7% 的栈尾部带 `"unknown"` 占位（含一条 `["unknown"×16]` / 295,506 样本），火焰图与调用链视图被无意义占位填满；修法：新增 `el-chronos-collect--trim-trailing-nils`，序列化前裁掉尾部 nil，全 nil 栈不写库。③ Emacs **C 原语与内置特殊形式**的 `symbol-file` 恒为 nil（`kill-buffer` / `overlay-get` / `read` / `mapc` / `plist-get` / `let` / `if` …），连同 profiler 自造的 `redisplay_internal (C function)` / `Automatic GC`（非 fboundp），曾被一律归为 `unknown` 包——实测 431 个函数 / 282,580 样本（37.1%）；修法：新增 `el-chronos-attrib--builtin-primitive-p`（非 fboundp 伪符号按名判定 + `subrp` 且非 `module-function-p`），命中即归 `built-in` 并在 `el-chronos-attrib-package` 符号分支前置短路（顺带省掉一次无谓的 `symbol-file` 调用）。**口径变化**：`overview` 的 `:samples` 不再含 nil 叶子（数值下降、更接近真实 CPU 归属）；`package_breakdown` 的 `built-in` 占比显著上升（正确口径）；`hourly_stacks` 样本总量与 `hourly_functions.samples` 本就不等（前者按完整栈去重、后者按 leaf 去重），改后方向是「栈表 ≥ 函数表」。**历史数据口径不可混算**，建议 `el-chronos-purge` 重来。新增 11 个用例（collect 4 / attrib 7），用例总数 110 → **121**。（补：判据 2 排除 `native-comp-function-p` 的 native-comp 函数——Emacs 30+ 的 `subrp` 对它们也返回 t，若不排除会把 straight 包的 native-comp 函数短路成 built-in，破坏 `.eln` 反查归因。）见 `openspec/completed/fix-sampling-attribution.md`。
- **dashboard 重复打开导致内存暴涨（OOM）**：`:sessions` 查询无行数上限（一年重启数千次即数千行），
  而该表标为「不分页」，`--tables` 把整表交给 ETAF；`etaf-table` 为每行保留一个行组件，于是
  单次渲染多保留约 62 万 cons、RSS +26 MB（6 次渲染 133 MB→304 MB，隔离实例 OOM）。修法：
  ① `--render-rows` 在构造行描述**之前**截断（分页表按页、不分页表只取首页，标题注明「共 N 条，
  显示前 M 条」）；② 新增 `el-chronos-dashboard-max-rows`（200），快照每个列表字段封顶，挡
  `:sessions` / `:trend` / `:heatmap` 这类无界查询；③ `--reload-snapshot` 重载前先丢弃旧快照。
  实测（3000 会话 fixture）：单次渲染交给 ETAF 的行数 2161→80、耗时 25–34s→4–5s、6 次打开后
  RSS 304 MB→105 MB、存活 cons 361 万→38 万（采样窗口 flush 后回落到 24.7 万）。见
  `docs/ui.org`「每页行数与内存」。
- **内部 buffer 不再补挂命令计时 hook**：`el-chronos-collect--internal-buffer-p` 识别名字以空格
  开头的 buffer（ETAF 挂载的 ` *work*`、`with-temp-buffer` 等），跳过补挂但仍登记——
  消掉每次渲染遍历全部 buffer 的负担（`--hooked-buffers` 因此稳定不增）。

- **Web 请求处理未纳入自观测抑制（TD-12）**：`el-chronos-web.el` 的请求处理（查询 + 序列化 + `process-send-string`）在主线程同步执行，耗时会被 1s 心跳判为一条 `slow_events(kind="block")`，形成「观测器自伤」记录与真实卡顿混淆。修法：在 `el-chronos-web--handle-request` 外层加 `el-chronos-web--without-block-events`——与 report 侧同款**三层机制**（绑定 `el-chronos-collect--suppress-block-p` / 阈值临时抬到 60s / `unwind-protect` 清理段重置心跳基线），为**内联重复实现**（web 刻意不 require report / collect，保持零额外依赖）。代价与 report 一致：请求期间真实发生的阻塞同样不记（用户主动触发的重查询耗时不属待排查卡顿）。新增 `el-chronos-web-test-suppresses-block-events` 端到端锁住三层（含反向验证：删掉基线重置后该用例必红）；用例总数 109 → **110**。见 `openspec/completed/fix-web-block-suppression.md`。
- dashboard 范围切换失效：UI 状态存**字符串**（`"1d"` / `"7d"` / `"30d"`），而 `el-chronos-analysis--range` 的 alist 键是**符号**（`'1d` / `'7d` / `'30d`）；传字符串会让 `alist-get` 取不到并**静默回落 7 天**，因此按 `1` / `3` 切到 1d 或 30d 后实际仍按 7d 查询。新增 `el-chronos-dashboard--range-symbol`（字符串 / 符号 → 归一符号，非法值回落 `7d`）与 `--range-string` 两个边界函数：状态与显示保持字符串，下给 analysis 的查询（`--load-snapshot` 的 `:range-symbol`、`--chart-rows`、`--tables`）一律转符号，`--range->days` 同时接受两种形态。
- samples 口径回归 self：`el-chronos-collect--accumulate-appearance` 不再累加 `samples`，改由 `el-chronos-collect--accumulate-self` 只给 leaf 同时累加 `self` / `samples`（`total_ms` 仍是「出现在任一栈中」的时间）。修复概览 `:samples` 样本数虚高、`top-functions` 的 pct 分母失真、回归判定被中间帧样本虚高击穿（抗噪退化）。文件头 2b、`--window-self` 与相关 docstring 同步写明「samples = 该函数作为 leaf 被采样的次数」。
- flush 失败时聚合缓冲无界增长：`el-chronos-store-flush` 的 error 分支无条件清空命令缓冲与全部聚合 hash（成功路径在会话为 nil 时保留命令缓冲是有意差异，已加注释说明）。
- 回归窗口配置失效：org 报告的回归节标题改为动态 `（近 %d 天）`，天数取 `el-chronos-regression-window-days`（`bound-and-true-p` 守卫，默认 7），不再让人误以为按显示范围判定。
- 同毫秒记录漏统计：`el-chronos-analysis--range` 把窗口上界 `END` 加 1 毫秒、SQL 统一用 `ts < END`，避免 `1d` 这类按当前时刻倒推的窗口漏掉与查询时刻同毫秒写入的最新行。
- file 粒度用法维度：`el-chronos-usage-granularity` 为 `'file` 时按被操作文件补记 `hourly_usage` 的 `file` 维度；docstring 更正为「写入被操作文件绝对路径、该表永久保留，仅 `el-chronos-purge` 可删」，默认 `'command` 不记任何路径（I7）。
- TD-9：Emacs 31 起 `pre-command-hook` / `post-command-hook` 为 auto-buffer-local，已有局部绑定的 buffer 会遮蔽全局默认值，导致该 buffer 内命令完全漏采。改为「全局默认值 + 每个 buffer 局部补挂」：启动时遍历 `buffer-list` 补挂局部值并登记（weak key），`buffer-list-update-hook` 增量覆盖新 buffer；停止时摘除局部值与登记表，并把「摘后回落到默认值」的局部绑定一并 `kill-local-variable`，不留遮蔽坑。实测被遮蔽 buffer 内命令计时恢复、连续 3 轮 start/stop 无重复挂、stop 后零残留。
- **命令双记**（D1）：`pre-command-hook` 的局部值若含 `t` 标记，会**连跑**全局默认值，与「全局默认值 + 每个 buffer 局部补挂」方案叠加后每条命令产生 `ok` + `aborted` 两条记录，导致命令计数、使用频次、中断率全部翻倍。修复：只在局部值**不含** `t` 时才补挂（不含 `t` 的局部值才是完整的遮蔽值），并加 1ms 去重兜底（同一 `(命令 . 时间)` 窗口内只记一次）。
- **profiler 帧名未归一**：`profiler` 回调给出的帧名可能是 `nil`（匿名帧）或闭包 `byte-code` 对象（形如 `#[0 "\300\207" [] 1]`），报告里直接出现 `nil` 与超长 `#[0 ...]` 串。修复：新增归一函数把 nil 映射为 `(anonymous)`、闭包对象映射为 `(closure)`，`el-chronos-collect` / `el-chronos-analysis` 两侧统一走归一。
- **中间帧占据排行**：`top-functions` / `package-breakdown` 原先按 `total_ms` 排序，`samples=0` 的中间帧（只出现在栈中、从未作为 leaf 被采样）会挤掉真正的热点。修复：两个查询都以 `samples > 0` 为前置过滤，pct 分母同步改为 leaf 样本总数。
- **报告生成被记为阻塞事件**：`el-chronos-report` 首次 `(require 'org)` 约 2.7 s，被自身 1s 心跳判为阻塞并落库，污染阻塞统计。修复见 `docs/architecture.org`「报告自观测抑制」——报告期间绑定抑制变量 + 抬高阈值 + `unwind-protect` 内重置心跳基线（三层机制；其中「重置基线」负责拦截事后补跑的补记，抑制变量本身由 collect 心跳读取，见下方「抑制层空转」条）。
- **单命令剖析 `--invoke` 参数语义**：`el-chronos-profile-command` 的 `ARGS` 为列表时原先被当作单参数塞给命令，导致 `find-file` 这类多参数命令只收到一个拼接串。修复：`nil` / 列表 / 单值三形态归一（列表按参数逐个 `funcall`，单值包成单元素列表）。
- **Web 500 响应泄露内部错误**：异常时错误详情（含 elisp 符号与栈片段）被直接写进 HTTP 响应体。修复：浏览器只回通用文案「内部错误，详见 *Messages*」，详情写 `*Messages*` 供排障。
- **Web 端口 0 显示错误**：`el-chronos-web-start` 传 `:port 0`（由系统分配端口）时 message 显示 `0` 而非实际监听端口。修复：从 `make-network-process` 返回的进程读取真实端口后再提示。
- **抑制层空转**：`el-chronos-report--without-block-events` / `el-chronos-dashboard--without-block-events` 早已绑定 `el-chronos-collect--suppress-block-p`，但 collect 侧心跳从不读取它——`let` 绑定形同空转，抑制完全依赖事后重置基线。修复：`el-chronos-collect--heartbeat` 用 `bound-and-true-p` 读取该变量，**抑制期间推进 `--last-heartbeat` 基线并跳过阻塞判定**，解除绑定后不再补记整段 gap。三层防护自此每层都有实际作用（新增 `el-chronos-collect-test-heartbeat-suppressed-skips-block` 断言 3s gap 不落库且基线被推进）。
- **dashboard 首次渲染被记为阻塞事件**：`el-chronos-dashboard` 首次渲染时的 ETAF 组件初始化耗时（同步、占主线程）被自身 1s 心跳判为阻塞并落库。修复：渲染前同样走抑制（绑定抑制变量 + 抬高阈值 + `unwind-protect` 重置基线），与报告侧口径一致。
- **`el-chronos-web-running-p` 返回非布尔值**：原先直接把 `process-status` 的结果交给调用方（`(listen ...)` / `(connect ...)` / `stop` 等状态值），`(if (running-p) ...)` 虽能判真，但 `(eq t ...)` 这类布尔断言会失败，且调用方可能把 `stop` 误当运行中。修复：归一为严格 `t` / `nil`（＝`processp` + `process-live-p` 后补 `t`），docstring 写明契约（新增 `el-chronos-ui-test-web-running-p-returns-boolean` 断言）。

### 变更

- 心跳间隔 1000ms → **250ms**（把停转时长的高估上界从 1s 压到 250ms；实测开销 +0.0357%，距 0.5% 预算余 14 倍）。
- 判定逻辑抽成 `el-chronos-collect--heartbeat-check`，timer / `--pre-command` / `--finish` 三处调用（前两处判定、`--finish` 只重置基线）。
- **文档与计划归档**：`docs/schema.org` / `api.org` / `architecture.org` / `ui.org` / `operations.org` 全部同步到 schema v2 与新增观测面（10 表 / 17 路由 / 14 报告节 / 20 defcustom）；`AGENTS.md` 基线与已知边界回填（199 用例）；新增技术债 TD-15～TD-19；计划 `expand-observation-surface.md` 由 `openspec/active/` 归档至 `openspec/completed/`（含「实现期勘误」）。
- `/api/config-history` 返回最近 50 个会话并附 `total-sessions` / `truncated` 标示；CSV 导出不截断（镜像 org 报告的完整序列）。
- `/api/health` 的 `ok-p` 显式归一为 JSON 布尔值，避免 `nil` 被序列化成 `null` 而与「未知」混淆。
- **org 报告节数 11 → 14**：新增「启动分解」「采集健康」「配置变更」三节，位置在「GC 与内存」之后、
  「阻塞事件」之前（三者都回答「这台机器这个时期的状态如何」，与趋势族相邻）。三节都遵守 I11：
  无数据时给**具体**的降级文案而不是静默省略。
- **`startup_ms` 在 mode 早于 `after-init-hook` 启用时改为「钩子捕获 + 下一次 flush 补写」**：这类会话里 `--ensure-session` 建会话行时 `after-init-time` 仍是 nil（`startup.el` 先 `setq after-init-time` 再跑 `after-init-hook`，两行都在 init 文件加载之后），`startup_ms` 落 NULL 且事后无人能补。现在由 `after-init-hook` 一次性回调算出 `before-init-time` → `after-init-time` 的毫秒差，调 `el-chronos-store-note-startup-ms` **纯内存登记**；真正的 `UPDATE sessions SET startup_ms = ? WHERE id = ? AND startup_ms IS NULL`（`IS NULL` 守卫防覆盖已正确写入的值）由 store 的下一次 flush 在**既有事务内**完成，COMMIT 成功才清 pending、ROLLBACK 保留。因此**启动期零 IO**（`busy_timeout=2000ms` 最坏把启动拖住 2s 的风险归零）、不新增 timer（复用既有 5 秒 flush）。代价：补写延迟 ≤ 一个 flush 周期，其间读 `startup_ms` 仍为 NULL。同时 `el-chronos-collect-stop` 的清理顺序改为「先摘启动打点钩子与 timer → 再 `--sample-tick` 收尾 → 再摘其余钩子」：补写回调若在清理途中被触发，会往「正在关闭」的会话里再登记一次 pending，`store-close` 的 flush 就把它写进库了。
- **org 报告节数 10 → 11**：新增「GC 与内存」节，位置在「趋势」之后、「阻塞事件」之前；无数据时该节显示可见降级说明而非静默省略。
- **`hourly_gc` 的 `heap_bytes` 采用 `COALESCE` 覆盖语义**：堆大小每 N 个采样窗口才采一次，其余窗口传 NULL；若用普通覆盖写入，同一小时后到的窗口会把已采到的堆值抹成 NULL，因此改为 `COALESCE` 保留已有值。
- **阻塞提示默认静默**：`el-chronos-collect-notify-blocks` 默认由 `t` 改为 `nil`——心跳检测到主线程
  阻塞后不再往 echo area 打「el-chronos：主线程阻塞约 N ms（已记录）」，因为该行会盖住 minibuffer
  候选、打断正在进行的输入与补全。**事件仍然照记**：三种取值下 `slow_events(kind="block")` 都照旧
  落库并出现在报告 / dashboard 里，开关只控制提示层（`nil` 静默 / `messages` 用
  `(let ((inhibit-message t)) (message ...))` 只写 `*Messages*` / `t` 保持旧语义真 echo）。
  同步更新 `AGENTS.md`「已知边界」、`docs/operations.org`「阻塞提示」与 `docs/api.org` 的 defcustom 表。
- **TD-1 关闭**（native-comp `.eln` 归因）：实测 Emacs 31.1 下 `symbol-file` 对原生编译函数返回 `eln-cache` 内的 `.eln` 路径；落地「文件名剪哈希 + `locate-library` 反查」方案，真实 844 个 `.eln` 中 **815 个反查成功（96.6%）**、加 trampoline 判 `built-in` 后**仅 9 个 `unknown`（1.1%）**，共归因到 162 个包；未采用代价更高的 `comp-el-to-eln-filename` 遍历方案。
- **TD-2 关闭**（非命令型阻塞覆盖率）：命令外 ≥2s 计算型停转 **5/5 捕获**（命令内忙等、timer 回调、进程过滤器、`font-lock-fontify-buffer`），记录值恒高估 ≤1 心跳间隔（实测 1.6s 被记成 2.58s，+61%）；`<2s` 停转与等待型调用仍零覆盖，残余缺口转 TD-11 并写入 `docs/architecture.org`「实测结论 10」。
- **TD-3 关闭**（10ms 采样开销）：改用 CPU 时间（`get-internal-run-time`）+ 相位级 ABBA 重测（上次墙钟 ±9% 抖动导致失败）。噪声地板 ±0.7–1.1% 内 10ms 档读数 +0.98%、20ms 档 −1.11%，与采样率无单调关系；以 1ms 档实测 +0.46% 为锚点外推，**10ms 开销 ≈ 0.02–0.2%，远低于 0.5% 阈值 → 保持默认 10ms**。附带两条方法论：`profiler-cpu-log` 需 `maphash` 求样本总数（`hash-table-count` 是 distinct 栈数）；按微块起停 profiler 会因定时器重置而测空，必须相位级常驻。数据见 `docs/architecture.org`「实测结论 11」。
- 排障提示同步：归因 `unknown` 的原因改为「已删包残留 `.eln` / 临时 snippet」（`.eln` 已支持反查，TD-1 已关闭）。

- 按独立审查意见修订（plan-reviewer 审查）：计划新增「隐私边界」「数据生命周期」「错误处理矩阵」「回归判定」四节；I7/I8 重写（记录边界细化到「函数归因所需例外」、loopback 非访问控制且 Web 无鉴权）；`commands.project` 明确只存项目 basename；`hourly_*` 三表改为永久保留并新增 `el-chronos-purge` 与迁移 `.bak` 回滚；回归判定阈值固化为 `el-chronos-regression-window-days` / `-threshold` / `-min-samples`；任务拆分 T5→T5a–c、T8→T8a–d、T9→T9a–d 并收紧 T2/T3/T4/T6/T10/T12 验收；`AGENTS.md`、`Readme.org`、`docs/schema.org`、ADR-0001 同步；新增 TD-5/TD-6/TD-7。
- 计划文档清单补入 `docs/api.org`（elisp 对外接口索引）与 `docs/operations.org`（装卸、数据清理、排障）。
- 计划 `el-chronos-core.md` 归档到 `openspec/completed/`（Phase 4 Review & Document 完成，2026-10-24）；仓库内（`AGENTS.md` / `Readme.org` / `docs/*.org` / 两份 ADR）的计划链接统一指向归档路径，`openspec/active/` 保留为空目录。（本文件中「设计计划」一条保留当时的 `openspec/active/` 原始路径，属历史记录。）

### 移除

- **dashboard 模块与 ETAF 依赖移除**：删除 `el-chronos-dashboard.el`（1382 行：ETAF 组件树 + tabulated-list 降级页）与 `etaf` / `etaf-ui` 软依赖，可视化收敛为「浏览器 Web dashboard + org 报告」两形态（共享同一 `el-chronos-analysis` 查询层）。同时移除 5 个 defcustom（`el-chronos-dashboard-page-size` / `-max-rows` / `-chart-points` / `-chart-width` / `-refresh-seconds`）、24 个 dashboard ERT 用例与 5 项专用夹具；`test/el-chronos-ui-test.el` 更名为 `test/el-chronos-web-test.el`（9 个 Web 用例保留并改名为 `el-chronos-web-test-*`）。补 2 个 `el-chronos-show-event` 用例（该命令保留，原覆盖来自被删用例），用例总数 107 → **109**。不变量 I9 改写为「ETAF 已完全移除，可视化层不引入 ETAF」、I11 去掉 ETAF/SVG 降级子项；技术债 TD-5（ETAF 重绘性能）关闭。测试辅助函数同步更名为 `el-chronos-web-test--*`（不含用户可感知行为变化）。见 ADR-0003。

### 新增

- **亚秒级卡顿可见（S2）**：新增两档阈值——block（2000ms）保持 `slow_events` 明细，drift（500ms）写入新增的 `hourly_drift` 小时聚合表（count / total_ms / max_ms）；新增 `el-chronos-analysis-drift-trend` 查询、报告「阻塞事件」节内的一行 drift 摘要、`/api/drift` 路由与 dashboard 小节。
- **schema v3**：新增 `hourly_drift` 表；`el-chronos-purge` 扩到 11 表。
- 新增 defcustom `el-chronos-drift-threshold-ms`（默认 500）。
- **采集开销实测结论**：S1 新增采集的常驻开销实测为 0.0000177%（GC 采集）与 2.18 ms 一次性（启动打点，日常为 0）；心跳降至 250ms 实测 +0.0357%（距 0.5% 预算余 14 倍），为亚秒级阻塞捕获（TD-11 建议①）在开销维度扫清障碍。同时记录 5 条方法论教训（字节编译断言、GC 污染轮丢弃、timer 唤醒的 regime 差异等）。
- **Web dashboard 接入观测面扩展数据**：新增 4 条只读路由 `/api/gc`、`/api/startup`、`/api/health`、`/api/config-history`（路由总数 13 → 17），以及对应的 GC 与内存、启动分解、采集健康、配置变更四个面板（沿用 30 秒轮询）。
- **CSV 导出同步覆盖**：Web 侧 CSV 区块 8 → 11，新增 startup / health / config-history 三块，字段与 org 报告侧逐列对齐。
  用例总数 **192 → 199**（web 用例 10 → 17）。
- **启动分解 / 采集健康 / 配置变更：三个只读查询 + 报告三节 + 导出覆盖（T7b + T8）**：新增
  `el-chronos-analysis-startup-breakdown`（会话启动分解：`mode-start` / `after-init` / `startup` /
  `first-idle` 确定性锚点 + 包加载 TOP，`:startup-ms` 与 `:phases` 是两套来源、任一方缺失不影响
  另一方）、`el-chronos-analysis-health`（`hourly_health` 窗口求和 + `:ok-p` 坏消息判定 + `:rows`
  行数）、`el-chronos-analysis-config-history`（会话序列 + 与**前一会话**比对得出的变更点，首会话
  `:changed` 恒为 nil）。org 报告新增「启动分解」/「采集健康」/「配置变更」三节。
  **CSV/JSON 导出同步覆盖三个新查询**：CSV 追加 `# section: startup`（阶段锚点与包加载合成
  `kind` / `name` / `ms` 一张表）、`# section: health`（`metric` / `value`，含一行 `rows`，导出件
  同样能区分「没采集」与「没异常」）、`# section: config-history`（会话时间 / **完整** `git-head` /
  `config-sig` / `changed` 写 `1`/`0`）三个区块，JSON 新增 `startup` / `health` / `config_history`
  三个键；既有 5 个 CSV 区块与既有 JSON 键一律保留。用例总数 **179 → 192**。
- **启动耗时分解（T6）**：新增采集侧「启动打点」，落 `startup_phases` 表。① **3 个确定性锚点**：`mode-start`（`collect-start` 记，即观测起点）/ `after-init`（`after-init-hook`）/ `startup`（`emacs-startup-hook`），值均为相对 `before-init-time` 的毫秒偏移；`first-idle` 为**可选**锚点（仅在能注册 idle timer 时记一次），因 idle 时机受用户活动影响、不可预期，**不参与任何判定**。② **包加载明细**：挂内置 `after-load-functions`，把相邻两次触发的 `float-time` 差值记成「这次 load 的耗时」（**近似归因**，差值里含前一个文件的收尾逻辑与它触发的钩子执行），落 `load:<library>`；内存保存全部记录，**只在写库前**按毫秒降序截断到 top-N（新 defcustom `el-chronos-startup-top-n`，默认 50，`0`/`nil` = 不记明细只记锚点）。③ 摘钩用**确定性三元**（`emacs-startup-hook` 已触发 / 累计 load 次数达 `4 × top-n` / 30 秒一次性 timer，任一满足即摘并落库），不依赖 idle 时机，`mode -1` 后零残留（I5）。
  **物理边界（务必照此理解数据）**：用户通常在 init 末尾（或用 `emacs-startup-hook`）才开启 mode，此时启动已基本结束 → **只记 `mode-start` 锚点，无任何包加载明细，也没有 `after-init` / `startup` 锚点**（钩子**一个都不挂**，因为强行挂上只会把「启动后的日常加载」冒充成启动耗时）；要覆盖完整启动，必须把 `(el-chronos-mode 1)` 提前到 `early-init.el`。这一判断使本机这类配置的启动打点开销为零。
  用例总数 **167 → 179**（T6a 8 例：不挂判据 / 累计语义 / top-N 截断 / 摘钩 / 幂等 / 次数上限 / 锚点 / 安装清理；T6b 4 例：`startup_ms` 零 IO 捕获 / 时间缺失跳过 / `collect-stop` 顺序 / 清理完整性），含两个反向验证（去掉「启动已结束就不挂」→ 用例必红；去掉 top-N 截断 → 用例必红）。
- **采集器自监控计数（T5）**：`dropped-commands` / `dropped-events`（缓冲截断丢弃量，按 SLOT 分流、按差值口径累计）、`flush-failures`（flush 失败次数）、`flush-count` / `flush-ms`（flush 次数与累计耗时，**滞后一个周期**上报以避免「上报动作改变被上报值」的自指）、`sample-misses`（采样窗口整窗丢失），统一落 `hourly_health`。store 侧 5 类计数用**独立 defvar**——刻意不进 `--clear-aggregates` 清空的容器（否则 flush 失败会把「失败了几次」一并抹掉，那正是唯一需要它的时刻）；COMMIT 成功后才减去已上报部分，失败路径一分不减、等下一次成功 flush 补写（eventual）。
- 用例总数 **159 → 167**（新增 store 自监控 7 例 + collect 采样窗口 1 例）。同步调整 `el-chronos-store-test-flush-failure-clears-buffers` 的 `--pending-p` 断言：失败计数被刻意纳入 `--pending-p'，故失败后 `--pending-p' 仍为真，但唯一原因是待补写的 `flush-failures`（数据层面的「本批已丢弃」断言全部保留）。`--flush-count` / `--flush-ms-total` **不**纳入 `--pending-p'`，否则它们每次 flush 后都非零 → 恒 pending → 无限 flush 循环（已用反向验证锁住）。
- **GC 与内存趋势**：新增只读查询 `el-chronos-analysis-gc-trend`，按时间桶聚合 `hourly_gc`（GC 次数与耗时求和、堆大小取桶内最后一个非 NULL 值），并在 org 报告中新增第 11 节「GC 与内存」。
- 用例总数 **153 → 159**（`make test`，增量集中在 analysis 查询与 report 渲染两侧：analysis 4 例 + report 2 例）。
- **观测面扩展 S1 采集侧（schema v2）**：新增 `hourly_gc`（GC 次数 / 耗时 / 堆大小）、`startup_phases`（启动耗时分解）、`hourly_health`（采集健康自监控）、`session_meta`（变更标记）四张表。
- **变更标记**：每个会话记录 `git-head`（**零子进程**直接读 `.git`）与 `config-sig`（配置文件 mtime / size 指纹），用于把回归结论归因到「哪天改了什么」。
- **GC 与内存采集**：`gcs-done` / `gc-elapsed` 增量（零副作用）＋ `garbage-collect-heapsize`（Emacs 31.1+ 可用，更低版本该字段写入 NULL），与 profiler 采样解耦。
- **新增 defcustom**：`el-chronos-config-watch-globs`、`el-chronos-heap-sample-windows`。
- 用例总数 **121 → 153**（`make test`，增量集中在 store 写入层与 collect 采集侧）。
- **ETAF 可视化页面**（`el-chronos-dashboard.el`，976 行）：`*el-chronos*` 一屏呈现 10 项能力——概览卡片 6 指标、慢命令排行、热点函数排行（含包归属）、包/模块占比条形图、趋势折线、阻塞事件列表与详情、用法热力图、回归列表、会话列表与启动耗时、时间范围切换与行级下钻；快捷键 `1`/`7`/`3` 切范围、`g` 刷新、`r` 自动刷新、`d` 看完整栈、`q` 关闭。ETAF 缺失时降级为 `tabulated-list` 简版页（慢命令表 + 热点函数表 + 切范围），terminal frame 下图表降级为文本字符图（I9 / I11）。
- **Web dashboard**（`el-chronos-web.el`，初版 692 行，现 709 行）：内置 `make-network-process` 自写最小 HTTP server + 字符串内嵌单页（HTML/CSS/JS 全内嵌，无 CDN、离线可用），**13 条只读 GET 路由**（`/` 与 `/api/summary|top-functions|slow-commands|packages|trend|heatmap|stacks|sessions|blocking|regressions|event|export.csv`）；手写 SVG 趋势/环形图、DOM 热力网格、按层聚合的火焰图近似、搜索/排序/分页（10 行/页）、下钻侧栏、自动刷新（默认 30s，可关）、CSV 导出、多会话对比。只绑 `127.0.0.1`、默认不启动、无写入路由；端口占用 `user-error` 且不换端口（I8 / I11）。
- **单命令高精度剖析** `el-chronos-profile-command`（T11）：在 1ms CPU 采样下当场执行一次命令，输出热点 / 调用链 / 包归属 / 优化建议；profiler 已被常驻采样占用时复用共享模式（不自起自停）；`el-chronos-profile-save` 非 nil 时结果落 `slow_events(kind="profile")`。
- **ERT 测试初期 76 用例**（`test/` 6 个文件，`make test` 自动发现）：schema / 迁移 / 批量写入 / 保留策略 / top-N 淘汰 / purge、归因链与 basename 隐私断言、命令三态与心跳阻塞、采样聚合自洽、analysis 13 查询 fixture、回归判定、dashboard（ETAF 与降级两路）与 Web 路由冒烟（405 / 404 / 端口占用 / start-stop）。
- **报告层测试**（`test/el-chronos-report-test.el`，419 行 / 22 用例）：org 报告 10 节结构与动态回归窗口标题、周报、CSV/JSON 导出、单事件详情、单命令剖析 `--invoke` 三形态参数、Web 500 错误隐藏、端口 0 实际端口显示。
- **ERT 总计 106 用例**（7 个测试文件；分布 report 22 / ui 25 / collect 16 / analysis 15 / store 14 / attrib 14），源码 8 模块 + 测试 7 文件共 7067 行；`make full-check` 全绿（`Ran 106 tests, 106 results as expected, 0 unexpected`，约 4.6 s），`make lint` 零告警。
- **文档**：新增 `docs/ui.org`（三形态总览、ETAF 组件树与 10 项能力映射、快捷键、**ETAF 10 条实测踩坑**、13 条 Web 路由表、org 报告 10 节、性能注意与 TD-5）、`docs/api.org`（8 模块对外接口索引、defcustom 清单、内部函数 `--` 不承诺兼容）、`docs/operations.org`（安装/卸载/数据清理/排障/验证步骤/隐私与保留表）；`docs/architecture.org` 补「实测结论」与「已知偏差」，`docs/schema.org` 补最终 DDL、top-N 淘汰 SQL、`session_id` 事实非空约束与 P95 近似说明；ADR-0002 状态转 Accepted 并补「实施结果」；`Readme.org`、`AGENTS.md` 同步。
- 项目初始化：建立仓库骨架（`Makefile` 验证入口、`.gitignore`、`AGENTS.md` 仓库地图、`Readme.org` 项目说明）。
- 设计计划：`openspec/active/el-chronos-core.md`，定义观测器分层、数据模型、采集策略、不变量与 T1–T10 任务分解。
- 架构决策记录：`openspec/decisions.md` 记录双源采集、SQLite 小时聚合、函数级定位边界、命令级隐私边界四项决策；`docs/adr/0001-observer-architecture.md` 给出完整 ADR。
- 文档骨架：`docs/architecture.org`（分层数据流与采集时序）、`docs/schema.org`（5 张表结构与典型查询）。
- 技术债清单：`openspec/tech-debt.md` 记录 4 项待实测项。
- 双形态可视化（增量需求）：Emacs 内可视化页面（`el-chronos-dashboard.el`，ETAF 实现：组件树 + `etaf-ui-svg` 图表 + `etaf-ui-table` 表格 + 下钻）与浏览器 Web dashboard（`el-chronos-web.el`，最小 HTTP server + 内嵌 HTML/CSS/JS、只绑 `127.0.0.1`、离线可用），两者共享同一 analysis 查询层。
- 数据模型扩充：新增 `hourly_stacks` 表（每小时 top-N 栈样本，默认 200，供火焰图与调用链分析），`docs/schema.org` 同步字段表与保留策略。
- 不变量扩充：新增 I8（Web 只绑 loopback、默认关闭、只读）、I9（dashboard 对 ETAF 软依赖、缺失降级）、I10（可视化资源内嵌/本地生成、无 CDN）、I11（不可用必须可见降级）。
- 架构决策记录：`docs/adr/0002-dual-visualization.md` 记录双形态与 Emacs 侧选用 ETAF 的决策、代价与 6 条被否决替代方案；`openspec/decisions.md` 追加对应行。
- 计划任务重排为 T1–T12（新增 T8 dashboard、T9 Web，T11 高精度剖析独立成任务），验收标准同步补齐可视化三条。
- 采集层：命令计时（`ok` / `aborted` / `error` 三态，含 GC 差值）、1s 心跳阻塞检测、内置 C profiler 常驻采样与窗口聚合（`el-chronos-collect.el`，T5a–T5c）。
- 存储层：SQLite 6 张表（`commands` / `slow_events` / `hourly_functions` / `hourly_usage` / `hourly_stacks` / `sessions`）、批量 flush、retention 保留策略、`hourly_stacks` top-N 淘汰、`PRAGMA user_version` 迁移与 `.bak` 备份回滚、`el-chronos-purge` 手动清理（`el-chronos-store.el`，T4）。
- 归因层：符号 → 源码文件 → straight 包 / `lisp/init-*.el` 模块 / site-lisp / built-in，项目只记 basename，隐私粒度按 `el-chronos-usage-granularity` 控制（`el-chronos-attrib.el`，T3）。
- 分析层：13 个聚合查询（top 函数、慢命令、阻塞事件、包归因、趋势、热力、栈样本、会话、回归判定等），返回 plist 供两种可视化形态共用（`el-chronos-analysis.el`，T6）。
- 报告层：org 报告（1/7/30 天）、周报、CSV/JSON 导出、单事件详情（`el-chronos-report.el`，T7）。
- 入口模块：`el-chronos-mode`（global minor mode）、defcustom 全套、启停编排幂等与 SQLite 不可用降级（`el-chronos.el`，T2）。
- 用例总数 **200 → 233**（上一档 199 → 200 由 `el-chronos-report-test-csv-sections-match-web` 带来，锁住 web 与 report 两侧 CSV 区块对齐；本档 200 → 233 为 S2 drift 两档阈值：collect 65 / store 60 / report 33 / analysis 29 / attrib 28 / web 18）。
