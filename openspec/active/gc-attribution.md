# GC 归因（schema v5）

## 当前状态

- 阶段：Phase 3（Implement）· 收尾
- 已确认：方案 ✅（用户 2026-10-26 决定「现在做」）
- 计划 ✅
- 进度：C1a ✅（schema v5 + 表 + 写入 + purge）、C1b ✅（post-gc-hook 采集 + 零分配 + 窗口 flush）、C1c ✅（analysis + report 第 16 节 + 文档）；`make test` 335/335
- 下一步：全量验证（`make full-check` + `make lint` 分别通过、真实库副本迁移复核、真实数据可解释性）与计划归档

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
- GC 可能发生在 idle timer / 进程过滤器里，此时 `this-command` 是上一条命令，存在滞后。
- 启动期 GC 的 `this-command` 通常为 nil → 记 `"<none>"`。
- 与 `hourly_gc`（总量）的关系：`sum(hourly_gc_attrib.gc_count)` 应≈ `hourly_gc.gc_count`，差值即「hook 安装前 / 采集窗口外的 GC」。

### 分析

新增 `el-chronos-analysis-gc-attribution (range &optional limit)`：按 `command` 聚合返回 `(:command :gc-count :gc-ms :pct)`，另提供按 `mode` 聚合的变体或参数。report 增加「GC 归因」展示，标题与首行须明确「发生在哪条命令之后」。

## 任务

- [x] C1a：`el-chronos-store.el` 新增 `--schema-version` 5、`--ddl-hourly-gc-attrib`、`--sql-migrate-v5`；迁移链按局部 `version` 变量逐级推进（v4 → v5）；新增写入函数（upsert 累加）；purge 的删除顺序插入新表（在 `sessions` 之前，与其余 `hour_ts` 表同序）
  - 验收：起始版本 0 / 1 / 2 / 3 / 4 各一条迁移用例；purge 顺序用例更新；`PRAGMA user_version` = 5
- [x] C1b：`el-chronos-collect.el` 的 `post-gc-hook` 采集 + 零分配聚合 + 窗口 flush + mode 开关联动
  - 验收：hook 体零分配审查（grep 无 `format` / `concat` / `number-to-string` / `symbol-name`）；装配/拆除用例；差值计算用例；GC 期间不递归的守卫
- [x] C1c：`el-chronos-analysis.el` 归因查询 + `el-chronos-report.el` 「GC 归因」节 + 文档六处（`docs/api.org` / `docs/architecture.org` / `docs/schema.org` / `AGENTS.md` 的查询计数 / `CHANGELOG.md` / `openspec/tech-debt.md`）
  - 验收：分析函数用例；真实库上能给出 top 命令；语义局限在 docstring 与文档里都写清
- [ ] 全量验证：`make full-check` + `make lint` 分别通过；在**数据库副本**上实测 v4 → v5 迁移与 `.bak` 回滚；真实库只读验证归因结果可与 `Automatic GC` 的 29.6% 对照解释

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
5. **`this-command` 滞后是设计局限，不是 bug**：文档与 docstring 必须原样写出「发生在哪条命令之后」。
6. **验证口径**：`make full-check` 不含 `lint`（见 TD-30），必须分别声明。
