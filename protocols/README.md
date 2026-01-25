# Protocols 模块

协议支持模块，提供 MCP 和 A2A（Agent-to-Agent）通信协议实现。

## 目录结构

```
protocols/
├── package-protocols.lisp    # 包定义
├── mcp.lisp                  # MCP 协议
├── mcp-client.lisp           # MCP 客户端
├── mcp-server.lisp           # MCP 服务器
├── a2a-types.lisp            # A2A 类型定义
├── a2a-endpoint.lisp         # A2A 端点
├── a2a-bus.lisp              # A2A 消息总线
├── a2a-messaging.lisp        # A2A 消息传递
├── a2a-handlers.lisp         # A2A 处理器
├── a2a-listeners.lisp        # A2A 监听器
├── a2a-service.lisp          # A2A 服务
└── a2a.lisp                  # A2A 入口
```

## MCP 协议

详见 [MCP 模块文档](../mcp/README.md)。

## A2A 协议

A2A（Agent-to-Agent）是用于 Agent 间通信的协议。

### 核心概念

```
┌─────────┐         ┌─────────┐
│ Agent A │ ←─────→ │ Agent B │
└─────────┘   A2A   └─────────┘
     ↓                   ↓
┌─────────────────────────────┐
│        Message Bus          │
└─────────────────────────────┘
     ↓         ↓         ↓
┌─────────┐ ┌─────────┐ ┌─────────┐
│Handler 1│ │Handler 2│ │Handler 3│
└─────────┘ └─────────┘ └─────────┘
```

### A2A 消息

```lisp
;; 消息结构
(defstruct a2a-message
  id              ; 消息 ID
  from            ; 发送者 Agent ID
  to              ; 接收者 Agent ID（可选，nil 表示广播）
  type            ; 消息类型
  content         ; 消息内容
  correlation-id  ; 关联 ID（用于请求-响应）
  timestamp       ; 时间戳
  metadata)       ; 元数据

;; 创建消息
(make-a2a-message
  :from "agent-a"
  :to "agent-b"
  :type :request
  :content '(:action "analyze" :data "..."))
```

### 消息类型

```lisp
:request    ; 请求消息（期望响应）
:response   ; 响应消息
:notify     ; 通知消息（不期望响应）
:broadcast  ; 广播消息
:error      ; 错误消息
```

## A2A 端点

### 创建端点

```lisp
(defvar *endpoint*
  (make-a2a-endpoint
    :id "my-agent"
    :name "My Agent"
    :capabilities '(:chat :tools :rag)))
```

### 注册处理器

```lisp
;; 处理特定类型的消息
(a2a-register-handler *endpoint* :request
  (lambda (message)
    (let ((action (getf (a2a-message-content message) :action)))
      (case (intern (string-upcase action) :keyword)
        (:analyze (handle-analyze message))
        (:summarize (handle-summarize message))
        (t (make-error-response "Unknown action"))))))

;; 处理所有消息
(a2a-register-handler *endpoint* :all
  (lambda (message)
    (format t "收到消息: ~A~%" message)))
```

### 发送消息

```lisp
;; 发送请求（等待响应）
(let ((response (a2a-request *endpoint* "other-agent"
                  '(:action "analyze" :data "..."))))
  (format t "响应: ~A~%" response))

;; 发送通知（不等待响应）
(a2a-notify *endpoint* "other-agent"
  '(:event "task-completed" :result "..."))

;; 广播
(a2a-broadcast *endpoint*
  '(:announcement "New capability available"))
```

## A2A 消息总线

### 创建消息总线

```lisp
(defvar *bus* (make-a2a-bus))

;; 注册端点
(a2a-bus-register *bus* *endpoint-a*)
(a2a-bus-register *bus* *endpoint-b*)
(a2a-bus-register *bus* *endpoint-c*)
```

### 消息路由

```lisp
;; 点对点
(a2a-bus-send *bus*
  (make-a2a-message :from "a" :to "b" :content "..."))

;; 广播
(a2a-bus-broadcast *bus*
  (make-a2a-message :from "a" :content "..."))

;; 基于能力路由
(a2a-bus-route-by-capability *bus* :rag
  (make-a2a-message :from "a" :content "..."))
```

### 订阅模式

```lisp
;; 订阅特定主题
(a2a-bus-subscribe *bus* "agent-a" "news/*")
(a2a-bus-subscribe *bus* "agent-b" "alerts/critical")

;; 发布到主题
(a2a-bus-publish *bus* "news/tech"
  (make-a2a-message :content '(:headline "...")))
```

## A2A 服务

### 创建服务

```lisp
(defvar *service*
  (make-a2a-service
    :endpoint *endpoint*
    :bus *bus*))

;; 启动服务
(a2a-service-start *service*)
```

### 服务发现

```lisp
;; 发现其他 Agent
(a2a-service-discover *service*)
;; => ((:id "agent-b" :name "Agent B" :capabilities (:chat :tools))
;;     (:id "agent-c" :name "Agent C" :capabilities (:rag)))

;; 按能力查找
(a2a-service-find-by-capability *service* :rag)
;; => ((:id "agent-c" ...))
```

### 健康检查

```lisp
;; 检查 Agent 状态
(a2a-service-ping *service* "agent-b")
;; => (:status :alive :latency 50)

;; 检查所有
(a2a-service-health-check *service*)
;; => ((:id "agent-b" :status :alive)
;;     (:id "agent-c" :status :unreachable))
```

## 与 Kernel 集成

### 创建 A2A Agent

```lisp
(defvar *kernel* (make-kernel :service *llm-service*))

(defvar *a2a-agent*
  (make-a2a-agent *kernel*
    :id "smart-agent"
    :name "Smart Agent"
    :capabilities '(:chat :tools :reasoning)))

;; 注册到总线
(a2a-bus-register *bus* (a2a-agent-endpoint *a2a-agent*))
```

### 处理 A2A 请求

```lisp
;; 自动将 A2A 请求转发给 Kernel
(a2a-agent-enable-auto-dispatch *a2a-agent*)

;; 或自定义处理
(a2a-agent-on-request *a2a-agent*
  (lambda (message)
    (let ((content (a2a-message-content message)))
      (agent-chat (a2a-agent-kernel-agent *a2a-agent*)
                  (getf content :query)))))
```

### 代理其他 Agent

```lisp
;; 将任务委托给其他 Agent
(defun delegate-to-rag-agent (query)
  (let ((rag-agents (a2a-service-find-by-capability *service* :rag)))
    (when rag-agents
      (a2a-request (a2a-agent-endpoint *a2a-agent*)
                   (getf (first rag-agents) :id)
                   `(:action "search" :query ,query)))))
```

## 使用示例

### 多 Agent 协作

```lisp
;; 创建专门的 Agent
(defvar *research-agent*
  (make-a2a-agent *research-kernel*
    :id "researcher"
    :capabilities '(:research :web-search)))

(defvar *writer-agent*
  (make-a2a-agent *writer-kernel*
    :id "writer"
    :capabilities '(:writing :summarization)))

(defvar *coordinator-agent*
  (make-a2a-agent *coordinator-kernel*
    :id "coordinator"
    :capabilities '(:coordination :planning)))

;; 注册到总线
(dolist (agent (list *research-agent* *writer-agent* *coordinator-agent*))
  (a2a-bus-register *bus* (a2a-agent-endpoint agent)))

;; 协调者分配任务
(defun coordinate-article (topic)
  ;; 1. 让研究 Agent 收集信息
  (let ((research-result
          (a2a-request (a2a-agent-endpoint *coordinator-agent*)
                       "researcher"
                       `(:action "research" :topic ,topic))))
    ;; 2. 让写作 Agent 撰写文章
    (a2a-request (a2a-agent-endpoint *coordinator-agent*)
                 "writer"
                 `(:action "write-article"
                   :topic ,topic
                   :research ,(getf research-result :data)))))
```

### 负载均衡

```lisp
;; 创建多个工作 Agent
(defvar *workers*
  (loop for i from 1 to 5
        collect (make-a2a-agent (make-kernel :service *service*)
                  :id (format nil "worker-~A" i)
                  :capabilities '(:processing))))

;; 负载均衡器
(defvar *load-balancer*
  (make-a2a-load-balancer
    :strategy :round-robin  ; 或 :least-connections, :random
    :agents *workers*))

;; 分发任务
(a2a-lb-dispatch *load-balancer*
  '(:action "process" :data "..."))
```

### 事件驱动架构

```lisp
;; 定义事件
(a2a-define-event :task-completed
  :schema '(:task-id :string
            :result :any
            :duration :number))

;; 订阅事件
(a2a-subscribe *endpoint* :task-completed
  (lambda (event)
    (format t "任务 ~A 完成，耗时 ~A ms~%"
            (getf event :task-id)
            (getf event :duration))))

;; 发布事件
(a2a-publish *endpoint* :task-completed
  '(:task-id "task-123"
    :result "success"
    :duration 1500))
```
