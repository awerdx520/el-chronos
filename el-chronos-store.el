;;; el-chronos-store.el --- SQLite 存储与聚合落库  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Thomas

;; Author: Thomas
;; Keywords: tools, performance
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; 存储层：schema 与版本迁移、内存缓冲、批量 flush、保留清理与 purge。
;;   - 采集层只调 `-record-*'，一律只进缓冲；flush timer 每 5 秒批量写库（单事务），
;;     失败整体 ROLLBACK 并按计划丢弃本批（内存不无界增长），告警 10 分钟限流，
;;     不向宿主抛错（I6）；
;;   - schema 版本用 `PRAGMA user_version'：迁移前复制 .bak，失败则关句柄并用 .bak
;;     覆盖回原文件，不破坏原库；
;;   - `commands' / `slow_events' 按 `el-chronos-retention-days' 清理，三张 hourly_*
;;     聚合表永久保留、只由 `el-chronos-purge' 手动清理；
;;   - `hourly_stacks' 每 (hour_ts, session_id) 只留 samples 最大的 top-N 条。
;; 单位（I4）：时间戳与耗时用毫秒，采样间隔用纳秒；数据只写 `el-chronos-db-path'。

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'sqlite)
(require 'el-chronos)

;;; 常量

(defconst el-chronos-store--schema-version 1
  "支持的 schema 版本，对应 `PRAGMA user_version'；升级时递增并追加迁移步骤。")
(defconst el-chronos-store--flush-interval-seconds 5
  "缓冲落库间隔（秒）；5 秒把崩溃丢失窗口压在秒级且写库抖动不可见。")
(defconst el-chronos-store--warn-interval-seconds 600
  "同类告警最小间隔（秒）；磁盘满、锁超时等故障会持续，必须限流。")
(defconst el-chronos-store--busy-timeout-ms 2000
  "SQLite 忙等待超时（毫秒）；外部进程短暂持锁时等待而非立即失败。")
(defconst el-chronos-store--max-buffer-items 50000
  "单类缓冲最大条目数；仅兜底，防库长期不可写时内存无界增长。")
(defconst el-chronos-store--schema-ddl "
CREATE TABLE IF NOT EXISTS sessions (id INTEGER PRIMARY KEY AUTOINCREMENT, started_at INTEGER NOT NULL, emacs_version TEXT, host TEXT, startup_ms REAL, gc_threshold REAL);
CREATE TABLE IF NOT EXISTS commands (id INTEGER PRIMARY KEY AUTOINCREMENT, ts INTEGER NOT NULL, session_id INTEGER NOT NULL REFERENCES sessions(id), name TEXT NOT NULL, duration_ms REAL NOT NULL, gc_ms REAL, mode TEXT, project TEXT, outcome TEXT, kind TEXT);
CREATE INDEX IF NOT EXISTS idx_commands_ts ON commands(ts);
CREATE INDEX IF NOT EXISTS idx_commands_duration ON commands(duration_ms DESC);
CREATE TABLE IF NOT EXISTS hourly_functions (hour_ts INTEGER NOT NULL, session_id INTEGER NOT NULL, function TEXT NOT NULL, file TEXT, package TEXT, self_ms REAL NOT NULL DEFAULT 0, total_ms REAL NOT NULL DEFAULT 0, samples INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (hour_ts, session_id, function));
CREATE TABLE IF NOT EXISTS slow_events (id INTEGER PRIMARY KEY AUTOINCREMENT, ts INTEGER NOT NULL, duration_ms REAL NOT NULL, kind TEXT, command TEXT, stack_json TEXT, context_json TEXT);
CREATE INDEX IF NOT EXISTS idx_slow_events_ts ON slow_events(ts);
CREATE TABLE IF NOT EXISTS hourly_usage (hour_ts INTEGER NOT NULL, dimension TEXT NOT NULL, key TEXT NOT NULL, count INTEGER NOT NULL DEFAULT 0, duration_ms REAL NOT NULL DEFAULT 0, PRIMARY KEY (hour_ts, dimension, key));
CREATE TABLE IF NOT EXISTS hourly_stacks (hour_ts INTEGER NOT NULL, session_id INTEGER, stack_hash TEXT NOT NULL, stack_json TEXT NOT NULL, samples INTEGER, PRIMARY KEY (hour_ts, session_id, stack_hash));"
  "建表建索引语句，一次批量执行（幂等）；`commands' 引用 `sessions'，顺序不能改。")
(defconst el-chronos-store--sql-insert-command
  "INSERT INTO commands (ts, session_id, name, duration_ms, gc_ms, mode, project, outcome, kind) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)")
(defconst el-chronos-store--sql-insert-slow-event
  "INSERT INTO slow_events (ts, duration_ms, kind, command, stack_json, context_json) VALUES (?, ?, ?, ?, ?, ?)")
(defconst el-chronos-store--sql-upsert-function
  "INSERT INTO hourly_functions (hour_ts, session_id, function, file, package, self_ms, total_ms, samples) VALUES (?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(hour_ts, session_id, function) DO UPDATE SET self_ms = self_ms + excluded.self_ms, total_ms = total_ms + excluded.total_ms, samples = samples + excluded.samples")
(defconst el-chronos-store--sql-upsert-usage
  "INSERT INTO hourly_usage (hour_ts, dimension, key, count, duration_ms) VALUES (?, ?, ?, ?, ?) ON CONFLICT(hour_ts, dimension, key) DO UPDATE SET count = count + excluded.count, duration_ms = duration_ms + excluded.duration_ms")
(defconst el-chronos-store--sql-upsert-stack
  "INSERT INTO hourly_stacks (hour_ts, session_id, stack_hash, stack_json, samples) VALUES (?, ?, ?, ?, ?) ON CONFLICT(hour_ts, session_id, stack_hash) DO UPDATE SET samples = samples + excluded.samples")
(defconst el-chronos-store--sql-evict-stacks
  "DELETE FROM hourly_stacks WHERE hour_ts = ? AND session_id = ? AND stack_hash NOT IN (SELECT stack_hash FROM hourly_stacks WHERE hour_ts = ? AND session_id = ? ORDER BY samples DESC LIMIT ?)"
  "按 samples 保留 top-N 的淘汰语句；`session_id' 本期恒非 NULL，避免 NULL 不去重。")

;;; 运行时状态

(defvar el-chronos-store--db nil "当前 SQLite 句柄；nil 表示未打开。")
(defvar el-chronos-store--path nil "当前数据库文件绝对路径，用于判断 open 是否幂等。")
(defvar el-chronos-store--buffer nil "待写入的命令事件 plist 列表（最新在前）。")
(defvar el-chronos-store--slow-events nil "待写入的慢事件 plist 列表（最新在前）。")
(defvar el-chronos-store--usage (make-hash-table :test #'equal)
  "用法聚合：键 \"hour|dimension|key\"，值 `[count duration-ms]'。")
(defvar el-chronos-store--functions (make-hash-table :test #'equal)
  "函数采样聚合：键 \"hour|session|function\"，值 `[file package self total samples]'。")
(defvar el-chronos-store--stacks (make-hash-table :test #'equal)
  "调用栈聚合：键 \"hour|session|hash\"，值 `[stack-json samples]'。")
(defvar el-chronos-store--flush-timer nil "周期 flush timer；关闭时取消。")
(defvar el-chronos-store--warned-at nil "上次告警的 `float-time'，用于限流。")
(defvar el-chronos-store--null-session-warned nil "是否已就「会话 ID 缺失」告警过。")
(defvar el-chronos-store--stack-skip-warned nil
  "是否已就「会话不可用、跳过 hourly_stacks」告警过。
每进程只告警一次，故 `el-chronos-store-close' 不重置它。")

;;; 小工具

(defun el-chronos-store--now-ms ()
  "当前 epoch 毫秒（整数）；I4 要求时间戳一律毫秒。"
  (truncate (* 1000 (float-time))))
(defun el-chronos-store--warn (format-string &rest args)
  "限流告警：每 `el-chronos-store--warn-interval-seconds' 秒最多一次，绝不抛错。"
  (let ((now (float-time)))
    (when (or (null el-chronos-store--warned-at)
              (> (- now el-chronos-store--warned-at)
                 el-chronos-store--warn-interval-seconds))
      (setq el-chronos-store--warned-at now)
      (display-warning 'el-chronos (apply #'format format-string args) :warning))))
(defun el-chronos-store--split-key (key)
  "把聚合键 \"hour|中间段|名字\" 拆成 (HOUR 中间段 名字)；名字允许含 \"|\"。"
  (if (string-match "\\`\\([0-9]+\\)|\\([^|]*\\)|\\(.*\\)\\'" key)
      (list (string-to-number (match-string 1 key))
            (match-string 2 key) (match-string 3 key))
    (list 0 "" key)))
(defun el-chronos-store--parse-session (string)
  "把聚合键中的会话片段 STRING 转回会话 ID；空串表示 NULL。"
  (if (or (null string) (string-empty-p string)) nil (string-to-number string)))
(defun el-chronos-store--session-key-part ()
  "聚合键里的会话片段：有会话时为其十进制形式，否则空串（落库为 NULL）。"
  (if el-chronos--session-id (number-to-string el-chronos--session-id) ""))
(defun el-chronos-store--json-value (value)
  "把 elisp 值转为 `json-serialize' 可接受的形式。
符号转字符串（关键字去冒号）、vector/list 转数组、plist 转对象、nil 转 null。
`:false' 与 `:json-false' 都归一为 `json-serialize' 认的 `:false'（JSON false），
`:null' 保持为 `:null'（JSON null），确保输出是合法布尔/空值而非字符串。"
  (cond ((or (stringp value) (numberp value) (eq value t)) value)
        ;; `json-serialize' 只认 `:false' / `:null' 两个哨兵：`:json-false' 必须归一
        ((memq value '(:false :json-false :null))
         (if (eq value :json-false) :false value))
        ((null value) :null)
        ((symbolp value) (string-remove-prefix ":" (symbol-name value)))
        ((vectorp value)
         (vconcat (mapcar #'el-chronos-store--json-value (append value nil))))
        ((and (consp value) (keywordp (car value)))
         (let ((table (make-hash-table :test #'equal)))
           (while value
             (setf (gethash (string-remove-prefix ":" (symbol-name (pop value))) table)
                   (el-chronos-store--json-value (pop value))))
           table))
        ((consp value) (vconcat (mapcar #'el-chronos-store--json-value value)))
        (t (format "%s" value))))
(defun el-chronos-store--json-string (value)
  "把 VALUE 序列化为 JSON；VALUE 为 nil 或序列化失败时返回 nil（落库 NULL）。"
  (when value
    (condition-case nil (json-serialize (el-chronos-store--json-value value))
      (error nil))))
(defun el-chronos-store--push-event (slot event)
  "把 EVENT（plist）补齐 `:ts' 后推入符号 SLOT 的缓冲，超上限丢最旧项。"
  (let ((plist (copy-sequence event))
        (buffer (cons nil (symbol-value slot))))
    (plist-put plist :ts (or (plist-get plist :ts) (el-chronos-store--now-ms)))
    (setcar buffer plist)
    (when (> (length (cdr buffer)) el-chronos-store--max-buffer-items)
      (setcdr (nthcdr (1- el-chronos-store--max-buffer-items) buffer) nil))
    (set slot buffer)))

;;; schema 与迁移

(defun el-chronos-store--database-version (db)
  "读取 DB 的 `PRAGMA user_version'，缺失时返回 0。"
  (or (caar (sqlite-select db "PRAGMA user_version")) 0))
(defun el-chronos-store--ensure-schema (db)
  "在 DB 上建表建索引（幂等），并把 user_version 置为当前版本。"
  (sqlite-execute-batch db el-chronos-store--schema-ddl)
  (sqlite-pragma db (format "user_version=%d" el-chronos-store--schema-version))
  t)
(defun el-chronos-store--migrate (db path from-version)
  "把已打开的 DB 从 FROM-VERSION 迁移到当前版本。
迁移前 checkpoint 并复制为 PATH.bak；失败则关句柄、用 .bak 覆盖回原文件、删残留
-wal/-shm 并告警，返回 nil（原库可用）。成功返回 t。"
  (let ((bak (concat path ".bak")))
    (condition-case err
        (progn
          ;; WAL 未 checkpoint 时主文件不含最新数据，复制前先落盘
          (ignore-errors (sqlite-execute db "PRAGMA wal_checkpoint(TRUNCATE)"))
          (when (file-exists-p path) (copy-file path bak t))
          ;; 版本 0 → 1 只建表；后续版本在此按 (< from-version N) 逐级追加
          (when (< from-version 1) (el-chronos-store--ensure-schema db))
          t)
      (error
       (display-warning 'el-chronos
                        (format "schema 迁移失败（%d → %d），已回滚为迁移前状态：%S"
                                from-version el-chronos-store--schema-version err)
                        :warning)
       (ignore-errors (sqlite-close db))
       (when (file-exists-p bak)
         (ignore-errors (copy-file bak path t))
         (dolist (suffix '("-wal" "-shm"))
           (ignore-errors (delete-file (concat path suffix)))))
       nil))))
(defun el-chronos-store--open-db (path)
  "打开 PATH，完成 pragma、版本检查与迁移后返回句柄；失败返回 nil（已告警）。"
  (let ((db (sqlite-open path)))
    (condition-case err
        (progn
          (sqlite-pragma db (format "busy_timeout=%d" el-chronos-store--busy-timeout-ms))
          (sqlite-pragma db "foreign_keys=ON")
          (sqlite-pragma db "journal_mode=WAL")
          (let ((version (el-chronos-store--database-version db)))
            (cond
             ((> version el-chronos-store--schema-version)
              (display-warning 'el-chronos
                               (format "schema 版本 %d 高于本程序支持的 %d，已放弃打开。"
                                       version el-chronos-store--schema-version)
                               :warning)
              (ignore-errors (sqlite-close db))
              nil)
             ;; 新库（版本 0）与旧库走同一条迁移路径；备份此时是空库副本，无副作用
             ((< version el-chronos-store--schema-version)
              (when (el-chronos-store--migrate db path version) db))
             (t db))))
      (error
       (display-warning 'el-chronos
                        (format "打开数据库失败（%s）：%S" path err) :warning)
       (ignore-errors (sqlite-close db))
       nil))))

;;; 会话

(defun el-chronos-store--session-known-p (db id)
  "DB 的 `sessions' 表中是否已有 ID 对应的行。"
  (and id (> (or (caar (sqlite-select db
                                      "SELECT count(*) FROM sessions WHERE id = ?"
                                      (list id)))
                 0)
             0)))
(defun el-chronos-store--ensure-session (db)
  "确保 DB 存在当前会话行并返回其 id。
`-close' 保留 `el-chronos--session-id'，同进程关闭后重开会复用同一行，故重复 open 幂等。"
  (let ((existing (bound-and-true-p el-chronos--session-id)))
    (if (el-chronos-store--session-known-p db existing)
        existing
      (let ((startup (when (and after-init-time before-init-time)
                       (* 1000 (float-time (time-subtract after-init-time
                                                          before-init-time))))))
        (sqlite-execute db (concat "INSERT INTO sessions (started_at, emacs_version,"
                                   " host, startup_ms, gc_threshold) VALUES (?,?,?,?,?)")
                        (list (el-chronos-store--now-ms) emacs-version (system-name)
                              startup (float gc-cons-threshold)))
        (or (caar (sqlite-select db "SELECT last_insert_rowid()")) 0)))))

;;; 生命周期

(defun el-chronos-store--start-flush-timer ()
  "启动周期 flush timer，并登记到 `el-chronos--active-timers'（供 I5 统一清理）。"
  (setq el-chronos-store--flush-timer
        (el-chronos--register-timer
         (run-with-timer el-chronos-store--flush-interval-seconds
                         el-chronos-store--flush-interval-seconds
                         #'el-chronos-store-flush))))
(defun el-chronos-store-open (&optional path)
  "打开（或复用）PATH 处数据库并返回句柄；失败返回 nil 且不抛错。
PATH 省略时用 `el-chronos-db-path'。同路径已打开时直接返回现有句柄（幂等：不重复插
会话、不重复起 timer）；路径变化时先 `el-chronos-store-close'。启动 flush timer 并做一次
保留清理后返回句柄。"
  (let ((path (expand-file-name (or path el-chronos-db-path))))
    (cond
     ((and el-chronos-store--db (equal path el-chronos-store--path))
      el-chronos-store--db)
     (t
      (when el-chronos-store--db (el-chronos-store-close))
      (condition-case err
          (let ((db (progn (make-directory (file-name-directory path) t)
                           (el-chronos-store--open-db path))))
            (when db
              (setq el-chronos-store--db db el-chronos-store--path path)
              (when (boundp 'el-chronos--session-id)
                (setq el-chronos--session-id (el-chronos-store--ensure-session db)))
              (el-chronos-store--start-flush-timer)
              (el-chronos-store--prune)
              db))
        (error
         (display-warning 'el-chronos
                          (format "打开数据库失败（%s）：%S" path err) :warning)
         (setq el-chronos-store--db nil el-chronos-store--path nil)
         nil))))))
(defun el-chronos-store-close ()
  "flush 缓冲、取消 flush timer、关闭数据库并清空本模块状态。
`el-chronos--session-id' 故意不置 nil：它由 `el-chronos.el' 决定生命周期，
保留才能让同一进程内重开复用会话行。
取消 flush timer 的同时把它从 `el-chronos--active-timers' 摘除，避免 I5 的统一清理
遇到已取消的 timer，也避免登记表在反复 open/close 后无限增长。"
  (ignore-errors (el-chronos-store-flush))
  (when el-chronos-store--flush-timer
    (ignore-errors (cancel-timer el-chronos-store--flush-timer))
    (when (bound-and-true-p el-chronos--active-timers) ; 用 bound-and-true-p 守卫
      (setq el-chronos--active-timers
            (delq el-chronos-store--flush-timer el-chronos--active-timers))))
  (when el-chronos-store--db
    (ignore-errors (sqlite-close el-chronos-store--db)))
  (setq el-chronos-store--db nil el-chronos-store--path nil
        el-chronos-store--flush-timer nil el-chronos-store--buffer nil
        el-chronos-store--slow-events nil el-chronos-store--null-session-warned nil
        el-chronos-store--warned-at nil
        el-chronos-store--usage (make-hash-table :test #'equal)
        el-chronos-store--functions (make-hash-table :test #'equal)
        el-chronos-store--stacks (make-hash-table :test #'equal))
  nil)

;;; 写入接口（只进缓冲，不直接写库）

(defun el-chronos-store-record-command (event)
  "把命令事件 EVENT 推入缓冲。
键：`:name' `:duration-ms' `:gc-ms' `:mode' `:project' `:outcome' `:kind'。"
  (el-chronos-store--push-event 'el-chronos-store--buffer event))
(defun el-chronos-store-record-slow-event (event)
  "把慢事件 EVENT 推入缓冲。
键：`:duration-ms' `:kind' `:command' `:stack'（符号 list）`:context'（plist）；
后两者落库前序列化为 JSON，缺失写 NULL。"
  (el-chronos-store--push-event 'el-chronos-store--slow-events event))
(defun el-chronos-store-record-usage (hour-ts dimension key count duration-ms)
  "累加按小时的使用统计；DIMENSION 取 command/mode/project，HOUR-TS 为整点毫秒。"
  (let* ((cell-key (format "%d|%s|%s" hour-ts dimension key))
         (cell (gethash cell-key el-chronos-store--usage)))
    (if cell
        (progn (aset cell 0 (+ (aref cell 0) (or count 0)))
               (aset cell 1 (+ (aref cell 1) (or duration-ms 0))))
      (puthash cell-key (vector (or count 0) (float (or duration-ms 0)))
               el-chronos-store--usage))))
(defun el-chronos-store-record-function-samples
    (hour-ts function file package self-ms total-ms samples)
  "累加按小时的函数采样聚合。
FILE / PACKAGE 为归因结果（可 nil）；SELF-MS / TOTAL-MS 为窗口累计耗时（毫秒）。"
  (let* ((cell-key (format "%d|%s|%s" hour-ts
                           (el-chronos-store--session-key-part) function))
         (cell (gethash cell-key el-chronos-store--functions)))
    (if cell
        (progn (aset cell 2 (+ (aref cell 2) (float (or self-ms 0))))
               (aset cell 3 (+ (aref cell 3) (float (or total-ms 0))))
               (aset cell 4 (+ (aref cell 4) (or samples 0))))
      (puthash cell-key (vector file package (float (or self-ms 0))
                                (float (or total-ms 0)) (or samples 0))
               el-chronos-store--functions))))
(defun el-chronos-store-record-stacks (hour-ts stacks)
  "累加按小时的调用栈样本；STACKS 为 list of (STACK-JSON . SAMPLES)。
`stack_hash' 取 `secure-hash' 的 sha1，相同 JSON 合并样本数。"
  (let ((session (el-chronos-store--session-key-part)))
    (dolist (entry stacks)
      (let* ((json (car entry)) (samples (or (cdr entry) 0))
             (cell-key (format "%d|%s|%s" hour-ts session (secure-hash 'sha1 json)))
             (cell (gethash cell-key el-chronos-store--stacks)))
        (if cell
            (aset cell 1 (+ (aref cell 1) samples))
          (puthash cell-key (vector json samples) el-chronos-store--stacks))))))

;;; flush

(defun el-chronos-store--pending-p ()
  "是否还有未落库的缓冲。"
  (or el-chronos-store--buffer el-chronos-store--slow-events
      (> (hash-table-count el-chronos-store--usage) 0)
      (> (hash-table-count el-chronos-store--functions) 0)
      (> (hash-table-count el-chronos-store--stacks) 0)))
(defun el-chronos-store--upsert (db key value sql plain-middle-p)
  "把聚合 VALUE 按其键 KEY 用 SQL UPSERT 进 DB，返回解析出的 (HOUR 中间段 名字)。
PLAIN-MIDDLE-P 为 t 时中间段原样绑定（usage 的 dimension），否则按会话 ID 转整数。"
  (let ((parts (el-chronos-store--split-key key)))
    (sqlite-execute
     db sql (append (list (nth 0 parts)
                          (if plain-middle-p (nth 1 parts)
                            (el-chronos-store--parse-session (nth 1 parts)))
                          (nth 2 parts))
                    (append value nil)))
    parts))
(defun el-chronos-store--evict-stacks (db groups)
  "对 GROUPS（每个 (HOUR . SESSION)）执行 hourly_stacks 的 top-N 淘汰。
保留 samples 最大的 `el-chronos-store-stack-top-n' 条；DELETE 由调用方包在同一事务内。
会话为 NULL 的分组跳过淘汰并只告警一次。"
  (dolist (group groups)
    (let ((hour (car group)) (session (cdr group)))
      (cond
       ((null session)
        (unless el-chronos-store--null-session-warned
          (setq el-chronos-store--null-session-warned t)
          (display-warning
           'el-chronos "hourly_stacks 出现 session_id 为 NULL 的行，已跳过淘汰。" :warning)))
       (t (sqlite-execute db el-chronos-store--sql-evict-stacks
                          (list hour session hour session
                                (or el-chronos-store-stack-top-n 200))))))))
(defun el-chronos-store--clear-aggregates ()
  "清空慢事件缓冲与三个聚合 hash（命令缓冲由调用方按会话状态决定）。
把 hash 换成新表而不是 `clrhash'，避免仍在遍历旧表的 `maphash' 回调看到被清空的内容。"
  (setq el-chronos-store--slow-events nil
        el-chronos-store--usage (make-hash-table :test #'equal)
        el-chronos-store--functions (make-hash-table :test #'equal)
        el-chronos-store--stacks (make-hash-table :test #'equal)))
(defun el-chronos-store--stack-session (db session)
  "返回可写入 `hourly_stacks' 的会话 ID；不可用时返回 nil 并每进程告警一次。
SESSION 为 nil，或 DB 的 `sessions' 表中没有对应行时视为不可用：`hourly_stacks' 的
session_id 语义上恒非 NULL（NULL 会让主键去重失效），故宁可不写也不写 NULL 行。"
  (cond
   ((and session (el-chronos-store--session-known-p db session)) session)
   (t
    (unless el-chronos-store--stack-skip-warned
      (setq el-chronos-store--stack-skip-warned t)
      (display-warning 'el-chronos
                       "会话 ID 缺失或对应会话行不存在，本次已跳过 hourly_stacks 写入。"
                       :warning))
    nil)))
(defun el-chronos-store-flush ()
  "把全部缓冲批量写入数据库（单事务）。无句柄或无缓冲时直接返回。
flush 失败按计划丢弃本批（磁盘满/锁超时时数据本就无法落库），避免内存无界增长：
ROLLBACK 后清空四类缓冲（命令、慢事件、usage / functions / stacks 三个聚合 hash），
只保留失败计数性质的限流告警（10 分钟最多一次，I6），不向宿主抛错。
会话不可用（ID 为 nil 或 `sessions' 表无对应行）时跳过 `hourly_stacks' 写入，
其余表照常，保证不产生 session_id 为 NULL 的栈行。"
  (interactive)
  (when (and el-chronos-store--db (el-chronos-store--pending-p))
    (let ((db el-chronos-store--db)
          (session el-chronos--session-id)
          (stack-session (el-chronos-store--stack-session el-chronos-store--db
                                                           el-chronos--session-id))
          (groups nil))
      (condition-case err
          (progn
            (sqlite-execute db "BEGIN")
            ;; 明细：命令事件（无会话时不落库，缓冲保留到会话就绪）
            (when session
              (dolist (cmd (reverse el-chronos-store--buffer))
                (sqlite-execute db el-chronos-store--sql-insert-command
                                (list (or (plist-get cmd :ts) (el-chronos-store--now-ms))
                                      session (or (plist-get cmd :name) "unknown")
                                      (float (or (plist-get cmd :duration-ms) 0))
                                      (plist-get cmd :gc-ms) (plist-get cmd :mode)
                                      (plist-get cmd :project) (plist-get cmd :outcome)
                                      (plist-get cmd :kind)))))
            ;; 明细：慢事件（stack / context 转 JSON）
            (dolist (e (reverse el-chronos-store--slow-events))
              (sqlite-execute db el-chronos-store--sql-insert-slow-event
                              (list (or (plist-get e :ts) (el-chronos-store--now-ms))
                                    (float (or (plist-get e :duration-ms) 0))
                                    (plist-get e :kind) (plist-get e :command)
                                    (el-chronos-store--json-string (plist-get e :stack))
                                    (el-chronos-store--json-string (plist-get e :context)))))
            ;; 聚合三表：函数采样 / 用法 / 调用栈（调用栈同时记下受影响分组）
            (maphash (lambda (key value)
                       (el-chronos-store--upsert db key value
                                                 el-chronos-store--sql-upsert-function nil))
                     el-chronos-store--functions)
            (maphash (lambda (key value)
                       (el-chronos-store--upsert db key value
                                                 el-chronos-store--sql-upsert-usage t))
                     el-chronos-store--usage)
            ;; 会话不可用时整张 hourly_stacks 跳过，不写 NULL session 行
            (when stack-session
              (maphash (lambda (key value)
                         (let ((parts (el-chronos-store--upsert
                                       db key value el-chronos-store--sql-upsert-stack nil)))
                           (push (cons (nth 0 parts)
                                       (el-chronos-store--parse-session (nth 1 parts)))
                                 groups)))
                       el-chronos-store--stacks)
              ;; top-N 淘汰与写入同事务，保证「恰好 N 行」对读者可见
              (el-chronos-store--evict-stacks db (delete-dups groups)))
            (sqlite-execute db "COMMIT")
            (when session (setq el-chronos-store--buffer nil))
            (el-chronos-store--clear-aggregates)
            t)
        (error
         (ignore-errors (sqlite-execute db "ROLLBACK"))
         ;; 按计划丢弃本批：数据此时本就无法落库，保留会无界增长。
         ;; 注意这里与**成功路径**的差异是**有意的**，不是漏写会话守卫：
         ;;   - 成功路径在 `session' 为 nil 时保留命令缓冲（会话就绪后还能补落库）；
         ;;   - 失败路径**无条件**清空命令缓冲，因为：
         ;;     1) 事务已 ROLLBACK，无法区分本批新增与上一轮遗留，保留会造成重复计数；
         ;;     2) 写库失败通常是持续性故障（磁盘满、WAL 锁超时），保留只会让内存无界增长；
         ;;     3) 会话缺失是短暂且可自愈的阻塞，写库失败是这一批数据真的落不下去。
         ;; 故命令缓冲与 `--clear-aggregates'（慢事件 + 三个聚合 hash）一并清空，
         ;; 只留下限流告警作为失败计数。
         (setq el-chronos-store--buffer nil)
         (el-chronos-store--clear-aggregates)
         (el-chronos-store--warn "写入数据库失败，本批缓冲已按计划丢弃：%S" err)
         nil)))))

;;; 保留清理与手动 purge

(defun el-chronos-store--prune ()
  "按 `el-chronos-retention-days' 清理明细表。
只删 `commands' 与 `slow_events'；三张 hourly_* 聚合表永久保留，只由 purge 清理。"
  (when el-chronos-store--db
    (let ((cutoff (- (el-chronos-store--now-ms)
                     (* (or el-chronos-retention-days 30) 86400000))))
      (condition-case err
          (progn
            (sqlite-execute el-chronos-store--db "BEGIN")
            (sqlite-execute el-chronos-store--db
                            "DELETE FROM commands WHERE ts < ?" (list cutoff))
            (sqlite-execute el-chronos-store--db
                            "DELETE FROM slow_events WHERE ts < ?" (list cutoff))
            (sqlite-execute el-chronos-store--db "COMMIT")
            t)
        (error
         (ignore-errors (sqlite-execute el-chronos-store--db "ROLLBACK"))
         (el-chronos-store--warn "保留清理失败（已跳过，下次启动重试）：%S" err)
         nil)))))
(defun el-chronos-store--delete-rows (db table column before)
  "删除 DB 中 TABLE 里 COLUMN 早于 BEFORE 的行；BEFORE 为 nil 时清空全表。返回行数。"
  (or (if before
          (sqlite-execute db (format "DELETE FROM %s WHERE %s < ?" table column)
                          (list before))
        (sqlite-execute db (format "DELETE FROM %s" table)))
      0))
(defun el-chronos-purge (&optional before)
  "删除 BEFORE（epoch 毫秒）之前的全部数据；BEFORE 为 nil 时清空 6 张表。
返回 ((表名 . 删除行数) ...)；与 `-prune' 的区别是连 hourly_* 聚合一起删。"
  (interactive
   (list (let ((text (string-trim
                      (read-string "删除该日期（YYYY-MM-DD）之前的数据，留空清空全部： "))))
           (unless (string-empty-p text)
             (truncate (* 1000 (float-time
                                (date-to-time (concat text " 00:00:00")))))))))
  (when (or el-chronos-store--db (el-chronos-store-open))
    (condition-case err
        (let ((db el-chronos-store--db) (result nil))
          (sqlite-execute db "BEGIN")
          (dolist (target '(("commands" . "ts") ("slow_events" . "ts")
                            ("hourly_functions" . "hour_ts") ("hourly_usage" . "hour_ts")
                            ("hourly_stacks" . "hour_ts") ("sessions" . "started_at")))
            (push (cons (car target)
                        (el-chronos-store--delete-rows db (car target) (cdr target) before))
                  result))
          (sqlite-execute db "COMMIT")
          ;; purge 可能删掉当前会话行：立刻补建，否则后续写入会撞外键约束
          (when (boundp 'el-chronos--session-id)
            (setq el-chronos--session-id (el-chronos-store--ensure-session db)))
          (setq result (nreverse result))
          (message "el-chronos：purge 完成 %s" result)
          result)
      (error
       (ignore-errors (sqlite-execute el-chronos-store--db "ROLLBACK"))
       (el-chronos-store--warn "purge 失败（已回滚）：%S" err)
       nil))))
(defun el-chronos-store-vacuum ()
  "对当前数据库执行 VACUUM 回收空间；未打开返回 nil。VACUUM 不能在事务内执行。"
  (interactive)
  (when el-chronos-store--db
    (condition-case err
        (progn (sqlite-execute el-chronos-store--db "VACUUM") t)
      (error (el-chronos-store--warn "VACUUM 失败：%S" err) nil))))

(provide 'el-chronos-store)

;;; el-chronos-store.el ends here
