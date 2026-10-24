# ADR-0001：观测器架构（双源采集 + SQLite 小时聚合 + 函数级定位 + 命令级隐私）

- **状态**：Accepted
- **日期**：2026-10-24
- **决策者**：用户（方案确认）
- **关联**：`openspec/completed/el-chronos-core.md` 不变量 I1–I11；`openspec/decisions.md` 四条决策；`docs/schema.org`

## 背景

Emacs 配置（thomas-emacs）长期存在"偶尔卡一下但定位不到原因"的问题。现有手段各有硬伤：

- `profiler-start` 手动采样：只在"卡的时候"想起用，拿到的是几分钟的平均值，看不到**偶发**慢点；
- `esup` / `benchmark-init`：只测启动一次，无长期趋势；
- `elp` / advice 插桩：对目标函数逐个包，需要先知道嫌疑人，且改变调用语义（额外 frame、影响 `called-interactively-p` 与 `this-command`）；
- 肉眼 `message` 计时：不可累积、无趋势。

需求因此是"**常驻低开销**观测 + **长期可查** + **能定位到函数级**"，且不得让观测本身成为卡顿源、不得成为隐私风险源。本 ADR 合并记录四项结构性决策。

## 决策

### D1 采集采用「内置 C profiler 采样 + 命令边界计时」双源，不用 advice 全量插桩

- **源 A（采样）**：`profiler-cpu-start` 以 `el-chronos-sampling-interval-ns`（默认 10ms）常驻，每 10s 取
  `profiler-cpu-log` 聚合为 self/total 后重置。SIGPROF 由 C 层处理，**主线程被 Lisp 阻塞时仍会留存栈样本**。
- **源 B（边界计时）**：`pre-command-hook` / `post-command-hook` 记 `float-time` 差值，同时取
  `gcs-done` / `gc-elapsed` 差值；下次 `pre` 到来时上一命令仍未结算 → 记为 `aborted`（即被 `C-g` 中断）。
- 两源互补：源 A 给"热在哪个函数"，源 B 给"哪些命令慢、慢多久、是否被打断"。均不修改被观测函数的定义。

### D2 存储用内置 SQLite + 小时级聚合，不用 JSONL/CSV 累积

- 表结构见 `docs/schema.org`；`PRAGMA user_version` 做迁移，WAL + `busy_timeout`。
- 原始事件量级约 **86 万行/天**（按 10ms 采样 + 高频命令估算），因此采样结果在内存按小时聚合后
  只落 `hourly_functions` / `hourly_usage`；命令级明细只落 `commands`（每命令一行）与超阈值的 `slow_events`。
- 写库走批量缓冲 + flush timer，不逐事件提交。

### D3 定位能力到「函数 + 调用链」为止，不承诺源码行级

- ELisp profiler 记录的是符号栈，**没有行号**；强行做行级需要重写字节码或全量插桩，代价与侵入性都不可接受。
- 对外能力的上限：热点函数 → 文件 → 包/模块归属；慢事件 → 当时的符号栈（`slow_events.stack_json`）。
- 真需要行级时，走 `el-chronos-profile-command` 对**单条可疑命令**做 1ms 高精度采样 + 微基准 + 二分注释法，
  属于"人工下钻"而非"常驻能力"。

### D4 默认隐私边界为命令级，不记文件路径/按键序列/内容；project 只存 basename

- 默认记录：命令名、耗时、GC 耗时、major-mode、project **basename**、结果、函数符号名、
  函数定义源码路径（后者仅为包/模块归因所需）。
- **不记录**：被操作文件路径、按键序列、buffer 内容、命令参数、剪贴板、环境变量。
- **`commands.project` 存 basename，不存绝对路径**：取值为
  `(file-name-nondirectory (directory-file-name (project-root ...)))`，取不到时为 NULL。
  这样即使数据库泄漏，也无法还原「哪些文件/哪些目录被编辑过」，只剩「哪个项目名忙」。
- 需要文件级粒度时，用户显式把 `el-chronos-usage-granularity` 改为 `'file`——主动选择，非默认。
- 数据库落在 `<user-emacs-directory>/.local/state/chronos/`（版本控制与常见备份系统的状态目录）。
- **loopback 不是访问控制**：Web server 只绑 `127.0.0.1` 仅用于阻断 LAN 暴露；它**没有鉴权**，
  而 WSL2 mirrored 网络共享端口空间，Windows 侧进程可直接访问该端口。因此 Web 形态的定位是
  「本机自用只读视图」，不得据此认为数据已受访问控制保护（对应 I8）。

## 后果

**正面**

- 常驻开销可控：两次 `float-time` + 内置 C profiler，无 per-function 包装；
- 能解释"卡顿"而不只是"慢命令"：源 A 的栈样本覆盖主线程停转期间（对应 I2）；
- 长期趋势可查：小时聚合 + 索引，30 天保留期内聚合查询在毫秒级；
- 隐私默认安全：不留文件路径与按键，即使数据库泄漏也只是一堆命令名与耗时。

**负面 / 代价**

- 采样是概率性的：短于 10ms 的函数可能采不到，`self_ms` 有统计噪声，需靠多窗口累积；
- 归因依赖 `symbol-file`，native-comp 下可能命中 `.eln`（**TD-1 已关闭**：`.eln` 路径可从文件名反查库名与源码，实测 844 个真实 `.eln` 中 96.6% 反查成功、仅 1.1% 归 `unknown`）；
- 无命令上下文的阻塞（timer / 进程过滤器 / redisplay）只能靠心跳识别"停转了"，栈归因质量待实测（**TD-2 已实测**：≥2s 停转 5/5 捕获，记录值恒高估 ≤1 心跳间隔；残余缺口转 TD-11）；
- 常驻采样本身的 CPU 占比需实测，超 0.5% 须退到 20/50ms（**TD-3 已实测关闭**：10ms 默认开销在噪声地板下不可分辨，上限约 0.2%，保持 10ms）；
- 行级需求无法由常驻能力满足，只能人工下钻。

**约束（进入不变量）**

I1（只用内置 profiler）、I2（阻塞期不依赖 Lisp 回调）、I3（只写 db-path）、I4（毫秒/纳秒单位）、
I5（停用零残留）、I6（归因失败降级不抛错）、I7（默认命令级隐私，project 只存 basename）、
I8（Web 只绑 loopback、无鉴权、只读）。

## 替代方案与被否决原因

| 替代方案 | 描述 | 否决原因 |
|---|---|---|
| 全量 advice 插桩 | 对每个可疑函数 `advice-add` 计时 | 需要先知道嫌疑人；改变调用语义（额外栈帧、影响 `called-interactively-p`）；函数数量大时开销不可控；与 I1 冲突 |
| 仅手动 `profiler-start` | 卡的时候手动采样 | 抓不到偶发慢点；无历史、无趋势；依赖人记得采 |
| 仅命令边界计时（无采样） | 只记命令耗时 | 能说"哪个命令慢"，说不出"慢在哪个函数"，无法回答第 2 问 |
| JSONL / CSV 追加文件 | 逐事件写文本，事后用 awk/jq 分析 | 86 万行/天，无索引无聚合，查询随时间线性退化；文件膨胀且需自造索引层 |
| 外部性能工具（perf / 系统级采样） | 在 OS 层采样 Emacs 进程 | 只到 C 层符号，无 ELisp 符号栈，无法归因到包/模块；且需 root |
| 行级采样（改字节码/全量插桩） | 记录源码行号 | 实现代价与侵入性极高，收益边际（函数级已能定位到嫌疑人）；与 I1 冲突 |
| 记录文件路径与按键序列 | 更细的使用统计 | 观测器不得成为隐私风险源；按键序列可还原输入内容（对应 I7） |
| 跨机器汇聚/上报 | 多机数据统一分析 | 引入网络与同步复杂度，与"本机低开销观测"定位不符；非目标 |

## 关联

- 计划：`openspec/completed/el-chronos-core.md`（分层、数据模型、采集策略、隐私边界、数据生命周期、错误处理矩阵、回归判定、I1–I11、T1–T12）
- 决策表：`openspec/decisions.md`（本 ADR 的四条对应行）
- 数据模型：`docs/schema.org`
- 时序与数据流：`docs/architecture.org`
- 技术债：`openspec/tech-debt.md`（TD-1 native-comp 归因、TD-2 阻塞捕获覆盖率、TD-3 采样开销——均已关闭；TD-4 CI 空跑、TD-5 ETAF 重绘性能、TD-6 Web 无鉴权边界、TD-7 P95 近似精度、TD-11 阻塞捕获残余缺口）
