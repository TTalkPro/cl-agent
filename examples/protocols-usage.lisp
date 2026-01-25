;;;; protocols-usage.lisp
;;;; CL-Agent - 协议使用示例

;; 加载系统
(asdf:load-system :cl-agent)

;; 使用包
(in-package :cl-user)
(use-package :cl-agent)
(use-package :cl-agent.protocols)

;;; ============================================================
;;; 示例 1：MCP 客户端基本使用
;;; ============================================================

(defun example-1-mcp-client-basic ()
  "MCP 客户端基本使用"
  (format t "~%=== Example 1: MCP Client Basic ===~%")

  ;; 创建客户端
  (let ((client (make-mcp-client
                 :name "example-client"
                 :version "1.0.0")))
    (format t "Created client: ~A~%"
            (mcp-client-info-name client))

    ;; 连接到服务器
    (mcp-client-connect client :server-command "mock-server")

    ;; 初始化
    (mcp-client-initialize client)

    (format t "Client initialized successfully~%")

    ;; 断开连接
    (mcp-client-disconnect client)))

;;; ============================================================
;;; 示例 2：MCP 服务器基本使用
;;; ============================================================

(defun example-2-mcp-server-basic ()
  "MCP 服务器基本使用"
  (format t "~%=== Example 2: MCP Server Basic ===~%")

  ;; 创建服务器
  (let ((server (make-mcp-server
                 :name "example-server"
                 :version "1.0.0")))
    (format t "Created server: ~A~%"
            (mcp-server-info-name server))

    ;; 注册资源
    (mcp-server-register-resource server
                                   "file:///example.txt"
                                   "Example Resource"
                                   :description "An example resource"
                                   :mime-type "text/plain")

    ;; 注册工具
    (mcp-server-register-tool server
                              "echo"
                              "Echo the input"
                              :handler (lambda (args)
                                        (format nil "Echoed: ~A"
                                                (gethash "text" args))))

    ;; 注册提示模板
    (mcp-server-register-prompt server
                                 "greeting"
                                 "A simple greeting prompt"
                                 :arguments '((:name "name"
                                              :description "Name to greet"
                                              :required t)))

    ;; 启动服务器
    (mcp-server-start server)

    (format t "Server started successfully~%")

    ;; 停止服务器
    (mcp-server-stop server)))

;;; ============================================================
;;; 示例 3：MCP 资源访问
;;; ============================================================

(defun example-3-mcp-resources ()
  "MCP 资源访问"
  (format t "~%=== Example 3: MCP Resources ===~%")

  ;; 创建并启动服务器
  (let ((server (make-mcp-server)))
    ;; 注册多个资源
    (mcp-server-register-resource server
                                   "config:///settings"
                                   "Settings"
                                   :description "Application settings"
                                   :mime-type "application/json")

    (mcp-server-register-resource server
                                   "data:///users"
                                   "User Data"
                                   :description "User information"
                                   :mime-type "application/json")

    (mcp-server-start server)

    (format t "Registered ~A resources~%"
            (hash-table-count (mcp-server-resources server)))

    ;; 客户端访问资源
    (let ((client (make-mcp-client)))
      (mcp-client-connect client)
      (mcp-client-initialize client)

      ;; 列出资源
      (let ((resources (mcp-client-list-resources client)))
        (format t "Available resources: ~A~%"
                (length resources)))

      ;; 读取资源
      (let ((content (mcp-client-read-resource client "config:///settings")))
        (format t "Resource content: ~A~%" content))

      (mcp-client-disconnect client))

    (mcp-server-stop server)))

;;; ============================================================
;;; 示例 4：MCP 工具调用
;;; ============================================================

(defun example-4-mcp-tools ()
  "MCP 工具调用"
  (format t "~%=== Example 4: MCP Tools ===~%")

  ;; 创建并启动服务器
  (let ((server (make-mcp-server)))

    ;; 注册多个工具
    (mcp-server-register-tool server
                              "calculate"
                              "Perform basic calculations"
                              :handler (lambda (args)
                                        (let ((operation (gethash "operation" args))
                                              (a (gethash "a" args))
                                              (b (gethash "b" args)))
                                          (string-case operation
                                            ("add" (format nil "~A" (+ a b)))
                                            ("subtract" (format nil "~A" (- a b)))
                                            ("multiply" (format nil "~A" (* a b)))
                                            ("divide" (format nil "~A" (/ a b)))
                                            (otherwise "Unknown operation")))))

    (mcp-server-register-tool server
                              "get_weather"
                              "Get weather information"
                              :handler (lambda (args)
                                        (declare (ignore args))
                                        "{ "temperature": 22, "condition": "sunny" }"))

    (mcp-server-start server)

    (format t "Registered ~A tools~%"
            (hash-table-count (mcp-server-tools server)))

    ;; 客户端调用工具
    (let ((client (make-mcp-client)))
      (mcp-client-connect client)
      (mcp-client-initialize client)

      ;; 列出工具
      (let ((tools (mcp-client-list-tools client)))
        (format t "Available tools: ~A~%"
                (length tools)))

      ;; 调用工具
      (let ((result (mcp-client-call-tool client
                                          "calculate"
                                          (let ((args (make-hash-table :test #'equal)))
                                            (setf (gethash "operation" args) "add")
                                            (setf (gethash "a" args) 5)
                                            (setf (gethash "b" args) 3)
                                            args))))
        (format t "Tool result: ~A~%" result))

      (mcp-client-disconnect client))

    (mcp-server-stop server)))

;;; ============================================================
;;; 示例 5：A2A 消息传递
;;; ============================================================

(defun example-5-a2a-messaging ()
  "A2A 消息传递"
  (format t "~%=== Example 5: A2A Messaging ===~%")

  ;; 创建消息总线
  (let ((bus1 (make-a2a-message-bus
               :agent-id "agent-1"
               :endpoint (make-a2a-endpoint :port 7001)))
        (bus2 (make-a2a-message-bus
               :agent-id "agent-2"
               :endpoint (make-a2a-endpoint :port 7002))))

    (format t "Created message buses: ~A and ~A~%"
            (a2a-message-bus-agent-id bus1)
            (a2a-message-bus-agent-id bus2))

    ;; 添加监听器
    (a2a-add-listener bus2 "agent-1"
                      (lambda (message)
                        (format t "Agent-2 received message from ~A~%"
                                (a2a-message-from message))
                        (let ((payload (a2a-message-payload message)))
                          (format t "Payload: ~A~%" payload))
                        "Response from agent-2"))

    ;; 发送消息
    (let ((payload (make-hash-table :test #'equal)))
      (setf (gethash "action" payload) "greet")
      (setf (gethash "data" payload) "Hello from agent-1!")

      (let ((response (a2a-send-request bus1 "agent-2" payload)))
        (format t "Received response: ~A~%"
                (a2a-message-payload response))))))

;;; ============================================================
;;; 示例 6：A2A 事件广播
;;; ============================================================

(defun example-6-a2a-events ()
  "A2A 事件广播"
  (format t "~%=== Example 6: A2A Events ===~%")

  ;; 创建消息总线
  (let ((bus (make-a2a-message-bus
              :agent-id "event-broker")))

    ;; 创建订阅者
    (let ((subscriber1 (make-a2a-message-bus
                       :agent-id "subscriber-1"))
          (subscriber2 (make-a2a-message-bus
                       :agent-id "subscriber-2")))

      ;; 订阅事件
      (a2a-subscribe subscriber1 "user-login"
                     (lambda (event-type data)
                       (format t "Subscriber-1 received event: ~A~%"
                               event-type)
                       (format t "Data: ~A~%" data)))

      (a2a-subscribe subscriber2 "user-login"
                     (lambda (event-type data)
                       (format t "Subscriber-2 received event: ~A~%"
                               event-type)
                       (format t "Data: ~A~%" data)))

      ;; 广播事件
      (let ((event-data (make-hash-table :test #'equal)))
        (setf (gethash "userId" event-data) "user-123")
        (setf (gethash "timestamp" event-data)
              (cl-agent.core:timestamp-now))

        (let ((count (a2a-broadcast-event bus
                                          "user-login"
                                          event-data)))
          (format t "Event sent to ~A subscribers~%" count)))))

  ;; 订阅事件（使用默认总线）
  (a2a-subscribe (get-default-a2a-bus) "task-completed"
                 (lambda (event-type data)
                   (format t "Task completed: ~A~%"
                           (gethash "taskId" data))))

  ;; 发布事件
  (let ((task-data (make-hash-table :test #'equal)))
    (setf (gethash "taskId" task-data) "task-456")
    (setf (gethash "result" task-data) "success")

    (a2a-publish-event "task-completed" task-data))

  (format t "Event published~%"))

;;; ============================================================
;;; 示例 7：A2A 服务发现
;;; ============================================================

(defun example-7-a2a-discovery ()
  "A2A 服务发现"
  (format t "~%=== Example 7: A2A Service Discovery ===~%")

  ;; 注册服务
  (let* ((agent1-info (make-a2a-agent-info
                      :id "agent-1"
                      :name "Calculator Agent"
                      :type "calculator"
                      :version "1.0.0"
                      :capabilities '("add" "subtract" "multiply" "divide")))
         (agent1-endpoint (make-a2a-endpoint
                           :host "localhost"
                           :port 8001))

         (agent2-info (make-a2a-agent-info
                      :id "agent-2"
                      :name "Weather Agent"
                      :type "weather"
                      :version "1.0.0"
                      :capabilities '("get_weather" "forecast")))
         (agent2-endpoint (make-a2a-endpoint
                           :host "localhost"
                           :port 8002)))

    (a2a-register-service agent1-info agent1-endpoint)
    (a2a-register-service agent2-info agent2-endpoint)

    (format t "Registered 2 services~%")

    ;; 发现所有服务
    (let ((all-services (a2a-discover-services)))
      (format t "Discovered ~A services:~%" (length all-services))
      (dolist (service all-services)
        (format t "  - ~A (~A)~%"
                (a2a-agent-info-name service)
                (a2a-agent-info-type service))))

    ;; 按类型发现
    (let ((calc-services (a2a-discover-services :type "calculator")))
      (format t "~%Found ~A calculator services~%"
              (length calc-services)))

    ;; 获取服务端点
    (let ((endpoint (a2a-get-service-endpoint "agent-1")))
      (format t "Agent-1 endpoint: ~A~%"
              (a2a-endpoint-to-string endpoint)))))

;;; ============================================================
;;; 示例 8：MCP + A2A 集成
;;; ============================================================

(defun example-8-integration ()
  "MCP + A2A 集成"
  (format t "~%=== Example 8: MCP + A2A Integration ===~%")

  ;; 创建 MCP 服务器
  (let ((mcp-server (make-mcp-server
                     :name "integrated-server")))

    ;; 注册 A2A 工具到 MCP
    (mcp-server-register-tool mcp-server
                              "send_a2a_message"
                              "Send message via A2A"
                              :handler (lambda (args)
                                        (let ((to (gethash "to" args))
                                              (payload (gethash "payload" args)))
                                          (a2a-send-message to payload)
                                          "{ "status": "sent" }")))

    (mcp-server-register-tool mcp-server
                              "discover_a2a_services"
                              "Discover A2A services"
                              :handler (lambda (args)
                                        (declare (ignore args))
                                        (let ((services (a2a-discover-services)))
                                          (format nil "{ "count": ~A }"
                                                  (length services)))))

    (mcp-server-start mcp-server)

    (format t "Integrated MCP + A2A server started~%")

    ;; 客户端调用
    (let ((mcp-client (make-mcp-client)))
      (mcp-client-connect mcp-client)
      (mcp-client-initialize mcp-client)

      ;; 通过 MCP 调用 A2A 功能
      (let ((result (mcp-client-call-tool mcp-client
                                         "discover_a2a_services"
                                         (make-hash-table :test #'equal))))
        (format t "A2A services via MCP: ~A~%" result))

      (mcp-client-disconnect mcp-client))

    (mcp-server-stop mcp-server)))

;;; ============================================================
;;; 示例 9：MCP 提示模板
;;; ============================================================

(defun example-9-mcp-prompts ()
  "MCP 提示模板"
  (format t "~%=== Example 9: MCP Prompts ===~%")

  ;; 创建服务器
  (let ((server (make-mcp-server)))

    ;; 注册多个提示模板
    (mcp-server-register-prompt server
                                 "code_review"
                                 "Request a code review"
                                 :arguments '((:name "code"
                                              :description "Code to review"
                                              :required t)
                                             (:name "language"
                                              :description "Programming language"
                                              :required nil)))

    (mcp-server-register-prompt server
                                 "explain_concept"
                                 "Explain a concept"
                                 :arguments '((:name "concept"
                                              :description "Concept to explain"
                                              :required t)
                                             (:name "level"
                                              :description "Explanation level"
                                              :required nil)))

    (mcp-server-start server)

    (format t "Registered ~A prompts~%"
            (hash-table-count (mcp-server-prompts server)))

    ;; 客户端使用提示
    (let ((client (make-mcp-client)))
      (mcp-client-connect client)
      (mcp-client-initialize client)

      ;; 列出提示
      (let ((prompts (mcp-client-list-prompts client)))
        (format t "Available prompts: ~A~%"
                (length prompts)))

      ;; 获取提示
      (let ((prompt (mcp-client-get-prompt
                     client
                     "code_review"
                     :arguments (let ((args (make-hash-table :test #'equal)))
                                  (setf (gethash "code" args) "(defun foo (x) x)")
                                  (setf (gethash "language" args) "lisp")
                                  args))))
        (format t "Prompt content: ~A~%" prompt))

      (mcp-client-disconnect client))

    (mcp-server-stop server)))

;;; ============================================================
;;; 示例 10：A2A 双向通信
;;; ============================================================

(defun example-10-a2a-bidirectional ()
  "A2A 双向通信"
  (format t "~%=== Example 10: A2A Bidirectional Communication ===~%")

  ;; 创建两个 Agent
  (let ((agent1 (make-a2a-message-bus
                 :agent-id "worker-agent"
                 :endpoint (make-a2a-endpoint :port 9001)))
        (agent2 (make-a2a-message-bus
                 :agent-id "supervisor-agent"
                 :endpoint (make-a2a-endpoint :port 9002))))

    ;; Agent 1 监听来自 Agent 2 的消息
    (a2a-add-listener agent1 "supervisor-agent"
                      (lambda (message)
                        (let ((payload (a2a-message-payload message)))
                          (format t "Worker received task: ~A~%"
                                  (gethash "task" payload))
                          ;; 处理任务
                          (let ((result (make-hash-table :test #'equal)))
                            (setf (gethash "status" result) "completed")
                            (setf (gethash "result" result)
                                  (format nil "Processed: ~A"
                                          (gethash "task" payload)))
                            result))))

    ;; Agent 2 监听来自 Agent 1 的消息
    (a2a-add-listener agent2 "worker-agent"
                      (lambda (message)
                        (let ((payload (a2a-message-payload message)))
                          (format t "Supervisor received result: ~A~%"
                                  (gethash "result" payload))
                          "Acknowledged")))

    ;; Supervisor 发送任务给 Worker
    (let ((task (make-hash-table :test #'equal)))
      (setf (gethash "task" task) "process_data")
      (setf (gethash "params" task) "(param1 param2)")

      (let ((response (a2a-send-request agent2
                                        "worker-agent"
                                        task)))
        (format t "Task completed with response: ~A~%"
                (a2a-message-payload response))))))

;;; ============================================================
;;; 运行所有示例
;;; ============================================================

(defun run-protocols-examples ()
  "运行所有协议示例"
  (format t "~%========================================")
  (format t "~%  CL-Agent Protocols Examples")
  (format t "~%========================================")

  (example-1-mcp-client-basic)
  (example-2-mcp-server-basic)
  (example-3-mcp-resources)
  (example-4-mcp-tools)
  (example-5-a2a-messaging)
  (example-6-a2a-events)
  (example-7-a2a-discovery)
  (example-8-integration)
  (example-9-mcp-prompts)
  (example-10-a2a-bidirectional)

  (format t "~%========================================")
  (format t "~%  All protocols examples completed!")
  (format t "~%========================================~%"))

;; 运行示例（取消注释）
;; (run-protocols-examples)
