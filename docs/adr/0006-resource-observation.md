# ADR-0006 启动探针提前到 early-init + 资源维度观测

- **状态**：Accepted（已接受，**已实施** —— 落地计划 `openspec/completed/startup-probe-and-resources.md` 已完成并归档，schema v4 落地，2026-10-26）
- **日期**：2026-10-26
- **决策者**：用户（明确要求「启动变慢能定位到具体包」并接受配置侧改动；三项拍板：① org 报告 14 → 15 节、新增独立「资源」节；② `el-chronos` 与 `thomas-emacs` 两个仓库都改；③ 探针与资源采集默认开启、可 `defcustom` 关闭）
- **关联**：`openspec/completed/startup-probe-and-resources.md`（落地计划）、
  `openspec/tech-debt.md` TD-16（本 ADR 正面处置其覆盖范围限制）与 TD-15（`memory-info` 排除依据）、
  `docs/architecture.org`（路径 5 启动打点 / 已知偏差）、`docs/schema.org`（v4 DDL）、
  `AGENTS.md` I5 / I6 / I10、`openspec/decisions.md`、前序 `docs/adr/0004-observation-surface-expansion.md`

## 背景

### 一、TD-16 的覆盖范围限制在实测中等于「功能形同虚设」

ADR-0004 的 D3 用 `after-load-functions` 相邻两次回调的差值做启动分解，并如实标注了边界：
只有 **mode 装设之前**发生的 load 才被记录，启动已结束时**根本不挂**该钩子（否则启动后的
交互式 load 会被记成「启动耗时」）。TD-16 把这条记为「不修（物理边界，非 bug）」，给出的
替代路径是「把 `(el-chronos-mode 1)` 提前到 `early-init.el`」。

2026-10-26 对本机库与配置的取证表明，这个「边界」在本机配置下把功能压成了零：

| 证据 | 事实 |
|---|---|
| `startup_phases` | 20 个会话、共 20 行，`phase` 全为 `mode-start`，`load:*` 明细 **0 条** |
| `sessions.startup_ms` | 2.16–4.23 s（中位 ~2.6 s），有值 |
| `mode-start − startup_ms` | **+299 ~ +936 ms**（20/20 恒为正）→ mode 启动稳定晚于 `after-init` |
| 配置侧 | `thomas-emacs/lisp/init-chronos.el:64` `(add-hook 'emacs-startup-hook (lambda () (el-chronos-mode 1)))` |
| 采集侧 | `el-chronos-collect.el:1181` `(unless (bound-and-true-p after-init-time) …)` → 启动已结束则**一个钩子都不挂** |

结论：`startup_phases` 实际只承担「观测器自己什么时候上岗」这一个锚点，**init 主体加载
物理上测不到**。它仍是正确的观测数据（不冒充全程），但用户的问题「启动变慢慢在哪个包」
完全无法回答 —— 「不修」在语义上没错，在效用上等于没有这个功能。

### 二、观测面缺资源维度

ADR-0004 把维度从「时间」扩到「时间 + 内存 / GC + 启动 + 配置变更」，但「内存」只有
`heap_bytes`（Emacs 堆，且 31.1+ 才有）与 GC 计数，**没有**进程级 CPU 利用率、RSS、
线程数，也没有系统负载。于是「Emacs 越用越占 CPU」「RSS 缓慢爬升」「机器整体在忙」三类
问题在库里没有任何痕迹，只能靠外部 `top` 手看，无法回看趋势。

而这三维**零依赖可取**：Emacs 内置 `process-attributes`（查自身 pid 的 `time` / `rss` /
`thcount`）与 `load-average`，不需要起子进程、不引第三方包。

## 决策

**启动探针从 `el-chronos-mode` 剥离为独立零依赖文件，由用户在 `early-init.el` 显式
`(load "el-chronos-startup-probe" t)`；资源采集并入既有采样 timer，schema v4 新增 `hourly_resources`。**
四条具体决策如下。

### D1 探针独立成文件、只写内存、不碰 SQLite

新增 `el-chronos-startup-probe.el`：

- **零依赖**：只用内置 `float-time` / `puthash` / `gethash` / `add-hook` / `remove-hook` /
  `run-with-timer` / `condition-case`；**不** require 任何 el-chronos 模块、也不 require
  cl-lib / subr-x（early-init 期 `straight/build-*` 目录尚未建立，任何 require 都可能失败）。
- **只写内存**：`--loads`（hash library → 累计 ms）、`--anchors`（alist phase → 相对
  `before-init-time` 的 ms）、`--last-load-ts`、`--load-count`、`--done-p`。
  探针**不开库、不建库、不写库** —— SQLite 与 flush 事务全部留给 collect，启动路径上
  不出现任何可能阻塞的 IO。
- **锚点**：`early-init`（探针加载时刻）、`after-init`（`after-init-hook`）、
  `startup`（`emacs-startup-hook`，因 early-init 期 `add-hook` 为前插，排在用户回调之前）。
  收尾用 `(run-with-timer 0 nil #'--finish)` 延迟到事件循环下一轮再摘 `after-load-functions`，
  以覆盖整个 `emacs-startup-hook` 段之后的加载。
- **兜底摘钩**：`init` 异常时 `emacs-startup-hook` 不会跑 → `after-load-functions` 会永久残留且无上限累积。
  故除正常路径外另设两条下界：`--load-count` 达 800 立即 `--finish`（量级依据：一次正常启动加载数百个库，
  800 ≈ 2 倍，只为防病态累积）、`after-init-hook` 里登记 30 秒兜底 timer。三条路径全部幂等，
  且 `--finish` 内**必须 cancel 该兜底 timer** —— 探针不在 `el-chronos-mode` 生命周期内，
  `el-chronos-mode -1` 碰不到它，I5 在此无覆盖。
- **失败即静默**：所有入口 `condition-case` 包裹，绝不向宿主抛错（I6）；early-init 期的
  异常会直接影响启动，这是本决策唯一不可让步的硬约束。

「近似归因」的措辞与覆盖范围标注（自 early-init 探针上岗起）**原样保留**，不得把近似数据
冒充全程 —— TD-16 的可见性约束不因本 ADR 而放松。

### D2 交接用「collect 主动 take」，不依赖 hook 顺序

`el-chronos-collect--startup-instrument` 开头尝试
`(when (fboundp 'el-chronos-startup-probe-take) …)`：

| 探针数据 | 行为 |
|---|---|
| 有（`captured-p` 非 nil） | **不挂任何自有钩子**；锚点全部写库（值来自探针），`loads` 按 `el-chronos-startup-top-n` 截断后逐条落 `startup_phases` |
| 无（探针未加载） | 完全走现状逻辑，一字不改 |

`take` 的 `anchors` 只读不重置、`loads` 取走即清空（增量语义，支持多次 take）；`data` 是纯只读快照。选「collect 主动拉」
而不是「探针完成后推」的理由：推送需要探针知道 collect 何时就绪（探针不能 require
collect，early-init 期加载会拖启动），而主动拉取把时序问题降级为一次 `fboundp` 判定，任何启用时机都不会因 hook 顺序而**全量**丢失数据。但需明确边界：首次 `take` 发生在 mode 启动时刻，探针真正摘钩在事件循环下一轮，两者之间的少量加载（mode 自身加载的 `sqlite` / `org` 等）不由首次 take 覆盖，故设计上由探针在 `--finish` 内部软调用 collect（`fboundp 'el-chronos-collect--startup-take-probe` 守卫）补写增量。此方案取代了备选的「`first-idle` 时二次 take」——idle 时机不可预期（collect 现有 docstring 已否决该用法），且其 timer 在被跳过的分支内、本机配置下永不注册。即便如此，load 明细的覆盖终点是「最后一次 take 时刻」而非「启动结束」，此口径必须原样出现在报告与面板措辞中。

探针存在时**仍记 `mode-start`**（观测器真正上岗时刻，语义独立）；`first-idle` 仍由 collect
注册（探针只管启动阶段的加载）。

### D3 资源采集并入既有采样 timer，schema v4 新增 `hourly_resources`

- **不新增 timer**：`el-chronos-collect--collect-resources` 在 `--sample-tick` 中与
  `--collect-gc` 并列调用，且放在 `sampling-p` 之外（与 profiler 互不依赖，profiler 起不来
  时资源仍采）。I5 的清理清单因此不变 —— 没有新 timer 需要 stop 时清理（探针的启动期
  一次性 timer 属 D1，不在采集器 timer 清单内）。
- **数据源**：`(process-attributes (emacs-pid))` 取 `time`（utime+stime，`current-time` 格式）
  做差分算 `cpu_ms`、`rss`（KB）、`thcount`；`(load-average t)` 取 1/5/15。
  （`process-attributes` 另有 `pcpu` 字段，但它是「自进程启动以来的累计百分比」，早期高 CPU 会永久拉高均值，不适合窗口趋势，故用 `time` 字段做窗口差分。）
  **只查自身 pid，不遍历全系统进程**。
- **逐字段降级**：每个字段独立 `assq` 取值 + `condition-case`，一个字段缺失即该字段 NULL，
  不影响其余（`load-average` 文档明确「取不到会抛错」，必须吞掉）。
- **首窗口只建基线**：与 GC 口径一致，第一个采样窗口只记起点，故首个桶的 `cpu_ms` 可能偏小。
- **schema v4**：`--schema-version` 3 → 4，新增表

  ```sql
  CREATE TABLE IF NOT EXISTS hourly_resources (
    hour_ts INTEGER NOT NULL, session_id INTEGER NOT NULL,
    cpu_ms REAL NOT NULL DEFAULT 0, wall_ms REAL NOT NULL DEFAULT 0,
    rss_kb_max INTEGER, rss_kb_sum INTEGER, threads_max INTEGER,
    load1_sum REAL, load5_sum REAL, load15_sum REAL,
    load_n INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (hour_ts, session_id));
  ```

  upsert 累加，写法同 `hourly_gc`；`purge` 删除清单 **11 → 12 表**；`--prune` 不动它
  （小时聚合永久保留，与既有六张 `hourly_*` 同档）。
- **可关**：`el-chronos-resource-sampling`（默认 `t`），nil 则完全不采、零开销。

### D4 `memory-info` 明确排除

系统内存不采。TD-15 已论证：`memory-info` 是**系统内存**不是 Emacs 堆，且在 remote
`default-directory` 下会触发 TRAMP 查询（把远端数据写进本机库，或直接阻塞采集路径）。
本 ADR 的资源维度只取 `process-attributes`（本进程）与 `load-average`（本机内核），
两者都是本地、无子进程；`garbage-collect` 同样禁用（观测不干预，I1 语义）。

## 备选方案与被否决原因

| 替代方案 | 描述 | 否决原因 |
|---|---|---|
| ① 直接把 `(el-chronos-mode 1)` 挪到 `early-init.el` | 不改代码，只改配置：mode 在 early-init 就启用，现有 `after-load-functions` 逻辑自然覆盖 init 主体 | **early-init 期开库有阻塞启动的风险**：`el-chronos-store` 要建目录、开 SQLite、跑迁移，`sqlite` 打开带 `busy_timeout=2000ms`，迁移失败还要写 `.bak`；采集器任何异常都会直接拖慢或打断启动，而观测器的第一原则是「不干预」。探针形态把「启动期测量」与「观测器上岗（开库 / timer / profiler）」彻底解耦，风险面从「整个采集器」缩到「几百行纯内存代码」 |
| ② 保留现状，只补记「启动后发生的加载」（`post-load:` 前缀） | 不动时机，把 `emacs-startup-hook` 之后的 load 也记下来，至少数据不为空 | **测不到 init 主体，价值不足**：用户的问题是「启动慢在哪个包」，启动后的交互式 load（打开文件触发的 mode、按需加载的包）与启动耗时不构成因果关系，把它们记进 `startup_phases` 反而污染「启动分解」这个语义。实测的 2.16–4.23 s 启动时间里有多少是 init 主体，仍然无法回答 |
| ③ 类 esup 的按需精确剖析命令 | 加一个 `M-x el-chronos-profile-startup`，重启后给出精确的每包耗时报告 | **不入库、无长期趋势、需重启才能测**：esup 类工具是一次性快照，回答不了「这次改动是否引入回归」「上周到现在启动慢了 300ms 是哪个包」。而本项目的核心价值恰恰是长期趋势与回归判定。本期否决，不排斥将来作为独立命令补充（届时仍须把结果写库才能进趋势） |
| ④ 用 `memory-info` 采系统内存 | 顺手把系统内存也记下来，看起来信息更全 | **remote 下会查远端且语义错位**（TD-15）：`memory-info` 是系统内存不是 Emacs 堆，remote `default-directory` 下 TRAMP 会去查远端；把系统内存写进「这个 Emacs 用了多少」的位置会把读者引向反向结论。要系统级数据有 `load-average` 与进程 RSS 足够，且都是本地调用 |

## 后果

**正向**

- **启动分解真正可用**：装探针后 `startup_phases` 具备 `early-init` / `after-init` /
  `startup` / `mode-start` 锚点与 `load:<库>` 明细，回答「哪个包 / 哪个阶段慢」；
  同时保留 `mode-start` 与 `first-idle`，「观测器自身开销」仍可独立读出。
- **降级可见而非静默**：未装探针时行为与现状**完全一致**（走原有分支，一字不改），
  但 Web 面板与报告必须明确提示「未安装 early-init 探针」—— 空数据被解释成「没装探针」，
  而不是「启动没开销」。
- **资源画像可长期观察**：CPU%、RSS 峰值/均值、线程数峰值、负载 1/5/15 按小时桶聚合，
  回答「越用越占 CPU」「RSS 缓慢爬升」「机器整体在忙」三类问题，且能回看趋势。
- **开销可忽略、零新增依赖**：并入既有采样 timer（采集期不新增常驻 timer），数据源全是内置函数，
  不引第三方包、不起子进程（I10）。
- **风险面收缩**：early-init 期只跑「几百行纯内存代码」，不开库、不建采集类常驻 timer、不碰 profiler
  （仅在启动期注册一次性 `--finish` / 兜底 timer，`--finish` 内 cancel）；
  `condition-case` 全覆盖，探针失败不影响启动（I6）。
- **交接不依赖 hook 顺序**：`fboundp` 判定让 mode 早/晚启用都能拿到数据，不会全量丢失、不会重复计数（`anchors` 只读 + upsert 幂等；`loads` 增量）。但 load 明细的覆盖终点是「最后一次 take 时刻」，不是「启动结束」。

**负向 / 代价**

- **需要配置侧改动**：`early-init.el` 加两行（`add-to-list 'load-path` + `(load "el-chronos-startup-probe" t)`），
  且 **`load-path` 必须手动加** —— early-init 期 straight 的 `build-*` 目录尚未建立，
  不能指望包已被 straight 接管。两行都要带 `THOMAS_EMACS_INSTANCE` 守卫（与
  `init-chronos.el` 一致），否则隔离实例会跟着跑探针、污染验证结论。
- **未装探针时仍只有 `mode-start`**：这是**有意保留的降级形态**（不是缺陷），
  但必须在 UI 与报告里写清，否则用户会把它读成「采集失败」。
- **首窗口基线偏差**：第一个采样窗口只建基线，首个小时桶的 `cpu_ms` 可能偏小，
  与 `hourly_gc` 的首桶口径一致 —— 阅读时按后续桶为准。
- **多一张表与一条迁移分支**：11 → 12 表，迁移链多一级 `v3 → v4`，`purge` 顺序多一处；
  文档同步面扩大（`AGENTS.md` 表计数、`docs/schema.org`、`docs/ui.org` 路由与节数），
  文档与代码不一致即算未完成。
- **用例数上升**：预计 +20~25（当前基线 237），L2 基线只准上升。
- **探针承担了额外复杂度**：三条摘钩路径（正常 / load-count 800 / after-init 30 秒兜底）、`--finish` 内必须 cancel 兜底 timer、以及向 collect 的单向软调用。这些是为保证「探针绝不残留、绝不影响启动」付出的实现成本，且探针不在 `el-chronos-mode` 生命周期内，I5 对它没有覆盖，只能靠代码自证。

**残留边界（物理限制，不是 bug）**

- **探针加载之前的执行无法测量**：`early-init.el` 自身的执行（含 `load-path` 设置、
  `(load "el-chronos-startup-probe" t)` 之前的任何 form）与 Emacs 自身的初始化都在探针上岗之前，`before-init-time`
  是唯一的时间零点，故「Emacs 启动到探针加载」这一段只能由 `sessions.startup_ms` 与
  `early-init` 锚点的差值间接反映，不能细分到文件。
- **包加载明细仍是近似归因**：沿用「相邻两次 `after-load-functions` 回调的差值」，
  差值含前一文件的收尾逻辑与它触发的钩子；这是 ADR-0004 已确立的口径，本 ADR 不改，
  措辞必须保留。
- **真实启动验证不可自动化**：探针的真实价值只有在用户重启 Emacs 后才能验收
  （`/api/startup` 的 `phases` 出现四个锚点、`loads` 非空），该项列入 Phase 4 复查项
  与技术债。
- **`run-with-timer 0` 的覆盖范围依赖启动尾部时序**：另需注意 `run-with-timer 0` 的覆盖范围依赖「启动尾部到进入事件循环之间不进入事件循环」这一时序事实（已源码核验：`term-setup-hook` / 帧参数 / `window-setup-hook` 均为同步代码）；若将来某版本在启动尾部引入 `sit-for` / `accept-process-output`，`--finish` 会提前触发、之后的加载不再记录。

**约束（进入不变量语义的解释，不新增不变量）**

I5（采集期不新增常驻 timer、stop 后内存态归零；探针的一次性启动期 timer 不属 `el-chronos-mode` 生命周期，由 `--finish` 自行清理）、I6（探针与资源采集所有入口 `condition-case`）、
I8（Web 仍只绑 `127.0.0.1`）、I10（无外链、零第三方依赖）、I11（端口占用 `user-error` 且不换端口）。
**I1–I11 一条不改、编号不重排。**

## 关联

- 落地计划：`openspec/completed/startup-probe-and-resources.md`（T1–T9：store v4 / 探针 / collect 交接
  与资源采集 / analysis / web / report / thomas-emacs 接入 / 文档同步 / 归档）
- 技术债：`openspec/tech-debt.md` **TD-16 由本 ADR 正面处置**（改写为「walked around 而非不修」，
  覆盖范围限制改由「探针是否安装」表达）；TD-15（`memory-info` / `garbage-collect` 禁令的出处）
- 技术文档：`docs/architecture.org`（路径 5 启动打点改为「探针 + 交接」、新增资源采集路径、
  「实测结论」补 `process-attributes` 实际字段与资源开销）、`docs/schema.org`（v4 DDL 与 upsert、
  12 表 3 索引）、`docs/api.org`（新模块与两个 analysis 查询）、`docs/ui.org`（路由 18 → 19、
  报告 14 → 15 节）、`docs/operations.org`（early-init 接入指引与「未装探针」的降级说明）
- 决策表：`openspec/decisions.md`（2026-10-26 一行）
- 不变量：`AGENTS.md` I5 / I6 / I8 / I10 / I11（编号与语义均不改）
- 前序 ADR：`docs/adr/0004-observation-surface-expansion.md`（启动分解的原始设计、近似归因口径、
  新表不写外键的先例）、`docs/adr/0005-two-tier-block-detection.md`（schema 迁移链式推进的写法）
