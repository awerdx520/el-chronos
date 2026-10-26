;;; el-chronos-autoload-test.el --- autoload 契约（cookie / 生成物 / 库名）ERT 测试  -*- lexical-binding: t; -*-

;; 覆盖三件事：
;; 1. `el-chronos-autoload-test-cookies-cover-all-interactive-commands`：
;;    16 个 interactive 命令都带紧贴其定义的 `;;;###autoload` cookie，且
;;    「cookie 数 == 命令清单长度 == `(interactive` 代码出现次数 +
;;    `(define-minor-mode` 代码出现次数」三者相等（不写死单一数字，
;;    增删命令时用例自动跟随）。
;; 2. `el-chronos-autoload-test-autoloads-file-makes-commands-callable`：
;;    按与 Makefile 同源逻辑生成 autoloads 到临时目录，加载后 16 个命令
;;    `autoloadp` 全为 t（包未加载时 M-x 可调用）。
;; 3. `el-chronos-autoload-test-library-matches-definition`：
;;    每条 autoload 记录的库名等于该命令的定义文件名（防 cookie 落错文件）。
;;
;; 本文件只读：autoloads 生成到临时目录并由 `unwind-protect` 清理，不写仓库文件、
;; 不启 timer、不碰网络、不触发采集；不依赖 `el-chronos-test-helper`（无需数据库）。

;;; Code:

(require 'ert)

;; 编译期声明：`loaddefs-generate` 由 Emacs 29+ 提供，`make-directory-autoloads`
;; 由内置 `autoload.el` 提供。运行时按 `fboundp` 分流（与 Makefile 同源守卫，
;; 不硬编码单一实现）。
(declare-function loaddefs-generate "loaddefs-gen"
                  (dir output-file &optional excluded-files state))
(declare-function make-directory-autoloads "autoload" (dir &optional output-file))

;;; 常量

(defconst el-chronos-autoload-test--commands
  '(("el-chronos-mode" . "el-chronos")
    ("el-chronos-status" . "el-chronos")
    ("el-chronos-attrib-clear-cache" . "el-chronos-attrib")
    ("el-chronos-store-flush" . "el-chronos-store")
    ("el-chronos-purge" . "el-chronos-store")
    ("el-chronos-store-vacuum" . "el-chronos-store")
    ("el-chronos-collect-start" . "el-chronos-collect")
    ("el-chronos-collect-stop" . "el-chronos-collect")
    ("el-chronos-report" . "el-chronos-report")
    ("el-chronos-weekly-report" . "el-chronos-report")
    ("el-chronos-export" . "el-chronos-report")
    ("el-chronos-show-event" . "el-chronos-report")
    ("el-chronos-profile-command" . "el-chronos-report")
    ("el-chronos-web-start" . "el-chronos-web")
    ("el-chronos-web-stop" . "el-chronos-web")
    ("el-chronos-web-browse" . "el-chronos-web"))
  "全部 interactive 命令与其定义文件（库名，不含 .el 后缀）。
顺序与计划「需带 autoload cookie 的 16 个命令」表一致。")

(defconst el-chronos-autoload-test--source-files
  '("el-chronos"
    "el-chronos-attrib"
    "el-chronos-store"
    "el-chronos-collect"
    "el-chronos-report"
    "el-chronos-web"
    "el-chronos-analysis")
  "参与计数不变量的源文件（不含 .el 后缀）。
`el-chronos-analysis` 是纯查询模块，期望 cookie 数为 0。")

;;; 辅助函数

(defun el-chronos-autoload-test--root ()
  "返回 el-chronos 源码根目录。
测试须带 `-L .` 运行（`make test` / `make lint` 均如此），否则报错而非静默跳过。"
  (let ((lib (locate-library "el-chronos")))
    (unless lib
      (error "load-path 中找不到 el-chronos，请用 `-L .` 运行测试"))
    (file-name-directory lib)))

(defun el-chronos-autoload-test--source-file (name)
  "返回源文件 NAME（不含 .el 后缀）的绝对路径。"
  (expand-file-name (concat name ".el") (el-chronos-autoload-test--root)))

(defun el-chronos-autoload-test--source-text (name)
  "读取源文件 NAME（不含 .el 后缀）的全文。"
  (with-temp-buffer
    (insert-file-contents (el-chronos-autoload-test--source-file name))
    (buffer-string)))

(defun el-chronos-autoload-test--count-code-occurrences (text needle)
  "统计 TEXT 中 NEEDLE 的**代码**出现次数（注释与字符串内的不计）。
判定用 `syntax-ppss` 的字符串/注释状态（`(nth 3 pp)` / `(nth 4 pp)`），
不用「逐行截断分号」的粗糙做法（对 docstring 示例与块注释不可靠）。
注意：`syntax-ppss` 可能移动 point，必须用 `save-excursion` 包裹，
否则外层 `search-forward` 会反复命中同一个位置而死循环。"
  (with-temp-buffer
    (insert text)
    (emacs-lisp-mode)
    (let ((count 0))
      (save-excursion
        (goto-char (point-min))
        (while (search-forward needle nil t)
          (let ((pp (save-excursion (syntax-ppss (match-beginning 0)))))
            (when (and (not (nth 3 pp)) (not (nth 4 pp)))
              (setq count (1+ count))))))
      count)))

(defun el-chronos-autoload-test--count-cookie-lines (text)
  "统计 TEXT 中以 `;;;###autoload` 开头的行数（cookie 本身是注释，行首匹配即可）。"
  (let ((count 0))
    (dolist (line (split-string text "\n"))
      (when (string-match-p "\\`[ \t]*;;;###autoload[ \t]*\\'" line)
        (setq count (1+ count))))
    count))

(defun el-chronos-autoload-test--cookie-before-def-p (lines command)
  "LINES 中是否存在紧贴 COMMAND 定义行上方的 `;;;###autoload` 行。
「紧贴」= cookie 行与定义行之间不允许有空行。"
  (let ((found nil))
    (while (and lines (not found))
      (when (and (string-match-p "\\`[ \t]*;;;###autoload[ \t]*\\'" (car lines))
                 (cdr lines)
                 (string-match-p
                  (concat "\\`[ \t]*(\\(?:defun\\|define-minor-mode\\) "
                          (regexp-quote command)
                          "\\(?:[ \t\n)]\\|\\'\\)")
                  (cadr lines)))
        (setq found t))
      (setq lines (cdr lines)))
    found))

(defun el-chronos-autoload-test--generate (dir)
  "在 DIR 中生成 autoloads 文件并返回其路径。
与 Makefile 的 `autoloads` 目标同源：优先 `loaddefs-generate`（把仓库根已有的
生成物列入 EXCLUDED-FILES 防自引用），缺失时回退 `make-directory-autoloads`。"
  (require 'autoload)
  (let ((out (expand-file-name "el-chronos-autoload-test-autoloads.el" dir))
        (src (el-chronos-autoload-test--root)))
    (if (fboundp 'loaddefs-generate)
        (loaddefs-generate src out (list "el-chronos-autoloads.el"))
      (make-directory-autoloads src out))
    (unless (file-exists-p out)
      (error "autoloads 生成失败：%s 不存在" out))
    out))

(defun el-chronos-autoload-test--library-basename (library)
  "把 autoload 记录里的库名归一化为文件基名（去掉目录与扩展名）。
在临时目录生成时 `loaddefs-generate` 写的是相对输出目录的库名（如
\"../../home/u/repo/el-chronos\"），与 Makefile 在仓库根生成时的 \"el-chronos\"
等价，故比较前统一取基名；若 cookie 落错文件，基名仍会不同（如
\"el-chronos-store\"），断言依然有效。"
  (file-name-nondirectory (file-name-sans-extension library)))

(defun el-chronos-autoload-test--parse-autoloads (file)
  "解析 FILE 中的 `(autoload \\='NAME \"LIB\"` 记录，返回 ((NAME . LIB) ...)。"
  (let ((records nil))
    (with-temp-buffer
      (insert-file-contents file)
      (goto-char (point-min))
      (while (re-search-forward
              "^[ \t]*(autoload '\\([^ \t\n\"]+\\) \"\\([^\"]+\\)\"" nil t)
        (push (cons (match-string-no-properties 1)
                    (match-string-no-properties 2))
              records)))
    (nreverse records)))

;;; 用例 1：cookie 覆盖全部 interactive 命令

(ert-deftest el-chronos-autoload-test-cookies-cover-all-interactive-commands ()
  "全部 interactive 命令都带紧贴定义的 autoload cookie，且计数不变量成立。"
  ;; 断言 A：逐条命令检查「cookie 行紧贴定义行」
  (dolist (entry el-chronos-autoload-test--commands)
    (let* ((command (car entry))
           (library (cdr entry))
           (lines (split-string (el-chronos-autoload-test--source-text library)
                                "\n")))
      (unless (el-chronos-autoload-test--cookie-before-def-p lines command)
        (ert-fail
         (format "命令 %s 缺少紧贴定义的 `;;;###autoload` cookie（定义文件 %s.el）"
                 command library)))))
  ;; 断言 B：计数不变量。当前实测为 `(interactive` 15 次 + `(define-minor-mode` 1 次
  ;; = 16 次，与 cookie 数、清单长度三者相等；这里刻意不写死 15 / 1，
  ;; 以便未来增删命令时用例自动跟随（真正的守卫是「三者相等」）。
  (let ((cookies 0)
        (interactives 0)
        (minor-modes 0)
        (detail nil))
    (dolist (name el-chronos-autoload-test--source-files)
      (let* ((text (el-chronos-autoload-test--source-text name))
             (c (el-chronos-autoload-test--count-cookie-lines text))
             (i (el-chronos-autoload-test--count-code-occurrences text "(interactive"))
             (m (el-chronos-autoload-test--count-code-occurrences
                 text "(define-minor-mode")))
        (setq cookies (+ cookies c)
              interactives (+ interactives i)
              minor-modes (+ minor-modes m))
        (push (format "  %s.el: cookie=%d interactive=%d define-minor-mode=%d"
                      name c i m)
              detail)))
    (let ((expected (length el-chronos-autoload-test--commands)))
      (unless (and (= (+ interactives minor-modes) cookies)
                   (= cookies expected))
        (ert-fail
         (format (concat "autoload 计数不变量不成立："
                         "cookie=%d，清单=%d，interactive=%d，"
                         "define-minor-mode=%d，interactive+mode=%d\n明细：\n%s")
                 cookies expected interactives minor-modes
                 (+ interactives minor-modes)
                 (mapconcat #'identity (nreverse detail) "\n"))))))
  ;; 断言 C：analysis 是纯查询模块，无 interactive 命令，cookie 必须为 0
  ;; （防止「顺手加个 cookie」破坏契约）。
  (let ((analysis-cookies
         (el-chronos-autoload-test--count-cookie-lines
          (el-chronos-autoload-test--source-text "el-chronos-analysis"))))
    (unless (= 0 analysis-cookies)
      (ert-fail (format "el-chronos-analysis.el 不该有 autoload cookie（实测 %d 处）：查询模块没有 interactive 命令，请检查是否误加"
                        analysis-cookies)))))

;;; 用例 2：生成的 autoloads 让命令可调用

(ert-deftest el-chronos-autoload-test-autoloads-file-makes-commands-callable ()
  "加载生成的 autoloads 后，16 个命令都是 autoload stub。"
  (unless (fboundp 'loaddefs-generate)
    (ert-skip "loaddefs-generate 不存在，跳过（make autoloads 会走 make-directory-autoloads 回退）"))
  (let ((tmp (make-temp-file "el-chronos-autoloads-test-" t))
        (commands (mapcar (lambda (entry) (intern (car entry)))
                          el-chronos-autoload-test--commands)))
    (unwind-protect
        (let ((out (el-chronos-autoload-test--generate tmp))
              (saved nil))
          ;; 隔离方案 A（本进程内保存 / 恢复）：`make test` 把全部测试文件加载进
          ;; 同一进程，此时这 16 个命令多半已由其他测试的 `require` 变成真实定义。
          ;; 实测 `autoload` **不覆盖**已有定义——探针：
          ;;   (progn (defun foo () 1) (autoload 'foo "nonexistent")
          ;;          (autoloadp (symbol-function 'foo)))  ⇒ nil
          ;; 因此必须先 `fmakunbound` 再 `load`，否则永远看不到 autoload stub。
          ;; 为不留跨用例污染：先保存每个符号的现有定义（原先未定义记 nil），
          ;; 断言结束后在清理段逐个恢复（nil 用 `fmakunbound` 还原）。
          (dolist (command commands)
            (push (cons command (and (fboundp command) (symbol-function command)))
                  saved))
          (unwind-protect
              (progn
                (dolist (command commands)
                  (when (fboundp command)
                    (fmakunbound command)))
                (load out nil t)
                (dolist (command commands)
                  (unless (and (fboundp command)
                               (autoloadp (symbol-function command)))
                    (ert-fail
                     (format "加载生成的 autoloads 后 %s 不是 autoload stub（fboundp=%S，定义=%S）"
                             command (fboundp command)
                             (and (fboundp command)
                                  (symbol-function command)))))))
            (dolist (pair saved)
              (if (cdr pair)
                  (fset (car pair) (cdr pair))
                (when (fboundp (car pair))
                  (fmakunbound (car pair)))))))
      (delete-directory tmp t))))

;;; 用例 3：autoload 记录的库名与定义文件一致

(ert-deftest el-chronos-autoload-test-library-matches-definition ()
  "每条 autoload 记录的库名等于命令的定义文件名；无遗漏、无多余。"
  (unless (fboundp 'loaddefs-generate)
    (ert-skip "loaddefs-generate 不存在，跳过（make autoloads 会走 make-directory-autoloads 回退）"))
  (let ((tmp (make-temp-file "el-chronos-autoloads-lib-test-" t)))
    (unwind-protect
        (let* ((out (el-chronos-autoload-test--generate tmp))
               (records (el-chronos-autoload-test--parse-autoloads out)))
          ;; 逐条：命令 → 期望库名 → 实际库名
          (dolist (entry el-chronos-autoload-test--commands)
            (let* ((command (car entry))
                   (expected (cdr entry))
                   (actual (cdr (assoc command records))))
              (unless actual
                (ert-fail (format "命令 %s 未出现在生成的 autoloads 中（期望库名 %s）"
                                  command expected)))
              (unless (equal (el-chronos-autoload-test--library-basename actual)
                             expected)
                (ert-fail (format "命令 %s → 期望库名 %s，实际库名 %s"
                                  command expected actual)))))
          ;; 无多余：生成物里不能有清单之外的 autoload 命令
          (let ((extra nil))
            (dolist (record records)
              (unless (assoc (car record) el-chronos-autoload-test--commands)
                (push (car record) extra)))
            (when extra
              (ert-fail (format "生成的 autoloads 含清单之外的命令：%s"
                                (mapconcat #'identity (nreverse extra) ", ")))))
          ;; 条数一致（防同一命令重复生成）
          (unless (= (length records)
                     (length el-chronos-autoload-test--commands))
            (ert-fail (format "生成的 autoload 记录数 %d 与命令清单长度 %d 不一致"
                              (length records)
                              (length el-chronos-autoload-test--commands)))))
      (delete-directory tmp t))))

(provide 'el-chronos-autoload-test)

;;; el-chronos-autoload-test.el ends here
