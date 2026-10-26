# 架构决策日志

记录跨越模块边界、影响长期结构的决策。日常实现选择不入此表（写进计划或代码注释）。
每条决策的结构化展开（含替代方案与被否决原因）见 `docs/adr/`。

| 日期 | 决策 | 理由 | 关联 |
|---|---|---|---|
| 2026-10-24 | 采集采用「内置 C profiler 采样 + 命令边界计时」双源，不用 advice 全量插桩 | 采样零侵入、能抓到主线程阻塞期间的栈；advice 有开销且改变语义 | ADR-0001、I1、I2 |
| 2026-10-24 | 存储用内置 SQLite + 小时级聚合，不用 JSONL/CSV 累积 | 长期查询需要索引；原始事件量级约 86 万行/天，必须聚合 | ADR-0001、`docs/schema.org` |
| 2026-10-24 | 定位能力到「函数 + 调用链」为止，不承诺源码行级 | ELisp profiler 记录符号栈，无行号；行级只能对可疑函数做微基准+二分 | ADR-0001、`el-chronos-profile-command` |
| 2026-10-24 | 默认隐私边界为命令级，不记文件路径/按键序列/内容 | 观测器不得成为隐私风险源；文件级需用户显式改 `el-chronos-usage-granularity` | ADR-0001、I7 |
| 2026-10-24 | 可视化采用双形态（Emacs 内 ETAF 页面 + 浏览器 Web dashboard），共享同一 analysis 查询层 | Emacs 侧选 ETAF 而非内置 svg.el + tabulated-list：组件化布局、响应式状态、表格与 SVG 组合能力强，且本机已装；日常查看不离开 Emacs、深度分析在浏览器。代价：dashboard 对 ETAF 形成软依赖、需处理缺失与 terminal 降级，代码量增加约 40% | ADR-0002、I8–I11 |
| 2026-10-24 | 可视化收敛为两形态（浏览器 Web dashboard + org 报告），删除 dashboard 模块与 ETAF 软依赖 | dashboard 与 Web 能力重叠但独占总维护成本（ETAF 软依赖、双渲染路径、10 条踩坑、TD-5 内存/重绘风险、24 个用例）；Web 已覆盖全部只读查看需求且零第三方依赖 | ADR-0003、I8–I11 改写（I 编号不变，I9/I11 语义见 `AGENTS.md` 不变量清单） |
| 2026-10-25 | 观测面扩展到时间+内存+启动+配置变更：一次 schema v2 迁移新增 hourly_gc / startup_phases / hourly_health / session_meta 四表，GC 用 gcs-done+gc-elapsed（零副作用）与 garbage-collect-heapsize（31+ 守卫），变更标记零子进程读 .git，启动分解用 after-load-functions 近似 | 内存维度为零导致「越用越胖」不可观测；回归只能看到「变慢」看不到「什么变了」；ALTER 加列不幂等故全走新表 | ADR-0004、I5/I6/I10 |
| 2026-10-25 | 亚秒级卡顿采用两档阈值：block(2000ms) 保持 slow_events 明细、drift(500ms) 新增 hourly_drift 小时聚合，心跳降至 250ms | 只降心跳只解决高估不解决检出下界；降 block 阈值会让明细表爆炸；聚合表使阈值定低也不会膨胀 | ADR-0005、TD-11 |

| 2026-10-25 | 包侧提供 autoload cookie（**15 个 interactive 命令**）+ `make autoloads` 生成入口，产物 `el-chronos-autoloads.el` **不入库** | 生成物入库必然与源码漂移，按需生成即可；产物由 `EL_FILES` 显式排除、**不进 L1/L2**，否则生成后门禁检查范围会随生成物变化 | `openspec/completed/add-use-package-support.md` D1、`Makefile`、`.gitignore` |
| 2026-10-25 | 主模式**不做**延迟加载适配：配置侧必须 `:demand t`，不写 `:defer t` | `startup_phases` 的包加载明细只在 mode 早于 `after-init-hook` 启用时存在；`:defer t` 会让启动分解退化为单锚点 `mode-start`（物理边界，不是采集失败）；延迟对本包也省不到什么（`el-chronos.el` 很薄，`sqlite` / `org` 本就在 mode 启动后按需加载） | 计划 D2、TD-16、`docs/operations.org`「启动分解的物理边界」 |
| 2026-10-25 | 配置侧用 straight `:local-repo` recipe（与 `seshat-reader` 同款）+ `:demand t`；`:build (:not compile native-compile)` **保留 autoloads**、禁 compile / native-compile | 本地开发仓与远端是同一份代码：`:local-repo` 让 straight 软链开发仓源码、`:repo` / `:branch` 保留 upstream 识别，改完源码 `M-x straight-rebuild-package RET el-chronos` 即生效（不需 push/pull）；保留 autoloads 让包侧 15 条 cookie 真正生效（命令免配置可 `M-x`，实测 `autoloadp` 全 `t`），禁 compile / native-compile 保证源码改动即时可见；`:files` 显式 `(:exclude "el-chronos-autoloads.el")` 以免 `make autoloads` 生成物被软链进 build 目录后穿透写回源仓库（实测源仓库 sha256 不变）。代价：`straight-pull-package` / `straight-checkout-package` 直接作用在开发仓上，新增 / 改名 interactive 命令后须 rebuild 才有新 autoload | 计划 D3、实测 P1/P2/P6、`docs/operations.org`「方式 A」、`Readme.org`「安装」 |
| 2026-10-25 | 入口命令在 `:init` 内**逐条显式 `autoload`**（库名 = 定义文件名），**不用** use-package 的 `:autoload` / `:commands`；计划 D4 的「语法不成立」分支因此落地为退化形态 | 实测 `:autoload` / `:commands` 生成的 autoload **库名恒为包名** `el-chronos`（`:autoload` 复用 `:commands` 的 normalizer，只吃符号，没有 per-symbol 文件名语法），而 report / web 命令不在 `el-chronos.el` 里 → 首次调用报 `Autoloading file ... failed to define function`。故**实测 `:autoload`/`:commands` 不支持跨文件入口，采用 `:init` 显式 autoload**；退化形态与迁移前手写 autoload 语义等价，无功能损失 | 计划 D4、实测 P3/P4、`docs/api.org`「为什么 autoload 库名必须是定义文件」 |
| 2026-10-25 | hook 挂 `(lambda () (el-chronos-mode 1))`，**不用** `#'el-chronos-mode` | `add-hook` 投递符号后是**无参调用**，而 `el-chronos-mode` 的无参形态是 **toggle**：重复求值（重载配置、多个 hook 位）会把观测关掉 | 计划 D5、实测 P5、`docs/operations.org`「`:hook` 无参 toggle 陷阱」 |
| 2026-10-25 | autoload 契约作为**编码约定 + ERT 守门**，不新增不变量编号 | 保持 I1–I11 稳定（AGENTS.md 约定「编号不重排」）；可机械检查的约束用计数不变量守门（`(interactive` 出现次数 = cookie 数 = 命令清单长度），比人工名单可靠 | 计划 D6、`AGENTS.md`「编码约定」、`test/el-chronos-autoload-test.el` |
| 2026-10-25 | autoload 契约覆盖**全部 15 个** interactive 命令，不按「是否推荐手动调用」筛选 | 机械规则可检、无人工名单争议；`collect-start` / `collect-stop` / `store-flush` 虽不推荐手动调用（由 `el-chronos-mode` 与 5s flush timer 编排），autoload 化不改变行为语义，只让「未加载时 `M-x` 可调用」成立 | 计划 D7、`docs/api.org`「15 个 interactive 命令与定义文件」 |
| 2026-10-25 | 用户要求本地开发仓与远端同源，接线改用 straight `:local-repo` 而非 `:load-path` | 用户显式要求（D3 修订触发点）：开发仓 `git@github.com:awerdx520/el-chronos.git`（`master`）与本地工作树是同一份代码，用 `:local-repo` 让 straight 统一管理 build 目录与 autoloads；`:load-path` 形态下包落在 straight 视野之外（无包记录、无 autoloads 生成、须逐条手写 autoload、且 `:load-path` 有「相对路径宏展开期固化 / sexp 形态整个 form 展开为 nil」两个静默陷阱）。与 `seshat-reader` 形态一致，减少一套心智模型 | 计划 D8（D3 修订 v3）、实测 P1/P2/P6、`thomas-emacs/lisp/init-chronos.el` |
| 2026-10-26 | 启动探针剥离为独立零依赖文件并在 `early-init.el` 接入（`el-chronos-startup-probe.el` + collect 主动 take）；资源观测新增 `hourly_resources`（schema v4） | TD-16 的「不修」在该配置下使启动分解形同虚设（实测 20/20 会话只有 `mode-start`，`load:*` 明细 0 条）；资源维度（CPU / RSS / 线程 / 负载）可零依赖补齐：`process-attributes` + `load-average`，不新增 timer、不调 `garbage-collect` / `memory-info`。详见 ADR-0006 | ADR-0006、TD-16、TD-15、I5 / I6 / I10 |
| 2026-10-26 | 新增 `el-chronos-analysis-inclusive-functions`（**栈包含法归因**）：按 `hourly_stacks.stack_json` 统计「谁在调用链上出现过」；候选集取窗口内 `hourly_functions` 的**全量** `function` 集、**不按 `samples > 0` 过滤**；按 JSON 双引号**整名相等**匹配（非子串）；每栈先 `delete-dups` 再累加（同栈同名帧只算一次） | self 口径严重低估「驱动大量下游但自己不吃 CPU」的函数——实测同一次排查里该函数 **self 6.7% vs 栈包含 20.2%**（差 3 倍）。三条约束各有实据：① 只作为中间帧出现的函数 `samples` 恒为 0，而它们正是包含法的首要目标，加 `samples > 0` 会把目标整体排除（首轮审查的 blocking 项）；② 子串匹配会让 `foo` 误命中 `foo-bar`（`eca-chat--viewing-bottom-p` vs `...-pos`）；③ 不去重会让递归 / advice 链把 `:pct` 推到 100% 以上（实测 `apply` 虚高 128,530 vs 真值 109,982）。性能走「一次取栈 + Lisp 单遍扫描」（29 ms 字节编译）而非 SQL `instr` JOIN（24,500 ms）。报告层以「热点函数」节内的 `** 栈包含占比 TOP` 子小节呈现，**刻意不增节**（self 榜与包含榜的差异本身就是结论） | `openspec/completed/2026-10-26-compact-observability.md` T2 / T3、TD-10、`CHANGELOG.md`「新增」「修复」 |
| 2026-10-26 | 栈包含归因（`el-chronos-analysis-inclusive-functions`）只接入 org 报告的「热点函数」节内 `** 栈包含占比 TOP` 子小节，Web 侧不新增路由与面板 | ① 栈包含的价值依赖与 self 榜**并排阅读**（两者的差异本身就是结论），Web 现有布局做不到并排；② Web 已有 19 条路由，栈包含属「按需深查」的分析型数据，不是常看面板；③ 数据仍可由 `/api/top-functions` 导出后本地 SQL 得到，能力不丢。**推翻条件**：若 Web 侧解决「self 榜与包含榜并排」的布局问题，可重新评估 | `openspec/completed/2026-10-26-compact-observability.md` 待办 6 |
| 2026-10-26 | 所有计划、CHANGELOG、验收报告在声称「验证通过」时必须**分别写明** `make full-check`（= check-parens + test）与 `make lint`（字节编译告警），不得合并叙述 | `Makefile:53` 的 `full-check: check-parens test` **不含** lint；历史上的「full-check 全绿、lint 零告警」并列表述会让读者以为前者覆盖后者 | TD-30、`Makefile` |
| 2026-10-26 | GC 归因只接入 org 报告，不接入 Web | 与栈包含归因同理：该数据需与 `hourly_gc` 总量（GC 总量 / 堆大小）**对照阅读**才有意义，Web 现有布局做不到并排；且它属「按需深查」的分析型数据，不是常看面板。推翻条件：Web 侧支持对照布局后可重评。 | `hourly_gc_attrib` / `el-chronos-analysis-gc-attribution` / report 第 16 节 |
| 2026-10-26 | `el-chronos-store--migrate` 对「已是最新版本」加**版本相等早退守卫**：`from-version >= --schema-version` 时直接返回 `t`，不 checkpoint、不生成 `.bak`、不开事务 | 把「不动已是最新的库」编码为**函数自身的不变量**，不依赖调用方 `--open-db` 先短路。误调用会白跑 `PRAGMA wal_checkpoint(TRUNCATE)` 并 `copy-file` 生成一份与库同大的 `.bak`（真实库约 10 MB）——既是 IO 代价，也是隐私代价（多一份数据副本，且失败回滚路径会把它当成「迁移前状态」）。守门用例 `el-chronos-store-test-migrate-noop-when-already-current` 锁住「返回 t / 无 `.bak` / 无 checkpoint / 无 `BEGIN` / 版本与行数均不变」 | `el-chronos-store.el`、`test/el-chronos-store-test.el`、`openspec/completed/gc-attribution.md` |

## 决策模板

新增决策时按下列格式追加一行，并在 `docs/adr/` 补一份完整 ADR（编号连续，四位数字）：

| 日期 | 决策 | 理由 | 关联 |
|---|---|---|---|
| YYYY-MM-DD | 做什么（一句话，可执行） | 为什么（含被否决方案的原因） | ADR-NNNN / 不变量 / 文件 |
