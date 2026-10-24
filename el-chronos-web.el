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
    ("/api/regressions" . el-chronos-web--route-regressions)
    ("/api/event" . el-chronos-web--route-event)
    ("/api/export.csv" . el-chronos-web--route-export-csv))
  "路由表：路径 → 处理函数。全部只读，没有任何写入 / 执行入口。")

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
但可见面在 Emacs 而不是公网响应体）。"
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
                                   (plist-get resp :body) (plist-get resp :headers))))

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

(defun el-chronos-web--csv-string (range)
  "生成 RANGE 的 CSV 全文：overview + 7 个明细区块，用 `# section:' 注释行分隔。
字段一律保持原始值（毫秒/计数），便于下游脚本解析。"
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
      el-chronos-web--csv-sections ""))))

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

(defun el-chronos-web--route-regressions (params)
  "GET /api/regressions：按 `el-chronos-regression-window-days' 判定的回归列表。"
  (el-chronos-web--list-response params #'el-chronos-analysis-regressions))

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

(defun el-chronos-web-running-p ()
  "Web server 是否正在运行。"
  (and (processp el-chronos-web--process)
       (process-live-p el-chronos-web--process)))

(defun el-chronos-web-start (&optional port)
  "启动 Web dashboard，返回 server 进程对象。
只绑定 127.0.0.1 的 PORT（默认 `el-chronos-web-port'）；已在运行时先关闭再启动。
端口占用或其他启动失败一律 `user-error'，**不自动换端口**（I8 / I11）。

message 与返回值都反映**实际绑定**的端口：PORT 为 0 时由内核分配，此时显示的仍是
入参 0 就毫无意义，故统一取 `process-contact' 的 `:service'（取不到才回落 PORT）。
调用方可用 `(process-contact (el-chronos-web-start))' 核验绑定地址。"
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
                              (error-message-string err))))))
    (setq el-chronos-web--process proc)
    (message "el-chronos Web dashboard：http://%s:%s/" el-chronos-web--host
             (or (process-contact proc :service) port))
    proc))

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
<section><h2>包 / 模块占比</h2><div style='display:flex;gap:16px;flex-wrap:wrap;align-items:center'><svg id='donut' viewBox='0 0 120 120' style='width:120px;height:120px'></svg><div class='legend' id='donut-legend' style='flex-direction:column;gap:4px'></div></div></section>
<section><h2>用法热力</h2><div class='hm' id='heat'></div></section>
<section><h2>慢命令</h2><input id='q-slow' placeholder='搜索命令…'><table id='t-slow'></table></section>
<section><h2>热点函数</h2><input id='q-func' placeholder='搜索函数 / 包…'><table id='t-func'></table></section>
<section><h2>阻塞事件</h2><table id='t-block'></table></section>
<section><h2>回归</h2><table id='t-reg'></table></section>
<section><h2>会话</h2><table id='t-sess'></table></section>
<section><h2>火焰图（调用栈）</h2><svg id='flame' viewBox='0 0 800 200' preserveAspectRatio='none' style='width:100%;height:200px'></svg><div class='legend' id='flame-legend'></div></section>
</main>
<aside id='panel'><button id='panel-close'>关闭</button><div id='panel-body'></div></aside>
"
  "内嵌页面结构（顶栏 → 概览 → 趋势 → 占比 → 热力 → 慢命令 → 热点函数 → 阻塞 → 回归 → 会话 → 火焰图 + 下钻侧栏）。")

(defconst el-chronos-web--script
  "
const RANGES=['1d','7d','30d'];
const S={range:'7d',auto:true,timer:null,per:10,data:{},view:{},
  sort:{slow:'total-ms',func:'self-ms',block:'duration-ms',sess:'started-at',reg:'growth'},
  dir:{slow:-1,func:-1,block:-1,sess:-1,reg:-1},
  page:{slow:1,func:1,block:1,sess:1,reg:1},q:{slow:'',func:'',block:'',sess:'',reg:''}};
const $=id=>document.getElementById(id);
const DQ=String.fromCharCode(34),SQ=String.fromCharCode(39);
const esc=v=>{const s=String(v==null?'':v);return s.split('&').join('&amp;').split('<').join('&lt;').split('>').join('&gt;').split(DQ).join('&quot;').split(SQ).join('&#39;');};
const nf=v=>Number(v||0).toLocaleString();
const ms=v=>{v=Number(v||0);if(v>=1000)return (v/1000).toFixed(2)+'s';return v>=1?v.toFixed(1)+'ms':Math.round(v*1000)+'us';};
const bytes=v=>{v=Number(v||0);const u=['B','KB','MB','GB'];let i=0;while(v>=1024&&i<3){v=v/1024;i++;}return v.toFixed(i?1:0)+u[i];};
const ts=v=>new Date(Number(v||0)).toLocaleString(),pct=v=>Number(v||0).toFixed(1)+'%';
const COLORS=['#4f9cf9','#f0b429','#3fb950','#ef5b5b','#a371f7','#79c0ff','#d29922','#8b949e'];
const COLS={
 slow:[{k:'name',t:'命令'},{k:'count',t:'次数',n:1},{k:'total-ms',t:'总耗时',f:ms},{k:'avg-ms',t:'均值',f:ms},{k:'max-ms',t:'最大',f:ms},{k:'aborted',t:'中断',n:1}],
 func:[{k:'function',t:'函数'},{k:'package',t:'包/模块'},{k:'self-ms',t:'self',f:ms},{k:'samples',t:'样本',n:1},{k:'pct',t:'占比',f:pct},{k:'file',t:'文件'}],
 block:[{k:'id',t:'#'},{k:'ts',t:'时间',f:ts},{k:'duration-ms',t:'耗时',f:ms},{k:'command',t:'命令'},{k:'mode',t:'mode'},{k:'project',t:'项目'}],
 sess:[{k:'id',t:'#'},{k:'started-at',t:'启动',f:ts},{k:'startup-ms',t:'启动耗时',f:ms},{k:'emacs-version',t:'Emacs'},{k:'host',t:'主机'}],
 reg:[{k:'function',t:'函数'},{k:'current-ms',t:'当前',f:ms},{k:'previous-ms',t:'上一窗口',f:ms},{k:'growth',t:'增长',f:v=>'+'+Math.round(Number(v||0)*100)+'%'},{k:'current-samples',t:'样本',n:1}]};
async function getJSON(path,extra){
  const q=new URLSearchParams(Object.assign({range:S.range},extra||{}));
  const r=await fetch(path+'?'+q.toString(),{cache:'no-store'});
  if(!r.ok)throw new Error(path+' -> '+r.status);
  return r.json();}
function ranges(){
  $('ranges').innerHTML=RANGES.map(r=>`<button data-r='${r}'${r===S.range?\" class='on'\":''}>${r}</button>`).join('');
  $('csv').setAttribute('href','/api/export.csv?range='+S.range);}
function cards(o){
  const it=[['命令数',nf(o.commands)],['慢命令',nf(o['slow-commands'])],['阻塞总时长',ms(o['blocked-ms'])],
    ['采样点数',nf(o.samples)],['启动中位',o['startup-ms']==null?'-':ms(o['startup-ms'])],
    ['会话数',nf(o.sessions)],['数据库',bytes(o['db-size'])]];
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
    :`<tbody><tr><td class='mut' colspan='${cols.length}'>（无数据）</td></tr></tbody>`;
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
    const [sum,func,slow,pkg,tr,hm,st,sess,block,reg]=await Promise.all([
      getJSON('/api/summary'),getJSON('/api/top-functions',{limit:50}),getJSON('/api/slow-commands',{limit:50}),
      getJSON('/api/packages'),getJSON('/api/trend'),getJSON('/api/heatmap',{limit:12}),
      getJSON('/api/stacks',{limit:40}),getJSON('/api/sessions'),getJSON('/api/blocking',{limit:30}),
      getJSON('/api/regressions',{limit:30})]);
    S.data={sum:sum,func:func,slow:slow,pkg:pkg,trend:tr,heat:hm,stacks:st,sess:sess,block:block,reg:reg};
    cards(sum.overview||{});trend(tr.items||[]);donut(pkg.items||[]);heat(hm.items||[]);flame(st.items||[]);
    ['slow','func','block','reg','sess'].forEach(table);
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
