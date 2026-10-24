;;; el-chronos-store-test.el --- 存储层（schema / flush / 保留 / purge）ERT 测试  -*- lexical-binding: t; -*-

;; 全部用例在临时目录里的独立 SQLite 库上跑（`el-chronos-test-with-db'），
;; 不触碰 `<user-emacs-directory>' 下的真实库，也不依赖网络与第三方包。

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'sqlite)
(require 'el-chronos)
(require 'el-chronos-store)
(eval-and-compile
  ;; `make lint' 只带 `-L .'（不编译 test/ 目录）：编译期据 `byte-compile-current-file'
  ;; 把本文件所在目录加进 load-path，否则下面的 `require' 找不到 helper。
  ;; 运行期由 `make test' 的 `-L test' 提供，本段自然跳过。
  (when (bound-and-true-p byte-compile-current-file)
    (add-to-list 'load-path (file-name-directory byte-compile-current-file))))
(require 'el-chronos-test-helper)

;;; 打开与 schema

(ert-deftest el-chronos-store-test-open-idempotent ()
  "同路径重复 open 返回同一句柄、只建一行会话、只起一个 flush timer。"
  (el-chronos-test-with-db
    (let ((db el-chronos-store--db))
      (should db)
      (should (eq db (el-chronos-store-open el-chronos-db-path)))
      (should (equal (expand-file-name el-chronos-db-path) el-chronos-store--path))
      (should (= 1 (el-chronos-test--count "sessions")))
      (should (timerp el-chronos-store--flush-timer))
      ;; 会话 ID 由 open 写入，重开复用同一行
      (should (integerp el-chronos--session-id)))))

(ert-deftest el-chronos-store-test-user-version-migration ()
  "新库迁移到当前 schema 版本，六张表齐备；重开不重复迁移。"
  (el-chronos-test-with-db
    (should (= 1 el-chronos-store--schema-version))
    (should (= el-chronos-store--schema-version
               (el-chronos-test--scalar "PRAGMA user_version")))
    (should (= 6 (el-chronos-test--scalar
                  "SELECT count(*) FROM sqlite_master WHERE type = 'table'\
 AND name IN ('sessions','commands','hourly_functions','slow_events',\
'hourly_usage','hourly_stacks')")))
    (el-chronos-store-close)
    (should (el-chronos-store-open el-chronos-db-path))
    (should (= el-chronos-store--schema-version
               (el-chronos-test--scalar "PRAGMA user_version")))))

(ert-deftest el-chronos-store-test-refuses-future-version ()
  "库里 user_version 高于程序支持的版本时拒绝打开（返回 nil 且不破坏文件）。"
  (el-chronos-test-with-tmp-dir dir
    (let ((path (expand-file-name "future.sqlite" dir)))
      (let ((db (sqlite-open path)))
        (sqlite-pragma db "user_version=99")
        (sqlite-close db))
      (should-not (el-chronos-store-open path))
      (should-not el-chronos-store--db)
      (should (file-exists-p path)))))

;;; 写入与 flush

(ert-deftest el-chronos-store-test-flush-100-commands ()
  "100 条命令先进缓冲，flush 一次全部落库并清空缓冲。"
  (el-chronos-test-with-db
    (dotimes (i 100)
      (el-chronos-store-record-command
       (list :name (format "cmd-%d" i) :duration-ms (float (1+ i))
             :mode "emacs-lisp-mode" :project "proj" :outcome "ok" :kind "interactive")))
    (should (= 0 (el-chronos-test--count "commands")))
    (should (el-chronos-store--pending-p))
    (should (el-chronos-store-flush))
    (should (= 100 (el-chronos-test--count "commands")))
    (should-not (el-chronos-store--pending-p))
    (should-not el-chronos-store--buffer)))

(ert-deftest el-chronos-store-test-usage-upsert-accumulates ()
  "同一 (hour, dimension, key) 的用法统计在库内累加而非新增行。"
  (el-chronos-test-with-db
    (let ((hour (el-chronos-test--hour-ts)))
      (el-chronos-store-record-usage hour 'command "cmd" 1 10.0)
      (el-chronos-store-record-usage hour 'command "cmd" 2 5.0)
      (el-chronos-store-flush)
      (should (= 1 (el-chronos-test--count "hourly_usage")))
      (let ((row (car (sqlite-select el-chronos-store--db
                                     "SELECT count, duration_ms FROM hourly_usage\
 WHERE dimension = 'command' AND key = 'cmd'"
                                     nil))))
        (should (= 3 (nth 0 row)))
        (should (= 15.0 (nth 1 row)))))))

(ert-deftest el-chronos-store-test-stacks-top-n-eviction ()
  "300 条不同 hash（samples 1..300）写库后按 samples 保留 top-200，最小 samples 为 101。"
  (el-chronos-test-with-db
    (let ((hour (el-chronos-test--hour-ts))
          (stacks (cl-loop for i from 1 to 300
                           collect (cons (format "[\"fn-%d\"]" i) i))))
      (el-chronos-store-record-stacks hour stacks)
      (el-chronos-store-flush)
      (should (= 200 (el-chronos-test--count "hourly_stacks")))
      (should (= 101 (el-chronos-test--scalar "SELECT min(samples) FROM hourly_stacks")))
      (should (= 300 (el-chronos-test--scalar "SELECT max(samples) FROM hourly_stacks"))))))

(ert-deftest el-chronos-store-test-null-session-skips-stacks ()
  "会话不可用时跳过 `hourly_stacks'，不写 session_id 为 NULL 的栈行。"
  (el-chronos-test-with-db
    (let ((el-chronos--session-id nil)
          (el-chronos-store--stack-skip-warned t)) ; 已告警过一次，避免测试输出噪声
      (el-chronos-store-record-stacks (el-chronos-test--hour-ts)
                                      (list (cons "[\"a\"]" 5)))
      ;; flush 必须在会话为 nil 的作用域内执行，才是「会话不可用」这条路径
      (el-chronos-store-flush))
    (should (= 0 (el-chronos-test--count "hourly_stacks")))))

(ert-deftest el-chronos-store-test-close-flushes-buffer ()
  "`close' 之前缓冲未落库，close 会自动 flush 后再关句柄。"
  (el-chronos-test-with-db
    (el-chronos-store-record-command (list :name "before-close" :duration-ms 12.5))
    (should (= 0 (el-chronos-test--count "commands")))
    (el-chronos-store-close)
    (should-not el-chronos-store--db)
    (should-not el-chronos-store--flush-timer)
    (should (el-chronos-store-open el-chronos-db-path))
    (should (= 1 (el-chronos-test--count "commands")))))

(ert-deftest el-chronos-store-test-reopen-keeps-data ()
  "关闭再打开同一文件，数据与会话行都保留（同进程复用会话行）。"
  (el-chronos-test-with-db
    (let ((session el-chronos--session-id))
      (el-chronos-store-record-command (list :name "persist" :duration-ms 1.0))
      (el-chronos-store-flush)
      (el-chronos-store-close)
      (should (el-chronos-store-open el-chronos-db-path))
      (should (= 1 (el-chronos-test--count "commands")))
      (should (= 1 (el-chronos-test--count "sessions")))
      (should (= session el-chronos--session-id)))))

(ert-deftest el-chronos-store-test-flush-failure-clears-buffers ()
  "COMMIT 抛错时整批 ROLLBACK，四类缓冲全部清空，不向调用方抛错。"
  (el-chronos-test-with-db
    (let ((hour (el-chronos-test--hour-ts))
          (original (symbol-function 'sqlite-execute)))
      (el-chronos-store-record-command (list :name "doomed" :duration-ms 2.0))
      (el-chronos-store-record-slow-event (list :duration-ms 900.0 :kind "block"))
      (el-chronos-store-record-usage hour 'command "doomed" 1 2.0)
      (el-chronos-store-record-function-samples hour "fn" nil "pkg" 1.0 2.0 1)
      (el-chronos-store-record-stacks hour (list (cons "[\"fn\"]" 1)))
      (should (el-chronos-store--pending-p))
      (cl-letf (((symbol-function 'sqlite-execute)
                 (lambda (db sql &rest args)
                   (if (string-match-p "COMMIT" sql)
                       (error "mock commit failure")
                     (apply original db sql args)))))
        ;; 失败只降级为告警，不抛错
        (should-not (el-chronos-store-flush)))
      (should-not (el-chronos-store--pending-p))
      (should-not el-chronos-store--buffer)
      (should-not el-chronos-store--slow-events)
      (should (= 0 (hash-table-count el-chronos-store--usage)))
      (should (= 0 (hash-table-count el-chronos-store--functions)))
      (should (= 0 (hash-table-count el-chronos-store--stacks)))
      ;; 事务已回滚，明细表没有半批数据
      (should (= 0 (el-chronos-test--count "commands")))
      (should (= 0 (el-chronos-test--count "slow_events"))))))

;;; JSON 序列化

(ert-deftest el-chronos-store-test-json-value-sentinels ()
  "`:false' / `:json-false' / `:null' / nil / 符号 / plist 都转成合法 JSON 形态。"
  (should (eq :false (el-chronos-store--json-value :false)))
  (should (eq :false (el-chronos-store--json-value :json-false)))
  (should (eq :null (el-chronos-store--json-value :null)))
  (should (eq :null (el-chronos-store--json-value nil)))
  (should (equal "kw" (el-chronos-store--json-value :kw)))
  (should (hash-table-p (el-chronos-store--json-value (list :a 1)))))

(ert-deftest el-chronos-store-test-json-string-symbol-stack ()
  "符号组成的调用栈能序列化成 JSON 字符串，落库为 TEXT 而非报错。"
  (el-chronos-test-with-db
    (let ((json (el-chronos-store--json-string
                 '(el-chronos-collect--finish el-chronos-store-flush))))
      (should (stringp json))
      (should (equal '("el-chronos-collect--finish" "el-chronos-store-flush")
                     (json-parse-string json :array-type 'list))))
    (el-chronos-store-record-slow-event
     (list :duration-ms 500.0 :kind "command" :command "cmd"
           :stack '(el-chronos-collect--finish el-chronos-store-flush)
           :context (list :mode "emacs-lisp-mode" :project "proj")))
    (el-chronos-store-flush)
    (let ((row (car (sqlite-select el-chronos-store--db
                                   "SELECT stack_json, context_json FROM slow_events" nil))))
      (should (equal '("el-chronos-collect--finish" "el-chronos-store-flush")
                     (json-parse-string (nth 0 row) :array-type 'list)))
      (should (equal "proj"
                     (plist-get (json-parse-string (nth 1 row) :object-type 'plist)
                                :project))))))

;;; 保留清理与 purge

(ert-deftest el-chronos-store-test-prune-only-details ()
  "保留清理只删 `commands' / `slow_events'，三张 hourly_* 聚合表一行不动。"
  (el-chronos-test-with-db
    (let ((old 1000))                     ; 远早于 30 天阈值
      (el-chronos-test--insert-command old "ancient" 5.0)
      (el-chronos-test--insert-slow-event old 900.0 "block")
      (el-chronos-test--insert-function old "old-fn" nil "pkg" 1.0 1.0 1)
      (el-chronos-test--insert-usage old 'command "ancient" 1 5.0)
      (el-chronos-test--insert-stack old "[\"old-fn\"]" 1)
      (should (= 1 (el-chronos-test--count "hourly_functions")))
      (should (el-chronos-store--prune))
      (should (= 0 (el-chronos-test--scalar
                    "SELECT count(*) FROM commands WHERE name = 'ancient'")))
      (should (= 0 (el-chronos-test--scalar
                    "SELECT count(*) FROM slow_events WHERE ts = ?" (list old))))
      (should (= 1 (el-chronos-test--count "hourly_functions")))
      (should (= 1 (el-chronos-test--count "hourly_usage")))
      (should (= 1 (el-chronos-test--count "hourly_stacks"))))))

(ert-deftest el-chronos-store-test-purge-empties-and-rebuilds-session ()
  "`purge' 无参时清空 6 张表，并立刻补建当前会话行（否则后续写入撞外键）。"
  (el-chronos-test-with-db
    (let ((hour (el-chronos-test--hour-ts)))
      (el-chronos-test--insert-command hour "cmd" 5.0)
      (el-chronos-test--insert-slow-event hour 900.0 "block")
      (el-chronos-test--insert-function hour "fn" nil "pkg" 1.0 1.0 1)
      (el-chronos-test--insert-usage hour 'command "cmd" 1 5.0)
      (el-chronos-test--insert-stack hour "[\"fn\"]" 1)
      (let ((result (el-chronos-purge)))
        (should (= 6 (length result)))
        (should (equal '("commands" "slow_events" "hourly_functions"
                         "hourly_usage" "hourly_stacks" "sessions")
                       (mapcar #'car result))))
      (dolist (table '("commands" "slow_events" "hourly_functions"
                       "hourly_usage" "hourly_stacks"))
        (should (= 0 (el-chronos-test--count table))))
      ;; 会话行被补建，且写入路径仍然可用
      (should (= 1 (el-chronos-test--count "sessions")))
      (should (= 1 (el-chronos-test--scalar
                    "SELECT count(*) FROM sessions WHERE id = ?"
                    (list el-chronos--session-id))))
      (el-chronos-store-record-command (list :name "after-purge" :duration-ms 1.0))
      (el-chronos-store-flush)
      (should (= 1 (el-chronos-test--count "commands"))))))

(provide 'el-chronos-store-test)

;;; el-chronos-store-test.el ends here
