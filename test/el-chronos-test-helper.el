;;; el-chronos-test-helper.el --- ERT 测试公共辅助（临时库 / fixture）  -*- lexical-binding: t; -*-

;; 本文件**不**命名为 `*-test.el'，因此不会被 `make test' 的自动发现
;; （`test/*-test.el'）加载；各测试文件用下面的形式显式引入：
;;
;;   (require 'el-chronos-test-helper
;;            (expand-file-name "el-chronos-test-helper"
;;                              (file-name-directory (or load-file-name
;;                                                       buffer-file-name))))
;;
;; 第二个参数是「回退文件名」：`make test' 带 `-L test'，从 load-path 直接命中；
;; `make lint' 只带 `-L .'（不编译 test/ 目录），此时靠显式路径回退，否则测试文件
;; 字节编译会在 require 处失败。两条路径都保证宏 `el-chronos-test-with-db' 在
;; 编译期已定义。
;;
;; 依赖：只依赖内置库（sqlite / el-chronos / el-chronos-store），不引入第三方包，
;; 不依赖网络，也不触碰 `<user-emacs-directory>' 下的真实数据库（一律临时目录）。

;;; Code:

(require 'sqlite)
(require 'el-chronos)
(require 'el-chronos-store)

(defvar el-chronos-test--tmp-dirs nil
  "本次用例创建、待删除的临时目录列表。
由 `el-chronos-test-with-db' / `el-chronos-test-with-tmp-dir' 动态绑定，
所以每个用例互不干扰，也不会把路径残留在全局状态里。")

(defun el-chronos-test--tmp-dir ()
  "创建并登记一个临时目录，返回其绝对路径。"
  (let ((dir (make-temp-file "chronos-test-" t)))
    (push dir el-chronos-test--tmp-dirs)
    dir))

(defun el-chronos-test--db-path ()
  "在新建的临时目录里给出一个数据库文件路径（只算路径，不打开）。"
  (expand-file-name "chronos.sqlite" (el-chronos-test--tmp-dir)))

(defun el-chronos-test--open-db (&optional path)
  "把 `el-chronos-db-path' 指向 PATH（默认新建临时目录下的库）并打开它。
返回句柄；打开失败返回 nil（调用方负责报错）。"
  (let ((path (or path (el-chronos-test--db-path))))
    (setq el-chronos-db-path path)
    (el-chronos-store-open path)))

(defun el-chronos-test--cleanup-dirs ()
  "删除本次用例创建的全部临时目录（数据库 -wal / -shm 一并随目录删除）。"
  (dolist (dir el-chronos-test--tmp-dirs)
    (ignore-errors (delete-directory dir t)))
  (setq el-chronos-test--tmp-dirs nil))

(defun el-chronos-test--close-db ()
  "关闭当前测试数据库（关闭前由 store 自行 flush），再删除临时目录。"
  (ignore-errors (el-chronos-store-close))
  (el-chronos-test--cleanup-dirs))

(defmacro el-chronos-test-with-db (&rest body)
  "在临时 SQLite 库上执行 BODY，结束（正常或异常）时关库并删目录。
绑定 `el-chronos--session-id' 为 nil，保证每个用例都新建会话行、互不依赖；
固定 `el-chronos-retention-days' 与 `el-chronos-slow-command-threshold-ms'，
让 open 时的保留清理与慢命令判定都可预期。"
  (declare (indent 0) (debug t))
  `(let ((el-chronos-test--tmp-dirs nil)
         (el-chronos-db-path nil)
         (el-chronos--session-id nil)
         (el-chronos-retention-days 30)
         (el-chronos-slow-command-threshold-ms 200))
     (unwind-protect
         (progn
           (unless (el-chronos-test--open-db)
             (error "测试数据库打开失败：%s" el-chronos-db-path))
           ,@body)
       (el-chronos-test--close-db))))

(defmacro el-chronos-test-with-tmp-dir (var &rest body)
  "把新建临时目录绑到 VAR 并执行 BODY，结束后删除目录（不涉及数据库）。"
  (declare (indent 1) (debug t))
  `(let* ((el-chronos-test--tmp-dirs nil)
          (,var (el-chronos-test--tmp-dir)))
     (unwind-protect
         (progn ,@body)
       (el-chronos-test--cleanup-dirs))))

;;; 时间与 SQL 小工具

(defun el-chronos-test--now-ms ()
  "当前 epoch 毫秒（整数），与 store / analysis 的口径一致（I4）。"
  (truncate (* 1000 (float-time))))

(defun el-chronos-test--hour-ts ()
  "当前整点的时间戳（毫秒），用作聚合表的 fixture 基准。"
  (* 3600000 (floor (/ (float-time) 3600))))

(defun el-chronos-test--exec (sql &optional params)
  "在当前测试库上执行 SQL（PARAMS 用 `?' 占位符绑定）。"
  (sqlite-execute el-chronos-store--db sql params))

(defun el-chronos-test--scalar (sql &optional params)
  "在当前测试库上执行 SQL 并返回第一行第一列。"
  (caar (sqlite-select el-chronos-store--db sql params)))

(defun el-chronos-test--count (table)
  "返回当前测试库中 TABLE 的行数（表名由测试硬编码，非用户输入）。"
  (el-chronos-test--scalar (format "SELECT count(*) FROM %s" table)))

;;; fixture 写入

(defun el-chronos-test--insert-session (started-at &optional startup-ms version host)
  "插入一条会话行并返回其 id。
STARTED-AT 为毫秒；STARTUP-MS 为启动耗时（毫秒，nil 表示未知）；
VERSION / HOST 落库为 emacs_version / host。"
  (el-chronos-test--exec
   "INSERT INTO sessions (started_at, emacs_version, host, startup_ms, gc_threshold)\
 VALUES (?, ?, ?, ?, ?)"
   (list started-at (or version "31.1") (or host "test-host")
         startup-ms (float gc-cons-threshold)))
  (el-chronos-test--scalar "SELECT last_insert_rowid()"))

(defun el-chronos-test--insert-command (ts name duration-ms
                                          &optional gc-ms mode project outcome kind)
  "插入一条命令明细行。
TS 为毫秒；OUTCOME 默认 \"ok\"，KIND 默认 \"interactive\"。"
  (el-chronos-test--exec
   "INSERT INTO commands (ts, session_id, name, duration_ms, gc_ms, mode, project,\
 outcome, kind) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)"
   (list ts (or el-chronos--session-id 0) name (float duration-ms) gc-ms mode project
         (or outcome "ok") (or kind "interactive"))))

(defun el-chronos-test--insert-slow-event (ts duration-ms kind
                                              &optional command stack-json context-json)
  "插入一条慢事件行。KIND 取 \"block\" 或 \"command\"；两个 JSON 参数原样进库。"
  (el-chronos-test--exec
   "INSERT INTO slow_events (ts, duration_ms, kind, command, stack_json, context_json)\
 VALUES (?, ?, ?, ?, ?, ?)"
   (list ts (float duration-ms) kind command stack-json context-json)))

(defun el-chronos-test--insert-function (hour-ts function
                                                 &optional file package self-ms total-ms samples)
  "插入一条函数聚合行。SELF-MS / TOTAL-MS 为毫秒，SAMPLES 为 leaf 口径计数。"
  (el-chronos-test--exec
   "INSERT INTO hourly_functions (hour_ts, session_id, function, file, package,\
 self_ms, total_ms, samples) VALUES (?, ?, ?, ?, ?, ?, ?, ?)"
   (list hour-ts (or el-chronos--session-id 0) function file package
         (float (or self-ms 0)) (float (or total-ms 0)) (or samples 0))))

(defun el-chronos-test--insert-usage (hour-ts dimension key count duration-ms)
  "插入一条用法聚合行。DIMENSION 取 command / mode / project / file（符号或字符串）。"
  (el-chronos-test--exec
   "INSERT INTO hourly_usage (hour_ts, dimension, key, count, duration_ms)\
 VALUES (?, ?, ?, ?, ?)"
   (list hour-ts (if (symbolp dimension) (symbol-name dimension) dimension)
         key (or count 0) (float (or duration-ms 0)))))

(defun el-chronos-test--insert-stack (hour-ts stack-json samples &optional session-id)
  "插入一条调用栈聚合行。SESSION-ID 默认取当前会话。"
  (el-chronos-test--exec
   "INSERT INTO hourly_stacks (hour_ts, session_id, stack_hash, stack_json, samples)\
 VALUES (?, ?, ?, ?, ?)"
   (list hour-ts (or session-id el-chronos--session-id 0)
         (secure-hash 'sha1 stack-json) stack-json (or samples 0))))

(defun el-chronos-test--insert-gc (hour-ts gc-count gc-ms &optional heap-bytes session-id)
  "插入一条 GC 聚合行。HEAP-BYTES 为 nil 时落库为 NULL（Emacs 31.1 以下不采集）；
SESSION-ID 默认取当前会话，显式传入可造同一小时的多个会话行（主键含 session_id）。"
  (el-chronos-test--exec
   "INSERT INTO hourly_gc (hour_ts, session_id, gc_count, gc_ms, heap_bytes)\
 VALUES (?, ?, ?, ?, ?)"
   (list hour-ts (or session-id el-chronos--session-id 0)
         (or gc-count 0) (float (or gc-ms 0)) heap-bytes)))

(defun el-chronos-test--insert-startup-phase (session-id phase ms)
  "插入一条启动阶段打点：SESSION-ID / PHASE / MS（毫秒）。
PHASE 取 `mode-start' / `after-init' / `startup' / `first-idle'，包加载明细传
\"load:<library>\"。主键是 (session_id, phase)，同键重复插入会撞约束。"
  (el-chronos-test--exec
   "INSERT INTO startup_phases (session_id, phase, ms) VALUES (?, ?, ?)"
   (list session-id phase (float (or ms 0)))))

(defun el-chronos-test--insert-health (hour-ts key value &optional session-id)
  "插入一条自监控计数：HOUR-TS / KEY / VALUE；SESSION-ID 默认取当前会话。
主键是 (hour_ts, session_id, key)，同小时同键重复插入会撞约束（要造多行请换小时）。"
  (el-chronos-test--exec
   "INSERT INTO hourly_health (hour_ts, session_id, key, value) VALUES (?, ?, ?, ?)"
   (list hour-ts (or session-id el-chronos--session-id 0) key (float (or value 0)))))

(defun el-chronos-test--insert-session-meta (session-id key value)
  "插入一条会话级元数据 KV：SESSION-ID / KEY / VALUE（VALUE 为 nil 时落 NULL）。
实际写入的 KEY 只有 `git-head' / `config-sig'；主键是 (session_id, key)。
（`mode-start' 是 `startup_phases.phase' 的取值，不是本表键。）"
  (el-chronos-test--exec
   "INSERT INTO session_meta (session_id, key, value) VALUES (?, ?, ?)"
   (list session-id key value)))


(provide 'el-chronos-test-helper)

;;; el-chronos-test-helper.el ends here
