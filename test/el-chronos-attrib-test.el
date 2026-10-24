;;; el-chronos-attrib-test.el --- 归因层（符号 → 包 / 上下文）ERT 测试  -*- lexical-binding: t; -*-

;; 覆盖 `el-chronos-attrib--classify-path' 的六条路径分类分支、
;; 符号归因（built-in / unknown）、上下文的项目 basename 不含路径分隔符，
;; 以及符号归因缓存的命中行为。

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'el-chronos)
(require 'el-chronos-attrib)
(eval-and-compile
  ;; `make lint' 只带 `-L .'：编译期把本文件所在目录（test/）加进 load-path，
  ;; 否则下面的 `require' 找不到 helper；运行期由 `-L test' 提供，本段跳过。
  (when (bound-and-true-p byte-compile-current-file)
    (add-to-list 'load-path (file-name-directory byte-compile-current-file))))
(require 'el-chronos-test-helper)

;;; 路径分类六分支

(ert-deftest el-chronos-attrib-test-classify-straight-build ()
  "straight build 目录（带版本号与不带版本号两种布局）都归到包名。"
  (should (equal "magit"
                 (el-chronos-attrib--classify-path
                  "/home/u/.emacs.d/.local/straight/build-31.1/magit/magit.el")))
  (should (equal "org"
                 (el-chronos-attrib--classify-path
                  "/home/u/.emacs.d/.local/straight/build/org/org.el"))))

(ert-deftest el-chronos-attrib-test-classify-straight-repos ()
  "straight repos 目录归到包名。"
  (should (equal "magit"
                 (el-chronos-attrib--classify-path
                  "/home/u/.emacs.d/.local/straight/repos/magit/lisp/magit.el"))))

(ert-deftest el-chronos-attrib-test-classify-init-module ()
  "用户配置模块 lisp/init-*.el 归到模块名。"
  (should (equal "init-base"
                 (el-chronos-attrib--classify-path "/home/u/emacs/lisp/init-base.el")))
  (should (equal "init-llm"
                 (el-chronos-attrib--classify-path "/home/u/emacs/lisp/init-llm.el"))))

(ert-deftest el-chronos-attrib-test-classify-site-lisp ()
  "site-lisp 单文件归到 \"site-lisp/<名>\"。"
  (should (equal "site-lisp/my-tool"
                 (el-chronos-attrib--classify-path "/home/u/emacs/site-lisp/my-tool.el"))))

(ert-deftest el-chronos-attrib-test-classify-built-in ()
  "系统 Emacs 内置文件归到 \"built-in\"（发行版安装前缀与 /usr 前缀两条判据）。"
  (should (equal "built-in"
                 (el-chronos-attrib--classify-path "/usr/share/emacs/31.1/lisp/files.elc")))
  (should (equal "built-in"
                 (el-chronos-attrib--classify-path "/opt/emacs/lisp/subr.el"))))

(ert-deftest el-chronos-attrib-test-classify-unknown ()
  "nil / 空串 / 非字符串 / 无特征路径一律降级为 \"unknown\"（I6）。"
  (should (equal "unknown" (el-chronos-attrib--classify-path nil)))
  (should (equal "unknown" (el-chronos-attrib--classify-path "")))
  (should (equal "unknown" (el-chronos-attrib--classify-path 42)))
  (should (equal "unknown" (el-chronos-attrib--classify-path "/tmp/scratch.el"))))

(ert-deftest el-chronos-attrib-test-classify-straight-wins ()
  "优先级：straight 目录下即使出现 lisp/init-*.el 也认包名而不是配置模块。"
  (should (equal "foo-mod"
                 (el-chronos-attrib--classify-path
                  "/home/u/.local/straight/build-31.1/foo-mod/lisp/init-x.el"))))

;;; 符号归因

(ert-deftest el-chronos-attrib-test-package-built-in ()
  "内置函数 `save-buffer' 归到 \"built-in\"（源码路径在系统 Emacs 目录下）。"
  (el-chronos-attrib-clear-cache)
  (should (equal "built-in" (el-chronos-attrib-package 'save-buffer))))

(ert-deftest el-chronos-attrib-test-package-unknown-symbol ()
  "不存在的符号归到 \"unknown\"，且不抛错。"
  (el-chronos-attrib-clear-cache)
  (should (equal "unknown" (el-chronos-attrib-package 'el-chronos-no-such-symbol-xyzzy)))
  (should-not (el-chronos-attrib-file 'el-chronos-no-such-symbol-xyzzy)))

(ert-deftest el-chronos-attrib-test-package-accepts-path ()
  "参数为字符串时直接按路径分类，符号与路径两种入参共用同一套判据。"
  (should (equal "magit" (el-chronos-attrib-package
                          "/home/u/.local/straight/repos/magit/magit.el")))
  (should (equal "unknown" (el-chronos-attrib-package nil))))

(ert-deftest el-chronos-attrib-test-cache-hit ()
  "同一符号第二次归因命中缓存，不再调用 `symbol-file'。"
  (el-chronos-attrib-clear-cache)
  (let ((calls 0)
        (original (symbol-function 'symbol-file)))
    (cl-letf (((symbol-function 'symbol-file)
               (lambda (&rest args)
                 (setq calls (1+ calls))
                 (apply original args))))
      (should (equal "built-in" (el-chronos-attrib-package 'save-buffer)))
      (should (equal "built-in" (el-chronos-attrib-package 'save-buffer)))
      (should (= 1 calls)))
    (should (= 1 (el-chronos-attrib-clear-cache)))))

;;; native-comp `.eln' 归因（TD-1）

(ert-deftest el-chronos-attrib-test-eln-library-candidates ()
  "从 `.eln' 文件名剪出候选库名：两段哈希优先，单段与原样兜底。
实测 Emacs 29+ 文件名形如 `<库名>-<8位hex>-<8位hex>.eln'（两段哈希）。"
  (let ((candidates (el-chronos-attrib--eln-library-candidates
                     (concat "/home/u/.emacs.d/eln-cache/31.1-8806c27d/"
                             "etaf-runtime-6519e0cb-e3ee97c3.eln"))))
    ;; 第一个候选就是剪掉两段哈希后的库名，反查一次即可命中
    (should (equal "etaf-runtime" (car candidates)))
    (should (member "etaf-runtime" candidates)))
  ;; 单段哈希（早期形态，位数不固定）也要能剪掉
  (should (member "foo"
                  (el-chronos-attrib--eln-library-candidates
                   "/home/u/.emacs.d/eln-cache/28.1-abc/foo-6519e0cb.eln")))
  ;; 非 `.eln' / 非字符串 → nil
  (should-not (el-chronos-attrib--eln-library-candidates
               "/home/u/.local/straight/build-31.1/magit/magit.elc"))
  (should-not (el-chronos-attrib--eln-library-candidates nil))
  ;; subr trampoline 文件名里没有库名：剪不动，只剩原样一个候选
  ;; （实际由 `el-chronos-attrib--classify-eln' 的前缀分支拦截，不会走到反查）
  (should (= 1 (length (el-chronos-attrib--eln-library-candidates
                        (concat "/x/eln-cache/31.1-abc/subr--trampoline-"
                                "7365742d77696e646f772d627566666572_set_window_buffer_0.eln"))))))

(ert-deftest el-chronos-attrib-test-classify-eln-to-package ()
  "eln-cache 下的 `.eln' 靠文件名反查源码库，再按源码路径归到 straight 包名。"
  (el-chronos-attrib-clear-cache)
  (cl-letf (((symbol-function 'locate-library)
             (lambda (library &rest _)
               (when (equal library "magit-status")
                 "/home/u/.emacs.d/.local/straight/build-31.1/magit/magit-status.elc"))))
    (should (equal "magit"
                   (el-chronos-attrib--classify-path
                    (concat "/home/u/.emacs.d/eln-cache/31.1-8806c27d/"
                            "magit-status-a79d2fac-f169e7b7.eln"))))))

(ert-deftest el-chronos-attrib-test-classify-eln-unresolvable ()
  "反查不到源码库的 `.eln' 降级 \"unknown\"，绝不猜包名（宁缺勿错）。"
  (el-chronos-attrib-clear-cache)
  (cl-letf (((symbol-function 'locate-library) (lambda (&rest _) nil)))
    (should (equal "unknown"
                   (el-chronos-attrib--classify-path
                    "/home/u/.emacs.d/eln-cache/31.1-8806c27d/achive-dec52775-fd11e29e.eln")))
    ;; 已删除包的 `.eln' 同样降级，且不抛错（I6）
    (should (equal "unknown"
                   (el-chronos-attrib--classify-path
                    "/home/u/.emacs.d/eln-cache/31.1-8806c27d/.yas-setup-68420073-a5e6bac6.eln")))))

(ert-deftest el-chronos-attrib-test-classify-eln-built-in-paths ()
  "subr trampoline 与系统 native-lisp 目录的 `.eln' 直接判 built-in，不做反查。"
  (el-chronos-attrib-clear-cache)
  (let ((calls 0))
    (cl-letf (((symbol-function 'locate-library)
               (lambda (&rest _) (setq calls (1+ calls)) nil)))
      (should (equal "built-in"
                     (el-chronos-attrib--classify-path
                      (concat "/home/u/.emacs.d/eln-cache/31.1-8806c27d/subr--trampoline-"
                              "7365742d77696e646f772d627566666572_set_window_buffer_0.eln"))))
      (should (equal "built-in"
                     (el-chronos-attrib--classify-path
                      (concat "/usr/lib/emacs/31.1/native-lisp/31.1-8806c27d/"
                              "locate-bbb85898-7be8d951.eln"))))
      (should (= 0 calls)))))

(ert-deftest el-chronos-attrib-test-classify-eln-cached ()
  "同一 `.eln' 路径第二次归因命中缓存，不再调用 `locate-library'。"
  (el-chronos-attrib-clear-cache)
  (let ((eln (concat "/home/u/.emacs.d/eln-cache/31.1-8806c27d/"
                     "etaf-runtime-6519e0cb-e3ee97c3.eln"))
        (calls 0))
    (cl-letf (((symbol-function 'locate-library)
               (lambda (library &rest _)
                 (setq calls (1+ calls))
                 (when (equal library "etaf-runtime")
                   "/home/u/.emacs.d/.local/straight/build-31.1/etaf/lisp/etaf-runtime.elc"))))
      (should (equal "etaf" (el-chronos-attrib--classify-path eln)))
      (should (equal "etaf" (el-chronos-attrib--classify-path eln)))
      (should (= 1 calls)))
    ;; 缓存条目确实写进了归因缓存表，且可被统一清理
    (should (= 1 (el-chronos-attrib-clear-cache)))))

(ert-deftest el-chronos-attrib-test-package-from-eln-symbol ()
  "符号经 `symbol-file' 拿到 `.eln' 路径时，端到端仍能归到源码包名。"
  (el-chronos-attrib-clear-cache)
  (let ((eln (concat "/home/u/.emacs.d/eln-cache/31.1-8806c27d/"
                     "magit-status-a79d2fac-f169e7b7.eln")))
    (cl-letf (((symbol-function 'symbol-file) (lambda (&rest _) eln))
              ((symbol-function 'locate-library)
               (lambda (library &rest _)
                 (when (equal library "magit-status")
                   "/home/u/.emacs.d/.local/straight/build-31.1/magit/magit-status.elc"))))
      (should (equal "magit" (el-chronos-attrib-package 'magit-status))))))

(ert-deftest el-chronos-attrib-test-classify-source-skips-locate ()
  "非 `.eln' 路径不触发 `locate-library'（归因热路径不新增 IO）。"
  (let ((calls 0))
    (cl-letf (((symbol-function 'locate-library)
               (lambda (&rest _) (setq calls (1+ calls)) nil)))
      (should (equal "magit"
                     (el-chronos-attrib--classify-path
                      "/home/u/.local/straight/build-31.1/magit/magit.elc")))
      (should (equal "built-in"
                     (el-chronos-attrib--classify-path
                      "/usr/share/emacs/31.1/lisp/files.elc")))
      (should (= 0 calls)))))

;;; 上下文

(ert-deftest el-chronos-attrib-test-context-project-basename ()
  "项目内 buffer 的 `:project' 是项目 basename，绝不含 \"/\"（I7）。"
  (el-chronos-test-with-tmp-dir dir
    (make-directory (expand-file-name ".git" dir))
    (with-temp-buffer
      (setq default-directory (file-name-as-directory dir))
      (let ((context (el-chronos-attrib-context)))
        (should (equal (file-name-nondirectory (directory-file-name dir))
                       (plist-get context :project)))
        (should-not (string-match-p "/" (plist-get context :project)))
        (should (stringp (plist-get context :mode)))
        ;; 默认粒度 command 下不记录被操作文件路径（I7）
        (should-not (plist-get context :file))))))

(ert-deftest el-chronos-attrib-test-context-outside-project ()
  "不在任何项目里的 buffer，`:project' 为 nil，上下文仍完整可用。"
  (with-temp-buffer
    (setq default-directory "/")
    (let ((context (el-chronos-attrib-context)))
      (should-not (plist-get context :project))
      (should (stringp (plist-get context :mode))))))

(ert-deftest el-chronos-attrib-test-context-file-granularity ()
  "粒度设为 `file' 时 `:file' 才出现，且等于 `buffer-file-name'。"
  (el-chronos-test-with-tmp-dir dir
    (let ((file (expand-file-name "sample.el" dir)))
      (with-temp-file file (insert ";; noop\n"))
      (with-current-buffer (find-file-noselect file)
        (unwind-protect
            (let ((el-chronos-usage-granularity 'file))
              (should (equal file (plist-get (el-chronos-attrib-context) :file))))
          (set-buffer-modified-p nil)
          (kill-buffer))))))

(provide 'el-chronos-attrib-test)

;;; el-chronos-attrib-test.el ends here
