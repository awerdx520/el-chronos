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
;; 百分比口径：`top-functions' / `stacks' / `inclusive-functions' 用样本数做分母
;; （前两者的样本是 self / 栈样本口径，`inclusive-functions' 是「栈包含」口径），
;; `package-breakdown' 用 self_ms 总和做分母；分母都取窗口内全部行，不受 LIMIT 截断影响。
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
  "按窗口长度选择默认趋势桶数：≤1 天 24、≤8 天 168、更长 720。
跨度按 `(- end start 1)' 而非 `(- end start)' 计算：`el-chronos-analysis--range' 返回的
END 是「真实上界 + 1 毫秒」（下游 SQL 一律 `ts < END'，加 1 才能包含与上界同毫秒的行），
那 1 毫秒会把整 1 天算成 1.00000001 天，越过 `(<= days 1.0)' 分支落进 168 档 —— `1d' 于是
拿到 168 桶而不是 24。这里必须先把这 1 毫秒减掉，还原真实跨度；**不要「优化」掉这个 -1**。"
  (let ((days (/ (float (max 0 (- end start 1))) (float el-chronos-analysis--ms-per-day))))
    (cond ((<= days 1.0) 24) ((<= days 8.0) 168) (t 720))))

(defun el-chronos-analysis--bucket-span (start end buckets)
  "计算趋势桶宽（毫秒）：至少 1 小时且桶数不超过 BUCKETS（超出时按整小时倍数合并）。
小时数与上一条同样按 `(- end start 1)' 计算：END 含 `el-chronos-analysis--range' 加的
1 毫秒，不减掉会把 720 小时抬成 720.0000003 小时、`ceiling' 得 721，再按 720 桶求整小时
倍数即合并成 **2 小时**（30d / 7d 的桶宽都因此翻倍；7d 的 168 小时被抬成 169 后合并成
2 小时、只剩 84 桶）。这 1 毫秒只为 SQL 右开区间而加，与桶宽计算无关，
**不要「优化」掉这个 -1**。"
  (let* ((buckets (max 1 (or buckets 1)))
         (hours (max 1 (ceiling (/ (float (max 0 (- end start 1)))
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

;;; GC 与内存趋势
(defun el-chronos-analysis-gc-trend (range &optional buckets)
  "窗口 RANGE 内按桶聚合的 GC 与内存趋势。
返回 plist：`:range' 是归一化后的半开区间 (START . END)（毫秒）、`:bucket-span' 是桶宽
（毫秒）、`:buckets' 是按桶起点升序的桶列表、`:gc-total' 是窗口内 `gc-count' 合计、
`:heap-latest' 是窗口内最后一个非空堆大小（无任何堆样本时为 nil）。

`:buckets' 的元素是 `(:bucket START-MS :gc-count N :gc-ms X :heap-bytes N)'：
`:gc-count' / `:gc-ms' 为桶内求和，`:heap-bytes' 取桶内**按 hour_ts 升序最后一个非
NULL 值**（代表该时段末的 Emacs 堆大小；桶内全为 NULL 时 nil）。BUCKETS 省略时与
`el-chronos-analysis-trend' 用同一套默认（`el-chronos-analysis--range-buckets'），并同样
受 `el-chronos-analysis--bucket-span' 的整小时倍数合并约束。SQL 只做窗口过滤、不做聚合
（桶内「最后一个非 NULL」用 SQL 表达需要窗口函数或相关子查询，代价与可读性都更差），
聚合在 Elisp 层完成。空桶不返回；无数据时 `:buckets' 为 nil 而整体仍返回 plist
（与同层其他查询不同：不返回 nil，避免调用方判空分支分叉）。

三点口径必须知晓，否则会把有意为之当 bug 修：
① `:heap-bytes' 只在 Emacs 31.1+ 有值（采集层用 `garbage-collect-heapsize' 守卫，
   函数不存在就不采），更低版本该列恒 NULL，本函数也就恒为 nil —— 不是数据丢失；
② 会话首个采样窗口只建立 `gcs-done' / `gc-elapsed' 基线、按 0 差值入库，因此可能出现
   `gc-count' / `gc-ms' 全 0 的桶（那是基线窗口，不等于「没有发生 GC」）；
③ 桶内堆大小取「最后一个非 NULL」而非求和或平均：heap_bytes 是瞬时量，求和没有意义、
   平均会被采样间隔不均拉偏，只有「时段末的值」能回答「是不是越用越胖」。同一 hour_ts
   若有多个会话行（主键含 session_id），按 session_id 升序取最后一个非 NULL —— 跨会话的
   堆大小本就该由最新一条代表，这个顺序同时保证结果确定、可复现。"
  (el-chronos-analysis--guard 'gc-trend
    (when-let* ((ctx (el-chronos-analysis--bounds range))
                (db (car ctx)) (start (nth 1 ctx)) (end (nth 2 ctx)))
      (let* ((buckets (max 1 (or buckets (el-chronos-analysis--range-buckets start end))))
             (span (el-chronos-analysis--bucket-span start end buckets))
             (table (make-hash-table :test #'equal)))
        ;; 按 hour_ts 升序扫描：后到的非 NULL 覆盖前值 ⟺ 桶内「最后一个非 NULL」
        (dolist (row (el-chronos-analysis--select
                      db
                      (concat "SELECT hour_ts, gc_count, gc_ms, heap_bytes FROM hourly_gc"
                              " WHERE hour_ts >= ? AND hour_ts < ?"
                              " ORDER BY hour_ts, session_id")
                      (list start end)))
          (cl-destructuring-bind (ts count ms heap) row
            (let* ((bucket (- ts (% ts span)))
                   (cell (or (gethash bucket table)
                             (puthash bucket (vector 0 0.0 nil) table))))
              (aset cell 0 (+ (aref cell 0) (or count 0)))
              (aset cell 1 (+ (aref cell 1) (float (or ms 0))))
              (when (numberp heap) (aset cell 2 heap)))))
        (let ((items (cl-sort
                      (cl-loop for bucket being the hash-keys of table
                               using (hash-values cell)
                               collect (list :bucket bucket :gc-count (aref cell 0)
                                             :gc-ms (aref cell 1)
                                             :heap-bytes (aref cell 2)))
                      #'< :key (lambda (i) (plist-get i :bucket)))))
          (list :range (cons start end)
                :bucket-span span
                :buckets items
                :gc-total (cl-loop for i in items sum (plist-get i :gc-count))
                :heap-latest (car (last (delq nil (mapcar (lambda (i)
                                                            (plist-get i :heap-bytes))
                                                          items))))))))))

(defun el-chronos-analysis-gc-attribution (range &optional limit dimension)
  "窗口 RANGE 内的 GC 归因排行。
DIMENSION 取 `command'（默认）或 `mode'：按「GC 发生在哪条命令之后」或「哪个 major-mode
里」聚合。元素 `(:name NAME :gc-count N :gc-ms X :pct P)'，`:pct' 是该 NAME 的 `gc_count'
占**同维度** `gc_count' 总和的百分比（分母取自截断前，不受 LIMIT 影响；跨维度不可比 ——
command 与 mode 两种聚合的分组数量不同，两个百分比序列各自归一）。

**语义限定（不要省略）**：本函数回答「GC **发生在**哪条命令之后」，**不是**「哪条命令
**导致** GC」。归因键是 GC 时刻的 `this-command' × `major-mode'：**GC 时刻没有正在执行的
命令时**（启动期、batch、命令循环**等待输入**期间，含 idle timer / 进程过滤器回调）
`this-command' 为 nil，一律归 \"<none>\"。因此 \"<none>\" 在真实库里常占多数（本机实测，
主要因 GC 多发生在命令循环等待输入的窗口），按命令维度的覆盖率有限 —— 本函数主要给
mode 维度与「命令执行期 GC」用。另：`sum(hourly_gc_attrib.gc_count)' 与
`hourly_gc.gc_count' 只能比大小（≤），**不能**做等式校验：差值 = hook 安装前 /
采集窗口外的 GC。

三条口径（与采集侧一字不差，见 `el-chronos-store-record-gc-attrib'）：
① `hour_ts' 是 **flush 时刻**的整点，不是 GC 发生时刻（跨小时边界时误差 ≤1 个采样窗口，
默认 10 秒）；② 归因键为 `this-command' × `major-mode'，两者为 nil 时写 \"<none>\" ——
\"<none>\" 是唯一哨兵，与真空串 \"\" 不是一回事；③ 数据自 schema v5 起才采集，老库该表为空，
本函数返回 nil（那不是「没有 GC」，是「没有归因数据」）。

LIMIT 默认 15，在 SQL 内截断（排序按 `gc_count' 降序，同分再比 `gc_ms' 降序、名字升序，
保证输出可复现）。无数据、数据库打不开或查询失败时返回 nil。"
  (el-chronos-analysis--guard 'gc-attribution
    (when-let* ((ctx (el-chronos-analysis--bounds range))
                (db (car ctx)) (start (nth 1 ctx)) (end (nth 2 ctx)))
      (let* ((window (list start end))
             ;; 维度只能取白名单里的两列之一：列名不能用 `?' 占位（SQL 里那是值不是
             ;; 标识符），因此用 pcase 选**两个固定字符串**，绝不把参数拼进 SQL
             (column (pcase dimension ('mode "mode") (_ "command")))
             ;; 分母单独取一条标量：SQL 的 LIMIT 作用于分组结果，截断后 sum 出来的只是
             ;; 榜单内部的合计，拿它当分母会让 `:pct' 随 LIMIT 变化（同一 name 两次查询
             ;; 给出两个占比，等于不可比）
             (total (or (caar (el-chronos-analysis--select
                               db
                               "SELECT coalesce(sum(gc_count), 0) FROM hourly_gc_attrib\
 WHERE hour_ts >= ? AND hour_ts < ?"
                               window))
                        0))
             (rows (el-chronos-analysis--select
                    db
                    (concat "SELECT " column ", sum(gc_count), sum(gc_ms)"
                            " FROM hourly_gc_attrib"
                            " WHERE hour_ts >= ? AND hour_ts < ?"
                            " GROUP BY " column
                            " ORDER BY sum(gc_count) DESC, sum(gc_ms) DESC, "
                            column " ASC LIMIT ?")
                    (append window (list (max 1 (or limit 15)))))))
        ;; 新表尚无数据（老库 / 刚升级）时 ROWS 为 nil —— 返回 nil 而不是空列表，与
        ;; `top-functions' / `slow-commands' 这些「窗口排行类」查询同形
        (when rows
          (cl-loop for (name count ms) in rows
                   collect (list :name name
                                 :gc-count (or count 0)
                                 :gc-ms (float (or ms 0))
                                 :pct (el-chronos-analysis--pct count total))))))))

;;; 进程资源趋势
(defun el-chronos-analysis--avg (total n)
  "TOTAL 除以 N 的均值；N 非正或非数字时返回 nil。
除数为 0 时返回 nil 而不用 0 冒充：「没有样本」与「样本值全为 0」是两件事，
用 0 顶替会让「负载采集全失败」看起来像「系统空闲」。"
  (when (and (numberp total) (numberp n) (> n 0))
    (/ (float total) (float n))))

(defun el-chronos-analysis-resource-trend (range &optional buckets)
  "窗口 RANGE 内按桶聚合的**进程资源**趋势（CPU 占用率 / RSS / 线程数 / 系统负载）。
返回 plist：`:range' 是归一化后的半开区间 (START . END)（毫秒）、`:bucket-span' 是桶宽
（毫秒）、`:buckets' 是按桶起点升序的桶列表；窗口级汇总键 `:cpu-ms-total' /
`:wall-ms-total' / `:cpu-pct-avg' / `:rss-kb-max' / `:rss-kb-avg' /
`:threads-max' / `:load1-avg' / `:load5-avg' / `:load15-avg' / `:samples'
与桶内字段口径一致（`:cpu-pct-avg' 对应桶内的 `:cpu-pct'）。

`:buckets' 的元素是 `(:bucket START-MS :cpu-ms X :wall-ms X :cpu-pct P
:rss-kb-max N :rss-kb-avg X :threads-max N :load1-avg X :load5-avg X
:load15-avg X :samples N)'。

单位（I4 只约束时间）：`:cpu-ms' / `:wall-ms' 为毫秒；`:rss-kb-*' 为 KB（**不是时间**）、
`:threads-max' 为线程计数、`:load*-avg' 为系统负载值（1/5/15 分钟平均）—— 后三者不受
I4 约束，改动时不要顺手「统一成毫秒」。

计算口径：桶起点取 `(- hour_ts (% hour_ts span))'，SPAN 来自
`el-chronos-analysis--bucket-span'（与 `el-chronos-analysis-trend' 同一套默认桶数与
整小时倍数合并，BUCKETS 省略时同样按 `el-chronos-analysis--range-buckets' 取默认值）。
同一桶可能有多个 session 行（`hourly_resources' 主键是 (hour_ts, session_id)）：
`:cpu-ms' / `:wall-ms' / `:samples' 跨行求和，`:rss-kb-max' / `:threads-max' 跨行取大，
`:rss-kb-avg' 的分子（各行 `rss_kb_sum'）跨行求和。SQL 只做窗口过滤与排序
（`ORDER BY hour_ts, session_id`）、不做聚合，聚合在 Elisp 层完成（与
`el-chronos-analysis-gc-trend' 同款取舍）。空桶不返回；无数据时 `:buckets' 为 nil 而
整体仍返回 plist（不返回 nil：调用方按同一套键读取，不必为「空」再分叉一条分支）。

三点口径必须知晓，否则会把有意为之当 bug 修：
① **`:rss-kb-avg' / `:load*-avg' 的分母是 `load_n'，不是采样窗口数**：`load_n' 只在
   「本窗口成功取到 `load-average'' 时 +1。若某桶内负载采集全部失败（`load-average'
   抛错或平台不支持），`load_n' 为 0 → 均值返回 **nil**，而同一行的 `:rss-kb-max' /
   `:threads-max' 仍有值（它们不依赖 `load_n'）。这是能力边界的诚实表达：不得用
   `:rss-kb-max' 冒充均值，也不得用 0 冒充（0 的含义是「观测到了，值为 0」）；
② **`:cpu-pct' 是窗口内 CPU 时间占比，不是瞬时利用率**：它等于「本窗口进程 CPU 时间
   增量 / 墙钟增量 × 100」。多个窗口累加后仍是同一比率，因此跨桶、跨会话先求和再相除是
   安全的（与「对百分比取算术平均」不同，后者会因各桶分母不同而失真）；
③ **首窗口无数据**：采集侧首个采样窗口只建立 CPU / 墙钟基线、不写库（与 `hourly_gc'
   同口径），所以会话启动后的第一个桶可能缺失 —— 不等于「那一刻 CPU 为 0」。"
  (el-chronos-analysis--guard 'resource-trend
    (when-let* ((ctx (el-chronos-analysis--bounds range))
                (db (car ctx)) (start (nth 1 ctx)) (end (nth 2 ctx)))
      (let* ((buckets (max 1 (or buckets (el-chronos-analysis--range-buckets start end))))
             (span (el-chronos-analysis--bucket-span start end buckets))
             ;; 每个桶一个向量：[cpu-ms wall-ms rss-max rss-sum threads-max
             ;;                  load1-sum load5-sum load15-sum load-n]
             (table (make-hash-table :test #'equal)))
        (dolist (row (el-chronos-analysis--select
                      db
                      (concat "SELECT hour_ts, cpu_ms, wall_ms, rss_kb_max, rss_kb_sum,"
                              " threads_max, load1_sum, load5_sum, load15_sum, load_n"
                              " FROM hourly_resources"
                              " WHERE hour_ts >= ? AND hour_ts < ?"
                              " ORDER BY hour_ts, session_id")
                      (list start end)))
          (cl-destructuring-bind (ts cpu wall rss-max rss-sum threads
                                     load1 load5 load15 load-n)
              row
            (let* ((bucket (- ts (% ts span)))
                   (cell (or (gethash bucket table)
                             (puthash bucket
                                      (vector 0.0 0.0 nil 0 nil 0.0 0.0 0.0 0)
                                      table))))
              (aset cell 0 (+ (aref cell 0) (float (or cpu 0))))
              (aset cell 1 (+ (aref cell 1) (float (or wall 0))))
              ;; 峰值类列：NULL 表示「从未观测到」，因此不参与取大，也不落成 0
              (when (numberp rss-max)
                (aset cell 2 (if (numberp (aref cell 2))
                                 (max (aref cell 2) rss-max)
                               rss-max)))
              (when (numberp rss-sum) (aset cell 3 (+ (aref cell 3) rss-sum)))
              (when (numberp threads)
                (aset cell 4 (if (numberp (aref cell 4))
                                 (max (aref cell 4) threads)
                               threads)))
              (when (numberp load1) (aset cell 5 (+ (aref cell 5) (float load1))))
              (when (numberp load5) (aset cell 6 (+ (aref cell 6) (float load5))))
              (when (numberp load15) (aset cell 7 (+ (aref cell 7) (float load15))))
              (aset cell 8 (+ (aref cell 8) (or load-n 0))))))
        (let ((items (cl-sort
                      (cl-loop for bucket being the hash-keys of table
                               using (hash-values cell)
                               collect (list :bucket bucket
                                             :cpu-ms (aref cell 0)
                                             :wall-ms (aref cell 1)
                                             :cpu-pct (el-chronos-analysis--pct
                                                       (aref cell 0) (aref cell 1))
                                             :rss-kb-max (aref cell 2)
                                             :rss-kb-avg (el-chronos-analysis--avg
                                                          (aref cell 3) (aref cell 8))
                                             :threads-max (aref cell 4)
                                             :load1-avg (el-chronos-analysis--avg
                                                         (aref cell 5) (aref cell 8))
                                             :load5-avg (el-chronos-analysis--avg
                                                         (aref cell 6) (aref cell 8))
                                             :load15-avg (el-chronos-analysis--avg
                                                          (aref cell 7) (aref cell 8))
                                             :samples (aref cell 8)))
                      #'< :key (lambda (i) (plist-get i :bucket))))
              (cpu-total 0.0) (wall-total 0.0) (rss-sum-total 0)
              (load1-total 0.0) (load5-total 0.0) (load15-total 0.0) (samples-total 0)
              (rss-max nil) (threads-max nil))
          ;; 窗口汇总取自桶单元（求和与取大与顺序无关，故 hash 遍历顺序无影响）
          (cl-loop for cell being the hash-values of table
                   do (setq cpu-total (+ cpu-total (aref cell 0))
                            wall-total (+ wall-total (aref cell 1))
                            rss-sum-total (+ rss-sum-total (aref cell 3))
                            load1-total (+ load1-total (aref cell 5))
                            load5-total (+ load5-total (aref cell 6))
                            load15-total (+ load15-total (aref cell 7))
                            samples-total (+ samples-total (aref cell 8)))
                   when (numberp (aref cell 2))
                   do (setq rss-max (if (numberp rss-max)
                                        (max rss-max (aref cell 2))
                                      (aref cell 2)))
                   when (numberp (aref cell 4))
                   do (setq threads-max (if (numberp threads-max)
                                            (max threads-max (aref cell 4))
                                          (aref cell 4))))
          (list :range (cons start end)
                :bucket-span span
                :buckets items
                :cpu-ms-total cpu-total
                :wall-ms-total wall-total
                :cpu-pct-avg (el-chronos-analysis--pct cpu-total wall-total)
                :rss-kb-max rss-max
                :rss-kb-avg (el-chronos-analysis--avg rss-sum-total samples-total)
                :threads-max threads-max
                :load1-avg (el-chronos-analysis--avg load1-total samples-total)
                :load5-avg (el-chronos-analysis--avg load5-total samples-total)
                :load15-avg (el-chronos-analysis--avg load15-total samples-total)
                :samples samples-total))))))

(defun el-chronos-analysis-resource-summary (range)
  "窗口 RANGE 内的**进程资源**汇总 plist（供概览卡片，避免前端加载全部桶）。
返回 `(:cpu-pct P :cpu-ms X :wall-ms X :rss-kb-max N :rss-kb-avg X
:threads-max N :load1-avg X :load5-avg X :load15-avg X :samples N)'；
各键口径与 `el-chronos-analysis-resource-trend' 的窗口级汇总字段**完全一致**
（同一套口径两处实现，改动时须同步，否则报告与 Web 会给出两个数）。

与 trend 的差别只有一个：**无数据时返回 nil**（与 `el-chronos-analysis-overview' 等
「窗口汇总类」查询一致）—— 概览卡片需要区分「无数据」与「有数据但全 0」，而趋势需要
稳定键集合以便绘图。实现上走一条 SQL 聚合（而非复用 trend 再取汇总键），以减少把窗口内
全部行搬进 Elisp 的开销；NULL 处理与 trend 同款：`MAX(rss_kb_max)' / `MAX(threads_max)'
跳过 NULL（全 NULL 时得 nil），均值分母用 `SUM(load_n)' 且为 0 时结果为 nil。
峰值 / 均值类字段的单位不是时间：`:rss-kb-*' 是 KB、`:threads-max' 是计数、
`:load*-avg' 是负载值；`:cpu-ms' / `:wall-ms' 才是毫秒。"
  (el-chronos-analysis--guard 'resource-summary
    (when-let* ((ctx (el-chronos-analysis--bounds range))
                (db (car ctx)) (start (nth 1 ctx)) (end (nth 2 ctx)))
      (let ((row (car (el-chronos-analysis--select
                       db
                       (concat "SELECT count(*), coalesce(sum(cpu_ms), 0),"
                               " coalesce(sum(wall_ms), 0), max(rss_kb_max),"
                               " sum(rss_kb_sum), max(threads_max),"
                               " sum(load1_sum), sum(load5_sum), sum(load15_sum),"
                               " coalesce(sum(load_n), 0)"
                               " FROM hourly_resources"
                               " WHERE hour_ts >= ? AND hour_ts < ?")
                       (list start end)))))
        ;; count = 0 时其余列全是 NULL / 0，必须返回 nil 而不是「全 0 的 plist」
        (when (and row (> (or (nth 0 row) 0) 0))
          (cl-destructuring-bind (_count cpu wall rss-max rss-sum threads
                                         load1 load5 load15 load-n)
              row
            (list :cpu-pct (el-chronos-analysis--pct cpu wall)
                  :cpu-ms (float (or cpu 0))
                  :wall-ms (float (or wall 0))
                  :rss-kb-max rss-max
                  :rss-kb-avg (el-chronos-analysis--avg rss-sum load-n)
                  :threads-max threads
                  :load1-avg (el-chronos-analysis--avg load1 load-n)
                  :load5-avg (el-chronos-analysis--avg load5 load-n)
                  :load15-avg (el-chronos-analysis--avg load15 load-n)
                  :samples (or load-n 0))))))))

;;; 采样覆盖率
(defun el-chronos-analysis--sampling-interval-ms ()
  "profiler 采样间隔的毫秒数，取自 `el-chronos-sampling-interval-ns'。
不要硬编码 10：该 defcustom 可被用户改写，硬编码会让覆盖率的分子恒按 10 ms 折算，
在改过采样间隔的配置上给出错误结论。"
  (/ (float el-chronos-sampling-interval-ns) 1000000.0))

(defun el-chronos-analysis-sampling-coverage (range)
  "窗口 RANGE 内 profiler 采样对真实 CPU 的覆盖率（判断采样结论是否可信）。
返回 plist：
  :sampling-interval-ms  采样间隔（毫秒，取自 `el-chronos-sampling-interval-ns'）
  :samples-total         参与计算的样本总数
  :samples-cpu-ms        `:samples-total' × `:sampling-interval-ms'
  :cpu-ms                参与计算的进程 CPU 总时间（毫秒）
  :wall-ms               参与计算的墙钟总时间（毫秒）
  :coverage-pct          `:samples-cpu-ms' / `:cpu-ms' × 100
  :cpu-pct               `:cpu-ms' / `:wall-ms' × 100
  :hours-covered         参与计算的 (hour_ts, session_id) 桶数
  :hours-requested       窗口内有采样数据的桶数
无可用数据时返回 nil。

只在**两侧都有数据**的桶上计算：`hourly_functions'（样本）与 `hourly_resources'
（cpu_ms / wall_ms）按 (hour_ts, session_id) 做 INNER JOIN。两张表的覆盖时段可能
差两个数量级（实测某库 `hourly_resources' 只有 9 分钟数据而 `hourly_functions'
覆盖 24 小时），把两侧总和直接相除会得出荒谬结论（覆盖率百分之几千）。

因此**必须同时读 `:hours-covered' 与 `:hours-requested'**：前者是 JOIN 后的桶数、
后者是 `hourly_functions' 在窗口内的桶数。两者差得多即说明分母不齐、结论不可用 ——
只报百分比而不报这两个数等于隐藏了这个前提。

多桶一律**加权**：各桶分子（样本数 × 采样间隔）与分母（cpu_ms）分别求和后再相除，
不是各桶比率的算术平均（各桶分子分母都不同，平均会失真）。

`:coverage-pct' 明显低于 100 说明采样折算出的 CPU 时间被系统性低估，此时
`el-chronos-analysis-top-functions' 一类的占比**结构**仍可用，但绝对耗时不可信。
分母为 0 时 `:coverage-pct' / `:cpu-pct' 均为 0.0（不除零）；「窗口内有桶」
与「窗口内无桶」由返回值是否为 nil 区分。

`:cpu-pct' 的口径与 TD-28 呼应：`cpu_ms / wall_ms' 有两种读法 —— 占**单核**
（本函数取这个，与 `docs/schema.org' 的既有示例一致）或占**全部核心**（再除以
`(num-processors)'）。多线程进程的 CPU 时间可超过墙钟，按前者读数会大于 100%，
按后者才是「机器算力占用」。本函数只给原始比率，不做归一化。"
  (el-chronos-analysis--guard 'sampling-coverage
    (when-let* ((ctx (el-chronos-analysis--bounds range))
                (db (car ctx)) (start (nth 1 ctx)) (end (nth 2 ctx)))
      (let* ((row (car (el-chronos-analysis--select
                        db
                        (concat "SELECT coalesce(sum(f.samples), 0),"
                                " coalesce(sum(r.cpu_ms), 0),"
                                " coalesce(sum(r.wall_ms), 0), count(*)"
                                " FROM (SELECT hour_ts, session_id,"
                                " sum(samples) samples FROM hourly_functions"
                                " WHERE hour_ts >= ? AND hour_ts < ?"
                                " GROUP BY hour_ts, session_id) f"
                                " JOIN hourly_resources r"
                                " ON r.hour_ts = f.hour_ts"
                                " AND r.session_id = f.session_id")
                        (list start end))))
             (covered (or (nth 3 row) 0)))
        ;; count(*) = 0 → 两侧没有交集（含「只有一侧有数据」），分子分母都无意义
        (when (> covered 0)
          (let ((requested (or (caar (el-chronos-analysis--select
                                      db
                                      (concat "SELECT count(*) FROM"
                                              " (SELECT hour_ts, session_id"
                                              " FROM hourly_functions"
                                              " WHERE hour_ts >= ? AND hour_ts < ?"
                                              " GROUP BY hour_ts, session_id)")
                                      (list start end)))
                               0)))
            (cl-destructuring-bind (samples cpu wall _covered) row
              (let* ((interval (el-chronos-analysis--sampling-interval-ms))
                     (samples-ms (* (float samples) interval))
                     (cpu-ms (float cpu))
                     (wall-ms (float wall)))
                (list :sampling-interval-ms interval
                      :samples-total samples
                      :samples-cpu-ms samples-ms
                      :cpu-ms cpu-ms
                      :wall-ms wall-ms
                      :coverage-pct (el-chronos-analysis--pct samples-ms cpu-ms)
                      :cpu-pct (el-chronos-analysis--pct cpu-ms wall-ms)
                      :hours-covered covered
                      ;; requested 查询异常（返回 nil）时退回 covered：否则会读出
                      ;; 「参与桶数 > 窗口内桶数」这种自相矛盾的组合
                      :hours-requested (max requested covered))))))))))

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

(defun el-chronos-analysis-inclusive-functions (range &optional limit)
  "窗口 RANGE 内按「栈包含样本数」降序的函数列表。
元素 `(:function NAME :samples N :pct P :stacks K)'：`:samples' 是该函数出现在其中的
栈样本数之和（包含口径，不是 leaf / self 口径），`:stacks' 是涉及的不同栈条数，
`:pct' 是 `:samples' 占**窗口内全部栈样本数**的百分比（分母取自截断前，不受 LIMIT
影响）。LIMIT 默认 100。

与 `el-chronos-analysis-top-functions' 的差别：后者是 self 口径（`samples' 只数 leaf），
成本记在被调用的 built-in 帧上时会把调用者严重低估；本函数按「出现在多少比例采样栈里」
计，故只作为**中间帧**出现的函数（`hourly_functions.samples' 恒为 0、`total_ms' > 0）
同样能被找出。

候选集取自窗口内 `hourly_functions' 的**全部**函数，SQL 侧按 `sum(total_ms)' 降序只为
输出确定性：**不**加 `samples > 0' 过滤，也不按候选数截断——中间帧的 `samples' 恒为 0、
`self_ms' 也恒为 0，任何 self 口径的过滤/排序都会把它们整批丢掉；而本实现的匹配成本与
候选数无关（候选只进哈希表），截断只会引入静默漏计。

匹配口径：把 `hourly_stacks.stack_json' 文本按双引号切分、取其中的字符串字段，与候选名
**整名相等**才算命中——等价于 SQL 的 `instr(stack_json, '\"' || function || '\"') > 0'，
故 `foo' 不会误命中 `foo-bar'。

实现路径与实测（真实库 1 天窗口：1721 条不同栈 / 约 47 万栈样本 / 3897 个候选）：
单条 JOIN 的 SQL 版（`instr' 边界匹配 + 候选子查询）**24500 ms**；改为一次取出栈文本、
在 Lisp 里单遍扫描后，纯匹配部分 **17–25 ms**，**整函数 29 ms（字节编译）/ 60 ms
（解释执行）**。中途试过的两个变体（逐候选 `string-search' 268 ms、逐候选
`string-match-p' + `regexp-quote' 737 ms）也都能用，但比单遍扫描慢一个数量级。

已知边界：
1. 函数名自身含 `\"` 或 `\\` 时 JSON 会转义，切出的字段与原名不再相等 → 这类函数
   **静默漏计**（含 `\"` 时理论上还可能切出伪字段，实际概率极低）。
2. 候选集来自 `hourly_functions'，该表按 top-N 淘汰：只出现在 `hourly_stacks'、
   已被淘汰的函数帧不会出现在结果里。
3. 不排除 \"Automatic GC\"（它是真实的采样帧，包含法下代表 GC 期间的整段栈）。"
  (el-chronos-analysis--guard 'inclusive-functions
    (when-let* ((ctx (el-chronos-analysis--bounds range))
                (db (car ctx)) (start (nth 1 ctx)) (end (nth 2 ctx)))
      (let* ((window (list start end))
             (total (or (caar (el-chronos-analysis--select
                               db
                               "SELECT coalesce(sum(samples), 0) FROM hourly_stacks\
 WHERE hour_ts >= ? AND hour_ts < ?"
                               window))
                        0))
             ;; 栈先按文本去重再累加：同一栈在窗口内可能跨小时 / 跨会话出现多次
             (stacks (el-chronos-analysis--select
                      db
                      "SELECT stack_json, sum(samples) FROM hourly_stacks\
 WHERE hour_ts >= ? AND hour_ts < ? GROUP BY stack_json"
                      window))
             (candidates (el-chronos-analysis--select
                          db
                          "SELECT function FROM hourly_functions\
 WHERE hour_ts >= ? AND hour_ts < ? GROUP BY function ORDER BY sum(total_ms) DESC"
                          window))
             (samples (make-hash-table :test #'equal :size (max 64 (length candidates))))
             (stack-count (make-hash-table :test #'equal :size (max 64 (length candidates)))))
        ;; 候选集必须先落表：「是否候选」用 `gethash' 判存在性，值为 0 也算命中
        (dolist (row candidates)
          (puthash (car row) 0 samples)
          (puthash (car row) 0 stack-count))
        (dolist (row stacks)
          (let ((json (nth 0 row))
                (n (or (nth 1 row) 0))
                (index 0)
                (hits nil))
            ;; `json-serialize' 产出的栈是紧凑数组 `[\"a\",\"b\"]'：按 `\"' 切分后
            ;; 第 0/2/4… 段是 `[' / `,' / `]' 等结构，第 1/3/5… 段才是帧名
            (dolist (token (split-string json "\"" nil))
              (when (and (= 1 (logand index 1))
                         (gethash token samples))
                (push token hits))
              (setq index (1+ index)))
            ;; 同一栈里同名帧可能出现多次（递归 / advice 链 / 同名闭包归一）：必须先
            ;; 按栈去重再累加，否则该栈的样本数被重复计入，`:pct' 甚至可能超过 100
            (dolist (token (delete-dups hits))
              (puthash token (+ (gethash token samples) n) samples)
              (puthash token (1+ (gethash token stack-count)) stack-count))))
        (let ((rows (cl-loop for name being the hash-keys of samples
                             using (hash-values n)
                             when (> (gethash name stack-count) 0)
                             collect (list :function name
                                           :samples n
                                           :pct (el-chronos-analysis--pct n total)
                                           :stacks (gethash name stack-count)))))
          ;; 同 `:samples' 时按 `:stacks' 降序、再按名字升序，保证输出可复现
          ;; （哈希表遍历顺序不确定，不定序会让同分条目的名次随机漂移）
          (el-chronos-analysis--take
           (cl-sort rows
                    (lambda (a b)
                      (let ((sa (plist-get a :samples))
                            (sb (plist-get b :samples)))
                        (cond ((/= sa sb) (> sa sb))
                              ((/= (plist-get a :stacks) (plist-get b :stacks))
                               (> (plist-get a :stacks) (plist-get b :stacks)))
                              (t (string< (plist-get a :function)
                                          (plist-get b :function)))))))
           (or limit 100)))))))

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

;;; 启动分解
(defconst el-chronos-analysis--startup-phase-order
  '("mode-start" "after-init" "startup" "first-idle")
  "启动分解里阶段锚点的固定展示顺序。
四个锚点由采集层按「确定性 3 个 + 可选 1 个」写入（`mode-start' 确定性写入；
`after-init' / `startup' 仅在 mode 启动时它们还没到时条件注册；`first-idle' 可选）。
缺失的锚点**不输出 nil 行** —— 采不到就是采不到，填 nil 只会让读表的人以为「耗时未知」
而不是「未记录」。")

(defconst el-chronos-analysis--startup-load-prefix "load:"
  "`startup_phases' 里包加载明细的阶段名前缀（完整阶段名为 \"load:<library>\"）。")

(defun el-chronos-analysis--startup-empty (session-id)
  "构造启动分解的空结果（与有数据时**同构**，避免调用方判空分支分叉）。
SESSION-ID 原样回填：显式传了 id 就回该 id，未传（自动选会话）时为 nil。
`:started-at' / `:startup-ms' / `:phases' / `:loads' 全为 nil。"
  (list :session-id session-id :started-at nil :startup-ms nil :phases nil :loads nil))

(defun el-chronos-analysis--startup-session (db session-id)
  "在 DB 上定位启动分解的目标会话，返回 (ID STARTED-AT STARTUP-MS) 或 nil。
SESSION-ID 为数字时按 id 精确取；为 nil 时取**有启动数据**的最近会话 ——
判据是 `startup_ms' 非空 **或** `startup_phases' 有行（两者任一即可：总耗时可能因
早期版本 / 补写未落库而缺失，而阶段锚点仍在；只按 `startup_ms' 筛会漏掉这种会话）。
排序用 `started_at' 降序，同毫秒时用 id 降序兜底，保证结果确定可复现。"
  (if (numberp session-id)
      (car (el-chronos-analysis--select
            db "SELECT id, started_at, startup_ms FROM sessions WHERE id = ?"
            (list session-id)))
    (car (el-chronos-analysis--select
          db (concat "SELECT s.id, s.started_at, s.startup_ms FROM sessions s"
                     " WHERE s.startup_ms IS NOT NULL"
                     " OR EXISTS (SELECT 1 FROM startup_phases p"
                     "            WHERE p.session_id = s.id)"
                     " ORDER BY s.started_at DESC, s.id DESC LIMIT 1")
          nil))))

(defun el-chronos-analysis--startup-anchors (phases)
  "把 PHASES（`(PHASE MS)' 列表）整理成固定顺序的锚点列表，并丢弃 `load:' 明细。
顺序由 `el-chronos-analysis--startup-phase-order' 决定（缺的跳过）；顺序表之外的非
`load:' 阶段（将来新增的锚点）按耗时降序追加在末尾 —— 宁可多显示一条，也不要静默丢弃
采集层新写入的阶段。"
  (let ((table (make-hash-table :test #'equal)) (others nil))
    (dolist (row phases)
      (let ((phase (car row)) (ms (float (or (nth 1 row) 0))))
        (when (and (stringp phase)
                   (not (string-prefix-p el-chronos-analysis--startup-load-prefix phase)))
          (if (member phase el-chronos-analysis--startup-phase-order)
              (puthash phase ms table)
            (push (list phase ms) others)))))
    (append (cl-loop for phase in el-chronos-analysis--startup-phase-order
                     when (gethash phase table)
                     collect (list phase (gethash phase table)))
            (cl-sort others #'> :key #'cl-second))))

(defun el-chronos-analysis--startup-loads (phases)
  "从 PHASES（`(PHASE MS)' 列表）里取出 `load:<library>' 明细，按耗时降序。
返回值元素是 `(LIBRARY MS)'，前缀 `load:' 已去掉。同耗时按库名升序，保证顺序确定。"
  (let ((prefix el-chronos-analysis--startup-load-prefix)
        (loads nil))
    (dolist (row phases)
      (let ((phase (car row)))
        (when (and (stringp phase) (string-prefix-p prefix phase))
          (push (list (substring phase (length prefix)) (float (or (nth 1 row) 0))) loads))))
    (cl-sort loads (lambda (a b)
                     (if (= (cl-second a) (cl-second b))
                         (string< (car a) (car b))
                       (> (cl-second a) (cl-second b)))))))

(defun el-chronos-analysis-startup-breakdown (&optional session-id)
  "取会话 SESSION-ID 的启动耗时分解；SESSION-ID 为 nil 时取最近一次有启动数据的会话。
「最近一次有启动数据」= `started_at' 最大且 `startup_ms' 非空 **或** `startup_phases'
有行的会话（见 `el-chronos-analysis--startup-session'）。

返回 plist：`:session-id' 会话 id、`:started-at' 会话启动时刻（epoch 毫秒）、
`:startup-ms' 该会话的总启动耗时（毫秒，未写入时 nil）、`:phases' 阶段锚点列表
`((PHASE MS) ...)'（固定顺序 `mode-start' / `after-init' / `startup' / `first-idle'，
缺的跳过）、`:loads' 包加载明细 `((LIBRARY MS) ...)'（`phase' 以 \"load:\" 开头的行，
按 ms 降序，前缀已去掉）。

三条口径必须知晓，否则会把有意为之当 bug 修：
① **近似归因**：包加载耗时是采集层用 `after-load-functions' 相邻两次回调的**时间差**
   记录的，差值里含前一个文件的收尾逻辑与它触发的钩子执行 —— 它不是精确耗时；
② **覆盖范围受加载时机限制**：用户通常在 init 末尾才启用 mode，此时启动已基本结束，
   于是只能记录 mode 启动之后发生的 load。**mode 在启动结束后启用时只有 `mode-start'**
   一个锚点，报告节标题必须据此标注覆盖范围，不许把近似数据冒充全程；
③ `:startup-ms' 与 `:phases' 是两套来源：前者来自 `before-init-time' → `after-init-time'
   的差值（store 层写入），后者来自采集打点。任一方缺失都不影响另一方。

无该会话、无数据或数据库不可用时返回**同构空结构**（不返回 nil，避免下游判空分叉）；
查询出错由 `el-chronos-analysis--guard' 告警并返回 nil（同其他查询的降级约定）。"
  (el-chronos-analysis--guard 'startup-breakdown
    (when-let* ((db (el-chronos-analysis--db)))
      (if-let* ((row (el-chronos-analysis--startup-session db session-id)))
          (cl-destructuring-bind (id started startup) row
            (let ((phases (el-chronos-analysis--select
                           db "SELECT phase, ms FROM startup_phases WHERE session_id = ?"
                           (list id))))
              (list :session-id id
                    :started-at started
                    :startup-ms (and (numberp startup) startup)
                    :phases (el-chronos-analysis--startup-anchors phases)
                    :loads (el-chronos-analysis--startup-loads phases))))
        (el-chronos-analysis--startup-empty session-id)))))

;;; 采集健康（自监控计数）
(defconst el-chronos-analysis--health-keys
  '((:dropped-commands . "dropped-commands")
    (:dropped-events . "dropped-events")
    (:flush-failures . "flush-failures")
    (:flush-count . "flush-count")
    (:flush-ms . "flush-ms")
    (:sample-misses . "sample-misses"))
  "返回 plist 键 → `hourly_health.key' 字符串的映射。
键名在 store 层是字符串枚举（`el-chronos-store-record-health' 的 docstring），
此处集中映射一次，避免拼写漂移；库里的未知键（将来新增）不影响已有键的取值。")

(defconst el-chronos-analysis--health-bad-keys
  '("dropped-commands" "dropped-events" "flush-failures" "sample-misses")
  "参与 `:ok-p' 判定的「坏消息」键。
`:ok-p' 为 t 读作「本期没有丢失/失败」：丢弃命令、丢弃事件、flush 失败、采样窗口丢失
全为 0。`flush-count' / `flush-ms' 是正常运转的度量，不算坏消息。")

(defun el-chronos-analysis-health (range)
  "窗口 RANGE 内采集器自监控计数的汇总。
返回 plist：`:dropped-commands' `:dropped-events' `:flush-failures' `:flush-count'
`:sample-misses' 均为整数（库内 REAL，取整）；`:flush-ms' 为求和后的毫秒数（浮点）；
`:flush-avg-ms' 为 `flush-ms / flush-count'（count 为 0 时 nil，避免除零）；
`:ok-p' 为「坏消息键」全 0（见 `el-chronos-analysis--health-bad-keys'）；
`:rows' 为窗口内 `hourly_health' 的**行数**（区分「没有坏消息」与「采集器根本没写过数据」）。

口径三条：
① 每个键对窗口内的行**求和**（`hourly_health' 的 upsert 语义是累加，同键多行只可能来自
   多会话/多小时）；
② **无数据时各项为 0 且 `:ok-p' 为 t** —— 「没有坏消息」不等于「有数据」：库里一条
   health 行都没有时本函数同样返回 `:ok-p' 为 t。要区分二者请读 `:rows'（0 = 没数据），
   报告层据 `:rows' 为 0 显示「本期无采集数据」，不走 `:ok-p' 分支（CSV 导出件里对应
   一行 `rows'）；
③ 计数是 **eventual** 值：flush 失败时写库本身也失败，失败计数只能在下一次成功 flush
   时补写（store 层设计 6 的已知悖论），因此失败可能滞后一个 flush 周期才出现在本函数
   的结果里。
数据库打不开或查询出错时返回 nil（`el-chronos-analysis--guard' 的降级约定）。"
  (el-chronos-analysis--guard 'health
    (when-let* ((ctx (el-chronos-analysis--bounds range))
                (db (car ctx)) (start (nth 1 ctx)) (end (nth 2 ctx)))
      (let ((table (make-hash-table :test #'equal))
            (rows (or (caar (el-chronos-analysis--select
                             db "SELECT count(*) FROM hourly_health\
 WHERE hour_ts >= ? AND hour_ts < ?"
                             (list start end)))
                      0)))
        (dolist (row (el-chronos-analysis--select
                      db (concat "SELECT key, sum(value) FROM hourly_health"
                                 " WHERE hour_ts >= ? AND hour_ts < ? GROUP BY key")
                      (list start end)))
          (puthash (car row) (float (or (nth 1 row) 0)) table))
        (let* ((value (lambda (key)
                        (or (gethash (alist-get key el-chronos-analysis--health-keys) table)
                            0.0)))
               (flush-count (funcall value :flush-count))
               (flush-ms (funcall value :flush-ms)))
          (list :dropped-commands (truncate (funcall value :dropped-commands))
                :dropped-events (truncate (funcall value :dropped-events))
                :flush-failures (truncate (funcall value :flush-failures))
                :flush-count (truncate flush-count)
                :flush-ms flush-ms
                :flush-avg-ms (if (> flush-count 0) (/ flush-ms flush-count) nil)
                :sample-misses (truncate (funcall value :sample-misses))
                :ok-p (cl-every (lambda (key)
                                  (zerop (funcall value key)))
                                '(:dropped-commands :dropped-events
                                  :flush-failures :sample-misses))
                :rows rows))))))

;;; 配置变更（git-head / config-sig 的会话序列）
(defun el-chronos-analysis-config-history (range)
  "窗口 RANGE 内各会话的变更标记序列，按启动时间**升序**（时间线顺序）。
返回 plist：`:sessions' 元素是 `(:id N :started-at MS
:git-head STR|nil :config-sig STR|nil :changed BOOL)' 的 plist 列表、
`:changes' 是变化次数。

`:changed' 表示**与前一个会话相比** `(git-head, config-sig)' 有变化，取值 t / nil。
**`nil' 有两种含义，且本层不区分二者**：① 第一个会话（没有「前一个」，无从比较）；
② 与前一会话相比标记无差异。调用方若需区分，请自行判断会话序号（`:sessions' 的首个
元素即第一个会话）。引入三态（`:n/a' / nil / t）属行为变更、未实施，见技术债 TD-20。
两个键都为 nil 的两个相邻会话视为**没变化** —— 两次都取不到标记时无法断言配置变了，
谎报变化比漏报更糟（会让人以为「那天改了什么」）。
`:changes' 只统计 `:changed' 为 t 的会话数，等于「标记发生变化的次数」（首会话 `:changed'
恒为 nil，故不计入）。

`git-head' / `config-sig' 取自 `session_meta' 的 KV（store 层写入：取不到就**不写行**），
因此 nil 表示「未取到」而非「取了但为空」。空库返回 `(:sessions nil :changes 0)`
（不返回 nil，与其他查询的降级约定一致）；查询出错返回 nil。"
  (el-chronos-analysis--guard 'config-history
    (when-let* ((ctx (el-chronos-analysis--bounds range))
                (db (car ctx)) (start (nth 1 ctx)) (end (nth 2 ctx)))
      (let ((rows (el-chronos-analysis--select
                   db (concat "SELECT s.id, s.started_at,"
                              " (SELECT m.value FROM session_meta m"
                              "   WHERE m.session_id = s.id AND m.key = ?),"
                              " (SELECT m.value FROM session_meta m"
                              "   WHERE m.session_id = s.id AND m.key = ?)"
                              " FROM sessions s"
                              " WHERE s.started_at >= ? AND s.started_at < ?"
                              " ORDER BY s.started_at, s.id")
                   (list "git-head" "config-sig" start end)))
            (previous nil)
            (changes 0)
            (items nil))
        (dolist (row rows)
          (cl-destructuring-bind (id started head sig) row
            (let* ((marks (list head sig))
                   (changed (and previous (not (equal marks previous)))))
              (when changed (setq changes (1+ changes)))
              (push (list :id id :started-at started
                          :git-head head :config-sig sig :changed changed)
                    items)
              (setq previous marks))))
        (list :sessions (nreverse items) :changes changes)))))

;;; 阻塞事件、命令外漂移与单条下钻
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

(defun el-chronos-analysis-drift-trend (range &optional buckets)
  "窗口 RANGE 内按桶聚合的「命令外停转」（drift）趋势。
返回 plist：`:range' 是归一化后的半开区间 (START . END)（毫秒）、`:bucket-span' 是桶宽
（毫秒）、`:buckets' 是按桶起点升序的桶列表、`:drift-total' 是窗口内 drift 次数合计、
`:ms-total' 是窗口内累计停转毫秒、`:slowest-ms' 是窗口内单次最长停转（三者无数据时为
0 / 0.0 / 0.0）。

`:buckets' 的元素是 `(:bucket START-MS :count N :total-ms X :max-ms Y)'：
`:count' 与 `:total-ms' 为桶内求和、`:max-ms' 取桶内最大值。BUCKETS 省略时与
`el-chronos-analysis-gc-trend' 用同一套默认（`el-chronos-analysis--range-buckets'），并
同样受 `el-chronos-analysis--bucket-span' 的整小时倍数合并约束。SQL 只做窗口过滤、不做
聚合，聚合在 Elisp 层完成（与 gc-trend 同款取舍）。空桶不返回；无数据时 `:buckets' 为
nil 而整体仍返回 plist（不返回 nil，避免调用方判空分支分叉）。

三点口径必须知晓，否则会把有意为之当 bug 修：
① **语义是「命令之外停转」**：`hourly_drift' 只统计命令执行之外的停转（心跳判定，命令
   开始前与结算时都会重置基线，把命令执行时间从间隔里切掉）。命令**内部**的停转由
   `commands' 表的耗时天然覆盖、经 `slow_events(kind='command')' 呈现，属「慢命令」节。
   因此 `hourly_drift' 的时长与 `commands' 的耗时**不可相加、也不该相加** —— 两者是
   不相交集合，相加会得到重复的总卡顿时长；
② `:total-ms' 与 `:max-ms' 都是**高估值**：单次时长以「发现时距上次基线的间隔」计时，
   每次最多多算一个心跳间隔（默认 250ms，见 `el-chronos-heartbeat-seconds'），所以
   `:max-ms' 减掉至多一个间隔才是真实停转下界；
③ `hourly_drift' 属六张永久保留的聚合表之一（不受 `el-chronos-retention-days' 约束），
   长时间窗口的趋势不会被保留清理削平 —— 但也因此不会随时间自动瘦身，需手动 purge。"
  (el-chronos-analysis--guard 'drift-trend
    (when-let* ((ctx (el-chronos-analysis--bounds range))
                (db (car ctx)) (start (nth 1 ctx)) (end (nth 2 ctx)))
      (let* ((buckets (max 1 (or buckets (el-chronos-analysis--range-buckets start end))))
             (span (el-chronos-analysis--bucket-span start end buckets))
             (table (make-hash-table :test #'equal)))
        ;; 两列累加、一列取最值 —— 与 `el-chronos-store--sql-upsert-drift' 的三列语义
        ;; 一一对应，因此跨会话、跨批次的同一小时行在这里同样是「求和 + 最大值」
        (dolist (row (el-chronos-analysis--select
                      db
                      (concat "SELECT hour_ts, count, total_ms, max_ms FROM hourly_drift"
                              " WHERE hour_ts >= ? AND hour_ts < ?"
                              " ORDER BY hour_ts, session_id")
                      (list start end)))
          (cl-destructuring-bind (ts count total maximum) row
            (let* ((bucket (- ts (% ts span)))
                   (cell (or (gethash bucket table)
                             (puthash bucket (vector 0 0.0 0.0) table))))
              (aset cell 0 (+ (aref cell 0) (or count 0)))
              (aset cell 1 (+ (aref cell 1) (float (or total 0))))
              (aset cell 2 (max (aref cell 2) (float (or maximum 0)))))))
        (let ((items (cl-sort
                      (cl-loop for bucket being the hash-keys of table
                               using (hash-values cell)
                               collect (list :bucket bucket :count (aref cell 0)
                                             :total-ms (aref cell 1) :max-ms (aref cell 2)))
                      #'< :key (lambda (i) (plist-get i :bucket)))))
          (list :range (cons start end)
                :bucket-span span
                :buckets items
                :drift-total (cl-loop for i in items sum (plist-get i :count))
                :ms-total (cl-loop for i in items sum (plist-get i :total-ms))
                ;; 空列表时 `maximize' 无返回值 → 显式兜底 0.0，保持「无数据也是数字」
                :slowest-ms (or (cl-loop for i in items maximize (plist-get i :max-ms))
                                0.0)))))))

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
