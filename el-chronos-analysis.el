;;; el-chronos-analysis.el --- 聚合查询层  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Thomas

;; Author: Thomas
;; Keywords: tools, performance
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; 只读聚合查询层：把 SQLite 明细整理成纯数据（plist / list of plist），供 org 报告（T7）、
;; Web API（T9）两方共用，SQL 只写在这里。
;;
;; 约定：首参 RANGE 取 `1d' / `7d' / `30d'（按当前时刻倒推）或显式半开区间
;; `(START . END)'（epoch 毫秒）；例外是 `el-chronos-analysis-regressions'——它的对比窗口由
;; `el-chronos-regression-window-days' 决定、与显示范围无关，RANGE 参数仅为签名一致而保留（被忽略）；
;; 只返回数据，不生成文本、不渲染、不写库；数据库未打开时先用
;; `el-chronos-store-open' 幂等打开，仍失败返回 nil；任何查询出错都 `display-warning' 并返回
;; nil，不向调用方抛错（与 I6 同款降级）。
;;
;; 单位（I4）：时间戳、耗时、桶起点一律毫秒；`sessions.startup_ms' 由 store 层按「秒差 × 1000」
;; 写入，落库即毫秒，本层读出直接使用，不再二次乘 1000。
;;
;; 百分比口径：`top-functions' / `stacks' 用样本数做分母，`package-breakdown' 用 self_ms 总和
;; 做分母；分母都取窗口内全部行，不受 LIMIT 截断影响。
;;
;; GC 处理：函数热点默认排除 "Automatic GC"（profiler 伪函数，不是用户代码），需要时传
;; INCLUDE-GC；包占比里 GC 恒单独成条（名 "GC"），与归因失败的 `unknown' 一起排在末尾。

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'sqlite)
(require 'el-chronos)

(declare-function el-chronos-store-open "el-chronos-store" (&optional path))
;; store 层持有的句柄与路径；此处只声明，避免字节编译的「自由变量」告警
(defvar el-chronos-store--db)
(defvar el-chronos-store--path)

(defconst el-chronos-analysis--gc-function "Automatic GC" "C profiler 采样中的 GC 伪函数名。")
(defconst el-chronos-analysis--gc-label "GC" "包占比里 GC 采样使用的条目名。")
(defconst el-chronos-analysis--unknown "unknown" "归因失败时使用的包名。")
(defconst el-chronos-analysis--ms-per-hour 3600000 "一小时的毫秒数；趋势桶宽恒为其整数倍。")
(defconst el-chronos-analysis--ms-per-day 86400000 "一天的毫秒数。")
(defconst el-chronos-analysis--range-days '((1d . 1) (7d . 7) (30d . 30))
  "符号化时间范围到天数的映射；未列出的符号按 7 天处理。")

;;; 内部工具
(defun el-chronos-analysis--now-ms ()
  "当前 epoch 毫秒（整数）。"
  (truncate (* 1000 (float-time))))

(defun el-chronos-analysis--range (range)
  "把 RANGE 归一为半开区间 (START . END)，单位毫秒。
RANGE 取 `1d' / `7d' / `30d'（按当前时刻倒推；未知值按 7 天处理），或显式
`(START . END)'（数字，反向时自动交换）。
END 恒为「上界 + 1 毫秒」：下游 SQL 一律用 `ts < END'，END 加 1 后右开区间才能包含
查询时刻刚写入、与 END 同毫秒的那一行（否则 `1d' 这类按当前时刻倒推的窗口会漏掉最新数据）。"
  (let* ((now (el-chronos-analysis--now-ms))
         (bounds (if (and (consp range) (numberp (car range)) (numberp (cdr range)))
                     (let ((a (truncate (car range))) (b (truncate (cdr range))))
                       (cons (min a b) (max a b)))
                   (cons (- now (* el-chronos-analysis--ms-per-day
                                   (or (alist-get range el-chronos-analysis--range-days) 7)))
                         now))))
    (cons (car bounds) (1+ (cdr bounds)))))

(defun el-chronos-analysis--range-buckets (start end)
  "按窗口长度选择默认趋势桶数：≤1 天 24、≤8 天 168、更长 720。"
  (let ((days (/ (float (max 0 (- end start))) (float el-chronos-analysis--ms-per-day))))
    (cond ((<= days 1.0) 24) ((<= days 8.0) 168) (t 720))))

(defun el-chronos-analysis--bucket-span (start end buckets)
  "计算趋势桶宽（毫秒）：至少 1 小时且桶数不超过 BUCKETS（超出时按整小时倍数合并）。"
  (let* ((buckets (max 1 (or buckets 1)))
         (hours (max 1 (ceiling (/ (float (max 0 (- end start)))
                                   (float el-chronos-analysis--ms-per-hour)))))
         (per (max 1 (ceiling (/ (float hours) (float buckets))))))
    (* per el-chronos-analysis--ms-per-hour)))

(defmacro el-chronos-analysis--guard (what &rest body)
  "在 WHAT（告警文案里的查询名）上下文执行 BODY；出错时告警并返回 nil。"
  (declare (indent 1) (debug t))
  `(condition-case err
       (progn ,@body)
     (error
      (display-warning 'el-chronos
                       (format "分析查询 %s 失败（已降级为空结果）：%S" ,what err)
                       :warning)
      nil)))

(defun el-chronos-analysis--db ()
  "返回可用的 SQLite 句柄；未打开时幂等打开，仍失败返回 nil。"
  (or (bound-and-true-p el-chronos-store--db)
      (when (require 'el-chronos-store nil t)
        (condition-case err
            (el-chronos-store-open)
          (error (display-warning 'el-chronos
                                  (format "分析层打开数据库失败：%S" err) :warning)
                 nil)))))

(defun el-chronos-analysis--select (db sql params)
  "在 DB 上执行只读 SQL 并返回行列表；用户数据一律经 PARAMS 用 `?' 占位符绑定。"
  (sqlite-select db sql params))

(defun el-chronos-analysis--bounds (range)
  "返回 (DB START END) 三元组；数据库打不开时返回 nil。"
  (when-let* ((db (el-chronos-analysis--db))
              (bounds (el-chronos-analysis--range range)))
    (list db (car bounds) (cdr bounds))))

(defun el-chronos-analysis--json (string)
  "把 JSON 文本 STRING 解析为 elisp 值（对象转 plist、数组转 list）；失败返回 nil。"
  (when (and (stringp string) (not (string-empty-p string)))
    (condition-case nil
        (json-parse-string string :object-type 'plist :array-type 'list)
      (error nil))))

(defun el-chronos-analysis--pct (part total)
  "PART 占 TOTAL 的百分比（0–100）；TOTAL 非正或参数非数字时返回 0.0。"
  (if (and (numberp part) (numberp total) (> total 0))
      (* 100.0 (/ (float part) (float total)))
    0.0))

(defun el-chronos-analysis--package-name (package)
  "把库中的 PACKAGE 值规范成展示名：nil / 空串归为 \"unknown\"。"
  (let ((name (and (stringp package) (string-trim package))))
    (if (string-empty-p (or name "")) el-chronos-analysis--unknown name)))

(defun el-chronos-analysis--take (rows limit)
  "取 ROWS 的前 LIMIT 个元素；LIMIT 为 nil 或非正时返回全部（「不限」语义）。"
  (if (and (numberp limit) (> limit 0))
      (cl-subseq rows 0 (min limit (length rows)))
    rows))

(defun el-chronos-analysis--median (numbers)
  "返回数值列表 NUMBERS 的中位数；空列表返回 nil。
元素个数为偶数时取升序后中间两数的平均值（单样本直接返回该值）。"
  (when-let* ((sorted (sort (copy-sequence numbers) #'<)))
    (let* ((n (length sorted)) (mid (/ n 2)))
      (if (cl-evenp n)
          (/ (+ (float (nth (1- mid) sorted)) (float (nth mid sorted))) 2.0)
        (float (nth mid sorted))))))

;;; 概览
(defun el-chronos-analysis-db-size ()
  "当前数据库主文件的字节数；文件不存在或不可读时返回 0。
只统计主文件，不含 SQLite 自动生成的 -wal / -shm（WAL 未 checkpoint 时主文件偏小）。"
  (let ((path (or (bound-and-true-p el-chronos-store--path) el-chronos-db-path)))
    (condition-case nil
        (if (and path (file-exists-p path)) (or (nth 7 (file-attributes path)) 0) 0)
      (error 0))))

(defun el-chronos-analysis-overview (range)
  "窗口 RANGE 内的总览指标 plist。
键与口径：`:commands' 命令条数（含 aborted）、`:blocked-ms' kind='block' 的耗时之和、
`:slow-commands' 耗时 ≥ `el-chronos-slow-command-threshold-ms' 的条数、`:samples'
`hourly_functions.samples' 之和（含 GC）、`:db-size' 数据库文件字节数、`:startup-ms'
最近 10 个有效会话（`startup_ms' 非空且 > 0）启动耗时的中位数（毫秒；无有效样本为 nil，
避免刚启动的会话单点覆盖结论）、`:sessions' 窗口内启动的会话数。
数据库打不开或查询失败时返回 nil。"
  (el-chronos-analysis--guard 'overview
    (when-let* ((ctx (el-chronos-analysis--bounds range))
                (db (car ctx)) (start (nth 1 ctx)) (end (nth 2 ctx)))
      (let ((w (list start end))
            (q (lambda (sql params) (caar (sqlite-select db sql params)))))
        (list :commands (funcall q
                                 "SELECT count(*) FROM commands WHERE ts >= ? AND ts < ?" w)
              :blocked-ms (funcall q "SELECT coalesce(sum(duration_ms), 0) FROM slow_events\
 WHERE kind = 'block' AND ts >= ? AND ts < ?" w)
              :slow-commands (funcall q "SELECT count(*) FROM commands\
 WHERE ts >= ? AND ts < ? AND duration_ms >= ?"
                                      (list start end (or el-chronos-slow-command-threshold-ms 0)))
              :samples (funcall q "SELECT coalesce(sum(samples), 0) FROM hourly_functions\
 WHERE hour_ts >= ? AND hour_ts < ?" w)
              :db-size (el-chronos-analysis-db-size)
              :startup-ms (el-chronos-analysis--median
                           (mapcar #'car
                                   (el-chronos-analysis--select
                                    db "SELECT startup_ms FROM sessions\
 WHERE startup_ms IS NOT NULL AND startup_ms > 0\
 ORDER BY started_at DESC LIMIT 10" nil)))
              :sessions (funcall q "SELECT count(*) FROM sessions\
 WHERE started_at >= ? AND started_at < ?" w))))))

;;; 函数热点
(defun el-chronos-analysis-top-functions (range &optional limit include-gc)
  "窗口 RANGE 内按 self 时间降序的热点函数列表。
元素 `(:function NAME :file PATH :package PKG :self-ms X :samples N :pct P)'；
LIMIT 默认 20；INCLUDE-GC 为 nil 时排除 \"Automatic GC\"。
SQL 过滤 `samples > 0'：`samples' 是 leaf（self）口径的采样计数，只作为中间帧 / 根帧
出现过的函数 `samples' 恒为 0（其 `self_ms' 也必为 0），属自时间排名里的纯噪声 ——
它们的调用链信息由 `el-chronos-analysis-stacks' 提供，不该占据热点榜。
`:pct' 是样本数占窗口内（同一过滤条件下）全部样本的百分比，分母不受 LIMIT 截断。"
  (el-chronos-analysis--guard 'top-functions
    (when-let* ((ctx (el-chronos-analysis--bounds range))
                (db (car ctx)) (start (nth 1 ctx)) (end (nth 2 ctx)))
      (let* ((rows (el-chronos-analysis--select
                    db
                    (concat "SELECT function, max(file), max(package), sum(self_ms),"
                            " sum(samples) FROM hourly_functions"
                            " WHERE hour_ts >= ? AND hour_ts < ? AND samples > 0"
                            (if include-gc "" " AND function <> ?")
                            " GROUP BY function")
                    (append (list start end)
                            (unless include-gc (list el-chronos-analysis--gc-function)))))
             (total (cl-loop for r in rows sum (or (nth 4 r) 0)))
             (sorted (cl-sort (copy-sequence rows) #'> :key (lambda (r) (or (nth 3 r) 0)))))
        (cl-loop for (function file package self samples) in
                 (el-chronos-analysis--take sorted (or limit 20))
                 collect (list :function function :file file
                               :package (el-chronos-analysis--package-name package)
                               :self-ms (float (or self 0)) :samples (or samples 0)
                               :pct (el-chronos-analysis--pct samples total)))))))

;;; 慢命令
(defun el-chronos-analysis-slow-commands (range &optional limit)
  "窗口 RANGE 内按总耗时降序的命令排行。
元素 `(:name NAME :count N :total-ms X :max-ms X :avg-ms X :aborted N)'；数据源是
`commands' 全表（不额外按阈值过滤），`:aborted' 统计 outcome='aborted' 的条数。
LIMIT 默认 20，在 SQL 内截断，因此 `:total-ms' 是该命令在窗口内的完整合计。"
  (el-chronos-analysis--guard 'slow-commands
    (when-let* ((ctx (el-chronos-analysis--bounds range))
                (db (car ctx)) (start (nth 1 ctx)) (end (nth 2 ctx)))
      (cl-loop for (name count total mx avg aborted) in
               (el-chronos-analysis--select
                db
                (concat "SELECT name, count(*), sum(duration_ms), max(duration_ms),"
                        " avg(duration_ms),"
                        " sum(CASE WHEN outcome = 'aborted' THEN 1 ELSE 0 END)"
                        " FROM commands WHERE ts >= ? AND ts < ? GROUP BY name"
                        " ORDER BY sum(duration_ms) DESC LIMIT ?")
                (list start end (max 1 (or limit 20))))
               collect (list :name name :count (or count 0)
                             :total-ms (float (or total 0)) :max-ms (float (or mx 0))
                             :avg-ms (float (or avg 0)) :aborted (or aborted 0))))))

;;; 包 / 模块占比
(defun el-chronos-analysis-package-breakdown (range &optional limit)
  "窗口 RANGE 内按包/模块聚合的 self 时间占比。
元素 `(:package PKG :self-ms X :pct P)'；`:pct' 分母是窗口内 self_ms 总和。
SQL 过滤 `self_ms > 0'：self 为 0 的行只代表该函数作为中间帧出现（`total_ms' 才有值），
对包占比没有贡献，留着只会产生 0% 条目、把列表长度浪费掉。
归因失败的 `unknown'（package 为 NULL 或空串）与 GC 采样（\"Automatic GC\" → \"GC\"）
恒单独成条并排在末尾（先 unknown 后 GC）；LIMIT 只限制其余条目数（nil 表示不限）。"
  (el-chronos-analysis--guard 'package-breakdown
    (when-let* ((ctx (el-chronos-analysis--bounds range))
                (db (car ctx)) (start (nth 1 ctx)) (end (nth 2 ctx)))
      (let* ((rows (el-chronos-analysis--select
                    db
                    (concat "SELECT CASE WHEN function = ? THEN ?"
                            " ELSE coalesce(nullif(package, ''), ?) END AS pkg,"
                            " sum(self_ms) FROM hourly_functions"
                            " WHERE hour_ts >= ? AND hour_ts < ? AND self_ms > 0"
                            " GROUP BY pkg")
                    (list el-chronos-analysis--gc-function el-chronos-analysis--gc-label
                          el-chronos-analysis--unknown start end)))
             (total (cl-loop for r in rows sum (or (nth 1 r) 0)))
             (tail (append (cl-remove-if-not (lambda (r) (equal (car r)
                                                                el-chronos-analysis--unknown))
                                             rows)
                           (cl-remove-if-not (lambda (r) (equal (car r)
                                                                el-chronos-analysis--gc-label))
                                             rows)))
             (head (cl-sort (cl-remove-if (lambda (r)
                                            (member (car r) (list el-chronos-analysis--unknown
                                                                  el-chronos-analysis--gc-label)))
                                          rows)
                            #'> :key (lambda (r) (or (nth 1 r) 0)))))
        (cl-loop for (package self) in (append (el-chronos-analysis--take head limit) tail)
                 collect (list :package package :self-ms (float (or self 0))
                               :pct (el-chronos-analysis--pct self total)))))))

;;; 趋势
(defun el-chronos-analysis--trend-accumulate (db sql params table column)
  "执行趋势分项查询 SQL（PARAMS 绑定），把计数累加到 TABLE 的第 COLUMN 槽（0/1/2）。"
  (dolist (row (el-chronos-analysis--select db sql params))
    (let ((cell (or (gethash (car row) table)
                    (puthash (car row) (vector 0 0 0) table))))
      (aset cell column (+ (aref cell column) (or (nth 1 row) 0))))))

(defun el-chronos-analysis-trend (range &optional buckets)
  "窗口 RANGE 内按桶聚合的趋势，按桶起点升序。
元素 `(:bucket START-MS :samples N :slow-commands N :blocked N)'，空桶不返回。
BUCKETS 省略时按窗口长度取 24（≤1 天）/168（≤8 天）/720；窗口小时数超过 BUCKETS 时
自动按整小时倍数合并，因此返回条数恒不超过 BUCKETS。"
  (el-chronos-analysis--guard 'trend
    (when-let* ((ctx (el-chronos-analysis--bounds range))
                (db (car ctx)) (start (nth 1 ctx)) (end (nth 2 ctx)))
      (let ((buckets (max 1 (or buckets (el-chronos-analysis--range-buckets start end))))
            (table (make-hash-table :test #'equal)))
        (let ((span (el-chronos-analysis--bucket-span start end buckets))
              (threshold (or el-chronos-slow-command-threshold-ms 0)))
          (el-chronos-analysis--trend-accumulate
           db "SELECT hour_ts - (hour_ts % ?) AS b, sum(samples) FROM hourly_functions\
 WHERE hour_ts >= ? AND hour_ts < ? GROUP BY b"
           (list span start end) table 0)
          (el-chronos-analysis--trend-accumulate
           db "SELECT ts - (ts % ?) AS b, count(*) FROM commands\
 WHERE ts >= ? AND ts < ? AND duration_ms >= ? GROUP BY b"
           (list span start end threshold) table 1)
          (el-chronos-analysis--trend-accumulate
           db "SELECT ts - (ts % ?) AS b, count(*) FROM slow_events\
 WHERE kind = 'block' AND ts >= ? AND ts < ? GROUP BY b"
           (list span start end) table 2))
        (cl-loop for bucket being the hash-keys of table using (hash-values cell)
                 collect (list :bucket bucket :samples (aref cell 0)
                               :slow-commands (aref cell 1) :blocked (aref cell 2))
                 into items
                 finally return (cl-sort items #'< :key (lambda (i) (plist-get i :bucket))))))))

;;; 用法热力图
(defun el-chronos-analysis-heatmap (range &optional limit)
  "窗口 RANGE 内的命令用法热力图。
元素 `(:bucket START-MS :command NAME :count N :duration-ms X)'，按桶起点升序、同桶内按
次数降序；`:duration-ms' 取 `hourly_usage.duration_ms'（该桶该命令的耗时合计，毫秒）。
只取 `hourly_usage' 中 dimension='command' 的行（mode / project 维度不参与热力图）。
LIMIT 限制参与的命令条数（按窗口内总次数取前 N，默认 20）。"
  (el-chronos-analysis--guard 'heatmap
    (when-let* ((ctx (el-chronos-analysis--bounds range))
                (db (car ctx)) (start (nth 1 ctx)) (end (nth 2 ctx)))
      (cl-loop for (bucket command count duration) in
               (el-chronos-analysis--select
                db
                (concat "SELECT hour_ts, key, count, duration_ms FROM hourly_usage"
                        " WHERE dimension = 'command' AND hour_ts >= ? AND hour_ts < ?"
                        " AND key IN (SELECT key FROM hourly_usage"
                        " WHERE dimension = 'command' AND hour_ts >= ? AND hour_ts < ?"
                        " GROUP BY key ORDER BY sum(count) DESC LIMIT ?)"
                        " ORDER BY hour_ts, count DESC")
                (list start end start end (max 1 (or limit 20))))
               collect (list :bucket bucket :command command :count (or count 0)
                             :duration-ms (float (or duration 0)))))))

;;; 调用栈
(defun el-chronos-analysis-stacks (range &optional limit)
  "窗口 RANGE 内的调用栈排行（按样本降序）。
元素 `(:stack (FUNCTION...) :samples N :pct P)'；`:stack' 是栈帧名字符串列表（第 0 个
是 leaf），`:pct' 分母是窗口内全部栈样本数。LIMIT 默认 50；解析失败的行跳过。"
  (el-chronos-analysis--guard 'stacks
    (when-let* ((ctx (el-chronos-analysis--bounds range))
                (db (car ctx)) (start (nth 1 ctx)) (end (nth 2 ctx)))
      (let* ((total (or (caar (el-chronos-analysis--select
                               db
                               "SELECT coalesce(sum(samples), 0) FROM hourly_stacks\
 WHERE hour_ts >= ? AND hour_ts < ?"
                               (list start end)))
                        0))
             (rows (el-chronos-analysis--select
                    db
                    (concat "SELECT stack_json, sum(samples) FROM hourly_stacks"
                            " WHERE hour_ts >= ? AND hour_ts < ?"
                            " GROUP BY stack_json ORDER BY sum(samples) DESC LIMIT ?")
                    (list start end (max 1 (or limit 50))))))
        (cl-loop for (json samples) in rows
                 for stack = (el-chronos-analysis--json json)
                 when stack
                 collect (list :stack stack :samples (or samples 0)
                               :pct (el-chronos-analysis--pct samples total)))))))

;;; 会话
(defun el-chronos-analysis-sessions (range)
  "窗口 RANGE 内启动的会话列表，按启动时间降序。
元素 `(:id N :started-at MS :startup-ms X :emacs-version V :host H)'；
`:startup-ms' 为毫秒（store 落库时已换算），缺失为 nil。"
  (el-chronos-analysis--guard 'sessions
    (when-let* ((ctx (el-chronos-analysis--bounds range))
                (db (car ctx)) (start (nth 1 ctx)) (end (nth 2 ctx)))
      (cl-loop for (id started startup version host) in
               (el-chronos-analysis--select
                db
                (concat "SELECT id, started_at, startup_ms, emacs_version, host"
                        " FROM sessions WHERE started_at >= ? AND started_at < ?"
                        " ORDER BY started_at DESC")
                (list start end))
               collect (list :id id :started-at started
                             :startup-ms (and (numberp startup) startup)
                             :emacs-version version :host host)))))

;;; 阻塞事件与单条下钻
(defun el-chronos-analysis-blocking-events (range &optional limit)
  "窗口 RANGE 内的命令外阻塞事件列表，按耗时降序。
元素 `(:id N :ts MS :duration-ms X :kind K :command C :mode M :project P)'；
`:kind' 恒为 \"block\"（命令超阈值属慢命令，不在本列表）；`:mode' / `:project' 取自
`context_json'，缺失为 nil。LIMIT 默认 20。"
  (el-chronos-analysis--guard 'blocking-events
    (when-let* ((ctx (el-chronos-analysis--bounds range))
                (db (car ctx)) (start (nth 1 ctx)) (end (nth 2 ctx)))
      (cl-loop for (id ts duration kind command json) in
               (el-chronos-analysis--select
                db
                (concat "SELECT id, ts, duration_ms, kind, command, context_json"
                        " FROM slow_events WHERE kind = 'block' AND ts >= ? AND ts < ?"
                        " ORDER BY duration_ms DESC LIMIT ?")
                (list start end (max 1 (or limit 20))))
               for context = (el-chronos-analysis--json json)
               collect (list :id id :ts ts :duration-ms (float (or duration 0))
                             :kind kind :command command
                             :mode (plist-get context :mode)
                             :project (plist-get context :project))))))

(defun el-chronos-analysis-event (id)
  "按 ID 取单条慢事件（含 block 与 command）的完整 plist；不存在返回 nil。
键：`:id' `:ts' `:duration-ms' `:kind' `:command' `:stack'（栈帧名 list）
`:context'（plist）；两个 JSON 字段缺失或解析失败时对应键为 nil。"
  (el-chronos-analysis--guard 'event
    (when-let* ((db (el-chronos-analysis--db)))
      (when (numberp id)
        (let ((row (car (el-chronos-analysis--select
                         db
                         (concat "SELECT id, ts, duration_ms, kind, command,"
                                 " stack_json, context_json FROM slow_events WHERE id = ?")
                         (list id)))))
          (when row
            (cl-destructuring-bind (id ts duration kind command stack context) row
              (list :id id :ts ts :duration-ms (float (or duration 0))
                    :kind kind :command command
                    :stack (el-chronos-analysis--json stack)
                    :context (el-chronos-analysis--json context)))))))))

;;; 回归判定
(defun el-chronos-analysis-regressions (range &optional limit)
  "返回按 `el-chronos-regression-window-days' 判定的回归列表，按增长率降序。
窗口由 `el-chronos-regression-window-days' 决定，与显示范围无关：当前窗口为
[当前时刻 - N 天, 当前时刻)，前窗口为 [当前时刻 - 2N 天, 当前时刻 - N 天)。
参数 RANGE 仅为保持与同层其他查询一致的签名而保留，本函数忽略它。
元素 `(:function NAME :current-ms X :previous-ms X :growth P :current-samples N
:previous-samples N)'，`:growth' 为增长率（0.5 即 +50%）。三个条件同时满足才计入
（计划「回归判定」节）：两窗口样本数都 ≥ `el-chronos-regression-min-samples'；增长率 ≥
`el-chronos-regression-threshold'；前窗口 self 时间 > 0（previous 为 0 时无法算增长，
跳过，避免除零误报）。\"Automatic GC\" 恒排除（不是用户函数）。LIMIT 默认 20。"
  (ignore range)
  (el-chronos-analysis--guard 'regressions
    (when-let* ((db (el-chronos-analysis--db)))
      (let* ((end (1+ (el-chronos-analysis--now-ms)))
             (window (* (or el-chronos-regression-window-days 7)
                        el-chronos-analysis--ms-per-day))
             (start (- end window))
             (min-samples (or el-chronos-regression-min-samples 10))
             (threshold (float (or el-chronos-regression-threshold 0.5)))
             (sql (concat "SELECT function, sum(self_ms), sum(samples) FROM hourly_functions"
                          " WHERE hour_ts >= ? AND hour_ts < ? AND function <> ?"
                          " GROUP BY function"))
             (current (el-chronos-analysis--select
                       db sql (list start end el-chronos-analysis--gc-function)))
             (previous (el-chronos-analysis--select
                        db sql (list (- start window) start el-chronos-analysis--gc-function)))
             (prev-table (make-hash-table :test #'equal))
             (items nil))
        (dolist (r previous) (puthash (car r) r prev-table))
        (dolist (r current)
          (let* ((name (car r)) (cur-ms (float (or (nth 1 r) 0))) (cur-n (or (nth 2 r) 0))
                 (prev (gethash name prev-table)))
            (when prev
              (let ((prev-ms (float (or (nth 1 prev) 0))) (prev-n (or (nth 2 prev) 0)))
                (when (and (> prev-ms 0) (>= cur-n min-samples) (>= prev-n min-samples))
                  (let ((growth (- (/ cur-ms prev-ms) 1.0)))
                    (when (>= growth threshold)
                      (push (list :function name :current-ms cur-ms :previous-ms prev-ms
                                  :growth growth :current-samples cur-n
                                  :previous-samples prev-n)
                            items))))))))
        (el-chronos-analysis--take
         (cl-sort items #'> :key (lambda (i) (plist-get i :growth)))
         (or limit 20))))))

;;; 命令名（供补全）
(defun el-chronos-analysis-names ()
  "数据库中记录过的全部命令名（升序去重），供补全使用；无数据或失败返回 nil。"
  (el-chronos-analysis--guard 'names
    (when-let* ((db (el-chronos-analysis--db)))
      (let ((names (delq nil (cl-loop for (name) in
                                      (el-chronos-analysis--select
                                       db "SELECT DISTINCT name FROM commands ORDER BY name" nil)
                                      collect name))))
        (when names names)))))

(provide 'el-chronos-analysis)

;;; el-chronos-analysis.el ends here
