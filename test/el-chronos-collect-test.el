;;; el-chronos-collect-test.el --- 采集层（窗口聚合 / 命令结算 / 心跳）ERT 测试  -*- lexical-binding: t; -*-

;; 采集层所有落库动作都经 `el-chronos-collect--safe-apply' 调用 store 的写接口，
;; 故本文件用 `cl-letf' 把 store 接口换成捕获器，既不建库也能断言「传了什么」；
;; 只有窗口聚合（`--accumulate*' / `--flush-window'）纯在内存里做，直接测结果。

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'el-chronos)
(require 'el-chronos-store)
(require 'el-chronos-collect)
(eval-and-compile
  ;; `make lint' 只带 `-L .'：编译期把本文件所在目录（test/）加进 load-path，
  ;; 否则下面的 `require' 找不到 helper；运行期由 `-L test' 提供，本段跳过。
  (when (bound-and-true-p byte-compile-current-file)
    (add-to-list 'load-path (file-name-directory byte-compile-current-file))))
(require 'el-chronos-test-helper)

;;; 窗口聚合（self / total / samples）

(ert-deftest el-chronos-collect-test-window-aggregation ()
  "`[leaf mid root]'×10 + `[leaf]'×5：leaf 三项皆 15，mid / root 只有 total 为 10。"
  (let ((el-chronos-collect--window-self (make-hash-table :test #'eq))
        (el-chronos-collect--window-stacks (make-hash-table :test #'equal)))
    (dotimes (_ 10)
      (el-chronos-collect--accumulate-entry [leaf mid root] 1))
    (dotimes (_ 5)
      (el-chronos-collect--accumulate-entry [leaf] 1))
    (should (equal [15 15 15] (gethash 'leaf el-chronos-collect--window-self)))
    (should (equal [0 10 0] (gethash 'mid el-chronos-collect--window-self)))
    (should (equal [0 10 0] (gethash 'root el-chronos-collect--window-self)))
    ;; 两条不同的栈各留一份，样本数分别为 10 与 5
    (should (= 2 (hash-table-count el-chronos-collect--window-stacks)))
    (should (equal '(10 5)
                   (sort (let (counts)
                           (maphash (lambda (_json samples) (push samples counts))
                                    el-chronos-collect--window-stacks)
                           counts)
                         #'>)))))

(ert-deftest el-chronos-collect-test-window-dedup-recursive-frames ()
  "同一栈内重复出现的帧（递归）只累加一次 total，不放大。"
  (let ((el-chronos-collect--window-self (make-hash-table :test #'eq))
        (el-chronos-collect--window-stacks (make-hash-table :test #'equal)))
    (el-chronos-collect--accumulate-entry [a a b] 3)
    (should (equal [3 3 3] (gethash 'a el-chronos-collect--window-self)))
    (should (equal [0 3 0] (gethash 'b el-chronos-collect--window-self)))))

;;; 窗口聚合：nil 帧口径（T1）
;; `(symbolp nil)' 为 t → 旧写法会造出一个伪函数 nil（报表里显示成 "unknown"）、
;; 并把 profiler 的尾部填充算进 total；全 nil 栈还会写进 `hourly_stacks'。

(ert-deftest el-chronos-collect-test-nil-leaf-not-counted ()
  "全 nil 栈既不出 self 条目，也不写栈表（否则报表多出一个伪热点 \"unknown\"）。"
  (let ((el-chronos-collect--window-self (make-hash-table :test #'eq))
        (el-chronos-collect--window-stacks (make-hash-table :test #'equal)))
    (el-chronos-collect--accumulate-entry (vector nil nil nil) 5)
    (should (= 0 (hash-table-count el-chronos-collect--window-self)))
    (should-not (gethash nil el-chronos-collect--window-self))
    (should (= 0 (hash-table-count el-chronos-collect--window-stacks)))))

(ert-deftest el-chronos-collect-test-nil-frame-not-in-total ()
  "nil 帧不计 total：`[car nil nil]'×3 时 car 的 self / total / samples 全是 3（不是 6 / 9）。"
  (let ((el-chronos-collect--window-self (make-hash-table :test #'eq))
        (el-chronos-collect--window-stacks (make-hash-table :test #'equal)))
    (el-chronos-collect--accumulate-entry (vector 'car nil nil) 3)
    (should (= 1 (hash-table-count el-chronos-collect--window-self)))
    (should (equal [3 3 3] (gethash 'car el-chronos-collect--window-self)))
    ;; 中间帧只有 total 增长，samples 归 leaf 口径
    (let ((cell (gethash 'car el-chronos-collect--window-self)))
      (should (= 3 (aref cell 0)))
      (should (= 3 (aref cell 1)))
      (should (= 3 (aref cell 2))))))

(ert-deftest el-chronos-collect-test-trailing-nils-trimmed ()
  "栈尾 nil 填充在序列化前裁掉：`[car nil nil]' 落成 `[\"car\"]'，不留 \"unknown\" 尾巴。"
  (let ((el-chronos-collect--window-self (make-hash-table :test #'eq))
        (el-chronos-collect--window-stacks (make-hash-table :test #'equal)))
    (el-chronos-collect--accumulate-entry (vector 'car nil nil) 3)
    (should (equal '("[\"car\"]")
                   (hash-table-keys el-chronos-collect--window-stacks)))
    (should (= 3 (gethash "[\"car\"]" el-chronos-collect--window-stacks)))))

(ert-deftest el-chronos-collect-test-middle-nil-kept ()
  "中间位置的 nil 不是尾部填充：保留为 \"unknown\" 占位，压缩栈结构会误导读者。"
  (let ((el-chronos-collect--window-self (make-hash-table :test #'eq))
        (el-chronos-collect--window-stacks (make-hash-table :test #'equal)))
    (el-chronos-collect--accumulate-entry (vector 'car nil 'cdr) 2)
    (should (equal '("[\"car\",\"unknown\",\"cdr\"]")
                   (hash-table-keys el-chronos-collect--window-stacks)))
    (should (= 2 (gethash "[\"car\",\"unknown\",\"cdr\"]"
                          el-chronos-collect--window-stacks)))))

(ert-deftest el-chronos-collect-test-accumulate-hash-log ()
  "`profiler-cpu-log' 的 hash table 形态（栈 vector → 样本数）走同一条聚合路径。"
  (let ((el-chronos-collect--window-self (make-hash-table :test #'eq))
        (el-chronos-collect--window-stacks (make-hash-table :test #'equal))
        (log (make-hash-table :test #'equal)))
    (puthash [leaf mid] 4 log)
    (puthash [leaf] 2 log)
    (el-chronos-collect--accumulate log)
    (should (equal [6 6 6] (gethash 'leaf el-chronos-collect--window-self)))
    (should (equal [0 4 0] (gethash 'mid el-chronos-collect--window-self)))
    (should (= 2 (hash-table-count el-chronos-collect--window-stacks)))))

(ert-deftest el-chronos-collect-test-flush-window-columns ()
  "落库三列口径：self_ms = leaf 样本数 × 采样间隔，total_ms 含中间帧，samples 不乘间隔。"
  (let ((el-chronos-collect--window-self (make-hash-table :test #'eq))
        (el-chronos-collect--window-stacks (make-hash-table :test #'equal))
        (el-chronos-sampling-interval-ns 10000000) ; 10 ms
        (el-chronos-store-stack-top-n 200)
        (captured nil))
    (el-chronos-collect--accumulate-entry [leaf mid] 4)
    (cl-letf (((symbol-function 'el-chronos-store-record-function-samples)
               (lambda (&rest args) (push (cons 'function args) captured)))
              ((symbol-function 'el-chronos-store-record-stacks)
               (lambda (hour-ts stacks) (push (list 'stacks hour-ts stacks) captured)))
              ((symbol-function 'el-chronos-attrib-file) (lambda (_symbol) "/tmp/x.el"))
              ((symbol-function 'el-chronos-attrib-package) (lambda (_symbol) "pkg")))
      (el-chronos-collect--flush-window))
    ;; 每行形如 ('function hour-ts function file package self-ms total-ms samples)
    (let* ((rows (cl-remove-if-not (lambda (e) (eq (car e) 'function)) captured))
           (leaf (cl-find "leaf" rows :key (lambda (e) (nth 2 e)) :test #'equal))
           (mid (cl-find "mid" rows :key (lambda (e) (nth 2 e)) :test #'equal)))
      (should (= 2 (length rows)))
      (should (equal "/tmp/x.el" (nth 3 leaf)))
      (should (equal "pkg" (nth 4 leaf)))
      (should (= 40.0 (nth 5 leaf)))       ; 4 样本 × 10 ms
      (should (= 40.0 (nth 6 leaf)))
      (should (= 4 (nth 7 leaf)))          ; samples 原样计数
      (should (= 0.0 (nth 5 mid)))         ; 中间帧 self 为 0
      (should (= 40.0 (nth 6 mid)))
      (should (= 0 (nth 7 mid))))
    ;; 栈上报走 `record-stacks'，且窗口被清空
    (let ((stacks (car (cl-remove-if-not (lambda (e) (eq (car e) 'stacks)) captured))))
      (should (= 1 (length (nth 2 stacks))))
      (should (= 4 (cdr (car (nth 2 stacks))))))
    (should (= 0 (hash-table-count el-chronos-collect--window-self)))
    (should (= 0 (hash-table-count el-chronos-collect--window-stacks)))))

;;; 命令结算

(ert-deftest el-chronos-collect-test-finish-aborted-slow-command ()
  "`aborted' 结算写命令事件、三维用法与超阈值慢事件，并清空命令状态。"
  (let ((events nil)
        (el-chronos-slow-command-threshold-ms 200)
        (el-chronos-usage-granularity 'command))
    (cl-letf (((symbol-function 'el-chronos-store-record-command)
               (lambda (event) (push (cons 'command event) events)))
              ((symbol-function 'el-chronos-store-record-slow-event)
               (lambda (event) (push (cons 'slow event) events)))
              ((symbol-function 'el-chronos-store-record-usage)
               (lambda (hour dimension key count duration)
                 (push (list 'usage hour dimension key count duration) events))))
      (setq el-chronos-collect--pending-p t
            el-chronos-collect--command-name "slow-cmd"
            el-chronos-collect--command-start (- (float-time) 0.35)
            el-chronos-collect--command-gc-elapsed gc-elapsed)
      (el-chronos-collect--finish 'aborted))
    (let ((command (cdr (assq 'command events)))
          (slow (cdr (assq 'slow events)))
          (dimensions (cl-loop for event in (reverse events)
                               when (eq (car event) 'usage)
                               collect (nth 2 event))))
      (should (equal "slow-cmd" (plist-get command :name)))
      (should (equal "aborted" (plist-get command :outcome)))
      (should (equal "interactive" (plist-get command :kind)))
      (should (>= (plist-get command :duration-ms) 300))
      (should (equal "command" (plist-get slow :kind)))
      (should (equal "slow-cmd" (plist-get slow :command)))
      (should (listp (plist-get slow :stack)))
      ;; 用法统计按 command → mode → project 顺序记录（维度是符号）
      (should (eq 'command (car dimensions)))
      (should (eq 'project (car (last dimensions))))
      (should-not el-chronos-collect--pending-p)
      (should-not el-chronos-collect--command-start)
      (should-not el-chronos-collect--command-name))))

(ert-deftest el-chronos-collect-test-finish-fast-command-no-slow-event ()
  "未超阈值的命令只写命令事件与用法，不产生慢事件。"
  (let ((events nil)
        (el-chronos-slow-command-threshold-ms 200))
    (cl-letf (((symbol-function 'el-chronos-store-record-command)
               (lambda (event) (push (cons 'command event) events)))
              ((symbol-function 'el-chronos-store-record-slow-event)
               (lambda (event) (push (cons 'slow event) events)))
              ((symbol-function 'el-chronos-store-record-usage)
               (lambda (&rest _args) nil)))
      (setq el-chronos-collect--pending-p t
            el-chronos-collect--command-name "fast-cmd"
            el-chronos-collect--command-start (float-time)
            el-chronos-collect--command-gc-elapsed gc-elapsed)
      (el-chronos-collect--finish 'ok))
    (should (= 1 (length (cl-remove-if-not (lambda (e) (eq (car e) 'command)) events))))
    (should-not (assq 'slow events))
    (should (equal "ok" (plist-get (cdr (assq 'command events)) :outcome)))))

(ert-deftest el-chronos-collect-test-pre-command-settles-pending-as-aborted ()
  "上一条命令未结算时，新命令的 `pre-command' 先把它按 aborted 结算，再开始新计时。"
  (let ((outcomes nil))
    (cl-letf (((symbol-function 'el-chronos-store-record-command)
               (lambda (event) (push (plist-get event :outcome) outcomes)))
              ((symbol-function 'el-chronos-store-record-slow-event)
               (lambda (&rest _args) nil))
              ((symbol-function 'el-chronos-store-record-usage)
               (lambda (&rest _args) nil)))
      (setq el-chronos-collect--pending-p t
            el-chronos-collect--command-start (- (float-time) 0.1)
            el-chronos-collect--command-name "previous-cmd"
            el-chronos-collect--errored-p nil)
      (let ((this-command 'next-cmd))
        (el-chronos-collect--pre-command))
      (should (equal '("aborted") outcomes))
      (should (equal "next-cmd" el-chronos-collect--command-name))
      (should el-chronos-collect--pending-p)
      ;; 清理：避免 pending 泄漏到其它用例
      (setq el-chronos-collect--pending-p nil
            el-chronos-collect--command-start nil
            el-chronos-collect--command-name nil))))

(ert-deftest el-chronos-collect-test-post-command-error-outcome ()
  "`--errored-p' 置位时结算为 error。"
  (let ((outcome nil))
    (cl-letf (((symbol-function 'el-chronos-store-record-command)
               (lambda (event) (setq outcome (plist-get event :outcome))))
              ((symbol-function 'el-chronos-store-record-slow-event)
               (lambda (&rest _args) nil))
              ((symbol-function 'el-chronos-store-record-usage)
               (lambda (&rest _args) nil)))
      (setq el-chronos-collect--pending-p t
            el-chronos-collect--command-start (float-time)
            el-chronos-collect--command-name "boom-cmd"
            el-chronos-collect--command-gc-elapsed gc-elapsed
            el-chronos-collect--errored-p t)
      (el-chronos-collect--post-command))
    (should (equal "error" outcome))))

;;; 心跳

(ert-deftest el-chronos-collect-test-heartbeat-drift-records-block ()
  "心跳实际间隔超过阈值时记一条 kind=block 的慢事件。"
  (let ((events nil)
        (el-chronos-collect-notify-blocks nil)
        (el-chronos-block-threshold-ms 2000))
    (cl-letf (((symbol-function 'el-chronos-store-record-slow-event)
               (lambda (event) (push event events))))
      (setq el-chronos-collect--last-heartbeat (- (float-time) 3.0))
      (el-chronos-collect--heartbeat))
    (let ((event (car events)))
      (should (= 1 (length events)))
      (should (equal "block" (plist-get event :kind)))
      (should (>= (plist-get event :duration-ms) 2900))
      (should-not (plist-get event :command)))))

(ert-deftest el-chronos-collect-test-heartbeat-on-time-no-record ()
  "心跳按时触发（漂移小于阈值）时不记录任何事件。"
  (let ((events nil)
        (el-chronos-collect-notify-blocks nil)
        (el-chronos-block-threshold-ms 2000))
    (cl-letf (((symbol-function 'el-chronos-store-record-slow-event)
               (lambda (event) (push event events))))
      (setq el-chronos-collect--last-heartbeat (- (float-time) 0.01))
      (el-chronos-collect--heartbeat))
    (should-not events)))

(ert-deftest el-chronos-collect-test-heartbeat-suppressed-skips-block ()
  "绑定 `--suppress-block-p' 为 t 时，同样的 3s gap 不记阻塞事件，但基线被推进到 ≈now。
对照组（不绑定）在同档 gap 下会记一条 block，证明抑制确实起作用而非 gap 未达阈值。"
  (let ((events nil)
        (el-chronos-collect-notify-blocks nil)
        (el-chronos-block-threshold-ms 2000)
        (age 0.0))
    (cl-letf (((symbol-function 'el-chronos-store-record-slow-event)
               (lambda (event) (push event events))))
      ;; 抑制组：大 gap 但抑制变量为 t → 不记事件，基线推进
      (let ((el-chronos-collect--suppress-block-p t)
            (el-chronos-collect--last-heartbeat (- (float-time) 3.0)))
        (el-chronos-collect--heartbeat)
        (setq age (- (float-time) el-chronos-collect--last-heartbeat)))
      (should-not events)
      (should (< age 0.5))
      ;; 对照组：不绑定抑制变量，同样 3s gap → 记一条 block
      (let ((el-chronos-collect--suppress-block-p nil)
            (el-chronos-collect--last-heartbeat (- (float-time) 3.0)))
        (el-chronos-collect--heartbeat))
      (should (= 1 (length events)))
      (should (equal "block" (plist-get (car events) :kind))))))

;;; 阻塞提示开关（三种取值：nil / messages / t）

(ert-deftest el-chronos-collect-test-heartbeat-default-silent-but-records ()
  "默认取值下心跳超阈值不提示，但阻塞事件照旧落库（提示开关不影响采集）。"
  (let ((events nil)
        (messages 0)
        (el-chronos-block-threshold-ms 2000))
    (should-not (default-value 'el-chronos-collect-notify-blocks))
    (cl-letf (((symbol-function 'el-chronos-store-record-slow-event)
               (lambda (event) (push event events)))
              ((symbol-function 'message)
               (lambda (&rest _args) (cl-incf messages))))
      (setq el-chronos-collect--last-heartbeat (- (float-time) 3.0))
      (el-chronos-collect--heartbeat))
    (should (= 0 messages))
    (should (= 1 (length events)))
    (should (equal "block" (plist-get (car events) :kind)))
    (should (>= (plist-get (car events) :duration-ms) 2900))))

(ert-deftest el-chronos-collect-test-heartbeat-notify-messages-logs-only ()
  "取 `messages' 时 `message' 被调用且 `inhibit-message' 为 t（只进 *Messages*，不占 echo area）。"
  (let ((events nil)
        (messages 0)
        (inhibit-seen 'unset)
        (el-chronos-collect-notify-blocks 'messages)
        (el-chronos-block-threshold-ms 2000))
    (cl-letf (((symbol-function 'el-chronos-store-record-slow-event)
               (lambda (event) (push event events)))
              ((symbol-function 'message)
               (lambda (&rest _args)
                 (cl-incf messages)
                 (setq inhibit-seen inhibit-message))))
      (setq el-chronos-collect--last-heartbeat (- (float-time) 3.0))
      (el-chronos-collect--heartbeat))
    (should (= 1 messages))
    (should (eq t inhibit-seen))
    (should (= 1 (length events)))
    (should (equal "block" (plist-get (car events) :kind)))))

(ert-deftest el-chronos-collect-test-heartbeat-notify-t-uses-echo-area ()
  "取 t 时 `message' 正常调用、`inhibit-message' 为 nil（真 echo area 提示）。"
  (let ((events nil)
        (messages 0)
        (inhibit-seen 'unset)
        (el-chronos-collect-notify-blocks t)
        (el-chronos-block-threshold-ms 2000))
    (cl-letf (((symbol-function 'el-chronos-store-record-slow-event)
               (lambda (event) (push event events)))
              ((symbol-function 'message)
               (lambda (&rest _args)
                 (cl-incf messages)
                 (setq inhibit-seen inhibit-message))))
      (setq el-chronos-collect--last-heartbeat (- (float-time) 3.0))
      (el-chronos-collect--heartbeat))
    (should (= 1 messages))
    (should-not inhibit-seen)
    (should (= 1 (length events)))
    (should (equal "block" (plist-get (car events) :kind)))))

;;; 启停幂等与零残留

(ert-deftest el-chronos-collect-test-start-stop-idempotent ()
  "start 幂等（timer 恒 2 个），stop 后 timer / hook / 登记表全部清零（I5）。"
  ;; 放大间隔，避免用例执行期间 timer 真的触发
  (let ((el-chronos-heartbeat-seconds 3600)
        (el-chronos-sample-window-seconds 3600))
    (unwind-protect
        (progn
          (should (eq t (el-chronos-collect-start)))
          (should (= 2 (length el-chronos-collect--timers)))
          ;; 幂等：再次 start 不重复注册
          (should (eq t (el-chronos-collect-start)))
          (should (= 2 (length el-chronos-collect--timers)))
          (should (memq #'el-chronos-collect--pre-command pre-command-hook))
          (should (memq #'el-chronos-collect--post-command post-command-hook))
          (should (memq #'el-chronos-collect--ensure-buffer-hooks
                        buffer-list-update-hook)))
      (el-chronos-collect-stop))
    (should-not el-chronos-collect--running-p)
    (should-not el-chronos-collect--timers)
    (should-not (memq #'el-chronos-collect--pre-command pre-command-hook))
    (should-not (memq #'el-chronos-collect--post-command post-command-hook))
    (should-not (memq #'el-chronos-collect--ensure-buffer-hooks
                      buffer-list-update-hook))
    (should (= 0 (hash-table-count el-chronos-collect--hooked-buffers)))
    (should-not el-chronos-collect--sampling-p)
    (when (fboundp 'profiler-cpu-running-p)
      (should-not (profiler-cpu-running-p)))))

(ert-deftest el-chronos-collect-test-start-warns-on-inverted-thresholds ()
  "阈值配错时 `--start' 各告警一次，且不阻断启动。
drift >= block → drift 区间为空（cond 里 block 分支在前），drift 永不触发；
drift <= 心跳间隔 → 每次心跳都记一条 drift。两者都是「数据悄悄错」，故启动时告警。"
  (let ((el-chronos-enabled t)
        warnings)
    (cl-letf (((symbol-function 'el-chronos--sqlite-available-p) #'always)
              ((symbol-function 'el-chronos-store-open) #'ignore)
              ((symbol-function 'el-chronos-collect-start) #'ignore)
              ((symbol-function 'el-chronos-collect-stop) #'ignore)
              ((symbol-function 'el-chronos-store-close) #'ignore)
              ((symbol-function 'display-warning)
               (lambda (type msg &optional level)
                 (push (list type msg level) warnings))))
      (unwind-protect
          ;; ① drift >= block
          (let ((el-chronos-drift-threshold-ms 3000)
                (el-chronos-block-threshold-ms 2000)
                (el-chronos-heartbeat-seconds 0.25))
            (should (eq t (el-chronos--start)))
            (should (= 1 (length warnings)))
            (should (eq 'el-chronos (caar warnings)))
            (should (string-match-p "永不触发" (cadar warnings))))
        (setq el-chronos--running-p nil))
      ;; ② drift <= 心跳间隔（0.25s → 250ms）
      (setq warnings nil)
      (unwind-protect
          (let ((el-chronos-drift-threshold-ms 200)
                (el-chronos-block-threshold-ms 2000)
                (el-chronos-heartbeat-seconds 0.25))
            (should (eq t (el-chronos--start)))
            (should (= 1 (length warnings)))
            (should (string-match-p "每次心跳都会记 drift" (cadar warnings))))
        (setq el-chronos--running-p nil))
      ;; ③ 阈值合法时零告警（默认值）
      (setq warnings nil)
      (unwind-protect
          (let ((el-chronos-drift-threshold-ms 500)
                (el-chronos-block-threshold-ms 2000)
                (el-chronos-heartbeat-seconds 0.25))
            (should (eq t (el-chronos--start)))
            (should-not warnings))
        (setq el-chronos--running-p nil)))))

;;; D1 双跑（局部 hook 值带 t）+ D2 帧名归一

(ert-deftest el-chronos-collect-test-skip-local-hook-when-t-marker ()
  "局部 hook 值末尾带 t 时不得补挂本模块函数（补了就是同一命令双跑 → 双记）。
本用例在没有修复（旧 ensure 无条件补挂）时会失败：
`memq' 能查到本模块函数，且一条命令产生 1 条 ok + 1 条 0ms 的 aborted。"
  (let ((el-chronos-heartbeat-seconds 3600)
        (el-chronos-sample-window-seconds 3600)
        (el-chronos-slow-command-threshold-ms 200)
        (el-chronos-usage-granularity 'command)
        (events nil)
        (dimensions nil)
        (buf (generate-new-buffer " *chronos-d1*")))
    (unwind-protect
        (cl-letf (((symbol-function 'el-chronos-store-record-command)
                   (lambda (event) (push event events)))
                  ((symbol-function 'el-chronos-store-record-slow-event)
                   (lambda (&rest _args) nil))
                  ((symbol-function 'el-chronos-store-record-usage)
                   (lambda (_hour dimension _key _count _duration)
                     (push dimension dimensions))))
          (with-current-buffer buf
            (setq-local pre-command-hook '(ignore t))
            (setq-local post-command-hook '(ignore t)))
          (el-chronos-collect-start)
          ;; 局部值带 t：`run-hooks' 本来就会连跑全局值 → 不补挂
          (should-not (memq #'el-chronos-collect--pre-command
                            (buffer-local-value 'pre-command-hook buf)))
          (should-not (memq #'el-chronos-collect--post-command
                            (buffer-local-value 'post-command-hook buf)))
          ;; 跳过也要登记，避免每次 buffer 切换重复判断
          (should (gethash buf el-chronos-collect--hooked-buffers))
          ;; 模拟一条命令：run-hooks 先跑局部值，末尾 t → 再跑全局值
          (with-current-buffer buf
            (let ((this-command 'test-cmd))
              (run-hooks 'pre-command-hook)
              (run-hooks 'post-command-hook)))
          (should (= 1 (length events)))
          (should (equal "ok" (plist-get (car events) :outcome)))
          (should (equal "test-cmd" (plist-get (car events) :name)))
          ;; 用法统计里 command 维度只累加一次（旧实现会记两次：ok + aborted）
          (should (= 1 (cl-count 'command dimensions))))
      (el-chronos-collect-stop)
      (kill-buffer buf))))

(ert-deftest el-chronos-collect-test-pre-command-dedupes-immediate-repeat ()
  "同一命令在 1ms 内被重复触发时（hook 双跑）不结算 aborted、不重置计时。"
  (let ((outcomes nil))
    (cl-letf (((symbol-function 'el-chronos-store-record-command)
               (lambda (event) (push (plist-get event :outcome) outcomes)))
              ((symbol-function 'el-chronos-store-record-slow-event)
               (lambda (&rest _args) nil))
              ((symbol-function 'el-chronos-store-record-usage)
               (lambda (&rest _args) nil)))
      (unwind-protect
          (progn
            (let ((this-command 'dup-cmd))
              (el-chronos-collect--pre-command)
              (let ((start el-chronos-collect--command-start))
                (el-chronos-collect--pre-command)
                (should-not outcomes)                          ; 没有 aborted 行
                (should (eql start el-chronos-collect--command-start))
                (should el-chronos-collect--pending-p))
              (el-chronos-collect--post-command)
              (should (equal '("ok") outcomes)))
            ;; 去重不误伤真实的漏结算：命令名不同 / 间隔超 1ms 时照旧记 aborted
            (setq el-chronos-collect--pending-p t
                  el-chronos-collect--command-start (- (float-time) 0.1)
                  el-chronos-collect--command-name "older-cmd")
            (let ((this-command 'second-cmd))
              (el-chronos-collect--pre-command))
            (should (equal '("aborted" "ok") outcomes)))
        (setq el-chronos-collect--pending-p nil
              el-chronos-collect--command-start nil
              el-chronos-collect--command-name nil
              el-chronos-collect--errored-p nil)))))

(ert-deftest el-chronos-collect-test-command-label-prefers-real-this-command ()
  "`real-this-command' 优先于 `this-command'：M-x 场景下 `this-command' 会被改写成中间态。
同时断言 `--pre-command' 落库用的是归一后的名字（而不是 `execute-extended-command'）。"
  (should (equal "foo" (let ((this-command 'execute-extended-command)
                             (real-this-command 'foo))
                         (el-chronos-collect--command-label))))
  (let ((names nil))
    (cl-letf (((symbol-function 'el-chronos-store-record-command)
               (lambda (event) (push (plist-get event :name) names)))
              ((symbol-function 'el-chronos-store-record-usage)
               (lambda (&rest _args) nil))
              ((symbol-function 'el-chronos-store-record-slow-event)
               (lambda (&rest _args) nil)))
      (unwind-protect
          (progn
            (setq el-chronos-collect--pending-p nil
                  el-chronos-collect--command-start nil
                  el-chronos-collect--command-name nil)
            (let ((this-command 'execute-extended-command)
                  (real-this-command 'foo))
              (el-chronos-collect--pre-command))
            (should (equal "foo" el-chronos-collect--command-name))
            (el-chronos-collect--post-command)
            (should (equal '("foo") names)))
        (setq el-chronos-collect--pending-p nil
              el-chronos-collect--command-start nil
              el-chronos-collect--command-name nil
              el-chronos-collect--errored-p nil)))))

(ert-deftest el-chronos-collect-test-command-label-normalization ()
  "符号 → 符号名；字符串（键盘宏绑定）→ 原样；非符号对象 → 类型名（旧实现记 anonymous）。"
  (should (equal "self-insert-command"
                 (let ((this-command 'self-insert-command)
                       (real-this-command nil))
                   (el-chronos-collect--command-label))))
  (should (equal "ab"
                 (let ((this-command "ab")
                       (real-this-command nil))
                   (el-chronos-collect--command-label))))
  (should (equal "interpreted-function"
                 (let ((this-command (lambda (x) x))
                       (real-this-command nil))
                   (el-chronos-collect--command-label))))
  ;; 键盘宏字符串优先于 `real-this-command' 的 nil
  (should (equal "ab"
                 (let ((this-command "ab")
                       (real-this-command nil))
                   (el-chronos-collect--command-label)))))

(ert-deftest el-chronos-collect-test-pre-command-nil-label-skips ()
  "`this-command' 与 `real-this-command' 均为 nil → 不开始计时、不落任何行（无 unknown）。"
  (let ((events nil))
    (cl-letf (((symbol-function 'el-chronos-store-record-command)
               (lambda (event) (push (plist-get event :name) events)))
              ((symbol-function 'el-chronos-store-record-usage)
               (lambda (&rest _args) (push 'usage events)))
              ((symbol-function 'el-chronos-store-record-slow-event)
               (lambda (&rest _args) (push 'slow events))))
      (unwind-protect
          (progn
            (setq el-chronos-collect--pending-p nil
                  el-chronos-collect--command-start nil
                  el-chronos-collect--command-name nil)
            (let ((this-command nil)
                  (real-this-command nil))
              (el-chronos-collect--pre-command))
            (should-not el-chronos-collect--pending-p)
            (should-not el-chronos-collect--command-start)
            (should-not el-chronos-collect--command-name)
            ;; 后续 post 不会结算出一条无主行
            (el-chronos-collect--post-command)
            (should-not events))
        (setq el-chronos-collect--pending-p nil
              el-chronos-collect--command-start nil
              el-chronos-collect--command-name nil
              el-chronos-collect--errored-p nil)))))

(ert-deftest el-chronos-collect-test-pre-command-nil-label-still-settles-pending ()
  "命令名取不到时不开始计时，但不吞掉上一条未结算命令（仍按 aborted 结算）。"
  (let ((outcomes nil))
    (cl-letf (((symbol-function 'el-chronos-store-record-command)
               (lambda (event) (push (plist-get event :outcome) outcomes)))
              ((symbol-function 'el-chronos-store-record-usage)
               (lambda (&rest _args) nil))
              ((symbol-function 'el-chronos-store-record-slow-event)
               (lambda (&rest _args) nil)))
      (unwind-protect
          (progn
            (setq el-chronos-collect--pending-p t
                  el-chronos-collect--command-start (- (float-time) 0.1)
                  el-chronos-collect--command-name "previous-cmd")
            (let ((this-command nil)
                  (real-this-command nil))
              (el-chronos-collect--pre-command))
            (should (equal '("aborted") outcomes))
            (should-not el-chronos-collect--pending-p))
        (setq el-chronos-collect--pending-p nil
              el-chronos-collect--command-start nil
              el-chronos-collect--command-name nil
              el-chronos-collect--errored-p nil)))))

(ert-deftest el-chronos-collect-test-finish-without-name-skips-write ()
  "`--command-name' 为 nil 时整条不落库（命令 / 用法 / 慢事件都不写），只清状态。
理由：无主行会污染 top-N 与中断率分母；正常路径下名字与起点同时设置，不会出现该状态。"
  (let ((events nil)
        (el-chronos-slow-command-threshold-ms 10))
    (cl-letf (((symbol-function 'el-chronos-store-record-command)
               (lambda (event) (push (cons 'command event) events)))
              ((symbol-function 'el-chronos-store-record-usage)
               (lambda (&rest args) (push (cons 'usage args) events)))
              ((symbol-function 'el-chronos-store-record-slow-event)
               (lambda (event) (push (cons 'slow event) events))))
      (setq el-chronos-collect--pending-p t
            el-chronos-collect--command-start (- (float-time) 0.5)
            el-chronos-collect--command-name nil
            el-chronos-collect--command-gc-elapsed gc-elapsed)
      (el-chronos-collect--finish 'ok))
    (should-not events)
    (should-not el-chronos-collect--pending-p)
    (should-not el-chronos-collect--command-start)))

(ert-deftest el-chronos-collect-test-mx-intermediate-is-recorded-once ()
  "M-x 中间态（`execute-extended-command'）记录**一条**，不跳过。
实测（Emacs 31.1，真实命令循环）：M-x 只触发一次 `pre-command-hook'（名字为
`execute-extended-command'），实际命令由 `command-execute' 执行且**不走** hook；
因此跳过中间态会让经 M-x 触发的命令彻底不被采集。要把这类记录归到实际命令，
需另行 advice `execute-extended-command'（未实施）。本用例锁定该结论，防止误改成「跳过」。"
  (let ((names nil))
    (cl-letf (((symbol-function 'el-chronos-store-record-command)
               (lambda (event) (push (plist-get event :name) names)))
              ((symbol-function 'el-chronos-store-record-usage)
               (lambda (&rest _args) nil))
              ((symbol-function 'el-chronos-store-record-slow-event)
               (lambda (&rest _args) nil)))
      (unwind-protect
          (progn
            (setq el-chronos-collect--pending-p nil
                  el-chronos-collect--command-start nil
                  el-chronos-collect--command-name nil)
            (let ((this-command 'execute-extended-command)
                  (real-this-command 'execute-extended-command))
              (el-chronos-collect--pre-command))
            (should el-chronos-collect--pending-p)
            (el-chronos-collect--post-command)
            (should (equal '("execute-extended-command") names)))
        (setq el-chronos-collect--pending-p nil
              el-chronos-collect--command-start nil
              el-chronos-collect--command-name nil
              el-chronos-collect--errored-p nil)))))

(ert-deftest el-chronos-collect-test-frame-name-normalization ()
  "栈帧归一：nil → \"unknown\"、非符号对象 → \"anonymous\"、符号 → 符号名（D2）。
归一作用于 `--current-stack' 与窗口聚合的栈序列化，故 JSON 里不出现 null。"
  (should (equal "unknown" (el-chronos-collect--frame-name nil)))
  (should (equal "anonymous" (el-chronos-collect--frame-name (make-vector 2 0))))
  (should (equal "anonymous" (el-chronos-collect--frame-name (lambda (x) x))))
  (should (equal "leaf" (el-chronos-collect--frame-name 'leaf)))
  ;; 帧结构 `(求值否 函数 参数表 标记)'：先取函数位再归一
  (should (equal "unknown"
                 (el-chronos-collect--frame-name
                  (el-chronos-collect--frame-head '(t nil nil nil)))))
  (should (equal "anonymous"
                 (el-chronos-collect--frame-name
                  (el-chronos-collect--frame-head (list t (make-vector 3 0) nil nil)))))
  (should (equal "fn"
                 (el-chronos-collect--frame-name
                  (el-chronos-collect--frame-head '(t fn (nil) nil)))))
  ;; 窗口聚合：栈里的 nil 与非符号对象都归一，hash key 用归一后的名字
  (let ((el-chronos-collect--window-self (make-hash-table :test #'eq))
        (el-chronos-collect--window-stacks (make-hash-table :test #'equal)))
    (el-chronos-collect--accumulate-entry (vector 'leaf nil (make-vector 2 0)) 2)
    (should (= 1 (hash-table-count el-chronos-collect--window-stacks)))
    (let* ((json (car (hash-table-keys el-chronos-collect--window-stacks)))
           (names (json-parse-string json :array-type 'list)))
      (should (equal '("leaf" "unknown" "anonymous") names))
      (should-not (string-match-p "nil\\|null" json))))
  ;; 结算时刻的真实栈：每帧都是字符串，没有 nil
  (should (cl-every #'stringp (el-chronos-collect--current-stack))))

(ert-deftest el-chronos-collect-test-adds-local-hook-when-shadowed ()
  "局部值**不含** t 时它完全遮蔽全局默认值 → 必须补挂局部值，否则该 buffer 漏采（TD-9）。
本用例守住 D1 修复的边界：收紧判据只该去掉「局部值带 t」的情形，不该连 TD-9 一起放掉。
buffer 名**不以空格开头**：内部 buffer（空格开头）按 `--internal-buffer-p' 一律不补挂，
另有 `el-chronos-collect-test-skips-internal-buffers' 覆盖那一条。"
  (let ((el-chronos-heartbeat-seconds 3600)
        (el-chronos-sample-window-seconds 3600)
        (buf (generate-new-buffer "chronos-td9")))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (setq-local pre-command-hook '(ignore))
            (setq-local post-command-hook '(ignore)))
          (el-chronos-collect-start)
          (should (memq #'el-chronos-collect--pre-command
                        (buffer-local-value 'pre-command-hook buf)))
          (should (memq #'el-chronos-collect--post-command
                        (buffer-local-value 'post-command-hook buf))))
      (el-chronos-collect-stop)
      (kill-buffer buf))))

(ert-deftest el-chronos-collect-test-skips-internal-buffers ()
  "内部 buffer（名字以空格开头）即使局部值遮蔽全局值也不补挂，但仍然登记。
`with-temp-buffer' 每次渲染都会新建这类 buffer：补挂没有意义（它们不承载
用户命令），却会让 `buffer-list-update-hook' 反复遍历全部 buffer、把 `--hooked-buffers'
撑大（重复渲染时的观感负担）。登记仍要做，避免每次 buffer 切换重复判断。"
  (let ((el-chronos-heartbeat-seconds 3600)
        (el-chronos-sample-window-seconds 3600)
        (buf (generate-new-buffer " *chronos-internal*")))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (setq-local pre-command-hook '(ignore))
            (setq-local post-command-hook '(ignore)))
          (el-chronos-collect-start)
          (should (el-chronos-collect--internal-buffer-p buf))
          (should-not (memq #'el-chronos-collect--pre-command
                            (buffer-local-value 'pre-command-hook buf)))
          (should-not (memq #'el-chronos-collect--post-command
                            (buffer-local-value 'post-command-hook buf)))
          (should (gethash buf el-chronos-collect--hooked-buffers)))
      (el-chronos-collect-stop)
      (kill-buffer buf))))

;;; GC 与内存采集（T4）
;; 采集侧只用两个 Emacs 自维护的累计计数器（`gcs-done' / `gc-elapsed'）与只读的
;; `garbage-collect-heapsize'，全部零副作用；测试用 `cl-letf' 伪造它们与 store 写接口，
;; 既不建库也不依赖真实堆。

(ert-deftest el-chronos-collect-test-collect-gc-runs-when-sampling-disabled ()
  "profiler 未采样时 `--sample-tick' 仍采集 GC 并落库（解耦）。
本用例锁住「`--collect-gc' 必须在 `(when el-chronos-collect--sampling-p ...)' 之外」：
一旦把它挪进 `sampling-p' 内，`record-gc' 一次都收不到，本用例必红。
对应错误矩阵里 profiler 启动失败（禁用采样、命令/心跳继续）时的降级契约。"
  (let ((el-chronos-collect--sampling-p nil)
        (el-chronos-collect--gc-baseline (cons gcs-done gc-elapsed))
        (el-chronos-collect--heap-tick-counter 0)
        (el-chronos-heap-sample-windows 6)
        (captured nil))
    (cl-letf (((symbol-function 'el-chronos-store-record-gc)
               (lambda (hour count ms heap) (push (list hour count ms heap) captured))))
      (el-chronos-collect--sample-tick))
    (should (= 1 (length captured)))
    (let ((row (car captured)))
      ;; hour-ts 是整点毫秒（与 `--flush-window' / `--finish' 同口径）
      (should (integerp (nth 0 row)))
      (should (= 0 (mod (nth 0 row) 3600000)))
      ;; 基线刚建立 → 本窗口增量为 0，但仍落一次库
      (should (= 0 (nth 1 row)))
      (should (= 0.0 (nth 2 row)))
      ;; 未到堆采样窗口（1 < 6）→ nil
      (should-not (nth 3 row)))))

(ert-deftest el-chronos-collect-test-collect-gc-computes-deltas ()
  "首窗口只建基线记 0；第二窗口记 `gcs-done' / `gc-elapsed' 的差值（秒 → 毫秒）。"
  (let ((el-chronos-collect--gc-baseline nil)
        (el-chronos-collect--heap-tick-counter 0)
        (el-chronos-heap-sample-windows 6)
        (rows nil))
    (cl-letf (((symbol-value 'gcs-done) 10)
              ((symbol-value 'gc-elapsed) 1.0)
              ((symbol-function 'el-chronos-store-record-gc)
               (lambda (_hour count ms heap) (push (list count ms heap) rows))))
      (el-chronos-collect--collect-gc)   ; 首窗口：初始化基线
      (setq gcs-done 13 gc-elapsed 1.75) ; 第二个窗口：+3 次、+0.75 秒
      (el-chronos-collect--collect-gc))
    (should (= 2 (length rows)))
    ;; push 逆序：nth 1 是第一次、nth 0 是第二次
    (let ((first (nth 1 rows))
          (second (nth 0 rows)))
      (should (= 0 (nth 0 first)))
      (should (= 0.0 (nth 1 first)))
      (should (= 3 (nth 0 second)))
      (should (= 750.0 (nth 1 second)))
      (should-not (nth 2 second)))))

(ert-deftest el-chronos-collect-test-collect-gc-handles-negative-elapsed ()
  "`gc-elapsed' 被重置（差值变负）按 0 处理：不抛错、GC 次数照常计入。"
  (let ((el-chronos-collect--gc-baseline (cons 10 5.0))
        (el-chronos-collect--heap-tick-counter 0)
        (el-chronos-heap-sample-windows 6)
        (rows nil))
    (cl-letf (((symbol-value 'gcs-done) 12)
              ((symbol-value 'gc-elapsed) 1.0) ; 5.0 → 1.0，明显被重置
              ((symbol-function 'el-chronos-store-record-gc)
               (lambda (_hour count ms heap) (push (list count ms heap) rows))))
      (should-not (el-chronos-collect--collect-gc)))
    (should (= 1 (length rows)))
    (let ((row (car rows)))
      (should (= 2 (nth 0 row)))       ; 次数正常
      (should (= 0.0 (nth 1 row)))     ; 负差值被钳到 0
      (should-not (nth 2 row)))))

(ert-deftest el-chronos-collect-test-collect-gc-heap-sampled-every-n-windows ()
  "堆采样按窗口计数稀疏化：`el-chronos-heap-sample-windows' = 2 时
第 2 次带 heap、第 1 / 3 次传 nil（nil 由 store 的 COALESCE 保住上次观测值）。"
  (let ((el-chronos-collect--gc-baseline (cons gcs-done gc-elapsed))
        (el-chronos-collect--heap-tick-counter 0)
        (el-chronos-heap-sample-windows 2)
        (rows nil))
    (cl-letf (((symbol-function 'el-chronos-collect--heap-bytes) (lambda () 12345))
              ((symbol-function 'el-chronos-store-record-gc)
               (lambda (_hour _count _ms heap) (push heap rows))))
      (dotimes (_ 3) (el-chronos-collect--collect-gc)))
    (should (equal '(nil 12345 nil) (nreverse rows)))
    ;; 采样后计数归零，再一个窗口即为 1（下一轮稀疏采样从头数）
    (should (= 1 el-chronos-collect--heap-tick-counter))))

(ert-deftest el-chronos-collect-test-collect-gc-degrades-without-heapsize ()
  "`garbage-collect-heapsize' 不存在（Emacs 29/30）→ heap 传 nil、不报错、GC 次数照常采集。
只对这一个符号伪造 `fboundp' 返回 nil，其余符号仍走真实实现（否则 `--safe-apply'
自身的 `fboundp' 守卫也会失效，store 根本收不到调用）。"
  (let ((el-chronos-collect--gc-baseline (cons 100 10.0))
        (el-chronos-collect--heap-tick-counter 0)
        (el-chronos-heap-sample-windows 1) ; 每窗口都该采堆 → 必然走到守卫
        (rows nil)
        (warnings nil)
        (real-fboundp (symbol-function 'fboundp)))
    (cl-letf (((symbol-value 'gcs-done) 103)
              ((symbol-value 'gc-elapsed) 10.5)
              ((symbol-function 'fboundp)
               (lambda (symbol &rest args)
                 (if (eq symbol 'garbage-collect-heapsize)
                     nil
                   (apply real-fboundp symbol args))))
              ((symbol-function 'el-chronos-store-record-gc)
               (lambda (_hour count ms heap) (push (list count ms heap) rows)))
              ((symbol-function 'display-warning)
               (lambda (&rest args) (push args warnings))))
      (should-not (el-chronos-collect--collect-gc)))
    (should (= 1 (length rows)))
    (let ((row (car rows)))
      (should (= 3 (nth 0 row)))       ; GC 次数照常（103 - 100）
      (should (= 500.0 (nth 1 row)))   ; 10.5 - 10.0 秒
      (should-not (nth 2 row))         ; 堆取不到 → nil
      (should-not warnings))))

(ert-deftest el-chronos-collect-test-collect-gc-stop-clears-state ()
  "`collect-start' 初始化 GC 采集状态、`collect-stop' 清零（I5 零残留）。"
  (let ((el-chronos-heartbeat-seconds 3600)
        (el-chronos-sample-window-seconds 3600))
    (unwind-protect
        (progn
          ;; start 前的脏状态必须被 start 清掉
          (setq el-chronos-collect--gc-baseline (cons 5 1.0)
                el-chronos-collect--heap-tick-counter 3)
          (el-chronos-collect-start)
          (should-not el-chronos-collect--gc-baseline)
          (should (= 0 el-chronos-collect--heap-tick-counter))
          ;; stop 前的脏状态必须被 stop 清掉
          (setq el-chronos-collect--gc-baseline (cons 7 2.0)
                el-chronos-collect--heap-tick-counter 4))
      (el-chronos-collect-stop))
    (should-not el-chronos-collect--gc-baseline)
    (should (= 0 el-chronos-collect--heap-tick-counter))))

(ert-deftest el-chronos-collect-test-sample-miss-recorded-when-window-exceeded ()
  "相邻两次 tick 间隔 > 2×采样窗口时记 `sample-misses'；正常间隔与首个 tick 都不记。
伪造 `--last-sample-tick' 为很久以前，把 `el-chronos-sample-window-seconds' 设成 10 秒
（阈值 20 秒）；同时覆盖「基线推进后紧接一次 tick 不再重复计数」与
「`collect-stop' 清零基线」（I5）。"
  (let ((el-chronos-collect--last-sample-tick (- (float-time) 100))
        (el-chronos-sample-window-seconds 10)
        (el-chronos-collect--gc-baseline (cons gcs-done gc-elapsed))
        (el-chronos-collect--heap-tick-counter 0)
        (el-chronos-heartbeat-seconds 3600)
        (health nil))
    (cl-letf (((symbol-function 'el-chronos-store-record-health)
               (lambda (hour key value) (push (list hour key value) health)))
              ((symbol-function 'el-chronos-store-record-gc)
               (lambda (&rest _args) nil)))
      ;; ① 间隔 100 秒 > 20 秒 → 记一次
      (el-chronos-collect--sample-tick)
      (should (= 1 (length health)))
      (let ((entry (car health)))
        (should (equal "sample-misses" (nth 1 entry)))
        (should (= 1 (nth 2 entry)))
        ;; hour-ts 与其它聚合同口径：整点毫秒
        (should (integerp (nth 0 entry)))
        (should (= 0 (mod (nth 0 entry) 3600000))))
      ;; ② 基线已推进 → 紧接着再 tick 不重复记
      (el-chronos-collect--sample-tick)
      (should (= 1 (length health)))
      ;; ③ 首个 tick（基线为 nil）只建立基线、不计 miss
      (setq el-chronos-collect--last-sample-tick nil
            health nil)
      (el-chronos-collect--sample-tick)
      (should-not health)
      (should el-chronos-collect--last-sample-tick)
      ;; ④ start 初始化 / stop 清零（I5）
      (el-chronos-collect-start)
      (should el-chronos-collect--last-sample-tick)
      (el-chronos-collect-stop)
      (should-not el-chronos-collect--last-sample-tick))))

;;; T6a 启动打点（after-load-functions + 阶段锚点 + top-N）

(defmacro el-chronos-collect-test--with-startup (top-n &rest body)
  "在干净的启动打点状态下执行 BODY，`el-chronos-startup-top-n' 绑为 TOP-N。
`after-init-time' 绑为 nil 表示「mode 在 `after-init-hook' 之前启用」（启动尚未结束），
这是启动打点唯一需要挂钩子的前提。各状态量都 `let' 绑定成新对象，
避免用例之间互相污染全局 hash / timer。"
  (declare (indent 1) (debug t))
  `(let ((el-chronos-startup-top-n ,top-n)
         (el-chronos-collect--startup-loads (make-hash-table :test #'equal))
         (el-chronos-collect--startup-last-load-ts nil)
         (el-chronos-collect--startup-load-count 0)
         (el-chronos-collect--startup-hook-done nil)
         (el-chronos-collect--startup-timer nil)
         (el-chronos-collect--startup-idle-timer nil)
         (after-init-time nil))
     ,@body))

(ert-deftest el-chronos-collect-test-startup-instrument-not-installed-when-init-done ()
  "启动已结束（`after-init-time' 非 nil）时一个启动钩子都不挂、也不注册兜底 timer。
反向验证的靶子：去掉这层前置判定后，本机这类配置（`(add-hook 'emacs-startup-hook
#'el-chronos-mode)'）会把**日常加载冒充成启动耗时**。"
  (let ((el-chronos-heartbeat-seconds 3600)
        (el-chronos-sample-window-seconds 3600)
        (after-init-time (current-time))
        (el-chronos-collect--startup-loads (make-hash-table :test #'equal))
        (el-chronos-collect--startup-timer nil)
        (el-chronos-collect--startup-idle-timer nil)
        (el-chronos-collect--startup-hook-done nil)
        (el-chronos--active-timers nil)
        (anchors nil))
    (cl-letf (((symbol-function 'el-chronos-store-record-startup-phase)
               (lambda (_session phase _ms) (push phase anchors))))
      (unwind-protect
          (progn
            (should (eq t (el-chronos-collect-start)))
            (should-not (memq #'el-chronos-collect--after-load
                              after-load-functions))
            (should-not (memq #'el-chronos-collect--startup-after-init
                              after-init-hook))
            (should-not (memq #'el-chronos-collect--startup-on-startup
                              emacs-startup-hook))
            (should-not el-chronos-collect--startup-timer)
            (should-not el-chronos-collect--startup-idle-timer)
            ;; 只记 `mode-start' 锚点，不倒填 after-init / startup
            (should (equal '(mode-start) anchors)))
        (el-chronos-collect-stop)))))

(ert-deftest el-chronos-collect-test-startup-instrument-installs-when-startup-pending ()
  "启动未结束时挂钩子 + 注册 30 秒兜底 timer；`collect-stop' 全部摘净（I5）。"
  (el-chronos-collect-test--with-startup 50
    (let ((el-chronos-heartbeat-seconds 3600)
          (el-chronos-sample-window-seconds 3600)
          (el-chronos--active-timers nil)
          (anchors nil))
      (cl-letf (((symbol-function 'el-chronos-store-record-startup-phase)
                 (lambda (_session phase _ms) (push phase anchors))))
        (unwind-protect
            (progn
              (should (eq t (el-chronos-collect-start)))
              (should (memq #'el-chronos-collect--after-load
                            after-load-functions))
              (should (memq #'el-chronos-collect--startup-after-init
                            after-init-hook))
              (should (memq #'el-chronos-collect--startup-on-startup
                            emacs-startup-hook))
              (should (timerp el-chronos-collect--startup-timer))
              (should (memql el-chronos-collect--startup-timer timer-list))
              (should (equal '(mode-start) anchors)))
          (el-chronos-collect-stop))
        ;; 停止后零残留
        (should-not (memq #'el-chronos-collect--after-load after-load-functions))
        (should-not (memq #'el-chronos-collect--startup-after-init after-init-hook))
        (should-not (memq #'el-chronos-collect--startup-on-startup
                          emacs-startup-hook))
        (should-not el-chronos-collect--startup-timer)
        (should-not el-chronos-collect--startup-idle-timer)
        (should-not el-chronos-collect--startup-last-load-ts)
        (should (= 0 el-chronos-collect--startup-load-count))
        (should (= 0 (hash-table-count el-chronos-collect--startup-loads)))))))

(ert-deftest el-chronos-collect-test-startup-after-load-accumulates ()
  "首次只建基线（不记录）；之后把与上次的时间差累加到本次 load 的文件名下。
库名从 `after-load-functions' 的文件名剥目录与扩展名：`.el' / `.elc' / `.eln' 一致。"
  (el-chronos-collect-test--with-startup 50
    (let ((now 100.0))
      (cl-letf (((symbol-function 'float-time) (lambda () now)))
        ;; ① 首次：只建基线，不产生记录（否则第一条带上「mode 启动到首次 load」的间隔）
        (el-chronos-collect--after-load "/x/a.el")
        (should-not (gethash "a" el-chronos-collect--startup-loads))
        (should (= 0 el-chronos-collect--startup-load-count))
        (should (= 100.0 el-chronos-collect--startup-last-load-ts))
        ;; ② `.elc' → 500ms
        (setq now 100.5)
        (el-chronos-collect--after-load "/y/b.elc")
        (should (= 500.0 (gethash "b" el-chronos-collect--startup-loads)))
        ;; ③ `.eln' → 250ms，同库第二次触发时**累加**
        (setq now 100.75)
        (el-chronos-collect--after-load "/z/c.eln")
        (setq now 101.0)
        (el-chronos-collect--after-load "/z/c.eln")
        (should (= 500.0 (gethash "c" el-chronos-collect--startup-loads)))
        (should-not (gethash "a" el-chronos-collect--startup-loads))
        (should (= 2 (hash-table-count el-chronos-collect--startup-loads)))
        (should (= 3 el-chronos-collect--startup-load-count))))))

(ert-deftest el-chronos-collect-test-startup-finish-writes-top-n ()
  "10 条记录、top-n = 2 → 只写最大的 2 条；top-n 为 0 时一条明细都不写。
截断必须发生在**写库前**（内存记全量），否则「保留 top-N」会变成「只采 top-N」。"
  (el-chronos-collect-test--with-startup 2
    (dotimes (i 10)
      (puthash (format "lib%d" i) (* 10.0 (1+ i))
               el-chronos-collect--startup-loads))
    (should (= 10 (hash-table-count el-chronos-collect--startup-loads)))
    (let ((written nil))
      (cl-letf (((symbol-function 'el-chronos-store-record-startup-phase)
                 (lambda (_session phase ms) (push (cons phase ms) written))))
        (el-chronos-collect--startup-finish)
        (setq written (nreverse written))
        (should (= 2 (length written)))
        (should (equal '("load:lib9" "load:lib8")
                       (mapcar #'car written)))
        (should (equal '(100.0 90.0) (mapcar #'cdr written)))
        ;; 收尾后内存清空（I5）
        (should (= 0 (hash-table-count el-chronos-collect--startup-loads))))
      ;; top-n 为 0 → 不记明细（只记锚点）
      (let ((el-chronos-startup-top-n 0)
            (more nil))
        (puthash "lib-x" 1.0 el-chronos-collect--startup-loads)
        (cl-letf (((symbol-function 'el-chronos-store-record-startup-phase)
                   (lambda (&rest args) (push args more))))
          (el-chronos-collect--startup-finish))
        (should-not more)
        (should (= 0 (hash-table-count el-chronos-collect--startup-loads)))))))

(ert-deftest el-chronos-collect-test-startup-finish-removes-hook-and-timer ()
  "`--startup-finish' 摘钩、取消 timer（并从登记表摘除）、清空内存状态。"
  (el-chronos-collect-test--with-startup 50
    (let ((timer (run-with-timer 3600 nil #'ignore)))
      (unwind-protect
          (progn
            (add-hook 'after-load-functions #'el-chronos-collect--after-load)
            (setq el-chronos-collect--startup-timer timer
                  el-chronos-collect--startup-last-load-ts 123.0
                  el-chronos-collect--startup-load-count 7
                  el-chronos--active-timers (list timer))
            (puthash "foo" 5.0 el-chronos-collect--startup-loads)
            (cl-letf (((symbol-function 'el-chronos-store-record-startup-phase)
                       (lambda (&rest _args) nil)))
              (el-chronos-collect--startup-finish))
            (should-not (memq #'el-chronos-collect--after-load
                              after-load-functions))
            (should-not el-chronos-collect--startup-timer)
            (should-not (memql timer timer-list))
            (should-not (memql timer el-chronos--active-timers))
            (should-not el-chronos-collect--startup-last-load-ts)
            (should (= 0 el-chronos-collect--startup-load-count))
            (should (= 0 (hash-table-count el-chronos-collect--startup-loads))))
        (ignore-errors (cancel-timer timer))))))

(ert-deftest el-chronos-collect-test-startup-finish-idempotent ()
  "连调两次 `--startup-finish'：不报错、不重复写、不重复清。"
  (el-chronos-collect-test--with-startup 50
    (puthash "foo" 12.0 el-chronos-collect--startup-loads)
    (let ((written nil))
      (cl-letf (((symbol-function 'el-chronos-store-record-startup-phase)
                 (lambda (_session phase ms) (push (cons phase ms) written))))
        (el-chronos-collect--startup-finish)
        (should (= 1 (length written)))
        (should (equal "load:foo" (caar written)))
        (should (= 12.0 (cdar written)))
        ;; 第二次：钩子已摘、timer 已取消、hash 已空 → 一条都不写
        (el-chronos-collect--startup-finish)
        (should (= 1 (length written)))))))

(ert-deftest el-chronos-collect-test-startup-load-count-limit-triggers-finish ()
  "累计 load 次数达到 `4 × el-chronos-startup-top-n' 时自动摘钩收尾
（模拟 `emacs-startup-hook' 永不触发：这条上限是防「无限累积」的确定性下界）。"
  (el-chronos-collect-test--with-startup 2      ; 上限 8 次
    (let ((now 0.0)
          (written nil))
      (cl-letf (((symbol-function 'float-time) (lambda () now))
                ((symbol-function 'el-chronos-store-record-startup-phase)
                 (lambda (_session phase ms) (push (cons phase ms) written))))
        (add-hook 'after-load-functions #'el-chronos-collect--after-load)
        ;; 1 次建基线 + 7 次记录 = count 7，尚未到上限
        (dotimes (_ 8)
          (setq now (+ now 0.01))
          (el-chronos-collect--after-load "/x/lib.el"))
        (should (= 7 el-chronos-collect--startup-load-count))
        (should (memq #'el-chronos-collect--after-load after-load-functions))
        (should-not written)
        ;; 第 8 次记录：count = 8 = 4 × 2 → 自动收尾并落库
        (setq now (+ now 0.01))
        (el-chronos-collect--after-load "/x/lib.el")
        (should-not (memq #'el-chronos-collect--after-load after-load-functions))
        (should (= 1 (length written)))
        (should (equal "load:lib" (caar written)))
        (should (= 80.0 (cdar written)))        ; 8 次 × 10ms
        (should (= 0 el-chronos-collect--startup-load-count))
        (should (= 0 (hash-table-count el-chronos-collect--startup-loads)))))))

(ert-deftest el-chronos-collect-test-startup-anchor-records-three-phases ()
  "三个确定性锚点各自算出相对 `before-init-time' 的毫秒偏移并交给 store；
`before-init-time' 不存在（交互式启动后的会话）时跳过且不报错、不倒填。"
  (let ((before-init-time (time-subtract (current-time) 2))
        (phases nil))
    (cl-letf (((symbol-function 'el-chronos-store-record-startup-phase)
               (lambda (_session phase ms) (push (cons phase ms) phases))))
      (el-chronos-collect--startup-anchor 'mode-start)
      (el-chronos-collect--startup-anchor 'after-init)
      (el-chronos-collect--startup-anchor 'startup))
    (should (= 3 (length phases)))
    (should (equal '(startup after-init mode-start) (mapcar #'car phases)))
    (dolist (entry phases)
      (should (floatp (cdr entry)))
      (should (>= (cdr entry) 2000.0))))
  ;; `before-init-time' 为 nil → 不记、不报错
  (let ((before-init-time nil)
        (phases nil))
    (cl-letf (((symbol-function 'el-chronos-store-record-startup-phase)
               (lambda (&rest args) (push args phases))))
      (should-not (el-chronos-collect--startup-anchor 'mode-start)))
    (should-not phases)))

;;; T6b 启动耗时补写（after-init 钩子）+ collect-stop 顺序

(ert-deftest el-chronos-collect-test-startup-after-init-captures-startup-ms-without-io ()
  "`after-init' 回调把 before/after-init 的差值登记为 pending，且**一次 sqlite 调用都没有**。
锁住「启动期零 IO」：若回调里直接 `sqlite-execute'（最坏受 busy_timeout=2000ms 拖累），
本用例的 `sqlite-calls' 断言必红；若忘了把 pending 交给 store，第二组断言必红。"
  (let ((el-chronos-startup-top-n 50)
        (before-init-time (time-subtract (current-time) 3))
        (after-init-time (time-subtract (current-time) 1))
        (el-chronos-store--db :fake-db)
        (el-chronos--session-id 7)
        (el-chronos-store--pending-startup-ms nil)
        (sqlite-calls 0)
        (anchors nil))
    (cl-letf (((symbol-function 'sqlite-execute)
               (lambda (&rest _args) (cl-incf sqlite-calls) 0))
              ((symbol-function 'sqlite-select)
               (lambda (&rest _args) (cl-incf sqlite-calls) nil))
              ((symbol-function 'sqlite-open)
               (lambda (&rest _args) (cl-incf sqlite-calls) :fake-db))
              ((symbol-function 'el-chronos-store-record-startup-phase)
               (lambda (_session phase _ms) (push phase anchors))))
      (el-chronos-collect--startup-after-init))
    ;; ① 零 IO
    (should (= 0 sqlite-calls))
    ;; ② pending 已置，值 ≈ 2000ms（3 秒前 → 1 秒前）
    (should el-chronos-store--pending-startup-ms)
    (should (< 1900.0 el-chronos-store--pending-startup-ms 2100.0))
    ;; ③ 锚点照记、钩子已自摘
    (should (equal '(after-init) anchors))
    (should-not (memq #'el-chronos-collect--startup-after-init after-init-hook))))

(ert-deftest el-chronos-collect-test-startup-after-init-skips-when-times-missing ()
  "`before-init-time' / `after-init-time' 任一为 nil 时不置 pending、不报错（只记锚点）。
后者属防御性判断：正常情况下本钩子只在 `after-init-time' 为 nil 时才会被挂上。"
  (let ((el-chronos-store--db :fake-db)
        (el-chronos--session-id 7)
        (el-chronos-store--pending-startup-ms nil)
        (anchors nil))
    (cl-letf (((symbol-function 'el-chronos-store-record-startup-phase)
               (lambda (_session phase _ms) (push phase anchors)))
              ((symbol-function 'sqlite-execute)
               (lambda (&rest _args) (ert-fail "不应有 sqlite 调用"))))
      ;; ① `before-init-time' 缺失（交互式启动后的会话）：锚点与 pending 都不产出
      (let ((before-init-time nil)
            (after-init-time (current-time)))
        (should-not (el-chronos-collect--startup-after-init))
        (should-not el-chronos-store--pending-startup-ms))
      (should-not anchors)
      ;; ② `after-init-time' 缺失：算不出差值，pending 保持 nil，也不报错
      (let ((before-init-time (time-subtract (current-time) 2))
            (after-init-time nil))
        (should-not (el-chronos-collect--startup-after-init))
        (should-not el-chronos-store--pending-startup-ms))
      ;; ② 的锚点照记（`before-init-time' 在，只是终点还没到）
      (should (equal '(after-init) anchors)))))

(ert-deftest el-chronos-collect-test-collect-stop-removes-startup-hooks-before-sample-tick ()
  "`collect-stop' 必须**先摘启动钩子**再跑 `--sample-tick' 收尾（顺序即语义）。
在 `--sample-tick' 被调用的那一刻检查两个 hook：若清理被挪到它之后，
补写 / 计时回调就会在「正在关闭」的会话上再触发一次 —— 本用例必红。"
  (let ((el-chronos-heartbeat-seconds 3600)
        (el-chronos-sample-window-seconds 3600)
        (el-chronos--active-timers nil)
        (el-chronos-collect--startup-loads (make-hash-table :test #'equal))
        (el-chronos-collect--startup-timer nil)
        (el-chronos-collect--startup-idle-timer nil)
        (observed nil))
    ;; batch 下 `after-init-time' 非 nil → `collect-start' 不会挂启动钩子；
    ;; 此处手工挂回去，让「摘钩位置」单独被测，不依赖启动是否真的未结束。
    (add-hook 'after-load-functions #'el-chronos-collect--after-load)
    (add-hook 'after-init-hook #'el-chronos-collect--startup-after-init)
    (setq el-chronos-collect--sampling-p t)
    (unwind-protect
        (cl-letf (((symbol-function 'el-chronos-collect--sample-tick)
                   (lambda ()
                     (setq observed
                           (list :after-load
                                 (and (memq #'el-chronos-collect--after-load
                                            after-load-functions)
                                      t)
                                 :after-init
                                 (and (memq #'el-chronos-collect--startup-after-init
                                            after-init-hook)
                                      t))))))
          (el-chronos-collect-stop))
      (setq el-chronos-collect--sampling-p nil)
      (el-chronos-collect-stop))
    (should (equal '(:after-load nil :after-init nil) observed))))

(ert-deftest el-chronos-collect-test-collect-stop-startup-cleanup-complete ()
  "`collect-stop' 后启动打点零残留（I5）：钩子摘净、两个 timer 取消、状态量归零、hash 清空。"
  (let ((el-chronos-heartbeat-seconds 3600)
        (el-chronos-sample-window-seconds 3600)
        (el-chronos-collect--sampling-p nil)
        (el-chronos--active-timers nil)
        (el-chronos-collect--startup-loads (make-hash-table :test #'equal))
        (el-chronos-collect--startup-timer (run-with-timer 3600 nil #'ignore))
        (el-chronos-collect--startup-idle-timer
         (run-with-idle-timer 3600 nil #'ignore))
        (el-chronos-collect--startup-hook-done t)
        (el-chronos-collect--startup-load-count 5)
        (el-chronos-collect--startup-last-load-ts 12.0))
    (let ((normal-timer el-chronos-collect--startup-timer)
          (idle-timer el-chronos-collect--startup-idle-timer))
      (puthash "lib" 3.0 el-chronos-collect--startup-loads)
      (add-hook 'after-load-functions #'el-chronos-collect--after-load)
      (add-hook 'after-init-hook #'el-chronos-collect--startup-after-init)
      (add-hook 'emacs-startup-hook #'el-chronos-collect--startup-on-startup)
      (setq el-chronos--active-timers (list normal-timer idle-timer))
      (el-chronos-collect-stop)
      (should-not (memq #'el-chronos-collect--after-load after-load-functions))
      (should-not (memq #'el-chronos-collect--startup-after-init after-init-hook))
      (should-not (memq #'el-chronos-collect--startup-on-startup
                        emacs-startup-hook))
      (should-not (memql normal-timer timer-list))
      (should-not (memql idle-timer timer-list))
      (should-not (memql normal-timer el-chronos--active-timers))
      (should-not (memql idle-timer el-chronos--active-timers))
      (should-not el-chronos-collect--startup-timer)
      (should-not el-chronos-collect--startup-idle-timer)
      (should-not el-chronos-collect--startup-hook-done)
      (should-not el-chronos-collect--startup-last-load-ts)
      (should (= 0 el-chronos-collect--startup-load-count))
      (should (= 0 (hash-table-count el-chronos-collect--startup-loads))))))

;;; 心跳判定单一函数 `--heartbeat-check'：三处调用点与两档阈值
;; （ADR-0005 D1 / D4 / D4a / D6 / D7）

;; 本组用例一律用「显式 now 注入 + 显式基线偏移」而不是真实 timer：
;; `--heartbeat-check' 的 NOW 参数就是为此准备的，于是 gap 完全确定，
;; 既不用等待也不会因 timer 相位抖动而 flaky（计划 4.4 的「四档边界」要求）。

(defmacro el-chronos-collect-test--with-capture (capture-var &rest body)
  "把四个 store 写接口换成「压入 CAPTURE-VAR 后返回 nil」的桩，再执行 BODY。
CAPTURE-VAR 需由调用方 `let' 绑定为 nil（本宏不绑定它，以便用例在宏外读结果）；
每次调用压入 `(类别 . 参数表)'，类别取 `command' / `usage' / `slow' / `drift'，
参数表一律是**列表**（故 `(car 参数表)' 恒为该次调用的第一个实参）。"
  (declare (indent 1) (debug t))
  `(cl-letf (((symbol-function 'el-chronos-store-record-command)
              (lambda (event) (push (cons 'command (list event)) ,capture-var)))
             ((symbol-function 'el-chronos-store-record-usage)
              (lambda (&rest args) (push (cons 'usage args) ,capture-var)))
             ((symbol-function 'el-chronos-store-record-slow-event)
              (lambda (event) (push (cons 'slow (list event)) ,capture-var)))
             ((symbol-function 'el-chronos-store-record-drift)
              (lambda (&rest args) (push (cons 'drift args) ,capture-var))))
     ,@body))

(defun el-chronos-collect-test--calls (capture kind)
  "返回 CAPTURE 里类别为 KIND 的调用参数表（按实际发生顺序）。
`drift' 类别的参数表形如 `(HOUR-TS GAP-MS)'。"
  (cl-loop for entry in (reverse capture)
           when (eq (car entry) kind)
           collect (cdr entry)))

(defun el-chronos-collect-test--slow-kinds (capture)
  "返回 CAPTURE 里慢事件的 kind 列表（按实际发生顺序）。"
  (mapcar (lambda (args) (plist-get (car args) :kind))
          (el-chronos-collect-test--calls capture 'slow)))

(ert-deftest el-chronos-collect-test-heartbeat-and-drift-defaults ()
  "两个 defcustom 的基线与硬约束：心跳 0.25s、drift 500ms，type 均为 `number'。
硬约束「drift 阈值 > 心跳间隔」与「drift 阈值 < block 阈值」若被改坏，
判定链会退化成「每次正常心跳都记 drift」或「drift 永远没机会命中」。"
  (should (= 0.25 (default-value 'el-chronos-heartbeat-seconds)))
  (should (= 500 (default-value 'el-chronos-drift-threshold-ms)))
  (should (eq 'number (get 'el-chronos-heartbeat-seconds 'custom-type)))
  (should (eq 'number (get 'el-chronos-drift-threshold-ms 'custom-type)))
  (should (> (default-value 'el-chronos-drift-threshold-ms)
             (* 1000 (default-value 'el-chronos-heartbeat-seconds))))
  (should (< (default-value 'el-chronos-drift-threshold-ms)
             (default-value 'el-chronos-block-threshold-ms))))

(ert-deftest el-chronos-collect-test-command-internal-block-records-no-block ()
  "命令内的停转只记 `kind=\"command\"'：`--finish' 重置基线后 block 与 drift 都不记。
**双记消除的核心守门用例**（TD-11 ③ / ADR-0005 D7）：伪造命令执行 3s（远超 block
阈值 2000ms）→ 结算 → 慢事件里只有一条 `command'，drift 一次都没被调用。
反向验证：把 `--finish' 的纯重置改成调 `--heartbeat-check' → 本例必红（双记复活）。"
  (let ((cap nil)
        (el-chronos-collect--last-heartbeat nil)
        (el-chronos-collect--pending-p t)
        (el-chronos-collect--command-name nil)
        (el-chronos-collect--command-start nil)
        (el-chronos-collect--command-gc-elapsed nil)
        (el-chronos-collect--suppress-block-p nil)
        (el-chronos-slow-command-threshold-ms 200)
        (el-chronos-usage-granularity 'command))
    (setq el-chronos-collect--command-name "slow-cmd"
          el-chronos-collect--command-start (- (float-time) 3.0)
          el-chronos-collect--command-gc-elapsed gc-elapsed
          el-chronos-collect--last-heartbeat (- (float-time) 3.0))
    (el-chronos-collect-test--with-capture cap
      (el-chronos-collect--finish 'ok))
    (should (equal '("command") (el-chronos-collect-test--slow-kinds cap)))
    (should-not (el-chronos-collect-test--calls cap 'drift))
    ;; 基线已推进到「命令刚结束」：下一次心跳只会看到 ≤一个心跳间隔的 gap
    (should (< (- (float-time) el-chronos-collect--last-heartbeat) 0.05))))

(ert-deftest el-chronos-collect-test-finish-resets-baseline ()
  "`--finish' 把心跳基线推进到当前时刻（命令执行时间被切出 gap）。"
  (let ((cap nil)
        (el-chronos-collect--last-heartbeat (- (float-time) 3.0))
        (el-chronos-collect--pending-p t)
        (el-chronos-collect--command-name "cmd")
        (el-chronos-collect--command-start (- (float-time) 3.0))
        (el-chronos-collect--command-gc-elapsed gc-elapsed)
        (el-chronos-slow-command-threshold-ms 200))
    (el-chronos-collect-test--with-capture cap
      (el-chronos-collect--finish 'ok))
    (should (< (abs (- (float-time) el-chronos-collect--last-heartbeat)) 0.05))))

(ert-deftest el-chronos-collect-test-finish-without-name-also-resets-baseline ()
  "无主命令（`--command-name' 为 nil）与 `aborted' 路径同样重置基线。
重置语句必须在 `(when (and (numberp start) name) …)' **之外** —— 否则这类早退路径
会把「上一条命令 + 命令间隙」整段留给下一次心跳，重新引入命令内时间。"
  (let ((cap nil)
        (el-chronos-collect--last-heartbeat (- (float-time) 3.0))
        (el-chronos-collect--pending-p t)
        (el-chronos-collect--command-name nil)
        (el-chronos-collect--command-start nil))
    (el-chronos-collect-test--with-capture cap
      (el-chronos-collect--finish 'aborted))
    (should-not (el-chronos-collect-test--calls cap 'command))
    (should (< (- (float-time) el-chronos-collect--last-heartbeat) 0.05))))

(ert-deftest el-chronos-collect-test-finish-does-not-call-check ()
  "`--finish' 绝不经过 `--heartbeat-check'（本设计的唯一硬禁令）。
那里调 check 会让 gap 恰等于刚执行完的命令时长 → 命令时长被记成 block / drift。"
  (let ((check-calls 0)
        (cap nil)
        (el-chronos-collect--last-heartbeat (- (float-time) 3.0))
        (el-chronos-collect--pending-p t)
        (el-chronos-collect--command-name "cmd")
        (el-chronos-collect--command-start (- (float-time) 3.0))
        (el-chronos-collect--command-gc-elapsed gc-elapsed)
        (el-chronos-slow-command-threshold-ms 200))
    (cl-letf (((symbol-function 'el-chronos-collect--heartbeat-check)
               (lambda (&optional _now) (cl-incf check-calls))))
      (el-chronos-collect-test--with-capture cap
        (el-chronos-collect--finish 'ok)))
    (should (= 0 check-calls))
    (should (= 0 (length (el-chronos-collect-test--calls cap 'drift))))))

(ert-deftest el-chronos-collect-test-pre-command-detects-pre-command-gap ()
  "命令开始前补判：1.5s 的命令外间隙记一条 drift，且基线被推进、新命令计时已开始。
这条覆盖「timer 被饿死 → 用户立刻按键 → `--finish' 的重置把整段吞掉」的漏检
（ADR-0005 D4a 的核心场景）。"
  (let ((cap nil)
        (now (float-time))
        (el-chronos-collect--last-heartbeat nil)
        (el-chronos-collect--pending-p nil)
        (el-chronos-collect--command-start nil)
        (el-chronos-collect--command-name nil)
        (el-chronos-collect--suppress-block-p nil)
        (el-chronos-block-threshold-ms 2000)
        (el-chronos-drift-threshold-ms 500)
        (this-command 'some-cmd))
    (el-chronos-collect-test--with-capture cap
      (setq el-chronos-collect--last-heartbeat (- now 1.5))
      (el-chronos-collect--pre-command))
    (let ((drift (el-chronos-collect-test--calls cap 'drift)))
      (should (= 1 (length drift)))
      ;; 参数形态：整点毫秒（整数） + 浮点毫秒 gap
      (should (integerp (car (car drift))))
      (should (floatp (cadr (car drift))))
      (should (>= (cadr (car drift)) 1400)))
    (should-not (el-chronos-collect-test--slow-kinds cap))
    (should (< (- (float-time) el-chronos-collect--last-heartbeat) 0.5))
    ;; 补判在 `--command-start' 赋值之前，故新命令照常开始计时
    (should el-chronos-collect--pending-p)
    (should (equal "some-cmd" el-chronos-collect--command-name))))

(ert-deftest el-chronos-collect-test-pre-command-detects-block-gap ()
  "命令开始前补判同样覆盖 block 档：2.5s 的命令外间隙记 block 且不记 drift。"
  (let ((cap nil)
        (now (float-time))
        (el-chronos-collect--last-heartbeat nil)
        (el-chronos-collect--pending-p nil)
        (el-chronos-collect--command-start nil)
        (el-chronos-collect--command-name nil)
        (el-chronos-collect--suppress-block-p nil)
        (el-chronos-collect-notify-blocks nil)
        (el-chronos-block-threshold-ms 2000)
        (el-chronos-drift-threshold-ms 500)
        (this-command 'some-cmd))
    (el-chronos-collect-test--with-capture cap
      (setq el-chronos-collect--last-heartbeat (- now 2.5))
      (el-chronos-collect--pre-command))
    (should (equal '("block") (el-chronos-collect-test--slow-kinds cap)))
    (should-not (el-chronos-collect-test--calls cap 'drift))
    (should-not (plist-get (car (car (el-chronos-collect-test--calls cap 'slow)))
                           :command))))

(ert-deftest el-chronos-collect-test-pre-command-settles-pending-before-check ()
  "补判写在 `(--finish 'aborted)' **之后**：先结算上一条（并因此重置基线），再补判。
于是 `aborted' 分支上补判看到的是「结算 → 命令开始」的 µs 级间隙，什么都不会记。
反向验证：把补判挪到 `(--finish 'aborted)' **之前** → 兜底门看到 `--pending-p' 仍为 t
→ 什么都不记（看似相同）；但若同时把 `--finish' 移除或改序，这里会冒出 1.2s 的
drift / block —— 两种错法都让本例的可观测断言不成立。"
  (let ((cap nil)
        (now (float-time))
        (el-chronos-collect--last-heartbeat nil)
        (el-chronos-collect--pending-p t)
        (el-chronos-collect--command-start nil)
        (el-chronos-collect--command-name "previous-cmd")
        (el-chronos-collect--command-gc-elapsed nil)
        (el-chronos-collect--suppress-block-p nil)
        (el-chronos-slow-command-threshold-ms 200)
        (this-command 'next-cmd))
    (setq el-chronos-collect--command-start (- now 0.05))
    (el-chronos-collect-test--with-capture cap
      (setq el-chronos-collect--last-heartbeat (- now 1.2))
      (el-chronos-collect--pre-command))
    ;; 上一条按 aborted 结算（顺序断言）
    (should (equal '("aborted")
                   (mapcar (lambda (args) (plist-get (car args) :outcome))
                           (el-chronos-collect-test--calls cap 'command))))
    ;; `--finish' 已把基线推进，故 aborted 分支上的补判不记录（µs 级间隙）
    (should-not (el-chronos-collect-test--calls cap 'drift))
    (should-not (el-chronos-collect-test--slow-kinds cap))
    ;; 新命令照常开始计时
    (should (eq t el-chronos-collect--pending-p))
    (should (equal "next-cmd" el-chronos-collect--command-name))))

(ert-deftest el-chronos-collect-test-suppress-blocks-drift ()
  "抑制门覆盖 drift：`--suppress-block-p' 为 t 时 1s 间隙既不记 drift 也不记 block，
但基线**仍推进**（否则解除抑制后会把整段渲染耗时算成一次 gap）。"
  (let ((cap nil)
        (el-chronos-collect--last-heartbeat (- (float-time) 1.0))
        (el-chronos-collect--pending-p nil)
        (el-chronos-collect--suppress-block-p t)
        (el-chronos-block-threshold-ms 2000)
        (el-chronos-drift-threshold-ms 500))
    (el-chronos-collect-test--with-capture cap
      (el-chronos-collect--heartbeat-check))
    (should-not (el-chronos-collect-test--calls cap 'drift))
    (should-not (el-chronos-collect-test--slow-kinds cap))
    (should (< (- (float-time) el-chronos-collect--last-heartbeat) 0.5))))

(ert-deftest el-chronos-collect-test-suppress-blocks-block ()
  "抑制门同样覆盖 block 档（3s 间隙在抑制期间不记；drift 更不可能有）。"
  (let ((cap nil)
        (el-chronos-collect--last-heartbeat (- (float-time) 3.0))
        (el-chronos-collect--pending-p nil)
        (el-chronos-collect--suppress-block-p t)
        (el-chronos-collect-notify-blocks nil)
        (el-chronos-block-threshold-ms 2000)
        (el-chronos-drift-threshold-ms 500))
    (el-chronos-collect-test--with-capture cap
      (el-chronos-collect--heartbeat-check))
    (should-not (el-chronos-collect-test--slow-kinds cap))
    (should-not (el-chronos-collect-test--calls cap 'drift))
    (should (< (- (float-time) el-chronos-collect--last-heartbeat) 0.5))))

(ert-deftest el-chronos-collect-test-pending-p-blocks-judgement ()
  "兜底门：`--pending-p' 为真时 1.2s 与 3s 间隙都不判定（两档同时被挡住），基线推进。
这是「命令中途让出主线程」（`sleep-for' / 同步 IO / 等待输入）时的心跳泄漏防线。"
  (let ((cap nil)
        (el-chronos-collect--pending-p t)
        (el-chronos-collect--suppress-block-p nil)
        (el-chronos-block-threshold-ms 2000)
        (el-chronos-drift-threshold-ms 500))
    (dolist (gap '(1.2 3.0))
      (setq el-chronos-collect--last-heartbeat (- (float-time) gap))
      (el-chronos-collect-test--with-capture cap
        (el-chronos-collect--heartbeat-check))
      (should (< (- (float-time) el-chronos-collect--last-heartbeat) 0.5)))
    (should-not (el-chronos-collect-test--calls cap 'drift))
    (should-not (el-chronos-collect-test--slow-kinds cap))))

(ert-deftest el-chronos-collect-test-drift-threshold-four-bands ()
  "命令外四档阈值（注入确定性 now，不依赖 timer 相位）：
0.3s 不记 / 0.6s 记 drift / 1.2s 记 drift / 2.5s 记 block 且不记 drift。"
  (let ((cap nil)
        (el-chronos-collect--last-heartbeat nil)
        (el-chronos-collect--pending-p nil)
        (el-chronos-collect--suppress-block-p nil)
        (el-chronos-block-threshold-ms 2000)
        (el-chronos-drift-threshold-ms 500))
    (el-chronos-collect-test--with-capture cap
      (dolist (gap '(0.3 0.6 1.2 2.5))
        (let ((now 1000000.0))
          (setq el-chronos-collect--last-heartbeat (- now gap))
          (el-chronos-collect--heartbeat-check now))))
    (let ((drift (el-chronos-collect-test--calls cap 'drift)))
      ;; 只有 0.6s 与 1.2s 两档进 drift（2.5s 走 block 档，两档互斥）
      (should (= 2 (length drift)))
      (should (equal '(600 1200)
                     (mapcar (lambda (args) (round (cadr args))) drift))))
    (should (equal '("block") (el-chronos-collect-test--slow-kinds cap)))
    ;; block 的 :command 恒为 nil（它只记命令外停转，回填上一条命令名会误导）
    (should-not (plist-get (car (car (el-chronos-collect-test--calls cap 'slow)))
                           :command))))

(ert-deftest el-chronos-collect-test-drift-does-not-write-slow-events ()
  "drift 只进小时桶，绝不写 `slow_events'（ADR-0005 D2：亚秒级不配当「重要事件」）。"
  (let ((cap nil)
        (el-chronos-collect--last-heartbeat nil)
        (el-chronos-collect--pending-p nil)
        (el-chronos-collect--suppress-block-p nil)
        (el-chronos-block-threshold-ms 2000)
        (el-chronos-drift-threshold-ms 500))
    (el-chronos-collect-test--with-capture cap
      (let ((now 1000000.0))
        (setq el-chronos-collect--last-heartbeat (- now 0.6))
        (el-chronos-collect--heartbeat-check now)))
    (should (= 1 (length (el-chronos-collect-test--calls cap 'drift))))
    (should (= 0 (length (el-chronos-collect-test--calls cap 'slow))))))

(ert-deftest el-chronos-collect-test-drift-recorded-with-hour-ts-and-ms ()
  "drift 落库参数形态：`(--hour-ts)' 的整点毫秒（整数，3600000 的整数倍）+ 浮点毫秒 gap。
store 侧 `-record-drift' 的签名是 `(hour-ts gap-ms)'，单位是毫秒而非秒（I4）。"
  (let ((cap nil)
        (el-chronos-collect--last-heartbeat nil)
        (el-chronos-collect--pending-p nil)
        (el-chronos-collect--suppress-block-p nil)
        (el-chronos-block-threshold-ms 2000)
        (el-chronos-drift-threshold-ms 500))
    (el-chronos-collect-test--with-capture cap
      (let ((now (float-time)))
        (setq el-chronos-collect--last-heartbeat (- now 0.75))
        (el-chronos-collect--heartbeat-check now)))
    (let* ((args (car (el-chronos-collect-test--calls cap 'drift)))
           (hour-ts (nth 0 args))
           (gap-ms (nth 1 args)))
      (should (integerp hour-ts))
      (should (= 0 (mod hour-ts 3600000)))
      (should (= hour-ts (el-chronos-collect--hour-ts)))
      (should (floatp gap-ms))
      (should (<= 700 gap-ms 800)))))

(ert-deftest el-chronos-collect-test-heartbeat-check-is-single-source-of-truth ()
  "三处调用点共享同一个判定函数：timer（`--heartbeat'）与 `--pre-command' 各一次，
`--finish' 零次 —— 计数 = 2。反向验证：让 `--finish' 也调 check → 计数变 3 → 本例必红。"
  (let ((check-calls 0)
        (cap nil)
        (el-chronos-collect--last-heartbeat (float-time))
        (el-chronos-collect--pending-p nil)
        (el-chronos-collect--command-start nil)
        (el-chronos-collect--command-name nil)
        (this-command 'cmd))
    (cl-letf (((symbol-function 'el-chronos-collect--heartbeat-check)
               (lambda (&optional _now) (cl-incf check-calls))))
      (el-chronos-collect-test--with-capture cap
        (el-chronos-collect--heartbeat)
        (should (= 1 check-calls))
        (el-chronos-collect--pre-command)
        (should (= 2 check-calls))
        (el-chronos-collect--finish 'ok)))
    (should (= 2 check-calls))))

(ert-deftest el-chronos-collect-test-heartbeat-check-condition-case-internal ()
  "`condition-case' 必须在 `--heartbeat-check' **内部**（I6）：内部抛错不逃出函数。
`--pre-command' 自身没有 `condition-case'，异常若逃出去会经 `pre-command-hook'
抛进命令循环、**中断用户正在执行的命令**。
反向验证：把 `condition-case' 移到 `--heartbeat' 薄壳 → 直接调用 check 会 signal → 本例必红。
另外断言「异常前基线已推进」：否则同一段 gap 会在每次心跳上反复被判。"
  (let ((cap nil)
        (el-chronos-collect--last-heartbeat nil)
        (el-chronos-collect--pending-p nil)
        (el-chronos-collect--command-start nil)
        (el-chronos-collect--command-name nil)
        (el-chronos-collect--suppress-block-p nil)
        (el-chronos-block-threshold-ms 2000)
        (el-chronos-drift-threshold-ms 500)
        (this-command 'cmd))
    (cl-letf (((symbol-function 'el-chronos-collect--hour-ts)
               (lambda () (error "boom"))))
      (el-chronos-collect-test--with-capture cap
        (setq el-chronos-collect--last-heartbeat (- (float-time) 1.0))
        ;; 直接调用：异常必须被 check 内部吞掉
        (should-not (condition-case err
                        (progn (el-chronos-collect--heartbeat-check) nil)
                      (error err)))
        ;; 经 `--pre-command' 调用：异常同样不得抛进命令循环
        (setq el-chronos-collect--last-heartbeat (- (float-time) 1.0))
        (should-not (condition-case err
                        (progn (el-chronos-collect--pre-command) nil)
                      (error err)))))
    ;; 异常发生前基线已推进（否则会反复判定同一段 gap）
    (should (< (- (float-time) el-chronos-collect--last-heartbeat) 0.5))
    (should-not (el-chronos-collect-test--calls cap 'drift))))

(provide 'el-chronos-collect-test)

;;; el-chronos-collect-test.el ends here
