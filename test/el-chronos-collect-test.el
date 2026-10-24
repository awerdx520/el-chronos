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
ETAF 挂载、`with-temp-buffer' 每次渲染都会新建这类 buffer：补挂没有意义（它们不承载
用户命令），却会让 `buffer-list-update-hook' 反复遍历全部 buffer、把 `--hooked-buffers'
撑大（dashboard 重复打开时的观感负担）。登记仍要做，避免每次 buffer 切换重复判断。"
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

(provide 'el-chronos-collect-test)

;;; el-chronos-collect-test.el ends here
