;;; el-chronos-collect.el --- 命令计时、心跳阻塞、采样聚合与 GC 归因  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Thomas

;; Author: Thomas
;; Keywords: tools, performance
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; 采集层：把三种运行时信号转成结构化事件，交给 store 层按小时聚合落库。
;;   T5a 命令计时：`pre-command-hook' 记起点，`post-command-hook' 结算耗时与 GC 差值；
;;       `C-g' 通常**仍会**跑 `post-command-hook'（quit 在命令循环里被捕获），这类命令
;;       照常结算为 `ok'/`error'，duration 含卡顿时间 —— 正是目标 #1 要看的；
;;       `aborted' 只覆盖上一条命令在下次 `pre' 时仍未结算的情形，即
;;       `post-command-hook' 被彻底跳过的顶层中断（`throw' 到顶层、`top-level' 重启、
;;       在 hook 自身或深层原生代码里跳出命令循环）；
;;       命令抛错由 `command-error-default-function' 的 advice 标记，结算为 `error'。
;;   T5b 心跳阻塞：1s timer 比较相邻触发间隔，漂移超 `el-chronos-block-threshold-ms'
;;       记 `slow_events(kind='block')`。阻塞期间没有可靠的 Lisp 回调，只能事后回溯（I2）。
;;   T5c 采样聚合：内置 C profiler 常驻采样（I1），每 `el-chronos-sample-window-seconds'
;;       取走 `profiler-cpu-log'（取用即重置），内存里按小时聚合，禁止逐窗口写库。
;;   T6a 启动打点：`after-load-functions' 把相邻两次触发的差值记成「这次 load 的耗时」
;;       （近似归因），加 3 个确定性阶段锚点（`mode-start' / `after-init' / `startup'）
;;       与 1 个可选锚点（`first-idle'）；摘钩用确定性三元，且**启动已结束时一个钩子都不挂**
;;       （否则日常加载会被冒充成启动耗时）。
;;   T6b GC 归因：`post-gc-hook' 把每次 GC 归到「**发生在**哪条命令之后 / 哪个 mode 里」
;;       （不是「哪条命令**导致**」），累积进二级 `eq' 哈希
;;       （command → mode → `[gc-count gc-ms]'），随采样窗口交给 store 累加到
;;       `hourly_gc_attrib'。hook 热路径**禁止字符串分配**（GC 刚清空堆，任何分配都会把
;;       下一次 GC 提前）；与 `hourly_gc' 的关系只是 `sum(attrib) ≤ gc_count'，
;;       差值来自 hook 安装前的 GC 与最后一次 flush 之后未结算的 GC。
;;
;; 采集路径上的一切异常都必须吞掉（I6）：子步骤失败只 `display-warning'（10 分钟限流），
;; 不得中断命令循环、不得终止 timer。
;;
;; 实测结论（2026-10-24，GNU Emacs 31.1，`emacs -Q --batch'，递归
;; probe-outer → probe-inner → probe-leaf 采样 1716 个样本）：
;;  1. `profiler-cpu-log' 返回 **hash table**（键 = 符号 vector，值 = 样本数），
;;     不是早期版本的 alist；本模块对两种形态都做了兜底。
;;  2. 栈顺序：`(aref stack 0)' 是**最内层（leaf，最近一次求值）**，
;;     `(aref stack (1- len))' 是最外层（`command-line' / `normal-top-level'）。
;;     实测一条栈（长度 16）：
;;       [0]=let [1]=while [2]=let [3]=let [4]=probe-leaf [5]=+ [6]=setq [7]=let
;;       [8]=while [9]=let [10]=let [11]=probe-inner [12]=probe-outer
;;       [13]=load-with-code-conversion [14]=command-line-1 [15]=command-line
;;     故 self 时间归属取 `(aref stack 0)'。leaf 常是 `let'/`while'/`+' 这类 subr
;;     （解释执行的函数把 self 时间落在它们身上），不做额外过滤。
;;  2b. self / total / samples 三列的口径，不能都记 leaf（否则 self_ms == total_ms，
;;     中间帧永远为 0，无法回答「慢在哪个函数、调用链是什么」）：
;;       - self / samples：只给每条栈第 0 帧（leaf）加 count。二者**同源同口径**，
;;         区别仅在落库形态 —— self 乘采样间隔换算成毫秒，samples 留原始计数，
;;         故恒有 `self_ms = samples × 采样间隔'。即
;;         **samples = 该函数作为 leaf 被采样的次数**（self 口径）；
;;         把全表 samples 求和恰好等于窗口内的真实样本总数（每条样本只有一个 leaf），
;;         可直接作百分比分母。
;;       - total：给该栈中**出现过的每个函数**各加一次 count，栈内先去重，故中间帧 /
;;         根帧的 total 等于「经过它的样本数」，恒有 self_ms ≤ total_ms。
;;         只作为中间帧出现的函数 samples 恒为 0 而 total_ms > 0 —— 这是**有意的**：
;;         占比与回归判定都按 self 口径，避免「出现得多但自己不耗时」的函数虚高。
;;     与内置 `profiler-report' 的关系：self 列只归栈顶帧，这一点与内置报告同口径；
;;     但 total 列（该函数作为栈帧出现过的样本数）是本模块按上述**栈内去重**规则自算的，
;;     与内置报告的 total 列**不完全相等**（内置按每帧累加），不要据此声称两者逐位相等
;;     或互相校验（见技术债 TD-10）。
;;     代价：每条栈多一遍遍历，栈内去重是 `memq' 的 O(栈长²)（实测栈长 ≤ 40 帧，可忽略），
;;     且汇总只发生在窗口 tick（`el-chronos-sample-window-seconds'，默认 10s）上，
;;     不在命令热路径里。
;;  3. `(backtrace)' 自 Emacs 31 起改为「打印调用栈」并返回 nil；取帧列表要用
;;     `backtrace-frames'（帧格式 `(求值否 函数 参数表 标记)'）。
;;  4. SQLite 绑定与 `json-serialize' 都不接受符号（前者报
;;     `(sqlite-error "invalid argument")'）；故落库前 outcome / kind 与栈里的符号
;;     一律转字符串，DB 里仍是 TEXT 的 ok/error/aborted、block/command。
;;
;; TD-9 修复说明（2026-10-24）：Emacs 31 起 `pre-command-hook' / `post-command-hook'
;;   是 auto-buffer-local —— `add-hook' 不带 LOCAL 时只改**默认值**，而任何已经留下
;;   局部绑定的 buffer（实测 `*scratch*' 被 eldoc 留过局部值）会用局部值遮蔽默认值，
;;   该 buffer 内的命令因此完全不计时（漏采）。修法为「全局默认值 + 每个 buffer 补挂
;;   局部值」两路并行：
;;   1. `el-chronos-collect-start' 仍先装全局 `add-hook'（新 buffer 未建局部绑定时的
;;      默认来源，也是 `el-chronos-mode -1' 后的正常态）；
;;   2. `el-chronos-collect--ensure-buffer-hooks' 遍历 `buffer-list'，给尚无登记的表项
;;      在 buffer 局部追加本模块两个函数，并 `puthash' 记入
;;      `el-chronos-collect--hooked-buffers'（weak key：buffer 被 kill 后自动出表）；
;;   3. `buffer-list-update-hook' 挂同一个 ensure 函数，新建或切换 buffer 后立即补挂
;;      （增量：只处理未登记的 buffer，已登记者一次 `gethash' 即返回）；
;;   4. `el-chronos-collect-stop' 先摘 `buffer-list-update-hook'，再由
;;      `el-chronos-collect--clean-buffer-hooks' 用 `remove-hook ... LOCAL=t' 摘掉每个
;;      buffer 的**局部**值并清空登记表，保证 `el-chronos-mode -1' 零残留（I5）。
;;   补挂时先确保局部绑定存在（无局部绑定时复制默认值），避免 add-hook 的局部语义
;;   在不同 Emacs 版本间差异导致丢掉其他包的默认 hook。
;;
;; D1 双跑陷阱与两层防护（2026-10-24 最终验收修复）：buffer 局部 hook 值**末尾带 `t'**
;;   时，`run-hooks' 先跑局部值、再跑全局值（`t' 的语义就是「同时跑全局值」）。此时若
;;   本模块既在全局默认值里、又被补挂进该 buffer 的局部值，同一个 hook 函数会对同一条
;;   命令执行两次：第一次开始计时，第二次把刚开始的命令按 `aborted'（0ms）结算 —— 于是
;;   每条命令产生 1 条 `ok' + 1 条 `aborted'，`commands' 表整体翻倍。两层防护：
;;   1. **补挂判据收紧**（`el-chronos-collect--ensure-buffer-hooks'）：只给「有局部绑定
;;      且局部值不含 `t'」的 buffer 补挂 —— 这类 buffer 的局部值完全遮蔽全局默认值
;;      （TD-9 的漏采场景，必须补）；无局部绑定或局部值含 `t' 的 buffer 本来就会跑到
;;      全局默认值，**不补挂**。判据必须用 `local-variable-p'：`buffer-local-value'
;;      在无局部绑定时回落到全局值，区分不出「有局部绑定」与「没有」。
;;   2. **命令级防御性去重**（`el-chronos-collect--pre-command'）：`--pending-p' 为真、
;;      命令名与本条命令相同、且距 `--command-start' 不足 1ms 时，判为同一命令被重复
;;      触发，直接返回，既不结算也不重置计时。
;;   第 2 层只兜底「局部值后来被别人改成带 `t'」这类运行时变化，正常路径由第 1 层挡住。
;;
;; 命令名归一（2026-10-24）：旧实现直接读 `this-command'，取不到就落 `unknown'，于是
;; `commands' 里混进一类既不能归因、又污染 top-N 与中断率分母的无主行（实测线上
;; 107/10887 = 0.98%，全部 `ok'、集中在 `fundamental-mode' / `dashboard-mode' /
;; `eca-chat-mode'，且常成串出现）。现在改为 `el-chronos-collect--command-label'：
;;   1. **`real-this-command' 优先**：它是命令循环记下的「用户真正要求的命令」，
;;      而 `this-command' 可能被命令自身改写（`push-button' 换成回调、
;;      `execute-extended-command' 在执行前把它换成实际命令）；
;;   2. 符号 → `symbol-name'；字符串（键绑定为键盘宏）→ 原样；其他非 nil 对象
;;      （`#[...]' 解释函数 / `closure' / keymap）→ 按 `(type-of CMD)' 落库，
;;      故 lambda 绑定记作 `interpreted-function' 而不是旧实现里的 `anonymous'；
;;   3. **两者均为 nil → 返回 nil**，`--pre-command' 据此不开始计时、不落库
;;      （宁可不记，也不产生无主行），上一条未结算的 pending 仍按 `aborted' 收尾。
;; 由此 `commands.name' 恒为「可归因的名字」，不再出现 `unknown'。
;;
;; 实测事实（2026-10-24，Emacs 31.1，真实命令循环 `recursive-edit' 下逐条打印
;; `pre-command-hook' / `post-command-hook' 的 `this-command' 与 `real-this-command'）：
;;  1. **M-x 只触发一次 `pre-command-hook'**（命令名 = `execute-extended-command'）：
;;     `execute-extended-command' 内部用 `command-execute' 跑实际命令，而
;;     `command-execute' **不走** pre/post hook —— 「M-x 会触发两次 hook」不成立。
;;     因此**不能**跳过 M-x 中间态：跳过后经 M-x 触发的命令（当前 61 行）将不再被采集，
;;     且 post 阶段无法补偿（见下条）。
;;  2. `post-command-hook' 时刻读到的 `this-command' / `real-this-command' 是**上一条**
;;     命令（命令循环在 post 之后才把它们滚到 `last-command'）。故结算必须用
;;     `--pre-command' 存下的 `--command-name'，**不得**在结算时重新读命令名 ——
;;     那会把上一条命令的名字安到本条上。
;;  3. 前缀键（`C-c p a'）只对最终命令触发一次 hook；宏录制 / 定时器里
;;     `call-interactively' / 命令内 `setq this-command' 均给出符号名。
;;  4. `execute-extended-command' 在 `command-execute' 之前把 `this-command' 与
;;     `real-this-command' 双双设成实际命令（simple.el 原注释：让 M-x <cmd> RET 等同于
;;     <cmd> 的键绑定），但这一改写发生在 hook 之外，采集层读不到；要把 M-x 记录归到
;;     实际命令需给 `execute-extended-command' 加 advice（新采集路径，未实施）。

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'el-chronos)
(require 'el-chronos-attrib nil t)

;; 兄弟模块的软引用：collect 可单独加载（例如批量测试），store 由入口模块先行加载。
(declare-function el-chronos-attrib-context "el-chronos-attrib" ())
(declare-function el-chronos-attrib-file "el-chronos-attrib" (symbol))
(declare-function el-chronos-attrib-package "el-chronos-attrib" (symbol-or-path))
(declare-function el-chronos-store-record-command "el-chronos-store" (event))
(declare-function el-chronos-store-record-slow-event "el-chronos-store" (event))
(declare-function el-chronos-store-record-usage "el-chronos-store"
                  (hour-ts dimension key count duration-ms))
(declare-function el-chronos-store-record-function-samples "el-chronos-store"
                  (hour-ts function file package self-ms total-ms samples))
(declare-function el-chronos-store-record-stacks "el-chronos-store" (hour-ts stacks))
(declare-function el-chronos-store-record-gc "el-chronos-store"
                  (hour-ts gc-count gc-ms heap-bytes))
(declare-function el-chronos-store-record-health "el-chronos-store"
                  (hour-ts key value))
(declare-function el-chronos-store-record-startup-phase "el-chronos-store"
                  (session-id phase ms))
(declare-function el-chronos-store-record-drift "el-chronos-store" (hour-ts gap-ms))
(declare-function el-chronos-store-record-gc-attrib "el-chronos-store"
                  (hour-ts session-id command mode gc-count gc-ms))
(declare-function el-chronos-store-note-startup-ms "el-chronos-store" (ms))
(declare-function el-chronos-store-record-resources "el-chronos-store" (hour-ts plist))
;; 启动探针是**可选**的零依赖侧文件（用户在 `early-init.el' 里显式 load）：
;; 这里只声明签名，配合 `fboundp' 软调用，**绝不 require** —— 探针缺失时 collect
;; 必须完全照旧工作，且 collect 不加载它就没有任何探针相关开销。
(declare-function el-chronos-startup-probe-take "el-chronos-startup-probe" ())

;;; 自定义项

(defcustom el-chronos-collect-notify-blocks nil
  "心跳检测到主线程阻塞时如何提示。
阻塞事件**始终**记入 `slow_events'（`kind' = \"block\"）并出现在报告与 Web 页面里，
本开关只控制「提示」这一层，取任何值都不影响采集与记录。

取值：
- nil      —— 默认，完全不提示（既不占 echo area，也不写 `*Messages*'）。
- messages —— 只写 `*Messages*'：`message' 被 `inhibit-message' 包住，
              不占用 echo area，不打断正在进行的 minibuffer 输入与补全。
- t        —— 在 echo area 提示一句（旧语义，兼容既有配置）。

为什么默认静默：这条提示落在 echo area，用户输入中途出现会盖住 minibuffer 候选、
干扰正常输入；而阻塞本身事后在报告 / Web 页面里可查。需要即时可见性时再显式
改成 `messages'（只进日志）或 `t'（真 echo）。"
  :type '(choice (const :tag "静默（只记录，不提示）" nil)
                 (const :tag "只写 *Messages*" messages)
                 (const :tag "echo area 提示" t))
  :group 'el-chronos)

;;; 运行时状态

(defvar el-chronos-collect--pending-p nil
  "是否有一条命令已开始计时但尚未结算。
为真时再遇到 `pre-command-hook' 说明上一条命令没走到 `post-command-hook'，按 `aborted' 结算。")

(defvar el-chronos-collect--command-start nil
  "当前命令的起点 `float-time'；nil 表示没有计时中的命令。")

(defvar el-chronos-collect--command-name nil
  "当前命令名（由 `el-chronos-collect--command-label' 归一，`real-this-command' 优先）。
在 `pre-command-hook' 里写入、结算时读取；**结算阶段不回读命令名**，因为那时
`this-command' / `real-this-command' 已是上一条命令。nil 表示没有计时中的命令。")

(defvar el-chronos-collect--command-gc-done nil
  "当前命令开始时的已完成 GC 次数（`gcs-done'）；诊断留档，口径以 `gc-elapsed' 差值为准。")

(defvar el-chronos-collect--command-gc-elapsed nil
  "当前命令开始时的累计 GC 时间（`gc-elapsed'，秒）。")

(defvar el-chronos-collect--errored-p nil
  "当前命令是否抛错：advice 置 t，`pre-command-hook' 清零，结算时读。")

(defvar el-chronos-collect--last-heartbeat nil
  "上一次「命令外时间」的结算时刻（`float-time'）；nil 表示尚无基线。
由三处推进：心跳 timer / `--pre-command' 的补判（都经
`el-chronos-collect--heartbeat-check'）、以及 `--finish' 的**纯重置**（结算命令时把
命令执行时间从 gap 中切掉）。语义仍是「上一次结算时刻」，不是「上一次真实心跳」。")

(defvar el-chronos-collect--suppress-block-p nil
  "非 nil 时心跳跳过判定（block 与 drift **两档都跳过**），只推进基线（抑制自观测假阳性）。
由 `el-chronos-report' 在渲染期间 `let' 绑定为 t；
`el-chronos-collect--heartbeat-check' 用 `bound-and-true-p' 读取并据此跳过判定，
同时把 `el-chronos-collect--last-heartbeat' 推进到当前时刻 —— 否则解除绑定后
那一次补跑的心跳会把整段渲染耗时算成一条巨型阻塞（I2 只认时间差，无法事后区分）。
drift 判定与 block 判定写在同一个 `unless' 之内，故本变量对两档一视同仁；
抑制宏第 2 层（`let' 抬高 `el-chronos-block-threshold-ms'）只对 block 档生效。
report 侧 `defvar' 同名声明，避免跨模块 `let' 绑定未声明变量报
`void-variable'；同义重复声明无副作用。")

(defvar el-chronos-collect--gc-baseline nil
  "上一次 GC 采样的基线，形如 `(gcs-done . gc-elapsed)'；nil 表示尚未初始化。
两个计数器都是 Emacs 自维护的**累计值**（启动至今），故首个窗口只初始化基线、
增量记 0 —— 否则会把开机以来累计的 GC 全算进这一个采样窗口。")

(defvar el-chronos-collect--heap-tick-counter 0
  "距上次堆采样已过去的采样窗口数。
每窗口 +1，达到 `el-chronos-heap-sample-windows' 时归零并采一次堆大小
（默认 6 个窗口 ≈ 60 秒；其余窗口给 store 传 nil，由 COALESCE 保住上次观测值）。")

(defvar el-chronos-collect--resource-baseline nil
  "上一次资源采样的基线，形如 `(CPU-TIME . FLOAT-TIME)'；nil 表示尚未初始化。
CPU-TIME 是 `(process-attributes (emacs-pid))' 的 `time' 字段（`current-time' 格式的
**进程累计 CPU 时间**，不是浮点秒）；FLOAT-TIME 是同一时刻的 `float-time'。
CPU-TIME 是累计量、FLOAT-TIME 是墙钟锚点，两者都只用于差分，故首个窗口**只建基线、
增量记 0**（与 `--collect-gc' 同口径）—— 否则会把开机以来累计的 CPU 时间全算进
这一个采样窗口，`cpu_ms / wall_ms' 的比值首窗就会离谱。
`el-chronos-collect-start' 初始化、`el-chronos-collect-stop' 清空（I5）。")

(defvar el-chronos-collect--last-sample-tick nil
  "上一次采样窗口实际触发的时刻（`float-time'）；nil 表示尚无基线。
**不复用 `el-chronos-collect--last-heartbeat'**：两个 timer 独立调度（心跳 0.25 秒、
采样窗口 10 秒），语义也不同 —— 心跳基线用于判定「主线程被占多久」，
本基线用于判定「采样窗口是否整窗丢失」。共用一个变量会让两条 timer 互相推进对方的基线，
两边的判定同时失真（心跳永远不超阈值、窗口永远不丢）。
`el-chronos-collect-start' 初始化、`el-chronos-collect-stop' 清零（I5）。")

(defvar el-chronos-collect--timers nil
  "本模块创建的 timer 列表（心跳 + 采样窗口），停止时逐个 cancel 并摘除登记（I5）。")

(defvar el-chronos-collect--sampling-p nil
  "内置 CPU profiler 是否由本模块启动并正在采样。")

(defvar el-chronos-collect--running-p nil
  "采集层是否已启动。用于 start 幂等。")

(defvar el-chronos-collect--hooked-buffers (make-hash-table :weakness 'key)
  "已经判断过补挂的 buffer（TD-9 / D1）。
键为 buffer 对象，weak key：buffer 被 kill 后可被 GC 回收，登记自动消失。
值为 t（只作成员判断，不存数据）。登记不代表「一定补挂过」——按
`el-chronos-collect--ensure-buffer-hooks' 的判据，局部值带 `t' 或无局部绑定的 buffer
会被跳过，但同样登记以免重复判断。停止时必须清空（I5 零残留）。")

(defvar el-chronos-collect--warned-at nil
  "上次告警的 `float-time'，用于 `el-chronos-collect--warn' 限流。")

(defvar el-chronos-collect--window-self (make-hash-table :test #'eq)
  "本窗口 self/total/samples 累计表：函数符号 → [SELF TOTAL SAMPLES]。
SELF 与 SAMPLES **同源**：都只统计「该函数**作为 leaf（栈顶帧）** 被采样」的次数，
区别仅在落库形态 —— SELF 乘采样间隔换算成毫秒，SAMPLES 留整数计数，
故恒有 `self-ms = samples × 采样间隔'（I4）。
TOTAL 统计「该函数在某条栈里出现过」的样本数（同一栈内多次出现只算一次），
故恒有 SELF ≤ TOTAL；只作为中间帧出现的函数 SELF = SAMPLES = 0 而 TOTAL > 0。
完整调用链交给 `el-chronos-collect--window-stacks'。")

(defvar el-chronos-collect--window-stacks (make-hash-table :test #'equal)
  "本窗口的调用栈累计表：栈的 JSON 字符串 → 样本数。")

(defvar el-chronos-collect--gc-attrib-last-done nil
  "上次记录的 `gcs-done' 值；nil 表示尚未建立基线。用两个独立整数而非 cons，
避免在 `post-gc-hook' 里分配 cons。")

(defvar el-chronos-collect--gc-attrib-last-elapsed nil
  "上次记录的 `gc-elapsed' 值（秒，float）。")

(defvar el-chronos-collect--gc-attrib-buffer (make-hash-table :test #'eq :size 64)
  "GC 归因缓冲：**二级** `eq' 哈希 —— 外层 key 是 command symbol，内层 hash 的 key
是 mode symbol，value 是 `[gc-count gc-ms]' 向量。
用二级表而非 `(cons command mode)' 作键：`post-gc-hook' 里每次分配 cons 都会让
下一次 GC 提前。内层表与向量只在**首次**遇到某个 command/mode 组合时分配。

内层表数量 = 10 秒窗口内出现过的不同 command 数，flush 时随外层一起清空；
不设显式上限——窗口只有 10 秒，正常负载下为数个到数十个。若不设上限仍担心
异常场景（插件生成海量匿名命令符号），可改为在 `--post-gc' 里对 `hash-table-count'
超过阈值时直接跳过记录（当前未做，属已知残余风险）。")

(defvar el-chronos-collect--gc-attrib-busy nil
  "递归/重入守卫：hook 执行期间置 t。")

;;; 小工具

(defun el-chronos-collect--warn (format-string &rest args)
  "限流告警：每 600 秒（10 分钟）最多一条，绝不抛错。
采集路径上的告警必须限流，否则「磁盘写满」这类故障会自己变成卡顿源。"
  (condition-case nil
      (let ((now (float-time)))
        (when (or (null el-chronos-collect--warned-at)
                  (> (- now el-chronos-collect--warned-at) 600))
          (setq el-chronos-collect--warned-at now)
          (display-warning 'el-chronos (apply #'format format-string args) :warning)))
    (error nil)))

(defun el-chronos-collect--safe-funcall (function)
  "无参调用 FUNCTION；未定义或出错时限流告警并返回 nil（I6）。"
  (condition-case err
      (when (fboundp function) (funcall function))
    (error (el-chronos-collect--warn "%s 调用失败：%S" function err) nil)))

(defun el-chronos-collect--safe-apply (function arguments)
  "以参数表 ARGUMENTS 调用 FUNCTION；未定义或出错时限流告警并返回 nil（I6）。"
  (condition-case err
      (when (fboundp function) (apply function arguments))
    (error (el-chronos-collect--warn "%s 调用失败：%S" function err) nil)))

(defun el-chronos-collect--hour-ts ()
  "当前整点的时间戳，单位毫秒（I4）——聚合表按整点对齐，不逐窗口写库。"
  (* 3600000 (floor (/ (float-time) 3600))))

(defun el-chronos-collect--interval-ms ()
  "一个采样样本代表的时间，单位毫秒（由纳秒间隔换算，I4）。"
  (/ (float el-chronos-sampling-interval-ns) 1000000.0))

(defun el-chronos-collect--frame-head (frame)
  "取出帧 FRAME 的函数位对象：可能是符号、闭包（`closure' / `#[...]'）或 nil。
帧形状兼容 `(求值否 函数 参数表 标记)'（Emacs 31 的 `backtrace-frames'）
与更早的 `(函数 参数...)'；非 cons 输入（裸符号 / 闭包向量 / nil）原样返回。"
  (cond ((not (consp frame)) frame)
        ((memq (car frame) '(t nil)) (nth 1 frame))
        (t (car frame))))

(defun el-chronos-collect--frame-function (frame)
  "从一帧 FRAME 取出函数符号，取不到返回 nil（非符号的函数位一律视为取不到）。"
  (let ((head (el-chronos-collect--frame-head frame)))
    (when (symbolp head) head)))

(defun el-chronos-collect--frame-name (function)
  "把栈帧的函数位 FUNCTION 归一成字符串名，保证落库与展示里不出现 nil。
nil（取不到函数位，如原生代码里的匿名帧）→ \"unknown\"；
非符号（`closure' 闭包 / 字节码 `#[...]' / 其他对象）→ \"anonymous\"；
符号 → `symbol-name' 的结果。
调用方一律传**函数位**（`el-chronos-collect--frame-head' 的结果，或 profiler 栈里的
元素本身），不要直接传整个帧 cons。
`hourly_functions.function' 与 `slow_events.stack_json' 共用本函数，口径一致；
栈聚合的 hash key 也用它，故同一个闭包对象不会因 `format' 差异生成两个 key。"
  (cond ((null function) "unknown")
        ((symbolp function) (symbol-name function))
        (t "anonymous")))

(defun el-chronos-collect--backtrace-frames ()
  "返回当前调用栈的帧列表（最内层在前），且绝不向任何输出流打印内容。
Emacs 31 起 `(backtrace)' 改为打印调用栈并返回 nil，故优先用 `backtrace-frames'；
旧版回退 `backtrace'，并把 `standard-output' 绑成丢弃函数以防意外打印。"
  (let ((standard-output #'ignore))
    (cond ((fboundp 'backtrace-frames) (backtrace-frames))
          (t (ignore-errors (backtrace))))))

(defun el-chronos-collect--current-stack ()
  "返回当前调用栈的函数名列表（最多 40 帧），栈顶在前。
每个帧名都经 `el-chronos-collect--frame-name' 归一（nil → \"unknown\"、非符号函数位 →
\"anonymous\"），故结果里既没有 nil 也没有对象字面量，可直接 JSON 序列化进
`slow_events.stack_json'。
**注意**：这是**结算时刻**的栈，不是慢函数现场栈；精确现场栈由 T11 高精度剖析提供。
当前无生产调用者：慢命令事件的 `:stack` 已改为恒 nil（见 `--finish` 的说明）。
保留给「按命令窗口切分采样栈」的后续实现，同时
`el-chronos-collect-test-frame-name-normalization` 用例仍直接覆盖本函数
（nil 帧裁剪 / JSON 序列化），删掉本函数会让该逻辑失去测试。"
  (condition-case nil
      (let* ((frames (el-chronos-collect--backtrace-frames))
             (names nil))
        (dolist (frame (cl-subseq frames 0 (min 40 (length frames))) (nreverse names))
          (push (el-chronos-collect--frame-name (el-chronos-collect--frame-head frame))
                names)))
    (error nil)))

;;; T5a 命令计时

(defun el-chronos-collect--note-error (&rest _)
  "标记「刚才执行的命令抛出了错误」。
挂在 `command-error-default-function' 的 `:before' advice 上，只置位不做 IO。
若用户把 `command-error-function' 换成**不委托**给默认实现的函数，本标记不会触发，
该命令会被结算为 `ok'（除非没走到 `post-command-hook'，那时记 `aborted'）——见技术债 TD-8。"
  (setq el-chronos-collect--errored-p t))

(defun el-chronos-collect--command-label ()
  "返回当前命令的落库名；命令名无法确定时返回 nil。
读取顺序：`real-this-command' 优先，其次 `this-command'（都用 `bound-and-true-p'
读取，未绑定或为 nil 时回落）。`real-this-command' 是命令循环记下的「用户真正要求的
命令」，`this-command' 则可能被命令自身改写 —— 例如 `push-button' 换成按钮回调、
`execute-extended-command' 在处理完命令名后把它换成实际命令；普通键路径下两者恒等
（实测 Emacs 31.1）。

归一规则：
- 符号 → `symbol-name'（绝大多数命令，也是唯一能归因到函数 / 包的形态）；
- 字符串 → 原样返回（键绑定为键盘宏字符串时）；
- 其他非 nil 对象 → `(format \"%s\" (type-of CMD))'，即按类型落库（`#[...]'
  解释函数实测为 `interpreted-function'，闭包 / keymap 同理）；
- nil → 返回 nil，**由调用方决定跳过**：本函数不提供 `unknown' 之类的兜底名，
  无主行会污染 top-N 与中断率分母（见 Commentary「命令名归一」）。

栈帧名不走本函数（那是另一维度：`el-chronos-collect--frame-name' 用 `unknown' /
`anonymous' 表示取不到 / 非符号的函数位）。"
  (let ((cmd (or (bound-and-true-p real-this-command) this-command)))
    (cond ((null cmd) nil)
          ((symbolp cmd) (symbol-name cmd))
          ((stringp cmd) cmd)
          (t (format "%s" (type-of cmd))))))

(defun el-chronos-collect--pre-command ()
  "命令开始计时。
若上一条命令仍未结算，先按 `aborted' 结算。

命令名取 `el-chronos-collect--command-label' 的结果：
- 为 nil（`this-command' 与 `real-this-command' 都取不到）→ **不开始计时**，清空命令
  状态后返回。这类触发无法归因，落库只会得到无主行（旧实现记 `unknown'，实测线上占
  0.98%），故宁可不记；上一条未结算的命令仍按 `aborted' 收尾。
- 否则记录起点、命令名与 GC 差值基线。

关于 `aborted' 的准确口径：`C-g' 通常**仍会**触发 `post-command-hook'（quit 在命令
循环里被捕获后照常跑 hook），这类命令会正常结算为 `ok'/`error'，其 duration 含卡顿
时间 —— 正是目标 #1 要看的数据，不是异常。真正记 `aborted' 的只有
`post-command-hook' 被彻底跳过的顶层中断（`throw' 到顶层、`top-level' 重启、
在 hook 自身或深层原生代码里跳出命令循环），此时这条命令无从结算，只能按已耗时间记
`aborted'。

**不跳过 M-x 中间态**（实测结论，见 Commentary）：`execute-extended-command' 内部的
`command-execute' 不走 pre/post hook，故 M-x 全程只有这一次计时机会。若在这里跳过，
经 M-x 触发的命令将彻底不被采集，且 `post-command-hook' 阶段补不回来（那时读到的
`this-command' 已是上一条命令）。要让这类记录归到实际命令，需另行 advice
`execute-extended-command'。

**防御性去重**（D1 第二层防护）：本函数可能被同一个 buffer 的「局部 hook 值 + 全局
默认值」在同一条命令上调用两次（局部值末尾带 `t' 的语义）。此时第二次调用看到的
`--pending-p' 为真、命令名与本条命令相同、且起点就在 1 毫秒以内 —— 判为重复触发，
直接返回，既不结算（否则白记一条 0ms 的 `aborted'）也不重置计时。正常路径由
`el-chronos-collect--ensure-buffer-hooks' 的补挂判据挡住，本判据只兜底局部值在运行期
被别人改成带 `t' 的情形。
命名比较口径：`--command-name' 存的是**字符串**（落库口径），而 `this-command' 是符号，
故判等用「把命令名归一后 `equal'」而不是 `eq'（符号与字符串 `eq' 恒为 nil，
那样判据永远不成立，等于没有防护）。

**命令开始前补判一次心跳**（`el-chronos-collect--heartbeat-check'，位置见注释）：
结清「命令外时间」，补上「timer 被饿死跑不了、而 `--finish' 的重置又会把整段吞掉」
的那一段 —— 卡顿结束后立刻按键是最常见的用户行为，只靠 timer + `--finish' 会稳定漏检。"
  (let ((name (el-chronos-collect--command-label)))
    ;; D1 兜底：同一命令被同一 hook 双跑时不结算、不重置（见 docstring）
    (unless (and el-chronos-collect--pending-p
                 (equal name el-chronos-collect--command-name)
                 (numberp el-chronos-collect--command-start)
                 (< (- (float-time) el-chronos-collect--command-start) 0.001))
      (when el-chronos-collect--pending-p
        (el-chronos-collect--finish 'aborted))
      ;; 命令开始前补判一次「命令外停转」（ADR-0005 D4a）。**位置不可移动**：
      ;; ① 必须在上面 `(--finish 'aborted)' 之后 —— 否则 `--pending-p' 仍为 t，
      ;;    兜底门会跳过判定，补判等于白跑；先结算再补判，gap 才是「上一条命令结束 →
      ;;    这一条开始」的命令外间隙。aborted 结算自身的开销（µs–ms 级）会计入该次
      ;;    gap，**明确接受**（远低于 drift 阈值，且只在 C-g / 异常中断路径发生）。
      ;; ② 必须在下面的 `--command-start' 赋值之前 —— 它度量的是「命令开始**之前**」的
      ;;    时间，放在赋值之后语义就变成「命令开始后又判了一次心跳」。
      ;; ③ 在 D1 双跑守卫（上面的 `unless'）之外：守卫命中说明没有真实间隙，
      ;;    保持「每条真实命令开始时都结清一次」的简单不变式。
      ;; 外层 `ignore-errors' 是双保险：check 内部已有 `condition-case'（I6），
      ;; 但这里是 `pre-command-hook' 的历史上第一个判定调用点，异常逃出去会中断用户
      ;; 正在执行的命令。
      (ignore-errors (el-chronos-collect--heartbeat-check))
      (if (null name)
          ;; 命令名取不到：清状态、不开始计时（不产生无主行）
          (setq el-chronos-collect--command-start nil
                el-chronos-collect--command-name nil
                el-chronos-collect--command-gc-done nil
                el-chronos-collect--command-gc-elapsed nil
                el-chronos-collect--errored-p nil
                el-chronos-collect--pending-p nil)
        (setq el-chronos-collect--command-start (float-time)
              el-chronos-collect--command-name name
              el-chronos-collect--command-gc-done gcs-done
              el-chronos-collect--command-gc-elapsed gc-elapsed
              el-chronos-collect--errored-p nil
              el-chronos-collect--pending-p t)))))

(defun el-chronos-collect--post-command ()
  "命令结束结算：pending 时按 `el-chronos-collect--errored-p' 记 `ok' 或 `error'。"
  (when el-chronos-collect--pending-p
    (el-chronos-collect--finish (if el-chronos-collect--errored-p 'error 'ok))))

(defun el-chronos-collect--finish (outcome)
  "结算当前命令。OUTCOME 取 `ok' / `error' / `aborted'。
写四处：命令事件、用法统计（command / mode / project 三维，粒度设为 `file' 时再加一维
被操作文件路径）、超阈值的慢事件（context 里可能带 `:file'）。
每步都经 `el-chronos-collect--safe-apply'，失败只限流告警，绝不中断命令循环（I6）。

命令名一律用 `--pre-command' 存下的 `--command-name'，**结算时不重新读命令名**：
实测 `post-command-hook' 时刻的 `this-command' / `real-this-command' 已是**上一条**
命令（命令循环在 post 之后才把它们滚进 `last-command'），此刻回读会把上一条命令的名字
安到本条上。`--command-name' 为 nil（无主命令）时整条不落库，也不记 `anonymous' ——
理由同 `el-chronos-collect--pre-command'：无主行会污染 top-N 与中断率分母，而正常路径
下 `--command-name' 与 `--command-start' 同时设置，不会出现该状态。

结算一开始先做一次**纯基线重置**（`(setq el-chronos-collect--last-heartbeat
(float-time))'）：把命令执行时间从心跳 gap 中切掉，使 block / drift 两档只覆盖
「命令外停转」（ADR-0005 D4 / D7）。`--pending-p' 兜底门只是补充，**不是主判据**。
此处**不得**调 `el-chronos-collect--heartbeat-check' —— 那会让 gap 恰等于刚执行完的
命令时长，命令时长被记成 block / drift，双记立刻复活。

命令型慢事件的 `stack_json` 恒为 NULL：栈只能在结算路径（`--post-command'）里取，
此时被观测命令的帧已弹出，栈顶必然是采集器自身
（`--post-command' → `--finish' → `--safe-apply' → `--current-stack'
 → `backtrace-frames'），记录它只会误导分析（真实排查中曾据此误判）。
命令归属请查 `hourly_stacks' 同时段样本。
与 `kind='block'` 的既有口径一致（TD-2 已定：block 的 stack_json 恒 NULL）。"
  (let ((start el-chronos-collect--command-start)
        (name el-chronos-collect--command-name)
        (gc-start el-chronos-collect--command-gc-elapsed))
    ;; 心跳基线重置（**纯 `setq'，此处绝不能调 `--heartbeat-check'**）：把命令执行时间
    ;; 从 gap 里切掉，使 block / drift 只覆盖「命令外停转」；`--pending-p' 兜底门只是
    ;; 补充，不是主判据 —— 主判据就是这一行。若在此调 check，gap 恰好等于刚执行完的
    ;; 命令时长 → 命令时长会被记成 block / drift，双记立刻复活（ADR-0005 D4 唯一硬禁令）。
    ;; 位置三条理由：① 紧贴命令真实结束时刻（越往后放，结算自身的归因 / 取栈 / 写库开销
    ;; 越会被悄悄切到基线之外）；② 早于下面的状态清空 —— 结算过程中若心跳被触发，
    ;; `--pending-p' 仍为 t，兜底门会跳过判定，而基线已是 now，不会把结算耗时算成 gap；
    ;; ③ 在下面的 `(when (and (numberp start) name) …)' 之外，故 `aborted' 与无主命令
    ;; 路径同样重置基线（否则 aborted 会把「上一条命令 + 命令间隙」整段留给下一次心跳）。
    (setq el-chronos-collect--last-heartbeat (float-time))
    ;; 先清状态再干活：即使下面的记录失败（已被吞掉），也不会留下粘住的 pending
    (setq el-chronos-collect--pending-p nil
          el-chronos-collect--command-start nil
          el-chronos-collect--command-name nil
          el-chronos-collect--command-gc-done nil
          el-chronos-collect--command-gc-elapsed nil
          el-chronos-collect--errored-p nil)
    (when (and (numberp start) name)
      (let* ((duration-ms (* 1000 (- (float-time) start)))
             ;; 极端情况下 gc-elapsed 被重置，差值会为负，按 0 处理
             (gc-ms (when (numberp gc-start)
                      (max 0 (* 1000 (- gc-elapsed gc-start)))))
             (hour-ts (el-chronos-collect--hour-ts))
             (context (or (el-chronos-collect--safe-funcall #'el-chronos-attrib-context)
                          (list :mode nil :project nil)))
             (mode (plist-get context :mode))
             (project (plist-get context :project)))
        (el-chronos-collect--safe-apply
         #'el-chronos-store-record-command
         (list (list :name name :duration-ms duration-ms :gc-ms gc-ms
                     :mode mode :project project
                     :outcome (symbol-name outcome) :kind "interactive")))
        (el-chronos-collect--safe-apply #'el-chronos-store-record-usage
                                       (list hour-ts 'command name 1 duration-ms))
        (when mode
          (el-chronos-collect--safe-apply #'el-chronos-store-record-usage
                                         (list hour-ts 'mode mode 1 duration-ms)))
        (when project
          (el-chronos-collect--safe-apply #'el-chronos-store-record-usage
                                         (list hour-ts 'project project 1 duration-ms)))
        ;; 文件维度用法：仅在 `el-chronos-usage-granularity' 为 `file' 且当前 buffer
        ;; 关联文件时记录。默认 `command' 粒度下这一行永远不会执行，即不记任何路径（I7）。
        ;; 取的是结算时刻的 `buffer-file-name'（与 context 的 `:file' 同源）；`aborted'
        ;; 在 `pre-command-hook' 里结算时当前 buffer 可能已是下一条命令的 buffer，
        ;; 此时文件归属按「当前 buffer」记，属于与 `:file' 相同的已知近似。
        (when (eq (bound-and-true-p el-chronos-usage-granularity) 'file)
          (when-let* ((file (buffer-file-name)))
            (el-chronos-collect--safe-apply #'el-chronos-store-record-usage
                                           (list hour-ts 'file file 1 duration-ms))))
        (when (>= duration-ms el-chronos-slow-command-threshold-ms)
          ;; `stack_json' 恒为 NULL（**有意为之，不是缺失**）：栈只能在结算路径里取，
          ;; 此时被观测命令的帧已弹出，栈顶必然是采集器自身，记录它只会误导分析
          ;; （真实排查中曾据此误判「慢在某条命令内」）。详见 `--finish' docstring。
          (el-chronos-collect--safe-apply
           #'el-chronos-store-record-slow-event
           (list (list :duration-ms duration-ms :kind "command" :command name
                       :stack nil
                       :context context)))))))
  nil)

;;; T5b 心跳阻塞

(defun el-chronos-collect--heartbeat-check (&optional now)
  "结算一次「命令外停转」判定，并推进心跳基线。
NOW 默认取 `(float-time)'，仅供测试注入确定性时刻（避免依赖 timer 真实相位）。

三处调用点，职责各不相同 —— **不许「统一一下」**（见 ADR-0005 D4）：
1. 心跳 timer（`el-chronos-collect--heartbeat'，每
   `el-chronos-heartbeat-seconds' 秒）→ 判定 + 重置：覆盖「两条命令之间迟迟没有
   下一条命令」的停转（此时没有 `pre-command-hook' 可挂钩）；
2. `el-chronos-collect--pre-command'（每条命令开始前）→ 补判 + 重置：在开始新命令计时
   之前结清「命令外时间」，补上「timer 被饿死、而 `--finish' 的重置又会把整段吞掉」
   的漏检（卡顿结束立刻按键是最常见的用户行为）；
3. `el-chronos-collect--finish'（命令结算）→ **只重置基线，绝不调用本函数**：那里的
   gap 恰好是刚执行完的命令时长，判定会把命令时长记成 block / drift，双记立刻复活。

判定链（两个门，block 与 drift **共用**，任何「只给一档加门」的写法都会造出可被静默
污染的档位，见 ADR-0005 D1 / D6）：
- 先**无条件**推进基线 `(setq --last-heartbeat now)' —— 抑制期间与兜底门跳过判定时同样
  推进，否则解除抑制后会把整段抑制耗时算成一次 gap；
- **抑制门**：`el-chronos-collect--suppress-block-p' 非 nil（报告 / Web 自观测抑制）→
  只推进基线、不判定；
- **兜底门**：`el-chronos-collect--pending-p' 非 nil（命令中途让出主线程时心跳真的跑了
  起来，此后命令内若再停转，gap 会跨过命令边界）→ 跳过判定、只推进基线。
  它是**兜底而非主判据**：主判据是 `--finish' 的重置（命令时间根本不进 gap）；
- 门内按 gap（毫秒）分档：> `el-chronos-block-threshold-ms' → 记
  `slow_events(kind=\"block\")' 明细（`:command' 恒 nil：它只记命令外停转，回填上一条
  命令名会把「命令外停转」误导成「某条命令内的停转」）；否则 >
  `el-chronos-drift-threshold-ms' → 累加到 `hourly_drift' 小时桶（不写明细）；
  都不满足 → 什么都不做。

`condition-case' **必须留在本函数内部**（I6）：`el-chronos-collect--pre-command' 自身
没有 `condition-case'，异常若从这里逃出去会经 `pre-command-hook' 抛进命令循环，
**直接中断用户正在执行的命令**，比丢一条数据严重一个量级。"
  (condition-case err
      (let* ((now (or now (float-time)))
             (last el-chronos-collect--last-heartbeat))
        ;; 基线推进在两道门之外（无条件）：抑制 / 兜底跳过判定时也必须推进
        (setq el-chronos-collect--last-heartbeat now)
        (unless (bound-and-true-p el-chronos-collect--suppress-block-p)
          (unless el-chronos-collect--pending-p
            (when-let* ((gap-ms (and (numberp last) (* 1000 (- now last)))))
              (cond
               ((> gap-ms el-chronos-block-threshold-ms)
                (let ((context (or (el-chronos-collect--safe-funcall
                                    #'el-chronos-attrib-context)
                                   (list :mode nil :project nil))))
                  (el-chronos-collect--safe-apply
                   #'el-chronos-store-record-slow-event
                   (list (list :duration-ms gap-ms :kind "block" :command nil
                               :stack nil :context context)))
                  ;; 提示开关只管「提示」这一层：上面已落库，三种取值都不影响记录。
                  ;; `messages' 用 `inhibit-message' 只写 `*Messages*'，不占 echo area。
                  (when-let* ((notify el-chronos-collect-notify-blocks))
                    (let ((inhibit-message (eq notify 'messages)))
                      (message "el-chronos：主线程阻塞约 %.0f ms（已记录）" gap-ms)))))
               ((> gap-ms el-chronos-drift-threshold-ms)
                ;; 亚秒级只进小时桶：不写 slow_events（ADR-0005 D2），也不发提示
                (el-chronos-collect--safe-apply
                 #'el-chronos-store-record-drift
                 (list (el-chronos-collect--hour-ts) gap-ms))))))))
    (error (el-chronos-collect--warn "心跳检测失败：%S" err)))
  nil)

(defun el-chronos-collect--heartbeat ()
  "心跳 timer 回调：薄壳，只做一次 `el-chronos-collect--heartbeat-check'。
心跳迟到说明主线程在两次触发之间被占住（原生代码、未分批 IO、长 timer 回调）；
阻塞期间无可靠 Lisp 回调，只能事后按时间差反推（I2）。

判定链、两道门与三处调用点的分工全部见 `el-chronos-collect--heartbeat-check'；
本函数只保留 timer 入口这一层（异常保护也在 check 内部，不在此处）。"
  (el-chronos-collect--heartbeat-check))

;;; T5c 采样窗口聚合

(defun el-chronos-collect--start-sampling ()
  "启动内置 C profiler 采样。失败只告警并置 `el-chronos-collect--sampling-p' 为 nil，
命令计时与心跳检测继续工作（错误处理矩阵：profiler 启动失败 → 禁用采样）。"
  (condition-case err
      (progn
        (profiler-cpu-start el-chronos-sampling-interval-ns)
        (setq el-chronos-collect--sampling-p t))
    (error
     (setq el-chronos-collect--sampling-p nil)
     (el-chronos-collect--warn
      "启动内置 CPU profiler 失败，已禁用采样（命令与心跳采集继续）：%S" err)
     nil)))

(defun el-chronos-collect--accumulate-self (function count)
  "给 FUNCTION 的格子同时累加 SELF 与 SAMPLES 计数 COUNT（leaf 口径，不动 TOTAL）。
二者同源：SELF 是「该函数作为 leaf 被采样的次数」，SAMPLES 是同一数字的整数留档。
落库时 SELF 乘采样间隔换算成毫秒（I4），SAMPLES 原样保留，故
`self_ms = samples × 采样间隔' 恒成立；`el-chronos-analysis-overview' 的 `:samples'
因此等于窗口内真实样本总数（可作占比分母、回归抗噪判据）。"
  (let ((cell (gethash function el-chronos-collect--window-self)))
    (if cell
        (progn
          (aset cell 0 (+ (aref cell 0) count))
          (aset cell 2 (+ (aref cell 2) count)))
      (puthash function (vector count 0 count) el-chronos-collect--window-self))))

(defun el-chronos-collect--accumulate-appearance (function count)
  "给 FUNCTION 的格子累加「出现次数」COUNT（**只**动 TOTAL，不动 self/samples）。
TOTAL 表示「该函数在某条栈里出现过」的样本数（含作为中间帧 / 根帧出现），落库时
换算成毫秒。SAMPLES 归 leaf 口径（见 `el-chronos-collect--accumulate-self'），此处
**不得**再动它 —— 否则中间帧的 samples 会虚高，连带让概览样本数偏大、top-functions
的 pct 分母失真、回归判定被「出现多但 self 不耗时」的函数击穿。"
  (let ((cell (gethash function el-chronos-collect--window-self)))
    (if cell
        (aset cell 1 (+ (aref cell 1) count))
      (puthash function (vector 0 count 0) el-chronos-collect--window-self))))

(defun el-chronos-collect--trim-trailing-nils (items)
  "去掉向量 ITEMS 尾部的 nil，返回新向量（不改原向量）。
profiler 的栈向量尾部是 nil 填充（实测形如
`[1+ setq let … normal-top-level nil nil nil]'）：这些空槽既不是函数也没有调用信息。
原样归一成 \"unknown\" 写进 `hourly_stacks' 后，火焰图与调用链视图会被无意义占位填满，
`unknown' 也会看起来像热点函数。
只裁尾部：中间位置若出现 nil（正常不该有）仍保留为 \"unknown\" 占位，
避免压缩栈结构误导读者。"
  (let ((end (length items)))
    (while (and (> end 0) (null (aref items (1- end))))
      (setq end (1- end)))
    (if (= end (length items)) items (substring items 0 end))))

(defun el-chronos-collect--accumulate-entry (stack count)
  "把一条采样（STACK 向量 + COUNT 样本）累计到本窗口的两个聚合表。
STACK 的第 0 个元素是 leaf（实测结论见文件头），口径见文件头 2b：
  - leaf 同时加 SELF 与 SAMPLES 计数（leaf 口径，二者同源、落库形态不同）；
  - 栈中每个**不同**函数各加一次 TOTAL，同一函数在一条栈里出现多次（递归帧）
    只算一次，避免 total 被重复帧放大；TOTAL 不碰 SAMPLES。
nil 帧（profiler 的尾部填充与未解析帧）**不计入** self / total：
`(symbolp nil)' 为 t，必须用 `(and X (symbolp X))' 排除，否则会造出一个
伪函数 \"unknown\"。
栈序列化前先 `el-chronos-collect--trim-trailing-nils' 去尾；全 nil 栈不写
`hourly_stacks'。
单条栈只遍历一遍：栈内去重用 `memq'，代价 O(栈长²)（实测栈长 ≤ 40 帧，可忽略），
且只在窗口 tick 上发生，不落在命令热路径里。"
  (when (and (vectorp stack) (> (length stack) 0) (numberp count) (> count 0))
    ;; 1) self / samples：只认栈顶帧（leaf），与内置 profiler 报告的自时间归属一致
    (let ((leaf (aref stack 0)))
      (when (and leaf (symbolp leaf))
        (el-chronos-collect--accumulate-self leaf count)))
    ;; 2) total：栈内去重后每个出现过的函数各记一次（不动 samples）
    (let ((seen nil)
          (length (length stack)))
      (dotimes (index length)
        (let ((function (aref stack index)))
          (when (and function (symbolp function) (not (memq function seen)))
            (push function seen)
            (el-chronos-collect--accumulate-appearance function count)))))
    ;; 栈本身按 JSON 字符串聚合并累加样本数（完整调用链的唯一来源）
    ;; 先裁掉尾部 nil 填充再归一；全 nil 栈归一后是空向量，直接跳过不写库。
    ;; 帧名统一经 `el-chronos-collect--frame-name' 归一：nil → "unknown"、非符号对象
    ;; （闭包 / 字节码 / 其他）→ "anonymous"。归一后的名字同时充当 hash key，故同一
    ;; 闭包对象不会因 `format' 输出差异被拆成两条栈。
    (let* ((trimmed (el-chronos-collect--trim-trailing-nils stack))
           (names (vconcat (mapcar #'el-chronos-collect--frame-name (append trimmed nil))))
           (json (and (> (length names) 0)
                      (condition-case nil (json-serialize names) (error nil)))))
      (when json
        (puthash json (+ count (gethash json el-chronos-collect--window-stacks 0))
                 el-chronos-collect--window-stacks))))
  nil)

(defun el-chronos-collect--accumulate (log)
  "把 profiler 日志 LOG 累计到窗口聚合表。
LOG 实测为 hash table（栈 vector → 样本数），同时兼容 (栈 . 样本数) 的情列表。"
  (cond
   ((hash-table-p log) (maphash #'el-chronos-collect--accumulate-entry log))
   ((listp log)
    (dolist (entry log)
      (when (consp entry)
        (el-chronos-collect--accumulate-entry (car entry) (cdr entry))))))
  nil)

(defun el-chronos-collect--flush-window ()
  "把本窗口的函数聚合与栈聚合交给 store 层，然后清空窗口。
store 侧再按键（小时 + 会话 + 名字）累加，写库由 store 的 flush timer 批量完成。
落库三列口径（见文件头 2b）：`self_ms' / `total_ms' 是「样本数 × 采样间隔」（I4），
`samples' 是 leaf 口径的原始整数计数（**不乘**间隔），故
`(round (/ self_ms interval-ms)) = samples' 恒成立。"
  (let ((hour-ts (el-chronos-collect--hour-ts))
        (interval-ms (el-chronos-collect--interval-ms)))
    (when (> (hash-table-count el-chronos-collect--window-self) 0)
      (maphash
       (lambda (function cell)
         (let ((self-count (aref cell 0))
               (total-count (aref cell 1))
               (samples (aref cell 2)))
           (el-chronos-collect--safe-apply
            #'el-chronos-store-record-function-samples
            (list hour-ts
                  ;; 函数名同样走 `el-chronos-collect--frame-name'，与栈序列化同口径
                  (el-chronos-collect--frame-name function)
                  (el-chronos-collect--safe-apply
                   #'el-chronos-attrib-file (list function))
                  (el-chronos-collect--safe-apply
                   #'el-chronos-attrib-package (list function))
                  ;; 三列口径不同，不能互相推导：
                  ;;   self-ms  = leaf 样本数 × 间隔（该函数自己耗的时间）
                  ;;   total-ms = 出现在任一栈中的样本数 × 间隔（含作为中间帧）
                  ;;   samples  = leaf 样本数，原值不乘间隔
                  ;; 故 total-ms ≥ self-ms，且 self-ms 与 samples 一一对应。
                  (* self-count interval-ms)
                  (* total-count interval-ms)
                  samples))))
       el-chronos-collect--window-self))
    (when (> (hash-table-count el-chronos-collect--window-stacks) 0)
      ;; 上报窗口内最热的一批栈：max(20, top-n / 10)，其余交给 store 侧合并淘汰
      (let ((limit (max 20 (/ el-chronos-store-stack-top-n 10)))
            (entries nil))
        (maphash (lambda (json samples) (push (cons json samples) entries))
                 el-chronos-collect--window-stacks)
        (setq entries (cl-subseq (sort entries (lambda (a b) (> (cdr a) (cdr b))))
                                 0 (min limit (length entries))))
        (el-chronos-collect--safe-apply
         #'el-chronos-store-record-stacks (list hour-ts entries))))
    (clrhash el-chronos-collect--window-self)
    (clrhash el-chronos-collect--window-stacks))
  nil)

(defun el-chronos-collect--heap-bytes ()
  "返回当前 Emacs 堆的在用字节数；`garbage-collect-heapsize' 不可用时返回 nil。
只读取值，**不触发 GC**：官方 docstring 说它「可能不是完全最新，除非紧跟一次完整 GC
之后调用」，即成本可忽略（`garbage-collect` 才是会真做一次 GC 的那个）。
Emacs 31.1 之前没有该函数 → `fboundp' 守卫返回 nil，调用方给 store 传 nil，
`hourly_gc.heap_bytes' 保持 NULL（分析层返回 nil 序列，I6 降级不报错）。
汇总口径：`Σ SIZE × USED`（USED 为堆中存活对象数，SIZE 为每个对象的字节数）。"
  (condition-case err
      (when (fboundp 'garbage-collect-heapsize)
        (let ((info (garbage-collect-heapsize)))
          (when (consp info)
            (cl-loop for entry in info
                     for size = (nth 1 entry)
                     for used = (nth 2 entry)
                     when (and (numberp size) (numberp used))
                     sum (* size used)))))
    (error (el-chronos-collect--warn "读取堆大小失败：%S" err) nil)))

(defun el-chronos-collect--collect-gc ()
  "采集本窗口的 GC 次数 / 耗时与（稀疏的）堆大小，交给 store 累加到小时桶。
与 profiler 采样**互不依赖**：`gcs-done' / `gc-elapsed' / `garbage-collect-heapsize'
都只读 Emacs 自维护的计数器，不需要 profiler。因此调用点在
`--sample-tick' 的 `(when el-chronos-collect--sampling-p ...)' **之外** ——
若绑在里面，profiler 启动失败时按错误矩阵只「禁用采样、命令/心跳继续」，
GC 与内存趋势会跟着陪葬，而它恰恰是判断「是不是越用越胖」的唯一依据。

首窗口（基线为 nil）只初始化基线、增量为 0：`gcs-done' / `gc-elapsed' 是启动至今的
累计值，直接当增量会把开机以来的 GC 全算进一个窗口。
`gc-elapsed' 可被重置，差值取负时按 0（沿用 `--finish' 的既有防御）。
堆大小每 `el-chronos-heap-sample-windows' 个窗口采一次，其余窗口传 nil
（store 侧 `heap_bytes' 用 COALESCE 保住上一次观测值）。
自身 `condition-case'：失败只限流告警，不向宿主抛错（I6）。"
  (condition-case err
      (let* ((done gcs-done)
             (elapsed gc-elapsed)
             (baseline el-chronos-collect--gc-baseline)
             (count 0)
             (gc-ms 0.0))
        (when (consp baseline)
          ;; 两个计数器都单调递增（除非被重置），负值说明被重置过 → 按 0
          (setq count (max 0 (- done (car baseline)))
                gc-ms (max 0.0 (* 1000 (- elapsed (cdr baseline))))))
        (setq el-chronos-collect--heap-tick-counter
              (1+ el-chronos-collect--heap-tick-counter))
        (let* ((windows (max 1 (or el-chronos-heap-sample-windows 1)))
               (heap-bytes
                (when (>= el-chronos-collect--heap-tick-counter windows)
                  (setq el-chronos-collect--heap-tick-counter 0)
                  (el-chronos-collect--heap-bytes))))
          (el-chronos-collect--safe-apply
           #'el-chronos-store-record-gc
           ;; hour-ts 与 `--flush-window' / `--finish' 用同一个 `--hour-ts'（整点毫秒，
           ;; epoch 基准），store 只把它当主键的一部分，不再做时区 / 对齐转换。
           (list (el-chronos-collect--hour-ts) count gc-ms heap-bytes)))
        (setq el-chronos-collect--gc-baseline (cons done elapsed)))
    (error (el-chronos-collect--warn "GC 采集失败：%S" err)))
  nil)

(defun el-chronos-collect--collect-resources ()
  "采集本窗口的 Emacs 进程资源（CPU / RSS / 线程数）与系统负载，交给 store 累加。
与 profiler 采样**互不依赖**，调用点与 `--collect-gc' 并列、同在其
`(when el-chronos-collect--sampling-p ...)' **之外**：profiler 启动失败时按错误矩阵只
「禁用采样、命令/心跳继续」，资源趋势不该跟着陪葬。

取数只用两个内置函数，零副作用、只查自己：
- `(process-attributes (emacs-pid))' 取本进程的 `time'（累计 CPU 时间）、`rss'（KB）、
  `thcount'（线程数）—— **只查自己**，绝不遍历全系统进程；
- `(load-average t)' 取系统负载 1 / 5 / 15。
**不采系统内存**：`memory-info' 给的是系统级内存，且 `default-directory' 为 remote 时
查的是远端主机（TD-15），与「Emacs 进程自己占多少」不是一回事。

`cpu_ms' = 本窗口 CPU 时间增量（毫秒）、`wall_ms' = 本窗口墙钟增量（毫秒），两者之比
即 CPU 占用率；都由 `--resource-baseline' 差分得到，不读任何百分比接口。
首个窗口（基线为 nil）**只建基线不写库**，与 `--collect-gc' 同一口径：`time' 是启动至今
的累计值，直接当增量会把开机以来的 CPU 全算进一个窗口。

TRAMP 守卫（**必须**）：整段取数包在 `(let ((default-directory temporary-file-directory))
...)` 里。`process-attributes' 的 docstring 明确「`default-directory' 指向远端时 PID 被
当作**远端主机**上的进程」，而 `--sample-tick' 的 timer 捕获的是创建时的
`default-directory' —— 用户在 TRAMP buffer 里启用模式就会把它带进来，不守就会去查远端
同号进程（取到的是别人的数）或卡在 TRAMP 上。

逐字段判空：任一项取不到（平台不支持 / 读失败）时该字段传 nil = 「本窗口没采到」，
由 store 落 NULL 并用 COALESCE 保住上一次观测值 —— **绝不用 0 冒充**（0 会把峰值与
均值拉偏）。`load-average' 可能抛错（部分平台未实现）→ 吞掉，本窗口三个负载字段不参与。

**上一条有且只有一处例外：`cpu_ms' / `wall_ms' 是 `NOT NULL' 列。** `time' 字段缺失
（`process-attributes' 的 alist 里没有 `time'，或本窗口 CPU 差分为 nil）时 CPU 时间传 nil，
落库被列约束兜成 **0**，于是 `cpu_pct = 0.0` —— 这个 0 必须读作「**本窗口未采集到 CPU
时间**」，**不是「CPU 空闲」**。同一行的 RSS / 线程 / 负载可能照常有值，所以「这一小时
有资源行」并不等于「CPU 一定采到了」。要彻底区分只能让这两列可空（或加 `cpu_n' 采样
计数），属 schema v5 范畴（TD-28）；在此之前读 `cpu_pct = 0' 时先看该桶的 `samples' 与
RSS 是否有值，不要直接当成空闲。

自身 `condition-case'：失败只限流告警，不向宿主抛错（I6），也不终止 timer。"
  (condition-case err
      (when el-chronos-resource-sampling
        (let ((default-directory temporary-file-directory))
          (let* ((now-float (float-time))
                 (attrs (process-attributes (emacs-pid)))
                 (cpu-time (let ((value (cdr (assq 'time attrs))))
                             (and (consp value) value)))
                 (rss (let ((value (cdr (assq 'rss attrs))))
                        (and (numberp value) value)))
                 (threads (let ((value (cdr (assq 'thcount attrs))))
                            (and (numberp value) value)))
                 (loads (condition-case nil
                            (load-average t)
                          (error nil)))
                 (baseline el-chronos-collect--resource-baseline))
            (if (not (consp baseline))
                ;; 首窗口：只建基线，不写库（见 docstring）
                (setq el-chronos-collect--resource-baseline
                      (cons cpu-time now-float))
              (let* ((previous-cpu (car baseline))
                     (previous-float (cdr baseline))
                     (cpu-ms (when (and cpu-time (consp previous-cpu))
                               (max 0.0 (* 1000.0
                                           (float-time
                                            (time-subtract cpu-time
                                                           previous-cpu))))))
                     (wall-ms (when (numberp previous-float)
                                (max 0.0 (* 1000.0
                                            (- now-float previous-float))))))
                (el-chronos-collect--safe-apply
                 #'el-chronos-store-record-resources
                 ;; hour-ts 与 `--flush-window' / `--collect-gc' 同口径（整点毫秒）；
                 ;; rss 的峰值与总和各传一次同值（单点采样，峰值即当年值、总和逐窗口累加）。
                 (list (el-chronos-collect--hour-ts)
                       (list :cpu-ms cpu-ms :wall-ms wall-ms
                             :rss-kb-max rss :rss-kb-sum rss
                             :threads-max threads
                             :load1-sum (nth 0 loads)
                             :load5-sum (nth 1 loads)
                             :load15-sum (nth 2 loads))))
                (setq el-chronos-collect--resource-baseline
                      (cons cpu-time now-float)))
            t))))
    (error (el-chronos-collect--warn "进程资源采集失败：%S" err)))
  nil)

(defun el-chronos-collect--check-sample-window (&optional now)
  "检查相邻两次采样 tick 之间是否丢了整窗，丢了就把 `sample-misses' 记进自监控。
NOW 为本次 tick 的时刻（`float-time'，默认现取）。基线取 `--last-sample-tick'，
比较后**无条件推进**基线 —— 无论是否判定丢失，下一次比较都从本次开始。
判据：间隔 > 2 × `el-chronos-sample-window-seconds'。
为什么是 2 倍而不是 1 倍：timer 调度本身有抖动，正常间隔会在应有时长附近浮动
（系统繁忙时多跑几十毫秒很常见），用 1 倍会把每次正常抖动都记成「丢了窗口」。
2 倍意味着「至少整整一个窗口没跑」，是保守且不假阳性的下界。
首个 tick（基线为 nil）只建立基线、不计 miss。
为什么需要这个计数：`--sample-tick' 由 timer 驱动，主线程被长任务占住期间 timer 不触发，
那段时间**完全没有采样数据**；库里看不出「这里是空窗」还是「这里真的没跑代码」。
`sample-misses' 就是「我的数据有洞」的自证信号（落 `hourly_health'）。
基线**不复用** `--last-heartbeat'：两条 timer 周期不同（心跳 0.25s / 采样 10s），
共用会互相推进对方的基线，两边的判定同时失真。
自身不抛错（`--safe-apply' 兜底，I6）：采样主流程不得因自监控失败而中断。"
  (let* ((now (or now (float-time)))
         (last el-chronos-collect--last-sample-tick)
         (window (max 1 (or el-chronos-sample-window-seconds 10)))
         (missed nil))
    (setq el-chronos-collect--last-sample-tick now)
    (when (and last (> (- now last) (* 2 window)))
      (setq missed t)
      (el-chronos-collect--safe-apply
       #'el-chronos-store-record-health
       (list (el-chronos-collect--hour-ts) "sample-misses" 1)))
    missed))

(defun el-chronos-collect--sample-tick ()
  "采样窗口到期：取走 profiler 日志 → 累加 → 落库 → 清空窗口。
`profiler-cpu-log' 取用即重置，本函数因此是采样数据的唯一出口（Emacs 单线程 timer
保证不会重入）。自身 `condition-case'：任何异常都不得终止 timer（I6）。

GC / 堆采集在 `(when el-chronos-collect--sampling-p ...)' **之外**调用，与 profiler
采样互不依赖：`gcs-done' / `gc-elapsed' / `garbage-collect-heapsize' 都不需要 profiler。
若绑在 `sampling-p' 内，profiler 启动失败时（错误矩阵：禁用采样，命令/心跳继续）
GC 与内存趋势会一起陪葬，而它正是「是不是越用越胖」的唯一依据。
进程资源采集（`--collect-resources'）与它并列、同样在 `sampling-p' 之外，理由相同：
`process-attributes' / `load-average' 都只读 OS 侧数值，与 profiler 无关。

入口第一件事是 `--check-sample-window'：判定「上一个窗口是否整窗丢失」（主线程被占住期间
timer 不触发，那段时间没有任何采样数据），丢则把 `sample-misses' 记进 `hourly_health'。
它与 profiler、GC 都无关，故同样放在 `sampling-p' 之外。

GC 归因缓冲（`--gc-attrib-buffer'，由 `post-gc-hook' 在内存里累积）也在这里交给 store
（`--flush-gc-attrib'）：归因的采集点是全局 hook，与 profiler 毫无关系，故同样在
`sampling-p' 之外。**不新开 timer** —— 复用本窗口的 10 秒节奏，归因粒度天然是「一个
采样窗口聚合一次」。"
  (condition-case err
      (progn
        ;; 先判定「上一个窗口是否整窗丢失」（自监控，与 profiler / GC 都无关）
        (el-chronos-collect--check-sample-window)
        ;; 再采 GC/堆：不依赖 profiler，且 profiler 路径即便异常也不该吞掉它
        (el-chronos-collect--collect-gc)
        ;; 进程资源（CPU / RSS / 线程 / 负载）：同样不依赖 profiler，理由同上
        (el-chronos-collect--collect-resources)
        ;; GC 归因（`post-gc-hook' 累积的内存缓冲）：同样不依赖 profiler —— hook 是否被
        ;; 触发与 profiler 无关，绑在 `sampling-p' 内会让 profiler 失败时归因永远不落库
        (el-chronos-collect--flush-gc-attrib)
        (when el-chronos-collect--sampling-p
          (el-chronos-collect--accumulate (profiler-cpu-log))
          (el-chronos-collect--flush-window)))
    (error
     ;; 异常时也要清空窗口，避免脏数据滚进下一个窗口
     (ignore-errors (clrhash el-chronos-collect--window-self))
     (ignore-errors (clrhash el-chronos-collect--window-stacks))
     (ignore-errors (clrhash el-chronos-collect--gc-attrib-buffer))
     (el-chronos-collect--warn "采样窗口聚合失败：%S" err)))
  nil)

;;; GC 归因（post-gc-hook）

(defun el-chronos-collect--post-gc ()
  "记录本次 GC 的归因（`post-gc-hook'）。
**分配约束（硬）**：本函数体内禁止字符串类分配 —— 不得出现 `format' / `concat' /
`number-to-string' / `symbol-name' / `prin1-to-string'。原因：`post-gc-hook' 在 GC
之后立即运行，此时堆刚清空，任何分配都会直接计入下一次 GC 的阈值，形成自我加速。
`gc_ms' 的差值计算不可避免会产生一个 float，这是本函数唯一的分配（每次 GC ≤1 个），
已在测试中以「允许 float、禁止字符串」的口径锁定。

首次调用只建立基线、不记录 —— 否则会把「启动至今的全部 GC」算给当时那条命令。
归因键取 `this-command' 与 `major-mode'，两者都可能为 nil（启动期 / idle timer /
进程过滤器），store 层会把 nil 归一为 \"<none>\"。

语义：记录的是「GC **发生在**哪条命令之后」，不是「哪条命令**导致**」GC —— GC 可能
发生在 idle timer / 进程过滤器里，此时 `this-command' 是**上一条**命令，存在滞后；
启动期归因为 \"<none>\"。调用方不得把它读成因果归因，也不得写
`sum(hourly_gc_attrib.gc_count) = hourly_gc.gc_count' 这样的等式：归因只覆盖
「hook 已安装且落在某个采样窗口内」的那部分 GC，差值是 hook 安装前的 GC 与
「最后一次 flush 之后未结算」的 GC，故只成立 ≤ 关系。

累积形态是**二级 `eq' 哈希**（command → mode → `[gc-count gc-ms]' 向量）：
hook 热路径上只在首次遇到某个组合时分配内层表与向量，之后只做 `aset' 原地累加，
不产生 cons（用 `(cons command mode)' 作键的话每次 GC 都要分配一个 cons）。
异常一律 `ignore-errors' 静默吞掉 —— 此处**不得**调 `el-chronos-collect--warn'
（它会 `format'），这是 I6 的降级要求与分配约束的交集。

重入时（`--gc-attrib-busy' 为 t）直接返回且**不推进基线**——那一次 GC 不会丢失，
它会被并入下一次正常触发的差值里，归因到下一次的 `this-command'。放弃记录比在
重入路径里承担分配风险更安全。"
  (unless el-chronos-collect--gc-attrib-busy
    ;; 重入守卫：hook 内若又触发 GC（理论上被 `gc-cons-threshold' 抑制，但不赌），
    ;; 直接放弃本次记录，避免递归。
    (let ((el-chronos-collect--gc-attrib-busy t))
      (ignore-errors
        (let ((done gcs-done) (elapsed gc-elapsed)
              (last-done el-chronos-collect--gc-attrib-last-done)
              (last-elapsed el-chronos-collect--gc-attrib-last-elapsed))
          (cond
           ((or (null last-done) (null last-elapsed))
            (setq el-chronos-collect--gc-attrib-last-done done
                  el-chronos-collect--gc-attrib-last-elapsed elapsed))
           (t
            ;; `gcs-done' / `gc-elapsed' 正常单调递增；若被外部重置（`gcs-done' 变小），
            ;; 差值为负会被下面的 `(> count 0)' 挡掉，但基线已推进到新值——理论上会少算
            ;; 一段 GC。属极端场景，不额外处理。
            (let ((count (- done last-done))
                  (ms (* 1000.0 (- elapsed last-elapsed))))
              (setq el-chronos-collect--gc-attrib-last-done done
                    el-chronos-collect--gc-attrib-last-elapsed elapsed)
              (when (> count 0)
                (let* ((cmd this-command)
                       (md major-mode)
                       (inner (gethash cmd el-chronos-collect--gc-attrib-buffer)))
                  (unless inner
                    (setq inner (make-hash-table :test #'eq :size 8))
                    (puthash cmd inner el-chronos-collect--gc-attrib-buffer))
                  (let ((cell (gethash md inner)))
                    (cond (cell (aset cell 0 (+ (aref cell 0) count))
                                (aset cell 1 (+ (aref cell 1) ms)))
                          (t (puthash md (vector count ms) inner)))))))))))))
  nil)

(defun el-chronos-collect--flush-gc-attrib ()
  "把 GC 归因缓冲交给 store 落库，然后清空。
**不在 `post-gc-hook' 内调用**：这里可以分配（`symbol-name' 由 store 层做），
只是不要污染 hook 的热路径。由采样窗口 tick 调用。

键的归一交给 store（`el-chronos-store-record-gc-attrib' 把 symbol / nil 统一成字符串，
nil → \"<none>\"）：采集层只做「原样搬运」，不在热路径或此处提前转字符串，
否则同一组合会在归因表里出现 `foo' 与 \"foo\" 两行之外的额外分类负担。

会话 ID 取**当前**会话（`el-chronos--session-id'，与 `--startup-finish' 同源）：
store 的「会话行存在」校验是批次级的，键里的会话与之不符的归因行会在落库时被丢弃，
故绝不能在这里缓存旧会话 ID。会话未建立时 store 侧自己跳过（每进程告警一次）。

失败降级（I6）：逐条写库经 `el-chronos-collect--safe-apply'，单条失败不牵连其余；
整体异常限流告警并清空缓冲（与本窗口聚合的「异常时清空、不滚进下一窗口」同口径）。"
  (condition-case err
      (let ((hour-ts (el-chronos-collect--hour-ts))
            (session-id el-chronos--session-id))
        (when (> (hash-table-count el-chronos-collect--gc-attrib-buffer) 0)
          (maphash
           (lambda (command inner)
             (maphash
              (lambda (mode cell)
                (el-chronos-collect--safe-apply
                 #'el-chronos-store-record-gc-attrib
                 (list hour-ts session-id command mode
                       (aref cell 0) (aref cell 1))))
              inner))
           el-chronos-collect--gc-attrib-buffer))
        (clrhash el-chronos-collect--gc-attrib-buffer))
    (error
     (ignore-errors (clrhash el-chronos-collect--gc-attrib-buffer))
     (el-chronos-collect--warn "GC 归因聚合失败（已丢弃本窗口）：%S" err)))
  nil)

;;; TD-9 buffer 局部 hook 补挂

(defvar el-chronos-collect--ensuring-p nil
  "`el-chronos-collect--ensure-buffer-hooks' 是否正在运行（重入守卫）。
`buffer-list-update-hook' 会在 hook 内部新建 buffer 时**重入**（实测 2026-10-24
Emacs 31.1：hook 内 `get-buffer-create' 再触发同一个 hook 一次），用本标志挡掉，
避免将来的改动把补挂逻辑变成递归。")

(defun el-chronos-collect--internal-buffer-p (buffer)
  "BUFFER 是否是「内部 buffer」（名字以空格开头，Emacs 约定不可见）。
这类 buffer（渲染层挂载用的 ` *work*'、`with-temp-buffer' 的临时 buffer 等）不承载
用户命令，不给它们补挂命令计时 hook；只判断名字，不读 buffer 内容。"
  (let ((name (buffer-name buffer)))
    (and (stringp name) (> (length name) 0) (eq (aref name 0) ?\s))))

(defun el-chronos-collect--ensure-buffer-hooks ()
  "给「局部 hook 值遮蔽了全局默认值」的 buffer 补挂本模块的命令计时 hook（TD-9）。
Emacs 31 起两个 command hook 是 auto-buffer-local：buffer 一旦有局部绑定，全局默认值
对它不再生效。但**并非每个有局部绑定的 buffer 都需要补挂**，按 `run-hooks' 的语义分三种：
  - **无局部绑定**：`run-hooks' 直接跑全局默认值，本模块函数已在其中 → 不补挂；
  - **有局部绑定且局部值含 `t'**：局部值末尾的 `t' 表示「跑完局部值再跑全局值」，
    本模块函数已在全局里 → 不补挂（补了就是同一命令双跑，D1）；
  - **有局部绑定且局部值不含 `t'**：局部值完全遮蔽全局默认值 → **必须补挂**，
    否则该 buffer 内的命令完全不计时（TD-9 的原始漏采问题）。
判据必须用 `local-variable-p'（它只回答「有没有局部绑定」）；`buffer-local-value'
在无局部绑定时会回落全局值，区分不出这两种情况，故只在确认有局部绑定后才用它读局部值。

跳过 minibuffer：其命令循环语义与普通 buffer 不同（`minibufferp' 为真即跳过）。
跳过**内部 buffer**（名字以空格开头，见 `--internal-buffer-p`）：`with-temp-buffer`
等每次渲染都会新建这类 buffer，它们不承载用户命令，补挂既无意义，又让
`buffer-list-update-hook' 在每次渲染时反复遍历全部 buffer（「每次渲染要碰全部
buffer」的观感来源）。跳过也登记，避免下次重复判断。
每个 buffer 单独 `condition-case'，单个 buffer 失败不影响其余（I6），整体再兜一层；
`--ensuring-p' 挡住 `buffer-list-update-hook' 的重入。
幂等：`add-hook' 自带去重，`--hooked-buffers' 保证不重复判断（跳过的 buffer 也登记）。"
  (unless el-chronos-collect--ensuring-p
    (let ((el-chronos-collect--ensuring-p t))
      (condition-case err
          (dolist (buf (buffer-list))
            (unless (or (minibufferp buf)
                        (gethash buf el-chronos-collect--hooked-buffers))
              (condition-case err-in-buffer
                  (with-current-buffer buf
                    (unless (el-chronos-collect--internal-buffer-p buf)
                      (dolist (pair '((pre-command-hook . el-chronos-collect--pre-command)
                                      (post-command-hook . el-chronos-collect--post-command)))
                        (let ((hook (car pair)))
                          ;; 只补「有局部绑定且局部值不含 t」的 buffer（判据见 docstring）
                          (when (and (local-variable-p hook buf)
                                     (not (memq t (buffer-local-value hook buf))))
                            (add-hook hook (cdr pair) nil t)))))
                    (puthash buf t el-chronos-collect--hooked-buffers))
                (error
                 (el-chronos-collect--warn "buffer %s 补挂命令 hook 失败：%S"
                                           (if (buffer-live-p buf)
                                               (buffer-name buf)
                                             "<dead>")
                                           err-in-buffer)))))
        (error (el-chronos-collect--warn "遍历 buffer 补挂命令 hook 失败：%S" err)))))
  nil)

(defun el-chronos-collect--clean-buffer-hooks ()
  "摘除所有 buffer 上的**局部**命令计时 hook 并清空登记表（I5 零残留）。
buffer 可能已被 kill（登记表是 weak key，未必已回收），逐个 `buffer-live-p' 守卫；
单个 buffer 失败只限流告警，不中断清理（I6）。

局部值摘掉本模块函数后若已回落到 `default-value'，说明该局部绑定就是本模块为补挂
而创建的副本，此时再 `kill-local-variable' 摘掉绑定本身 —— 否则它会永久遮蔽全局
默认值（正是 TD-9 的成因机制），不该由观测器留在用户 buffer 上。若期间有其他包往
同一 hook 加了局部值，摘掉本模块函数后局部值不等于默认值，则保留绑定不 kill。"
  (condition-case err
      (maphash
       (lambda (buf _)
         (when (buffer-live-p buf)
           (condition-case err-in-buffer
               (with-current-buffer buf
                 (dolist (pair '((pre-command-hook . el-chronos-collect--pre-command)
                                 (post-command-hook . el-chronos-collect--post-command)))
                   (remove-hook (car pair) (cdr pair) t)
                   (when (and (local-variable-p (car pair))
                              (equal (symbol-value (car pair))
                                     (default-value (car pair))))
                     (kill-local-variable (car pair)))))
             (error
              (el-chronos-collect--warn "buffer %s 摘除命令 hook 失败：%S"
                                        (buffer-name buf) err-in-buffer)))))
       el-chronos-collect--hooked-buffers)
    (error (el-chronos-collect--warn "遍历 buffer 摘除命令 hook 失败：%S" err)))
  (clrhash el-chronos-collect--hooked-buffers)
  nil)

;;; T6a 启动打点（after-load-functions + 阶段锚点 + top-N）

;; 口径（设计 7）：`after-load-functions' 每次 load 触发一次，钩子收一个 FILE 实参；
;; 相邻两次触发的 `float-time' 差值作为「这次 load 的耗时」—— 这是**近似归因**
;; （不是精确归因）：差值里含前一个文件的收尾逻辑与它触发的钩子执行。
;; 钩子内**只写内存**（hash + 计数），写库集中在 `--startup-finish'；
;; 钩子会被每次 require 调用，必须极轻：只读 `float-time'、累加 hash、必要时摘钩。

(defvar el-chronos-collect--startup-loads (make-hash-table :test #'equal)
  "启动期包加载耗时累计表：library 名 → 累计毫秒。
**内存里保存全部记录**（一次启动几百条可忽略），只在
`el-chronos-collect--startup-finish' 写库前按毫秒降序截断到
`el-chronos-startup-top-n' 条 —— 全量入库只会让 `startup_phases' 行数膨胀。
停止时清空（I5）。")

(defvar el-chronos-collect--startup-last-load-ts nil
  "上一次 `after-load-functions' 触发的 `float-time'；nil 表示尚未建立基线。
差值语义：本次触发时刻减上次触发时刻 = 这次 load 的耗时（近似归因，见本节开头）。
首次触发只建基线不记录 —— 否则第一条会带上「mode 启动到第一次 load」的间隔，
那是启动开销而不是该文件自己的 load 耗时。
**不复用** `--last-sample-tick' / `--last-heartbeat'：三者语义与调度都不同，
共用会让各自的判定同时失真。")

(defvar el-chronos-collect--startup-load-count 0
  "已记录的启动期 load 次数。
用于三元摘钩条件之二（达到 `el-chronos-collect--startup-load-limit' 即摘钩），
也便于排障时确认「到底挂了多少次」。")

(defvar el-chronos-collect--startup-timer nil
  "启动打点的 30 秒兜底 timer；nil 表示未登记（启动已结束、未挂钩子或已收尾）。
三元摘钩的第三条：`emacs-startup-hook' 迟迟不到时的确定性下界。")

(defvar el-chronos-collect--startup-idle-timer nil
  "可选锚点 `first-idle' 的一次性 idle timer；nil 表示未登记。
**不参与摘钩判断**（idle 时机受用户活动影响、不可预期）；
连同 `--startup-timer' 一起在 `el-chronos-collect-stop' 与 `--startup-finish' 里清理（I5）。")

(defvar el-chronos-collect--startup-hook-done nil
  "`emacs-startup-hook' 是否已触发（显式标志，由该 hook 的回调置 t）。
三元摘钩条件之一的判据之一：和 `after-init-time' 取或 —— 后者是启动流程在
`after-init-hook' **之前**设好的时间戳，用作 `emacs-startup-hook' 的代理信号，
这样「mode 挂在 `after-init-hook' 上」这类写法也能在启动收尾后立刻摘钩。")

(defun el-chronos-collect--startup-library (file)
  "从 FILE 取 library 名：去目录、去（可能的双层）扩展名。
`after-load-functions' 传的是绝对文件名，形态有 `.el' / `.elc' / `.eln'
与压缩的 `.el.gz'（`.el.gz' 剥一层后仍剩 `.el'，故再剥一次）。
非字符串输入（理论上不会出现）返回空串，绝不抛错。"
  (let ((base (file-name-base (if (stringp file) file ""))))
    (if (string-match-p "\\.el\\'" base)
        (file-name-sans-extension base)
      base)))

(defun el-chronos-collect--startup-done-p ()
  "启动是否已收尾（三元摘钩条件之一的判据）。
`--startup-hook-done' 由 `emacs-startup-hook' 回调置 t；`after-init-time' 是它的代理
（启动流程先 `setq after-init-time'、紧接着跑 `after-init-hook'）。"
  (or el-chronos-collect--startup-hook-done
      (and (bound-and-true-p after-init-time) t)))

(defun el-chronos-collect--startup-load-limit ()
  "摘钩的累计 load 次数上限：`4 ×' 明细条数上限（`el-chronos-startup-top-n'）。
top-n 为 `0' / nil（不记明细）时用 200 兜底 —— 该上限只为防「启动 hook 迟迟不到时
无限累积」这唯一的病态情形，不记明细时同样需要一个有限值。"
  (let ((top (and (numberp el-chronos-startup-top-n)
                  (> el-chronos-startup-top-n 0)
                  el-chronos-startup-top-n)))
    (* 4 (or top 200))))

(defun el-chronos-collect--startup-top-entries ()
  "按毫秒降序返回待写库的 (LIBRARY . MS) 列表，最多 `el-chronos-startup-top-n' 条。
截断**只在这里**（写库前）发生：钩子写的是全量记录，否则会把「保留 top-N」错做成
「只采 top-N」。`el-chronos-startup-top-n' 为 `0' / nil 时返回空列表（不记明细）。"
  (let ((top (and (numberp el-chronos-startup-top-n)
                  (> el-chronos-startup-top-n 0)
                  el-chronos-startup-top-n))
        (entries nil))
    (when top
      (maphash (lambda (library ms) (push (cons library ms) entries))
               el-chronos-collect--startup-loads)
      (setq entries (sort entries (lambda (a b) (> (cdr a) (cdr b)))))
      (setq entries (cl-subseq entries 0 (min top (length entries)))))
    entries))

(defun el-chronos-collect--startup-trim-entries (entries)
  "把 (LIBRARY . MS) 的 alist ENTRIES 按毫秒降序截断到 `el-chronos-startup-top-n' 条。
与 `--startup-top-entries'（输入是 hash）**语义相同、输入形态不同**：探针交接拿到的
已经是排好序的 alist，这里仍重排一次，是为了不依赖对端顺序（一次 `sort' 在几百条量级上
可忽略）。排序前 `copy-sequence'：`sort' 是破坏性的，不得就地改动探针快照。
`el-chronos-startup-top-n' 为 `0' / nil 时返回空列表（不记明细）。"
  (let ((top (and (numberp el-chronos-startup-top-n)
                  (> el-chronos-startup-top-n 0)
                  el-chronos-startup-top-n)))
    (when (and top entries)
      (cl-subseq (sort (copy-sequence entries)
                       (lambda (a b) (> (cdr a) (cdr b))))
                 0 (min top (length entries))))))

(defun el-chronos-collect--startup-take-probe ()
  "把 `el-chronos-startup-probe' 采到的启动数据接过来写库；写入了数据返回非 nil。
**两个调用来源共用本函数**（同一份逻辑，禁止分叉）：
1. `--startup-instrument'（mode 启用时）—— 首次交接：探针在 `early-init' 上岗，
   这里拿到的是 `early-init' 起的完整加载锚点与明细；
2. 探针 `--finish' 的软调用（探针侧 `fboundp' 守卫 + 软调用，它不 require 本模块）——
   补写增量：首次 take 之后到启动收尾之间又加载的包，只能由探针在收尾时交棒。

判据（缺一不可）：
- `fboundp' 对 `el-chronos-startup-probe-take' 返回 nil → 用户没在 early-init 里 load，
  返回 nil，调用方完全走原有路径。**绝不 require**：探针是可选的侧文件，
  collect 不依赖它也能工作。
- `:anchors' 与 `:loads' **都**为空 → 返回 nil、不写库。只看探针的 `:captured-p' 不够：
  它表示「探针在启动期工作过」（记到 `early-init' 锚点即为真），此时一条可写数据都
  可能没有；按它分支会让调用方误以为「已有数据、不必自己挂钩子」。
- `el-chronos--session-id' 为 nil（mode 尚未启用 / 已停止）→ 返回 nil、不写库。
  **会话守卫在 `take' 之前**（`and' 短路），所以此时探针内存里的 `:loads' **不会被清空**：
  用户之后真启用 mode 时，下一次交接仍能把这批明细补上。唯一代价是「始终未启用 mode」时
  探针收尾后不再记录新加载，那批明细一直留在内存里不写库 —— 宁可如此，也不往
  「不属于任何会话」的库里写孤儿行（store 侧也会因会话缺失告警）。

幂等与重复写：`startup_phases' 主键是 `(session_id, phase)' 且落库走 upsert，
锚点重复写同 phase 同值无害（`take' 对 `:anchors' 只读不重置，本来就重复返回同一份）；
`:loads' 是增量（探针侧取走即清空），不会重复计数。

写库形态：`:anchors' 每条 → `(PHASE, MS)' 一行；`:loads' 经 `--startup-trim-entries'
按 `el-chronos-startup-top-n' 截断后每条 → `load:<LIBRARY>'。
全部经 `--safe-apply'（store 未加载或出错时只限流告警），全程 `condition-case'，
绝不向宿主抛错（I6）。"
  (condition-case err
      (when (and (fboundp 'el-chronos-startup-probe-take)
                 el-chronos--session-id)
        (let* ((snapshot (el-chronos-startup-probe-take))
               (anchors (plist-get snapshot :anchors))
               (loads (plist-get snapshot :loads)))
          (when (or anchors loads)
            (dolist (entry anchors)
              (el-chronos-collect--safe-apply
               #'el-chronos-store-record-startup-phase
               (list el-chronos--session-id (car entry) (cdr entry))))
            (dolist (entry (el-chronos-collect--startup-trim-entries loads))
              (el-chronos-collect--safe-apply
               #'el-chronos-store-record-startup-phase
               (list el-chronos--session-id
                     (concat "load:" (car entry))
                     (cdr entry))))
            t)))
    (error
     (el-chronos-collect--warn "启动探针交接失败（已跳过）：%S" err)
     nil)))

(defun el-chronos-collect--after-load (file)
  "记录启动期一次 load 的耗时（**近似归因**），并在三元条件满足时摘钩收尾。
FILE 是 `after-load-functions' 的实参（刚 load 完的文件名）。
这是**近似归因**（不是精确归因）：差值里含前一个文件的收尾逻辑与它触发的钩子执行。
首次调用**只建基线不记录**：否则第一条会带上「mode 启动到第一次 load」的间隔，
那是启动开销而不是该文件自己的 load 耗时。
高频调用（每次 `require' 一次），故只做三件事：读 `float-time'、累加内存 hash、
检查摘钩条件；**绝不在此写库**（写库由 `--startup-finish' 一次性完成）。
任何异常都吞掉（I6）：钩子在 load 尾部运行，抛错会打断正在加载的包。"
  (condition-case err
      (let ((now (float-time)))
        (if (null el-chronos-collect--startup-last-load-ts)
            (setq el-chronos-collect--startup-last-load-ts now)
          (let* ((elapsed (* 1000.0 (- now el-chronos-collect--startup-last-load-ts)))
                 (library (el-chronos-collect--startup-library file))
                 (previous (gethash library el-chronos-collect--startup-loads 0)))
            (puthash library (+ (float previous) elapsed)
                     el-chronos-collect--startup-loads)
            (setq el-chronos-collect--startup-last-load-ts now)
            (setq el-chronos-collect--startup-load-count
                  (1+ el-chronos-collect--startup-load-count))
            (when (or (el-chronos-collect--startup-done-p)
                      (>= el-chronos-collect--startup-load-count
                          (el-chronos-collect--startup-load-limit)))
              (el-chronos-collect--startup-finish)))))
    (error
     (el-chronos-collect--warn "记录启动期 load 失败（已跳过）：%S" err)
     nil)))

(defun el-chronos-collect--startup-finish ()
  "摘钩 + 取消兜底 timer + 把内存里的 load 明细按毫秒降序取 top-N 落库，然后清空。
幂等：重复调用安全 —— 钩子已摘、timer 已取消、hash 已空时不写任何行。
**只在此处写库**（钩子内绝不碰 sqlite）：一次启动几百条记录若逐条写库，
会把启动期的 IO 放大成可观开销。"
  (condition-case err
      (progn
        (remove-hook 'after-load-functions #'el-chronos-collect--after-load)
        (dolist (timer (list el-chronos-collect--startup-timer
                             el-chronos-collect--startup-idle-timer))
          (when timer
            (ignore-errors (cancel-timer timer))
            (setq el-chronos--active-timers (delq timer el-chronos--active-timers))))
        (setq el-chronos-collect--startup-timer nil
              el-chronos-collect--startup-idle-timer nil
              el-chronos-collect--startup-last-load-ts nil)
        (dolist (entry (el-chronos-collect--startup-top-entries))
          (el-chronos-collect--safe-apply
           #'el-chronos-store-record-startup-phase
           (list el-chronos--session-id
                 (concat "load:" (car entry))
                 (cdr entry))))
        (clrhash el-chronos-collect--startup-loads)
        (setq el-chronos-collect--startup-load-count 0))
    (error
     (el-chronos-collect--warn "启动打点收尾失败（已跳过）：%S" err)
     nil))
  nil)

(defun el-chronos-collect--startup-anchor (phase)
  "记录阶段锚点 PHASE 相对 `before-init-time' 的毫秒偏移（浮点）。
PHASE 取 `mode-start' / `after-init' / `startup' / `first-idle'。
`before-init-time' 不存在（交互式启动后的会话）时直接返回 nil：这类会话没有启动起点，
**不能倒填**锚点，也不该报错。返回偏移毫秒（便于调用方与排障），失败返回 nil。"
  (condition-case err
      (when (and (boundp 'before-init-time) before-init-time)
        (let ((ms (* 1000.0 (float-time (time-subtract (current-time)
                                                       before-init-time)))))
          (el-chronos-collect--safe-apply
           #'el-chronos-store-record-startup-phase
           (list el-chronos--session-id phase ms))
          ms))
    (error
     (el-chronos-collect--warn "记录启动阶段锚点 %s 失败（已跳过）：%S" phase err)
     nil)))

(defun el-chronos-collect--startup-after-init ()
  "`after-init-hook' 回调：自摘后记 `after-init' 锚点，并捕获待补写的 `startup_ms'。
**不在此摘 `after-load-functions'**：启动收尾（`emacs-startup-hook' 及它触发的
load）还在后面，摘钩统一由三元条件负责 —— 两处都摘会让判定分散在两个地方。
**`startup_ms' 补写（设计 7 处置 ③）**：本钩子只在 `after-init-time' 为 nil 时才挂
（见 `el-chronos-collect--startup-instrument' 的前置判定），也就是「mode 在
`after-init-hook' 之前启用」这一种场景 —— 那时 `--ensure-session' 建会话行时
`after-init-time' 仍是 nil，`startup_ms' 落 NULL 且事后再没有人能补上，
所以在启动收尾处把 `before-init-time' → `after-init-time' 的差值算出来交给 store。
**本回调零 IO**：只算值并调 `el-chronos-store-note-startup-ms'（纯内存登记，
不碰 sqlite、不告警）；真正的 `UPDATE ... WHERE startup_ms IS NULL' 由 store 的
下一次 flush 在既有事务内完成（复用既有 5 秒 timer，**不新增 timer**，I5 清理清单不变）。
这样启动期一次 sqlite 调用都没有，`busy_timeout=2000ms' 把启动拖住 2 秒的风险归零。"
  (remove-hook 'after-init-hook #'el-chronos-collect--startup-after-init)
  (el-chronos-collect--startup-anchor 'after-init)
  (condition-case err
      (when (and after-init-time before-init-time)
        (el-chronos-collect--safe-apply
         #'el-chronos-store-note-startup-ms
         (list (* 1000.0 (float-time (time-subtract after-init-time
                                                     before-init-time))))))
    (error
     (el-chronos-collect--warn "捕获 startup_ms 失败（已跳过）：%S" err)
     nil))
  nil)

(defun el-chronos-collect--startup-on-startup ()
  "`emacs-startup-hook' 回调：置摘钩标志、自摘、记 `startup' 锚点，然后立即收尾。
自摘是幂等前提：关闭后再触发时不该再往停掉的观测器里塞值（I5）。"
  (setq el-chronos-collect--startup-hook-done t)
  (remove-hook 'emacs-startup-hook #'el-chronos-collect--startup-on-startup)
  (el-chronos-collect--startup-anchor 'startup)
  (el-chronos-collect--startup-finish))

(defun el-chronos-collect--startup-first-idle ()
  "可选锚点 `first-idle'：仅在能注册 idle timer 时记一次（**不参与摘钩**）。
idle 时机受用户活动影响、不可预期，故它只是「阶段标记」，绝不作确定性判据
（同一理由让本设计否决了「用 idle 时机做数据补写」的备选方案）。"
  (el-chronos-collect--startup-anchor 'first-idle))

(defun el-chronos-collect--startup-instrument ()
  "挂启动打点（T6a）：先尝试从 `early-init' 探针交接数据，再按需挂自己的钩子。
两条**互斥**路径，判据是 `--startup-take-probe' 的返回值（非 nil = 确实写入了探针数据）：

① **探针路径**（用户按 ADR-0006 在 `early-init.el' 里 load 了探针）：探针的
   `after-load-functions' 从 `early-init' 起就覆盖了**完整**加载过程，锚点与 `load:*'
   明细都已交接完毕 → 本模块**一个自有钩子都不挂**（`after-load-functions' /
   `after-init-hook' / `emacs-startup-hook' / 30 秒兜底 timer 全不挂）。理由：再挂一遍
   会把同一批 load 记两次（两套近似归因基线互相污染时间差），而探针那份覆盖范围更大。
   仍然记 `mode-start' 锚点（探针在 mode 启用前就记完了自己的锚点，`mode-start' 只有
   这里能记），并注册一次性 `first-idle' 锚点（纯阶段标记、不参与摘钩，与现状一致）。

② **现状路径**（探针不存在 / 探针没采到数据 / 会话尚未建立）：完全保持原逻辑 ——
   始终记 `mode-start' 锚点；仅当启动尚未结束时才挂钩子。
   **前置判定（最关键的一条）**：`after-init-time' 非 nil 表示启动已基本结束
   （启动流程先 `setq after-init-time' 再跑 `after-init-hook'，两行都在 init 文件加载之后）。
   用户（含本机配置）常用 `emacs-startup-hook' 启动 mode（本机 `init-chronos.el' 即如此）——
   那时 `emacs-startup-hook' 已跑完且**永不重触发**，三元摘钩里的第一条恒不可达，
   钩子会一直存活到「800 次 load」或「30 秒兜底」，把**日常加载冒充成启动耗时**、
   污染 `startup_phases'。所以这类配置下**一个钩子都不挂**（副作用是好的：零额外开销）。
   启动已结束时也不注册 30 秒 timer —— 没有钩子要摘，timer 只会白占一个登记项。

两条路径的差别只在**覆盖范围**：探针路径覆盖 `early-init' 起的完整加载；现状路径只覆盖
mode 之后的加载（观测器无法观测自己被加载之前的事，TD-16）。"
  (condition-case err
      (progn
        (clrhash el-chronos-collect--startup-loads)
        (setq el-chronos-collect--startup-last-load-ts nil
              el-chronos-collect--startup-load-count 0
              el-chronos-collect--startup-hook-done nil)
        ;; 先交接探针（它含 `early-init' 起的更早阶段），再补记 `mode-start'
        ;; —— `mode-start' 是探针无法知道的锚点，只能在这里记。
        (let ((probed (el-chronos-collect--startup-take-probe)))
          (el-chronos-collect--startup-anchor 'mode-start)
          (cond
           (probed
            ;; ① 探针路径：只补 `first-idle' 锚点，一个自有钩子都不挂
            (when (fboundp 'run-with-idle-timer)
              (ignore-errors
                (setq el-chronos-collect--startup-idle-timer
                      (el-chronos-collect--register-timer
                       (run-with-idle-timer
                        0 nil #'el-chronos-collect--startup-first-idle))))))
           ((not (bound-and-true-p after-init-time))
            ;; ② 现状路径：启动未结束才挂钩子（判据与理由见 docstring）
            (add-hook 'after-load-functions #'el-chronos-collect--after-load)
            (add-hook 'after-init-hook #'el-chronos-collect--startup-after-init)
            (add-hook 'emacs-startup-hook #'el-chronos-collect--startup-on-startup)
            ;; 可选锚点 first-idle：只作阶段标记，不参与摘钩（见 `--startup-first-idle'）
            (when (fboundp 'run-with-idle-timer)
              (ignore-errors
                (setq el-chronos-collect--startup-idle-timer
                      (el-chronos-collect--register-timer
                       (run-with-idle-timer
                        0 nil #'el-chronos-collect--startup-first-idle)))))
            ;; 30 秒兜底 timer（三元摘钩的第三条）：`emacs-startup-hook' 迟迟不到时的下界
            (setq el-chronos-collect--startup-timer
                  (el-chronos-collect--register-timer
                   (run-with-timer 30 nil #'el-chronos-collect--startup-finish)))))))
    (error
     (el-chronos-collect--warn "启动打点挂载失败（已跳过）：%S" err)
     nil))
  nil)

;;; 启停

(defun el-chronos-collect--register-timer (timer)
  "把 TIMER 登记到入口模块的 timer 表并返回它；入口模块未加载时直接返回。"
  (if (fboundp 'el-chronos--register-timer)
      (el-chronos--register-timer timer)
    timer))

;;;###autoload
(defun el-chronos-collect-start ()
  "启动采集层：命令计时 hook、错误标记 advice、心跳 timer、采样 timer 与 profiler。
命令计时装**全局默认值**，并由 `el-chronos-collect--ensure-buffer-hooks' 只给「局部值
遮蔽了全局默认值」的 buffer 补挂局部值（判据见该函数与文件头 D1 一节），再用
`buffer-list-update-hook' 给新 buffer 做同样的判断 —— Emacs 31 起两个 command hook 是
auto-buffer-local，只装默认值会被已有的局部绑定遮蔽（TD-9），而给「局部值含 `t'」的
buffer 也补挂则会让同一命令双跑（D1）。
幂等：已在运行时直接返回 t。各子步骤互不牵连——采样启动失败不影响命令计时与心跳，
任何异常都不向宿主抛错（I6）。

GC 归因挂 `post-gc-hook'（**全局** hook，与 buffer 无关）；三个 `--gc-attrib-*' 变量
在启动时归零 / 清空，保证首次 hook 只重建基线（否则会把「启动至今的全部 GC」算给当时
那条命令）—— 与 `--gc-baseline' 同口径。"
  (interactive)
  (unless el-chronos-collect--running-p
    (add-hook 'pre-command-hook #'el-chronos-collect--pre-command)
    (add-hook 'post-command-hook #'el-chronos-collect--post-command)
    ;; TD-9 / D1：两个 hook 在 Emacs 31 是 auto-buffer-local，局部值不含 t 的 buffer 会
    ;; 完全遮蔽上面的全局默认值（须补挂）；局部值含 t 的 buffer 会连带跑全局值（补挂即双跑）。
    (el-chronos-collect--ensure-buffer-hooks)
    (add-hook 'buffer-list-update-hook #'el-chronos-collect--ensure-buffer-hooks)
    ;; 错误检测：Emacs 30+ 的默认 `command-error-function' 是
    ;; `help-command-error-confusable-suggestions'，它内部仍调用
    ;; `command-error-default-function'（实测 2026-10-24，Emacs 31.1），
    ;; 故 advice 默认实现即可同时覆盖新旧默认值。
    (when (fboundp 'command-error-default-function)
      (unless (advice-member-p #'el-chronos-collect--note-error
                               'command-error-default-function)
        (advice-add 'command-error-default-function
                    :before #'el-chronos-collect--note-error)))
    (setq el-chronos-collect--timers
          (list (el-chronos-collect--register-timer
                 (run-with-timer el-chronos-heartbeat-seconds
                                 el-chronos-heartbeat-seconds
                                 #'el-chronos-collect--heartbeat))
                (el-chronos-collect--register-timer
                 (run-with-timer el-chronos-sample-window-seconds
                                 el-chronos-sample-window-seconds
                                 #'el-chronos-collect--sample-tick))))
    (setq el-chronos-collect--last-heartbeat (float-time))
    ;; 采样窗口基线：同样在启动时建立，避免「启动到第一次 tick 之间」被误判为丢窗
    (setq el-chronos-collect--last-sample-tick (float-time))
    ;; GC 基线：nil 表示未初始化，首个采样窗口只建立基线（见 `--collect-gc'）
    (setq el-chronos-collect--gc-baseline nil
          el-chronos-collect--heap-tick-counter 0)
    ;; 资源基线：同上，首个窗口只建基线（见 `--collect-resources'）
    (setq el-chronos-collect--resource-baseline nil)
    ;; GC 归因：`post-gc-hook' 是**全局** hook（与 buffer 无关），安装/移除必须严格配对
    ;; （I5 零残留）；两个 baseline 置 nil 保证下一次 hook 只重建基线、不把「启动至今的
    ;; 全部 GC」算给当时那条命令
    (add-hook 'post-gc-hook #'el-chronos-collect--post-gc)
    (setq el-chronos-collect--gc-attrib-last-done nil
          el-chronos-collect--gc-attrib-last-elapsed nil
          el-chronos-collect--gc-attrib-busy nil)
    (clrhash el-chronos-collect--gc-attrib-buffer)
    (el-chronos-collect--start-sampling)
    ;; 启动打点（T6a）：先记 `mode-start' 锚点；启动已结束则一个钩子都不挂
    ;; （判据与理由见 `el-chronos-collect--startup-instrument'）
    (el-chronos-collect--startup-instrument)
    (setq el-chronos-collect--running-p t))
  el-chronos-collect--running-p)

;;;###autoload
(defun el-chronos-collect-stop ()
  "停止采集层并清空全部状态，保证零残留（I5）。幂等。
零残留判据：`--timers' 为 nil、两个 hook 的默认值不含本模块函数、
**各 buffer 的局部值也不含**（`--hooked-buffers' 清空、`buffer-list-update-hook' 不含补挂函数）、
`(profiler-cpu-running-p)' 为 nil、窗口 hash 为空、pending 清空、
GC 采集状态归零（`--gc-baseline' 为 nil、`--heap-tick-counter' 为 0）、
GC 归因归零（`post-gc-hook' 不含本模块函数、`--gc-attrib-buffer' 为空、
`--gc-attrib-last-done' / `--gc-attrib-last-elapsed' /
`--gc-attrib-busy' 均为 nil）、
资源采集基线归零（`--resource-baseline' 为 nil）、
采样窗口基线归零（`--last-sample-tick' 为 nil）、
启动打点全部摘净（`after-load-functions' / `after-init-hook' / `emacs-startup-hook'
不含本模块函数、`--startup-timer' / `--startup-idle-timer' 为 nil、
`--startup-loads' 为空、`--startup-load-count' 为 0）。
**清理顺序是语义的一部分**：先摘启动打点的钩子与 timer → 再 `--sample-tick' 收尾 →
最后摘其余钩子。理由：`after-init-hook' 的补写回调与 `after-load-functions' 的计时回调
只要还被挂着，清理途中任何一次触发都会往「**正在关闭**」的会话里再塞一次值
（pending 被重新置上、load 记录又长出一条），随后 `store-close' 会把它写进库 ——
摘得越早越干净。"
  (interactive)
  ;; ── 阶段 1：启动打点清理（I5）────────────────────────────────────────────
  ;; 必在 `--sample-tick' 收尾**之前**：补写钩子若在清理途中被触发，会对正在关闭的会话
  ;; 再登记一次 pending，`store-close' 的 flush 就把它写进去了（见 docstring）。
  (remove-hook 'after-load-functions #'el-chronos-collect--after-load)
  (remove-hook 'after-init-hook #'el-chronos-collect--startup-after-init)
  (remove-hook 'emacs-startup-hook #'el-chronos-collect--startup-on-startup)
  (dolist (timer (list el-chronos-collect--startup-timer
                       el-chronos-collect--startup-idle-timer))
    (when timer
      (ignore-errors (cancel-timer timer))
      (setq el-chronos--active-timers (delq timer el-chronos--active-timers))))
  (setq el-chronos-collect--startup-timer nil
        el-chronos-collect--startup-idle-timer nil
        el-chronos-collect--startup-last-load-ts nil
        el-chronos-collect--startup-load-count 0
        el-chronos-collect--startup-hook-done nil)
  (clrhash el-chronos-collect--startup-loads)
  ;; ── 阶段 2：取走最后一个（可能不足一个窗口的）样本，再停 profiler ──────────
  (when el-chronos-collect--sampling-p
    (el-chronos-collect--sample-tick)
    (when (and (fboundp 'profiler-cpu-running-p) (profiler-cpu-running-p))
      (ignore-errors (profiler-cpu-stop)))
    (setq el-chronos-collect--sampling-p nil))
  ;; ── 阶段 3：摘其余钩子 ──────────────────────────────────────────────────
  ;; 先摘增量补挂入口，再摘各 buffer 的局部值（顺序颠倒会让清理期间的新 buffer 又被挂上）
  (remove-hook 'buffer-list-update-hook #'el-chronos-collect--ensure-buffer-hooks)
  (remove-hook 'pre-command-hook #'el-chronos-collect--pre-command)
  (remove-hook 'post-command-hook #'el-chronos-collect--post-command)
  ;; `post-gc-hook' 是全局 hook：摘函数与清缓冲必须同批（I5 零残留）；未 flush 的归因
  ;; （≤1 个窗口）在这里丢弃 —— 此时会话正在关闭，写库只会得到孤儿行或被批次校验丢弃
  (remove-hook 'post-gc-hook #'el-chronos-collect--post-gc)
  (clrhash el-chronos-collect--gc-attrib-buffer)
  (el-chronos-collect--clean-buffer-hooks)
  (when (fboundp 'command-error-default-function)
    (ignore-errors
      (advice-remove 'command-error-default-function
                     #'el-chronos-collect--note-error)))
  (dolist (timer el-chronos-collect--timers)
    (ignore-errors (cancel-timer timer))
    (setq el-chronos--active-timers (delq timer el-chronos--active-timers)))
  (setq el-chronos-collect--timers nil
        el-chronos-collect--last-heartbeat nil
        el-chronos-collect--last-sample-tick nil
        el-chronos-collect--gc-baseline nil
        el-chronos-collect--heap-tick-counter 0
        el-chronos-collect--resource-baseline nil
        el-chronos-collect--gc-attrib-last-done nil
        el-chronos-collect--gc-attrib-last-elapsed nil
        el-chronos-collect--gc-attrib-busy nil
        el-chronos-collect--pending-p nil
        el-chronos-collect--command-start nil
        el-chronos-collect--command-name nil
        el-chronos-collect--command-gc-done nil
        el-chronos-collect--command-gc-elapsed nil
        el-chronos-collect--errored-p nil
        el-chronos-collect--running-p nil)
  (clrhash el-chronos-collect--window-self)
  (clrhash el-chronos-collect--window-stacks)
  nil)

(provide 'el-chronos-collect)

;;; el-chronos-collect.el ends here
