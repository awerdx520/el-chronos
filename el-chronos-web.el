;;; el-chronos-web.el --- 内嵌 Web dashboard  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Thomas

;; Author: Thomas
;; Keywords: tools, performance
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; Web 可视化层：用内置 `make-network-process' 自写最小 HTTP server，把
;; `el-chronos-analysis' 的纯数据以 JSON 暴露给同源单页 dashboard（HTML / CSS / JS 全部以
;; elisp 字符串内嵌，不引第三方库与 CDN，离线可用）。
;;
;; 入口：`el-chronos-web-start' / `el-chronos-web-stop' / `el-chronos-web-running-p'。
;;
;; 边界（I8）：只绑 127.0.0.1（硬编码，不接受 0.0.0.0），默认端口 `el-chronos-web-port'；
;; 端口占用直接 `user-error' 且**不自动换端口**；只提供 GET 只读接口，无写入路由、无鉴权
;; （loopback 只防 LAN 暴露，WSL2 mirrored 网络下 Windows 侧进程可达，不构成本机访问控制）。
;;
;; 降级（I11）：端口占用 → 明确 `user-error'；单请求处理异常 → 返回 500（响应体只有通用
;; 文案，内部错误经 `display-warning' 落到 Emacs 侧，不回显给浏览器）且 server 继续服务；
;; analysis 返回 nil（数据库打不开/查询失败）→ 相应区块为空数组或 null，页面显示「无数据」。
;;
;; 请求处理模型：单 server 进程 + 每请求一条短连接。`:filter' 回调按连接累积字节，凑到
;; `\r\n\r\n' 后解析请求行并一次性响应，响应带 `Connection: close' 后发 EOF 关闭，因此
;; 不需要 keep-alive / 分块传输 / 长连接超时管理。单请求累积上限
;; `el-chronos-web--max-request-bytes'（超出返回 413），防止畸形请求无限占内存；请求处理在
;; Emacs 主线程同步执行，因此响应时间 = 查询时间（毫秒级，SQLite 本地读取）。
;;
;; 只读约束：本模块不写数据库、不改采集行为，路由表里没有任何写入/执行入口。

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'json)
(require 'url-util)
(require 'el-chronos)
(require 'el-chronos-analysis)

;;; 常量

(defconst el-chronos-web--host "127.0.0.1"
  "监听地址；硬编码 loopback（I8），不从 defcustom 接受 0.0.0.0。")

(defconst el-chronos-web--process-name "el-chronos-web"
  "HTTP server 进程名。")

(defconst el-chronos-web--max-request-bytes 16384
  "单请求累积字节上限；超出返回 413，避免畸形请求无限占内存。")

(defconst el-chronos-web--default-range '7d
  "未指定或非法 range 参数时的默认时间范围（符号，与 analysis 的映射一致）。")

(defconst el-chronos-web--ranges '(1d 7d 30d)
  "合法的 range 取值（符号）。")

(defconst el-chronos-web--default-limit 20
  "列表类接口的默认 limit。")

(defconst el-chronos-web--max-limit 1000
  "limit 参数上限，防止单次响应过大。")

(defconst el-chronos-web--config-history-sessions 50
  "`/api/config-history' 最多返回的会话数（取最近的 N 个，输出仍按启动时间升序）。
限流的理由：会话行随每次重启单调增长（每次启动一行），30d 窗口在频繁重启的机器上可达
数千行；Web 是单线程同步处理、浏览器还要一次性渲染整张表，全量返回会让主线程查询与渲染
时间一起变长。analysis 层不限条数（org 报告与 CSV 导出需要完整序列），因此限流只做在
Web 的 JSON 接口上，CSV 导出（`/api/export.csv'）保持完整序列。")

(defconst el-chronos-web--startup-load-rows 10
  "CSV 里「启动分解」包加载 TOP 最多输出的条数。
与 `el-chronos-report--startup-load-rows' 取值一致 —— 两处是**内联重复实现**
（本模块不 require report），改一处必须同步另一处。")

(defconst el-chronos-web--json-type "application/json; charset=utf-8"
  "JSON 响应的 Content-Type。")

(defconst el-chronos-web--html-type "text/html; charset=utf-8"
  "HTML 响应的 Content-Type。")

(defconst el-chronos-web--text-type "text/plain; charset=utf-8"
  "纯文本响应的 Content-Type。")

(defconst el-chronos-web--csv-type "text/csv; charset=utf-8"
  "CSV 响应的 Content-Type。")

;;; 状态

(defvar el-chronos-web--process nil
  "当前 HTTP server 进程；nil 表示未启动。")

(defvar el-chronos-web--pending (make-hash-table :test #'eq)
  "客户端进程 → 已累积但尚未凑齐请求头的字节串。")

;;; 通用工具

(defun el-chronos-web--now-ms ()
  "当前 epoch 毫秒（整数）。"
  (truncate (* 1000 (float-time))))

(defun el-chronos-web--html-escape (text)
  "把 TEXT 转义成可安全嵌入 HTML 的字符串。"
  (let ((s (format "%s" (or text ""))))
    (setq s (replace-regexp-in-string "&" "&amp;" s t t))
    (setq s (replace-regexp-in-string "<" "&lt;" s t t))
    (setq s (replace-regexp-in-string ">" "&gt;" s t t))
    (replace-regexp-in-string "\"" "&quot;" s t t)))

(defun el-chronos-web--json-value (value)
  "把 VALUE 递归转成 `json-serialize' 友好形态。
nil 转 `:null'（否则会输出 `{}'），列表转 vector（否则会被当成 alist），plist 保持 plist。
与 `el-chronos-report--json-value' 同口径，保证 JSON 导出与 Web API 的键形态一致。"
  (cond
   ((null value) :null)
   ((eq value t) t)
   ((vectorp value) (vconcat (mapcar #'el-chronos-web--json-value value)))
   ((consp value)
    (if (keywordp (car value))
        (cl-loop for (key item) on value by #'cddr
                 append (list key (el-chronos-web--json-value item)))
      (vconcat (mapcar #'el-chronos-web--json-value value))))
   (t value)))

(defun el-chronos-web--json-body (value)
  "把 VALUE 序列化成 JSON 文本（带结尾换行）。"
  (concat (json-serialize (el-chronos-web--json-value value)) "\n"))

(defun el-chronos-web--response (status type body &optional headers)
  "构造响应 plist：STATUS 状态行文本、TYPE Content-Type、BODY 响应体、HEADERS 附加头。"
  (list :status status :type type :body (or body "") :headers (or headers "")))

(defun el-chronos-web--json-response (value)
  "把 VALUE 序列化为 200 JSON 响应 plist。"
  (el-chronos-web--response "200 OK" el-chronos-web--json-type
                            (el-chronos-web--json-body value)))

;;; 查询参数

(defun el-chronos-web--url-decode (string)
  "对 STRING 做百分号解码（`+' 视作空格）；解码失败原样返回。"
  (condition-case nil
      (url-unhex-string (string-replace "+" " " (or string "")))
    (error (or string ""))))

(defun el-chronos-web--query-params (query)
  "把查询串 QUERY 解析成 alist（键值均为解码后的字符串）。"
  (let (params)
    (dolist (pair (split-string (or query "") "&" t))
      (let* ((eq-at (string-search "=" pair))
             (raw-key (if eq-at (substring pair 0 eq-at) pair))
             (raw-val (if eq-at (substring pair (1+ eq-at)) "")))
        (push (cons (el-chronos-web--url-decode raw-key)
                    (el-chronos-web--url-decode raw-val))
              params)))
    (nreverse params)))

(defun el-chronos-web--param (params key)
  "从 PARAMS 取 KEY 的字符串值；缺失返回 nil。"
  (cdr (assoc key params)))

(defun el-chronos-web--range-param (params)
  "从 PARAMS 取 range 并归一为符号；非法或缺失回落 `el-chronos-web--default-range'。"
  (let* ((raw (el-chronos-web--param params "range"))
         (sym (and raw (not (string-empty-p raw)) (intern raw))))
    (if (memq sym el-chronos-web--ranges) sym el-chronos-web--default-range)))

(defun el-chronos-web--int-param (params key default)
  "从 PARAMS 取整数参数 KEY；非正数或非数字回落 DEFAULT，上限 `el-chronos-web--max-limit'。"
  (let* ((raw (el-chronos-web--param params key))
         (num (and raw (not (string-empty-p raw)) (string-to-number raw))))
    (if (and num (> num 0))
        (min (truncate num) el-chronos-web--max-limit)
      default)))

;;; 自观测抑制（TD-12）
;;
;; Web 请求在主线程同步处理（查询 + 序列化 + 发送），耗时会被 1s 心跳判成"主线程阻塞"，
;; 形成"观测器自伤"记录。下面三个定义与 `el-chronos-report--without-block-events' 同款
;; 三层机制；两处为**内联重复实现**（有意为之：web 不 require report 也不 require collect，
;; 保持零额外依赖），任何一处改动都必须同步另一处。

(defvar el-chronos-collect--suppress-block-p nil
  "非 nil 时采集层心跳跳过阻塞判定。
由 Web 层在请求处理期间 `let' 绑定为 t；**读取方在 `el-chronos-collect'**（心跳里
`bound-and-true-p' 判断并推进基线），Web 层本身不读它。此处仅声明以避免跨模块 `let'
绑定未声明变量报 `void-variable'；与 collect / report 侧同名同义，重复声明无副作用。")

(defvar el-chronos-collect--last-heartbeat nil
  "上一次心跳的实际触发时刻（`float-time'），采集层持有。
Web 层只在一个场合写它：请求处理结束后重设基线，避免「请求耗时」被下一次心跳补算成阻塞
（主线程被占住期间心跳 timer 不会运行）。")

(defconst el-chronos-web--suppress-block-threshold-ms 60000
  "Web 请求处理期间临时抬高的阻塞阈值（毫秒），作为抑制变量的兜底：
即使 collect 侧尚未读取 `el-chronos-collect--suppress-block-p'，60s 也足够覆盖一次请求。")

(defmacro el-chronos-web--without-block-events (&rest body)
  "在 BODY 执行期间抑制采集层把「Web 请求处理耗时」记成阻塞事件，返回 BODY 的值。

三层保护（缺一不可，与 `el-chronos-report--without-block-events' 同款）：

1. 绑定 `el-chronos-collect--suppress-block-p' 为 t —— 采集层心跳据此直接跳过判定；
2. 把 `el-chronos-block-threshold-ms' 临时抬到
   `el-chronos-web--suppress-block-threshold-ms'（60s）—— 兜住「抑制变量还没被
   采集层读取」的过渡期（Web 请求在主线程同步执行、通常不会让出，故这一层主要防的是
   变量尚未生效的那一瞬；report 版还要额外兜 `read-file-name' 之类让出主线程的间隙）；
3. 收尾把 `el-chronos-collect--last-heartbeat' 重设为当前时刻 —— 关键一步：主线程被
   BODY 占住时心跳 timer 根本不会运行，`let' 绑定在 BODY 返回时就已解除，心跳是在**之后**
   才补跑、看到整段 gap 的。只做 1、2 两层拦不住这一次补跑，必须重置基线。

代价：请求处理期间恰好发生的**真实**阻塞也不会被记录。这是有意取舍 —— Web 请求是用户
主动触发的重查询，其耗时属预期行为，不该混进「待排查的卡顿」里。

注意：drift 的抑制**完全依赖** `el-chronos-collect--suppress-block-p' 这一道门，
没有像 block 那样的「临时抬高阈值」兜底层（抬 block 阈值对 drift 无效）。
若将来删改这道门，drift 会立即产生假阳性。"
  (declare (indent 0) (debug t))
  `(let ((el-chronos-collect--suppress-block-p t)
         (el-chronos-block-threshold-ms el-chronos-web--suppress-block-threshold-ms))
     (unwind-protect
         (progn ,@body)
       (setq el-chronos-collect--last-heartbeat (float-time)))))

;;; HTTP 层

(defun el-chronos-web--parse-request (raw)
  "解析完整请求文本 RAW 的请求行，返回 plist (:method :path :query)；无法解析返回 nil。"
  (when-let* ((head (car (split-string raw "\r\n" t)))
              (parts (split-string head " " t)))
    (when (>= (length parts) 2)
      (let* ((method (upcase (nth 0 parts)))
             (target (nth 1 parts))
             (qmark (string-search "?" target)))
        (list :method method
              :path (if qmark (substring target 0 qmark) target)
              :query (if qmark (substring target (1+ qmark)) ""))))))

(defconst el-chronos-web--routes
  '(("/" . el-chronos-web--route-index)
    ("/api/summary" . el-chronos-web--route-summary)
    ("/api/top-functions" . el-chronos-web--route-top-functions)
    ("/api/slow-commands" . el-chronos-web--route-slow-commands)
    ("/api/packages" . el-chronos-web--route-packages)
    ("/api/trend" . el-chronos-web--route-trend)
    ("/api/heatmap" . el-chronos-web--route-heatmap)
    ("/api/stacks" . el-chronos-web--route-stacks)
    ("/api/sessions" . el-chronos-web--route-sessions)
    ("/api/blocking" . el-chronos-web--route-blocking)
    ("/api/drift" . el-chronos-web--route-drift)
    ("/api/regressions" . el-chronos-web--route-regressions)
    ("/api/gc" . el-chronos-web--route-gc)
    ("/api/resources" . el-chronos-web--route-resources)
    ("/api/startup" . el-chronos-web--route-startup)
    ("/api/health" . el-chronos-web--route-health)
    ("/api/config-history" . el-chronos-web--route-config-history)
    ("/api/event" . el-chronos-web--route-event)
    ("/api/export.csv" . el-chronos-web--route-export-csv))
  "路由表：路径 → 处理函数。全部只读，没有任何写入 / 执行入口。
共 19 条（1 条 HTML + 17 条 JSON + 1 条 CSV）；新增路由必须同步 `docs/ui.org' 的路由表。")

(defun el-chronos-web--dispatch (req)
  "把解析后的请求 REQ 分发到路由，返回响应 plist。
非 GET → 405，路径不以 `/` 开头 → 400，未注册路径 → 404。"
  (let ((method (plist-get req :method))
        (path (plist-get req :path)))
    (cond
     ((not (equal method "GET"))
      (el-chronos-web--response
       "405 Method Not Allowed" el-chronos-web--text-type
       "<h1>405 Method Not Allowed</h1><p>只支持 GET（只读接口）。</p>"
       "Allow: GET\r\n"))
     ((not (and (stringp path) (string-prefix-p "/" path)))
      (el-chronos-web--response "400 Bad Request" el-chronos-web--text-type
                                "<h1>400 Bad Request</h1>"))
     (t (let ((handler (cdr (assoc path el-chronos-web--routes))))
          (if handler
              (funcall handler (el-chronos-web--query-params (plist-get req :query)))
            (el-chronos-web--response
             "404 Not Found" el-chronos-web--text-type
             (format "<h1>404 Not Found</h1><p>未知路径：%s</p>"
                     (el-chronos-web--html-escape path)))))))))

(defun el-chronos-web--send-response (proc status type body &optional headers)
  "向客户端 PROC 写回完整响应并发 EOF 关闭发送方向。
STATUS 是 `200 OK' 这类状态行文本，TYPE 是 Content-Type，BODY 是响应体，HEADERS 是附加头
（每行以 CRLF 结尾，可为空串）。Content-Length 按 UTF-8 字节数计算，避免中文被截断。"
  (let* ((payload (if (multibyte-string-p body) (encode-coding-string body 'utf-8) (or body "")))
         (head (concat (format "HTTP/1.1 %s\r\n" status)
                       (format "Content-Type: %s\r\n" type)
                       (format "Content-Length: %d\r\n" (string-bytes payload))
                       "Cache-Control: no-store\r\n"
                       "X-Content-Type-Options: nosniff\r\n"
                       "Connection: close\r\n"
                       (or headers "")
                       "\r\n")))
    (when (process-live-p proc)
      (condition-case nil
          (progn (process-send-string proc (concat head payload))
                 (process-send-eof proc))
        (error nil)))))

(defun el-chronos-web--handle-request (proc raw)
  "处理客户端 PROC 的完整请求 RAW 并写回响应；任何异常降级为 500，不影响 server。
500 分支**不回显内部错误**：浏览器只看到通用文案（内部报错常含绝对路径、SQL 片段、
变量值，回显等于对外泄露本机信息），`error-message-string' 改由 `display-warning'
写到 Emacs 侧（`*Messages*' / `*Warnings*'），本机用户仍能排障（I11：可见降级，
但可见面在 Emacs 而不是公网响应体）。
请求处理期间抑制采集层的阻塞判定（见 `el-chronos-web--without-block-events'），
避免 Web 重查询被心跳记为「观测器自伤」阻塞（TD-12）。"
  (el-chronos-web--without-block-events
    (let ((resp (condition-case err
                    (if-let* ((req (el-chronos-web--parse-request raw)))
                        (el-chronos-web--dispatch req)
                      (el-chronos-web--response "400 Bad Request" el-chronos-web--text-type
                                                "<h1>400 Bad Request</h1>"))
                  (error
                   (display-warning
                    'el-chronos
                    (format "Web dashboard 请求处理失败（%s）：%s"
                            (or (plist-get (ignore-errors (el-chronos-web--parse-request raw))
                                           :path)
                                "?")
                            (error-message-string err))
                    :warning)
                   (el-chronos-web--response
                    "500 Internal Server Error" el-chronos-web--text-type
                    (concat "<h1>500 Internal Server Error</h1>"
                            "<p>请求处理失败。内部错误详见 Emacs 的 *Messages*。</p>"))))))
      (el-chronos-web--send-response proc (plist-get resp :status) (plist-get resp :type)
                                     (plist-get resp :body) (plist-get resp :headers)))))

(defun el-chronos-web--client-sentinel (proc _event)
  "客户端 PROC 断开后清掉它的未完成请求缓冲。"
  (unless (process-live-p proc)
    (remhash proc el-chronos-web--pending)))

(defun el-chronos-web--filter (proc chunk)
  "客户端 PROC 收到数据块 CHUNK：累积到请求头完整后一次性响应（短连接）。
超出 `el-chronos-web--max-request-bytes' 返回 413 并丢弃缓冲。"
  (unless (process-get proc 'el-chronos-web-client)
    (process-put proc 'el-chronos-web-client t)
    ;; 二进制传输：我们自己按字节算 Content-Length，不让编码层二次转换
    (set-process-coding-system proc 'binary 'binary)
    (set-process-sentinel proc #'el-chronos-web--client-sentinel))
  (let ((acc (concat (or (gethash proc el-chronos-web--pending) "") chunk)))
    (cond
     ((> (string-bytes acc) el-chronos-web--max-request-bytes)
      (remhash proc el-chronos-web--pending)
      (el-chronos-web--send-response proc "413 Payload Too Large" el-chronos-web--text-type
                                     "<h1>413 Payload Too Large</h1>"))
     ((string-match "\r\n\r\n" acc)
      (remhash proc el-chronos-web--pending)
      (el-chronos-web--handle-request proc acc))
     (t (puthash proc acc el-chronos-web--pending)))))

(defun el-chronos-web--sentinel (proc _event)
  "server 进程 PROC 意外退出时清理状态，避免 `el-chronos-web-running-p' 误报。"
  (unless (process-live-p proc)
    (when (eq proc el-chronos-web--process)
      (setq el-chronos-web--process nil))))

;;; CSV 导出

(defun el-chronos-web--csv-field (value)
  "把 VALUE 转成 CSV 字段：含逗号、引号或换行时加引号并转义其中引号。"
  (let ((text (cond ((null value) "") ((stringp value) value) (t (format "%s" value)))))
    (if (string-match-p "[,\"\n\r]" text)
        (concat "\"" (replace-regexp-in-string "\"" "\"\"" text t t) "\"")
      text)))

(defun el-chronos-web--csv-block (name headers rows)
  "生成一个 CSV 区块：`# section: NAME' 注释行 + 表头 + ROWS（原始值，不做人类可读换算）。"
  (concat (format "# section: %s\n" name)
          (mapconcat #'el-chronos-web--csv-field headers ",") "\n"
          (mapconcat (lambda (row)
                       (concat (mapconcat #'el-chronos-web--csv-field row ",") "\n"))
                     rows "")))

(defun el-chronos-web--csv-rows (items keys)
  "把 plist 列表 ITEMS 投影成按 KEYS 取值的行列表（缺失字段为空）。"
  (mapcar (lambda (item) (mapcar (lambda (key) (plist-get item key)) keys)) items))

(defconst el-chronos-web--csv-sections
  '(("slow-commands" ("name" "count" "total_ms" "max_ms" "avg_ms" "aborted")
     el-chronos-analysis-slow-commands 200
     (:name :count :total-ms :max-ms :avg-ms :aborted))
    ("top-functions" ("function" "package" "file" "self_ms" "samples" "pct")
     el-chronos-analysis-top-functions 200
     (:function :package :file :self-ms :samples :pct))
    ("packages" ("package" "self_ms" "pct")
     el-chronos-analysis-package-breakdown nil (:package :self-ms :pct))
    ("trend" ("bucket_ms" "samples" "slow_commands" "blocked")
     el-chronos-analysis-trend nil (:bucket :samples :slow-commands :blocked))
    ("blocking-events" ("id" "ts_ms" "duration_ms" "kind" "command" "mode" "project")
     el-chronos-analysis-blocking-events 200
     (:id :ts :duration-ms :kind :command :mode :project))
    ("sessions" ("id" "started_at_ms" "startup_ms" "emacs_version" "host")
     el-chronos-analysis-sessions nil
     (:id :started-at :startup-ms :emacs-version :host))
    ("regressions" ("function" "current_ms" "previous_ms" "growth"
                    "current_samples" "previous_samples")
     el-chronos-analysis-regressions 200
     (:function :current-ms :previous-ms :growth :current-samples :previous-samples)))
  "CSV 明细区块：(区块名 表头 查询函数 LIMIT 字段)；再加 overview 共 8 个 `# section:'。")

;; 下面三个区块的生成函数与 `el-chronos-report--csv-startup' / `--csv-health' /
;; `--csv-config-history' 是**内联重复实现**：web 刻意不 require report（保持零额外依赖，
;; 见文件头「自观测抑制」段的同一取舍），代价是同一份 CSV 口径存在两处。
;; **两处需同步**：区块名（`# section:' 的值）、表头与列顺序、截断条数（启动分解 10 条）、
;; `changed' 写 `1' / `0' 而非空串、`health' 必带 `rows' 行。改任何一处都要同步另一处。

(defun el-chronos-web--csv-startup (breakdown)
  "生成「启动分解」CSV 区块（`# section: startup'）：阶段锚点与包加载 TOP 合成一张表。
两段用 `kind' 列区分（`phase' / `load'），其余列是 `name' 与 `ms'：合成一张表而不是两个
同名区块，是为了让下游只靠 `# section:' 就能定位区块。
包加载按 `el-chronos-web--startup-load-rows' 截断（与 report 侧口径一致）；
BREAKDOWN 为 nil 时只输出表头（I11：无数据不省略区块）。"
  (let* ((phases (and breakdown (plist-get breakdown :phases)))
         (loads (and breakdown (plist-get breakdown :loads))))
    (el-chronos-web--csv-block
     "startup" '("kind" "name" "ms")
     (append
      (cl-loop for (phase ms) in phases collect (list "phase" phase ms))
      (cl-loop for (library ms) in
               (last loads (min el-chronos-web--startup-load-rows (length loads)))
               collect (list "load" library ms))))))

(defun el-chronos-web--csv-health (health)
  "生成「采集健康」CSV 区块（`# section: health'）：`metric' / `value' 两列的窄表。
键名沿用 `hourly_health.key' 的写法（snake_case），并**必须带 `rows' 一行**（窗口内行数）
—— 导出件同样要能区分「没采集」与「没异常」，否则下游会重犯报告层曾犯的错（I11）。
`busy_retries' 是撞锁重试次数（中性度量，不进 `:ok-p'）；本函数与
`el-chronos-report--csv-health' 是内联重复实现，**两侧指标集合必须同步**
（`el-chronos-report-test-csv-health-metrics-match-web' 逐项比对）。
HEALTH 为 nil（查询失败）时只输出表头。"
  (el-chronos-web--csv-block
   "health" '("metric" "value")
   (when health
     (list (list "dropped_commands" (plist-get health :dropped-commands))
           (list "dropped_events" (plist-get health :dropped-events))
           (list "flush_failures" (plist-get health :flush-failures))
           (list "flush_count" (plist-get health :flush-count))
           (list "flush_ms" (plist-get health :flush-ms))
           (list "flush_avg_ms" (plist-get health :flush-avg-ms))
           (list "busy_retries" (plist-get health :busy-retries))
           (list "sample_misses" (plist-get health :sample-misses))
           (list "rows" (plist-get health :rows))))))

(defun el-chronos-web--csv-config-history (history)
  "生成「配置变更」CSV 区块（`# section: config-history'）。
列：`session_id' / `started_at_ms' / `git_head' / `config_sig' / `changed'；两个哈希写
**完整值**（org 报告截 8 位只为排版，导出件要给下游做 join 与比对），`changed' 写
`1' / `0' 而不是空串 —— 空串与「首会话无从比较」无法区分（与 report 侧同）。
HISTORY 为 nil 时只输出表头；此处**不做** `/api/config-history' 的 50 会话截断：导出件
的定位是完整序列（与 report 一致）。"
  (el-chronos-web--csv-block
   "config-history" '("session_id" "started_at_ms" "git_head" "config_sig" "changed")
   (cl-loop for item in (and history (plist-get history :sessions))
            collect (list (plist-get item :id)
                          (plist-get item :started-at)
                          (plist-get item :git-head)
                          (plist-get item :config-sig)
                          (if (plist-get item :changed) "1" "0")))))


(defun el-chronos-web--csv-drift (drift)
  "生成「命令外停转」CSV 区块（`# section: drift'）。
列：`bucket_ms' / `count' / `total_ms' / `max_ms'，行取自 analysis drift 趋势的桶列表，
字段保持原始值（毫秒、计数）。

与 `el-chronos-report--csv-drift' 是**内联重复实现**（web 不 require report，见文件头取舍）：
区块名、表头、列顺序、位置（CSV 末尾）必须两处一致；DRIFT 为 nil 或无桶时只输出表头
（I11：无数据不省略区块）。口径同 org 报告：只含命令之外的停转（与 `commands' 不可相加），
`total_ms' / `max_ms' 为高估值（每次最多多算一个心跳间隔）。"
  (el-chronos-web--csv-block
   "drift" '("bucket_ms" "count" "total_ms" "max_ms")
   (el-chronos-web--csv-rows (plist-get drift :buckets)
                             '(:bucket :count :total-ms :max-ms))))

(defun el-chronos-web--csv-resources (trend)
  "生成「进程资源」CSV 区块（`# section: resources'）。
列：`bucket_ms' / `cpu_ms' / `wall_ms' / `cpu_pct' / `rss_kb_max' / `rss_kb_avg' /
`threads_max' / `load1_avg' / `load5_avg' / `load15_avg' / `samples'；
行取自 analysis 资源趋势的桶列表，不截断（与 report 侧同）。

与 `el-chronos-report--csv-resources' 是**内联重复实现**（web 刻意不 require report，
见文件头取舍）：**区块名、表头、列顺序、行生成逻辑必须两处完全相同**，位置也都在
CSV 末尾（drift 之后）—— 改任何一处都要同步另一处，`el-chronos-report-test-csv-sections-match-web'
会抓区块名/顺序漂移。
单位（I4 只约束时间）：`bucket_ms' / `cpu_ms' / `wall_ms' 毫秒，`rss_kb_*' KB、
`threads_max' 计数、`load*-avg' 负载值。可空列（`load_n' 为 0 的桶）输出空串而非 0；
TREND 为 nil 或无桶时只输出表头（I11：无数据不省略区块）。"
  (el-chronos-web--csv-block
   "resources"
   '("bucket_ms" "cpu_ms" "wall_ms" "cpu_pct" "rss_kb_max" "rss_kb_avg"
     "threads_max" "load1_avg" "load5_avg" "load15_avg" "samples")
   (el-chronos-web--csv-rows
    (plist-get trend :buckets)
    '(:bucket :cpu-ms :wall-ms :cpu-pct :rss-kb-max :rss-kb-avg :threads-max
      :load1-avg :load5-avg :load15-avg :samples))))

(defun el-chronos-web--csv-string (range)
  "生成 RANGE 的 CSV 全文：overview + 7 个明细区块 + 5 个手写区块，共 13 个 `# section:'。
字段一律保持原始值（毫秒/计数），便于下游脚本解析。
前 8 个区块由 `el-chronos-web--csv-sections' 的通用规格生成（查询 → 行 → 列）；
后 5 个（startup / health / config-history / drift / resources）返回结构不齐整（启动分解
是两段嵌套列表、采集健康是扁平 plist、配置变更嵌在 `:sessions' 里、drift 与 resources 的桶
都在 `:buckets' 键下，且启动分解不吃 RANGE），各自手写区块生成函数 —— 与
`el-chronos-report--csv-string' 同款取舍，字段口径见那几个函数的 docstring
（两处需同步，区块顺序也被用例断言）。

末尾 `resources' 的位置与 report 侧一致（drift 之后）：report 侧共 10 块、web 侧多
overview / sessions / regressions 三块共 13 块，区块名与顺序由
`el-chronos-report-test-csv-sections-match-web' 逐项比对。"
  (let ((overview (el-chronos-analysis-overview range)))
    (concat
     (el-chronos-web--csv-block
      "overview" '("metric" "value")
      (mapcar (lambda (key) (list (symbol-name key) (plist-get overview key)))
              '(:commands :slow-commands :blocked-ms :samples :startup-ms :sessions :db-size)))
     (mapconcat
      (lambda (spec)
        (let ((items (if (nth 3 spec)
                         (funcall (nth 2 spec) range (nth 3 spec))
                       (funcall (nth 2 spec) range))))
          (el-chronos-web--csv-block (nth 0 spec) (nth 1 spec)
                                     (el-chronos-web--csv-rows items (nth 4 spec)))))
      el-chronos-web--csv-sections "")
     (el-chronos-web--csv-startup (el-chronos-analysis-startup-breakdown nil))
     (el-chronos-web--csv-health (el-chronos-analysis-health range))
     (el-chronos-web--csv-config-history (el-chronos-analysis-config-history range))
     ;; 命令外停转（drift）：位置与 report 侧一致（末尾），区块名/表头逐字对齐
     (el-chronos-web--csv-drift (el-chronos-analysis-drift-trend range))
     ;; 进程资源：与 report 侧同名区块逐字对齐，位置也在最末
     (el-chronos-web--csv-resources (el-chronos-analysis-resource-trend range)))))

;;; 路由处理函数

(defun el-chronos-web--list-response (params query &optional kind default-limit)
  "通用列表响应：按 PARAMS 的 range / limit（或 buckets）调用 QUERY，返回 JSON 响应。
KIND 取 `range'（QUERY 只接受 range，如 sessions）、`all'（range + nil limit，不限条数）、
`buckets'（range + buckets），其他按 `limit'（默认 DEFAULT-LIMIT 或
`el-chronos-web--default-limit'）。响应键恒含 `range' `limit' `items'，前端无需按接口分支。"
  (let* ((range (el-chronos-web--range-param params))
         (arg (cond ((memq kind '(range all)) nil)
                    ((eq kind 'buckets) (el-chronos-web--int-param params "buckets" nil))
                    (t (el-chronos-web--int-param
                        params "limit" (or default-limit el-chronos-web--default-limit)))))
         (items (if (eq kind 'range) (funcall query range) (funcall query range arg))))
    (el-chronos-web--json-response
     (list :range (format "%s" range) :limit arg :items items))))

(defun el-chronos-web--route-index (_params)
  "GET /：返回内嵌 HTML 页面。"
  (el-chronos-web--response "200 OK" el-chronos-web--html-type (el-chronos-web--index-html)))

(defun el-chronos-web--route-summary (params)
  "GET /api/summary：总览指标（`overview' 为 `el-chronos-analysis-overview' 的 plist）。"
  (let ((range (el-chronos-web--range-param params)))
    (el-chronos-web--json-response
     (list :range (format "%s" range) :generated-at (el-chronos-web--now-ms)
           :overview (el-chronos-analysis-overview range)))))

(defun el-chronos-web--route-top-functions (params)
  "GET /api/top-functions：按 self 时间降序的函数热点。"
  (el-chronos-web--list-response params #'el-chronos-analysis-top-functions))

(defun el-chronos-web--route-slow-commands (params)
  "GET /api/slow-commands：按总耗时降序的命令排行。"
  (el-chronos-web--list-response params #'el-chronos-analysis-slow-commands))

(defun el-chronos-web--route-packages (params)
  "GET /api/packages：按包 / 模块聚合的 self 时间占比（不限条数）。"
  (el-chronos-web--list-response params #'el-chronos-analysis-package-breakdown 'all))

(defun el-chronos-web--route-trend (params)
  "GET /api/trend：按桶聚合的趋势；buckets 省略时由 analysis 按窗口长度选择。"
  (el-chronos-web--list-response params #'el-chronos-analysis-trend 'buckets))

(defun el-chronos-web--route-heatmap (params)
  "GET /api/heatmap：命令用法热力图（桶 × 命令的计数矩阵）。"
  (el-chronos-web--list-response params #'el-chronos-analysis-heatmap))

(defun el-chronos-web--route-stacks (params)
  "GET /api/stacks：调用栈排行（火焰图数据源，默认 50 条）。"
  (el-chronos-web--list-response params #'el-chronos-analysis-stacks 'limit 50))

(defun el-chronos-web--route-sessions (params)
  "GET /api/sessions：窗口内启动的会话列表（多会话对比数据源）。"
  (el-chronos-web--list-response params #'el-chronos-analysis-sessions 'range))

(defun el-chronos-web--route-blocking (params)
  "GET /api/blocking：命令外阻塞事件列表。"
  (el-chronos-web--list-response params #'el-chronos-analysis-blocking-events))

(defun el-chronos-web--route-drift (params)
  "GET /api/drift：窗口内按桶聚合的「命令外停转」（drift）趋势。
查询参数 `range'（1d / 7d / 30d）与 `buckets'（正整数；省略时由 analysis 按窗口长度选择，
并受整小时倍数合并约束，与 `/api/gc' 同一套）。

响应键：`:range' 归一化范围字符串、`:bucket-count' 请求的桶数（省略时为 null）、
`:bucket-span' 桶宽（毫秒）、`:drift-total' 窗口内次数合计、`:ms-total' 累计停转毫秒、
`:slowest-ms' 窗口内单次最长停转（三者无数据时为 0 / 0.0 / 0.0）、`:items' 桶列表
`[{:bucket :count :total-ms :max-ms}]'（即 analysis 的 `:buckets'，改名以与其它列表接口
的 `:items' 同形）、`:threshold-ms' 当前判定阈值（取自
`el-chronos-drift-threshold-ms'，供页面文案使用；写死会与实际判定脱节）。

**口径必须随响应一起传达**（页面已标注）：本端点只含**命令之外**的停转，命令内部的
停转在 `/api/slow-commands'（`commands' 表），两者**不可相加**；`:ms-total' / `:slowest-ms'
是高估值（每次最多多算一个心跳间隔，默认 250ms）。
analysis 返回 nil（库打不开 / 查询失败）时降级为空结构（`:items' 为 null），仍返回 200。"
  (let* ((range (el-chronos-web--range-param params))
         (buckets (el-chronos-web--int-param params "buckets" nil))
         (trend (el-chronos-analysis-drift-trend range buckets)))
    (el-chronos-web--json-response
     (list :range (format "%s" range)
           :bucket-count buckets
           :bucket-span (plist-get trend :bucket-span)
           ;; 判定阈值随响应下发：页面文案里的「≥N ms」由 defcustom 决定，写死会与实际
           ;; 判定脱节（`el-chronos-drift-threshold-ms' 是可调项，见 operations 文档）
           :threshold-ms (or (bound-and-true-p el-chronos-drift-threshold-ms) 500)
           :drift-total (or (plist-get trend :drift-total) 0)
           :ms-total (or (plist-get trend :ms-total) 0.0)
           :slowest-ms (or (plist-get trend :slowest-ms) 0.0)
           :items (plist-get trend :buckets)))))

(defun el-chronos-web--route-regressions (params)
  "GET /api/regressions：按 `el-chronos-regression-window-days' 判定的回归列表。"
  (el-chronos-web--list-response params #'el-chronos-analysis-regressions))

(defun el-chronos-web--route-gc (params)
  "GET /api/gc：窗口内按桶聚合的 GC 与堆内存趋势。
查询参数 `range'（1d / 7d / 30d）与 `buckets'（正整数；省略时由 analysis 按窗口长度选择，
1d / 7d / 30d 分别对应 24 / 168 / 720，并受整小时倍数合并约束）。

响应键：`:range' 归一化范围、`:bucket-count' 请求的桶数（省略时为 null）、`:bucket-span'
桶宽（毫秒）、`:gc-total' 窗口内 GC 次数合计、`:heap-latest' 窗口内最后一个非空堆大小
（**Emacs 31.1 以下恒为 null**，不是数据丢失）、`:items' 桶列表
`[{:bucket :gc-count :gc-ms :heap-bytes}]'。

`:items' 就是 `el-chronos-analysis-gc-trend' 的 `:buckets'，改名为 `:items' 以与其它
列表接口（`:range' `:limit' `:items'）保持同一形状；`:heap-bytes' 为 null 表示该桶内
没有任何堆样本（桶内全 NULL），前端渲染 \"-\" 而非 0。
GC 次数与耗时全 0 的桶是**会话首个采样窗口的基线桶**，不等于「没有发生 GC」——
页面在本期全为基线桶时给降级说明（I11）。
analysis 返回 nil（库打不开 / 查询失败）时降级为空结构（`:items' 为 null），仍返回 200。"
  (let* ((range (el-chronos-web--range-param params))
         (buckets (el-chronos-web--int-param params "buckets" nil))
         (trend (el-chronos-analysis-gc-trend range buckets)))
    (el-chronos-web--json-response
     (list :range (format "%s" range)
           :bucket-count buckets
           :bucket-span (plist-get trend :bucket-span)
           :gc-total (plist-get trend :gc-total)
           :heap-latest (plist-get trend :heap-latest)
           :items (plist-get trend :buckets)))))

(defun el-chronos-web--route-resources (params)
  "GET /api/resources：窗口内按桶聚合的**进程资源**趋势（CPU / RSS / 线程数 / 系统负载）。
查询参数 `range'（1d / 7d / 30d）与 `buckets'（正整数；省略时由 analysis 按窗口长度选择，
1d / 7d / 30d 分别对应 24 / 168 / 720，并受整小时倍数合并约束，与 `/api/gc' 同一套）。

响应键：`:range' 归一化范围字符串、`:bucket-count' 请求的桶数（省略时为 null）、
`:bucket-span' 桶宽（毫秒）、窗口汇总 `:cpu-ms-total' `:wall-ms-total' `:cpu-pct-avg'
`:rss-kb-max' `:rss-kb-avg' `:threads-max' `:load1-avg' `:load5-avg'
`:load15-avg' `:samples'，以及 `:buckets' 桶列表
`[{:bucket :cpu-ms :wall-ms :cpu-pct :rss-kb-max :rss-kb-avg :threads-max
:load1-avg :load5-avg :load15-avg :samples}]'。

**单位（I4 只约束时间，别顺手「统一成毫秒」）**：`:cpu-ms' / `:wall-ms' 是毫秒；
`:rss-kb-*' 是 **KB**、`:threads-max' 是线程计数、`:load*-avg' 是系统负载值 ——
页面因此用专门的 `kb()' 换算，不能复用按**字节**起步的 `bytes()'（会差 1024 倍）。

**null 与 0 严格区分（诚实性）**：`:rss-kb-avg' 与 `:load*-avg' 的分母是 `load_n'
（成功取到 `load-average' 的窗口数），`load_n' 为 0 时这些均值是 **JSON null，不是 0** ——
0 的含义是「观测到了，值为 0」，用 0 顶替会把「负载采集全失败」显示成「系统空闲」。
同桶的 `:rss-kb-max' / `:threads-max' 不依赖 `load_n'，仍可能有值。`:cpu-pct-avg' 走
`el-chronos-analysis--pct'（分母为 0 时给 0.0），因此无样本时它是 0.0 而非 null。

**口径必须随响应一起传达**（页面已标注）：`:cpu-pct' 是「窗口内 CPU 时间增量 / 墙钟增量」，
不是瞬时利用率；首窗口只建 CPU / 墙钟基线、不写库，故会话启动后的第一个桶可能缺失
（不等于「那一刻 CPU 为 0」）。
`:buckets' 的键名不做改名（analysis 原样回传）：页面按 `buckets' 读取，与 `/api/gc' 的
`:items' 命名差异是有意保留的（本端点键集合由 analysis 定义，改名会再多一处同步负担）。
analysis 返回 nil（库打不开 / 查询失败）时降级为空结构（`:buckets' 为 null），仍返回 200。"
  (let* ((range (el-chronos-web--range-param params))
         (buckets (el-chronos-web--int-param params "buckets" nil))
         (trend (el-chronos-analysis-resource-trend range buckets)))
    (el-chronos-web--json-response
     (list :range (format "%s" range)
           :bucket-count buckets
           :bucket-span (plist-get trend :bucket-span)
           :cpu-ms-total (or (plist-get trend :cpu-ms-total) 0.0)
           :wall-ms-total (or (plist-get trend :wall-ms-total) 0.0)
           ;; 均值 / 峰值类一律原样下发：nil → JSON null（不补 0，见 docstring）
           :cpu-pct-avg (plist-get trend :cpu-pct-avg)
           :rss-kb-max (plist-get trend :rss-kb-max)
           :rss-kb-avg (plist-get trend :rss-kb-avg)
           :threads-max (plist-get trend :threads-max)
           :load1-avg (plist-get trend :load1-avg)
           :load5-avg (plist-get trend :load5-avg)
           :load15-avg (plist-get trend :load15-avg)
           :samples (plist-get trend :samples)
           :buckets (plist-get trend :buckets)))))

(defun el-chronos-web--route-startup (params)
  "GET /api/startup[?session=N]：单会话的启动耗时分解。
`session' 省略、非数字或非正数时取**最近一次有启动数据**的会话（判据见
`el-chronos-analysis--startup-session'）；提供了但库里没有该会话 →
`:session-id' 回填请求的 id、其余键为 null 的**同构空结构**，**不返回 404**：会话可能
已被保留策略清理，属正常空结果而非路径错误（与 `/api/event' 的 200 + null 同一取舍）。

响应即 `el-chronos-analysis-startup-breakdown' 的 plist：
`:session-id' `:started-at' `:startup-ms' `:phases'（`[[阶段 耗时ms] ...]'，固定顺序
mode-start → after-init → startup → first-idle，缺的跳过）、`:loads'（`[[库 耗时ms] ...]'
按耗时降序，采集层已按 `el-chronos-startup-top-n' 截断）。

**覆盖范围必须显式标注**（页面已标）：包加载耗时是相邻 `after-load-functions' 的时间差，
属近似归因；且只覆盖 mode 启动之后发生的 load —— 用户通常在 init 末尾才启用 mode，
此时只有 `mode-start' 一个锚点，本接口的数据不能冒充「完整启动剖析」。
analysis 返回 nil（查询失败）时降级为 JSON `null'。"
  (let* ((raw (el-chronos-web--param params "session"))
         (num (and raw (not (string-empty-p raw)) (string-to-number raw)))
         (id (and num (> num 0) (truncate num))))
    (el-chronos-web--json-response
     (el-chronos-analysis-startup-breakdown id))))

(defun el-chronos-web--route-health (params)
  "GET /api/health：窗口内采集器自监控计数的汇总。
响应是 `el-chronos-analysis-health' 的 plist 加一个 `:range'：
`:dropped-commands' `:dropped-events' `:flush-failures' `:flush-count'
`:flush-ms' `:flush-avg-ms' `:busy-retries' `:sample-misses' `:ok-p' `:rows'。
`:busy-retries' 是**中性度量**（锁竞争被成功自愈也会上升），刻意不计入 `:ok-p' ——
「busy-retries 升而 flush-failures 不升」是 **D1 路径**（open 期建会话行撞锁）的
自愈判据，不是异常；**D2 路径**（flush 写批撞锁）这两个数会同时升，判据改为
`:dropped-commands' / `:dropped-events' 是否跟涨（跟涨 = 数据真丢）。
**`:rows' 必须出现在响应里**：它是区分「本期无采集异常」（`:ok-p' 为 true 且 `:rows' > 0）
与「本期无采集数据」（`:rows' = 0）的唯一依据 —— analysis 在一条 health 行都没有时同样
返回 `:ok-p' 为 t，只看 `:ok-p' 会把「没采集」读成「一切正常」（T7b 在报告层修过的同一
语义，Web 页面按 `:rows' 先行分支，不复犯）。
`:ok-p' 显式归一为 JSON 布尔（true / false）：analysis 的 nil 经 `--json-value' 会变成
null，而「没有坏消息」是一个确定的 false/true 判断，不该与「未知」共用一个 JSON 值。
analysis 返回 nil（查询失败）时降级为 JSON `null'（页面显示「（无数据）」）。"
  (let* ((range (el-chronos-web--range-param params))
         (health (el-chronos-analysis-health range)))
    (el-chronos-web--json-response
     (when health
       (let ((payload (copy-sequence health)))
         (plist-put payload :ok-p (if (plist-get health :ok-p) t :false))
         (append (list :range (format "%s" range)) payload))))))

(defun el-chronos-web--route-config-history (params)
  "GET /api/config-history：窗口内各会话的变更标记时间线（按启动时间升序）。
响应：`:range' `:sessions'（元素 `{:id :started-at :git-head :config-sig :changed}'）
`:changes'（返回列表里 `:changed' 为 true 的条数）`:total-sessions'（截断前条数）
`:truncated'（是否被截断，显式归一为 JSON 布尔：nil 经 `--json-value' 会变成 null，
而「有没有截断」是确定判断，不该与「未知」共用 null）。

**只返回最近 `el-chronos-web--config-history-sessions' 个会话**（取尾部）：会话行随每次
重启单调增长，全量返回会让单线程 Web 的主线程查询与浏览器渲染时间一起变长。截断后
`:changes' 按**返回的**会话重算，保证「计数 = 表里打勾的行数」；保留下来的第一条若
`:changed' 为 true，它参照的前一会话已不在列表里（analysis 的 `:changed' 语义是「与前一
会话相比」），这是截断的固有代价，由 `:truncated' 标出。
`git-head' / `config-sig' 为 null 表示会话启动时未取到（store 层取不到就不写行），
不是「取了但为空」；`changed' 为 null 表示无变化或首会话无从比较（analysis 层不区分二者，
页面与 CSV 都按「无变化」渲染）。

analysis 返回 nil（查询失败）时降级为 `:sessions' 为 null、计数为 0 的空结构。"
  (let* ((range (el-chronos-web--range-param params))
         (history (el-chronos-analysis-config-history range))
         (all (plist-get history :sessions))
         (limit el-chronos-web--config-history-sessions)
         (kept (last all (min limit (length all)))))
    (el-chronos-web--json-response
     (list :range (format "%s" range)
           :total-sessions (length all)
           :truncated (if (> (length all) (length kept)) t :false)
           :changes (cl-count-if (lambda (item)
                                   (eq t (plist-get item :changed)))
                                 kept)
           :sessions kept))))

(defun el-chronos-web--route-event (params)
  "GET /api/event?id=N：单条慢事件详情；id 缺失、非法或记录不存在时 body 为 JSON `null'。
选择「200 + null」而非 404：下钻面板只需区分「有数据 / 无数据」，而事件可能已被保留策略
清理，属正常空结果而非路径错误（路径错误仍由 404 表达）。"
  (let* ((raw (el-chronos-web--param params "id"))
         (num (and raw (not (string-empty-p raw)) (string-to-number raw))))
    (el-chronos-web--json-response
     (and num (> num 0) (el-chronos-analysis-event (truncate num))))))

(defun el-chronos-web--route-export-csv (params)
  "GET /api/export.csv：多区块 CSV 下载（`# section:' 分隔，附件下载）。"
  (let ((range (el-chronos-web--range-param params)))
    (el-chronos-web--response
     "200 OK" el-chronos-web--csv-type (el-chronos-web--csv-string range)
     (format "Content-Disposition: attachment; filename=\"el-chronos-%s.csv\"\r\n" range))))
;;; 启停

(defun el-chronos-web--url (&optional proc)
  "返回 Web dashboard 的访问 URL，形如 `http://127.0.0.1:PORT/'。
PORT 优先取 PROC 的实际绑定端口（`process-contact' 的 `:service'）：PORT 入参为 0 时
由内核分配，此时显示入参 0 毫无意义，故以实际绑定为准。
PROC 为 nil 或取不到 `:service'（已关闭的进程）时回落 `el-chronos-web-port'。
之所以收敛成一个 helper：启动 message、交互式打开浏览器、`el-chronos-web-browse'
三处都要同一个 URL，拼接散落多份迟早写出不一致的 host / 斜杠。"
  (format "http://%s:%s/" el-chronos-web--host
          (or (and (processp proc)
                   (ignore-errors (process-contact proc :service)))
              el-chronos-web-port)))

(defun el-chronos-web-running-p ()
  "Web server 是否正在运行；严格返回 `t' 或 nil。
`process-live-p' 的状态是关键字（`listen' / `connect' / `stop' 等），直接返回会把状态
关键字泄漏给调用方（`(if (running-p) ...)' 仍能用，但 `(eq t ...)' 这类布尔断言会失败，
且调用方可能把 `stop' 误当运行中）。故归一为 `t' / nil。"
  (let ((proc el-chronos-web--process))
    (and (processp proc) (process-live-p proc) t)))

;;;###autoload
(defun el-chronos-web-start (&optional port)
  "启动 Web dashboard，返回 server 进程对象。
只绑定 127.0.0.1 的 PORT（默认 `el-chronos-web-port'）；已在运行时先关闭再启动。
端口占用或其他启动失败一律 `user-error'，**不自动换端口**（I8 / I11）。

message 与返回值都反映**实际绑定**的端口：PORT 为 0 时由内核分配，此时显示的仍是
入参 0 就毫无意义，故统一取 `process-contact' 的 `:service'（取不到才回落 PORT）。
调用方可用 `(process-contact (el-chronos-web-start))' 核验绑定地址。

**交互式调用**时若 `el-chronos-web-open-browser' 为真，启动后用 `browse-url' 打开
页面（尊重用户的 `browse-url-browser-function' 等设置）；打开失败只 `message' 提示
并给出 URL，不影响已启动的 server（I11：可见降级，不变成错误）。
程序化调用（例如 `el-chronos-web-auto-start' 在启用观测时顺带起 server）**不**弹
浏览器：两个判据必须同时成立（开关为真 **且** `called-interactively-p' 为真），
否则每次启动 Emacs 都会弹出一个窗口。"
  (interactive)
  (when (el-chronos-web-running-p)
    (el-chronos-web-stop))
  (let* ((port (or port el-chronos-web-port))
         (proc (condition-case err
                   (make-network-process
                    :name el-chronos-web--process-name
                    :server t
                    :host el-chronos-web--host
                    :service port
                    :family 'ipv4
                    :filter #'el-chronos-web--filter
                    :sentinel #'el-chronos-web--sentinel
                    :noquery t)
                 (error
                  (user-error "Web dashboard 启动失败（%s:%s 可能已被占用，不会自动换端口）：%s"
                              el-chronos-web--host port
                              (error-message-string err)))))
         (url nil))
    (setq el-chronos-web--process proc)
    (setq url (el-chronos-web--url proc))
    (message "el-chronos Web dashboard：%s" url)
    ;; 两条判据缺一不可：开关为真 + 交互式调用（程序化启动绝不弹窗）
    (when (and el-chronos-web-open-browser
               (called-interactively-p 'interactive))
      (condition-case err
          (browse-url url)
        (error (message "el-chronos：打开浏览器失败（%s），请手动访问 %s"
                        (error-message-string err) url))))
    proc))

;;;###autoload
(defun el-chronos-web-browse ()
  "用浏览器打开 Web dashboard 页面；server 未运行时先启动。
命令自身的打开动作**不看** `el-chronos-web-open-browser'：这是用户显式要求打开页面，
与开关无关。未启动时先 `el-chronos-web-start'——那是非交互调用，天然不弹浏览器，
随后由本命令打开一次，因此不会双弹。
与 `el-chronos-web-start' 交互路径的区别：后者只在「刚启动那一次」按开关决定是否
打开，server 已运行时不再打开；本命令每次调用都打开当前页面（server 已运行则直接打开）。
打开失败只 `message' 提示并给出 URL，不 `user-error'：server 已成功启动，缺一个浏览器
不该变成错误（I11：可见降级，不静默、不中断）。"
  (interactive)
  (unless (el-chronos-web-running-p)
    (el-chronos-web-start))
  (let ((url (el-chronos-web--url el-chronos-web--process)))
    (condition-case err
        (browse-url url)
      (error (message "el-chronos：打开浏览器失败（%s），请手动访问 %s"
                      (error-message-string err) url)))))

;;;###autoload
(defun el-chronos-web-stop ()
  "关闭 Web dashboard 并释放监听端口；返回 t 表示确有 server 被关闭。
同时清理未完成请求缓冲，避免残留 hash 项泄漏。"
  (interactive)
  (let ((proc el-chronos-web--process))
    (setq el-chronos-web--process nil)
    (clrhash el-chronos-web--pending)
    (when (processp proc)
      (ignore-errors (delete-process proc)))
    (when (called-interactively-p 'interactive)
      (message "el-chronos Web dashboard 已关闭"))
    (processp proc)))

;;; 内嵌页面（CSS / HTML / JS，无外部资源）

(defconst el-chronos-web--css
  ":root{--bg:#0f1115;--fg:#e6e8ee;--mut:#9aa3b2;--card:#171a21;--line:#252a34;--acc:#4f9cf9;--warn:#f0b429;--good:#3fb950}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);font:13px/1.5 system-ui,-apple-system,sans-serif}
header{position:sticky;top:0;z-index:5;display:flex;flex-wrap:wrap;gap:10px;align-items:center;padding:10px 16px;background:#12151b;border-bottom:1px solid var(--line)}
h1{margin:0;font-size:15px}.mut{color:var(--mut)}
button,select,input{background:var(--card);color:var(--fg);border:1px solid var(--line);border-radius:6px;padding:4px 8px;font:inherit}
button{cursor:pointer}button.on{border-color:var(--acc);color:var(--acc)}input[type=checkbox]{padding:0}
main{max-width:1200px;margin:0 auto;padding:16px;display:grid;gap:14px}
section{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:12px 14px;overflow:hidden}
section>h2{margin:0 0 10px;font-size:12px;letter-spacing:.05em;text-transform:uppercase;color:var(--mut)}
section h3{margin:10px 0 6px;font-size:11px;letter-spacing:.04em;text-transform:uppercase;color:var(--mut)}
section h3:first-child{margin-top:0}
.ok{color:var(--good)}
.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(130px,1fr));gap:10px}
.card{background:#12151b;border:1px solid var(--line);border-radius:8px;padding:9px}
.card b{display:block;font-size:17px}.card span{color:var(--mut);font-size:11px}
table{width:100%;border-collapse:collapse;table-layout:fixed}
th,td{padding:5px 8px;border-bottom:1px solid var(--line);text-align:left;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
th{cursor:pointer;color:var(--mut);font-size:11px;text-transform:uppercase}
tbody tr:hover{background:#1c212b;cursor:pointer}tfoot td{border:0;color:var(--mut);padding-top:8px}
.legend{display:flex;gap:12px;flex-wrap:wrap;color:var(--mut);font-size:11px;margin-top:8px}
.legend i{display:inline-block;width:9px;height:9px;border-radius:2px;margin-right:4px;background:var(--acc)}
.legend i.b{background:var(--warn)}.legend i.c{background:var(--good)}
.hm{display:grid;gap:2px;align-items:center}
.hmh{color:var(--mut);font-size:10px;text-align:center}
.hml{color:var(--mut);font-size:11px;line-height:14px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.hmv{height:14px;border-radius:2px}svg text{pointer-events:none}
#panel{position:fixed;top:0;right:0;bottom:0;width:min(540px,94vw);background:#12151b;border-left:1px solid var(--line);padding:14px;overflow:auto;transform:translateX(103%);transition:transform .18s;z-index:20}
#panel.open{transform:none}
#panel pre{white-space:pre-wrap;word-break:break-word;background:#0f1115;padding:8px;border-radius:6px;font-size:11px}
#panel ul{padding-left:18px;margin:6px 0}
@media (max-width:760px){main{padding:10px}th,td{padding:4px 6px}.cards{grid-template-columns:repeat(2,1fr)}#panel{width:100%}}
"
  "内嵌 CSS（无外链、无字体/图标请求；窄屏 `@media' 收窄表格与侧栏，规则逐条紧凑排列）。")

(defconst el-chronos-web--markup
  "<body>
<header><h1>el-chronos</h1><div id='ranges'></div>
<button id='refresh'>刷新</button>
<label class='mut'><input type='checkbox' id='auto' checked> 自动刷新 30s</label>
<a class='mut' id='csv' href='/api/export.csv?range=7d' download>导出 CSV</a>
<span id='status' class='mut'></span></header>
<main>
<section><h2>概览</h2><div class='cards' id='ov'></div></section>
<section><h2>趋势</h2><svg id='trend' viewBox='0 0 800 200' preserveAspectRatio='none' style='width:100%;height:200px'></svg><div class='legend' id='trend-legend'></div></section>
<section><h2>GC 与内存</h2><table id='t-gc'></table><div class='legend' id='gc-legend'></div></section>
<section><h2>资源（CPU / 内存 / 负载）</h2><div id='res'></div></section>
<section><h2>启动分解</h2><div id='startup'></div></section>
<section><h2>包 / 模块占比</h2><div style='display:flex;gap:16px;flex-wrap:wrap;align-items:center'><svg id='donut' viewBox='0 0 120 120' style='width:120px;height:120px'></svg><div class='legend' id='donut-legend' style='flex-direction:column;gap:4px'></div></div></section>
<section><h2>用法热力</h2><div class='hm' id='heat'></div></section>
<section><h2>慢命令</h2><input id='q-slow' placeholder='搜索命令…'><table id='t-slow'></table></section>
<section><h2>热点函数</h2><input id='q-func' placeholder='搜索函数 / 包…'><table id='t-func'></table></section>
<section><h2>阻塞事件</h2><div id='drift'></div><table id='t-block'></table></section>
<section><h2>回归</h2><table id='t-reg'></table></section>
<section><h2>采集健康</h2><div id='health'></div></section>
<section><h2>配置变更</h2><div id='conf'></div></section>
<section><h2>会话</h2><table id='t-sess'></table></section>
<section><h2>火焰图（调用栈）</h2><svg id='flame' viewBox='0 0 800 200' preserveAspectRatio='none' style='width:100%;height:200px'></svg><div class='legend' id='flame-legend'></div></section>
</main>
<aside id='panel'><button id='panel-close'>关闭</button><div id='panel-body'></div></aside>
"
  "内嵌页面结构（顶栏 → 概览 → 趋势 → GC 与内存 → 资源（CPU / 内存 / 负载）→ 启动分解 →
占比 → 热力 → 慢命令 → 热点函数 → 阻塞事件（含「命令外停转」汇总与明细）→ 回归 →
采集健康 → 配置变更 → 会话 → 火焰图 + 下钻侧栏）。")

(defconst el-chronos-web--script
  "
const RANGES=['1d','7d','30d'];
const S={range:'7d',auto:true,timer:null,per:10,data:{},view:{},
  sort:{slow:'total-ms',func:'self-ms',block:'duration-ms',sess:'started-at',reg:'growth',gc:'bucket'},
  dir:{slow:-1,func:-1,block:-1,sess:-1,reg:-1,gc:1},
  page:{slow:1,func:1,block:1,sess:1,reg:1,gc:1},q:{slow:'',func:'',block:'',sess:'',reg:'',gc:''}};
const EMPTY={gc:'本期无 GC 采样数据（Emacs 31.1 以下不采集堆大小）'};
const $=id=>document.getElementById(id);
const DQ=String.fromCharCode(34),SQ=String.fromCharCode(39);
const esc=v=>{const s=String(v==null?'':v);return s.split('&').join('&amp;').split('<').join('&lt;').split('>').join('&gt;').split(DQ).join('&quot;').split(SQ).join('&#39;');};
const nf=v=>Number(v||0).toLocaleString();
const ms=v=>{v=Number(v||0);if(v>=1000)return (v/1000).toFixed(2)+'s';return v>=1?v.toFixed(1)+'ms':Math.round(v*1000)+'us';};
const bytes=v=>{v=Number(v||0);const u=['B','KB','MB','GB'];let i=0;while(v>=1024&&i<3){v=v/1024;i++;}return v.toFixed(i?1:0)+u[i];};
// 资源数据（hourly_resources.rss_kb_*）的单位是 **KB**，不能套 bytes()（那里起点是字节，
// 会把 204800 KB 显示成 200 B，差 1024 倍）。kb() 的起点就是 KB。
const kb=v=>{v=Number(v||0);const u=['KB','MB','GB'];let i=0;while(v>=1024&&i<2){v=v/1024;i++;}return v.toFixed(i?1:0)+u[i];};
const ts=v=>new Date(Number(v||0)).toLocaleString(),pct=v=>Number(v||0).toFixed(1)+'%';
const COLORS=['#4f9cf9','#f0b429','#3fb950','#ef5b5b','#a371f7','#79c0ff','#d29922','#8b949e'];
const COLS={
 slow:[{k:'name',t:'命令'},{k:'count',t:'次数',n:1},{k:'total-ms',t:'总耗时',f:ms},{k:'avg-ms',t:'均值',f:ms},{k:'max-ms',t:'最大',f:ms},{k:'aborted',t:'中断',n:1}],
 func:[{k:'function',t:'函数'},{k:'package',t:'包/模块'},{k:'self-ms',t:'self',f:ms},{k:'samples',t:'样本',n:1},{k:'pct',t:'占比',f:pct},{k:'file',t:'文件'}],
 block:[{k:'id',t:'#'},{k:'ts',t:'时间',f:ts},{k:'duration-ms',t:'耗时',f:ms},{k:'command',t:'命令'},{k:'mode',t:'mode'},{k:'project',t:'项目'}],
 sess:[{k:'id',t:'#'},{k:'started-at',t:'启动',f:ts},{k:'startup-ms',t:'启动耗时',f:ms},{k:'emacs-version',t:'Emacs'},{k:'host',t:'主机'}],
 reg:[{k:'function',t:'函数'},{k:'current-ms',t:'当前',f:ms},{k:'previous-ms',t:'上一窗口',f:ms},{k:'growth',t:'增长',f:v=>'+'+Math.round(Number(v||0)*100)+'%'},{k:'current-samples',t:'样本',n:1}]};
COLS.gc=[{k:'bucket',t:'时间',f:ts},{k:'gc-count',t:'GC 次数',n:1},{k:'gc-ms',t:'GC 耗时',f:ms},
  {k:'heap-bytes',t:'内存',f:v=>v==null?'-':bytes(v)}];
async function getJSON(path,extra){
  const q=new URLSearchParams(Object.assign({range:S.range},extra||{}));
  const r=await fetch(path+'?'+q.toString(),{cache:'no-store'});
  if(!r.ok)throw new Error(path+' -> '+r.status);
  return r.json();}
function ranges(){
  $('ranges').innerHTML=RANGES.map(r=>`<button data-r='${r}'${r===S.range?\" class='on'\":''}>${r}</button>`).join('');
  $('csv').setAttribute('href','/api/export.csv?range='+S.range);}
function cards(o,res){
  // RES 来自 /api/resources（另一个请求，可能尚未加载 / 为 null）：缺失时资源三卡一律显示 '-',
  // 不用 0 顶替 —— 0 的含义是「观测到了，值为 0」，与「没有样本」是两件事。
  const r=res||{};
  const it=[['命令数',nf(o.commands)],['慢命令',nf(o['slow-commands'])],['阻塞总时长',ms(o['blocked-ms'])],
    ['采样点数',nf(o.samples)],['启动中位',o['startup-ms']==null?'-':ms(o['startup-ms'])],
    ['会话数',nf(o.sessions)],['数据库',bytes(o['db-size'])],
    ['CPU 均值',r['cpu-pct-avg']==null?'-':pct(r['cpu-pct-avg'])],
    ['RSS 峰值',r['rss-kb-max']==null?'-':kb(r['rss-kb-max'])],
    ['负载 1m',r['load1-avg']==null?'-':Number(r['load1-avg']).toFixed(2)]];
  $('ov').innerHTML=it.map(x=>`<div class='card'><b>${x[1]}</b><span>${x[0]}</span></div>`).join('');}
function trend(items){
  const W=800,H=200,P=18;
  if(!items.length){$('trend').innerHTML=`<text x='10' y='30' fill='#9aa3b2' font-size='12'>（无数据）</text>`;$('trend-legend').innerHTML='';return;}
  const max=Math.max(1,...items.map(d=>Number(d.samples||0))),step=items.length>1?(W-2*P)/(items.length-1):0;
  const ys=items.map((d,i)=>[P+i*step,H-P-(Number(d.samples||0)/max)*(H-2*P)]);
  const line=ys.map((p,i)=>(i?'L':'M')+p[0].toFixed(1)+' '+p[1].toFixed(1)).join(' ');
  const area=line+' L'+ys[ys.length-1][0].toFixed(1)+' '+(H-P)+' L'+P+' '+(H-P)+' Z';
  const bars=items.map((d,i)=>{const h=(Number(d['slow-commands']||0)/max)*(H-2*P);
    return `<rect x='${(P+i*step-1).toFixed(1)}' y='${(H-P-h).toFixed(1)}' width='2' height='${h.toFixed(1)}' fill='#f0b429' opacity='0.6'/>`;}).join('');
  $('trend').innerHTML=`<path d='${area}' fill='#4f9cf9' opacity='0.12'/><path d='${line}' fill='none' stroke='#4f9cf9' stroke-width='1.6'/>${bars}`;
  $('trend-legend').innerHTML=`<span><i></i>采样点数</span><span><i class='b'></i>慢命令</span><span class='mut'>${items.length} 桶</span>`;}
function donut(items){
  if(!items.length){$('donut').innerHTML='';$('donut-legend').textContent='（无数据）';return;}
  const R=45,CIR=2*Math.PI*R,top=items.slice(0,8);let acc=0;
  $('donut').innerHTML=top.map((d,i)=>{const p=Number(d.pct||0)/100,seg=CIR*p,off=CIR*acc;acc+=p;
    return `<circle r='${R}' cx='60' cy='60' fill='none' stroke='${COLORS[i%8]}' stroke-width='18' stroke-dasharray='${seg.toFixed(2)} ${CIR.toFixed(2)}' stroke-dashoffset='${(-off).toFixed(2)}' transform='rotate(-90 60 60)'/>`;}).join('');
  $('donut-legend').innerHTML=top.map((d,i)=>`<span><i style='background:${COLORS[i%8]}'></i>${esc(d.package)} ${pct(d.pct)}</span>`).join('');}
function heat(items){
  const el=$('heat');el.innerHTML='';el.style.gridTemplateColumns='';
  if(!items.length){el.textContent='（无数据）';return;}
  const cmds=[...new Set(items.map(d=>d.command))].slice(0,20);
  const buckets=[...new Set(items.map(d=>d.bucket))].sort((a,b)=>a-b);
  const max=Math.max(1,...items.map(d=>Number(d.count||0))),m=new Map();
  items.forEach(d=>m.set(d.bucket+'|'+d.command,Number(d.count||0)));
  el.style.gridTemplateColumns='130px repeat('+buckets.length+',14px)';
  const cell=(txt,cls,title)=>{const s=document.createElement('span');s.className=cls;s.textContent=txt;if(title)s.title=title;return s;};
  el.appendChild(cell('','hmh'));
  buckets.forEach(b=>el.appendChild(cell(String(new Date(Number(b)).getHours()),'hmh',ts(b))));
  cmds.forEach(c=>{el.appendChild(cell(c,'hml',c));
    buckets.forEach(b=>{const v=m.get(b+'|'+c)||0,s=cell('','hmv',c+' · '+ts(b)+' · '+v+' 次');
      s.style.background=v?'#4f9cf9':'#1d2530';s.style.opacity=(0.15+0.85*(v/max)).toFixed(2);el.appendChild(s);});});}
function flame(items){
  const total=items.reduce((a,b)=>a+Number(b.samples||0),0);
  if(!total){$('flame').innerHTML=`<text x='8' y='20' fill='#9aa3b2' font-size='12'>（无数据）</text>`;$('flame-legend').innerHTML='';return;}
  const depth=Math.min(6,Math.max(...items.map(d=>(d.stack||[]).length))),rows=[];
  for(let d=0;d<depth;d++){const m=new Map();
    items.forEach(it=>{const f=(it.stack||[])[d];if(!f)return;m.set(f,(m.get(f)||0)+Number(it.samples||0));});
    rows.push([...m.entries()].sort((a,b)=>b[1]-a[1]));}
  let svg='';
  rows.forEach((row,d)=>{let x=0;
    row.forEach(pair=>{const w=(pair[1]/total)*800;if(w<0.7)return;
      svg+=`<rect x='${x.toFixed(1)}' y='${d*28}' width='${Math.max(0.7,w-0.7).toFixed(1)}' height='24' rx='2' fill='${d%2?'#3a6ea8':'#4f9cf9'}'/>`;
      if(w>52)svg+=`<text x='${(x+4).toFixed(1)}' y='${d*28+16}' fill='#e6e8ee' font-size='10'>${esc(String(pair[0]).slice(0,Math.floor(w/6)))}</text>`;
      x+=w;});});
  $('flame').setAttribute('viewBox','0 0 800 '+Math.max(40,depth*28));
  $('flame').innerHTML=svg;
  $('flame-legend').innerHTML=`<span>${depth} 层 · ${items.length} 条栈 · ${nf(total)} 样本</span>`;}
function miniTable(headers,rows,empty){
  const head=`<thead><tr>${headers.map(h=>`<th>${esc(h)}</th>`).join('')}</tr></thead>`;
  const body=rows.length
    ?`<tbody>${rows.map(r=>`<tr>${r.map(c=>`<td>${c}</td>`).join('')}</tr>`).join('')}</tbody>`
    :`<tbody><tr><td class='mut' colspan='${headers.length}'>${esc(empty)}</td></tr></tbody>`;
  return `<table>${head}${body}</table>`;}
function gcLegend(items){
  // 全 0 的桶是会话首个采样窗口的基线桶（按 0 差值入库），不等于「没发生 GC」——
  // 与 report 侧 `--gc-rows' 同口径：全为基线桶时给降级说明而不是铺一整张 0 表。
  const list=items||[],el=$('gc-legend');
  if(!list.length){el.textContent='';return;}
  const allZero=list.every(d=>!Number(d['gc-count']||0)&&!Number(d['gc-ms']||0));
  const noHeap=list.every(d=>d['heap-bytes']==null);
  el.innerHTML=(allZero?`<span>${esc('本期只有基线桶（GC 计数与耗时全为 0，不代表没有发生 GC）')}</span>`:'')
    +(noHeap?`<span>${esc('无堆大小样本：Emacs 31.1 以下不采集（该列显示 -）')}</span>`:'')
    +`<span>${list.length} 桶</span>`;}
function driftPanel(d){
  // 「阻塞事件」面板顶部的一行汇总 + 最近若干小时的小表。
  // 口径必须显式标注（与 report 侧 `--drift-line' 同一套措辞）：只含**命令之外**的停转，
  // 与「慢命令」的耗时不可相加；累计与最坏是高估值（每个样本最多多算一个心跳间隔）。
  const el=$('drift'),items=(d&&Array.isArray(d.items))?d.items:[];
  const th=Number((d&&d['threshold-ms'])||500),total=Number((d&&d['drift-total'])||0);
  if(!items.length){
    el.innerHTML=`<p class='mut'>${esc('本期无命令外停转记录（≥'+nf(th)+'ms；命令内停转见「慢命令」表，两者不可相加）')}</p>`;
    return;}
  const rows=items.slice(-24);
  el.innerHTML=`<p class='ok'>${esc('命令外停转（≥'+nf(th)+'ms）：本期 '+nf(total)+' 次，累计 '
      +ms(d['ms-total']||0)+'，最坏 '+ms(d['slowest-ms']||0))}</p>`
    +miniTable(['小时','次数','累计','最坏'],
      rows.map(x=>[ts(x.bucket),nf(x.count),ms(x['total-ms']),ms(x['max-ms'])]),'（无数据）')
    +`<p class='mut'>${esc('口径：仅命令之外的停转；累计与最坏为高估值（每个样本最多多算一个心跳间隔 250ms）。命令内停转见上表，两者不可相加')}</p>`
    +(items.length>rows.length
      ?`<p class='mut'>${esc('仅显示最近 '+rows.length+' 个桶（共 '+items.length+' 个）')}</p>`:'');}
function startupPanel(d){
  const el=$('startup'),s=d||{};
  if(s['session-id']==null){
    el.innerHTML=`<p class='mut'>${esc('本期无启动分解数据（需在启动结束前启用 el-chronos-mode，最早可在 early-init.el 里启用）')}</p>`;
    return;}
  const phases=s.phases||[],loads=(s.loads||[]).slice(0,10);
  const m0=phases.filter(p=>p[0]==='mode-start').map(p=>p[1]);
  const total=s['startup-ms'];
  const head=`<p class='mut'>${esc('覆盖范围：自 mode 启动起 '
    +(m0.length?ms(m0[0]):'-')+' / 总 '+(total==null?'-':ms(total))
    +'（会话 #'+s['session-id']+' · '+(s['started-at']==null?'-':ts(s['started-at']))+'）')}</p>`
    +`<p class='mut'>${esc('包加载耗时是相邻 after-load-functions 回调的时间差（近似归因），且只覆盖 mode 启动之后的 load')}</p>`;
  el.innerHTML=head
    +'<h3>阶段锚点</h3>'
    +miniTable(['阶段','耗时'],phases.map(p=>[esc(p[0]),ms(p[1])]),
      '（无阶段锚点：mode 启动时启动已结束，只能记录 mode-start 之后的阶段）')
    +'<h3>包加载 TOP（前 10）</h3>'
    +miniTable(['包','耗时'],loads.map(p=>[esc(p[0]),ms(p[1])]),
      '（无包加载明细：mode 启动时启动已结束，不记录 after-load-functions）');}
function resChart(items,key,fmt,title,color){
  // 单指标折线（CPU% / RSS 各一张）：只用 viewBox + path + 少量文字，不引图表库与 CDN（I10）。
  // null 值跳过（既不画点也不计入 max）——「没样本」不能画成 0（那是「观测到 0」）。
  const W=800,H=140,P=18,list=items||[],step=list.length>1?(W-2*P)/(list.length-1):0;
  const pts=[];
  list.forEach((d,i)=>{if(d[key]==null)return;pts.push([P+i*step,Number(d[key])]);});
  const head=`<h3>${esc(title)}</h3>`;
  if(!pts.length)return head+`<p class='mut'>${esc('（该指标本期无样本，显示 - 而非 0）')}</p>`;
  const max=Math.max(1,...pts.map(p=>p[1]));
  const ys=pts.map(p=>[p[0].toFixed(1),(H-P-(p[1]/max)*(H-2*P)).toFixed(1)]);
  const line=ys.map((p,i)=>(i?'L':'M')+p[0]+' '+p[1]).join(' ');
  const dots=ys.map(p=>`<circle cx='${p[0]}' cy='${p[1]}' r='1.5' fill='${color}'/>`).join('');
  return head
    +`<svg viewBox='0 0 ${W} ${H}' preserveAspectRatio='none' style='width:100%;height:140px'>`
    +`<path d='${line}' fill='none' stroke='${color}' stroke-width='1.6'/>${dots}`
    +`<text x='${P}' y='11' fill='#9aa3b2' font-size='10'>${esc('max '+fmt(max))}</text></svg>`
    +`<p class='mut'>${esc(list.length+' 桶 · '+pts.length+' 个有效点 · 峰值 '+fmt(max))}</p>`;}
function resPanel(d){
  // 「资源（CPU / 内存 / 负载）」面板：顶部一行窗口汇总 → CPU% / RSS 两张折线 →
  // 一行负载图例 → 三条口径说明。无数据分支必须可见（I11），措辞与 report 侧
  // `el-chronos-report--resource-degrade' 同义。
  const el=$('res'),items=(d&&Array.isArray(d.buckets))?d.buckets:[];
  if(!items.length){
    el.innerHTML=`<p class='mut'>${esc('本期无进程资源数据（hourly_resources 为空；资源采样默认关闭）')}</p>`;
    return;}
  const v=(x,f)=>x==null?'-':f(x),num=x=>Number(x).toFixed(2);
  el.innerHTML=`<p class='ok'>${esc('CPU 占用 '+v(d['cpu-pct-avg'],pct)
      +'（cpu '+v(d['cpu-ms-total'],ms)+' / 墙钟 '+v(d['wall-ms-total'],ms)+'）· RSS 峰值 '
      +v(d['rss-kb-max'],kb)+' · 线程峰值 '+v(d['threads-max'],nf))}</p>`
    +resChart(items,'cpu-pct',pct,'CPU 占用率（窗口内 CPU 时间 / 墙钟）','#4f9cf9')
    +resChart(items,'rss-kb-max',kb,'RSS 峰值','#3fb950')
    +`<div class='legend'><span><i></i>${esc('负载 1m '+v(d['load1-avg'],num))}</span>`
    +`<span><i class='b'></i>${esc('负载 5m '+v(d['load5-avg'],num))}</span>`
    +`<span><i class='c'></i>${esc('负载 15m '+v(d['load15-avg'],num))}</span>`
    +`<span class='mut'>${esc(items.length+' 桶 · '+nf(d.samples||0)+' 个负载样本')}</span></div>`
    +`<p class='mut'>${esc('口径 ①：CPU% 是「窗口内 CPU 时间增量 / 墙钟增量」，不是瞬时利用率')}</p>`
    +`<p class='mut'>${esc('口径 ②：RSS 均值与三档负载的分母是 load_n（成功取到负载的窗口数）；采集失败时均值为 null，显示 - 而非 0')}</p>`
    +`<p class='mut'>${esc('口径 ③：首窗口只建基线，会话启动后的第一个桶可能缺失，不等于「那一刻 CPU 为 0」')}</p>`;}
function healthPanel(h){
  const el=$('health');
  // 四个分支与 report 侧 `--section-health' 同序：无数据 / 没采集 / 没异常 / 完整表。
  // 顺序不可调换：analysis 在「一条 health 行都没有」时同样返回 ok-p 为 true，
  // 先判 ok-p 会把「没采集」显示成「一切正常」。
  if(!h){el.innerHTML=`<table><tbody><tr><td class='mut'>（无数据）</td></tr></tbody></table>`;return;}
  if(Number(h.rows||0)===0){
    el.innerHTML=`<p class='mut'>${esc('本期无采集数据（采集器尚未写入健康指标）')}</p>`;return;}
  if(h['ok-p']){
    el.innerHTML=`<p class='ok'>${esc('本期无采集异常（flush '+nf(h['flush-count']||0)+' 次，平均 '
      +(h['flush-avg-ms']==null?'-':ms(h['flush-avg-ms']))+'）'
      // 撞锁重试是中性度量（不进 ok-p）：>0 时在摘要里点出来，否则「有锁竞争但已自愈」这一
      // 常态永远看不见。为 0 时不追加，保持文案与既有断言逐字一致。
      +(Number(h['busy-retries']||0)>0?'；撞锁重试 '+nf(h['busy-retries'])+' 次':''))}</p>`;
    if(!Number(h['flush-count']||0))el.innerHTML+=`<p class='mut'>${esc('（本期无 flush 记录）')}</p>`;
    return;}
  const v=k=>h[k]==null?'-':nf(h[k]);
  el.innerHTML=miniTable(['指标','值'],[
    ['丢弃命令',v('dropped-commands')],['丢弃事件',v('dropped-events')],
    ['flush 失败',v('flush-failures')],['flush 次数',v('flush-count')],
    ['flush 总耗时',h['flush-ms']==null?'-':ms(h['flush-ms'])],
    ['flush 平均耗时',h['flush-avg-ms']==null?'-':ms(h['flush-avg-ms'])],
    ['撞锁重试',v('busy-retries')],
    ['采样窗口丢失',v('sample-misses')],['健康行数',v('rows')]],'（无数据）');}
function confPanel(c){
  const el=$('conf'),items=(c&&c.sessions)||[];
  if(!items.length){
    el.innerHTML=`<p class='mut'>${esc('本期无会话变更记录（会话启动时未取到 git-head / config-sig，或窗口内没有会话）')}</p>`;
    return;}
  const dig=v=>esc(String(v||'').slice(0,8)||'-');
  el.innerHTML=miniTable(['会话启动时间','提交','配置指纹','变化'],
      items.map(x=>[ts(x['started-at']),dig(x['git-head']),dig(x['config-sig']),
        x.changed?`<span class='ok'>✓</span>`:'-']),
      '（无数据）')
    +`<p class='mut'>${esc('共 '+items.length+' 个会话 · 变化 '+nf(c.changes||0)+' 次'
      +(c.truncated?'（仅显示最近 '+items.length+' 个）':''))}</p>`;}
function table(key){
  const cols=COLS[key],rows=(S.data[key]&&S.data[key].items)||[],q=S.q[key].toLowerCase();
  let data=rows.slice();
  if(q)data=data.filter(r=>cols.some(c=>String(r[c.k]==null?'':r[c.k]).toLowerCase().indexOf(q)>=0));
  const sk=S.sort[key],dir=S.dir[key];
  data.sort((a,b)=>{const x=a[sk],y=b[sk];
    const p=(typeof x==='number'||typeof y==='number')?Number(x||0)-Number(y||0):String(x||'').localeCompare(String(y||''));
    return p*dir;});
  const pages=Math.max(1,Math.ceil(data.length/S.per)),page=Math.min(Math.max(1,S.page[key]||1),pages);
  S.page[key]=page;S.view[key]=data;
  const slice=data.slice((page-1)*S.per,page*S.per);
  const cellHtml=(c,r)=>c.f?c.f(r[c.k]):(c.n?nf(r[c.k]):esc(r[c.k]));
  const head=`<thead><tr>${cols.map(c=>`<th data-t='${key}' data-k='${c.k}'>${c.t}${sk===c.k?(dir<0?' ↓':' ↑'):''}</th>`).join('')}</tr></thead>`;
  const body=slice.length
    ?`<tbody>${slice.map((r,i)=>`<tr data-t='${key}' data-i='${(page-1)*S.per+i}'>${cols.map(c=>`<td>${cellHtml(c,r)}</td>`).join('')}</tr>`).join('')}</tbody>`
    :`<tbody><tr><td class='mut' colspan='${cols.length}'>${esc(EMPTY[key]||'（无数据）')}</td></tr></tbody>`;
  const foot=`<tfoot><tr><td colspan='${cols.length}'>共 ${data.length} 行 · 第 ${page}/${pages} 页 <button data-pg='${key}' data-d='-1'>上一页</button> <button data-pg='${key}' data-d='1'>下一页</button></td></tr></tfoot>`;
  $('t-'+key).innerHTML=head+body+foot;}
function panel(title,obj){
  $('panel').classList.add('open');
  $('panel-body').innerHTML=`<h3>${esc(title)}</h3><pre>${esc(JSON.stringify(obj,null,1))}</pre>`;}
async function openEvent(id){
  $('panel').classList.add('open');$('panel-body').textContent='加载中…';
  try{
    const ev=await getJSON('/api/event',{id:id});
    if(!ev){$('panel-body').innerHTML=`<h3>事件 #${esc(id)}</h3><p class='mut'>未找到（可能已被保留策略清理）</p>`;return;}
    const st=(ev.stack||[]).map(f=>`<li>${esc(f)}</li>`).join('');
    $('panel-body').innerHTML=`<h3>事件 #${esc(ev.id)} · ${esc(ev.kind)}</h3>
      <p class='mut'>耗时 ${ms(ev['duration-ms'])} · 命令 ${esc(ev.command)}</p>
      <h4>调用栈</h4><ul>${st||'<li class=mut>（无）</li>'}</ul>
      <h4>上下文</h4><pre>${esc(JSON.stringify(ev.context==null?'':ev.context,null,1))}</pre>`;
  }catch(err){$('panel-body').textContent='加载失败：'+err.message;}}
async function load(){
  $('status').textContent='加载中…';
  try{
    const [sum,func,slow,pkg,tr,hm,st,sess,block,reg,gcD,suD,heD,cfD,drD,rsD]=await Promise.all([
      getJSON('/api/summary'),getJSON('/api/top-functions',{limit:50}),getJSON('/api/slow-commands',{limit:50}),
      getJSON('/api/packages'),getJSON('/api/trend'),getJSON('/api/heatmap',{limit:12}),
      getJSON('/api/stacks',{limit:40}),getJSON('/api/sessions'),getJSON('/api/blocking',{limit:30}),
      getJSON('/api/regressions',{limit:30}),
      getJSON('/api/gc'),getJSON('/api/startup'),getJSON('/api/health'),getJSON('/api/config-history'),
      getJSON('/api/drift'),getJSON('/api/resources')]);
    S.data={sum:sum,func:func,slow:slow,pkg:pkg,trend:tr,heat:hm,stacks:st,sess:sess,block:block,reg:reg,
      gc:gcD,startup:suD,health:heD,conf:cfD,drift:drD,res:rsD};
    cards(sum.overview||{},rsD);trend(tr.items||[]);donut(pkg.items||[]);heat(hm.items||[]);flame(st.items||[]);
    gcLegend(gcD.items||[]);resPanel(rsD);startupPanel(suD);healthPanel(heD);confPanel(cfD);driftPanel(drD);
    ['slow','func','block','reg','sess','gc'].forEach(table);
    $('status').textContent='更新于 '+new Date().toLocaleTimeString();
  }catch(e){$('status').textContent='加载失败：'+e.message;}}
function setAuto(){
  $('auto').checked=S.auto;
  if(S.timer){clearInterval(S.timer);S.timer=null;}
  if(S.auto)S.timer=setInterval(load,30000);}
document.addEventListener('click',e=>{
  const cl=sel=>e.target.closest?e.target.closest(sel):null,th=cl('th[data-k]');
  if(th){const k=th.dataset.k,t=th.dataset.t;
    if(S.sort[t]===k)S.dir[t]=-S.dir[t];else{S.sort[t]=k;S.dir[t]=-1;}
    table(t);return;}
  const pg=cl('button[data-pg]');
  if(pg){S.page[pg.dataset.pg]=(S.page[pg.dataset.pg]||1)+Number(pg.dataset.d);table(pg.dataset.pg);return;}
  const rb=cl('button[data-r]');
  if(rb){S.range=rb.dataset.r;ranges();load();return;}
  const tr=cl('tr[data-t]');if(!tr)return;
  const t=tr.dataset.t,o=S.view[t][Number(tr.dataset.i)];if(!o)return;
  if(t==='block'&&o.id!=null)openEvent(o.id);else panel(t,o);});
$('refresh').onclick=()=>load();
$('panel-close').onclick=()=>$('panel').classList.remove('open');
$('auto').onchange=e=>{S.auto=e.target.checked;setAuto();};
$('q-slow').oninput=e=>{S.q.slow=e.target.value;S.page.slow=1;table('slow');};
$('q-func').oninput=e=>{S.q.func=e.target.value;S.page.func=1;table('func');};
ranges();setAuto();load();
"
  "内嵌 JS：并发 fetch 全部只读接口 → 渲染卡片 / 折线 / 环图 / 热力 / 火焰图 / 表格；
表格支持搜索、排序、前端分页；点击行打开下钻面板（阻塞事件走 `/api/event'）；30s 自动刷新可关。")

(defun el-chronos-web--index-html ()
  "拼出 dashboard HTML 全文。
CSS 与 JS 全部内嵌，`src='' / `href='' 均无外部地址（除同源 API 与站内锚点），离线可用。"
  (concat "<!DOCTYPE html>\n<html lang='zh-CN'>\n<head>\n<meta charset='utf-8'>\n"
          "<meta name='viewport' content='width=device-width,initial-scale=1'>\n"
          "<title>el-chronos dashboard</title>\n<style>\n"
          el-chronos-web--css
          "</style>\n</head>\n"
          el-chronos-web--markup
          "<script>\n"
          el-chronos-web--script
          "</script>\n</body>\n</html>\n"))

(provide 'el-chronos-web)

;;; el-chronos-web.el ends here
