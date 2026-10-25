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
;;   - `commands' / `slow_events' 按 `el-chronos-retention-days' 清理，五张 hourly_*
;;     聚合表（`hourly_functions' / `hourly_usage' / `hourly_stacks' / `hourly_gc' /
;;     `hourly_health'）永久保留、只由 `el-chronos-purge' 手动清理；
;;   - `hourly_stacks' 每 (hour_ts, session_id) 只留 samples 最大的 top-N 条。
;; 单位（I4）：时间戳与耗时用毫秒，采样间隔用纳秒；数据只写 `el-chronos-db-path'。

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'sqlite)
(require 'el-chronos)

;;; 常量

(defconst el-chronos-store--schema-version 2
  "支持的 schema 版本，对应 `PRAGMA user_version'；升级时递增并追加迁移步骤。
版本 2 = 新增 hourly_gc / startup_phases / hourly_health / session_meta 四表
（增量脚本见 `el-chronos-store--sql-migrate-v2'）；版本 1 = 最初的 6 表 + 3 索引。")
(defconst el-chronos-store--flush-interval-seconds 5
  "缓冲落库间隔（秒）；5 秒把崩溃丢失窗口压在秒级且写库抖动不可见。")
(defconst el-chronos-store--warn-interval-seconds 600
  "同类告警最小间隔（秒）；磁盘满、锁超时等故障会持续，必须限流。")
(defconst el-chronos-store--busy-timeout-ms 2000
  "SQLite 忙等待超时（毫秒）；外部进程短暂持锁时等待而非立即失败。")
(defconst el-chronos-store--max-buffer-items 50000
  "单类缓冲最大条目数；仅兜底，防库长期不可写时内存无界增长。")
(defconst el-chronos-store--ddl-hourly-gc
  "CREATE TABLE IF NOT EXISTS hourly_gc (hour_ts INTEGER NOT NULL, session_id INTEGER NOT NULL, gc_count INTEGER NOT NULL DEFAULT 0, gc_ms REAL NOT NULL DEFAULT 0, heap_bytes INTEGER, PRIMARY KEY (hour_ts, session_id));"
  "v2 新增：GC 次数 / 耗时 / 堆大小的按小时聚合（每会话每小时一行）。
`heap_bytes' 是稀疏写入（同小时多数窗口为 NULL），读取时按「本行最后一次非 NULL 值
胜出」理解；写层用 COALESCE 实现该语义（写入函数随 T2 落地）。
不写外键：与 `hourly_functions' / `hourly_stacks' 一致，避免 purge 的删除顺序与级联
约束耦合。")
(defconst el-chronos-store--ddl-startup-phases
  "CREATE TABLE IF NOT EXISTS startup_phases (session_id INTEGER NOT NULL, phase TEXT NOT NULL, ms REAL NOT NULL, PRIMARY KEY (session_id, phase));"
  "v2 新增：启动各阶段耗时（每会话每阶段一行，重复打点覆盖）。
不写外键：同 `el-chronos-store--ddl-hourly-gc'。")
(defconst el-chronos-store--ddl-hourly-health
  "CREATE TABLE IF NOT EXISTS hourly_health (hour_ts INTEGER NOT NULL, session_id INTEGER NOT NULL, key TEXT NOT NULL, value REAL NOT NULL DEFAULT 0, PRIMARY KEY (hour_ts, session_id, key));"
  "v2 新增：采集器自监控计数（丢弃事件 / flush 失败 / 采样窗口丢失等），按小时聚合。
不写外键：同 `el-chronos-store--ddl-hourly-gc'。")
(defconst el-chronos-store--ddl-session-meta
  "CREATE TABLE IF NOT EXISTS session_meta (session_id INTEGER NOT NULL, key TEXT NOT NULL, value TEXT, PRIMARY KEY (session_id, key));"
  "v2 新增：会话级元数据 KV，加一个键无需再迁移。
**实际写入的键只有两个**：`git-head'（会话启动时的仓库提交 sha）与 `config-sig'
（配置文件 mtime/size 的 sha1 指纹），由 `el-chronos-store--ensure-session' 每会话
写一次；取不到值的键**不写行**（不写 NULL 值行）。
`mode-start' **不在本表** —— 它是 `startup_phases.phase' 的取值（模式启用锚点），
查启动分解请查 `startup_phases'。
不写外键：同 `el-chronos-store--ddl-hourly-gc'。")
(defconst el-chronos-store--schema-ddl
  (concat "
CREATE TABLE IF NOT EXISTS sessions (id INTEGER PRIMARY KEY AUTOINCREMENT, started_at INTEGER NOT NULL, emacs_version TEXT, host TEXT, startup_ms REAL, gc_threshold REAL);
CREATE TABLE IF NOT EXISTS commands (id INTEGER PRIMARY KEY AUTOINCREMENT, ts INTEGER NOT NULL, session_id INTEGER NOT NULL REFERENCES sessions(id), name TEXT NOT NULL, duration_ms REAL NOT NULL, gc_ms REAL, mode TEXT, project TEXT, outcome TEXT, kind TEXT);
CREATE INDEX IF NOT EXISTS idx_commands_ts ON commands(ts);
CREATE INDEX IF NOT EXISTS idx_commands_duration ON commands(duration_ms DESC);
CREATE TABLE IF NOT EXISTS hourly_functions (hour_ts INTEGER NOT NULL, session_id INTEGER NOT NULL, function TEXT NOT NULL, file TEXT, package TEXT, self_ms REAL NOT NULL DEFAULT 0, total_ms REAL NOT NULL DEFAULT 0, samples INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (hour_ts, session_id, function));
CREATE TABLE IF NOT EXISTS slow_events (id INTEGER PRIMARY KEY AUTOINCREMENT, ts INTEGER NOT NULL, duration_ms REAL NOT NULL, kind TEXT, command TEXT, stack_json TEXT, context_json TEXT);
CREATE INDEX IF NOT EXISTS idx_slow_events_ts ON slow_events(ts);
CREATE TABLE IF NOT EXISTS hourly_usage (hour_ts INTEGER NOT NULL, dimension TEXT NOT NULL, key TEXT NOT NULL, count INTEGER NOT NULL DEFAULT 0, duration_ms REAL NOT NULL DEFAULT 0, PRIMARY KEY (hour_ts, dimension, key));
CREATE TABLE IF NOT EXISTS hourly_stacks (hour_ts INTEGER NOT NULL, session_id INTEGER, stack_hash TEXT NOT NULL, stack_json TEXT NOT NULL, samples INTEGER, PRIMARY KEY (hour_ts, session_id, stack_hash));"
          "\n" el-chronos-store--ddl-hourly-gc
          "\n" el-chronos-store--ddl-startup-phases
          "\n" el-chronos-store--ddl-hourly-health
          "\n" el-chronos-store--ddl-session-meta)
  "全量建表建索引语句（10 表 + 3 索引），一次批量执行（幂等）；`commands' 引用
`sessions'，顺序不能改。v2 的 4 张新表由单表 DDL 常量 concat 而来，与
`el-chronos-store--sql-migrate-v2' 共用同一批字面量（两份字面量必然漂移，而漂移的表现是
「新库对、旧库缺表」）。
**必须始终是全量**：`el-chronos-store--ensure-schema' 建完表就无条件把 `user_version'
置为当前版本，缺表的新库会被标记成 v2 而之后永远不再迁移。
新表一律不写外键（与 `hourly_functions' / `hourly_stacks' 一致），避免 purge 的删除
顺序与级联约束耦合。")
(defconst el-chronos-store--sql-migrate-v2
  (concat el-chronos-store--ddl-hourly-gc
          "\n" el-chronos-store--ddl-startup-phases
          "\n" el-chronos-store--ddl-hourly-health
          "\n" el-chronos-store--ddl-session-meta)
  "version 1 → 2 的增量迁移脚本：只建 4 张新表。
不含既有 6 表与 3 索引（迁移不需要重复建它们），也不重复 DDL 全量，避免与
`el-chronos-store--schema-ddl' 的双份同步负担；两者共用同一批单表 DDL 常量。
四条语句全是 CREATE TABLE IF NOT EXISTS，可无条件重跑；但**执行时必须显式包事务**
（`sqlite-execute-batch' 不自带），见 `el-chronos-store--migrate'。")
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
(defconst el-chronos-store--sql-upsert-gc
  "INSERT INTO hourly_gc (hour_ts, session_id, gc_count, gc_ms, heap_bytes) VALUES (?, ?, ?, ?, ?) ON CONFLICT(hour_ts, session_id) DO UPDATE SET gc_count = gc_count + excluded.gc_count, gc_ms = gc_ms + excluded.gc_ms, heap_bytes = COALESCE(excluded.heap_bytes, heap_bytes)"
  "GC 聚合的 upsert：次数与耗时**累加**，堆大小只在有新样本时覆盖。

`heap_bytes = COALESCE(excluded.heap_bytes, heap_bytes)' 的意义（不可改成普通覆盖）：
堆采样是稀疏的（每 `el-chronos-heap-sample-windows' 个窗口一次），同一会话同一小时的
**其余窗口一律传 NULL**。若写成 `heap_bytes = excluded.heap_bytes'，一个采样点之后
第一个 NULL 窗口就会把它抹成 NULL —— 该小时最后一次写入若是 NULL，整小时采到的值全部
丢失。这是**每个会话每小时都会发生**的场景（不是防御性设计），故必须 COALESCE，
语义读作「本次无样本时保留本行最后一次观测值」。
代价：`heap_bytes' 的时间戳含义是「本行最后一次有样本的时刻」，不是整点，跨小时不携带。")
(defconst el-chronos-store--sql-upsert-health
  "INSERT INTO hourly_health (hour_ts, session_id, key, value) VALUES (?, ?, ?, ?) ON CONFLICT(hour_ts, session_id, key) DO UPDATE SET value = value + excluded.value"
  "自监控计数的 upsert：同 (hour_ts, session_id, key) **累加**。
计数（丢弃事件、flush 次数）与耗时（flush-ms）都是单调量，累加是唯一正确语义。")
(defconst el-chronos-store--sql-upsert-startup
  "INSERT INTO startup_phases (session_id, phase, ms) VALUES (?, ?, ?) ON CONFLICT(session_id, phase) DO UPDATE SET ms = excluded.ms"
  "启动阶段耗时的 upsert：同 (session_id, phase) **覆盖**（重复打点取最后一次）。
覆盖而非累加：同一阶段在一次启动里重复打点说明是「修正值」，累加毫无意义。")
(defconst el-chronos-store--sql-upsert-session-meta
  "INSERT INTO session_meta (session_id, key, value) VALUES (?, ?, ?) ON CONFLICT(session_id, key) DO UPDATE SET value = excluded.value"
  "会话级元数据 KV 的 upsert：同 (session_id, key) **覆盖**（同一键只保留当前值）。
由 `el-chronos-store-record-session-meta' **直接执行**（不走缓冲、不参与 flush 事务，
见该函数 docstring 的 O10 说明）。")
(defconst el-chronos-store--sql-update-startup-ms
  "UPDATE sessions SET startup_ms = ? WHERE id = ? AND startup_ms IS NULL"
  "`startup_ms' 的**补写**语句（计划设计 7 处置 ③）。
`AND startup_ms IS NULL' 守卫不可去掉：它防的是「mode 由 `emacs-startup-hook' 启动」
这类正常路径 —— 那条路径上 `--ensure-session' 已经把真实值算对并写进库，若补写无条件
覆盖，就会用一个更晚的、口径不同的值把它盖掉（本机 `init-chronos.el` 正是这种写法）。")
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
(defvar el-chronos-store--gc (make-hash-table :test #'equal)
  "GC 聚合：键 \"hour|session\"（两段，**不是**三段），值 `[gc-count gc-ms heap-bytes]'。
累加语义：次数与耗时逐次相加；`heap-bytes' 只在**非 nil** 时更新（nil 表示本窗口无堆样本，
必须留住上一次观测值，落库时由 `el-chronos-store--sql-upsert-gc' 的 COALESCE 保证）。
会话片段为空串时不会入缓冲（记录函数先判会话可用）。")
(defvar el-chronos-store--health (make-hash-table :test #'equal)
  "采集器自监控计数聚合：键 \"hour|session|key\"，值累加数字（耗时也用 REAL）。
KEY 是固定枚举字符串（`dropped-commands' / `dropped-events' / `flush-failures' /
`flush-count' / `flush-ms' / `sample-misses'），本身不含 \"|\"，故沿用三段拆分。")
(defvar el-chronos-store--startup (make-hash-table :test #'equal)
  "启动阶段耗时：键 \"session|phase\"（两段），值毫秒。
**覆盖**语义：同键重复写入取最后一次（`startup_phases' 的主键是 (session_id, phase)）。
只有**第一个** \"|\" 处切分会话与阶段，故阶段名含 \"|\"（如未来某个
`load:<library>' 的库名）也不会串键，见 `el-chronos-store--split-startup-key'。")
(defvar el-chronos-store--flush-timer nil "周期 flush timer；关闭时取消。")
(defvar el-chronos-store--warned-at nil "上次告警的 `float-time'，用于限流。")
(defvar el-chronos-store--null-session-warned nil "是否已就「会话 ID 缺失」告警过。")
(defvar el-chronos-store--stack-skip-warned nil
  "是否已就「会话不可用、跳过 hourly_stacks」告警过。
每进程只告警一次，故 `el-chronos-store-close' 不重置它。")
(defvar el-chronos-store--aggregate-skip-warned nil
  "是否已就「会话不可用、跳过新聚合（hourly_gc / hourly_health / startup_phases）」告警过。
沿用 `el-chronos-store--stack-skip-warned' 的每进程一次语义；同样不随 close 重置 ——
同一进程里会话长期缺失是同一个问题，反复告警只会制造噪音。")
(defvar el-chronos-store--aggregate-orphan-warned nil
  "是否已就「会话行不存在、跳过新聚合三表写入」告警过。
与上面两个 skip 标志**有意不同**：本标志由 `el-chronos-store-close' 重置。原因：它描述的
是「当前库里那个会话行还在不在」这一具体事实，重开库（尤其换了 `el-chronos-db-path'）
后该事实可能已经变化，重置才能让新问题重新可见；同时也是 I5「关闭后不残留状态」的要求。")
(defvar el-chronos-store--pending-startup-ms nil
  "待补写的 `sessions.startup_ms'（毫秒）；nil 表示无需补写。
**覆盖式、非累加**：它是一次性 `after-init-hook' 回调写入的**单个标量**（每次启动最多发生
一次），重复赋值只取最后一次。后加路径不得把它当计数器用 —— 累加会让 `startup_ms' 变成
几倍的启动耗时，且没有任何地方会发现。
**未消费即丢弃**：`el-chronos-store-close' 会把它置 nil。close 首行已有一次 flush，
通常已经消费；真被丢弃的只是一个标量（下次启动会重算），与既有 5 秒 flush 窗口的崩溃
丢失同级，故不告警。")

;;; 采集器自监控计数器
;;
;; 这 5 个计数器**一律用独立 defvar**，既不放 `--clear-aggregates' 清空的那批 hash，
;; 也不挂 `--buffer' / `--slow-events' 上。理由是设计 §6 的「已知悖论」：
;; 这些容器会在 flush 成功（本批已处理）与 flush 失败（ROLLBACK，本批丢弃）两条路径上
;; 被清空，而「刚刚丢了多少 / 失败了几次」恰恰要在失败**之后**仍然可观测 —— 挂上去就等于
;; 「失败了」这件事永远不可见。生命周期与缓冲彻底解耦之后，归零点只由本模块自己的上报点
;; （COMMIT 成功）控制。

(defvar el-chronos-store--dropped-commands 0
  "因 `--max-buffer-items' 截断而丢弃的命令事件数（整数，单调累加）。
**不进 `--clear-aggregates' 清空的容器**：那批容器的清空点是「本批已处理」/「本批已丢弃」，
一次 flush 失败就会把「刚丢了多少条」一并抹掉，而 flush 失败正是唯一需要这个数字的时刻。
也**不挂 `--buffer'**：那个容器本身会被 ROLLBACK 置 nil，计数随之消失。
归零只在 COMMIT 成功后减去已上报部分（见 `el-chronos-store-flush'），失败路径一分不减。")

(defvar el-chronos-store--dropped-events 0
  "因 `--max-buffer-items' 截断而丢弃的慢事件数（整数，单调累加）。
与 `--dropped-commands' **分开计**：`--push-event' 同时服务命令缓冲与慢事件缓冲，
合并成一个计数会让「慢事件丢了」看起来像「命令丢了」。
**不进 `--clear-aggregates' 清空的容器**、也不挂 `--slow-events'（同 `--dropped-commands'
的理由：那两个位置都会在 flush 失败时被清掉，而失败后必须仍能看到丢弃量）。")

(defvar el-chronos-store--flush-failures 0
  "`el-chronos-store-flush' 失败（ROLLBACK / 抛错）次数（整数，单调累加）。
**不进 `--clear-aggregates' 清空的容器**：这是最不能放进去的一个 —— flush 失败路径必然
执行 `--clear-aggregates'，计数放那儿等于「失败一次、清零一次」，库里的
`flush-failures' 永远是最新一次的 0 或 1。独立 defvar 才能在失败后保留值，
由下一次成功 flush 补写（eventual 语义，写库失败时无法记录失败本身）。
失败分支里 +1，成功路径一分不减（只在成功时减去「已上报」的旧值）。")

(defvar el-chronos-store--flush-count 0
  "已成功的 flush 次数（整数）。
**滞后一个周期上报**：本变量只在 COMMIT 之后 +1，而快照是在 COMMIT 之前取的，所以本次
flush **不**计入本次上报，而是进下一次快照 —— 否则「上报的动作」会改变「被上报的值」，
出现自指（写库时不知道这次算不算成功）。
**非零不参与 `--pending-p'**：flush 之后它恒 ≥ 1，纳入会让 `--pending-p' 永远为真 →
flush timer 每 5 秒都发现「有待写数据」→ 无限 flush 循环（每轮再 +1，永远非零）。
故它只随别的待写数据一起被带出去，单独残留时留在内存等下一次（close 时丢弃）。")

(defvar el-chronos-store--flush-ms-total 0.0
  "已成功 flush 的累计耗时（毫秒，浮点）。
**滞后一个周期上报**：与 `--flush-count' 同理 —— 本次耗时在 COMMIT 之后才累加，
故进下一次快照（`flush-ms' 键）。
**非零不参与 `--pending-p'**：一次 flush 之后它通常 > 0 且单调增长，纳入会让
`--pending-p' 恒为真 → 无限 flush 循环（同 `--flush-count'）。")

;;; 小工具

(defun el-chronos-store--now-ms ()
  "当前 epoch 毫秒（整数）；I4 要求时间戳一律毫秒。"
  (truncate (* 1000 (float-time))))
(defun el-chronos-store--hour-ts ()
  "当前整点的时间戳（毫秒，I4），自监控计数快照按它归属小时。
与 collect 的 `el-chronos-collect--hour-ts' 同口径（整点毫秒、epoch 基准）。
store 侧自带一份而不是反向 require collect：依赖方向是 collect → store，
store 是底层，不能为了一个整点换算引入反向依赖。"
  (* 3600000 (floor (/ (float-time) 3600))))
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
(defun el-chronos-store--aggregate-session (session)
  "新聚合可写时返回 SESSION，否则返回 nil 并每进程告警一次。
`hourly_gc' / `hourly_health' / `startup_phases' 的主键都含 `session_id'，与
`hourly_stacks' 同一理由：写 NULL 行会让主键去重失效，「同会话同小时累加」的语义也不成立，
故宁可不写也不写 NULL 行。会话恢复后（会话行建好、`el-chronos--session-id' 非 nil）
后续记录自然恢复，无需补偿。"
  (cond
   (session session)
   (t
    (unless el-chronos-store--aggregate-skip-warned
      (setq el-chronos-store--aggregate-skip-warned t)
      (display-warning 'el-chronos
                       "会话 ID 缺失，本次已跳过 hourly_gc / hourly_health / startup_phases 写入。"
                       :warning))
    nil)))
(defun el-chronos-store--split-gc-key (key)
  "把 GC 聚合键 \"hour|session\" 拆成 (HOUR SESSION-STRING)。
两段专拆：`--split-key' 要求三段（hour|中间段|名字），用在这里会匹配失败并退化成
(HOUR=0 SESSION=\"\" KEY=整个键)，把数据写到 0 小时、NULL 会话的错行上。"
  (if (string-match "\\`\\([0-9]+\\)|\\([^|]*\\)\\'" key)
      (list (string-to-number (match-string 1 key)) (match-string 2 key))
    (list 0 "")))
(defun el-chronos-store--split-startup-key (key)
  "把启动阶段键 \"session|phase\" 拆成 (SESSION-ID . PHASE)；拆不出会话 ID 时返回 nil。
只在**第一个** \"|\" 处切分：左段必须是纯十进制会话 ID（结构上不含 \"|\"），右段整段是
阶段名（`.*' 截到串尾）。因此阶段名即使含 \"|\"（如某个 `load:<library>' 的库名）也不会
串键 —— 若用 `--split-key' 的三段正则，第二个 \"|\" 会被当成「名字的起点」，阶段名与
会话的对应关系就错位了。"
  (when (string-match "\\`\\([0-9]+\\)|\\(.*\\)\\'" key)
    (cons (string-to-number (match-string 1 key)) (match-string 2 key))))
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
(defun el-chronos-store--note-dropped (slot count)
  "按 SLOT 把本批因截断而丢弃的 COUNT 条事件累加到对应自监控计数器。
`el-chronos-store--buffer' → `--dropped-commands'、
`el-chronos-store--slow-events' → `--dropped-events'。
**必须按 SLOT 分流**：`--push-event' 同时服务两个缓冲，不分开就会把慢事件记进命令计数，
「命令丢了多少」这个数字从此不可信。未知 SLOT 不计数、不抛错（I6）。
这些计数器是独立 defvar（不进 `--clear-aggregates'、不挂缓冲），见其 docstring。"
  (cond
   ((eq slot 'el-chronos-store--buffer)
    (setq el-chronos-store--dropped-commands
          (+ el-chronos-store--dropped-commands count)))
   ((eq slot 'el-chronos-store--slow-events)
    (setq el-chronos-store--dropped-events
          (+ el-chronos-store--dropped-events count)))
   (t nil)))

(defun el-chronos-store--push-event (slot event)
  "把 EVENT（plist）补齐 `:ts' 后推入符号 SLOT 的缓冲，超上限丢最旧项。
截断时把**丢弃条数**记进自监控计数器，口径是**差值**：
「本次 push 后的长度 − `--max-buffer-items'」。当前每次 push 只加一条，正常状态下
差值恒为 1，与「每事件 +1」完全等价；采用差值口径是**防御性**的 —— 将来若改成批量 push
（一次补多条），逐条 +1 的写法会漏计或需要额外遍历，而差值口径天然正确。"
  (let* ((plist (copy-sequence event))
         (buffer (cons nil (symbol-value slot)))
         (new-length (1+ (length (symbol-value slot)))))
    (plist-put plist :ts (or (plist-get plist :ts) (el-chronos-store--now-ms)))
    (setcar buffer plist)
    (when (> new-length el-chronos-store--max-buffer-items)
      (setcdr (nthcdr (1- el-chronos-store--max-buffer-items) buffer) nil)
      ;; 差值 = 截断前长度 − 上限（截断前长度即 new-length）
      (el-chronos-store--note-dropped
       slot (- new-length el-chronos-store--max-buffer-items)))
    (set slot buffer)))

;;; schema 与迁移

(defun el-chronos-store--database-version (db)
  "读取 DB 的 `PRAGMA user_version'，缺失时返回 0。"
  (or (caar (sqlite-select db "PRAGMA user_version")) 0))
(defun el-chronos-store--ensure-schema (db)
  "在 DB 上建全量 10 表 + 3 索引（幂等），并把 user_version 置为当前版本。
它**无条件**把版本写成 `el-chronos-store--schema-version'：因此
`el-chronos-store--schema-ddl' 必须始终是全量 DDL —— 否则新库（版本 0）只建成部分表却
被标记成最新版本，之后 `--migrate' 因版本相等不再运行，缺的表永远不存在。"
  (sqlite-execute-batch db el-chronos-store--schema-ddl)
  (sqlite-pragma db (format "user_version=%d" el-chronos-store--schema-version))
  t)
(defun el-chronos-store--migrate (db path from-version)
  "把已打开的 DB 从 FROM-VERSION 迁移到当前版本。
迁移前 checkpoint 并复制为 PATH.bak；失败则关句柄、用 .bak 覆盖回原文件、删残留
-wal/-shm 并告警，返回 nil（原库可用）。成功返回 t。
两条顺序硬约束（改这里之前先读懂）：
① `.bak' 复制必须在 `BEGIN' **之前** —— 备份要反映迁移前的完整状态；
② 失败时 `ROLLBACK' 必须在 `.bak' 覆盖**之前** —— 先撤事务再动文件，否则覆盖时句柄
   仍持有未回滚事务。"
  (let ((bak (concat path ".bak")))
    (condition-case err
        (progn
          ;; WAL 未 checkpoint 时主文件不含最新数据，复制前先落盘
          (ignore-errors (sqlite-execute db "PRAGMA wal_checkpoint(TRUNCATE)"))
          (when (file-exists-p path) (copy-file path bak t))
          ;; 版本 0 → 当前：建全量表并把版本置为当前版本（由 `--ensure-schema' 完成）
          (when (< from-version 1) (el-chronos-store--ensure-schema db))
          ;; 版本 1 → 2：补建 4 张新表。用 `=' 而非 `<' —— from-version 0 已被上面的
          ;; `--ensure-schema' 建全 10 表并置版本为 2，再跑一遍 v2 脚本虽幂等，但会让
          ;; 失败恢复路径难以推理，语义上也不该走。
          (when (= from-version 1)
            ;; `sqlite-execute-batch' 不自带事务（实测：无显式 BEGIN 时中途报错，
            ;; 先前已执行的语句仍留在库里），故显式包事务，保证「4 张表全有或全无」
            ;; —— 半成品库会让分析层因缺表静默降级，外部 sqlite3 读者看到残缺 schema。
            (sqlite-execute db "BEGIN")
            (sqlite-execute-batch db el-chronos-store--sql-migrate-v2)
            ;; 版本号写死为 2 而不是当前常量：迁移步骤各自负责「把版本推进到本步的
            ;; 目标版本」，将来追加 v2 → v3 时本步仍应只把版本置为 2。
            (sqlite-pragma db "user_version=2")
            (sqlite-execute db "COMMIT"))
          t)
      (error
       ;; 先撤事务（顺序约束 ②），再走既有回滚路径
       (ignore-errors (sqlite-execute db "ROLLBACK"))
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

;;; 变更标记采集（git-head / config-sig）

(defun el-chronos-store--read-trimmed-line (file)
  "读出 FILE 全文并去掉首尾空白；文件不存在、为空或读失败时返回 nil。"
  (when (file-regular-p file)
    (with-temp-buffer
      (insert-file-contents file)
      (let ((text (string-trim (buffer-string))))
        (unless (string-empty-p text) text)))))

(defun el-chronos-store--commit-sha-p (string)
  "STRING 是否是 git 提交 sha 的形态（40 位 SHA-1 或 64 位 SHA-256 小写十六进制）。
只做形态校验，不判断对象是否真的存在 —— 目的是把 `.git' 里的垃圾内容挡在库外。"
  (and (stringp string)
       (> (length string) 0)
       (string-match-p "\\`\\(?:[0-9a-f]\\{40\\}\\|[0-9a-f]\\{64\\}\\)\\'" string)
       t))

(defun el-chronos-store--git-ref-sha (git-dir ref)
  "在 GIT-DIR 下按松散引用 REF（如 \"refs/heads/master\"）读提交 sha；取不到返回 nil。"
  (when (and (stringp ref) (string-prefix-p "refs/" ref))
    (let ((sha (el-chronos-store--read-trimmed-line
                (expand-file-name ref git-dir))))
      (and (el-chronos-store--commit-sha-p sha) sha))))

(defun el-chronos-store--git-packed-ref-sha (git-dir ref)
  "在 GIT-DIR 的 `packed-refs' 里查 REF 对应的提交 sha；取不到返回 nil。
逐行按「`<sha> <refname>'」两字段解析：只接受字段数恰为 2、第二字段与 REF
**完全相等**、第一字段符合 sha 形态的行。注释行（`#'）与 peeled 行（`^'）跳过：
peeled 行只有一个字段（`^<sha>'），本来就是被剥掉 tag 对象的提交，不参与引用解析。
已知盲区（有意不覆盖）：ref 名里含空格（git 本身不允许，故不处理）、
`refs/` 之下的符号引用（`HEAD' 指向另一个 ref 而非 sha）、以及 `.git' 是文件
（worktree / submodule 的 `gitdir: ...' 指针）的情况 —— 后两者一律按「取不到」处理。"
  (let ((file (expand-file-name "packed-refs" git-dir)))
    (when (and (stringp ref) (file-regular-p file))
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        (let (found)
          (while (and (not found) (not (eobp)))
            (let ((line (string-trim
                         (buffer-substring (line-beginning-position)
                                           (line-end-position)))))
              (when (and (not (string-empty-p line))
                         (not (string-prefix-p "#" line))
                         (not (string-prefix-p "^" line)))
                (let ((parts (split-string line)))
                  (when (and (= 2 (length parts))
                             (equal ref (nth 1 parts))
                             (el-chronos-store--commit-sha-p (nth 0 parts)))
                    (setq found (nth 0 parts))))))
            (forward-line 1))
          found)))))

(defun el-chronos-store--git-head ()
  "读 `user-emacs-directory' 下 `.git' 的当前提交 sha（字符串），取不到返回 nil。
三条分支，按优先级：松散引用（`.git/HEAD' = \"ref: refs/heads/X\" →
`.git/refs/heads/X'）→ `packed-refs'（引用已被 pack，松散文件不存在）→
detached HEAD（`HEAD' 内容本身就是 sha）。
**绝不调用 git 子进程**（`call-process' / `shell-command-to-string' 一律禁止）：
启动期 fork+exec 会阻塞主线程，`/mnt/c' 慢 IO 下更甚，且违背「观测不干预」。
全部包在 `condition-case' 内，任何失败都返回 nil —— 不抛错、不告警（I6）；
`git-head' 取不到时不写行（见 `el-chronos-store--record-session-meta-1'）。
隐私（I7）：只记录提交 sha，不记录分支名、远端地址与工作区状态。"
  (condition-case nil
      (let* ((root (file-name-as-directory (expand-file-name user-emacs-directory)))
             (git-dir (expand-file-name ".git/" root))
             (content (el-chronos-store--read-trimmed-line
                       (expand-file-name "HEAD" git-dir))))
        (cond
         ((null content) nil)
         ((string-prefix-p "ref:" content)
          (let ((ref (string-trim (substring content 4))))
            (or (el-chronos-store--git-ref-sha git-dir ref)
                (el-chronos-store--git-packed-ref-sha git-dir ref))))
         ((el-chronos-store--commit-sha-p content) content)
         (t nil)))
    (error nil)))

(defun el-chronos-store--config-entries ()
  "返回 `el-chronos-config-watch-globs' 命中的配置文件 (相对路径 mtime size) 列表。
相对路径相对 `user-emacs-directory'；mtime 取浮点秒（`file-attribute-modification-time'
+ `float-time'），size 取字节数；按相对路径升序排序以保证指纹稳定。
只按 glob 展开，**不遍历整个配置目录**；目录（glob 命中同名目录）与读不到属性的
条目跳过。"
  (let* ((root (file-name-as-directory (expand-file-name user-emacs-directory)))
         (entries nil))
    (dolist (glob (bound-and-true-p el-chronos-config-watch-globs))
      (when (and (stringp glob) (not (string-empty-p glob)))
        (dolist (file (file-expand-wildcards (expand-file-name glob root) t))
          (let ((attrs (file-attributes file)))
            ;; 只要普通文件：glob 可能命中同名目录，目录的 mtime/size 与配置内容无关。
            ;; 用 `file-regular-p'（跟随符号链接）而不是 `file-attribute-type' ——
            ;; 后者在本机 Emacs 31.1 上对普通文件返回 nil（其首位是「是否目录」），
            ;; 按文档语义（t = 普通文件）写会一个文件都收不到，实测踩过。
            (when (and attrs (file-regular-p file))
              (push (list (file-relative-name file root)
                          (float-time (file-attribute-modification-time attrs))
                          (file-attribute-size attrs))
                    entries))))))
    (sort entries (lambda (a b) (string< (car a) (car b))))))

(defun el-chronos-store--config-sig ()
  "配置指纹：`el-chronos-config-watch-globs' 命中文件的 sha1（字符串），取不到返回 nil。
口径：把 (相对路径 mtime size) 列表排序后 `prin1-to-string' 再取 `sha1' ——
只看「哪些配置文件存在、各自何时被改、多大」，**不读文件内容**，因此不泄漏配置正文
（I7：不记录文件路径之外的任何内容；指纹本身不可逆推出内容）。
mtime 用浮点秒（纳秒精度），比格式化字符串稳定且不受 locale / 打印宽度影响。
无任何命中文件时返回 nil（调用方据此**不写行**）；失败同样返回 nil、不抛错、不告警（I6）。"
  (condition-case nil
      (let ((entries (el-chronos-store--config-entries)))
        (when entries
          ;; 绑定打印变量：`print-length' / `print-level' 被用户截断时指纹会失真
          (let ((print-length nil) (print-level nil) (print-escape-newlines nil))
            (secure-hash 'sha1 (prin1-to-string entries)))))
    (error nil)))

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
`-close' 保留 `el-chronos--session-id'，同进程关闭后重开会复用同一行，故重复 open 幂等。
新建会话行之后立刻写变更标记（`git-head' / `config-sig'）——每会话只算一次，属冷路径；
用**传入的 DB** 而**不是**全局 `el-chronos-store--db'（此刻它可能尚未赋值，purge 重建会话
时则是另一条句柄路径）。取不到值的键不写行（见 `--record-session-meta-1'）。"
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
        (let ((id (or (caar (sqlite-select db "SELECT last_insert_rowid()")) 0)))
          ;; 顺序硬约束：先拿到会话 id，再写 meta（`session_meta' 的主键含 session_id）
          (el-chronos-store--record-session-meta-1
           db id "git-head" (el-chronos-store--git-head))
          (el-chronos-store--record-session-meta-1
           db id "config-sig" (el-chronos-store--config-sig))
          id)))))

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
遇到已取消的 timer，也避免登记表在反复 open/close 后无限增长。
`el-chronos-store--pending-startup-ms' 与孤儿会话告警标志一并清零（I5 零残留）：
前者是「未消费即丢弃」的标量（close 首行的 flush 通常已消费它），后者描述的是当前库里
会话行是否存在这一具体事实，重开库后需要重新判定。
5 个自监控计数器（`--dropped-commands' / `--dropped-events' / `--flush-failures' /
`--flush-count' / `--flush-ms-total'）一并清零，且**这里是它们唯一的无条件清零点**：
它们与 `--clear-aggregates' 刻意分离 —— 后者是 flush 路径的「本批数据已处理 / 已丢弃」
语义（每次 flush 都跑，成功失败都跑），本处是 close 路径的「进程内状态归零」语义。
混在一起会出两种错：同进程反复 open/close 时把上一轮的计数带进新会话；
或某条 flush 路径顺手抹掉「已丢了多少」。close 前已有一次 flush，正常情况已上报；
未上报的部分随 close 丢弃，与既有 5 秒 flush 窗口的崩溃丢失同级，故不告警。"
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
        el-chronos-store--stacks (make-hash-table :test #'equal)
        ;; 三个新聚合 hash 同样清零（I5 零残留）：close 前已 flush 过，留下只会让同进程
        ;; 重开时把上一会话的 GC / 自监控 / 启动阶段记到新会话名下
        el-chronos-store--gc (make-hash-table :test #'equal)
        el-chronos-store--health (make-hash-table :test #'equal)
        el-chronos-store--startup (make-hash-table :test #'equal)
        ;; `startup_ms' 补写标量「未消费即丢弃」：close 首行已 flush 过一次，通常已消费；
        ;; 真被丢弃的只是一个标量（下次启动会重算），与 5 秒 flush 窗口的崩溃丢失同级，不告警
        el-chronos-store--pending-startup-ms nil
        ;; 5 个自监控计数器归零（I5 零残留）。**必须与 `--clear-aggregates' 分开**：
        ;; 那个函数是 flush 路径「本批已处理/已丢弃」的语义，每次 flush 都会跑；
        ;; 这里是 close 路径「进程内状态归零」的语义。混用会让 flush 顺手抹掉
        ;; 「丢了多少 / 失败几次」，而这两件事恰恰要在失败之后仍可观测。
        el-chronos-store--dropped-commands 0
        el-chronos-store--dropped-events 0
        el-chronos-store--flush-failures 0
        el-chronos-store--flush-count 0
        el-chronos-store--flush-ms-total 0.0
        ;; 孤儿会话告警标志重置：它描述「当前库里那个会话行还在不在」，重开库后该事实可能
        ;; 已变，重置才能让新问题重新可见（I5：关闭后不留状态）
        el-chronos-store--aggregate-orphan-warned nil)
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
(defun el-chronos-store-record-gc (hour-ts gc-count gc-ms heap-bytes)
  "累加按小时的 GC 统计：HOUR-TS 整点毫秒，GC-COUNT 次数，GC-MS 耗时（毫秒）。
HEAP-BYTES 为**堆大小字节数，nil 表示本窗口没有堆样本**（采集稀疏，每
`el-chronos-heap-sample-windows' 个窗口才有一次）：此时该行的 `heap_bytes' 保持上一次
观测值不变，只有非 nil 才覆盖 —— 由 `el-chronos-store--sql-upsert-gc' 的 COALESCE 保证，
本函数只负责「nil 不更新缓冲区里的 heap 槽」。
会话 ID 缺失时跳过并每进程告警一次（I6：不抛错）。"
  (condition-case err
      (when (el-chronos-store--aggregate-session el-chronos--session-id)
        (let* ((cell-key (format "%d|%s" hour-ts
                                 (el-chronos-store--session-key-part)))
               (cell (gethash cell-key el-chronos-store--gc)))
          (if cell
              (progn
                (aset cell 0 (+ (aref cell 0) (or gc-count 0)))
                (aset cell 1 (+ (aref cell 1) (float (or gc-ms 0))))
                ;; nil 段必须留住上一次观测值（同 COALESCE 的语义，在内存里先做一遍）
                (when heap-bytes (aset cell 2 heap-bytes)))
            (puthash cell-key (vector (or gc-count 0) (float (or gc-ms 0)) heap-bytes)
                     el-chronos-store--gc))
          t))
    (error (el-chronos-store--warn "记录 GC 聚合失败（已跳过）：%S" err) nil)))
(defun el-chronos-store-record-health (hour-ts key value)
  "累加采集器自监控计数：同 (HOUR-TS, KEY) 在库内累加 VALUE（数或毫秒）。
KEY 取固定枚举字符串（`dropped-commands' / `dropped-events' / `flush-failures' /
`flush-count' / `flush-ms' / `sample-misses'），不含 \"|\"。
累计口径与「事件数」等价：flush 失败等计数在**下一次成功 flush 时**才落库
（写库失败时无法记录失败本身），故库里是 eventual 值，滞后上限一次成功 flush 的间隔。
会话 ID 缺失时跳过并每进程告警一次（I6：不抛错）。"
  (condition-case err
      (when (el-chronos-store--aggregate-session el-chronos--session-id)
        (let ((cell-key (format "%d|%s|%s" hour-ts
                                (el-chronos-store--session-key-part) key)))
          (puthash cell-key
                   (+ (or (gethash cell-key el-chronos-store--health) 0)
                      (float (or value 0)))
                   el-chronos-store--health)
          t))
    (error (el-chronos-store--warn "记录自监控计数失败（已跳过）：%S" err) nil)))
(defun el-chronos-store-record-startup-phase (session-id phase ms)
  "记录启动阶段耗时：`startup_phases' 中 (SESSION-ID, PHASE) 一行，重复打点**覆盖**。
PHASE 取 `mode-start' / `after-init' / `startup' / `first-idle'，包加载明细用
\"load:<library>\"；MS 为毫秒。PHASE 允许含 \"|\"（键只在第一个 \"|\" 处切分）。
SESSION-ID 缺失时跳过并每进程告警一次（I6：不抛错）。"
  (condition-case err
      (when (el-chronos-store--aggregate-session session-id)
        (puthash (format "%d|%s" session-id phase) (float (or ms 0))
                 el-chronos-store--startup)
        t)
    (error (el-chronos-store--warn "记录启动阶段失败（已跳过）：%S" err) nil)))

;;; 直接写库（不走缓冲）

(defun el-chronos-store--record-session-meta-1 (db session-id key value)
  "用 DB 把 SESSION-ID / KEY / VALUE 写入 `session_meta'（VALUE 为 nil 时**不写行**）。
内部版本：**不依赖全局 `el-chronos-store--db'**，显式接收句柄 —— `--ensure-session' 建会话行
时全局句柄可能还没赋值，purge 重建会话走的也是调用方持有的句柄。
为什么直接 `sqlite-execute' 而不进 flush 缓冲：变更标记是「每会话一次」的冷路径，
立即写库可立刻可见、不占缓冲、不参与批量事务，失败也能独立限流告警
（不会被别处的 flush 失败一并丢弃）；也就不进 `--clear-aggregates' 的丢弃路径。
VALUE 为 nil / DB 或 SESSION-ID 为 nil 时直接返回 nil（KV 表里的空值没有信息量，
且会让「取不到」与「取了但为空」在查询层不可区分）。
成功返回 t；失败降级为限流告警并返回 nil（I6：不抛错）。"
  (when (and db session-id key value)
    (condition-case err
        (progn
          (sqlite-execute db el-chronos-store--sql-upsert-session-meta
                          (list session-id
                                (if (stringp key) key (format "%s" key))
                                (if (stringp value) value (format "%s" value))))
          t)
      (error (el-chronos-store--warn "写入 session_meta 失败（已跳过）：%S" err) nil))))

(defun el-chronos-store-record-session-meta (session-id key value)
  "把会话级元数据 SESSION-ID / KEY / VALUE **直接写入** `session_meta'，不走缓冲。
为什么直接写而不进 flush 事务（O10 定案）：这是「每会话一次」的冷路径，立即写库可立刻
可见、不占缓冲、不参与批量事务，失败也能独立限流告警（不会因为别处的 flush 失败而被
一并丢弃）。代价是每次调用一次同步写入，调用点必须只在冷路径（如 `--ensure-session'）。
VALUE 为 nil 时**不写行**（KV 表里的空值没有信息量，且会让「取不到」与「取了但为空」
在查询层不可区分）；`el-chronos-store--db' 为 nil（未打开）时直接返回 nil、不报错。
成功返回 t；失败 `condition-case' 降级为限流告警并返回 nil（I6：不抛错）。
对外入口只补一次「全局句柄是否可用」的门；实际写入走 `--record-session-meta-1'。"
  (when el-chronos-store--db
    (el-chronos-store--record-session-meta-1
     el-chronos-store--db session-id key value)))

;;; 启动耗时补写（纯内存打点，落库并入下一次 flush）

(defun el-chronos-store-note-startup-ms (ms)
  "登记待补写的启动耗时 MS（毫秒，纯内存操作），落库交给下一次 `el-chronos-store-flush'。
触发场景（并非只有 early-init）：**mode 在 `after-init-hook' 之前启用**时，
`--ensure-session' 建会话行那一刻 `after-init-time' 仍是 nil，`startup_ms' 落 NULL
（`startup.el' 先设 `after-init-time' 再跑 `after-init-hook'，两行都在 init 文件加载之后）。
collect 侧的 `after-init-hook' 回调算出 `before-init-time' → `after-init-time' 的差值后
调本函数登记，由下一次 flush 在既有事务内补写（计划设计 7 处置 ③）。
**调用方须保证这是纯内存操作**：本函数不碰 sqlite、不告警、不抛错、不登记 timer ——
目的是让启动期零 IO（否则 `busy_timeout=2000ms' 最坏会把启动拖住 2 秒）。
因此**禁止在钩子路径上做任何库操作**（`sqlite-execute' / `sqlite-select' 一类一律不许
出现在钩子内），也**不要**为此新增 timer：复用既有 5 秒 flush timer 即可，I5 的清理清单
不必扩。
`el-chronos-store--db' 或 `el-chronos--session-id' 为 nil 时**忽略**（无库可写 / 无会话可
归属，登记了也只会被丢弃）；两处都要判：`store-close' 会保留 session-id 却把 db 置 nil。"
  (when (and el-chronos-store--db el-chronos--session-id)
    (setq el-chronos-store--pending-startup-ms ms))
  nil)

;;; flush

(defun el-chronos-store--pending-p ()
  "是否还有未落库的缓冲。
三个新聚合 hash（`--gc' / `--health' / `--startup'）与 `--pending-startup-ms' **必须**在这里
逐一列出：`el-chronos-store-flush' 的第一道门是 `(and db (--pending-p))'，漏掉任何一个都会让
「只有该类数据待写」时 flush 直接早退 —— 数据永不落库且没有任何报错（静默丢数据）。
`--pending-startup-ms' 最容易漏：空闲会话（启动后没人敲命令、profiler 也采不到样本）里
它是**唯一**残留，漏了补写就永远不发生。

自监控计数器里**只列 `--dropped-commands' / `--dropped-events' / `--flush-failures'**
三个：它们表示「有数据还没进库」（丢弃量与失败次数都是待补写的真实信息），单独残留时
必须触发一次 flush 才能补写。
**`--flush-count' / `--flush-ms-total' 绝不能列进来**：它们每次成功 flush 之后都变成非零
且单调不减，纳入会让 `--pending-p' **恒为真** → flush timer 每 5 秒都判定「有待写数据」
并跑一次事务，而每次成功又继续 +1 / 累加 → 永远非零 → 无限 flush 循环（空转事务、
磁盘与 CPU 都被白烧，且 `flush-count' 的值本身被自己的上报行为无限推高）。
它们只搭别的待写数据的便车上报；单独残留时留在内存（eventual，close 时丢弃）。"
  (or el-chronos-store--buffer el-chronos-store--slow-events
      (> (hash-table-count el-chronos-store--usage) 0)
      (> (hash-table-count el-chronos-store--functions) 0)
      (> (hash-table-count el-chronos-store--stacks) 0)
      (> (hash-table-count el-chronos-store--gc) 0)
      (> (hash-table-count el-chronos-store--health) 0)
      (> (hash-table-count el-chronos-store--startup) 0)
      el-chronos-store--pending-startup-ms
      (> el-chronos-store--dropped-commands 0)
      (> el-chronos-store--dropped-events 0)
      (> el-chronos-store--flush-failures 0)))
(defun el-chronos-store--aggregates-pending-p ()
  "三个新聚合 hash（gc / health / startup）是否有待写数据。"
  (or (> (hash-table-count el-chronos-store--gc) 0)
      (> (hash-table-count el-chronos-store--health) 0)
      (> (hash-table-count el-chronos-store--startup) 0)))
(defun el-chronos-store--warn-orphan-aggregates ()
  "就「会话行不存在、跳过新聚合三表写入」告警一次（每进程一次，close 时重置标志）。"
  (unless el-chronos-store--aggregate-orphan-warned
    (setq el-chronos-store--aggregate-orphan-warned t)
    (display-warning
     'el-chronos
     "会话行不存在，本次已跳过 hourly_gc / hourly_health / startup_phases 写入。"
     :warning)))

;;; 自监控计数的上报快照

(defun el-chronos-store--health-snapshot ()
  "取自监控计数快照：((KEY . VALUE) ...)，**只含非零项**。
为什么只写非零值：空闲会话里多数计数器长期为 0，无条件写会让每小时
都多出几行恒 0 的 `hourly_health' 行 ——「0 次丢弃」没有信息量，
反而让「这一小时没有任何自监控数据」与「有数据但都是 0」在查询层
不可区分。
为什么在事务开始**之前**取：COMMIT 成功后要按这份快照把已上报部分从
计数器里**减掉**（不是无条件置 0）。若在事务中间或之后取，
上报期间新发生的丢弃会被一并抹掉。
键名与 `el-chronos-store-record-health' 的枚举一致，集中定义在本函数
与该函数 docstring 里以避免拼写漂移：
`dropped-commands' / `dropped-events' / `flush-failures' /
`flush-count' / `flush-ms'。"
  (delq nil
        (list (when (> el-chronos-store--dropped-commands 0)
                (cons "dropped-commands" el-chronos-store--dropped-commands))
              (when (> el-chronos-store--dropped-events 0)
                (cons "dropped-events" el-chronos-store--dropped-events))
              (when (> el-chronos-store--flush-failures 0)
                (cons "flush-failures" el-chronos-store--flush-failures))
              (when (> el-chronos-store--flush-count 0)
                (cons "flush-count" el-chronos-store--flush-count))
              (when (> el-chronos-store--flush-ms-total 0)
                (cons "flush-ms" el-chronos-store--flush-ms-total)))))
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
  "清空慢事件缓冲与六个聚合 hash（命令缓冲由调用方按会话状态决定）。
把 hash 换成新表而不是 `clrhash'，避免仍在遍历旧表的 `maphash' 回调看到被清空的内容。
六个聚合 = 既有 usage / functions / stacks + 新增 gc / health / startup：
它们同一批被 flush 写入同一事务，故成败路径都必须同批清空（否则成功路径会重复累加，
失败路径会无界增长）。
**自监控计数器（`--dropped-commands' / `--dropped-events' / `--flush-failures' /
`--flush-count' / `--flush-ms-total'）刻意不在这里**：本函数的两个调用点分别是
「本批已处理」（COMMIT 成功）与「本批已丢弃」（ROLLBACK），两者都要清掉「这批数据」，
而计数器描述的是「发生过多少次丢弃/失败」这一跨批次事实 —— 清掉它等于让 flush 失败
这件事永远不可观测（设计 §6 的「已知悖论」）。它们的归零点由 `el-chronos-store-flush'
在 COMMIT 之后单独控制（减去已上报部分，不是无条件清零）。"
  (setq el-chronos-store--slow-events nil
        el-chronos-store--usage (make-hash-table :test #'equal)
        el-chronos-store--functions (make-hash-table :test #'equal)
        el-chronos-store--stacks (make-hash-table :test #'equal)
        el-chronos-store--gc (make-hash-table :test #'equal)
        el-chronos-store--health (make-hash-table :test #'equal)
        el-chronos-store--startup (make-hash-table :test #'equal)))
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
ROLLBACK 后清空六类聚合缓冲（慢事件 + usage / functions / stacks / gc / health / startup），
只保留失败计数性质的限流告警（10 分钟最多一次，I6），不向宿主抛错。
会话不可用（ID 为 nil 或 `sessions' 表无对应行）时跳过 `hourly_stacks' 写入，
其余表照常，保证不产生 session_id 为 NULL 的栈行。

此外在同一事务内写三张新聚合表：`hourly_gc'（次数/耗时累加、堆大小 COALESCE 保旧值）、
`hourly_health'（累加）、`startup_phases'（按 (session_id, phase) 覆盖）。
`session_meta' **不参与** flush —— 它由 `el-chronos-store-record-session-meta' 直接写库。
这三张新表写入前先校验会话行存在（它们无外键，孤儿行 purge 删不掉），不存在则整批跳过并
每进程告警一次。
同一事务内还会把 `el-chronos-store--pending-startup-ms' 补写进 `sessions.startup_ms'
（`UPDATE ... WHERE id = ? AND startup_ms IS NULL'）：补写成功且 COMMIT 成功才清 pending，
失败或回滚都保留待下次（eventual，值可能晚到一个 flush 周期但不会丢）。"
  (interactive)
  (when (and el-chronos-store--db (el-chronos-store--pending-p))
    (let* ((db el-chronos-store--db)
           (session el-chronos--session-id)
           (stack-session (el-chronos-store--stack-session el-chronos-store--db
                                                            el-chronos--session-id))
           ;; 新聚合三表 + `startup_ms' 补写共用这一次存在性判定（每批只有一个会话，
           ;; 故只需查一次）：见下方「孤儿 session_id」注释
           (session-known (and session (el-chronos-store--session-known-p
                                        el-chronos-store--db session)))
           (startup-written nil)
           (groups nil)
           ;; 自监控计数：快照在事务前取，COMMIT 成功后才按它减去（见 `--health-snapshot'）
           (health-snapshot (el-chronos-store--health-snapshot))
           (health-written nil)
           (flush-start (float-time)))
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
            ;; 新聚合：GC 统计 / 自监控计数 / 启动阶段（同一事务，与既有聚合一起提交）。
            ;; **写入前必须校验会话行存在**（`session-known'，每批只有一个会话、查一次）：
            ;; 这三张表**刻意无外键**（避免 purge 的删除顺序与级联约束耦合），所以数据库
            ;; 不会替我们挡住孤儿 session_id —— 一旦写入一个不存在的会话，
            ;; `el-chronos-purge' 的 `session_id IN (SELECT id FROM sessions ...)' 子查询
            ;; 永远定位不到这些行，它们会**永久残留且不报错**（同类风险面上还有存
            ;; git-head / config-sig 的 `session_meta'，那是隐私数据，更不能残留）。
            ;; 会话不可用时本批的这三个 hash 与 flush 失败一样被丢弃（`--clear-aggregates'），
            ;; 只留一条每进程一次的告警。
            (cond
             (session-known
              ;; GC 的键只有两段（hour|session），必须用专用拆分函数，见 `--split-gc-key'
              (maphash (lambda (key value)
                         (let ((parts (el-chronos-store--split-gc-key key)))
                           (sqlite-execute
                            db el-chronos-store--sql-upsert-gc
                            (list (nth 0 parts)
                                  (el-chronos-store--parse-session (nth 1 parts))
                                  (aref value 0) (aref value 1) (aref value 2)))))
                       el-chronos-store--gc)
              (maphash (lambda (key value)
                         (el-chronos-store--upsert db key (vector value)
                                                   el-chronos-store--sql-upsert-health nil))
                       el-chronos-store--health)
              ;; 自监控计数快照：与上面各表**同一事务**提交，故「库里有值」与
              ;; 「本批数据确实落库」严格同态（不存在「计数写了、数据回滚了」的半态）。
              ;; 会话行存在才写（`hourly_health' 无外键，孤儿行 purge 删不掉），
              ;; 与三张新表同一判定；会话未知时计数器**一分不减**，等下次补写。
              (dolist (entry health-snapshot)
                (sqlite-execute db el-chronos-store--sql-upsert-health
                                (list (el-chronos-store--hour-ts) session
                                      (car entry) (float (cdr entry)))))
              (setq health-written t)
              ;; 启动阶段的键是 session|phase，只在第一个 "|" 处切分（phase 可含 "|"）
              (maphash (lambda (key value)
                         (let ((parts (el-chronos-store--split-startup-key key)))
                           (when parts
                             (sqlite-execute db el-chronos-store--sql-upsert-startup
                                             (list (car parts) (cdr parts) value)))))
                       el-chronos-store--startup))
             ;; 没有待写数据时不告警（否则「只有 pending-startup-ms 且会话未知」也会噪声告警）
             ((el-chronos-store--aggregates-pending-p)
              (el-chronos-store--warn-orphan-aggregates)))
            ;; `startup_ms' 补写（计划设计 7 处置 ③）：并入同一事务，`IS NULL' 守卫见
            ;; `el-chronos-store--sql-update-startup-ms'。**单独** condition-case ——
            ;; 补写失败只记录并保留 pending（下次 flush 重试），不因此主动放弃本批其余表：
            ;; 补写是「附加值」，为它回滚掉一批采集数据是明显的取舍颠倒。
            (when (and el-chronos-store--pending-startup-ms session-known)
              (condition-case err
                  (progn
                    (sqlite-execute db el-chronos-store--sql-update-startup-ms
                                    (list (float el-chronos-store--pending-startup-ms)
                                          session))
                    (setq startup-written t))
                (error (el-chronos-store--warn
                        "补写 startup_ms 失败（本批其余表照常提交，pending 保留待下次）：%S"
                        err))))
            (sqlite-execute db "COMMIT")
            ;; **COMMIT 成功之后**才算消费掉 pending：ROLLBACK 或补写失败都不清，留待下次
            ;; （eventual 语义：值可能晚到一次 flush 周期，但不会丢）。
            (when startup-written (setq el-chronos-store--pending-startup-ms nil))
            ;; 自监控计数（同样只在 COMMIT 成功之后才动）：
            ;; ① 把**已上报**的部分从计数器里**减去** —— 不是无条件置 0。上报期间（本事务
            ;;    期间）新发生的丢弃/失败必须留住；置 0 会把它们静默吞掉，库里就少记了。
            ;; ② 再把**本次** flush 的耗时与次数累加进去。这两步都排在快照之后，所以本次
            ;;    flush 只会在**下一次**被上报（滞后一个周期）—— 否则「上报的动作」会改变
            ;;    「被上报的值」，构成自指（写库那一刻还不知道这次算不算成功）。
            ;; 库内该键的累计值 + 内存里的未上报差额 = 真实总量。
            (when health-written
              (dolist (entry health-snapshot)
                (let ((value (cdr entry)))
                  (cond
                   ((equal (car entry) "dropped-commands")
                    (setq el-chronos-store--dropped-commands
                          (- el-chronos-store--dropped-commands value)))
                   ((equal (car entry) "dropped-events")
                    (setq el-chronos-store--dropped-events
                          (- el-chronos-store--dropped-events value)))
                   ((equal (car entry) "flush-failures")
                    (setq el-chronos-store--flush-failures
                          (- el-chronos-store--flush-failures value)))
                   ((equal (car entry) "flush-count")
                    (setq el-chronos-store--flush-count
                          (- el-chronos-store--flush-count value)))
                   ((equal (car entry) "flush-ms")
                    (setq el-chronos-store--flush-ms-total
                          (- el-chronos-store--flush-ms-total value)))))))
            (setq el-chronos-store--flush-count (1+ el-chronos-store--flush-count)
                  el-chronos-store--flush-ms-total
                  (+ el-chronos-store--flush-ms-total
                     (* 1000.0 (- (float-time) flush-start))))
            (when session (setq el-chronos-store--buffer nil))
            (el-chronos-store--clear-aggregates)
            t)
        (error
         (ignore-errors (sqlite-execute db "ROLLBACK"))
         ;; 自监控：失败次数 +1，其余 4 个计数器**一分不减**（丢弃量、已成功的 flush 次数与
         ;; 累计耗时都不因本次失败而改变）。特别注意别在这里调用任何会清计数器的逻辑 ——
         ;; 下面紧跟的 `--clear-aggregates' 清的是「本批数据」容器，计数器不在其中（见其
         ;; docstring）。这些值等下一次成功 flush 补写（eventual，滞后上限一次成功 flush
         ;; 的间隔；库长期不可写时无上限）。
         (setq el-chronos-store--flush-failures
               (1+ el-chronos-store--flush-failures))
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
只删 `commands' 与 `slow_events'；**五张** hourly_* 聚合表（`hourly_functions' /
`hourly_usage' / `hourly_stacks' / `hourly_gc' / `hourly_health'）永久保留，
只由 `el-chronos-purge' 清理。"
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
(defconst el-chronos-store--stale-session-sql
  "started_at < ? AND id NOT IN (SELECT DISTINCT session_id FROM commands WHERE ts >= ?)"
  "判定「已过期且没有存活子行」的会话的 WHERE 片段；两个占位符都绑同一个 BEFORE。

为什么必须排除「仍有 `ts >= BEFORE' 的 commands 行的会话」：`commands' 按 `ts'
删、`sessions' 按 `started_at' 删，两者的时间口径不同。一个「很久以前启动、今天还在
运行」的会话满足 `started_at < BEFORE'，但它名下还有 `ts >= BEFORE' 的 commands 行 ——
直接 `DELETE FROM sessions' 会撞 `commands.session_id REFERENCES sessions(id)' 外键
（`--open-db' 开了 `foreign_keys=ON'），让**整个 purge 事务回滚**：一条数据都没删掉，
用户却只看得到一句限流告警。`el-chronos-purge' 是隐私清理手段（`session_meta' 存
git-head / config-sig），「以为删了其实没删」比「少删几个会话」严重得多，所以宁可
保留这个会话（它的过期明细照样按 `ts' 删掉），也不能让整批失败。

`NOT IN' 在这里安全：`commands.session_id' 声明为 `NOT NULL'，子查询不会产生 NULL
（若可能产生 NULL，`NOT IN' 恒为 unknown，会静默地一行都不删 —— 那正是要避免的故障形态）。")
(defconst el-chronos-store--purge-targets
  '(("commands" . ts)
    ("slow_events" . ts)
    ("startup_phases" . stale-session-rows)
    ("session_meta" . stale-session-rows)
    ("hourly_functions" . hour-ts)
    ("hourly_usage" . hour-ts)
    ("hourly_stacks" . hour-ts)
    ("hourly_gc" . hour-ts)
    ("hourly_health" . hour-ts)
    ("sessions" . stale-session))
  "`el-chronos-purge' 的删除顺序：10 张表，**顺序不可改**。
元素是 (表名 . 删除策略)，策略决定该表用哪种条件删（`before' 为 nil 时全部退化为
无条件 `DELETE FROM <table>'）：

- `ts' / `hour-ts'：表里有时间列，按列删（`ts < ?' / `hour_ts < ?'），
  交给 `el-chronos-store--delete-rows'。
- `stale-session-rows'：表里**没有时间列**，只能按所属会话删；判据是
  「会话已过期且没有存活子行」（`el-chronos-store--stale-session-sql'），
  交给 `el-chronos-store--delete-rows-of-stale-sessions'。
- `stale-session'：`sessions' 行自身，用同一判据（`started_at < ?' 且无存活子行），
  交给 `el-chronos-store--delete-stale-sessions'。

两条**互不相同**的顺序理由，不要混为一谈：

1. `commands' 必须最先 —— 它是唯一带外键的表
   （`session_id REFERENCES sessions(id)'，且 `--open-db' 开了 `foreign_keys=ON'）。
   留到删 `sessions' 之后再删就会直接撞外键约束，整个 purge 回滚。
2. `startup_phases' / `session_meta' 必须早于 `sessions' —— 驱动理由**不是外键**而是子查询：
   它们的删除条件依赖 `SELECT id FROM sessions ...'。若先删 `sessions'，
   子查询在删空之后恒为空 → 这两张表的行**永远不会被删除且不报错**，静默留下孤儿。
   `session_meta' 还存 git-head / config-sig（隐私），残留等于 purge 的语义被破坏。

三张会话相关的表（`sessions' 与两张会话级子表）共用**同一个**过期判据
（`el-chronos-store--stale-session-sql'），保证「一个会话要么整体删、要么整体保留」：
若只给 `sessions' 加存活排除而子表仍按 `started_at' 删，保留下的会话会变成
「会话行在、startup_phases / session_meta 却没了」的半截状态，反而破坏归因。

`before' 为 nil（清空全部）时所有表都走无条件删除，子查询不参与，顺序此时无关紧要；
但仍按同一顺序、走同一份数据结构执行，保持**单一代码路径**（一个顺序覆盖两种 `before'）。")
(defun el-chronos-store--delete-rows (db table column before)
  "删除 DB 中 TABLE 里 COLUMN 早于 BEFORE 的行；BEFORE 为 nil 时清空全表。返回行数。"
  (or (if before
          (sqlite-execute db (format "DELETE FROM %s WHERE %s < ?" table column)
                          (list before))
        (sqlite-execute db (format "DELETE FROM %s" table)))
      0))
(defun el-chronos-store--delete-stale-sessions (db before)
  "删除 DB 中「已过期且无存活子行」的会话；BEFORE 为 nil 时清空全表。返回行数。
判据见 `el-chronos-store--stale-session-sql'（为什么不能只按 `started_at' 删也写在那里）。"
  (or (if before
          (sqlite-execute db (format "DELETE FROM sessions WHERE %s"
                                     el-chronos-store--stale-session-sql)
                          (list before before))
        (sqlite-execute db "DELETE FROM sessions"))
      0))
(defun el-chronos-store--delete-rows-of-stale-sessions (db table before)
  "删除 DB 中 TABLE 里属于「已过期且无存活子行」会话的行；BEFORE 为 nil 时清空全表。
返回行数。只服务 `startup_phases' / `session_meta' 这两张「会话级、无时间列」的表。

为什么不给 `el-chronos-store--delete-rows' 扩签名：它只表达 `COLUMN < ?' 一种形态，
若为了子查询再把表名、列名、整段 WHERE 片段都塞进去，这个通用函数就退化成 SQL 拼接器，
调用点也看不出究竟在删什么。这里单开一个函数，WHERE 只引用
`el-chronos-store--stale-session-sql' 这一个片段，表名来自常量
`el-chronos-store--purge-targets' 而非用户输入。

判据与会话行**共用**：保证保留下来的会话不会只剩半截数据（见计划设计 8 与 X1）。"
  (or (if before
          (sqlite-execute
           db
           (format "DELETE FROM %s WHERE session_id IN (SELECT id FROM sessions WHERE %s)"
                   table el-chronos-store--stale-session-sql)
           (list before before))
        (sqlite-execute db (format "DELETE FROM %s" table)))
      0))
(defun el-chronos-purge (&optional before)
  "删除 BEFORE（epoch 毫秒）之前的全部数据；BEFORE 为 nil 时清空全部 10 张表。
返回按删除顺序排列的 ((表名 . 删除行数) ...)。
与 `-prune' 的区别是连 hourly_* 聚合、会话级数据（`startup_phases' / `session_meta'）
以及 `sessions' 行本身一起删 —— 10 张表 vs 2 张表。

删除顺序见常量 `el-chronos-store--purge-targets'：先 `commands'（唯一有外键的表），
再 `startup_phases' / `session_meta'（删除条件靠子查询定位会话），最后 `sessions'。
顺序颠倒会分别造成「撞外键报错」与「静默不删的孤儿」两种不同故障。
`before' 为 nil 时所有表无条件清空，子查询不参与，但顺序不变（单一代码路径）。

**过期会话的判据**（`el-chronos-store--stale-session-sql'）：`started_at < BEFORE'
且名下没有 `ts >= BEFORE' 的 commands 行。后者不能省：一个「很久以前启动、今天还在
运行」的会话若被直接删掉，会撞 `commands.session_id' 外键 → **整批事务回滚**，
purge 一条都没删。本函数是隐私清理手段，宁可保留这类会话（它的过期明细照样删），
也不能让它整体失败。三张会话相关表共用该判据，避免留下「会话在、meta 没了」的半截状态。

purge 会删掉当前会话行，故结束后用 `--ensure-session' 补建一行（否则后续写入撞外键），
并把它刚写入的 `startup_ms' **显式置 NULL**：`--ensure-session' 用
`before-init-time' → `after-init-time' 求差，运行中的 Emacs 里两者都非 nil，
会让 `started_at = 现在' 的行带上「本进程几小时前启动」的耗时，语义自相矛盾。"
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
          (dolist (target el-chronos-store--purge-targets)
            (let ((table (car target)) (strategy (cdr target)))
              (push (cons table
                          (pcase strategy
                            ('ts (el-chronos-store--delete-rows db table "ts" before))
                            ('hour-ts (el-chronos-store--delete-rows db table "hour_ts" before))
                            ('stale-session-rows
                             (el-chronos-store--delete-rows-of-stale-sessions db table before))
                            ('stale-session
                             (el-chronos-store--delete-stale-sessions db before))
                            (_ (error "未知的 purge 删除策略：%S" strategy))))
                    result)))
          (sqlite-execute db "COMMIT")
          ;; purge 可能删掉当前会话行：立刻补建，否则后续写入会撞外键约束
          (when (boundp 'el-chronos--session-id)
            (setq el-chronos--session-id (el-chronos-store--ensure-session db))
            ;; 重建行的 `startup_ms' 语义上是「本进程的启动耗时」，与刚写的 `started_at'
            ;; （现在）矛盾 —— 置 NULL 表示「本会话行是 purge 补建的，启动耗时未知」。
            ;; 失败不影响 purge 结果本体，故不抛错也不告警（I6）。
            (ignore-errors
              (sqlite-execute db "UPDATE sessions SET startup_ms = NULL WHERE id = ?"
                              (list el-chronos--session-id))))
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
