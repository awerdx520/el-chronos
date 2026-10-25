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

;;; fixture：schema v1 旧库

(defconst el-chronos-store-test--v1-ddl
  "
CREATE TABLE IF NOT EXISTS sessions (id INTEGER PRIMARY KEY AUTOINCREMENT, started_at INTEGER NOT NULL, emacs_version TEXT, host TEXT, startup_ms REAL, gc_threshold REAL);
CREATE TABLE IF NOT EXISTS commands (id INTEGER PRIMARY KEY AUTOINCREMENT, ts INTEGER NOT NULL, session_id INTEGER NOT NULL REFERENCES sessions(id), name TEXT NOT NULL, duration_ms REAL NOT NULL, gc_ms REAL, mode TEXT, project TEXT, outcome TEXT, kind TEXT);
CREATE INDEX IF NOT EXISTS idx_commands_ts ON commands(ts);
CREATE INDEX IF NOT EXISTS idx_commands_duration ON commands(duration_ms DESC);
CREATE TABLE IF NOT EXISTS hourly_functions (hour_ts INTEGER NOT NULL, session_id INTEGER NOT NULL, function TEXT NOT NULL, file TEXT, package TEXT, self_ms REAL NOT NULL DEFAULT 0, total_ms REAL NOT NULL DEFAULT 0, samples INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (hour_ts, session_id, function));
CREATE TABLE IF NOT EXISTS slow_events (id INTEGER PRIMARY KEY AUTOINCREMENT, ts INTEGER NOT NULL, duration_ms REAL NOT NULL, kind TEXT, command TEXT, stack_json TEXT, context_json TEXT);
CREATE INDEX IF NOT EXISTS idx_slow_events_ts ON slow_events(ts);
CREATE TABLE IF NOT EXISTS hourly_usage (hour_ts INTEGER NOT NULL, dimension TEXT NOT NULL, key TEXT NOT NULL, count INTEGER NOT NULL DEFAULT 0, duration_ms REAL NOT NULL DEFAULT 0, PRIMARY KEY (hour_ts, dimension, key));
CREATE TABLE IF NOT EXISTS hourly_stacks (hour_ts INTEGER NOT NULL, session_id INTEGER, stack_hash TEXT NOT NULL, stack_json TEXT NOT NULL, samples INTEGER, PRIMARY KEY (hour_ts, session_id, stack_hash));"
  "schema v1 的原始 DDL（6 表 + 3 索引），专用于构造「旧库」fixture。
刻意写成字面量而不是引用 store 的常量：迁移测试必须验证**真的 v1 库**能升级，
若从 `el-chronos-store--schema-ddl' 派生就永远造不出缺表的旧库。")

(defconst el-chronos-store-test--all-tables
  '("commands" "hourly_functions" "hourly_gc" "hourly_health" "hourly_stacks"
    "hourly_usage" "session_meta" "sessions" "slow_events" "startup_phases")
  "schema v2 的全部 10 张用户表（升序，与 `el-chronos-store-test--tables' 的排序一致）。")

(defun el-chronos-store-test--tables (db)
  "返回 DB 中 sqlite_master 记录的用户表名（升序）。
排除 `sqlite_%' 开头的内部表 —— `sessions' / `commands' / `slow_events' 用了
AUTOINCREMENT，SQLite 会额外建 `sqlite_sequence'。"
  (mapcar #'car
          (sqlite-select db "SELECT name FROM sqlite_master\
 WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name")))

(defun el-chronos-store-test--make-v1-db (path)
  "在 PATH 造一个 schema v1 的库并关闭句柄（不经过 store 的 open）。
内容：6 表 + 3 索引、`user_version'=1、1 行 sessions、2 行 commands ——
供「迁移后既有数据一行不丢」断言使用。"
  (let ((db (sqlite-open path))
        ;; 时间戳取当前时刻：open 之后 `--prune' 会按 `el-chronos-retention-days'
        ;; 删掉早于 30 天的 commands，旧时间戳会让「迁移不丢数据」的断言假红。
        (now (truncate (* 1000 (float-time)))))
    (unwind-protect
        (progn
          (sqlite-execute-batch db el-chronos-store-test--v1-ddl)
          (sqlite-pragma db "user_version=1")
          (sqlite-execute
           db "INSERT INTO sessions (started_at, emacs_version, host, startup_ms,\
 gc_threshold) VALUES (?, ?, ?, ?, ?)"
           (list now "31.1" "old-host" 321.0 (float gc-cons-threshold)))
          (dotimes (i 2)
            (sqlite-execute
             db "INSERT INTO commands (ts, session_id, name, duration_ms, gc_ms, mode,\
 project, outcome, kind) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)"
             (list (- now (* (1+ i) 1000)) (+ i 1) (format "old-cmd-%d" i)
                   (float (1+ i)) nil "emacs-lisp-mode" "old-proj" "ok" "interactive"))))
      (sqlite-close db))))

;;; fixture：与真实运行环境隔离的库

(defvar el-chronos-store-test--hermetic-dir nil
  "`el-chronos-store-test--with-hermetic-db' 里绑定的临时目录（即假 `user-emacs-directory'）。")

(defmacro el-chronos-store-test--with-hermetic-db (&rest body)
  "在临时目录里的独立库上执行 BODY，并把 `user-emacs-directory' 绑到同一个临时目录。
为什么需要它（T3 与 T1 的交叉约束）：`--ensure-session' 建会话行时会采集变更标记
`git-head' / `config-sig'，两者的输入都是 `user-emacs-directory' 下的文件。若该变量
指向真实的配置目录（本机 `/home/thomas/thomas-emacs'，既有 `.git' 也有
`early-init.el' / `init.el' / `lisp/init-*.el'），每次 open 都会往 `session_meta'
写 1–2 行 —— 于是「`session_meta' 必为 0」类断言会因**真实环境**而假红，
且用例结果随开发机的配置目录变化。故：凡对 `session_meta' 有精确行数断言的用例
一律用本宏，它提供的临时目录**无 `.git'、无 init 文件**。"
  (declare (indent 0) (debug t))
  `(el-chronos-test-with-tmp-dir el-chronos-store-test--hermetic-dir
     (let ((user-emacs-directory
            (file-name-as-directory el-chronos-store-test--hermetic-dir)))
       (el-chronos-test-with-db ,@body))))

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
  "新库迁移到当前 schema 版本，十张表齐备；重开不重复迁移。"
  (el-chronos-test-with-db
    (should (= 2 el-chronos-store--schema-version))
    (should (= el-chronos-store--schema-version
               (el-chronos-test--scalar "PRAGMA user_version")))
    (should (equal el-chronos-store-test--all-tables
                   (el-chronos-store-test--tables el-chronos-store--db)))
    (el-chronos-store-close)
    (should (el-chronos-store-open el-chronos-db-path))
    (should (= el-chronos-store--schema-version
               (el-chronos-test--scalar "PRAGMA user_version")))))

(ert-deftest el-chronos-store-test-migrate-v1-to-v2 ()
  "v1 旧库（6 表 + `user_version'=1）打开后升到 v2：10 表齐备、既有 commands 不丢、
4 张新表已建但为空。"
  (el-chronos-test-with-tmp-dir dir
    (let ((path (expand-file-name "v1.sqlite" dir))
          ;; 绑定假配置目录：`--ensure-session' 会采变更标记，若指向真实
          ;; `user-emacs-directory' 就会往 `session_meta' 写行，「新表为空」的断言必红
          (user-emacs-directory (file-name-as-directory dir))
          (el-chronos-db-path nil)
          (el-chronos--session-id nil))
      (el-chronos-store-test--make-v1-db path)
      ;; 迁移前先确认 fixture 确实是 v1 的 6 表库
      (let ((raw (sqlite-open path)))
        (unwind-protect
            (progn
              (should (= 1 (caar (sqlite-select raw "PRAGMA user_version"))))
              (should (= 6 (length (el-chronos-store-test--tables raw)))))
          (sqlite-close raw)))
      (setq el-chronos-db-path path)
      (unwind-protect
          (progn
            (should (el-chronos-store-open path))
            (should (= 2 (el-chronos-test--scalar "PRAGMA user_version")))
            (should (equal el-chronos-store-test--all-tables
                           (el-chronos-store-test--tables el-chronos-store--db)))
            ;; 既有明细一行不丢
            (should (= 2 (el-chronos-test--scalar
                          "SELECT count(*) FROM commands WHERE name LIKE 'old-cmd-%'")))
            (should (= 1 (el-chronos-test--scalar
                          "SELECT count(*) FROM sessions WHERE host = 'old-host'")))
            ;; 新 4 表已建且为空（写入层由 T2 负责）
            (dolist (table '("hourly_gc" "startup_phases" "hourly_health"
                            "session_meta"))
              (should (= 0 (el-chronos-test--count table)))))
        (el-chronos-store-close)))))

(ert-deftest el-chronos-store-test-new-db-has-ten-tables ()
  "全新空库 open 后直接是 10 表 + `user_version'=2（`--ensure-schema' 必须走全量 DDL）。"
  (el-chronos-store-test--with-hermetic-db
    (should (= 2 el-chronos-store--schema-version))
    (should (= 2 (el-chronos-test--scalar "PRAGMA user_version")))
    (should (equal el-chronos-store-test--all-tables
                   (el-chronos-store-test--tables el-chronos-store--db)))
    (dolist (table '("hourly_gc" "startup_phases" "hourly_health" "session_meta"))
      (should (= 0 (el-chronos-test--count table))))))

(ert-deftest el-chronos-store-test-migrate-rollback ()
  "v2 迁移脚本报错时整体回滚：open 返回 nil、原库仍是 v1 的 6 表且数据完整、
留下 .bak；去掉注入后同一个库能正常升级。"
  (el-chronos-test-with-tmp-dir dir
    (let ((path (expand-file-name "v1.sqlite" dir))
          (el-chronos-db-path nil)
          (el-chronos--session-id nil))
      (el-chronos-store-test--make-v1-db path)
      ;; 让迁移脚本执行时抛错（`--ensure-schema' 在 from-version=1 时不会被调用，
      ;; 故注入只影响 v2 分支）
      (cl-letf (((symbol-function 'sqlite-execute-batch)
                 (lambda (_db _sql) (error "mock v2 migration failure"))))
        (should-not (el-chronos-store-open path)))
      (should-not el-chronos-store--db)
      (should (file-exists-p (concat path ".bak")))
      ;; 原库未被破坏：仍是 v1 + 6 表 + 完整数据
      (let ((raw (sqlite-open path)))
        (unwind-protect
            (progn
              (should (= 1 (caar (sqlite-select raw "PRAGMA user_version"))))
              (should (= 6 (length (el-chronos-store-test--tables raw))))
              (should (= 2 (caar (sqlite-select raw "SELECT count(*) FROM commands")))))
          (sqlite-close raw)))
      ;; 回滚没有把库弄坏：去掉注入后能正常迁移到 v2
      (unwind-protect
          (progn
            (should (el-chronos-store-open path))
            (should (= 2 (el-chronos-test--scalar "PRAGMA user_version")))
            (should (= 10 (length (el-chronos-store-test--tables
                                   el-chronos-store--db)))))
        (el-chronos-store-close)))))

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
      ;; T5 起 `--pending-p' 在失败后**仍为真**，但唯一原因是 `--flush-failures' = 1
      ;; 有待补写（eventual 语义：写库失败时无法记录失败本身，只能留内存等下一轮）。
      ;; 旧断言 `(should-not (pending-p))` 因此失效 —— 那是「本批数据已丢弃」的等价说法，
      ;; 而现在 `--pending-p' 还承载「有自监控计数没进库」。数据层面的断言全部保留在下面。
      (should (= 1 el-chronos-store--flush-failures))
      (should (el-chronos-store--pending-p))
      (should-not el-chronos-store--buffer)
      (should-not el-chronos-store--slow-events)
      (should (= 0 (hash-table-count el-chronos-store--usage)))
      (should (= 0 (hash-table-count el-chronos-store--functions)))
      (should (= 0 (hash-table-count el-chronos-store--stacks)))
      ;; 其余 4 个自监控计数器一分不减（丢弃量没发生、成功的 flush 次数与耗时不变）
      (should (= 0 el-chronos-store--dropped-commands))
      (should (= 0 el-chronos-store--dropped-events))
      (should (= 0 el-chronos-store--flush-count))
      (should (= 0.0 el-chronos-store--flush-ms-total))
      ;; 失败时库中没有任何 health 行（写库本身就是失败的那件事）
      (should (= 0 (el-chronos-test--count "hourly_health")))
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
  "`purge' 无参时清空 9 张数据表，并立刻补建当前会话行（否则后续写入撞外键）。
补建行的 `startup_ms' 必须为 NULL —— 它是 purge 造的会话行，不该带上本进程的启动耗时。"
  (el-chronos-store-test--with-hermetic-db
    (let ((hour (el-chronos-test--hour-ts))
          (session el-chronos--session-id))
      (el-chronos-test--insert-command hour "cmd" 5.0)
      (el-chronos-test--insert-slow-event hour 900.0 "block")
      (el-chronos-test--insert-function hour "fn" nil "pkg" 1.0 1.0 1)
      (el-chronos-test--insert-usage hour 'command "cmd" 1 5.0)
      (el-chronos-test--insert-stack hour "[\"fn\"]" 1)
      ;; 新 4 表：写入层由 T2 / T3 负责，这里直接 INSERT 造数据
      (el-chronos-test--exec "INSERT INTO hourly_gc (hour_ts, session_id, gc_count,\
 gc_ms, heap_bytes) VALUES (?, ?, ?, ?, ?)"
                             (list hour session 3 1.5 4096))
      (el-chronos-test--exec "INSERT INTO hourly_health (hour_ts, session_id, key, value)\
 VALUES (?, ?, ?, ?)"
                             (list hour session "dropped-commands" 2.0))
      (el-chronos-test--exec "INSERT INTO startup_phases (session_id, phase, ms)\
 VALUES (?, ?, ?)"
                             (list session "init" 12.5))
      (el-chronos-test--exec "INSERT INTO session_meta (session_id, key, value)\
 VALUES (?, ?, ?)"
                             (list session "git-head" "deadbeef"))
      ;; 让 `--ensure-session' 一定算出非 nil 的 startup_ms（两个 init 时刻差 2 小时），
      ;; 才可能验证 purge 补建后把它置回了 NULL；否则该断言恒真、锁不住行为。
      (let ((before-init-time (time-subtract (current-time) 7200))
            (after-init-time (current-time)))
        (let ((result (el-chronos-purge)))
          (should (= 10 (length result)))
          (should (equal '("commands" "slow_events" "startup_phases" "session_meta"
                           "hourly_functions" "hourly_usage" "hourly_stacks"
                           "hourly_gc" "hourly_health" "sessions")
                         (mapcar #'car result)))))
      (dolist (table (remove "sessions" el-chronos-store-test--all-tables))
        (should (= 0 (el-chronos-test--count table))))
      ;; 会话行被补建，且写入路径仍然可用
      (should (= 1 (el-chronos-test--count "sessions")))
      (should (= 1 (el-chronos-test--scalar
                    "SELECT count(*) FROM sessions WHERE id = ?"
                    (list el-chronos--session-id))))
      ;; 补建行的启动耗时置 NULL（`started_at` 说「刚启动」，`startup_ms` 不能是几小时前）
      (should (null (el-chronos-test--scalar
                     "SELECT startup_ms FROM sessions WHERE id = ?"
                     (list el-chronos--session-id))))
      (el-chronos-store-record-command (list :name "after-purge" :duration-ms 1.0))
      (el-chronos-store-flush)
      (should (= 1 (el-chronos-test--count "commands"))))))

(ert-deftest el-chronos-store-test-purge-empties-nine-tables ()
  "`purge' 无参时 10 张表的 1–2 行数据全部清空，只留下重建的当前会话行。
fixture 把 `user-emacs-directory' 绑到临时目录（无 `.git'、无 init 文件），
保证变更标记即便写入也不会污染 `session_meta'，从而让「必为 0」的断言站得住。"
  (el-chronos-test-with-tmp-dir dir
    (let ((user-emacs-directory (file-name-as-directory dir)))
      (el-chronos-test-with-db
        (let ((hour (el-chronos-test--hour-ts))
              (session el-chronos--session-id))
          (el-chronos-test--insert-command hour "cmd-a" 5.0)
          (el-chronos-test--insert-command hour "cmd-b" 7.0)
          (el-chronos-test--insert-slow-event hour 900.0 "block")
          (el-chronos-test--insert-slow-event hour 400.0 "command" "cmd-a")
          (el-chronos-test--insert-function hour "fn" nil "pkg" 1.0 1.0 1)
          (el-chronos-test--insert-usage hour 'command "cmd-a" 2 9.0)
          (el-chronos-test--insert-stack hour "[\"fn\"]" 1)
          ;; 新 4 表：手工 INSERT，不依赖 T2 / T3 的写入路径
          (el-chronos-test--exec "INSERT INTO hourly_gc (hour_ts, session_id, gc_count,\
 gc_ms, heap_bytes) VALUES (?, ?, ?, ?, ?)"
                                 (list hour session 3 1.5 4096))
          (el-chronos-test--exec "INSERT INTO hourly_health (hour_ts, session_id, key, value)\
 VALUES (?, ?, ?, ?)"
                                 (list hour session "dropped-commands" 2.0))
          (el-chronos-test--exec "INSERT INTO startup_phases (session_id, phase, ms)\
 VALUES (?, ?, ?)"
                                 (list session "init" 12.5))
          (el-chronos-test--exec "INSERT INTO session_meta (session_id, key, value)\
 VALUES (?, ?, ?)"
                                 (list session "git-head" "deadbeef"))
          ;; 10 表都非空（`sessions' 由 open 建好）
          (dolist (table el-chronos-store-test--all-tables)
            (should (>= (el-chronos-test--count table) 1)))
          (el-chronos-purge)
          ;; 9 张数据表清空
          (dolist (table (remove "sessions" el-chronos-store-test--all-tables))
            (should (= 0 (el-chronos-test--count table))))
          ;; 含隐私表 `session_meta'：干净 fixture 下必须一行不剩
          (should (= 0 (el-chronos-test--count "session_meta")))
          ;; `sessions' 只留下重建的当前会话行
          (should (>= (el-chronos-test--count "sessions") 1))
          (should (= 1 (el-chronos-test--scalar
                        "SELECT count(*) FROM sessions WHERE id = ?"
                        (list el-chronos--session-id)))))))))

(ert-deftest el-chronos-store-test-purge-with-before-leaves-no-orphans ()
  "带 BEFORE 的 purge 必须连「无时间列、按会话删」的 `startup_phases' / `session_meta'
一起删干净：旧会话的会话级行全为 0，新会话的数据一行不少。
若把这两张表挪到 `sessions' 之后删，子查询恒为空 → 行留下来且不报错（孤儿），本用例即红。"
  (el-chronos-test-with-tmp-dir dir
    (let ((user-emacs-directory (file-name-as-directory dir)))
      (el-chronos-test-with-db
        (let* ((now (el-chronos-test--now-ms))
               (cutoff (- now (* 10 86400000)))          ; 界：10 天前
               (old-start (- now (* 20 86400000)))       ; 旧会话：20 天前启动
               (old-hour (- (el-chronos-test--hour-ts) (* 264 3600000))) ; 11 天前那个整点
               (cur-hour (el-chronos-test--hour-ts))
               (old-id (el-chronos-test--insert-session old-start))
               (new-id el-chronos--session-id))
          ;; 旧会话：明细 + 4 张新表各 1 行
          (let ((el-chronos--session-id old-id))
            (el-chronos-test--insert-command old-start "old-cmd" 5.0)
            (el-chronos-test--insert-slow-event old-start 800.0 "block")
            (el-chronos-test--exec "INSERT INTO startup_phases (session_id, phase, ms)\
 VALUES (?, ?, ?)"
                                   (list old-id "init" 10.0))
            (el-chronos-test--exec "INSERT INTO session_meta (session_id, key, value)\
 VALUES (?, ?, ?)"
                                   (list old-id "git-head" "old-sha"))
            (el-chronos-test--exec "INSERT INTO hourly_gc (hour_ts, session_id, gc_count,\
 gc_ms, heap_bytes) VALUES (?, ?, ?, ?, ?)"
                                   (list old-hour old-id 1 1.0 1024))
            (el-chronos-test--exec "INSERT INTO hourly_health (hour_ts, session_id, key,\
 value) VALUES (?, ?, ?, ?)"
                                   (list old-hour old-id "dropped-commands" 1.0)))
          ;; 新（当前）会话：明细 + 4 张新表各 1 行
          (el-chronos-test--insert-command now "new-cmd" 5.0)
          (el-chronos-test--insert-slow-event now 700.0 "block")
          (el-chronos-test--exec "INSERT INTO startup_phases (session_id, phase, ms)\
 VALUES (?, ?, ?)"
                                 (list new-id "init" 12.0))
          (el-chronos-test--exec "INSERT INTO session_meta (session_id, key, value)\
 VALUES (?, ?, ?)"
                                 (list new-id "git-head" "new-sha"))
          (el-chronos-test--exec "INSERT INTO hourly_gc (hour_ts, session_id, gc_count,\
 gc_ms, heap_bytes) VALUES (?, ?, ?, ?, ?)"
                                 (list cur-hour new-id 2 2.0 2048))
          (el-chronos-test--exec "INSERT INTO hourly_health (hour_ts, session_id, key,\
 value) VALUES (?, ?, ?, ?)"
                                 (list cur-hour new-id "flush-failures" 3.0))
          (el-chronos-purge cutoff)
          ;; 旧会话整条消失：会话行、明细、会话级数据、按时间删的聚合
          (should (= 0 (el-chronos-test--scalar
                        "SELECT count(*) FROM sessions WHERE id = ?" (list old-id))))
          (should (= 0 (el-chronos-test--scalar
                        "SELECT count(*) FROM commands WHERE session_id = ?" (list old-id))))
          (should (= 0 (el-chronos-test--scalar
                        "SELECT count(*) FROM slow_events WHERE ts = ?" (list old-start))))
          ;; ★ 这两条是「子查询恒空」那个坑的哨兵：挪动顺序就红
          (should (= 0 (el-chronos-test--scalar
                        "SELECT count(*) FROM startup_phases WHERE session_id = ?"
                        (list old-id))))
          (should (= 0 (el-chronos-test--scalar
                        "SELECT count(*) FROM session_meta WHERE session_id = ?"
                        (list old-id))))
          (should (= 0 (el-chronos-test--scalar
                        "SELECT count(*) FROM hourly_gc WHERE hour_ts = ?"
                        (list old-hour))))
          (should (= 0 (el-chronos-test--scalar
                        "SELECT count(*) FROM hourly_health WHERE hour_ts = ?"
                        (list old-hour))))
          ;; 新会话数据完整
          (should (= 1 (el-chronos-test--scalar
                        "SELECT count(*) FROM sessions WHERE id = ?" (list new-id))))
          (should (= 1 (el-chronos-test--scalar
                        "SELECT count(*) FROM commands WHERE session_id = ?" (list new-id))))
          (should (= 1 (el-chronos-test--scalar
                        "SELECT count(*) FROM slow_events WHERE ts = ?" (list now))))
          (should (= 1 (el-chronos-test--scalar
                        "SELECT count(*) FROM startup_phases WHERE session_id = ?"
                        (list new-id))))
          (should (= 1 (el-chronos-test--scalar
                        "SELECT count(*) FROM session_meta WHERE session_id = ?"
                        (list new-id))))
          (should (= 1 (el-chronos-test--scalar
                        "SELECT count(*) FROM hourly_gc WHERE hour_ts = ?" (list cur-hour))))
          (should (= 1 (el-chronos-test--scalar
                        "SELECT count(*) FROM hourly_health WHERE hour_ts = ?"
                        (list cur-hour)))))))))

(ert-deftest el-chronos-store-test-prune-does-not-touch-new-tables ()
  "自动 retention（`--prune'）只删 `commands' / `slow_events'：
4 张新表即使数据早已超期也一行不动（聚合与元数据长期保留，只由 purge 清理）。"
  (el-chronos-store-test--with-hermetic-db
    (let* ((old 1000)                    ; 远早于 30 天保留阈值
           (old-id (el-chronos-test--insert-session old)))
      (el-chronos-test--insert-command old "ancient" 5.0)
      (el-chronos-test--insert-slow-event old 900.0 "block")
      (el-chronos-test--exec "INSERT INTO hourly_gc (hour_ts, session_id, gc_count,\
 gc_ms, heap_bytes) VALUES (?, ?, ?, ?, ?)"
                             (list old old-id 4 3.0 8192))
      (el-chronos-test--exec "INSERT INTO hourly_health (hour_ts, session_id, key, value)\
 VALUES (?, ?, ?, ?)"
                             (list old old-id "sampling-misses" 5.0))
      (el-chronos-test--exec "INSERT INTO startup_phases (session_id, phase, ms)\
 VALUES (?, ?, ?)"
                             (list old-id "init" 9.0))
      (el-chronos-test--exec "INSERT INTO session_meta (session_id, key, value)\
 VALUES (?, ?, ?)"
                             (list old-id "config-sig" "abc"))
      (should (el-chronos-store--prune))
      ;; 明细超期行被删
      (should (= 0 (el-chronos-test--scalar
                    "SELECT count(*) FROM commands WHERE name = 'ancient'")))
      (should (= 0 (el-chronos-test--scalar
                    "SELECT count(*) FROM slow_events WHERE ts = ?" (list old))))
      ;; 4 张新表一行不少（含超期的 hourly_gc / hourly_health）
      (should (= 1 (el-chronos-test--count "hourly_gc")))
      (should (= 1 (el-chronos-test--count "hourly_health")))
      (should (= 1 (el-chronos-test--count "startup_phases")))
      (should (= 1 (el-chronos-test--count "session_meta"))))))

(ert-deftest el-chronos-store-test-purge-keeps-session-with-live-commands ()
  "purge 不得因为「会话很久前启动、今天还在跑」而整批失败。
`commands' 按 `ts' 删、`sessions' 按 `started_at' 删，口径不同：会话 A 的
`started_at' 已过期但名下还有 `ts >= BEFORE' 的命令，直接删它会撞
`commands.session_id' 外键（`foreign_keys=ON'）→ 整个事务 ROLLBACK、一条都没删。
本用例锁住修法：过期但仍有存活子行的会话**保留**（其过期明细照删），
其余过期会话正常删除。purge 是隐私清理手段，「以为删了其实没删」比「少删」严重。"
  (el-chronos-test-with-tmp-dir dir
    (let ((user-emacs-directory (file-name-as-directory dir)))
      (el-chronos-test-with-db
        (let* ((now (el-chronos-test--now-ms))
               (cutoff (- now (* 30 86400000)))         ; 界：30 天前
               (old (- now (* 40 86400000)))            ; 40 天前
               (cur-hour (el-chronos-test--hour-ts))
               (old-hour (- cur-hour (* 960 3600000)))  ; 40 天前的整点
               ;; 数据全部在 open 之后插：open 时的自动 `--prune' 会把 40 天前的
               ;; commands 直接删掉，先插后开库会让本用例的前提消失。
               (a-id (el-chronos-test--insert-session old))
               (b-id (el-chronos-test--insert-session old)))
          ;; 会话 A：一行过期命令 + 一行今天的命令（存活子行 → 必须保留会话）
          (let ((el-chronos--session-id a-id))
            (el-chronos-test--insert-command old "a-old" 5.0)
            (el-chronos-test--insert-command now "a-live" 5.0)
            (el-chronos-test--exec "INSERT INTO startup_phases (session_id, phase, ms)\
 VALUES (?, ?, ?)" (list a-id "init" 10.0))
            (el-chronos-test--exec "INSERT INTO session_meta (session_id, key, value)\
 VALUES (?, ?, ?)" (list a-id "git-head" "a-sha"))
            (el-chronos-test--exec "INSERT INTO hourly_gc (hour_ts, session_id, gc_count,\
 gc_ms, heap_bytes) VALUES (?, ?, ?, ?, ?)"
                                   (list cur-hour a-id 1 1.0 1024))
            (el-chronos-test--exec "INSERT INTO hourly_health (hour_ts, session_id, key,\
 value) VALUES (?, ?, ?, ?)"
                                   (list cur-hour a-id "dropped-commands" 1.0)))
          ;; 会话 B：全部数据都已过期（无存活子行 → 应连会话行一起删）
          (let ((el-chronos--session-id b-id))
            (el-chronos-test--insert-command old "b-old" 5.0)
            (el-chronos-test--insert-command (1+ old) "b-old-2" 5.0)
            (el-chronos-test--exec "INSERT INTO startup_phases (session_id, phase, ms)\
 VALUES (?, ?, ?)" (list b-id "init" 11.0))
            (el-chronos-test--exec "INSERT INTO session_meta (session_id, key, value)\
 VALUES (?, ?, ?)" (list b-id "git-head" "b-sha"))
            (el-chronos-test--exec "INSERT INTO hourly_gc (hour_ts, session_id, gc_count,\
 gc_ms, heap_bytes) VALUES (?, ?, ?, ?, ?)"
                                   (list old-hour b-id 2 2.0 2048))
            (el-chronos-test--exec "INSERT INTO hourly_health (hour_ts, session_id, key,\
 value) VALUES (?, ?, ?, ?)"
                                   (list old-hour b-id "flush-failures" 2.0)))
          ;; ① 不报错、事务真的提交（外键失败时 purge 返回 nil）
          (let ((result (el-chronos-purge cutoff)))
            (should (= 10 (length result)))
            ;; 只删掉 B 这一行会话
            (should (= 1 (cdr (assoc "sessions" result)))))
          ;; ② 会话 A 保留；A 的过期命令被删，今天的命令保留
          (should (= 1 (el-chronos-test--scalar
                        "SELECT count(*) FROM sessions WHERE id = ?" (list a-id))))
          (should (= 0 (el-chronos-test--scalar
                        "SELECT count(*) FROM commands WHERE name = 'a-old'")))
          (should (= 1 (el-chronos-test--scalar
                        "SELECT count(*) FROM commands WHERE name = 'a-live'")))
          ;; ③ 会话 B 整条删净
          (should (= 0 (el-chronos-test--scalar
                        "SELECT count(*) FROM sessions WHERE id = ?" (list b-id))))
          (should (= 0 (el-chronos-test--scalar
                        "SELECT count(*) FROM commands WHERE session_id = ?" (list b-id))))
          (should (= 0 (el-chronos-test--scalar
                        "SELECT count(*) FROM startup_phases WHERE session_id = ?"
                        (list b-id))))
          (should (= 0 (el-chronos-test--scalar
                        "SELECT count(*) FROM session_meta WHERE session_id = ?"
                        (list b-id))))
          (should (= 0 (el-chronos-test--scalar
                        "SELECT count(*) FROM hourly_gc WHERE hour_ts = ?" (list old-hour))))
          (should (= 0 (el-chronos-test--scalar
                        "SELECT count(*) FROM hourly_health WHERE hour_ts = ?"
                        (list old-hour))))
          ;; ④ 保留会话 A 的 4 张新表行仍在（扩表与新判据协同；
          ;;    会话级两张表与 sessions 共用同一判据，故 A 不会被清成半截）
          (should (= 1 (el-chronos-test--scalar
                        "SELECT count(*) FROM startup_phases WHERE session_id = ?"
                        (list a-id))))
          (should (= 1 (el-chronos-test--scalar
                        "SELECT count(*) FROM session_meta WHERE session_id = ?"
                        (list a-id))))
          (should (= 1 (el-chronos-test--scalar
                        "SELECT count(*) FROM hourly_gc WHERE hour_ts = ?"
                        (list cur-hour))))
          (should (= 1 (el-chronos-test--scalar
                        "SELECT count(*) FROM hourly_health WHERE hour_ts = ?"
                        (list cur-hour)))))))))

;;; 新聚合写入（GC / 自监控 / 启动阶段 / 会话元数据）

(ert-deftest el-chronos-store-test-record-gc-accumulates-and-heap-wins-last-non-nil ()
  "同键两次 record：`gc_count' / `gc_ms' 累加，`heap_bytes' 保持最后一次**非 nil** 值。
第二次传 nil 模拟「本窗口没采堆」（稀疏采样，每 N 个窗口才有一次）：它不得把首值抹掉。
本用例锁住 `--sql-upsert-gc' 里的 COALESCE —— 改成 `heap_bytes = excluded.heap_bytes'
（普通覆盖）后必红。"
  (el-chronos-test-with-db
    (let ((hour (el-chronos-test--hour-ts)))
      (el-chronos-store-record-gc hour 3 1.5 1000)
      (el-chronos-store-record-gc hour 2 0.5 nil)
      (should (el-chronos-store--pending-p))
      (should (el-chronos-store-flush))
      (should (= 1 (el-chronos-test--count "hourly_gc")))
      (let ((row (car (sqlite-select el-chronos-store--db
                                     "SELECT gc_count, gc_ms, heap_bytes FROM hourly_gc"
                                     nil))))
        (should (= 5 (nth 0 row)))
        (should (= 2.0 (nth 1 row)))
        (should (= 1000 (nth 2 row))))
      ;; 第二次 flush：本批全是 nil 段，仍不得抹掉已落库的值（跨批次的同一条保证）
      (el-chronos-store-record-gc hour 1 0.5 nil)
      (el-chronos-store-flush)
      (should (= 6 (el-chronos-test--scalar "SELECT gc_count FROM hourly_gc")))
      (should (= 1000 (el-chronos-test--scalar "SELECT heap_bytes FROM hourly_gc"))))))

(ert-deftest el-chronos-store-test-record-health-accumulates ()
  "同 (hour, session, key) 两次 record → 一行、值累加；不同 key 各成一行。"
  (el-chronos-test-with-db
    (let ((hour (el-chronos-test--hour-ts)))
      (el-chronos-store-record-health hour "dropped-commands" 2)
      (el-chronos-store-record-health hour "dropped-commands" 3)
      (el-chronos-store-record-health hour "flush-count" 1)
      (el-chronos-store-flush)
      (should (= 2 (el-chronos-test--count "hourly_health")))
      (should (= 5 (el-chronos-test--scalar
                    "SELECT value FROM hourly_health WHERE key = 'dropped-commands'")))
      (should (= 1 (el-chronos-test--scalar
                    "SELECT value FROM hourly_health WHERE key = 'flush-count'"))))))

(ert-deftest el-chronos-store-test-record-startup-overwrites ()
  "同 (session, phase) 两次 record → 一行、后者胜（覆盖语义）。
阶段名含 \"|\" 时也不串键：键只在**第一个** \"|\" 处切分，右段整段是阶段名。"
  (el-chronos-test-with-db
    (let ((session el-chronos--session-id))
      (el-chronos-store-record-startup-phase session "after-init" 12.5)
      (el-chronos-store-record-startup-phase session "after-init" 20.0)
      (el-chronos-store-record-startup-phase session "load:foo|bar" 3.0)
      (el-chronos-store-flush)
      (should (= 2 (el-chronos-test--count "startup_phases")))
      (should (= 20.0 (el-chronos-test--scalar
                       "SELECT ms FROM startup_phases WHERE phase = 'after-init'")))
      (should (= 1 (el-chronos-test--scalar
                    "SELECT count(*) FROM startup_phases WHERE phase = 'load:foo|bar'"))))))

(ert-deftest el-chronos-store-test-record-session-meta-writes-immediately-and-skips-nil ()
  "`record-session-meta' **不跑 flush 就能查到**（直接写库，O10）；
同键覆盖；value 为 nil 时不写行（不写 NULL 值行）；未打开数据库时静默返回 nil。"
  (el-chronos-store-test--with-hermetic-db
    (let ((session el-chronos--session-id))
      (should (= 0 (el-chronos-test--count "session_meta")))
      (should (el-chronos-store-record-session-meta session "git-head" "abc123"))
      ;; 关键：没有调用 `el-chronos-store-flush'
      (should (= 1 (el-chronos-test--count "session_meta")))
      (should (equal "abc123" (el-chronos-test--scalar
                               "SELECT value FROM session_meta WHERE key = 'git-head'")))
      ;; 同键覆盖而不是新增行
      (el-chronos-store-record-session-meta session "git-head" "def456")
      (should (= 1 (el-chronos-test--count "session_meta")))
      (should (equal "def456" (el-chronos-test--scalar
                               "SELECT value FROM session_meta WHERE key = 'git-head'")))
      ;; 取不到值 → 不写行
      (should-not (el-chronos-store-record-session-meta session "config-sig" nil))
      (should (= 0 (el-chronos-test--scalar
                    "SELECT count(*) FROM session_meta WHERE key = 'config-sig'")))
      ;; 未打开数据库：直接返回 nil，不报错（I6）
      (let ((el-chronos-store--db nil))
        (should-not (el-chronos-store-record-session-meta session "git-head" "x")))
      (should (equal "def456" (el-chronos-test--scalar
                               "SELECT value FROM session_meta WHERE key = 'git-head'"))))))

(ert-deftest el-chronos-store-test-flush-runs-when-only-new-aggregates-pending ()
  "只有新聚合待写时 flush 也必须执行 —— 分别覆盖 gc / health / startup 三个容器。
锁住的门禁漏洞：flush 第一道门是 `(and db (--pending-p))'，`--pending-p' 若漏掉任一
新 hash，「只有该类数据待写」时 flush 直接早退，数据永不落库且无任何报错。
每轮开头的空容器断言保证这一轮确实只剩单个容器待写，反向验证才有意义。"
  (el-chronos-test-with-db
    (let ((hour (el-chronos-test--hour-ts))
          (session el-chronos--session-id))
      (cl-flet ((only-new-aggregates-p ()
                  (and (null el-chronos-store--buffer)
                       (null el-chronos-store--slow-events)
                       (= 0 (hash-table-count el-chronos-store--usage))
                       (= 0 (hash-table-count el-chronos-store--functions))
                       (= 0 (hash-table-count el-chronos-store--stacks)))))
        ;; ① 只有 hourly_health
        (el-chronos-store-record-health hour "flush-count" 1)
        (should (only-new-aggregates-p))
        (should (= 1 (hash-table-count el-chronos-store--health)))
        (should (el-chronos-store--pending-p))
        (should (el-chronos-store-flush))
        (should (= 1 (el-chronos-test--count "hourly_health")))
        ;; ② 只有 hourly_gc
        (el-chronos-store-record-gc hour 1 1.0 nil)
        (should (only-new-aggregates-p))
        (should (= 1 (hash-table-count el-chronos-store--gc)))
        (should (el-chronos-store--pending-p))
        (should (el-chronos-store-flush))
        (should (= 1 (el-chronos-test--count "hourly_gc")))
        ;; ③ 只有 startup_phases
        (el-chronos-store-record-startup-phase session "mode-start" 5.0)
        (should (only-new-aggregates-p))
        (should (= 1 (hash-table-count el-chronos-store--startup)))
        (should (el-chronos-store--pending-p))
        (should (el-chronos-store-flush))
        (should (= 1 (el-chronos-test--count "startup_phases")))))))

(ert-deftest el-chronos-store-test-flush-clears-new-aggregates-after-commit ()
  "flush 成功后三个新 hash 全部清空（与既有聚合同批）；close 后同样不残留（I5）。
若只在成功路径漏清某一个 hash，同一批数据会在下一次 flush 被重复累加（计数翻倍）。"
  (el-chronos-test-with-db
    (let ((hour (el-chronos-test--hour-ts))
          (session el-chronos--session-id))
      (el-chronos-store-record-gc hour 1 1.0 4096)
      (el-chronos-store-record-health hour "flush-count" 1)
      (el-chronos-store-record-startup-phase session "startup" 5.0)
      (should (el-chronos-store-flush))
      (should (= 0 (hash-table-count el-chronos-store--gc)))
      (should (= 0 (hash-table-count el-chronos-store--health)))
      (should (= 0 (hash-table-count el-chronos-store--startup)))
      (should-not (el-chronos-store--pending-p))
      ;; close 前再塞一批（close 会先 flush），close 之后三个 hash 仍必须为空
      (el-chronos-store-record-gc hour 2 2.0 nil)
      (el-chronos-store-record-health hour "flush-failures" 1)
      (el-chronos-store-record-startup-phase session "after-init" 1.0)
      (el-chronos-store-close)
      (should (= 0 (hash-table-count el-chronos-store--gc)))
      (should (= 0 (hash-table-count el-chronos-store--health)))
      (should (= 0 (hash-table-count el-chronos-store--startup)))
      (should-not (el-chronos-store--pending-p)))))

;;; 自监控计数（T5）

(ert-deftest el-chronos-store-test-flush-counter-not-cleared-by-clear-aggregates ()
  "直接调 `--clear-aggregates' 后 5 个自监控计数器**一个也不变**。
这是「独立 defvar」的反向验证正面形态：一旦把它们塞进被清空的容器
（`--usage' / `--health' ... 或直接挂 `--buffer' / `--slow-events'），本用例必红 ——
那正是「flush 失败把失败计数一并抹掉」的退化路径，也是设计 §6「已知悖论」的核心陷阱。"
  (el-chronos-test-with-db
    (setq el-chronos-store--dropped-commands 3
          el-chronos-store--dropped-events 2
          el-chronos-store--flush-failures 1
          el-chronos-store--flush-count 4
          el-chronos-store--flush-ms-total 12.5)
    (el-chronos-store--clear-aggregates)
    (should (= 3 el-chronos-store--dropped-commands))
    (should (= 2 el-chronos-store--dropped-events))
    (should (= 1 el-chronos-store--flush-failures))
    (should (= 4 el-chronos-store--flush-count))
    (should (= 12.5 el-chronos-store--flush-ms-total))
    ;; 对照断言：本批数据容器确实被清空了（证明函数真的跑过，不是被 cl-letf 掉）
    (should (= 0 (hash-table-count el-chronos-store--health)))
    (should-not el-chronos-store--slow-events)))

(ert-deftest el-chronos-store-test-dropped-commands-counted-by-difference ()
  "命令缓冲超 `--max-buffer-items' 时 `--dropped-commands' 等于溢出条数。
用 `cl-letf' 把上限压到 2（真实上限 50000，撑满它要 5 万条且毫无额外信息），
再推 5 条 → 丢 3 条。差值口径（截断前长度 − 上限）在当前「每次推一条」的实现下
恒为 1，本用例同时验证**累计**正确（3 次截断 = 3）。"
  (el-chronos-test-with-db
    (cl-letf (((symbol-value 'el-chronos-store--max-buffer-items) 2))
      (dotimes (i 5)
        (el-chronos-store-record-command
         (list :name (format "c%d" i) :duration-ms 1.0)))
      (should (= 3 el-chronos-store--dropped-commands))
      (should (= 2 (length el-chronos-store--buffer)))
      ;; 慢事件计数器不受影响（按 SLOT 分流）
      (should (= 0 el-chronos-store--dropped-events)))))

(ert-deftest el-chronos-store-test-dropped-events-counted-separately ()
  "慢事件缓冲截断只累加 `--dropped-events'，`--dropped-commands' 不变。
锁住 `--push-event' 里的 SLOT 分流：同一函数服务两个缓冲，不分流就会把慢事件
记进命令计数（「命令丢了多少」从此不可信）。"
  (el-chronos-test-with-db
    (cl-letf (((symbol-value 'el-chronos-store--max-buffer-items) 1))
      (dotimes (_ 4)
        (el-chronos-store-record-slow-event (list :duration-ms 900.0 :kind "block")))
      (should (= 3 el-chronos-store--dropped-events))
      (should (= 0 el-chronos-store--dropped-commands))
      (should (= 1 (length el-chronos-store--slow-events))))))

(ert-deftest el-chronos-store-test-flush-reports-counters-and-resets-after-commit ()
  "flush 在事务内把计数器快照写进 `hourly_health'，COMMIT 后把已上报部分减掉；
`flush-count' / `flush-ms' **滞后一个周期**上报（本次 flush 只进下一次快照）。"
  (el-chronos-test-with-db
    (let ((hour (el-chronos-test--hour-ts)))
      (setq el-chronos-store--dropped-commands 3
            el-chronos-store--dropped-events 2
            el-chronos-store--flush-failures 1)
      (should (el-chronos-store-flush))
      ;; 三个「有数据没进库」性质的计数已上报
      (should (= 3 (el-chronos-test--scalar
                    "SELECT value FROM hourly_health WHERE key = 'dropped-commands'")))
      (should (= 2 (el-chronos-test--scalar
                    "SELECT value FROM hourly_health WHERE key = 'dropped-events'")))
      (should (= 1 (el-chronos-test--scalar
                    "SELECT value FROM hourly_health WHERE key = 'flush-failures'")))
      ;; 上报后归零（减去已上报部分）
      (should (= 0 el-chronos-store--dropped-commands))
      (should (= 0 el-chronos-store--dropped-events))
      (should (= 0 el-chronos-store--flush-failures))
      ;; 本次 flush 的 count / ms 在快照之后才写入计数器 → 库里**还没有**它们
      (should (= 1 el-chronos-store--flush-count))
      (should (> el-chronos-store--flush-ms-total 0.0))
      (should (= 0 (el-chronos-test--scalar
                    "SELECT count(*) FROM hourly_health WHERE key = 'flush-count'")))
      ;; 第二次 flush（用一条待写数据驱动）→ 上一轮的 count / ms 被带上
      (el-chronos-store-record-health hour "sample-misses" 1)
      (should (el-chronos-store-flush))
      (should (= 1 (el-chronos-test--scalar
                    "SELECT value FROM hourly_health WHERE key = 'flush-count'")))
      (should (> (el-chronos-test--scalar
                  "SELECT value FROM hourly_health WHERE key = 'flush-ms'")
                 0.0))
      ;; 上报后仍是 1（减去已上报的 1，再加本次的 1 —— 不是归零，也不是累加到 2）
      (should (= 1 el-chronos-store--flush-count)))))

(ert-deftest el-chronos-store-test-flush-failure-keeps-counters ()
  "flush 中途报错 → 计数器**一分不减**、`--flush-failures' +1、库中无 health 行；
下一次成功 flush 才把失败次数与丢弃量一起补写（eventual 语义）。"
  (el-chronos-test-with-db
    (let ((original (symbol-function 'sqlite-execute)))
      (setq el-chronos-store--dropped-commands 3
            el-chronos-store--dropped-events 2)
      (cl-letf (((symbol-function 'sqlite-execute)
                 (lambda (db sql &rest args)
                   (if (string-match-p "COMMIT" sql)
                       (error "mock commit failure")
                     (apply original db sql args)))))
        ;; 失败只降级为告警，不抛错
        (should-not (el-chronos-store-flush))))
    (should (= 1 el-chronos-store--flush-failures))
    (should (= 3 el-chronos-store--dropped-commands))
    (should (= 2 el-chronos-store--dropped-events))
    (should (= 0 el-chronos-store--flush-count))
    (should (= 0.0 el-chronos-store--flush-ms-total))
    ;; 写库本身就是失败的那件事 → 库里一行 health 都没有
    (should (= 0 (el-chronos-test--count "hourly_health")))
    ;; 下一次成功 flush 补写（`--flush-failures' 已在 `--pending-p' 里，故不会早退）
    (should (el-chronos-store-flush))
    (should (= 3 (el-chronos-test--scalar
                  "SELECT value FROM hourly_health WHERE key = 'dropped-commands'")))
    (should (= 1 (el-chronos-test--scalar
                  "SELECT value FROM hourly_health WHERE key = 'flush-failures'")))
    (should (= 0 el-chronos-store--flush-failures))))

(ert-deftest el-chronos-store-test-close-clears-counters ()
  "`store-close' 清空 5 个自监控计数器，且**不依赖** `--clear-aggregates'（两者分离）。
做两件事让「close 清零」不与「flush 上报后归零」混淆：① 关句柄使 close 首行的 flush
早退（否则计数会被正常上报）；② 把 `--clear-aggregates' 整个 cl-letf 成空操作。"
  (el-chronos-test-with-db
    (setq el-chronos-store--dropped-commands 3
          el-chronos-store--dropped-events 2
          el-chronos-store--flush-failures 1
          el-chronos-store--flush-count 4
          el-chronos-store--flush-ms-total 12.5)
    (cl-letf (((symbol-function 'el-chronos-store--clear-aggregates)
               (lambda (&rest _args) nil))
              ;; 句柄置 nil → close 首行 `(ignore-errors (flush))' 因 `--pending-p' 门
              ;; 的 db 判定直接早退，计数器不被上报
              ((symbol-value 'el-chronos-store--db) nil))
      (el-chronos-store-close))
    (should (= 0 el-chronos-store--dropped-commands))
    (should (= 0 el-chronos-store--dropped-events))
    (should (= 0 el-chronos-store--flush-failures))
    (should (= 0 el-chronos-store--flush-count))
    (should (= 0.0 el-chronos-store--flush-ms-total))))

(ert-deftest el-chronos-store-test-pending-p-ignores-flush-count ()
  "只有 `--flush-count' / `--flush-ms-total' 非零时 `--pending-p' 必须为 nil。
反向验证（L3 第②项）：把这两个纳入 `--pending-p' → 本用例必红。
为什么必须排除：它们每次成功 flush 之后都非零且单调增长，纳入后 `--pending-p' 恒真 →
flush timer 每 5 秒空转一次事务，且 `flush-count' 被自己的上报行为无限推高（永不归零）。
本用例用**真实**的连续两次 flush 构造场景，而不是手工 setq（那样测不出真实路径）。"
  (el-chronos-test-with-db
    (let ((hour (el-chronos-test--hour-ts)))
      (el-chronos-store-record-health hour "sample-misses" 1)
      (should (el-chronos-store-flush))
      (el-chronos-store-record-health hour "sample-misses" 1)
      (should (el-chronos-store-flush))
      ;; 此刻：所有数据容器空，只有 flush-count / flush-ms-total 非零
      (should (> el-chronos-store--flush-count 0))
      (should (> el-chronos-store--flush-ms-total 0.0))
      (should (equal 0 (hash-table-count el-chronos-store--health)))
      (should-not el-chronos-store--buffer)
      (should-not el-chronos-store--slow-events)
      (should (= 0 el-chronos-store--dropped-commands))
      (should (= 0 el-chronos-store--dropped-events))
      (should (= 0 el-chronos-store--flush-failures))
      (should-not (el-chronos-store--pending-p)))))

;;; startup_ms 补写与孤儿会话守卫（T2b）

(ert-deftest el-chronos-store-test-note-startup-ms-sets-pending-without-io ()
  "`note-startup-ms' 只置 pending，**一次 sqlite 调用都不发**（锁住「启动期零 IO」）。
db 或 session-id 为 nil 时忽略（登记了也无处可写）；重复调用是覆盖而非累加。"
  (el-chronos-test-with-db
    (let ((calls 0)
          (el-chronos-store--pending-startup-ms nil))
      (cl-letf (((symbol-function 'sqlite-execute)
                 (lambda (&rest _) (cl-incf calls) nil)))
        (el-chronos-store-note-startup-ms 123.0))
      (should (= 0 calls))
      (should (= 123.0 el-chronos-store--pending-startup-ms))
      ;; 未打开数据库：忽略，不报错
      (let ((el-chronos-store--db nil))
        (el-chronos-store-note-startup-ms 456.0))
      (should (= 123.0 el-chronos-store--pending-startup-ms))
      ;; 会话缺失：忽略（store-close 会保留 session-id 但把 db 置 nil，两处都要判）
      (let ((el-chronos--session-id nil))
        (el-chronos-store-note-startup-ms 789.0))
      (should (= 123.0 el-chronos-store--pending-startup-ms))
      ;; 覆盖式非累加：第二次调用替换而不是相加
      (el-chronos-store-note-startup-ms 200.0)
      (should (= 200.0 el-chronos-store--pending-startup-ms)))))

(ert-deftest el-chronos-store-test-flush-writes-pending-startup-ms ()
  "库里 `startup_ms' 为 NULL → note → flush → 补写成非 NULL 且值正确；pending 被清。"
  (el-chronos-test-with-db
    (let ((session el-chronos--session-id))
      ;; open 时 `--ensure-session' 可能已写入本进程的启动耗时，先显式置 NULL 造出
      ;; 「mode 在 after-init 之前启用」那种未知状态
      (el-chronos-test--exec "UPDATE sessions SET startup_ms = NULL WHERE id = ?"
                             (list session))
      (should (null (el-chronos-test--scalar
                     "SELECT startup_ms FROM sessions WHERE id = ?" (list session))))
      (el-chronos-store-note-startup-ms 1234.5)
      (should (el-chronos-store-flush))
      (should (= 1234.5 (el-chronos-test--scalar
                         "SELECT startup_ms FROM sessions WHERE id = ?" (list session))))
      ;; COMMIT 成功之后才清 pending
      (should-not el-chronos-store--pending-startup-ms))))

(ert-deftest el-chronos-store-test-flush-does-not-overwrite-existing-startup-ms ()
  "会话行已有 `startup_ms'（如 `emacs-startup-hook' 启动的正常路径）：补写不得覆盖。
本用例锁住 `UPDATE ... AND startup_ms IS NULL' 的守卫 —— 去掉它必红。"
  (el-chronos-test-with-db
    (let ((session el-chronos--session-id))
      (el-chronos-test--exec "UPDATE sessions SET startup_ms = 500 WHERE id = ?"
                             (list session))
      (el-chronos-store-note-startup-ms 999)
      (should (el-chronos-store-flush))
      (should (= 500 (el-chronos-test--scalar
                      "SELECT startup_ms FROM sessions WHERE id = ?" (list session))))
      ;; 库里已有正确值 → UPDATE 影响 0 行也算「已消费」，重试没有意义，故清 pending
      (should-not el-chronos-store--pending-startup-ms))))

(ert-deftest el-chronos-store-test-flush-runs-when-only-pending-startup-ms ()
  "只有 pending 待补写时 flush 也必须执行 —— `--pending-p' 漏掉它 → 本用例必红。
锁住的门禁漏洞：空闲会话（启动后没敲命令、profiler 也没采到样本）里 pending 是唯一残留，
漏判时 flush 第一道门 `(and db (--pending-p))' 直接早退，补写永远不发生且无任何报错。"
  (el-chronos-test-with-db
    (let ((session el-chronos--session-id))
      (el-chronos-test--exec "UPDATE sessions SET startup_ms = NULL WHERE id = ?"
                             (list session))
      (el-chronos-store-note-startup-ms 42.0)
      ;; 其余容器全空：这一轮确实只剩 pending
      (should-not el-chronos-store--buffer)
      (should-not el-chronos-store--slow-events)
      (should (= 0 (hash-table-count el-chronos-store--usage)))
      (should (= 0 (hash-table-count el-chronos-store--functions)))
      (should (= 0 (hash-table-count el-chronos-store--stacks)))
      (should (= 0 (hash-table-count el-chronos-store--gc)))
      (should (= 0 (hash-table-count el-chronos-store--health)))
      (should (= 0 (hash-table-count el-chronos-store--startup)))
      (should (el-chronos-store--pending-p))
      (should (el-chronos-store-flush))
      (should (= 42.0 (el-chronos-test--scalar
                       "SELECT startup_ms FROM sessions WHERE id = ?" (list session)))))))

(ert-deftest el-chronos-store-test-close-clears-pending-startup-ms ()
  "`close' 后 pending 与孤儿告警标志都归零（I5 零残留）。
把 flush 打桩掉，才能区分「close 自己清的」与「close 首行 flush 顺带消费掉的」。"
  (el-chronos-test-with-db
    (setq el-chronos-store--aggregate-orphan-warned t)
    (el-chronos-store-note-startup-ms 77.0)
    (should (= 77.0 el-chronos-store--pending-startup-ms))
    (cl-letf (((symbol-function 'el-chronos-store-flush) #'ignore))
      (el-chronos-store-close))
    (should-not el-chronos-store--pending-startup-ms)
    (should-not el-chronos-store--aggregate-orphan-warned)))

(ert-deftest el-chronos-store-test-flush-skips-new-aggregates-when-session-unknown ()
  "`--session-id' 指向不存在的会话行时，flush 跳过三张新聚合表并每进程告警一次。
这三张表**无外键**（避免 purge 顺序耦合），DB 不会挡孤儿 session_id —— 一旦写进去，
purge 的 `session_id IN (SELECT id FROM sessions ...)' 子查询永远删不掉，静默残留。
既有表行为必须不变：`hourly_functions' 照写（本任务只补齐新表，不做统一重构）。"
  (el-chronos-test-with-db
    (let ((hour (el-chronos-test--hour-ts))
          (messages nil)
          (el-chronos-store--aggregate-orphan-warned nil)
          ;; 让 hourly_stacks 的既有告警走已告警分支，避免混进本用例的计数
          (el-chronos-store--stack-skip-warned t))
      (cl-letf (((symbol-function 'display-warning)
                 (lambda (_type msg &optional _level) (push msg messages))))
        ;; 记录时会话行还在（记录层不判存在性），随后删掉会话行模拟孤儿 session_id
        (el-chronos-store-record-gc hour 1 1.0 nil)
        (el-chronos-store-record-health hour "flush-count" 1)
        (el-chronos-store-record-startup-phase el-chronos--session-id "mode-start" 1.0)
        (el-chronos-store-record-function-samples hour "fn" nil "pkg" 1.0 2.0 1)
        (el-chronos-test--exec "DELETE FROM sessions WHERE id = ?"
                               (list el-chronos--session-id))
        (should (el-chronos-store-flush))
        (should (= 0 (el-chronos-test--count "hourly_gc")))
        (should (= 0 (el-chronos-test--count "hourly_health")))
        (should (= 0 (el-chronos-test--count "startup_phases")))
        ;; 既有表不受影响（既有行为一行不改）
        (should (= 1 (el-chronos-test--count "hourly_functions")))
        ;; 每进程只告警一次，且只一次
        (should (= 1 (length messages)))
        (should el-chronos-store--aggregate-orphan-warned))
      ;; 本批三个 hash 已随成功路径清空，不会在下一轮重复尝试
      (should (= 0 (hash-table-count el-chronos-store--gc)))
      (should (= 0 (hash-table-count el-chronos-store--health)))
      (should (= 0 (hash-table-count el-chronos-store--startup))))))

;;; 变更标记采集（T3：git-head / config-sig）

(defconst el-chronos-store-test--sha
  "1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9012"
  "用例里伪造的 40 位提交 sha。")

(defconst el-chronos-store-test--sha-other
  "0123456789abcdef0123456789abcdef01234567"
  "第二个伪造 sha，用于 packed-refs 的干扰行与 peeled 行。")

(defun el-chronos-store-test--write-file (path content)
  "在 PATH 处写入 CONTENT（自动创建父目录）。"
  (make-directory (file-name-directory path) t)
  (with-temp-file path (insert content)))

(ert-deftest el-chronos-store-test-session-meta-no-git-no-config-files-writes-nothing ()
  "临时目录里既无 `.git' 也无 init 文件 → `session_meta' 一行不写。
这是「取不到的键不写行」的底线：KV 表里不放 NULL 值行，否则「取不到」与「取了但为空」
在查询层不可区分。同时不得抛错、不得告警（I6）—— 两个采集函数都返回 nil 而非报错。"
  (el-chronos-store-test--with-hermetic-db
    (should (= 0 (el-chronos-test--count "session_meta")))
    ;; 独立验证两个采集函数（不经库）：空目录下都返回 nil
    (should-not (el-chronos-store--git-head))
    (should-not (el-chronos-store--config-sig))))

(ert-deftest el-chronos-store-test-session-meta-git-head-from-ref ()
  "松散引用分支：`.git/HEAD' 指向 `refs/heads/master'，sha 从该 ref 文件读出。"
  (el-chronos-store-test--with-hermetic-db
    (let ((root user-emacs-directory))
      (el-chronos-store-test--write-file
       (expand-file-name ".git/HEAD" root) "ref: refs/heads/master\n")
      (el-chronos-store-test--write-file
       (expand-file-name ".git/refs/heads/master" root)
       (concat el-chronos-store-test--sha "\n")))
    ;; 采集发生在 fixture 的 open 之后不行 —— 所以关库重开，让 `--ensure-session' 重跑
    (el-chronos-store-close)
    (setq el-chronos--session-id nil)
    (should (el-chronos-test--open-db el-chronos-db-path))
    (should (equal el-chronos-store-test--sha
                   (el-chronos-test--scalar
                    "SELECT value FROM session_meta WHERE key = 'git-head'\
 ORDER BY session_id DESC LIMIT 1")))
    ;; 没有 init 文件 → 只 1 行（config-sig 不写行）
    (should (= 1 (el-chronos-test--scalar
                  "SELECT count(*) FROM session_meta WHERE session_id = ?"
                  (list el-chronos--session-id))))))

(ert-deftest el-chronos-store-test-session-meta-git-head-detached ()
  "detached HEAD 分支：`.git/HEAD' 内容本身就是 sha，直接取用。"
  (el-chronos-store-test--with-hermetic-db
    (el-chronos-store-test--write-file
     (expand-file-name ".git/HEAD" user-emacs-directory)
     (concat el-chronos-store-test--sha "\n"))
    (el-chronos-store-close)
    (setq el-chronos--session-id nil)
    (should (el-chronos-test--open-db el-chronos-db-path))
    (should (equal el-chronos-store-test--sha
                   (el-chronos-test--scalar
                    "SELECT value FROM session_meta WHERE key = 'git-head'\
 ORDER BY session_id DESC LIMIT 1")))))

(ert-deftest el-chronos-store-test-session-meta-git-head-packed-refs ()
  "packed-refs 回退分支：松散 ref 文件不存在时，从 `.git/packed-refs' 按名字匹配取 sha。
本机 `thomas-emacs' 就是「loose ref 与 packed-refs 同时存在」的布局，故这条是必需路径。
fixture 特意放了注释行、另一个 ref 行与 peeled 行（`^<sha>'，单字段），
验证解析既不误取兄弟分支、也不把 peeled 行当提交。"
  (el-chronos-store-test--with-hermetic-db
    (let ((root user-emacs-directory))
      (el-chronos-store-test--write-file
       (expand-file-name ".git/HEAD" root) "ref: refs/heads/master\n")
      (el-chronos-store-test--write-file
       (expand-file-name ".git/packed-refs" root)
       (concat "# pack-refs with: peeled fully-peeled sorted\n"
               el-chronos-store-test--sha-other " refs/heads/develop\n"
               el-chronos-store-test--sha " refs/heads/master\n"
               "^" el-chronos-store-test--sha-other "\n")))
    (el-chronos-store-close)
    (setq el-chronos--session-id nil)
    (should (el-chronos-test--open-db el-chronos-db-path))
    (should (equal el-chronos-store-test--sha
                   (el-chronos-test--scalar
                    "SELECT value FROM session_meta WHERE key = 'git-head'\
 ORDER BY session_id DESC LIMIT 1")))))

(ert-deftest el-chronos-store-test-session-meta-unresolvable-ref-writes-nothing ()
  "引用解析不出 sha（松散文件与 packed-refs 都没有该 ref）→ `git-head' 不写行、不报错。
这一条挡的是「写了个假 sha 或写了分支名」的退化：宁可少一个键，也不写不可信的值。"
  (el-chronos-store-test--with-hermetic-db
    (let ((root user-emacs-directory))
      (el-chronos-store-test--write-file
       (expand-file-name ".git/HEAD" root) "ref: refs/heads/gone\n")
      (el-chronos-store-test--write-file
       (expand-file-name ".git/packed-refs" root)
       (concat el-chronos-store-test--sha-other " refs/heads/develop\n")))
    (el-chronos-store-close)
    (setq el-chronos--session-id nil)
    (should (el-chronos-test--open-db el-chronos-db-path))
    (should (= 0 (el-chronos-test--scalar
                  "SELECT count(*) FROM session_meta WHERE key = 'git-head'")))
    (should-not (el-chronos-store--git-head))))

(ert-deftest el-chronos-store-test-session-meta-config-sig-changes-with-mtime ()
  "`config-sig' 随配置文件 mtime 变化（内容不变也会变），且是 40 位 sha1。
指纹口径：(相对路径 mtime size) 排序后 `prin1-to-string' 取 sha1 —— **不读文件内容**，
故「只改 mtime、不改内容」也必须换指纹，这条正好锁住「mtime 真的进了指纹」。
两次采集走两次真实 open（关库、清 session-id 再开），确保断言的是落库值而不是中间变量。"
  (el-chronos-store-test--with-hermetic-db
    (let ((file (expand-file-name "init.el" user-emacs-directory)))
      (el-chronos-store-test--write-file file ";; 配置内容不变，只改 mtime\n")
      (el-chronos-store-close)
      (setq el-chronos--session-id nil)
      (should (el-chronos-test--open-db el-chronos-db-path))
      (let ((sig1 (el-chronos-test--scalar
                   "SELECT value FROM session_meta WHERE key = 'config-sig'\
 ORDER BY session_id DESC LIMIT 1")))
        (should (stringp sig1))
        (should (= 40 (length sig1)))
        ;; 只动 mtime：往后推一小时，内容一个字节不改
        (set-file-times file (time-subtract (current-time) 3600))
        (el-chronos-store-close)
        (setq el-chronos--session-id nil)
        (should (el-chronos-test--open-db el-chronos-db-path))
        (let ((sig2 (el-chronos-test--scalar
                     "SELECT value FROM session_meta WHERE key = 'config-sig'\
 ORDER BY session_id DESC LIMIT 1")))
          (should (stringp sig2))
          (should-not (equal sig1 sig2)))))))

(ert-deftest el-chronos-store-test-session-meta-both-keys ()
  "既有 `.git' 又有 `init.el' → 两个键各一行，共 2 行，且不跑 flush 就能查到。
最后这条是「直接写库、不走缓冲」的验收：变更标记必须立即可见（O10 定案）。"
  (el-chronos-store-test--with-hermetic-db
    (let ((root user-emacs-directory))
      (el-chronos-store-test--write-file
       (expand-file-name ".git/HEAD" root) "ref: refs/heads/master\n")
      (el-chronos-store-test--write-file
       (expand-file-name ".git/refs/heads/master" root)
       (concat el-chronos-store-test--sha "\n"))
      (el-chronos-store-test--write-file
       (expand-file-name "early-init.el" root) ";; early\n")
      (el-chronos-store-test--write-file
       (expand-file-name "lisp/init-a.el" root) ";; a\n"))
    (el-chronos-store-close)
    (setq el-chronos--session-id nil)
    (should (el-chronos-test--open-db el-chronos-db-path))
    ;; 未调用 `el-chronos-store-flush'，直接查库
    (should (= 2 (el-chronos-test--scalar
                  "SELECT count(*) FROM session_meta WHERE session_id = ?"
                  (list el-chronos--session-id))))
    (should (equal '("config-sig" "git-head")
                   (mapcar #'car
                           (sqlite-select el-chronos-store--db
                                          "SELECT key FROM session_meta\
 WHERE session_id = ? ORDER BY key"
                                          (list el-chronos--session-id)))))
    (should (equal el-chronos-store-test--sha
                   (el-chronos-test--scalar
                    "SELECT value FROM session_meta WHERE key = 'git-head'\
 AND session_id = ?" (list el-chronos--session-id))))))

(provide 'el-chronos-store-test)

;;; el-chronos-store-test.el ends here
