;;; el-chronos-report.el --- org 报告与数据导出  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Thomas

;; Author: Thomas
;; Keywords: tools, performance
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; 报告层：把 `el-chronos-analysis' 的纯数据渲染成人类可读产物，本身不做 SQL、不写库、不改
;; 采集行为。入口：`el-chronos-report' / `el-chronos-weekly-report' / `el-chronos-export' /
;; `el-chronos-show-event' / `el-chronos-profile-command'（T11 单命令高精度剖析：当场跑
;; 一次命令 + 1ms 采样，不查库）。降级（同 I6 / I11）：analysis 返回 nil 一律按「空数据」
;; 渲染成 `（无数据）'，不向调用方抛错；只有「事件不存在」这类输入错误才 `user-error'。
;; 单位（I4）：analysis 给出毫秒，本层只做展示换算；JSON 的 `generated_at' 也是毫秒。
;;
;; 与采集层的唯一接触点（只读语义的例外，见 `el-chronos-report--without-block-events'）：
;; 重查询期间绑定 `el-chronos-collect--suppress-block-p' 并在结束时重设
;; `el-chronos-collect--last-heartbeat'，避免报告耗时被心跳记成假阻塞。
;; **读取方在 `el-chronos-collect'**：本文件只负责绑定，不改心跳逻辑。

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'org)
(require 'el-chronos)
(require 'el-chronos-analysis)
;; 剖析（T11）需要按包归因与（可选）落库，两者都是核心模块，无第三方依赖
(require 'el-chronos-attrib)
(require 'el-chronos-store)

(defconst el-chronos-report--buffer-name "*el-chronos-report*" "报告 buffer 名称。")
(defconst el-chronos-report--event-buffer-name "*el-chronos-event*" "事件详情 buffer 名称。")
(defconst el-chronos-report--default-range '7d "未指定时间范围时的默认值。")
(defconst el-chronos-report--range-alist '((1d . 1) (7d . 7) (30d . 30)) "范围到天数的映射。")
(defconst el-chronos-report--state-subdir ".local/state/chronos/" "运行时状态目录。")
(defconst el-chronos-report--weekly-file-name "chronos-weekly.org" "周报默认文件名。")
(defconst el-chronos-report--trend-rows 48 "趋势最多展示的桶数（取最近若干桶）。")
(defconst el-chronos-report--blocking-rows 20 "阻塞事件最多展示条数。")
(defconst el-chronos-report--session-rows 20 "会话最多展示条数。")
(defconst el-chronos-report--stack-rows 10 "调用栈排行最多展示条数。")
(defconst el-chronos-report--stack-frames 8 "调用栈展示保留的帧数（自 leaf 起）。")
(defconst el-chronos-report--gc-rows 48 "「GC 与内存」最多展示的桶数（取最近若干桶）。")
(defconst el-chronos-report--gc-degrade
  "本期无 GC 采样数据（Emacs 31.1 以下不采集堆大小）。"
  "「GC 与内存」节的降级说明。
I11：无数据时**不省略整节**（与其它节的 `（无数据）' 占位等价，但更具体 —— 用户需要
知道「没数据」的可能原因是 Emacs 版本低于 31.1、堆大小无从采集）。")
(defconst el-chronos-report--empty "（无数据）" "空数据占位文本。")
(defconst el-chronos-report--startup-load-rows 10
  "「启动分解」里包加载 TOP 最多展示的库数。
采集层按 `el-chronos-startup-top-n'（默认 50）截断入库，报告再截一次只为可读性。")
(defconst el-chronos-report--startup-degrade
  "本期无启动分解数据（需在启动结束前启用 `el-chronos-mode'，最早可在 early-init.el 里启用）。"
  "「启动分解」节的整体降级说明：库里没有任何会话带启动数据时使用。
I11：无数据时**不省略整节**，且说明为什么可能没数据 —— 用户看不到启动分解的最常见原因
就是 mode 在 init 末尾才启用（此时启动已结束，采不到任何 load）。")
(defconst el-chronos-report--startup-phases-degrade
  "（无阶段锚点：mode 启动时启动已结束，只能记录 mode-start 之后的阶段）"
  "「启动分解」节里阶段锚点表为空时的降级说明。")
(defconst el-chronos-report--startup-loads-degrade
  "（无包加载明细：mode 启动时启动已结束，不记录 after-load-functions）"
  "「启动分解」节里包加载表为空时的降级说明。")
(defconst el-chronos-report--startup-total-degrade
  "（无总启动耗时：该会话的 startup_ms 尚未写入）"
  "「启动分解」节里总耗时缺失时的降级说明（`startup_ms' 为 NULL 的会话）。")
(defconst el-chronos-report--config-degrade
  "本期无会话变更记录（会话启动时未取到 git-head / config-sig，或窗口内没有会话）。"
  "「配置变更」节无数据时的降级说明（I11：不省略整节）。")
(defconst el-chronos-report--health-no-data
  "本期无采集数据（采集器尚未写入健康指标）"
  "「采集健康」节在窗口内 `hourly_health' **一行都没有**时的专属说明。
必须与 `本期无采集异常' 严格区分（I11）：后者是「采集器在工作、只是没有坏消息」，
前者是「采集器根本没上报」——两者的运维含义相反，混用会把「没采集」显示成「一切正常」。")


(defvar-local el-chronos-report--current-range nil
  "报告 buffer 对应的当前时间范围，供 `revert-buffer' 复用。")

;;; 报告期间抑制自观测阻塞
;;
;; 报告是重查询（首次 `el-chronos-report' 要加载 org + 跑 13 个 analysis 查询，实测约
;; 2.7s），会被 1s 心跳记成一条 `block' 事件 —— 观测者在观测自己，属假阳性。抑制依赖
;; 两个**采集层**变量，本文件只声明 + 在重查询期间绑定，读取方在 `el-chronos-collect'：
;;
;; - `el-chronos-collect--suppress-block-p'：collect 侧心跳用 `bound-and-true-p' 读取，
;;   非 nil 即跳过阻塞判定。跨模块 `let' 绑定未声明变量会 `void-variable'，故此处先
;;   `defvar' 声明（与 collect 侧同名同义，重复声明无副作用）。
;; - `el-chronos-collect--last-heartbeat'：collect 侧的心跳基线，重查询结束后由本文件
;;   重设（原因见 `el-chronos-report--without-block-events' 的第 3 层说明）。

(defvar el-chronos-collect--suppress-block-p nil
  "非 nil 时采集层心跳跳过阻塞判定。
由报告层在重查询（报告 / 周报 / 导出）期间 `let' 绑定为 t；**读取方在
`el-chronos-collect'（心跳里 `bound-and-true-p' 判断并推进基线）**，报告层本身不读它。
此处仅声明以避免跨模块 `let' 绑定未声明变量报 `void-variable'；与 collect 侧同名同义，
重复声明无副作用。")

(defvar el-chronos-collect--last-heartbeat nil
  "上一次心跳的实际触发时刻（`float-time'），采集层持有。
报告层只在一个场合写它：重查询结束后重设基线，避免「报告耗时」被下一次心跳补算成阻塞
（主线程被占住期间心跳 timer 不会运行，见 `el-chronos-report--without-block-events'）。")

(defconst el-chronos-report--suppress-block-threshold-ms 60000
  "报告期间临时抬高的阻塞阈值（毫秒），作为抑制变量的兜底：
即使 collect 侧尚未读取 `el-chronos-collect--suppress-block-p'，60s 也足够覆盖一次报告。")

(defmacro el-chronos-report--without-block-events (&rest body)
  "在 BODY 执行期间抑制采集层把「报告生成耗时」记成阻塞事件，返回 BODY 的值。

三层保护（缺一不可）：

1. 绑定 `el-chronos-collect--suppress-block-p' 为 t —— 采集层心跳据此直接跳过判定；
2. 把 `el-chronos-block-threshold-ms' 临时抬到
   `el-chronos-report--suppress-block-threshold-ms'（60s）—— 兜住「抑制变量还没被
   采集层读取」的过渡期，以及 BODY 内部偶发让出主线程（如 `read-file-name'）时的心跳；
3. 收尾把 `el-chronos-collect--last-heartbeat' 重设为当前时刻 —— 关键一步：主线程被
   BODY 占住时心跳 timer 根本不会运行，`let' 绑定在 BODY 返回时就已解除，心跳是在**之后**
   才补跑、看到整段 gap 的。只做 1、2 两层拦不住这一次补跑，必须重置基线。

代价：报告期间恰好发生的**真实**阻塞也不会被记录。这是有意取舍 —— 报告是用户主动触发的
重查询，其耗时属预期行为，不该混进「待排查的卡顿」里。

注意：drift 的抑制**完全依赖** `el-chronos-collect--suppress-block-p' 这一道门，
没有像 block 那样的「临时抬高阈值」兜底层（抬 block 阈值对 drift 无效）。
若将来删改这道门，drift 会立即产生假阳性。"
  (declare (indent 0) (debug t))
  `(let ((el-chronos-collect--suppress-block-p t)
         (el-chronos-block-threshold-ms el-chronos-report--suppress-block-threshold-ms))
     (unwind-protect
         (progn ,@body)
       (setq el-chronos-collect--last-heartbeat (float-time)))))

(defun el-chronos-report--ms->human (ms)
  "把毫秒 MS 格式化为文本（<1000 用 ms，否则用 s）；非数字返回 \"-\"。"
  (cond ((not (numberp ms)) "-")
        ((< (abs (float ms)) 1000.0) (format "%.0f ms" (float ms)))
        (t (format "%.2f s" (/ (float ms) 1000.0)))))
(defun el-chronos-report--bytes->human (bytes)
  "把字节数 BYTES 格式化为 B / KB / MB / GB；非数字返回 \"-\"。"
  (cond ((not (numberp bytes)) "-")
        ((< (float bytes) 1024.0) (format "%.0f B" (float bytes)))
        ((< (float bytes) 1048576.0) (format "%.1f KB" (/ (float bytes) 1024.0)))
        ((< (float bytes) 1073741824.0) (format "%.2f MB" (/ (float bytes) 1048576.0)))
        (t (format "%.2f GB" (/ (float bytes) 1073741824.0)))))
(defun el-chronos-report--num (value)
  "把数字 VALUE 格式化为整数文本；非数字返回 \"-\"。"
  (if (numberp value) (format "%d" (round value)) "-"))
(defun el-chronos-report--str (value)
  "把 VALUE 转成展示用字符串；nil 或空串返回 \"-\"。"
  (let ((text (and value (format "%s" value))))
    (if (or (null text) (string-empty-p text)) "-" text)))
(defun el-chronos-report--pct (value)
  "把百分比数值 VALUE 格式化为 \"12.3%\"；非数字返回 \"-\"。"
  (if (numberp value) (format "%.1f%%" (float value)) "-"))
(defun el-chronos-report--digest (value)
  "把 VALUE 截成前 8 个字符用于展示（提交号 / 配置指纹）；nil 或空串返回 \"-\"。
短于 8 个字符时原样返回 —— 只截不补，补零会伪造出不存在的长度。"
  (let ((text (and value (format "%s" value))))
    (if (or (null text) (string-empty-p text))
        "-"
      (substring text 0 (min 8 (length text))))))

(defun el-chronos-report--time (ms)
  "把 epoch 毫秒 MS 格式化为本地时间；非数字返回 \"-\"。"
  (if (numberp ms) (format-time-string "%Y-%m-%d %H:%M:%S" (/ (float ms) 1000.0)) "-"))

(defun el-chronos-report--days (range)
  "把 RANGE 换算成天数（用于标题）；无法判断时按 7 天处理。"
  (or (alist-get range el-chronos-report--range-alist)
      (if (and (consp range) (numberp (car range)) (numberp (cdr range)))
          (max 1 (round (/ (float (- (cdr range) (car range))) 86400000.0))) 7)))

(defun el-chronos-report--stack-text (stack)
  "把栈列表 STACK 渲染成单行文本（自 leaf 起最多 `--stack-frames' 帧）。"
  (let ((frames (and (listp stack) (cl-subseq stack 0 (min el-chronos-report--stack-frames
                                                          (length stack))))))
    (if frames (mapconcat #'el-chronos-report--str frames " ← ") "-")))

(defun el-chronos-report--plist->text (plist)
  "把 PLIST 渲染成多行 `- key：value' 文本；空时返回 \"-\"。"
  (if (null plist) "-"
    (cl-loop for (key value) on plist by #'cddr concat
             (format "- %s：%s\n" (string-remove-prefix ":" (format "%s" key))
                     (el-chronos-report--str value)))))

(defun el-chronos-report--cell (row key kind)
  "取 ROW 的 KEY 值并按 KIND 格式化：`str' `num' `ms' `pct' `time' `stack' `bytes' `raw'。"
  (let ((value (plist-get row key)))
    (pcase kind
      ('str (el-chronos-report--str value)) ('num (el-chronos-report--num value))
      ('ms (el-chronos-report--ms->human value)) ('pct (el-chronos-report--pct value))
      ('time (el-chronos-report--time value)) ('stack (el-chronos-report--stack-text value))
      ('bytes (el-chronos-report--bytes->human value)) (_ value))))

(defun el-chronos-report--rows (rows keys kinds)
  "把 ROWS（plist 列表）按 KEYS 与 KINDS 逐列格式化；ROWS 为 nil 时返回 nil。"
  (cl-loop for row in rows
           collect (cl-loop for key in keys for kind in kinds
                            collect (el-chronos-report--cell row key kind))))

(defun el-chronos-report--table (headers rows)
  "由 HEADERS 与 ROWS（字符串列表的列表）生成 org 表格；ROWS 为空返回 `（无数据）'。"
  (if (null rows)
      (concat el-chronos-report--empty "\n")
    (concat "| " (mapconcat #'el-chronos-report--str headers " | ") " |\n"
            "|" (mapconcat (lambda (_header) "---") headers "|") "|\n"
            (mapconcat (lambda (row)
                         (concat "| " (mapconcat #'el-chronos-report--str row " | ") " |\n"))
                       rows ""))))

(defun el-chronos-report--table-section (title headers rows)
  "渲染标题为 TITLE 的 org 节，正文是 HEADERS/ROWS 组成的表格。"
  (concat (format "* %s\n" title) (el-chronos-report--table headers rows) "\n"))

(defun el-chronos-report--file-size (file)
  "返回文件 FILE 的字节数；取不到时返回 0。"
  (condition-case nil (or (file-attribute-size (file-attributes file)) 0) (error 0)))
(defun el-chronos-report--read-range ()
  "交互读取时间范围符号，默认 `7d'。"
  (intern (completing-read "时间范围: " '("1d" "7d" "30d") nil t nil nil "7d")))

(defun el-chronos-report--org-buffer (name content)
  "创建或复用 NAME buffer，写入 CONTENT，切 `org-mode' 并置只读。"
  (let ((buffer (get-buffer-create name)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t)) (erase-buffer) (insert content))
      (unless (eq major-mode 'org-mode) (org-mode))
      (read-only-mode 1) (goto-char (point-min)))
    buffer))

(defun el-chronos-report--section-overview (overview)
  "渲染「概览」节；OVERVIEW 为 `el-chronos-analysis-overview' 的结果或 nil。
命令、样本、会话都为 0（空库）时输出 `（无数据）'。"
  (let* ((get (lambda (key) (and overview (plist-get overview key))))
         (commands (funcall get :commands)) (samples (funcall get :samples))
         (sessions (funcall get :sessions)))
    (concat
     "* 概览\n"
     (if (and (numberp commands) (zerop commands) (numberp samples) (zerop samples)
              (numberp sessions) (zerop sessions))
         (concat el-chronos-report--empty "\n\n")
       (concat
        (cl-loop for (label key kind) in
                 '(("命令数" :commands num) ("阻塞总时长" :blocked-ms ms)
                   ("慢命令数" :slow-commands num) ("采样样本数" :samples num)
                   ("数据库大小" :db-size bytes) ("会话数" :sessions num)
                   ("最近启动耗时" :startup-ms ms))
                 concat (format "- %s：%s\n" label
                                (el-chronos-report--cell overview key kind)))
        "\n")))))

(defun el-chronos-report--gc-rows (trend)
  "把 `el-chronos-analysis-gc-trend' 的结果 TREND 转成「GC 与内存」表格行。
取最近 `el-chronos-report--gc-rows' 个桶；TREND 为 nil、无桶、或全部桶的
`gc-count' / `gc-ms' 都是 0 时返回 nil（由 `el-chronos-report--section-gc' 渲染降级
说明）。全 0 也算「无可展示数据」：会话首个采样窗口只建基线、按 0 差值入库，把整表 0
铺出来只会误导用户以为「一直在 GC」。"
  (let ((items (and trend (plist-get trend :buckets))))
    (when (and items
               (not (cl-every (lambda (i)
                                (and (zerop (or (plist-get i :gc-count) 0))
                                     (zerop (or (plist-get i :gc-ms) 0))))
                              items)))
      (el-chronos-report--rows
       (last items (min el-chronos-report--gc-rows (length items)))
       '(:bucket :gc-count :gc-ms :heap-bytes) '(time num ms bytes)))))

(defun el-chronos-report--section-gc (trend)
  "渲染「GC 与内存」节；TREND 为 `el-chronos-analysis-gc-trend' 的结果或 nil。
表头 `时间' / `GC 次数' / `GC 耗时' / `内存'，其中内存无样本渲染为 \"-\"。
无数据时输出一行 `el-chronos-report--gc-degrade' 说明 —— 按 I11 降级必须可见，
不得静默省略整节。"
  (if-let* ((rows (el-chronos-report--gc-rows trend)))
      (el-chronos-report--table-section
       "GC 与内存" '("时间" "GC 次数" "GC 耗时" "内存") rows)
    (concat "* GC 与内存\n" el-chronos-report--gc-degrade "\n\n")))

(defun el-chronos-report--section-startup (breakdown)
  "渲染「启动分解」节；BREAKDOWN 为 `el-chronos-analysis-startup-breakdown' 的结果或 nil。
标题形如 `启动分解（自 mode 启动起 X ms / 总 Y ms）'，其中 X 取 `mode-start' 锚点、
Y 取会话的 `startup_ms'；任一段缺失时对应位置显示 \"-\" 并在正文给出降级说明。

正文两张表：① 阶段锚点（`阶段' / `耗时'，固定顺序 mode-start → after-init → startup →
first-idle，缺的跳过）；② 包加载 TOP（`包' / `耗时'，按耗时降序取前
`el-chronos-report--startup-load-rows' 条）。

**覆盖范围必须显式标注**（计划设计 7 处置 ①）：包加载耗时是 `after-load-functions' 相邻
回调的时间差，属**近似归因**；且只覆盖 mode 启动之后发生的 load。用户通常在 init 末尾才
启用 mode，此时只有 `mode-start' 一个锚点 —— 这张表不能冒充「完整启动剖析」。
无任何启动数据时整节走 `el-chronos-report--startup-degrade'（I11：不省略整节）。"
  (let* ((session (and breakdown (plist-get breakdown :session-id)))
         (phases (and breakdown (plist-get breakdown :phases)))
         (loads (and breakdown (plist-get breakdown :loads)))
         (startup (and breakdown (plist-get breakdown :startup-ms)))
         (mode-start (cadr (assoc "mode-start" phases))))
    (if (null session)
        (concat "* 启动分解\n" el-chronos-report--startup-degrade "\n\n")
      (concat
       (format "* 启动分解（自 mode 启动起 %s / 总 %s）\n"
               (el-chronos-report--ms->human mode-start)
               (el-chronos-report--ms->human startup))
       (if (numberp startup) "" (concat el-chronos-report--startup-total-degrade "\n"))
       "阶段锚点：\n"
       (if phases
           (el-chronos-report--table
            '("阶段" "耗时")
            (cl-loop for (phase ms) in phases
                     collect (list (el-chronos-report--str phase)
                                   (el-chronos-report--ms->human ms))))
         (concat el-chronos-report--startup-phases-degrade "\n"))
       (format "包加载 TOP（前 %d）：\n" el-chronos-report--startup-load-rows)
       (if loads
           (el-chronos-report--table
            '("包" "耗时")
            (cl-loop for (library ms) in
                     (last loads (min el-chronos-report--startup-load-rows (length loads)))
                     collect (list (el-chronos-report--str library)
                                   (el-chronos-report--ms->human ms))))
         (concat el-chronos-report--startup-loads-degrade "\n"))
       "\n"))))

(defun el-chronos-report--section-health (health)
  "渲染「采集健康」节；HEALTH 为 `el-chronos-analysis-health' 的结果或 nil。
`指标' / `值' 两列：丢弃命令、丢弃事件、flush 失败、flush 次数、flush 平均耗时、
采样窗口丢失。

四个分支（I11：任何分支都不省略整节）：
① HEALTH 为 nil（查询失败）→ 空表 → `（无数据）'；
② `:rows' 为 0（窗口内 `hourly_health' 一行都没有）→「本期无采集数据」——
   **不许**落到 `:ok-p' 分支：analysis 层在无数据时同样给 `:ok-p' 为 t，
   照抄会显示「本期无采集异常」，把「没采集」读成「一切正常」；
③ `:rows' 非 0 且 `:ok-p' 为 t → 只给一行「本期无采集异常」，括号里带 flush 次数与
   平均耗时 —— 它们是正常运转的度量，「无异常」不等于「无信息」；
④ 否则渲染完整指标表。"
  (let ((rows (and health (plist-get health :rows)))
        (ok (and health (plist-get health :ok-p)))
        (value (lambda (key) (and health (plist-get health key)))))
    (cond
     ((null health) (el-chronos-report--table-section "采集健康" '("指标" "值") nil))
     ((and (numberp rows) (zerop rows))
      (concat "* 采集健康\n" el-chronos-report--health-no-data "\n\n"))
     (ok (concat "* 采集健康\n"
                 (if (> (or (funcall value :flush-count) 0) 0)
                     (format "本期无采集异常（flush %s 次，平均 %s）\n\n"
                             (el-chronos-report--num (funcall value :flush-count))
                             (el-chronos-report--ms->human (funcall value :flush-avg-ms)))
                   "本期无采集异常（本期无 flush 记录）\n\n")))
     (t (el-chronos-report--table-section
         "采集健康" '("指标" "值")
         (list (list "丢弃命令" (el-chronos-report--num (funcall value :dropped-commands)))
               (list "丢弃事件" (el-chronos-report--num (funcall value :dropped-events)))
               (list "flush 失败" (el-chronos-report--num (funcall value :flush-failures)))
               (list "flush 次数" (el-chronos-report--num (funcall value :flush-count)))
               (list "flush 平均耗时"
                     (el-chronos-report--ms->human (funcall value :flush-avg-ms)))
               (list "采样窗口丢失" (el-chronos-report--num (funcall value :sample-misses)))))))))

(defun el-chronos-report--section-config (history)
  "渲染「配置变更」节；HISTORY 为 `el-chronos-analysis-config-history' 的结果或 nil。
表头 `会话启动时间' / `提交' / `配置指纹' / `变化'：`git-head' 与 `config-sig' 各显示前
8 个字符（完整哈希在表格里没有可读性），`:changed' 为 t 时「变化」列显示 `✓'，
首个会话与无变化会话显示 \"-\"（首个会话无从比较，不能算「没变化」）。
`:sessions' 为空或无 HISTORY 时走 `el-chronos-report--config-degrade'（I11：不省略整节）。"
  (let ((sessions (and history (plist-get history :sessions))))
    (if (null sessions)
        (concat "* 配置变更\n" el-chronos-report--config-degrade "\n\n")
      (el-chronos-report--table-section
       "配置变更" '("会话启动时间" "提交" "配置指纹" "变化")
       (cl-loop for item in sessions
                collect (list (el-chronos-report--time (plist-get item :started-at))
                              (el-chronos-report--digest (plist-get item :git-head))
                              (el-chronos-report--digest (plist-get item :config-sig))
                              (if (plist-get item :changed) "✓" "-")))))))


(defun el-chronos-report--drift-line (drift)
  "渲染「命令外停转」汇总行；DRIFT 为 `el-chronos-analysis-drift-trend' 的结果或 nil。
返回以 `- ' 开头、以换行结尾的单行文本，形如 `- 命令外停转（500–2000 ms）：本期 37 次，
累计 24.10 s，最坏 1.82 s（累计与最坏为高估值…；命令内停转见「慢命令」节，两者不可相加）'。
区间上下界分别取 `el-chronos-drift-threshold-ms' 与 `el-chronos-block-threshold-ms'，
高估上界取 `el-chronos-heartbeat-seconds' 换算的毫秒 —— 三个都是可调 defcustom，写死会
与实际判定脱节。

三处措辞口径（不可删改，这是本改动最容易被误读的地方）：
① 必须带「命令外」限定：`hourly_drift' 只记命令之外的停转，`commands' 覆盖命令内部，
   两者是互补集合，**相加会重复计数**；
② 必须标注高估：单次时长以「发现时距上次心跳基线的间隔」计时，每次最多多算一个心跳间隔；
③ 无数据时给可见降级文案（I11），且降级文案同样带「命令内停转见慢命令」的指引 ——
   否则用户会以为「命令外的卡顿也没被记录」。"
  (let* ((drift-ms (or (bound-and-true-p el-chronos-drift-threshold-ms) 500))
         (block-ms (or (bound-and-true-p el-chronos-block-threshold-ms) 2000))
         (heartbeat-ms (* 1000.0 (or (bound-and-true-p el-chronos-heartbeat-seconds) 0.25)))
         (band (format "%s–%s ms" (el-chronos-report--num drift-ms)
                       (el-chronos-report--num block-ms)))
         (count (or (plist-get drift :drift-total) 0)))
    (if (or (null drift) (not (numberp count)) (zerop count))
        (format "- 命令外停转（%s）：本期无记录（命令内停转见「慢命令」节；两者不可相加）\n"
                band)
      (format (concat "- 命令外停转（%s）：本期 %s 次，累计 %s，最坏 %s"
                      "（累计与最坏为高估值，每次最多多算一个心跳间隔 %.0f ms；"
                      "命令内停转见「慢命令」节，两者不可相加）\n")
              band (el-chronos-report--num count)
              (el-chronos-report--ms->human (plist-get drift :ms-total))
              (el-chronos-report--ms->human (plist-get drift :slowest-ms))
              heartbeat-ms))))

(defun el-chronos-report--usage-rows (range)
  "构造「用法 TOP」行（plist `:name' `:count' `:total-ms'）。
次数与总耗时都取自 `hourly_usage' 的 command 维度热力图（前 20 个命令跨桶求和），
`:total-ms' 汇总热力图的 `:duration-ms'；该命令无有效时长数据时为 nil（渲染为 \"-\"）。"
  (let ((totals (make-hash-table :test #'equal))
        (counts (make-hash-table :test #'equal)) (order nil))
    (dolist (row (el-chronos-analysis-heatmap range 20))
      (let ((name (plist-get row :command))
            (duration (plist-get row :duration-ms)))
        (unless (gethash name counts) (push name order))
        (puthash name (+ (or (gethash name counts) 0) (or (plist-get row :count) 0)) counts)
        (when-let* ((ms (and (numberp duration) (> duration 0) duration)))
          (puthash name (+ (or (gethash name totals) 0) ms) totals))))
    (cl-loop for name in (cl-sort order #'> :key (lambda (n) (gethash n counts)))
             collect (list :name name :count (gethash name counts)
                           :total-ms (gethash name totals)))))

(defun el-chronos-report--content (range)
  "生成 RANGE 的 org 报告全文（字符串）。任一 analysis 查询返回 nil 时按空数据渲染。"
  (let* ((trend (el-chronos-analysis-trend range))
         ;; GC 与内存趋势单独一节：堆大小是瞬时量、口径与 `trend' 的计数型指标不同，
         ;; 混进「趋势」表会既撑宽表格又混淆单位，因此拆成紧随其后的独立节。
         (gc-trend (el-chronos-analysis-gc-trend range))
         (blocking (cl-sort (copy-sequence (el-chronos-analysis-blocking-events
                                            range el-chronos-report--blocking-rows))
                            #'> :key (lambda (r) (or (plist-get r :ts) 0))))
         ;; 「命令外停转」趋势：不算独立一节，只在「阻塞事件」节内加一行汇总（见下）
         (drift (el-chronos-analysis-drift-trend range))
         (sessions (el-chronos-analysis-sessions range))
         ;; 三个「本期健康/环境」视角的节：都在「GC 与内存」之后、「阻塞事件」之前。
         ;; 与趋势族相邻的理由：它们回答的是「这台机器这个时期的状态如何」，而不是单点明细。
         (startup (el-chronos-analysis-startup-breakdown nil))
         (health (el-chronos-analysis-health range))
         (config-history (el-chronos-analysis-config-history range)))
    (concat
     (format "#+TITLE: el-chronos 报告（近 %d 天）\n" (el-chronos-report--days range))
     (format "#+DATE: %s\n" (format-time-string "%Y-%m-%dT%H:%M:%S%z"))
     (format "#+GENERATED: %s\n\n" (format-time-string "%Y-%m-%d %H:%M:%S"))
     (el-chronos-report--section-overview (el-chronos-analysis-overview range))
     (el-chronos-report--table-section
      "慢命令 TOP" '("命令" "次数" "总耗时" "最大" "平均" "中断数")
      (el-chronos-report--rows (el-chronos-analysis-slow-commands range 20)
       '(:name :count :total-ms :max-ms :avg-ms :aborted) '(str num ms ms ms num)))
     (el-chronos-report--table-section
      "热点函数 TOP" '("函数" "包" "self" "样本" "占比")
      (el-chronos-report--rows (el-chronos-analysis-top-functions range 20)
       '(:function :package :self-ms :samples :pct) '(str str ms num pct)))
     (el-chronos-report--table-section
      "包归因" '("包" "self" "占比")
      (el-chronos-report--rows (el-chronos-analysis-package-breakdown range nil)
       '(:package :self-ms :pct) '(str ms pct)))
     (el-chronos-report--table-section
      "趋势" '("小时" "样本" "慢命令" "阻塞")
      (el-chronos-report--rows (last trend (min el-chronos-report--trend-rows (length trend)))
       '(:bucket :samples :slow-commands :blocked) '(time num num num)))
     ;; 紧随「趋势」：同属时间桶视角，用户从「慢/阻塞」往下看自然想知道「是不是内存涨了」
     (el-chronos-report--section-gc gc-trend)
     ;; 启动分解 → 采集健康 → 配置变更：三节都是「本期健康 / 环境」类视角，紧随趋势族
     (el-chronos-report--section-startup startup)
     (el-chronos-report--section-health health)
     (el-chronos-report--section-config config-history)
     ;; 「阻塞事件」节内先给一行「命令外停转」汇总，再列 block 明细：两者同属「命令之外的
     ;; 停转」，只有放在一起读者才看得到完整图景（drift 覆盖 [500ms, 2000ms) 区间，block
     ;; 覆盖 ≥2000ms）。**刻意不新增节**：报告已有 14 节，再拆一节只增加阅读负担，还会连带
     ;; 改一堆按节数断言的老用例。drift 摘要是独立信息 —— 即使下面的表格因无数据降级为
     ;; `（无数据）'，这一行也必须出现（I11：可见降级）。
     (concat
      "* 阻塞事件\n"
      (el-chronos-report--drift-line drift)
      (el-chronos-report--table
       '("时间" "时长" "命令" "mode" "project")
       (el-chronos-report--rows
        (cl-subseq blocking 0 (min el-chronos-report--blocking-rows (length blocking)))
        '(:ts :duration-ms :command :mode :project) '(time ms str str str)))
      "\n")
     (el-chronos-report--table-section
      ;; 回归窗口由 `el-chronos-regression-window-days' 决定、与显示范围无关，
      ;; 标题必须动态标注真实天数，否则容易让人误以为是「近 RANGE 天」判出来的。
      (format "回归（近 %d 天）"
              (or (bound-and-true-p el-chronos-regression-window-days) 7))
      '("函数" "当前" "之前" "增长" "样本")
      (cl-loop for r in (el-chronos-analysis-regressions range 20) collect
               (list (el-chronos-report--str (plist-get r :function))
                     (el-chronos-report--ms->human (plist-get r :current-ms))
                     (el-chronos-report--ms->human (plist-get r :previous-ms))
                     (if (numberp (plist-get r :growth))
                         (format "+%.1f%%" (* 100.0 (plist-get r :growth))) "-")
                     (format "%s/%s" (el-chronos-report--num (plist-get r :current-samples))
                             (el-chronos-report--num (plist-get r :previous-samples))))))
     (el-chronos-report--table-section
      "用法 TOP" '("命令" "次数" "总耗时")
      (el-chronos-report--rows (el-chronos-report--usage-rows range)
                               '(:name :count :total-ms) '(str num ms)))
     (el-chronos-report--table-section
      "会话" '("开始时间" "启动耗时" "版本" "主机")
      (el-chronos-report--rows
       (cl-subseq sessions 0 (min el-chronos-report--session-rows (length sessions)))
       '(:started-at :startup-ms :emacs-version :host) '(time ms str str)))
     (el-chronos-report--table-section
      "调用栈 TOP" '("栈（自 leaf 起）" "样本" "占比")
      (el-chronos-report--rows (el-chronos-analysis-stacks range el-chronos-report--stack-rows)
                               '(:stack :samples :pct) '(stack num pct))))))

(defun el-chronos-report (&optional range)
  "生成（或刷新）`*el-chronos-report*' org 报告 buffer 并显示。
RANGE 取 `1d' / `7d' / `30d'，省略时用 `7d'，交互时用 `completing-read' 选择。
buffer 内 `g' 重新生成、`q' 关闭窗口；返回报告 buffer。
生成期间抑制采集层的阻塞判定（见 `el-chronos-report--without-block-events'），
报告耗时不会被记成 `block' 事件。"
  (interactive (list (el-chronos-report--read-range)))
  (el-chronos-report--without-block-events
    (let* ((range (or range el-chronos-report--default-range))
           (buffer (el-chronos-report--org-buffer el-chronos-report--buffer-name
                                                  (el-chronos-report--content range))))
      (with-current-buffer buffer
        (setq-local el-chronos-report--current-range range)
        (setq-local revert-buffer-function
                    (lambda (_ignore-auto _noconfirm)
                      (el-chronos-report el-chronos-report--current-range)))
        (local-set-key (kbd "g") #'revert-buffer) (local-set-key (kbd "q") #'quit-window))
      (display-buffer buffer)
      buffer)))

(defun el-chronos-weekly-report (&optional file)
  "把近 7 天的 org 报告写入 FILE（默认 `chronos-weekly.org' 落在状态目录）。
目录不存在时自动创建；文件头带 `#+FILETAGS: :chronos:'；写入后 message 路径。
写入期间抑制采集层的阻塞判定（同 `el-chronos-report'）。返回写入的文件绝对路径。"
  (interactive (list (read-file-name "周报输出文件: "
                                     (expand-file-name el-chronos-report--state-subdir
                                                       user-emacs-directory)
                                     nil nil el-chronos-report--weekly-file-name)))
  (let* ((file (if (and (stringp file) (not (string-empty-p file)))
                   (expand-file-name file)
                 (expand-file-name (concat el-chronos-report--state-subdir
                                           el-chronos-report--weekly-file-name)
                                   user-emacs-directory)))
         (content (el-chronos-report--without-block-events
                    (concat "#+FILETAGS: :chronos:\n" (el-chronos-report--content '7d)))))
    (when-let* ((dir (file-name-directory file))) (make-directory dir t))
    (with-temp-file file (insert content))
    (message "周报已写入 %s（%d 字节）" file (el-chronos-report--file-size file))
    file))

(defun el-chronos-report--csv-field (value)
  "把 VALUE 转成 CSV 字段：含逗号、引号或换行时加引号并转义其中的引号。"
  (let ((text (cond ((null value) "") ((stringp value) value) (t (format "%s" value)))))
    (if (string-match-p "[,\"\n\r]" text)
        (concat "\"" (replace-regexp-in-string "\"" "\"\"" text t t) "\"")
      text)))

(defun el-chronos-report--csv-block (name headers rows)
  "生成一个 CSV 区块：`# section: NAME' 注释行 + 表头 + ROWS。
ROWS 输出原始值（不做人类可读格式化），便于下游解析。"
  (concat (format "# section: %s\n" name)
          (mapconcat #'el-chronos-report--csv-field headers ",") "\n"
          (mapconcat (lambda (row)
                       (concat (mapconcat #'el-chronos-report--csv-field row ",") "\n"))
                     rows "")))

(defconst el-chronos-report--csv-sections
  '(("slow-commands" ("name" "count" "total_ms" "max_ms" "avg_ms" "aborted")
     el-chronos-analysis-slow-commands 100 (:name :count :total-ms :max-ms :avg-ms :aborted))
    ("top-functions" ("function" "package" "file" "self_ms" "samples" "pct")
     el-chronos-analysis-top-functions 100 (:function :package :file :self-ms :samples :pct))
    ("packages" ("package" "self_ms" "pct")
     el-chronos-analysis-package-breakdown nil (:package :self-ms :pct))
    ("trend" ("bucket_ms" "samples" "slow_commands" "blocked")
     el-chronos-analysis-trend nil (:bucket :samples :slow-commands :blocked))
    ("blocking-events" ("id" "ts_ms" "duration_ms" "kind" "command" "mode" "project")
     el-chronos-analysis-blocking-events 100 (:id :ts :duration-ms :kind :command :mode :project)))
  "CSV 导出的 5 个区块：(区块名 表头 查询函数 LIMIT 字段)。")

(defun el-chronos-report--csv-startup (breakdown)
  "生成「启动分解」CSV 区块（`# section: startup'）：阶段锚点与包加载 TOP 合成一张表。
两段用 `kind' 列区分（`phase' / `load'），其余列是 `name' 与 `ms'：合成一张表而不是两个
同名区块，是为了让下游只靠 `# section:' 就能定位区块（同名区块会让人以为解析错了）。
包加载按 `el-chronos-report--startup-load-rows' 截断，与 org 报告的可读性口径一致；
BREAKDOWN 为 nil 时只输出表头（无数据不省略区块，与 org 报告的 I11 一致）。"
  (let* ((phases (and breakdown (plist-get breakdown :phases)))
         (loads (and breakdown (plist-get breakdown :loads))))
    (el-chronos-report--csv-block
     "startup" '("kind" "name" "ms")
     (append
      (cl-loop for (phase ms) in phases collect (list "phase" phase ms))
      (cl-loop for (library ms) in
               (last loads (min el-chronos-report--startup-load-rows (length loads)))
               collect (list "load" library ms))))))

(defun el-chronos-report--csv-health (health)
  "生成「采集健康」CSV 区块（`# section: health'）：`metric' / `value' 两列的窄表。
键名沿用 `hourly_health.key' 的写法（snake_case），另加一行 `rows'（窗口内行数）——
导出件同样要能区分「没采集」与「没异常」，否则下游会重犯 org 报告曾犯的错（I11）。
HEALTH 为 nil（查询失败）时只输出表头。"
  (el-chronos-report--csv-block
   "health" '("metric" "value")
   (when health
     (list (list "dropped_commands" (plist-get health :dropped-commands))
           (list "dropped_events" (plist-get health :dropped-events))
           (list "flush_failures" (plist-get health :flush-failures))
           (list "flush_count" (plist-get health :flush-count))
           (list "flush_ms" (plist-get health :flush-ms))
           (list "flush_avg_ms" (plist-get health :flush-avg-ms))
           (list "sample_misses" (plist-get health :sample-misses))
           (list "rows" (plist-get health :rows))))))

(defun el-chronos-report--csv-config-history (history)
  "生成「配置变更」CSV 区块（`# section: config-history'）。
列：`session_id' / `started_at_ms' / `git_head' / `config_sig' / `changed'；两个哈希写
**完整值**（org 报告截 8 位只为排版，导出件要给下游做 join 与比对），`changed' 写
`1' / `0' 而不是空串 —— 空串与「首会话无从比较」无法区分。
HISTORY 为 nil 时只输出表头。"
  (el-chronos-report--csv-block
   "config-history" '("session_id" "started_at_ms" "git_head" "config_sig" "changed")
   (cl-loop for item in (and history (plist-get history :sessions))
            collect (list (plist-get item :id)
                          (plist-get item :started-at)
                          (plist-get item :git-head)
                          (plist-get item :config-sig)
                          (if (plist-get item :changed) "1" "0")))))

(defun el-chronos-report--csv-drift (drift)
  "生成「命令外停转」CSV 区块（`# section: drift'）。
列：`bucket_ms' / `count' / `total_ms' / `max_ms'，行取自 analysis drift 趋势的桶列表，
字段保持原始值（毫秒、计数）。

两处口径与 org 报告同源，不得省略：
① 本区块只含**命令之外**的停转，与 `commands' / `blocking-events' 的耗时不可相加；
② `total_ms' / `max_ms' 是高估值（每次最多多算一个心跳间隔）。
DRIFT 为 nil 或无桶时**只输出表头**（I11：无数据不省略区块，否则下游会误判成「这一版
根本没有 drift 能力」）。

区块位置固定在 CSV 末尾（config-history 之后）：report 与 web 两处内联实现的区块名与顺序
必须一致，`el-chronos-report-test-csv-sections-match-web' 会逐项比对。"
  (el-chronos-report--csv-block
   "drift" '("bucket_ms" "count" "total_ms" "max_ms")
   (el-chronos-report--rows (plist-get drift :buckets)
                            '(:bucket :count :total-ms :max-ms) '(raw raw raw raw))))

(defun el-chronos-report--csv-string (range)
  "生成 RANGE 的 CSV 全文：9 个区块用 `# section:' 注释行分隔；字段保持原始值。
前 5 个区块由 `el-chronos-report--csv-sections' 的通用规格生成（查询 → 行 → 列）；
后 4 个（startup / health / config-history / drift）返回结构不齐整 —— 启动分解是两段嵌套
列表、采集健康是扁平 plist、配置变更嵌在 `:sessions' 里、drift 的桶在 `:buckets' 键下，
且启动分解不吃 RANGE —— 各自手写区块生成函数，而不是硬塞进通用规格。
drift 放在末尾：它与 web 侧的同名区块必须**位置一致**（顺序也是被断言的不变量）。"
  (concat
   (mapconcat
    (lambda (spec)
      (let* ((keys (nth 4 spec))
             (items (funcall (nth 2 spec) range (nth 3 spec))))
        (el-chronos-report--csv-block (nth 0 spec) (nth 1 spec)
                                      (el-chronos-report--rows items keys
                                                               (make-list (length keys) 'raw)))))
    el-chronos-report--csv-sections "")
   (el-chronos-report--csv-startup (el-chronos-analysis-startup-breakdown nil))
   (el-chronos-report--csv-health (el-chronos-analysis-health range))
   (el-chronos-report--csv-config-history (el-chronos-analysis-config-history range))
   ;; 命令外停转（drift）：与 org 报告「阻塞事件」节内的那一行汇总同源
   (el-chronos-report--csv-drift (el-chronos-analysis-drift-trend range))))

(defun el-chronos-report--json-value (value)
  "把 VALUE 递归转成 `json-serialize' 友好形态。
nil 转 `:null'（否则会输出 `{}'），列表转 vector（否则会被当成 alist），plist 保持 plist。"
  (cond
   ((null value) :null)
   ((eq value t) t)
   ((vectorp value) (vconcat (mapcar #'el-chronos-report--json-value value)))
   ((consp value)
    (if (keywordp (car value))
        (cl-loop for (key item) on value by #'cddr
                 append (list key (el-chronos-report--json-value item)))
      (vconcat (mapcar #'el-chronos-report--json-value value))))
   (t value)))

(defun el-chronos-report--json-string (range)
  "生成 RANGE 的 JSON 全文（单个对象，含 overview 与各明细区块）。
键名沿用既有 snake_case 风格（`slow_commands' / `blocking_events'）；
三个新查询对应 `startup' / `health' / `config_history'；
`drift' 是「命令外停转」汇总（`bucket_span' / `total' / `ms_total' / `slowest_ms' /
`buckets'，窗口本身由外层 `range' / `days' 表达），**不可与 `slow_commands' 的耗时相加**。"
  (concat
   (json-serialize
    (el-chronos-report--json-value
     (list :range (format "%s" range) :days (el-chronos-report--days range)
           :generated_at (truncate (* 1000 (float-time)))
           :overview (el-chronos-analysis-overview range)
           :slow_commands (el-chronos-analysis-slow-commands range 100)
           :top_functions (el-chronos-analysis-top-functions range 100)
           :packages (el-chronos-analysis-package-breakdown range nil)
           :trend (el-chronos-analysis-trend range)
           :blocking_events (el-chronos-analysis-blocking-events range 100)
           ;; 命令外停转（drift）：analysis 的 `:range' 是 cons (START . END)，
           ;; `--json-value' 无法序列化 dotted pair（会对它调 mapcar 而报错），故这里只取
           ;; 标量与桶列表 —— 窗口本身已由外层的 `:range' / `:days' 表达，不必重复。
           ;; **不可与 `:slow_commands' / `:blocking_events' 的耗时相加**（互补集合）。
           :drift (let ((drift (el-chronos-analysis-drift-trend range)))
                    (list :bucket_span (plist-get drift :bucket-span)
                          :total (plist-get drift :drift-total)
                          :ms_total (plist-get drift :ms-total)
                          :slowest_ms (plist-get drift :slowest-ms)
                          :buckets (plist-get drift :buckets)))
           :regressions (el-chronos-analysis-regressions range 100)
           :usage (el-chronos-analysis-heatmap range 20)
           :sessions (el-chronos-analysis-sessions range)
           :stacks (el-chronos-analysis-stacks range 100)
           ;; 三个「本期健康 / 环境」视角查询，与 org 报告新增的三节同源
           :startup (el-chronos-analysis-startup-breakdown nil)
           :health (el-chronos-analysis-health range)
           :config_history (el-chronos-analysis-config-history range))))
   "\n"))

(defun el-chronos-export (format file &optional range)
  "把 RANGE 的数据导出到 FILE。
FORMAT 取 `csv'（多区块单文件，`# section:' 分隔）或 `json'（单个对象）；
RANGE 取 `1d' / `7d' / `30d'，省略时用 `7d'。目录不存在时自动创建；写入后
message 路径与字节数。返回写入的文件绝对路径。"
  (interactive
   (list (intern (completing-read "导出格式: " '("csv" "json") nil t nil nil "csv"))
         (read-file-name "导出文件: ") (el-chronos-report--read-range)))
  (let* ((file (expand-file-name (or file "")))
         (range (or range el-chronos-report--default-range))
         (content (el-chronos-report--without-block-events
                    (if (eq format 'json) (el-chronos-report--json-string range)
                      (el-chronos-report--csv-string range)))))
    (when-let* ((dir (file-name-directory file))) (make-directory dir t))
    (with-temp-file file (insert content))
    (message "已导出 %s（%d 字节）" file (el-chronos-report--file-size file))
    file))

(defun el-chronos-report--event-content (event)
  "生成单条慢事件 EVENT 的 org 详情文本（含完整栈与 context）。"
  (let ((id (el-chronos-report--num (plist-get event :id)))
        (stack (plist-get event :stack))
        (context (plist-get event :context)))
    (concat
     (format "#+TITLE: el-chronos 事件 #%s\n\n" id)
     (format "* 事件 #%s\n- 时间：%s\n- 时长：%s\n" id
             (el-chronos-report--time (plist-get event :ts))
             (el-chronos-report--ms->human (plist-get event :duration-ms)))
     (format "- 类型：%s\n- 命令：%s\n" (el-chronos-report--str (plist-get event :kind))
             (el-chronos-report--str (plist-get event :command)))
     (format "- mode：%s\n- project：%s\n\n" (el-chronos-report--str (plist-get context :mode))
             (el-chronos-report--str (plist-get context :project)))
     "* 调用栈\n"
     (if (null stack)
         (concat el-chronos-report--empty "\n")
       (cl-loop for frame in stack for index from 0
                concat (format "%d. %s\n" index (el-chronos-report--str frame))))
     "\n* context\n"
     (let ((text (el-chronos-report--plist->text context)))
       (if (string-empty-p text) (concat el-chronos-report--empty "\n") text)))))

(defun el-chronos-report--read-event-id ()
  "交互从近 7 天阻塞事件中选择一条，返回其 id；无事件时 `user-error'。"
  (let ((events (el-chronos-analysis-blocking-events '7d 20)))
    (unless events (user-error "没有可显示的阻塞事件"))
    (let* ((choices (cl-loop for e in events
                             collect (cons (format "#%s  %s  %s"
                                                   (el-chronos-report--num (plist-get e :id))
                                                   (el-chronos-report--ms->human
                                                    (plist-get e :duration-ms))
                                                   (el-chronos-report--str (plist-get e :command)))
                                           (plist-get e :id))))
           (choice (completing-read "阻塞事件: " choices nil t)))
      (when-let* ((id (cdr (assoc choice choices)))) id))))

(defun el-chronos-show-event (id)
  "在 `*el-chronos-event*' buffer 中展示慢事件 ID 的详情。
ID 不存在时 `user-error'；交互时从近 7 天阻塞事件里选一条。返回事件 buffer。"
  (interactive (list (el-chronos-report--read-event-id)))
  (let ((event (and (numberp id) (el-chronos-analysis-event id))))
    (unless event (user-error "事件 %s 不存在" id))
    (let ((buffer (el-chronos-report--org-buffer el-chronos-report--event-buffer-name
                                                 (el-chronos-report--event-content event))))
      (display-buffer buffer)
      buffer)))

;;; 单命令剖析（T11）
;;
;; 与报告其余部分的口径差异：报告查库（analysis），本节的证据来自「当场跑一次命令 +
;; 内置 C profiler 1ms 采样」，不依赖采集层是否在跑，也不改变任何采集行为。
;; 采样口径沿用 T5 的实测结论：`profiler-cpu-log' 返回 hash table（栈 vector → 样本数），
;; 栈里 `(aref stack 0)' 是 leaf（最近一次求值），末尾常有 nil 填充帧。

(defcustom el-chronos-profile-save nil
  "非 nil 时把单命令剖析结果写进 `slow_events'（`kind' 为 \"profile\"）并立即 flush。
默认 nil：剖析只产出报告、不落库。剖析样本是单条命令的 1ms 采样，与常规采集的窗口
口径不同，混进长期统计会污染趋势与回归判定，故做成显式选择。"
  :type 'boolean
  :group 'el-chronos)

(defconst el-chronos-profile--buffer-name "*el-chronos-profile*"
  "单命令剖析报告 buffer 名称。")
(defconst el-chronos-profile--interval-ns 1000000
  "单命令剖析的采样间隔（纳秒，即 1ms）。")
(defconst el-chronos-profile--top-functions 30
  "热点函数表最多展示条数。")
(defconst el-chronos-profile--top-stacks 10
  "调用链最多展示条数。")
(defconst el-chronos-profile--gc-warn-pct 20.0
  "GC 耗时占比超过该百分比时给出 `gc-cons-threshold' 建议。")
(defconst el-chronos-profile--idle-functions "eldoc\\|font-lock\\|jit-lock"
  "命中即建议调整 idle delay 的函数名正则。")

(defun el-chronos-profile--interval-ms ()
  "返回剖析采样间隔的毫秒数（I4：展示与库内都用毫秒）。"
  (/ (float el-chronos-profile--interval-ns) 1000000.0))

(defun el-chronos-profile--estimated-interval (samples elapsed-ms)
  "估算采样间隔（毫秒）：SAMPLES 个样本耗时 ELAPSED-MS 时反推每个样本的间隔。
共享已在运行的 profiler 时读不到它的真实间隔（`profiler-cpu-start' 无对应的读取接口），
只能用「样本数 / 耗时」反推（对 CPU 受限的命令足够准）；样本或耗时为 0 时回退默认间隔。"
  (if (and (numberp samples) (> samples 0) (numberp elapsed-ms) (> elapsed-ms 0))
      (max 0.001 (/ (float elapsed-ms) samples))
    (el-chronos-profile--interval-ms)))

(defun el-chronos-profile--frames (stack)
  "把采样栈 STACK（vector 或 list，leaf 在索引 0）转成自 leaf 起的函数列表。
尾部 nil 填充帧（profiler 的占位）被去掉；STACK 非序列时返回 nil。"
  (let ((frames (reverse (append stack nil))))
    (while (and frames (null (car frames))) (pop frames))
    (reverse frames)))

(defun el-chronos-profile--log->rows (log)
  "把 `profiler-cpu-log' 的 LOG 转成 `(STACK-VECTOR . COUNT)' 列表，按 COUNT 降序。
LOG 为 hash table（实测形态），同时兼容 `(STACK . COUNT)' 的 cons 列表；
LOG 为 nil 或形态不认识时返回 nil（空剖析按「无数据」渲染，不抛错）。"
  (let ((rows nil))
    (cond
     ((hash-table-p log)
      (maphash (lambda (stack count)
                 (when (and (vectorp stack) (numberp count) (> count 0))
                   (push (cons stack count) rows)))
               log))
     ((listp log)
      (dolist (entry log)
        (when (and (consp entry) (vectorp (car entry))
                   (numberp (cdr entry)) (> (cdr entry) 0))
          (push entry rows)))))
    (cl-sort rows #'> :key #'cdr)))

(defun el-chronos-profile--self-ranking (rows)
  "按 leaf 口径把 ROWS 聚合成 `(FUNCTION . COUNT)' 列表，按 COUNT 降序。
leaf 取 `(aref stack 0)'（T5 已实测口径，与 profiler 报告的自时间归属一致）。"
  (let ((table (make-hash-table :test #'eq)) (seen nil) (ranking nil))
    (dolist (row rows)
      (let ((leaf (car (el-chronos-profile--frames (car row)))))
        (when (symbolp leaf)
          (unless (gethash leaf table) (push leaf seen))
          (puthash leaf (+ (cdr row) (or (gethash leaf table) 0)) table))))
    (dolist (leaf seen)
      (push (cons leaf (gethash leaf table)) ranking))
    (cl-sort ranking #'> :key #'cdr)))

(defun el-chronos-profile--stack-json (frames)
  "把函数列表 FRAMES 序列化成与采集层一致的栈 JSON 字符串（函数名数组，leaf 在前）。
序列化失败返回 nil（该栈不参与聚合）。"
  (condition-case nil
      (json-serialize (vconcat (mapcar (lambda (frame) (format "%s" frame)) frames)))
    (error nil)))

(defun el-chronos-profile--json->frames (json)
  "把栈 JSON 字符串 JSON 解码成函数名列表（自 leaf 起）；解码失败返回 nil。"
  (condition-case nil
      (append (json-parse-string json :array-type 'list) nil)
    (error nil)))

(defun el-chronos-profile--stack-ranking (rows)
  "把 ROWS 按调用栈聚合成 `(STACK-JSON . COUNT)' 列表，按 COUNT 降序。
STACK-JSON 形态与 `hourly_stacks' 落库口径一致（函数名 JSON 数组，索引 0 为 leaf），
因此剖析里的栈可与库里已有栈直接比对。"
  (let ((table (make-hash-table :test #'equal)) (seen nil) (ranking nil))
    (dolist (row rows)
      (when-let* ((json (el-chronos-profile--stack-json
                         (el-chronos-profile--frames (car row)))))
        (unless (gethash json table) (push json seen))
        (puthash json (+ (cdr row) (or (gethash json table) 0)) table)))
    (dolist (json seen) (push (cons json (gethash json table)) ranking))
    (cl-sort ranking #'> :key #'cdr)))

(defun el-chronos-profile--package-of (function)
  "把 FUNCTION 归因到包/模块名；GC 伪函数返回 \"GC\"，归因失败返回 \"unknown\"。
GC 伪函数（`Automatic GC'）没有源码文件，直接走归因会得到 unknown 并误触发
TD-1 提示，故先按名字拦下（口径同 `el-chronos-analysis-package-breakdown'）。"
  (cond ((null function) el-chronos-analysis--unknown)
        ((equal (format "%s" function) el-chronos-analysis--gc-function)
         el-chronos-analysis--gc-label)
        (t (el-chronos-attrib-package function))))

(defun el-chronos-profile--package-ranking (rows)
  "把 ROWS 的 self 样本按包/模块聚合，返回 `(PACKAGE . COUNT)' 列表（COUNT 降序）。"
  (let ((table (make-hash-table :test #'equal)) (seen nil) (ranking nil))
    (dolist (entry (el-chronos-profile--self-ranking rows))
      (let ((package (el-chronos-profile--package-of (car entry))))
        (unless (gethash package table) (push package seen))
        (puthash package (+ (cdr entry) (or (gethash package table) 0)) table)))
    (dolist (package seen) (push (cons package (gethash package table)) ranking))
    (cl-sort ranking #'> :key #'cdr)))

(defun el-chronos-profile--pct (count total)
  "把 COUNT 换算成占 TOTAL 的百分比数值；TOTAL 非正数时返回 0.0。"
  (if (and (numberp total) (> total 0)) (* 100.0 (/ (float (or count 0)) total)) 0.0))

(defun el-chronos-profile--hot-section (rows samples interval)
  "渲染「热点函数」表：函数 | 包 | self(ms) | 样本 | 占比（self 降序，最多 30 行）。
INTERVAL 是折算 self 时间的每样本毫秒数。"
  (let* ((ranking (el-chronos-profile--self-ranking rows)))
    (el-chronos-report--table
     '("函数" "包" "self(ms)" "样本" "占比")
     (cl-loop for (function . count) in
              (cl-subseq ranking 0 (min el-chronos-profile--top-functions (length ranking)))
              collect (list (format "%s" function)
                            (el-chronos-profile--package-of function)
                            (el-chronos-report--ms->human (* count interval))
                            (el-chronos-report--num count)
                            (el-chronos-report--pct (el-chronos-profile--pct count samples)))))))

(defun el-chronos-profile--stack-section (rows)
  "渲染「调用链 TOP」节：栈（leaf 起）| 样本数，并附最热栈的缩进深度视图。"
  (let* ((ranking (el-chronos-profile--stack-ranking rows))
         (top (cl-subseq ranking 0 (min el-chronos-profile--top-stacks (length ranking))))
         (table (el-chronos-report--table
                 '("栈（leaf 起）" "样本数")
                 (cl-loop for (json . count) in top
                          collect (list (el-chronos-report--stack-text
                                         (el-chronos-profile--json->frames json))
                                        (el-chronos-report--num count)))))
         (hottest (and top (el-chronos-profile--json->frames (caar top)))))
    (concat "* 调用链 TOP\n" table "\n"
            (if (null hottest) ""
              (concat "最热栈的深度视图（root 在上，缩进表示深度）：\n#+begin_example\n"
                      (cl-loop for frame in (reverse hottest) for depth from 0
                               concat (format "%s%s\n" (make-string (* 2 depth) ?\s)
                                              frame))
                      "#+end_example\n\n")))))

(defun el-chronos-profile--package-section (rows samples interval)
  "渲染「归因」节：按包/模块汇总 self 样本（包 | self(ms) | 占比）。
INTERVAL 是折算 self 时间的每样本毫秒数。"
  (el-chronos-report--table
   '("包" "self(ms)" "占比")
   (cl-loop for (package . count) in (el-chronos-profile--package-ranking rows)
            collect (list package
                          (el-chronos-report--ms->human (* count interval))
                          (el-chronos-report--pct (el-chronos-profile--pct count samples))))))

(defun el-chronos-profile--suggestions (rows gc-pct)
  "按规则生成「优化建议」文本行列表。
规则（顺序即优先级，命中即止）：归因失败（TOP 包 unknown）→ 排查已删包/临时 snippet（TD-1 已关闭）；
TOP 函数属 eldoc/font-lock/jit-lock → 调 idle delay；GC 占比超阈值 → 调
`gc-cons-threshold'；否则建议对 TOP 函数做二分注释定位。无样本时给出样本不足提示。"
  (let* ((top-function (caar (el-chronos-profile--self-ranking rows)))
         (top-name (and top-function (format "%s" top-function)))
         (top-package (caar (el-chronos-profile--package-ranking rows))))
    (cond
     ((null top-name)
      (list (format "未采到样本（间隔 %s）：命令太快或采样不可用，换更耗时的命令或加大样本量再试"
                    (el-chronos-report--ms->human (el-chronos-profile--interval-ms)))))
     ((equal top-package el-chronos-analysis--unknown)
      (list "归因失败（TOP 包为 unknown）：通常来自已删除包的残留 .eln 或临时 snippet（.eln 已支持反查，TD-1 已关闭）"))
     ((string-match-p el-chronos-profile--idle-functions top-name)
      (list (format "热点在 `%s'（idle 类机制）：考虑调大对应 idle delay 或收窄启用范围" top-name)))
     ((> (or gc-pct 0.0) el-chronos-profile--gc-warn-pct)
      (list (format "GC 占比 %.1f%%（> %.0f%%）：考虑调整 `gc-cons-threshold'（本机已有 gcmh 管理）"
                    gc-pct el-chronos-profile--gc-warn-pct)))
     (t (list (format "可对 `%s' 做二分注释定位：逐段注释掉调用后重跑本剖析，观察样本迁移"
                      top-name))))))

(defun el-chronos-profile--error-text (error-object)
  "把 `--invoke' 捕到的错误对象 ERROR-OBJECT 渲染成一行文本。"
  (if (null error-object) ""
    (format "%s" (condition-case nil
                     (error-message-string error-object)
                   (error (format "%S" error-object))))))

(defun el-chronos-profile--content (command result)
  "生成命令 COMMAND 的剖析 org 全文；RESULT 是 `el-chronos-profile--run' 的返回值。"
  (let* ((elapsed (plist-get result :elapsed-ms))
         (gc-ms (plist-get result :gc-ms))
         (gc-count (plist-get result :gc-count))
         (samples (or (plist-get result :samples) 0))
         (rows (plist-get result :rows))
         (error-object (plist-get result :error))
         (interval (or (plist-get result :interval-ms) (el-chronos-profile--interval-ms)))
         (shared (plist-get result :shared))
         (gc-pct (el-chronos-profile--pct gc-ms elapsed))
         (hottest (caar (el-chronos-profile--self-ranking rows)))
         (top-package (caar (el-chronos-profile--package-ranking rows))))
    (concat
     (format "#+TITLE: el-chronos 单命令剖析：%s\n" (format "%s" command))
     (format "#+DATE: %s\n\n" (format-time-string "%Y-%m-%dT%H:%M:%S%z"))
     "* 概览\n"
     (format "- 命令：%s\n" (format "%s" command))
     (format "- 总耗时：%s\n" (el-chronos-report--ms->human elapsed))
     (format "- GC：%s 次 / %s（占总耗时 %s）\n" (el-chronos-report--num gc-count)
             (el-chronos-report--ms->human gc-ms) (el-chronos-report--pct gc-pct))
     (format "- 采样：%s\n"
             (cond
              ((not (plist-get result :sampling))
               "不可用（profiler 启动失败，仅有计时与 GC 数据）")
              (shared
               (format "沿用已在运行的 profiler（无法读取其真实间隔，按样本数/耗时估算为 %s），样本 %s 个"
                       (el-chronos-report--ms->human interval)
                       (el-chronos-report--num samples)))
              (t (format "间隔 %s，样本 %s 个（覆盖约 %s CPU）"
                         (el-chronos-report--ms->human interval)
                         (el-chronos-report--num samples)
                         (el-chronos-report--ms->human (* samples interval))))))
     (if shared
         "- 提示：本次剖析取走了当前采样窗口的样本，`el-chronos' 采集在该窗口内的样本会偏少\n"
       "")
     (format "- 最热函数：%s\n" (if hottest (format "%s" hottest) el-chronos-report--empty))
     (format "- 归因包 TOP：%s\n\n" (or top-package el-chronos-report--empty))
     (if error-object
         (concat "* 错误\n- 命令执行期间抛错："
                 (el-chronos-profile--error-text error-object) "\n\n")
       "")
     "* 热点函数\n" (el-chronos-profile--hot-section rows samples interval) "\n"
     (el-chronos-profile--stack-section rows)
     "* 归因\n" (el-chronos-profile--package-section rows samples interval)
     "\n* 优化建议\n"
     (mapconcat (lambda (line) (concat "- " line "\n"))
                (el-chronos-profile--suggestions rows gc-pct) ""))))

(defun el-chronos-profile--invoke (command args)
  "执行 COMMAND（ARGS 决定传参形态），返回错误对象或 nil。
ARGS 的三种形态：

- nil：按交互命令执行 `(call-interactively COMMAND)'（会读 minibuffer、把前缀参数
  交给命令）。COMMAND 不是命令（普通函数、lambda）时退回无参 `funcall' ——
  `call-interactively' 对非命令会直接报 `commandp' 错。
- 列表：整体作为实参列表 `(apply COMMAND ARGS)'，即 `\\='(1 2 3)' 传给
  `(COMMAND 1 2 3)'（三个实参，不是「一个列表实参」）。
- 其他非 nil 值：作为**单个**实参 `(funcall COMMAND ARGS)'。

错误与 C-g 都在此捕获 —— 剖析对象出错不能把调用方带崩，错误信息要出现在报告里
（可见降级，I11）。"
  (condition-case err
      (progn
        (cond ((and args (listp args)) (apply command args))
              ((null args) (if (commandp command)
                               (call-interactively command)
                             (funcall command)))
              (t (funcall command args)))
        nil)
    (error err)
    (quit err)))

(defun el-chronos-profile--run (command args)
  "在 1ms 采样下执行一次 COMMAND（ARGS 可传参），返回剖析结果 plist。
键：`:sampling' `:shared' `:interval-ms' `:elapsed-ms' `:gc-count' `:gc-ms'
`:samples' `:rows' `:error'。

profiler 已被别人（`el-chronos-mode' 的采集）占用时 `profiler-cpu-start' 会直接报
\"CPU profiler is already running\"，此时**沿用**已运行的 profiler：先取走当前日志
（保证本次窗口从干净状态开始），跑完再取一次；**不停止**它（不属于本函数）。
代价是本窗口采集层的样本被剖析取走，报告里会显式提示。
总耗时只覆盖命令执行本身（profiler 停止不计入）；GC 差值取 `gcs-done' /
`gc-elapsed'（与采集层同口径）。"
  (let* ((shared (and (fboundp 'profiler-cpu-running-p) (profiler-cpu-running-p)))
         (sampling (cond
                    (shared (progn (ignore-errors (profiler-cpu-log)) t))
                    (t (condition-case nil
                           (progn (profiler-cpu-start el-chronos-profile--interval-ns) t)
                         (error nil)))))
         (start (float-time))
         (gc-count-0 gcs-done)
         (gc-elapsed-0 gc-elapsed)
         (error-object nil)
         (elapsed-ms 0.0) (gc-count 0) (gc-ms 0.0))
    (unwind-protect
        (setq error-object (el-chronos-profile--invoke command args))
      (setq elapsed-ms (* 1000.0 (- (float-time) start))
            gc-count (- gcs-done gc-count-0)
            gc-ms (* 1000.0 (- gc-elapsed gc-elapsed-0)))
      ;; 共享模式下 profiler 归调用方所有，不能停
      (when (and sampling (not shared)) (ignore-errors (profiler-cpu-stop))))
    (let* ((log (when sampling (ignore-errors (profiler-cpu-log))))
           (rows (el-chronos-profile--log->rows log))
           (samples (cl-loop for row in rows sum (cdr row))))
      (list :sampling sampling :shared shared
            :interval-ms (if shared
                             (el-chronos-profile--estimated-interval samples elapsed-ms)
                           (el-chronos-profile--interval-ms))
            :elapsed-ms elapsed-ms :gc-count gc-count :gc-ms gc-ms
            :samples samples :rows rows :error error-object))))

(defun el-chronos-profile--save (command result)
  "把 COMMAND 的剖析结果 RESULT 作为一条 `slow_events(kind=\"profile\")' 写入并 flush。
只在 `el-chronos-profile-save' 为 t 时由 `el-chronos-profile-command' 调用；
`RESULT' 的 `:samples' 为 0（命令太快或采样不可用）时**不写库**，返回 nil ——
零样本的剖析没有任何证据价值，写进去只会在慢事件列表里留下一条 `0 ms / 无栈' 的噪声。
写库失败只告警、不影响报告（I6/I11）。栈取最热栈（与 `hourly_stacks' 同 JSON 口径），
context 取 `el-chronos-attrib-context'（只含 mode 与项目 basename，守 I7）。"
  (let ((samples (or (plist-get result :samples) 0)))
    (if (or (not (numberp samples)) (< samples 1))
        nil
      (condition-case err
          (let* ((hottest (car (el-chronos-profile--stack-ranking
                                (plist-get result :rows))))
                 (stack (mapcar #'intern (el-chronos-profile--json->frames (car hottest)))))
            (el-chronos-store-record-slow-event
             (list :duration-ms (plist-get result :elapsed-ms) :kind "profile"
                   :command (format "%s" command) :stack stack
                   :context (el-chronos-attrib-context)))
            (el-chronos-store-flush)
            t)
        (error (display-warning 'el-chronos
                                (format "剖析结果写库失败：%S" err) :warning)
               nil)))))

;;;###autoload
(defun el-chronos-profile-command (command &optional args)
  "在 1ms CPU 采样下执行一次 COMMAND，生成高精度剖析报告并显示。
报告中含总耗时、GC 占比、样本数、热点函数（函数/包/self/样本/占比）、调用链 TOP、
按包的归因汇总与规则化优化建议。COMMAND 自身的错误与中断不会传出调用方，
而是记进报告的 `* 错误' 节（可见降级）。

ARGS 的三种形态（详见 `el-chronos-profile--invoke'）：nil → 按交互命令执行；
列表 → 作为实参列表 `apply'（`\\='(1 2 3)' 即三个实参）；其他非 nil 值 → 单个实参。
交互调用不读 ARGS（`call-interactively' 无法传参）。

默认只产出报告、不写库；`el-chronos-profile-save' 为 t 时额外写一条
`slow_events(kind=\"profile\")' 并 flush，采样数为 0 时即便开启了保存也不写。
返回剖析 buffer。"
  (interactive
   (list (intern-soft (completing-read "命令: " obarray #'commandp t))))
  ;; `commandp' 对字符串/vector 也返回 t（键盘宏），但剖析对象必须是符号或函数值：
  ;; 字符串会被 `call-interactively' 当键盘宏“执行”，得不到有意义的剖析。
  (unless (and command (functionp command))
    (user-error "不是可调用的命令/函数：%s" command))
  (let* ((result (el-chronos-profile--run command args))
         (buffer (el-chronos-report--org-buffer
                  el-chronos-profile--buffer-name
                  (el-chronos-profile--content command result))))
    (when el-chronos-profile-save (el-chronos-profile--save command result))
    (display-buffer buffer)
    buffer))

(provide 'el-chronos-report)

;;; el-chronos-report.el ends here
