# 技术债

记录已知但当前不解决的技术风险与待实测项。计划阶段识别、实现阶段认领、验证阶段关闭。

| 编号 | 描述 | 影响 | 计划 |
|---|---|---|---|
| TD-1 | `symbol-file` 在 native-comp 下可能返回 `.eln`，归因兜底方案（`comp-el-to-eln-filename` 反查）未实测 | 归因可能指向编译产物而非源码，包/模块归属错判为 `unknown` | T3 实现时用 native-comp 环境的真实 `.eln` 路径实测反查链路；兜底失败仍降级 `unknown`（I6） |
| TD-2 | 非命令型阻塞（timer / 进程过滤器 / redisplay）的捕获覆盖率未实测 | 心跳检测只能发现「主线程停转」，长耗时的 timer 回调与进程过滤器可能被误记为普通阻塞且无命令上下文 | **部分缓解（2026-10-24）**：命令内阻塞由 `post-command-hook` 结算覆盖（duration 含卡顿，作为慢命令落 `slow_events`）；非命令型（命令之外的主线程停转）由 1s 心跳覆盖。覆盖率仍待实测（原计划：注入式 sleep 型 timer + 慢 filter 量化召回率并记录到 `docs/architecture.org`） |
| TD-3 | 10ms 采样开销未实测，超 0.5% CPU 需退到 20/50ms | 常驻采样本身可能成为开销源，违背「低开销观测器」定位 | T5 完成后用内置 profiler 自身对比测 `profiler-cpu-start` 常驻的 CPU 占比；超阈值把 `el-chronos-sampling-interval-ns` 默认值退到 20ms 或 50ms 并在 CHANGELOG 标注 |
| TD-4 | Makefile 在无 `.el` 仓库初期的目标空跑行为未在 CI 验证 | 空跑分支只在本地手工验证过；CI 环境差异（`find` 行为、`make` 版本）可能导致误失败 | T1 已本地验证；Phase 3 接入 CI 时补一条「空仓库 `make full-check` 通过」的门禁用例 |
| TD-5 | ETAF 页面在大量行 / 多图表重绘下的性能未实测（`etaf-ui-table` 分页 20 行 + 3 张 SVG 图） | 数据量大时页面可能卡顿，反而成为「观测器自己慢」的新问题 | T8 完成后用 30 天真实数据实测首次渲染与切范围重绘耗时；超 1s 则下调每页行数与图表采样点上限（默认 60 点），必要时改为按需渲染 |
| TD-6 | Web 无鉴权，且 loopback 不构成本机访问控制（WSL2 mirrored 下 Windows 侧进程可达） | 本机其他进程或多用户环境可读取全部采集数据 | 已在 I8 / 隐私边界显式声明为「本机自用只读视图」；Phase 3 评估加最小 token 校验，或仅在显式 `el-chronos-web-start` 期间监听 |
| TD-7 | P95 用 `ORDER BY duration_ms DESC LIMIT/OFFSET` 近似的精度未评估 | 长尾分布下分页近似可能明显偏离真实百分位，误导优化优先级 | T6/T7 完成后用 fixture 数据对比「排序取位」与「分桶直方图」两种算法误差；偏差 >5% 改用直方图表 |
| TD-8 | 命令 error 检测依赖 `command-error-default-function` 的 advice：Emacs 30+ 默认 `command-error-function` 是 `help-command-error-confusable-suggestions`（内部仍调默认实现，实测 2026-10-24 Emacs 31.1 可用）；若用户把它换成**不委托**给默认实现的函数，则 error 无法识别 | 该用户的错误类命令会被记为 `ok`（若未走 `post-command-hook` 则记 `aborted`），`outcome='error'` 统计偏低 | T5 已用 advice 方案落地并在可用路径实测；后续评估补兜底（如检测到自定义 `command-error-function` 时告警） |
| TD-9 | Emacs 31 起 `pre-command-hook` / `post-command-hook` 是 auto-buffer-local（`local-variable-if-set-p` 为 t）：`add-hook` 无 LOCAL 时只改**默认值**，已有局部绑定的 buffer（实测 `*scratch*` 被 eldoc 留了局部值）会遮蔽全局值 | 那些 buffer 里的命令不会被计时（漏采），数据完整性下降 | **已修复（2026-10-24）**：改为「全局默认值 + 每个 buffer 局部补挂」双路——`el-chronos-collect-start` 仍装全局 `add-hook`，新增 `el-chronos-collect--ensure-buffer-hooks` 遍历 `buffer-list` 逐个补挂局部值并登记到 `el-chronos-collect--hooked-buffers`（weak key），`buffer-list-update-hook` 负责新 buffer 增量补挂；`el-chronos-collect-stop` 先摘 `buffer-list-update-hook`，再由 `el-chronos-collect--clean-buffer-hooks` 用 `remove-hook ... LOCAL=t` 摘局部值、对「摘后已回落到默认值」的局部绑定再 `kill-local-variable`（不把遮蔽坑留给用户）、最后 `clrhash` 登记表。验收：被遮蔽 buffer 内命令计时恢复（`emacs -Q --batch` 端到端捕获到 `move-end-of-line` 事件）、连续 3 轮 start/stop 无重复挂、stop 后局部值与登记表零残留 |
| TD-10 | `total_ms` 与内置 `profiler-report` 的 total 列口径不完全相等：本模块按**栈内去重**累加（同一函数在一条栈里出现多次只算一次），内置报告按每帧累加 | 同一份采样数据在两处读数不同，跨工具对比时易被误判为数据错乱或 bug | **文档已注明（2026-10-24）**：`el-chronos-collect.el` 文件头 2b 与计划「注意事项」均写明 samples 为 self 口径（leaf 采样次数）、`total_ms` 为出现时间（栈内去重）；不打算对齐——去重口径才符合「经过该函数的样本数」语义，且避免深递归函数的 total 被重复帧放大 |

## 使用约定

- 新发现风险追加 TD-N（编号连续），不删除历史条目——关闭时在「计划」列末标注 `已关闭（YYYY-MM-DD）`。
- 影响面涉及不变量（I1–I11）的条目须同时在 `openspec/decisions.md` 留决策记录。
