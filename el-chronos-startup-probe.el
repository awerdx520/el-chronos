;;; el-chronos-startup-probe.el --- early-init 启动探针（零依赖、只写内存）  -*- lexical-binding: t; -*-

;; 用途：把「启动阶段锚点 + 包加载耗时明细」的测量点从 `el-chronos-mode' 剥离到
;; `early-init.el'。用户在 early-init 里显式 `(load "el-chronos-startup-probe" t)'，
;; 本文件加载即上岗：记 `early-init' 锚点、挂三个钩子（`after-load-functions' /
;; `after-init-hook' / `emacs-startup-hook'），启动结束后自摘钩，数据留在内存里
;; 等 collect 侧（`el-chronos-collect--startup-take-probe'）主动 `take' 走。
;;
;; 为什么需要它：本机 `el-chronos-mode' 挂在 `emacs-startup-hook' 里启用，
;; 此刻 `after-init-time' 已非 nil，`el-chronos-collect--startup-instrument' 按既定
;; 设计**一个钩子都不挂** → `startup_phases' 只有 `mode-start' 一行、`load:*' 明细 0 条。
;;
;; 硬约束（违反即失败）：
;;   1. **零依赖**：不 require 任何 el-chronos 模块，不 require cl-lib / subr-x / seq
;;      或任何第三方库。只用内置函数（浮点时间、hash、hook、timer、condition-case）。
;;      `clrhash' 是内置 C 函数（`emacs -Q' 下 `fboundp' 即为 t），用它不算引依赖。
;;   2. **绝不抛错、绝不提示**：所有入口 `condition-case' 包裹，失败只忽略 ——
;;      early-init 期 `display-warning' / `message' 都可能打断或污染启动。
;;   3. **绝不写库、绝不写文件**：不碰 sqlite、不碰 `el-chronos-db-path'。收集只进内存。
;;
;; 口径（必须保留「近似归因」措辞，TD-16 的可见性约束）：包加载耗时是
;; `after-load-functions' **相邻两次回调**的 `float-time' 差值 —— 近似归因，
;; 不是精确归因：差值里含前一个文件的收尾逻辑与它触发的钩子执行。

;;; Code:

;; T3 在 collect 侧实现并调用本探针的交接函数。这里只声明签名，**不 require** ——
;; 探针必须在 collect 完全未加载时也能工作（`fboundp' 守卫 + 软调用）。
(declare-function el-chronos-collect--startup-take-probe "el-chronos-collect" ())

(defconst el-chronos-startup-probe--load-limit 800
  "`after-load-functions' 累计记录多少次后强制收尾（防病态累积）。
量级依据：一次正常启动加载数百个库，800 ≈ 2 倍余量。**这不是业务阈值**，
不可配置 —— 它只为兜住「`emacs-startup-hook' 永不触发」（init 报错等异常）时
钩子无限累积与内存无限增长这一种病态情形。正常路径由 `emacs-startup-hook'
的 0 秒延时收尾负责，`--fallback-timer' 是第二条下界。")

(defconst el-chronos-startup-probe--fallback-seconds 30
  "`after-init-hook' 之后登记的第二条兜底下界（秒）。
`init' 文件报错时 `emacs-startup-hook' 不会跑，否则收尾永不发生，故在
`after-init-hook' 里再登记一个一次性 timer 到时无条件收尾。")

(defvar el-chronos-startup-probe--loads (make-hash-table :test #'equal)
  "启动期包加载耗时累计表：library 名 → 累计毫秒（float）。
**内存里保存全量**（一次启动几百条可忽略）；top-N 截断由 collect 在写库前做，
探针零依赖读不到 `el-chronos-startup-top-n'，也不该读。
`el-chronos-startup-probe-take' 取走后 `clrhash' 清空（增量语义）。")

(defvar el-chronos-startup-probe--anchors nil
  "启动阶段锚点表：alist，phase 符号 → 相对 `before-init-time' 的毫秒（float）。
**同一 phase 首个值优先**（不覆盖）：锚点语义是「首次到达该阶段的时刻」，
重写只会让值漂到更晚。`take' 只读不重置（重复写同 phase 同值由 `startup_phases'
主键 upsert 吸收，幂等）。")

(defvar el-chronos-startup-probe--last-load-ts nil
  "上一次 `after-load-functions' 触发的 `float-time'；nil 表示尚未建立基线。
首次触发**只建基线不记录** —— 否则第一条会带上「探针上岗到第一次 load」的间隔，
那是启动开销而不是该文件自己的 load 耗时。")

(defvar el-chronos-startup-probe--load-count 0
  "已记录的启动期 load 次数（累计，不随 `take' 清零）。
两个用途：① 与 `--load-limit' 比较构成收尾下界之一；
② 排障时确认「到底挂了多少次」。")

(defvar el-chronos-startup-probe--done-p nil
  "是否已收尾（`--finish' 已被调用过）。幂等判据之一。
收尾后 `after-load-functions' 已摘、timer 已取消，数据仍留内存等 collect 拉取。")

(defvar el-chronos-startup-probe--finish-timer nil
  "`emacs-startup-hook' 里登记的 0 秒延时收尾 timer；nil 表示未登记或已取消。
**必须**由 `--finish' cancel：探针的生命周期不在 `el-chronos-mode -1' 的清理清单里，
I5 在此没有覆盖，漏 cancel 就等于遗留一个探针侧 timer。")

(defvar el-chronos-startup-probe--fallback-timer nil
  "`after-init-hook' 里登记的 30 秒兜底 timer；nil 表示未登记或已取消。
与 `--finish-timer' 一样必须在 `--finish' 内 cancel，理由同它。")

(defvar el-chronos-startup-probe--instrumented-p nil
  "是否已挂过钩子（幂等守卫）。
`(load \"el-chronos-startup-probe\" t)' 可能被重复执行（`load' 不像 `require'
受 `provide' 保护），没有这层守卫就会把同一个函数挂进 hook 多次。")

;;; 内部工具

(defun el-chronos-startup-probe--library (file)
  "从 FILE 取 library 名：去目录、去（可能的双层）扩展名。
`after-load-functions' 传的是文件名，形态有 `.el' / `.elc' / `.eln' 与压缩的
`.el.gz'（剥一层后仍剩 `.el'，故再剥一次）。
**不用 `file-name-base'**：它在 `.eln' 路径（straight 的 build 目录）上的表现需自行
核验，这里用 `file-name-nondirectory' + 手工剥扩展名，逻辑与
`el-chronos-collect--startup-library' 等价（等价性由本文件测试覆盖）。
非字符串输入返回空串，绝不抛错。"
  (condition-case nil
      (if (stringp file)
          (let ((base (file-name-nondirectory file)))
            (when (string-match "\\.[^./]*\\'" base)
              (setq base (substring base 0 (match-beginning 0))))
            (when (string-match "\\.el\\'" base)
              (setq base (substring base 0 (match-beginning 0))))
            base)
        "")
    (error "")))

(defun el-chronos-startup-probe--captured-p ()
  "探针是否采集到过任何启动数据 —— `captured-p' 字段的统一口径。
三条件取或：`--done-p'（已收尾）/ `--load-count' 大于 0（记录过 load）/
`--anchors' 非空（至少在启动期上岗并记到了某个阶段锚点）。
三者任一为真即「探针在启动期真的工作过」；`take' 把 loads 取空后本判据仍可能为真
（它就是「曾经采到过」，不是「此刻还有待取数据」）。"
  (or el-chronos-startup-probe--done-p
      (> el-chronos-startup-probe--load-count 0)
      (and el-chronos-startup-probe--anchors t)))

(defun el-chronos-startup-probe--loads-alist ()
  "把 `--loads' 拷成 alist `(LIBRARY . MS)'，按毫秒降序。
只读快照：不修改 hash。排序用内置 `sort'（不是 cl-*）。"
  (condition-case nil
      (let (entries)
        (maphash (lambda (library ms) (push (cons library ms) entries))
                 el-chronos-startup-probe--loads)
        (sort entries (lambda (a b) (> (cdr a) (cdr b)))))
    (error nil)))

(defun el-chronos-startup-probe--anchor (phase)
  "记录阶段锚点 PHASE 相对 `before-init-time' 的毫秒偏移（float）。
PHASE 取 `early-init' / `after-init' / `startup'。**同一 phase 首个值优先**：
已存在则不覆盖（「首次到达时刻」语义）。
`before-init-time' 未绑定或其值为 nil（交互式启动、REPL 里手工加载）时直接返回
nil：这类会话没有启动起点，**不能倒填**锚点，也不该报错。
返回偏移毫秒（便于排障），未记录时返回 nil。"
  (condition-case nil
      (when (and (boundp 'before-init-time) before-init-time)
        (unless (assq phase el-chronos-startup-probe--anchors)
          (let ((ms (* 1000.0
                        (float-time (time-subtract (current-time)
                                                   before-init-time)))))
            (push (cons phase ms) el-chronos-startup-probe--anchors)
            ms)))
    (error nil)))

(defun el-chronos-startup-probe--finish ()
  "幂等收尾：摘 `after-load-functions'、cancel 两个 timer、置 `--done-p'，然后软调用 collect。
**幂等**：重复调用安全 —— 钩子已摘、timer 已置 nil、`done-p' 已 t 时只重复做无副作用的
摘除与软调用，绝不重复登记任何 timer。
**两个 timer 都要 cancel**（`--finish-timer' 与 `--fallback-timer'）：探针生命周期
不在 `el-chronos-mode -1' 的清理清单里（I5 在此无覆盖），漏一个就是探针侧遗留 timer。
**软调用**：collect 未加载时 `fboundp' 为 nil，什么都不做 —— 数据留内存等后续 `take'
（用户可能压根没启用 `el-chronos-mode'）。collect 已加载则让它把「首次 take 之后到本次
收尾之间」的增量 loads 补写掉（那次加载没人拉取，只能由探针在此主动交棒）。
永不抛错。"
  (condition-case nil
      (progn
        (remove-hook 'after-load-functions #'el-chronos-startup-probe--after-load)
        (dolist (timer (list el-chronos-startup-probe--finish-timer
                             el-chronos-startup-probe--fallback-timer))
          (when timer
            (ignore-errors (cancel-timer timer))))
        (setq el-chronos-startup-probe--finish-timer nil
              el-chronos-startup-probe--fallback-timer nil
              el-chronos-startup-probe--done-p t)
        (when (fboundp 'el-chronos-collect--startup-take-probe)
          (condition-case nil
              (el-chronos-collect--startup-take-probe)
            (error nil))))
    (error nil))
  nil)

;;; 钩子回调（按「先定义被调用者」顺序排列，避免前向引用）

(defun el-chronos-startup-probe--after-load (file)
  "`after-load-functions' 回调：把相邻两次触发的差值记成 FILE 的加载耗时。
FILE 是刚 load 完的文件名；耗时是**近似归因**（见文件头口径）。
首次调用只建基线不记录（否则第一条会带上探针上岗到第一次 load 的启动开销）。
高频调用（每次 `require' 一次），只做三件事：读 `float-time'、累加内存 hash、
检查收尾条件；**绝不写库、绝不提示**。任何异常都吞掉：钩子在 load 尾部运行，
抛错会打断正在加载的包。"
  (condition-case nil
      (let ((now (float-time)))
        (if (null el-chronos-startup-probe--last-load-ts)
            (setq el-chronos-startup-probe--last-load-ts now)
          (let* ((elapsed (* 1000.0
                             (- now el-chronos-startup-probe--last-load-ts)))
                 (library (el-chronos-startup-probe--library file))
                 (previous (gethash library el-chronos-startup-probe--loads 0)))
            (puthash library (+ (float previous) elapsed)
                     el-chronos-startup-probe--loads)
            (setq el-chronos-startup-probe--last-load-ts now)
            (setq el-chronos-startup-probe--load-count
                  (1+ el-chronos-startup-probe--load-count))
            (when (or el-chronos-startup-probe--done-p
                      (>= el-chronos-startup-probe--load-count
                          el-chronos-startup-probe--load-limit))
              (el-chronos-startup-probe--finish)))))
    (error nil))
  nil)

(defun el-chronos-startup-probe--after-init ()
  "`after-init-hook' 回调：自摘、记 `after-init' 锚点、登记 30 秒兜底 timer。
自摘是幂等前提：收尾后再触发时不该往已停的探针里塞值。
**不在此摘 `after-load-functions'**：`emacs-startup-hook' 及其触发的 load 还在后面，
摘钩统一由 `--finish' 负责（三条收尾路径全部收敛到它）。
兜底 timer 的存在理由：`init' 报错时 `emacs-startup-hook' 不会跑，
没有这条下界收尾就永不发生。"
  (condition-case nil
      (progn
        (remove-hook 'after-init-hook #'el-chronos-startup-probe--after-init)
        (el-chronos-startup-probe--anchor 'after-init)
        (when el-chronos-startup-probe--fallback-timer
          (ignore-errors (cancel-timer el-chronos-startup-probe--fallback-timer)))
        (unless el-chronos-startup-probe--done-p
          (setq el-chronos-startup-probe--fallback-timer
                (run-with-timer el-chronos-startup-probe--fallback-seconds nil
                                #'el-chronos-startup-probe--finish))))
    (error nil))
  nil)

(defun el-chronos-startup-probe--on-startup ()
  "`emacs-startup-hook' 回调：自摘、记 `startup' 锚点，登记 **0 秒延时** 收尾 timer。
**为什么延时 0 秒而不是立刻收尾**（时序依赖，不可改成直接调用）：
`add-hook' 默认前插，本回调排在用户回调**之前**；而 `emacs-startup-hook' 的其余回调
与随后的 `window-setup-hook' 都是同步代码。若在此立刻 `--finish'，就会把「启动收尾
阶段自己触发的 load」挡在 `after-load-functions' 之外。`run-with-timer' 的回调要等
控制权回到事件循环才运行，那时整段同步启动收尾已经跑完 —— 这正是我们要的边界。"
  (condition-case nil
      (progn
        (remove-hook 'emacs-startup-hook #'el-chronos-startup-probe--on-startup)
        (el-chronos-startup-probe--anchor 'startup)
        (when el-chronos-startup-probe--finish-timer
          (ignore-errors (cancel-timer el-chronos-startup-probe--finish-timer)))
        (unless el-chronos-startup-probe--done-p
          (setq el-chronos-startup-probe--finish-timer
                (run-with-timer 0 nil #'el-chronos-startup-probe--finish))))
    (error nil))
  nil)

;;; 对外接口

(defun el-chronos-startup-probe-data ()
  "返回探针内存快照 plist：`(:anchors ALIST :loads ALIST :captured-p BOOL)'。
- `:anchors' —— alist，phase 符号 → 相对 `before-init-time' 的毫秒，按记录顺序（早→晚）。
- `:loads' —— alist，library 名 → 累计毫秒，按毫秒降序。
- `:captured-p' —— 见 `el-chronos-startup-probe--captured-p' 的口径。
**纯只读**：不清空、不重置任何状态（与 `el-chronos-startup-probe-take' 的区别就在这里），
可反复调用拿到同一份数据，适合排障与断言。永不抛错（异常时返回 nil）。"
  (condition-case nil
      (list :anchors (reverse el-chronos-startup-probe--anchors)
            :loads (el-chronos-startup-probe--loads-alist)
            :captured-p (el-chronos-startup-probe--captured-p))
    (error nil)))

(defun el-chronos-startup-probe-take ()
  "取走探针数据：plist `(:anchors ALIST :loads ALIST :captured-p BOOL)'。
**增量语义**（与 `data' 的只读语义相对）：
- `:anchors' —— **只读不重置**：重复 take 会重复返回同一份锚点；写库侧靠
  `startup_phases' 的主键 `(session_id, phase)' upsert 吸收幂等，故无需清空
  （清空反而会丢「首次到达时刻」）。
- `:loads' —— **取走即清空**（`clrhash'）：支持多次增量 take，第二次 take 的
  `:loads' 为空列表。
- `:captured-p' —— 取值与本函数是否清空无关（口径见 `--captured-p'）：
  它在清空前算好，所以「刚 take 完立刻再 take」两者返回同一个值。
永不抛错（异常时返回 nil）。"
  (condition-case nil
      (let ((anchors (reverse el-chronos-startup-probe--anchors))
            (loads (el-chronos-startup-probe--loads-alist))
            (captured (el-chronos-startup-probe--captured-p)))
        (clrhash el-chronos-startup-probe--loads)
        (list :anchors anchors :loads loads :captured-p captured))
    (error nil)))

;;; 挂载

(defun el-chronos-startup-probe--instrument ()
  "幂等挂载：记 `early-init' 锚点并挂三个钩子。
已挂过（`--instrumented-p' 为真）则直接返回 —— `load' 可能被重复执行。
三个钩子都在 early-init 期前插（`add-hook' 默认插到最前），所以本探针的回调排在
用户自己的回调**之前**，锚点语义因此是「首次到达该阶段的时刻」。
永不抛错：early-init 期抛错会打断整个启动。"
  (unless el-chronos-startup-probe--instrumented-p
    (setq el-chronos-startup-probe--instrumented-p t)
    (condition-case nil
        (progn
          (el-chronos-startup-probe--anchor 'early-init)
          (add-hook 'after-load-functions #'el-chronos-startup-probe--after-load)
          (add-hook 'after-init-hook #'el-chronos-startup-probe--after-init)
          (add-hook 'emacs-startup-hook #'el-chronos-startup-probe--on-startup))
      (error nil)))
  nil)

(defun el-chronos-startup-probe--reset ()
  "把探针恢复到「从未上岗」的干净状态：摘三个钩子、cancel 两个 timer、清空全部内存态。
**仅供测试与排障使用，生产代码不调用** —— 生产路径的收尾走 `--finish'
（它保留数据等 collect 取走，本函数连数据一起丢）。
存在的理由：探针在文件加载时就挂钩子（这就是它的设计），测试必须能把这份全局态
干净地还原，否则用例之间互相污染。"
  (ignore-errors
    (remove-hook 'after-load-functions #'el-chronos-startup-probe--after-load)
    (remove-hook 'after-init-hook #'el-chronos-startup-probe--after-init)
    (remove-hook 'emacs-startup-hook #'el-chronos-startup-probe--on-startup))
  (dolist (timer (list el-chronos-startup-probe--finish-timer
                       el-chronos-startup-probe--fallback-timer))
    (when timer
      (ignore-errors (cancel-timer timer))))
  (setq el-chronos-startup-probe--finish-timer nil
        el-chronos-startup-probe--fallback-timer nil
        el-chronos-startup-probe--last-load-ts nil
        el-chronos-startup-probe--load-count 0
        el-chronos-startup-probe--done-p nil
        el-chronos-startup-probe--anchors nil
        el-chronos-startup-probe--instrumented-p nil)
  (clrhash el-chronos-startup-probe--loads)
  nil)

;; 加载即上岗：这是「early-init 里一行 `(load ...)' 就生效」的实现方式。
(el-chronos-startup-probe--instrument)

(provide 'el-chronos-startup-probe)

;;; el-chronos-startup-probe.el ends here
