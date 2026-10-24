;;; el-chronos-web-test.el --- 内嵌 Web 服务测试（启停 / 路由 / 边界）  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Thomas

;; Author: Thomas
;; Keywords: tools, performance
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; 内嵌 Web 服务（`el-chronos-web'）的 ERT 覆盖：启停幂等、`/` 与 JSON 接口、404 / 405、
;; 端口占用 `user-error'、只绑 loopback、`running-p' 返回严格布尔。
;;
;; 设计约束（与仓库不变量对应）：
;;   - 不碰真实数据库：所有涉及库的用例把 `el-chronos-db-path' 绑到临时目录（I3），退出时
;;     `el-chronos-store-close' 并删目录，仓库根与 `~/.emacs.d' 都不落运行产物。
;;   - HTTP 客户端用内置 `make-network-process' 手写（不调 curl），batch 下靠
;;     `accept-process-output' 轮询并有总超时，避免无输出时挂死。
;;   - server 一律起在 `:service 0'（内核分配端口）并 `unwind-protect' 关闭：既避免与用户
;;     正在运行的 Web 服务（默认 8787）抢端口，也保证用例失败后不留监听（I5 精神）。
;;
;; 运行：emacs -Q --batch -L . -L test -l test/el-chronos-web-test.el \
;;              -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'json)
(require 'sqlite)
(require 'el-chronos)
(require 'el-chronos-store)
(require 'el-chronos-web)

;;; 测试夹具与辅助

(defvar el-chronos-ui-test--http-timeout 5.0
  "单次 HTTP 往返的总超时（秒）；超时后返回已收到的内容，不让用例挂死。")

(defvar el-chronos-ui-test--port nil
  "当前用例里 server 实际监听的端口；由 `--with-server' 绑定。")

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

(defmacro el-chronos-ui-test--with-server (&rest body)
  "在自动分配的 loopback 端口上起 server 执行 BODY，绑定 `--port'。
端口用 `:service 0' 让内核分配：不与用户运行中的 Web 服务（默认 8787）冲突；
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

;;; Web server：启停、路由与边界

(ert-deftest el-chronos-web-test-start-stop ()
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

(ert-deftest el-chronos-web-test-running-p-returns-boolean ()
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

(ert-deftest el-chronos-web-test-binds-loopback ()
  "server 只绑 127.0.0.1（I8：不接受 0.0.0.0）。"
  (el-chronos-ui-test--with-temp-db
    (el-chronos-ui-test--with-server
      (should (equal "127.0.0.1" (format "%s" (nth 0 (process-contact el-chronos-ui-test--proc)))))
      (should (equal "127.0.0.1" el-chronos-web--host)))))

(ert-deftest el-chronos-web-test-index-html ()
  "GET / 返回 200 + text/html，页面含 el-chronos 标识。"
  (el-chronos-ui-test--with-temp-db
    (el-chronos-ui-test--with-server
      (let ((response (el-chronos-ui-test--http "GET" "/")))
        (should (equal 200 (plist-get response :status)))
        (should (string-match-p "text/html" (plist-get response :headers)))
        (should (string-match-p "el-chronos" (plist-get response :body)))))))

(ert-deftest el-chronos-web-test-api-summary ()
  "GET /api/summary 返回 200 + application/json，body 可解析且含 range / overview。"
  (el-chronos-ui-test--with-temp-db
    (el-chronos-ui-test--with-server
      (let* ((response (el-chronos-ui-test--http "GET" "/api/summary"))
             (parsed (el-chronos-ui-test--json response)))
        (should (equal 200 (plist-get response :status)))
        (should (string-match-p "application/json" (plist-get response :headers)))
        (should (equal "7d" (plist-get parsed :range)))
        (should (plist-member parsed :overview))))))

(ert-deftest el-chronos-web-test-api-top-functions ()
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

(ert-deftest el-chronos-web-test-unknown-path-404 ()
  "未注册路径返回 404（未知路径不得静默返回首页）。"
  (el-chronos-ui-test--with-temp-db
    (el-chronos-ui-test--with-server
      (let ((response (el-chronos-ui-test--http "GET" "/nope")))
        (should (equal 404 (plist-get response :status)))
        (should (string-match-p "404 Not Found" (plist-get response :body)))))))

(ert-deftest el-chronos-web-test-non-get-405 ()
  "非 GET 请求返回 405 且带 `Allow: GET'（只读接口）。"
  (el-chronos-ui-test--with-temp-db
    (el-chronos-ui-test--with-server
      (let ((response (el-chronos-ui-test--http "POST" "/")))
        (should (equal 405 (plist-get response :status)))
        (should (string-match-p "Allow: GET" (plist-get response :headers)))))))

(ert-deftest el-chronos-web-test-port-in-use ()
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

(provide 'el-chronos-web-test)

;;; el-chronos-web-test.el ends here
