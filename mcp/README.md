# MCP 模块

Model Context Protocol（模型上下文协议）实现模块。

## 目录结构

```
mcp/
├── package.lisp              # 包定义
├── protocol.lisp             # 协议定义
├── json-rpc.lisp             # JSON-RPC 2.0 实现
├── transport/                # 传输层
│   ├── base.lisp            # 基础传输接口
│   ├── stdio.lisp           # 标准输入/输出
│   └── sse.lisp             # Server-Sent Events
├── client/
│   └── core.lisp            # MCP 客户端
└── server/
    ├── core.lisp            # MCP 服务器核心
    └── main.lisp            # MCP 服务器入口
```

## MCP 概述

MCP（Model Context Protocol）是一种标准化协议，用于：
- AI 模型与外部工具的通信
- 上下文信息的传递
- 资源访问和管理

## JSON-RPC 消息

### 请求

```lisp
(defclass mcp-request ()
  ((jsonrpc :initform "2.0")
   (id :accessor request-id)
   (method :accessor request-method)
   (params :accessor request-params)))

;; 创建请求
(make-mcp-request
  :id "1"
  :method "tools/call"
  :params '(:name "get-weather" :arguments (:city "Tokyo")))
```

### 响应

```lisp
(defclass mcp-response ()
  ((jsonrpc :initform "2.0")
   (id :accessor response-id)
   (result :accessor response-result)
   (error :accessor response-error)))

;; 成功响应
(make-mcp-response
  :id "1"
  :result '(:content "Weather in Tokyo: 22°C"))

;; 错误响应
(make-mcp-response
  :id "1"
  :error '(:code -32600 :message "Invalid Request"))
```

### 通知

```lisp
(defclass mcp-notification ()
  ((jsonrpc :initform "2.0")
   (method :accessor notification-method)
   (params :accessor notification-params)))

(make-mcp-notification
  :method "notifications/message"
  :params '(:level "info" :message "Processing..."))
```

## 传输层

### STDIO 传输

通过标准输入/输出通信：

```lisp
(defvar *transport*
  (make-stdio-transport))

;; 发送消息
(transport-send *transport* message)

;; 接收消息
(transport-receive *transport*)

;; 关闭
(transport-close *transport*)
```

### SSE 传输

通过 Server-Sent Events 通信：

```lisp
(defvar *transport*
  (make-sse-transport
    :url "http://localhost:8080/events"))

;; 连接
(transport-connect *transport*)

;; 监听事件
(transport-on-event *transport*
  (lambda (event)
    (format t "收到事件: ~A~%" event)))
```

## MCP 客户端

### 创建客户端

```lisp
(defvar *client*
  (make-mcp-client
    :transport (make-stdio-transport)))

;; 连接
(mcp-client-connect *client*)
```

### 初始化

```lisp
;; 发送初始化请求
(mcp-client-initialize *client*
  :protocol-version "2024-11-05"
  :capabilities '(:tools t :resources t)
  :client-info '(:name "cl-agent" :version "1.0.0"))
```

### 工具操作

```lisp
;; 列出可用工具
(mcp-client-list-tools *client*)
;; => ((:name "get-weather" :description "获取天气" :input-schema {...})
;;     (:name "search" :description "搜索" :input-schema {...}))

;; 调用工具
(mcp-client-call-tool *client* "get-weather"
  '(:city "Tokyo"))
;; => (:content "Weather in Tokyo: 22°C, sunny")
```

### 资源操作

```lisp
;; 列出资源
(mcp-client-list-resources *client*)
;; => ((:uri "file:///docs/readme.md" :name "README" :mime-type "text/markdown"))

;; 读取资源
(mcp-client-read-resource *client* "file:///docs/readme.md")
;; => (:contents "# README\n...")
```

### 提示操作

```lisp
;; 列出提示
(mcp-client-list-prompts *client*)

;; 获取提示
(mcp-client-get-prompt *client* "code-review"
  '(:language "lisp"))
```

## MCP 服务器

### 创建服务器

```lisp
(defvar *server*
  (make-mcp-server
    :transport (make-stdio-transport)
    :name "my-mcp-server"
    :version "1.0.0"))
```

### 注册工具

```lisp
;; 注册工具
(mcp-register-tool *server* "get-weather"
  :description "获取指定城市的天气"
  :input-schema '(:type "object"
                  :properties (:city (:type "string"
                                      :description "城市名"))
                  :required ("city"))
  :handler (lambda (args)
             (let ((city (getf args :city)))
               `(:content ,(format nil "~A: 22°C" city)))))

;; 注册带验证的工具
(mcp-register-tool *server* "calculate"
  :description "执行计算"
  :input-schema '(:type "object"
                  :properties (:expression (:type "string")))
  :validator (lambda (args)
               (handler-case
                   (progn (read-from-string (getf args :expression)) t)
                 (error () nil)))
  :handler #'handle-calculate)
```

### 注册资源

```lisp
;; 静态资源
(mcp-register-resource *server*
  :uri "file:///config.json"
  :name "Configuration"
  :mime-type "application/json"
  :handler (lambda ()
             (read-file-into-string "/path/to/config.json")))

;; 动态资源
(mcp-register-resource-template *server*
  :uri-template "db://records/{id}"
  :name "Database Record"
  :handler (lambda (params)
             (get-record (getf params :id))))
```

### 注册提示

```lisp
(mcp-register-prompt *server* "code-review"
  :description "代码审查提示"
  :arguments '((:name "language" :description "编程语言" :required t))
  :handler (lambda (args)
             `(:messages ((:role "user"
                           :content ,(format nil "请审查以下 ~A 代码："
                                            (getf args :language)))))))
```

### 启动服务器

```lisp
;; 启动（阻塞）
(mcp-server-start *server*)

;; 后台启动
(mcp-server-start-async *server*)

;; 停止
(mcp-server-stop *server*)
```

## 与 Kernel 集成

### 作为工具提供者

```lisp
;; 从 MCP 服务器获取工具
(defvar *mcp-tools*
  (mcp-client-list-tools *client*))

;; 创建 MCP 工具插件
(defvar *mcp-plugin*
  (make-mcp-plugin *client*))

;; 添加到 Kernel
(defvar *kernel*
  (make-kernel
    :service *service*
    :plugins (list *mcp-plugin*)))
```

### 暴露 Kernel 工具

```lisp
;; 将 Kernel 插件暴露为 MCP 工具
(mcp-expose-plugin *server* 'my-plugin)

;; 或暴露所有工具
(mcp-expose-kernel *server* *kernel*)
```

## 错误处理

```lisp
;; MCP 标准错误码
-32700  ; Parse error
-32600  ; Invalid Request
-32601  ; Method not found
-32602  ; Invalid params
-32603  ; Internal error

;; 处理错误
(handler-case
    (mcp-client-call-tool *client* "unknown-tool" '())
  (mcp-error (e)
    (format t "MCP 错误: ~A (代码: ~A)~%"
            (mcp-error-message e)
            (mcp-error-code e))))
```

## 使用示例

### 天气服务 MCP 服务器

```lisp
(defvar *weather-server*
  (make-mcp-server
    :transport (make-stdio-transport)
    :name "weather-service"
    :version "1.0.0"))

(mcp-register-tool *weather-server* "get-weather"
  :description "获取天气信息"
  :input-schema '(:type "object"
                  :properties (:city (:type "string")
                               :unit (:type "string"
                                      :enum ("celsius" "fahrenheit")))
                  :required ("city"))
  :handler (lambda (args)
             (let ((city (getf args :city))
                   (unit (or (getf args :unit) "celsius")))
               ;; 调用天气 API
               `(:content ,(get-weather-from-api city unit)))))

(mcp-register-tool *weather-server* "get-forecast"
  :description "获取天气预报"
  :input-schema '(:type "object"
                  :properties (:city (:type "string")
                               :days (:type "integer")))
  :handler #'handle-forecast)

(mcp-server-start *weather-server*)
```

### 连接 MCP 服务的 Agent

```lisp
;; 连接到 MCP 服务器
(defvar *mcp-client*
  (make-mcp-client
    :transport (make-stdio-transport
                 :command '("node" "weather-server.js"))))

(mcp-client-connect *mcp-client*)
(mcp-client-initialize *mcp-client*)

;; 创建带 MCP 工具的 Agent
(defvar *agent*
  (make-kernel-agent
    (make-kernel
      :service *service*
      :plugins (list (make-mcp-plugin *mcp-client*)))
    :system-prompt "你可以查询天气信息。"))

(agent-chat *agent* "北京明天天气怎么样？")
```
