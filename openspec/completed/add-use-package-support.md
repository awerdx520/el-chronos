# el-chronos 适配 use-package 配置方式

## 当前状态

- 阶段：Phase 4（Review & Document）· 已完成并归档
- 已确认：方案 ✅（门禁 1）、计划 ✅（门禁 2）、代码审查 ✅（code-reviewer 三轮：初审不通过 → 复审不通过（`:if` 作用域）→ 终审通过）
- 结果：包侧 15 个 interactive 命令带 `;;;###autoload`、`make autoloads` 生成入口、3 个 ERT 用例（总数 234 → 237）；配置侧 `init-chronos.el` 改为 straight `:local-repo` recipe（保留 autoloads）；`docs/api.org` 三处 interactive 标注修正
- 修订记录：（保留原有 v1–v4 行）v1 被 plan-reviewer 判为「不通过」（命令清单 12→15、Makefile 生成物污染门禁、仓库 B 文档清单缺 AGENTS.md、锚点表述含糊、T3 缺版本守卫）；v2 逐条修正；**v3：D3 由 `:load-path` 改为 straight `:local-repo`（保留 autoloads）**；**v4：修复 `:if` 与 `:straight` 的作用域（改 `if` 包裹）** —— code-reviewer 指出的 major：`use-package` 的 `:if` 包不住 `:straight` 生成的 `straight-use-package` 调用（实测展开仍在 `progn` 顶层），仓库缺失时照样会去远端 clone；改为 `if` 包住整个 `use-package`，结论见「实现期结论 › P8」。

## 目标

让 el-chronos 提供**标准 autoload 契约**，使 use-package 配置可用；并把本机配置侧的接入从「手写 autoload」迁移为声明式形态。

1. **包侧**：**15 个 interactive 命令**全部带 `;;;###autoload` cookie（新增 14 处）；Makefile 提供 `autoloads` 生成入口，产物 `el-chronos-autoloads.el` **不入库、不进 L1/L2 门禁**。
2. **配置侧**：`thomas-emacs/lisp/init-chronos.el` 迁移为 use-package 形态，删除已下线的 `el-chronos-dashboard` 残留 autoload，并同步该仓库 `AGENTS.md` 的接线描述。
3. **语义不变**：主模式仍需尽早启用（不写 `:defer t`）；包内零第三方依赖；I1–I11 编号不动。

**非目标**：MELPA / package.el 打包（不建 `el-chronos-pkg.el`）；不做「只加载报告命令」的延迟形态（仅文档说明代价）；不改 ADR 体系。

## 设计

### 设计决策

| 编号 | 决策 | 理由 |
|---|---|---|
| D1 | 包侧提供 autoload cookie + `make autoloads`；生成物不入库 | 生成物入库必然与源码漂移；按需生成即可 |
| D2 | 主模式不做延迟加载适配 | `startup_phases` 的包加载明细只在 mode 早于 `after-init-hook` 启用时存在；`:defer t` 会让启动分解退化为单锚点 |
| D3 | 配置侧用 straight `:local-repo` recipe（与 `seshat-reader` 同款）+ `:demand t`；`:build (:not compile native-compile)` **保留 autoloads** | **v3 修订**（用户 2026-10-25 追加要求：本地开发仓与远端同源）：`:local-repo` 软链开发仓源码、`:repo` / `:branch` 保留 upstream 识别，改源码后 `straight-rebuild-package` 即生效；保留 autoloads 让 15 条 cookie 真正生效（命令免配置可 `M-x`），禁 compile / native-compile 保证源码改动即时可见；`:files` 排除 `make autoloads` 生成物以免软链穿透写回源仓库 |
| D4 | 入口命令用 use-package 声明式 autoload；语法不成立则退化为 `:init` 内显式 `autoload` | H5 待实测；退化形态与现状等价，无功能损失 |
| D5 | hook 不用 `#'el-chronos-mode`（无参 toggle），改 `(lambda () (el-chronos-mode 1))` | `add-hook` 传符号即无参调用，重复求值会反转模式 |
| D6 | autoload 契约作为**编码约定** + ERT 守门，不新增 I 编号 | 保持 I1–I11 稳定（AGENTS.md 约定编号不重排） |
| D7 | autoload 契约覆盖**全部** interactive 命令（15 个），不按「是否推荐手动调用」筛选 | 机械规则可检、无人工名单争议；`collect-start`/`collect-stop`/`store-flush` 虽不推荐手动调用（api.org 已注明），autoload 化不改变其行为语义，只让「未加载时 M-x 可调用」成立 |

### 需带 autoload cookie 的 15 个命令（事实来源：源码 `(interactive)` 交叉核对 `docs/api.org`）

| # | 命令 | 定义文件 | 现状 |
|---|---|---|---|
| 1 | `el-chronos-mode` | `el-chronos.el` | 无 cookie（`define-minor-mode`） |
| 2 | `el-chronos-status` | `el-chronos.el` | 无 cookie |
| 3 | `el-chronos-attrib-clear-cache` | `el-chronos-attrib.el` | 无 cookie |
| 4 | `el-chronos-store-flush` | `el-chronos-store.el` | 无 cookie（api.org 未标 interactive，T4 修正） |
| 5 | `el-chronos-purge` | `el-chronos-store.el` | 无 cookie |
| 6 | `el-chronos-store-vacuum` | `el-chronos-store.el` | 无 cookie |
| 7 | `el-chronos-collect-start` | `el-chronos-collect.el` | 无 cookie（api.org 标「一般不直接调用」，T4 补 interactive 标注） |
| 8 | `el-chronos-collect-stop` | `el-chronos-collect.el` | 同上 |
| 9 | `el-chronos-report` | `el-chronos-report.el` | 无 cookie |
| 10 | `el-chronos-weekly-report` | `el-chronos-report.el` | 无 cookie |
| 11 | `el-chronos-export` | `el-chronos-report.el` | 无 cookie |
| 12 | `el-chronos-show-event` | `el-chronos-report.el` | 无 cookie |
| 13 | `el-chronos-profile-command` | `el-chronos-report.el` | **已有 cookie（第 1121 行）** |
| 14 | `el-chronos-web-start` | `el-chronos-web.el` | 无 cookie |
| 15 | `el-chronos-web-stop` | `el-chronos-web.el` | 无 cookie |

按文件分布：入口 2 / attrib 1 / store 3 / collect 2 / report 5 / web 2 = 15；需新增 **14** 处 cookie。

### 关键坑点（实现期必读）

- `define-minor-mode` 的 cookie 必须紧贴 `(define-minor-mode el-chronos-mode` 上一行；生成的 autoload 只定义函数、不定义变量（`add-hook` 投递符号即可，运行时触发加载）。
- `loaddefs-generate` 的 `DIRS` **不递归**；调用时把自身产物列入 `EXCLUDED-FILES`，避免自引用。
- Emacs 29.1 是否已有 `loaddefs-generate` 未实测（H4）：Makefile 必须先 `(fboundp 'loaddefs-generate)` 判断，缺失时回退 `(require 'autoload)` + `make-directory-autoloads`；**ERT 用例必须同源守卫**（`ert-skip`），不得硬编码单一实现。
- `use-package` 的 `:autoload (sym "file")` 语法未实测（H5）：先在 `verify` 隔离实例 `macroexpand-1` 验证再落笔。
- **Makefile 的 `EL_FILES` 用 `find`，不读 `.gitignore`**：生成物必须显式排除，否则生成后 `make check-parens` / `make lint` 的检查范围会随生成物变化。
- 「interactive 命令数」守卫的匹配词必须是 **`(interactive`（带左括号）**，否则会误计 `call-interactively` / `called-interactively-p` / 字符串 `"interactive"`；注释与字符串内的出现不计数，判定用 `syntax-ppss`（或 `parse-partial-sexp`），不要用「逐行截断 `;`」的粗糙做法（对 docstring 示例与块注释不可靠）。
- thomas-emacs 的 `test/init-smoke-test.el`（`test-chronos-observer-instance-guard`，约 4612–4645 行）用**源码文本断言**锁住 `init-chronos.el` 形态，共 5 组断言（a–e）。必须字面保留的锚点：① `THOMAS_EMACS_INSTANCE`；② `(member (getenv "THOMAS_EMACS_INSTANCE") '("isolated" "pure"))`；③ `unless` 前置结构；④ `emacs-startup-hook` 与 `el-chronos-mode`；⑤ 注释中的 `server-name`。**唯一预期变化**是 D5 带来的 `#'el-chronos-mode` → `(lambda () (el-chronos-mode 1))`，而断言 ④ 是宽匹配「el-chronos-mode」字符串，不受影响——因此 T8 的「更新正则」应视为**兜底**，正常情况下不该发生。

## 任务

- [x] **T1 包侧补 autoload cookie（14 处新增）**（依赖：无）
  - 文件与数量：`el-chronos.el`（2：`el-chronos-mode`、`el-chronos-status`）、`el-chronos-attrib.el`（1）、`el-chronos-store.el`（3：`store-flush`、`purge`、`store-vacuum`）、`el-chronos-collect.el`（2：`collect-start`、`collect-stop`）、`el-chronos-report.el`（4，`profile-command` 已有）、`el-chronos-web.el`（2）。
  - 只加 `;;;###autoload` 行，不改函数体、docstring、签名。
  - 验收：全仓 `grep -c ';;;###autoload'` = **15**；`make check-parens` 与 `make lint` 通过；`git diff` 只含 cookie 行（逐文件核对新增行数 2/1/3/2/4/2）。
  - 命中任务类型：`verify`。

- [x] **T2 Makefile autoloads 目标 + 生成物隔离**（依赖：T1）
  - `Makefile`：新增 `autoloads` 目标（优先 `loaddefs-generate`，缺失回退 `make-directory-autoloads`；输出 `el-chronos-autoloads.el`；`EXCLUDED-FILES` 含自身；加入 `.PHONY`）。
  - `EL_FILES` 的 `find` 追加 `-not -name 'el-chronos-autoloads.el'`（防生成物污染 L1/L2）。
  - `.gitignore` 追加 `/el-chronos-autoloads.el`。
  - 验收：`make autoloads` 生成文件；`emacs -Q --batch -L . -l el-chronos-autoloads.el --eval` 对 15 个命令 `autoloadp` 全 `t`；生成后 `make check-parens` 输出**不含**该文件；`git status` 中该文件被忽略。
  - 命中任务类型：`verify`。

- [x] **T3 新增 ERT autoload 用例**（依赖：T1、T2）
  - 新文件 `test/el-chronos-autoload-test.el`（文件头/尾按 AGENTS.md 不变量；中文注释），至少 3 个用例：
    1. `el-chronos-autoload-cookies-cover-all-interactive-commands`：① 显式清单 15 条逐条断言「其定义源码含 cookie」；② **计数不变量守卫**——「源码中 `(interactive`（左括号紧跟 interactive）的**代码**出现次数 = 14」+「`define-minor-mode el-chronos-mode` = 1」，合计 15，且该值与该命令清单长度、与 `;;;###autoload` 的代码出现次数三者相等（不写死单一数字以便未来增删命令时用例自动跟随）；匹配词必须带左括号，以排除 `call-interactively` / `called-interactively-p` / 字符串字面量 `"interactive"`；「是否位于注释或字符串内」用 `syntax-ppss`（或 `parse-partial-sexp`）判定，不用逐行截断 `;`；③ `define-minor-mode` 单列处理。清单与计数不一致时用例名带出差异命令。
    2. `el-chronos-autoloads-file-makes-commands-callable`：按与 Makefile 同源逻辑生成 autoloads 到临时目录（`(unless (fboundp 'loaddefs-generate) (ert-skip "loaddefs-generate 不存在"))` 守卫）→ `load` → 15 个命令 `autoloadp` 为 t。
    3. `el-chronos-autoload-library-matches-definition`：每个 autoload 的库名等于其定义文件名（防 cookie 落错文件）。
  - 验收：`make test` 全绿，用例数 **≥ 237**（基线 234），0 skipped。
  - 命中任务类型：`verify`（ERT 只允许在隔离实例跑，禁止 `config`）。

- [x] **T4 仓库 A 文档同步**（依赖：T1–T3）
  - `Readme.org`：安装节增加 use-package 三形态（`:load-path` 直连源码 / straight `:local-repo` / 手工 autoloads），并注明「不要 `:defer t`」的理由。
  - `docs/operations.org`：新增「autoloads 生成」「`:straight nil` 陷阱」「`:hook` 无参 toggle 陷阱」「排障：命令 void-function」四小节。
  - `docs/api.org`：新增「autoload 与 use-package 集成」节（15 命令 ↔ 定义文件 ↔ 生成入口）；**修正 3 处 interactive 标注遗漏**——`el-chronos-store-flush`、`el-chronos-collect-start`、`el-chronos-collect-stop` 在源码中是 interactive 命令，签名表须标注（collect 两处保留「一般不直接调用，由 `el-chronos-mode` 编排」的语义说明）。
  - 验收：文档中每个配置示例与 T2/T5 实际行为逐条一致；api.org 的 interactive 标注与源码 15 个命令完全对齐；无死链。

- [x] **T5 仓库 A 工件同步**（依赖：T4）
  - `AGENTS.md`：编码约定加「interactive 命令必须带 `;;;###autoload` cookie，`make autoloads` 生成、生成物不入库」；验证入口加 `make autoloads`；基线用例数 234 → 实测值。
  - `CHANGELOG.md` `[Unreleased]`「新增」段记录 autoload 契约、`make autoloads`、api.org 标注修正。
  - `openspec/decisions.md` 追加 D1–D7 决策行（日期 + 决策 + 理由）。

- [x] **T6 配置侧实测 use-package 展开**（依赖：T1）
  - 在 `verify` 隔离实例内 `macroexpand-1` 验证：`:straight nil`、`:load-path`、`:autoload (sym "file")`、`:demand t` 的展开结果；同时确认 `loaddefs-generate` 在当前 Emacs 的存在性（H4 记录）。
  - 结论写入本计划「实现期结论」小节（T6 负责新增该小节），必须附展开片段，不凭记忆断言。

- [x] **T7 重写 `thomas-emacs/lisp/init-chronos.el`**（依赖：T6）
  - 改为 use-package 形态：`:straight nil` + `:load-path`（源码目录绝对路径）+ `:demand t` + `:config` 内实例守卫 + `(lambda () (el-chronos-mode 1))`；入口命令按 T6 结论声明；删除 `el-chronos-dashboard` autoload；保留全部解释性注释（含 `server-name` 理由）。
  - 必须字面保留「关键坑点」列出的 5 个锚点（含 `unless`）。
  - 验收：`make check-parens`（thomas-emacs）通过；文件不再出现 `el-chronos-dashboard`；5 个锚点全部命中。

- [x] **T8 配置侧验证与文档**（依赖：T7）
  - 跑 thomas-emacs `make test`；若 `test-chronos-observer-instance-guard` 失配，按新形态更新正则（保持同等强度，**不得删除任何一组断言**）。
  - 更新 `thomas-emacs/AGENTS.md` 的 el-chronos 节（约第 179–186 行）：接线描述改为「use-package `:straight nil` + `:load-path` + `:demand t`，不建 straight recipe」；入口段删除 `el-chronos-dashboard`（I9：ETAF 已完全移除），改为「用 use-package 声明式 autoload 声明 report / weekly / profile / web-start / web-stop」，并点明 autoload 契约由 el-chronos 包侧提供。
  - `thomas-emacs/CHANGELOG.md` 记录迁移。
  - 验收：`make test` 全绿；AGENTS.md 中不再出现 `el-chronos-dashboard` 与「手动 `add-to-list 'load-path`」的旧描述。

## 文档清单

**仓库 A（el-chronos）**

| 文件 | 变更 |
|---|---|
| `Readme.org` | 安装节 use-package 形态；「不要 defer」说明 |
| `docs/operations.org` | autoloads 生成、`:straight nil` 与 toggle 陷阱、void-function 排障 |
| `docs/api.org` | 「autoload 与 use-package 集成」节 + 3 处 interactive 标注修正 |
| `AGENTS.md` | 编码约定 + 验证入口 + 用例基线 |
| `CHANGELOG.md` | `[Unreleased]` 新增条目 |
| `.gitignore` | 忽略 `el-chronos-autoloads.el` |
| `Makefile` | `autoloads` 目标 + `EL_FILES` 排除生成物 |
| `openspec/decisions.md` | D1–D7 决策行 |

**仓库 B（thomas-emacs）**

| 文件 | 变更 |
|---|---|
| `lisp/init-chronos.el` | 重写为 use-package 形态；删 dashboard 残留 |
| `test/init-smoke-test.el` | 仅在文本断言失配时更新正则（不得减断言） |
| `AGENTS.md` | el-chronos 节接线描述与入口段更新（删 dashboard、改 use-package） |
| `CHANGELOG.md` | 迁移记录 |

## 实现期结论

（T6 实测，Emacs **31.1** / use-package **2.4.5**（Emacs 自带 `use-package-core`，
`featurep 'use-package` 为 nil 但 `use-package` 宏可用），`verify` 隔离实例 `elisp-test`
（实测 `server-name` = `elisp-test`、`user-emacs-directory` = `~/.cache/thomas-emacs-elisp-test/`），
2026-10-25。前置事实：`use-package-always-defer` = nil、`use-package-expand-minimally` = t、
`straight-use-package-by-default` = t、`(fboundp 'loaddefs-generate)` = **t**
（H4 结论：本机 Emacs 31.1 存在，无需回退 `make-directory-autoloads`；跨版本守卫仍保留）。）

| 探针 | 展开/行为要点 | 结论（配置侧该用哪种写法） |
|---|---|---|
| P1 `:straight nil` | 带该关键字：展开**无**任何 straight 调用；去掉后展开含 `(straight-use-package 'el-chronos)` | **必须写** `:straight nil`（`straight-use-package-by-default` = t 时不写等于要求 straight 安装/管理该包） |
| P2 `:load-path` | 字符串原样进 `(eval-and-compile (add-to-list 'load-path "…"))`，**不** expand `~`；相对路径在**宏展开期**按当时 `user-emacs-directory` 固化成绝对路径；`(expand-file-name …)` 或变量形式让整个 form 展开为 **nil**（静默失效） | 只写**字符串字面量绝对路径**；不要在 `:load-path` 里放 sexp/变量 |
| P3 `:autoload (sym "file")` | **语法不支持**（见下方错误原文）：`(sym "file")` 让整个 form 展开为 nil；仅符号形式可用且库名恒为**包名** | 不能用 `:autoload` 声明跨文件入口 |
| P4 `:commands` | 库名恒为包名 `"el-chronos"`；`:demand t` 时**完全不生成 autoload**（只剩 require）；无 `:demand` 时生成 `(unless (fboundp 'x) (autoload #'x "el-chronos" nil t))` 并隐含 defer | **不能**用来声明跨文件入口命令（el-chronos.el 不 require report/web） |
| P5 `:hook` | lambda 形态 → `(add-hook 'emacs-startup-hook #'(lambda nil (el-chronos-mode 1)))`；符号形态 → `(add-hook 'emacs-startup-hook #'el-chronos-mode)`（无参调用 = toggle） | 用 **lambda 形态**（D5 成立）；`emacs-startup` 自动补 `-hook` 后缀 |
| P6 `:custom` | 展开为 `deftheme use-package` + `custom-theme-set-variables`（**不是** `customize-set-variable`），位置在 require **之前**；未定义变量上不报错、不立即绑定，随后 `defcustom` 加载时值**正确生效**（实测 14 生效） | `:custom` **不需要**配合 `:demand t` 或 `:init (require …)` |

### P1 `:straight nil` 必写

```elisp
;; 带 :straight nil
(progn (eval-and-compile (add-to-list 'load-path "/tmp/nowhere"))
       (require 'el-chronos nil nil) (message "cfg") t)
;; 去掉 :straight nil
(progn (straight-use-package 'el-chronos) …)
```

旁注：`:demand t` 生成的 require 是 `(require 'el-chronos nil nil)`（**noerror = nil**，加载失败会直接抛错，
不会静默），与任务预期的 `nil t` 不同——这是期望的正常形态，不要额外加 `:no-require t`。

### P2 `:load-path` 只接受字符串字面量

```elisp
;; "~/Workspace/el-chronos" → 原样传入（不 expand；运行时 locate-library 仍能解析 ~，可用但不推荐）
(eval-and-compile (add-to-list 'load-path "~/Workspace/el-chronos"))
;; "lisp"（相对）→ 宏展开期按 user-emacs-directory 固化：
(eval-and-compile (add-to-list 'load-path "/home/thomas/.cache/thomas-emacs-elisp-test/lisp"))
;; (expand-file-name "~/Workspace/el-chronos") 或 el-chronos-dir 变量 → 整个 form 展开为 nil
```

结论：写 `/home/thomas/Workspace/el-chronos` 这类**字面量绝对路径**最稳；相对路径会跟随
`user-emacs-directory`（隔离实例里就是隔离根，等于静默指错目录）；sexp/变量形态静默失效（无 autoload、无 require）。

### P3 `:autoload (sym "file")` 不支持（H5 结论：退化形态必需）

| 写法 | 展开 |
|---|---|
| `:autoload el-chronos-report` | `(unless (fboundp 'el-chronos-report) (autoload #'el-chronos-report "el-chronos"))` |
| `:autoload (el-chronos-report "el-chronos-report")` | `nil`（整个 form 失效） |
| 同上，直接调 normalizer | 报错原文：`(error "use-package: :autoload wants a symbol, or list of symbols")` |

源码依据（`use-package-core.el` 2.4.5）：`:autoload` 复用 `:commands` 的 normalizer（只吃符号），
库名一律取 `(use-package-as-string name)`，**没有** per-symbol 文件名语法。

单库 autoload 的后果（实测）：`el-chronos.el` 内**没有任何** `(require 'el-chronos-report)` /
`'el-chronos-web`（只有 `require 'sqlite`、以及 mode 启动时的 `require 'el-chronos-store` /
`'el-chronos-collect` 软加载），因此 `(autoload 'el-chronos-report "el-chronos")` 首次调用会加载
`el-chronos.el` 却**不定义**该命令，Emacs 报（同机制最小复现原文）：
`(error "Autoloading file /tmp/fake-entry.el failed to define function fake-cmd")`。

→ D4 的「语法不成立」分支**必须走**：入口命令在 `:init` 里逐条显式 `autoload`（库名 = 定义文件名）。

### P4 `:commands` 不能声明跨文件入口

```elisp
;; 有 :demand t —— autoload 完全不生成，只剩 require
(progn (require 'el-chronos nil nil))
;; 无 :demand —— 生成 autoload，但库名是包名
(progn (unless (fboundp 'el-chronos-report) (autoload #'el-chronos-report "el-chronos" nil t))
       (unless (fboundp 'el-chronos-web-start) (autoload #'el-chronos-web-start "el-chronos" nil t)))
```

三点回答：① 无 `:demand` 才生成 autoload；② 文件名恒为包名 `el-chronos`，**不是** `el-chronos-report`；
③ `:commands` 隐含 defer，但 `:demand t` 覆盖之（`:demand` 在关键字序中位于 `:commands` 之后，且
handler 用 `(plist-get state :demand)` 抑制 autoload 生成）。

### P5 `:hook` 两种形态

```elisp
;; (emacs-startup . (lambda () (el-chronos-mode 1)))
(progn (require 'el-chronos nil nil) (add-hook 'emacs-startup-hook #'(lambda nil (el-chronos-mode 1))))
;; (emacs-startup . el-chronos-mode)
(progn (require 'el-chronos nil nil) (add-hook 'emacs-startup-hook #'el-chronos-mode))
```

符号形态确实直接 `add-hook` 符号 → 运行时无参调用 `(el-chronos-mode)`，即 toggle（D5 的理由成立）。
另：`:hook` 自带 autoload 推断，无 `:demand` 时会先插 `(unless (fboundp 'el-chronos-mode) (autoload … "el-chronos" nil t))`。

### P6 `:custom` 与未加载包

```elisp
(progn (let ((custom--inhibit-theme-enable nil))
         (unless (memq 'use-package custom-known-themes)
           (deftheme use-package) (enable-theme 'use-package)
           (setq custom-enabled-themes (remq 'use-package custom-enabled-themes)))
         (custom-theme-set-variables 'use-package '(el-chronos-retention-days 14 nil nil "…")))
       (require 'el-chronos nil nil))
```

- 展开的是 `custom-theme-set-variables`（挂在 `use-package` 伪主题上），**不是** `customize-set-variable`。
- 未定义变量上不报错、不立即绑定：`(customize-set-variable 'el-chronos-does-not-exist-xyz 1)` 返回 `1`
  并使其 bound；`custom-theme-set-variables` 对未定义符号返回 nil、`boundp` 仍为 nil。
- 关键：把值设定在 `defcustom` 加载**之前**也**不会丢**——实测「先 `custom-theme-set-variables` 14 →
  后 load 定义 `(defcustom … 1)`」的结果是 **14**。
- 故 `:custom` 无需 `:demand t`，也无需 `:init (require …)` 前置。

### P7 straight `:local-repo` 形态（用户 2026-10-25 追加要求，D3 v3）

用户要求本地开发仓与远端同源，接线由 `:load-path` 改为 straight `:local-repo` recipe（与
`seshat-reader` 同款）。**先在 `verify` 隔离实例确认 straight 状态落在隔离根下**再执行任何安装动作
（实测：`straight-base-dir` = `~/.cache/thomas-emacs-elisp-test/.local/`、`user-emacs-directory` =
`~/.cache/thomas-emacs-elisp-test/`，均位于隔离根内，未触碰主实例 `.emacs.d/.local/`）。

实测（`elisp-test` 隔离实例，Emacs 31.1）：

| 断言 | 实测值 |
|---|---|
| `(locate-library "el-chronos")` | `~/.cache/thomas-emacs-elisp-test/.local/straight/build-31.1/el-chronos/el-chronos.el`（软链到开发仓） |
| build 目录内容 | 7 个 `el-chronos*.el` 软链 + `el-chronos-autoloads.el`（**独立真实文件**，非软链） |
| straight 生成的 autoload 条目数 | **15**（与 `make autoloads` 产物逐字节相同） |
| 5 个入口命令 `autoloadp` | `report` / `weekly-report` / `profile-command` / `web-start` / `web-stop` 全 `t` |
| 跨文件抽查 `autoloadp` | `el-chronos-purge` = `t`、`el-chronos-attrib-clear-cache` = `t`、`el-chronos-web-stop` = `t` |
| `(load init-chronos.el)` | 返回 `t`（无错误）；`(featurep 'el-chronos)` = `t`；`THOMAS_EMACS_INSTANCE` = `isolated` 时 `emacs-startup-hook` 无 chronos 条目（守卫生效） |
| 源仓库 `el-chronos-autoloads.el` sha256 | 前后均为 `9d4aeefb…73efbc7`（**无写穿**，`:files` 的 `(:exclude ...)` 生效） |
| `straight-rebuild-package` | **未触发** —— 首次 build 即生成 autoloads，`autoloadp` 全 `t` |

两条新约束（已同步进 `Readme.org` / `docs/operations.org`）：

1. `straight-pull-package` / `straight-checkout-package` 直接作用在**开发仓本身**（`:local-repo`
   就是那个 git 工作树，straight 不复刻副本）。
2. 新增 / 改名 interactive 命令后须 `M-x straight-rebuild-package RET el-chronos`，否则新命令不在
   autoload 表里。

### P8 `:if` 包不住 `:straight`（code-reviewer major 问题，D3 v4）

**结论**：`use-package` 的 `:if` / `:when` **不能**用来抑制 straight 安装。需要「仓库缺失就降级」
时必须用 `if` 包住**整个** `use-package` form。原「最终写法」里的
`:if (file-exists-p ...)`（P7 遗留）只能阻止 `require`，`straight-use-package` 照样执行 ——
目录缺失时会去远端 clone 本仓，破坏「缺失只告警」的降级语义。

实测（`elisp-test` 隔离实例，Emacs 31.1 / use-package 2.4.5，`macroexpand-1` 原始展开）：

```elisp
;; ① 旧形态：straight-use-package 在 progn 顶层，:if 只包住 when
(macroexpand-1 '(use-package el-chronos
                  :if nil
                  :straight (el-chronos :type git :host github :repo "awerdx520/el-chronos"
                                        :local-repo "/tmp/definitely-not-a-repo"
                                        :build (:not compile native-compile))))
;; → (progn
;;     (straight-use-package '(el-chronos :type git :host github :repo "awerdx520/el-chronos"
;;                                        :local-repo "/tmp/definitely-not-a-repo"
;;                                        :build (:not compile native-compile)))
;;     (when nil (require 'el-chronos nil nil)))

;; ② 对照形态：整个 use-package 在 if 分支内（macroexpand-all 展开）
(macroexpand-all '(if nil (use-package el-chronos :straight (el-chronos :local-repo "/tmp/x"))))
;; → (if nil
;;     (progn (straight-use-package '(el-chronos :local-repo "/tmp/x"))
;;            (require 'el-chronos nil nil)))
```

运行时交叉验证（把 `straight-use-package` 用 `cl-letf` 换成记录器）：

| 形态 | `straight-use-package` 是否被调用 | 说明 |
|---|---|---|
| `(use-package el-chronos :if nil :straight …)` | **是**（`(el-chronos :local-repo "/tmp/x")`） | 会真的去 clone |
| `(if (file-exists-p …) (use-package …) (display-warning …))`（条件取假） | 否 | 走 `display-warning` 分支（实测 `warn-args` = `chronos`） |

**正确写法**：见下节「最终采用的 `init-chronos.el` 写法」——`if` 在最外层，`display-warning` 放在
else 分支。**不要**用 `:if` / `:when`，也不要试图把判据塞进 `:straight` 的 recipe。

**同步范围**：`Readme.org`（方式 C 示例改 `if` 包裹 + 陷阱节新增第一条「`:if` / `:when` 包不住
straight 安装」，节标题「两个新增陷阱」→「三个新增陷阱」）、`docs/operations.org`（方式 C 示例 +
关键字表格 + 「三个静默陷阱」→「四个静默陷阱」并新增 ④ + 展开片段补两段）、`docs/api.org`
（「配置侧写法」要点三条 → 四条）、`el-chronos/AGENTS.md`（autoload 契约行补降级判据）、
`thomas-emacs` 仓（`lisp/init-chronos.el` 改 `if` 包裹、`CHANGELOG.md` 补修复条、`AGENTS.md`
降级描述补判据形态）、`el-chronos/CHANGELOG.md`（修复条 + 旧条目交叉引用）。

### 最终采用的 `init-chronos.el` 写法（供 T7）

```elisp
;; P8/D3 v4：降级判据必须用 if 包住整个 use-package —— use-package 的 :if 包不住 :straight
(if (file-exists-p "/home/thomas/Workspace/el-chronos/el-chronos.el")
    (use-package el-chronos
      :straight (el-chronos                       ; D3 v3：与 seshat-reader 同款
                 :type git
                 :host github
                 :repo "awerdx520/el-chronos"
                 :branch "master"
                 :local-repo "/home/thomas/Workspace/el-chronos"
                 :files ("el-chronos*.el" (:exclude "el-chronos-autoloads.el"))
                 :build (:not compile native-compile))
      :demand t                                   ; D2：模式须尽早启用
      :config
      ;; D5/P5：必须 lambda 形态，符号形态是无参 toggle
      (unless (member (getenv "THOMAS_EMACS_INSTANCE") '("isolated" "pure"))
        (add-hook 'emacs-startup-hook (lambda () (el-chronos-mode 1)))))
  (display-warning 'chronos "未找到 el-chronos，性能与用法观测不可用" :warning))
```

- **不再需要 `:init` 内逐条 `autoload`**：P7 实测 straight 依 15 条 cookie 生成并自动加载
  autoloads（5 个入口 + `purge` / `attrib-clear-cache` 等抽查 `autoloadp` 全 `t`）。
  P3/P4 的结论仍有效——它解释的是**手写 autoload** 或 `:load-path` 形态下的约束。
- `:custom` 可按需使用（P6：不必配合 `:demand`）。
- 可选优化（不进 T7 硬性要求，**v3 起已由 straight 自动完成**）：手工 `:load-path` 形态下，本机跑过
  `make autoloads` 后可在 `:init` 里改一行
  `(load (expand-file-name "el-chronos-autoloads" "/home/thomas/Workspace/el-chronos") nil t)`
  一次覆盖 15 个命令（T2 生成物实测每个命令都指向自己的定义文件，如
  `(autoload 'el-chronos-report "el-chronos-report" …)`）。生成物**不入库**，缺文件时须静默跳过。

## 验证标准

| 级别 | 命令 | 通过判据 |
|---|---|---|
| L1 | 两仓库 `make check-parens`；el-chronos `make lint` | 全部通过；lint 零告警；生成物不在检查范围 |
| L2 | el-chronos `make test` | ≥ 237 用例全绿，0 skipped |
| L2 | `make autoloads` + 15 命令 `autoloadp` 检查 | 15 个 `t` |
| L2 | thomas-emacs `make test` | 全绿（含 `test-chronos-observer-instance-guard` 五组断言） |
| L3 | `verify` 隔离实例：autoload → `(el-chronos-mode 1)` → `el-chronos-status` | 无错误、状态显示运行中；收尾 `set_task auto` + `instance stop` |

## 注意事项

1. **实例路由**：所有 elisp 验证必须先 `elisp_mcp_set_task(task="verify")`，需要实例时 `elisp_mcp_instance(action="start", instance="verify")` 并轮询 `alive`；收尾三步 `set_task auto` → `instance(action="stop", instance="verify")` → `instance_status` 确认。**禁止**在 `config` 任务下跑 ERT / 批量字节编译。
2. **安全点**：两仓库改动前各自执行 `git status` 确认工作树干净（有未提交改动则先报告），再开始编辑。
3. **零第三方依赖**：包内不得出现 `(require 'use-package)` 或 straight 相关代码。
4. **文件头尾**：新文件必须含 `lexical-binding: t` 与 `;;; <name>.el ends here`。
5. **注释与文档中文**，符号英文，前缀 `el-chronos-`。
6. **不做 git 提交**：除非用户显式要求。
7. 「实现期结论」小节由 T6 填写（H4/H5 实测结果），Phase 4 假设复盘据此展开。
