;;;; mcp.lisp
;;;; CL-Agent - Model Context Protocol (MCP) 实现
;;;;
;;;; 概述：
;;;;   实现 Model Context Protocol，使 LLM 应用能够与外部数据源和工具集成
;;;;
;;;; 特性：
;;;;   - JSON-RPC 2.0 消息格式
;;;;   - 客户端-服务器架构
;;;;   - 能力协商
;;;;   - Resources/Prompts/Tools 支持
;;;;   - 生命周期管理

(in-package :cl-agent.protocols)

;;; ============================================================
;;; MCP 协议常量
;;; ============================================================

(defparameter *mcp-protocol-version* "2024-11-05"
  "MCP 协议版本")

(defparameter *mcp-jsonrpc-version* "2.0"
  "JSON-RPC 版本")

;;; ============================================================
;;; MCP 消息结构
;;; ============================================================

(defstruct mcp-message
  "MCP JSON-RPC 消息

  槽位说明：
    JSONRPC    - JSON-RPC 版本
    ID         - 请求 ID（用于请求和响应）
    METHOD     - 方法名（用于请求和通知）
    PARAMS     - 参数
    RESULT     - 结果（用于响应）
    ERROR      - 错误（用于错误响应）"
  (jsonrpc *mcp-jsonrpc-version* :type string)
  (id nil :type (or null integer string))
  (method nil :type (or null string))
  (params nil :type (or null hash-table))
  (result nil :type (or null hash-table list))
  (error nil :type (or null mcp-error)))

(defstruct mcp-error
  "MCP 错误

  槽位说明：
    CODE    - 错误代码
    MESSAGE - 错误消息
    DATA    - 额外错误数据"
  (code -32700 :type integer)
  (message "" :type string)
  (data nil :type (or null hash-table list)))

;;; ============================================================
;;; MCP 能力结构
;;; ============================================================

(defstruct mcp-capabilities
  "MCP 能力

  槽位说明：
    ROOTS        - 文件系统根目录支持
    SAMPLING     - LLM 采样支持
    ELICITATION  - 请求额外信息支持
    TASKS        - 任务支持
    LOGGING      - 日志支持
    PROMPTS      - 提示模板支持
    RESOURCES    - 资源支持
    TOOLS        - 工具支持
    EXPERIMENTAL - 实验性功能"
  (roots nil :type (or null hash-table))
  (sampling nil :type (or null hash-table))
  (elicitation nil :type (or null hash-table))
  (tasks nil :type (or null hash-table))
  (logging nil :type (or null hash-table))
  (prompts nil :type (or null hash-table))
  (resources nil :type (or null hash-table))
  (tools nil :type (or null hash-table))
  (experimental nil :type (or null hash-table)))

(defstruct mcp-client-info
  "MCP 客户端信息

  槽位说明：
    NAME         - 客户端名称
    VERSION      - 客户端版本
    TITLE        - 显示名称
    DESCRIPTION  - 描述
    ICONS        - 图标列表
    WEBSITE-URL  - 网站 URL"
  (name "" :type string)
  (version "1.0.0" :type string)
  (title "" :type (or null string))
  (description "" :type (or null string))
  (icons nil :type (or null list))
  (website-url nil :type (or null string)))

(defstruct mcp-server-info
  "MCP 服务器信息

  槽位说明：
    NAME         - 服务器名称
    VERSION      - 服务器版本
    TITLE        - 显示名称
    DESCRIPTION  - 描述
    ICONS        - 图标列表
    WEBSITE-URL  - 网站 URL"
  (name "" :type string)
  (version "1.0.0" :type string)
  (title "" :type (or null string))
  (description "" :type (or null string))
  (icons nil :type (or null list))
  (website-url nil :type (or null string)))

;;; ============================================================
;;; MCP 连接状态
;;; ============================================================

(defstruct mcp-connection
  "MCP 连接

  槽位说明：
    STATE         - 连接状态
    CLIENT-ID     - 客户端 ID
    SERVER-ID     - 服务器 ID
    CLIENT-CAPS   - 客户端能力
    SERVER-CAPS   - 服务器能力
    CLIENT-INFO   - 客户端信息
    SERVER-INFO   - 服务器信息
    TRANSPORT     - 传输层
    METADATA      - 元数据"
  (state :disconnected :type keyword)
  (client-id nil :type (or null string))
  (server-id nil :type (or null string))
  (client-caps nil :type (or null mcp-capabilities))
  (server-caps nil :type (or null mcp-capabilities))
  (client-info nil :type (or null mcp-client-info))
  (server-info nil :type (or null mcp-server-info))
  (transport nil :type (or null mcp-transport))
  (metadata nil :type (or null hash-table)))

;;; ============================================================
;;; MCP 传输层
;;; ============================================================

(defstruct mcp-transport
  "MCP 传输层

  槽位说明：
    TYPE       - 传输类型（:stdio 或 :http）
    CONNECTED-P - 是否已连接
    CONFIG     - 配置"
  (type :stdio :type keyword)
  (connected-p nil :type boolean)
  (config nil :type (or null hash-table)))

;;; ============================================================
;;; MCP 资源、提示、工具
;;; ============================================================

(defstruct mcp-resource
  "MCP 资源

  槽位说明：
    URI         - 资源 URI
    NAME        - 资源名称
    DESCRIPTION - 描述
    MIME-TYPE   - MIME 类型"
  (uri "" :type string)
  (name "" :type string)
  (description "" :type (or null string))
  (mime-type "text/plain" :type string))

(defstruct mcp-prompt
  "MCP 提示模板

  槽位说明：
    NAME        - 提示名称
    DESCRIPTION - 描述
    ARGUMENTS   - 参数列表"
  (name "" :type string)
  (description "" :type (or null string))
  (arguments nil :type (or null list)))

(defstruct mcp-tool
  "MCP 工具

  槽位说明：
    NAME        - 工具名称
    DESCRIPTION - 描述
    INPUT-SCHEMA - 输入 JSON Schema"
  (name "" :type string)
  (description "" :type string)
  (input-schema nil :type (or null hash-table)))

;;; ============================================================
;;; MCP 客户端
;;; ============================================================

(defstruct (mcp-client (:constructor make-mcp-client-struct))
  "MCP 客户端

  槽位说明：
    CONNECTION   - 连接
    INFO         - 客户端信息
    CAPABILITIES - 能力
    REQUEST-HANDLERS - 请求处理器
    NOTIFICATION-HANDLERS - 通知处理器"
  connection
  info
  capabilities
  (request-handlers (make-hash-table :test #'equal))
  (notification-handlers (make-hash-table :test #'equal)))

(defun make-mcp-client (&key (name "cl-agent-client")
                             (version "1.0.0")
                             (capabilities nil)
                             (transport-type :stdio))
  "创建 MCP 客户端

  参数：
    NAME            - 客户端名称
    VERSION         - 客户端版本
    CAPABILITIES    - 能力
    TRANSPORT-TYPE  - 传输类型

  返回：
    MCP 客户端实例"
  (let* ((info (make-mcp-client-info
                :name name
                :version version
                :title name
                :description (format nil "CL-Agent MCP Client ~A" version)))
         (caps (or capabilities
                    (make-mcp-capabilities
                     :roots (make-hash-table)
                     :sampling (make-hash-table))))
         (transport (make-mcp-transport
                     :type transport-type
                     :connected-p nil
                     :config (make-hash-table)))
         (connection (make-mcp-connection
                      :state :disconnected
                      :transport transport
                      :client-info info
                      :client-caps caps)))
    (make-mcp-client-struct
     :connection connection
     :info info
     :capabilities caps)))

;;; ============================================================
;;; MCP 服务器
;;; ============================================================

(defstruct (mcp-server (:constructor make-mcp-server-struct))
  "MCP 服务器

  槽位说明：
    CONNECTION   - 连接
    INFO         - 服务器信息
    CAPABILITIES - 能力
    RESOURCES    - 资源列表
    PROMPTS      - 提示列表
    TOOLS        - 工具列表
    REQUEST-HANDLERS - 请求处理器"
  connection
  info
  capabilities
  (resources (make-hash-table :test #'equal))
  (prompts (make-hash-table :test #'equal))
  (tools (make-hash-table :test #'equal))
  (request-handlers (make-hash-table :test #'equal)))

(defun make-mcp-server (&key (name "cl-agent-server")
                             (version "1.0.0")
                             (capabilities nil)
                             (transport-type :stdio))
  "创建 MCP 服务器

  参数：
    NAME            - 服务器名称
    VERSION         - 服务器版本
    CAPABILITIES    - 能力
    TRANSPORT-TYPE  - 传输类型

  返回：
    MCP 服务器实例"
  (let* ((info (make-mcp-server-info
                :name name
                :version version
                :title name
                :description (format nil "CL-Agent MCP Server ~A" version)))
         (caps (or capabilities
                    (make-mcp-capabilities
                     :resources (make-hash-table)
                     :prompts (make-hash-table)
                     :tools (make-hash-table))))
         (transport (make-mcp-transport
                     :type transport-type
                     :connected-p nil
                     :config (make-hash-table)))
         (connection (make-mcp-connection
                      :state :disconnected
                      :transport transport
                      :server-info info
                      :server-caps caps)))
    (make-mcp-server-struct
     :connection connection
     :info info
     :capabilities caps)))

;;; ============================================================
;;; 消息构建函数
;;; ============================================================

(defun make-request-message (id method &key (params nil))
  "创建请求消息

  参数：
    ID      - 请求 ID
    METHOD  - 方法名
    PARAMS  - 参数

  返回：
    MCP 消息"
  (make-mcp-message
   :jsonrpc *mcp-jsonrpc-version*
   :id id
   :method method
   :params params))

(defun make-response-message (id result &key (error nil))
  "创建响应消息

  参数：
    ID      - 请求 ID
    RESULT  - 结果
    ERROR   - 错误

  返回：
    MCP 消息"
  (make-mcp-message
   :jsonrpc *mcp-jsonrpc-version*
   :id id
   :result result
   :error error))

(defun make-notification-message (method &key (params nil))
  "创建通知消息

  参数：
    METHOD  - 方法名
    PARAMS  - 参数

  返回：
    MCP 消息"
  (make-mcp-message
   :jsonrpc *mcp-jsonrpc-version*
   :method method
   :params params))

(defun make-error-message (id code message &key (data nil))
  "创建错误消息

  参数：
    ID      - 请求 ID
    CODE    - 错误代码
    MESSAGE - 错误消息
    DATA    - 额外数据

  返回：
    MCP 消息"
  (make-mcp-message
   :jsonrpc *mcp-jsonrpc-version*
   :id id
   :error (make-mcp-error
           :code code
           :message message
           :data data)))

;;; ============================================================
;;; JSON 序列化/反序列化
;;; ============================================================

(defun mcp-message-to-json (message)
  "将 MCP 消息转换为 JSON

  参数：
    MESSAGE - MCP 消息

  返回：
    JSON 字符串"
  (let ((json-obj (make-hash-table :test #'equal)))
    ;; JSON-RPC 版本
    (setf (gethash "jsonrpc" json-obj) (mcp-message-jsonrpc message))

    ;; ID（如果有）
    (when (mcp-message-id message)
      (setf (gethash "id" json-obj) (mcp-message-id message)))

    ;; 方法（如果有）
    (when (mcp-message-method message)
      (setf (gethash "method" json-obj) (mcp-message-method message)))

    ;; 参数（如果有）
    (when (mcp-message-params message)
      (setf (gethash "params" json-obj) (mcp-message-params message)))

    ;; 结果（如果有）
    (when (mcp-message-result message)
      (setf (gethash "result" json-obj) (mcp-message-result message)))

    ;; 错误（如果有）
    (when (mcp-message-error message)
      (let ((error-obj (make-hash-table :test #'equal)))
        (setf (gethash "code" error-obj)
              (mcp-error-code (mcp-message-error message)))
        (setf (gethash "message" error-obj)
              (mcp-error-message (mcp-message-error message)))
        (when (mcp-error-data (mcp-message-error message))
          (setf (gethash "data" error-obj)
                (mcp-error-data (mcp-message-error message))))
        (setf (gethash "error" json-obj) error-obj)))

    ;; 转换为 JSON
    (cl-agent.core:json-stringify json-obj)))

(defun json-to-mcp-message (json-string)
  "将 JSON 转换为 MCP 消息

  参数：
    JSON-STRING - JSON 字符串

  返回：
    MCP 消息"
  (let ((json-obj (cl-agent.core:json-parse json-string)))
    (make-mcp-message
     :jsonrpc (gethash "jsonrpc" json-obj)
     :id (gethash "id" json-obj)
     :method (gethash "method" json-obj)
     :params (gethash "params" json-obj)
     :result (gethash "result" json-obj)
     :error (when (gethash "error" json-obj)
              (let ((error-obj (gethash "error" json-obj)))
                (make-mcp-error
                 :code (gethash "code" error-obj)
                 :message (gethash "message" error-obj)
                 :data (gethash "data" error-obj)))))))

;;; ============================================================
;;; 协议方法
;;; ============================================================

(defun mcp-make-initialize-request (client-info client-caps)
  "创建初始化请求

  参数：
    CLIENT-INFO  - 客户端信息
    CLIENT-CAPS  - 客户端能力

  返回：
    初始化请求消息"
  (let ((params (make-hash-table :test #'equal)))
    (setf (gethash "protocolVersion" params) *mcp-protocol-version*)

    ;; 能力
    (let ((caps-obj (make-hash-table :test #'equal)))
      (when (mcp-capabilities-roots client-caps)
        (setf (gethash "roots" caps-obj)
              (mcp-capabilities-roots client-caps)))
      (when (mcp-capabilities-sampling client-caps)
        (setf (gethash "sampling" caps-obj)
              (mcp-capabilities-sampling client-caps)))
      (when (mcp-capabilities-elicitation client-caps)
        (setf (gethash "elicitation" caps-obj)
              (mcp-capabilities-elicitation client-caps)))
      (setf (gethash "capabilities" params) caps-obj))

    ;; 客户端信息
    (let ((info-obj (make-hash-table :test #'equal)))
      (setf (gethash "name" info-obj)
            (mcp-client-info-name client-info))
      (setf (gethash "version" info-obj)
            (mcp-client-info-version client-info))
      (when (mcp-client-info-title client-info)
        (setf (gethash "title" info-obj)
              (mcp-client-info-title client-info)))
      (when (mcp-client-info-description client-info)
        (setf (gethash "description" info-obj)
              (mcp-client-info-description client-info)))
      (when (mcp-client-info-icons client-info)
        (setf (gethash "icons" info-obj)
              (mcp-client-info-icons client-info)))
      (when (mcp-client-info-website-url client-info)
        (setf (gethash "websiteUrl" info-obj)
              (mcp-client-info-website-url client-info)))
      (setf (gethash "clientInfo" params) info-obj))

    (make-request-message 1 "initialize" :params params)))

(defun mcp-make-initialized-notification ()
  "创建已初始化通知

  返回：
    已初始化通知消息"
  (make-notification-message "notifications/initialized"))

(defun mcp-parse-initialize-response (response-message)
  "解析初始化响应

  参数：
    RESPONSE-MESSAGE - 响应消息

  返回：
    (values server-info server-caps)"
  (when (mcp-message-error response-message)
    (error 'mcp-error
           :code (mcp-error-code (mcp-message-error response-message))
           :message (mcp-error-message (mcp-message-error response-message))))

  (let ((result (mcp-message-result response-message)))
    (let* ((server-info-obj (gethash "serverInfo" result))
           (server-info (make-mcp-server-info
                         :name (gethash "name" server-info-obj)
                         :version (gethash "version" server-info-obj)
                         :title (gethash "title" server-info-obj)
                         :description (gethash "description" server-info-obj)
                         :icons (gethash "icons" server-info-obj)
                         :website-url (gethash "websiteUrl" server-info-obj)))
           (caps-obj (gethash "capabilities" result))
           (server-caps (make-mcp-capabilities
                         :logging (gethash "logging" caps-obj)
                         :prompts (gethash "prompts" caps-obj)
                         :resources (gethash "resources" caps-obj)
                         :tools (gethash "tools" caps-obj)
                         :tasks (gethash "tasks" caps-obj))))
      (values server-info server-caps))))

;;; ============================================================
;;; 全局变量
;;; ============================================================

(defparameter *default-mcp-client* nil
  "默认 MCP 客户端")

(defparameter *default-mcp-server* nil
  "默认 MCP 服务器")

(defparameter *mcp-verbose* nil
  "是否输出 MCP 详细日志")

(defun get-default-mcp-client ()
  "获取或创建默认 MCP 客户端"
  (unless *default-mcp-client*
    (setf *default-mcp-client* (make-mcp-client)))
  *default-mcp-client*)

(defun get-default-mcp-server ()
  "获取或创建默认 MCP 服务器"
  (unless *default-mcp-server*
    (setf *default-mcp-server* (make-mcp-server)))
  *default-mcp-server*)

;;; ============================================================
;;; 日志函数
;;; ============================================================

(defun mcp-log (level format-string &rest args)
  "MCP 日志输出

  参数：
    LEVEL          - 日志级别（:debug, :info, :warn, :error）
    FORMAT-STRING  - 格式化字符串
    ARGS           - 参数"
  (when *mcp-verbose*
    (let ((timestamp (cl-agent.core:timestamp-now)))
      (format t "[~A] [MCP ~A] ~?~%"
              timestamp
              (string-upcase level)
              format-string
              args))))
