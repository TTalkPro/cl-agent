;;;; mcp-client.lisp
;;;; CL-Agent - MCP 客户端实现
;;;;
;;;; 概述：
;;;;   实现 MCP 客户端功能
;;;;
;;;; 特性：
;;;;   - 连接管理（stdio 和 HTTP 传输）
;;;;   - 初始化握手
;;;;   - 资源访问
;;;;   - 工具调用
;;;;   - 提示模板

(in-package :cl-agent.protocols)

;;; ============================================================
;;; 请求 ID 生成
;;; ============================================================

(defvar *mcp-request-id* 0
  "MCP 请求 ID 计数器")

(defun mcp-next-request-id ()
  "生成下一个请求 ID"
  (incf *mcp-request-id*))

;;; ============================================================
;;; 传输层实现
;;; ============================================================

(defun mcp-send-message (transport message)
  "通过传输层发送消息

  参数：
    TRANSPORT - 传输层
    MESSAGE   - MCP 消息

  返回：
    是否成功"
  (unless (mcp-transport-connected-p transport)
    (error "Transport is not connected"))

  (let ((json-str (mcp-message-to-json message)))
    (case (mcp-transport-type transport)
      (:stdio
       (mcp-send-stdio transport json-str))
      (:http
       (mcp-send-http transport json-str))
      (otherwise
       (error "Unknown transport type: ~A" (mcp-transport-type transport))))))

(defun mcp-receive-message (transport &key (timeout 30))
  "从传输层接收消息

  参数：
    TRANSPORT - 传输层
    TIMEOUT   - 超时秒数

  返回：
    MCP 消息或 NIL"
  (unless (mcp-transport-connected-p transport)
    (error "Transport is not connected"))

  (case (mcp-transport-type transport)
    (:stdio
     (mcp-receive-stdio transport :timeout timeout))
    (:http
     (mcp-receive-http transport :timeout timeout))
    (otherwise
     (error "Unknown transport type: ~A" (mcp-transport-type transport)))))

(defun mcp-send-stdio (transport json-str)
  "通过 stdio 发送消息

  参数：
    TRANSPORT - 传输层
    JSON-STR  - JSON 字符串

  返回：
    是否成功"
  (let* ((config (mcp-transport-config transport))
         (process-stream (when config (gethash "process-input" config))))
    (if process-stream
        (progn
          ;; 按照 JSON-RPC over stdio 协议发送
          ;; 格式: Content-Length: N\r\n\r\n<json>
          (format process-stream "Content-Length: ~D~C~C~C~C~A"
                  (length json-str)
                  #\Return #\Newline #\Return #\Newline
                  json-str)
          (force-output process-stream)
          (mcp-log :debug "Sent message: ~A" json-str)
          t)
        (progn
          (mcp-log :error "No process stream available for stdio transport")
          nil))))

(defun mcp-receive-stdio (transport &key (timeout 30))
  "从 stdio 接收消息

  参数：
    TRANSPORT - 传输层
    TIMEOUT   - 超时秒数

  返回：
    MCP 消息或 NIL"
  (declare (ignore timeout))
  (let* ((config (mcp-transport-config transport))
         (process-stream (when config (gethash "process-output" config))))
    (if process-stream
        (handler-case
            (let* ((header-line (read-line process-stream nil nil))
                   (content-length (when (and header-line
                                              (search "Content-Length:" header-line))
                                    (parse-integer
                                     (string-trim " " (subseq header-line 15))
                                     :junk-allowed t))))
              (when content-length
                ;; 跳过空行
                (read-line process-stream nil nil)
                ;; 读取 JSON 内容
                (let ((buffer (make-string content-length)))
                  (read-sequence buffer process-stream)
                  (mcp-log :debug "Received message: ~A" buffer)
                  (json-to-mcp-message buffer))))
          (error (e)
            (mcp-log :error "Error receiving stdio message: ~A" e)
            nil))
        (progn
          (mcp-log :error "No process stream available for stdio transport")
          nil))))

(defun mcp-send-http (transport json-str)
  "通过 HTTP 发送消息

  参数：
    TRANSPORT - 传输层
    JSON-STR  - JSON 字符串

  返回：
    HTTP 响应"
  (let* ((config (mcp-transport-config transport))
         (base-url (when config (gethash "base-url" config)))
         (headers (when config (gethash "headers" config))))
    (unless base-url
      (error "No base URL configured for HTTP transport"))

    (handler-case
        (let ((response (cl-agent.http:http-post
                         (format nil "~A/message" base-url)
                         :body json-str
                         :headers (append
                                   '(("Content-Type" . "application/json"))
                                   headers)
                         :timeout 30)))
          (mcp-log :debug "HTTP request sent, status: ~A"
                   (cl-agent.http:http-response-status response))
          response)
      (error (e)
        (mcp-log :error "HTTP send error: ~A" e)
        nil))))

(defun mcp-receive-http (transport &key (timeout 30))
  "从 HTTP 响应接收消息

  参数：
    TRANSPORT - 传输层
    TIMEOUT   - 超时秒数

  返回：
    MCP 消息或 NIL"
  (declare (ignore transport timeout))
  ;; HTTP 模式下，响应在 send 时已经获取
  ;; 这里用于 SSE 或 WebSocket 等流式场景
  nil)

;;; ============================================================
;;; 请求/响应处理
;;; ============================================================

(defun mcp-client-send-request (client method &key (params nil) (timeout 30))
  "发送请求并等待响应

  参数：
    CLIENT  - MCP 客户端
    METHOD  - 方法名
    PARAMS  - 参数
    TIMEOUT - 超时秒数

  返回：
    响应消息"
  (let* ((connection (mcp-client-connection client))
         (transport (mcp-connection-transport connection))
         (request-id (mcp-next-request-id))
         (request (make-request-message request-id method :params params)))

    (mcp-log :debug "Sending request: ~A (id=~A)" method request-id)

    ;; 根据传输类型处理
    (case (mcp-transport-type transport)
      (:stdio
       ;; stdio: 发送请求，然后等待响应
       (mcp-send-message transport request)
       (let ((response (mcp-receive-message transport :timeout timeout)))
         (when response
           (unless (eql (mcp-message-id response) request-id)
             (mcp-log :warn "Response ID mismatch: expected ~A, got ~A"
                      request-id (mcp-message-id response))))
         response))

      (:http
       ;; HTTP: 同步请求/响应
       (let* ((config (mcp-transport-config transport))
              (base-url (when config (gethash "base-url" config)))
              (headers (when config (gethash "headers" config)))
              (json-str (mcp-message-to-json request)))
         (handler-case
             (let* ((http-response (cl-agent.http:http-post
                                    (format nil "~A/message" base-url)
                                    :body json-str
                                    :headers (append
                                              '(("Content-Type" . "application/json"))
                                              headers)
                                    :timeout timeout))
                    (response-body (cl-agent.http:http-response-body http-response)))
               (when response-body
                 (json-to-mcp-message response-body)))
           (error (e)
             (mcp-log :error "HTTP request error: ~A" e)
             nil))))

      (otherwise
       (error "Unknown transport type: ~A" (mcp-transport-type transport))))))

(defun mcp-client-send-notification (client method &key (params nil))
  "发送通知（不等待响应）

  参数：
    CLIENT - MCP 客户端
    METHOD - 方法名
    PARAMS - 参数

  返回：
    是否成功"
  (let* ((connection (mcp-client-connection client))
         (transport (mcp-connection-transport connection))
         (notification (make-notification-message method :params params)))

    (mcp-log :debug "Sending notification: ~A" method)
    (mcp-send-message transport notification)))

;;; ============================================================
;;; 客户端连接
;;; ============================================================

(defun mcp-client-connect (client &key (server-command nil) (base-url nil) (headers nil))
  "连接到 MCP 服务器

  参数：
    CLIENT         - MCP 客户端
    SERVER-COMMAND - 服务器命令（用于 stdio 传输）
    BASE-URL       - 基础 URL（用于 HTTP 传输）
    HEADERS        - HTTP 请求头

  返回：
    连接是否成功"
  (mcp-log :info "Connecting to MCP server...")

  (let ((transport (mcp-connection-transport
                    (mcp-client-connection client))))
    (case (mcp-transport-type transport)
      (:stdio
       (mcp-connect-stdio client server-command))
      (:http
       (mcp-connect-http client base-url headers))
      (otherwise
       (mcp-log :error "Unknown transport type: ~A" (mcp-transport-type transport))
       nil))))

(defun mcp-connect-stdio (client server-command)
  "通过 stdio 连接

  参数：
    CLIENT         - MCP 客户端
    SERVER-COMMAND - 服务器命令

  返回：
    是否成功"
  (unless server-command
    (mcp-log :error "Server command required for stdio transport")
    (return-from mcp-connect-stdio nil))

  (let* ((connection (mcp-client-connection client))
         (transport (mcp-connection-transport connection))
         (config (or (mcp-transport-config transport)
                     (make-hash-table :test #'equal))))

    ;; 存储命令
    (setf (gethash "command" config) server-command)

    ;; 启动子进程
    (handler-case
        (let* ((command-parts (if (stringp server-command)
                                  (uiop:split-string server-command)
                                  server-command))
               (process-info (uiop:launch-program
                              command-parts
                              :input :stream
                              :output :stream
                              :error-output :stream)))
          ;; 存储进程流
          (setf (gethash "process" config) process-info)
          (setf (gethash "process-input" config)
                (uiop:process-info-input process-info))
          (setf (gethash "process-output" config)
                (uiop:process-info-output process-info))

          (setf (mcp-transport-config transport) config)
          (setf (mcp-transport-connected-p transport) t)
          (setf (mcp-connection-state connection) :connected)

          (mcp-log :info "Connected via stdio (command: ~A)" server-command)
          t)
      (error (e)
        (mcp-log :error "Failed to start server process: ~A" e)
        nil))))

(defun mcp-connect-http (client base-url headers)
  "通过 HTTP 连接

  参数：
    CLIENT   - MCP 客户端
    BASE-URL - 基础 URL
    HEADERS  - 请求头

  返回：
    是否成功"
  (unless base-url
    (mcp-log :error "Base URL required for HTTP transport")
    (return-from mcp-connect-http nil))

  (let* ((connection (mcp-client-connection client))
         (transport (mcp-connection-transport connection))
         (config (or (mcp-transport-config transport)
                     (make-hash-table :test #'equal))))

    ;; 存储配置
    (setf (gethash "base-url" config) base-url)
    (setf (gethash "headers" config) headers)

    ;; 验证连接（可选：发送 ping 请求）
    (handler-case
        (progn
          (setf (mcp-transport-config transport) config)
          (setf (mcp-transport-connected-p transport) t)
          (setf (mcp-connection-state connection) :connected)

          (mcp-log :info "Connected via HTTP (base-url: ~A)" base-url)
          t)
      (error (e)
        (mcp-log :error "Failed to connect via HTTP: ~A" e)
        nil))))

(defun mcp-client-disconnect (client)
  "断开与 MCP 服务器的连接

  参数：
    CLIENT - MCP 客户端

  返回：
    是否成功断开"
  (mcp-log :info "Disconnecting from MCP server...")

  (let ((transport (mcp-connection-transport
                    (mcp-client-connection client))))
    (setf (mcp-transport-connected-p transport) nil)
    (setf (mcp-connection-state (mcp-client-connection client))
          :disconnected)
    (mcp-log :info "Disconnected")
    t))

(defun mcp-client-initialize (client)
  "初始化 MCP 连接

  参数：
    CLIENT - MCP 客户端

  返回：
    是否成功初始化"
  (mcp-log :info "Initializing MCP connection...")

  ;; 检查连接状态
  (unless (eq (mcp-connection-state (mcp-client-connection client))
              :connected)
    (error "Client is not connected"))

  ;; 发送初始化请求
  (let* ((params (make-hash-table :test #'equal))
         (caps-obj (make-hash-table :test #'equal))
         (info-obj (make-hash-table :test #'equal))
         (client-info (mcp-client-info client))
         (client-caps (mcp-client-capabilities client)))

    ;; 构建参数
    (setf (gethash "protocolVersion" params) *mcp-protocol-version*)

    ;; 能力
    (when (mcp-capabilities-roots client-caps)
      (setf (gethash "roots" caps-obj) (mcp-capabilities-roots client-caps)))
    (when (mcp-capabilities-sampling client-caps)
      (setf (gethash "sampling" caps-obj) (mcp-capabilities-sampling client-caps)))
    (setf (gethash "capabilities" params) caps-obj)

    ;; 客户端信息
    (setf (gethash "name" info-obj) (mcp-client-info-name client-info))
    (setf (gethash "version" info-obj) (mcp-client-info-version client-info))
    (setf (gethash "clientInfo" params) info-obj)

    ;; 发送请求
    (let ((response (mcp-client-send-request client "initialize" :params params)))
      (if response
          (handler-case
              (progn
                ;; 解析响应
                (multiple-value-bind (server-info server-caps)
                    (mcp-parse-initialize-response response)
                  (let ((connection (mcp-client-connection client)))
                    (setf (mcp-connection-server-info connection) server-info)
                    (setf (mcp-connection-server-caps connection) server-caps)
                    (setf (mcp-connection-state connection) :initialized)

                    ;; 发送已初始化通知
                    (mcp-client-send-notification client "notifications/initialized")

                    (mcp-log :info "MCP connection initialized (server: ~A ~A)"
                             (mcp-server-info-name server-info)
                             (mcp-server-info-version server-info))
                    t)))
            (error (e)
              (mcp-log :error "Failed to parse initialize response: ~A" e)
              nil))
          (progn
            (mcp-log :error "No response received for initialize request")
            nil)))))

;;; ============================================================
;;; 资源访问
;;; ============================================================

(defun mcp-client-list-resources (client &key (cursor nil))
  "列出可用资源

  参数：
    CLIENT - MCP 客户端
    CURSOR - 分页游标

  返回：
    资源列表 ((:resources ... :next-cursor ...))"
  (mcp-log :info "Listing resources...")

  ;; 检查连接状态
  (unless (eq (mcp-connection-state (mcp-client-connection client))
              :initialized)
    (error "Client is not initialized"))

  ;; 构建参数
  (let ((params (make-hash-table :test #'equal)))
    (when cursor
      (setf (gethash "cursor" params) cursor))

    ;; 发送请求
    (let ((response (mcp-client-send-request client "resources/list"
                                              :params (when cursor params))))
      (if (and response (mcp-message-result response))
          (let* ((result (mcp-message-result response))
                 (resources-raw (gethash "resources" result))
                 (next-cursor (gethash "nextCursor" result)))
            (list :resources (mcp-parse-resources resources-raw)
                  :next-cursor next-cursor))
          '(:resources nil :next-cursor nil)))))

(defun mcp-parse-resources (resources-raw)
  "解析资源列表

  参数：
    RESOURCES-RAW - 原始资源列表

  返回：
    mcp-resource 列表"
  (when resources-raw
    (loop for res across (if (vectorp resources-raw) resources-raw
                             (coerce resources-raw 'vector))
          collect (make-mcp-resource
                   :uri (gethash "uri" res)
                   :name (gethash "name" res)
                   :description (gethash "description" res)
                   :mime-type (or (gethash "mimeType" res) "text/plain")))))

(defun mcp-client-read-resource (client uri)
  "读取资源内容

  参数：
    CLIENT - MCP 客户端
    URI    - 资源 URI

  返回：
    资源内容 plist (:contents ...)"
  (mcp-log :info "Reading resource: ~A" uri)

  ;; 检查连接状态
  (unless (eq (mcp-connection-state (mcp-client-connection client))
              :initialized)
    (error "Client is not initialized"))

  ;; 构建参数
  (let ((params (make-hash-table :test #'equal)))
    (setf (gethash "uri" params) uri)

    ;; 发送请求
    (let ((response (mcp-client-send-request client "resources/read" :params params)))
      (if (and response (mcp-message-result response))
          (let* ((result (mcp-message-result response))
                 (contents (gethash "contents" result)))
            (list :contents (mcp-parse-resource-contents contents)))
          '(:contents nil)))))

(defun mcp-parse-resource-contents (contents-raw)
  "解析资源内容

  参数：
    CONTENTS-RAW - 原始内容列表

  返回：
    内容列表"
  (when contents-raw
    (loop for content across (if (vectorp contents-raw) contents-raw
                                  (coerce contents-raw 'vector))
          collect (list :uri (gethash "uri" content)
                        :mime-type (gethash "mimeType" content)
                        :text (gethash "text" content)
                        :blob (gethash "blob" content)))))

(defun mcp-client-subscribe-resource (client uri)
  "订阅资源更新

  参数：
    CLIENT - MCP 客户端
    URI    - 资源 URI

  返回：
    是否成功"
  (mcp-log :info "Subscribing to resource: ~A" uri)

  ;; 检查能力
  (let ((server-caps (mcp-connection-server-caps
                      (mcp-client-connection client))))
    (unless (and server-caps
                 (mcp-capabilities-resources server-caps)
                 (gethash "subscribe" (mcp-capabilities-resources server-caps)))
      (error "Server does not support resource subscription")))

  ;; 构建参数
  (let ((params (make-hash-table :test #'equal)))
    (setf (gethash "uri" params) uri)

    ;; 发送请求
    (let ((response (mcp-client-send-request client "resources/subscribe" :params params)))
      (and response (not (mcp-message-error response))))))

(defun mcp-client-unsubscribe-resource (client uri)
  "取消订阅资源

  参数：
    CLIENT - MCP 客户端
    URI    - 资源 URI

  返回：
    是否成功"
  (mcp-log :info "Unsubscribing from resource: ~A" uri)

  ;; 构建参数
  (let ((params (make-hash-table :test #'equal)))
    (setf (gethash "uri" params) uri)

    ;; 发送请求
    (let ((response (mcp-client-send-request client "resources/unsubscribe" :params params)))
      (and response (not (mcp-message-error response))))))

;;; ============================================================
;;; 提示模板
;;; ============================================================

(defun mcp-client-list-prompts (client &key (cursor nil))
  "列出可用提示模板

  参数：
    CLIENT - MCP 客户端
    CURSOR - 分页游标

  返回：
    提示模板列表 (:prompts ... :next-cursor ...)"
  (mcp-log :info "Listing prompts...")

  ;; 检查连接状态
  (unless (eq (mcp-connection-state (mcp-client-connection client))
              :initialized)
    (error "Client is not initialized"))

  ;; 构建参数
  (let ((params (when cursor
                  (let ((p (make-hash-table :test #'equal)))
                    (setf (gethash "cursor" p) cursor)
                    p))))

    ;; 发送请求
    (let ((response (mcp-client-send-request client "prompts/list" :params params)))
      (if (and response (mcp-message-result response))
          (let* ((result (mcp-message-result response))
                 (prompts-raw (gethash "prompts" result))
                 (next-cursor (gethash "nextCursor" result)))
            (list :prompts (mcp-parse-prompts prompts-raw)
                  :next-cursor next-cursor))
          '(:prompts nil :next-cursor nil)))))

(defun mcp-parse-prompts (prompts-raw)
  "解析提示模板列表

  参数：
    PROMPTS-RAW - 原始提示列表

  返回：
    mcp-prompt 列表"
  (when prompts-raw
    (loop for prompt across (if (vectorp prompts-raw) prompts-raw
                                 (coerce prompts-raw 'vector))
          collect (make-mcp-prompt
                   :name (gethash "name" prompt)
                   :description (gethash "description" prompt)
                   :arguments (mcp-parse-prompt-arguments
                               (gethash "arguments" prompt))))))

(defun mcp-parse-prompt-arguments (args-raw)
  "解析提示参数

  参数：
    ARGS-RAW - 原始参数列表

  返回：
    参数列表"
  (when args-raw
    (loop for arg across (if (vectorp args-raw) args-raw
                              (coerce args-raw 'vector))
          collect (list :name (gethash "name" arg)
                        :description (gethash "description" arg)
                        :required (gethash "required" arg)))))

(defun mcp-client-get-prompt (client name &key (arguments nil))
  "获取提示模板

  参数：
    CLIENT    - MCP 客户端
    NAME      - 提示名称
    ARGUMENTS - 参数 (hash-table 或 plist)

  返回：
    提示内容 (:description ... :messages ...)"
  (mcp-log :info "Getting prompt: ~A" name)

  ;; 检查连接状态
  (unless (eq (mcp-connection-state (mcp-client-connection client))
              :initialized)
    (error "Client is not initialized"))

  ;; 构建参数
  (let ((params (make-hash-table :test #'equal)))
    (setf (gethash "name" params) name)
    (when arguments
      (setf (gethash "arguments" params)
            (if (hash-table-p arguments)
                arguments
                (plist-to-hash-table arguments))))

    ;; 发送请求
    (let ((response (mcp-client-send-request client "prompts/get" :params params)))
      (if (and response (mcp-message-result response))
          (let* ((result (mcp-message-result response))
                 (description (gethash "description" result))
                 (messages (gethash "messages" result)))
            (list :description description
                  :messages (mcp-parse-prompt-messages messages)))
          '(:description nil :messages nil)))))

(defun mcp-parse-prompt-messages (messages-raw)
  "解析提示消息列表

  参数：
    MESSAGES-RAW - 原始消息列表

  返回：
    消息列表"
  (when messages-raw
    (loop for msg across (if (vectorp messages-raw) messages-raw
                              (coerce messages-raw 'vector))
          collect (list :role (gethash "role" msg)
                        :content (gethash "content" msg)))))

(defun plist-to-hash-table (plist)
  "将 plist 转换为 hash-table

  参数：
    PLIST - plist

  返回：
    hash-table"
  (let ((ht (make-hash-table :test #'equal)))
    (loop for (key value) on plist by #'cddr
          do (setf (gethash (string-downcase (string key)) ht) value))
    ht))

;;; ============================================================
;;; 工具调用
;;; ============================================================

(defun mcp-client-list-tools (client &key (cursor nil))
  "列出可用工具

  参数：
    CLIENT - MCP 客户端
    CURSOR - 分页游标

  返回：
    工具列表 (:tools ... :next-cursor ...)"
  (mcp-log :info "Listing tools...")

  ;; 检查连接状态
  (unless (eq (mcp-connection-state (mcp-client-connection client))
              :initialized)
    (error "Client is not initialized"))

  ;; 构建参数
  (let ((params (when cursor
                  (let ((p (make-hash-table :test #'equal)))
                    (setf (gethash "cursor" p) cursor)
                    p))))

    ;; 发送请求
    (let ((response (mcp-client-send-request client "tools/list" :params params)))
      (if (and response (mcp-message-result response))
          (let* ((result (mcp-message-result response))
                 (tools-raw (gethash "tools" result))
                 (next-cursor (gethash "nextCursor" result)))
            (list :tools (mcp-parse-tools tools-raw)
                  :next-cursor next-cursor))
          '(:tools nil :next-cursor nil)))))

(defun mcp-parse-tools (tools-raw)
  "解析工具列表

  参数：
    TOOLS-RAW - 原始工具列表

  返回：
    mcp-tool 列表"
  (when tools-raw
    (loop for tool across (if (vectorp tools-raw) tools-raw
                               (coerce tools-raw 'vector))
          collect (make-mcp-tool
                   :name (gethash "name" tool)
                   :description (or (gethash "description" tool) "")
                   :input-schema (gethash "inputSchema" tool)))))

(defun mcp-client-call-tool (client name arguments)
  "调用工具

  参数：
    CLIENT    - MCP 客户端
    NAME      - 工具名称
    ARGUMENTS - 参数 (hash-table 或 plist)

  返回：
    工具执行结果 (:content ... :is-error ...)"
  (mcp-log :info "Calling tool: ~A" name)

  ;; 检查连接状态
  (unless (eq (mcp-connection-state (mcp-client-connection client))
              :initialized)
    (error "Client is not initialized"))

  ;; 构建参数
  (let ((params (make-hash-table :test #'equal)))
    (setf (gethash "name" params) name)
    (setf (gethash "arguments" params)
          (if (hash-table-p arguments)
              arguments
              (plist-to-hash-table arguments)))

    ;; 发送请求
    (let ((response (mcp-client-send-request client "tools/call" :params params)))
      (cond
        ;; 检查 JSON-RPC 错误
        ((and response (mcp-message-error response))
         (let ((err (mcp-message-error response)))
           (list :content nil
                 :is-error t
                 :error-code (mcp-error-code err)
                 :error-message (mcp-error-message err))))

        ;; 正常响应
        ((and response (mcp-message-result response))
         (let* ((result (mcp-message-result response))
                (content (gethash "content" result))
                (is-error (gethash "isError" result)))
           (list :content (mcp-parse-tool-content content)
                 :is-error is-error)))

        ;; 无响应
        (t
         (list :content nil
               :is-error t
               :error-message "No response received"))))))

(defun mcp-parse-tool-content (content-raw)
  "解析工具返回内容

  参数：
    CONTENT-RAW - 原始内容列表

  返回：
    内容列表"
  (when content-raw
    (loop for item across (if (vectorp content-raw) content-raw
                               (coerce content-raw 'vector))
          collect (let ((type (gethash "type" item)))
                    (cond
                      ((string= type "text")
                       (list :type :text :text (gethash "text" item)))
                      ((string= type "image")
                       (list :type :image
                             :data (gethash "data" item)
                             :mime-type (gethash "mimeType" item)))
                      ((string= type "resource")
                       (list :type :resource
                             :resource (gethash "resource" item)))
                      (t
                       (list :type (intern (string-upcase type) :keyword)
                             :raw item)))))))

;;; ============================================================
;;; 便捷函数
;;; ============================================================

(defun mcp-connect (&key (server-command nil))
  "连接到 MCP 服务器（使用默认客户端）

  参数：
    SERVER-COMMAND - 服务器命令

  返回：
    是否成功"
  (let ((client (get-default-mcp-client)))
    (mcp-client-connect client :server-command server-command)
    (mcp-client-initialize client)))

(defun mcp-disconnect ()
  "断开连接（使用默认客户端）

  返回：
    是否成功"
  (let ((client (get-default-mcp-client)))
    (mcp-client-disconnect client)))

(defun mcp-list-resources (&key (cursor nil))
  "列出资源（使用默认客户端）

  参数：
    CURSOR - 分页游标

  返回：
    资源列表"
  (mcp-client-list-resources (get-default-mcp-client) :cursor cursor))

(defun mcp-read-resource (uri)
  "读取资源（使用默认客户端）

  参数：
    URI - 资源 URI

  返回：
    资源内容"
  (mcp-client-read-resource (get-default-mcp-client) uri))

(defun mcp-list-tools (&key (cursor nil))
  "列出工具（使用默认客户端）

  参数：
    CURSOR - 分页游标

  返回：
    工具列表"
  (mcp-client-list-tools (get-default-mcp-client) :cursor cursor))

(defun mcp-call-tool (name arguments)
  "调用工具（使用默认客户端）

  参数：
    NAME      - 工具名称
    ARGUMENTS - 参数

  返回：
    工具执行结果"
  (mcp-client-call-tool (get-default-mcp-client) name arguments))
