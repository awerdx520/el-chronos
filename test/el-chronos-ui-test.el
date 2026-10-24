;;; el-chronos-ui-test.el --- 可视化层测试（dashboard 降级页 + 内嵌 Web）  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Thomas

;; Author: Thomas
;; Keywords: tools, performance
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; T10b：为可视化层（T8 dashboard / T9 web）补 ERT 覆盖，并固化 T8 遗留的 `d' 键回归。
;;
;; 覆盖范围：
;;   1. dashboard 降级路径（ETAF 缺席 → tabulated-list 页）：形态、区块、快捷键、范围切换、
;;      空库占位、纯函数（`--bar' / `--scale' / `--range->days' / `--to-text-bars'）。
;;   2. Web server：启停幂等、`/` 与 JSON 接口、404 / 405、端口占用 `user-error'、
;;      只绑 loopback。
;;   3. `d' 键回归（T8 遗留）：fixture DB 里 1 条 block 事件 → 下钻 → `*el-chronos-event*'
;;      含完整栈帧。
;;
;; 设计约束（与仓库不变量对应）：
;;   - 不依赖 ETAF：测试统一把 `el-chronos-dashboard--etaf-available-p' 绑成 nil，走 I9/I11
;;     要求的降级路径（batch 下 `emacs -Q' 本就没有 ETAF，显式绑定是为了在有 ETAF 的机器上也
;;     测同一条路径）。
;;   - 不碰真实数据库：所有涉及库的用例把 `el-chronos-db-path' 绑到临时目录（I3），退出时
;;     `el-chronos-store-close' 并删目录，仓库根与 `~/.emacs.d' 都不落运行产物。
;;   - HTTP 客户端用内置 `make-network-process' 手写（不调 curl），batch 下靠
;;     `accept-process-output' 轮询并有总超时，避免无输出时挂死。
;;   - server 一律起在 `:service 0'（内核分配端口）并 `unwind-protect' 关闭：既避免与用户
;;     正在运行的 dashboard（默认 8787）抢端口，也保证用例失败后不留监听（I5 精神）。
;;
;; 运行：emacs -Q --batch -L . -L test -l test/el-chronos-ui-test.el \
;;              -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'json)
(require 'sqlite)
(require 'el-chronos)
(require 'el-chronos-store)
(require 'el-chronos-collect)            ; `--heartbeat'：验证渲染不新增假阻塞
(require 'el-chronos-dashboard)
(require 'el-chronos-web)

;; ETAF / ebox 是可选依赖（`make test' 的 load-path 里没有）：只为渲染用例的函数调用
;; 消掉「未知函数」字节编译告警，不是运行期依赖。
(declare-function etaf-mount "etaf" (buffer-or-name view &optional options))
(declare-function etaf-unmount "etaf" (&optional runtime))
(declare-function etaf-runtime-for-buffer "etaf" (buffer-or-name))
(declare-function ebox-buffer-mount "ebox" (buffer-or-name))
(declare-function ebox-mount-root "ebox" (mount))
(declare-function ebox-node-children "ebox" (node))
(declare-function ebox-node-geometry "ebox" (node))
(declare-function ebox-node-classes "ebox" (node))

;;; 测试夹具与辅助

(defvar el-chronos-ui-test--http-timeout 5.0
  "单次 HTTP 往返的总超时（秒）；超时后返回已收到的内容，不让用例挂死。")

(defvar el-chronos-ui-test--port nil
  "当前用例里 server 实际监听的端口；由 `--with-server' 绑定。")

(defvar el-chronos-ui-test--event-buffer-name "*el-chronos-event*"
  "阻塞事件完整栈的 buffer 名（与 `el-chronos-report--event-buffer-name' 一致）。")

(defmacro el-chronos-ui-test--with-temp-db (&rest body)
  "在临时数据库上执行 BODY。
把 `el-chronos-db-path' 绑到临时目录下的 `chronos.sqlite'（I3：数据只写该文件），
退出时关闭句柄并删掉整个临时目录，保证不污染仓库与 `~/.emacs.d'。"
  (declare (indent 0) (debug t))
  `(let* ((el-chronos-ui-test--dir (make-temp-file "el-chronos-ui-test-" t))
          (el-chronos-db-path (expand-file-name "chronos.sqlite" el-chronos-ui-test--dir)))
     (unwind-protect
         (progn ,@body)
       (ignore-errors (el-chronos-store-close))
       (ignore-errors (delete-directory el-chronos-ui-test--dir t)))))

(defmacro el-chronos-ui-test--with-fallback (&rest body)
  "强制 dashboard 走 ETAF 缺席的降级路径执行 BODY。
退出时杀掉 `*el-chronos*' 并清空 UI 状态，避免用例之间互相污染。"
  (declare (indent 0) (debug t))
  `(let ((el-chronos-dashboard--etaf-available-p nil))
     (unwind-protect
         (progn ,@body)
       (when (get-buffer el-chronos-dashboard--buffer-name)
         (kill-buffer (get-buffer el-chronos-dashboard--buffer-name)))
       (setq el-chronos-dashboard--state nil
             el-chronos-dashboard--snapshot nil))))

(defmacro el-chronos-ui-test--with-server (&rest body)
  "在自动分配的 loopback 端口上起 server 执行 BODY，绑定 `--port'。
端口用 `:service 0' 让内核分配：不与用户运行中的 dashboard（默认 8787）冲突；
无论 BODY 成败都关闭 server，保证不留监听端口。"
  (declare (indent 0) (debug t))
  `(progn
     (ignore-errors (el-chronos-web-stop))
     (let* ((el-chronos-ui-test--proc (el-chronos-web-start 0))
            (el-chronos-ui-test--port (process-contact el-chronos-ui-test--proc :service)))
       (unwind-protect
           (progn ,@body)
         (ignore-errors (el-chronos-web-stop))))))

(defun el-chronos-ui-test--parse-response (raw)
  "把响应原始字节 RAW 拆成 plist：`:status'（整数）/`:status-line'/`:headers'/`:body'。
头部是纯 ASCII，直接在原始字节上按 `\\r\\n' 切；只有 body 按 `utf-8-unix' 解码。
不用裸 `utf-8' 解码：它的 EOL 类型未定，遇到 CRLF 会按 DOS 解码把 CR 吃掉（实测 404/405
这类含中文的 text/plain 响应会踩到，导致 `:headers' 变空）。
缺分隔符时 `:status' 为 nil，便于用例断言「没有完整响应」。"
  (let ((split (string-match "\r\n\r\n" raw)))
    (if (null split)
        (list :status nil :status-line "" :headers "" :body "")
      (let* ((lines (split-string (substring raw 0 split) "\r\n" t))
             (status-line (or (car lines) "")))
        (list :status (and (string-match "\\`HTTP/[0-9.]+ +\\([0-9]+\\)" status-line)
                           (string-to-number (match-string 1 status-line)))
              :status-line status-line
              :headers (mapconcat #'identity (cdr lines) "\n")
              :body (decode-coding-string (substring raw (+ split 4)) 'utf-8-unix))))))

(defun el-chronos-ui-test--http (method path &optional port)
  "用内置 `make-network-process' 向 127.0.0.1:PORT 发 METHOD PATH 请求，返回响应 plist。
请求带 `Connection: close'，读到对端 EOF 或超过 `--http-timeout' 秒即返回。
客户端按 binary 读（字节边界自己掌握，见 `--parse-response'），并挂 `ignore' 作 sentinel：
默认 sentinel 会把「connection broken」写进 process buffer，污染响应体。"
  (let* ((port (or port el-chronos-ui-test--port el-chronos-web-port))
         (buffer (generate-new-buffer " *el-chronos-ui-test-http*"))
         (proc (make-network-process :name "el-chronos-ui-test-client"
                                     :buffer buffer
                                     :host el-chronos-web--host
                                     :service port
                                     :family 'ipv4
                                     :coding 'binary
                                     :sentinel #'ignore
                                     :noquery t))
         (deadline (+ (float-time) el-chronos-ui-test--http-timeout)))
    (unwind-protect
        (progn
          (process-send-string
           proc (format "%s %s HTTP/1.1\r\nHost: %s\r\nConnection: close\r\n\r\n"
                        method path el-chronos-web--host))
          (while (and (process-live-p proc) (< (float-time) deadline))
            (accept-process-output proc 0.05))
          (el-chronos-ui-test--parse-response (with-current-buffer buffer (buffer-string))))
      (when (process-live-p proc) (ignore-errors (delete-process proc)))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(defun el-chronos-ui-test--json (response)
  "把 RESPONSE 的 body 解析成 plist；body 非 JSON 时用例直接失败。"
  (let ((body (plist-get response :body)))
    (should (stringp body))
    (json-parse-string body :object-type 'plist)))

(defun el-chronos-ui-test--insert-block-event (db)
  "在 DB 的 `slow_events' 插入一条 kind=\"block\" 的事件，返回该事件 id。
栈与 context 各写一个 JSON 字段，用于覆盖 `--blocker-detail' 与 `d' 键的完整路径。"
  (let ((context (make-hash-table :test #'equal)))
    (puthash "mode" "emacs-lisp-mode" context)
    (puthash "project" "el-chronos" context)
    (sqlite-execute db
                    (concat "INSERT INTO slow_events (ts, duration_ms, kind, command,"
                            " stack_json, context_json) VALUES (?, ?, ?, ?, ?, ?)")
                    (list (truncate (* 1000 (float-time))) 3000.0 "block"
                          "el-chronos-test-cmd"
                          (json-serialize (vector "el-chronos-test-frame-a"
                                                  "el-chronos-test-frame-b"))
                          (json-serialize context)))
    (or (caar (sqlite-select db "SELECT max(id) FROM slow_events")) 0)))

(defun el-chronos-ui-test--count-block-events ()
  "当前测试库里 `slow_events' 中 kind=\"block\" 的行数。
心跳假阻塞的判据：渲染前后该计数必须不变（`el-chronos-collect--heartbeat' 判定阻塞后
把事件塞进 store 的待写缓冲，`el-chronos-store-flush' 之后才落库，故调用前先 flush）。"
  (when-let* ((db (el-chronos-store-open)))
    (or (caar (sqlite-select db "SELECT count(*) FROM slow_events WHERE kind='block'")) 0)))

;;; dashboard：形态与内容（降级路径）

(ert-deftest el-chronos-ui-test-dashboard-etaf-absent ()
  "未加载 ETAF 时 `el-chronos-dashboard-etaf-available-p' 必须为 nil（I9 降级前提）。"
  (skip-unless (not (featurep 'etaf)))
  (should-not (el-chronos-dashboard-etaf-available-p))
  ;; 显式绑定探针变量后也必须是 nil：函数不得绕过探测重新 require
  (let ((el-chronos-dashboard--etaf-available-p nil))
    (should-not (el-chronos-dashboard-etaf-available-p))))

(ert-deftest el-chronos-ui-test-dashboard-degraded-page ()
  "ETAF 缺席时 `(el-chronos-dashboard)' 不报错，`*el-chronos*' 是 tabulated-list-mode。"
  (el-chronos-ui-test--with-temp-db
    (el-chronos-ui-test--with-fallback
      (let ((buffer (el-chronos-dashboard "7d")))
        (should (bufferp buffer))
        (should (equal el-chronos-dashboard--buffer-name (buffer-name buffer)))
        (with-current-buffer buffer
          (should (eq major-mode 'tabulated-list-mode))
          (should (derived-mode-p 'tabulated-list-mode)))))))

(ert-deftest el-chronos-ui-test-dashboard-sections ()
  "降级页必须同时含「慢命令」与「热点函数」两个区块（不是空壳页面）。"
  (el-chronos-ui-test--with-temp-db
    (el-chronos-ui-test--with-fallback
      (let ((buffer (el-chronos-dashboard "7d")))
        (with-current-buffer buffer
          (should (string-match-p "慢命令" (buffer-string)))
          (should (string-match-p "热点函数" (buffer-string)))
          (should (string-match-p (regexp-quote el-chronos-dashboard--section-slow)
                                  (buffer-string)))
          (should (string-match-p (regexp-quote el-chronos-dashboard--section-functions)
                                  (buffer-string))))))))

(ert-deftest el-chronos-ui-test-dashboard-keys ()
  "`1'/`7'/`3' 绑定到对应范围命令，`g'/`r'/`d'/`q' 均有绑定。"
  (el-chronos-ui-test--with-temp-db
    (el-chronos-ui-test--with-fallback
      (with-current-buffer (el-chronos-dashboard "7d")
        (should (eq (key-binding (kbd "1")) #'el-chronos-dashboard-range-1d))
        (should (eq (key-binding (kbd "7")) #'el-chronos-dashboard-range-7d))
        (should (eq (key-binding (kbd "3")) #'el-chronos-dashboard-range-30d))
        (should (eq (key-binding (kbd "g")) #'el-chronos-dashboard-refresh))
        (should (eq (key-binding (kbd "r")) #'el-chronos-dashboard-toggle-auto-refresh))
        (should (eq (key-binding (kbd "d")) #'el-chronos-dashboard-show-event))
        (should (eq (key-binding (kbd "q")) #'el-chronos-dashboard-quit))))))

(ert-deftest el-chronos-ui-test-dashboard-range-switch ()
  "按 `3'（`el-chronos-dashboard-range-30d'）后 UI 状态的 range 变成 \"30d\"。"
  (el-chronos-ui-test--with-temp-db
    (el-chronos-ui-test--with-fallback
      (el-chronos-dashboard "7d")
      (should (equal "7d" (plist-get (el-chronos-dashboard--ensure-state nil) :range)))
      (el-chronos-dashboard-range-1d)
      (should (equal "1d" (plist-get (el-chronos-dashboard--ensure-state nil) :range)))
      (el-chronos-dashboard-range-30d)
      (should (equal "30d" (plist-get (el-chronos-dashboard--ensure-state nil) :range)))
      (with-current-buffer (get-buffer el-chronos-dashboard--buffer-name)
        (should (string-match-p "范围 30 天" header-line-format))))))

(ert-deftest el-chronos-ui-test-dashboard-empty-db ()
  "空库时不报错：两个区块各保留一行「（无数据）」，总条目数为 4。"
  (el-chronos-ui-test--with-temp-db
    (el-chronos-ui-test--with-fallback
      (let ((buffer (el-chronos-dashboard "1d")))
        (should (bufferp buffer))
        (with-current-buffer buffer
          (should (string-match-p el-chronos-dashboard--empty (buffer-string)))
          ;; 2 行区块标题 + 2 行空占位
          (should (= 4 (length (el-chronos-dashboard--degraded-entries))))
          (should (= 4 (length tabulated-list-entries))))))))

(ert-deftest el-chronos-ui-test-dashboard-bar ()
  "`--bar' 按比例渲染 `█'：满值取满宽度，0 / 非数字返回空串，非零至少 1 个字符。"
  (let ((full (el-chronos-dashboard--bar 5 5 4)))
    (should (stringp full))
    (should (= 4 (length full)))
    (should (equal (make-string 4 ?█) full))
    (should (string-empty-p (el-chronos-dashboard--bar 0 5 4)))
    (should (string-empty-p (el-chronos-dashboard--bar 5 5 0)))
    (should (= 1 (length (el-chronos-dashboard--bar 1 1000 4))))))

(ert-deftest el-chronos-ui-test-dashboard-range->days ()
  "`--range->days' 的映射：\"1d\"→1、\"7d\"→7、\"30d\"→30，未知值回落 7。
符号写法与字符串写法必须同结果（bug 修复点：analysis 层只认符号）。"
  (should (= 1 (el-chronos-dashboard--range->days "1d")))
  (should (= 7 (el-chronos-dashboard--range->days "7d")))
  (should (= 30 (el-chronos-dashboard--range->days "30d")))
  (should (= 7 (el-chronos-dashboard--range->days "xx")))
  (should (= 1 (el-chronos-dashboard--range->days '1d)))
  (should (= 7 (el-chronos-dashboard--range->days '7d)))
  (should (= 30 (el-chronos-dashboard--range->days '30d)))
  (should (= 7 (el-chronos-dashboard--range->days nil))))

(ert-deftest el-chronos-ui-test-dashboard-range-symbol ()
  "`--range-symbol' 把字符串/符号统一归一为 analysis 认的符号；非法值回落 `7d'。
范围切换 bug 的根因就是这里：dashboard 存字符串、analysis 用符号键。"
  (should (eq '1d (el-chronos-dashboard--range-symbol "1d")))
  (should (eq '7d (el-chronos-dashboard--range-symbol "7d")))
  (should (eq '30d (el-chronos-dashboard--range-symbol "30d")))
  (should (eq '1d (el-chronos-dashboard--range-symbol '1d)))
  (should (eq '7d (el-chronos-dashboard--range-symbol '7d)))
  (should (eq '30d (el-chronos-dashboard--range-symbol '30d)))
  ;; 非法值一律回落 7d，不抛错
  (should (eq '7d (el-chronos-dashboard--range-symbol nil)))
  (should (eq '7d (el-chronos-dashboard--range-symbol "xx")))
  (should (eq '7d (el-chronos-dashboard--range-symbol "")))
  (should (eq '7d (el-chronos-dashboard--range-symbol 30)))
  ;; 反向归一（状态存字符串）与 `--range->days' 互通
  (should (equal "1d" (el-chronos-dashboard--range-string "1d")))
  (should (equal "30d" (el-chronos-dashboard--range-string '30d)))
  (should (equal "7d" (el-chronos-dashboard--range-string "xx")))
  (should (= 1 (el-chronos-dashboard--range->days
                (el-chronos-dashboard--range-symbol "1d")))))

(ert-deftest el-chronos-ui-test-dashboard-load-snapshot-symbol ()
  "`--load-snapshot' 必须把符号（而非字符串）交给 analysis。
用 `cl-letf' 捕获 `el-chronos-analysis-overview' 的实参：这是 bug 的可观测面——
之前传 \"1d\" 字符串，analysis 的 `alist-get' 取不到符号键而静默回落 7 天。"
  (el-chronos-ui-test--with-temp-db
    (let ((captured nil))
      (cl-letf (((symbol-function 'el-chronos-analysis-overview)
                 (lambda (range) (push range captured) nil)))
        (el-chronos-dashboard--load-snapshot "1d")
        (should (equal '(1d) captured))
        (setq captured nil)
        (el-chronos-dashboard--load-snapshot "30d")
        (should (equal '(30d) captured))
        (setq captured nil)
        (el-chronos-dashboard--load-snapshot '7d)
        (should (equal '(7d) captured))
        (setq captured nil)
        ;; 非法值也必须是符号（7d），不能把字符串或 nil 漏给 analysis
        (el-chronos-dashboard--load-snapshot "xx")
        (should (equal '(7d) captured)))
      ;; 快照同时暴露原始入参与归一后的符号
      (let ((snapshot (el-chronos-dashboard--load-snapshot "1d")))
        (should (equal "1d" (plist-get snapshot :range)))
        (should (eq '1d (plist-get snapshot :range-symbol)))))))

(ert-deftest el-chronos-ui-test-dashboard-range-symbol-filters-data ()
  "端到端：切 1d 只取 1 天内的数据，切 7d 两条都在。
fixture 放一条「1 小时内」（确定落在 1d 窗口内）与一条「5 天前」（只在 7d 窗口内）；
不用恰好 24 小时前：那是 1d 窗口的左边界，插入时刻与查询时刻的漂移会让断言不稳定。"
  (el-chronos-ui-test--with-temp-db
    (let ((db (el-chronos-store-open))
          (now (truncate (* 1000 (float-time)))))
      (should db)
      ;; store 层开了 `foreign_keys=ON'，`commands.session_id' 必须有对应 sessions 行
      (sqlite-execute db
                      "INSERT INTO sessions (started_at, emacs_version, host) VALUES (?, ?, ?)"
                      (list (- now (* 6 86400000)) "el-chronos-test" "test-host"))
      (let ((session (caar (sqlite-select db "SELECT max(id) FROM sessions"))))
        (should (integerp session))
        (dolist (spec (list (cons "el-chronos-test-recent" (- now 3600000))
                            (cons "el-chronos-test-old" (- now (* 5 86400000)))))
          (sqlite-execute db
                          (concat "INSERT INTO commands (ts, session_id, name, duration_ms,"
                                  " mode, outcome, kind) VALUES (?, ?, ?, ?, ?, ?, ?)")
                          (list (cdr spec) session (car spec) 120.0 "emacs-lisp-mode" "ok"
                                "command"))))
      (el-chronos-ui-test--with-fallback
        (let ((one-day (el-chronos-dashboard "1d")))
          (with-current-buffer one-day
            (let ((names (mapcar (lambda (row) (plist-get row :name))
                                 (el-chronos-dashboard--snapshot-get :slow))))
              (should (member "el-chronos-test-recent" names))
              (should-not (member "el-chronos-test-old" names))
              ;; 归一后的符号必须落进快照，供断言/排查
              (should (eq '1d (el-chronos-dashboard--snapshot-get :range-symbol))))))
        (el-chronos-dashboard "7d")
        (let ((names (mapcar (lambda (row) (plist-get row :name))
                             (el-chronos-dashboard--snapshot-get :slow))))
          (should (member "el-chronos-test-recent" names))
          (should (member "el-chronos-test-old" names)))))))

(ert-deftest el-chronos-ui-test-dashboard-to-text-bars ()
  "`--to-text-bars' 返回文本字符串（SVG 不可用的降级形态），空数据返回占位文本。"
  (let ((text (el-chronos-dashboard--to-text-bars
               '(:kind bars :rows ((:label "cmd" :value 5 :pct 50.0))) 40)))
    (should (stringp text))
    (should (string-match-p "cmd" text))
    (should (string-match-p "█" text)))
  ;; I11：没有数据时必须给出可见占位，而不是空串或 image
  (should (equal el-chronos-dashboard--empty
                 (el-chronos-dashboard--to-text-bars '(:kind bars :rows nil) 40))))

(ert-deftest el-chronos-ui-test-dashboard-scale ()
  "`--scale' 把 VALUES 缩放到高度 HEIGHT，返回 3 个 (IDX . Y) 点。"
  (let ((points (el-chronos-dashboard--scale '(1 5 3) 5 10)))
    (should (= 3 (length points)))
    (should (equal '(0 1 2) (mapcar #'car points)))
    ;; Y 用 SVG 习惯（0 在顶）：1/5 → 8、5/5 → 0、3/5 → 4
    (should (equal '(8 0 4) (mapcar #'cdr points)))))

;;; dashboard：`d' 键回归（T8 遗留，需真实 fixture 数据）

(ert-deftest el-chronos-ui-test-dashboard-show-event-blocker ()
  "T8 回归：fixture 里 1 条 block 事件 → 下钻选中 → `d' 键打开 `*el-chronos-event*' 且含栈帧。"
  (el-chronos-ui-test--with-temp-db
    (let ((db (el-chronos-store-open)))
      (should db)
      (let ((id (el-chronos-ui-test--insert-block-event db)))
        (should (integerp id))
        (should (> id 0))
        (el-chronos-ui-test--with-fallback
          (unwind-protect
              (progn
                (el-chronos-dashboard "7d")
                (let ((rows (el-chronos-dashboard--snapshot-get :blockers)))
                  (should (= 1 (length rows)))
                  ;; 等价于在阻塞事件表里选中该行（`:on-press' 走同一函数）
                  (el-chronos-dashboard--drill
                   :blockers (el-chronos-dashboard--row :blockers (car rows)))
                  (should (equal id (plist-get (plist-get el-chronos-dashboard--state
                                                          :selected)
                                               :event-id)))
                  (el-chronos-dashboard-show-event)
                  (should (get-buffer el-chronos-ui-test--event-buffer-name))
                  (with-current-buffer el-chronos-ui-test--event-buffer-name
                    (should (string-match-p "el-chronos-test-frame-a" (buffer-string)))
                    (should (string-match-p "el-chronos-test-frame-b" (buffer-string)))
                    (should (string-match-p "调用栈" (buffer-string))))))
            (when (get-buffer el-chronos-ui-test--event-buffer-name)
              (kill-buffer (get-buffer el-chronos-ui-test--event-buffer-name)))))))))

(ert-deftest el-chronos-ui-test-dashboard-show-event-requires-blocker ()
  "选中项不是阻塞事件时 `d' 键 `user-error'，不静默失败（I11）。"
  (el-chronos-ui-test--with-fallback
    (let ((el-chronos-dashboard--state (list :range "7d" :page 0 :selected nil)))
      (should-error (el-chronos-dashboard-show-event) :type 'user-error))))

(ert-deftest el-chronos-ui-test-dashboard-suppresses-block-event ()
  "渲染后心跳不新增 `block' 行：对照组（绕过抑制入口）会新增，抑制入口（`el-chronos-dashboard'）不会。
`el-chronos-collect--last-heartbeat' 必须在 `let' 内读取 —— 它是 dynamic binding，
出 `let' 后读到的是全局值。"
  (el-chronos-ui-test--with-temp-db
    (el-chronos-ui-test--with-fallback
      (let ((el-chronos-collect-notify-blocks nil)
            (baseline 0) (after-suppress 0) (age 0.0))
        ;; 对照组：直接跑渲染、模拟 5s 前的心跳基线 → 心跳判定为阻塞（证明假阳性真实存在）
        (let ((el-chronos-collect--last-heartbeat (- (float-time) 5.0)))
          (el-chronos-dashboard--render-fallback "7d")
          (el-chronos-collect--heartbeat))
        (el-chronos-store-flush)
        (setq baseline (el-chronos-ui-test--count-block-events))
        (should (= 1 baseline))         ; 假阳性 1 行（fixture 未插 block 行）
        ;; 修复后：走 `el-chronos-dashboard' 入口，基线被重设 → 心跳不再记阻塞
        (let ((el-chronos-collect--last-heartbeat (- (float-time) 5.0)))
          (el-chronos-dashboard "7d")
          (el-chronos-collect--heartbeat)
          (setq age (- (float-time) el-chronos-collect--last-heartbeat)))
        (el-chronos-store-flush)
        (setq after-suppress (el-chronos-ui-test--count-block-events))
        (should (= baseline after-suppress))
        ;; 基线确实被推进（不是靠运气把 gap 抹平）
        (should (< age 1.0))))))

;;; Web server：启停、路由与边界

(ert-deftest el-chronos-ui-test-web-start-stop ()
  "start 后 `running-p' 为 t；stop 后为 nil 且可再次 start（无残留）。"
  (el-chronos-ui-test--with-temp-db
    (ignore-errors (el-chronos-web-stop))
    (unwind-protect
        (progn
          (should-not (el-chronos-web-running-p))
          (let* ((proc (el-chronos-web-start 0))
                 (port (process-contact proc :service)))
            (should (processp proc))
            (should (el-chronos-web-running-p))
            (should (integerp port))
            (should (> port 0))
            (should (el-chronos-web-stop))
            (should-not (el-chronos-web-running-p)))
          (let ((again (el-chronos-web-start 0)))
            (should (processp again))
            (should (el-chronos-web-running-p))
            (should (integerp (process-contact again :service)))))
      (ignore-errors (el-chronos-web-stop)))))

(ert-deftest el-chronos-ui-test-web-running-p-returns-boolean ()
  "`el-chronos-web-running-p' 严格返回 `t' / nil，不得把 `process-live-p' 的状态关键字
（`listen' / `connect' / `stop'）泄漏给调用方。"
  (el-chronos-ui-test--with-temp-db
    (ignore-errors (el-chronos-web-stop))
    (should-not (el-chronos-web-running-p))
    (let ((proc (el-chronos-web-start 0)))
      (unwind-protect
          (progn
            (should (processp proc))
            ;; 底层状态确实不是布尔：这正是需要归一的原因
            (should-not (eq t (process-live-p proc)))
            (should (eq t (el-chronos-web-running-p))))
        (ignore-errors (el-chronos-web-stop)))
      (should-not (el-chronos-web-running-p)))))

(ert-deftest el-chronos-ui-test-web-binds-loopback ()
  "server 只绑 127.0.0.1（I8：不接受 0.0.0.0）。"
  (el-chronos-ui-test--with-temp-db
    (el-chronos-ui-test--with-server
      (should (equal "127.0.0.1" (format "%s" (nth 0 (process-contact el-chronos-ui-test--proc)))))
      (should (equal "127.0.0.1" el-chronos-web--host)))))

(ert-deftest el-chronos-ui-test-web-index-html ()
  "GET / 返回 200 + text/html，页面含 el-chronos 标识。"
  (el-chronos-ui-test--with-temp-db
    (el-chronos-ui-test--with-server
      (let ((response (el-chronos-ui-test--http "GET" "/")))
        (should (equal 200 (plist-get response :status)))
        (should (string-match-p "text/html" (plist-get response :headers)))
        (should (string-match-p "el-chronos" (plist-get response :body)))))))

(ert-deftest el-chronos-ui-test-web-api-summary ()
  "GET /api/summary 返回 200 + application/json，body 可解析且含 range / overview。"
  (el-chronos-ui-test--with-temp-db
    (el-chronos-ui-test--with-server
      (let* ((response (el-chronos-ui-test--http "GET" "/api/summary"))
             (parsed (el-chronos-ui-test--json response)))
        (should (equal 200 (plist-get response :status)))
        (should (string-match-p "application/json" (plist-get response :headers)))
        (should (equal "7d" (plist-get parsed :range)))
        (should (plist-member parsed :overview))))))

(ert-deftest el-chronos-ui-test-web-api-top-functions ()
  "GET /api/top-functions 返回 200 + JSON，含 range / limit / items 三个键。"
  (el-chronos-ui-test--with-temp-db
    (el-chronos-ui-test--with-server
      (let* ((response (el-chronos-ui-test--http "GET" "/api/top-functions?range=1d&limit=5"))
             (parsed (el-chronos-ui-test--json response)))
        (should (equal 200 (plist-get response :status)))
        (should (string-match-p "application/json" (plist-get response :headers)))
        (should (equal "1d" (plist-get parsed :range)))
        (should (equal 5 (plist-get parsed :limit)))
        (should (plist-member parsed :items))))))

(ert-deftest el-chronos-ui-test-web-unknown-path-404 ()
  "未注册路径返回 404（未知路径不得静默返回首页）。"
  (el-chronos-ui-test--with-temp-db
    (el-chronos-ui-test--with-server
      (let ((response (el-chronos-ui-test--http "GET" "/nope")))
        (should (equal 404 (plist-get response :status)))
        (should (string-match-p "404 Not Found" (plist-get response :body)))))))

(ert-deftest el-chronos-ui-test-web-non-get-405 ()
  "非 GET 请求返回 405 且带 `Allow: GET'（只读接口）。"
  (el-chronos-ui-test--with-temp-db
    (el-chronos-ui-test--with-server
      (let ((response (el-chronos-ui-test--http "POST" "/")))
        (should (equal 405 (plist-get response :status)))
        (should (string-match-p "Allow: GET" (plist-get response :headers)))))))

(ert-deftest el-chronos-ui-test-web-port-in-use ()
  "端口被占用时 start 直接 `user-error'，不自动换端口、不留运行态（I8 / I11）。"
  (let* ((blocker (make-network-process :name "el-chronos-ui-test-blocker"
                                        :server t
                                        :host el-chronos-web--host
                                        :service t
                                        :family 'ipv4
                                        :noquery t))
         (port (process-contact blocker :service)))
    (unwind-protect
        (progn
          (should (integerp port))
          (should-error (el-chronos-web-start port) :type 'user-error)
          (should-not (el-chronos-web-running-p)))
      (when (process-live-p blocker) (delete-process blocker))
      (ignore-errors (el-chronos-web-stop)))))

;;; dashboard：每页行数上限与重复打开不增长（内存回归）

(ert-deftest el-chronos-ui-test-dashboard-tables-cap-rows ()
  "5 张表交给 ETAF 的行数都不超过 `el-chronos-dashboard-page-size'。
回归背景：`:sessions' 查询**无行数上限**（一年重启数千次 → 数千行），旧实现把整表交给
`etaf-table'，每行会保留一个行 Host + 单元格子组件，单次渲染多保留约 61 万 cons，
连续打开 dashboard 导致进程内存暴涨（实测 6 次渲染 RSS 148MB→306MB）。

判据分两层：
  - 分页表（慢命令 / 热点函数）取第 PAGE 页，行数 ≤ size，标题带页码；
  - 不分页表（阻塞 / 回归 / 会话）只取前 size 行，超限时标题注明「共 N 条，显示前 M 条」。"
  (let* ((size 20)
         (el-chronos-dashboard-page-size size)
         (el-chronos-dashboard--snapshot
          (list :slow (cl-loop for i below 200 collect (list :name (format "cmd-%d" i)))
                :functions (cl-loop for i below 200 collect (list :function (format "fn-%d" i)))
                :blockers (cl-loop for i below 200 collect (list :id i))
                :regressions (cl-loop for i below 200 collect (list :function (format "r-%d" i)))
                :sessions (cl-loop for i below 200 collect (list :id i)))))
    (dolist (page (list 0 3))
      (dolist (table (el-chronos-dashboard--tables page))
        (should (<= (length (plist-get table :rows)) size))
        (should (stringp (plist-get table :title)))))
    ;; 分页表：第 0 页是前 20 条，第 3 页是第 61–80 条（顺序由快照给定）
    (let* ((slow (nth 0 (el-chronos-dashboard--tables 0)))
           (slow-page-3 (nth 0 (el-chronos-dashboard--tables 3)))
           (first-row (car (plist-get slow :rows)))
           (row-60 (car (plist-get slow-page-3 :rows))))
      (should (= 20 (length (plist-get slow :rows))))
      (should (equal "cmd-0" (plist-get (alist-get :source first-row) :name)))
      (should (equal "cmd-60" (plist-get (alist-get :source row-60) :name)))
      ;; 10 页（200 行 / 20 行每页）
      (should (string-match-p "第 1/10 页" (plist-get slow :title))))
    ;; 不分页表：只取首页 + 标题如实说明截断
    (let ((sessions (nth 4 (el-chronos-dashboard--tables 0))))
      (should (= size (length (plist-get sessions :rows))))
      (should (string-match-p "已加载 200 条，显示前 20 条" (plist-get sessions :title))))
    ;; 短列表不改标题、不加截断说明
    (let* ((el-chronos-dashboard--snapshot (list :sessions (list (list :id 1))))
           (sessions (nth 4 (el-chronos-dashboard--tables 0))))
      (should (= 1 (length (plist-get sessions :rows))))
      (should-not (string-match-p "已加载 " (plist-get sessions :title))))))

(ert-deftest el-chronos-ui-test-dashboard-snapshot-cap-rows ()
  "`--load-snapshot' 每个列表字段都不超过 `el-chronos-dashboard-max-rows'。
`:sessions' / `:trend' / `:heatmap' 随窗口增长而没有行数上限，快照必须自己封顶，
否则一次渲染就把整表搬进内存（快照持有到下次渲染）。"
  (el-chronos-ui-test--with-temp-db
    (should (el-chronos-store-open))
    (let ((el-chronos-dashboard-max-rows 5)
          (rows (cl-loop for i below 50 collect (list :id i))))
      (cl-letf (((symbol-function 'el-chronos-analysis-sessions) (lambda (&rest _) rows))
                ((symbol-function 'el-chronos-analysis-trend) (lambda (&rest _) rows))
                ((symbol-function 'el-chronos-analysis-slow-commands)
                 (lambda (&rest _) rows))
                ((symbol-function 'el-chronos-analysis-overview) (lambda (&rest _) nil)))
        (let ((snapshot (el-chronos-dashboard--load-snapshot "7d")))
          (should (= 5 (length (plist-get snapshot :sessions))))
          (should (= 5 (length (plist-get snapshot :trend))))
          (should (= 5 (length (plist-get snapshot :slow))))
          ;; 截断保留的是前 N 条（顺序不变）
          (should (equal 0 (plist-get (car (plist-get snapshot :sessions)) :id)))
          (should (equal 4 (plist-get (nth 4 (plist-get snapshot :sessions)) :id))))
        ;; 短列表原样返回（不截断、不返 nil）
        (cl-letf (((symbol-function 'el-chronos-analysis-sessions)
                   (lambda (&rest _) (list (list :id 1) (list :id 2)))))
          (should (= 2 (length (plist-get (el-chronos-dashboard--load-snapshot "7d")
                                          :sessions)))))))))

(ert-deftest el-chronos-ui-test-dashboard-reload-snapshot-drops-old ()
  "重载快照前先把旧快照置 nil：查询期间不持有两代数据，且新快照替换旧值。"
  (el-chronos-ui-test--with-temp-db
    (should (el-chronos-store-open))
    (let ((delivered (list (list :id 1))))
      (cl-letf (((symbol-function 'el-chronos-analysis-sessions) (lambda (&rest _) delivered))
                ((symbol-function 'el-chronos-analysis-overview) (lambda (&rest _) nil)))
        (setq el-chronos-dashboard--snapshot (list :sessions (list (list :id 'stale))))
        (el-chronos-dashboard--reload-snapshot "7d")
        (let ((sessions (plist-get el-chronos-dashboard--snapshot :sessions)))
          (should (= 1 (length sessions)))
          (should (equal 1 (plist-get (car sessions) :id)))))
      (setq el-chronos-dashboard--snapshot nil))))

(ert-deftest el-chronos-ui-test-dashboard-repeat-open-no-growth ()
  "连续打开 dashboard 不增长 buffer 数与 hook 登记表，ETAF runtime 至多 1 个。
回归背景：每次打开都新建 runtime / buffer 却不回收时，连开数次就把隔离实例撑爆
（实测修复前 6 次渲染 RSS 148MB→306MB，存活 cons 92 万→361 万）。
ETAF 缺席时（`make test' 不带 ETAF 的 load-path）走 tabulated-list 降级页，同一套断言仍然成立。"
  (el-chronos-ui-test--with-temp-db
    (let ((db (el-chronos-store-open)))
      (should db)
      (sqlite-execute db
                      "INSERT INTO sessions (started_at, emacs_version, host) VALUES (?, ?, ?)"
                      (list (truncate (* 1000 (float-time))) "el-chronos-test" "test-host"))
      (unwind-protect
          (progn
            (el-chronos-dashboard "7d")
            (let ((buffers (length (buffer-list)))
                  (sessions (length (plist-get el-chronos-dashboard--snapshot :sessions)))
                  (hooked (hash-table-count el-chronos-collect--hooked-buffers))
                  ;; ETAF 缺席时变量不存在：用 `boundp' + `symbol-value' 读，
                  ;; 避免字节编译在 ETAF 不在 load-path 时报自由变量告警
                  (runtimes (and (boundp 'etaf--runtimes)
                                 (hash-table-count (symbol-value 'etaf--runtimes)))))
              (dotimes (_ 4) (el-chronos-dashboard "7d"))
              ;; 允许首次渲染期新建 1 个内部 buffer（ETAF 的 ` *work*'）
              (should (<= (length (buffer-list)) (1+ buffers)))
              (should (= hooked (hash-table-count el-chronos-collect--hooked-buffers)))
              (when runtimes
                (should (<= (hash-table-count (symbol-value 'etaf--runtimes))
                            (max 1 runtimes))))
              ;; 关键：快照每次整体替换，行数不随打开次数累积
              (should (= sessions
                         (length (plist-get el-chronos-dashboard--snapshot :sessions))))))
        (when (get-buffer el-chronos-dashboard--buffer-name)
          (kill-buffer (get-buffer el-chronos-dashboard--buffer-name)))
        (setq el-chronos-dashboard--state nil
              el-chronos-dashboard--snapshot nil)))))

;;; dashboard 宽度策略与主题配色（不截断、不溢出、背景跟随主题）

(defconst el-chronos-ui-test--widths '(60 80 120 160)
  "宽度自适应用例覆盖的窗口列数：60 是分屏下的常见下限。")

(ert-deftest el-chronos-ui-test-dashboard-card-fields-complete ()
  "`--card' 把数据行拆成 `:head' + `:detail'，两者都保留**完整文本**（不含 `…'）。
这是用户可见性要求的直接断言：命令名 / 函数名 / 包名 / 路径这类数据文本一旦被截断
（旧实现的 `etaf-table' 定宽列会用 `truncate-string-to-width' 补 `…'，`:overflow hidden'
则直接裁掉），就再也读不到完整信息。"
  (let* ((long-name "el-chronos-very-long-command-name-exceeding-any-column-width")
         (rows (list (cons :slow (list :name long-name :total-ms 1234 :count 7 :aborted 1))
                     (cons :functions (list :function long-name :package "el-chronos"
                                            :self-ms 1234 :pct 42.5))
                     (cons :blockers (list :ts 1700000000000 :duration-ms 980
                                           :command long-name :mode "emacs-lisp-mode"))
                     (cons :regressions (list :function long-name :growth 1.5
                                              :current-ms 800 :previous-ms 400
                                              :current-samples 10 :previous-samples 8))
                     (cons :sessions (list :id 3 :started-at 1700000000000
                                           :startup-ms 1234 :emacs-version "31.1"
                                           :host long-name)))))
    (dolist (entry rows)
      (let* ((kind (car entry))
             (card (el-chronos-dashboard--card kind (cdr entry)))
             (head (plist-get card :head))
             (detail (plist-get card :detail))
             (columns (alist-get kind el-chronos-dashboard--columns))
             (head-key (alist-get kind el-chronos-dashboard--card-primary))
             (head-label (nth 1 (assq head-key columns))))
        ;; 主键全文本出现，且卡片里没有截断标记
        (should (stringp head))
        (should (string-match-p (regexp-quote long-name) (concat head " " detail)))
        (should-not (string-match-p "…" head))
        (should-not (string-match-p "…" detail))
        ;; 除主键外每个字段的标签都在 `:detail' 里（数据不丢字段）
        (dolist (column (cl-remove head-key columns :key #'car :test #'eq))
          (should (string-match-p (regexp-quote (nth 1 column)) detail)))
        ;; 主键不重复出现在 detail 里（首行已完整显示）
        (should-not (string-match-p (regexp-quote head-label) detail))))))

(ert-deftest el-chronos-ui-test-dashboard-theme-palette ()
  "`--theme-palette' 从 `default' / `shadow' / `link' 等 face 派生 ETAF 主题色。
判据：颜色可用时必须给出 `:ui-bg' 与 `:ui-fg'（页面与文字跟随主题），面板表面色是
背景的明暗偏移；主题未指定（`emacs -Q --batch' 的 `unspecified-bg'）时返回 nil ——
绝不把 `unspecified-bg' 当颜色传下去（实测那会让面板拿到非法颜色）。"
  (cl-letf (((symbol-function 'face-attribute)
             (lambda (face attribute &optional _frame _inherit)
               (pcase (cons face attribute)
                 ('(default . :background) "#202634")
                 ('(default . :foreground) "#F4F6FB")
                 ('(shadow . :foreground) "#7A8699")
                 ('(link . :foreground) "#4FC1FF")
                 ('(highlight . :background) "#2F6FE4")
                 (_ "unspecified")))))
    (let ((palette (el-chronos-dashboard--theme-palette)))
      (should (equal "#202634" (plist-get palette :ui-bg)))
      (should (equal "#F4F6FB" (plist-get palette :ui-fg)))
      (should (equal "#F4F6FB" (plist-get palette :ui-panel-fg)))
      (should (equal "#7A8699" (plist-get palette :ui-muted-fg)))
      (should (equal "#4FC1FF" (plist-get palette :ui-accent)))
      (should (equal "#2F6FE4" (plist-get palette :ui-button-primary-bg)))
      ;; 面板表面色 = 背景的明暗偏移（可解析为合法颜色）
      (should (color-name-to-rgb (plist-get palette :ui-panel-bg)))
      ;; 只有解析出颜色串的键才出现（nil 值会让组件拿 nil 当颜色）
      (should (cl-every #'stringp (cl-loop for (_key value) on palette by #'cddr
                                           collect value)))))
  ;; 主题不可用（`emacs -Q --batch' 的默认情形）→ nil，而不是把 `unspecified-bg' 当颜色
  (cl-letf (((symbol-function 'face-attribute)
             (lambda (_face attribute &optional _frame _inherit)
               (if (eq attribute :background) "unspecified-bg" "unspecified-fg"))))
    (should-not (el-chronos-dashboard--theme-palette))))

(ert-deftest el-chronos-ui-test-dashboard-chart-width-fits ()
  "图表宽度不超过内容宽度；文本图逐行截断后每行都不超内容宽度（图表文本允许缩略）。"
  (dolist (avail el-chronos-ui-test--widths)
    (let ((content (el-chronos-dashboard--content-cells avail)))
      (should (<= (el-chronos-dashboard--chart-width content) content))
      (dolist (kind '(trend bars heatmap))
        (let ((text (el-chronos-dashboard--fit-text-chart
                     kind
                     (list (list :label "a-very-long-command-name-exceeding-the-cell"
                                 :value 12 :pct 50.0 :values '(1 2 3)))
                     content)))
          (should (stringp text))
          (dolist (line (split-string text "\n"))
            (should (<= (string-width line) content))))))))

(defun el-chronos-ui-test--default-remap-spec ()
  "返回 `face-remapping-alist' 里 `default' 的重映射 face spec（`set-base' 与
`add-relative' 两种形态都兼容：前者是 plist，后者是列表尾部带 `default' 的 spec）。"
  (let ((spec (cdr (assq 'default face-remapping-alist))))
    (cond ((null spec) nil)
          ((keywordp (car spec)) spec)
          ((consp (car spec)) (car spec)))))

(defun el-chronos-ui-test--squeeze (text)
  "去掉 TEXT 的空白与换行：用于比较「折行后仍完整」的文本。"
  (replace-regexp-in-string "[ \t\n\u3000]+" "" (or text "")))

(ert-deftest el-chronos-ui-test-dashboard-render-no-truncation ()
  "ETAF 实际渲染：60/80/120/160 列窗口下不截断（无 `…'）、不溢出、数据文本完整、背景跟随主题。

判据分四层：
  1. 渲染文本里**不出现** `…'（数据行与标签都不允许省略）；
  2. 每行 `string-width' ≤ 窗口列数（折行发生在窗口内，不越界）；
  3. 把渲染文本去掉空白后仍**包含完整的命令名 / 函数名**（折行不丢字符）；
  4. 主题背景可用时，buffer 的 `default' face remap 背景等于主题背景。
ETAF 不在 load-path（`make test' 默认如此）时跳过。"
  (skip-unless (and (require 'ebox nil t)
                    (el-chronos-dashboard-etaf-available-p)))
  (el-chronos-ui-test--with-temp-db
    (let ((db (el-chronos-store-open))
          (long-command "el-chronos-very-long-command-name-01-suffix"))
      (should db)
      (let ((hour (* 3600000 (floor (/ (float-time) 3600))))
            (now (truncate (* 1000 (float-time)))))
        (sqlite-execute db "INSERT INTO sessions (started_at, emacs_version, host, startup_ms)\
 VALUES (?, ?, ?, ?)" (list (- now 3600000) "31.1" "test-host" 1234))
        (dotimes (index 6)
          (sqlite-execute db "INSERT INTO commands (ts, session_id, name, duration_ms, gc_ms,\
 mode, outcome) VALUES (?, ?, ?, ?, ?, ?, ?)"
                          (list (- now (* (1+ index) 60000))
                                (caar (sqlite-select db "SELECT max(id) FROM sessions"))
                                (format "%s-%02d" long-command index)
                                (* 100 (1+ index)) 1 "emacs-lisp-mode" "ok"))
          (sqlite-execute db "INSERT INTO hourly_functions (hour_ts, session_id, function, file,\
 package, self_ms, total_ms, samples) VALUES (?, ?, ?, ?, ?, ?, ?, ?)"
                          (list hour 1 (format "el-chronos--long-function-name-%02d" index)
                                "/tmp/el-chronos-dashboard.el" "el-chronos"
                                (* 10.0 (1+ index)) (* 20.0 (1+ index)) (1+ index)))))
      (unwind-protect
          (progn
            (el-chronos-dashboard--render-etaf "7d")
            (dolist (cells el-chronos-ui-test--widths)
              (let* ((buffer (get-buffer el-chronos-dashboard--buffer-name))
                     (pixels (* cells (frame-char-width)))
                     (ebox-viewport-width pixels)
                     (theme-bg (el-chronos-dashboard--theme-background)))
                (ignore ebox-viewport-width)
                (when-let* ((runtime (etaf-runtime-for-buffer buffer)))
                  (etaf-unmount runtime))
                (etaf-mount buffer
                            (eval `(etaf-view (el-chronos-dashboard-app
                                               :range "7d" :page 0 :selected nil))
                                  t))
                (with-current-buffer buffer
                  (let ((text (buffer-substring-no-properties (point-min) (point-max))))
                    ;; 1) 数据文本不截断
                    (should-not (string-match-p "…" text))
                    ;; 3) 折行不丢字符：完整命令名仍在
                    (should (string-match-p (regexp-quote (el-chronos-ui-test--squeeze
                                                           long-command))
                                            (el-chronos-ui-test--squeeze text)))
                    ;; 2) 每行不超窗口
                    (dolist (line (split-string text "\n"))
                      (should (<= (string-width line) cells)))
                    ;; 4) 背景跟随主题（有主题时）
                    (when theme-bg
                      (should (equal theme-bg
                                     (plist-get (el-chronos-ui-test--default-remap-spec)
                                                :background))))))
                ;; 不溢出：任何节点的右边界都在窗口内
                (let ((overflow 0))
                  (el-chronos-ui-test--walk-nodes
                   (ebox-mount-root (ebox-buffer-mount buffer))
                   (lambda (node)
                     (let ((geometry (ignore-errors (ebox-node-geometry node))))
                       (when (and geometry
                                  (numberp (plist-get geometry :x))
                                  (numberp (plist-get geometry :width))
                                  (> (+ (plist-get geometry :x) (plist-get geometry :width))
                                     pixels))
                         (setq overflow (1+ overflow))))))
                  (should (= 0 overflow))))))
        (when (get-buffer el-chronos-dashboard--buffer-name)
          (kill-buffer (get-buffer el-chronos-dashboard--buffer-name)))
        (setq el-chronos-dashboard--state nil
              el-chronos-dashboard--snapshot nil)))))

(defun el-chronos-ui-test--walk-nodes (node function)
  "对 NODE 及其子树逐个调用 FUNCTION（先父后子）。"
  (funcall function node)
  (dolist (child (ebox-node-children node))
    (el-chronos-ui-test--walk-nodes child function)))

(provide 'el-chronos-ui-test)

;;; el-chronos-ui-test.el ends here
