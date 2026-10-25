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

## 决策模板

新增决策时按下列格式追加一行，并在 `docs/adr/` 补一份完整 ADR（编号连续，四位数字）：

| 日期 | 决策 | 理由 | 关联 |
|---|---|---|---|
| YYYY-MM-DD | 做什么（一句话，可执行） | 为什么（含被否决方案的原因） | ADR-NNNN / 不变量 / 文件 |
