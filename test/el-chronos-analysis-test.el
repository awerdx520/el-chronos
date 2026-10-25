;;; el-chronos-analysis-test.el --- 聚合查询层 ERT 测试  -*- lexical-binding: t; -*-

;; 全部用例在临时库上插入固定 fixture（时间基准为当前整点），再断言查询结果。
;; 数据库一律经 `el-chronos-test-with-db' 建在临时目录，退出即删。

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'sqlite)
(require 'el-chronos)
(require 'el-chronos-store)
(require 'el-chronos-analysis)
(eval-and-compile
  ;; `make lint' 只带 `-L .'：编译期把本文件所在目录（test/）加进 load-path，
  ;; 否则下面的 `require' 找不到 helper；运行期由 `-L test' 提供，本段跳过。
  (when (bound-and-true-p byte-compile-current-file)
    (add-to-list 'load-path (file-name-directory byte-compile-current-file))))
(require 'el-chronos-test-helper)

;;; 用例内共用的小夹具

(defun el-chronos-analysis-test--window ()
  "返回 24 小时窗口 (START . END)，以当前整点为基准，覆盖当前小时。"
  (let ((base (el-chronos-test--hour-ts)))
    (cons (- base (* 3600000 23)) (+ base 3600000))))

(defun el-chronos-analysis-test--seed-functions ()
  "插入三条函数聚合行：magit 60 ms / 6 样本、org 30 ms / 3 样本、GC 10 ms / 1 样本。"
  (let ((hour (el-chronos-test--hour-ts)))
    (el-chronos-test--insert-function hour "fn-aaa" "/tmp/a.el" "magit" 60.0 60.0 6)
    (el-chronos-test--insert-function hour "fn-bbb" "/tmp/b.el" "org" 30.0 30.0 3)
    (el-chronos-test--insert-function hour "Automatic GC" nil nil 10.0 10.0 1)))

;;; 时间范围

(ert-deftest el-chronos-analysis-test-range-upper-bound ()
  "显式区间的上界 +1ms，使与上界同毫秒的记录仍落在窗口内；反向区间自动交换。"
  (let ((bounds (el-chronos-analysis--range (cons 1000 5000))))
    (should (= 1000 (car bounds)))
    (should (= 5001 (cdr bounds))))
  (let ((bounds (el-chronos-analysis--range (cons 5000 1000))))
    (should (= 1000 (car bounds)))
    (should (= 5001 (cdr bounds))))
  (el-chronos-test-with-db
    (el-chronos-test--insert-command 5000 "edge-cmd" 1.0)
    (should (= 1 (plist-get (el-chronos-analysis-overview (cons 1000 5000)) :commands)))
    ;; 上界是 5000（不含）时同一行被排除，证明「包含」来自 +1ms
    (should (= 0 (plist-get (el-chronos-analysis-overview (cons 1000 4999)) :commands)))))

(ert-deftest el-chronos-analysis-test-bucket-planning ()
  "桶规划：≤1 天 24 桶、≤8 天 168 桶、更长 720 桶；桶宽恒为整小时倍数。"
  (should (= 24 (el-chronos-analysis--range-buckets 0 (* 24 3600000))))
  (should (= 168 (el-chronos-analysis--range-buckets 0 (* 7 86400000))))
  (should (= 720 (el-chronos-analysis--range-buckets 0 (* 30 86400000))))
  (should (= 3600000 (el-chronos-analysis--bucket-span 0 (* 24 3600000) 24)))
  ;; 24 小时窗口切 6 桶：桶宽为 4 小时的整小时倍数（不会小于 1 小时）
  (should (= (* 4 3600000) (el-chronos-analysis--bucket-span 0 (* 24 3600000) 6)))
  (should (= 3600000 (el-chronos-analysis--bucket-span 0 (* 24 3600000) 100))))

;;; 概览

(ert-deftest el-chronos-analysis-test-overview ()
  "概览各字段：命令数、阻塞合计、慢命令数、样本合计、库大小、启动中位数、会话数。"
  (el-chronos-test-with-db
    (let* ((window (el-chronos-analysis-test--window))
           (start (car window))
           (base (el-chronos-test--hour-ts))
           (baseline (el-chronos-test--count "sessions")))
      (dotimes (i 10)
        (el-chronos-test--insert-session (- base 1000 (* i 1000)) 500.0))
      (el-chronos-test--insert-command (+ start 1000) "slow-cmd" 300.0)
      (el-chronos-test--insert-command (+ start 2000) "fast-cmd" 1.0)
      (el-chronos-test--insert-slow-event (+ start 3000) 3000.0 "block")
      (el-chronos-analysis-test--seed-functions)
      (let ((overview (el-chronos-analysis-overview window)))
        (should (= 2 (plist-get overview :commands)))
        (should (= 3000.0 (plist-get overview :blocked-ms)))
        (should (= 1 (plist-get overview :slow-commands)))
        (should (= 10 (plist-get overview :samples)))
        (should (> (plist-get overview :db-size) 0))
        (should (numberp (plist-get overview :startup-ms)))
        (should (= 500.0 (plist-get overview :startup-ms)))
        (should (= (+ baseline 10) (plist-get overview :sessions)))))))

;;; 函数热点

(ert-deftest el-chronos-analysis-test-top-functions ()
  "热点按 self 降序，pct 分母为样本数且合计 ≈100，默认排除 \"Automatic GC\"。"
  (el-chronos-test-with-db
    (el-chronos-analysis-test--seed-functions)
    (let* ((window (el-chronos-analysis-test--window))
           (items (el-chronos-analysis-top-functions window)))
      (should (equal '("fn-aaa" "fn-bbb")
                     (mapcar (lambda (i) (plist-get i :function)) items)))
      (should (equal "magit" (plist-get (nth 0 items) :package)))
      (should (= 6 (plist-get (nth 0 items) :samples)))
      (should (= 60.0 (plist-get (nth 0 items) :self-ms)))
      (should (< 66.0 (plist-get (nth 0 items) :pct) 67.0))
      (should (< 33.0 (plist-get (nth 1 items) :pct) 34.0))
      (should (< 99.9 (cl-loop for i in items sum (plist-get i :pct)) 100.1))
      ;; 显式包含 GC 时多一行，且 pct 分母同步变大
      (let ((with-gc (el-chronos-analysis-top-functions window nil t)))
        (should (= 3 (length with-gc)))
        (should (equal "Automatic GC" (plist-get (nth 2 with-gc) :function)))
        (should (= 60.0 (plist-get (nth 0 with-gc) :pct)))))))

;;; 慢命令

(ert-deftest el-chronos-analysis-test-slow-commands ()
  "慢命令按窗口内总耗时降序，并统计 aborted 条数；`names' 返回去重升序命令名。"
  (el-chronos-test-with-db
    (let* ((window (el-chronos-analysis-test--window))
           (start (car window)))
      (el-chronos-test--insert-command (+ start 1000) "foo" 300.0)
      (el-chronos-test--insert-command (+ start 2000) "foo" 400.0 nil nil nil "aborted")
      (el-chronos-test--insert-command (+ start 3000) "bar" 250.0)
      (el-chronos-test--insert-command (+ start 4000) "baz" 1.0)
      (let ((items (el-chronos-analysis-slow-commands window)))
        (should (equal '("foo" "bar" "baz")
                       (mapcar (lambda (i) (plist-get i :name)) items)))
        (should (= 2 (plist-get (nth 0 items) :count)))
        (should (= 700.0 (plist-get (nth 0 items) :total-ms)))
        (should (= 400.0 (plist-get (nth 0 items) :max-ms)))
        (should (= 350.0 (plist-get (nth 0 items) :avg-ms)))
        (should (= 1 (plist-get (nth 0 items) :aborted)))
        (should (= 0 (plist-get (nth 1 items) :aborted)))
        ;; LIMIT 生效
        (should (= 1 (length (el-chronos-analysis-slow-commands window 1)))))
      (should (equal '("bar" "baz" "foo") (el-chronos-analysis-names))))))

;;; 包占比

(ert-deftest el-chronos-analysis-test-package-breakdown ()
  "包占比把 unknown 与 GC 恒排在末尾（先 unknown 后 GC），pct 合计 ≈100。"
  (el-chronos-test-with-db
    (let ((hour (el-chronos-test--hour-ts)))
      (el-chronos-analysis-test--seed-functions)
      ;; 归因失败：package 为 NULL
      (el-chronos-test--insert-function hour "fn-ccc" nil nil 5.0 5.0 1))
    (let ((items (el-chronos-analysis-package-breakdown
                  (el-chronos-analysis-test--window))))
      (should (equal '("magit" "org" "unknown" "GC")
                     (mapcar (lambda (i) (plist-get i :package)) items)))
      (should (< 99.9 (cl-loop for i in items sum (plist-get i :pct)) 100.1))
      (should (= 60.0 (plist-get (nth 0 items) :self-ms)))
      ;; LIMIT 只截断正常条目，unknown / GC 仍保留在末尾
      (let ((limited (el-chronos-analysis-package-breakdown
                      (el-chronos-analysis-test--window) 1)))
        (should (equal '("magit" "unknown" "GC")
                       (mapcar (lambda (i) (plist-get i :package)) limited)))))))

;;; D3：samples=0 / self_ms=0 的纯中间帧不进榜
(ert-deftest el-chronos-analysis-test-zero-sample-rows-filtered ()
  "只作为中间帧出现的行（samples=0 且 self_ms=0）不进热点榜与包占比（D3）。
这类行 `total_ms' 有值但 self 恒为 0，留在榜里只会占据条目、产生 0% 占比；
调用链信息由 `el-chronos-analysis-stacks' 提供。"
  (el-chronos-test-with-db
    (let ((hour (el-chronos-test--hour-ts)))
      (el-chronos-analysis-test--seed-functions)
      ;; 纯中间帧：total_ms 90 但 samples = 0（self 必为 0），包归到 magit
      (el-chronos-test--insert-function hour "fn-mid" "/tmp/mid.el" "magit" 0.0 90.0 0)
      ;; 只以中间帧身份出现的包：该包所有行 self_ms 都是 0
      (el-chronos-test--insert-function hour "fn-zero" "/tmp/z.el" "zero-only" 0.0 40.0 0))
    (let* ((window (el-chronos-analysis-test--window))
           (items (el-chronos-analysis-top-functions window)))
      (should (equal '("fn-aaa" "fn-bbb")
                     (mapcar (lambda (i) (plist-get i :function)) items)))
      (should (cl-every (lambda (i) (> (plist-get i :samples) 0)) items))
      ;; 分母也排除 samples=0 的行，故 pct 合计仍约为 100
      (should (< 99.9 (cl-loop for i in items sum (plist-get i :pct)) 100.1)))
    (let ((packages (el-chronos-analysis-package-breakdown
                     (el-chronos-analysis-test--window))))
      (should (equal '("magit" "org" "GC")
                     (mapcar (lambda (i) (plist-get i :package)) packages)))
      (should (cl-every (lambda (i) (> (plist-get i :self-ms) 0)) packages))
      (should (< 99.9 (cl-loop for i in packages sum (plist-get i :pct)) 100.1)))))

;;; 趋势

(ert-deftest el-chronos-analysis-test-trend ()
  "趋势按桶聚合样本 / 慢命令 / 阻塞，桶起点为整小时倍数且条数受 BUCKETS 约束。"
  (el-chronos-test-with-db
    (let* ((window (el-chronos-analysis-test--window))
           (start (car window)))
      (el-chronos-test--insert-command (+ start 1000) "slow-a" 300.0)
      (el-chronos-test--insert-command (+ start 2000) "slow-b" 400.0)
      (el-chronos-test--insert-command (+ start 3600000) "fast-cmd" 1.0)
      (el-chronos-test--insert-slow-event (+ start 4000) 2500.0 "block")
      (el-chronos-test--insert-function (el-chronos-test--hour-ts)
                                        "fn-a" nil "pkg" 1.0 1.0 7)
      (let ((items (el-chronos-analysis-trend window)))
        (should (= 2 (length items)))   ; 只有两个桶有数据，空桶不返回
        (should (cl-every (lambda (i) (zerop (mod (plist-get i :bucket) 3600000)))
                          items))
        (should (= 2 (cl-loop for i in items sum (plist-get i :slow-commands))))
        (should (= 1 (cl-loop for i in items sum (plist-get i :blocked))))
        (should (= 7 (cl-loop for i in items sum (plist-get i :samples))))
        (should (equal (sort (mapcar (lambda (i) (plist-get i :bucket)) items) #'<)
                       (mapcar (lambda (i) (plist-get i :bucket)) items))))
      ;; 显式要求 6 桶：条数不超过 6，粒度更粗但汇总数据不变
      (let ((coarse (el-chronos-analysis-trend window 6)))
        (should (<= (length coarse) 6))
        (should (= 2 (cl-loop for i in coarse sum (plist-get i :slow-commands))))
        (should (cl-every (lambda (i) (zerop (mod (plist-get i :bucket) 3600000)))
                          coarse))))))

;;; GC 与内存趋势

(defun el-chronos-analysis-test--gc-hours (range buckets count)
  "返回 RANGE / BUCKETS 下**同一个桶内**连续 COUNT 个 hour_ts（升序）。
先按实现的口径（`el-chronos-analysis--bucket-span'）算出桶宽，再把起点向上对齐到桶
边界，于是 `(- ts (% ts span))' 对返回的每个 ts 都相同 —— 无需猜测桶对齐方式。"
  (let* ((bounds (el-chronos-analysis--range range))
         (span (el-chronos-analysis--bucket-span (car bounds) (cdr bounds) buckets))
         (b0 (* span (ceiling (/ (car bounds) (float span))))))
    (cl-loop for i below count collect (+ b0 (* i 3600000)))))

(ert-deftest el-chronos-analysis-test-gc-trend-aggregates-buckets ()
  "GC 趋势按桶对 gc-count / gc-ms 求和（同小时多会话也累加），桶升序且为整小时倍数。"
  (el-chronos-test-with-db
    (let* ((window (el-chronos-analysis-test--window))
           (hour (el-chronos-test--hour-ts))
           (prev (- hour 3600000))
           (trend nil))
      ;; 上一小时：1 次 / 7.5ms / 堆 1000；当前小时两个会话：3+4 次、12.5+5.0ms
      (el-chronos-test--insert-gc prev 1 7.5 1000)
      (el-chronos-test--insert-gc hour 3 12.5 nil)
      (el-chronos-test--insert-gc hour 4 5.0 nil 999)
      (setq trend (el-chronos-analysis-gc-trend window))
      (let ((items (plist-get trend :buckets)))
        (should (= 2 (length items)))          ; 空桶不返回
        (should (equal (mapcar (lambda (i) (plist-get i :bucket)) items) (list prev hour)))
        (should (cl-every (lambda (i) (zerop (mod (plist-get i :bucket) 3600000))) items))
        (should (= 1 (plist-get (car items) :gc-count)))
        (should (= 7.5 (plist-get (car items) :gc-ms)))
        (should (= 1000 (plist-get (car items) :heap-bytes)))
        (should (= 7 (plist-get (nth 1 items) :gc-count)))   ; 3 + 4，跨会话累加
        (should (= 17.5 (plist-get (nth 1 items) :gc-ms)))   ; 12.5 + 5.0
        (should-not (plist-get (nth 1 items) :heap-bytes))
        (should (= 8 (plist-get trend :gc-total)))
        (should (= 1000 (plist-get trend :heap-latest)))
        (should (equal (cons (- hour (* 3600000 23)) (+ hour 3600001))
                       (plist-get trend :range)))
        (should (integerp (plist-get trend :bucket-span)))))))

(ert-deftest el-chronos-analysis-test-gc-trend-heap-takes-last-non-nil ()
  "桶内堆大小取按 hour_ts 升序「最后一个非 NULL」值：后行 NULL 不覆盖前值，后行有值则覆盖。"
  (el-chronos-test-with-db
    (let* ((range (el-chronos-analysis-test--window))
           ;; 桶数压到 2 → 桶宽 > 1 小时，两个连续小时落在同一桶
           (hours (el-chronos-analysis-test--gc-hours range 2 2))
           (h1 (nth 0 hours)) (h2 (nth 1 hours))
           (span (plist-get (el-chronos-analysis-gc-trend range 2) :bucket-span)))
      (should (< (- h2 h1) span))           ; 前提：两行确实同桶
      ;; 情形 a：前有值、后 NULL → 取前值（NULL 不是「归零」）
      (el-chronos-test--insert-gc h1 1 1.0 1000)
      (el-chronos-test--insert-gc h2 1 1.0 nil)
      (let ((items (plist-get (el-chronos-analysis-gc-trend range 2) :buckets)))
        (should (= 1 (length items)))
        (should (= 1000 (plist-get (car items) :heap-bytes))))
      ;; 情形 b：改成前 NULL、后有值 → 取后值
      (el-chronos-test--exec "UPDATE hourly_gc SET heap_bytes = NULL WHERE hour_ts = ?"
                             (list h1))
      (el-chronos-test--exec "UPDATE hourly_gc SET heap_bytes = 2000 WHERE hour_ts = ?"
                             (list h2))
      (let ((items (plist-get (el-chronos-analysis-gc-trend range 2) :buckets)))
        (should (= 1 (length items)))
        (should (= 2000 (plist-get (car items) :heap-bytes)))
        (should (= 2000 (plist-get (el-chronos-analysis-gc-trend range 2)
                                   :heap-latest))))
      ;; 情形 c（判别用例）：两行都有值且值不同 → 必须取后者；取前者会在这里变红
      (el-chronos-test--exec "UPDATE hourly_gc SET heap_bytes = 1000 WHERE hour_ts = ?"
                             (list h1))
      (el-chronos-test--exec "UPDATE hourly_gc SET heap_bytes = 2000 WHERE hour_ts = ?"
                             (list h2))
      (let ((items (plist-get (el-chronos-analysis-gc-trend range 2) :buckets)))
        (should (= 2000 (plist-get (car items) :heap-bytes)))))))

(ert-deftest el-chronos-analysis-test-gc-trend-empty-range ()
  "无数据时返回与有数据同构的空 plist（不是 nil），`:buckets' 为 nil。"
  (el-chronos-test-with-db
    (let* ((window (el-chronos-analysis-test--window))
           (empty (el-chronos-analysis-gc-trend window)))
      (should (listp empty))
      (should-not (plist-get empty :buckets))
      (should (= 0 (plist-get empty :gc-total)))
      (should-not (plist-get empty :heap-latest))
      (should (consp (plist-get empty :range)))
      (should (integerp (plist-get empty :bucket-span)))
      ;; 有数据时键集合完全一致（同构：调用方不必分叉判空）
      (el-chronos-test--insert-gc (el-chronos-test--hour-ts) 2 3.0 4096)
      (let ((filled (el-chronos-analysis-gc-trend window)))
        (should (equal (cl-loop for (key _v) on empty by #'cddr collect key)
                       (cl-loop for (key _v) on filled by #'cddr collect key)))
        (should (plist-get filled :buckets))))))

(ert-deftest el-chronos-analysis-test-gc-trend-all-null-heap ()
  "所有行 heap_bytes 为 NULL 时每桶堆大小为 nil、`:heap-latest' 为 nil，且不报错。"
  (el-chronos-test-with-db
    (let* ((window (el-chronos-analysis-test--window))
           (hour (el-chronos-test--hour-ts)))
      (el-chronos-test--insert-gc hour 2 5.0 nil)
      (el-chronos-test--insert-gc (- hour 3600000) 1 2.0 nil)
      (let ((trend (el-chronos-analysis-gc-trend window)))
        (should (= 2 (length (plist-get trend :buckets))))
        (should (cl-every (lambda (i) (null (plist-get i :heap-bytes)))
                          (plist-get trend :buckets)))
        (should-not (plist-get trend :heap-latest))
        (should (= 3 (plist-get trend :gc-total)))))))

;;; 热力图

(ert-deftest el-chronos-analysis-test-heatmap ()
  "热力图只取 dimension='command' 的行，`:duration-ms' 取 usage 的耗时合计。"
  (el-chronos-test-with-db
    (let* ((window (el-chronos-analysis-test--window))
           (hour (el-chronos-test--hour-ts)))
      (el-chronos-test--insert-usage hour "command" "foo" 5 1000.0)
      (el-chronos-test--insert-usage hour "mode" "emacs-lisp-mode" 9 200.0)
      (el-chronos-test--insert-usage hour "project" "proj" 7 300.0)
      (let ((items (el-chronos-analysis-heatmap window)))
        (should (= 1 (length items)))
        (should (equal "foo" (plist-get (car items) :command)))
        (should (= 5 (plist-get (car items) :count)))
        (should (= 1000.0 (plist-get (car items) :duration-ms)))
        (should (= hour (plist-get (car items) :bucket)))))))

;;; 调用栈

(ert-deftest el-chronos-analysis-test-stacks ()
  "调用栈按样本降序，`:stack' 解析为帧名列表，pct 合计 ≈100。"
  (el-chronos-test-with-db
    (let* ((window (el-chronos-analysis-test--window))
           (hour (el-chronos-test--hour-ts)))
      (el-chronos-test--insert-stack hour "[\"leaf\",\"mid\",\"root\"]" 3)
      (el-chronos-test--insert-stack hour "[\"other\"]" 1)
      (let ((items (el-chronos-analysis-stacks window)))
        (should (= 2 (length items)))
        (should (equal '("leaf" "mid" "root") (plist-get (nth 0 items) :stack)))
        (should (= 3 (plist-get (nth 0 items) :samples)))
        (should (= 75.0 (plist-get (nth 0 items) :pct)))
        (should (= 25.0 (plist-get (nth 1 items) :pct)))
        (should (= 100.0 (cl-loop for i in items sum (plist-get i :pct))))))))

;;; 阻塞事件与单条下钻

(ert-deftest el-chronos-analysis-test-blocking-events ()
  "阻塞事件列表只含 kind='block'，按耗时降序，mode / project 取自 context。"
  (el-chronos-test-with-db
    (let* ((window (el-chronos-analysis-test--window))
           (start (car window)))
      (el-chronos-test--insert-slow-event (+ start 1000) 800.0 "block" nil nil
                                          "{\"mode\":\"emacs-lisp-mode\",\
\"project\":\"el-chronos\"}")
      (el-chronos-test--insert-slow-event (+ start 2000) 2500.0 "block")
      ;; 命令超阈值属慢命令，不在阻塞列表里
      (el-chronos-test--insert-slow-event (+ start 3000) 9999.0 "command" "cmd")
      (let ((items (el-chronos-analysis-blocking-events window)))
        (should (= 2 (length items)))
        (should (= 2500.0 (plist-get (nth 0 items) :duration-ms)))
        (should (cl-every (lambda (i) (equal "block" (plist-get i :kind))) items))
        (should (equal "emacs-lisp-mode" (plist-get (nth 1 items) :mode)))
        (should (equal "el-chronos" (plist-get (nth 1 items) :project)))))))

(ert-deftest el-chronos-analysis-test-event ()
  "单条下钻解析 stack 与 context；不存在的 ID 返回 nil。"
  (el-chronos-test-with-db
    (let* ((window (el-chronos-analysis-test--window))
           (start (car window)))
      (el-chronos-test--insert-slow-event
       (+ start 1000) 5000.0 "block" nil
       "[\"el-chronos-collect--finish\",\"foo\"]"
       "{\"mode\":\"emacs-lisp-mode\",\"project\":\"el-chronos\"}")
      (let* ((listed (car (el-chronos-analysis-blocking-events window)))
             (event (el-chronos-analysis-event (plist-get listed :id))))
        (should (= 5000.0 (plist-get event :duration-ms)))
        (should (equal "block" (plist-get event :kind)))
        (should (equal '("el-chronos-collect--finish" "foo") (plist-get event :stack)))
        (should (equal "emacs-lisp-mode" (plist-get (plist-get event :context) :mode)))
        (should (equal "el-chronos"
                       (plist-get (plist-get event :context) :project))))
      (should-not (el-chronos-analysis-event 999999))
      (should-not (el-chronos-analysis-event nil)))))

;;; 回归判定

(ert-deftest el-chronos-analysis-test-regressions ()
  "回归判定：命中增长，无增长 / 前窗口为 0 / 样本不足都不误报。"
  (el-chronos-test-with-db
    (let ((el-chronos-regression-window-days 1)
          (el-chronos-regression-min-samples 10)
          (el-chronos-regression-threshold 0.5)
          (base (el-chronos-test--hour-ts))
          (previous (- (el-chronos-test--hour-ts) (* 24 3600000))))
      ;; 命中：self 100 → 200（+100%），两窗口样本数都 ≥ 10
      (el-chronos-test--insert-function base "hot" nil "pkg" 200.0 200.0 20)
      (el-chronos-test--insert-function previous "hot" nil "pkg" 100.0 100.0 20)
      ;; 不命中：没有增长
      (el-chronos-test--insert-function base "cold" nil "pkg" 100.0 100.0 20)
      (el-chronos-test--insert-function previous "cold" nil "pkg" 100.0 100.0 20)
      ;; 不误报：前窗口 self 为 0，无法计算增长（避免除零）
      (el-chronos-test--insert-function base "fresh" nil "pkg" 500.0 500.0 20)
      (el-chronos-test--insert-function previous "fresh" nil "pkg" 0.0 0.0 20)
      ;; 不误报：样本数不足
      (el-chronos-test--insert-function base "tiny" nil "pkg" 900.0 900.0 5)
      (el-chronos-test--insert-function previous "tiny" nil "pkg" 100.0 100.0 5)
      (let ((items (el-chronos-analysis-regressions '7d)))
        (should (equal '("hot") (mapcar (lambda (i) (plist-get i :function)) items)))
        (should (= 1.0 (plist-get (car items) :growth)))
        (should (= 200.0 (plist-get (car items) :current-ms)))
        (should (= 100.0 (plist-get (car items) :previous-ms)))
        (should (= 20 (plist-get (car items) :current-samples)))))))

;;; 会话

(ert-deftest el-chronos-analysis-test-sessions ()
  "会话列表按启动时间降序，`:startup-ms' 直接是毫秒。"
  (el-chronos-test-with-db
    (let* ((window (el-chronos-analysis-test--window))
           (start (car window))
           (id (el-chronos-test--insert-session (+ start 1000) 250.0)))
      (let* ((items (el-chronos-analysis-sessions window))
             (found (cl-find id items :key (lambda (i) (plist-get i :id)))))
        (should found)
        (should (= 250.0 (plist-get found :startup-ms)))
        (should (equal "31.1" (plist-get found :emacs-version)))
        (should (equal "test-host" (plist-get found :host)))))))

;;; 空库降级

(ert-deftest el-chronos-analysis-test-empty-database ()
  "空库上所有查询返回 nil 或 0，不抛错（I6 降级）。"
  (el-chronos-test-with-db
    (let ((window (cons 1000000 2000000)))
      (let ((overview (el-chronos-analysis-overview window)))
        (should (= 0 (plist-get overview :commands)))
        (should (= 0 (plist-get overview :blocked-ms)))
        (should (= 0 (plist-get overview :slow-commands)))
        (should (= 0 (plist-get overview :samples)))
        (should (= 0 (plist-get overview :sessions)))
        (should (or (null (plist-get overview :startup-ms))
                    (numberp (plist-get overview :startup-ms)))))
      (should-not (el-chronos-analysis-top-functions window))
      (should-not (el-chronos-analysis-slow-commands window))
      (should-not (el-chronos-analysis-package-breakdown window))
      (should-not (el-chronos-analysis-trend window))
      (should-not (el-chronos-analysis-heatmap window))
      (should-not (el-chronos-analysis-stacks window))
      (should-not (el-chronos-analysis-blocking-events window))
      (should-not (el-chronos-analysis-sessions window))
      (should-not (el-chronos-analysis-regressions '1d))
      (should-not (el-chronos-analysis-names))
      (should-not (el-chronos-analysis-event 1)))))

(provide 'el-chronos-analysis-test)

;;; el-chronos-analysis-test.el ends here
