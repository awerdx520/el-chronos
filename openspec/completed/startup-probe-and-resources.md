# 启动探针（early-init）+ 资源观测（CPU / RSS / 负载）

## 当前状态

- 阶段：Phase 4（Review & Document）· **已完成并归档**（2026-10-26）
- 已确认：方案 ✅（用户 2026-10-26 确认；三项拍板：① org 报告 14→15 节，新增独立「资源」节；② `el-chronos` 与 `thomas-emacs` 两个仓库都改；③ 探针与资源采集默认开启、可 `defcustom` 关闭）
- 已确认：计划 ✅（门禁 2 通过）；L1 / L2 / L3 全部通过
- 最终基线：**304 用例全绿、lint 零告警、check-parens 通过**（`make full-check` 实测 `Ran 304 tests, 304 results as expected, 0 unexpected`，约 5.0 s，**0 skipped**）
- 结果（7 模块 → **8 模块**、11 表 → **12 表**、Web 18 → **19 路由**、org 报告 14 → **15 节**、analysis 18 → **21 查询**、defcustom 21 → **23**、interactive 命令 15 → **16**、ERT 237 → **304**）：schema v4 新增 `hourly_resources`；零依赖探针 `el-chronos-startup-probe.el`（318 行 / 16 用例）由 `early-init.el` 提前加载；collect 侧探针交接（`--startup-take-probe`）与资源采集（`--collect-resources`，复用既有 10 秒 timer、TRAMP 守卫、逐字段降级）；analysis `resource-trend` / `resource-summary`；Web `/api/resources` + 资源面板；org 报告「资源（CPU / 内存 / 负载）」节；ADR-0006；五份 `docs/*.org` + `AGENTS.md` + `CHANGELOG.md` + `openspec/tech-debt.md` 全部同步
- 归档时已知残留：
  - **TD-16**（启动分解的物理边界）——本批用 early-init 探针正面处置，但 `startup` 锚点之后事件循环之前的少量加载仍可能缺失；探针路径写死仓库绝对路径，搬迁后 `(load … t)` 静默失败（排障口诀：`load:*` 为 0 条先查路径）
  - **TD-25**（`make test` 在仓库根泄漏临时目录）、**TD-27**（`hourly_resources` 缺独立 `rss_n`，RSS 均值分母复用 `load_n`）、**TD-28**（`cpu_ms` / `wall_ms` 是 `NOT NULL DEFAULT 0`，`cpu_pct = 0` 有「未采集 / 真空闲」两义，彻底区分需 schema v5）
  - **真实启动验证待用户在真机确认**：重启 Emacs 后 `/api/startup` 的 `phases` 应出现 `early-init` / `after-init` / `startup` / `mode-start` 且 `loads` 非空 —— 不可自动化，已列入 `docs/operations.org` 的验证步骤

## 背景与根本问题

### 取证（2026-10-26，数据库与配置实测）

| 证据 | 事实 |
|---|---|
| `startup_phases` | 20 个会话、共 20 行，phase 全为 `mode-start`，`load:*` 明细 **0 条** |
| `sessions.startup_ms` | 2.16–4.23 s（中位 ~2.6 s），有值 |
| `mode-start − startup_ms` | **+299 ~ +936 ms**（20/20 恒为正）→ mode 启动晚于 `after-init` |
| 配置 | `thomas-emacs/lisp/init-chronos.el:64` `(add-hook 'emacs-startup-hook (lambda () (el-chronos-mode 1)))` |
| 采集侧 | `el-chronos-collect.el:1181` `(unless (bound-and-true-p after-init-time) …)` → 启动已结束则**一个钩子都不挂** |
| 资源维度 | 全仓无 CPU 利用率 / RSS / 负载采集（`cpu` 仅命中 `profiler-cpu-*` 句柄） |

### 根本问题

1. **启动打点挂在 `el-chronos-mode` 上，而 mode 在启动结束后才启用** → init 主体加载物理上测不到。`openspec/tech-debt.md` TD-16 把该现象记为「不修（物理边界）」，但实测体验是「功能形同虚设」。出路：把**探针从 mode 剥离**，提前到 `early-init.el` 落位。
2. **观测面缺资源维度** → Emacs 内置 `process-attributes` / `load-average` 可零依赖补齐。

## 目标

1. 装了探针的配置下，`startup_phases` 含 `early-init` / `after-init` / `startup` / `mode-start` / `first-idle` 锚点 + `load:<库>` 明细（按 `el-chronos-startup-top-n` 截断），可在 Web 与 org 报告中定位「哪个包 / 哪个阶段慢」。
2. 未装探针时行为与现状**完全一致**（降级可见：面板明确提示「未安装 early-init 探针」）。
3. 新增资源趋势：Emacs 进程 CPU%（`time` 差分 / wall 时间，user+sys 合计）、RSS 峰值与均值、线程数峰值、系统负载 1/5/15 均值，按小时桶聚合。
4. 采集开销仍低于测量噪声，**采集期不新增常驻 timer**（I5 清理清单不变；探针的 0 延迟收尾 timer 与 30 秒兜底 timer 只存在于启动期，且 `--finish` 内必须 cancel）。
5. 不变量 I1–I11 全部不被破坏。

## 设计

### D1 启动探针（新文件 `el-chronos-startup-probe.el`）

- **零依赖**：只用内置 `float-time` / `puthash` / `gethash` / `add-hook` / `remove-hook` / `run-with-timer` / `condition-case`；**不** require 任何 el-chronos 模块，**不** require cl-lib / subr-x。
- 内存态：`--loads`（hash library → 累计 ms）、`--anchors`（alist phase → 相对 `before-init-time` 的 ms）、`--last-load-ts`、`--load-count`、`--done-p`。
- 加载即：记 `early-init` 锚点、挂 `after-load-functions` / `after-init-hook` / `emacs-startup-hook`。
- 锚点语义：`early-init`（探针加载时刻）、`after-init`（`after-init-hook`）、`startup`（`emacs-startup-hook`；因 early-init 期 `add-hook` 为前插，排在用户回调之前）。
- 收尾：`emacs-startup-hook` 回调内用 `(run-with-timer 0 nil #'--finish)` 延迟到事件循环下一轮 → **覆盖整个 `emacs-startup-hook` 段之后**再摘 `after-load-functions`；`--finish` 幂等。
- **兜底摘钩**（防 `emacs-startup-hook` 不触发）：`init` 报错等异常下 `emacs-startup-hook` 不会跑，`--finish` 永不触发 → `after-load-functions` 永久残留且无上限累积。因此探针另设两条独立下界：① `--load-count` 达到 **800** 时立即 `--finish`（量级依据：一次正常启动加载数百个库，800 ≈ 2 倍，只为防病态累积，不是可调业务阈值）；② `after-init-hook` 里登记 **30 秒**兜底 timer，到时无条件 `--finish`。三条摘钩路径（正常 / load-count / 兜底 timer）全部幂等，且 `--finish` 内**必须 cancel 兜底 timer**（否则它是探针侧唯一遗留 timer，而 `el-chronos-mode -1` 碰不到探针生命周期，I5 在此无覆盖）。
- 交接接口：`el-chronos-startup-probe-data`（**只读**全量，不清空）与 `el-chronos-startup-probe-take`（`anchors` **只读不重置**，`loads` **取走即清空** → 支持多次增量 take）。两者均 `condition-case` 包裹，**绝不抛错**（I6）。
- `--finish` 后数据仍留内存等 collect 拉取（几百条 cons，可忽略）。
- 口径：沿用「相邻两次 `after-load-functions` 回调的差值」，docstring **必须原样保留「近似归因」措辞**（TD-16 的可见性约束）。

### D2 交接（`el-chronos-collect.el`）

- `--startup-instrument` 开头尝试 `(when (fboundp 'el-chronos-startup-probe-take) …)`：
  - **有数据**（`captured-p` 非 nil）→ **不挂任何自有钩子**；锚点全部写库（值来自探针），`loads` 按 `el-chronos-startup-top-n` 截断后逐条 `el-chronos-store-record-startup-phase`。
  - **无数据**（探针未加载）→ 完全走现状逻辑，一字不改。
- **`take` 语义**：返回 plist `(:anchors ALIST :loads ALIST :captured-p t)`；`anchors` **只读不重置**（重复写同 phase 同值由 `startup_phases` 主键 upsert 吸收，幂等），`loads` **取走即清空**（增量语义，供多次 take）。collect 侧把「take + 写库」封装为单一函数 `el-chronos-collect--startup-take-probe`，首次交接与探针软调用补写**都走它**，行为只有一份。
- **二次增量补写（必须实现，载体是探针主动软调用）**：首次 take 发生在 mode 启动时刻，探针真正摘钩在事件循环下一轮 —— 两者之间的加载（mode 自身加载的 `sqlite` / `org` 等）无人拉取。故在探针 `--finish` 内部执行 `(when (fboundp 'el-chronos-collect--startup-take-probe) (el-chronos-collect--startup-take-probe))` 软调用，由 collect 把增量 loads 补写；collect 未加载（用户还没启用 mode）时 `fboundp` 为 nil，数据留内存等下次 take。**不用 `first-idle`**：collect 现有 docstring 已否决「用 idle 时机做数据补写」（idle 时机不可预期），且其 timer 注册在 `(unless after-init-time …)` 分支内、本机场景根本不会注册。**明确口径**：load 明细覆盖 `early-init` 探针上岗起 → 最后一次 take 时刻；`startup` 锚点之后到启动结束之间的少量加载可能缺失（相对现状「一个钩子都不挂」不构成退化）。
- 探针存在时**仍记 `mode-start`**（观测器真正上岗时刻，语义独立）；`first-idle` 仍由 collect 注册。

### D3 资源采集（`el-chronos-collect.el`）

- 新函数 `el-chronos-collect--collect-resources`，在 `--sample-tick` 中与 `--collect-gc` **并列**调用（放在 `sampling-p` 之外，与 profiler 互不依赖）。
- 数据源（全部 `condition-case`；逐字段 `assq` 取值，缺失即 NULL）：
  - `(process-attributes (emacs-pid))`：`time`（utime+stime，`current-time` 格式）→ 与上次差值算 `cpu_ms`；`rss`（KB）；`thcount`。
  - `(load-average t)`：1/5/15（文档明确「取不到会抛错」→ 吞掉，本窗口三字段不计）。
- **TRAMP 守卫**：`process-attributes` 的 docstring 明确「`default-directory` 为 remote 时 PID 被当作远端主机进程」。`--sample-tick` 的 timer 会捕获创建时的 `default-directory`，故 `--collect-resources` 内必须先 `(let ((default-directory temporary-file-directory)) …)` 再取值。
- **补写路径不得阻塞输入**：`--startup-take-probe` 的写库必须走 `--safe-apply` 并对齐 store 既有 flush 批（避免在事件循环第一轮做同步 SQLite 写而卡住用户第一次输入）；`process-attributes` / `load-average` 的取值同样 `condition-case` 包裹。
- 内存累加态 `--resource-acc`（plist：cpu-ms / wall-ms / rss-max / rss-sum / threads-max / load1-sum / load5-sum / load15-sum / n），每采样窗口 upsert 到 `hourly_resources`；**首个窗口只建基线**（与 GC 口径一致）。
- defcustom：`el-chronos-resource-sampling`（默认 `t`；nil 则完全不采、零开销）。

### D4 schema v4（`el-chronos-store.el`）

- `--schema-version` 3 → **4**，新增 DDL：

  `CREATE TABLE IF NOT EXISTS hourly_resources (hour_ts INTEGER NOT NULL, session_id INTEGER NOT NULL, cpu_ms REAL NOT NULL DEFAULT 0, wall_ms REAL NOT NULL DEFAULT 0, rss_kb_max INTEGER, rss_kb_sum INTEGER, threads_max INTEGER, load1_sum REAL, load5_sum REAL, load15_sum REAL, load_n INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (hour_ts, session_id));`

- 迁移：`(sqlite-pragma db "user_version=4")` 分支追加在 v3 之后；`.bak` 回滚机制复用现状；补齐 v0→v4 / v1→v4 / v2→v4 / v3→v4 四条守门用例。
- 新记录函数 `el-chronos-store-record-resources`（upsert 累加，写法同 `hourly_gc`；调用方用 `--safe-apply` 包裹）。
- `el-chronos-purge` 删除清单 **11 → 12 表**。

### D5 展示

- `el-chronos-analysis.el`：`el-chronos-analysis-resource-trend (range &optional buckets)`（按桶返回 cpu-pct / rss-avg / rss-max / threads-max / load1-avg / load5-avg / load15-avg）与 `el-chronos-analysis-resource-summary (range)`（窗口均值与峰值，供概览卡片）。
- `el-chronos-web.el`：`/api/resources` 路由（**18 → 19**）；概览卡片加「CPU 均值」「RSS 峰值」「负载 1m」；新增 `<section>资源（CPU / 内存 / 负载）</section>`（CPU% 折线 + RSS 折线 + 负载图例）；CSV 区块 **9 → 10**。
- `el-chronos-report.el`：新增「资源（CPU / 内存 / 负载）」节（**14 → 15**），含窗口均值/峰值表与上一窗口对比；CSV 区块同步。

## 假设清单

| # | 假设 | 标记 | 处置 |
|---|---|---|---|
| 1 | `before-init-time` 在 `early-init.el` 执行前已绑定 | 事实✓ | — |
| 2 | 探针零依赖可行（只用内置 subr） | 事实✓ | — |
| 3 | early-init 需手动 `add-to-list 'load-path`（straight build 目录尚未建立） | 事实✓ | 写进 `docs/operations.org` + 配置侧 2 行 |
| 4 | `process-attributes` 本机返回 `rss` / `thcount` / `time` | 假设? | **L3 实测确认**；字段缺失则落 NULL，不报错 |
| 5 | `load-average` 本机可用但取不到会抛错 | 事实✓ | `condition-case` 吞掉 |
| 6 | v3→v4 只新增表、不改既有列 → 迁移低风险 | 事实✓ | 补齐 4 条守门用例 |
| 7 | 探针内存数据量（几百条）无害 | 事实✓ | — |
| 8 | 用户目标是「启动变慢能定位到具体包」 | 用户显式 | 已确认 |

## 任务

- [x] **T1** store v4：`hourly_resources` DDL + 迁移分支 + `record-resources` + purge 12 表 + 测试（v0/v1/v2/v3→v4 四条守门 + 累计写入 + purge 计数）；并补「v3→v4 迁移后既有 11 表数据不受损」与「链式推进各迁移脚本恰好各跑一次」两条断言
  - 交付：`el-chronos-store.el` 的 `--schema-version` 3 → **4**、`--ddl-hourly-resources`、`--sql-migrate-v4`、`--sql-upsert-resources`、`el-chronos-store-record-resources`、purge 11 → **12 表**；`test/el-chronos-store-test.el` 四条迁移守门（v0/v1/v2/v3 → v4，均断言「12 表齐备、`hourly_resources` 为空、更早脚本不重跑」）
- [x] **T2** 新文件 `el-chronos-startup-probe.el` + 测试（加载记锚点 / after-load 差值 / take 增量语义（`anchors` 只读不重置、`loads` 取走即清空）/ 无 `before-init-time` 不崩 / 异常吞掉）
  - 交付：`el-chronos-startup-probe.el`（**318 行**）+ `test/el-chronos-startup-probe-test.el`（**16 用例**）；三条自证收尾路径（`emacs-startup-hook` / `load-count` 800 / `after-init` 30 秒兜底 timer）全部汇到幂等的 `--finish`，自摘钩子 + `cancel-timer`
- [x] **T3** collect：探针交接 + 资源采集 + 1 个 defcustom（`el-chronos-resource-sampling`）+ 测试（有/无探针两路、top-n 截断、资源累计与首窗口基线、`load-average` 抛错降级）；含「探针 --finish 软调用补写增量」与「collect 未加载时 fboundp 为 nil 不报错」两个用例
  - 交付：`el-chronos-collect.el` 的 `--startup-take-probe`（首次交接与探针软调用补写共用同一函数）、`--collect-resources`（TRAMP 守卫 + 逐字段降级 + 首窗口只建基线 + 不新增 timer）、`el-chronos-resource-sampling` defcustom；`test/el-chronos-collect-test.el` 新增 79 用例中的对应部分（含「探针 --finish 软调用补写增量」「collect 未加载时 `fboundp` 为 nil 不报错」）
- [x] **T4** analysis：`resource-trend` + `resource-summary` + 测试（fixture 断言均值/峰值/桶合并）
  - 交付：`el-chronos-analysis.el` 两函数（可空列一律 NULL 而非 0，`load_n = 0` 时均值为 NULL）+ `test/el-chronos-analysis-test.el` fixture 断言
- [x] **T5** web：`/api/resources` + 概览卡片 + section + CSV 区块 + 测试（路由 / JSON 形状 / 空表降级）
  - 交付：路由 18 → **19** 条、概览 3 张资源卡 + 「资源」section、CSV web 侧 12 → **13** 块；`test/el-chronos-web-test.el` 25 用例
- [x] **T6** report：资源节 + CSV 区块 + 测试（节数 15、空数据文案）
  - 交付：org 报告 14 → **15** 节（位置紧接「GC 与内存」）、CSV report 侧 9 → **10** 块、I11 的具体降级文案；`test/el-chronos-report-test.el` 38 用例
- [x] **T7** thomas-emacs 接入：`early-init.el` 加 2 行（`add-to-list 'load-path` + **`(load "el-chronos-startup-probe" t)`**，用 `t` 让探针缺失/仓库搬迁时不打断 early-init），带 `THOMAS_EMACS_INSTANCE` 守卫（与 `init-chronos.el` 一致）
  - 交付：`thomas-emacs/early-init.el` 按上述形态接入（仓库路径写死为绝对路径，静默降级口径见 `docs/operations.org` 与 `AGENTS.md`「已知边界」）；**真实启动验证需用户在真机重启后确认**，本计划不含自动化
- [x] **T8** 文档同步：`AGENTS.md` / `docs/{architecture,schema,api,ui,operations}.org` / `docs/adr/0006-resource-observation.md` / `openspec/decisions.md` / `openspec/tech-debt.md`（TD-16 改写）/ `CHANGELOG.md` / `Readme.org`
  - 交付：五份 `docs/*.org` + ADR-0006 + `AGENTS.md`（目录结构表 / 基线 / 已知边界）+ `CHANGELOG.md`（新增 / 变更 / 修复三段）+ `Readme.org` + `openspec/decisions.md`（1 行）+ `openspec/tech-debt.md`（TD-16 改写为「已由探针正面处置」、新增 TD-25～TD-28）全部同步
- [x] **T9** 归档：计划移入 `openspec/completed/`，基线数字全部更新（用例数、7 模块 → **8 模块**、11 表 → **12 表**、18 路由 → **19 路由**、14 节 → **15 节**、defcustom 21 → **23**、analysis 18 查询 → **21**）；同步「11 表 / 11 张表」字面量共 **12 处**（`el-chronos-store.el` 6 处：100 / 422 / 463 / 1344 / 1410 / 1413 行；`test/el-chronos-store-test.el` 6 处）
  - 交付：本文件移入 `openspec/completed/`；`el-chronos-store.el` 的「11 表」字面量已清零（`grep -c "11 表\|11 张表"` = **0**），`test/el-chronos-store-test.el` 保留的 7 处**均是 v3 老库 fixture 的正确描述**（「v3 的 11 表」），不是当前基线，故不改；`AGENTS.md` 基线 301 → **304**、`openspec/active/` 归空
  - **勘误**：本行原写「defcustom 21 → **22**」为错，实测 **23**（`el-chronos.el` 21 + collect 1 + report 1）

## 依赖关系

- T1、T2 无依赖，可并行
- T3 依赖 T1 + T2
- T4 依赖 T1
- T5、T6 依赖 T4，彼此可并行
- T7 依赖 T2 + T3
- T8 依赖 T1–T7
- T9 依赖 T8

## 文档清单

`AGENTS.md`、`docs/architecture.org`、`docs/schema.org`、`docs/api.org`、`docs/ui.org`、`docs/operations.org`、`docs/adr/0006-resource-observation.md`（新建）、`openspec/decisions.md`、`openspec/tech-debt.md`、`CHANGELOG.md`、`Readme.org`

## 验证标准

- **L1**：`make check-parens` + `make lint` 零告警（新文件自动纳入 `EL_FILES`）
- **L2**：`make test` 全绿，用例数只升不降（237 → 预计 +20~25）；elisp 验证一律走 `verify` 隔离实例（`elisp_mcp_set_task("verify")` → ERT → 收尾 `set_task("auto")` + `elisp_mcp_instance(action="stop", instance="verify")`）
- **L3**：Web `/api/resources` 返回合法 JSON；`process-attributes` 实际返回字段实测并记入 `docs/architecture.org`「实测结论」；探针在隔离实例注入 after-load 序列后 `startup_phases` 出现 `load:*` 行
- **真实启动验证**：用户重启 Emacs 后 `/api/startup` 的 `phases` 出现 `early-init`/`after-init`/`startup`/`mode-start`，`loads` 非空 —— **不可自动化**，列入 Phase 4 复查项与 `openspec/tech-debt.md`
- **不变量**：I5（stop 后 timer/hook/内存态归零）、I6（所有采集路径 `condition-case`）、I8（Web 仍只绑 `127.0.0.1`）、I10（无外链）、I11（端口占用 `user-error` 且不换端口）

## 注意事项

- 探针在 early-init 运行，**任何异常都必须吞掉**；绝不能因探针失败影响启动。
- 探针只在 `early-init.el` 里由用户显式 `(load "el-chronos-startup-probe" t)`，因此**不需要 autoload cookie**；本计划**不新增 interactive 命令**，`test/el-chronos-autoload-test.el` 的 cookie 计数不变量不受影响。若实现中决定加命令，必须在同一次改动内补 cookie，否则用例变红。
- 新增 `hourly_resources` 后必须同步：`purge` 删除清单、`docs/schema.org` 表计数、`AGENTS.md`「11 表」表述、`docs/ui.org` 路由与节数计数。文档与代码不一致即算未完成。
- 资源采集**不得**调用 `garbage-collect` 或 `memory-info`（TD-15 明令：后者是系统内存且 remote 下会查远端）；`process-attributes` 只查 `(emacs-pid)`，**不得**遍历全系统进程。
- `load-average` 与 `process-attributes` 的失败必须**逐字段降级**（一个字段失败不影响其余）。
- 探针「覆盖范围」措辞必须保留：报告节与 Web 面板需标注「自 early-init 探针上岗起」，**不得**把近似数据冒充全程（TD-16 的可见性约束）。
- **探针加载失败不得打断启动**：配置侧必须用 `(load "el-chronos-startup-probe" t)` 形态；`condition-case` 只兜住探针运行期，兜不住 `require` 加载期。
- **探针摘钩需三条路径全部实现**（`--finish` 幂等）：正常 `emacs-startup-hook` 路径、`--load-count` 上限路径、`after-init` 30 秒兜底 timer 路径。缺任一都可能让 `after-load-functions` 永久残留。
- **二次补写的软调用方向是单向的**：探针 → collect（用 `fboundp` 守卫），collect 永不反向 require 探针。这样探针保持零依赖，collect 也不知道探针是否安装。
