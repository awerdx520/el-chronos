;;; el-chronos-startup-probe-test.el --- 启动探针（零依赖 early-init 探针）ERT 测试  -*- lexical-binding: t; -*-

;; 探针在**文件加载时**就挂钩子（这是它的设计：early-init 里 `(load ...)' 即生效），
;; 所以每个用例都必须先把这份全局态洗干净 —— 见 `--with-probe' fixture：它先
;; `--reset'、再把全部内存态 `let' 绑定成新对象、结束时再 `--reset'。
;;
;; 测试文件**允许** require cl-lib（测试不在 early-init 环境，不受探针的零依赖约束）；
;; 但被侧文件 `el-chronos-startup-probe.el' 绝对不许 require 任何东西。
;;
;; `el-chronos-collect--startup-take-probe' 由 T3 在 collect 侧实现，本文件用
;; `fset' 桩（保存 / 还原原定义）来断言「软调用的发生与否」，从而不依赖 T3 是否已落地。

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'el-chronos-startup-probe)

;;; 夹具

(defmacro el-chronos-startup-probe-test--with-probe (&rest body)
  "在干净的探针状态下执行 BODY，并保证结束后同样干净。
干净 = 三个钩子全摘、两个 timer 全取消、内存态全部重置、`--instrumented-p' 为 nil。
`before-init-time' 绑成当前时刻，使 `--anchor' 能算出偏移（否则锚点一律不记录）。"
  (declare (indent 0) (debug t))
  `(progn
     (el-chronos-startup-probe--reset)
     (let ((el-chronos-startup-probe--loads (make-hash-table :test #'equal))
           (el-chronos-startup-probe--anchors nil)
           (el-chronos-startup-probe--last-load-ts nil)
           (el-chronos-startup-probe--load-count 0)
           (el-chronos-startup-probe--done-p nil)
           (el-chronos-startup-probe--finish-timer nil)
           (el-chronos-startup-probe--fallback-timer nil)
           (el-chronos-startup-probe--instrumented-p nil)
           (before-init-time (current-time)))
       (unwind-protect
           (progn ,@body)
         (el-chronos-startup-probe--reset)))))

(defun el-chronos-startup-probe-test--count (function hook)
  "统计 FUNCTION 在 HOOK 里出现几次。
**不要用 `length' + `memq' 计数**：`memq' 返回的是尾巴，长度 = 1 + 尾巴里其余元素的
个数 —— 对 `(f other)' 这种列表会得 2，把「挂了一次」误判成两次。"
  (let ((n 0))
    (dolist (item hook) (when (eq item function) (setq n (1+ n))))
    n))

(defmacro el-chronos-startup-probe-test--stub-take (&rest body)
  "在把 `el-chronos-collect--startup-take-probe' 桩成计数器的前提下执行 BODY。
桩的调用次数记在词法变量 `take-calls' 上；结束后还原原定义（原本未定义则 fmakunbound）。
这样无论 T3 是否已实现该函数，断言都是确定的。"
  (declare (indent 0) (debug t))
  `(let ((saved (and (fboundp 'el-chronos-collect--startup-take-probe)
                     (symbol-function 'el-chronos-collect--startup-take-probe)))
         (take-calls 0))
     (unwind-protect
         (progn
           (fset 'el-chronos-collect--startup-take-probe
                 (lambda () (setq take-calls (1+ take-calls))))
           ,@body)
       (if saved
           (fset 'el-chronos-collect--startup-take-probe saved)
         (fmakunbound 'el-chronos-collect--startup-take-probe)))))

;;; 挂载

(ert-deftest el-chronos-startup-probe-test-instrument-idempotent ()
  "连续两次 `--instrument' 只挂一份钩子，`--instrumented-p' 为 t。
理由：`(load \"...\" t)' 不受 `provide' 保护，可能被重复执行 —— 没有守卫就会把
同一个函数挂进 hook 多次，load 被记多遍、锚点判定也会乱。"
  (el-chronos-startup-probe-test--with-probe
    ;; fixture 已 reset：起点必须一个都没有
    (should-not (memq #'el-chronos-startup-probe--after-load after-load-functions))
    (el-chronos-startup-probe--instrument)
    (el-chronos-startup-probe--instrument)
    (should el-chronos-startup-probe--instrumented-p)
    ;; 计数用 `--count' 而不是 `(length (memq ...))'（后者会多算 1，见其 docstring）
    (should (= 1 (el-chronos-startup-probe-test--count
                  #'el-chronos-startup-probe--after-load
                  after-load-functions)))
    (should (= 1 (el-chronos-startup-probe-test--count
                  #'el-chronos-startup-probe--after-init
                  after-init-hook)))
    (should (= 1 (el-chronos-startup-probe-test--count
                  #'el-chronos-startup-probe--on-startup
                  emacs-startup-hook)))))

(ert-deftest el-chronos-startup-probe-test-instrument-records-early-init-anchor ()
  "`--instrument' 记 `early-init' 锚点（相对 `before-init-time' 的毫秒，非负数）。"
  (el-chronos-startup-probe-test--with-probe
    (should-not el-chronos-startup-probe--anchors)
    (el-chronos-startup-probe--instrument)
    (let ((entry (assq 'early-init el-chronos-startup-probe--anchors)))
      (should entry)
      (should (numberp (cdr entry)))
      (should (>= (cdr entry) 0)))))

(ert-deftest el-chronos-startup-probe-test-anchor-first-value-wins ()
  "同一 phase 重复打点**不覆盖**首个值（「首次到达该阶段的时刻」语义）。"
  (el-chronos-startup-probe-test--with-probe
    (el-chronos-startup-probe--anchor 'startup)
    (let ((first (cdr (assq 'startup el-chronos-startup-probe--anchors))))
      (should (numberp first))
      ;; 若第二次数值不同且覆盖生效，这里就会变；用 `sleep-for' 保证时间确实前进
      (sleep-for 0.01)
      (el-chronos-startup-probe--anchor 'startup)
      (should (= first (cdr (assq 'startup el-chronos-startup-probe--anchors))))
      (should (= 1 (length el-chronos-startup-probe--anchors))))))

;;; after-load 差值

(ert-deftest el-chronos-startup-probe-test-after-load-first-call-only-baseline ()
  "首次 `--after-load' 只建基线：不记 load、计数仍为 0。
否则第一条会带上「探针上岗到第一次 load」的启动开销，那是错的归因。"
  (el-chronos-startup-probe-test--with-probe
    (should-not el-chronos-startup-probe--last-load-ts)
    (el-chronos-startup-probe--after-load "/tmp/foo.el")
    (should el-chronos-startup-probe--last-load-ts)
    (should (= 0 (hash-table-count el-chronos-startup-probe--loads)))
    (should (= 0 el-chronos-startup-probe--load-count))))

(ert-deftest el-chronos-startup-probe-test-after-load-accumulates-deltas ()
  "相邻两次回调的差值按 library 累加，计数逐次 +1（近似归因，见文件头口径）。
`float-time' 用 `cl-letf' 桩成受控序列，断言的是精确数值而不是「大于 0」。"
  (el-chronos-startup-probe-test--with-probe
    (let ((now 100.0))
      (cl-letf (((symbol-function 'float-time) (lambda (&optional _t) now)))
        (el-chronos-startup-probe--after-load "/x/foo.el")     ; 建基线
        (setq now 100.5)
        (el-chronos-startup-probe--after-load "/x/bar.elc")    ; bar += 500
        (setq now 101.0)
        (el-chronos-startup-probe--after-load "/x/foo.el")     ; foo += 500
        (setq now 101.5)
        (el-chronos-startup-probe--after-load "/x/foo.eln")))  ; foo += 500（累加）
    (should (= 3 el-chronos-startup-probe--load-count))
    (should (= 2 (hash-table-count el-chronos-startup-probe--loads)))
    (should (= 1000.0 (gethash "foo" el-chronos-startup-probe--loads)))
    (should (= 500.0 (gethash "bar" el-chronos-startup-probe--loads)))))

(ert-deftest el-chronos-startup-probe-test-library-strips-extensions ()
  "library 名取法：去目录 + 剥扩展名（`.el' / `.elc' / `.eln' / `.el.gz'），非字符串给空串。
不用 `file-name-base' 是为了在 straights 的 `.eln' 路径上行为可控。"
  (should (equal "foo" (el-chronos-startup-probe--library "/a/b/foo.el")))
  (should (equal "foo" (el-chronos-startup-probe--library "/a/b/foo.elc")))
  (should (equal "foo" (el-chronos-startup-probe--library "/a/b/foo.eln")))
  (should (equal "foo" (el-chronos-startup-probe--library "/a/b/foo.el.gz")))
  (should (equal "foo-bar" (el-chronos-startup-probe--library "foo-bar.el")))
  (should (equal "noext" (el-chronos-startup-probe--library "/a/b/noext")))
  (should (equal "" (el-chronos-startup-probe--library nil)))
  (should (equal "" (el-chronos-startup-probe--library 42))))

;;; data / take 语义

(ert-deftest el-chronos-startup-probe-test-data-is-read-only ()
  "`data' 是纯只读快照：调用后 hash 与锚点都还在（与 `take' 的增量语义相对）。"
  (el-chronos-startup-probe-test--with-probe
    (puthash "foo" 12.0 el-chronos-startup-probe--loads)
    (setq el-chronos-startup-probe--anchors '((early-init . 3.0)))
    (let ((snapshot (el-chronos-startup-probe-data)))
      (should (equal '(("foo" . 12.0)) (plist-get snapshot :loads)))
      (should (equal '((early-init . 3.0)) (plist-get snapshot :anchors)))
      (should (plist-get snapshot :captured-p)))
    ;; 未被清空
    (should (= 1 (hash-table-count el-chronos-startup-probe--loads)))
    (should (equal '((early-init . 3.0)) el-chronos-startup-probe--anchors))
    ;; 可反复取到同一份
    (should (equal '(("foo" . 12.0))
                   (plist-get (el-chronos-startup-probe-data) :loads)))))

(ert-deftest el-chronos-startup-probe-test-take-clears-loads-keeps-anchors ()
  "`take' 增量语义：`loads' 取走即清空，`anchors' 只读不重置（可反复返回）。"
  (el-chronos-startup-probe-test--with-probe
    (puthash "foo" 12.0 el-chronos-startup-probe--loads)
    (setq el-chronos-startup-probe--anchors '((early-init . 3.0)))
    (let ((first (el-chronos-startup-probe-take)))
      (should (equal '(("foo" . 12.0)) (plist-get first :loads)))
      (should (equal '((early-init . 3.0)) (plist-get first :anchors)))
      (should (plist-get first :captured-p)))
    (should (= 0 (hash-table-count el-chronos-startup-probe--loads)))
    (should (equal '((early-init . 3.0)) el-chronos-startup-probe--anchors))
    (let ((second (el-chronos-startup-probe-take)))
      (should-not (plist-get second :loads))
      (should (equal '((early-init . 3.0)) (plist-get second :anchors)))
      ;; `captured-p' 在清空前算好，且口径是「曾经采到过」
      (should (plist-get second :captured-p)))))

(ert-deftest el-chronos-startup-probe-test-take-plist-empty-when-nothing-captured ()
  "什么都没采到时 `take' 返回 plist：`loads' / `anchors' 为空、`captured-p' 为 nil。"
  (el-chronos-startup-probe-test--with-probe
    (let ((snapshot (el-chronos-startup-probe-take)))
      (should-not (plist-get snapshot :loads))
      (should-not (plist-get snapshot :anchors))
      (should-not (plist-get snapshot :captured-p)))))

;;; 收尾

(ert-deftest el-chronos-startup-probe-test-finish-unhooks-and-cancels-timers ()
  "`--finish' 摘钩 + **两个** timer 都 cancel + 置 `--done-p'；重复调用仍幂等。
漏 cancel 的后果：探针生命周期不在 `el-chronos-mode -1' 的清理清单里（I5 在此无覆盖），
遗留 timer 就再没人清。"
  (el-chronos-startup-probe-test--with-probe
    (let* ((finish-timer (run-with-timer 3600 nil #'ignore))
           (fallback-timer (run-with-timer 3600 nil #'ignore))
           (el-chronos-startup-probe--finish-timer finish-timer)
           (el-chronos-startup-probe--fallback-timer fallback-timer))
      (el-chronos-startup-probe-test--stub-take
        (el-chronos-startup-probe--instrument)
        (should (memq #'el-chronos-startup-probe--after-load after-load-functions))
        (should (memq finish-timer timer-list))
        (should (memq fallback-timer timer-list))
        (el-chronos-startup-probe--finish)
        (should el-chronos-startup-probe--done-p)
        (should-not (memq #'el-chronos-startup-probe--after-load
                          after-load-functions))
        (should-not (memq finish-timer timer-list))
        (should-not (memq fallback-timer timer-list))
        (should-not el-chronos-startup-probe--finish-timer)
        (should-not el-chronos-startup-probe--fallback-timer)
        ;; 幂等：第二次调用不报错、不复活钩子 / timer
        (el-chronos-startup-probe--finish)
        (should el-chronos-startup-probe--done-p)
        (should-not (memq #'el-chronos-startup-probe--after-load
                          after-load-functions))
        (should-not el-chronos-startup-probe--finish-timer)))))

(ert-deftest el-chronos-startup-probe-test-load-count-limit-triggers-finish ()
  "累计 load 次数达到 `--load-limit'（800）时立即收尾（防病态累积的下界之一）。"
  (el-chronos-startup-probe-test--with-probe
    (el-chronos-startup-probe-test--stub-take
      (el-chronos-startup-probe--instrument)
      (setq el-chronos-startup-probe--last-load-ts (float-time))
      (setq el-chronos-startup-probe--load-count
            (1- el-chronos-startup-probe--load-limit))
      (should (memq #'el-chronos-startup-probe--after-load after-load-functions))
      (el-chronos-startup-probe--after-load "/tmp/foo.el")
      (should (= el-chronos-startup-probe--load-limit
                 el-chronos-startup-probe--load-count))
      (should el-chronos-startup-probe--done-p)
      (should-not (memq #'el-chronos-startup-probe--after-load
                        after-load-functions)))))

(ert-deftest el-chronos-startup-probe-test-after-init-registers-fallback-timer ()
  "`--after-init' 自摘、记 `after-init' 锚点、登记 30 秒兜底 timer。"
  (el-chronos-startup-probe-test--with-probe
    (el-chronos-startup-probe--instrument)
    (unwind-protect
        (progn
          (el-chronos-startup-probe--after-init)
          (should-not (memq #'el-chronos-startup-probe--after-init after-init-hook))
          (should (assq 'after-init el-chronos-startup-probe--anchors))
          (should el-chronos-startup-probe--fallback-timer)
          (should (memq el-chronos-startup-probe--fallback-timer timer-list))
          ;; 已自摘后重复调用仍不报错（幂等）
          (el-chronos-startup-probe--after-init))
      (when el-chronos-startup-probe--fallback-timer
        (ignore-errors
          (cancel-timer el-chronos-startup-probe--fallback-timer))))))

(ert-deftest el-chronos-startup-probe-test-on-startup-schedules-zero-delay-finish ()
  "`--on-startup' 自摘、记 `startup' 锚点，**不立刻收尾**而是登记 0 秒延时 timer。
延时是时序依赖：`emacs-startup-hook' 的其余回调与 `window-setup-hook' 还是同步代码，
立刻收尾就会把它们触发的 load 挡在 `after-load-functions' 之外。"
  (el-chronos-startup-probe-test--with-probe
    (el-chronos-startup-probe--instrument)
    (unwind-protect
        (progn
          (el-chronos-startup-probe--on-startup)
          (should-not (memq #'el-chronos-startup-probe--on-startup
                            emacs-startup-hook))
          (should (assq 'startup el-chronos-startup-probe--anchors))
          (should el-chronos-startup-probe--finish-timer)
          (should (memq el-chronos-startup-probe--finish-timer timer-list))
          ;; 关键断言：此刻还没收尾（钩子仍在），收尾要等事件循环
          (should-not el-chronos-startup-probe--done-p)
          (should (memq #'el-chronos-startup-probe--after-load
                        after-load-functions)))
      (when el-chronos-startup-probe--finish-timer
        (ignore-errors
          (cancel-timer el-chronos-startup-probe--finish-timer))))))

;;; 降级（不可用 / 未加载）

(ert-deftest el-chronos-startup-probe-test-anchor-without-before-init-time ()
  "`before-init-time' 为 nil 或不可见时 `--anchor' 不抛错、也不倒填锚点。
交互式启动后的会话（REPL 里手工 load 探针）就是这种场景。
**不能用 `makunbound' 模拟「未绑定」**：`before-init-time' 是预加载的内置变量，
Emacs 31 直接报 `Built-in variable may not be unbound`，故改用 `boundp' 桩覆盖
`--anchor' 里 `(boundp \\='before-init-time)' 那一支。"
  (el-chronos-startup-probe-test--with-probe
    ;; ① 绑定为 nil
    (let ((before-init-time nil))
      (should-not (el-chronos-startup-probe--anchor 'early-init)))
    (should-not el-chronos-startup-probe--anchors)
    ;; ② 模拟「根本未绑定」：只让 `boundp' 对该符号返回 nil
    (let ((real-boundp (symbol-function 'boundp)))
      (cl-letf (((symbol-function 'boundp)
                 (lambda (symbol)
                   (if (eq symbol 'before-init-time)
                       nil
                     (funcall real-boundp symbol)))))
        (should-not (boundp 'before-init-time))
        (should (boundp 'load-path))
        (should-not (el-chronos-startup-probe--anchor 'early-init))
        (should-not el-chronos-startup-probe--anchors)))))

(ert-deftest el-chronos-startup-probe-test-finish-without-take-function ()
  "collect 侧交接函数不存在时（collect 未加载 / T3 未落地）`--finish' 不报错。
数据留内存等后续 take —— 用户可能压根没启用 `el-chronos-mode'。"
  (el-chronos-startup-probe-test--with-probe
    (let ((saved (and (fboundp 'el-chronos-collect--startup-take-probe)
                      (symbol-function 'el-chronos-collect--startup-take-probe))))
      (unwind-protect
          (progn
            (when saved
              (fmakunbound 'el-chronos-collect--startup-take-probe))
            (should-not (fboundp 'el-chronos-collect--startup-take-probe))
            (puthash "foo" 1.0 el-chronos-startup-probe--loads)
            (should-not (el-chronos-startup-probe--finish))
            (should el-chronos-startup-probe--done-p)
            ;; 收尾不清数据：留给 collect 之后来取
            (should (= 1 (hash-table-count el-chronos-startup-probe--loads))))
        (when saved
          (fset 'el-chronos-collect--startup-take-probe saved))))))

(ert-deftest el-chronos-startup-probe-test-finish-soft-calls-take-function ()
  "交接函数存在时 `--finish' 软调用它一次（二次增量补写的载体）。
首次 take 发生在 mode 启动时刻，探针真正摘钩在事件循环下一轮 —— 两者之间的加载
没人拉取，只能由探针在收尾处主动交棒。"
  (el-chronos-startup-probe-test--with-probe
    (el-chronos-startup-probe-test--stub-take
      (el-chronos-startup-probe--instrument)
      (el-chronos-startup-probe--finish)
      (should el-chronos-startup-probe--done-p)
      (should (= 1 take-calls))
      ;; 幂等收尾会再软调用一次（每次收尾都尝试交棒，无副作用）
      (el-chronos-startup-probe--finish)
      (should (= 2 take-calls)))))

(provide 'el-chronos-startup-probe-test)

;;; el-chronos-startup-probe-test.el ends here
