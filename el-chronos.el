;;; el-chronos.el --- Emacs 长期性能与用法观测器  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Thomas

;; Author: Thomas
;; Keywords: tools, performance
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; el-chronos 是常驻 Emacs 的低开销性能与用法观测器：采集命令耗时、函数热点、
;; 命令外阻塞与用法统计，落库到 SQLite，并据此回答长期趋势与回归问题。
;;
;; 本文件只负责「编排」：
;;   - 自定义组与全部可调参数（defgroup / defcustom）；
;;   - 运行时状态变量（timer 登记表、运行标志、会话 ID）；
;;   - 全局次模式 `el-chronos-mode`，开启即启动采集、关闭即零残留（I5）；
;;   - 错误降级：SQLite 不可用或任何启动异常都只告警并禁用采集，不向宿主抛错（I6）。
;;
;; 采集（collect）、归因（attrib）、存储（store）、分析（analysis）等模块由各自的
;; 文件实现。为支持「模块尚未落地时入口仍可加载并安全启停」，本文件对它们一律使用
;; 软加载（`require ... nil t` + `fboundp` 守卫），不产生硬依赖。
;;
;; 用法：
;;   (require 'el-chronos)
;;   (el-chronos-mode 1)     ; 启动观测
;;   M-x el-chronos-status   ; 查看运行状态
;;   (el-chronos-mode -1)    ; 停止观测，清理全部 timer / hook / 未 flush 缓冲
;;
;; 数据只写 `el-chronos-db-path'（I3），默认
;; `<user-emacs-directory>/.local/state/chronos/chronos.sqlite'。

;;; Code:

;;; 自定义组

(defgroup el-chronos nil
  "Emacs 长期性能与用法观测器。"
  :group 'tools
  :prefix "el-chronos-"
  :link '(custom-manual "(elisp)Profiling"))

;;; 可调参数

(defcustom el-chronos-enabled t
  "总开关。
为 nil 时 `el-chronos-mode' 仍可切换，但不会启动任何采集。"
  :type 'boolean
  :group 'el-chronos)

(defcustom el-chronos-sampling-interval-ns 10000000
  "函数热点采样间隔，单位纳秒（默认 10000000 ns，即 10ms）。
单位约定见 I4：采样间隔用纳秒，其余耗时指标一律毫秒。"
  :type 'integer
  :group 'el-chronos)

(defcustom el-chronos-sample-window-seconds 10
  "采样窗口长度，单位秒。
每满一个窗口就把 profiler 计数取走并重置，在内存里按小时聚合后落库，
避免逐窗口写库造成抖动。"
  :type 'integer
  :group 'el-chronos)

(defcustom el-chronos-heartbeat-seconds 1
  "心跳定时器间隔，单位秒。
心跳用于检测「命令之外的主线程阻塞」：比较相邻两次触发的实际间隔，
漂移超过 `el-chronos-block-threshold-ms' 时记一次阻塞事件（I2）。"
  :type 'number
  :group 'el-chronos)

(defcustom el-chronos-block-threshold-ms 2000
  "判定一次阻塞事件的漂移阈值，单位毫秒。
心跳延迟超过该值即认为主线程被长时间占住（例如未分批的 IO 或原生代码）。"
  :type 'number
  :group 'el-chronos)

(defcustom el-chronos-slow-command-threshold-ms 200
  "判定「慢命令」的耗时阈值，单位毫秒。
超过该值的命令会被记入慢事件，供排行与下钻使用。"
  :type 'number
  :group 'el-chronos)

(defcustom el-chronos-db-path
  (expand-file-name ".local/state/chronos/chronos.sqlite" user-emacs-directory)
  "SQLite 数据库文件路径。
默认落在 `<user-emacs-directory>/.local/state/chronos/chronos.sqlite'。
I3 要求全部观测数据只写这一个文件（连同 SQLite 自动生成的 -wal / -shm）。"
  :type 'file
  :group 'el-chronos)

(defcustom el-chronos-retention-days 30
  "明细数据保留天数。
只作用于 `commands' 与 `slow_events' 两张明细表；`hourly_functions'、
`hourly_usage'、`hourly_stacks' 三张聚合表永久保留，由用户手动 purge 清理。"
  :type 'integer
  :group 'el-chronos)

(defcustom el-chronos-usage-granularity 'command
  "用法统计的聚合维度。
`command' 表示按命令名统计 —— 默认值，**不写任何文件路径**（I7）。
`file' 表示**额外**增加一维「被操作文件的**绝对路径**」写入 `hourly_usage'：
取命令结算时刻当前 buffer 的 `buffer-file-name'（`el-chronos-collect--finish' 里
`-record-usage' 的 `file' 维度，落在 key 列）。
隐私提示：`hourly_usage' 是**永久保留**表（只由 `el-chronos-purge' 手动清理，
不随 `el-chronos-retention-days' 轮换），一旦启用 `file' 粒度，被操作文件路径会长期
留在库里；仅在确实需要「按文件看用法」时开启，默认保持 `command'。"
  :type '(choice (const :tag "按命令名" command)
                 (const :tag "按文件（记绝对路径，永久保留）" file))
  :group 'el-chronos)

(defcustom el-chronos-store-stack-top-n 200
  "每个会话每小时保留的调用栈样本条数上限。
超限按样本数淘汰，用于在行数可控的前提下支撑火焰图与调用链分析。"
  :type 'integer
  :group 'el-chronos)

(defcustom el-chronos-regression-window-days 7
  "回归判定的时间窗口长度，单位天。
以「近 N 天」对比「前一个等长窗口」来判断是否发生回归。"
  :type 'integer
  :group 'el-chronos)

(defcustom el-chronos-regression-threshold 0.5
  "回归判定的增长比例阈值（0.5 即 50%）。
近窗口的 self 时间相对前窗口增长达到该比例，且两窗口样本数都满足
`el-chronos-regression-min-samples' 时，才判定为回归。"
  :type 'number
  :group 'el-chronos)

(defcustom el-chronos-regression-min-samples 10
  "回归判定要求的最小样本数（两个窗口各自都要满足）。
用于抑制小样本噪声被误判为回归。"
  :type 'integer
  :group 'el-chronos)

(defcustom el-chronos-web-port 8787
  "Web dashboard 监听端口。
I8：Web 服务只绑定 127.0.0.1，端口被占用时启动直接失败，不自动换端口。"
  :type 'integer
  :group 'el-chronos)

(defcustom el-chronos-web-auto-start nil
  "启用观测时是否顺带启动 Web dashboard。
默认 nil（不自动启动）：Web 服务需要用户显式 `M-x el-chronos-web-start'。"
  :type 'boolean
  :group 'el-chronos)

;;; 运行时状态

(defvar el-chronos--active-timers nil
  "已注册的 timer 列表。
collect / store 等模块在创建 timer 时通过 `el-chronos--register-timer' 登记，
停止时统一取消，保证 `el-chronos-mode' 关闭后零残留（I5）。")

(defvar el-chronos--running-p nil
  "观测器当前是否已启动。
用于让启停编排幂等：重复开启不会重复注册 hook / timer。")

(defvar el-chronos--session-id nil
  "当前会话在 `sessions' 表中的 ID。
由 store 模块在开启时写入，关闭时置 nil。")

;;; 内部辅助函数

(defun el-chronos--sqlite-available-p ()
  "判断内置 SQLite 支持是否可用。
Emacs 29 起内置 `sqlite' 库；不可用时返回 nil 而不抛错。"
  (condition-case nil
      (and (require 'sqlite nil t)
           (fboundp 'sqlite-open))
    (error nil)))

(defun el-chronos--register-timer (timer)
  "把 TIMER 登记到 `el-chronos--active-timers' 并返回 TIMER。
供各模块登记自己创建的 timer，以便统一取消。"
  (push timer el-chronos--active-timers)
  timer)

(defun el-chronos--cancel-timers ()
  "取消全部已登记的 timer 并清空登记表。
单个 timer 取消失败不影响其余 timer 的清理。"
  (dolist (timer el-chronos--active-timers)
    (ignore-errors (cancel-timer timer)))
  (setq el-chronos--active-timers nil)
  nil)

(defun el-chronos--call-if-bound (function)
  "FUNCTION 已定义时无参调用它，否则直接返回 nil。
用符号 + `funcall' 的形式调用，既可软调用尚未落地的模块函数，
也不会在字节编译期产生「函数未定义」告警。"
  (when (fboundp function)
    (funcall function)))

;;; 全局次模式

;; 说明：模式定义故意排在其调用的内部函数之前 —— 这样内部函数引用
;; `el-chronos-mode' 变量时它已被 defvar（由 define-minor-mode 产生），
;; 字节编译不会报「自由变量」告警。
(define-minor-mode el-chronos-mode
  "全局次模式：启停 el-chronos 长期性能与用法观测器。

开启时依次：检查内置 SQLite → 软加载 store / collect 模块 → 打开数据库 →
启动采集。任何一步失败都只告警并自动禁用模式，不向宿主抛错（I6）。

关闭时依次：停止采集 → 关闭数据库（关闭前 flush）→ 取消全部 timer →
清空运行状态，保证零残留（I5）。重复开启/关闭均为幂等操作。

该模式的运行开销来自内置 C profiler 的采样与两次 `float-time' 计时，
不做全量 advice、不改命令语义（I1）。"
  :global t
  :group 'el-chronos
  :lighter " Chronos"
  (condition-case err
      (if el-chronos-mode
          (el-chronos--start)
        (el-chronos--stop))
    (error
     (display-warning
      'el-chronos
      (format "切换 el-chronos-mode 失败，已禁用观测：%S" err)
      :warning)
     (setq el-chronos-mode nil))))

;;; 启停编排

(defun el-chronos--start ()
  "启动观测器。成功返回 t，失败返回 nil。
幂等：已处于运行态时先停止（清理旧 timer / hook）再重新启动。
SQLite 不可用或启动过程中出错时，告警并把 `el-chronos-mode' 置 nil。"
  ;; 幂等：先回收上一次的运行态，避免重复注册 hook / timer
  (when el-chronos--running-p
    (el-chronos--stop))
  (cond
   ((not el-chronos-enabled)
    (message "el-chronos：总开关 el-chronos-enabled 为 nil，不启动采集。")
    nil)
   ((not (el-chronos--sqlite-available-p))
    (display-warning
     'el-chronos
     "内置 SQLite 不可用（需要 Emacs 29+ 且支持 sqlite），已禁用采集。"
     :warning)
    (setq el-chronos-mode nil)
    nil)
   (t
    (condition-case err
        (progn
          ;; 软加载：这两个模块尚未落地时 require 返回 nil，不得报错
          (require 'el-chronos-store nil t)
          (require 'el-chronos-collect nil t)
          (el-chronos--call-if-bound 'el-chronos-store-open)
          (el-chronos--call-if-bound 'el-chronos-collect-start)
          (setq el-chronos--running-p t)
          t)
      (error
       (display-warning
        'el-chronos
        (format "启动失败，已禁用观测：%S" err)
        :warning)
       ;; 尽力清理半启动状态（例如库已打开、hook 已挂上）
       (condition-case nil
           (el-chronos--stop)
         (error nil))
       (setq el-chronos-mode nil)
       nil)))))

(defun el-chronos--stop ()
  "停止观测器并清理全部残留。
依次停止采集、关闭数据库（关闭前由 store 负责 flush）、取消已登记的 timer，
最后清空运行标志与会话 ID。清理过程中的错误只告警，不向宿主抛错。"
  (condition-case err
      (progn
        (el-chronos--call-if-bound 'el-chronos-collect-stop)
        (el-chronos--call-if-bound 'el-chronos-store-close))
    (error
     (display-warning
      'el-chronos
      (format "停止时出错（已忽略并继续清理）：%S" err)
      :warning)))
  ;; 兜底：即使各模块自己漏了 timer，这里也统一取消（I5）
  (el-chronos--cancel-timers)
  (setq el-chronos--running-p nil
        el-chronos--session-id nil)
  nil)

;;; 状态查询

(defun el-chronos-status ()
  "在 echo area 显示 el-chronos 的运行状态。
只读命令：不启停观测、不写数据库、不修改任何状态。"
  (interactive)
  (message
   (concat "el-chronos：%s | 数据库 %s | 采样间隔 %d ns（%s ms）"
           " | 采样窗口 %d s | 保留 %d 天 | 会话 %s")
   (cond ((not el-chronos-enabled) "已禁用（el-chronos-enabled 为 nil）")
         (el-chronos--running-p "运行中")
         (t "未运行"))
   el-chronos-db-path
   el-chronos-sampling-interval-ns
   (/ el-chronos-sampling-interval-ns 1000000.0)
   el-chronos-sample-window-seconds
   el-chronos-retention-days
   (or el-chronos--session-id "无"))
  nil)

(provide 'el-chronos)

;;; el-chronos.el ends here
