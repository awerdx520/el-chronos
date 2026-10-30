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
  '("commands" "hourly_drift" "hourly_functions" "hourly_gc" "hourly_gc_attrib"
    "hourly_health" "hourly_resources" "hourly_stacks" "hourly_usage" "session_meta"
    "sessions" "slow_events" "startup_phases")
  "schema v5 的全部 13 张用户表（升序，与 `el-chronos-store-test--tables' 的排序一致）。")

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

;;; fixture：schema v2 旧库

(defconst el-chronos-store-test--v2-ddl
  (concat el-chronos-store-test--v1-ddl "
CREATE TABLE IF NOT EXISTS hourly_gc (hour_ts INTEGER NOT NULL, session_id INTEGER NOT NULL, gc_count INTEGER NOT NULL DEFAULT 0, gc_ms REAL NOT NULL DEFAULT 0, heap_bytes INTEGER, PRIMARY KEY (hour_ts, session_id));
CREATE TABLE IF NOT EXISTS startup_phases (session_id INTEGER NOT NULL, phase TEXT NOT NULL, ms REAL NOT NULL, PRIMARY KEY (session_id, phase));
CREATE TABLE IF NOT EXISTS hourly_health (hour_ts INTEGER NOT NULL, session_id INTEGER NOT NULL, key TEXT NOT NULL, value REAL NOT NULL DEFAULT 0, PRIMARY KEY (hour_ts, session_id, key));
CREATE TABLE IF NOT EXISTS session_meta (session_id INTEGER NOT NULL, key TEXT NOT NULL, value TEXT, PRIMARY KEY (session_id, key));")
  "schema v2 的 DDL（10 表 + 3 索引），专用于构造「S1 之后、v3 之前」的旧库 fixture。
同 `el-chronos-store-test--v1-ddl'，v2 的 4 张新表也写成字面量而非引用 store 常量：
若从 `el-chronos-store--ddl-hourly-gc' 之类派生，store 一改常量本 fixture 就跟着变，
「v2 库升到 v3」的用例就再也看不到真实的旧库形状。")

(defun el-chronos-store-test--make-v2-db (path)
  "在 PATH 造一个 schema v2 的库并关闭句柄（不经过 store 的 open）。
内容：10 表 + 3 索引、`user_version'=2、1 行 sessions、2 行 commands、1 行 hourly_gc ——
供「v2 库升到 v3 后既有数据一行不丢」断言使用。
时间戳取当前时刻：open 之后 `--prune' 会按 `el-chronos-retention-days' 删掉早于 30 天的
commands，旧时间戳会让「迁移不丢数据」的断言假红。"
  (let ((db (sqlite-open path))
        (now (truncate (* 1000 (float-time)))))
    (unwind-protect
        (progn
          (sqlite-execute-batch db el-chronos-store-test--v2-ddl)
          (sqlite-pragma db "user_version=2")
          (sqlite-execute
           db "INSERT INTO sessions (started_at, emacs_version, host, startup_ms,\
 gc_threshold) VALUES (?, ?, ?, ?, ?)"
           (list now "31.1" "v2-host" 111.0 (float gc-cons-threshold)))
          (let ((session (caar (sqlite-select db "SELECT last_insert_rowid()"))))
            (dotimes (i 2)
              (sqlite-execute
               db "INSERT INTO commands (ts, session_id, name, duration_ms, gc_ms, mode,\
 project, outcome, kind) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)"
               (list (- now (* (1+ i) 1000)) session (format "v2-cmd-%d" i)
                     (float (1+ i)) nil "emacs-lisp-mode" "v2-proj" "ok" "interactive")))
            (sqlite-execute
             db "INSERT INTO hourly_gc (hour_ts, session_id, gc_count, gc_ms, heap_bytes)\
 VALUES (?, ?, ?, ?, ?)"
             (list (* 3600000 (floor (/ (float now) 3600))) session 2 1.0 2048))))
      (sqlite-close db))))

;;; fixture：schema v3 旧库

(defconst el-chronos-store-test--v3-ddl
  (concat el-chronos-store-test--v2-ddl "
CREATE TABLE IF NOT EXISTS hourly_drift (hour_ts INTEGER NOT NULL, session_id INTEGER NOT NULL, count INTEGER NOT NULL DEFAULT 0, total_ms REAL NOT NULL DEFAULT 0, max_ms REAL NOT NULL DEFAULT 0, PRIMARY KEY (hour_ts, session_id));")
  "schema v3 的 DDL（11 表 + 3 索引），专用于构造「v3 → v4」的旧库 fixture。
同前两份 fixture：`hourly_drift' 写成字面量而非引用 store 常量，否则 store 改常量
本 fixture 跟着变，「v3 库升到 v4」的用例就再也看不到真实的旧库形状。")

(defun el-chronos-store-test--make-v3-db (path)
  "在 PATH 造一个 schema v3 的库并关闭句柄（不经过 store 的 open）。
内容：11 表 + 3 索引、`user_version'=3、1 行 sessions、2 行 commands、
1 行 hourly_gc、1 行 hourly_drift —— 供「v3 库升到 v4 后既有 11 表数据一行不丢」断言使用。
时间戳取当前时刻：open 之后 `--prune' 会按 `el-chronos-retention-days' 删掉早于 30 天的
commands，旧时间戳会让「迁移不丢数据」的断言假红。"
  (let ((db (sqlite-open path))
        (now (truncate (* 1000 (float-time)))))
    (unwind-protect
        (progn
          (sqlite-execute-batch db el-chronos-store-test--v3-ddl)
          (sqlite-pragma db "user_version=3")
          (sqlite-execute
           db "INSERT INTO sessions (started_at, emacs_version, host, startup_ms,\
 gc_threshold) VALUES (?, ?, ?, ?, ?)"
           (list now "31.1" "v3-host" 222.0 (float gc-cons-threshold)))
          (let ((session (caar (sqlite-select db "SELECT last_insert_rowid()"))))
            (dotimes (i 2)
              (sqlite-execute
               db "INSERT INTO commands (ts, session_id, name, duration_ms, gc_ms, mode,\
 project, outcome, kind) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)"
               (list (- now (* (1+ i) 1000)) session (format "v3-cmd-%d" i)
                     (float (1+ i)) nil "emacs-lisp-mode" "v3-proj" "ok" "interactive")))
            (sqlite-execute
             db "INSERT INTO hourly_gc (hour_ts, session_id, gc_count, gc_ms, heap_bytes)\
 VALUES (?, ?, ?, ?, ?)"
             (list (* 3600000 (floor (/ (float now) 3600))) session 2 1.0 2048))
            (sqlite-execute
             db "INSERT INTO hourly_drift (hour_ts, session_id, count, total_ms, max_ms)\
 VALUES (?, ?, ?, ?, ?)"
             (list (* 3600000 (floor (/ (float now) 3600))) session 3 2400.0 900.0))))
      (sqlite-close db))))

;;; fixture：schema v4 旧库

(defconst el-chronos-store-test--v4-ddl
  (concat el-chronos-store-test--v3-ddl "
CREATE TABLE IF NOT EXISTS hourly_resources (hour_ts INTEGER NOT NULL, session_id INTEGER NOT NULL, cpu_ms REAL NOT NULL DEFAULT 0, wall_ms REAL NOT NULL DEFAULT 0, rss_kb_max INTEGER, rss_kb_sum INTEGER, threads_max INTEGER, load1_sum REAL, load5_sum REAL, load15_sum REAL, load_n INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (hour_ts, session_id));")
  "schema v4 的 DDL（12 表 + 3 索引），专用于构造「v4 → v5」的旧库 fixture。
同前三份 fixture：`hourly_resources' 写成字面量而非引用 store 常量，否则 store 改常量
本 fixture 跟着变，「v4 库升到 v5」的用例就再也看不到真实的旧库形状。")

(defun el-chronos-store-test--make-v4-db (path)
  "在 PATH 造一个 schema v4 的库并关闭句柄（不经过 store 的 open）。
内容：12 表 + 3 索引、`user_version'=4、1 行 sessions、2 行 commands、1 行 hourly_gc、
1 行 hourly_drift、1 行 hourly_resources —— 供「v4 库升到 v5 后既有 12 表数据一行不丢」
与「v5 迁移脚本失败时回滚到 v4」两类断言使用。
时间戳取当前时刻：open 之后 `--prune' 会按 `el-chronos-retention-days' 删掉早于 30 天的
commands，旧时间戳会让「迁移不丢数据」的断言假红。"
  (let ((db (sqlite-open path))
        (now (truncate (* 1000 (float-time)))))
    (unwind-protect
        (progn
          (sqlite-execute-batch db el-chronos-store-test--v4-ddl)
          (sqlite-pragma db "user_version=4")
          (sqlite-execute
           db "INSERT INTO sessions (started_at, emacs_version, host, startup_ms,\
 gc_threshold) VALUES (?, ?, ?, ?, ?)"
           (list now "31.1" "v4-host" 333.0 (float gc-cons-threshold)))
          (let ((session (caar (sqlite-select db "SELECT last_insert_rowid()"))))
            (dotimes (i 2)
              (sqlite-execute
               db "INSERT INTO commands (ts, session_id, name, duration_ms, gc_ms, mode,\
 project, outcome, kind) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)"
               (list (- now (* (1+ i) 1000)) session (format "v4-cmd-%d" i)
                     (float (1+ i)) nil "emacs-lisp-mode" "v4-proj" "ok" "interactive")))
            (sqlite-execute
             db "INSERT INTO hourly_gc (hour_ts, session_id, gc_count, gc_ms, heap_bytes)\
 VALUES (?, ?, ?, ?, ?)"
             (list (* 3600000 (floor (/ (float now) 3600))) session 2 1.0 2048))
            (sqlite-execute
             db "INSERT INTO hourly_drift (hour_ts, session_id, count, total_ms, max_ms)\
 VALUES (?, ?, ?, ?, ?)"
             (list (* 3600000 (floor (/ (float now) 3600))) session 3 2400.0 900.0))
            (sqlite-execute
             db "INSERT INTO hourly_resources (hour_ts, session_id, cpu_ms, wall_ms,\
 rss_kb_max, rss_kb_sum, threads_max, load1_sum, load5_sum, load15_sum, load_n)\
 VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
             (list (* 3600000 (floor (/ (float now) 3600))) session 100.0 400.0
                   40960 204800 8 1.5 1.2 0.9 1))))
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
  "新库迁移到当前 schema 版本，十三张表齐备；重开不重复迁移。"
  (el-chronos-test-with-db
    (should (= 5 el-chronos-store--schema-version))
    (should (= el-chronos-store--schema-version
               (el-chronos-test--scalar "PRAGMA user_version")))
    (should (equal el-chronos-store-test--all-tables
                   (el-chronos-store-test--tables el-chronos-store--db)))
    (el-chronos-store-close)
    (should (el-chronos-store-open el-chronos-db-path))
    (should (= el-chronos-store--schema-version
               (el-chronos-test--scalar "PRAGMA user_version")))))

(ert-deftest el-chronos-store-test-migrate-v0-to-v5 ()
  "全新空库（`user_version'=0）一次打开就到 v5：13 表齐备、版本为 5，
且**不重跑** v2 / v3 / v4 / v5 增量脚本（`--ensure-schema' 已建全表并置版本）。
锁住两件历史陷阱：
① `--migrate' 里「`--ensure-schema' 之后把局部版本同步为当前常量」—— 若同步成 0 或 1，
   末尾 pragma 会写出错误版本、或让四条幂等脚本各多跑一遍；
② `--schema-ddl' 必须是**全量**：只改版本号不把新表 concat 进全量串，新库会只建成旧表
   却被标记成最新版本，之后 `--migrate' 因版本相等不再运行，`hourly_gc_attrib' 永远不存在。"
  (el-chronos-test-with-tmp-dir dir
    (let* ((path (expand-file-name "v0.sqlite" dir))
           (user-emacs-directory (file-name-as-directory dir))
           (el-chronos-db-path path)
           (el-chronos--session-id nil)
           (batches nil)
           (orig (symbol-function 'sqlite-execute-batch)))
      (cl-letf (((symbol-function 'sqlite-execute-batch)
                 (lambda (db sql) (push sql batches) (funcall orig db sql))))
        (should (el-chronos-store-open path)))
      (unwind-protect
          (progn
            (should (= 5 (el-chronos-test--scalar "PRAGMA user_version")))
            (should (equal el-chronos-store-test--all-tables
                           (el-chronos-store-test--tables el-chronos-store--db)))
            (should (= 13 (length (el-chronos-store-test--tables
                                   el-chronos-store--db))))
            ;; `--ensure-schema' 执行的是全量 DDL；四条增量脚本都不该出现
            (should (member el-chronos-store--schema-ddl batches))
            (should-not (member el-chronos-store--sql-migrate-v2 batches))
            (should-not (member el-chronos-store--sql-migrate-v3 batches))
            (should-not (member el-chronos-store--sql-migrate-v4 batches))
            (should-not (member el-chronos-store--sql-migrate-v5 batches))
            ;; 全量 DDL 真的建出了新表（不只是「常量里提到了」）
            (should (= 0 (el-chronos-test--count "hourly_gc_attrib"))))
        (el-chronos-store-close)))))
(ert-deftest el-chronos-store-test-migrate-v1-to-v5 ()
  "v1 老库（6 表 + `user_version'=1）打开后**一次**升到 v5：13 表齐备（含
`hourly_drift' / `hourly_resources' / `hourly_gc_attrib'）、既有 commands / sessions
一行不丢。
这是迁移链的守门用例：若 `--migrate' 写成 `(= from-version 2)' 的互斥分支，
v1 库走完 v2 就停住，本用例因后续表缺失而必红。"
  (el-chronos-test-with-tmp-dir dir
    (let ((path (expand-file-name "v1.sqlite" dir))
          ;; 绑定假配置目录：`--ensure-session' 会采变更标记，若指向真实
          ;; `user-emacs-directory' 就会往 `session_meta' 写行，「新表为空」的断言必红
          (user-emacs-directory (file-name-as-directory dir))
          (el-chronos-db-path nil)
          (el-chronos--session-id nil)
          (batches nil)
          (orig (symbol-function 'sqlite-execute-batch)))
      (el-chronos-store-test--make-v1-db path)
      ;; 迁移前先确认 fixture 确实是 v1 的 6 表库
      (let ((raw (sqlite-open path)))
        (unwind-protect
            (progn
              (should (= 1 (caar (sqlite-select raw "PRAGMA user_version"))))
              (should (= 6 (length (el-chronos-store-test--tables raw)))))
          (sqlite-close raw)))
      (setq el-chronos-db-path path)
      (cl-letf (((symbol-function 'sqlite-execute-batch)
                 (lambda (db sql) (push sql batches) (funcall orig db sql))))
        (should (el-chronos-store-open path)))
      (unwind-protect
          (progn
            (should (= 5 (el-chronos-test--scalar "PRAGMA user_version")))
            (should (equal el-chronos-store-test--all-tables
                           (el-chronos-store-test--tables el-chronos-store--db)))
            ;; 四步增量脚本都必须真的跑过（链式推进，不是只跑到 v2 / v3 / v4）
            (should (member el-chronos-store--sql-migrate-v2 batches))
            (should (member el-chronos-store--sql-migrate-v3 batches))
            (should (member el-chronos-store--sql-migrate-v4 batches))
            (should (member el-chronos-store--sql-migrate-v5 batches))
            ;; 既有明细一行不丢
            (should (= 2 (el-chronos-test--scalar
                          "SELECT count(*) FROM commands WHERE name LIKE 'old-cmd-%'")))
            (should (= 1 (el-chronos-test--scalar
                          "SELECT count(*) FROM sessions WHERE host = 'old-host'")))
            ;; v2 四表 + v3 / v4 / v5 新表都在，且都为空（写入层由别的任务负责）
            (dolist (table '("hourly_gc" "startup_phases" "hourly_health"
                            "session_meta" "hourly_drift" "hourly_resources"
                            "hourly_gc_attrib"))
              (should (= 0 (el-chronos-test--count table)))))
        (el-chronos-store-close)))))
(ert-deftest el-chronos-store-test-migrate-v2-to-v5 ()
  "v2 库（10 表 + `user_version'=2）打开后补建 `hourly_drift' / `hourly_resources' /
`hourly_gc_attrib' 并升到 v5：13 表齐备、既有 commands / hourly_gc 数据一行不丢、
三张新表为空，且 v2 增量脚本**不重跑**（版本已是 2）。"
  (el-chronos-test-with-tmp-dir dir
    (let* ((path (expand-file-name "v2.sqlite" dir))
           (user-emacs-directory (file-name-as-directory dir))
           (el-chronos-db-path path)
           (el-chronos--session-id nil)
           (batches nil)
           (orig (symbol-function 'sqlite-execute-batch)))
      (el-chronos-store-test--make-v2-db path)
      ;; fixture 自检：确实是 v2 的 10 表库
      (let ((raw (sqlite-open path)))
        (unwind-protect
            (progn
              (should (= 2 (caar (sqlite-select raw "PRAGMA user_version"))))
              (should (= 10 (length (el-chronos-store-test--tables raw)))))
          (sqlite-close raw)))
      (cl-letf (((symbol-function 'sqlite-execute-batch)
                 (lambda (db sql) (push sql batches) (funcall orig db sql))))
        (should (el-chronos-store-open path)))
      (unwind-protect
          (progn
            (should (= 5 (el-chronos-test--scalar "PRAGMA user_version")))
            (should (equal el-chronos-store-test--all-tables
                           (el-chronos-store-test--tables el-chronos-store--db)))
            ;; v3 / v4 / v5 脚本跑过，v2 脚本不重跑
            (should-not (member el-chronos-store--sql-migrate-v2 batches))
            (should (member el-chronos-store--sql-migrate-v3 batches))
            (should (member el-chronos-store--sql-migrate-v4 batches))
            (should (member el-chronos-store--sql-migrate-v5 batches))
            (should (= 2 (el-chronos-test--scalar
                          "SELECT count(*) FROM commands WHERE name LIKE 'v2-cmd-%'")))
            (should (= 1 (el-chronos-test--count "hourly_gc")))
            (should (= 0 (el-chronos-test--count "hourly_drift")))
            (should (= 0 (el-chronos-test--count "hourly_resources")))
            (should (= 0 (el-chronos-test--count "hourly_gc_attrib")))
            (should (= 1 (el-chronos-test--scalar
                          "SELECT count(*) FROM sessions WHERE host = 'v2-host'"))))
        (el-chronos-store-close)))))
(ert-deftest el-chronos-store-test-migrate-v3-to-v5 ()
  "v3 库（11 表 + `user_version'=3）打开后补建 `hourly_resources' 与 `hourly_gc_attrib'
并升到 v5：13 表齐备、两张新表为空，且 v2 / v3 增量脚本不重跑（只跑 v4 / v5 两步）。
「既有 11 表数据不受损」是本用例的核心断言：迁移只加表，不得动既有行
（`commands' / `sessions' / `hourly_gc' / `hourly_drift' 四条数据逐项比对）。"
  (el-chronos-test-with-tmp-dir dir
    (let* ((path (expand-file-name "v3.sqlite" dir))
           (user-emacs-directory (file-name-as-directory dir))
           (el-chronos-db-path path)
           (el-chronos--session-id nil)
           (batches nil)
           (orig (symbol-function 'sqlite-execute-batch)))
      (el-chronos-store-test--make-v3-db path)
      ;; fixture 自检：确实是 v3 的 11 表库
      (let ((raw (sqlite-open path)))
        (unwind-protect
            (progn
              (should (= 3 (caar (sqlite-select raw "PRAGMA user_version"))))
              (should (= 11 (length (el-chronos-store-test--tables raw)))))
          (sqlite-close raw)))
      (cl-letf (((symbol-function 'sqlite-execute-batch)
                 (lambda (db sql) (push sql batches) (funcall orig db sql))))
        (should (el-chronos-store-open path)))
      (unwind-protect
          (progn
            (should (= 5 (el-chronos-test--scalar "PRAGMA user_version")))
            (should (equal el-chronos-store-test--all-tables
                           (el-chronos-store-test--tables el-chronos-store--db)))
            ;; 只跑 v4 / v5 两步
            (should (member el-chronos-store--sql-migrate-v4 batches))
            (should (member el-chronos-store--sql-migrate-v5 batches))
            (should-not (member el-chronos-store--sql-migrate-v2 batches))
            (should-not (member el-chronos-store--sql-migrate-v3 batches))
            ;; 既有 11 表数据一行不丢、一个字段不变
            (should (= 2 (el-chronos-test--scalar
                          "SELECT count(*) FROM commands WHERE name LIKE 'v3-cmd-%'")))
            (should (= 1 (el-chronos-test--scalar
                          "SELECT count(*) FROM sessions WHERE host = 'v3-host'")))
            (should (= 2 (el-chronos-test--scalar "SELECT gc_count FROM hourly_gc")))
            (should (= 2048 (el-chronos-test--scalar
                             "SELECT heap_bytes FROM hourly_gc")))
            (should (= 3 (el-chronos-test--scalar "SELECT count FROM hourly_drift")))
            (should (= 2400.0 (el-chronos-test--scalar
                               "SELECT total_ms FROM hourly_drift")))
            (should (= 900.0 (el-chronos-test--scalar "SELECT max_ms FROM hourly_drift")))
            ;; 新表为空（写入层由 collect 侧调用，本任务只补 schema）
            (should (= 0 (el-chronos-test--count "hourly_resources")))
            (should (= 0 (el-chronos-test--count "hourly_gc_attrib"))))
        (el-chronos-store-close)))))

(ert-deftest el-chronos-store-test-migrate-v4-to-v5 ()
  "v4 库（12 表 + `user_version'=4）打开后**只**补建 `hourly_gc_attrib' 并升到 v5：
13 表齐备、新表为空，且 v2 / v3 / v4 增量脚本不重跑（只跑 v5 一步）。
「既有 12 表数据不受损」逐项比对：迁移只加表，不得动既有行
（`commands' / `sessions' / `hourly_gc' / `hourly_drift' / `hourly_resources'）。
这是 v5 迁移的守门用例：漏掉 `--schema-ddl' 的 concat 或 `--sql-migrate-v5' 时，
这里会因 `hourly_gc_attrib' 缺失而必红。"
  (el-chronos-test-with-tmp-dir dir
    (let* ((path (expand-file-name "v4.sqlite" dir))
           (user-emacs-directory (file-name-as-directory dir))
           (el-chronos-db-path path)
           (el-chronos--session-id nil)
           (batches nil)
           (orig (symbol-function 'sqlite-execute-batch)))
      (el-chronos-store-test--make-v4-db path)
      ;; fixture 自检：确实是 v4 的 12 表库
      (let ((raw (sqlite-open path)))
        (unwind-protect
            (progn
              (should (= 4 (caar (sqlite-select raw "PRAGMA user_version"))))
              (should (= 12 (length (el-chronos-store-test--tables raw)))))
          (sqlite-close raw)))
      (cl-letf (((symbol-function 'sqlite-execute-batch)
                 (lambda (db sql) (push sql batches) (funcall orig db sql))))
        (should (el-chronos-store-open path)))
      (unwind-protect
          (progn
            (should (= 5 (el-chronos-test--scalar "PRAGMA user_version")))
            (should (equal el-chronos-store-test--all-tables
                           (el-chronos-store-test--tables el-chronos-store--db)))
            (should (= 13 (length (el-chronos-store-test--tables
                                   el-chronos-store--db))))
            ;; 只跑 v5 一步
            (should (member el-chronos-store--sql-migrate-v5 batches))
            (should-not (member el-chronos-store--sql-migrate-v2 batches))
            (should-not (member el-chronos-store--sql-migrate-v3 batches))
            (should-not (member el-chronos-store--sql-migrate-v4 batches))
            ;; 既有 12 表数据一行不丢、一个字段不变
            (should (= 2 (el-chronos-test--scalar
                          "SELECT count(*) FROM commands WHERE name LIKE 'v4-cmd-%'")))
            (should (= 1 (el-chronos-test--scalar
                          "SELECT count(*) FROM sessions WHERE host = 'v4-host'")))
            (should (= 2 (el-chronos-test--scalar "SELECT gc_count FROM hourly_gc")))
            (should (= 2048 (el-chronos-test--scalar
                             "SELECT heap_bytes FROM hourly_gc")))
            (should (= 3 (el-chronos-test--scalar "SELECT count FROM hourly_drift")))
            (should (= 900.0 (el-chronos-test--scalar "SELECT max_ms FROM hourly_drift")))
            (should (= 40960 (el-chronos-test--scalar
                              "SELECT rss_kb_max FROM hourly_resources")))
            (should (= 1 (el-chronos-test--scalar
                          "SELECT load_n FROM hourly_resources")))
            ;; 新表为空（写入层由 collect 侧调用，本任务只补 schema）
            (should (= 0 (el-chronos-test--count "hourly_gc_attrib"))))
        (el-chronos-store-close)))))

(ert-deftest el-chronos-store-test-migrate-v5-idempotent ()
  "已是 v5 的库再打开一次：不报错、版本仍 5、13 表不变、**一条迁移脚本都不跑**。
锁住 `--open-db' 的版本门（`(= version --schema-version)' 分支直接复用句柄）——
若把「相等」错写成「大于等于才跳过」之类，每次启动都会重跑全量 DDL 与迁移脚本。"
  (el-chronos-test-with-tmp-dir dir
    (let* ((path (expand-file-name "v5.sqlite" dir))
           (user-emacs-directory (file-name-as-directory dir))
           (el-chronos-db-path path)
           (el-chronos--session-id nil))
      ;; 第一次打开：空库 → v5
      (unwind-protect
          (progn
            (should (el-chronos-store-open path))
            (should (= 5 (el-chronos-test--scalar "PRAGMA user_version"))))
        (el-chronos-store-close))
      ;; 第二次打开：不得再跑任何迁移脚本
      (let ((batches nil)
            (orig (symbol-function 'sqlite-execute-batch)))
        (cl-letf (((symbol-function 'sqlite-execute-batch)
                   (lambda (db sql) (push sql batches) (funcall orig db sql))))
          (should (el-chronos-store-open path)))
        (unwind-protect
            (progn
              (should (= 5 (el-chronos-test--scalar "PRAGMA user_version")))
              (should (equal el-chronos-store-test--all-tables
                             (el-chronos-store-test--tables el-chronos-store--db)))
              (should-not batches))
          (el-chronos-store-close))))))

(ert-deftest el-chronos-store-test-migrate-noop-when-already-current ()
  "FROM-VERSION 已等于当前版本时 `--migrate' 直接返回 t，且**什么都不做**：
不 checkpoint、不复制 `.bak'、不开事务、版本与数据都不变。
锁住函数**自身**的不变量（而不是依赖 `--open-db' 的版本门）：生产路径确实只在版本更低时
才调用它，但误调用会无谓地跑一次 `wal_checkpoint(TRUNCATE)' 并生成一份与库同大的 `.bak'
副本（真实库约 10 MB 量级）—— 既有隐私考量（库副本落在用户目录里），也有纯 IO 代价。"
  (el-chronos-store-test--with-hermetic-db
    ;; 造一行数据：迁移若真跑了，行数或版本会露馅
    (el-chronos-test--exec
     "INSERT INTO sessions (started_at, emacs_version, host, startup_ms, gc_threshold)\
 VALUES (?, ?, ?, ?, ?)"
     (list (el-chronos-test--now-ms) "31.1" "noop-host" 12.0 (float gc-cons-threshold)))
    (let ((before (el-chronos-test--count "sessions"))
          (bak (concat el-chronos-db-path ".bak"))
          (statements nil)
          (orig (symbol-function 'sqlite-execute)))
      ;; 打开新库时 fixture 自己走过一次 v0 → v5 迁移，会留下 .bak；先删掉，
      ;; 这样「这次调用没有生成 .bak」才是可断言的
      (ignore-errors (delete-file bak))
      (should-not (file-exists-p bak))
      (cl-letf (((symbol-function 'sqlite-execute)
                 (lambda (db sql &optional params)
                   (push sql statements)
                   (funcall orig db sql params))))
        ;; ① 已是最新版本 → 返回 t（幂等语义不变）
        (should (eq t (el-chronos-store--migrate
                       el-chronos-store--db el-chronos-db-path
                       el-chronos-store--schema-version))))
      ;; ② 未生成 .bak（也就没走 copy-file）
      (should-not (file-exists-p bak))
      ;; ③ 未 checkpoint、未开事务
      (should-not (cl-some (lambda (sql) (string-match-p "wal_checkpoint" sql))
                           statements))
      (should-not (cl-some (lambda (sql) (string-prefix-p "BEGIN" (upcase sql)))
                           statements))
      ;; ④ 版本与数据行数都不变
      (should (= el-chronos-store--schema-version
                 (el-chronos-test--scalar "PRAGMA user_version")))
      (should (= before (el-chronos-test--count "sessions"))))))

(ert-deftest el-chronos-store-test-migrate-v5-failure-rolls-back ()
  "v5 迁移脚本报错时整体回滚：open 返回 nil、原库仍是 v4 的 12 表（版本 4）且数据完整、
留下 .bak；去掉注入后同一个库能正常升到 v5。
锁住「迁移失败不得留下半成品库」——`hourly_gc_attrib' 缺失的库会让 GC 归因写入静默失败
（`no such table' → flush 丢本批，只留限流告警），用户不会察觉。"
  (el-chronos-test-with-tmp-dir dir
    (let ((path (expand-file-name "v4.sqlite" dir))
          (user-emacs-directory (file-name-as-directory dir))
          (el-chronos-db-path nil)
          (el-chronos--session-id nil))
      (el-chronos-store-test--make-v4-db path)
      ;; 只让 v5 脚本失败（v4 库的迁移链上只有 v5 一步）
      (let ((orig (symbol-function 'sqlite-execute-batch)))
        (cl-letf (((symbol-function 'sqlite-execute-batch)
                   (lambda (db sql)
                     (if (equal sql el-chronos-store--sql-migrate-v5)
                         (error "mock v5 migration failure")
                       (funcall orig db sql)))))
          (should-not (el-chronos-store-open path))))
      (should-not el-chronos-store--db)
      (should (file-exists-p (concat path ".bak")))
      ;; 原库未被破坏：仍是 v4 + 12 表 + 完整数据，且**没有**半成品新表
      (let ((raw (sqlite-open path)))
        (unwind-protect
            (progn
              (should (= 4 (caar (sqlite-select raw "PRAGMA user_version"))))
              (should (= 12 (length (el-chronos-store-test--tables raw))))
              (should-not (member "hourly_gc_attrib"
                                  (el-chronos-store-test--tables raw)))
              (should (= 2 (caar (sqlite-select raw "SELECT count(*) FROM commands"))))
              (should (= 1 (caar (sqlite-select raw
                                                "SELECT count(*) FROM hourly_resources")))))
          (sqlite-close raw)))
      ;; 去掉注入后能正常升到 v5
      (unwind-protect
          (progn
            (should (el-chronos-store-open path))
            (should (= 5 (el-chronos-test--scalar "PRAGMA user_version")))
            (should (equal el-chronos-store-test--all-tables
                           (el-chronos-store-test--tables el-chronos-store--db))))
        (el-chronos-store-close)))))

(ert-deftest el-chronos-store-test-new-db-has-thirteen-tables ()
  "全新空库 open 后直接是 13 表 + `user_version'=5（`--ensure-schema' 必须走全量 DDL）。"
  (el-chronos-store-test--with-hermetic-db
    (should (= 5 el-chronos-store--schema-version))
    (should (= 5 (el-chronos-test--scalar "PRAGMA user_version")))
    (should (equal el-chronos-store-test--all-tables
                   (el-chronos-store-test--tables el-chronos-store--db)))
    (dolist (table '("hourly_gc" "startup_phases" "hourly_health" "session_meta"
                     "hourly_drift" "hourly_resources" "hourly_gc_attrib"))
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
      ;; 回滚没有把库弄坏：去掉注入后能正常迁移到 v5
      (unwind-protect
          (progn
            (should (el-chronos-store-open path))
            (should (= 5 (el-chronos-test--scalar "PRAGMA user_version")))
            (should (= 13 (length (el-chronos-store-test--tables
                                   el-chronos-store--db)))))
        (el-chronos-store-close)))))

(ert-deftest el-chronos-store-test-migrate-v3-failure-rolls-back ()
  "v3 迁移脚本报错时整体回滚：open 返回 nil、原库仍是 v2 的 10 表（版本 2）且数据完整、
留下 .bak；去掉注入后同一个库能正常升到 v4。
锁住的是「迁移失败不得留下半成品库」——缺 `hourly_drift' 的库会让 drift 写入静默失败
（`no such table' → flush 丢本批，只留限流告警），用户不会察觉。"
  (el-chronos-test-with-tmp-dir dir
    (let ((path (expand-file-name "v2.sqlite" dir))
          (el-chronos-db-path nil)
          (el-chronos--session-id nil))
      (el-chronos-store-test--make-v2-db path)
      ;; 只让 v3 脚本失败（v2 脚本不出现在 from-version=2 的路径上）
      (let ((orig (symbol-function 'sqlite-execute-batch)))
        (cl-letf (((symbol-function 'sqlite-execute-batch)
                   (lambda (db sql)
                     (if (equal sql el-chronos-store--sql-migrate-v3)
                         (error "mock v3 migration failure")
                       (funcall orig db sql)))))
          (should-not (el-chronos-store-open path))))
      (should-not el-chronos-store--db)
      (should (file-exists-p (concat path ".bak")))
      ;; 原库未被破坏：仍是 v2 + 10 表 + 完整数据
      (let ((raw (sqlite-open path)))
        (unwind-protect
            (progn
              (should (= 2 (caar (sqlite-select raw "PRAGMA user_version"))))
              (should (= 10 (length (el-chronos-store-test--tables raw))))
              (should (= 2 (caar (sqlite-select raw "SELECT count(*) FROM commands"))))
              (should (= 1 (caar (sqlite-select raw "SELECT count(*) FROM hourly_gc")))))
          (sqlite-close raw)))
      ;; 去掉注入后能正常升到 v5（v3 步骤是链上的一环，跳过它不成立）
      (unwind-protect
          (progn
            (should (el-chronos-store-open path))
            (should (= 5 (el-chronos-test--scalar "PRAGMA user_version")))
            (should (equal el-chronos-store-test--all-tables
                           (el-chronos-store-test--tables el-chronos-store--db))))
        (el-chronos-store-close)))))

(ert-deftest el-chronos-store-test-hourly-drift-has-no-foreign-key ()
  "`hourly_drift' 不写外键（与既有 hourly_* 及 v2 四表一致）。
为什么必须锁住它：一旦加上 `REFERENCES sessions(id)'，purge 删除顺序、
级联删除与 `foreign_keys=ON' 三者立刻耦合 —— 删会话行会撞外键（整批回滚）
或静默级联删掉聚合数据，两种后果都不是观测器想要的。
判据：`PRAGMA foreign_key_list(hourly_drift)' 为空，且在本库（`foreign_keys' 为 ON）
上直接删掉会话行不报错。已知代价：孤儿 drift 行只能靠 purge 按 `hour_ts' 清理。"
  (el-chronos-store-test--with-hermetic-db
    (should (= 1 (el-chronos-test--scalar "PRAGMA foreign_keys")))
    (should (null (sqlite-select el-chronos-store--db
                                 "PRAGMA foreign_key_list(hourly_drift)")))
    (let ((id (el-chronos-test--insert-session (el-chronos-test--now-ms))))
      (el-chronos-test--exec "INSERT INTO hourly_drift (hour_ts, session_id, count,\
 total_ms, max_ms) VALUES (?, ?, ?, ?, ?)"
                             (list (el-chronos-test--hour-ts) id 1 600.0 600.0))
      (el-chronos-test--exec "DELETE FROM sessions WHERE id = ?" (list id))
      (should (= 0 (el-chronos-test--scalar
                    "SELECT count(*) FROM sessions WHERE id = ?" (list id))))
      (should (= 1 (el-chronos-test--count "hourly_drift"))))))

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
  "会话不可用时跳过 `hourly_stacks'，不写 session_id 为 NULL 的栈行。
**T1（D1）后语义收窄**：flush 批前会补建会话行，故「会话为 nil」只有在**补建也失败**
（撞锁）时才成立 —— 本用例据此把 `--ensure-session' 注入成 `sqlite-locked-error'。
断言本身不变（仍是「不写 NULL 会话的栈行」），变的只是构造该状态的方式：以前只需把
`el-chronos--session-id' 绑 nil，现在那条路径已被补建救回。"
  (el-chronos-test-with-db
    (let ((el-chronos--session-id nil)
          (el-chronos-store--stack-skip-warned t)) ; 已告警过一次，避免测试输出噪声
      (el-chronos-store-record-stacks (el-chronos-test--hour-ts)
                                      (list (cons "[\"a\"]" 5)))
      (cl-letf (((symbol-function 'el-chronos-store--ensure-session)
                 (lambda (&rest _args)
                   (signal 'sqlite-locked-error '("database is locked")))))
        ;; flush 必须在「补建失败、会话仍为 nil」的作用域内执行，才是「会话不可用」这条路径
        (el-chronos-store-flush)))
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
      ;; **S1 起语义变化**：非锁错误整批丢弃时 `dropped-*` 必须记账（本批 1 条命令 +
      ;; 1 条慢事件）。旧断言「丢弃量没发生」只在「丢弃量仅由缓冲上限截断产生」时成立；
      ;; 现在它同时承载「整批写库失败被丢弃」，正是「数据真的丢了」的唯一直接信号
      ;; （`flush-failures` 只说明失败过，保留重试与真丢弃在它上面无法区分）。
      (should (= 1 el-chronos-store--dropped-commands))
      (should (= 1 el-chronos-store--dropped-events))
      (should (= 0 el-chronos-store--flush-count))
      (should (= 0.0 el-chronos-store--flush-ms-total))
      ;; 失败时库中没有任何 health 行（写库本身就是失败的那件事）
      (should (= 0 (el-chronos-test--count "hourly_health")))
      ;; 事务已回滚，明细表没有半批数据
      (should (= 0 (el-chronos-test--count "commands")))
      (should (= 0 (el-chronos-test--count "slow_events"))))))

;;; 多实例并发写：会话行延迟补建（D1 / T1）

(ert-deftest el-chronos-store-test-open-survives-locked-session ()
  "open 期建会话行撞写锁不阻断打开（D1）：仍返回句柄、起 flush timer、会话 ID 暂为 nil。
锁住「`--ensure-session' 抛 `sqlite-locked-error' 时 `store-open' 不得返回 nil」——
那正是「两个实例共用同一 chronos 库时，后启动的实例完全不采集」的病灶：没有会话行
就没有会话 ID，命令明细与九张聚合表全线停写，进程内一条数据都落不了库。
撞锁只记一次 `--busy-retries'、**不**告警（锁竞争是瞬时且可自愈的，不是坏消息）；
句柄拿到之后下一次 flush 负责把会话行补建起来。"
  (el-chronos-test-with-tmp-dir dir
    (let ((path (expand-file-name "locked-open.sqlite" dir))
          (user-emacs-directory (file-name-as-directory dir))
          (el-chronos-db-path nil)
          (el-chronos--session-id nil)
          (el-chronos-retention-days 30)
          (el-chronos-store--warned-at nil)
          (warnings nil))
      (cl-letf (((symbol-function 'el-chronos-store--ensure-session)
                 (lambda (&rest _args)
                   (signal 'sqlite-locked-error '("database is locked"))))
                ((symbol-function 'display-warning)
                 (lambda (&rest args) (push args warnings))))
        (should (el-chronos-store-open path)))
      (unwind-protect
          (progn
            (should el-chronos-store--db)
            (should-not el-chronos--session-id)
            (should (timerp el-chronos-store--flush-timer))
            (should (= 1 el-chronos-store--busy-retries))
            (should-not warnings)       ; 锁竞争静默计数，不走限流告警
            (should (= 0 (el-chronos-test--count "sessions")))
            ;; 句柄确实可用：注入解除后下一次 flush 把会话行补建起来并落库
            (el-chronos-store-record-command (list :name "after-unlock" :duration-ms 1.0))
            (should (el-chronos-store-flush))
            (should (integerp el-chronos--session-id))
            (should (= 1 (el-chronos-test--count "sessions")))
            (should (= 1 (el-chronos-test--count "commands"))))
        (el-chronos-store-close)))))

(ert-deftest el-chronos-store-test-open-survives-session-error ()
  "open 期建会话行遇到**非锁**错误：仍返回句柄，并走 `--warn' 限流告警（I6 不抛错）。
与撞锁路径的唯一差别是可见性：锁竞争瞬时自愈，静默计数即可；其余错误（权限、
schema 损坏、磁盘满）用户需要知道，故告警后同样降级为「会话行延迟补建」，
而不是让整个实例停止采集。"
  (el-chronos-test-with-tmp-dir dir
    (let ((path (expand-file-name "error-open.sqlite" dir))
          (user-emacs-directory (file-name-as-directory dir))
          (el-chronos-db-path nil)
          (el-chronos--session-id nil)
          (el-chronos-retention-days 30)
          (el-chronos-store--warned-at nil)
          (warnings nil))
      (cl-letf (((symbol-function 'el-chronos-store--ensure-session)
                 (lambda (&rest _args) (error "mock session failure")))
                ((symbol-function 'display-warning)
                 (lambda (&rest args) (push args warnings))))
        (should (el-chronos-store-open path)))
      (unwind-protect
          (progn
            (should el-chronos-store--db)
            (should-not el-chronos--session-id)
            (should (timerp el-chronos-store--flush-timer))
            ;; 非锁错误不计入撞锁计数（它不描述锁竞争）
            (should (= 0 el-chronos-store--busy-retries))
            (should (= 1 (length warnings)))
            (should (string-match-p "会话行" (nth 1 (car warnings)))))
        (el-chronos-store-close)))))

(ert-deftest el-chronos-store-test-flush-backfills-session-before-bindings ()
  "会话 ID 为 nil 时 flush 在 `let*' 求值**之前**补建，本批明细与 `hourly_stacks' 同批落库。
锁住顺序约束（计划 §D1）：补建若落在 `let*' 之后，`session' / `stack-session' /
`session-known' 三个绑定仍是旧 nil —— 命令明细因 `session' 为 nil 不写、`hourly_stacks'
被 `--stack-session' 静默跳过，而成功路径随后清空缓冲，数据就无声消失了。"
  (el-chronos-test-with-db
    (let ((hour (el-chronos-test--hour-ts)))
      ;; 记录栈样本时会话正常（键里带会话段），随后模拟「open 期撞锁未建成会话行」
      (el-chronos-store-record-stacks hour (list (cons "[\"fn\"]" 2)))
      (setq el-chronos--session-id nil)
      (el-chronos-store-record-command (list :name "backfilled" :duration-ms 3.0))
      (should (el-chronos-store-flush))
      (should (integerp el-chronos--session-id))
      (should (= 1 (el-chronos-test--count "commands")))
      ;; 顺序约束的可观测后果：本批 `hourly_stacks' 未被跳过
      (should (= 1 (el-chronos-test--count "hourly_stacks"))))))

;;; 多实例并发写：flush 锁竞争保留重试（D2 / T2）

(ert-deftest el-chronos-store-test-flush-locked-keeps-batch ()
  "flush 撞写锁（`sqlite-locked-error'）时**保留**整批：明细、慢事件与九个聚合 hash
一个都不清，只把失败与撞锁计数 +1，streak = 1，返回 nil。
锁住「锁竞争 ≡ 瞬时且可自愈」这条判据：ROLLBACK 之后库状态与事务前完全一致，保留缓冲
重写不会重复计数；而按旧的 `error' 分支一刀切丢弃，会让对端一次 prune / 迁移就白丢
最多 5 秒的采集数据（实测真实库 7 次 flush-failures 全落在这条路径上）。"
  (el-chronos-test-with-db
    (let ((hour (el-chronos-test--hour-ts))
          (session el-chronos--session-id)
          (original (symbol-function 'sqlite-execute)))
      (el-chronos-store-record-command (list :name "kept" :duration-ms 2.0))
      (el-chronos-store-record-slow-event (list :duration-ms 900.0 :kind "block"))
      (el-chronos-store-record-usage hour 'command "kept" 1 2.0)
      (el-chronos-store-record-function-samples hour "fn" nil "pkg" 1.0 2.0 1)
      (el-chronos-store-record-stacks hour (list (cons "[\"fn\"]" 1)))
      (el-chronos-store-record-gc hour 1 1.5 nil)
      (el-chronos-store-record-health hour "sample-misses" 1)
      (el-chronos-store-record-startup-phase session "startup" 10.0)
      (el-chronos-store-record-drift hour 800.0)
      (el-chronos-store-record-resources hour (list :cpu-ms 10 :wall-ms 100))
      (el-chronos-store-record-gc-attrib hour session "cmd" "emacs-lisp-mode" 1 1.5)
      (should (el-chronos-store--pending-p))
      (cl-letf (((symbol-function 'sqlite-execute)
                 (lambda (db sql &rest args)
                   (if (string-match-p "COMMIT" sql)
                       (signal 'sqlite-locked-error '("database is locked"))
                     (apply original db sql args)))))
        ;; 撞锁只降级为告警，不抛错，也不丢弃本批
        (should-not (el-chronos-store-flush)))
      (should (= 1 el-chronos-store--flush-failures))
      (should (= 1 el-chronos-store--busy-retries))
      (should (= 1 el-chronos-store--flush-lock-streak))
      (should el-chronos-store--buffer)
      (should el-chronos-store--slow-events)
      (should (= 1 (hash-table-count el-chronos-store--usage)))
      (should (= 1 (hash-table-count el-chronos-store--functions)))
      (should (= 1 (hash-table-count el-chronos-store--stacks)))
      (should (= 1 (hash-table-count el-chronos-store--gc)))
      (should (= 1 (hash-table-count el-chronos-store--health)))
      (should (= 1 (hash-table-count el-chronos-store--startup)))
      (should (= 1 (hash-table-count el-chronos-store--drift)))
      (should (= 1 (hash-table-count el-chronos-store--resources)))
      (should (= 1 (hash-table-count el-chronos-store--gc-attrib)))
      ;; 事务已回滚：库里没有任何半批数据
      (should (= 0 (el-chronos-test--count "commands")))
      (should (= 0 (el-chronos-test--count "slow_events")))
      (should (= 0 (el-chronos-test--count "hourly_stacks")))
      ;; 成功路径的 `--flush-count' 不因失败变化
      (should (= 0 el-chronos-store--flush-count)))))

(ert-deftest el-chronos-store-test-flush-locked-retry-then-success ()
  "撞锁一次后重试成功：库内行数 = 缓冲条数（**不翻倍**），streak 归 0。
锁住「保留重试不会重复计数」—— 依据是 ROLLBACK 之后库状态与事务前一致，故缓冲原样
重写只会写一次；若哪个分支漏了 ROLLBACK 或提前清了 streak 之外的容器，
这条用例会分别以「行数 2」或「streak 不归零」失败。"
  (el-chronos-test-with-db
    (let ((hour (el-chronos-test--hour-ts))
          (original (symbol-function 'sqlite-execute)))
      (el-chronos-store-record-command (list :name "retried" :duration-ms 3.0))
      (el-chronos-store-record-slow-event (list :duration-ms 700.0 :kind "block"))
      (el-chronos-store-record-usage hour 'command "retried" 1 3.0)
      (cl-letf (((symbol-function 'sqlite-execute)
                 (lambda (db sql &rest args)
                   (if (string-match-p "COMMIT" sql)
                       (signal 'sqlite-locked-error '("database is locked"))
                     (apply original db sql args)))))
        (should-not (el-chronos-store-flush)))
      (should (= 1 el-chronos-store--flush-lock-streak))
      ;; **F2 起语义变化**：撞锁会置 30 秒退避，紧随其后的 flush 会早退（不碰库）。
      ;; 本用例要验的是「退避到期后的重试不重复计数」，故把退避时刻推到过去，模拟
      ;; 生产里「timer 在 ~35 秒后再触发」。不改这条会让用例把「退避生效」误判成「重试失效」。
      (setq el-chronos-store--flush-backoff-until (- (float-time) 1))
      ;; 解除注入后重试：本批原样落库
      (should (el-chronos-store-flush))
      (should (= 0 el-chronos-store--flush-lock-streak))
      (should (= 1 (el-chronos-test--count "commands")))
      (should (= 1 (el-chronos-test--count "slow_events")))
      (should (= 1 (el-chronos-test--count "hourly_usage")))
      ;; 缓冲已消费；撞锁计数已随本次成功 flush 上报（库内累计 1），内存计数器扣回 0
      ;; —— 与 `flush-failures' 同一口径：内存里只留「还没上报的部分」，
      ;; 真实总量 = 库内累计 + 内存差额。旧断言「内存仍为 1」在 T6 上报落地后不再成立。
      (should-not el-chronos-store--buffer)
      (should-not el-chronos-store--slow-events)
      (should (= 0 el-chronos-store--busy-retries))
      (should (= 1 (el-chronos-test--scalar
                    "SELECT value FROM hourly_health WHERE key = 'busy-retries'"))))))

(ert-deftest el-chronos-store-test-flush-locked-streak-limit-discards ()
  "连续撞锁达到 `--max-lock-retries'（6）次后按既有语义丢弃本批，并把 streak 清零。
锁住「保留重试必须有上限」：锁错误可能持续很久（对端长期持锁、库被占满），
无上限保留会让明细与聚合 hash 双双无界增长（明细有 `--max-buffer-items'，
聚合 hash 没有任何上限）。6 × 5 秒 = 30 秒是覆盖对端 prune / 迁移的界。"
  (el-chronos-test-with-db
    (let ((hour (el-chronos-test--hour-ts))
          (original (symbol-function 'sqlite-execute)))
      (el-chronos-store-record-command (list :name "doomed" :duration-ms 4.0))
      (el-chronos-store-record-slow-event (list :duration-ms 600.0 :kind "block"))
      (el-chronos-store-record-usage hour 'command "doomed" 1 4.0)
      (cl-letf (((symbol-function 'sqlite-execute)
                 (lambda (db sql &rest args)
                   (if (string-match-p "COMMIT" sql)
                       (signal 'sqlite-locked-error '("database is locked"))
                     (apply original db sql args)))))
        (dotimes (_ (1- el-chronos-store--max-lock-retries))
          ;; **F2 起语义变化**：每次撞锁都置 30 秒退避，紧随其后的 flush 会早退。
          ;; 模拟「退避到期、timer 再触发」（生产里第 N 次尝试间隔 ~35 秒），否则库里
          ;; 永远只有 streak = 1，本用例测不到上限丢弃。
          (setq el-chronos-store--flush-backoff-until nil)
          (should-not (el-chronos-store-flush))
          (should el-chronos-store--buffer))
        ;; 第 6 次：达到上限，丢弃
        (setq el-chronos-store--flush-backoff-until nil)
        (should-not (el-chronos-store-flush)))
      (should (= el-chronos-store--max-lock-retries el-chronos-store--flush-failures))
      (should (= el-chronos-store--max-lock-retries el-chronos-store--busy-retries))
      (should-not el-chronos-store--buffer)
      (should-not el-chronos-store--slow-events)
      (should (= 0 (hash-table-count el-chronos-store--usage)))
      (should (= 0 el-chronos-store--flush-lock-streak))
      ;; 库内仍无半批数据（每次都 ROLLBACK 了）
      (should (= 0 (el-chronos-test--count "commands")))
      (should (= 0 (el-chronos-test--count "slow_events"))))))

(ert-deftest el-chronos-store-test-flush-non-lock-error-still-discards ()
  "非锁错误（磁盘满 / `no such table' / 约束冲突）**仍立即丢弃**本批，且不计撞锁次数。
锁住「按错误类型分流」的另一半：这些是**持续故障**，重试没有意义 —— 保留只会让内存
无界增长，还会让 streak 语义失真（把磁盘满当成锁竞争）。
streak 必须归零：否则一批磁盘满错误累积的 streak 会把后面的锁竞争提前推到上限。"
  (el-chronos-test-with-db
    (let ((hour (el-chronos-test--hour-ts))
          (original (symbol-function 'sqlite-execute)))
      (el-chronos-store-record-command (list :name "disk-full" :duration-ms 5.0))
      (el-chronos-store-record-usage hour 'command "disk-full" 1 5.0)
      ;; 先造一次撞锁，让 streak 非零，验证非锁错误会把它清零
      (cl-letf (((symbol-function 'sqlite-execute)
                 (lambda (db sql &rest args)
                   (if (string-match-p "COMMIT" sql)
                       (signal 'sqlite-locked-error '("database is locked"))
                     (apply original db sql args)))))
        (should-not (el-chronos-store-flush)))
      (should (= 1 el-chronos-store--flush-lock-streak))
      ;; **F2 起语义变化**：撞锁置了 30 秒退避，紧随其后的 flush 会早退 —— 这里把退避
      ;; 推到过去，模拟「退避到期后再来一次非锁错误」（否则本用例只测到退避门，测不到
      ;; 「非锁错误丢弃本批且不计撞锁次数」这个判据）。
      (setq el-chronos-store--flush-backoff-until nil)
      (cl-letf (((symbol-function 'sqlite-execute)
                 (lambda (db sql &rest args)
                   (if (string-match-p "COMMIT" sql)
                       (signal 'error '("disk full"))
                     (apply original db sql args)))))
        (should-not (el-chronos-store-flush)))
      (should (= 2 el-chronos-store--flush-failures))
      ;; 非锁错误不计撞锁次数（上一次的 1 保留）
      (should (= 1 el-chronos-store--busy-retries))
      (should (= 0 el-chronos-store--flush-lock-streak))
      (should-not el-chronos-store--buffer)
      (should (= 0 (hash-table-count el-chronos-store--usage)))
      (should (= 0 (el-chronos-test--count "commands"))))))

(ert-deftest el-chronos-store-test-flush-backfill-locked-keeps-buffer ()
  "会话行补建撞锁时本批仍然保留明细缓冲，且撞锁计数累加到两次（补建 + COMMIT）。
锁住 D1 与 D2 的交点：补建失败 → 事务里没有命令可写（`session' 为 nil）、随后 COMMIT
撞锁 —— 两条路径都只能降级，绝不能顺手把明细丢掉（那正是「打开时撞锁 → 整场会话
零数据」的最后一环）。`--ignore-error' 式的丢弃会在这里留下空缓冲。"
  (el-chronos-test-with-db
    (let ((original (symbol-function 'sqlite-execute)))
      (setq el-chronos--session-id nil)
      (el-chronos-store-record-command (list :name "keep-me" :duration-ms 4.0))
      (cl-letf (((symbol-function 'el-chronos-store--ensure-session)
                 (lambda (&rest _args)
                   (signal 'sqlite-locked-error '("database is locked"))))
                ((symbol-function 'sqlite-execute)
                 (lambda (db sql &rest args)
                   (if (string-match-p "COMMIT" sql)
                       (signal 'sqlite-locked-error '("database is locked"))
                     (apply original db sql args)))))
        (should-not (el-chronos-store-flush)))
      (should (= 1 (length el-chronos-store--buffer)))
      (should-not el-chronos--session-id)   ; 补建失败，会话仍未建立
      (should (= 2 el-chronos-store--busy-retries))
      (should (= 1 el-chronos-store--flush-lock-streak))
      (should (= 0 (el-chronos-test--count "commands"))))))

;;; 多实例并发写：丢弃告警不节流（F1）+ 撞锁退避（F2）

;; 这两条是 T8 双进程实测暴露的缺陷（保留重试落地之后才显现）：
;;   F1 丢弃告警被 10 分钟限流吞掉 —— 第 1 次撞锁的「保留重试」就把 `--warned-at' 占满，
;;      第 6 次的「本批已丢弃」永远不出现：用户只看得到过程，看不到数据真的丢了。
;;   F2 保留重试让 `--pending-p' 恒真（失败计数非零），于是每 5 秒 flush 一次、每次撞锁
;;      等满 8 秒，主线程被占满（实测 8 次 × 8.01 s）—— 比老的「失败即丢弃后早退」更糟。

(ert-deftest el-chronos-store-test-locked-discard-warning-bypasses-throttle ()
  "第 6 次撞锁的**丢弃**告警必须绕过节流：即使限流窗口已被前一条普通告警占满也要可见。
锁住 F1：`--warned-at' 是一条**共享**的限流通道 —— 第 1 次撞锁的「保留重试」告警就把
600 秒窗口占满，于是「写库连续撞锁 6 次，本批缓冲已按计划丢弃」在生产里**永远不出现**：
用户只看得到过程（第 1/6 次），看不到结果（数据真的丢了）。"
  (el-chronos-test-with-db
    (let ((warnings nil)
          (original (symbol-function 'sqlite-execute)))
      (el-chronos-store-record-command (list :name "doomed" :duration-ms 4.0))
      (cl-letf (((symbol-function 'display-warning)
                 (lambda (_type msg &rest _args) (push msg warnings)))
                ((symbol-function 'sqlite-execute)
                 (lambda (db sql &rest args)
                   (if (string-match-p "COMMIT" sql)
                       (signal 'sqlite-locked-error '("database is locked"))
                     (apply original db sql args)))))
        ;; 先占满限流窗口（第 1 次撞锁的「保留重试」告警正是同一种过程消息）
        (el-chronos-store--warn "先来的普通告警 %d" 1)
        (dotimes (_ el-chronos-store--max-lock-retries)
          ;; 每次尝试前清退避：模拟「30 秒退避已过、flush timer 再触发」（F2 不参与本判据）
          (setq el-chronos-store--flush-backoff-until nil)
          (el-chronos-store-flush)))
      ;; 普通告警只出现一次（限流对过程消息仍然生效）
      (should (= 1 (length (cl-remove-if-not
                            (lambda (m) (string-match-p "先来的普通告警" m))
                            warnings))))
      ;; 结果消息（本批已丢弃）必须**出现在**收集列表里 —— 改造前被限流吞掉，本行必红
      (should (cl-some (lambda (m) (string-match-p "已按计划丢弃" m)) warnings))
      (should-not el-chronos-store--buffer))))

(ert-deftest el-chronos-store-test-locked-retry-warning-still-throttled ()
  "「保留重试」那条（**过程**消息）仍走 10 分钟限流：窗口内只输出一次，不刷屏。
这是 F1 的反向守门：只有「数据真的丢了」这类结果消息才绕过节流；若把 force 也用到过程
消息上，对端持续持锁时每 5 秒一条告警，比不告警更吵（而且会淹没真正的结果消息）。"
  (el-chronos-test-with-db
    (let ((warnings nil)
          (original (symbol-function 'sqlite-execute)))
      (el-chronos-store-record-command (list :name "retry" :duration-ms 1.0))
      (cl-letf (((symbol-function 'display-warning)
                 (lambda (_type msg &rest _args) (push msg warnings)))
                ((symbol-function 'sqlite-execute)
                 (lambda (db sql &rest args)
                   (if (string-match-p "COMMIT" sql)
                       (signal 'sqlite-locked-error '("database is locked"))
                     (apply original db sql args)))))
        (dotimes (_ 3)
          (setq el-chronos-store--flush-backoff-until nil)
          (el-chronos-store-flush)))
      ;; 撞锁了 3 次但只告警 1 次
      (should (= 3 el-chronos-store--flush-lock-streak))
      (should (= 1 (length (cl-remove-if-not
                            (lambda (m) (string-match-p "保留待下次" m))
                            warnings)))))))

(ert-deftest el-chronos-store-test-flush-locked-sets-backoff ()
  "撞锁后设置 30 秒退避：退避期内 flush 早退（一次 SQL / 一次 pragma 都不发、不阻塞主线程），
到期后正常尝试，成功即把退避清零。
锁住 F2：保留重试让 `--pending-p' 恒真（`--flush-failures' / `--busy-retries' 非零），
若不退避，flush timer 每 5 秒就在撞锁后立刻再撞一次，而单次撞锁最坏等满 `busy_timeout'
（8 秒）—— 实测「每 5 秒一次、每次 8.01 秒」共 8 次，主线程被占满，Emacs 基本无响应。"
  (el-chronos-test-with-db
    (let ((original-execute (symbol-function 'sqlite-execute))
          (original-pragma (symbol-function 'sqlite-pragma))
          (exec-calls 0)
          (pragma-calls 0)
          (before (float-time)))
      (el-chronos-store-record-command (list :name "backoff" :duration-ms 1.0))
      (cl-letf (((symbol-function 'sqlite-execute)
                 (lambda (db sql &rest args)
                   (setq exec-calls (1+ exec-calls))
                   (if (string-match-p "COMMIT" sql)
                       (signal 'sqlite-locked-error '("database is locked"))
                     (apply original-execute db sql args))))
                ((symbol-function 'sqlite-pragma)
                 (lambda (db pragma)
                   (when (string-prefix-p "busy_timeout" pragma)
                     (setq pragma-calls (1+ pragma-calls)))
                   (funcall original-pragma db pragma))))
        (should-not (el-chronos-store-flush)))
      ;; 退避窗口 ≈ [撞锁前, 撞锁后] + 30 秒（用区间断言，不依赖时钟精度）
      (should el-chronos-store--flush-backoff-until)
      (should (>= el-chronos-store--flush-backoff-until
                  (+ before el-chronos-store--flush-backoff-seconds)))
      (should (<= el-chronos-store--flush-backoff-until
                  (+ (float-time) el-chronos-store--flush-backoff-seconds)))
      ;; 退避期内：不碰库（SQL 0 次、pragma 0 次），返回 nil，缓冲原样
      (setq exec-calls 0
            pragma-calls 0)
      (should-not (el-chronos-store-flush))
      (should (= 0 exec-calls))
      (should (= 0 pragma-calls))
      (should (= 1 (length el-chronos-store--buffer)))
      ;; 到期后（手工把时刻推到过去）：正常尝试并成功，成功后退避清零
      (setq el-chronos-store--flush-backoff-until (- (float-time) 1))
      (should (el-chronos-store-flush))
      (should-not el-chronos-store--flush-backoff-until)
      (should (= 1 (el-chronos-test--count "commands"))))))

(ert-deftest el-chronos-store-test-flush-locked-discard-still-sets-backoff ()
  "达到 `--max-lock-retries' 丢弃本批后**同样**退避，不因数据容器已清空就立刻再撞。
锁住 F2 的第二半：丢弃路径清的是数据容器，`--flush-failures' / `--busy-retries' 非零
让 `--pending-p' 仍为真 —— 不退避的话下一轮 timer 又白撞满 8 秒。"
  (el-chronos-test-with-db
    (let ((original (symbol-function 'sqlite-execute)))
      (el-chronos-store-record-command (list :name "doomed" :duration-ms 4.0))
      (cl-letf (((symbol-function 'sqlite-execute)
                 (lambda (db sql &rest args)
                   (if (string-match-p "COMMIT" sql)
                       (signal 'sqlite-locked-error '("database is locked"))
                     (apply original db sql args)))))
        (dotimes (_ el-chronos-store--max-lock-retries)
          (setq el-chronos-store--flush-backoff-until nil)
          (el-chronos-store-flush)))
      (should-not el-chronos-store--buffer)
      (should (= el-chronos-store--max-lock-retries el-chronos-store--flush-failures))
      (should el-chronos-store--flush-backoff-until)
      (should (> el-chronos-store--flush-backoff-until (float-time))))))

(ert-deftest el-chronos-store-test-close-resets-flush-backoff ()
  "`store-close' 把撞锁退避清零（I5 零残留）。
残留的后果：同进程重开库（换路径 / 换会话）时仍处在旧库的退避窗口里，前 30 秒的 flush
全部早退 —— 表现为「刚打开就 30 秒不落库」，而且没有任何告警解释原因。"
  (el-chronos-test-with-db
    (setq el-chronos-store--flush-backoff-until (+ (float-time) 30))
    (should el-chronos-store--flush-backoff-until)
    (el-chronos-store-close)
    (should-not el-chronos-store--flush-backoff-until)))

;;; 多实例并发写：写事务 BEGIN IMMEDIATE（D3 / T3）

;; 四处写事务（flush / prune / purge / 迁移）一律用 `BEGIN IMMEDIATE'：抢锁在事务**起点**
;; 完成，不会「干完半批活才失败」；也防御 deferred `BEGIN' 里「先读后写」在 WAL 下升级写
;; 失败（`SQLITE_BUSY_SNAPSHOT'，实测 0 ms 失败、`busy_timeout' 完全无效）。
;; 下面四条用例逐个锁住「事务语句确实是 IMMEDIATE」以及「没有残留裸 BEGIN」。

(ert-deftest el-chronos-store-test-begin-immediate-flush ()
  "flush 的事务语句是 `BEGIN IMMEDIATE'（不是裸 `BEGIN'）。"
  (el-chronos-test-with-db
    (let ((statements nil)
          (original (symbol-function 'sqlite-execute)))
      (el-chronos-store-record-command (list :name "immediate" :duration-ms 1.0))
      (cl-letf (((symbol-function 'sqlite-execute)
                 (lambda (db sql &rest args)
                   (push sql statements)
                   (apply original db sql args))))
        (should (el-chronos-store-flush)))
      (should (member "BEGIN IMMEDIATE" statements))
      (should-not (member "BEGIN" statements))
      ;; 明细确实落库（事务真的执行了，而不是「没跑事务所以没报错」）
      (should (= 1 (el-chronos-test--count "commands"))))))

(ert-deftest el-chronos-store-test-begin-immediate-prune ()
  "`--prune' 的事务语句是 `BEGIN IMMEDIATE'。"
  (el-chronos-test-with-db
    (let ((statements nil)
          (original (symbol-function 'sqlite-execute)))
      (el-chronos-test--insert-command 1000 "ancient" 5.0)
      (cl-letf (((symbol-function 'sqlite-execute)
                 (lambda (db sql &rest args)
                   (push sql statements)
                   (apply original db sql args))))
        (should (el-chronos-store--prune t)))
      (should (member "BEGIN IMMEDIATE" statements))
      (should-not (member "BEGIN" statements))
      (should (= 0 (el-chronos-test--scalar
                    "SELECT count(*) FROM commands WHERE name = 'ancient'"))))))

(ert-deftest el-chronos-store-test-begin-immediate-purge ()
  "`purge' 的事务语句是 `BEGIN IMMEDIATE'。"
  (el-chronos-test-with-db
    (let ((statements nil)
          (original (symbol-function 'sqlite-execute)))
      (el-chronos-test--insert-command (el-chronos-test--hour-ts) "cmd" 5.0)
      (cl-letf (((symbol-function 'sqlite-execute)
                 (lambda (db sql &rest args)
                   (push sql statements)
                   (apply original db sql args))))
        (should (el-chronos-purge)))
      (should (member "BEGIN IMMEDIATE" statements))
      (should-not (member "BEGIN" statements))
      (should (= 0 (el-chronos-test--count "commands"))))))

(ert-deftest el-chronos-store-test-begin-immediate-migrate ()
  "迁移步骤的事务语句是 `BEGIN IMMEDIATE'（以 v4 → v5 为例）。"
  (el-chronos-test-with-tmp-dir dir
    (let ((path (expand-file-name "v4-immediate.sqlite" dir)))
      (el-chronos-store-test--make-v4-db path)
      (let ((db (sqlite-open path))
            (statements nil)
            (original (symbol-function 'sqlite-execute)))
        (unwind-protect
            (progn
              (cl-letf (((symbol-function 'sqlite-execute)
                         (lambda (handle sql &rest args)
                           (push sql statements)
                           (apply original handle sql args))))
                (should (el-chronos-store--migrate db path 4)))
              (should (member "BEGIN IMMEDIATE" statements))
              (should-not (member "BEGIN" statements))
              (should (= 5 (caar (sqlite-select db "PRAGMA user_version")))))
          (ignore-errors (sqlite-close db)))))))

(ert-deftest el-chronos-store-test-begin-immediate-migrate-all-steps ()
  "v1 老库一次升到 v5 时，**四个迁移步骤各自**用 `BEGIN IMMEDIATE'（共 4 次、0 次裸 BEGIN）。
上一个用例只覆盖 v4 → v5 一步；这里逐级走完 v2 / v3 / v4 / v5，避免「只改了其中一处」漏检。"
  (el-chronos-test-with-tmp-dir dir
    (let ((path (expand-file-name "v1-immediate.sqlite" dir)))
      (el-chronos-store-test--make-v1-db path)
      (let ((db (sqlite-open path))
            (statements nil)
            (original (symbol-function 'sqlite-execute)))
        (unwind-protect
            (progn
              (cl-letf (((symbol-function 'sqlite-execute)
                         (lambda (handle sql &rest args)
                           (push sql statements)
                           (apply original handle sql args))))
                (should (el-chronos-store--migrate db path 1)))
              (should (= 4 (cl-count "BEGIN IMMEDIATE" statements :test #'equal)))
              (should-not (cl-find "BEGIN" statements :test #'equal))
              (should (= 5 (caar (sqlite-select db "PRAGMA user_version")))))
          (ignore-errors (sqlite-close db)))))))

;;; 多实例并发写：busy_timeout 分层（D4 / T4）

;; 分层：启动路径（open / 建会话行）保持 2000 ms —— 拖长会拖慢 Emacs 启动；
;; 后台批量写（flush / prune / purge）允许等到 8000 ms —— 两个实例共享一个库时，
;; 对端一次大 prune 或迁移就可能持锁 1–3 秒。8 秒仍是**有界**等待。

(ert-deftest el-chronos-store-test-busy-timeout-write-window-flush ()
  "flush 期间句柄的 `busy_timeout' 抬到 8000 ms，结束后恢复 2000 ms。
除了拦截 `sqlite-pragma' 校验调用序列，还**真的**读一次 `PRAGMA busy_timeout`：
连接级 pragma 会残留，只验证「拦截层看起来调用了恢复」不足以证明恢复生效。"
  (el-chronos-test-with-db
    (let ((pragmas nil)
          (original (symbol-function 'sqlite-pragma)))
      (should (= 2000 (caar (sqlite-select el-chronos-store--db "PRAGMA busy_timeout"))))
      (el-chronos-store-record-command (list :name "timeout" :duration-ms 1.0))
      (cl-letf (((symbol-function 'sqlite-pragma)
                 (lambda (db pragma)
                   (when (string-prefix-p "busy_timeout" pragma)
                     (push pragma pragmas))
                   (funcall original db pragma))))
        (should (el-chronos-store-flush)))
      (should (equal '("busy_timeout=8000" "busy_timeout=2000") (nreverse pragmas)))
      ;; 恢复是真的（连接级 pragma 残留会让之后所有写入都白等 8 秒）
      (should (= 2000 (caar (sqlite-select el-chronos-store--db "PRAGMA busy_timeout")))))))

(ert-deftest el-chronos-store-test-busy-timeout-restored-on-error ()
  "flush 在事务中途抛错时**同样**恢复 2000 ms（`unwind-protect' 语义）。
漏恢复的后果不是「多等一次」：连接级 pragma 会残留到后续所有写入，让每次撞锁都白等 8 秒，
直接拖慢用户正在用的 Emacs。故错误路径与成功路径必须一样。"
  (el-chronos-test-with-db
    (let ((pragmas nil)
          (original-pragma (symbol-function 'sqlite-pragma))
          (original-execute (symbol-function 'sqlite-execute)))
      (el-chronos-store-record-command (list :name "doomed" :duration-ms 1.0))
      (cl-letf (((symbol-function 'sqlite-pragma)
                 (lambda (db pragma)
                   (when (string-prefix-p "busy_timeout" pragma)
                     (push pragma pragmas))
                   (funcall original-pragma db pragma)))
                ((symbol-function 'sqlite-execute)
                 (lambda (db sql &rest args)
                   (if (string-match-p "COMMIT" sql)
                       (error "mock commit failure")
                     (apply original-execute db sql args)))))
        (should-not (el-chronos-store-flush)))
      (should (equal '("busy_timeout=8000" "busy_timeout=2000") (nreverse pragmas)))
      (should (= 2000 (caar (sqlite-select el-chronos-store--db "PRAGMA busy_timeout")))))))

(ert-deftest el-chronos-store-test-busy-timeout-open-keeps-default ()
  "`store-open' 全程**不出现** `busy_timeout=8000`：启动路径保持 2000 ms。
两层含义：① `--open-db' / `--ensure-session-quiet' 不得包 write-timeout（那会把
Emacs 启动拖长）；② 新库上 `--prune' 没有候选行，因此连写事务都不开 —— 也就不会调
write-timeout。只出现一次 `busy_timeout=2000'（`--open-db' 的默认设置）。"
  (el-chronos-test-with-tmp-dir dir
    (let ((path (expand-file-name "open-timeout.sqlite" dir))
          (user-emacs-directory (file-name-as-directory dir))
          (el-chronos-db-path nil)
          (el-chronos--session-id nil)
          (el-chronos-retention-days 30)
          (pragmas nil)
          (original (symbol-function 'sqlite-pragma)))
      (cl-letf (((symbol-function 'sqlite-pragma)
                 (lambda (db pragma)
                   (when (string-prefix-p "busy_timeout" pragma)
                     (push pragma pragmas))
                   (funcall original db pragma))))
        (should (el-chronos-store-open path)))
      (unwind-protect
          (progn
            (should (equal '("busy_timeout=2000") (nreverse pragmas)))
            (should-not (member "busy_timeout=8000" pragmas))
            (should (= 2000 (caar (sqlite-select el-chronos-store--db
                                                 "PRAGMA busy_timeout")))))
        (el-chronos-store-close)))))

;;; 多实例并发写：prune 预检 + 节流（D5 / T5）

;; `--prune' 是写操作，每次都会抢一次写锁；它唯一的调用点是 `el-chronos-store-open'，
;; 而多实例 / 反复 open-close（隔离实例、批量脚本）会让「每次 open 都 prune」变成常态
;; 锁竞争源。故：① 一小时一次（`--prune-interval-seconds'）；② 过门之后再预检候选行，
;; 两表都没有过期行就**完全不开写事务**。

(ert-deftest el-chronos-store-test-prune-skips-write-when-nothing-expired ()
  "没有过期行时 `--prune' 不开写事务：既不 `BEGIN IMMEDIATE' 也不 DELETE，返回 nil。
锁住候选预检 —— 空转的写事务是「多实例同时启动」场景里最无谓的锁竞争来源。"
  (el-chronos-test-with-db
    (let ((statements nil)
          (original (symbol-function 'sqlite-execute)))
      ;; 只留「没过期」的明细行
      (el-chronos-test--insert-command (el-chronos-test--now-ms) "fresh" 5.0)
      (cl-letf (((symbol-function 'sqlite-execute)
                 (lambda (db sql &rest args)
                   (push sql statements)
                   (apply original db sql args))))
        (should-not (el-chronos-store--prune t)))
      (should-not (cl-some (lambda (sql) (string-match-p "BEGIN" sql)) statements))
      (should-not (cl-some (lambda (sql) (string-match-p "DELETE" sql)) statements))
      ;; 只做了读锁层面的预检，数据一行不少
      (should (= 1 (el-chronos-test--scalar
                    "SELECT count(*) FROM commands WHERE name = 'fresh'"))))))

(ert-deftest el-chronos-store-test-prune-throttled-within-interval ()
  "距上次 `--prune' 未满 `--prune-interval-seconds' 时直接跳过：不查询、不开事务、不删行。
节流门必须比预检更早 —— 否则「每分钟跑一次 count(*)」也还是浪费。"
  (el-chronos-test-with-db
    (let ((statements nil)
          (el-chronos-store--last-prune-time (float-time))
          (original-execute (symbol-function 'sqlite-execute))
          (original-select (symbol-function 'sqlite-select)))
      (el-chronos-test--insert-command 1000 "ancient" 5.0)
      (cl-letf (((symbol-function 'sqlite-execute)
                 (lambda (db sql &rest args)
                   (push sql statements)
                   (apply original-execute db sql args)))
                ((symbol-function 'sqlite-select)
                 (lambda (db sql &rest args)
                   (push sql statements)
                   (apply original-select db sql args))))
        (should-not (el-chronos-store--prune)))
      ;; 连预检的 SELECT 都没跑
      (should-not statements)
      (should (= 1 (el-chronos-test--count "commands")))
      ;; 节流跳过不更新时间戳（否则永远等不到下个窗口）
      (should (< (- (float-time) el-chronos-store--last-prune-time) 5)))))

(ert-deftest el-chronos-store-test-prune-force-bypasses-throttle ()
  "FORCE 非 nil 时绕过节流门，即使刚 prune 过也照常清理。
这是测试与手动排障的入口（`--prune' 唯一的生产调用点仍然是 `store-open'）。"
  (el-chronos-test-with-db
    (let ((el-chronos-store--last-prune-time (float-time)))
      (el-chronos-test--insert-command 1000 "ancient" 5.0)
      (should (el-chronos-store--prune t))
      (should (= 0 (el-chronos-test--scalar
                    "SELECT count(*) FROM commands WHERE name = 'ancient'"))))))

(ert-deftest el-chronos-store-test-prune-updates-last-prune-time ()
  "过了节流门就**立即**记录时间戳（无论有没有候选行），并照常删掉过期行。
记录点必须在预检之前：否则「没有候选行」的那些 open 每分钟都要重跑 count(*)。"
  (el-chronos-test-with-db
    (let ((el-chronos-store--last-prune-time (- (float-time) 7200))) ; 两小时前
      (el-chronos-test--insert-command 1000 "ancient" 5.0)
      (el-chronos-test--insert-slow-event 1000 900.0 "block")
      (should (el-chronos-store-test--prune-now))
      (should (= 0 (el-chronos-test--scalar
                    "SELECT count(*) FROM commands WHERE name = 'ancient'")))
      (should (= 0 (el-chronos-test--scalar
                    "SELECT count(*) FROM slow_events WHERE ts = 1000")))
      (should (floatp el-chronos-store--last-prune-time))
      (should (>= el-chronos-store--last-prune-time (- (float-time) 5))))))

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

(defun el-chronos-store-test--prune-now ()
  "在用例里强制跑一次 `--prune'（FORCE 非 nil，绕过节流门）。
为什么必须强制：fixture 的 `el-chronos-store-open' 已经替用例跑过一次 prune 并把
`--last-prune-time' 写成「刚刚」，不强制就会被节流门直接跳过并返回 nil ——
那是 `prune-throttled-within-interval' 专门验证的行为，不该混进「prune 会不会删超期行」
这类用例里。"
  (el-chronos-store--prune t))

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
      (should (el-chronos-store-test--prune-now))
      (should (= 0 (el-chronos-test--scalar
                    "SELECT count(*) FROM commands WHERE name = 'ancient'")))
      (should (= 0 (el-chronos-test--scalar
                    "SELECT count(*) FROM slow_events WHERE ts = ?" (list old))))
      (should (= 1 (el-chronos-test--count "hourly_functions")))
      (should (= 1 (el-chronos-test--count "hourly_usage")))
      (should (= 1 (el-chronos-test--count "hourly_stacks"))))))

(ert-deftest el-chronos-store-test-purge-empties-and-rebuilds-session ()
  "`purge' 无参时清空 10 张数据表，并立刻补建当前会话行（否则后续写入撞外键）。
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
      ;; v3 新表同理：T1 只有 schema，没有写入接口
      (el-chronos-test--exec "INSERT INTO hourly_drift (hour_ts, session_id, count,\
 total_ms, max_ms) VALUES (?, ?, ?, ?, ?)"
                             (list hour session 4 3200.0 900.0))
      ;; v4 新表（hourly_resources）同样手工 INSERT
      (el-chronos-test--exec "INSERT INTO hourly_resources (hour_ts, session_id,\
 cpu_ms, wall_ms, rss_kb_max, rss_kb_sum, threads_max, load1_sum, load5_sum,\
 load15_sum, load_n) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
                             (list hour session 120.0 500.0 81920 409600 12
                                   1.5 1.2 0.9 1))
      ;; v5 新表（hourly_gc_attrib）同样手工 INSERT
      (el-chronos-test--exec "INSERT INTO hourly_gc_attrib (hour_ts, session_id,\
 command, mode, gc_count, gc_ms) VALUES (?, ?, ?, ?, ?, ?)"
                             (list hour session "save-buffer" "emacs-lisp-mode" 2 12.0))
      ;; 让 `--ensure-session' 一定算出非 nil 的 startup_ms（两个 init 时刻差 2 小时），
      ;; 才可能验证 purge 补建后把它置回了 NULL；否则该断言恒真、锁不住行为。
      (let ((before-init-time (time-subtract (current-time) 7200))
            (after-init-time (current-time)))
        (let ((result (el-chronos-purge)))
          (should (= 13 (length result)))
          (should (equal '("commands" "slow_events" "startup_phases" "session_meta"
                           "hourly_functions" "hourly_usage" "hourly_stacks"
                           "hourly_gc" "hourly_health" "hourly_drift"
                           "hourly_resources" "hourly_gc_attrib" "sessions")
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

(ert-deftest el-chronos-store-test-purge-survives-session-rebuild-lock ()
  "COMMIT **之后**补建会话行撞锁时，purge 仍返回删除结果、且不报「已回滚」。
事务已经提交，此处的失败不属于回滚语义：若仍走会抛错的 `--ensure-session'，异常会被
外层 `condition-case' 当成事务失败 —— 用户看到「purge 失败（已回滚）」而 13 张表其实
已经删干净了（错误的方向是「以为没删、实际删了」，比反过来更危险）。
改用 `--ensure-session-quiet'：撞锁只记 `--busy-retries'，会话 ID 留 nil 等下次补建。"
  (el-chronos-test-with-db
    (let ((warnings nil))
      (el-chronos-test--insert-command (el-chronos-test--hour-ts) "cmd" 5.0)
      (cl-letf (((symbol-function 'el-chronos-store--ensure-session)
                 (lambda (&rest _args)
                   (signal 'sqlite-locked-error '("database is locked"))))
                ((symbol-function 'display-warning)
                 (lambda (&rest args) (push args warnings))))
        (let ((result (el-chronos-purge)))
          ;; 删除结果照常返回（13 张表，顺序不变）
          (should (= 13 (length result)))
          (should (equal "commands" (car (car result))))))
      ;; 没有「已回滚」告警
      (should-not (cl-some (lambda (w) (string-match-p "已回滚" (format "%s" w)))
                           warnings))
      ;; 数据确实删掉了（提交是真的，不是被回滚过的假象）
      (should (= 0 (el-chronos-test--count "commands")))
      ;; 撞锁只记一次 `--busy-retries'；会话 ID 保持 nil，等下次 open / flush 补建
      (should (= 1 el-chronos-store--busy-retries))
      (should-not el-chronos--session-id))))

(ert-deftest el-chronos-store-test-purge-empties-ten-tables ()
  "`purge' 无参时 13 张表的 1–2 行数据全部清空，只留下重建的当前会话行。
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
          ;; v3 新表：同上，手工 INSERT
          (el-chronos-test--exec "INSERT INTO hourly_drift (hour_ts, session_id, count,\
 total_ms, max_ms) VALUES (?, ?, ?, ?, ?)"
                                 (list hour session 3 1800.0 700.0))
          ;; v4 新表：同上
          (el-chronos-test--exec "INSERT INTO hourly_resources (hour_ts, session_id,\
 cpu_ms, wall_ms, rss_kb_max, rss_kb_sum, threads_max, load1_sum, load5_sum,\
 load15_sum, load_n) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
                                 (list hour session 60.0 250.0 65536 204800 10
                                       1.0 0.8 0.6 1))
          ;; v5 新表：同上
          (el-chronos-test--exec "INSERT INTO hourly_gc_attrib (hour_ts, session_id,\
 command, mode, gc_count, gc_ms) VALUES (?, ?, ?, ?, ?, ?)"
                                 (list hour session "save-buffer" "emacs-lisp-mode"
                                       2 12.0))
          ;; 13 表都非空（`sessions' 由 open 建好）
          (dolist (table el-chronos-store-test--all-tables)
            (should (>= (el-chronos-test--count table) 1)))
          (el-chronos-purge)
          ;; 10 张数据表清空
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
                                   (list old-hour old-id "dropped-commands" 1.0))
            (el-chronos-test--exec "INSERT INTO hourly_drift (hour_ts, session_id, count,\
 total_ms, max_ms) VALUES (?, ?, ?, ?, ?)"
                                   (list old-hour old-id 2 1300.0 800.0)))
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
          (el-chronos-test--exec "INSERT INTO hourly_drift (hour_ts, session_id, count,\
 total_ms, max_ms) VALUES (?, ?, ?, ?, ?)"
                                 (list cur-hour new-id 1 620.0 620.0))
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
          (should (= 0 (el-chronos-test--scalar
                        "SELECT count(*) FROM hourly_drift WHERE hour_ts = ?"
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
                        (list cur-hour))))
          (should (= 1 (el-chronos-test--scalar
                        "SELECT count(*) FROM hourly_drift WHERE hour_ts = ?"
                        (list cur-hour)))))))))

(ert-deftest el-chronos-store-test-prune-does-not-touch-new-tables ()
  "自动 retention（`--prune'）只删 `commands' / `slow_events'：
新表（v2 四表与 v3 的 `hourly_drift'）即使数据早已超期也一行不动
（聚合与元数据长期保留，只由 purge 清理）。"
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
      (el-chronos-test--exec "INSERT INTO hourly_drift (hour_ts, session_id, count,\
 total_ms, max_ms) VALUES (?, ?, ?, ?, ?)"
                             (list old old-id 6 4200.0 1100.0))
      (should (el-chronos-store-test--prune-now))
      ;; 明细超期行被删
      (should (= 0 (el-chronos-test--scalar
                    "SELECT count(*) FROM commands WHERE name = 'ancient'")))
      (should (= 0 (el-chronos-test--scalar
                    "SELECT count(*) FROM slow_events WHERE ts = ?" (list old))))
      ;; 新表一行不少（含超期的 hourly_gc / hourly_health / hourly_drift）
      (should (= 1 (el-chronos-test--count "hourly_gc")))
      (should (= 1 (el-chronos-test--count "hourly_health")))
      (should (= 1 (el-chronos-test--count "startup_phases")))
      (should (= 1 (el-chronos-test--count "session_meta")))
      (should (= 1 (el-chronos-test--count "hourly_drift"))))))

(ert-deftest el-chronos-store-test-prune-does-not-touch-hourly-drift ()
  "自动 retention（`--prune'）不动 `hourly_drift'：即使行早已超期也一行不删
（小时聚合永久保留，只由 `el-chronos-purge' 清理）。
与 `prune-does-not-touch-new-tables' 的区别：这里只留 drift 一种聚合行，
断言「唯一的数据源没被顺手删掉」，不掺 v2 四表。"
  (el-chronos-store-test--with-hermetic-db
    (let* ((old 1000)                    ; 远早于 30 天保留阈值
           (old-id (el-chronos-test--insert-session old)))
      (el-chronos-test--insert-command old "ancient" 5.0)
      (el-chronos-test--exec "INSERT INTO hourly_drift (hour_ts, session_id, count,\
 total_ms, max_ms) VALUES (?, ?, ?, ?, ?)"
                             (list old old-id 7 5600.0 1200.0))
      (should (el-chronos-store-test--prune-now))
      (should (= 0 (el-chronos-test--scalar
                    "SELECT count(*) FROM commands WHERE name = 'ancient'")))
      (should (= 1 (el-chronos-test--count "hourly_drift"))))))

(ert-deftest el-chronos-store-test-purge-with-before-deletes-old-hourly-drift ()
  "带 BEFORE 的 purge 按 `hour_ts' 删 `hourly_drift'，而且**与会话是否保留无关**：
旧小时的 drift 行即便所属会话因「名下仍有存活命令」被保留，也照样删掉 —— 聚合表按时间
轮换，不像 `startup_phases' 那样跟会话共存亡。新小时的 drift 行一行不少。
锁住的是 `(:hourly_drift . hour-ts)' 这条 purge 目标真的生效（漏了它就是永久孤儿）。"
  (el-chronos-test-with-tmp-dir dir
    (let ((user-emacs-directory (file-name-as-directory dir)))
      (el-chronos-test-with-db
        (let* ((now (el-chronos-test--now-ms))
               (cutoff (- now (* 10 86400000)))               ; 界：10 天前
               (old-hour (- (el-chronos-test--hour-ts) (* 264 3600000))) ; 11 天前整点
               (cur-hour (el-chronos-test--hour-ts))
               (old-id (el-chronos-test--insert-session (- now (* 20 86400000))))
               (new-id el-chronos--session-id))
          ;; 旧会话：一行今天的命令（存活子行 → 会话必须保留）+ 一行旧小时的 drift
          (let ((el-chronos--session-id old-id))
            (el-chronos-test--insert-command now "old-session-live" 5.0))
          (el-chronos-test--exec "INSERT INTO hourly_drift (hour_ts, session_id, count,\
 total_ms, max_ms) VALUES (?, ?, ?, ?, ?)"
                                 (list old-hour old-id 3 2100.0 800.0))
          (el-chronos-test--exec "INSERT INTO hourly_drift (hour_ts, session_id, count,\
 total_ms, max_ms) VALUES (?, ?, ?, ?, ?)"
                                 (list cur-hour new-id 1 620.0 620.0))
          (should (= 2 (el-chronos-test--count "hourly_drift")))
          (el-chronos-purge cutoff)
          ;; 会话被保留（名下还有今天的命令）
          (should (= 1 (el-chronos-test--scalar
                        "SELECT count(*) FROM sessions WHERE id = ?" (list old-id))))
          ;; 但它的旧 drift 行照样被删（按 hour_ts，不按会话）
          (should (= 0 (el-chronos-test--scalar
                        "SELECT count(*) FROM hourly_drift WHERE hour_ts = ?"
                        (list old-hour))))
          ;; 新小时的 drift 行保留
          (should (= 1 (el-chronos-test--scalar
                        "SELECT count(*) FROM hourly_drift WHERE hour_ts = ?"
                        (list cur-hour))))
          (should (= 1 (el-chronos-test--count "hourly_drift"))))))))

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
            (should (= 13 (length result)))
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

;;; 命令外停转聚合（v3 / T2a：drift 写入链路）

(ert-deftest el-chronos-store-test-record-drift-accumulates-and-max-wins ()
  "同键两次 record（500ms、1200ms）→ flush → count=2、total_ms=1700、max_ms=1200。
锁住 `--sql-upsert-drift' 的三列语义：`count' / `total_ms' 必须**累加**，
`max_ms' 必须取标量 `MAX'。把 `max_ms = MAX(max_ms, excluded.max_ms)' 写成普通覆盖，
只要本批最大值不是历史最大值就会红；写成累加则 max_ms 变成 1700。
第二批更小再验一次：库里的 max_ms 不得被抹小（跨批次的同一条保证）。"
  (el-chronos-test-with-db
    (let ((hour (el-chronos-test--hour-ts)))
      (el-chronos-store-record-drift hour 500.0)
      (el-chronos-store-record-drift hour 1200.0)
      (should (= 1 (hash-table-count el-chronos-store--drift)))
      (should (el-chronos-store-flush))
      (should (= 1 (el-chronos-test--count "hourly_drift")))
      (let ((row (car (sqlite-select el-chronos-store--db
                                     "SELECT count, total_ms, max_ms FROM hourly_drift"
                                     nil))))
        (should (= 2 (nth 0 row)))
        (should (= 1700.0 (nth 1 row)))
        (should (= 1200.0 (nth 2 row))))
      ;; 第二批更小：count / total 继续累加，max 保历史最大值
      (el-chronos-store-record-drift hour 300.0)
      (should (el-chronos-store-flush))
      (should (= 3 (el-chronos-test--scalar "SELECT count FROM hourly_drift")))
      (should (= 2000.0 (el-chronos-test--scalar "SELECT total_ms FROM hourly_drift")))
      (should (= 1200.0 (el-chronos-test--scalar "SELECT max_ms FROM hourly_drift"))))))

(ert-deftest el-chronos-store-test-record-drift-skips-invalid-input ()
  "GAP-MS 为 0 / 负数 / 非数值 / nil → 不累加、不报错（防御 + I6）。
0ms 的「停转」没有信息量，负数只可能是时钟回拨或调用方算错；放进缓冲区会污染
`count' 与 `total_ms' 的比值，且不会有任何地方发现。
末尾再验一个合法值仍然进得来（守卫没有误伤正常输入）。"
  (el-chronos-test-with-db
    (let ((hour (el-chronos-test--hour-ts)))
      (should-not (el-chronos-store-record-drift hour 0))
      (should-not (el-chronos-store-record-drift hour -300))
      (should-not (el-chronos-store-record-drift hour "500"))
      (should-not (el-chronos-store-record-drift hour nil))
      (should (= 0 (hash-table-count el-chronos-store--drift)))
      (should-not (el-chronos-store--pending-p))
      (should (el-chronos-store-record-drift hour 0.5))
      (should (= 1 (hash-table-count el-chronos-store--drift))))))

(ert-deftest el-chronos-store-test-flush-runs-when-only-drift-pending ()
  "只有 drift 待写时 flush 也必须执行（锁 `--pending-p' 里的 `--drift'）。
漏掉它 → flush 第一道门 `(and db (--pending-p))' 早退 → 停转数据永不落库且**无任何报错**。
停转是稀疏事件（几百毫秒到几秒才可能有一条），「只有 drift 待写」是常态而非边缘情况。
开头逐个断言其余容器为空，保证这一轮确实只剩 drift 待写。"
  (el-chronos-test-with-db
    (let ((hour (el-chronos-test--hour-ts)))
      (should (null el-chronos-store--buffer))
      (should (null el-chronos-store--slow-events))
      (should (= 0 (hash-table-count el-chronos-store--usage)))
      (should (= 0 (hash-table-count el-chronos-store--functions)))
      (should (= 0 (hash-table-count el-chronos-store--stacks)))
      (should (= 0 (hash-table-count el-chronos-store--gc)))
      (should (= 0 (hash-table-count el-chronos-store--health)))
      (should (= 0 (hash-table-count el-chronos-store--startup)))
      (should-not el-chronos-store--pending-startup-ms)
      (el-chronos-store-record-drift hour 800.0)
      (should (= 1 (hash-table-count el-chronos-store--drift)))
      (should (el-chronos-store--pending-p))
      (should (el-chronos-store-flush))
      (should (= 1 (el-chronos-test--count "hourly_drift"))))))

(ert-deftest el-chronos-store-test-flush-skips-drift-when-session-unknown ()
  "会话行不存在时 flush 跳过 `hourly_drift` 并告警一次（锁会话守卫 + 文案）。
`hourly_drift` 无外键（与 v2 三表一致），DB 不会挡孤儿 session_id —— 一旦写进去，
purge 的 `session_id IN (SELECT id FROM sessions ...)' 子查询永远删不掉，静默永久残留。
告警文案必须点名 `hourly_drift`，否则用户看到「已跳过聚合写入」会以为 drift 写成功了。
既有表行为必须不变（`hourly_functions' 照写：本任务只补 drift，不做统一重构）。"
  (el-chronos-test-with-db
    (let ((hour (el-chronos-test--hour-ts))
          (messages nil)
          (el-chronos-store--aggregate-orphan-warned nil)
          ;; 让 hourly_stacks 的既有告警走已告警分支，避免混进本用例的计数
          (el-chronos-store--stack-skip-warned t))
      (cl-letf (((symbol-function 'display-warning)
                 (lambda (_type msg &optional _level) (push msg messages))))
        ;; 记录时会话行还在（记录层只判会话 ID 有无），随后删掉会话行模拟孤儿 session_id
        (el-chronos-store-record-drift hour 900.0)
        (el-chronos-store-record-function-samples hour "fn" nil "pkg" 1.0 2.0 1)
        (el-chronos-test--exec "DELETE FROM sessions WHERE id = ?"
                               (list el-chronos--session-id))
        (should (el-chronos-store-flush))
        (should (= 0 (el-chronos-test--count "hourly_drift")))
        ;; 既有表不受影响（既有行为一行不改）
        (should (= 1 (el-chronos-test--count "hourly_functions")))
        ;; 每进程只告警一次，且只一次
        (should (= 1 (length messages)))
        (should (string-match-p "hourly_drift" (car messages)))
        (should el-chronos-store--aggregate-orphan-warned))
      ;; 本批随成功路径清空，不会在下一轮重复尝试
      (should (= 0 (hash-table-count el-chronos-store--drift))))))

(ert-deftest el-chronos-store-test-flush-clears-drift-after-commit ()
  "flush 成功后 `--drift` 清空（它是 `--clear-aggregates' 的第七个容器）。
漏清 → 同一批数据在下一次 flush 被重复累加（count 与 total_ms 翻倍，且不报错）。"
  (el-chronos-test-with-db
    (let ((hour (el-chronos-test--hour-ts)))
      (el-chronos-store-record-drift hour 700.0)
      (should (el-chronos-store-flush))
      (should (= 0 (hash-table-count el-chronos-store--drift)))
      (should-not (el-chronos-store--pending-p)))))

(ert-deftest el-chronos-store-test-close-clears-drift ()
  "`close' 之后 `--drift` 不残留（I5 零残留）。
把 flush 打桩掉，才能区分「close 自己清的」与「close 首行 flush 顺带消费掉的」。"
  (el-chronos-test-with-db
    (el-chronos-store-record-drift (el-chronos-test--hour-ts) 600.0)
    (should (= 1 (hash-table-count el-chronos-store--drift)))
    (cl-letf (((symbol-function 'el-chronos-store-flush) #'ignore))
      (el-chronos-store-close))
    (should (= 0 (hash-table-count el-chronos-store--drift)))))

(ert-deftest el-chronos-store-test-aggregates-pending-p-includes-drift ()
  "`--aggregates-pending-p' 必须把 `--drift` 算在内（四个新容器全覆盖）。
它是「会话未知时是否要告警」的判据：漏掉 drift 会让「只有 drift 待写且会话行不存在」时
既不写行也不告警 —— 用户以为写成功、实际整批跳过。
末尾反证：清空 drift 后判据立刻为假，说明真值确实来自 drift 而非别的容器。"
  (el-chronos-test-with-db
    (el-chronos-store-record-drift (el-chronos-test--hour-ts) 550.0)
    (should (= 1 (hash-table-count el-chronos-store--drift)))
    (should (= 0 (hash-table-count el-chronos-store--gc)))
    (should (= 0 (hash-table-count el-chronos-store--health)))
    (should (= 0 (hash-table-count el-chronos-store--startup)))
    (should (el-chronos-store--aggregates-pending-p))
    (setq el-chronos-store--drift (make-hash-table :test #'equal))
    (should-not (el-chronos-store--aggregates-pending-p))))

;;; 自监控计数（T5）

(ert-deftest el-chronos-store-test-flush-counter-not-cleared-by-clear-aggregates ()
  "直接调 `--clear-aggregates' 后 7 个自监控计数器**一个也不变**。
这是「独立 defvar」的反向验证正面形态：一旦把它们塞进被清空的容器
（`--usage' / `--health' ... 或直接挂 `--buffer' / `--slow-events'），本用例必红 ——
那正是「flush 失败把失败计数一并抹掉」的退化路径，也是设计 §6「已知悖论」的核心陷阱。
T1/T2 新增的 `--busy-retries' / `--flush-lock-streak' 一并断言：它们是同一族标量，
被 `--clear-aggregates' 清掉会让「撞锁发生过」这件事在第一次 flush 失败后即消失。"
  (el-chronos-test-with-db
    (setq el-chronos-store--dropped-commands 3
          el-chronos-store--dropped-events 2
          el-chronos-store--flush-failures 1
          el-chronos-store--flush-count 4
          el-chronos-store--flush-ms-total 12.5
          el-chronos-store--busy-retries 6
          el-chronos-store--flush-lock-streak 2)
    (el-chronos-store--clear-aggregates)
    (should (= 3 el-chronos-store--dropped-commands))
    (should (= 2 el-chronos-store--dropped-events))
    (should (= 1 el-chronos-store--flush-failures))
    (should (= 4 el-chronos-store--flush-count))
    (should (= 12.5 el-chronos-store--flush-ms-total))
    (should (= 6 el-chronos-store--busy-retries))
    (should (= 2 el-chronos-store--flush-lock-streak))
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
  "`store-close' 清空 7 个自监控计数器，且**不依赖** `--clear-aggregates'（两者分离）。
做两件事让「close 清零」不与「flush 上报后归零」混淆：① 关句柄使 close 首行的 flush
早退（否则计数会被正常上报）；② 把 `--clear-aggregates' 整个 cl-letf 成空操作。
T1/T2 新增的 `--busy-retries' / `--flush-lock-streak' 一并断言：它们若残留，同进程
重开库（新会话）时会带着上一轮的撞锁 streak 进来，第一次撞锁就可能直接越过
`--max-lock-retries' 而丢弃整批。"
  (el-chronos-test-with-db
    (setq el-chronos-store--dropped-commands 3
          el-chronos-store--dropped-events 2
          el-chronos-store--flush-failures 1
          el-chronos-store--flush-count 4
          el-chronos-store--flush-ms-total 12.5
          el-chronos-store--busy-retries 5
          el-chronos-store--flush-lock-streak 3)
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
    (should (= 0.0 el-chronos-store--flush-ms-total))
    (should (= 0 el-chronos-store--busy-retries))
    (should (= 0 el-chronos-store--flush-lock-streak))))

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

;;; 进程资源聚合（v4：hourly_resources）

(ert-deftest el-chronos-store-test-record-resources-accumulates-and-max-wins ()
  "同键两次 record：`cpu_ms' / `wall_ms' / `load*_sum' 累加，`rss_kb_max' /
`threads_max' 取大，`rss_kb_sum' 累加，`load_n' 每次有负载样本 +1；
第二次的可空字段传 nil（模拟「本窗口没采到该指标」）不得把已有值抹成 NULL。
锁住 `--sql-upsert-resources' 的三组列语义（累加 / 取最值 / 条件累加）与 NULL 保旧值：
把取最值写成普通覆盖、或把条件累加写成裸加法（任一侧 NULL 即得 NULL），本用例即红。"
  (el-chronos-test-with-db
    (let ((hour (el-chronos-test--hour-ts)))
      (el-chronos-store-record-resources
       hour (list :cpu-ms 120.0 :wall-ms 500.0 :rss-kb-max 81920 :rss-kb-sum 409600
                  :threads-max 12 :load1-sum 1.5 :load5-sum 1.2 :load15-sum 0.9))
      (el-chronos-store-record-resources
       hour (list :cpu-ms 80.0 :wall-ms 300.0))
      (should (= 1 (hash-table-count el-chronos-store--resources)))
      (should (el-chronos-store-flush))
      (should (= 1 (el-chronos-test--count "hourly_resources")))
      (let ((row (car (sqlite-select
                       el-chronos-store--db
                       (concat "SELECT cpu_ms, wall_ms, rss_kb_max, rss_kb_sum,"
                               " threads_max, load1_sum, load5_sum, load15_sum, load_n"
                               " FROM hourly_resources")
                       nil))))
        (should (= 200.0 (nth 0 row)))    ; cpu 累加
        (should (= 800.0 (nth 1 row)))    ; wall 累加
        (should (= 81920 (nth 2 row)))    ; rss 峰值保旧值（第二批传 nil）
        (should (= 409600 (nth 3 row)))   ; rss 总和保旧值
        (should (= 12 (nth 4 row)))       ; 线程数峰值保旧值
        (should (= 1.5 (nth 5 row)))      ; load1 保旧值
        (should (= 1.2 (nth 6 row)))
        (should (= 0.9 (nth 7 row)))
        (should (= 1 (nth 8 row)))))      ; 只有第一批带负载 → load_n = 1
    ;; 第三批：带**更大**的峰值与一个负载样本 —— 峰值取大、load_n 再 +1（跨批次同一保证）
    (el-chronos-store-record-resources
     (el-chronos-test--hour-ts)
     (list :rss-kb-max 90000 :threads-max 16
           :load1-sum 0.5 :load5-sum 0.4 :load15-sum 0.3))
    (should (el-chronos-store-flush))
    (should (= 2 (el-chronos-test--scalar "SELECT load_n FROM hourly_resources")))
    (should (= 2.0 (el-chronos-test--scalar "SELECT load1_sum FROM hourly_resources")))
    (should (= 200.0 (el-chronos-test--scalar "SELECT cpu_ms FROM hourly_resources")))
    ;; 峰值取大（跨批次）：把 `rss_kb_max' 写成普通覆盖不会红（本批更大），
    ;; 故上一批已锁住「较小值不覆盖」，两条合起来才完整覆盖「取标量 MAX」。
    (should (= 90000 (el-chronos-test--scalar "SELECT rss_kb_max FROM hourly_resources")))
    (should (= 16 (el-chronos-test--scalar "SELECT threads_max FROM hourly_resources")))))

(ert-deftest el-chronos-store-test-record-resources-ignores-empty-plist ()
  "全部字段为空（或缺省）时不建行、不报错：一行全 0 的资源数据没有信息量，
还会让「这一小时到底有没有采到资源」在查询层不可区分（I6：不抛错）。"
  (el-chronos-test-with-db
    (let ((hour (el-chronos-test--hour-ts)))
      (should-not (el-chronos-store-record-resources hour nil))
      (should-not (el-chronos-store-record-resources
                   hour (list :cpu-ms "120" :rss-kb-max 'big)))
      (should (= 0 (hash-table-count el-chronos-store--resources)))
      (should-not (el-chronos-store--pending-p))
      ;; 单个合法字段就能建行（守卫没有误伤正常输入）
      (should (el-chronos-store-record-resources hour (list :rss-kb-max 4096)))
      (should (= 1 (hash-table-count el-chronos-store--resources))))))

(ert-deftest el-chronos-store-test-flush-runs-when-only-resources-pending ()
  "只有资源聚合待写时 flush 也必须执行（锁 `--pending-p' 与 `--aggregates-pending-p'
里的 `--resources'）。
漏掉前者 → flush 第一道门 `(and db (--pending-p))' 早退 → 资源数据永不落库且**无任何报错**；
漏掉后者 → 会话行不存在时既不写行也不告警。资源采样本质稀疏（每 N 秒一条窗口），
「只有 resources 待写」是常态而非边缘情况。"
  (el-chronos-test-with-db
    (let ((hour (el-chronos-test--hour-ts)))
      (should (null el-chronos-store--buffer))
      (should (null el-chronos-store--slow-events))
      (should (= 0 (hash-table-count el-chronos-store--usage)))
      (should (= 0 (hash-table-count el-chronos-store--functions)))
      (should (= 0 (hash-table-count el-chronos-store--stacks)))
      (should (= 0 (hash-table-count el-chronos-store--gc)))
      (should (= 0 (hash-table-count el-chronos-store--health)))
      (should (= 0 (hash-table-count el-chronos-store--startup)))
      (should (= 0 (hash-table-count el-chronos-store--drift)))
      (should-not el-chronos-store--pending-startup-ms)
      (el-chronos-store-record-resources hour (list :cpu-ms 10.0 :wall-ms 40.0))
      (should (= 1 (hash-table-count el-chronos-store--resources)))
      (should (el-chronos-store--pending-p))
      (should (el-chronos-store--aggregates-pending-p))
      (should (el-chronos-store-flush))
      (should (= 1 (el-chronos-test--count "hourly_resources")))
      (should (= 0 (hash-table-count el-chronos-store--resources)))
      (should-not (el-chronos-store--pending-p)))))

(ert-deftest el-chronos-store-test-close-clears-resources ()
  "`close' 之后 `--resources' 不残留（I5 零残留）。
把 flush 打桩掉，才能区分「close 自己清的」与「close 首行 flush 顺带消费掉的」。"
  (el-chronos-test-with-db
    (el-chronos-store-record-resources (el-chronos-test--hour-ts)
                                       (list :cpu-ms 5.0 :wall-ms 20.0))
    (should (= 1 (hash-table-count el-chronos-store--resources)))
    (cl-letf (((symbol-function 'el-chronos-store-flush) #'ignore))
      (el-chronos-store-close))
    (should (= 0 (hash-table-count el-chronos-store--resources)))))

(ert-deftest el-chronos-store-test-purge-empties-hourly-resources ()
  "无参 `purge' 把 `hourly_resources' 清空，且重建的当前会话行不受影响。
它是**永久保留**类表（`--prune' 不碰），唯一清理入口就是 purge —— 若漏在
`--purge-targets' 清单里，资源数据会永久残留且不报错，用户以为隐私清理已生效。"
  (el-chronos-store-test--with-hermetic-db
    (let ((hour (el-chronos-test--hour-ts))
          (session el-chronos--session-id))
      (el-chronos-test--exec "INSERT INTO hourly_resources (hour_ts, session_id,\
 cpu_ms, wall_ms, rss_kb_max, rss_kb_sum, threads_max, load1_sum, load5_sum,\
 load15_sum, load_n) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
                             (list hour session 100.0 400.0 40960 204800 8
                                   1.0 0.9 0.8 1))
      (should (= 1 (el-chronos-test--count "hourly_resources")))
      (let ((result (el-chronos-purge)))
        (should (= 13 (length result)))
        (should (assoc "hourly_resources" result))
        (should (= 1 (cdr (assoc "hourly_resources" result)))))
      (should (= 0 (el-chronos-test--count "hourly_resources")))
      (should (= 1 (el-chronos-test--count "sessions"))))))

(ert-deftest el-chronos-store-test-hourly-resources-has-no-foreign-key ()
  "`hourly_resources' 不写外键（与既有 hourly_* 及 v2 / v3 各表一致）。
加上 `REFERENCES sessions(id)' 会让 purge 删除顺序、级联删除与 `foreign_keys=ON'
三者耦合 —— 删会话行要么撞外键（整批回滚）要么静默级联删掉聚合数据。
判据：`PRAGMA foreign_key_list(hourly_resources)' 为空，且直接删会话行不报错。"
  (el-chronos-store-test--with-hermetic-db
    (should (null (sqlite-select el-chronos-store--db
                                 "PRAGMA foreign_key_list(hourly_resources)")))
    (let ((id (el-chronos-test--insert-session (el-chronos-test--now-ms))))
      (el-chronos-test--exec "INSERT INTO hourly_resources (hour_ts, session_id,\
 cpu_ms, wall_ms) VALUES (?, ?, ?, ?)"
                             (list (el-chronos-test--hour-ts) id 10.0 20.0))
      (el-chronos-test--exec "DELETE FROM sessions WHERE id = ?" (list id))
      (should (= 1 (el-chronos-test--count "hourly_resources"))))))

(ert-deftest el-chronos-store-test-prune-does-not-touch-hourly-resources ()
  "自动 retention（`--prune'）不碰 `hourly_resources'：即使行的时间戳远早于保留阈值，
也一行不动（资源聚合永久保留，只由 purge 清理）。
过期明细行是本用例的前置条件：没有候选时 `--prune' 按候选预检**不开写事务**，
「没碰聚合表」就成了空断言。"
  (el-chronos-store-test--with-hermetic-db
    (let* ((old 1000)                   ; 远早于 30 天保留阈值
           (old-id (el-chronos-test--insert-session old)))
      (el-chronos-test--insert-command old "ancient" 5.0)
      (el-chronos-test--exec "INSERT INTO hourly_resources (hour_ts, session_id,\
 cpu_ms, wall_ms, load_n) VALUES (?, ?, ?, ?, ?)"
                             (list old old-id 50.0 200.0 1))
      (should (el-chronos-store-test--prune-now))
      (should (= 0 (el-chronos-test--scalar
                    "SELECT count(*) FROM commands WHERE name = 'ancient'")))
      (should (= 1 (el-chronos-test--count "hourly_resources"))))))

;;; GC 归因聚合（v5：hourly_gc_attrib）

(ert-deftest el-chronos-store-test-record-gc-attrib-accumulates ()
  "同键两次 record：`gc_count' 与 `gc_ms' **都累加**，落库只有一行。
锁住 `--sql-upsert-gc-attrib' 的 `ON CONFLICT' 目标必须命中**完整四列主键**
（hour_ts, session_id, command, mode）：只写部分列时 SQLite 会报错（可见失败），
而把两列写成覆盖时本用例的后半段会因 gc_ms 只剩最后一批而红。"
  (el-chronos-test-with-db
    (let ((hour (el-chronos-test--hour-ts))
          (session el-chronos--session-id))
      (el-chronos-store-record-gc-attrib hour session "save-buffer" "emacs-lisp-mode"
                                         2 10.0)
      (el-chronos-store-record-gc-attrib hour session "save-buffer" "emacs-lisp-mode"
                                         3 20.0)
      (should (= 1 (hash-table-count el-chronos-store--gc-attrib)))
      (should (el-chronos-store--pending-p))
      (should (el-chronos-store--aggregates-pending-p))
      (should (el-chronos-store-flush))
      (should (= 1 (el-chronos-test--count "hourly_gc_attrib")))
      (should (= 5 (el-chronos-test--scalar "SELECT gc_count FROM hourly_gc_attrib")))
      (should (= 30.0 (el-chronos-test--scalar "SELECT gc_ms FROM hourly_gc_attrib")))
      ;; flush 之后缓冲清空（`--clear-aggregates'），不会重复累加
      (should (= 0 (hash-table-count el-chronos-store--gc-attrib)))
      (should-not (el-chronos-store--pending-p))
      (el-chronos-store-flush)          ; 无待写数据时是空操作（返回 nil，不算失败）
      (should (= 5 (el-chronos-test--scalar "SELECT gc_count FROM hourly_gc_attrib")))
      ;; 换 mode 就是另一个桶：主键的另外两列确实参与去重
      (el-chronos-store-record-gc-attrib hour session "save-buffer" "prog-mode" 1 4.0)
      (should (el-chronos-store-flush))
      (should (= 2 (el-chronos-test--count "hourly_gc_attrib")))
      (should (= 6 (el-chronos-test--scalar
                    "SELECT sum(gc_count) FROM hourly_gc_attrib"))))))

(ert-deftest el-chronos-store-test-record-gc-attrib-normalizes-none-and-symbol ()
  "COMMAND / MODE 的归一：nil → \"<none>\"，symbol `foo' → \"foo\"，string 原样；
两次 nil 写入累加到**同一行**（证明主键归一有效），symbol 与同名字符串也合并。
锁住 `--attrib-label' 与 DDL 的 `NOT NULL'：主键列一旦被写入 NULL，SQL 的「NULL 互不
相等」会让同一组合变成多行，本用例的「一行 + 计数累加」断言即红。"
  (el-chronos-test-with-db
    (let ((hour (el-chronos-test--hour-ts))
          (session el-chronos--session-id))
      ;; nil / nil：启动期没有 this-command、也没有 mode
      (el-chronos-store-record-gc-attrib hour session nil nil 1 1.0)
      (el-chronos-store-record-gc-attrib hour session nil nil 1 2.0)
      ;; symbol / symbol：`this-command' 与 `major-mode' 的常态
      (el-chronos-store-record-gc-attrib hour session 'foo 'emacs-lisp-mode 2 3.0)
      ;; string / string：与上面的 symbol 同名 → 同一行
      (el-chronos-store-record-gc-attrib hour session "foo" "emacs-lisp-mode" 1 4.0)
      (should (= 2 (hash-table-count el-chronos-store--gc-attrib)))
      (should (el-chronos-store-flush))
      (should (= 2 (el-chronos-test--count "hourly_gc_attrib")))
      ;; nil → \"<none>\"，且两次累加到一行
      (should (= 2 (el-chronos-test--scalar
                    "SELECT gc_count FROM hourly_gc_attrib\
 WHERE command = '<none>' AND mode = '<none>'")))
      (should (= 3.0 (el-chronos-test--scalar
                      "SELECT gc_ms FROM hourly_gc_attrib\
 WHERE command = '<none>'")))
      ;; symbol 与同名字符串合并到同一行（3 次 GC）
      (should (= 3 (el-chronos-test--scalar
                    "SELECT gc_count FROM hourly_gc_attrib WHERE command = 'foo'")))
      (should (= 7.0 (el-chronos-test--scalar
                      "SELECT gc_ms FROM hourly_gc_attrib WHERE command = 'foo'")))
      ;; 库里没有 NULL 行（主键列 NOT NULL）
      (should (= 0 (el-chronos-test--scalar
                    "SELECT count(*) FROM hourly_gc_attrib\
 WHERE command IS NULL OR mode IS NULL"))))))

(ert-deftest el-chronos-store-test-record-gc-attrib-skips-invalid-input ()
  "脏输入一律跳过、不抛错、不入缓冲（I6）。
HOUR-TS 非数值尤其必须挡住：它会被绑进 NOT NULL 主键列，一条脏输入就会让**整批**
flush 撞 `NOT NULL constraint failed' 回滚（一批已采数据全丢）。"
  (el-chronos-test-with-db
    (let ((hour (el-chronos-test--hour-ts))
          (session el-chronos--session-id))
      (should-not (el-chronos-store-record-gc-attrib nil session "c" "m" 1 1.0))
      (should-not (el-chronos-store-record-gc-attrib "hour" session "c" "m" 1 1.0))
      (should-not (el-chronos-store-record-gc-attrib hour session "c" "m" 0 1.0))
      (should-not (el-chronos-store-record-gc-attrib hour session "c" "m" -3 1.0))
      (should-not (el-chronos-store-record-gc-attrib hour session "c" "m" "2" 1.0))
      (should (= 0 (hash-table-count el-chronos-store--gc-attrib)))
      (should-not (el-chronos-store--pending-p))
      ;; GC-MS 脏值只把时长按 0 处理，次数仍然有价值
      (should (el-chronos-store-record-gc-attrib hour session "c" "m" 1 nil))
      (should (= 1 (hash-table-count el-chronos-store--gc-attrib)))
      (should (el-chronos-store-flush))
      (should (= 1 (el-chronos-test--scalar "SELECT gc_count FROM hourly_gc_attrib")))
      (should (= 0.0 (el-chronos-test--scalar "SELECT gc_ms FROM hourly_gc_attrib")))
      ;; 会话 ID 缺失：跳过（按 `--aggregate-session' 每进程告警一次）
      (let ((el-chronos--session-id nil))
        (should-not (el-chronos-store-record-gc-attrib hour nil "c" "m" 1 1.0))))))

(ert-deftest el-chronos-store-test-record-gc-attrib-skips-unknown-session ()
  "会话行不存在的 session_id：不抛错、不写行。
`hourly_gc_attrib' 无外键，DB 不会替我们挡孤儿行；flush 的批次级守卫只对**当前会话**
判一次，故本表在落库时再比对键里的会话，不符即跳过（否则孤儿行 purge 删不掉）。"
  (el-chronos-test-with-db
    (let* ((hour (el-chronos-test--hour-ts))
           (ghost 999999))
      (should (el-chronos-store-record-gc-attrib hour ghost "c" "m" 4 8.0))
      (should (= 1 (hash-table-count el-chronos-store--gc-attrib)))
      (should (el-chronos-store-flush))
      (should (= 0 (el-chronos-test--count "hourly_gc_attrib")))
      ;; 缓冲照样被清空（本批已处理），不会无界增长
      (should (= 0 (hash-table-count el-chronos-store--gc-attrib)))
      ;; 当前会话的行照常写入（守卫没有把正常路径一起挡掉）
      (el-chronos-store-record-gc-attrib hour el-chronos--session-id "c" "m" 1 1.0)
      (should (el-chronos-store-flush))
      (should (= 1 (el-chronos-test--count "hourly_gc_attrib"))))))

(ert-deftest el-chronos-store-test-flush-runs-when-only-gc-attrib-pending ()
  "只有 GC 归因待写时 flush 也必须执行（锁 `--pending-p' 与 `--aggregates-pending-p'
里的 `--gc-attrib'）。
漏掉前者 → flush 第一道门 `(and db (--pending-p))' 早退 → 归因数据永不落库且**无任何
报错**；漏掉后者 → 会话行不存在时既不写行也不告警。"
  (el-chronos-test-with-db
    (let ((hour (el-chronos-test--hour-ts)))
      (should (null el-chronos-store--buffer))
      (should (null el-chronos-store--slow-events))
      (should (= 0 (hash-table-count el-chronos-store--gc)))
      (should (= 0 (hash-table-count el-chronos-store--drift)))
      (should (= 0 (hash-table-count el-chronos-store--resources)))
      (should-not el-chronos-store--pending-startup-ms)
      (el-chronos-store-record-gc-attrib hour el-chronos--session-id "c" "m" 1 1.0)
      (should (= 1 (hash-table-count el-chronos-store--gc-attrib)))
      (should (el-chronos-store--pending-p))
      (should (el-chronos-store--aggregates-pending-p))
      (should (el-chronos-store-flush))
      (should (= 1 (el-chronos-test--count "hourly_gc_attrib")))
      (should-not (el-chronos-store--pending-p)))))

(ert-deftest el-chronos-store-test-close-clears-gc-attrib ()
  "`close' 之后 `--gc-attrib' 不残留（I5 零残留）。
把 flush 打桩掉，才能区分「close 自己清的」与「close 首行 flush 顺带消费掉的」。"
  (el-chronos-test-with-db
    (el-chronos-store-record-gc-attrib (el-chronos-test--hour-ts)
                                       el-chronos--session-id "c" "m" 1 1.0)
    (should (= 1 (hash-table-count el-chronos-store--gc-attrib)))
    (cl-letf (((symbol-function 'el-chronos-store-flush) #'ignore))
      (el-chronos-store-close))
    (should (= 0 (hash-table-count el-chronos-store--gc-attrib)))))

(ert-deftest el-chronos-store-test-purge-empties-hourly-gc-attrib ()
  "无参 `purge' 把 `hourly_gc_attrib' 清空，且重建的当前会话行不受影响。
它是**永久保留**类表（`--prune' 不碰），唯一清理入口就是 purge —— 若漏在
`--purge-targets' 清单里，GC 归因会永久残留且不报错，用户以为隐私清理已生效。"
  (el-chronos-store-test--with-hermetic-db
    (let ((hour (el-chronos-test--hour-ts))
          (session el-chronos--session-id))
      (el-chronos-test--exec "INSERT INTO hourly_gc_attrib (hour_ts, session_id,\
 command, mode, gc_count, gc_ms) VALUES (?, ?, ?, ?, ?, ?)"
                             (list hour session "save-buffer" "emacs-lisp-mode" 2 12.0))
      (should (= 1 (el-chronos-test--count "hourly_gc_attrib")))
      (let ((result (el-chronos-purge)))
        (should (= 13 (length result)))
        (should (assoc "hourly_gc_attrib" result))
        (should (= 1 (cdr (assoc "hourly_gc_attrib" result)))))
      (should (= 0 (el-chronos-test--count "hourly_gc_attrib")))
      (should (= 1 (el-chronos-test--count "sessions"))))))

(ert-deftest el-chronos-store-test-prune-does-not-touch-hourly-gc-attrib ()
  "自动 retention（`--prune'）不碰 `hourly_gc_attrib'：即使行的 `hour_ts' 远早于保留
阈值，也一行不动（归因聚合永久保留，只由 purge 清理）。
过期明细行是本用例的前置条件：没有候选时 `--prune' 按候选预检**不开写事务**，
那样「没碰聚合表」就是空断言 —— 有候选、真跑了 DELETE，才证明它只删了明细这两张表。"
  (el-chronos-store-test--with-hermetic-db
    (let* ((old 1000)                   ; 远早于 30 天保留阈值
           (old-id (el-chronos-test--insert-session old)))
      (el-chronos-test--insert-command old "ancient" 5.0)
      (el-chronos-test--exec "INSERT INTO hourly_gc_attrib (hour_ts, session_id,\
 command, mode, gc_count, gc_ms) VALUES (?, ?, ?, ?, ?, ?)"
                             (list old old-id "c" "m" 1 1.0))
      (should (el-chronos-store-test--prune-now))
      (should (= 0 (el-chronos-test--scalar
                    "SELECT count(*) FROM commands WHERE name = 'ancient'")))
      (should (= 1 (el-chronos-test--count "hourly_gc_attrib"))))))

(ert-deftest el-chronos-store-test-hourly-gc-attrib-has-no-foreign-key ()
  "`hourly_gc_attrib' 不写外键（与既有 hourly_* 及 v2 / v3 / v4 各表一致）。
加上 `REFERENCES sessions(id)' 会让 purge 删除顺序、级联删除与 `foreign_keys=ON'
三者耦合 —— 删会话行要么撞外键（整批回滚）要么静默级联删掉聚合数据。
判据：`PRAGMA foreign_key_list(hourly_gc_attrib)' 为空，且直接删会话行不报错。"
  (el-chronos-store-test--with-hermetic-db
    (should (null (sqlite-select el-chronos-store--db
                                 "PRAGMA foreign_key_list(hourly_gc_attrib)")))
    (let ((id (el-chronos-test--insert-session (el-chronos-test--now-ms))))
      (el-chronos-test--exec "INSERT INTO hourly_gc_attrib (hour_ts, session_id,\
 command, mode, gc_count, gc_ms) VALUES (?, ?, ?, ?, ?, ?)"
                             (list (el-chronos-test--hour-ts) id "c" "m" 1 1.0))
      (el-chronos-test--exec "DELETE FROM sessions WHERE id = ?" (list id))
      (should (= 1 (el-chronos-test--count "hourly_gc_attrib"))))))

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

;;; 多实例并发写：busy-retries 上报（D6 / T6）

;; `busy-retries` 与 `flush-failures` 同一机制、同一 `cond` 分支族：快照在事务前取，
;; COMMIT 成功后按快照减去已上报部分。两条额外约束：
;;   ① 它**必须**进 `--pending-p` —— D1 路径（open 期建会话行撞锁）只 +1 计数器、不产生
;;      任何采集数据，「只有 busy-retries 待上报」是常态；漏了它这个计数就永不落库。
;;   ② 它是中性度量，不进 `--health-bad-keys`（锁竞争被自愈也会上升），故库里该键非 0
;;      不代表采集异常 —— 判读按路径分：**D1 路径**（open 期建会话行撞锁）看
;;      「busy-retries 升而 flush-failures 不升 = 自愈生效」；**D2 路径**（flush 写批撞锁）
;;      这两个数会同时升，判据改为 `dropped-commands` / `dropped-events` 是否跟涨。

(ert-deftest el-chronos-store-test-busy-retries-reported-after-successful-flush ()
  "撞锁 → `--busy-retries' 为 1 且库内无该键（事务已回滚）；随后成功 flush 把它写进
`hourly_health' 并把内存计数器扣回 0。
扣回而不是置 0：事务期间新发生的撞锁必须留住，置 0 会把它们静默吞掉。"
  (el-chronos-test-with-db
    (let ((original (symbol-function 'sqlite-execute)))
      (el-chronos-store-record-command (list :name "contended" :duration-ms 1.0))
      (cl-letf (((symbol-function 'sqlite-execute)
                 (lambda (db sql &rest args)
                   (if (string-match-p "COMMIT" sql)
                       (signal 'sqlite-locked-error '("database is locked"))
                     (apply original db sql args)))))
        (should-not (el-chronos-store-flush)))
      (should (= 1 el-chronos-store--busy-retries))
      ;; 事务被 ROLLBACK：连自监控行也没进库
      (should (= 0 (el-chronos-test--count "hourly_health")))
      ;; 解除注入后重试成功 → 该键才落库，且内存计数器被扣回 0
      ;; **F2 起语义变化**：撞锁置了 30 秒退避，紧随其后的 flush 会早退；本用例要验的是
      ;; 「成功 flush 时才上报并扣回」，故把退避推到过去（生产里 ~35 秒后 timer 再触发）。
      (setq el-chronos-store--flush-backoff-until nil)
      (should (el-chronos-store-flush))
      (should (= 1 (el-chronos-test--scalar
                    "SELECT value FROM hourly_health WHERE key = 'busy-retries'")))
      (should (= 0 el-chronos-store--busy-retries))
      (should (= 1 (el-chronos-test--scalar
                    "SELECT value FROM hourly_health WHERE key = 'flush-failures'"))))))

(ert-deftest el-chronos-store-test-pending-p-includes-busy-retries ()
  "只有 `--busy-retries' 非零时 `--pending-p' 必须为真，且 flush **真的执行**（不是早退）。
这是 D1 路径的落库唯一入口：open 期 `--ensure-session-quiet' 撞锁 → 计数 +1，此后可能
长时间无任何采集数据（空闲会话），若该计数不进 `--pending-p'，flush timer 每次都判定
「无待写数据」直接早退，这个计数永远不会上报、修复效果永远不可量化。"
  (el-chronos-test-with-db
    (should-not (el-chronos-store--pending-p))
    (setq el-chronos-store--busy-retries 2)
    (should (el-chronos-store--pending-p))
    (should (el-chronos-store-flush))
    (should (= 2 (el-chronos-test--scalar
                  "SELECT value FROM hourly_health WHERE key = 'busy-retries'")))
    (should (= 0 el-chronos-store--busy-retries))))

(ert-deftest el-chronos-store-test-busy-timeout-skipped-when-no-pending ()
  "无待写数据时 flush **不进** write-timeout 包裹，也不打开任何 pragma。
否则 5 秒一次的 flush timer 每轮都白跑两次 `sqlite-pragma'（抬 8000 + 恢复 2000），
而这两次往返对它要做的「什么都不做」毫无帮助。"
  (el-chronos-test-with-db
    (let ((pragmas nil)
          (original (symbol-function 'sqlite-pragma)))
      (should-not (el-chronos-store--pending-p))
      (cl-letf (((symbol-function 'sqlite-pragma)
                 (lambda (db pragma)
                   (when (string-prefix-p "busy_timeout" pragma)
                     (push pragma pragmas))
                   (funcall original db pragma))))
        (should-not (el-chronos-store-flush)))
      (should-not pragmas)
      ;; 句柄仍是默认 2000（没有残留的 8000）
      (should (= 2000 (caar (sqlite-select el-chronos-store--db
                                           "PRAGMA busy_timeout")))))))

;;; 行为对齐：close 绕过退避（B1）与丢弃可判读（S1）

(ert-deftest el-chronos-store-test-close-bypasses-flush-backoff ()
  "撞锁退避未到期时 `store-close' 仍必须尽力 flush 一次（B1）。
锁住「退避只节流**周期性** flush，不该拦住退出前的最后一次写」：撞锁后本批是**保留**的，
close 若被退避门早退，紧随其后的 `setq' 会把这批数据静默丢掉（无告警、无计数），与
close docstring 的承诺相悖。改造前本用例的 `commands` 行数为 0。"
  (el-chronos-test-with-db
    (let ((hour (el-chronos-test--hour-ts))
          (original (symbol-function 'sqlite-execute)))
      (el-chronos-store-record-command (list :name "kept-at-close" :duration-ms 7.0))
      (el-chronos-store-record-slow-event (list :duration-ms 900.0 :kind "block"))
      (el-chronos-store-record-usage hour 'command "kept-at-close" 1 7.0)
      ;; 一次撞锁：本批保留、退避置位（30 秒窗口内），库里没有任何半批数据
      (cl-letf (((symbol-function 'sqlite-execute)
                 (lambda (db sql &rest args)
                   (if (string-match-p "COMMIT" sql)
                       (signal 'sqlite-locked-error '("database is locked"))
                     (apply original db sql args)))))
        (should-not (el-chronos-store-flush)))
      (should el-chronos-store--buffer)
      (should el-chronos-store--slow-events)
      (should (el-chronos-store--flush-backoff-active-p))
      (should (= 0 (el-chronos-test--count "commands")))
      ;; 注入已解除、退避仍未到期：close 必须绕过退避写一次
      (el-chronos-store-close)
      (should (el-chronos-store-open el-chronos-db-path))
      (should (= 1 (el-chronos-test--count "commands")))
      (should (= 1 (el-chronos-test--count "slow_events")))
      (should (= 1 (el-chronos-test--count "hourly_usage")))
      ;; 撞锁计数正确：一次撞锁随 close 的那次 flush 上报（内存计数器由 close 归零，
      ;; 库里的累计值是唯一证据）
      (should (= 1 (el-chronos-test--scalar
                    "SELECT value FROM hourly_health WHERE key = 'flush-failures'")))
      (should (= 1 (el-chronos-test--scalar
                    "SELECT value FROM hourly_health WHERE key = 'busy-retries'")))
      ;; 没有任何数据被丢弃（自愈路径不写 dropped-*）
      (should-not (el-chronos-test--scalar
                   "SELECT value FROM hourly_health WHERE key = 'dropped-commands'")))))

(ert-deftest el-chronos-store-test-locked-discard-counts-dropped ()
  "撞锁达到上限丢弃本批时，丢弃条数必须记进 `--dropped-commands' / `--dropped-events'（S1）。
锁住判读口径的另一半：撞锁分支对 `busy-retries' 与 `flush-failures' **同时 +1**，
保留重试与真丢弃在计数器上完全一样 —— 没有本用例的两个数，操作者无法判断「数据丢没丢」。
条数口径为**缓冲长度**（明细 + 慢事件各按自己的计数），故造 2 命令 + 3 慢事件。"
  (el-chronos-test-with-db
    (let ((original (symbol-function 'sqlite-execute)))
      (el-chronos-store-record-command (list :name "c1" :duration-ms 1.0))
      (el-chronos-store-record-command (list :name "c2" :duration-ms 1.0))
      (dotimes (i 3)
        (el-chronos-store-record-slow-event
         (list :duration-ms (+ 500.0 i) :kind "block")))
      (cl-letf (((symbol-function 'sqlite-execute)
                 (lambda (db sql &rest args)
                   (if (string-match-p "COMMIT" sql)
                       (signal 'sqlite-locked-error '("database is locked"))
                     (apply original db sql args)))))
        (dotimes (_ (1- el-chronos-store--max-lock-retries))
          ;; 撞锁即置 30 秒退避，紧随其后的 flush 会早退；模拟「退避到期、timer 再触发」
          (setq el-chronos-store--flush-backoff-until nil)
          (should-not (el-chronos-store-flush)))
        ;; 保留重试阶段一条都不计：撞锁本身不是丢弃
        (should (= 0 el-chronos-store--dropped-commands))
        (should (= 0 el-chronos-store--dropped-events))
        ;; 第 6 次：达到上限，本批按计划丢弃
        (setq el-chronos-store--flush-backoff-until nil)
        (should-not (el-chronos-store-flush)))
      (should-not el-chronos-store--buffer)
      (should-not el-chronos-store--slow-events)
      ;; 条数必须在清空缓冲**之前**取，否则恒为 0
      (should (= 2 el-chronos-store--dropped-commands))
      (should (= 3 el-chronos-store--dropped-events))
      (should (= el-chronos-store--max-lock-retries el-chronos-store--flush-failures))
      (should (= el-chronos-store--max-lock-retries el-chronos-store--busy-retries)))))

(ert-deftest el-chronos-store-test-non-lock-discard-counts-dropped ()
  "非锁错误（磁盘满等）丢弃本批时同样累加丢弃条数（S1）。
锁住「两条丢弃路径口径一致」：只给撞锁上限那条路径计数，会让磁盘满时的丢数据在
`hourly_health' 里完全不可见。"
  (el-chronos-test-with-db
    (let ((original (symbol-function 'sqlite-execute)))
      (el-chronos-store-record-command (list :name "disk-full" :duration-ms 5.0))
      (el-chronos-store-record-slow-event (list :duration-ms 800.0 :kind "block"))
      (cl-letf (((symbol-function 'sqlite-execute)
                 (lambda (db sql &rest args)
                   (if (string-match-p "COMMIT" sql)
                       (error "disk full")
                     (apply original db sql args)))))
        (should-not (el-chronos-store-flush)))
      (should-not el-chronos-store--buffer)
      (should-not el-chronos-store--slow-events)
      (should (= 1 el-chronos-store--dropped-commands))
      (should (= 1 el-chronos-store--dropped-events))
      (should (= 1 el-chronos-store--flush-failures)))))

(ert-deftest el-chronos-store-test-locked-retry-does-not-count-dropped ()
  "撞锁保留重试后成功（D2 自愈路径）**不计**丢弃（S1）。
这是判读口径的前一半：`dropped-*` 不升 = 数据没丢，只有它同时升才代表真丢。
若在撞锁分支无条件累加，自愈与丢弃将无法区分，本数就失去诊断价值。"
  (el-chronos-test-with-db
    (let ((original (symbol-function 'sqlite-execute)))
      (el-chronos-store-record-command (list :name "retried" :duration-ms 3.0))
      (el-chronos-store-record-command (list :name "retried-2" :duration-ms 4.0))
      (cl-letf (((symbol-function 'sqlite-execute)
                 (lambda (db sql &rest args)
                   (if (string-match-p "COMMIT" sql)
                       (signal 'sqlite-locked-error '("database is locked"))
                     (apply original db sql args)))))
        (should-not (el-chronos-store-flush)))
      (should (= 1 el-chronos-store--flush-lock-streak))
      (should (= 0 el-chronos-store--dropped-commands))
      (should (= 0 el-chronos-store--dropped-events))
      (setq el-chronos-store--flush-backoff-until nil)
      (should (el-chronos-store-flush))
      (should (= 2 (el-chronos-test--count "commands")))
      ;; 自愈之后仍然一条不丢
      (should (= 0 el-chronos-store--dropped-commands))
      (should (= 0 el-chronos-store--dropped-events))
      (should (= 0 el-chronos-store--flush-lock-streak)))))

(provide 'el-chronos-store-test)

;;; el-chronos-store-test.el ends here
