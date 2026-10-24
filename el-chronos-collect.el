;;; el-chronos-collect.el --- 命令计时、心跳阻塞与采样聚合  -*- lexical-binding: t; -*-

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

;;; 自定义项

(defcustom el-chronos-collect-notify-blocks nil
  "心跳检测到主线程阻塞时如何提示。
阻塞事件**始终**记入 `slow_events'（`kind' = \"block\"）并出现在报告与 dashboard 里，
本开关只控制「提示」这一层，取任何值都不影响采集与记录。

取值：
- nil      —— 默认，完全不提示（既不占 echo area，也不写 `*Messages*'）。
- messages —— 只写 `*Messages*'：`message' 被 `inhibit-message' 包住，
              不占用 echo area，不打断正在进行的 minibuffer 输入与补全。
- t        —— 在 echo area 提示一句（旧语义，兼容既有配置）。

为什么默认静默：这条提示落在 echo area，用户输入中途出现会盖住 minibuffer 候选、
干扰正常输入；而阻塞本身事后在报告 / dashboard 里可查。需要即时可见性时再显式
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
  "上一次心跳的实际触发时刻（`float-time'）；nil 表示尚无基线。")

(defvar el-chronos-collect--suppress-block-p nil
  "非 nil 时心跳跳过阻塞判定，只推进基线（抑制自观测假阳性）。
由 `el-chronos-report' 与 `el-chronos-dashboard' 在渲染期间 `let' 绑定为 t；
`el-chronos-collect--heartbeat' 用 `bound-and-true-p' 读取并据此跳过阻塞判定，
同时把 `el-chronos-collect--last-heartbeat' 推进到当前时刻 —— 否则解除绑定后
那一次补跑的心跳会把整段渲染耗时算成一条巨型阻塞（I2 只认时间差，无法事后区分）。
两个可视化模块各自 `defvar' 同名声明，避免跨模块 `let' 绑定未声明变量报
`void-variable'；同义重复声明无副作用。")

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
**注意**：这是**结算时刻**的栈，不是慢函数现场栈；精确现场栈由 T11 高精度剖析提供。"
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
那样判据永远不成立，等于没有防护）。"
  (let ((name (el-chronos-collect--command-label)))
    ;; D1 兜底：同一命令被同一 hook 双跑时不结算、不重置（见 docstring）
    (unless (and el-chronos-collect--pending-p
                 (equal name el-chronos-collect--command-name)
                 (numberp el-chronos-collect--command-start)
                 (< (- (float-time) el-chronos-collect--command-start) 0.001))
      (when el-chronos-collect--pending-p
        (el-chronos-collect--finish 'aborted))
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
下 `--command-name' 与 `--command-start' 同时设置，不会出现该状态。"
  (let ((start el-chronos-collect--command-start)
        (name el-chronos-collect--command-name)
        (gc-start el-chronos-collect--command-gc-elapsed))
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
          (el-chronos-collect--safe-apply
           #'el-chronos-store-record-slow-event
           (list (list :duration-ms duration-ms :kind "command" :command name
                       :stack (el-chronos-collect--current-stack)
                       :context context)))))))
  nil)

;;; T5b 心跳阻塞

(defun el-chronos-collect--heartbeat ()
  "心跳：比较相邻两次触发的实际间隔，漂移超阈值即记一条阻塞事件。
心跳迟到说明主线程在两次触发之间被占住（原生代码、未分批 IO、长 timer 回调）；
阻塞期间无可靠 Lisp 回调，只能事后按时间差反推（I2）。自身 `condition-case'。

`el-chronos-collect--suppress-block-p' 非 nil 时不判定阻塞，只推进基线 ——
报告 / 页面渲染是用户主动触发的重查询，其耗时不该混进「待排查的卡顿」（自观测抑制）。"
  (condition-case err
      (let* ((now (float-time))
             (last el-chronos-collect--last-heartbeat))
        (setq el-chronos-collect--last-heartbeat now)
        (unless (bound-and-true-p el-chronos-collect--suppress-block-p)
          (when-let* ((gap-ms (and (numberp last) (* 1000 (- now last))))
                      ((> gap-ms el-chronos-block-threshold-ms)))
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
                  (message "el-chronos：主线程阻塞约 %.0f ms（已记录）" gap-ms)))))))
    (error (el-chronos-collect--warn "心跳检测失败：%S" err)))
  nil)

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

(defun el-chronos-collect--accumulate-entry (stack count)
  "把一条采样（STACK 向量 + COUNT 样本）累计到本窗口的两个聚合表。
STACK 的第 0 个元素是 leaf（实测结论见文件头），口径见文件头 2b：
  - leaf 同时加 SELF 与 SAMPLES 计数（leaf 口径，二者同源、落库形态不同）；
  - 栈中每个**不同**函数各加一次 TOTAL，同一函数在一条栈里出现多次（递归帧）
    只算一次，避免 total 被重复帧放大；TOTAL 不碰 SAMPLES。
单条栈只遍历一遍：栈内去重用 `memq'，代价 O(栈长²)（实测栈长 ≤ 40 帧，可忽略），
且只在窗口 tick 上发生，不落在命令热路径里。"
  (when (and (vectorp stack) (> (length stack) 0) (numberp count) (> count 0))
    ;; 1) self / samples：只认栈顶帧（leaf），与内置 profiler 报告的自时间归属一致
    (let ((leaf (aref stack 0)))
      (when (symbolp leaf)
        (el-chronos-collect--accumulate-self leaf count)))
    ;; 2) total：栈内去重后每个出现过的函数各记一次（不动 samples）
    (let ((seen nil)
          (length (length stack)))
      (dotimes (index length)
        (let ((function (aref stack index)))
          (when (and (symbolp function) (not (memq function seen)))
            (push function seen)
            (el-chronos-collect--accumulate-appearance function count)))))
    ;; 栈本身按 JSON 字符串聚合并累加样本数（完整调用链的唯一来源）
    ;; 帧名统一经 `el-chronos-collect--frame-name' 归一：nil → "unknown"、非符号对象
    ;; （闭包 / 字节码 / 其他）→ "anonymous"。归一后的名字同时充当 hash key，故同一
    ;; 闭包对象不会因 `format' 输出差异被拆成两条栈。
    (let* ((names (vconcat (mapcar #'el-chronos-collect--frame-name (append stack nil))))
           (json (condition-case nil (json-serialize names) (error nil))))
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

(defun el-chronos-collect--sample-tick ()
  "采样窗口到期：取走 profiler 日志 → 累加 → 落库 → 清空窗口。
`profiler-cpu-log' 取用即重置，本函数因此是采样数据的唯一出口（Emacs 单线程 timer
保证不会重入）。自身 `condition-case'：任何异常都不得终止 timer（I6）。"
  (condition-case err
      (when el-chronos-collect--sampling-p
        (el-chronos-collect--accumulate (profiler-cpu-log))
        (el-chronos-collect--flush-window))
    (error
     ;; 异常时也要清空窗口，避免脏数据滚进下一个窗口
     (ignore-errors (clrhash el-chronos-collect--window-self))
     (ignore-errors (clrhash el-chronos-collect--window-stacks))
     (el-chronos-collect--warn "采样窗口聚合失败：%S" err)))
  nil)

;;; TD-9 buffer 局部 hook 补挂

(defvar el-chronos-collect--ensuring-p nil
  "`el-chronos-collect--ensure-buffer-hooks' 是否正在运行（重入守卫）。
`buffer-list-update-hook' 会在 hook 内部新建 buffer 时**重入**（实测 2026-10-24
Emacs 31.1：hook 内 `get-buffer-create' 再触发同一个 hook 一次），用本标志挡掉，
避免将来的改动把补挂逻辑变成递归。")

(defun el-chronos-collect--internal-buffer-p (buffer)
  "BUFFER 是否是「内部 buffer」（名字以空格开头，Emacs 约定不可见）。
这类 buffer（ETAF 挂载用的 ` *work*'、`with-temp-buffer' 的临时 buffer 等）不承载
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
跳过**内部 buffer**（名字以空格开头，见 `--internal-buffer-p`）：ETAF 挂载、`with-temp-buffer`
等每次渲染都会新建这类 buffer，它们不承载用户命令，补挂既无意义，又让
`buffer-list-update-hook' 在每次渲染时反复遍历全部 buffer（「打开 dashboard 要碰全部
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

;;; 启停

(defun el-chronos-collect--register-timer (timer)
  "把 TIMER 登记到入口模块的 timer 表并返回它；入口模块未加载时直接返回。"
  (if (fboundp 'el-chronos--register-timer)
      (el-chronos--register-timer timer)
    timer))

(defun el-chronos-collect-start ()
  "启动采集层：命令计时 hook、错误标记 advice、心跳 timer、采样 timer 与 profiler。
命令计时装**全局默认值**，并由 `el-chronos-collect--ensure-buffer-hooks' 只给「局部值
遮蔽了全局默认值」的 buffer 补挂局部值（判据见该函数与文件头 D1 一节），再用
`buffer-list-update-hook' 给新 buffer 做同样的判断 —— Emacs 31 起两个 command hook 是
auto-buffer-local，只装默认值会被已有的局部绑定遮蔽（TD-9），而给「局部值含 `t'」的
buffer 也补挂则会让同一命令双跑（D1）。
幂等：已在运行时直接返回 t。各子步骤互不牵连——采样启动失败不影响命令计时与心跳，
任何异常都不向宿主抛错（I6）。"
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
    (el-chronos-collect--start-sampling)
    (setq el-chronos-collect--running-p t))
  el-chronos-collect--running-p)

(defun el-chronos-collect-stop ()
  "停止采集层并清空全部状态，保证零残留（I5）。幂等。
零残留判据：`--timers' 为 nil、两个 hook 的默认值不含本模块函数、
**各 buffer 的局部值也不含**（`--hooked-buffers' 清空、`buffer-list-update-hook' 不含补挂函数）、
`(profiler-cpu-running-p)' 为 nil、窗口 hash 为空、pending 清空。"
  (interactive)
  ;; 先取走最后一个（可能不足一个窗口的）样本，再停 profiler —— 半个窗口也不丢
  (when el-chronos-collect--sampling-p
    (el-chronos-collect--sample-tick)
    (when (and (fboundp 'profiler-cpu-running-p) (profiler-cpu-running-p))
      (ignore-errors (profiler-cpu-stop)))
    (setq el-chronos-collect--sampling-p nil))
  ;; 先摘增量补挂入口，再摘各 buffer 的局部值（顺序颠倒会让清理期间的新 buffer 又被挂上）
  (remove-hook 'buffer-list-update-hook #'el-chronos-collect--ensure-buffer-hooks)
  (remove-hook 'pre-command-hook #'el-chronos-collect--pre-command)
  (remove-hook 'post-command-hook #'el-chronos-collect--post-command)
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
