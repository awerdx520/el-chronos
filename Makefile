# el-chronos 验证入口
#
# 全部目标使用 `emacs -Q --batch`（不依赖 emacsclient / 不碰运行中的 daemon）。
# 无 .el 文件时 check-parens / lint / test 均空跑成功，保证仓库初期骨架可用。

EMACS ?= emacs
EL_FILES := $(shell find . -name '*.el' -not -path './.git/*' -not -path './.local/*' -not -name 'el-chronos-autoloads.el' 2>/dev/null)
TEST_FILES := $(sort $(wildcard test/*-test.el))

.PHONY: all check-parens test lint autoloads full-check clean

all: full-check

# L1：括号平衡检查（逐文件）
check-parens:
	@if [ -z "$(EL_FILES)" ]; then \
		echo "no elisp files"; \
	else \
		for f in $(EL_FILES); do \
			echo "check-parens: $$f"; \
			$(EMACS) -Q --batch --eval '(progn (find-file (car command-line-args-left)) (check-parens) (kill-emacs 0))' "$$f" || exit 1; \
		done; \
	fi

# L2：ERT 测试（自动发现 test/*-test.el 并全部加载；无测试文件时空跑成功）
test:
	@if [ -z "$(TEST_FILES)" ]; then \
		echo "no test files"; \
	else \
		echo "test: $(TEST_FILES)"; \
		$(EMACS) -Q --batch -L . -L test $(addprefix -l ,$(TEST_FILES)) -f ert-run-tests-batch-and-exit; \
	fi

# L1 补充：字节编译告警检查（输出到临时目录，不污染仓库）
lint:
	@if [ -z "$(EL_FILES)" ]; then \
		echo "no elisp files"; \
	else \
		build_dir=$$(mktemp -d); \
		for f in $(EL_FILES); do \
			echo "lint: $$f"; \
			EL_CHRONOS_BC_DIR="$$build_dir" $(EMACS) -Q --batch -L . --eval '(setq byte-compile-error-on-warn nil byte-compile-dest-file-function (lambda (f) (expand-file-name (file-name-nondirectory f) (getenv "EL_CHRONOS_BC_DIR"))))' -f batch-byte-compile "$$f" || { rm -rf "$$build_dir"; exit 1; }; \
		done; \
		rm -rf "$$build_dir"; \
	fi

full-check: check-parens test

# autoloads：生成 `el-chronos-autoloads.el`（按需生成，**生成物不入库、不进 L1/L2**）
#
# 用途：use-package / 手工 autoload 场景下让 16 个 interactive 命令在包未加载时也能 M-x 调用。
# 不入库的原因：生成物与原文件必然漂移，按需重建即可（`.gitignore` 已忽略）；
# 不进 L1/L2 的原因：`EL_FILES` 的 find 已显式排除，否则生成后检查范围会随生成物变化。
# 实现分流：Emacs 29+ 用 `loaddefs-generate`（自身产物列入 EXCLUDED-FILES 防自引用），
# 更早版本回退 `make-directory-autoloads`（与 ERT 用例同源守卫，不硬编码单一实现）。
autoloads:
	@$(EMACS) -Q --batch -L . --eval '(progn (unless (fboundp (quote loaddefs-generate)) (require (quote autoload))) (if (fboundp (quote loaddefs-generate)) (loaddefs-generate "." "el-chronos-autoloads.el" (list "el-chronos-autoloads.el")) (make-directory-autoloads "." "el-chronos-autoloads.el")) (let ((n (with-temp-buffer (insert-file-contents "el-chronos-autoloads.el") (count-lines (point-min) (point-max))))) (message "el-chronos-autoloads.el 生成完成：%d 行" n)))'


clean:
	rm -rf .eln-cache eln-cache
	find . -name '*.elc' -not -path './.git/*' -delete
