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
(eval-and-compile
  ;; `make lint' 只带 `-L .'（不编译 test/ 目录）：编译期据 `byte-compile-current-file'
  ;; 把本文件所在目录加进 load-path，否则下面的 `require' 找不到 helper。
  ;; 运行期由 `make test' 的 `-L test' 提供，本段自然跳过。
  (when (bound-and-true-p byte-compile-current-file)
    (add-to-list 'load-path (file-name-directory byte-compile-current-file))))
(require 'el-chronos-test-helper)

;;; 测试夹具与辅助

(defvar el-chronos-web-test--http-timeout 5.0
  "单次 HTTP 往返的总超时（秒）；超时后返回已收到的内容，不让用例挂死。")

(defvar el-chronos-web-test--port nil
  "当前用例里 server 实际监听的端口；由 `--with-server' 绑定。")

(defmacro el-chronos-web-test--with-temp-db (&rest body)
  "在临时数据库上执行 BODY。
把 `el-chronos-db-path' 绑到临时目录下的 `chronos.sqlite'（I3：数据只写该文件），
退出时关闭句柄并删掉整个临时目录，保证不污染仓库与 `~/.emacs.d'。"
  (declare (indent 0) (debug t))
  `(let* ((el-chronos-web-test--dir (make-temp-file "el-chronos-web-test-" t))
          (el-chronos-db-path (expand-file-name "chronos.sqlite" el-chronos-web-test--dir)))
     (unwind-protect
         (progn ,@body)
       (ignore-errors (el-chronos-store-close))
       (ignore-errors (delete-directory el-chronos-web-test--dir t)))))

(defmacro el-chronos-web-test--with-server (&rest body)
  "在自动分配的 loopback 端口上起 server 执行 BODY，绑定 `--port'。
端口用 `:service 0' 让内核分配：不与用户运行中的 Web 服务（默认 8787）冲突；
无论 BODY 成败都关闭 server，保证不留监听端口。"
  (declare (indent 0) (debug t))
  `(progn
     (ignore-errors (el-chronos-web-stop))
     (let* ((el-chronos-web-test--proc (el-chronos-web-start 0))
            (el-chronos-web-test--port (process-contact el-chronos-web-test--proc :service)))
       (unwind-protect
           (progn ,@body)
         (ignore-errors (el-chronos-web-stop))))))

(defun el-chronos-web-test--parse-response (raw)
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

(defun el-chronos-web-test--http (method path &optional port)
  "用内置 `make-network-process' 向 127.0.0.1:PORT 发 METHOD PATH 请求，返回响应 plist。
请求带 `Connection: close'，读到对端 EOF 或超过 `--http-timeout' 秒即返回。
客户端按 binary 读（字节边界自己掌握，见 `--parse-response'），并挂 `ignore' 作 sentinel：
默认 sentinel 会把「connection broken」写进 process buffer，污染响应体。"
  (let* ((port (or port el-chronos-web-test--port el-chronos-web-port))
         (buffer (generate-new-buffer " *el-chronos-web-test-http*"))
         (proc (make-network-process :name "el-chronos-web-test-client"
                                     :buffer buffer
                                     :host el-chronos-web--host
                                     :service port
                                     :family 'ipv4
                                     :coding 'binary
                                     :sentinel #'ignore
                                     :noquery t))
         (deadline (+ (float-time) el-chronos-web-test--http-timeout)))
    (unwind-protect
        (progn
          (process-send-string
           proc (format "%s %s HTTP/1.1\r\nHost: %s\r\nConnection: close\r\n\r\n"
                        method path el-chronos-web--host))
          (while (and (process-live-p proc) (< (float-time) deadline))
            (accept-process-output proc 0.05))
          (el-chronos-web-test--parse-response (with-current-buffer buffer (buffer-string))))
      (when (process-live-p proc) (ignore-errors (delete-process proc)))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(defun el-chronos-web-test--json (response)
  "把 RESPONSE 的 body 解析成 plist；body 非 JSON 时用例直接失败。"
  (let ((body (plist-get response :body)))
    (should (stringp body))
    (json-parse-string body :object-type 'plist)))

;;; Web server：启停、路由与边界

(ert-deftest el-chronos-web-test-start-stop ()
  "start 后 `running-p' 为 t；stop 后为 nil 且可再次 start（无残留）。"
  (el-chronos-web-test--with-temp-db
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
  (el-chronos-web-test--with-temp-db
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
  (el-chronos-web-test--with-temp-db
    (el-chronos-web-test--with-server
      (should (equal "127.0.0.1" (format "%s" (nth 0 (process-contact el-chronos-web-test--proc)))))
      (should (equal "127.0.0.1" el-chronos-web--host)))))

(ert-deftest el-chronos-web-test-index-html ()
  "GET / 返回 200 + text/html，页面含 el-chronos 标识。
另断言「资源」节与卡片容器存在：新增 section 忘了加容器 id 会让 `resPanel' 静默不渲染
（`$('res')' 为 null），属 I11 的静默失败面。"
  (el-chronos-web-test--with-temp-db
    (el-chronos-web-test--with-server
      (let ((response (el-chronos-web-test--http "GET" "/")))
        (should (equal 200 (plist-get response :status)))
        (should (string-match-p "text/html" (plist-get response :headers)))
        (should (string-match-p "el-chronos" (plist-get response :body)))
        (should (string-match-p "资源（CPU / 内存 / 负载）" (plist-get response :body)))
        (should (string-match-p "id='res'" (plist-get response :body)))
        (should (string-match-p "CPU 均值" (plist-get response :body)))))))

(ert-deftest el-chronos-web-test-api-summary ()
  "GET /api/summary 返回 200 + application/json，body 可解析且含 range / overview。"
  (el-chronos-web-test--with-temp-db
    (el-chronos-web-test--with-server
      (let* ((response (el-chronos-web-test--http "GET" "/api/summary"))
             (parsed (el-chronos-web-test--json response)))
        (should (equal 200 (plist-get response :status)))
        (should (string-match-p "application/json" (plist-get response :headers)))
        (should (equal "7d" (plist-get parsed :range)))
        (should (plist-member parsed :overview))))))

(ert-deftest el-chronos-web-test-api-top-functions ()
  "GET /api/top-functions 返回 200 + JSON，含 range / limit / items 三个键。"
  (el-chronos-web-test--with-temp-db
    (el-chronos-web-test--with-server
      (let* ((response (el-chronos-web-test--http "GET" "/api/top-functions?range=1d&limit=5"))
             (parsed (el-chronos-web-test--json response)))
        (should (equal 200 (plist-get response :status)))
        (should (string-match-p "application/json" (plist-get response :headers)))
        (should (equal "1d" (plist-get parsed :range)))
        (should (equal 5 (plist-get parsed :limit)))
        (should (plist-member parsed :items))))))

(ert-deftest el-chronos-web-test-unknown-path-404 ()
  "未注册路径返回 404（未知路径不得静默返回首页）。"
  (el-chronos-web-test--with-temp-db
    (el-chronos-web-test--with-server
      (let ((response (el-chronos-web-test--http "GET" "/nope")))
        (should (equal 404 (plist-get response :status)))
        (should (string-match-p "404 Not Found" (plist-get response :body)))))))

(ert-deftest el-chronos-web-test-non-get-405 ()
  "非 GET 请求返回 405 且带 `Allow: GET'（只读接口）。"
  (el-chronos-web-test--with-temp-db
    (el-chronos-web-test--with-server
      (let ((response (el-chronos-web-test--http "POST" "/")))
        (should (equal 405 (plist-get response :status)))
        (should (string-match-p "Allow: GET" (plist-get response :headers)))))))

(ert-deftest el-chronos-web-test-port-in-use ()
  "端口被占用时 start 直接 `user-error'，不自动换端口、不留运行态（I8 / I11）。"
  (let* ((blocker (make-network-process :name "el-chronos-web-test-blocker"
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

;; TD-12：Web 请求处理期间的自观测抑制（与 report 侧同款三层机制，端到端锁住）
(ert-deftest el-chronos-web-test-suppresses-block-events ()
  "请求处理期间抑制采集层阻塞判定，结束后恢复原值并重置心跳基线（TD-12）。
三层都要验：① 抑制变量在请求体内为 t；② 阻塞阈值抬到 60s；③ 结束后基线被重置
（否则解除抑制后补跑的那次心跳仍会把整段请求耗时记成阻塞）。
用 `cl-letf' 替换路由处理器在**请求体内**取样：只在处理器被调用时才能看到抑制期间的值，
事后从外部读只会读到已恢复的原值。"
  (el-chronos-web-test--with-temp-db
    (el-chronos-web-test--with-server
      (let* ((baseline (- (float-time) 100))
             (seen-suppress 'unset)
             (seen-threshold 'unset)
             (seen-heartbeat 'unset)
             (el-chronos-collect--suppress-block-p nil)
             (el-chronos-block-threshold-ms 2000)
             (el-chronos-collect--last-heartbeat baseline))
        (cl-letf (((symbol-function 'el-chronos-web--route-summary)
                   (lambda (_params)
                     (setq seen-suppress el-chronos-collect--suppress-block-p
                           seen-threshold el-chronos-block-threshold-ms
                           seen-heartbeat el-chronos-collect--last-heartbeat)
                     (el-chronos-web--response "200 OK" el-chronos-web--json-type
                                               "{\"range\":\"7d\"}"))))
          (let ((response (el-chronos-web-test--http "GET" "/api/summary")))
            ;; 处理器的确被调用（否则下面对 'unset 的断言会以更晦涩的方式失败）
            (should (equal 200 (plist-get response :status)))
            (should (string-match-p "7d" (plist-get response :body)))
            ;; ① 请求体内抑制变量为 t
            (should (eq t seen-suppress))
            ;; ② 阈值在请求体内抬到 60s
            (should (= el-chronos-web--suppress-block-threshold-ms seen-threshold))
            ;; 第 3 层只在收尾写基线：请求体内读到的仍是进入前的值
            (should (= baseline seen-heartbeat))
            ;; 请求结束后两层 `let' 绑定都恢复原值
            (should-not el-chronos-collect--suppress-block-p)
            (should (= 2000 el-chronos-block-threshold-ms))
            ;; ③ 基线被重置到 ≈now（进入前是 now-100，不重置则相差约 100 秒）
            (should (> el-chronos-collect--last-heartbeat (+ baseline 50)))
            (should (< (- (float-time) el-chronos-collect--last-heartbeat) 2))))))))

;;; 新查询路由（GC / 启动分解 / 采集健康 / 配置变更）与 CSV 新区块

(defun el-chronos-web-test--open-fixture-db ()
  "打开临时库（父宏已把 `el-chronos-db-path' 绑到临时目录）以便插入 fixture 行。
`make test' 的用例里 analysis 层会惰性打开库；这里先显式打开，才能用
`el-chronos-test-helper' 的插入函数造数据。"
  (should (el-chronos-store-open)))

(ert-deftest el-chronos-web-test-api-gc ()
  "GET /api/gc 返回 200 + JSON：空库 items 为空，有数据时按桶聚合。
`heap-bytes' 无样本（Emacs < 31.1 口径）时该字段为 null，页面渲染 \"-\" 而非 0。"
  (el-chronos-web-test--with-temp-db
    (el-chronos-web-test--open-fixture-db)
    (el-chronos-web-test--with-server
      (let* ((empty-resp (el-chronos-web-test--http "GET" "/api/gc?range=1d&buckets=4"))
             (empty (el-chronos-web-test--json empty-resp)))
        (should (equal 200 (plist-get empty-resp :status)))
        (should (string-match-p "application/json" (plist-get empty-resp :headers)))
        (should (equal "1d" (plist-get empty :range)))
        (should (= 4 (plist-get empty :bucket-count)))
        ;; 空数组经 `--json-value' 序列化为 null（nil 分支），前端按 `items||[]' 处理
        (should (eq :null (plist-get empty :items)))
        (should (zerop (or (plist-get empty :gc-total) 0))))
      (el-chronos-test--insert-gc (el-chronos-test--hour-ts) 3 12.5 52428800)
      (let* ((resp (el-chronos-web-test--http "GET" "/api/gc?range=1d"))
             (parsed (el-chronos-web-test--json resp))
             (items (plist-get parsed :items))
             (first (aref items 0)))
        (should (equal 200 (plist-get resp :status)))
        (should (= 1 (length items)))
        (should (= 3 (plist-get first :gc-count)))
        (should (= 52428800 (plist-get first :heap-bytes)))
        (should (= 3 (plist-get parsed :gc-total)))
        (should (= 52428800 (plist-get parsed :heap-latest)))
        ;; buckets 省略时由 analysis 按窗口长度决定，响应里为 null（不是 0）
        (should (plist-member parsed :bucket-count))
        (should (eq :null (plist-get parsed :bucket-count)))
        (should (integerp (plist-get parsed :bucket-span)))))))

(ert-deftest el-chronos-web-test-api-health-rows-semantics ()
  "GET /api/health：空库 rows=0 且 ok-p 为 true；有丢弃计数时 ok-p 为 false 且 rows>0。
`:rows' 是区分「没采集」与「没异常」的唯一依据（T7b 报告层同口径，I11）——
反向验证：把 `:rows' 从响应里去掉，本用例的 rows 断言必红。"
  (el-chronos-web-test--with-temp-db
    (el-chronos-web-test--open-fixture-db)
    (el-chronos-web-test--with-server
      (let* ((empty-resp (el-chronos-web-test--http "GET" "/api/health?range=1d"))
             (empty (el-chronos-web-test--json empty-resp)))
        (should (equal 200 (plist-get empty-resp :status)))
        (should (equal 0 (plist-get empty :rows)))
        ;; 无数据时 analysis 也给 ok-p 为 t —— 故必须靠 rows 区分
        (should (eq t (plist-get empty :ok-p))))
      (el-chronos-test--insert-health (el-chronos-test--hour-ts) "dropped-commands" 5)
      (let* ((resp (el-chronos-web-test--http "GET" "/api/health?range=1d"))
             (parsed (el-chronos-web-test--json resp)))
        (should (equal 200 (plist-get resp :status)))
        (should (equal 1 (plist-get parsed :rows)))
        (should (= 5 (plist-get parsed :dropped-commands)))
        (should (eq :false (plist-get parsed :ok-p)))))))

(ert-deftest el-chronos-web-test-api-startup-missing-session ()
  "GET /api/startup?session=<不存在> → 200 + 同构空结构（不 404、不 500）。
会话可能已被保留策略清理，属正常空结果而非路径错误（与 `/api/event' 的 200 + null 同取舍）。"
  (el-chronos-web-test--with-temp-db
    (el-chronos-web-test--open-fixture-db)
    (el-chronos-web-test--with-server
      (let* ((resp (el-chronos-web-test--http "GET" "/api/startup?session=999999"))
             (parsed (el-chronos-web-test--json resp)))
        (should (equal 200 (plist-get resp :status)))
        (should (string-match-p "application/json" (plist-get resp :headers)))
        (should (= 999999 (plist-get parsed :session-id)))
        ;; 同构空结构：键都在，值为 JSON null（json-parse 把 null 读成 `:null'）
        (should (plist-member parsed :phases))
        (should (eq :null (plist-get parsed :phases)))
        (should (eq :null (plist-get parsed :loads)))
        (should (eq :null (plist-get parsed :startup-ms)))))))

(ert-deftest el-chronos-web-test-api-startup-with-fixture ()
  "GET /api/startup?session=N：阶段锚点按固定顺序返回、包加载按耗时降序。"
  (el-chronos-web-test--with-temp-db
    (el-chronos-web-test--open-fixture-db)
    (let* ((started (- (el-chronos-test--now-ms) 60000))
           (id (el-chronos-test--insert-session started 1500)))
      (el-chronos-test--insert-startup-phase id "mode-start" 100)
      (el-chronos-test--insert-startup-phase id "load:dashboard" 40)
      (el-chronos-test--insert-startup-phase id "load:org" 60)
      (el-chronos-web-test--with-server
        (let* ((resp (el-chronos-web-test--http "GET" (format "/api/startup?session=%d" id)))
               (parsed (el-chronos-web-test--json resp))
               (phases (plist-get parsed :phases))
               (loads (plist-get parsed :loads)))
          (should (equal 200 (plist-get resp :status)))
          (should (= id (plist-get parsed :session-id)))
          (should (= 1500 (plist-get parsed :startup-ms)))
          (should (= 1 (length phases)))
          (should (equal "mode-start" (aref (aref phases 0) 0)))
          (should (= 100 (aref (aref phases 0) 1)))
          (should (= 2 (length loads)))
          (should (equal "org" (aref (aref loads 0) 0)))
          (should (= 60 (aref (aref loads 0) 1)))
          (should (equal "dashboard" (aref (aref loads 1) 0))))))))

(ert-deftest el-chronos-web-test-api-config-history ()
  "GET /api/config-history：首会话 changed 为 null（无从比较），标记变化后为 true；
`:changes' 等于返回列表里 changed 为 true 的条数。"
  (el-chronos-web-test--with-temp-db
    (el-chronos-web-test--open-fixture-db)
    (let* ((now (el-chronos-test--now-ms))
           (auto el-chronos--session-id)
           (old (el-chronos-test--insert-session (- now 7200000)))
           (new (el-chronos-test--insert-session (- now 3600000))))
      (el-chronos-test--insert-session-meta old "git-head" "aaaa1111")
      (el-chronos-test--insert-session-meta old "config-sig" "cccc0000")
      (el-chronos-test--insert-session-meta new "git-head" "bbbb2222")
      (el-chronos-test--insert-session-meta new "config-sig" "cccc0000")
      ;; 删掉 store-open 自动建的当前会话行，让 fixture 成为窗口内唯二会话
      (when auto (el-chronos-test--exec "DELETE FROM sessions WHERE id = ?" (list auto)))
      (el-chronos-web-test--with-server
        (let* ((resp (el-chronos-web-test--http "GET" "/api/config-history?range=1d"))
               (parsed (el-chronos-web-test--json resp))
               (sessions (plist-get parsed :sessions)))
          (should (equal 200 (plist-get resp :status)))
          (should (= 2 (length sessions)))
          (should (equal "aaaa1111" (plist-get (aref sessions 0) :git-head)))
          ;; 首会话：无从比较 → analysis 给 nil → JSON null（不是 false）
          (should (eq :null (plist-get (aref sessions 0) :changed)))
          (should (eq t (plist-get (aref sessions 1) :changed)))
          (should (= 1 (plist-get parsed :changes)))
          (should (= 2 (plist-get parsed :total-sessions)))
          (should (eq :false (plist-get parsed :truncated))))))))

(ert-deftest el-chronos-web-test-api-drift ()
  "GET /api/drift 返回 200 + 合法 JSON：空库 items 为 null、汇总键为 0、阈值随响应下发；
有数据时按桶聚合，汇总字段（次数 / 累计 / 最坏）与桶内容一致。
`:threshold-ms' 是页面文案「≥N ms」的来源 —— 缺了它前端只能写死 500，与可调 defcustom 脱节。"
  (el-chronos-web-test--with-temp-db
    (el-chronos-web-test--open-fixture-db)
    (el-chronos-web-test--with-server
      (let* ((empty-resp (el-chronos-web-test--http "GET" "/api/drift?range=1d&buckets=4"))
             (empty (el-chronos-web-test--json empty-resp)))
        (should (equal 200 (plist-get empty-resp :status)))
        (should (string-match-p "application/json" (plist-get empty-resp :headers)))
        (should (equal "1d" (plist-get empty :range)))
        (should (= 4 (plist-get empty :bucket-count)))
        ;; 空数组经 `--json-value' 序列化为 null（nil 分支），前端按 `items||[]' 处理
        (should (eq :null (plist-get empty :items)))
        (should (= 0 (plist-get empty :drift-total)))
        (should (= 0.0 (plist-get empty :ms-total)))
        (should (= 0.0 (plist-get empty :slowest-ms)))
        (should (= 500 (plist-get empty :threshold-ms)))
        (should (integerp (plist-get empty :bucket-span))))
      (el-chronos-test--exec
       "INSERT INTO hourly_drift (hour_ts, session_id, count, total_ms, max_ms)\
 VALUES (?, ?, ?, ?, ?)"
       (list (el-chronos-test--hour-ts) 0 3 4200.0 1800.0))
      (let* ((resp (el-chronos-web-test--http "GET" "/api/drift?range=1d"))
             (parsed (el-chronos-web-test--json resp))
             (items (plist-get parsed :items))
             (first (aref items 0)))
        (should (equal 200 (plist-get resp :status)))
        (should (= 1 (length items)))
        (should (= 3 (plist-get first :count)))
        (should (= 4200.0 (plist-get first :total-ms)))
        (should (= 1800.0 (plist-get first :max-ms)))
        (should (= 3 (plist-get parsed :drift-total)))
        (should (= 4200.0 (plist-get parsed :ms-total)))
        (should (= 1800.0 (plist-get parsed :slowest-ms)))
        ;; buckets 省略时由 analysis 按窗口长度决定，响应里为 null（不是 0）
        (should (plist-member parsed :bucket-count))
        (should (eq :null (plist-get parsed :bucket-count)))))))

(ert-deftest el-chronos-web-test-export-csv-new-sections ()
  "GET /api/export.csv 含 13 个 `# section:'，其中 startup / health / config-history / drift /
resources 五块齐备。五个手写块的区块名、表头与 report 侧逐字一致（两处内联重复实现，
改动需同步）。区块数由 12 抬到 13：多出 resources（进程资源，位置在 drift 之后 = 最末）。"
  (el-chronos-web-test--with-temp-db
    (el-chronos-web-test--open-fixture-db)
    (el-chronos-web-test--with-server
      (let* ((resp (el-chronos-web-test--http "GET" "/api/export.csv?range=1d"))
             (body (plist-get resp :body)))
        (should (equal 200 (plist-get resp :status)))
        (should (string-match-p "text/csv" (plist-get resp :headers)))
        (should (string-match-p "^# section: overview$" body))
        (should (string-match-p "^# section: startup$" body))
        (should (string-match-p "^# section: health$" body))
        (should (string-match-p "^# section: config-history$" body))
        (should (string-match-p "^# section: drift$" body))
        (should (string-match-p "^# section: resources$" body))
        ;; 表头逐字对齐 report 侧
        (should (string-match-p "^kind,name,ms$" body))
        (should (string-match-p "^metric,value$" body))
        (should (string-match-p "^session_id,started_at_ms,git_head,config_sig,changed$" body))
        (should (string-match-p "^bucket_ms,count,total_ms,max_ms$" body))
        (should (string-match-p
                 (concat "^bucket_ms,cpu_ms,wall_ms,cpu_pct,rss_kb_max,rss_kb_avg,"
                         "threads_max,load1_avg,load5_avg,load15_avg,samples$")
                 body))
        ;; health 必带 rows 行（区分「没采集」与「没异常」）
        (should (string-match-p "^rows," body))
        (should (= 13 (length (cl-remove-if-not
                               (lambda (line) (string-prefix-p "# section: " line))
                               (split-string body "\n")))))))))

(ert-deftest el-chronos-web-test-api-resources ()
  "GET /api/resources 返回 200 + JSON：空库 buckets 为 null 且均值为 null，有数据时按桶聚合。
null 与 0 严格区分：`load_n` 为 0 时 `rss-kb-avg` / `load*-avg` 是 JSON null（不是 0）——
用 0 顶替会把「负载采集全失败」显示成「系统空闲」（与 analysis docstring 同一口径）。
`:cpu-pct-avg' 走 `--pct'，无墙钟样本时为 0.0 而非 null，故不在此列。"
  (el-chronos-web-test--with-temp-db
    (el-chronos-web-test--open-fixture-db)
    (el-chronos-web-test--with-server
      (let* ((empty-resp (el-chronos-web-test--http "GET" "/api/resources?range=1d&buckets=4"))
             (empty (el-chronos-web-test--json empty-resp)))
        (should (equal 200 (plist-get empty-resp :status)))
        (should (string-match-p "application/json" (plist-get empty-resp :headers)))
        (should (equal "1d" (plist-get empty :range)))
        (should (= 4 (plist-get empty :bucket-count)))
        ;; 空数组经 `--json-value' 序列化为 null（nil 分支），前端按 `buckets||[]' 处理
        (should (plist-member empty :buckets))
        (should (eq :null (plist-get empty :buckets)))
        (should (eq :null (plist-get empty :rss-kb-max)))
        (should (eq :null (plist-get empty :rss-kb-avg)))
        (should (eq :null (plist-get empty :load1-avg)))
        (should (= 0.0 (plist-get empty :cpu-ms-total)))
        (should (= 0 (or (plist-get empty :samples) 0)))
        (should (integerp (plist-get empty :bucket-span))))
      ;; cpu 3000ms / 墙钟 12000ms → 25%；rss 峰值 204800KB；线程 18；
      ;; 负载 6/9/12 之和除以 load_n=3 → 2.0/3.0/4.0
      (el-chronos-test--exec
       "INSERT INTO hourly_resources (hour_ts, session_id, cpu_ms, wall_ms, rss_kb_max,\
 rss_kb_sum, threads_max, load1_sum, load5_sum, load15_sum, load_n)\
 VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
       (list (el-chronos-test--hour-ts) 0 3000.0 12000.0 204800 409600 18 6.0 9.0 12.0 3))
      (let* ((resp (el-chronos-web-test--http "GET" "/api/resources?range=1d"))
             (parsed (el-chronos-web-test--json resp))
             (items (plist-get parsed :buckets))
             (first (aref items 0)))
        (should (equal 200 (plist-get resp :status)))
        (should (= 1 (length items)))
        (should (= 25.0 (plist-get first :cpu-pct)))
        (should (= 204800 (plist-get first :rss-kb-max)))
        (should (= 18 (plist-get first :threads-max)))
        (should (= 2.0 (plist-get first :load1-avg)))
        (should (= 3 (plist-get first :samples)))
        (should (= 204800 (plist-get parsed :rss-kb-max)))
        (should (= 18 (plist-get parsed :threads-max)))
        (should (= 2.0 (plist-get parsed :load1-avg)))
        ;; buckets 省略时由 analysis 按窗口长度决定，响应里为 null（不是 0）
        (should (plist-member parsed :bucket-count))
        (should (eq :null (plist-get parsed :bucket-count)))))))

(ert-deftest el-chronos-web-test-routes-count ()
  "路由表共 19 条且六个新查询路由已注册、无重复键。
新增路由必须同步 `docs/ui.org' 的 17 条 API 路由表（T10）。"
  (should (= 19 (length el-chronos-web--routes)))
  (should (= 19 (length (delete-dups (mapcar #'car el-chronos-web--routes)))))
  (dolist (path '("/api/gc" "/api/resources" "/api/startup" "/api/health"
                  "/api/config-history" "/api/drift"))
    (should (assoc path el-chronos-web--routes))))

;;; 交互启动时自动打开浏览器（`el-chronos-web-open-browser'）

(defmacro el-chronos-web-test--with-browse-stub (calls &rest body)
  "在 BODY 期间把 `browse-url' 桩成记录器，不真的打开浏览器（batch 下也没有图形界面）。
每次调用把 URL `push' 进变量 CALLS（须为本用例 `let' 绑定的列表变量，最近一次在前），
并原样返回 URL（真实 `browse-url' 的返回值不稳定，测试不依赖它）。"
  (declare (indent 1) (debug t))
  `(cl-letf (((symbol-function 'browse-url)
              (lambda (url &rest _)
                (setq ,calls (cons url ,calls))
                url)))
     ,@body))

(defmacro el-chronos-web-test--with-message-stub (msgs &rest body)
  "在 BODY 期间把 `message' 桩成收集器，格式化后的文本 `push' 进变量 MSGS。
用于断言降级路径确实发出了可见提示（I11：不得静默失败），同时不污染 batch 输出。
CALLS / MSGS 同样是本用例 `let' 绑定的列表变量，最近一条在前。"
  (declare (indent 1) (debug t))
  `(cl-letf (((symbol-function 'message)
              (lambda (fmt &rest args)
                (setq ,msgs
                      (cons (condition-case nil
                                (apply #'format-message fmt args)
                              (error (if (stringp fmt) fmt (format "%s" fmt))))
                            ,msgs)))))
     ,@body))

(ert-deftest el-chronos-web-test-start-browses-when-interactive ()
  "交互式启动 + `el-chronos-web-open-browser' 为 t → `browse-url' 恰好被调用一次，
参数是 `http://127.0.0.1:PORT/' 形态（PORT 取实际绑定端口，不是入参 0）。
交互上下文用 `cl-letf' 桩 `called-interactively-p' 模拟，比 `call-interactively' 轻。"
  (el-chronos-web-test--with-temp-db
    (ignore-errors (el-chronos-web-stop))
    (let ((el-chronos-web-open-browser t)
          (calls nil))
      (unwind-protect
          (el-chronos-web-test--with-browse-stub calls
            (cl-letf (((symbol-function 'called-interactively-p) (lambda (&rest _) t)))
              (let* ((proc (el-chronos-web-start 0))
                     (port (process-contact proc :service)))
                (should (processp proc))
                (should (integerp port))
                (should (= 1 (length calls)))
                (should (equal (format "http://127.0.0.1:%d/" port) (car calls))))))
        (ignore-errors (el-chronos-web-stop))))))

(ert-deftest el-chronos-web-test-start-keeps-quiet-when-disabled ()
  "交互式启动但开关为 nil → 不打开浏览器；server 仍启动、URL 提示仍输出（可见不中断）。"
  (el-chronos-web-test--with-temp-db
    (ignore-errors (el-chronos-web-stop))
    (let ((el-chronos-web-open-browser nil)
          (calls nil)
          (msgs nil))
      (unwind-protect
          (el-chronos-web-test--with-browse-stub calls
            (cl-letf (((symbol-function 'called-interactively-p) (lambda (&rest _) t)))
              (el-chronos-web-test--with-message-stub msgs
                (let ((proc (el-chronos-web-start 0)))
                  (should (processp proc))
                  (should (el-chronos-web-running-p))
                  (should-not calls)
                  (should (= 1 (length msgs)))
                  (should (string-match-p
                           (format "127\\.0\\.0\\.1:%d" (process-contact proc :service))
                           (car msgs)))))))
        (ignore-errors (el-chronos-web-stop))))))

(ert-deftest el-chronos-web-test-start-does-not-browse-programmatically ()
  "程序化启动（非交互）即使开关为 t 也不弹浏览器 —— 这条挡住「每次启动 Emacs 都弹窗」。
本用例**不桩** `called-interactively-p'：batch 下它真实返回 nil，也就是
`el-chronos-web-auto-start' 等程序化调用所处的上下文。"
  (el-chronos-web-test--with-temp-db
    (ignore-errors (el-chronos-web-stop))
    (let ((el-chronos-web-open-browser t)
          (calls nil))
      (unwind-protect
          (el-chronos-web-test--with-browse-stub calls
            (let ((proc (el-chronos-web-start 0)))
              (should (processp proc))
              (should (el-chronos-web-running-p))
              (should-not calls)))
        (ignore-errors (el-chronos-web-stop))))))

(ert-deftest el-chronos-web-test-start-survives-browse-url-error ()
  "`browse-url' 抛错（无 GUI / 无可用浏览器）→ 错误不外抛、server 照常运行，
且给出含 URL 的可见降级提示（I11：可见降级，不静默、不变成错误）。"
  (el-chronos-web-test--with-temp-db
    (ignore-errors (el-chronos-web-stop))
    (let ((el-chronos-web-open-browser t)
          (msgs nil)
          (proc nil))
      (unwind-protect
          (cl-letf (((symbol-function 'browse-url)
                     (lambda (&rest _) (error "No usable browser")))
                    ((symbol-function 'called-interactively-p) (lambda (&rest _) t)))
            (el-chronos-web-test--with-message-stub msgs
              (setq proc (el-chronos-web-start 0))
              (should (processp proc))
              (should (el-chronos-web-running-p))
              ;; 两条消息：启动提示 + 打开失败提示（最近一条在前）
              (should (= 2 (length msgs)))
              (should (string-match-p "打开浏览器失败" (car msgs)))
              (should (string-match-p
                       (format "127\\.0\\.0\\.1:%d" (process-contact proc :service))
                       (car msgs)))))
        (ignore-errors (el-chronos-web-stop))))))

(ert-deftest el-chronos-web-test-browse-starts-server-when-needed ()
  "`el-chronos-web-browse' 未启动时先拉起 server，且只打开一次浏览器（不双弹）。
顺带断言 `--url' 在 PROC 为 nil 时回落 `el-chronos-web-port'。
`el-chronos-web-port' 绑 0：本命令内部调 `el-chronos-web-start' 走默认端口，而默认 8787
可能正被用户运行中的 dashboard（或本机其它进程）占用，绑 0 由内核分配才不依赖环境。"
  (el-chronos-web-test--with-temp-db
    (ignore-errors (el-chronos-web-stop))
    (let ((el-chronos-web-open-browser t)
          (el-chronos-web-port 0)
          (calls nil))
      (unwind-protect
          (el-chronos-web-test--with-browse-stub calls
            (should-not (el-chronos-web-running-p))
            (el-chronos-web-browse)
            (should (el-chronos-web-running-p))
            (should (= 1 (length calls)))
            (should (equal (format "http://127.0.0.1:%d/"
                                   (process-contact el-chronos-web--process :service))
                           (car calls)))
            ;; PROC 为 nil → 回落 `el-chronos-web-port'
            (let ((el-chronos-web-port 65000))
              (should (equal "http://127.0.0.1:65000/" (el-chronos-web--url)))))
        (ignore-errors (el-chronos-web-stop))))))

(ert-deftest el-chronos-web-test-browse-reuses-running-server ()
  "`el-chronos-web-browse' 在 server 已运行时复用同一进程（不重启、不提端口），只打开一次。"
  (el-chronos-web-test--with-temp-db
    (ignore-errors (el-chronos-web-stop))
    (let ((el-chronos-web-open-browser t)
          (calls nil))
      (unwind-protect
          (let ((proc (el-chronos-web-start 0)))
            (should (processp proc))
            (el-chronos-web-test--with-browse-stub calls
              (el-chronos-web-browse)
              (should (eq proc el-chronos-web--process))
              (should (process-live-p proc))
              (should (= 1 (length calls)))
              (should (equal (format "http://127.0.0.1:%d/"
                                     (process-contact proc :service))
                             (car calls)))))
        (ignore-errors (el-chronos-web-stop))))))

(provide 'el-chronos-web-test)

;;; el-chronos-web-test.el ends here
