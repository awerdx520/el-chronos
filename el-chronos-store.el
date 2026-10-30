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
;;   - `commands' / `slow_events' 按 `el-chronos-retention-days' 清理，七张 hourly_*
;;     聚合表（`hourly_functions' / `hourly_usage' / `hourly_stacks' / `hourly_gc' /
;;     `hourly_health' / `hourly_drift' / `hourly_resources'）永久保留、只由
;;     `el-chronos-purge' 手动清理；
;;   - `hourly_stacks' 每 (hour_ts, session_id) 只留 samples 最大的 top-N 条。
;; 单位（I4）：时间戳与耗时用毫秒，采样间隔用纳秒；数据只写 `el-chronos-db-path'。

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'sqlite)
(require 'el-chronos)

;;; 常量

(defconst el-chronos-store--schema-version 5
  "支持的 schema 版本，对应 `PRAGMA user_version'；升级时递增并追加迁移步骤。
版本 5 = 新增 hourly_gc_attrib 表（GC 归因：**GC 发生在**哪条命令之后 / 哪个 mode 里，
按 hour × session × command × mode 累加，增量脚本见
`el-chronos-store--sql-migrate-v5'）；
版本 4 = 新增 hourly_resources 表（进程 CPU / RSS / 线程数 / 系统负载的按小时聚合，
增量脚本见 `el-chronos-store--sql-migrate-v4'）；
版本 3 = 新增 hourly_drift 表（增量脚本见 `el-chronos-store--sql-migrate-v3'）；
版本 2 = 新增 hourly_gc / startup_phases / hourly_health / session_meta 四表
（增量脚本见 `el-chronos-store--sql-migrate-v2'）；版本 1 = 最初的 6 表 + 3 索引。")
(defconst el-chronos-store--flush-interval-seconds 5
  "缓冲落库间隔（秒）；5 秒把崩溃丢失窗口压在秒级且写库抖动不可见。")
(defconst el-chronos-store--warn-interval-seconds 600
  "同类告警最小间隔（秒）；磁盘满、锁超时等故障会持续，必须限流。")
(defconst el-chronos-store--busy-timeout-ms 2000
  "SQLite 忙等待超时（毫秒）；外部进程短暂持锁时等待而非立即失败。")
(defconst el-chronos-store--busy-timeout-write-ms 8000
  "后台批量写事务的 SQLite 忙等待超时（毫秒）。
与 `--busy-timeout-ms'（2000）的分工：启动路径必须短（open / 建会话行拖长会拖慢 Emacs 启动），
后台批量写（flush / prune / purge）可以等——两个 Emacs 实例共享一个库时，对端一次大 prune
或迁移就可能持锁 1–3 秒，2 秒余量不够。8 秒仍是**有界**等待：卡死时最坏多占 8 秒主线程，
而不是永久挂住。")
(defconst el-chronos-store--max-lock-retries 6
  "flush 连续撞锁的最大批次数；达到即按既有语义丢弃本批。
6 批 × 5 秒 flush 周期 = 30 秒，足以覆盖对端 prune / 迁移 / 系统 IO 卡顿，又不让内存
无界增长。**注意（F2 起）**：撞锁后有一次 `--flush-backoff-seconds'（30 秒）退避，
故「连续 6 次撞锁」在**墙钟**上跨越约 3 分钟（5 + 30 的周期 × 6），时间跨度变长但
保留的**批数**上限仍是 6 —— 内存上界由批数决定，与退避无关。
**只对 `sqlite-locked-error' 计数**；磁盘满、`no such table'、约束冲突等持续故障仍立即丢弃
（重试无意义）。")
(defconst el-chronos-store--flush-backoff-seconds 30
  "flush 撞锁后的退避秒数。
为什么必须有退避：撞锁后本批被**保留**（D2）→ `--flush-failures' / `--busy-retries' 非零
→ `--pending-p' 恒真 → 下一次 flush timer（5 秒）会立刻再撞，而单次撞锁最坏等满
`--busy-timeout-write-ms'（8 秒）。不退避的话，对端持续持锁时主线程会被「每 5 秒一次、
每次 8 秒」的等待占满（T8 场景 C 实测 8 次 × 8.01 s，Emacs 基本无响应）—— 这比
「失败即丢弃」的老行为更糟，是老行为被 D2 改掉之后才出现的 regression（F2）。
代价（必须写明）：撞锁期间崩溃的丢数据窗口从 5 秒放大到 5 + 30 秒（见 `docs/operations.org'）。
取 30 秒的理由：对端的大 prune / 迁移实测在 0.5–2.2 秒量级，30 秒足以跨过；又远小于用户的
「这软件卡住了」感知阈值。达到 `--max-lock-retries' 而丢弃本批后**同样**退避，否则
`--pending-p' 因失败计数非零仍为真，会继续每 5 秒白撞 8 秒。
与 `--flush-interval-seconds' 的关系：退避门在 flush 的**最前面**，退避期内 timer 每 5 秒
仍会唤醒，但只是判一个 `float-time' 就返回 —— 不碰库、不阻塞主线程。")
(defconst el-chronos-store--max-buffer-items 50000
  "单类缓冲最大条目数；仅兜底，防库长期不可写时内存无界增长。")
(defconst el-chronos-store--prune-interval-seconds 3600
  "两次 `--prune' 之间的最小间隔（秒）。
取值理由：`--prune' 是写操作，每次都会抢一次写锁；它唯一的调用点是 `el-chronos-store-open'，
而多实例/反复 open-close（如隔离实例、批量脚本）会让「每次 open 都 prune」变成常态锁竞争源。
一小时一次足以兜住保留策略，又不至于让空转的写事务成为常态。")
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
(defconst el-chronos-store--ddl-hourly-drift
  "CREATE TABLE IF NOT EXISTS hourly_drift (hour_ts INTEGER NOT NULL, session_id INTEGER NOT NULL, count INTEGER NOT NULL DEFAULT 0, total_ms REAL NOT NULL DEFAULT 0, max_ms REAL NOT NULL DEFAULT 0, PRIMARY KEY (hour_ts, session_id));"
  "v3 新增：**命令之外**主线程停转 500–2000ms 的按小时聚合（每会话每小时一行）。
语义是「主线程在**命令之外**停转 500ms–2000ms 的聚合」：命令**内部**的停转不进本表 ——
它由 `commands' 的 `duration_ms' 精确记录（≥ `el-chronos-slow-command-threshold-ms'
时另进 `slow_events(kind='command')'）。排除机制不靠任何判据，而是采集侧在命令结算后
重置心跳基线，命令执行时间根本不进入 gap。
推论（读者必须知道）：`hourly_drift' 的时长与 `commands' 的耗时**不可相加、也不该相加**
—— 两者是不相交的集合（「命令间隙的停转」vs「命令总耗时」）。
`max_ms' 保留「本小时最坏单次」：亚秒级卡顿最有价值的读数就是最坏值，平均值会被大量
小停顿稀释（`count' / `total_ms' 已给出频次与总量）。
写入语义（upsert）：`count' 与 `total_ms' 累加、`max_ms' 取标量
`MAX(max_ms, excluded.max_ms)'。
不写外键：同 `el-chronos-store--ddl-hourly-gc'（避免 purge 的删除顺序与级联约束耦合）。
保留策略：**永久保留**，只由 `el-chronos-purge' 清理（`el-chronos-store--prune' 不碰它）。")
(defconst el-chronos-store--ddl-hourly-resources
  "CREATE TABLE IF NOT EXISTS hourly_resources (hour_ts INTEGER NOT NULL, session_id INTEGER NOT NULL, cpu_ms REAL NOT NULL DEFAULT 0, wall_ms REAL NOT NULL DEFAULT 0, rss_kb_max INTEGER, rss_kb_sum INTEGER, threads_max INTEGER, load1_sum REAL, load5_sum REAL, load15_sum REAL, load_n INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (hour_ts, session_id));"
  "v4 新增：Emacs **进程自身**资源占用的按小时聚合（每会话每小时一行）。
口径（不可与别的表混读）：
- `cpu_ms' / `wall_ms'：本小时内**采样窗口**累计的进程 CPU 时间与墙钟时间（毫秒，I4）；
  二者之比即该小时的进程 CPU 占用率。它们是**增量累加量**，不是瞬时值。
- `rss_kb_max' / `rss_kb_sum'：进程常驻集大小（**KB**，不是时间单位，不受 I4 约束）。
  两者并存是因为单独一个都不够用：`max' 抓峰值（内存回归最先表现在峰值上），
  `sum' 抓体重（峰值相同的两小时，平均占用可能差一倍）。
- `threads_max'：进程线程数峰值。
- `load1_sum' / `load5_sum' / `load15_sum'：系统负载（`load-average'，1/5/15 分钟）的
  累加和；`load_n' 是**负载样本条数**（每次采样三值同时到达，故一条样本记 1 次）。
  读作「本小时平均负载 = `loadN_sum' / `load_n'」—— 存和而非均值是 upsert 累加语义的
  直接结果（写库时不知道最终样本数，先算均值会因样本陆续到达而失真）。
可空列（`rss_kb_*' / `threads_max' / `load*_sum'）语义：**NULL = 本行从未观测到该指标**
（平台不支持或采样关闭），0 则是「观测到了，值为 0」。写层用 COALESCE / 条件累加保证
「nil 不覆盖既有非 NULL 值」，与 `hourly_gc.heap_bytes' 同一类陷阱（见
`el-chronos-store--sql-upsert-resources'）。
不写外键：同 `el-chronos-store--ddl-hourly-gc'（避免 purge 的删除顺序与级联约束耦合）。
保留策略：**永久保留**，只由 `el-chronos-purge' 清理（`el-chronos-store--prune' 不碰它）。")
(defconst el-chronos-store--ddl-hourly-gc-attrib
  "CREATE TABLE IF NOT EXISTS hourly_gc_attrib (hour_ts INTEGER NOT NULL, session_id INTEGER NOT NULL, command TEXT NOT NULL, mode TEXT NOT NULL, gc_count INTEGER NOT NULL DEFAULT 0, gc_ms REAL NOT NULL DEFAULT 0, PRIMARY KEY (hour_ts, session_id, command, mode));"
  "v5 新增：**GC 归因**的按小时聚合 —— 回答「GC 发生在哪条命令之后 / 哪个 mode 里」。
主键是四元组 (hour_ts, session_id, command, mode)，同一小时同一会话按命令与 mode 分桶。

**`command' / `mode' 必须 `NOT NULL'（不可放宽）**：SQL 的主键把 NULL 当**互不相等**
（NULL = NULL 结果为 NULL，不是真），一旦主键列出现 NULL，同一组合的多次写入会变成
**多行**而不是 upsert 累加 —— 表看起来有数据，数字全是错的，且不报任何错。
故写层把 nil 归一为哨兵字符串 \"<none>\"（见 `el-chronos-store-record-gc-attrib'）。

**语义边界（读者必读）**：本表记录的是「GC **发生在**哪条命令之后 / 哪个 mode 里」，
**不是**「哪条命令**导致**」GC。归因键是 GC 时刻的 `this-command' × `major-mode'：
**GC 时刻没有正在执行的命令时**（启动期、batch、命令循环**等待输入**期间，含 idle timer /
进程过滤器回调与 `post-gc-hook' 自身的延迟路径）它就是 nil，一律记 \"<none>\"。真实库里
\"<none>\" 常占多数（本机实测，主要因 GC 多发生在命令循环等待输入的窗口），故按命令的
覆盖率有限。任何把它读成因果归因的报告都是错的。

与 `hourly_gc' 的关系：两表**并存、不可互相替代** —— `hourly_gc' 是总量（次数 / 耗时 /
堆大小），本表是同一批 GC 的**分布**（按命令 × mode 拆开）。本表的 `gc_count' 之和
**可以**小于 `hourly_gc' 的（会话未知 / 启动期的 GC 记不进来），不要拿两者做等式校验。

不写外键：同 `el-chronos-store--ddl-hourly-gc'（避免 purge 的删除顺序与级联约束耦合）。
保留策略：**永久保留**，只由 `el-chronos-purge' 清理（`el-chronos-store--prune' 不碰它）。")
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
          "\n" el-chronos-store--ddl-hourly-drift
          "\n" el-chronos-store--ddl-hourly-resources
          "\n" el-chronos-store--ddl-hourly-gc-attrib
          "\n" el-chronos-store--ddl-session-meta)
  "全量建表建索引语句（13 表 + 3 索引），一次批量执行（幂等）；`commands' 引用
`sessions'，顺序不能改。v2 / v3 / v4 / v5 的新表由单表 DDL 常量 concat 而来，与
`el-chronos-store--sql-migrate-v2' / `el-chronos-store--sql-migrate-v3' /
`el-chronos-store--sql-migrate-v4' / `el-chronos-store--sql-migrate-v5'
共用同一批字面量（两份字面量必然漂移，而漂移的表现是
「新库对、旧库缺表」）。
**必须始终是全量**：`el-chronos-store--ensure-schema' 建完表就无条件把 `user_version'
置为当前版本，缺表的新库会被标记成最新版本而之后永远不再迁移。
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
(defconst el-chronos-store--sql-migrate-v3
  el-chronos-store--ddl-hourly-drift
  "version 2 → 3 的增量迁移脚本：只建 `hourly_drift' 一张新表。
与 `el-chronos-store--sql-migrate-v2' 同款：单条 DDL 常量、不含既有表与索引、
`CREATE TABLE IF NOT EXISTS' 可无条件重跑，但**执行时必须显式包事务**（见
`el-chronos-store--migrate'）。
注意：v1 老库会先跑 v2 脚本再跑本脚本（迁移链按版本变量逐级推进），因此本脚本
不能假设库里已有 v2 的 4 张表 —— 它只负责自己这一步。")
(defconst el-chronos-store--sql-migrate-v4
  el-chronos-store--ddl-hourly-resources
  "version 3 → 4 的增量迁移脚本：只建 `hourly_resources' 一张新表。
与 `el-chronos-store--sql-migrate-v2' / `-v3' 同款：单条 DDL 常量、不含既有表与索引、
`CREATE TABLE IF NOT EXISTS' 可无条件重跑，但**执行时必须显式包事务**（见
`el-chronos-store--migrate'）。
注意：v0 / v1 / v2 老库会先跑更早的步骤再跑本脚本（迁移链按版本变量逐级推进），
因此本脚本不能假设库里已有 v2 / v3 的表 —— 它只负责自己这一步。")
(defconst el-chronos-store--sql-migrate-v5
  el-chronos-store--ddl-hourly-gc-attrib
  "version 4 → 5 的增量迁移脚本：只建 `hourly_gc_attrib' 一张新表。
与 `el-chronos-store--sql-migrate-v2' / `-v3' / `-v4' 同款：单条 DDL 常量、不含既有表与
索引、`CREATE TABLE IF NOT EXISTS' 可无条件重跑，但**执行时必须显式包事务**（见
`el-chronos-store--migrate'）。
与 `el-chronos-store--ddl-hourly-gc-attrib' **共用同一个字面量**（`defconst' 直接取该
常量的值，不另写一份）：两份独立字面量必然漂移，而漂移的表现是「新库对、旧库缺表」——
新库走全量 DDL 建到了，老库走增量脚本却漏了，症状是 GC 归因在升级过的库上静默丢光。
注意：v0 / v1 / v2 / v3 老库会先跑更早的步骤再跑本脚本（迁移链按版本变量逐级推进），
因此本脚本不能假设库里已有 v2 / v3 / v4 的表 —— 它只负责自己这一步。")
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
(defconst el-chronos-store--sql-upsert-drift
  "INSERT INTO hourly_drift (hour_ts, session_id, count, total_ms, max_ms) VALUES (?, ?, ?, ?, ?) ON CONFLICT(hour_ts, session_id) DO UPDATE SET count = count + excluded.count, total_ms = total_ms + excluded.total_ms, max_ms = MAX(max_ms, excluded.max_ms)"
  "命令外停转聚合的 upsert：同 (hour_ts, session_id) **部分累加、部分取最值**。

三列的语义**不同类**，写反了不会报错，只会让数字错（与 `--sql-upsert-gc' 的 COALESCE
同一类陷阱：一种是「可累加量」，另一种是「必须保留/取最值」）：
- `count = count + excluded.count'：停转**次数**累加；
- `total_ms = total_ms + excluded.total_ms'：停转**总时长**累加；
- `max_ms = MAX(max_ms, excluded.max_ms)'：单次**最大**停转取两者较大值（SQLite 的两参数
  `MAX' 是标量函数）。写成 `max_ms = excluded.max_ms' 会让「本批恰好都较小」时最大值的
  历史观测被抹掉，`hourly_drift.max_ms' 变成「最后一批的最大值」；写成
  `max_ms = max_ms + excluded.max_ms' 更糟 —— 每批累加一次，数字迟早离谱。

`hourly_drift' 与 `hourly_gc' 一样是两段键（hour_ts + session_id），会话片段由记录函数
写进缓冲键，落库时用 `--split-gc-key' 拆分（同格式）。")
(defconst el-chronos-store--sql-upsert-resources
  "INSERT INTO hourly_resources (hour_ts, session_id, cpu_ms, wall_ms, rss_kb_max, rss_kb_sum, threads_max, load1_sum, load5_sum, load15_sum, load_n) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(hour_ts, session_id) DO UPDATE SET cpu_ms = cpu_ms + excluded.cpu_ms, wall_ms = wall_ms + excluded.wall_ms, rss_kb_max = MAX(COALESCE(rss_kb_max, excluded.rss_kb_max), COALESCE(excluded.rss_kb_max, rss_kb_max)), rss_kb_sum = COALESCE(rss_kb_sum + excluded.rss_kb_sum, rss_kb_sum, excluded.rss_kb_sum), threads_max = MAX(COALESCE(threads_max, excluded.threads_max), COALESCE(excluded.threads_max, threads_max)), load1_sum = COALESCE(load1_sum + excluded.load1_sum, load1_sum, excluded.load1_sum), load5_sum = COALESCE(load5_sum + excluded.load5_sum, load5_sum, excluded.load5_sum), load15_sum = COALESCE(load15_sum + excluded.load15_sum, load15_sum, excluded.load15_sum), load_n = load_n + excluded.load_n"
  "进程资源聚合的 upsert：同 (hour_ts, session_id) **部分累加、部分取最值**。

三组列的语义**不同类**（与 `--sql-upsert-gc' / `--sql-upsert-drift' 同一类陷阱：
写反不报错，只让数字错）：
- `cpu_ms' / `wall_ms' / `load*_sum' / `load_n'：**累加**（累计量、计数）；
- `rss_kb_max' / `threads_max'：取**标量** `MAX'（峰值，历史最大值不得被本批较小值抹小）；
- `rss_kb_sum'：**条件累加**（见下）。

**NULL 处置（本语句最容易写错的一处，与 `--sql-upsert-gc' 的 COALESCE 同源）**：
可空列（`rss_kb_max' / `rss_kb_sum' / `threads_max' / `load*_sum'）在「本窗口没采到该指标」
时传 NULL。天真的 `rss_kb_max = MAX(rss_kb_max, excluded.rss_kb_max)' 在任一参数为 NULL 时
（SQLite 的两参数 MAX 是标量函数，不是聚合）**返回 NULL** —— 一个 NULL 窗口就会把该小时
已经采到的峰值抹掉；`rss_kb_sum = rss_kb_sum + excluded.rss_kb_sum' 同理。
故写成：
- 取最值列：`MAX(COALESCE(<列>, excluded.<列>), COALESCE(excluded.<列>, <列>))`，
  两侧都 NULL 才得 NULL，否则取「两边各自就近的那一个」再取大；
- 求和列：`COALESCE(<列> + excluded.<列>, <列>, excluded.<列>)'——`a + b' 任一为 NULL
  即为 NULL，外层 COALESCE 依次退到「本行旧值」再退到「本次新值」，
  语义读作「有值就加，只有一边有值就取它，两边都没有才留 NULL」。
`cpu_ms' / `wall_ms' / `load_n' 声明为 NOT NULL（DEFAULT 0），写入方必须传数字：
向 NOT NULL 列传 NULL 会被 SQLite 直接拒（`NOT NULL constraint failed'），
整批 flush 回滚——故 `el-chronos-store-record-resources' 在内存里就把 nil 归零。")
(defconst el-chronos-store--sql-upsert-gc-attrib
  "INSERT INTO hourly_gc_attrib (hour_ts, session_id, command, mode, gc_count, gc_ms) VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(hour_ts, session_id, command, mode) DO UPDATE SET gc_count = gc_count + excluded.gc_count, gc_ms = gc_ms + excluded.gc_ms"
  "GC 归因聚合的 upsert：同 (hour_ts, session_id, command, mode) **两列都累加**。
`gc_count' 与 `gc_ms' 都是单调可累加量（GC 次数与耗时各窗口独立），没有取最值或
保旧值的列，故不需要 `--sql-upsert-gc' 那套 COALESCE。

`ON CONFLICT' 的目标必须是**完整主键**（四列）：漏掉 `command' 或 `mode' 时 SQLite 会
报 `ON CONFLICT clause does not match any PRIMARY KEY or UNIQUE constraint'（这是可见
的失败）；而主键列含 NULL 时冲突判定**静默失效**变成多行（见
`el-chronos-store--ddl-hourly-gc-attrib' 的 docstring）——后者才是难查的那种。
故写层把 nil 归一为 \"<none>\"，本语句收到的 `command' / `mode' 恒为非 NULL 字符串。")
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
(defvar el-chronos-store--drift (make-hash-table :test #'equal)
  "命令外停转聚合：键 \"hour|session\"（两段，同 `--gc'），值 `[count total-ms max-ms]'。
**累加语义**：`count' 与 `total-ms' 逐次累加，`max-ms' 取两者较大值 —— 与
`el-chronos-store--sql-upsert-drift' 的三列语义一一对应（两列累加、一列取最值）。

**语义边界（读代码/写报告前必读）**：本容器记的是「主线程在**命令之外**停转 500–2000ms」
的聚合。命令**之内**的停转由 `commands' 表独占（`duration_ms' 已含卡顿，≥200ms 另进
`slow_events(kind='command')'），**不进本表**。推论：`hourly_drift' 的时长与 `commands'
的耗时**不可相加、也不该相加** —— 任何「总卡顿 = 慢命令 + block + drift」的求和式都是错的。
会话片段为空串时不会入缓冲（记录函数先判会话可用，同 v2 三张表）。")
(defvar el-chronos-store--resources (make-hash-table :test #'equal)
  "进程资源聚合：键 \"hour|session\"（两段，同 `--gc'）。
值 vector 共 9 槽：`[cpu-ms wall-ms rss-kb-max rss-kb-sum threads-max
load1-sum load5-sum load15-sum load-n]'。
**混合语义**（与 `el-chronos-store--sql-upsert-resources' 的列语义一一对应）：
前两槽与后四槽累加，`rss-kb-max' / `threads-max' 取较大值，`rss-kb-sum' 在有值时才累加。
可空槽的 nil 表示「本窗口没采到该指标」，更新时**留住旧值**（落库由 SQL 里的 COALESCE
再保一次）—— 与 `--gc' 的 `heap-bytes' 同一类陷阱：nil 覆盖会让该小时已采到的峰值消失。
会话片段为空串时不会入缓冲（记录函数先判会话可用）。")
(defvar el-chronos-store--gc-attrib (make-hash-table :test #'equal)
  "GC 归因聚合（v5）：键是**四元列表** `(HOUR-TS SESSION-ID COMMAND MODE)'，
值 `[gc-count gc-ms]'（两列都累加）。
**为什么键是列表而不是像其余聚合那样的 \"a|b|c\" 字符串**：本表有两个自由文本维度
（`command' / `mode' 由调用方给 symbol 或任意 string），任何分隔符都可能出现在值里
（命令名与 mode 名通常不含 \"|\"，但 API 允许任意字符串）。用 `equal' 比较的列表键
天然没有分隔符冲突，也不必再写一个 `--split-*' 拆分函数与其边界测试 —— 字符串键的
拆分正则一旦与真实取值冲突，症状是「两个不同组合被合并成一行」，静默错数。
`HOUR-TS' / `SESSION-ID' 保留为整数（落库直接绑定，不经过 `--parse-session'）。
会话 ID 缺失时不入缓冲（记录函数先判会话可用，同 v2+ 各表）；键里的会话与当前会话
不一致时由 flush 丢弃（批次级会话守卫只对当前会话判一次，见 `el-chronos-store-flush'）。")
(defvar el-chronos-store--flush-timer nil "周期 flush timer；关闭时取消。")
(defvar el-chronos-store--warned-at nil "上次告警的 `float-time'，用于限流。")
(defvar el-chronos-store--last-prune-time nil
  "上次执行 `--prune' 的 `float-time'；nil 表示本进程尚未执行过（首次总是通过节流门）。")
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
(defvar el-chronos-store--gc-attrib-session-mismatch-warned nil
  "是否已就「GC 归因批次里有行不属于当前会话、已被丢弃」告警过。

**每进程只告警一次**（与 `--stack-skip-warned' / `--aggregate-skip-warned' 同档，
`el-chronos-store-close' 不重置）：该现象正常路径不应出现，一旦出现就是
`record-gc-attrib' 的调用方传错了 session-id，属代码缺陷而非瞬时环境问题——
同一进程里它会持续复现，逐批告警只会刷屏，一次足够定位。

告警走 `display-warning' 而非 `el-chronos-store--warn'：后者的 600 秒限流可能已被
其它告警消耗，会把这条「本该每进程恰好一次」的告警静默吞掉，而标志已置 t 就永久
不再提示。每进程一次本身就是最严的限流，不会造成刷屏。")
(defvar el-chronos-store--pending-startup-ms nil
  "待补写的 `sessions.startup_ms'（毫秒）；nil 表示无需补写。
**覆盖式、非累加**：它是一次性 `after-init-hook' 回调写入的**单个标量**（每次启动最多发生
一次），重复赋值只取最后一次。后加路径不得把它当计数器用 —— 累加会让 `startup_ms' 变成
几倍的启动耗时，且没有任何地方会发现。
**未消费即丢弃**：`el-chronos-store-close' 会把它置 nil。close 会**绕过撞锁退避**尽力
flush 一次，成功即消费；若此时对端仍持锁，本批连同它一起丢失并留下告警。真被丢弃的只是
一个标量（下次启动会重算），与既有 5 秒 flush 窗口的崩溃丢失同级，故不单独告警。")

;;; 采集器自监控计数器
;;
;; 这 5 个计数器**一律用独立 defvar**，既不放 `--clear-aggregates' 清空的那批 hash，
;; 也不挂 `--buffer' / `--slow-events' 上。理由是设计 §6 的「已知悖论」：
;; 这些容器会在 flush 成功（本批已处理）与 flush 失败（ROLLBACK，本批丢弃）两条路径上
;; 被清空，而「刚刚丢了多少 / 失败了几次」恰恰要在失败**之后**仍然可观测 —— 挂上去就等于
;; 「失败了」这件事永远不可见。生命周期与缓冲彻底解耦之后，归零点只由本模块自己的上报点
;; （COMMIT 成功）控制。

(defvar el-chronos-store--dropped-commands 0
  "因**缓冲上限截断** 或 **整批写库失败被丢弃**而丢失的命令事件数（整数，单调累加）。
两类来源**同口径累加**（同一变量），因为对「数据丢没丢」这个判读而言它们等价；区分二者
看的是 `--flush-failures' / `--busy-retries' 与「本批已按计划丢弃」结果告警。
**不进 `--clear-aggregates' 清空的容器**：那批容器的清空点是「本批已处理」/「本批已丢弃」，
一次 flush 失败就会把「刚丢了多少条」一并抹掉，而 flush 失败正是唯一需要这个数字的时刻。
也**不挂 `--buffer'**：那个容器本身会被 ROLLBACK 置 nil，计数随之消失。
归零只在 COMMIT 成功后减去已上报部分（见 `el-chronos-store-flush'），失败路径一分不减。")

(defvar el-chronos-store--dropped-events 0
  "因**缓冲上限截断** 或 **整批写库失败被丢弃**而丢失的慢事件数（整数，单调累加）。
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

(defvar el-chronos-store--busy-retries 0
  "写库撞锁（`sqlite-locked-error'）的次数（整数，单调累加）。
口径：**每一次**撞锁都 +1 —— 包括 flush 保留重试的那次、`--ensure-session-quiet' 的那次。
它不是坏消息（中性度量，类 `flush-count'）：锁竞争被成功自愈也会让它上升，故**不进**
`--health-bad-keys'。上报走 `hourly_health' 的 `busy-retries' 键（T6）。")

(defvar el-chronos-store--flush-lock-streak 0
  "flush **连续**撞锁的批次数（整数）；成功 flush 或走非锁错误分支后归零。
达到 `--max-lock-retries' 才放弃保留本批（防内存无界）；否则保留明细与聚合待下轮重试。")

(defvar el-chronos-store--flush-backoff-until nil
  "**下次允许尝试 flush** 的时刻（`float-time'），nil 表示无退避（F2）。
置位时机：撞锁分支（保留重试与达到上限丢弃**两条**路径都置）——
`(+ (float-time) el-chronos-store--flush-backoff-seconds)'。
清零时机：COMMIT 成功、非锁错误分支（它本就丢弃本批 → `--pending-p' 自然清空，
不需要退避）、以及 `el-chronos-store-close'（**在它那次 flush 之前**清零：退避是给
周期性 flush 的节流，不该拦住「退出前的最后一次写」，见 `el-chronos-store-close'）。
为什么它不是「本次失败的时间戳」而是「允许重试的时刻」：flush 的退避门只需一次比较
`(< (float-time) VALUE)'，不必在每次判定时重算窗口；也让测试可以把它推到过去来模拟
「30 秒已过」，无需操作时钟。
**不进 `--pending-p'**：它不是「有待写数据」，而是「暂时不许尝试」——放进
`--pending-p' 只会让判定永远为真，与 `--flush-count' 同类的无限 flush 陷阱。
`--flush-batch' 不检查本变量（只有 `el-chronos-store-flush' 检查）：直接调 `--flush-batch'
是显式绕过退避的内部入口，仅测试与排障使用。")

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
(defun el-chronos-store--warn-emit (force format-string &rest args)
  "`--warn' / `--warn-force' 的共同实现，绝不抛错。
FORCE 非 nil 时**不做限流判定**（仍更新 `--warned-at'），直接 `display-warning'；
否则每 `--warn-interval-seconds' 秒最多一次。
`--warned-at' 是一条**共享**的限流通道：任何一条告警都会占满窗口，故 FORCE 的决定权在
调用方（只有「结果」类消息能自己判断它不可被限流），本函数不猜。"
  (let ((now (float-time)))
    (when (or force
              (null el-chronos-store--warned-at)
              (> (- now el-chronos-store--warned-at)
                 el-chronos-store--warn-interval-seconds))
      (setq el-chronos-store--warned-at now)
      (display-warning 'el-chronos (apply #'format format-string args) :warning))))
(defun el-chronos-store--warn (format-string &rest args)
  "限流告警：每 `el-chronos-store--warn-interval-seconds' 秒最多一次，绝不抛错。
本函数是**过程消息**的通道（撞锁重试、补写失败、prune 失败…）：这类故障会持续存在，
不限流就会把 echo area 与 `*Messages*' 刷满。
**数据真的丢了**这类结果消息改用 `el-chronos-store--warn-force'（绕过节流）。"
  (apply #'el-chronos-store--warn-emit nil format-string args))
(defun el-chronos-store--warn-force (format-string &rest args)
  "不受限流的告警：立即 `display-warning'，同时仍更新 `--warned-at'。
**只给「数据真的丢了」这类不可再限流的消息用**。理由（F1，双进程实测暴露）：
`--warned-at' 是共享通道 —— 第 1 次撞锁的「保留重试（第 1/6 次）」就把 600 秒窗口占满，
于是第 6 次的「本批缓冲已按计划丢弃」在生产里**永远不出现**：用户只看得到过程，
看不到数据真丢了。
反向约束同样重要：**不要**用「频繁清空重试计数器」来绕过这个问题 —— 那会让过程消息
刷屏，用户同样只看得到过程、看不到结果。过程消息走 `--warn'，结果消息走本函数。"
  (apply #'el-chronos-store--warn-emit t format-string args))
(defun el-chronos-store--call-with-write-timeout (thunk)
  "在 `--busy-timeout-write-ms' 生效期间调用 THUNK，返回其结果。
连接级 pragma 会**残留**，故恢复必须放进 `unwind-protect'；恢复动作本身用 `ignore-errors'
包住——句柄已被关闭时 `sqlite-pragma' 会抛错，而那不该盖住 THUNK 的真实结果/错误。
**不可嵌套**：恢复分支恒把 `busy_timeout' 恢复成默认的 2000 ms（`--busy-timeout-ms'），
不记「进来前的值」。故若将来在 THUNK 内部再调用本函数，内层退出时会把外层的 8000 ms
提前降回 2000 —— 外层剩余的写操作就在 2 秒超时下跑，表现为「偶发撞锁」而不是报错。"
  (when el-chronos-store--db
    (ignore-errors
      (sqlite-pragma el-chronos-store--db
                     (format "busy_timeout=%d" el-chronos-store--busy-timeout-write-ms))))
  (unwind-protect
      (funcall thunk)
    (when el-chronos-store--db
      (ignore-errors
        (sqlite-pragma el-chronos-store--db
                       (format "busy_timeout=%d" el-chronos-store--busy-timeout-ms))))))
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
`hourly_gc' / `hourly_health' / `startup_phases' / `hourly_drift' /
`hourly_resources' / `hourly_gc_attrib' 的主键都含 `session_id'，与
`hourly_stacks' 同一理由：写 NULL 行会让主键去重失效，「同会话同小时累加」的语义
也不成立，故宁可不写也不写 NULL 行。会话恢复后（会话行建好、
`el-chronos--session-id' 非 nil）后续记录自然恢复，无需补偿。"
  (cond
   (session session)
   (t
    (unless el-chronos-store--aggregate-skip-warned
      (setq el-chronos-store--aggregate-skip-warned t)
      (display-warning 'el-chronos
                       (concat "会话 ID 缺失，本次已跳过 hourly_gc / hourly_health"
                               " / startup_phases / hourly_drift / hourly_resources"
                               " / hourly_gc_attrib 写入。")
                       :warning))
    nil)))
(defun el-chronos-store--split-gc-key (key)
  "把两段聚合键 \"hour|session\" 拆成 (HOUR SESSION-STRING)；`hourly_gc' 与
`hourly_drift' 共用（两表主键都是 (hour_ts, session_id)）。
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
  "在 DB 上建全量 13 表 + 3 索引（幂等），并把 user_version 置为当前版本。
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

迁移链用**局部版本变量逐级推进**（`(let ((version from-version)) ...)'），
不用 `(= from-version N)' 的互斥分支。三条理由，缺一条都会踩坑：

① **链式推进**：互斥分支下 `from-version = 1` 的库走完 v2 就停住，而 `--migrate' 仍
   返回 t、库也「可用」，但缺 `hourly_drift' → 本次会话所有 drift 写入撞
   `no such table' → flush 失败、丢本批、只留限流告警（静默降级型缺陷）。
   逐级推进让 S1 之前的老库「一次打开就到位」。
② **`--ensure-schema' 分支结束后必须把 `version' 同步为 `--schema-version'（不是 1）**：
   它建完表后**无条件**写 `user_version = --schema-version'，所以那次调用返回后库已是
   最新，而局部变量还停在 0。三种结局只有一种可接受 —— 留在 0 会让末尾 pragma 把最新库
   标成版本 0（下次又走一遍迁移，版本号长期失真）；置成 1 版本号虽正确，但 v2 / v3 / v4 / v5
   脚本会被各多跑一遍（`CREATE TABLE IF NOT EXISTS' 幂等不报错，可「刚建全表又迁移两遍」
   让失败恢复路径难以推理）；置成当前常量则后续分支自然都不触发。
③ **`.bak' 复制必须在 `BEGIN' 之前** —— 备份要反映迁移前的完整状态；放进事务里会把
   未提交状态带上，回滚后 .bak 已失真。
另外：失败时 `ROLLBACK' 必须在 `.bak' 覆盖**之前** —— 先撤事务再动文件，否则覆盖时句柄
仍持有未回滚事务。
每个迁移步骤各自 `BEGIN IMMEDIATE' / `COMMIT'（回滚粒度按步清楚），步骤内把版本推进到
**本步目标版本**（追加新版本时，既有各步仍只把版本置为本步目标值 2 / 3 / 4 / 5）；末尾再
统一写一次最终版本。

**为什么是 `IMMEDIATE` 而不是裸 `BEGIN'**（D3）：裸 `BEGIN' 是 deferred 的 —— 事务起点
不抢锁，第一条**写**语句才去要写锁，于是「干完半批活才失败」，且失败点取决于语句顺序。
`IMMEDIATE' 把抢锁前移到事务起点：拿不到锁就立刻失败，事务里一句都没执行。
它同时防御另一条病理：deferred 事务里「先读后写」在 WAL 下升级写锁会直接失败为
`SQLITE_BUSY_SNAPSHOT'，**等锁耗时 0 ms**、`busy_timeout' 完全不起作用（实测双进程复现）
—— `IMMEDIATE' 从一开始就以写者身份进入，不存在「读快照之后再升级」这一步。

**版本相等直接返回**（`(>= from-version --schema-version)' → t）编码在函数**内部**，而不是
只依赖 `--open-db' 的版本门：生产路径确实只在 `(< version --schema-version)' 分支才调用本
函数，但「不动已是最新的库」是 `--migrate' 自身的不变量，不该由调用方保证。误调用（版本门
写错、外部直接调用）会无谓地跑一次 `wal_checkpoint(TRUNCATE)' 并生成一份与库同大的
`.bak' 副本（真实库约 10 MB 量级）—— 既有隐私考量（库副本落在用户目录里），也有纯 IO
代价；且这份 `.bak' 在失败回滚路径上会被当作「迁移前状态」使用，内容却与现库相同。"
  (if (>= from-version el-chronos-store--schema-version)
      ;; 已是最新版本：不 checkpoint、不复制 .bak、不开事务，直接返回（保持幂等语义）
      t
    (let ((bak (concat path ".bak")))
      (condition-case err
          (progn
            ;; WAL 未 checkpoint 时主文件不含最新数据，复制前先落盘
            (ignore-errors (sqlite-execute db "PRAGMA wal_checkpoint(TRUNCATE)"))
            (when (file-exists-p path) (copy-file path bak t))
            (let ((version from-version))
              ;; 版本 0 → 当前：建全量表并把版本置为当前版本（由 `--ensure-schema' 完成）
              (when (< version 1)
                (el-chronos-store--ensure-schema db)
                ;; 它已把 13 张表建全并把 user_version 置为当前常量，故把局部版本同步为
                ;; 同一个值（不是 1），否则下面的 v2 / v3 / v4 / v5 分支会对着刚建全的库再跑一遍
                (setq version el-chronos-store--schema-version))
              ;; 版本 1 → 2：补建 4 张新表
              (when (= version 1)
                ;; `sqlite-execute-batch' 不自带事务（实测：无显式 BEGIN 时中途报错，
                ;; 先前已执行的语句仍留在库里），故显式包事务，保证「4 张表全有或全无」
                ;; —— 半成品库会让分析层因缺表静默降级，外部 sqlite3 读者看到残缺 schema。
                (sqlite-execute db "BEGIN IMMEDIATE")
                (sqlite-execute-batch db el-chronos-store--sql-migrate-v2)
                (sqlite-pragma db "user_version=2")
                (sqlite-execute db "COMMIT")
                (setq version 2))
              ;; 版本 2 → 3：补建 hourly_drift。v1 老库会连续走完上面两步，一次到位
              (when (= version 2)
                (sqlite-execute db "BEGIN IMMEDIATE")
                (sqlite-execute-batch db el-chronos-store--sql-migrate-v3)
                (sqlite-pragma db "user_version=3")
                (sqlite-execute db "COMMIT")
                (setq version 3))
              ;; 版本 3 → 4：补建 hourly_resources。v0 / v1 / v2 老库会连续走完上面各步，
              ;; 一次到位（这正是「逐级推进」而非互斥分支的意义）
              (when (= version 3)
                (sqlite-execute db "BEGIN IMMEDIATE")
                (sqlite-execute-batch db el-chronos-store--sql-migrate-v4)
                (sqlite-pragma db "user_version=4")
                (sqlite-execute db "COMMIT")
                (setq version 4))
              ;; 版本 4 → 5：补建 hourly_gc_attrib。v0 / v1 / v2 / v3 老库会连续走完上面各步，
              ;; 一次到位（这正是「逐级推进」而非互斥分支的意义）
              (when (= version 4)
                (sqlite-execute db "BEGIN IMMEDIATE")
                (sqlite-execute-batch db el-chronos-store--sql-migrate-v5)
                (sqlite-pragma db "user_version=5")
                (sqlite-execute db "COMMIT")
                (setq version 5))
              (sqlite-pragma db (format "user_version=%d" version)))
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
         nil)))))
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
(defun el-chronos-store--ensure-session-quiet (db)
  "确保 DB 存在当前会话行并返回 id；失败返回 nil，**从不抛错**（I6）。
与 `--ensure-session' 的唯一区别是错误处置：锁竞争（`sqlite-locked-error'）记一次
`--busy-retries' 后静默返回 nil，其余错误走 `--warn' 限流告警后返回 nil。
调用方据此把「会话行暂时建不起来」当作可延迟的状态（D1）：`store-open' 仍返回句柄，
flush 批前再补建一次。"
  (condition-case err
      (el-chronos-store--ensure-session db)
    (sqlite-locked-error
     (setq el-chronos-store--busy-retries (1+ el-chronos-store--busy-retries))
     nil)
    (error
     (el-chronos-store--warn "建立会话行失败（延迟到下次 flush 重试）：%S" err)
     nil)))

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
保留清理后返回句柄。
**会话行建不起来（锁竞争）不阻断打开**：此时句柄照常返回、flush timer 照常启动，
`el-chronos--session-id' 保持 nil，由下一次 `el-chronos-store-flush' 批前补建
（见 `--ensure-session-quiet'）。否则另一个 Emacs 实例持写锁的瞬间打开库，本实例就
整场会话一条数据都采不到（这是「多实例共用同一库」的首要故障形态）。"
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
                (setq el-chronos--session-id
                      (el-chronos-store--ensure-session-quiet db)))
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
前者是「未消费即丢弃」的标量 —— close 会**绕过撞锁退避**尽力 flush 一次，成功即消费它；
若此时对端仍持锁，本批（含这个标量）会丢失并留下告警（不是「通常已消费」那么乐观）。
后者描述的是当前库里会话行是否存在这一具体事实，重开库后需要重新判定。
7 个自监控计数器一并清零，且**这里是它们唯一的无条件清零点**
（`--dropped-commands' / `--dropped-events' / `--flush-failures' /
`--flush-count' / `--flush-ms-total' / `--busy-retries' /
`--flush-lock-streak'），撞锁退避时刻 `--flush-backoff-until'（F2）也一并归零：
它们与 `--clear-aggregates' 刻意分离 —— 后者是 flush 路径的「本批数据已处理 / 已丢弃」
语义（每次 flush 都跑，成功失败都跑），本处是 close 路径的「进程内状态归零」语义。
混在一起会出两种错：同进程反复 open/close 时把上一轮的计数带进新会话；
或某条 flush 路径顺手抹掉「已丢了多少」。close 前已有一次 flush（**绕过退避**），正常情况
已上报；未上报的部分随 close 丢弃，与既有 5 秒 flush 窗口的崩溃丢失同级，故不告警。"
  (ignore-errors
    ;; 退避是给**周期性** flush 的节流，不该拦住「退出前的最后一次写」：
    ;; 撞锁后本批是**保留**的，若 close 也受退避门限制，下面的 setq 会把
    ;; 这批数据静默丢掉（无告警、无计数），与 close 的语义承诺相悖。
    (setq el-chronos-store--flush-backoff-until nil)
    (el-chronos-store-flush))
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
        ;; 五个新聚合 hash（v2 三张 + v3 的 drift + v4 的 resources）同样清零（I5 零残留）：
        ;; close 前已 flush 过，留下只会让同进程重开时把上一会话的 GC / 自监控 / 启动阶段 /
        ;; 停转 / 进程资源记到新会话名下
        el-chronos-store--gc (make-hash-table :test #'equal)
        el-chronos-store--health (make-hash-table :test #'equal)
        el-chronos-store--startup (make-hash-table :test #'equal)
        ;; `hourly_drift' 聚合同样清零（与上面三个同一理由：close 前已 flush 过，留下会让
        ;; 同进程重开时把上一会话的停转记到新会话名下）
        el-chronos-store--drift (make-hash-table :test #'equal)
        ;; `hourly_resources' 聚合同样清零（I5 零残留，理由同上）
        el-chronos-store--resources (make-hash-table :test #'equal)
        ;; `hourly_gc_attrib' 聚合同样清零（I5 零残留，理由同上）
        el-chronos-store--gc-attrib (make-hash-table :test #'equal)
        ;; `startup_ms' 补写标量「未消费即丢弃」：close 会绕过退避尽力 flush 一次，成功即
        ;; 消费（对端仍持锁时与本批一起丢，已有告警）；真被丢弃的只是一个标量（下次启动会
        ;; 重算），与 5 秒 flush 窗口的崩溃丢失同级，不单独告警
        el-chronos-store--pending-startup-ms nil
        ;; 7 个自监控计数器归零（I5 零残留）。**必须与 `--clear-aggregates' 分开**：
        ;; 那个函数是 flush 路径「本批已处理/已丢弃」的语义，每次 flush 都会跑；
        ;; 这里是 close 路径「进程内状态归零」的语义。混用会让 flush 顺手抹掉
        ;; 「丢了多少 / 失败几次」，而这两件事恰恰要在失败之后仍可观测。
        el-chronos-store--dropped-commands 0
        el-chronos-store--dropped-events 0
        el-chronos-store--flush-failures 0
        el-chronos-store--flush-count 0
        el-chronos-store--flush-ms-total 0.0
        ;; 撞锁计数与连续撞锁 streak（T1/T2）：与上面 5 个同属「进程内状态」。
        ;; 不清零会让同进程重开库（换会话）时把上一轮的撞锁 streak 带进来 —— 新会话
        ;; 第一次撞锁就可能直接越过 `--max-lock-retries' 而丢弃整批。
        el-chronos-store--busy-retries 0
        el-chronos-store--flush-lock-streak 0
        ;; 撞锁退避时刻（F2）同样归零：残留会让同进程重开库的前 30 秒 flush 全部早退 ——
        ;; 表现为「刚打开就不落库」，且没有任何告警解释原因（I5 零残留）
        el-chronos-store--flush-backoff-until nil
        ;; 孤儿会话告警标志重置：它描述「当前库里那个会话行还在不在」，重开库后该事实可能
        ;; 已变，重置才能让新问题重新可见（I5：关闭后不留状态）
        el-chronos-store--aggregate-orphan-warned nil
        ;; prune 节流时间戳（D5）同样归零：它是进程级的「上次 prune 是什么时候」，
        ;; 关闭后再开库应当**重新判定**值不值得 prune，而不是沿用上一轮的计时窗口。
        el-chronos-store--last-prune-time nil)
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
**`busy-retries' 不在本函数的枚举内**：它由 `--health-snapshot' 直接上报（store 自持的
`--busy-retries' 计数器，成功 flush 后按快照扣减）；外部调用方不得写这个键 —— 手工累加会
与「减去已上报部分」的口径冲突，库内值就不再等于真实撞锁次数。
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
(defun el-chronos-store-record-drift (hour-ts gap-ms)
  "累加一次「命令外停转」：HOUR-TS 为整点毫秒（整数），GAP-MS 为停转时长（**浮点毫秒**，
不是秒）。同 (HOUR-TS, session) 累加进 `--drift'：次数 +1、总时长 + GAP-MS、最大值取较大者。
落库由 `el-chronos-store-flush' 在同一事务内完成（`--sql-upsert-drift' 的三列语义：两列累加、
`max_ms' 取标量 MAX）。

**调用方负责保证 GAP-MS 是「命令外」停转的时长**：命令**之内**的停转不进本表（`commands'
的 `duration_ms' 已精确记录，且 ≥200ms 另进 `slow_events(kind='command')'）。本函数不判
归属、也无法判 —— 判定（心跳 `gap' 的计算、抑制门、兜底门、`--finish' 结算后重置基线）
全在 collect 侧，写错边界的责任在调用方，不在 store。

防御与降级（I6：采集路径不得向宿主抛错）：
- GAP-MS 非数值或非正数 → 直接返回 nil、不累加（0ms 的「停转」没有信息量，负数只可能是
  时钟回拨或调用方算错；这类输入若放进去会污染 `count' 与 `total_ms' 的比值）；
- 会话 ID 缺失 → 跳过并每进程告警一次（沿 v2 三张表同款 `--aggregate-session'）；
- 「会话行是否真的存在」**不在本函数判**（与 v2 三张表一致：记录层只判 ID 有无，判行存在
  要查库，属热路径不该做的事）。孤儿 session_id 由 flush 前的 `session-known' 守卫挡住并
  走 `--warn-orphan-aggregates'（`hourly_drift' 无外键，DB 不会替我们挡）。"
  (condition-case err
      (when (and (numberp gap-ms) (> gap-ms 0)
                 (el-chronos-store--aggregate-session el-chronos--session-id))
        (let* ((cell-key (format "%d|%s" hour-ts
                                 (el-chronos-store--session-key-part)))
               (cell (gethash cell-key el-chronos-store--drift)))
          (if cell
              (progn
                (aset cell 0 (1+ (aref cell 0)))
                (aset cell 1 (+ (aref cell 1) (float gap-ms)))
                (aset cell 2 (max (aref cell 2) (float gap-ms))))
            (puthash cell-key (vector 1 (float gap-ms) (float gap-ms))
                     el-chronos-store--drift))
          t))
    (error (el-chronos-store--warn "记录停转聚合失败（已跳过）：%S" err) nil)))

(defun el-chronos-store--resource-value (value)
  "把资源聚合的可空字段 VALUE 规整为数字或 nil。
非数值（字符串、符号、nil）一律按「本窗口没采到该指标」处理，返回 nil —— 与
`--sql-upsert-resources' 的 NULL 语义对齐。这样做是为了让脏输入退化成「少记一个指标」
而不是把字符串写进 REAL 列（SQLite 会宽松地存下来，之后读出来是脏数据）或让整批
flush 撞错回滚（I6：采集路径不得向宿主抛错，也不该因一个字段毁掉一批数据）。"
  (and (numberp value) value))
(defun el-chronos-store-record-resources (hour-ts plist)
  "累加一次**进程资源**采样到 `hourly_resources'：HOUR-TS 为整点毫秒（整数），
PLIST 为本次采样窗口的读数（每采样窗口一次，由 `el-chronos-store-flush' 的批次承载落库）。
会话取自 `el-chronos--session-id'（与 `record-gc' / `record-drift' 同款：这三张表都是
「每会话每小时的聚合」，会话是记录时的全局上下文而不是调用方每次都要重复传的参数）。

PLIST 可含的键（全部可选，缺省或非数值一律按「本窗口没采到该指标」处理）：
- `:cpu-ms'  本窗口进程 CPU 时间（**毫秒**，I4），累加；
- `:wall-ms' 本窗口墙钟时间（**毫秒**，I4），累加；与 `:cpu-ms' 之比即 CPU 占用率；
- `:rss-kb-max' / `:rss-kb-sum' 常驻集大小（**KB**，不是时间单位，不受 I4 约束）：
  前者取历史最大值、后者累加；
- `:threads-max' 线程数峰值，取历史最大值；
- `:load1-sum' / `:load5-sum' / `:load15-sum' 系统负载（1/5/15 分钟）三值，累加；
- `load_n' **不接受显式传值**：只要三值里有任意一个非空，本次记一条负载样本（计数 +1），
  读法即「本小时平均负载 = 对应的 `load*_sum' / `load_n'」。

**NULL 语义（关键，与 `hourly_gc.heap_bytes' 同一类陷阱）**：可空字段传 nil 时
**不得**把库里 / 缓冲里已有的非 NULL 值覆盖成 NULL —— 一个 NULL 窗口会把该小时已采到的
峰值抹掉。内存侧由本函数逐槽「有值才更新」保证，落库侧由
`--sql-upsert-resources' 的 COALESCE / 双 COALESCE-MAX 再保一次（两道都必要：
内存槽与库内行是两个不同的持久层）。

**上一条有且只有一处例外：`:cpu-ms' / `:wall-ms' 是 `NOT NULL DEFAULT 0' 列。** 上面那句
「缺省或非数值一律按没采到处理」对这两列**不成立**：列约束把它们兜成 **0** 而不是 NULL。
`process-attributes' 的 `time' 字段缺失（平台不支持 / 读失败）时采集侧传 nil，落库即 0，
于是该小时的 `cpu_pct = 0.0' —— 这个 0 必须读作「**本窗口未采集到 CPU 时间**」，**不是
「进程空闲」**；`COALESCE' 保住上次观测值的那套机制对这两列**不生效**，而且 0 还会参与
`cpu_ms = cpu_ms + excluded.cpu_ms' 的累加，把本小时的均值往小拉。同一行的 RSS / 线程 /
负载可能照常有值，故「这一小时有资源行」并不等于「CPU 一定采到了」。彻底区分只能让这两列
可空（去掉 `DEFAULT 0'）或加 `cpu_n' 采样计数列，属 schema **v5** 范畴（TD-28）；在此之前
读 `cpu_pct = 0' 时先看该桶的 `samples' 与 RSS 是否有值，不要直接当成空闲。**口径与
`el-chronos-collect--collect-resources' 的 docstring 一致**（那边是发现的现场，本处是落库端
的同一句话：读 `cpu_pct = 0' 应读作未采集到 CPU 时间而非空闲）。

防御与降级（I6：采集路径不得向宿主抛错）：
- PLIST 全空（所有可空字段与 cpu / wall 都没值）→ 直接返回 nil、不建行（一行全 0 的
  资源行没有信息量，还会让「这一小时有没有采到资源数据」不可区分）；
- 会话 ID 缺失 → 跳过并每进程告警一次（沿 v2 三张表同款 `--aggregate-session'）；
- 「会话行是否真的存在」不在本函数判（同 v2 三张表：记录层只判 ID 有无），
  孤儿 session_id 由 flush 前的 `session-known' 守卫挡住。
落库仍走 `el-chronos-store-flush' 的同一事务，故 `hourly_resources' 与
`hourly_gc' / `hourly_drift' 等的「库里有值 ⇔ 本批已提交」严格同态。"
  (condition-case err
      (let* ((cpu (el-chronos-store--resource-value (plist-get plist :cpu-ms)))
             (wall (el-chronos-store--resource-value (plist-get plist :wall-ms)))
             (rss-max (el-chronos-store--resource-value (plist-get plist :rss-kb-max)))
             (rss-sum (el-chronos-store--resource-value (plist-get plist :rss-kb-sum)))
             (threads (el-chronos-store--resource-value (plist-get plist :threads-max)))
             (load1 (el-chronos-store--resource-value (plist-get plist :load1-sum)))
             (load5 (el-chronos-store--resource-value (plist-get plist :load5-sum)))
             (load15 (el-chronos-store--resource-value (plist-get plist :load15-sum)))
             (load-n (if (or load1 load5 load15) 1 0)))
        (when (and (or cpu wall rss-max rss-sum threads (> load-n 0))
                   (el-chronos-store--aggregate-session el-chronos--session-id))
          (let* ((cell-key (format "%d|%s" hour-ts
                                   (el-chronos-store--session-key-part)))
                 (cell (gethash cell-key el-chronos-store--resources)))
            (if cell
                (progn
                  ;; 累加槽：nil 按 0 计（NOT NULL 列，落库时不能是 NULL）
                  (aset cell 0 (+ (aref cell 0) (float (or cpu 0))))
                  (aset cell 1 (+ (aref cell 1) (float (or wall 0))))
                  ;; 峰值槽：只在有值时才更新（nil 覆盖 = 抹掉本小时峰值）
                  (when rss-max (aset cell 2 (max (or (aref cell 2) rss-max) rss-max)))
                  ;; 求和槽：条件累加，两边都无值才留 nil
                  (when rss-sum (aset cell 3 (+ (or (aref cell 3) 0) rss-sum)))
                  (when threads (aset cell 4 (max (or (aref cell 4) threads) threads)))
                  (when load1 (aset cell 5 (+ (or (aref cell 5) 0) load1)))
                  (when load5 (aset cell 6 (+ (or (aref cell 6) 0) load5)))
                  (when load15 (aset cell 7 (+ (or (aref cell 7) 0) load15)))
                  (aset cell 8 (+ (aref cell 8) load-n)))
              (puthash cell-key
                       (vector (float (or cpu 0)) (float (or wall 0))
                               rss-max rss-sum threads load1 load5 load15 load-n)
                       el-chronos-store--resources))
            t)))
    (error (el-chronos-store--warn "记录进程资源聚合失败（已跳过）：%S" err) nil)))

(defun el-chronos-store--attrib-label (value)
  "把 GC 归因的自由文本维度 VALUE 归一为**非 NULL 字符串**。
nil → \"<none>\"；symbol → 其名字（`this-command' / `major-mode' 的常态）；
string 原样；其余（数字等）→ `format' 成字符串。

为什么必须归一：`hourly_gc_attrib' 的 `command' / `mode' 是主键列，而 SQL 把主键里的
NULL 当**互不相等**（`NULL = NULL' 结果是 NULL 而非真），nil 直接落库会让同一组合的
多次写入变成**多行**而不是 upsert 累加 —— 表看着有数据、数字全错且不报任何错。
\"<none>\" 是唯一的「无命令 / 无 mode」哨兵（启动期没有 `this-command'，采集侧传 nil），
它与真空串 \"\" 是两个不同的键，不要混用。

非字符串非符号（如数字）也 `format' 成字符串而不是原样绑定：`command' / `mode' 列是
TEXT 亲和性，数字会被 SQLite 悄悄转成文本，主键比较因此按文本走 —— 显式转比依赖
隐式亲和性更容易解释。"
  (cond ((null value) "<none>")
        ((symbolp value) (symbol-name value))
        ((stringp value) value)
        (t (format "%s" value))))
(defun el-chronos-store-record-gc-attrib (hour-ts session-id command mode gc-count gc-ms)
  "记录一条 GC 归因聚合（按 `hour_ts' × `session_id' × `command' × `mode' 累加）。
COMMAND / MODE 可为 symbol、string 或 nil；nil 记作 \"<none>\"（避免主键出现 NULL ——
SQL 的主键把 NULL 当互不相等，同一组合的多次写入会变成多行而不是累加）。
GC-COUNT / GC-MS 累加，与 `record-drift' 同款 upsert（落库 SQL 见
`el-chronos-store--sql-upsert-gc-attrib'；写入仍走批量缓冲，由
`el-chronos-store-flush' 与 `hourly_gc' / `hourly_drift' / `hourly_resources' 在同一
事务内提交，故「库里有值 ⇔ 本批已提交」严格同态）。

**语义**：本表记录的是「GC **发生在**哪条命令之后 / 哪个 mode 里」，不是「哪条命令
**导致**」GC —— 归因键是 GC 时刻的 `this-command'，**没有正在执行的命令时**（启动期、
batch、命令循环**等待输入**期间，含 idle timer / 进程过滤器回调）为 nil，记 \"<none>\"。
调用方不要把它读成因果归因，也不要把 \"<none>\" 读成采集缺陷。

**SESSION-ID 为什么显式传参**（而 `record-gc' / `record-drift' / `record-resources' 都从
全局 `el-chronos--session-id' 取）：本函数的采集点（`post-gc-hook'）可能在缺少当前会话
上下文的路径上被触发，显式传参让调用方自己决定归属。但**必须传当前会话**
（`el-chronos--session-id'）：flush 的「会话行存在」校验是**批次级**的（每批只对当前会话
查一次库，见 `el-chronos-store-flush'），键里的会话与之不符的行会在落库时被丢弃 ——
库里不会出现孤儿会话的归因行（`hourly_gc_attrib' 无外键，孤儿行 purge 删不掉）。

防御与降级（I6：采集路径不得向宿主抛错）：
- HOUR-TS 非数值 → 返回 nil、不累加（写空值会撞主键列的 NOT NULL 约束，把**整批**
  flush 拖去回滚 —— 一条脏输入毁掉一批已采数据，是绝不能有的放大）；数值一律
  `truncate' 成整数（I4：时间戳一律毫秒整数）；
- GC-COUNT 非正数或非数值 → 返回 nil、不累加（0 次 GC 没有信息量，负数只可能是调用方
  算错，放进去会污染「每命令 GC 频率」这个比值的分母）；
- GC-MS 非数值或负数按 0 处理（时长缺失不该让整条归因一起丢掉；`gc_count' 仍然有价值）；
- 会话 ID 缺失 → 跳过并每进程告警一次（`el-chronos-store--aggregate-session'，同
  v2+ 各表）；
- 「会话行是否真的存在」**不在本函数判**（同 v2+ 各表：记录层只判 ID 有无，查库是
  flush 的事，属热路径不该做的事）。"
  (condition-case err
      (when (and (numberp hour-ts)
                 (numberp gc-count) (> gc-count 0)
                 (el-chronos-store--aggregate-session session-id))
        (let* ((cmd (el-chronos-store--attrib-label command))
               (md (el-chronos-store--attrib-label mode))
               (ms (if (and (numberp gc-ms) (> gc-ms 0)) (float gc-ms) 0.0))
               (key (list (truncate hour-ts) session-id cmd md))
               (cell (gethash key el-chronos-store--gc-attrib)))
          (if cell
              (progn
                (aset cell 0 (+ (aref cell 0) (truncate gc-count)))
                (aset cell 1 (+ (aref cell 1) ms)))
            (puthash key (vector (truncate gc-count) ms)
                     el-chronos-store--gc-attrib))
          t))
    (error (el-chronos-store--warn "记录 GC 归因聚合失败（已跳过）：%S" err) nil)))

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
五类新聚合 hash（`--gc' / `--health' / `--startup' / `--drift' / `--resources'）与
`--pending-startup-ms' **必须**在这里逐一列出：`el-chronos-store-flush' 的第一道门是
`(and db (--pending-p))'，漏掉任何一个都会让
「只有该类数据待写」时 flush 直接早退 —— 数据永不落库且没有任何报错（静默丢数据）。
`--pending-startup-ms' 最容易漏：空闲会话（启动后没人敲命令、profiler 也采不到样本）里
它是**唯一**残留，漏了补写就永远不发生。
`--drift' 同样容易漏：停转是**稀疏事件**（几百毫秒到几秒才可能有一条），「只有 drift 待写」
是常态而非边缘情况，漏掉就等于 drift 全部丢光。
`--resources' 同理：资源采样是**按窗口**的稀疏数据（默认每 N 秒一条），「只有资源待写」
同样常见，漏掉即全丢。

自监控计数器里**只列 `--dropped-commands' / `--dropped-events' / `--flush-failures' /
`--busy-retries'** 四个：它们表示「有数据还没进库」（丢弃量、失败次数与撞锁次数都是待补写
的真实信息），单独残留时必须触发一次 flush 才能补写。
`--busy-retries' 尤其不能漏（D1 路径）：open 期建会话行撞锁只 +1 这个计数、不产生任何
采集数据，空闲会话里它是**唯一**残留 —— 漏掉就等于「撞锁记录永不落库」，D6 的
「锁竞争可量化」直接失效，而且没有任何报错。
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
      (> (hash-table-count el-chronos-store--drift) 0)
      (> (hash-table-count el-chronos-store--resources) 0)
      (> (hash-table-count el-chronos-store--gc-attrib) 0)
      el-chronos-store--pending-startup-ms
      (> el-chronos-store--dropped-commands 0)
      (> el-chronos-store--dropped-events 0)
      (> el-chronos-store--flush-failures 0)
      (> el-chronos-store--busy-retries 0)))
(defun el-chronos-store--flush-backoff-active-p ()
  "撞锁退避是否仍然生效（`--flush-backoff-until' 未到）；只读，不改任何状态。
nil 或已过期都返回 nil。`el-chronos-store-flush' 用它做**最前面**的早退门（F2）：
退避期内不碰库、不打 pragma、不阻塞主线程，缓冲与计数器原样保留。"
  (and el-chronos-store--flush-backoff-until
       (< (float-time) el-chronos-store--flush-backoff-until)))
(defun el-chronos-store--aggregates-pending-p ()
  "六个聚合 hash（gc / health / startup / drift / resources / gc-attrib）是否有待写数据。
这是「自监控计数是否搭便车上报」的判据（flush 的 `session-known' 分支之外的第二条告警门）：
漏掉任一个 hash，都会让「只有该类数据待写」时既不写行、也不告警 —— 用户以为写成功，
实际整批跳过。"
  (or (> (hash-table-count el-chronos-store--gc) 0)
      (> (hash-table-count el-chronos-store--health) 0)
      (> (hash-table-count el-chronos-store--startup) 0)
      (> (hash-table-count el-chronos-store--drift) 0)
      (> (hash-table-count el-chronos-store--resources) 0)
      (> (hash-table-count el-chronos-store--gc-attrib) 0)))
(defun el-chronos-store--warn-orphan-aggregates ()
  "就「会话行不存在、跳过新聚合六表写入」告警一次（每进程一次，close 时重置标志）。
文案必须**逐一列出**被跳过的表（含 `hourly_drift' / `hourly_gc_attrib'）：只说「已跳过
聚合写入」会让用户以为 drift / GC 归因写成功，而实际整批被跳过。"
  (unless el-chronos-store--aggregate-orphan-warned
    (setq el-chronos-store--aggregate-orphan-warned t)
    (display-warning
     'el-chronos
     (concat "会话行不存在，本次已跳过 hourly_gc / hourly_health / startup_phases"
             " / hourly_drift / hourly_resources / hourly_gc_attrib 写入。")
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
`flush-count' / `flush-ms' / `busy-retries'。
`busy-retries' 是**中性度量**（锁竞争被自愈也会上升），故它既不算坏消息
（不进 `--health-bad-keys'），也**必须**进 `--pending-p' —— D1 路径
（open 期建会话行撞锁）只 +1 这个计数而不产生任何采集数据，
「只有它待上报」是常态而非边缘情况。"
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
                (cons "flush-ms" el-chronos-store--flush-ms-total))
              (when (> el-chronos-store--busy-retries 0)
                (cons "busy-retries" el-chronos-store--busy-retries)))))
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
  "清空慢事件缓冲与九个聚合 hash（命令缓冲由调用方按会话状态决定）。
把 hash 换成新表而不是 `clrhash'，避免仍在遍历旧表的 `maphash' 回调看到被清空的内容。
九个聚合 = 既有 usage / functions / stacks + v2 的 gc / health / startup + v3 的 drift
+ v4 的 resources + v5 的 gc-attrib：它们同一批被 flush 写入同一事务，故成败路径都必须
同批清空（否则成功路径会重复累加，失败路径会无界增长）。
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
        el-chronos-store--startup (make-hash-table :test #'equal)
        ;; `hourly_drift' 与上面各表同批（同一事务），故成败路径都必须同批清空：
        ;; 成功不清 → 下次 flush 重复累加（次数与总时长翻倍）；失败不清 → 无界增长
        el-chronos-store--drift (make-hash-table :test #'equal)
        ;; `hourly_resources' 同理（v4）
        el-chronos-store--resources (make-hash-table :test #'equal)
        ;; `hourly_gc_attrib' 同理（v5）：成功不清 → 下次 flush 重复累加（GC 次数与耗时翻倍）；
        ;; 失败不清 → 无界增长（键的基数还会随命令 × mode 组合数增长）
        el-chronos-store--gc-attrib (make-hash-table :test #'equal)))
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
;;;###autoload
(defun el-chronos-store-flush ()
  "把全部缓冲批量写入数据库（单事务）。无句柄或无缓冲时直接返回。
失败按**错误类型**分流处置（`--max-lock-retries' 是分界线）：
- `sqlite-locked-error'（锁竞争）：**保留**本批 —— 明细缓冲、慢事件与九个聚合 hash
  一个都不清，只把 `--flush-failures' / `--busy-retries' / `--flush-lock-streak' 各 +1，
  返回 nil 待下次 flush 重试。依据是 ROLLBACK 之后库状态与事务前完全一致，故原样重写
  不会重复计数；明细本身有 `--max-buffer-items' 上限，聚合 hash 由 streak 上限兜底。
- 连续撞锁达到 `--max-lock-retries'：按既有语义丢弃本批（`--buffer' 置 nil +
  `--clear-aggregates'）+ 限流告警，并把 streak 清零 —— 锁错误可能持续很久，
  无上限保留会让聚合 hash 无界增长。
- 其余错误（磁盘满、`no such table'、约束冲突等**持续故障**）：立即丢弃本批（同既有语义），
  streak 清零。重试无意义，保留只会让内存无界增长。
COMMIT 成功后 streak 归零。ROLLBACK 后只留限流告警（10 分钟最多一次，I6），不向宿主抛错。
会话不可用（ID 为 nil 且补建失败，或 `sessions' 表无对应行）时跳过 `hourly_stacks' 写入，
其余表照常，保证不产生 session_id 为 NULL 的栈行。

此外在同一事务内写六张新聚合表：`hourly_gc'（次数/耗时累加、堆大小 COALESCE 保旧值）、
`hourly_health'（累加）、`startup_phases'（按 (session_id, phase) 覆盖）、
`hourly_drift'（次数/总时长累加、`max_ms' 取标量 MAX）、
`hourly_resources'（cpu / wall / load 累加，rss 峰值与线程数峰值取标量 MAX、rss 总和条件累加）、
`hourly_gc_attrib'（按 hour × session × command × mode 的次数/耗时累加）。
`session_meta' **不参与** flush —— 它由 `el-chronos-store-record-session-meta' 直接写库。
这六张新表写入前先校验会话行存在（它们无外键，孤儿行 purge 删不掉），不存在则整批跳过并
每进程告警一次。
同一事务内还会把 `el-chronos-store--pending-startup-ms' 补写进 `sessions.startup_ms'
（`UPDATE ... WHERE id = ? AND startup_ms IS NULL'）：补写成功且 COMMIT 成功才清 pending，
失败或回滚都保留待下次（eventual，值可能晚到一个 flush 周期但不会丢）。

**会话行延迟补建**（D1）：若 `el-chronos--session-id' 为 nil（`store-open' 期建会话行
撞锁，见 `--ensure-session-quiet'），本函数在事务开始**之前**补建一次；补建仍失败则按
「会话不可用」的既有分支走（命令缓冲保留、`hourly_stacks' 与本批聚合跳过、告警一次）。
补建必须发生在 `let*' 求值之前 —— `session' / `stack-session' / `session-known' 三个绑定
在 `let*' 里一次求值，放在其后就只会取到旧的 nil。
**已知口径损失（有意取舍）**：会话 ID 为 nil 期间，六个 `record-*' 聚合入口经
`--aggregate-session' 在**记录时**即已跳过（不入 hash），故补建只能救回**明细**
（`commands'）；聚合与 `hourly_stacks' 的缺失窗口 ≈ 一个 flush 周期（5 秒）—— 这是
「丢掉 5 秒聚合」换「整场会话零数据」的取舍，不可后补（hash 里从来没有那些键）。

**写事务的超时分层**（D4）：整个批次（含事务前的会话补建与事务本身）包在
`--call-with-write-timeout' 里，期间 `busy_timeout' 抬到 `--busy-timeout-write-ms'
（8 秒），结束后恢复 `--busy-timeout-ms'（2 秒）。理由：flush 是后台写，可以对端
等；而启动路径（`--open-db' / 建会话行）必须保持 2 秒，否则拖慢 Emacs 启动。
8 秒是有界等待，卡死时最坏多占 8 秒主线程。
事务用 `BEGIN IMMEDIATE'（D3）：抢锁在事务起点完成，不会「干完半批活才失败」，
也防御 deferred `BEGIN' 里「先读后写」在 WAL 下的 `SQLITE_BUSY_SNAPSHOT'
（实测 0 ms 失败、`busy_timeout' 完全无效）。
包装器本身只在**确实有待写数据**时才进入：无待写数据的轮次不该为「什么都不做」
白付两次 `sqlite-pragma' 往返（5 秒一次的 timer 大多数轮次正是这种情况）。

**撞锁退避**（F2）：撞锁后本批被保留 → `--pending-p' 恒真 → 下一个 timer 会立刻再撞，
而单次撞锁最坏等满 8 秒（实测 8 次 × 8.01 s，主线程被占满）。故撞锁分支（保留重试与
达到上限丢弃**两条**路径）都把 `--flush-backoff-until' 置为 now +
`--flush-backoff-seconds'（30 秒）；退避期内本函数**最前面**就早退（不碰库、返回 nil、
缓冲与计数器原样），COMMIT 成功或走非锁错误分支则清零。代价是崩溃丢数据窗口从 5 秒
放大到 5 + 30 秒（见 `docs/operations.org'）。

**判读口径（撞锁自愈 vs 真的丢了）**：撞锁分支对 `--busy-retries' 与 `--flush-failures'
**同时 +1**，故这两个数**不能**区分「保留重试」与「整批丢弃」。区分靠 `--dropped-commands' /
`--dropped-events'：
- **撞锁自愈**（保留重试，数据没丢）：`busy-retries' 升，而 `dropped-commands' /
  `dropped-events' **不升**；
- **真的丢了**（撞锁达到 `--max-lock-retries' 上限、或非锁错误整批丢弃）：
  `dropped-*' **同时升**（条数 = 被丢弃的缓冲长度），并伴随一条「本批已按计划丢弃」的
  **结果告警**（`--warn-force'，不受 600 秒限流）。
两路信号都在 `hourly_health' 里（`busy-retries' / `flush-failures' /
`dropped-commands' / `dropped-events' 四键），故事后可判读；运行期则看告警文案是
「保留待下次」还是「已按计划丢弃」。"
  (interactive)
  (cond
   ;; F2：撞锁退避——到期前直接早退，不碰库、不阻塞主线程、不改任何缓冲/计数器。
   ;; 放在最前面（连 `--pending-p' 都不算）：退避期内唯一该做的事就是等。
   ((el-chronos-store--flush-backoff-active-p) nil)
   ;; 第一道门（有库 + 有待写数据）在包装器**之外**：没有待写数据时连两次
   ;; `sqlite-pragma'（抬 8000 / 恢复 2000）都不做。裸调 `--flush-batch' 时会再判一次，
   ;; 故这里重复一次判定只是为了让包装器不进空转路径，不承担正确性职责。
   ((and el-chronos-store--db (el-chronos-store--pending-p))
    (el-chronos-store--call-with-write-timeout #'el-chronos-store--flush-batch))))
(defun el-chronos-store--flush-batch ()
  "把本批缓冲写入数据库（`el-chronos-store-flush' 的事务体）。
单独成一个函数只为让 `--call-with-write-timeout' 包住**整个**批次（含事务前的会话补建），
而不必给二十行主体加一层缩进；返回语义与错误处置全由 `el-chronos-store-flush' 的
docstring 定义（t = 本批已处理，nil = 已按类型分流处置）。
本函数自带「有库 + 有待写数据」守卫，因此直接调用也是安全的（包装器是否已进入由调用方
决定，见 `el-chronos-store-flush'）。"
  (when (and el-chronos-store--db (el-chronos-store--pending-p))
    ;; D1：会话行可能在 open 期撞锁未建成 —— 必须在这里（`let*' 求值之前）补建，
    ;; 否则下面 `session' / `stack-session' / `session-known' 三个绑定仍取到旧的 nil，
    ;; 本批 `hourly_stacks' 会被 `--stack-session' 静默跳过。
    (when (and (boundp 'el-chronos--session-id) (null el-chronos--session-id))
      (setq el-chronos--session-id
            (el-chronos-store--ensure-session-quiet el-chronos-store--db)))
    (let* ((db el-chronos-store--db)
           (session el-chronos--session-id)
           (stack-session (el-chronos-store--stack-session el-chronos-store--db
                                                            el-chronos--session-id))
           ;; 新聚合六表 + `startup_ms' 补写共用这一次存在性判定（每批只有一个会话，
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
            (sqlite-execute db "BEGIN IMMEDIATE")
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
              ;; 与五张新表同一判定；会话未知时计数器**一分不减**，等下次补写。
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
                       el-chronos-store--startup)
              ;; 命令外停转聚合（v3）：键同样两段（hour|session），沿用 `--split-gc-key'
              ;; 拆分。三列语义**不同类**（count / total_ms 累加，max_ms 取标量 MAX），
              ;; 见 `el-chronos-store--sql-upsert-drift' 的 docstring —— 写反不报错只错数
              (maphash (lambda (key value)
                         (let ((parts (el-chronos-store--split-gc-key key)))
                           (sqlite-execute
                            db el-chronos-store--sql-upsert-drift
                            (list (nth 0 parts)
                                  (el-chronos-store--parse-session (nth 1 parts))
                                  (aref value 0) (aref value 1) (aref value 2)))))
                       el-chronos-store--drift)
              ;; 进程资源聚合（v4）：键同样两段（hour|session），沿用 `--split-gc-key'。
              ;; 列语义分三组（累加 / 取最值 / 条件累加），NULL 处置见
              ;; `el-chronos-store--sql-upsert-resources' —— 写反不报错只错数。
              ;; 三个 NOT NULL 列（cpu_ms / wall_ms / load_n）在记录层已归零，
              ;; 这里直接传缓冲值即可。
              (maphash (lambda (key value)
                         (let ((parts (el-chronos-store--split-gc-key key)))
                           (sqlite-execute
                            db el-chronos-store--sql-upsert-resources
                            (append (list (nth 0 parts)
                                          (el-chronos-store--parse-session
                                           (nth 1 parts)))
                                    (append value nil)))))
                       el-chronos-store--resources)
              ;; GC 归因聚合（v5）：键是**四元列表** (hour session command mode)，
              ;; 用 `equal' 精确匹配（无分隔符冲突，见 `el-chronos-store--gc-attrib'）。
              ;; 会话守卫：批次级判定（`session-known'）只针对**当前会话**查过一次库，
              ;; 故这里再与前缀会话比对，键里若是别的会话一律跳过 —— `hourly_gc_attrib'
              ;; 无外键，写进去的孤儿行 purge 的子查询永远定位不到，会永久残留且不报错。
              (let ((mismatched 0))
                (maphash (lambda (key value)
                           (let ((hour (nth 0 key)) (sid (nth 1 key)))
                             (if (equal sid session)
                                 (sqlite-execute
                                  db el-chronos-store--sql-upsert-gc-attrib
                                  (list hour sid (nth 2 key) (nth 3 key)
                                        (aref value 0) (aref value 1)))
                               (setq mismatched (1+ mismatched)))))
                         el-chronos-store--gc-attrib)
                ;; 丢弃不再静默：本批出现会话不匹配的行时每进程告警一次（含丢弃行数）。
                ;; 计数按**行**累加而非按 hash 键 —— 每个键就是一行，故二者等价；
                ;; 用局部 let 而非新增全局计数器：丢弃量本身没有跨批次累积的意义。
                (when (and (> mismatched 0)
                           (not el-chronos-store--gc-attrib-session-mismatch-warned))
                  (setq el-chronos-store--gc-attrib-session-mismatch-warned t)
                  (display-warning
                   'el-chronos
                   (format (concat "GC 归因批次里有 %d 行不属于当前会话（已丢弃）。"
                                   "正常路径不应出现，若持续出现说明"
                                   " record-gc-attrib 的调用方传错了 session-id。")
                           mismatched)
                   :warning))))
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
            ;; F2：成功即清退避 —— 抢锁已成功，下一轮不必再等（否则一次历史撞锁会让
            ;; 之后 30 秒的 flush 全部早退：正常数据也跟着晚 30 秒落库）。
            (setq el-chronos-store--flush-backoff-until nil)
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
                          (- el-chronos-store--flush-ms-total value)))
                   ;; 中性度量（撞锁次数）同样按快照扣减：置 0 会吞掉事务期间新发生的撞锁
                   ((equal (car entry) "busy-retries")
                    (setq el-chronos-store--busy-retries
                          (- el-chronos-store--busy-retries value)))))))
            (setq el-chronos-store--flush-count (1+ el-chronos-store--flush-count)
                  el-chronos-store--flush-ms-total
                  (+ el-chronos-store--flush-ms-total
                     (* 1000.0 (- (float-time) flush-start)))
                  ;; 成功一次就把「连续撞锁」的计数归零：streak 的语义是**连续**，
                  ;; 不是累计（累计在 `--busy-retries' 里）。
                  el-chronos-store--flush-lock-streak 0)
            (when session (setq el-chronos-store--buffer nil))
            (el-chronos-store--clear-aggregates)
            t)
        (sqlite-locked-error
         ;; 锁竞争是**瞬时且可自愈**的（对端 flush / prune / 迁移撞在一起），与磁盘满、
         ;; `no such table'、约束冲突这类**持续故障**性质不同，不能一刀切丢弃：
         ;; ROLLBACK 之后库状态与事务前完全一致，保留缓冲重写不会重复计数
         ;; （明细有 `--max-buffer-items' 上限，聚合 hash 靠下面的 streak 上限兜底）。
         ;; **分支顺序是硬约束**：`sqlite-locked-error' 是 `sqlite-error' → `error' 的
         ;; 子类型，排在下面的 `(error ...)' 之后会被静默吞掉 —— 那时锁竞争会走「丢弃
         ;; 整批」，且不注入 locked 错误的用例根本不会变红（表面全绿、行为是错的）。
         (ignore-errors (sqlite-execute db "ROLLBACK"))
         (setq el-chronos-store--flush-failures (1+ el-chronos-store--flush-failures)
               el-chronos-store--busy-retries (1+ el-chronos-store--busy-retries)
               el-chronos-store--flush-lock-streak
               (1+ el-chronos-store--flush-lock-streak)
               ;; F2：撞锁后必须退避 —— 本批被保留（或刚丢弃但失败计数非零），
               ;; `--pending-p' 恒真，下一个 timer（5 秒）会立刻再撞，而单次撞锁最坏
               ;; 等满 `--busy-timeout-write-ms'（8 秒）。不退避 = 「每 5 秒一次、
               ;; 每次 8 秒」占满主线程（实测 8 次 × 8.01 s）。两条路径（保留重试 /
               ;; 达到上限丢弃）都要置位，见 `--flush-backoff-seconds' 的 docstring。
               el-chronos-store--flush-backoff-until
               (+ (float-time) el-chronos-store--flush-backoff-seconds))
         (if (>= el-chronos-store--flush-lock-streak
                 el-chronos-store--max-lock-retries)
             (progn
               ;; S1：丢弃**必须先记账**再清空缓冲 —— 顺序是硬约束，两条计数都取
               ;; `length'，放到下面的 `setq' 之后就恒为 0。撞锁分支对
               ;; `busy-retries' 与 `flush-failures' 同时 +1，保留重试与真丢弃在
               ;; 那两个数上完全一样，操作者只能靠这两个数判断「数据丢没丢」。
               (setq el-chronos-store--dropped-commands
                     (+ el-chronos-store--dropped-commands
                        (length el-chronos-store--buffer))
                     el-chronos-store--dropped-events
                     (+ el-chronos-store--dropped-events
                        (length el-chronos-store--slow-events)))
               (setq el-chronos-store--buffer nil)
               (el-chronos-store--clear-aggregates)
               (setq el-chronos-store--flush-lock-streak 0)
               ;; F1：这条是**结果**消息（数据真的丢了），必须用 `--warn-force'
               ;; 绕过节流 —— 否则第 1 次撞锁的「保留重试」已占满 600 秒窗口，
               ;; 用户永远看不到「本批已丢弃」。
               (el-chronos-store--warn-force
                "写库连续撞锁 %d 次，本批缓冲已按计划丢弃（明细与聚合）：%S"
                el-chronos-store--max-lock-retries err))
           ;; 过程消息：保留 10 分钟限流（对端持续持锁时每 5 秒一条告警比不告警更吵）
           (el-chronos-store--warn
            "写库撞锁（第 %d/%d 次），明细与聚合保留待下次 flush 重试：%S"
            el-chronos-store--flush-lock-streak
            el-chronos-store--max-lock-retries err))
         nil)
        (error
         (ignore-errors (sqlite-execute db "ROLLBACK"))
         ;; `error' 分支同时承接上个版本的「锁超时」语义之外的一切错误：它不再包含锁竞争
         ;; （那条已被上面的 `sqlite-locked-error' 分支截走）。streak 归零：非锁错误说明
         ;; 这一段不是「连续撞锁」，留着会把后来的锁竞争提前推到上限。
         ;; F2：非锁错误**不退避** —— 本批已丢弃、`--pending-p' 自然清空，不会每 5 秒白撞；
         ;; 且持续故障（磁盘满 / 库损坏）退避也没有意义，反而让恢复后的补写晚 30 秒。
         (setq el-chronos-store--flush-lock-streak 0
               el-chronos-store--flush-backoff-until nil)
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
         ;;     2) 写库失败通常是持续性故障（磁盘满、`no such table'、约束冲突），
         ;;        保留只会让内存无界增长；
         ;;     3) 会话缺失是短暂且可自愈的阻塞，写库失败是这一批数据真的落不下去。
         ;; 故命令缓冲与 `--clear-aggregates'（慢事件 + 九个聚合 hash）一并清空，
         ;; 只留下限流告警作为失败计数。
         ;;
         ;; S1：丢弃前**先记账**（顺序硬约束 —— 计数取 `length'，必须在下面清空
         ;; `--buffer' / `--slow-events' 之前，否则恒为 0）。与撞锁上限丢弃同一口径：
         ;; `flush-failures' 只说明「失败过」，`dropped-*' 才说明「数据真的丢了」。
         (setq el-chronos-store--dropped-commands
               (+ el-chronos-store--dropped-commands
                  (length el-chronos-store--buffer))
               el-chronos-store--dropped-events
               (+ el-chronos-store--dropped-events
                  (length el-chronos-store--slow-events)))
         (setq el-chronos-store--buffer nil)
         (el-chronos-store--clear-aggregates)
         (el-chronos-store--warn "写入数据库失败，本批缓冲已按计划丢弃：%S" err)
         nil)))))

;;; 保留清理与手动 purge

(defun el-chronos-store--prune (&optional force)
  "按 `el-chronos-retention-days' 清理明细表；受节流门与候选预检两道约束。
只删 `commands' 与 `slow_events'；**八张** hourly_* 聚合表（`hourly_functions' /
`hourly_usage' / `hourly_stacks' / `hourly_gc' / `hourly_health' /
`hourly_drift' / `hourly_resources' / `hourly_gc_attrib'）永久保留，
只由 `el-chronos-purge' 清理。

**节流**（D5）：`--prune' 是写操作，每次都要抢一次写锁；而它**唯一的调用点是
`el-chronos-store-open'**（不挂周期 timer，见 TD-37），多实例 / 反复 open-close
（隔离实例、批量脚本）会让「每次 open 都 prune」变成常态锁竞争源。故两次之间至少隔
`--prune-interval-seconds'（1 小时）；FORCE 非 nil 时绕过节流门（测试与排障用）。
跨进程各自计时：多实例同时启动时「首次各自执行一次」，靠下面的预检把空转写事务降为 0。

**候选预检**：过门之后先对两张表各做一次 `SELECT count(*) ... WHERE ts < ?'（走
`idx_commands_ts' / `idx_slow_events_ts'，读锁不阻塞写者）；**两表都为 0 就直接返回 nil，
完全不开写事务**。时间戳在过门时**立即**记录（不是删完之后），因为「预检本身」也不该每次
open 都重跑。
注意记录点在**预检之前**：撞锁失败的那一次同样算「已过门」，会把下一次尝试推迟一小时
（语义可接受——prune 本就是低频清理，且 retention 的实际生效本来就依赖实例重启）。

**保留策略的实际生效依赖实例重启**：本函数不挂周期 timer，只在 open 时调用一次，
所以 `el-chronos-retention-days' 的改动要下次启动才生效（既有事实，本次不改变）。

**事务与超时**：有候选才开 `BEGIN IMMEDIATE' 写事务（抢锁在起点完成，不会「干完半批活
才失败」，也防御 deferred `BEGIN' 里「先读后写」在 WAL 下的 `SQLITE_BUSY_SNAPSHOT'），
并包在 `--call-with-write-timeout' 里（期间 `busy_timeout' 8 秒，结束恢复 2 秒）。
失败仍只降级为限流告警（I6），绝不向 `store-open' 抛错。"
  (when (and el-chronos-store--db
             (or force
                 (null el-chronos-store--last-prune-time)
                 (>= (- (float-time) el-chronos-store--last-prune-time)
                     el-chronos-store--prune-interval-seconds)))
    ;; 过门即记时（预检不通过也要记）：否则「没有候选行」的每次 open 都重跑 count(*)
    (setq el-chronos-store--last-prune-time (float-time))
    (let ((cutoff (- (el-chronos-store--now-ms)
                     (* (or el-chronos-retention-days 30) 86400000))))
      (condition-case err
          (let ((command-hits (or (caar (sqlite-select
                                         el-chronos-store--db
                                         "SELECT count(*) FROM commands WHERE ts < ?"
                                         (list cutoff)))
                                  0))
                (event-hits (or (caar (sqlite-select
                                       el-chronos-store--db
                                       "SELECT count(*) FROM slow_events WHERE ts < ?"
                                       (list cutoff)))
                                0)))
            ;; 两表都没有过期行 → 直接返回，**完全不开写事务**
            (when (or (> command-hits 0) (> event-hits 0))
              (el-chronos-store--call-with-write-timeout
               (lambda ()
                 (sqlite-execute el-chronos-store--db "BEGIN IMMEDIATE")
                 (sqlite-execute el-chronos-store--db
                                 "DELETE FROM commands WHERE ts < ?" (list cutoff))
                 (sqlite-execute el-chronos-store--db
                                 "DELETE FROM slow_events WHERE ts < ?" (list cutoff))
                 (sqlite-execute el-chronos-store--db "COMMIT")
                 t))))
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
    ("hourly_drift" . hour-ts)
    ("hourly_resources" . hour-ts)
    ("hourly_gc_attrib" . hour-ts)
    ("sessions" . stale-session))
  "`el-chronos-purge' 的删除顺序：13 张表，**顺序不可改**。
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

`hourly_gc_attrib'（v5）排在 `hourly_resources' 之后、`sessions' 之前：它有 `hour_ts'
时间列、按列删，故必须早于 `sessions'（与其余七张聚合表同一个顺序理由）；
`sessions' 必须最后 —— 它是 `commands' 外键的父表，且 `startup_phases' / `session_meta'
的子查询依赖它。

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
;;;###autoload
(defun el-chronos-purge (&optional before)
  "删除 BEFORE（epoch 毫秒）之前的全部数据；BEFORE 为 nil 时清空全部 13 张表。
返回按删除顺序排列的 ((表名 . 删除行数) ...)。
与 `-prune' 的区别是连 hourly_* 聚合、会话级数据（`startup_phases' / `session_meta'）
以及 `sessions' 行本身一起删 —— 13 张表 vs 2 张表。

删除顺序见常量 `el-chronos-store--purge-targets'：先 `commands'（唯一有外键的表），
再 `startup_phases' / `session_meta'（删除条件靠子查询定位会话），最后 `sessions'。
顺序颠倒会分别造成「撞外键报错」与「静默不删的孤儿」两种不同故障。
`before' 为 nil 时所有表无条件清空，子查询不参与，但顺序不变（单一代码路径）。

**为什么事务用 `BEGIN IMMEDIATE'**（D3）：裸 `BEGIN' 是 deferred 的，起点不抢锁，
第一条写语句才要写锁 —— 于是「干完半批活才失败」，失败点还取决于语句顺序；purge 要删
13 张表，失败在这里意味着前面几张已经删掉的行白删（虽会 ROLLBACK，但写锁在整段尾段才拿，
竞争窗口最大）。`IMMEDIATE' 把抢锁前移到起点：拿不到锁立刻失败、事务里一句都没执行。
它同时防御 deferred 事务里「先读后写」在 WAL 下的升级失败（`SQLITE_BUSY_SNAPSHOT'，
实测 0 ms 失败、`busy_timeout' 完全无效）—— purge 的删除条件里就有子查询（读），
先是读后是写，正好落在该病理上。

**超时分层**（D4）：整个函数体包在 `--call-with-write-timeout' 里，期间 `busy_timeout'
抬到 `--busy-timeout-write-ms'（8 秒），结束（含失败）恢复 `--busy-timeout-ms'（2 秒）。
purge 是低频手动操作、且一次要删 13 张表，等得起；反过来说，用 2 秒的默认值在
「对端正在写」时极易白失败一次，而它已经是用户显式发起的意图。

**过期会话的判据**（`el-chronos-store--stale-session-sql'）：`started_at < BEFORE'
且名下没有 `ts >= BEFORE' 的 commands 行。后者不能省：一个「很久以前启动、今天还在
运行」的会话若被直接删掉，会撞 `commands.session_id' 外键 → **整批事务回滚**，
purge 一条都没删。本函数是隐私清理手段，宁可保留这类会话（它的过期明细照样删），
也不能让它整体失败。三张会话相关表共用该判据，避免留下「会话在、meta 没了」的半截状态。

purge 会删掉当前会话行，故结束后用 `--ensure-session-quiet' 补建一行（否则后续写入撞
外键），并把它刚写入的 `startup_ms' **显式置 NULL**：`--ensure-session-quiet' 用
`before-init-time' → `after-init-time' 求差，运行中的 Emacs 里两者都非 nil，
会让 `started_at = 现在' 的行带上「本进程几小时前启动」的耗时，语义自相矛盾。
用 quiet 版而不是会抛错的 `--ensure-session'：补建发生在 COMMIT **之后**，此处失败
不属于回滚语义 —— 抛错的后果是「13 张表已删干净、却告警说已回滚并返回 nil」。
补建撞锁时只记一次 `--busy-retries'，`el-chronos--session-id' 留 nil 等下次 open / flush
补建（后续写入在该窗口内会撞外键，与既有「会话行延迟补建」路径同一处置）。"
  (interactive
   (list (let ((text (string-trim
                      (read-string "删除该日期（YYYY-MM-DD）之前的数据，留空清空全部： "))))
           (unless (string-empty-p text)
             (truncate (* 1000 (float-time
                                (date-to-time (concat text " 00:00:00")))))))))
  (when (or el-chronos-store--db (el-chronos-store-open))
    (el-chronos-store--call-with-write-timeout
     (lambda ()
       (condition-case err
           (let ((db el-chronos-store--db) (result nil))
             (sqlite-execute db "BEGIN IMMEDIATE")
             (dolist (target el-chronos-store--purge-targets)
               (let ((table (car target)) (strategy (cdr target)))
                 (push (cons table
                             (pcase strategy
                               ('ts
                                (el-chronos-store--delete-rows db table "ts" before))
                               ('hour-ts
                                (el-chronos-store--delete-rows db table "hour_ts" before))
                               ('stale-session-rows
                                (el-chronos-store--delete-rows-of-stale-sessions
                                 db table before))
                               ('stale-session
                                (el-chronos-store--delete-stale-sessions db before))
                               (_ (error "未知的 purge 删除策略：%S" strategy))))
                       result)))
             (sqlite-execute db "COMMIT")
             ;; purge 可能删掉当前会话行：立刻补建，否则后续写入会撞外键约束。
             ;; **用 quiet 版**：事务已经提交，此处失败不属于回滚语义 —— 若让它抛错，
             ;; 异常会被外层 `condition-case' 当成「事务失败（已回滚）」告警并返回 nil，
             ;; 而 13 张表其实已经删完（方向是「以为没删、实际删了」，比反过来更危险）。
             ;; 撞锁只记 `--busy-retries'，会话 ID 留 nil，等下次 open / flush 补建。
             (when (boundp 'el-chronos--session-id)
               (setq el-chronos--session-id (el-chronos-store--ensure-session-quiet db))
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
          nil))))))
;;;###autoload
(defun el-chronos-store-vacuum ()
  "对当前数据库执行 VACUUM 回收空间；未打开返回 nil。VACUUM 不能在事务内执行。"
  (interactive)
  (when el-chronos-store--db
    (condition-case err
        (progn (sqlite-execute el-chronos-store--db "VACUUM") t)
      (error (el-chronos-store--warn "VACUUM 失败：%S" err) nil))))

(provide 'el-chronos-store)

;;; el-chronos-store.el ends here
