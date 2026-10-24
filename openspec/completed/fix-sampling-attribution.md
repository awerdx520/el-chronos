# 修复采样归因：nil 帧污染热点表与 C 原语归因

## 当前状态
- 阶段：Phase 4（Review & Document）已完成，计划已归档
- 已确认：方案 ✅（用户 2026-10-25 确认）、计划 ✅（用户 2026-10-25 确认）、独立审查 ✅（plan-reviewer 通过，7 条 minor 全部采纳）
- 结果：nil 帧不再计入 self/total、栈尾 nil 裁剪、全 nil 栈不写；C 原语与 profiler 伪符号归 built-in；`make test` 120 全绿、`make lint` 零告警
- 提交：代码+测试见 `fix: 采样归因修正——nil 帧不再计入、C 原语归 built-in`

## 目标

1. **nil 采样帧不再被统计成函数**：当前 `unknown` 稳居热点表第 1（295,509 样本 / 38.8%），且其 `total_ms` 占全部样本 98.7%，任何 total 口径的占比与趋势都被它抬高。
2. **Emacs C 原语与 profiler 伪符号归为 `built-in`**：当前 431 个函数 / 282,580 样本（37.1%）的 `package` 是 `unknown`，原因是 C 原语 `symbol-file` 返回 nil。
3. **无效栈不进 `hourly_stacks`**：当前 93.7% 的栈尾部带 `"unknown"` 占位（nil 填充帧），其中一条 `["unknown"×16]` 独占 295,506 样本，污染火焰图与调用链视图。

## 设计

### 根因（本机实测证据）

| 现象 | 根因 | 证据 |
|---|---|---|
| `function='unknown'` 295,509 样本 | `(symbolp nil)` = **t**，nil 叶子被 `--accumulate-entry` 当符号累加；落库时 `--frame-name` 把 nil 归一为 `"unknown"` | 该行 `file` 列全 NULL；`(fboundp 'unknown)` = nil；`hourly_stacks` 有 `["unknown"×16]` / 295,506 样本；每小时持续新增（非历史脏数据） |
| `package='unknown'` 431 个函数 / 282,580 样本 | C 原语与特殊形式的 `symbol-file` 恒为 nil（Emacs 31.1 实测 18/18）→ `--classify-source(nil)` → `"unknown"` | `kill-buffer` / `overlay-get` / `read` / `mapc` / `plist-get` / `let` / `if` 等全部 `subrp=t`、`symbol-file=nil` |
| `redisplay_internal (C function)` 158,095 样本、`Automatic GC` 63,820 样本 | 二者是 **profiler 自造的非 fboundp 符号**（`strings /usr/bin/emacs` 可查到字面串），`subrp` 判据救不了 | `(fboundp 'redisplay_internal)` = nil；`(fboundp 'Automatic GC)` = nil |
| 93.7% 的栈尾部带 `"unknown"` | profiler 栈向量尾部是 nil 填充 | `profiler-cpu-log` 实测栈形如 `[1+ setq let while … normal-top-level nil nil nil nil]` |

### 改动点

**A. `el-chronos-collect--accumulate-entry`（两处门禁）**
- leaf：`(symbolp leaf)` → `(and leaf (symbolp leaf))` —— nil 不进 self/samples
- total：`(and (symbolp function) (not (memq function seen)))` → `(and function (symbolp function) (not ...))` —— nil 不进 total

**B. 栈序列化：新增 `el-chronos-collect--trim-trailing-nils`**
- 签名 `(ITEMS)`，输入 vector（栈），返回去掉**尾部** nil 的 vector；实现用索引回退（`aref` + `substring`），不改原 vector
- 在 `--accumulate-entry` 的栈聚合处、**归一（`--frame-name`）之前**调用
- trim 后长度为 0 → **不写入** `hourly_stacks`（全 nil 栈无信息量，只占空间）
- 保留 `--frame-name` 的 `nil → "unknown"`（中间位置若出现 nil，仍需要占位以免 JSON 出现 null）

**C. `el-chronos-attrib`：新增 `el-chronos-attrib--builtin-primitive-p`**
- 签名 `(SYMBOL)` → `"built-in"` 或 nil；在 `el-chronos-attrib-package` 的**符号分支最前面**调用（命中即返回）
- 判据（按顺序，全部包在 `ignore-errors` 内）：
  1. 非 fboundp 的 profiler 伪符号：`(and (not (fboundp SYMBOL)) (or (string-suffix-p " (C function)" NAME) (string= NAME "Automatic GC")))` —— `(not (fboundp ...))` 是**必需前提**，否则任何名字恰好以 `" (C function)"` 结尾的真实函数会被误判。
  2. `(and (fboundp SYMBOL) (let ((FN (indirect-function SYMBOL))) (and (subrp FN) (not (and (fboundp 'module-function-p) (module-function-p FN))))))` —— FN 即 `(indirect-function SYMBOL)`；`module-function-p` 需 `fboundp` 守卫（Emacs 29 以下无此函数），守卫失败时按「非模块」处理。
- **不改** `--classify-source` / `--classify-path` / `--classify-eln`（它们只处理路径，C 原语根本没有路径）

**D. 明确不做的（记录为技术债，避免口径再扩散）**
- **闭包叶子（非符号）仍被丢弃**（现状）：`--accumulate-entry` 的 leaf 门禁只认符号，非符号叶子从来不进 `hourly_functions`，但会出现在 `hourly_stacks`（作为 `"anonymous"`）。这与 nil 叶子被记成 `unknown` 的旧行为是**两处相反的不对称**；本次只消除 nil 一侧（因为它排第一且污染 total），不新增 `anonymous` 行——避免把「不可归因样本」再引一种新展示口径。
- **全 nil 栈的成因未定**：为何有些采样整条栈 16 帧全空（295,506 样本）尚未定因（batch 下无法复现）。本次只做「不计入」处置，成因登记为技术债。

### 影响与代价

- `top-functions`：`unknown` 行消失；`Automatic GC` / `redisplay_internal (C function)` / C 原语归入 `built-in` → 排行变化（GC 与 redisplay 不再伪装成 unknown 包）
- `package_breakdown`：`built-in` 占比显著上升（这是**正确**口径；此前 `format` 是唯一 built-in 项）
- `overview` 的 `:samples`：不再包含 nil 叶子 → 数值下降（更接近真实 CPU 归属样本数）
- `hourly_stacks`：不再有全 nil 栈与尾部占位；火焰图更干净
- **历史数据**：新旧口径不可混算 → 用户已确认自行 `el-chronos-purge` 清空重来（库龄仅 7 小时，成本低）

## 任务

- [x] **T1 collect 侧：nil 门禁 + 栈尾 trim**
  `el-chronos-collect.el`：① `--accumulate-entry` 的 leaf 与 total 两处门禁加 `(and X ...)`；② 新增 `el-chronos-collect--trim-trailing-nils`（vector 去尾 nil）；③ 栈聚合处归一前调用它，trim 后为空则跳过；④ 更新 `--accumulate-entry` docstring（说明 nil 帧被跳过、尾部 nil 被裁剪）。
  验收标准：`make check-parens` 通过；`make lint` 零告警；`grep -c "trim-trailing-nils" el-chronos-collect.el` ≥ 2（定义 + 使用）。
  （依赖：无）

- [x] **T2 attrib 侧：C 原语与伪符号归 built-in**
  `el-chronos-attrib.el`：新增 `el-chronos-attrib--builtin-primitive-p`，并在 `el-chronos-attrib-package` 符号分支最前调用；更新其 docstring 与文件头「归因链」说明（加一条「C 原语 / profiler 伪符号 → built-in」）。
  验收标准：`emacs -Q --batch -L . --eval` 下 `(el-chronos-attrib-package 'kill-buffer)` = `"built-in"`、`'overlay-get` = `"built-in"`、`'redisplay_internal` 的伪符号名为 `"redisplay_internal (C function)"` 时 = `"built-in"`、`"Automatic GC"` 符号 = `"built-in"`、`'format` 仍 `"built-in"`、`'car` = `"built-in"`；`make lint` 零告警。
  （依赖：无）

- [x] **T3 测试：两侧各补用例**
  - `test/el-chronos-collect-test.el`：① 插入一条 leaf 为 nil 的栈 → `--window-self` 里无 nil key、samples 不计；② 栈中含 nil 帧 → total 不计 nil；③ 栈尾 nil 被 trim（断言拼接后的 JSON 不含尾部 `"unknown"`）；④ 全 nil 栈 → 不写 `--window-stacks`
  - `test/el-chronos-attrib-test.el`：① `kill-buffer` / `overlay-get` → `built-in`；② `redisplay_internal (C function)`（用 `(intern "redisplay_internal (C function)")` 构造）→ `built-in`；③ `"Automatic GC"` 符号 → `built-in`；④ 普通无文件符号（如 `(intern "nonexistent-fn-xyz")`）→ 仍 `unknown`（不误判）；⑤ `cl-letf` 伪造 `module-function-p` 返回 t 时 → 不判 built-in（若 `module-function-p` 存在）
  验收标准：`make test` 全绿（用例数从 110 增至约 119 —— 9 个断言组；若 attrib ① 拆成两个则 120，实测为准）；`make lint` 零告警；含反向验证（把 T1 的 leaf 门禁改回 `(symbolp leaf)` → 对应用例必红 → 还原）。
  （依赖：T1、T2）

- [x] **T4 文档同步与提交**
  ⓪ `Readme.org`：两处用例数（「当前 110 用例」/「ERT 110 用例」）按实测回填到新总数；
  ① `docs/architecture.org`：采样口径 / 「已知偏差」补两条（nil 帧不计入、C 原语归 built-in；全 nil 栈成因未知）；并补一条口径说明：`hourly_stacks`（按完整栈去重）与 `hourly_functions.samples`（按 leaf 去重）本就不等，改后方向是「栈表样本 ≥ 函数表样本」（闭包叶子或 nil 叶子但中间帧有符号的栈只进栈表），属预期而非 bug；再补一句：`redisplay_internal (C function)` 归 built-in 后不再被 `regressions` 的 SQL 排除（该 SQL 仅排除 `Automatic GC`），其 self 波动超阈值会进入回归列表——这是正确行为（redisplay 确实是耗时大户），但需在文档中标明，避免被当作误报。
  ② `docs/api.org`：`el-chronos-attrib-package` 条目补「C 原语 / profiler 伪符号 → built-in」与判据顺序；
  ③ `AGENTS.md`：「已知边界」表新增一行（采样归因口径：nil 帧跳过、C 原语 built-in、闭包叶子仍丢弃的不对称）；基线数字按实测回填；
  ④ `CHANGELOG.md`：`### 修复` 段新增条目（nil 帧污染 + C 原语归因 + 栈尾 trim；含实测数字 295,509 / 282,580）；
  ⑤ `openspec/tech-debt.md`：新增 TD-13（全 nil 栈成因未知；已做「不计入」处置）+ TD-14（闭包叶子与 nil 帧的处理不对称，未统一）；
  ⑥ `docs/operations.org`：排障表可选补一条（「built-in 占比高」是正常口径，非归因失败）；
  ⑦ 全量验证 + 提交（代码/测试一个、文档一个）+ 计划归档。
  验收标准：`make test` 全绿、`make lint` 零告警；文档 grep 判据通过；提交后 `git status` 为空；`openspec/active/` 只剩 `.gitkeep`。
  （依赖：T3）

## 执行记录与偏差

| 项 | 计划 | 实际 | 原因 |
|---|---|---|---|
| 用例数 | 约 119 | **120** | cache-hit 为修改（不算新增），实际新增 10（collect 4 + attrib 6，含「短路不调 symbol-file」1 个） |
| cache-hit 用例 | 计划未含 | 已修 | 新短路让 C 原语不再调 `symbol-file`，原断言 `(= 1 calls)` 失效；被测符号改为非 subrp 的 lisp 函数 |
| 反向验证 | 只要求 collect 侧 | collect 两处门禁 + attrib 短路各做一次 | 发现 nil 门禁有两处（leaf / total），分别锁定不同用例 |
| 文档范围 | 8 处 | 9 处（补 `docs/operations.org` 的 `Ran 131 tests` 过时数字） | 该行早已过时，与基线矛盾 |
| 剩余不对称 | 计划已声明不改 | 记录为 TD-14 | 闭包叶子仍丢弃，与 nil 帧处置不一致 |

## 文档清单

| 产物 | 状态 |
|---|---|
| `el-chronos-collect.el` | 需更新（T1） |
| `el-chronos-attrib.el` | 需更新（T2） |
| `test/el-chronos-collect-test.el` / `el-chronos-attrib-test.el` | 需更新（T3） |
| `docs/architecture.org` | 采样口径与已知偏差（T4） |
| `docs/api.org` | 归因规则（T4） |
| `AGENTS.md` | 已知边界表 + 基线（T4） |
| `CHANGELOG.md` | 修复条目（T4） |
| `openspec/tech-debt.md` | 新增 TD-13 / TD-14（T4） |
| `docs/operations.org` | 排障一条（T4，可选） |
| `docs/schema.org` | 不需更新（表结构不变） |
| `docs/ui.org` | 不需更新（展示逻辑不变） |

## 验证标准

| 级别 | 方法 | 通过判据 |
|---|---|---|
| L1 | `make check-parens` + `make lint` | 全绿、零告警 |
| L2 | `make test` | 全绿（预期用例数见 T3 验收标准，实测为准），0 unexpected、0 skipped |
| L3 | ① 反向验证（leaf 门禁改回 → 用例变红 → 还原）；② **端到端 smoke**（真实 profiler 采样跑 ≥3 秒，检查落库后 `hourly_functions` 中 `function='unknown'` 为 0、`hourly_stacks` 中 `stack_json LIKE '%"unknown"]'` 为 0）—— 注意：batch 下可能本就不产生 nil 帧，故此条只作冒烟；**门禁正确性由 ① 反向验证保证**；③ `--frame-name` 对 nil 仍返回 `"unknown"`（契约未破） | ①②③ 全部满足 |

## 注意事项

1. **不要动 `--frame-name`**：它的 `nil → "unknown"` 映射被栈展示与测试依赖，只在下游过滤。
2. **trim 只去尾部 nil**，不要过滤中间 nil（中间 nil 若存在应保留为 `"unknown"` 占位，避免栈结构被压缩误导）。
3. `module-function-p` 必须 `fboundp` 守卫（Emacs 28 及更早无此函数）。
4. 「` (C function)`」后缀匹配要**带前导空格**（避免误伤名字里含 `(C function)` 的正常符号）。
5. 不改 `el-chronos-analysis.el`（`samples > 0` 过滤与 GC 归类逻辑不变；GC 伪函数仍由 `--gc-function` 常量在 SQL 层排除）。
6. 历史数据由用户自行 purge，本计划**不执行**任何 purge/写库操作。
7. `grep --include` 必须加单引号（本机 shell glob 坑）。
