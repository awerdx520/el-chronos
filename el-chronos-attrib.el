;;; el-chronos-attrib.el --- 符号与包归属归因  -*- lexical-binding: t; -*-

;; 本模块负责把「一个符号」逐级归因到「包 / 配置模块 / site-lisp / built-in」，
;; 并提供命令执行时的上下文（major-mode、项目 basename、可选的文件路径）。
;; 注意两种「文件」不要混用：函数所在的**定义源码文件**由 `el-chronos-attrib-file'
;; 提供（用于包归因）；上下文里的 `:file' 是**被操作文件**（`buffer-file-name'），
;; 只在 `el-chronos-usage-granularity' 为 `file' 时出现（默认不记，守 I7）。
;;
;; 归因链：符号 --symbol-file--> 源码文件路径 --路径前缀--> 包名。
;; 例外：C 原语 / 内置特殊形式 / profiler 伪符号（nil 无源码路径）先经
;; `el-chronos-attrib--builtin-primitive-p' 判为 built-in，不走路径归因。
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
  "归因结果缓存表。键空间有两类（符号与字符串永不相等，不会互相命中）：
  1. 符号 → 源码文件路径字符串，或 `el-chronos-attrib--no-file` 表示确实没有源码文件；
  2. native-comp 的 `.eln' 路径（字符串）→ `locate-library' 反查到的源码路径，
     或 `el-chronos-attrib--no-file' 表示确定反查不到。
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
  "清空归因缓存，返回被清除的条目数。
包含两部分：符号 → 源码路径，以及 `.eln' 路径 → 反查到的源码路径
（native-comp 归因用，见 `el-chronos-attrib--eln-source-file'）。
重装/重载包之后调用，避免继续命中旧的源码路径。
注意：**不含**项目 basename 缓存 —— 后者是 buffer-local（`--project-cache'），
随 buffer 的 `buffer-file-name' 变化自动失效，不在此处遍历清理。"
  (interactive)
  (let ((count (hash-table-count el-chronos-attrib--cache)))
    (clrhash el-chronos-attrib--cache)
    count))

(defconst el-chronos-attrib--system-native-lisp-regexp "/native-lisp/[0-9]"
  "系统 Emacs 自带 native-lisp 目录的判据。
实测（2026-10-24，Emacs 31.1）：内置库的 AOT 产物落在
`/usr/lib/emacs/31.1/native-lisp/31.1-8806c27d/<库名>-<8位hex>-<8位hex>.eln'。
该目录只放内置库产物，命中即可直接判 built-in，不必 `locate-library' 反查。")

(defun el-chronos-attrib--eln-library-candidates (path)
  "从 `.eln' 路径 PATH 推出候选库名列表（可靠度降序）。
推不出时返回 nil。
eln-cache 的目录名是 `<版本>-<编译哈希>'、文件名是 `<库名>-<哈希段>'，除库名外没有
任何包信息，故只能剪掉末尾哈希段、把剩下的名字交给 `locate-library' 逐个试。
实测 Emacs 29+ 是**两段**十六进制（源码哈希 + 编译参数哈希，各 8 位，如
`etaf-runtime-6519e0cb-e3ee97c3.eln'），早期版本是单段、位数不固定，故按
「1–2 段、每段 6–32 位十六进制」剪，得到三个候选：
  1. 剪两段 —— 正常形态下一次命中；
  2. 剪一段 —— 兼容单段哈希形态；
  3. 原样 —— 兜底覆盖「库名本身以十六进制段结尾」的边界（如 `foo-deadbeef'）。
剪完为空串或以 `-' 结尾的候选直接丢弃（一定不是库名），重复的只留一个。"
  (when (stringp path)
    (let ((base (file-name-nondirectory path)))
      (when (string-suffix-p ".eln" base)
        (let ((stem (substring base 0 (- (length base) (length ".eln")))))
          (delete-dups
           (delq nil
                 (mapcar
                  (lambda (regexp)
                    (if (null regexp)
                        stem
                      (let ((name (replace-regexp-in-string regexp "" stem)))
                        (unless (or (string-empty-p name) (string-suffix-p "-" name))
                          name))))
                  ;; 两段哈希 / 一段哈希 / 原样兜底
                  (list "\\(?:-[0-9a-f]\\{6,32\\}\\)\\{2\\}\\'"
                        "\\(?:-[0-9a-f]\\{6,32\\}\\)\\'"
                        nil)))))))))

(defun el-chronos-attrib--eln-source-file (path)
  "把 `.eln' 路径 PATH 反查成对应的源码文件路径；反查不到时 nil。
反查方式：从文件名剪出库名（`el-chronos-attrib--eln-library-candidates'）后逐个
`locate-library'，第一个命中即采用 —— 返回的是 `.elc' 或 `.el' 路径（`locate-library'
不返回 `.eln'），可直接交给 `el-chronos-attrib--classify-source' 按目录前缀分类。
反查结果（含「确定反查不到」）按 PATH 缓存进 `el-chronos-attrib--cache'：采样数据里
同一 `.eln' 会反复出现，不能让每次归因都扫一遍 `load-path'（`locate-library' 是 IO）。"
  (let ((hit (gethash path el-chronos-attrib--cache el-chronos-attrib--missing)))
    (cond
     ((eq hit el-chronos-attrib--no-file) nil)
     ((not (eq hit el-chronos-attrib--missing)) hit)
     (t
      (let ((found (cl-loop for name in (el-chronos-attrib--eln-library-candidates path)
                            for lib = (ignore-errors (locate-library name))
                            when lib return lib)))
        (puthash path (or found el-chronos-attrib--no-file) el-chronos-attrib--cache)
        found)))))

(defun el-chronos-attrib--classify-source (path)
  "把**源码/字节码**路径 PATH 归类为包或模块名（纯函数，无副作用）。
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
必须先认包再认配置模块。
注意：本函数**不处理** `.eln'（native-comp 产物没有源码路径形态），入口是
`el-chronos-attrib--classify-path'。"
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

(defun el-chronos-attrib--classify-eln (path)
  "把 native-comp 的 `.eln' 路径 PATH 归类为包/模块名。
无法反查时返回 \"unknown\"。
`.eln' 只出现在三类位置，判据各不相同：
  1. `subr--trampoline-<符号hex>_<名>_<序号>.eln' → \"built-in\"。这是内置 subr 的
     trampoline 产物，文件名里根本没有库名（`locate-library' 必然查不到），
     但它只可能是内置 subr 的产物，按前缀判定是可靠的；
  2. 系统 native-lisp 目录 → \"built-in\"。判据见
     `el-chronos-attrib--system-native-lisp-regexp'：该目录只放内置库的 AOT 产物；
  3. 用户 eln-cache（`<user-emacs-directory>/eln-cache/<版本>-<编译哈希>/'）→ 目录名不含
     任何包信息，只能靠文件名反查源码库（`el-chronos-attrib--eln-source-file'），
     再用源码路径沿用普通分类规则；反查失败一律 \"unknown\"（**宁缺勿错**：宁愿记
     unknown 也不猜包名，避免把包占比算到错误包上）。
实测（2026-10-24，真实 Elisp 配置的 eln-cache 844 个 `.eln'）：815 个能反查回源码
（96.6%，且其中 814 个落到 straight build 目录），其余是已删除包、snippet 临时文件
（`.yas-setup-*.eln'）与 trampoline 产物 —— 前两类按设计降级 unknown。"
  (cond
   ((string-prefix-p "subr--trampoline-" (file-name-nondirectory path)) "built-in")
   ((string-match-p el-chronos-attrib--system-native-lisp-regexp path) "built-in")
   (t (let ((source (el-chronos-attrib--eln-source-file path)))
        (cond
         ((null source) "unknown")
         ;; 反查若仍返回 `.eln'（异常情形）则不再递归，保守降级，防死循环
         ((string-suffix-p ".eln" source) "unknown")
         (t (el-chronos-attrib--classify-source source)))))))

(defun el-chronos-attrib--classify-path (path)
  "把路径 PATH（源码 / 字节码 / `.eln'）归类为包或模块名。
先分流 `.eln'（`el-chronos-attrib--classify-eln'）：eln-cache 目录里没有包名信息，
靠文件名剪出库名反查源码库，反查成功再按源码路径前缀分类，失败降级 \"unknown\"；
非 `.eln' 路径直接按源码路径前缀判定（`el-chronos-attrib--classify-source'）。
`.eln' 反查结果会被缓存（写入 `el-chronos-attrib--cache'），此外无外部副作用。"
  (cond
   ((not (stringp path)) "unknown")
   ((string-empty-p path) "unknown")
   ((string-suffix-p ".eln" path) (el-chronos-attrib--classify-eln path))
   (t (el-chronos-attrib--classify-source path))))

(defun el-chronos-attrib--builtin-primitive-p (symbol)
  "SYMBOL 是 Emacs 内核实现的 C 原语 / 内置特殊形式 / profiler 伪符号时返回 \"built-in\"，否则 nil。
`symbol-file' 对 C 原语与特殊形式**恒返回 nil**（Emacs 31.1 实测），故它们无法走
「符号 → 源码路径 → 包名」的常规归因链，会被误判成 `unknown'（实测占全部样本 37.1%）。
判据（按顺序，全部 `ignore-errors' 包裹，失败即视为不命中）：

1. **非 fboundp 的 profiler 伪符号**：`redisplay_internal (C function)' 与
   `Automatic GC' 是 C profiler 自己 mint 的符号（`strings /usr/bin/emacs' 可查到字面串），
   既不是 fboundp 也没有源码路径。`(not (fboundp SYMBOL))' 是**必需前提**——否则任何
   名字恰好以 \" (C function)\" 结尾的真实函数会被误判（后缀带前导空格，避免误伤）。
2. **C 原语 / 特殊形式**：`fboundp' 且 `(subrp (indirect-function SYMBOL))'。
   排除动态模块函数（`module-function-p' 为 t）：模块来自第三方，归 built-in 会掩盖其来源；
   `module-function-p' 在 Emacs 29 以下不存在，故用 `fboundp' 守卫，守卫失败时按「非模块」处理
   （那些版本还没有模块函数这一说）。

注意：`format' 这类能查到 `format.elc' 的也在 `subrp' 之列，归 built-in 与既有
`--classify-source' 的判定一致，不产生冲突。"
  (ignore-errors
    (and (symbolp symbol)
         (or
          ;; 1) profiler 伪符号（非 fboundp）
          (and (not (fboundp symbol))
               (let ((name (symbol-name symbol)))
                 (or (string-suffix-p " (C function)" name)
                     (string= name "Automatic GC"))))
          ;; 2) C 原语 / 内置特殊形式（排除动态模块）
          (and (fboundp symbol)
               (let ((function (indirect-function symbol)))
                 (and (subrp function)
                      (not (and (fboundp 'module-function-p)
                                (module-function-p function)))))))
         "built-in")))

(defun el-chronos-attrib-file (symbol)
  "返回 SYMBOL 的定义源码文件路径；取不到时返回 nil。
先按函数定义查 `symbol-file'，失败再查任意定义；两步都失败即 nil。
结果缓存于 `el-chronos-attrib--cache'，避免在采集路径上反复查询。

注意：Emacs 30+ 的原生编译函数可能返回 `.eln' 路径而不是 `.el'/`.elc' ——
实测（2026-10-24，Emacs 31.1）显式加载 `.eln' 后 `symbol-file' 返回形如
`…/eln-cache/31.1-8806c27d/magit-status-a79d2fac-f169e7b7.eln' 的路径。
本函数**原样保留** `.eln' 路径、不抛错，交给 `el-chronos-attrib--classify-path'
处理：系统 native-lisp 目录与 subr trampoline 直接判 built-in，用户 eln-cache
目录从文件名反查源码库再按源码路径分类，反查失败降级 \"unknown\"
（TD-1 已关闭，见 `openspec/tech-debt.md'）。"
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
符号分支先判 C 原语 / profiler 伪符号（→ \"built-in\"），再走源码路径归因。
本函数不会向调用方抛错（不变量 I6：采集中归因失败静默降级）。"
  (condition-case nil
      (cond
       ((null symbol-or-path) "unknown")
       ((stringp symbol-or-path)
        (el-chronos-attrib--classify-path symbol-or-path))
       ((symbolp symbol-or-path)
        (or (el-chronos-attrib--builtin-primitive-p symbol-or-path)
            (el-chronos-attrib--classify-path
             (el-chronos-attrib-file symbol-or-path))))
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
