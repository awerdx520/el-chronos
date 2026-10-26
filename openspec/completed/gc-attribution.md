# GC 归因（schema v5）

## 当前状态

- 阶段：**Phase 4（Review & Document）已完成 · 已归档**（2026-10-26 归档至 `openspec/completed/gc-attribution.md`）
- 已确认：方案 ✅（用户 2026-10-26 决定「现在做」）
- 计划 ✅
- 进度：C1a ✅（schema v5 + 表 + 写入 + purge）、C1b ✅（post-gc-hook 采集 + 零分配 + 窗口 flush）、C1c ✅（analysis + report 第 16 节 + 文档）、全量验证 ✅；`make test` **336/336**（**0 skipped**）
- **验证结果（2026-10-26 实测）**：
  - L1 `make check-parens` exit=0（17 文件）；L2 `make test` = `Ran 336 tests, 336 results as expected, 0 unexpected`（约 4.7–14.9 秒，视机器负载）；L2b `make lint` exit=0，`Warning` / `Error` 计数 **0**
  - L3 ① **迁移实测通过**：真实库 v4 副本 → v5 后 `PRAGMA user_version = 5`、12 → 13 表、12 张既有表**一行不变**、迁移后 `sqlite_master` 与真实库逐字相同；v5 幂等路径**不生成 `.bak`**；回滚守门 4 用例（含 `migrate-v5-failure-rolls-back`）全绿
  - L3 ② **归因同桶同会话覆盖 100%**（session 23 某桶 attrib 42 = `hourly_gc` 42）；全库差值 99.52% 全部来自 v5 之前没有归因数据的时间段
  - L3 ③ 最终验收项「可与 `Automatic GC` 的 29.6% 对照解释」**只能部分达成**，三层原因：① **时间覆盖不重叠** —— 全库实测 `Automatic GC` 栈样本占比 **38.28%**（418,664 / 1,093,762），主要来自 v5 之前的会话，计划里的 29.6% 是早期快照；② **口径不可换算** —— 栈样本数 vs GC 事件计数；③ command 维度 **88.1%（37/45）落 `<none>`**
- **审查结论**：通过，无 blocking；1 major（`<none>` 成因文案与实测不符）+ 1 minor（`--migrate` 版本相等守卫）均已修复
- 归档日期：**2026-10-26**

## 目标

消除本项目**最大的归因盲点**：`Automatic GC` 在 2026-10-26 那次真实排查中占**栈包含样本的 29.6%**（单帧栈，无父帧），却完全无法回答「GC 是谁触发的」。

现状：`hourly_gc` 只有 `(hour_ts, session_id)` 维度的 `gc_count` / `gc_ms` / `heap_bytes`；`commands.gc_ms` 只覆盖「命令执行期」触发的 GC（v2 起就有）。命令之外的 GC（idle timer、进程过滤器、redisplay）没有任何归因路径。

## 设计

### 表（schema v5）

```sql
CREATE TABLE IF NOT EXISTS hourly_gc_attrib (
  hour_ts INTEGER NOT NULL, session_id INTEGER NOT NULL,
  command TEXT NOT NULL, mode TEXT NOT NULL,
  gc_count INTEGER NOT NULL DEFAULT 0, gc_ms REAL NOT NULL DEFAULT 0,
  PRIMARY KEY (hour_ts, session_id, command, mode));
```

- `command` / `mode` 均为 `NOT NULL`，nil 时写 `"<none>"`（避免主键里出现 NULL）。
- upsert 累加：`ON CONFLICT(hour_ts, session_id, command, mode) DO UPDATE SET gc_count = gc_count + excluded.gc_count, gc_ms = gc_ms + excluded.gc_ms`。
- 不写外键（与其余 6 张 `hourly_*` 一致），写入前校验会话行存在。

### 采集（`post-gc-hook`）

- 在 hook 里读 `(gcs-done . gc-elapsed)` 与上次的差值 → 本次 GC 次数与耗时。
- 归因键：`(cons this-command major-mode)` 的 **symbol**，累积到内存 hash（value 为 `[count ms]` 向量）。
- **零分配是硬约束**：hook 体内禁止 `format` / `concat` / `number-to-string` / `symbol-name`——`post-gc-hook` 里任何分配都会让下一次 GC 提前，形成自我加速。字符串转换推迟到 10 秒窗口 tick 的 flush 路径。
- 与 `el-chronos-mode` 联动：`-1` 时 `remove-hook` + 清空内存 hash。

### 语义局限（必须写进 docstring 与文档，不得含糊）

- 表回答的是「**GC 发生在哪条命令之后 / 哪个 mode 里**」，**不是**「哪条命令导致 GC」。
- 归因键是 GC 时刻的 `this-command` × `major-mode`。**GC 时刻没有正在执行的命令**时 `this-command` 为 `nil` → 记 `"<none>"`。这一档包括：启动期、batch、命令循环**等待输入**期间，以及 idle timer / 进程过滤器回调（三者都不在命令执行中）。命令循环只在真正运行命令前才设置 `this-command`，故等待输入期间它是 `nil` 而**不是**上一条命令——旧稿「idle / 进程过滤器里 `this-command` 是上一条命令」的滞后断言与 `info` 手册及实测均不符，已删除。
- **实测（本机真实库，2026-10-26）**：45 次归因中 **37 次（88.1%）** 落 `"<none>"`，集中在交互会话（`eca-chat-mode` 21 / `fundamental-mode` 10 / `magit-status-mode` 3），**不是**启动期或 batch。因此「按命令归因」的覆盖率有限——命令维度只对「命令执行期 GC」有效，mode 维度更稳。
- 与 `hourly_gc`（总量）的关系：`sum(hourly_gc_attrib.gc_count)` 应≈ `hourly_gc.gc_count`，差值即「hook 安装前 / 采集窗口外的 GC」。（实现口径为 `≤`，见 `openspec/tech-debt.md` TD-31：不得写成等式。）

### 分析

新增 `el-chronos-analysis-gc-attribution (range &optional limit)`：按 `command` 聚合返回 `(:command :gc-count :gc-ms :pct)`，另提供按 `mode` 聚合的变体或参数。report 增加「GC 归因」展示，标题与首行须明确「发生在哪条命令之后」。

## 任务

- [x] C1a：`el-chronos-store.el` 新增 `--schema-version` 5、`--ddl-hourly-gc-attrib`、`--sql-migrate-v5`；迁移链按局部 `version` 变量逐级推进（v4 → v5）；新增写入函数（upsert 累加）；purge 的删除顺序插入新表（在 `sessions` 之前，与其余 `hour_ts` 表同序）
  - 验收：起始版本 0 / 1 / 2 / 3 / 4 各一条迁移用例；purge 顺序用例更新；`PRAGMA user_version` = 5
- [x] C1b：`el-chronos-collect.el` 的 `post-gc-hook` 采集 + 零分配聚合 + 窗口 flush + mode 开关联动
  - 验收：hook 体零分配审查（grep 无 `format` / `concat` / `number-to-string` / `symbol-name`）；装配/拆除用例；差值计算用例；GC 期间不递归的守卫
- [x] C1c：`el-chronos-analysis.el` 归因查询 + `el-chronos-report.el` 「GC 归因」节 + 文档六处（`docs/api.org` / `docs/architecture.org` / `docs/schema.org` / `AGENTS.md` 的查询计数 / `CHANGELOG.md` / `openspec/tech-debt.md`）
  - 验收：分析函数用例；真实库上能给出 top 命令；语义局限在 docstring 与文档里都写清
- [x] 全量验证：`make full-check` + `make lint` 分别通过；在**数据库副本**上实测 v4 → v5 迁移与 `.bak` 回滚；真实库只读验证归因结果可与 `Automatic GC` 的 29.6% 对照解释
  - 结果（2026-10-26）：`make check-parens` exit=0、`make test` **336 用例全绿（0 skipped）**、`make lint` 零告警；迁移实测 v4 → v5 通过（12 → 13 表、既有 12 表一行不变、幂等路径不生成 `.bak`、回滚守门全绿）；**第三项只部分达成**——同桶同会话覆盖 100%，但「与 29.6% 对照解释」无法成立：全库 `Automatic GC` 栈样本实测 38.28%（口径不同：栈样本数 vs GC 事件计数，且主要来自 v5 前会话），command 维度 88.1% 落 `<none>`

## 文档清单

| 文档 | 动作 |
|---|---|
| `docs/schema.org` | 新增第 13 张表、v4→v5 迁移节、`purge` 顺序表补一行 |
| `docs/api.org` | 新分析函数签名与返回 |
| `docs/architecture.org` | 「路径 6：GC 与自监控」补归因路径与语义局限 |
| `docs/ui.org` | report 新节 |
| `AGENTS.md` | analysis 查询计数 -1 → 实际数；模块清单若变动同步 |
| `CHANGELOG.md` | 新增小节（含 schema v5 标注） |
| `openspec/tech-debt.md` | 「hook 安装前的 GC 无归因」与「启动期 GC 归因为 `<none>`」两条已知边界 |

## 验证标准

| 级别 | 方法 |
|---|---|
| L1 | `make check-parens` |
| L2 | `make test`（304 + 新增，全绿） |
| L2b | `make lint`（零告警，**单独跑**） |
| L3 | 真实库**副本**上迁移 v4→v5；真实库只读查询归因结果 |

## 注意事项

1. **零分配不是建议，是不变量**：`post-gc-hook` 里分配 = 让下次 GC 提前，属自我加速。审查时以 grep 为准。
2. **不得用 `hourly_health` 的 KV 承载**：GC 归因是二维分布（command × mode），KV 会 key 爆炸且混淆「采集器自监控」语义。
3. **迁移链按版本变量逐级推进**：`--ensure-schema` 后必须把局部 `version` 同步为当前常量（历史陷阱，见 `docs/schema.org` 的「迁移 v2 → v3」节）。
4. **`gc-elapsed` 是累计值**：差值才是单次耗时；hook 里必须与上次记录的值相减，不能直接用。
5. **`this-command` 取不到值只是「GC 时刻没有正在执行的命令」，不是滞后、也不是 bug**：命令循环只在运行命令前才设置它，等待输入期间为 `nil`（→ `"<none>"`）。文档与 docstring 必须原样写出「发生在哪条命令之后」，并给出实测覆盖率（45 次中 37 次落 `<none>`）。
6. **验证口径**：`make full-check` 不含 `lint`（见 TD-30），必须分别声明。
