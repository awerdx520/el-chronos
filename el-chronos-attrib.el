;;; el-chronos-attrib.el --- 符号与包归属归因  -*- lexical-binding: t; -*-

;; 本模块负责把「一个符号」逐级归因到「包 / 配置模块 / site-lisp / built-in」，
;; 并提供命令执行时的上下文（major-mode、项目 basename、可选的文件路径）。
;; 注意两种「文件」不要混用：函数所在的**定义源码文件**由 `el-chronos-attrib-file'
;; 提供（用于包归因）；上下文里的 `:file' 是**被操作文件**（`buffer-file-name'），
;; 只在 `el-chronos-usage-granularity' 为 `file' 时出现（默认不记，守 I7）。
;;
;; 归因链：符号 --symbol-file--> 源码文件路径 --路径前缀--> 包名。
;; 归因失败一律降级为 "unknown"，绝不向宿主抛错（不变量 I6）；
;; 上下文只取项目 basename，绝不落绝对路径（不变量 I7）。
;;
;; 仅依赖内置库 cl-lib / subr-x，不引入任何第三方依赖。

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(declare-function project-current "project" (&optional maybe-prompt directory))
(declare-function project-root "project" (project))

(defconst el-chronos-attrib--missing 'el-chronos-attrib--missing
  "查询缓存时的「未命中」哨兵。
区别于「命中但值为 nil」（缓存里存 `el-chronos-attrib--no-file`），
避免对已知无源码路径的符号重复调用 `symbol-file'。")

(defconst el-chronos-attrib--no-file 'el-chronos-attrib--no-file
  "缓存中表示「该符号确定没有源码文件」的占位值。")

(defvar el-chronos-attrib--cache (make-hash-table :test #'equal)
  "符号 → 归因结果的缓存表。
键为符号，值为源码文件路径字符串，或 `el-chronos-attrib--no-file` 表示确实没有源码文件。
用 `el-chronos-attrib-clear-cache' 清空（例如重新加载包之后）。")

(defvar-local el-chronos-attrib--project-cache nil
  "当前 buffer 的项目 basename 缓存，形状为 cons `(BUFFER-FILE . BASENAME)'。
`BUFFER-FILE' 是计算时的 `buffer-file-name'（可能为 nil），`BASENAME' 是那次算出的
项目 basename（nil 表示**确定**不在项目里）。

命中条件：缓存非 nil 且 `(car cache)' 与当前 `buffer-file-name' `equal'。
nil 也缓存 —— 否则 `*scratch*' 这类无文件 buffer 会为每条命令重跑一次
`project-current'（它会遍历 `locate-dominating-file'，是命令热路径上的开销）。
缓存随 buffer 走（buffer-local），`el-chronos-attrib-clear-cache' 不遍历 buffer 清它。")

(defun el-chronos-attrib-clear-cache ()
  "清空符号归因缓存，返回被清除的条目数。
重装/重载包之后调用，避免继续命中旧的源码路径。
注意：**不含**项目 basename 缓存 —— 后者是 buffer-local（`--project-cache'），
随 buffer 的 `buffer-file-name' 变化自动失效，不在此处遍历清理。"
  (interactive)
  (let ((count (hash-table-count el-chronos-attrib--cache)))
    (clrhash el-chronos-attrib--cache)
    count))

(defun el-chronos-attrib--classify-path (path)
  "把源码文件路径 PATH 归类为包或模块名（纯函数，无副作用）。
返回值与判定顺序（示例均为路径 → 结果）：
  1. straight build 目录 → 包名
     …/straight/build-31.1/magit/magit.el → \"magit\"
  2. straight repos 目录 → 包名
     …/straight/repos/magit/lisp/magit.el → \"magit\"
  3. 配置模块 lisp/init-*.el → 模块名
     …/lisp/init-base.el → \"init-base\"
  4. site-lisp 单文件 → \"site-lisp/<名>\"
  5. 系统 Emacs 内置文件 → \"built-in\"
  6. 其余（nil / 非字符串 / 空串） → \"unknown\"

优先级上 straight 最高：straight 目录下也可能出现 `lisp/init-*.el` 之类名字，
必须先认包再认配置模块。"
  (cond
   ((not (stringp path)) "unknown")
   ((string-empty-p path) "unknown")
   ;; 1) straight build（含 build-<版本> 与无版本号的 build 两种布局）
   ((string-match "/\\.local/straight/build[^/]*/\\([^/]+\\)/" path)
    (match-string 1 path))
   ;; 2) straight repos
   ((string-match "/\\.local/straight/repos/\\([^/]+\\)/" path)
    (match-string 1 path))
   ;; 3) 用户配置模块 lisp/init-*.el
   ((string-match "/lisp/\\(init-[^/]+\\)\\.el" path)
    (match-string 1 path))
   ;; 4) site-lisp 单文件
   ((string-match "/site-lisp/\\([^/]+\\)\\.el" path)
    (concat "site-lisp/" (match-string 1 path)))
   ;; 5) 系统 Emacs 内置（发行版安装前缀，或 lisp 目录位于系统前缀下）
   ((string-match-p "\\(?:/usr/share/emacs/\\|/emacs-[0-9]\\)" path) "built-in")
   ((and (string-match-p "/lisp/" path)
         (string-match-p "^/\\(?:usr\\|opt\\|snap\\|nix\\)/" path))
    "built-in")
   (t "unknown")))

(defun el-chronos-attrib-file (symbol)
  "返回 SYMBOL 的定义源码文件路径；取不到时返回 nil。
先按函数定义查 `symbol-file'，失败再查任意定义；两步都失败即 nil。
结果缓存于 `el-chronos-attrib--cache'，避免在采集路径上反复查询。

注意：Emacs 30+ 的原生编译函数（如 straight 包内的函数）可能返回 `.eln' 路径
而不是 `.el'。本函数**原样保留** `.eln' 路径、不抛错，由
`el-chronos-attrib--classify-path' 靠路径前缀归因；但 `.eln' 若落在
`eln-cache' 目录下则无法识别包名，会降级为 \"unknown\"（技术债 TD-1）。"
  (when (symbolp symbol)
    (let ((hit (gethash symbol el-chronos-attrib--cache el-chronos-attrib--missing)))
      (cond
       ;; 未命中：现查一次并写缓存
       ((eq hit el-chronos-attrib--missing)
        (let ((path (or (ignore-errors (symbol-file symbol 'defun))
                        (ignore-errors (symbol-file symbol)))))
          (puthash symbol (or path el-chronos-attrib--no-file) el-chronos-attrib--cache)
          path))
       ;; 命中的是「确实没有源码文件」
       ((eq hit el-chronos-attrib--no-file) nil)
       (t hit)))))

(defun el-chronos-attrib-package (symbol-or-path)
  "把符号或源码路径归因到包/模块名；任何失败都返回 \"unknown\"。
参数为符号时先经 `el-chronos-attrib-file' 取源码路径再分类；
参数为字符串时直接按路径分类。
本函数不会向调用方抛错（不变量 I6：采集中归因失败静默降级）。"
  (condition-case nil
      (cond
       ((null symbol-or-path) "unknown")
       ((stringp symbol-or-path)
        (el-chronos-attrib--classify-path symbol-or-path))
       ((symbolp symbol-or-path)
        (el-chronos-attrib--classify-path
         (el-chronos-attrib-file symbol-or-path)))
       (t "unknown"))
    (error "unknown")))

(defun el-chronos-attrib--project-basename-uncached ()
  "查询当前 buffer 所属项目的 basename（不含任何路径成分），取不到时 nil。
`project-current' 在非项目 buffer、TRAMP、或 project.el 异常时都可能出错，
故整体包在 `condition-case' 中降级为 nil（不变量 I6）。本函数**不读缓存**，
只由 `el-chronos-attrib--project-basename' 在缓存失效时调用。"
  (condition-case nil
      (when-let* ((project (project-current))
                  (root (project-root project)))
        (let ((base (file-name-nondirectory (directory-file-name root))))
          ;; 项目根为 "/" 等特殊情况会得到空串，按「取不到」处理
          (unless (string-empty-p base) base)))
    (error nil)))

(defun el-chronos-attrib--project-basename ()
  "返回当前 buffer 所属项目的 basename，取不到时 nil；结果按 buffer 缓存。
缓存键是计算时的 `buffer-file-name'：只有它与当前值 `equal' 时才命中，
因此切换 buffer 的文件（`set-visited-file-name'、`find-alternate-file'）会重算。
「不在项目里」（nil）也写进缓存 —— 命令热路径上不能每条命令都跑一次
`project-current'（它会走 `locate-dominating-file'，是 IO）。详见
`el-chronos-attrib--project-cache'。

已知取舍：无文件 buffer（`*scratch*'、`*compilation*' 等，且多半 `dired' 出来的目录
缓冲）若 `default-directory' 变了而 `buffer-file-name' 仍是 nil，缓存不会失效 ——
这类 buffer 的项目归属继续保持首次计算结果，直到 `buffer-file-name' 变化、buffer
被重建，或手动 `(setq el-chronos-attrib--project-cache nil)' 失效。"
  (let* ((file (buffer-file-name))
         (cached el-chronos-attrib--project-cache))
    (if (and cached (equal (car cached) file))
        (cdr cached)
      (let ((base (el-chronos-attrib--project-basename-uncached)))
        (setq el-chronos-attrib--project-cache (cons file base))
        base))))

(defun el-chronos-attrib--context-file ()
  "返回**被操作文件**的路径；仅当粒度为 `file' 时返回 `buffer-file-name'。
语义：这是命令作用的那个文件（`buffer-file-name'），不是函数定义所在文件 ——
后者由 `el-chronos-attrib-file' 单独提供，两者含义不同，不要混用。

粒度由 `el-chronos-usage-granularity' 决定：变量未定义（入口模块未加载）或取
`command' / `mode' 等更粗粒度时返回 nil，即默认不记录任何文件路径（不变量 I7）。
取到路径时，collect 层会把它写进慢事件的 `:file' context，并在粒度恰为 `file' 时
额外累加一条 `dimension=\"file\"' 的用法统计。"
  (when (eq (bound-and-true-p el-chronos-usage-granularity) 'file)
    (buffer-file-name)))

(defun el-chronos-attrib-context ()
  "返回当前命令上下文的 plist：(:mode MODE :project BASENAME :file PATH-or-nil)。
`:mode'    为 `major-mode' 的符号名字符串；
`:project' 为项目 basename（绝不含 \"/\"，不变量 I7；按 buffer 缓存）；
`:file'    为**被操作文件**路径（`buffer-file-name'），**不是**函数定义文件；
           仅在 `el-chronos-usage-granularity' 为 `file' 时给出，否则恒为 nil（I7）。
           用途：慢事件 context 与文件维度用法统计（见 `el-chronos-attrib--context-file'）。
本函数不抛错：任何子步骤失败都降级为 nil 字段。"
  (list :mode (let ((mode major-mode))
                (when mode (symbol-name mode)))
        :project (el-chronos-attrib--project-basename)
        :file (condition-case nil
                  (el-chronos-attrib--context-file)
                (error nil))))

(provide 'el-chronos-attrib)

;;; el-chronos-attrib.el ends here
