;;; el-chronos-report-test.el --- 报告与剖析测试  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Thomas

;; Author: Thomas
;; Keywords: tools, performance
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; T11（单命令剖析）与报告渲染的 ERT 覆盖。原实现只有实现没有测试，本文件补上：
;;
;;   1. `profiler-cpu-log' 形态兼容：hash table（实测形态）与 cons 列表两种输入；
;;      nil / 非法输入一律空结果（不抛错）。
;;   2. self 口径（leaf = `(aref stack 0)'）与栈 JSON 聚合：同 leaf / 同栈合并计数、降序。
;;   3. 包归因：GC 伪函数拦到 "GC"；无源码符号降级 "unknown"；内置函数归到 "built-in"。
;;   4. `--invoke' 的三种 ARGS 形态：nil → `call-interactively'（mock 计数）；
;;      列表 → `apply'（断言实参确实是 3 个，而不是「一个列表」）；单值 → 单个实参。
;;   5. 错误与降级：命令抛错只进报告 `* 错误' 节，调用方不崩；`--save' 在零样本时
;;      不写库；`el-chronos-profile-save' 为 nil 时根本不调用 `--save'。
;;   6. 报告结构：14 个 `* 标题' 节、空库 8 处 `（无数据）'、正文不出现 `nil' 字面量；
;;      新增三节（启动分解 / 采集健康 / 配置变更）各自的有数据与降级渲染，
;;      其中「采集健康」区分「没采集」（`:rows' 为 0）与「没异常」（`:ok-p' 为 t）。
;;   9. 导出：CSV 的 8 个 `# section:' 区块（既有 5 + startup / health / config-history）
;;      与 JSON 的三个新键；断言覆盖行内容而非只认标题。
;;   7. 报告期间抑制自观测阻塞：`--without-block-events' 的绑定/恢复 + 关键行为断言
;;      （重查询后心跳不新增 `block' 行；对照组直接跑重查询则确实会新增）。
;;   8. Web：500 分支不回显内部错误（含绝对路径）、改走 `display-warning'、之后仍可服务；
;;      端口 0 时 message 显示内核实际分配的端口。
;;
;; 约束：数据库一律经 `el-chronos-test-with-db' 建在临时目录（I3），退出即删；不依赖网络
;; （HTTP 只在 `/127.0.0.1'+`:service 0' 上起本地 server，且必关）；不碰运行中的 daemon。
;;
;; 运行：emacs -Q --batch -L . -L test -l test/el-chronos-report-test.el \
;;              -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'json)
(require 'sqlite)
(require 'el-chronos)
(require 'el-chronos-store)
(require 'el-chronos-analysis)
(require 'el-chronos-attrib)
(require 'el-chronos-report)
;; 心跳基线变量与 `--heartbeat'：抑制机制的另一半在采集层，断言必须读它
(require 'el-chronos-collect)
(require 'el-chronos-web)
(eval-and-compile
  ;; `make lint' 只带 `-L .'：编译期把 test/ 加进 load-path 才能 `require' helper
  (when (bound-and-true-p byte-compile-current-file)
    (add-to-list 'load-path (file-name-directory byte-compile-current-file))))
(require 'el-chronos-test-helper)

;;; 辅助

(defun el-chronos-report-test--count-matches (regexp string)
  "返回 REGEXP 在 STRING 中的匹配次数（不依赖 buffer，故不用 `how-many'）。"
  (let ((count 0) (pos 0))
    (while (string-match regexp string pos)
      (setq count (1+ count)
            pos (max (match-end 0) (1+ (match-beginning 0)))))
    count))

(defun el-chronos-report-test--log (&rest spec)
  "把 SPEC（每项是 `(STACK-LIST . COUNT)'）建成 `profiler-cpu-log' 形态的 hash 表。
栈 vector 的索引 0 为 leaf，与采集层实测形态一致。"
  (let ((table (make-hash-table :test #'equal)))
    (dolist (entry spec)
      (puthash (vconcat (car entry)) (cdr entry) table))
    table))

(defun el-chronos-report-test--self-count (rows function)
  "从 `--self-ranking' 结果 ROWS 里取 FUNCTION 的计数；不存在返回 nil。"
  (cdr (assq function rows)))

(defun el-chronos-report-test--seed ()
  "插入一套覆盖报告各节的 fixture：会话、命令、阻塞事件、函数、用法、栈。"
  (let ((hour (el-chronos-test--hour-ts))
        (now (el-chronos-test--now-ms)))
    (el-chronos-test--insert-session now 1200.0)
    (el-chronos-test--insert-command now "save-buffer" 350.0 10.0 "emacs-lisp-mode" "proj" "ok")
    (el-chronos-test--insert-slow-event
     now 900.0 "block" nil "[\"leaf-fn\",\"mid-fn\"]"
     "{\"mode\":\"emacs-lisp-mode\",\"project\":\"proj\"}")
    (el-chronos-test--insert-function hour "leaf-fn" "/tmp/leaf.el" "magit" 60.0 60.0 6)
    (el-chronos-test--insert-usage hour 'command "save-buffer" 3 350.0)
    (el-chronos-test--insert-stack hour "[\"leaf-fn\",\"mid-fn\"]" 5)))

(defun el-chronos-report-test--count-block-events ()
  "当前库中 `kind=\"block\"' 的慢事件行数。"
  (el-chronos-test--scalar "SELECT count(*) FROM slow_events WHERE kind='block'"))

;;; `profiler-cpu-log' 解析

(ert-deftest el-chronos-report-test--log->rows-empty ()
  "LOG 为 nil、非表、空表时一律返回 nil（空剖析按无数据渲染，不抛错）。"
  (should-not (el-chronos-profile--log->rows nil))
  (should-not (el-chronos-profile--log->rows 42))
  (should-not (el-chronos-profile--log->rows "not-a-log"))
  (should-not (el-chronos-profile--log->rows (make-hash-table :test #'equal)))
  ;; 表里全是非法条目（栈不是 vector / 计数非正）时同样被过滤掉
  (let ((table (make-hash-table :test #'equal)))
    (puthash 'not-a-vector 5 table)
    (puthash (vector 'leaf) 0 table))
  (should-not (el-chronos-profile--log->rows
               (let ((table (make-hash-table :test #'equal)))
                 (puthash 'not-a-vector 5 table)
                 (puthash (vector 'leaf) 0 table)
                 table))))

(ert-deftest el-chronos-report-test--log->rows-hash-desc ()
  "hash table 形态的日志转成 `(STACK . COUNT)' 列表并按 COUNT 降序。"
  (let* ((log (el-chronos-report-test--log (cons (list 'leaf-a 'root) 2)
                                          (cons (list 'leaf-b 'root) 9)))
         (rows (el-chronos-profile--log->rows log)))
    (should (= 2 (length rows)))
    (should (= 9 (cdr (nth 0 rows))))
    (should (= 2 (cdr (nth 1 rows))))
    (should (equal (vector 'leaf-b 'root) (car (nth 0 rows))))))

(ert-deftest el-chronos-report-test--log->rows-cons-form ()
  "兼容 `(STACK . COUNT)' 的 cons 列表（旧形态），并与 hash 形态同样降序。"
  (let ((rows (el-chronos-profile--log->rows
               (list (cons (vector 'x 'root) 1) (cons (vector 'y 'root) 4)))))
    (should (= 2 (length rows)))
    (should (= 4 (cdr (nth 0 rows))))
    (should (= 1 (cdr (nth 1 rows))))))

;;; self / 栈 / 包 聚合

(ert-deftest el-chronos-report-test--self-ranking-leaf ()
  "`[leaf mid root]'×10 → leaf 计 10；不同栈的同 leaf 合并；非符号 leaf 忽略。"
  (let* ((rows (el-chronos-profile--log->rows
                (el-chronos-report-test--log (cons (list 'leaf 'mid 'root) 10)
                                             (cons (list 'leaf 'other 'root) 5)
                                             (cons (list 'other-leaf 'root) 3)
                                             (cons (vector "string-leaf" 'root) 7))))
         (ranking (el-chronos-profile--self-ranking rows)))
    (should (= 15 (el-chronos-report-test--self-count ranking 'leaf)))
    (should (= 3 (el-chronos-report-test--self-count ranking 'other-leaf)))
    ;; 字符串 leaf 不是符号，归因不了，不进 self 排行
    (should (= 2 (length ranking)))
    ;; 降序：leaf(15) 在 other-leaf(3) 之前
    (should (eq 'leaf (caar ranking)))))

(ert-deftest el-chronos-report-test--stack-ranking-aggregate ()
  "同栈（含帧序不同）合并计数，栈 JSON 与 `hourly_stacks' 同口径（leaf 在前）。"
  (let* ((rows (el-chronos-profile--log->rows
                ;; 用 cons 列表形态构造重复栈（hash 形态的键唯一，表达不了重复样本）
                (list (cons (vector 'leaf 'root) 4)
                      (cons (vector 'leaf 'root) 6)
                      (cons (vector 'root 'leaf) 2))))
         (ranking (el-chronos-profile--stack-ranking rows)))
    (should (= 3 (length rows)))
    (should (= 2 (length ranking)))
    (should (= 10 (cdr (nth 0 ranking))))
    (should (equal '("leaf" "root")
                   (append (json-parse-string (car (nth 0 ranking)) :array-type 'list) nil)))
    (should (= 2 (cdr (nth 1 ranking))))
    (should (equal '("root" "leaf")
                   (append (json-parse-string (car (nth 1 ranking)) :array-type 'list) nil)))))

(ert-deftest el-chronos-report-test--package-of ()
  "GC 伪函数归 \"GC\"；无源码符号归 \"unknown\"；内置函数归 \"built-in\"。"
  (should (equal el-chronos-analysis--gc-label
                 (el-chronos-profile--package-of el-chronos-analysis--gc-function)))
  (should (equal "GC" (el-chronos-profile--package-of "Automatic GC")))
  (should (equal "unknown" (el-chronos-profile--package-of nil)))
  (should (equal "unknown"
                 (el-chronos-profile--package-of 'el-chronos--no-such-function-xyz)))
  (should (equal "built-in" (el-chronos-profile--package-of 'save-buffer))))

;;; `--invoke' 的三种 ARGS 形态

(ert-deftest el-chronos-report-test--invoke-nil-calls-interactively ()
  "ARGS 为 nil 时走 `call-interactively'（mock 计数），而不是无参 `funcall'。"
  (let ((calls 0) (target nil))
    (cl-letf (((symbol-function 'call-interactively)
               (lambda (command &optional _record-flag _keys)
                 (setq calls (1+ calls) target command)
                 nil)))
      (should-not (el-chronos-profile--invoke 'ignore nil)))
    (should (= 1 calls))
    (should (eq 'ignore target))
    ;; 非命令（lambda）没有交互规格：不能走 `call-interactively'，退回无参 funcall
    (let ((ran 0))
      (cl-letf (((symbol-function 'call-interactively)
                 (lambda (&rest _) (error "不该被调用"))))
        (should-not (el-chronos-profile--invoke (lambda () (setq ran (1+ ran))) nil)))
      (should (= 1 ran)))))

(ert-deftest el-chronos-report-test--invoke-list-applies-args ()
  "ARGS 为列表时作为实参列表 `apply'：`(1 2 3)' 必须收到 3 个实参。"
  (let ((received 'none))
    (should-not (el-chronos-profile--invoke
                 (lambda (&rest args) (setq received args)) '(1 2 3)))
    (should (equal '(1 2 3) received))
    (should (= 3 (length received)))))

(ert-deftest el-chronos-report-test--invoke-single-value ()
  "ARGS 为非 nil 非列表（单值）时作为**单个**实参传给 `funcall'。"
  (let ((received 'none))
    (should-not (el-chronos-profile--invoke
                 (lambda (arg) (setq received arg)) 42))
    (should (equal 42 received))
    ;; 单值形态也不会被当成列表展开
    (let ((count 0))
      (should-not (el-chronos-profile--invoke
                   (lambda (&rest args) (setq count (length args))) "one"))
      (should (= 1 count)))))

(ert-deftest el-chronos-report-test--invoke-error-captured ()
  "命令抛错时返回错误对象（不向调用方抛），错误信息进报告 `* 错误' 节。"
  (let ((err (el-chronos-profile--invoke
              (lambda () (error "boom-xyz")) nil)))
    (should err)
    (should (equal 'error (car err)))
    (should (string-match-p "boom-xyz" (el-chronos-profile--error-text err)))
    ;; 报告渲染不崩，且带出错误文案
    (let ((content (el-chronos-profile--content
                    'demo (list :elapsed-ms 5.0 :gc-ms 0.0 :gc-count 0 :samples 0
                                :rows nil :sampling t :error err))))
      (should (stringp content))
      (should (string-match-p "\\* 错误" content))
      (should (string-match-p "boom-xyz" content)))))

(ert-deftest el-chronos-report-test--run-does-not-propagate ()
  "`--run' 面对抛错的命令只把错误放进 :error，返回值结构完整。"
  (let ((result (el-chronos-profile--run (lambda () (error "run-boom")) nil)))
    (should (plist-get result :error))
    (should (string-match-p "run-boom"
                            (el-chronos-profile--error-text (plist-get result :error))))
    (should (numberp (plist-get result :elapsed-ms)))
    (should (>= (or (plist-get result :samples) 0) 0))))

;;; `--save' 与保存开关

(ert-deftest el-chronos-report-test--save-writes-when-sample-present ()
  "有样本时写一条 `slow_events(kind=\"profile\")' 并 flush。"
  (el-chronos-test-with-db
    (should (el-chronos-profile--save
             'demo-cmd (list :elapsed-ms 120.0 :samples 5
                             :rows (el-chronos-profile--log->rows
                                    (el-chronos-report-test--log
                                     (cons (list 'leaf 'root) 5))))))
    (should (= 1 (el-chronos-test--count "slow_events")))
    (should (equal "profile"
                   (el-chronos-test--scalar
                    "SELECT kind FROM slow_events WHERE command='demo-cmd'")))
    (should (= 120 (round (el-chronos-test--scalar
                           "SELECT duration_ms FROM slow_events WHERE command='demo-cmd'"))))))

(ert-deftest el-chronos-report-test--save-skips-zero-samples ()
  "samples 为 0 时 `--save' 直接返回 nil、不写库（零样本没有证据价值）。"
  (el-chronos-test-with-db
    (should-not (el-chronos-profile--save
                 'demo-cmd (list :elapsed-ms 0.4 :samples 0 :rows nil)))
    (should (= 0 (el-chronos-test--count "slow_events")))
    ;; :samples 缺失也按 0 处理，同样不写
    (should-not (el-chronos-profile--save 'demo-cmd (list :elapsed-ms 0.4 :rows nil)))
    (should (= 0 (el-chronos-test--count "slow_events")))))

(ert-deftest el-chronos-report-test--save-gated-by-defcustom ()
  "`el-chronos-profile-save' 为 nil 时 `el-chronos-profile-command' 根本不调用 `--save'。"
  (let ((calls 0))
    (cl-letf (((symbol-function 'el-chronos-profile--save)
               (lambda (&rest _) (setq calls (1+ calls)) t)))
      (let ((el-chronos-profile-save nil))
        (should (bufferp (el-chronos-profile-command 'ignore)))
        (should (= 0 calls)))
      (let ((el-chronos-profile-save t))
        (should (bufferp (el-chronos-profile-command 'ignore)))
        (should (= 1 calls))))
    (ignore-errors (kill-buffer el-chronos-profile--buffer-name))))

;;; 报告渲染

(ert-deftest el-chronos-report-test--content-sections ()
  "fixture 下报告含 14 个 `* 标题' 节、关键数据可见、正文无 `nil' 字面量。"
  (el-chronos-test-with-db
    (el-chronos-report-test--seed)
    (let ((content (el-chronos-report--content '7d)))
      (should (stringp content))
      (should (string-match-p "\\`#\\+TITLE: el-chronos 报告" content))
      (should (= 14 (el-chronos-report-test--count-matches "^\\* " content)))
      (should (string-match-p "save-buffer" content))
      (should (string-match-p "leaf-fn" content))
      (should (string-match-p "900 ms" content))
      (should-not (string-match-p "\\_<nil\\_>" content)))))

(ert-deftest el-chronos-report-test--content-empty-db ()
  "空库时报告仍然成型：14 节、8 处 `（无数据）'、无 `nil' 字面量。
「GC 与内存」节空库走更具体的降级说明（见 `report-gc-section-degrades-visible'），
「启动分解」/「配置变更」两节同理走各自的降级文案（见各自的 renders-and-degrades 用例），
「采集健康」空库走「本期无采集数据」（没采集 ≠ 没异常，见
`health-distinguishes-no-data-from-no-problem'）—— 因此这四节都不计入 `（无数据）' 的 8 处。"
  (el-chronos-test-with-db
    (let ((content (el-chronos-report--content '7d)))
      (should (= 14 (el-chronos-report-test--count-matches "^\\* " content)))
      (should (= 8 (el-chronos-report-test--count-matches "（无数据）" content)))
      (should-not (string-match-p "\\_<nil\\_>" content)))))


(ert-deftest el-chronos-report-test-gc-section-renders ()
  "有 GC 数据时「GC 与内存」节渲染出表头与格式化后的单元格。"
  (el-chronos-test-with-db
    (let ((hour (el-chronos-test--hour-ts)))
      (el-chronos-test--insert-gc hour 3 1500.0 1048576)
      (let ((content (el-chronos-report--content '7d)))
        (should (string-match-p "^\\* GC 与内存$" content))
        (should (string-match-p "| 时间 | GC 次数 | GC 耗时 | 内存 |" content))
        (should (string-match-p "| 3 | 1.50 s | 1.00 MB |" content))
        (should-not (string-match-p "本期无 GC 采样数据" content))))))

(ert-deftest el-chronos-report-test-gc-section-degrades-visible ()
  "无 GC 数据时该节仍然出现，并给出可见的降级说明（I11：不得静默省略整节）。"
  (el-chronos-test-with-db
    (let ((content (el-chronos-report--content '7d)))
      (should (string-match-p "^\\* GC 与内存$" content))
      (should (string-match-p "本期无 GC 采样数据（Emacs 31.1 以下不采集堆大小）" content))
      ;; 全 0 的桶（首个采样窗口只建基线）同样按「无数据」降级，不铺一屏 0
      (el-chronos-test--insert-gc (el-chronos-test--hour-ts) 0 0.0 nil)
      (let ((zero (el-chronos-report--content '7d)))
        (should (string-match-p "本期无 GC 采样数据" zero))
        (should-not (string-match-p "| 时间 | GC 次数" zero))))))

(ert-deftest el-chronos-report-test--report-buffer ()
  "`el-chronos-report' 返回 org 只读 buffer，并登记 `g' 重生成所需的 range。"
  (el-chronos-test-with-db
    (el-chronos-report-test--seed)
    (let ((buffer (el-chronos-report '1d)))
      (unwind-protect
          (with-current-buffer buffer
            (should (eq major-mode 'org-mode))
            (should buffer-read-only)
            (should (eq '1d el-chronos-report--current-range))
            (should (functionp revert-buffer-function))
            (should (= 14 (el-chronos-report-test--count-matches
                           "^\\* " (buffer-substring-no-properties
                                    (point-min) (point-max))))))
        (kill-buffer buffer)))))


;;; 启动分解 / 采集健康 / 配置变更三节

(ert-deftest el-chronos-report-test-startup-section-renders-and-degrades ()
  "「启动分解」有数据时渲染覆盖范围标题 + 两张表（锚点 / 包加载，前者固定顺序、
后者按耗时降序）；无数据时给出可见的整体降级说明（I11：不省略整节）。
降级分支用 `cl-letf' 把查询打成 nil 模拟 —— 新库总会有一条自动建的会话行，
真实库很难造出「完全无启动数据」的状态。"
  (el-chronos-test-with-db
    (let* ((now (el-chronos-test--now-ms))
           (id (el-chronos-test--insert-session now 2500.0)))
      (el-chronos-test--insert-startup-phase id "mode-start" 8.0)
      (el-chronos-test--insert-startup-phase id "after-init" 1800.0)
      (el-chronos-test--insert-startup-phase id "load:magit" 1200.0)
      (el-chronos-test--insert-startup-phase id "load:org" 300.0)
      (let ((content (el-chronos-report--content '7d)))
        ;; 标题标注覆盖范围与总时长（mode-start 8 ms / startup_ms 2500 ms）
        (should (string-match-p "^\\* 启动分解（自 mode 启动起 8 ms / 总 2\\.50 s）$"
                                content))
        (should (string-match-p "阶段锚点：" content))
        (should (string-match-p "| 阶段 | 耗时 |" content))
        (should (string-match-p "| mode-start | 8 ms |" content))
        (should (string-match-p "| after-init | 1.80 s |" content))
        (should (string-match-p "包加载 TOP（前 10）：" content))
        (should (string-match-p "| magit | 1.20 s |" content))
        ;; 包加载按耗时降序：magit 在 org 之前
        (should (< (string-match "| magit |" content) (string-match "| org |" content)))
        (should-not (string-match-p "本期无启动分解数据" content))
        (should-not (string-match-p "无包加载明细" content))))
    ;; 只有 mode-start 一个锚点、没有总耗时与 load 明细：分段降级说明必须可见
    (let ((id (el-chronos-test--insert-session (el-chronos-test--now-ms) nil)))
      (el-chronos-test--insert-startup-phase id "mode-start" 3.0)
      (let* ((content (el-chronos-report--content '7d))
             (section (substring content (string-match "^\\* 启动分解" content))))
        (should (string-match-p "^\\* 启动分解（自 mode 启动起 3 ms / 总 -）$" section))
        (should (string-match-p "无总启动耗时" section))
        (should (string-match-p "无包加载明细" section))))
    ;; 查询整体失败（返回 nil）→ 整节降级，不省略标题
    (cl-letf (((symbol-function 'el-chronos-analysis-startup-breakdown)
               (lambda (&rest _) nil)))
      (let ((content (el-chronos-report--content '7d)))
        (should (string-match-p "^\\* 启动分解$" content))
        (should (string-match-p "本期无启动分解数据" content))))))

(ert-deftest el-chronos-report-test-health-section-renders-and-degrades ()
  "「采集健康」有坏消息时渲染 `指标' / `值' 六行；有数据且全零（`:ok-p' 为 t）时只给一行
说明并带上 flush 次数 / 平均耗时 —— 两种状态都不省略整节（I11）。
「一行 health 行都没有」是第三种状态，由
`health-distinguishes-no-data-from-no-problem' 专门覆盖，本用例不重复。"
  (el-chronos-test-with-db
    (let ((hour (el-chronos-test--hour-ts)))
      (el-chronos-test--insert-health hour "dropped-commands" 5)
      (el-chronos-test--insert-health hour "sample-misses" 2)
      (el-chronos-test--insert-health hour "flush-count" 20)
      (el-chronos-test--insert-health hour "flush-ms" 100.0)
      (let ((content (el-chronos-report--content '7d)))
        (should (string-match-p "^\\* 采集健康$" content))
        (should (string-match-p "| 指标 | 值 |" content))
        (should (string-match-p "| 丢弃命令 | 5 |" content))
        (should (string-match-p "| 采样窗口丢失 | 2 |" content))
        (should (string-match-p "| flush 次数 | 20 |" content))
        (should (string-match-p "| flush 平均耗时 | 5 ms |" content))
        (should-not (string-match-p "本期无采集异常" content))))
    (el-chronos-test-with-db
      (let ((hour (el-chronos-test--hour-ts)))
        ;; 有行但全零：采集器在工作、没有坏消息
        (el-chronos-test--insert-health hour "flush-count" 4)
        (el-chronos-test--insert-health hour "flush-ms" 8.0)
        (el-chronos-test--insert-health hour "dropped-commands" 0)
        (let ((content (el-chronos-report--content '7d)))
          (should (string-match-p "^\\* 采集健康$" content))
          (should (string-match-p "本期无采集异常" content))
          (should (string-match-p "flush 4 次" content))
          (should-not (string-match-p "| 指标 | 值 |" content)))))))

(ert-deftest el-chronos-report-test-health-distinguishes-no-data-from-no-problem ()
  "「没采集」与「没异常」必须是两句不同的话（I11）。
空库时 `hourly_health' 一行都没有，analysis 层的 `:ok-p' 也是 t —— 若报告层按 `:ok-p'
分支渲染，用户会看到「本期无采集异常（本期无 flush 记录）」并读成「一切正常」，而真相是
采集器根本没上报。有数据且全零才是真正的「无异常」，此时不许出现「无采集数据」。"
  (el-chronos-test-with-db
    (let ((content (el-chronos-report--content '7d)))
      (should (string-match-p "^\\* 采集健康$" content))
      (should (string-match-p "本期无采集数据（采集器尚未写入健康指标）" content))
      (should-not (string-match-p "本期无采集异常" content))))
  (el-chronos-test-with-db
    (let ((hour (el-chronos-test--hour-ts)))
      (el-chronos-test--insert-health hour "dropped-commands" 0)
      (el-chronos-test--insert-health hour "flush-count" 7)
      (el-chronos-test--insert-health hour "flush-ms" 35.0)
      (let ((content (el-chronos-report--content '7d)))
        (should (string-match-p "本期无采集异常（flush 7 次，平均 5 ms）" content))
        (should-not (string-match-p "本期无采集数据" content))))))

(ert-deftest el-chronos-report-test-config-section-renders-and-degrades ()
  "「配置变更」渲染 `会话启动时间' / `提交' / `配置指纹' / `变化' 四列：两个哈希各截前
8 位，`:changed' 为 t 时显示 `✓'、首会话显示 \"-\"；窗口内无会话时给出降级说明。"
  (el-chronos-test-with-db
    (let* ((end (- (el-chronos-test--now-ms) 3600000))
           (start (- end 3600000))
           (window (cons start end))
           (first (el-chronos-test--insert-session (+ start 1000) 100.0))
           (second (el-chronos-test--insert-session (+ start 2000) 100.0)))
      (el-chronos-test--insert-session-meta first "git-head" "aaaaaaaabbbbcccc")
      (el-chronos-test--insert-session-meta first "config-sig" "111122223333")
      (el-chronos-test--insert-session-meta second "git-head" "ddddddddeeeeffff")
      (el-chronos-test--insert-session-meta second "config-sig" "111122223333")
      (let ((content (el-chronos-report--content window)))
        (should (string-match-p "^\\* 配置变更$" content))
        (should (string-match-p "| 会话启动时间 | 提交 | 配置指纹 | 变化 |" content))
        (should (string-match-p "| aaaaaaaa | 11112222 | - |" content))
        (should (string-match-p "| dddddddd | 11112222 | ✓ |" content))
        (should-not (string-match-p "本期无会话变更记录" content))))
    ;; 窗口内没有任何会话 → 整节降级（不省略标题）
    (el-chronos-test-with-db
      (let ((content (el-chronos-report--content (cons 1000000 2000000))))
        (should (string-match-p "^\\* 配置变更$" content))
        (should (string-match-p "本期无会话变更记录" content))))))

;;; 导出：既有的 5 个区块 + 三个新查询

(ert-deftest el-chronos-report-test-report-export-includes-new-sections ()
  "CSV 含 startup / health / config-history 三个新区块且既有区块不丢；
JSON 含 `:startup' / `:health' / `:config_history' 三个新键。
新增区块不是「有标题就算完」：断言还覆盖各区块的实际行内容（启动分解的两段 `kind'、
采集健康的 `rows' 行、配置变更的完整哈希与 `1'/'0' 变化标记），否则生成函数写错了
标题照样匹配。"
  (el-chronos-test-with-db
    (let* ((now (el-chronos-test--now-ms))
           (id (el-chronos-test--insert-session now 2500.0))
           (hour (el-chronos-test--hour-ts)))
      (el-chronos-test--insert-startup-phase id "mode-start" 8.0)
      (el-chronos-test--insert-startup-phase id "load:magit" 1200.0)
      (el-chronos-test--insert-health hour "flush-count" 3)
      (el-chronos-test--insert-health hour "flush-ms" 12.0)
      (el-chronos-test--insert-session-meta id "git-head" "aaaaaaaabbbbcccc")
      (el-chronos-test--insert-session-meta id "config-sig" "111122223333")
      (let ((csv (el-chronos-report--csv-string '7d)))
        ;; 三个新区块的标题
        (should (string-match-p "^# section: startup$" csv))
        (should (string-match-p "^# section: health$" csv))
        (should (string-match-p "^# section: config-history$" csv))
        ;; 既有 5 个区块仍在（导出是全量快照，不许因新增而丢旧块）
        (should (string-match-p "^# section: slow-commands$" csv))
        (should (string-match-p "^# section: top-functions$" csv))
        (should (string-match-p "^# section: packages$" csv))
        (should (string-match-p "^# section: trend$" csv))
        (should (string-match-p "^# section: blocking-events$" csv))
        ;; startup：阶段锚点与包加载合成一张 kind/name/ms 表
        (should (string-match-p "^kind,name,ms$" csv))
        (should (string-match-p "^phase,mode-start,8\\(\\.0\\)?$" csv))
        (should (string-match-p "^load,magit,1200\\(\\.0\\)?$" csv))
        ;; health：key/value 窄表，含区分「没采集」用的 rows 行
        (should (string-match-p "^metric,value$" csv))
        (should (string-match-p "^flush_count,3$" csv))
        (should (string-match-p "^rows,2$" csv))
        ;; config-history：完整哈希（不截 8 位）；`changed' 取决于库里是否已有更早的会话
        ;; （测试夹具的库在打开时会自动写一条会话行并带真实 git-head），故这里只断言取值域
        (should (string-match-p "^session_id,started_at_ms,git_head,config_sig,changed$" csv))
        (should (string-match-p (format "\n%d,%d,aaaaaaaabbbbcccc,111122223333,[01]\n"
                                        id now)
                                csv)))
      (let ((json (json-parse-string (el-chronos-report--json-string '7d)
                                     :object-type 'plist)))
        (should (plist-member json :startup))
        (should (plist-member json :health))
        (should (plist-member json :config_history))
        ;; 新键里确实带数据（不是空壳）。注意嵌套 plist 的键由 `json-serialize' 直接取符号名，
        ;; 连字符不会转下划线（既有 `slow_commands' 里的 `total-ms' 就是同一形态）
        (should (equal 2500.0 (plist-get (plist-get json :startup) :startup-ms)))
        (should (= 2 (plist-get (plist-get json :health) :rows)))
        ;; 会话序列里必有本次插入的会话（夹具库在打开时会自动写一条会话行，故不判总数）
        (should (cl-some (lambda (session) (equal id (plist-get session :id)))
                         (append (plist-get (plist-get json :config_history) :sessions) nil)))))))

;;; 单条事件下钻：`el-chronos-show-event'

(ert-deftest el-chronos-report-test-show-event-renders ()
  "事件存在时 `el-chronos-show-event' 渲染 `*el-chronos-event*' 且含栈帧名。
断言两层：返回的 buffer 就是事件 buffer（而非报告 buffer），且正文里逐条列出
fixture 的两个栈帧符号与命令名——即真的走了 `--event-content' 的「调用栈」节。"
  (el-chronos-test-with-db
    (el-chronos-test--insert-slow-event
     (el-chronos-test--now-ms) 3000 "block"
     "el-chronos-test-cmd"
     "[\"el-chronos-test-frame-a\",\"el-chronos-test-frame-b\"]"
     "{\"mode\":\"emacs-lisp-mode\",\"project\":\"el-chronos\"}")
    (let* ((id (el-chronos-test--scalar "SELECT last_insert_rowid()"))
           (buffer (el-chronos-show-event id)))
      (unwind-protect
          (progn
            (should (bufferp buffer))
            ;; 事件详情固定落在 `el-chronos-report--event-buffer-name'（"*el-chronos-event*"）
            (should (equal "*el-chronos-event*" (buffer-name buffer)))
            (with-current-buffer buffer
              (let ((content (buffer-substring-no-properties (point-min) (point-max))))
                (should (string-match-p (format "\\`#\\+TITLE: el-chronos 事件 #%d" id)
                                        content))
                (should (string-match-p "el-chronos-test-frame-a" content))
                (should (string-match-p "el-chronos-test-frame-b" content))
                (should (string-match-p "el-chronos-test-cmd" content))
                (should (string-match-p "emacs-lisp-mode" content)))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest el-chronos-report-test-show-event-missing ()
  "事件 id 不存在时 `el-chronos-show-event' 抛 `user-error'（不建 buffer）。"
  (el-chronos-test-with-db
    (should-error (el-chronos-show-event 99999999) :type 'user-error)
    ;; 非法 id 同样按「不存在」处理，且不留半成品 buffer
    (should-error (el-chronos-show-event "not-a-number") :type 'user-error)
    (should-not (get-buffer "*el-chronos-event*"))))

;;; 报告期间不新增阻塞事件

(ert-deftest el-chronos-report-test--suppress-binding-restored ()
  "`--without-block-events' 在体内绑定抑制变量与 60s 阈值，退出后恢复原值。"
  (let (seen-suppress seen-threshold)
    (let ((el-chronos-collect--suppress-block-p nil)
          (el-chronos-block-threshold-ms 2000))
      (el-chronos-report--without-block-events
        (setq seen-suppress el-chronos-collect--suppress-block-p
              seen-threshold el-chronos-block-threshold-ms))
      (should (eq t seen-suppress))
      (should (= el-chronos-report--suppress-block-threshold-ms seen-threshold))
      (should (= 60000 seen-threshold))
      (should-not el-chronos-collect--suppress-block-p)
      (should (= 2000 el-chronos-block-threshold-ms)))))

(ert-deftest el-chronos-report-test--report-suppresses-block-event ()
  "重查询后心跳不新增 `block' 行；对照组（不走抑制入口）确实会新增。"
  (el-chronos-test-with-db
    (el-chronos-report-test--seed)
    (let ((el-chronos-collect-notify-blocks nil)
          (baseline 0) (after-suppress 0) (age 0.0))
      ;; 对照组：直接跑重查询、模拟 5s 前的心跳基线 → 心跳判定为阻塞（证明假阳性真实存在）
      (let ((el-chronos-collect--last-heartbeat (- (float-time) 5.0)))
        (el-chronos-report--content '7d)
        (el-chronos-collect--heartbeat))
      (el-chronos-store-flush)
      (setq baseline (el-chronos-report-test--count-block-events))
      (should (= 2 baseline))           ; fixture 1 行 + 假阳性 1 行
      ;; 修复后：走抑制入口，基线被重设 → 心跳不再记阻塞
      ;; （age 必须在 let 内读取：该变量是 dynamic binding，出 let 后读到的是全局值）
      (let ((el-chronos-collect--last-heartbeat (- (float-time) 5.0)))
        (el-chronos-report '7d)
        (el-chronos-collect--heartbeat)
        (setq age (- (float-time) el-chronos-collect--last-heartbeat)))
      (el-chronos-store-flush)
      (setq after-suppress (el-chronos-report-test--count-block-events))
      (should (= baseline after-suppress))
      ;; 基线确实被推进（不是靠运气把 gap 抹平）
      (should (< age 1.0)))))

;;; Web：500 分支与端口显示

(ert-deftest el-chronos-report-test--web-500-hides-internal-error ()
  "500 分支只回通用文案：响应体不含文件路径/错误原文，Emacs 侧有 warning。"
  (let ((body nil) (status nil) (warnings nil))
    (cl-letf (((symbol-function 'el-chronos-web--send-response)
               (lambda (_proc status* _type body* &optional _headers)
                 (setq status status* body body*)))
              ((symbol-function 'display-warning)
               (lambda (_type message &optional level) (push (cons message level) warnings))))
      (let ((el-chronos-web--routes
             (cons (cons "/api/boom"
                         (lambda (_params)
                           (error "SQL 失败于 /home/thomas/Workspace/el-chronos/el-chronos-web.el:42")))
                   el-chronos-web--routes)))
        (el-chronos-web--handle-request nil "GET /api/boom HTTP/1.1\r\nHost: x\r\n\r\n")))
    (should (equal "500 Internal Server Error" status))
    (should (stringp body))
    (should (string-match-p "Internal Server Error" body))
    (should (string-match-p "\\*Messages\\*" body))
    ;; 不泄露：路径、文件名、错误原文都不出现在响应体里
    (should-not (string-match-p "/home/thomas" body))
    (should-not (string-match-p "el-chronos-web\\.el" body))
    (should-not (string-match-p "SQL 失败" body))
    ;; 但 Emacs 侧必须留痕（可见降级，I11）
    (should (= 1 (length warnings)))
    (should (string-match-p "SQL 失败" (caar warnings)))
    (should (eq :warning (cdar warnings)))))

(ert-deftest el-chronos-report-test--web-500-keeps-serving ()
  "一次 500 之后 server 仍能正常响应下一个请求（condition-case 不中断服务）。"
  (let ((bodies nil) (statuses nil))
    (cl-letf (((symbol-function 'el-chronos-web--send-response)
               (lambda (_proc status _type body &optional _headers)
                 (push status statuses) (push body bodies)))
              ((symbol-function 'display-warning) (lambda (&rest _) nil)))
      (let ((el-chronos-web--routes
             (cons (cons "/api/boom" (lambda (_params) (error "boom")))
                   el-chronos-web--routes)))
        (el-chronos-web--handle-request nil "GET /api/boom HTTP/1.1\r\n\r\n"))
      (el-chronos-web--handle-request nil "GET /api/nope HTTP/1.1\r\n\r\n"))
    (should (equal '("500 Internal Server Error" "404 Not Found")
                   (nreverse statuses)))
    (should (string-match-p "404" (car bodies)))))

(ert-deftest el-chronos-report-test--web-start-port-zero-message ()
  "端口 0 时 message 报的是内核实际分配的端口，而不是入参 0。"
  (let ((msg nil))
    (cl-letf (((symbol-function 'message)
               (lambda (format-string &rest args)
                 (setq msg (apply #'format format-string args)) nil)))
      (let ((proc (el-chronos-web-start 0)))
        (unwind-protect
            (let ((real (process-contact proc :service)))
              (should (integerp real))
              (should (> real 0))
              (should (stringp msg))
              (should (string-match-p (format ":%d/" real) msg))
              (should-not (string-match-p ":0/" msg)))
          (el-chronos-web-stop))))
    (should-not (el-chronos-web-running-p))))

(provide 'el-chronos-report-test)

;;; el-chronos-report-test.el ends here
