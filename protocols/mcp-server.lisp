;;;; mcp-server.lisp
;;;; CL-Agent - MCP 服务器实现
;;;;
;;;; 概述：
;;;;   实现 MCP 服务器功能
;;;;
;;;; 特性：
;;;;   - 服务器连接管理
;;;;   - 资源提供
;;;;   - 工具暴露
;;;;   - 提示模板

(in-package :cl-agent.protocols)

;;; ============================================================
;;; 服务器启动
;;; ============================================================

(defun mcp-server-start (server &key (port nil))
  "启动 MCP 服务器

  参数：
    SERVER - MCP 服务器
    PORT   - 端口（用于 HTTP 传输）

  返回：
    是否成功启动"
  (declare (type mcp-server server))
  (mcp-log :info "Starting MCP server: ~A"
           (mcp-server-info-name server))

  (let ((transport (mcp-connection-transport
                    (mcp-server-connection server))))
    (case (mcp-transport-type transport)
      (:stdio
       ;; stdio 传输：等待来自 stdin 的连接
       (setf (mcp-transport-connected-p transport) t)
       (setf (mcp-connection-state (mcp-server-connection server))
             :connected)
       (mcp-log :info "Server started (stdio transport)")
       t)
      (:http
       ;; HTTP 传输
       (when port
         (let ((config (make-hash-table :test #'equal)))
           (setf (gethash "port" config) port)
           (setf (mcp-transport-config transport) config))
         (setf (mcp-transport-connected-p transport) t)
         (setf (mcp-connection-state (mcp-server-connection server))
               :connected)
         (mcp-log :info "Server started on port ~A" port)
         t))
      (otherwise
       (mcp-log :error "Unknown transport type")
       nil))))

(defun mcp-server-stop (server)
  "停止 MCP 服务器

  参数：
    SERVER - MCP 服务器

  返回：
    是否成功停止"
  (declare (type mcp-server server))
  (mcp-log :info "Stopping MCP server...")

  (let ((transport (mcp-connection-transport
                    (mcp-server-connection server))))
    (setf (mcp-transport-connected-p transport) nil)
    (setf (mcp-connection-state (mcp-server-connection server))
          :disconnected)
    (mcp-log :info "Server stopped")
    t))

;;; ============================================================
;;; 请求处理
;;; ============================================================

(defun mcp-server-handle-request (server request-message)
  "处理客户端请求

  参数：
    SERVER          - MCP 服务器
    REQUEST-MESSAGE - 请求消息

  返回：
    响应消息"
  (mcp-log :debug "Handling request: ~A"
           (mcp-message-method request-message))

  (let ((method (mcp-message-method request-message))
        (params (mcp-message-params request-message))
        (id (mcp-message-id request-message)))

    (cond
      ;; 初始化
      ((string= method "initialize")
       (mcp-server-handle-initialize server params id))

      ;; 资源相关
      ((string= method "resources/list")
       (mcp-server-handle-list-resources server params id))
      ((string= method "resources/read")
       (mcp-server-handle-read-resource server params id))
      ((string= method "resources/subscribe")
       (mcp-server-handle-subscribe-resource server params id))
      ((string= method "resources/unsubscribe")
       (mcp-server-handle-unsubscribe-resource server params id))

      ;; 提示相关
      ((string= method "prompts/list")
       (mcp-server-handle-list-prompts server params id))
      ((string= method "prompts/get")
       (mcp-server-handle-get-prompt server params id))

      ;; 工具相关
      ((string= method "tools/list")
       (mcp-server-handle-list-tools server params id))
      ((string= method "tools/call")
       (mcp-server-handle-call-tool server params id))

      ;; 未知方法
      (t
       (make-error-message id -32601 (format nil "Method not found: ~A" method))))))

(defun mcp-server-handle-initialize (server params id)
  "处理初始化请求

  参数：
    SERVER - MCP 服务器
    PARAMS - 参数
    ID     - 请求 ID

  返回：
    响应消息"
  (declare (type mcp-server server)
           (ignore params))
  (mcp-log :info "Handling initialize request")

  ;; 更新连接状态
  (let ((connection (mcp-server-connection server)))
    (setf (mcp-connection-state connection) :initialized)

    ;; 构建响应
    (let ((result (make-hash-table :test #'equal))
          (server-info (mcp-server-info server))
          (server-caps (mcp-server-capabilities server)))

      ;; 协议版本
      (setf (gethash "protocolVersion" result) *mcp-protocol-version*)

      ;; 服务器信息
      (let ((info-obj (make-hash-table :test #'equal)))
        (setf (gethash "name" info-obj)
              (mcp-server-info-name server-info))
        (setf (gethash "version" info-obj)
              (mcp-server-info-version server-info))
        (when (mcp-server-info-title server-info)
          (setf (gethash "title" info-obj)
                (mcp-server-info-title server-info)))
        (when (mcp-server-info-description server-info)
          (setf (gethash "description" info-obj)
                (mcp-server-info-description server-info)))
        (when (mcp-server-info-icons server-info)
          (setf (gethash "icons" info-obj)
                (mcp-server-info-icons server-info)))
        (when (mcp-server-info-website-url server-info)
          (setf (gethash "websiteUrl" info-obj)
                (mcp-server-info-website-url server-info)))
        (setf (gethash "serverInfo" result) info-obj))

      ;; 能力
      (let ((caps-obj (make-hash-table :test #'equal)))
        (when (mcp-capabilities-logging server-caps)
          (setf (gethash "logging" caps-obj)
                (mcp-capabilities-logging server-caps)))
        (when (mcp-capabilities-prompts server-caps)
          (setf (gethash "prompts" caps-obj)
                (mcp-capabilities-prompts server-caps)))
        (when (mcp-capabilities-resources server-caps)
          (setf (gethash "resources" caps-obj)
                (mcp-capabilities-resources server-caps)))
        (when (mcp-capabilities-tools server-caps)
          (setf (gethash "tools" caps-obj)
                (mcp-capabilities-tools server-caps)))
        (when (mcp-capabilities-tasks server-caps)
          (setf (gethash "tasks" caps-obj)
                (mcp-capabilities-tasks server-caps)))
        (setf (gethash "capabilities" result) caps-obj))

      (make-response-message id result))))

;;; ============================================================
;;; 资源处理
;;; ============================================================

(defun mcp-server-handle-list-resources (server params id)
  "处理列出资源请求

  参数：
    SERVER - MCP 服务器
    PARAMS - 参数
    ID     - 请求 ID

  返回：
    响应消息"
  (declare (ignore params))
  (mcp-log :debug "Handling resources/list request")

  (let ((resources (make-hash-table :test #'equal))
        (resource-list '()))

    ;; 收集所有资源
    (maphash (lambda (uri resource)
               (push (list :uri (mcp-resource-uri resource)
                          :name (mcp-resource-name resource)
                          :description (mcp-resource-description resource)
                          :mimeType (mcp-resource-mime-type resource))
                     resource-list))
             (mcp-server-resources server))

    (setf (gethash "resources" resources) (nreverse resource-list))

    (make-response-message id resources)))

(defun mcp-server-handle-read-resource (server params id)
  "处理读取资源请求

  参数：
    SERVER - MCP 服务器
    PARAMS - 参数
    ID     - 请求 ID

  返回：
    响应消息"
  (let ((uri (gethash "uri" params)))
    (mcp-log :debug "Handling resources/read request: ~A" uri)

    ;; 查找资源
    (let ((resource (gethash uri (mcp-server-resources server))))
      (if resource
          ;; TODO: 实际读取资源内容
          (let ((result (make-hash-table :test #'equal)))
            (let ((content-table (make-hash-table :test #'equal)))
              (setf (gethash "uri" content-table) uri)
              (setf (gethash "mimeType" content-table) (mcp-resource-mime-type resource))
              (setf (gethash "text" content-table) "")
              (setf (gethash "contents" result) (list content-table)))
            (make-response-message id result))
          (make-error-message id -32602
                             (format nil "Resource not found: ~A" uri))))))

(defun mcp-server-handle-subscribe-resource (server params id)
  "处理订阅资源请求

  参数：
    SERVER - MCP 服务器
    PARAMS - 参数
    ID     - 请求 ID

  返回：
    响应消息"
  (declare (ignore server))
  (let ((uri (gethash "uri" params)))
    (mcp-log :debug "Handling resources/subscribe request: ~A" uri)
    ;; TODO: 实现订阅逻辑
    (make-response-message id (make-hash-table :test #'equal))))

(defun mcp-server-handle-unsubscribe-resource (server params id)
  "处理取消订阅资源请求

  参数：
    SERVER - MCP 服务器
    PARAMS - 参数
    ID     - 请求 ID

  返回：
    响应消息"
  (declare (ignore server))
  (let ((uri (gethash "uri" params)))
    (mcp-log :debug "Handling resources/unsubscribe request: ~A" uri)
    ;; TODO: 实现取消订阅逻辑
    (make-response-message id (make-hash-table :test #'equal))))

;;; ============================================================
;;; 提示处理
;;; ============================================================

(defun mcp-server-handle-list-prompts (server params id)
  "处理列出提示请求

  参数：
    SERVER - MCP 服务器
    PARAMS - 参数
    ID     - 请求 ID

  返回：
    响应消息"
  (declare (ignore params))
  (mcp-log :debug "Handling prompts/list request")

  (let ((prompts (make-hash-table :test #'equal))
        (prompt-list '()))

    ;; 收集所有提示
    (maphash (lambda (name prompt)
               (push (list :name (mcp-prompt-name prompt)
                          :description (mcp-prompt-description prompt)
                          :arguments (mcp-prompt-arguments prompt))
                     prompt-list))
             (mcp-server-prompts server))

    (setf (gethash "prompts" prompts) (nreverse prompt-list))

    (make-response-message id prompts)))

(defun mcp-server-handle-get-prompt (server params id)
  "处理获取提示请求

  参数：
    SERVER - MCP 服务器
    PARAMS - 参数
    ID     - 请求 ID

  返回：
    响应消息"
  (let ((name (gethash "name" params))
        (arguments (gethash "arguments" params)))
    (mcp-log :debug "Handling prompts/get request: ~A" name)

    ;; 查找提示
    (let ((prompt (gethash name (mcp-server-prompts server))))
      (if prompt
          (let ((result (make-hash-table :test #'equal)))
            ;; TODO: 根据参数生成提示内容
            (setf (gethash "description" result)
                  (mcp-prompt-description prompt))
            (setf (gethash "messages" result)
                  (list (let ((msg-table (make-hash-table :test #'equal)))
                          (setf (gethash "role" msg-table) "user")
                          (setf (gethash "content" msg-table)
                                (format nil "Prompt: ~A" name))
                          msg-table)))
            (make-response-message id result))
          (make-error-message id -32602
                             (format nil "Prompt not found: ~A" name))))))

;;; ============================================================
;;; 工具处理
;;; ============================================================

(defun mcp-server-handle-list-tools (server params id)
  "处理列出工具请求

  参数：
    SERVER - MCP 服务器
    PARAMS - 参数
    ID     - 请求 ID

  返回：
    响应消息"
  (declare (ignore params))
  (mcp-log :debug "Handling tools/list request")

  (let ((tools (make-hash-table :test #'equal))
        (tool-list '()))

    ;; 收集所有工具
    (maphash (lambda (name tool)
               (push (list :name (mcp-tool-name tool)
                          :description (mcp-tool-description tool)
                          :inputSchema (mcp-tool-input-schema tool))
                     tool-list))
             (mcp-server-tools server))

    (setf (gethash "tools" tools) (nreverse tool-list))

    (make-response-message id tools)))

(defun mcp-server-handle-call-tool (server params id)
  "处理调用工具请求

  参数：
    SERVER - MCP 服务器
    PARAMS - 参数
    ID     - 请求 ID

  返回：
    响应消息"
  (let ((name (gethash "name" params))
        (arguments (gethash "arguments" params)))
    (mcp-log :debug "Handling tools/call request: ~A" name)

    ;; 查找工具
    (let ((tool (gethash name (mcp-server-tools server))))
      (if tool
          ;; 查找处理器
          (let ((handler (gethash name (mcp-server-request-handlers server))))
            (if handler
                (let ((result (funcall handler arguments)))
                  (let ((response (make-hash-table :test #'equal)))
                    (let ((content-table (make-hash-table :test #'equal)))
                      (setf (gethash "type" content-table) "text")
                      (setf (gethash "text" content-table) result))
                      (setf (gethash "content" response) (list content-table)))
                    (make-response-message id response)))
                (make-error-message id -32603
                                   (format nil "No handler for tool: ~A" name))))
          (make-error-message id -32602
                             (format nil "Tool not found: ~A" name)))))

;;; ============================================================
;;; 资源/工具/提示注册
;;; ============================================================

(defun mcp-server-register-resource (server uri name &key
                                              (description "")
                                              (mime-type "text/plain"))
  "注册资源

  参数：
    SERVER      - MCP 服务器
    URI         - 资源 URI
    NAME        - 资源名称
    DESCRIPTION - 描述
    MIME-TYPE   - MIME 类型

  返回：
    是否成功"
  (let ((resource (make-mcp-resource
                   :uri uri
                   :name name
                   :description description
                   :mime-type mime-type)))
    (setf (gethash uri (mcp-server-resources server)) resource)
    (mcp-log :info "Registered resource: ~A" uri)
    t))

(defun mcp-server-register-prompt (server name description &key
                                             (arguments nil))
  "注册提示模板

  参数：
    SERVER      - MCP 服务器
    NAME        - 提示名称
    DESCRIPTION - 描述
    ARGUMENTS   - 参数列表

  返回：
    是否成功"
  (let ((prompt (make-mcp-prompt
                 :name name
                 :description description
                 :arguments arguments)))
    (setf (gethash name (mcp-server-prompts server)) prompt)
    (mcp-log :info "Registered prompt: ~A" name)
    t))

(defun mcp-server-register-tool (server name description &key
                                          (input-schema nil)
                                          (handler nil))
  "注册工具

  参数：
    SERVER       - MCP 服务器
    NAME         - 工具名称
    DESCRIPTION  - 描述
    INPUT-SCHEMA - 输入 JSON Schema
    HANDLER      - 处理函数

  返回：
    是否成功"
  (let ((tool (make-mcp-tool
               :name name
               :description description
               :input-schema (or input-schema
                                 (make-hash-table :test #'equal)))))
    (setf (gethash name (mcp-server-tools server)) tool)
    (when handler
      (setf (gethash name (mcp-server-request-handlers server)) handler))
    (mcp-log :info "Registered tool: ~A" name)
    t))

;;; ============================================================
;;; 便捷函数
;;; ============================================================

(defun mcp-start (&key (name "cl-agent-server") (port nil))
  "启动 MCP 服务器（使用默认服务器）

  参数：
    NAME - 服务器名称
    PORT - 端口（HTTP 传输）

  返回：
    是否成功"
  (let ((server (get-default-mcp-server)))
    (mcp-server-start server :port port)))

(defun mcp-stop ()
  "停止 MCP 服务器（使用默认服务器）

  返回：
    是否成功"
  (let ((server (get-default-mcp-server)))
    (mcp-server-stop server)))

(defun mcp-register-resource (uri name &key (description "")
                                          (mime-type "text/plain"))
  "注册资源（使用默认服务器）

  参数：
    URI         - 资源 URI
    NAME        - 资源名称
    DESCRIPTION - 描述
    MIME-TYPE   - MIME 类型

  返回：
    是否成功"
  (let ((server (get-default-mcp-server)))
    (mcp-server-register-resource server uri name
                                   :description description
                                   :mime-type mime-type)))

(defun mcp-register-tool (name description &key (input-schema nil)
                                         (handler nil))
  "注册工具（使用默认服务器）

  参数：
    NAME         - 工具名称
    DESCRIPTION  - 描述
    INPUT-SCHEMA - 输入 JSON Schema
    HANDLER      - 处理函数

  返回：
    是否成功"
  (let ((server (get-default-mcp-server)))
    (mcp-server-register-tool server name description
                               :input-schema input-schema
                               :handler handler)))

(defun mcp-register-prompt (name description &key (arguments nil))
  "注册提示模板（使用默认服务器）

  参数：
    NAME        - 提示名称
    DESCRIPTION - 描述
    ARGUMENTS   - 参数列表

  返回：
    是否成功"
  (let ((server (get-default-mcp-server)))
    (mcp-server-register-prompt server name description
                                 :arguments arguments)))
