;;; el-chronos-dashboard.el --- ETAF 可视化页面  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Thomas

;; Author: Thomas
;; Keywords: tools, performance
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; Emacs 内可视化页面（T8）：组件树 + SVG 图表 + 数据卡片 + 下钻。数据全部来自
;; `el-chronos-analysis'（本模块不写 SQL、不写库、不改采集行为）；阻塞事件的完整栈复用
;; `el-chronos-report' 的 `*el-chronos-event*'。
;;
;; 自观测抑制：渲染是慢路径（首次渲染含 ETAF 组件定义 + 快照查询，实测约 2.8s），会被
;; 1s 心跳记成一条 `block' 事件 —— 观测者在观测自己，属假阳性。`el-chronos-dashboard' 与
;; `--refresh' 套用与 `el-chronos-report--without-block-events' 同款的**三层**抑制
;; （抑制变量 + 抬高阈值 + 重置心跳基线），见
;; `el-chronos-dashboard--without-block-events'。只包渲染入口，不包纯读取函数。
;;
;; 两种形态（I9 / I11）：ETAF 可用 → `*el-chronos*' 是 `etaf-mount' 挂载的 ETAF 页面；
;; ETAF 缺失 → `display-warning' 提示安装 + `tabulated-list-mode' 降级页（慢命令区块 +
;; 热点函数区块 + `1'/`7'/`3' 切范围），不是空壳。图表在非图形 frame 下降级为文本字符图。
;;
;; 能力清单（10 项）：① 概览卡片 6 指标 ② 慢命令排行 ③ 热点函数排行（含包归属）
;; ④ 包 / 模块占比条形图 ⑤ 趋势折线（样本量 / 慢命令 / 阻塞）⑥ 阻塞事件列表与详情
;; ⑦ 用法热力图 ⑧ 回归列表 ⑨ 会话列表与启动耗时 ⑩ 时间范围切换与下钻。
;; 快捷键：`1'/`7'/`3' 切范围、`g' 刷新、`r' 自动刷新、`d' 阻塞事件完整栈、`q' 关闭。
;;
;; ETAF 是软依赖（`require ... nil t'）。组件式与挂载形式都走 `eval' 延迟展开：`make lint'
;; 的 `emacs -Q --batch -L .' 字节编译在 ETAF 缺席时展开不了 `etaf-define-component' /
;; `etaf-view'（宏缺席会被编成普通函数调用，运行期即使 ETAF 在位也会失败）。代价是组件体
;; 不做编译期检查，故组件体只调用本文件已定义好的函数。
;;
;; 配色与宽度（详见 docs/ui.org「主题与配色」「宽度策略与不截断」）：
;; - 背景 / 文字跟随当前 Emacs 主题：根组件 `:setup' 用 `etaf-theme-provide' 提供从
;;   `default' / `shadow' / `link' 等 face 派生的调色板（内置组件的语义 token 全部命中）；
;;   根 column 再带 `:background-color' / `:color'，挂载后 `--apply-theme-canvas' 用
;;   `face-remap-set-base' 把 buffer 的 `default' face 也 remap 成主题色。
;; - 数据文本**不截断**：`etaf-table' 的单元格固定 `:overflow hidden' + `:wrap-mode none'，
;;   整数列宽还会补 `…'，两条路都违反可见性要求，故数据行改用卡片（`el-chronos-dashboard-card'），
;;   主键一行、其余字段一行，按窗口宽度折行。`--fit-text' 只用于标题与图表标签。
;;
;; 图表纯函数（ERT 可直接断言，需 ETAF 在 load-path）：`--bar' `--scale' `--sparkline'
;; `--bar-chart' `--heatmap' `--range-symbol' `--range-string' `--range->days' `--page-slice'
;; `--to-text-bars'。

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'color)
(require 'face-remap)
(require 'tabulated-list)
(require 'el-chronos)
(require 'el-chronos-analysis)
(require 'el-chronos-report)            ; `el-chronos-show-event'：阻塞事件完整栈

(declare-function etaf-mount "etaf" (buffer-or-name view &optional options))
(declare-function etaf-ui-svg-image "etaf-ui"
                  (body width height viewbox &optional preserve-aspect-ratio))
(declare-function etaf-ui-svg-rect "etaf-ui" (x y width height &rest attributes))
(declare-function etaf-ui-svg-path "etaf-ui" (d &rest attributes))
(declare-function etaf-ui-svg-text "etaf-ui" (x y text &rest attributes))
(declare-function etaf-unmount "etaf" (&optional runtime))
(declare-function etaf-runtime-for-buffer "etaf" (buffer-or-name))
(declare-function etaf-runtime-viewport "etaf" (&optional runtime))

;;; ETAF 软依赖探测（I9）

(defvar el-chronos-dashboard--etaf-available-p
  (and (require 'etaf nil t) (require 'etaf-ui nil t)
       (fboundp 'etaf-mount) (fboundp 'etaf-ui-svg-image))
  "加载时探测到的 ETAF 可用性。
ETAF 由 `etaf' 与 `etaf-ui' 提供（recipe 见 thomas-emacs 的 `lisp/init-etaf.el'：
`ecss' → `ebox' → `etaf' → `etaf-ui' 四个 straight 包，编译期顺序不可乱）。")

(defvar el-chronos-dashboard--components-defined-p nil
  "非 nil 表示 ETAF 组件已在本会话定义过；`defvar' 语义使本文件重载后仍保留。
`etaf-define-component' 拒绝「重复定义」，故必须守卫，不能靠重复 `eval'。")

(defun el-chronos-dashboard-etaf-available-p ()
  "返回 ETAF（`etaf' + `etaf-ui'）是否可用；只读探测，不重新 require。"
  (and (bound-and-true-p el-chronos-dashboard--etaf-available-p) t))

;;; 自观测抑制（与 `el-chronos-report' 同机制，三层缺一不可）

(defvar el-chronos-collect--suppress-block-p nil
  "非 nil 时采集层心跳跳过阻塞判定。
由报告层（`el-chronos-report--without-block-events'）与页面层
（`el-chronos-dashboard--without-block-events'）在重查询 / 渲染期间 `let' 绑定为 t；
**读取方在 `el-chronos-collect'（心跳里 `bound-and-true-p' 判断并推进基线）**，
本文件只声明 + 绑定，不读取。此处仅声明以避免跨模块 `let' 绑定未声明变量报
`void-variable'；与 collect 侧同名同义，重复声明无副作用。")

(defvar el-chronos-collect--last-heartbeat nil
  "上一次心跳的实际触发时刻（`float-time'），采集层持有。
本文件只在渲染结束后重设基线：主线程被渲染占住期间心跳 timer 不会运行，`let' 绑定在渲染
返回时就已解除，心跳是在**之后**才补跑的 —— 只做前两层抑制拦不住这次补跑。")

(defconst el-chronos-dashboard--suppress-block-threshold-ms 60000
  "渲染期间临时抬高的阻塞阈值（毫秒），作为抑制变量的兜底（60s 足够覆盖一次渲染）。")

(defmacro el-chronos-dashboard--without-block-events (&rest body)
  "在 BODY 执行期间抑制采集层把「页面渲染耗时」记成阻塞事件，返回 BODY 的值。

与 `el-chronos-report--without-block-events' 同款三层保护（缺一不可）：

1. 绑定 `el-chronos-collect--suppress-block-p' 为 t —— 采集层心跳据此跳过判定；
2. 把 `el-chronos-block-threshold-ms' 临时抬到
   `el-chronos-dashboard--suppress-block-threshold-ms'（60s）—— 兜住「抑制变量还没被
   采集层读取」的过渡期；
3. 收尾把 `el-chronos-collect--last-heartbeat' 重设为当前时刻 —— **唯一有效的一层**：
   主线程被 BODY 占住时心跳 timer 根本不运行，`let' 绑定在 BODY 返回时就已解除，心跳
   是在之后才补跑、看到整段 gap 的；不重置基线，前两层都拦不住这次补跑（report 侧已
   实测验证）。

代价：渲染期间恰好发生的**真实**阻塞也不会被记录。有意取舍 —— 首屏渲染 / 刷新是用户主动
触发的一次性重绘，其耗时属预期行为，不该混进「待排查的卡顿」里。"
  (declare (indent 0) (debug t))
  `(let ((el-chronos-collect--suppress-block-p t)
         (el-chronos-block-threshold-ms el-chronos-dashboard--suppress-block-threshold-ms))
     (unwind-protect
         (progn ,@body)
       (setq el-chronos-collect--last-heartbeat (float-time)))))

;;; 常量与自定义项

(defconst el-chronos-dashboard--buffer-name "*el-chronos*" "页面 buffer 名称（两种形态共用）。")
(defconst el-chronos-dashboard--range-names '("1d" "7d" "30d")
  "UI 显示与 `--state' 用的规范范围字符串；顺序即页面按钮顺序。")
(defconst el-chronos-dashboard--range-days '((1d . 1) (7d . 7) (30d . 30))
  "符号化范围（analysis 层认的键）到天数的映射；未列出的符号按 7 天处理。")
(defconst el-chronos-dashboard--default-range "7d" "默认时间范围（字符串，显示用）。")
(defconst el-chronos-dashboard--empty "（无数据）" "空数据占位文本。")
(defconst el-chronos-dashboard--heat-chars ["·" "░" "▒" "▓" "█"] "文本热力图的强度字符。")
(defconst el-chronos-dashboard--chart-height 12 "图表 scene 的逻辑高度（坐标单位）。")
(defconst el-chronos-dashboard--section-slow "▸ 慢命令 TOP" "降级页第一张表的区块标题。")
(defconst el-chronos-dashboard--section-functions "▸ 热点函数 TOP" "降级页第二张表的区块标题。")
(defconst el-chronos-dashboard--degraded-format
  [("区块" 12 t) ("名称 / 指标" 34 t) ("值" 12 t) ("明细" 24 t)]
  "降级页列格式：区块 / 名称 / 值 / 明细（向量里的元素是字面量列表，不要写 `(list ...)'）。")

(defcustom el-chronos-dashboard-page-size 20
  "表格每页行数（5 张表都受此上限约束：分页表按页取，不分页表只取首页）。
这是**单次渲染**进入 ETAF 组件的行数上限：`etaf-table' 会为每一行保留一个行 Host
（含单元格子组件），行数直接决定单次渲染的分配量与保留量（实测见
`docs/ui.org'「每页行数与内存」）。不要为了「一次看全」把它调到几百以上。"
  :type 'integer :group 'el-chronos)
(defcustom el-chronos-dashboard-max-rows 200
  "单表进入数据快照的最大行数（防御无界查询）。
`:sessions' 按时间窗查询且**无行数上限**（一年重启数千次就有数千行）、`:trend' /
`:heatmap' 同理随窗口增长。快照只保留前 max-rows 行，渲染再按
`el-chronos-dashboard-page-size' 取首页，两级上限共同把单次渲染的内存占住。"
  :type 'integer :group 'el-chronos)
(defcustom el-chronos-dashboard-chart-points 60
  "趋势折线最多使用的采样点数（超出等距抽稀）。" :type 'integer :group 'el-chronos)
(defcustom el-chronos-dashboard-chart-width 72
  "图表逻辑宽度（坐标单位，也是 terminal 文本图的字符宽度）。" :type 'integer :group 'el-chronos)
(defcustom el-chronos-dashboard-refresh-seconds 30
  "自动刷新间隔（秒）；`r' 切换，关闭页面时取消。" :type 'integer :group 'el-chronos)

(defvar el-chronos-dashboard--state nil
  "页面 UI 状态 plist：`:range' 范围、`:page' 页码（0 基）、`:selected' 下钻项。
用全局变量而非 buffer-local：ETAF 的 `:on-press' 回调在渲染上下文执行、闭包不携带
buffer，而页面是单例。")
(defvar el-chronos-dashboard--snapshot nil
  "最近一次加载的数据快照（见 `--load-snapshot'）。渲染只读快照，绝不在渲染路径跑 SQL。")
(defvar el-chronos-dashboard--refresh-timer nil "自动刷新 timer；nil 表示关闭。")

;;; 小工具

(defun el-chronos-dashboard--graphic-p ()
  "当前能否用 SVG 图表（图形 frame 且 SVG 类型可用）。batch / terminal 下为 nil。"
  (and (fboundp 'display-graphic-p) (display-graphic-p)
       (image-type-available-p 'svg)))

(defun el-chronos-dashboard--fmt (kind value)
  "按 KIND 格式化 VALUE：`num' `ms' `bytes' `pct' `time' `str'；取不到值返回 \"-\"。"
  (pcase kind
    ('num (if (numberp value) (format "%d" (round value)) "-"))
    ('ms (cond ((not (numberp value)) "-")
               ((< (abs (float value)) 1000.0) (format "%.0f ms" (float value)))
               (t (format "%.2f s" (/ (float value) 1000.0)))))
    ('bytes (cond ((not (numberp value)) "-")
                  ((< (float value) 1024.0) (format "%.0f B" (float value)))
                  ((< (float value) 1048576.0) (format "%.1f KB" (/ (float value) 1024.0)))
                  ((< (float value) 1073741824.0) (format "%.2f MB" (/ (float value) 1048576.0)))
                  (t (format "%.2f GB" (/ (float value) 1073741824.0)))))
    ('pct (if (numberp value) (format "%.1f%%" (float value)) "-"))
    ('time (if (numberp value) (format-time-string "%m-%d %H:%M" (/ (float value) 1000.0)) "-"))
    (_ (let ((text (and value (format "%s" value))))
         (if (or (null text) (string-empty-p text)) "-" text)))))

;;; 宽度策略（任何 ≥ 60 列的窗口都不溢出、数据文本不被截断）

;;
;; 目标有两个，且它们互相拉扯：
;;   (a) 不溢出：任何节点都不越过窗口右边界；
;;   (b) 不截断：命令名 / 函数名 / 包名 / 路径这类**数据文本**必须完整可见，
;;       既不许用 `…' 省略，也不许被 `:overflow hidden' 裁掉。
;;
;; 为什么数据区不再用 `etaf-table'（读 `etaf-ui-table.el' 确认，实验复核见 docs/ui.org）：
;;   - 整数列宽 N：ETAF 走「定宽文本」快路径（整行一个 padded Text Host），列严格对齐，
;;     但超长单元格由 `etaf-ui--table-fit-text' 调 `truncate-string-to-width' 补 `…' → 违反 (b)。
;;   - `(fr N)' 权重列宽：走 Grid 路径，`etaf-ui--table-cell' 仍是 `:overflow hidden
;;     :wrap-mode none'，超长文本直接被裁掉（连 `…' 都没有）→ 同样违反 (b)；
;;     且**每行各自算 track**（行容器 shrink-wrap），表头与数据行、数据行彼此都列不对齐
;;     （实测三行 `(fr 4)/(fr 1)/(fr 1)'：表头首列 6 列、数据行首列 48 列，起始位置各不相同；
;;     给单元格加 `:min-width (px 0)' 也压不住 min-content 差异）。
;;   结论：**ETAF 表格无法同时满足 (a) 与 (b)**。故数据行改为**卡片布局**：每条记录一个
;;   `column'，主键一行、其余字段一行，都用 `:wrap-mode word' 在窗口内自动折行 —— 文本完整、
;;   不越过窗口。代价是失去表格式的列对齐（卡片布局本来也没有列）。见 docs/ui.org「不截断策略」。
;;
;; 仍然按窗口宽度算的东西：图表宽度、tile 单元格宽度、下钻弹窗宽度、文本图逐行宽度。
;; 它们的宽度预算与 ETAF 盒模型逐项对应（见 docs/ui.org「宽度策略」）：
;;   窗口列数
;;   − 面板左右占位 6（`etaf-panel' 内边距 `(ch 2)' × 2 边 + 1px 边框两侧按 2 列算）
;;   − 余量 1（像素取整）
;; = 内容可用列数

(defconst el-chronos-dashboard--panel-padding-cells 6
  "面板左右占位合计（字符）：内边距 `(ch 2)' × 2 边 = 4，再按 2 列算 1px 边框（两侧各 1px）。
实测 chart-block 的 x 坐标 = 3、宽度 = 窗口宽度 − 6，与 6 列占位一致。")

(defconst el-chronos-dashboard--width-safety-cells 1
  "像素取整的余量（列）：宁可少 1 列，也不要因取整溢出。")

(defconst el-chronos-dashboard--fallback-width 80
  "拿不到 viewport 时的兜底列数：`emacs -Q --batch' 的 frame 宽度就是 80。")

(defun el-chronos-dashboard--viewport-cells ()
  "返回页面可用字符列数（窗口 body 宽度）。

优先读 ETAF viewport：组件**渲染期**读取它即建立响应式依赖，窗口缩放后 ETAF 会重渲染
（`ebox-viewport-change-functions'）——这是列宽 / 图宽自适应的唯一可靠输入；
`(window-body-width)' 在首渲染时可能还是旧窗口，且不参与响应式。
viewport 宽度的单位是像素（图形 frame）/ 字符单元（文本终端），故按 `frame-char-width' 折算成列。
未挂载（纯函数测试、首次挂载前）时回退 `(window-body-width)'，再回退 `--fallback-width'。"
  (let* ((char-width (max 1 (frame-char-width)))
         (pixels (car-safe (ignore-errors (etaf-runtime-viewport)))))
    (cond
     ((and (numberp pixels) (> pixels 0)) (max 20 (floor pixels char-width)))
     ((and (fboundp 'window-body-width) (window-body-width))
      (max 20 (window-body-width)))
     (t el-chronos-dashboard--fallback-width))))

(defun el-chronos-dashboard--content-cells (&optional avail)
  "AVAIL（默认 `--viewport-cells'）扣掉面板内边距与边框余量后的内容列数。"
  (max 24 (- (or avail (el-chronos-dashboard--viewport-cells))
             el-chronos-dashboard--panel-padding-cells
             el-chronos-dashboard--width-safety-cells)))

(defun el-chronos-dashboard--fit-text (text width)
  "把单行 TEXT 截到 WIDTH 列以内（超出部分用 `…'）。"
  (let ((text (format "%s" (or text ""))))
    (if (<= (string-width text) (max 1 width)) text
      (truncate-string-to-width text (max 1 width) 0 nil "…"))))

(defun el-chronos-dashboard--fit-text-block (text width)
  "把多行 TEXT 逐行截到 WIDTH 列以内（超出部分用 `…'），返回同样行数的字符串。

文本图一行由 `%-6s 条形 峰值 N' 拼成，窄窗口下总宽超过内容宽度就会被 ETAF 折行——
一张图被拆成两行（`布局错乱' 的又一来源）。逐行截断保证每行仍是一行，图整体不被拆散。"
  (mapconcat (lambda (line) (el-chronos-dashboard--fit-text line width))
             (split-string (format "%s" (or text "")) "\n")
             "\n"))

(defun el-chronos-dashboard--widest-line (text)
  "返回多行 TEXT 中最宽一行的显示宽度（列）。"
  (cl-loop for line in (split-string (format "%s" (or text "")) "\n")
           maximize (string-width line)))

(defun el-chronos-dashboard--fit-text-chart (kind rows limit)
  "在 LIMIT 列内渲染 KIND 文本图，返回逐行都不超 LIMIT 的字符串。

文本图一行的宽度不仅取决于 `width'，还取决于条形字符的实际显示宽度（`█'/`░' 在等宽字体里
通常占 1 列，在 `char-width' 表里可能是 2 列）。故先按当前图表宽度画，宽了就缩窄图表宽度重画
（最多 4 轮），仍超宽才逐行截断——这样「峰值 N」这类尾部信息尽量保住，而不是一刀切掉。"
  (let* ((width (el-chronos-dashboard--chart-width))
         (text (el-chronos-dashboard--to-text-bars (list :kind kind :rows rows) width))
         (round 0))
    (while (and (< round 4)
                (> (el-chronos-dashboard--widest-line text) limit))
      (setq width (max 20 (- width (max 2 (ceiling (/ (- (el-chronos-dashboard--widest-line text)
                                                         limit)
                                                      2.0)))))
            text (el-chronos-dashboard--to-text-bars (list :kind kind :rows rows) width)
            round (1+ round)))
    (el-chronos-dashboard--fit-text-block text limit)))

;;; 主题配色（背景 / 文字跟随当前 Emacs 主题）

;;
;; 为什么经由 ETAF 的 Theme 机制，而不是给每个节点写死颜色（读 `etaf-context.el' /
;; `etaf-ui-style.el' / `ebox-buffer.el' 确认）：
;;   - `etaf-ui' 的每个内置组件都从「继承的 Theme」里取语义色 token（`:ui-panel-bg' /
;;     `:ui-fg' / `:ui-table-border' …），取不到才回落到包内**固定浅色**调色板（`#FFFDF8'
;;     等）——所以页面默认永远是浅色，与用户主题无关；
;;   - 「让整页跟随主题」= 在组件树根部 provide 一份主题调色板（`etaf-theme-provide'，
;;     与 `etaf-provide' 同一提供机制，可在组件 `:setup' 里调用），子树内所有组件的
;;     token 解析自动生效（实测：面板及其**全部后代**节点的 `ebox-cs-bg' 都变成提供的颜色）；
;;   - `etaf-mount' 只有 `:viewport-width' / `:viewport-height' / `:observer' 三个选项，
;;     **不接受** `:background' / `:foreground'（`etaf-app-open' 接受，但它自带
;;     buffer / 窗口 / 模式行一整套语义，与本页面的挂载方式不兼容），所以背景走两条腿：
;;       ① Theme 调色板 → 页面内部（面板、表格、按钮、文字）跟随主题；
;;       ② 根节点 `:background-color' / `:color' → ebox 的 `ebox--sync-canvas' 把 buffer
;;          的 `default' face 背景 remap 成同一颜色，面板之外的行尾空白不再露出宿主底色。
;; 颜色取不到（`emacs -Q --batch' 没有主题）时一律返回 nil / 空 plist：绝不把
;; `unspecified-bg' 当颜色传下去（实测那样面板会拿到一个非法颜色）。

(defconst el-chronos-dashboard--theme-shade-amount 4
  "面板表面相对页面背景的明暗偏移（百分数）：同一颜色太糊，偏移 4 足以分层又不刺眼。")

(defun el-chronos-dashboard--face-color (attribute face)
  "返回 FACE 的 ATTRIBUTE（`:background' / `:foreground'）颜色串，取不到返回 nil。
INHERIT 传 t，主题通过 face 继承设置的颜色同样可取到；未定义或未指定时 Emacs 返回
`unspecified-bg' / `unspecified-fg' 这类字符串，一律按 nil 处理（否则会被当颜色使用）。"
  (when (facep face)
    (let ((value (ignore-errors (face-attribute face attribute nil t))))
      (and (stringp value)
           (not (string-prefix-p "unspecified" value))
           (not (string-empty-p value))
           value))))

(defun el-chronos-dashboard--theme-surface (color)
  "把页面色 COLOR 往对比方向推 `--theme-shade-amount'，作为面板表面色；失败时原样返回。"
  (or (ignore-errors
        (if (eq (frame-parameter nil 'background-mode) 'dark)
            (color-lighten-name color el-chronos-dashboard--theme-shade-amount)
          (color-darken-name color el-chronos-dashboard--theme-shade-amount)))
      color))

(defun el-chronos-dashboard--theme-palette ()
  "从当前 Emacs 主题派生 ETAF 调色板（keyword plist）；主题不可用时返回 nil。
只收录**确实解析出颜色串**的键：缺失键由 ETAF 回落到包内默认调色板，而给一个 nil 值
会让组件把 nil 当颜色用（渲染期报非法颜色）。"
  (let* ((bg (el-chronos-dashboard--face-color :background 'default))
         (fg (el-chronos-dashboard--face-color :foreground 'default))
         (muted (or (el-chronos-dashboard--face-color :foreground 'shadow) fg))
         (border (or (el-chronos-dashboard--face-color :foreground 'shadow)
                     (el-chronos-dashboard--face-color :background 'mode-line)
                     fg))
         (accent (or (el-chronos-dashboard--face-color :foreground 'link) fg))
         (accent-bg (or (el-chronos-dashboard--face-color :background 'highlight) accent))
         (surface (and bg (el-chronos-dashboard--theme-surface bg)))
         (pairs (list :ui-bg bg :ui-fg fg
                      :ui-panel-bg surface :ui-panel-fg fg
                      :ui-panel-border border :ui-border border
                      :ui-table-border border :ui-muted-fg muted
                      :ui-accent accent :ui-accent-fg bg
                      :ui-button-primary-bg accent-bg :ui-button-primary-fg bg
                      :ui-button-secondary-bg surface :ui-button-secondary-fg accent
                      :ui-button-ghost-fg fg
                      :ui-success-fg (el-chronos-dashboard--face-color :foreground 'success)
                      :ui-warning-fg (el-chronos-dashboard--face-color :foreground 'warning)
                      :ui-danger-fg (el-chronos-dashboard--face-color :foreground 'error)
                      :ui-info-fg accent)))
    (when (and bg fg)
      (cl-loop for (key value) on pairs by #'cddr
               when (and (keywordp key) (stringp value))
               append (list key value)))))

(defun el-chronos-dashboard--theme-background ()
  "页面底色（字符串）或 nil：根节点 `:background-color' 用，nil 时不写该属性。"
  (el-chronos-dashboard--face-color :background 'default))

(defun el-chronos-dashboard--theme-foreground ()
  "页面文字色（字符串）或 nil：根节点 `:color' 用，nil 时不写该属性。"
  (el-chronos-dashboard--face-color :foreground 'default))

(defun el-chronos-dashboard--apply-theme-canvas (buffer)
  "把 BUFFER 的 `default' face 重映射成当前主题的背景 / 前景色，返回 BUFFER。

这是 etaf 的 `etaf-app--paint-canvas' 用的同一机制（`face-remap-set-base'）：
`etaf-mount' 不接受 `:background' / `:foreground'，而 ebox 的 `ebox--sync-canvas' 只在
**显示时**（有 window）才把根节点背景 remap 到 `default' face —— batch / 首次挂载前读不到。
这里在挂载后显式设置一次：面板之外的行尾空白、`text' 节点未覆盖的列都跟随主题背景，
文字默认色也跟随主题前景。用 `set-base' 而非 `add-relative'：重复渲染幂等，不会叠加。
主题颜色取不到（batch 无主题）时复位，保持宿主默认。"
  (with-current-buffer buffer
    (let ((bg (el-chronos-dashboard--theme-background))
          (fg (el-chronos-dashboard--theme-foreground)))
      (if (or bg fg)
          (face-remap-set-base 'default (append (and bg (list :background bg))
                                                (and fg (list :foreground fg))))
        (face-remap-reset-base 'default))))
  buffer)

;;; 纯函数：分页与图元

(defun el-chronos-dashboard--range-symbol (range)
  "把 RANGE（字符串或符号）归一为 analysis 层使用的符号键。
返回 `1d' / `7d' / `30d'；非法值（nil、未知字符串、其他类型）回落 `7d'。

归一必须发生在**数据查询**这一侧：`el-chronos-analysis--range' 的 alist 键是符号
（`el-chronos-analysis--range-days'），传字符串 `\"1d\"' 会让 `alist-get' 取不到而
静默回落 7 天。UI 状态仍存字符串（显示用），查询一律经本函数。"
  (let ((name (cond ((stringp range) (string-trim range))
                    ((symbolp range) (symbol-name range))
                    (t nil))))
    (if (member name el-chronos-dashboard--range-names)
        (intern name)
      '7d)))

(defun el-chronos-dashboard--range-string (range)
  "把 RANGE 归一为 UI 显示与 `--state' 用的规范字符串：\"1d\" / \"7d\" / \"30d\"。
非法值回落 `--default-range'。与 `--range-symbol' 互为两侧：状态存字符串、查询传符号。"
  (symbol-name (el-chronos-dashboard--range-symbol range)))

(defun el-chronos-dashboard--range->days (range)
  "把 RANGE 换算成天数：\"1d\"/`1d'→1、\"7d\"/`7d'→7、\"30d\"/`30d'→30；未知值按 7 天。
整数 RANGE 直接当作天数（保留旧行为）；字符串与符号两种写法都正确。"
  (if (integerp range)
      (max 1 range)
    (alist-get (el-chronos-dashboard--range-symbol range)
               el-chronos-dashboard--range-days 7)))

(defun el-chronos-dashboard--page-slice (rows page size)
  "取 ROWS 第 PAGE 页（0 基）内容，每页 SIZE 行；越界或空返回 nil。"
  (let* ((size (max 1 (or size 1)))
         (start (* (max 0 (or page 0)) size))
         (total (length rows)))
    (when (< start total) (cl-subseq rows start (min total (+ start size))))))

(defun el-chronos-dashboard--page-count (rows size)
  "ROWS 按 SIZE 行分页的总页数（至少 1）。"
  (max 1 (ceiling (float (length rows)) (max 1 (or size 1)))))

(defun el-chronos-dashboard--bar (value max width)
  "把 VALUE（参照上限 MAX）渲染成 `█' 重复的条形字符串，长度不超过 WIDTH。
VALUE 非正或非数字返回空串；MAX 非正视为「全部占满」；取整后不足 1 个字符补 1 个。"
  (let ((width (max 0 (or width 0))))
    (cond ((or (<= width 0) (not (numberp value)) (<= (float value) 0)) "")
          ((not (and (numberp max) (> (float max) 0))) (make-string width ?█))
          (t (make-string (max 1 (round (* width (min 1.0 (/ (float value) (float max))))))
                          ?█)))))

(defun el-chronos-dashboard--scale (values max height)
  "把 VALUES 线性缩放到高度 HEIGHT 的坐标点 `((IDX . Y) ...)'。
Y 用 SVG 习惯（0 在顶、HEIGHT 在底）；MAX 非正时全部落底。"
  (let* ((h (max 1 (or height 1)))
         (top (if (and (numberp max) (> (float max) 0)) (float max) 0.0)))
    (cl-loop for value in (cl-coerce values 'list) for index from 0
             collect (cons index
                           (if (<= top 0) h
                             (round (- h (* h (min 1.0 (/ (float (or value 0)) top))))))))))

;;; 纯函数：SVG 图表（scene = 不含 <svg> 外壳的元素串）

(defun el-chronos-dashboard--polyline-d (values width height)
  "返回把 VALUES 画成折线的 SVG path `d'；空 VALUES 返回 nil，末点贴右边界。"
  (let ((values (cl-coerce values 'list)))
    (when values
      (let* ((peak (cl-loop for v in values maximize (or v 0)))
             (points (el-chronos-dashboard--scale values peak height))
             (step (/ (float (1- (max 1 width))) (max 1 (1- (length values))))))
        (mapconcat (lambda (point)
                     (format "%s%.1f %d" (if (zerop (car point)) "M" "L")
                             (* (car point) step) (cdr point)))
                   points " ")))))

(defun el-chronos-dashboard--svg-wrap (body width height)
  "把 scene BODY 包成完整 `<svg>' 文档字符串，viewBox 取逻辑坐标 0 0 WIDTH HEIGHT。"
  (format (concat "<svg xmlns='http://www.w3.org/2000/svg' width='%d' height='%d'"
                  " viewBox='0 0 %d %d'>%s</svg>")
          width height width height body))

(defun el-chronos-dashboard--sparkline (values width height)
  "把 VALUES 画成折线，返回完整 `<svg>...</svg>' 字符串（纯函数，可测）。
折线用 path 承载：ETAF 的元素集没有 polyline，path 是等价载体。"
  (let ((body (or (when-let* ((d (el-chronos-dashboard--polyline-d values width height)))
                    (etaf-ui-svg-path d :fill "none" :stroke "#3355aa" :stroke-width 1.5))
                  (etaf-ui-svg-text 2 12 el-chronos-dashboard--empty
                                    :font-size 10 :fill "#8899aa"))))
    (el-chronos-dashboard--svg-wrap body width height)))

(defun el-chronos-dashboard--bar-chart (rows width height)
  "把 ROWS（`(:label L :value V :pct P)'）画成横向条形图，返回完整 SVG 字符串。
左侧标签占 1/3 宽，条形长度按 ROWS 内最大值归一。"
  (let* ((rows (cl-remove-if-not #'consp rows))
         (peak (cl-loop for row in rows maximize (float (or (plist-get row :value) 0))))
         (label-w (max 8 (/ width 3)))
         (bar-max (max 4 (- width label-w 8)))
         (row-h (max 1 (/ height (max 1 (length rows)))))
         (body (if (null rows) ""
                 (cl-loop for row in rows for index from 0 concat
                          (let* ((y (* index row-h))
                                 (label (el-chronos-dashboard--fmt 'str (plist-get row :label)))
                                 (len (length (el-chronos-dashboard--bar
                                               (plist-get row :value) peak bar-max))))
                            (concat
                             (etaf-ui-svg-text 0 (+ y row-h -2)
                                               (substring label 0 (min label-w (length label)))
                                               :font-size 9 :fill "#445566")
                             (when (> len 0)
                               (etaf-ui-svg-rect label-w (+ y 1) len (max 1 (- row-h 3))
                                                 :fill "#4a7fc1" :rx 1))
                             (etaf-ui-svg-text (+ label-w len 2) (+ y row-h -2)
                                               (el-chronos-dashboard--fmt
                                                'pct (plist-get row :pct))
                                               :font-size 9 :fill "#667788")))))))
    (el-chronos-dashboard--svg-wrap body width height)))

(defun el-chronos-dashboard--heat-color (value max)
  "把 VALUE（上限 MAX）映射成热力色（冷色 → 深蓝），0 为浅灰底。"
  (let ((ratio (if (and (numberp max) (> (float max) 0))
                   (min 1.0 (/ (float (or value 0)) (float max))) 0.0)))
    (cond ((zerop ratio) "#eef1f5") ((< ratio 0.25) "#c6dbef")
          ((< ratio 0.5) "#6baed6") ((< ratio 0.75) "#2171b5") (t "#08306b"))))

(defun el-chronos-dashboard--heatmap (rows width height)
  "把 ROWS（`(:label L :values (N...))'）画成热力图，返回完整 SVG 字符串。
每行一个命令、每列一个时间桶，颜色按全局最大值归一。"
  (let* ((rows (cl-remove-if-not #'consp rows))
         (buckets (cl-loop for row in rows maximize (length (plist-get row :values))))
         (peak (cl-loop for row in rows
                        maximize (cl-loop for v in (plist-get row :values) maximize (or v 0))))
         (label-w (max 8 (/ width 4)))
         (cell-w (max 2 (/ (- width label-w) (max 1 (or buckets 1)))))
         (row-h (max 1 (/ height (max 1 (length rows)))))
         (body (if (null rows) ""
                 (cl-loop for row in rows for index from 0 concat
                          (let ((y (* index row-h))
                                (values (plist-get row :values)))
                            (concat
                             (etaf-ui-svg-text 0 (+ y row-h -2)
                                               (el-chronos-dashboard--fmt
                                                'str (plist-get row :label))
                                               :font-size 9 :fill "#445566")
                             (cl-loop for value in values for column from 0 concat
                                      (etaf-ui-svg-rect
                                       (+ label-w (* column cell-w)) y
                                       (1- cell-w) (max 1 (- row-h 1))
                                       :fill (el-chronos-dashboard--heat-color
                                              value peak)))))))))
    (el-chronos-dashboard--svg-wrap body width height)))

(defun el-chronos-dashboard--trend-body (rows width height)
  "把趋势 ROWS（`(:label L :values (...))'）画成多条折线，返回 scene（不含 `<svg>'）。"
  (let ((colors '("#3355aa" "#cc6644" "#338855")) (index 0) (body ""))
    (dolist (row rows body)
      (when-let* ((d (el-chronos-dashboard--polyline-d
                      (plist-get row :values) width (max 2 (1- height)))))
        (setq body (concat body (etaf-ui-svg-path
                                 d :fill "none"
                                 :stroke (nth (mod index (length colors)) colors)
                                 :stroke-width 1.5))))
      (setq index (1+ index)))))

;;; 文本字符图（terminal 降级，I11）

(defun el-chronos-dashboard--heat-char (value max)
  "按 VALUE / MAX 的比例取一个热力字符字符串（`--heat-chars' 由弱到强）。"
  (let* ((chars el-chronos-dashboard--heat-chars)
         (ratio (if (and (numberp max) (> (float max) 0))
                    (min 1.0 (/ (float (or value 0)) (float max))) 0.0)))
    (aref chars (min (1- (length chars)) (round (* ratio (1- (length chars))))))))

(defun el-chronos-dashboard--text-chart (kind rows width)
  "把图表 KIND 的行 ROWS 渲染成文本字符图（每行一条）。

标签列按固定宽度截断（`%-16s' / `%-6s' / `%-18s' 只是补齐，长标签不截断会把同一张图
各行推成不同起点），故先 `--fit-text' 再补齐：图内各行的条形 / 时间桶因此始终对齐。"
  (let* ((rows (cl-remove-if-not #'consp rows))
         (bar-width (max 4 (- width 26)))
         (fmt (lambda (k v) (el-chronos-dashboard--fmt k v)))
         (label (lambda (row size)
                  (el-chronos-dashboard--fit-text
                   (funcall fmt 'str (plist-get row :label)) size))))
    (if (null rows) el-chronos-dashboard--empty
      (pcase kind
        ('bars (let ((peak (cl-loop for row in rows maximize
                                    (float (or (plist-get row :value) 0)))))
                 (mapconcat (lambda (row)
                              (format "%-16s %s %s"
                                      (funcall label row 16)
                                      (el-chronos-dashboard--bar (plist-get row :value)
                                                                 peak bar-width)
                                      (funcall fmt 'pct (plist-get row :pct))))
                            rows "\n")))
        ('trend (mapconcat (lambda (row)
                             (let ((peak (cl-loop for v in (plist-get row :values)
                                                  maximize (or v 0))))
                               (format "%-6s %s 峰值 %s"
                                       (funcall label row 6)
                                       (el-chronos-dashboard--bar peak peak bar-width)
                                       (funcall fmt 'num peak))))
                           rows "\n"))
        (_ (let ((peak (cl-loop for row in rows maximize
                                (cl-loop for v in (plist-get row :values)
                                         maximize (or v 0)))))
             (mapconcat (lambda (row)
                          (let ((values (append (plist-get row :values) nil)))
                            (format "%-18s %s"
                                    (funcall label row 18)
                                    (mapconcat (lambda (value)
                                                 (el-chronos-dashboard--heat-char
                                                  value peak))
                                               (cl-subseq values 0 (min bar-width
                                                                        (length values)))
                                               ""))))
                        rows "\n")))))))

(defun el-chronos-dashboard--to-text-bars (spec &optional width)
  "把图表 SPEC 渲染成文本字符图字符串（SVG 不可用时的降级，I11：永不返回 image）。
SPEC 是 plist：`:kind' 取 `trend' / `bars' / `heatmap'，`:rows' 为已归一的图表行；
WIDTH 是可用字符宽度（默认 `el-chronos-dashboard-chart-width'）。"
  (el-chronos-dashboard--text-chart (plist-get spec :kind) (plist-get spec :rows)
                                    (max 12 (or width el-chronos-dashboard-chart-width))))

;;; 图表行归一（analysis plist → 图表行）

(defun el-chronos-dashboard--snapshot-get (key)
  "从当前数据快照取 KEY；无快照返回 nil。" (plist-get el-chronos-dashboard--snapshot key))

(defun el-chronos-dashboard--downsample (values limit)
  "把 VALUES 等距抽稀到不超过 LIMIT 个点；LIMIT 非正或无需抽稀时原样返回。"
  (let ((values (cl-coerce (or values nil) 'list)) (limit (or limit 0)))
    (if (or (<= limit 0) (<= (length values) limit)) values
      (cl-loop for index from 0 below limit
               collect (nth (round (* index (/ (float (1- (length values))) (max 1 (1- limit)))))
                            values)))))

(defun el-chronos-dashboard--chart-rows (kind)
  "取图表 KIND（`trend' / `bars' / `heatmap'）的行数据。"
  (pcase kind
    ('trend (let* ((trend (el-chronos-dashboard--snapshot-get :trend))
                   (pick (lambda (key)
                           (el-chronos-dashboard--downsample
                            (mapcar (lambda (row) (or (plist-get row key) 0)) trend)
                            el-chronos-dashboard-chart-points))))
              (list (list :label "样本" :values (funcall pick :samples))
                    (list :label "慢命令" :values (funcall pick :slow-commands))
                    (list :label "阻塞" :values (funcall pick :blocked)))))
    ('bars (mapcar (lambda (row)
                     (list :label (plist-get row :package)
                           :value (or (plist-get row :self-ms) 0)
                           :pct (plist-get row :pct)))
                   (el-chronos-dashboard--snapshot-get :packages)))
    ('heatmap
     (let* ((rows (el-chronos-dashboard--snapshot-get :heatmap))
            (buckets (delete-dups (mapcar (lambda (row) (plist-get row :bucket)) rows)))
            (table (make-hash-table :test #'equal)))
       (dolist (row rows)
         (let* ((command (plist-get row :command))
                (cell (or (gethash command table)
                          (puthash command (make-vector (max 1 (length buckets)) 0) table)))
                (index (or (cl-position (plist-get row :bucket) buckets :test #'equal) 0)))
           (when (< index (length cell))
             (aset cell index (+ (aref cell index) (or (plist-get row :count) 0))))))
       (cl-loop for command being the hash-keys of table using (hash-values cell)
                collect (list :label command :values (append cell nil)))))
    (_ nil)))

(defun el-chronos-dashboard--chart-specs ()
  "图表区的 3 个图表描述（类型 + 标题）。"
  (list (list :kind 'trend :title "图表① 趋势折线：样本量 / 慢命令 / 阻塞事件")
        (list :kind 'bars :title "图表② 包 / 模块 CPU 占比（self 时间）")
        (list :kind 'heatmap :title "图表③ 用法热力图：命令 × 时间桶")))

;;; 数据快照

(defun el-chronos-dashboard--load-snapshot (range)
  "加载 RANGE 的数据快照 plist。
RANGE 接受字符串（\"1d\"）或符号（`1d'），**进查询前一律归一为符号**（见
`--range-symbol'）：analysis 层的范围键是符号，传字符串会被静默当成 7 天。
快照里的 `:range' 保留原始入参（显示用），`:range-symbol' 是归一后的符号（查询用）。
每个列表字段都过 `--cap-rows'（`el-chronos-dashboard-max-rows'）：`:sessions' /
`:trend' / `:heatmap' 没有行数上限，窗口一大就能把整表搬进内存。
分析层已把查询失败降级为 nil 并 `display-warning'，这里再包一层 `condition-case'
是双保险（I6：可视化出错不得向宿主抛错）。"
  (let ((symbol (el-chronos-dashboard--range-symbol range)))
    (condition-case error-object
        (list :range range :range-symbol symbol
              :loaded-at (truncate (* 1000 (float-time)))
              :overview (el-chronos-analysis-overview symbol)
              :slow (el-chronos-dashboard--cap-rows
                     (el-chronos-analysis-slow-commands symbol 60))
              :functions (el-chronos-dashboard--cap-rows
                          (el-chronos-analysis-top-functions symbol 60))
              :packages (el-chronos-dashboard--cap-rows
                         (el-chronos-analysis-package-breakdown symbol 12))
              :trend (el-chronos-dashboard--cap-rows (el-chronos-analysis-trend symbol))
              :heatmap (el-chronos-dashboard--cap-rows
                        (el-chronos-analysis-heatmap symbol 8))
              :blockers (el-chronos-dashboard--cap-rows
                         (el-chronos-analysis-blocking-events symbol 20))
              :regressions (el-chronos-dashboard--cap-rows
                            (el-chronos-analysis-regressions symbol 20))
              :sessions (el-chronos-dashboard--cap-rows
                         (el-chronos-analysis-sessions symbol)))
      (error (display-warning 'el-chronos
                              (format "可视化数据加载失败：%s" error-object) :warning)
             (list :range range :range-symbol symbol
                   :loaded-at (truncate (* 1000 (float-time))))))))

(defun el-chronos-dashboard--reload-snapshot (range)
  "丢弃旧快照后按 RANGE 重新加载（返回新快照并写进 `--snapshot'）。
先把全局置 nil 再查询：否则查询期间新旧两代快照同时存活，内存峰值翻倍
（重查询本身可能耗时数百毫秒，两代都被 profiler 采样扫到）。"
  (setq el-chronos-dashboard--snapshot nil)
  (setq el-chronos-dashboard--snapshot
        (el-chronos-dashboard--load-snapshot
         (or range (plist-get el-chronos-dashboard--state :range))))
  el-chronos-dashboard--snapshot)

;;; 概览卡片与状态栏

(defun el-chronos-dashboard--metric-pairs ()
  "返回 6 个概览指标的 `(LABEL . VALUE-TEXT)'，顺序固定用于 tile-grid 坐标映射。"
  (let ((overview (el-chronos-dashboard--snapshot-get :overview)))
    (cl-loop for (label kind key) in '(("命令" num :commands) ("阻塞" ms :blocked-ms)
                                      ("慢命令" num :slow-commands) ("采样" num :samples)
                                      ("数据库" bytes :db-size) ("启动" ms :startup-ms))
             collect (cons label (el-chronos-dashboard--fmt kind (plist-get overview key))))))

(defun el-chronos-dashboard--metric-text (row column)
  "tile-grid 的 `cell-text' / `cell-label' 回调：第 ROW 行第 COLUMN 列指标的单行文本。
必须单行且不超过 `:cell-width'（ETAF 会校验，超出直接报错），故用「名称 值」短格式并按
`--tile-cell-width' 截断——窄窗口下 cell-width 会变小，不截断就会抛 ETAF 校验错误。"
  (when-let* ((pair (nth (+ (* row 3) column) (el-chronos-dashboard--metric-pairs))))
    (el-chronos-dashboard--fit-text (format "%s %s" (car pair) (cdr pair))
                                    (el-chronos-dashboard--tile-cell-width))))

(defun el-chronos-dashboard--metric-image (row column)
  "tile-grid 的 `cell-image' 回调：图形 frame 下的 SVG 指标卡片。
非图形 frame 返回 nil，由 `:cell-text' 走文本路径（I11）。"
  (when (and (el-chronos-dashboard-etaf-available-p) (el-chronos-dashboard--graphic-p))
    (when-let* ((pair (nth (+ (* row 3) column) (el-chronos-dashboard--metric-pairs))))
      (etaf-ui-svg-image
       (concat (etaf-ui-svg-rect 0 0 190 52 :fill "#f4f7fb" :rx 4)
               (etaf-ui-svg-text 8 16 (car pair) :font-size 10 :fill "#667788")
               (etaf-ui-svg-text 8 38 (cdr pair) :font-size 16 :font-weight "bold"
                                 :fill "#223344"))
       190 52 '(0 0 190 52)))))

(defun el-chronos-dashboard--status-line ()
  "状态栏：时间范围、DB 大小、采集状态、采样间隔、最近更新时间。"
  (let ((loaded (el-chronos-dashboard--snapshot-get :loaded-at)))
    (format "范围 %d 天 · DB %s · 采集 %s · 采样间隔 %d ms · 更新 %s"
            (el-chronos-dashboard--range->days
             (or (plist-get el-chronos-dashboard--state :range)
                 el-chronos-dashboard--default-range))
            (el-chronos-dashboard--fmt 'bytes (el-chronos-analysis-db-size))
            (if (bound-and-true-p el-chronos--running-p) "运行中" "未运行")
            (round (/ (float el-chronos-sampling-interval-ns) 1000000.0))
            (if (numberp loaded)
                (format-time-string "%H:%M:%S" (/ (float loaded) 1000.0)) "-"))))

;;; 表格：列定义、行格式化、5 个区块

(defconst el-chronos-dashboard--columns
  ;; KIND（关键字，与快照键同名）→ ((数据键 列名 宽度 格式化) ...)
  ;; 数据键直接取分析层 plist 的键，`--cell' 用 `--fmt' 的 KIND 格式化。
  '((:slow (:name "命令" 30 str) (:total-ms "总耗时" 10 ms) (:count "次数" 7 num)
           (:aborted "中断" 6 num))
    (:functions (:function "函数" 32 str) (:package "包 / 模块" 18 str)
                (:self-ms "self 时间" 10 ms) (:pct "占比" 7 pct))
    (:blockers (:ts "时间" 13 time) (:duration-ms "时长" 10 ms) (:command "命令" 26 str)
               (:mode "mode" 16 str))
    (:regressions (:function "函数" 28 str) (:growth "增长" 8 pct)
                  (:current "当前窗口" 18 note) (:previous "前窗口" 18 note))
    (:sessions (:started-at "启动时间" 13 time) (:startup-ms "启动耗时" 10 ms)
               (:emacs-version "Emacs" 12 str) (:host "主机" 14 str)))
  "5 个表格区块的列定义；`note' 是复合列（两窗口对照），由 `--cell' 特判。")

(defun el-chronos-dashboard--cell (kind row key)
  "取 ROW（分析层 plist）在 KIND 表格 KEY 列的展示字符串。"
  (let ((fmt (lambda (k v) (el-chronos-dashboard--fmt k v))))
    (pcase key
      (:growth (funcall fmt 'pct (* 100.0 (or (plist-get row :growth) 0))))
      (:current (format "%s / %s 样本" (funcall fmt 'ms (plist-get row :current-ms))
                        (funcall fmt 'num (plist-get row :current-samples))))
      (:previous (format "%s / %s 样本" (funcall fmt 'ms (plist-get row :previous-ms))
                         (funcall fmt 'num (plist-get row :previous-samples))))
      (_ (funcall fmt (or (nth 3 (assq key (alist-get kind el-chronos-dashboard--columns)))
                          'str)
                  (plist-get row key))))))

;;; 卡片（数据行的呈现单位）

(defconst el-chronos-dashboard--card-primary
  '((:slow . :name) (:functions . :function) (:blockers . :command)
    (:regressions . :function) (:sessions . :started-at))
  "卡片首行（`:head'）显示的数据键：一律取**全文本**，不截断。
选「最需要看全的那个字段」：命令名 / 函数名 / 阻塞事件的命令；会话没有名字，用启动时间。")

(defun el-chronos-dashboard--card (kind row)
  "把 KIND 的第 ROW 行渲染成卡片描述：`:head' `:detail' `:key' `:source' `:kind'。
`:head' 是主键全文本，`:detail' 是其余字段的 `标签 值' 串联（全文本）。两者**都不经过**
`--fit-text'：数据文本一旦补 `…' 就再也读不到完整信息，可见性优先于整齐。"
  (let* ((columns (alist-get kind el-chronos-dashboard--columns))
         (cells (el-chronos-dashboard--row kind row))
         (value (lambda (key) (format "%s" (or (cdr (assq key cells)) "-"))))
         (head-key (or (alist-get kind el-chronos-dashboard--card-primary)
                       (nth 0 (nth 0 columns)))))
    (list :head (funcall value head-key)
          :detail (mapconcat (lambda (column)
                               (format "%s %s" (nth 1 column) (funcall value (nth 0 column))))
                             (cl-remove head-key columns :key #'car :test #'eq)
                             " · ")
          :key (cdr (assq :key cells))
          :source (cdr (assq :source cells))
          :kind kind)))

(defun el-chronos-dashboard--chart-width (&optional avail)
  "图表宽度（字符列）：声明的 `el-chronos-dashboard-chart-width' 与可用宽度取小。

图形 frame 下图是 `:columns' 个字符宽的 SVG image，文本终端下是等宽字符图，两者都占
`width' 列；上限取内容宽度减 2（图内左右留白），下限 20——再窄的窗口继续缩也读不出趋势，
剩下的交给 `--fit-text-block' 逐行截断。"
  (let* ((avail (or avail (el-chronos-dashboard--content-cells)))
         (cap (max 20 (- avail 2))))
    (min (max 20 (or el-chronos-dashboard-chart-width 72)) cap)))

(defun el-chronos-dashboard--tile-cell-width ()
  "概览 3 列 tile 的单元格宽度（字符）：不超过 24，且 3 列合计不超内容宽度。
`:cell-width' 由 ETAF 校验（正整数），单元格文本也必须 ≤ 它，故两边用同一函数取宽。"
  (max 8 (min 24 (floor (el-chronos-dashboard--content-cells) 3))))

(defun el-chronos-dashboard--dialog-width ()
  "下钻弹窗宽度（字符）：不超过 64，且不超内容宽度。"
  (max 24 (min 64 (el-chronos-dashboard--content-cells))))

(defun el-chronos-dashboard--row (kind row)
  "把分析层的 ROW 转成 KIND 表格行：alist（列 KEY → 展示串）+ `:key' + `:source'。"
  (cons (cons :source row)
        (append (list (cons :key (cond ((eq kind :slow) (el-chronos-dashboard--fmt
                                                        'str (plist-get row :name)))
                                       ((memq kind '(:functions :regressions))
                                        (el-chronos-dashboard--fmt
                                         'str (plist-get row :function)))
                                       (t (format "%s-%s" kind
                                                  (or (plist-get row :id) 0))))))
                (mapcar (lambda (column)
                          (cons (car column) (el-chronos-dashboard--cell kind row (car column))))
                        (alist-get kind el-chronos-dashboard--columns)))))

(defconst el-chronos-dashboard--sections
  '((:slow "慢命令 TOP" t) (:functions "热点函数 TOP（含包归属）" t)
    (:blockers "阻塞事件（命令外卡顿）" nil)
    (:regressions "回归（近 7 天 vs 前 7 天）" nil)
    (:sessions "会话与启动耗时" nil))
  "5 个表格区块：(KIND 标题 是否分页)。")

(defun el-chronos-dashboard--cap-rows (rows)
  "把 ROWS 截到 `el-chronos-dashboard-max-rows' 行以内；nil / 短列表原样返回。
快照层的上限：挡无界查询（`:sessions' 无行数上限）把整张表搬进内存。"
  (let ((limit (max 1 (or el-chronos-dashboard-max-rows 200))))
    (cond ((null rows) nil)
          ((<= (length rows) limit) rows)
          (t (cl-subseq rows 0 limit)))))

(defun el-chronos-dashboard--render-rows (rows paged page size)
  "取本次渲染要交给 ETAF 的 ROWS：分页表取第 PAGE 页，不分页表只取前 SIZE 行。
**必须在构造行描述（`--row'）之前就截断**：先全量构造再截断会让整表都进过一次
内存（实测 2100 行会话表 → 每次渲染多保留约 61 万 cons，见 docs/ui.org）。"
  (let ((size (max 1 (or size 1))))
    (if paged
        (el-chronos-dashboard--page-slice rows page size)
      (when (and rows (> (length rows) 0))
        (cl-subseq rows 0 (min (length rows) size))))))

(defun el-chronos-dashboard--table-title (title rows paged page size)
  "表格标题：分页表带页码，不分页表在超出行数上限时注明已加载条数与截断。
用「已加载」而非「共」：快照本身受 `el-chronos-dashboard-max-rows' 约束，屏幕上的总数
不等于库里的总数，标题不谎称全量。"
  (let ((size (max 1 (or size 1)))
        (total (length (or rows nil))))
    (cond (paged (format "%s（第 %d/%d 页）" title (1+ (max 0 page))
                         (el-chronos-dashboard--page-count rows size)))
          ((> total size) (format "%s（已加载 %d 条，显示前 %d 条）" title total size))
          (t title))))

(defun el-chronos-dashboard--tables (page)
  "按 PAGE 生成 5 个区块的渲染描述：标题（分页表带页码）、列定义、行、`--row' 行描述、卡片。
每个区块交给 ETAF 的行数都不超过 `el-chronos-dashboard-page-size'（见 `--render-rows'）。
`:cards' 是实际渲染单位（见 `--card'）：数据文本不截断，故不再用 `etaf-table'，也不再
按窗口宽度压缩列宽（表格的定宽 `…' 截断与 `:overflow hidden' 都与「不截断」冲突）。"
  (let ((size el-chronos-dashboard-page-size))
    (mapcar (lambda (section)
              (let* ((kind (nth 0 section))
                     (all (or (el-chronos-dashboard--snapshot-get kind) nil))
                     (paged (nth 2 section))
                     (rows (el-chronos-dashboard--render-rows all paged page size)))
                (list :title (el-chronos-dashboard--table-title
                              (nth 1 section) all paged page size)
                      :columns (mapcar (lambda (column)
                                         (list :key (nth 0 column) :label (nth 1 column)
                                               :width (nth 2 column)))
                                       (alist-get kind el-chronos-dashboard--columns))
                      :rows (mapcar (lambda (row) (el-chronos-dashboard--row kind row)) rows)
                      :cards (mapcar (lambda (row) (el-chronos-dashboard--card kind row)) rows)
                      :on-press (lambda (row) (el-chronos-dashboard--drill kind row)))))
            el-chronos-dashboard--sections)))

;;; 下钻：选中项 → `etaf-dialog' 详情

(defun el-chronos-dashboard--suggestions (kind source)
  "按 KIND（`slow' / `functions'）与 SOURCE 给出优化建议文本。"
  (let ((tips nil))
    (pcase kind
      (:slow (let ((avg (or (plist-get source :avg-ms) 0))
                   (aborted (or (plist-get source :aborted) 0))
                   (count (or (plist-get source :count) 0)))
               (when (> (float avg) el-chronos-slow-command-threshold-ms)
                 (push "单次平均耗时高于慢命令阈值：考虑异步化、缓存或减少重复计算。" tips))
               (when (> aborted 0)
                 (push "存在 C-g 中断：该命令有可感知的长阻塞，优先拆分。" tips))
               (when (and (> count 50) (<= (float avg) el-chronos-slow-command-threshold-ms))
                 (push "高频但单次不慢：收益来自调用次数（合并调用 / 延迟执行）。" tips))))
      (:functions (when (> (float (or (plist-get source :pct) 0)) 20.0)
                    (push "单函数 self 占比超过 20%：热点集中，先看该函数的算法复杂度。" tips))))
    (or (mapconcat (lambda (tip) (concat "- " tip)) (nreverse tips) "\n") "- 暂无建议")))

(defun el-chronos-dashboard--lines (title pairs)
  "拼出下钻详情文本：TITLE 一行 + PAIRS（`(LABEL . VALUE)'）逐行。"
  (concat title "\n"
          (mapconcat (lambda (pair) (format "%s：%s" (car pair) (cdr pair))) pairs "\n")))

(defconst el-chronos-dashboard--detail-specs
  ;; kind → (标题格式 标题取值的键 ((标签 格式化 KEY) ...))
  '((:slow "命令 %s" :name (("总耗时" ms :total-ms) ("调用次数" num :count)
                           ("最大单次" ms :max-ms) ("平均单次" ms :avg-ms)
                           ("中断次数" num :aborted)))
    (:functions "函数 %s" :function (("包 / 模块" str :package) ("源码文件" str :file)
                                    ("self 时间" ms :self-ms) ("样本数" num :samples)
                                    ("占比" pct :pct)))
    (:regressions "回归 %s" :function (("增长率" pct :growth-pct)
                                      ("当前窗口 self" ms :current-ms)
                                      ("前窗口 self" ms :previous-ms)
                                      ("当前样本" num :current-samples)
                                      ("前样本" num :previous-samples)))
    (:sessions "会话 #%s" :id (("启动时间" time :started-at) ("启动耗时" ms :startup-ms)
                              ("Emacs" str :emacs-version) ("主机" str :host))))
  "4 类下钻详情的字段表；`:growth-pct' 是 `:growth' 的百分数视图，由 `--drill' 特判。")

(defun el-chronos-dashboard--drill (kind row)
  "下钻 KIND 表格的 ROW：把详情写进 UI 状态并重绘（详情弹窗由 `:selected' 驱动）。"
  (let* ((source (or (alist-get :source row) row))
         (spec (alist-get kind el-chronos-dashboard--detail-specs))
         (fmt (lambda (k key)
                (if (eq key :growth-pct)
                    (el-chronos-dashboard--fmt
                     'pct (* 100.0 (or (plist-get source :growth) 0)))
                  (el-chronos-dashboard--fmt k (plist-get source key))))))
    (el-chronos-dashboard--select
     (if (eq kind :blockers)
         (el-chronos-dashboard--blocker-detail source)
       (list :title (format (nth 0 spec)
                            (el-chronos-dashboard--fmt 'str (plist-get source (nth 1 spec))))
             :body (el-chronos-dashboard--lines
                    "详情"
                    (mapcar (lambda (item) (cons (nth 0 item) (funcall fmt (nth 1 item)
                                                                      (nth 2 item))))
                            (nth 2 spec)))
             :tips (el-chronos-dashboard--suggestions kind source))))))

(defun el-chronos-dashboard--blocker-detail (source)
  "阻塞事件的下钻详情：事件字段 + 栈样本 + context，并记下 `:event-id' 供 `d' 键使用。"
  (let* ((id (plist-get source :id))
         (event (and (numberp id) (el-chronos-analysis-event id)))
         (stack (plist-get event :stack))
         (context (plist-get event :context))
         (fmt (lambda (k key) (el-chronos-dashboard--fmt k (plist-get source key)))))
    (list :event-id id
          :title (format "阻塞事件 #%s" (funcall fmt 'num :id))
          :body (concat
                 (el-chronos-dashboard--lines
                  "事件"
                  (list (cons "时间" (funcall fmt 'time :ts))
                        (cons "时长" (funcall fmt 'ms :duration-ms))
                        (cons "命令" (funcall fmt 'str :command))
                        (cons "mode" (funcall fmt 'str :mode))
                        (cons "project" (funcall fmt 'str :project))))
                 "\n\n栈样本（自 leaf 起，前 8 帧）\n"
                 (if stack
                     (mapconcat (lambda (frame) (el-chronos-dashboard--fmt 'str frame))
                                (cl-subseq stack 0 (min 8 (length stack))) "\n")
                   el-chronos-dashboard--empty)
                 "\n\ncontext\n"
                 (if context
                     (mapconcat (lambda (pair)
                                  (format "- %s：%s" (substring (symbol-name (car pair)) 1)
                                          (el-chronos-dashboard--fmt 'str (cdr pair))))
                                (cl-loop for (key value) on context by #'cddr
                                         collect (cons key value))
                                "\n")
                   el-chronos-dashboard--empty))
          :tips (format "按 `d' 在 `*el-chronos-event*' 查看完整栈（事件 #%s）。"
                        (funcall fmt 'num :id)))))

(defun el-chronos-dashboard--select (selection)
  "记录下钻选中项 SELECTION 并重绘（弹窗由组件的 `:selected' 属性驱动）。"
  (el-chronos-dashboard--ensure-state nil)
  (setq el-chronos-dashboard--state (plist-put el-chronos-dashboard--state
                                               :selected selection))
  (el-chronos-dashboard--refresh))

(defun el-chronos-dashboard--clear-selection ()
  "关闭下钻弹窗（`etaf-dialog' 的 `:on-close' 回调）。"
  (el-chronos-dashboard--select nil))

;;; ETAF 组件（延迟定义，见 Commentary）

(defconst el-chronos-dashboard--component-forms
  '(;; 数据卡片：主键一行 + 其余字段一行，均按窗口宽度自动折行（数据文本不截断）
    (etaf-define-component el-chronos-dashboard-card (&key head detail press)
      "把一条数据记录渲染成卡片：HEAD 加粗、DETAIL 次要色，两者都 `wrap-mode word' 折行。
不用 `etaf-table' 承载数据行：表格单元格固定为 `:overflow hidden' + `:wrap-mode none'，
整数列宽还会被 `truncate-string-to-width' 补 `…'，数据文本必然显示不全（依据与实测见
`docs/ui.org'「不截断策略」）。"
      :view
      (column :class "el-chronos-card"
              :width 'stretch :item-gap '(lh 0) :wrap-mode 'word
              :on-press press
              :padding '((lh 0) (ch 1))
              :border-bottom-width '(px 1) :border-bottom-style 'solid
              :border-bottom-color (etaf-theme-value :ui-table-border "#687386")
        (box :width 'stretch :wrap-mode 'word :font-weight 'bold
             (text (expr head)))
        (box :width 'stretch :wrap-mode 'word
             :color (etaf-theme-value :ui-muted-fg "#526174")
             (text (expr detail)))))
    ;; 图表组件：图形 frame → SVG image；terminal → 文本字符图（I11）
    (etaf-define-component el-chronos-dashboard-chart (&key kind rows width height)
      "把一个图表 KIND 渲染成 SVG image（图形 frame）或文本字符图（terminal frame）。"
      :render
      (let* ((graphic (el-chronos-dashboard--graphic-p))
             (width (or width (el-chronos-dashboard--chart-width)))
             (height (or height el-chronos-dashboard--chart-height)))
        (if graphic
            (etaf-view
             (image :src (etaf-ui-svg-image
                          (pcase kind
                            ('trend (el-chronos-dashboard--trend-body rows width height))
                            ('bars (el-chronos-dashboard--bar-chart rows width height))
                            ('heatmap (el-chronos-dashboard--heatmap rows width height))
                            (_ ""))
                          (* width 8) (* height 18) (list 0 0 width height))
                    :columns width :rows height))
          (etaf-view
           ;; text Host 里的非字面量必须写成 `(expr FORM)'，否则 ETAF 报 DSL 语法错；
           ;; 文本图超宽会被 ETAF 折行（一张图拆成两行），故按内容宽度重算条形宽度再截断
           (text (expr (el-chronos-dashboard--fit-text-chart
                        kind rows (el-chronos-dashboard--content-cells))))))))
    ;; 根组件：:bindings 持有 range / page / selected 三项 UI 状态
    (etaf-define-component el-chronos-dashboard-app (&key (range "7d") (page 0) (selected nil))
      "el-chronos 页面根组件：顶栏 + 概览 + 图表 + 5 组数据卡片 + 下钻弹窗。"
      :setup (let ((palette (el-chronos-dashboard--theme-palette)))
               (when palette (etaf-theme-provide palette)))
      :bindings ((range-state (etaf-ref range)) (page-state (etaf-ref page))
                 (selected-state (etaf-ref selected)))
      :view
      (column :class "el-chronos-dashboard" :width 'stretch :item-gap '(lh 1)
              ;; 主题色取自 `default' face：`:background-color' 由 ebox 的
              ;; `ebox--sync-canvas' 同步到 buffer 的 `default' face 背景（面板之外的行尾
              ;; 空白不再露出宿主底色），`:color' 沿子树继承给所有文字。
              :background-color (el-chronos-dashboard--theme-background)
              :color (el-chronos-dashboard--theme-foreground)
        (etaf-panel :title "el-chronos · 性能与用法观测器"
          (row :class "el-chronos-toolbar"
            (etaf-button :label "1 天" :variant 'primary
                         :on-press #'el-chronos-dashboard-range-1d)
            (etaf-button :label "7 天" :on-press #'el-chronos-dashboard-range-7d)
            (etaf-button :label "30 天" :on-press #'el-chronos-dashboard-range-30d)
            (etaf-button :label "刷新" :variant 'ghost
                         :on-press #'el-chronos-dashboard-refresh)
            (etaf-button :label "上一页" :variant 'ghost
                         :on-press #'el-chronos-dashboard-previous-page)
            (etaf-button :label "下一页" :variant 'ghost
                         :on-press #'el-chronos-dashboard-next-page))
          (etaf-label :text (el-chronos-dashboard--status-line) :variant 'muted))
        (etaf-panel :title "概览（6 指标）"
          (etaf-tile-grid :rows 2 :columns 3
                          ;; cell-width 必须随窗口收窄：3 × 24 = 72 列在 60 列窗口里会溢出并折行
                          :cell-width (el-chronos-dashboard--tile-cell-width)
                          :cell-height 3
                          :cell-text #'el-chronos-dashboard--metric-text
                          :cell-label #'el-chronos-dashboard--metric-text
                          :cell-image #'el-chronos-dashboard--metric-image))
        (etaf-panel :title "图表"
          (expr (mapcar
                 (lambda (spec)
                   (etaf-view
                    (column :class "el-chronos-chart-block"
                      (etaf-label :text (plist-get spec :title) :variant 'strong)
                      (el-chronos-dashboard-chart
                       :kind (plist-get spec :kind)
                       :rows (el-chronos-dashboard--chart-rows (plist-get spec :kind))
                       :width (el-chronos-dashboard--chart-width)
                       :height el-chronos-dashboard--chart-height))))
                 (el-chronos-dashboard--chart-specs))))
        (expr (mapcar
               (lambda (spec)
                 (etaf-view
                  (etaf-panel :title (plist-get spec :title)
                    (expr (mapcar
                           (lambda (card)
                             (etaf-view
                              (el-chronos-dashboard-card
                               :head (plist-get card :head)
                               :detail (plist-get card :detail)
                               :press (lambda ()
                                        (el-chronos-dashboard--drill
                                         (plist-get card :kind)
                                         (plist-get card :source))))))
                           (plist-get spec :cards)))
                    (expr (unless (plist-get spec :cards)
                            (etaf-view (etaf-label :text "（无数据）"
                                                   :variant 'muted)))))))
               (el-chronos-dashboard--tables (etaf-value page-state))))
        (etaf-dialog :open (etaf-value selected-state)
                     :title (or (plist-get (etaf-value selected-state) :title) "详情")
                     :width (list 'ch (el-chronos-dashboard--dialog-width))
                     :on-close #'el-chronos-dashboard--clear-selection
          (text (expr (or (plist-get (etaf-value selected-state) :body) "")))
          (etaf-label :text (or (plist-get (etaf-value selected-state) :tips) "")
                      :variant 'muted)))))
  "ETAF 组件定义式；由 `--define-components' 在 ETAF 可用时 `eval'。
不放成顶层形式是为了让字节编译在 ETAF 缺席时不去展开 `etaf-define-component' /
`etaf-view'（宏缺席会被编成普通函数调用）。")

(defun el-chronos-dashboard--define-components ()
  "在 ETAF 可用时定义（且仅定义一次）页面组件。"
  (when (and (el-chronos-dashboard-etaf-available-p)
             (not el-chronos-dashboard--components-defined-p))
    (dolist (form el-chronos-dashboard--component-forms) (eval form t))
    (setq el-chronos-dashboard--components-defined-p t)))

;;; 状态、挂载与快捷键

(defun el-chronos-dashboard--ensure-state (range)
  "确保 UI 状态存在：RANGE 覆盖时间范围，其余字段补齐。
`:range' 一律归一为规范字符串（`--range-string'）：状态只服务显示，
`(el-chronos-dashboard \"1d\")' 这类调用即便传符号 `1d' 也不会让状态与按钮不一致；
真正下给 analysis 的符号由 `--load-snapshot' 统一转换。"
  (setq el-chronos-dashboard--state
        (list :range (el-chronos-dashboard--range-string
                      (or range (plist-get el-chronos-dashboard--state :range)
                          el-chronos-dashboard--default-range))
              :page (or (plist-get el-chronos-dashboard--state :page) 0)
              :selected (plist-get el-chronos-dashboard--state :selected)))
  el-chronos-dashboard--state)

(defun el-chronos-dashboard--install-keys (buffer)
  "在 BUFFER 上装页面快捷键（`1'/`7'/`3'、`g'、`r'、`d'、`q'）。"
  (with-current-buffer buffer
    (local-set-key (kbd "1") #'el-chronos-dashboard-range-1d)
    (local-set-key (kbd "7") #'el-chronos-dashboard-range-7d)
    (local-set-key (kbd "3") #'el-chronos-dashboard-range-30d)
    (local-set-key (kbd "g") #'el-chronos-dashboard-refresh)
    (local-set-key (kbd "r") #'el-chronos-dashboard-toggle-auto-refresh)
    (local-set-key (kbd "d") #'el-chronos-dashboard-show-event)
    (local-set-key (kbd "q") #'el-chronos-dashboard-quit)))

(defun el-chronos-dashboard--render-etaf (range)
  "用 RANGE 的数据把 ETAF 页面挂载到 `--buffer-name'，返回该 buffer。
挂载形式走 `eval'：`etaf-view' 是宏，`make lint' 在 ETAF 缺席时无法展开它。
挂载前先卸载已有 runtime：ETAF 会保留已挂载实例的 `:bindings'（如 `selected-state'），
不卸载就重挂会让弹窗与状态栏停在旧值上。"
  (el-chronos-dashboard--define-components)
  (el-chronos-dashboard--ensure-state range)
  (el-chronos-dashboard--reload-snapshot range)
  (let* ((state el-chronos-dashboard--state)
         (buffer (get-buffer-create el-chronos-dashboard--buffer-name)))
    (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
    (etaf-mount buffer
                (eval `(etaf-view (el-chronos-dashboard-app
                                   :range ,(plist-get state :range)
                                   :page ,(plist-get state :page)
                                   ;; 选中项是 plist：必须包成 `(quote ...)'，否则
                                   ;; ETAF 会把列表当代码求值（`void-function :title'）
                                   :selected (quote ,(plist-get state :selected))))
                      t))
    (el-chronos-dashboard--apply-theme-canvas buffer)
    (el-chronos-dashboard--install-keys buffer)
    buffer))

;;; 降级页（tabulated-list，I9 / I11）

(defun el-chronos-dashboard--degraded-entries ()
  "生成降级页条目：慢命令区块 + 热点函数区块，各带一行区块标题。
`tabulated-list-mode' 一个 buffer 只支持一张表，故用区块标题行把两张表放进同一张
tabulated-list（标题行也是条目），保证 `*el-chronos*' 仍是 tabulated-list-mode 且两张表
都在（T8a 的最小能力集）。空库时每个区块保留一行 `（无数据）'。"
  (let ((entries nil))
    (dolist (section (list (list :functions el-chronos-dashboard--section-functions "占比"
                                 (lambda (row)
                                   (format "%s · %s"
                                           (el-chronos-dashboard--fmt
                                            'str (plist-get row :package))
                                           (el-chronos-dashboard--fmt
                                            'ms (plist-get row :self-ms))))
                                 (lambda (row) (el-chronos-dashboard--fmt
                                                'pct (plist-get row :pct)))
                                 :function)
                         (list :slow el-chronos-dashboard--section-slow "总耗时"
                               (lambda (row)
                                 (format "%s 次 / 中断 %s"
                                         (el-chronos-dashboard--fmt
                                          'num (plist-get row :count))
                                         (el-chronos-dashboard--fmt
                                          'num (plist-get row :aborted))))
                               (lambda (row) (el-chronos-dashboard--fmt
                                              'ms (plist-get row :total-ms)))
                               :name)))
      (let* ((kind (nth 0 section)) (title (nth 1 section))
             (rows (el-chronos-dashboard--snapshot-get kind)))
        (push (list (format "%s-header" kind) (vector title (nth 2 section) "明细" ""))
              entries)
        (if rows
            (dolist (row rows)
              (push (list (format "%s-%s" kind (plist-get row (nth 5 section)))
                          (vector title
                                  (el-chronos-dashboard--fmt
                                   'str (plist-get row (nth 5 section)))
                                  (funcall (nth 4 section) row)
                                  (funcall (nth 3 section) row)))
                    entries))
          (push (list (format "%s-empty" kind) (vector title el-chronos-dashboard--empty
                                                       "" ""))
                entries))))
    (nreverse entries)))

(defun el-chronos-dashboard--render-fallback (range)
  "用 RANGE 渲染 tabulated-list 降级页，返回 `--buffer-name' buffer。"
  (el-chronos-dashboard--ensure-state range)
  (el-chronos-dashboard--reload-snapshot range)
  (let ((buffer (get-buffer-create el-chronos-dashboard--buffer-name)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (tabulated-list-mode)
        (setq-local tabulated-list-format el-chronos-dashboard--degraded-format)
        (setq-local tabulated-list-entries (el-chronos-dashboard--degraded-entries))
        (setq-local tabulated-list-sort-key nil)
        (tabulated-list-init-header)
        (tabulated-list-print t))
      (setq header-line-format
            (format " el-chronos · ETAF 未安装（降级页）· 范围 %d 天 · 1/7/3 切范围 · g 刷新 · q 关闭"
                    (el-chronos-dashboard--range->days
                     (plist-get el-chronos-dashboard--state :range))))
      (el-chronos-dashboard--install-keys buffer))
    buffer))

;;; 命令

(defun el-chronos-dashboard--refresh ()
  "重绘当前形态（ETAF 或降级）的页面，返回页面 buffer。
渲染属慢路径（快照查询 + ETAF 组件定义 + 挂载），期间抑制采集层的阻塞判定，避免观测者
把自身渲染记成 `block' 事件（见 `el-chronos-dashboard--without-block-events'）。"
  (el-chronos-dashboard--without-block-events
    (let ((range (or (plist-get el-chronos-dashboard--state :range)
                     el-chronos-dashboard--default-range)))
      (if (el-chronos-dashboard-etaf-available-p)
          (el-chronos-dashboard--render-etaf range)
        (el-chronos-dashboard--render-fallback range)))))

(defun el-chronos-dashboard-refresh ()
  "刷新 `*el-chronos*' 页面（快捷键 `g'），返回页面 buffer。"
  (interactive)
  (let ((range (or (plist-get el-chronos-dashboard--state :range)
                   el-chronos-dashboard--default-range)))
    (prog1 (el-chronos-dashboard--refresh)
      (when (called-interactively-p 'any)
        (message "el-chronos：已刷新（范围 %d 天）"
                 (el-chronos-dashboard--range->days range))))))

(defun el-chronos-dashboard--set-range (range)
  "把时间范围切到 RANGE 并重绘：页码归零、关闭下钻弹窗。"
  (el-chronos-dashboard--ensure-state range)
  (setq el-chronos-dashboard--state
        (plist-put (plist-put el-chronos-dashboard--state :page 0) :selected nil))
  (el-chronos-dashboard--refresh))

(defun el-chronos-dashboard-range-1d ()
  "切到最近 1 天（快捷键 `1'）。" (interactive)
  (el-chronos-dashboard--set-range "1d") (message "el-chronos：范围 1 天"))

(defun el-chronos-dashboard-range-7d ()
  "切到最近 7 天（快捷键 `7'）。" (interactive)
  (el-chronos-dashboard--set-range "7d") (message "el-chronos：范围 7 天"))

(defun el-chronos-dashboard-range-30d ()
  "切到最近 30 天（快捷键 `3'）。" (interactive)
  (el-chronos-dashboard--set-range "30d") (message "el-chronos：范围 30 天"))

(defun el-chronos-dashboard--set-page (page)
  "把表格页码设为 PAGE（夹到 [0, 总页数-1]）并重绘。"
  (let ((size el-chronos-dashboard-page-size))
    (el-chronos-dashboard--ensure-state nil)
    (setq el-chronos-dashboard--state
          (plist-put el-chronos-dashboard--state :page
                     (max 0 (min (1- (max (el-chronos-dashboard--page-count
                                           (el-chronos-dashboard--snapshot-get :slow) size)
                                          (el-chronos-dashboard--page-count
                                           (el-chronos-dashboard--snapshot-get
                                            :functions) size)))
                                 (or page 0)))))
    (el-chronos-dashboard--refresh)))

(defun el-chronos-dashboard-next-page ()
  "翻到下一页（表格分页）。" (interactive)
  (el-chronos-dashboard--set-page (1+ (or (plist-get el-chronos-dashboard--state :page) 0))))

(defun el-chronos-dashboard-previous-page ()
  "翻到上一页（表格分页）。" (interactive)
  (el-chronos-dashboard--set-page (1- (or (plist-get el-chronos-dashboard--state :page) 0))))

(defun el-chronos-dashboard-show-event ()
  "在 `*el-chronos-event*' 看当前下钻选中的阻塞事件完整栈（快捷键 `d'）。"
  (interactive)
  (let ((id (plist-get (plist-get el-chronos-dashboard--state :selected) :event-id)))
    (if (numberp id)
        (el-chronos-show-event id)
      (user-error "当前选中项不是阻塞事件（先在阻塞事件表里选一行）"))))

(defun el-chronos-dashboard-toggle-auto-refresh ()
  "切换自动刷新（快捷键 `r'）：每 `el-chronos-dashboard-refresh-seconds' 秒重绘。"
  (interactive)
  (if (timerp el-chronos-dashboard--refresh-timer)
      (progn (cancel-timer el-chronos-dashboard--refresh-timer)
             (setq el-chronos-dashboard--refresh-timer nil)
             (message "el-chronos：自动刷新已关闭"))
    (setq el-chronos-dashboard--refresh-timer
          (run-at-time el-chronos-dashboard-refresh-seconds
                       el-chronos-dashboard-refresh-seconds
                       #'el-chronos-dashboard--auto-refresh))
    (message "el-chronos：自动刷新每 %d 秒" el-chronos-dashboard-refresh-seconds)))

(defun el-chronos-dashboard--auto-refresh ()
  "自动刷新 tick；页面 buffer 已消失时自动关掉 timer（零残留）。"
  (if (not (get-buffer el-chronos-dashboard--buffer-name))
      (progn (when (timerp el-chronos-dashboard--refresh-timer)
               (cancel-timer el-chronos-dashboard--refresh-timer))
             (setq el-chronos-dashboard--refresh-timer nil))
    (condition-case error-object (el-chronos-dashboard--refresh)
      (error (display-warning 'el-chronos
                              (format "el-chronos 自动刷新失败：%s" error-object)
                              :warning)))))

(defun el-chronos-dashboard-quit ()
  "关闭 `*el-chronos*'（快捷键 `q'）：取消自动刷新并退出窗口。"
  (interactive)
  (when (timerp el-chronos-dashboard--refresh-timer)
    (cancel-timer el-chronos-dashboard--refresh-timer)
    (setq el-chronos-dashboard--refresh-timer nil))
  (quit-window))

;;;###autoload
(defun el-chronos-dashboard (&optional range)
  "打开（或刷新）Emacs 内可视化页面 `*el-chronos*'，返回页面 buffer。
RANGE 取 \"1d\" / \"7d\" / \"30d\"（字符串或对应符号 `1d' / `7d' / `30d' 均可），
省略时沿用上次范围（默认 \"7d\"）；非法值按 \"7d\"。
UI 状态与显示用字符串，下给 analysis 的查询一律转成符号（见 `--range-symbol'）。

形态选择（I9 / I11）：ETAF 可用 → ETAF 页面（组件树 + SVG 图表 + 表格 + 下钻，图形
frame 用 SVG、terminal frame 用文本字符图）；ETAF 不可用 → `display-warning' 提示安装
并降级到 tabulated-list 简版页面，不抛错。

渲染是慢路径（首次渲染含 ETAF 组件定义与快照查询，实测约 2.8s），整段套
`el-chronos-dashboard--without-block-events'，避免这次自身耗时被心跳记成 `block' 事件。"
  (interactive)
  (el-chronos-dashboard--without-block-events
    (let ((buffer
           (if (el-chronos-dashboard-etaf-available-p)
               (el-chronos-dashboard--render-etaf range)
             (display-warning
              'el-chronos
              (concat "ETAF 不可用，el-chronos 已降级为 tabulated-list 简版页面"
                      "（慢命令 + 热点函数两张表、1/7/3 切时间范围）。"
                      "安装后可用完整页面：straight recipe 见 thomas-emacs 的 lisp/init-etaf.el"
                      "（需 ecss / ebox / etaf / etaf-ui 四个包，编译期顺序不可乱）。")
              :warning)
             (el-chronos-dashboard--render-fallback range))))
      (unless noninteractive (display-buffer buffer))
      buffer)))

(provide 'el-chronos-dashboard)

;;; el-chronos-dashboard.el ends here
