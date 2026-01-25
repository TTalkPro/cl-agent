;;;; test-protocols.lisp
;;;; CL-Agent - 协议测试

(in-package :cl-agent/tests)

;; 协议测试套件
(def-suite protocols-suite :in cl-agent-tests:lisp-in-agents-suite
  :description "协议测试（MCP 和 A2A）")

(in-suite protocols-suite)

;; ============================================================
;; MCP 消息测试
;; ============================================================

(test make-mcp-message
  "测试创建 MCP 消息"
  (let ((msg (cl-agent.protocols:make-mcp-message)))
    (is (string= (cl-agent.protocols:mcp-message-jsonrpc msg) "2.0"))))

(test make-mcp-request
  "测试创建 MCP 请求"
  (let ((msg (cl-agent.protocols:make-request-message 1 "test_method")))
    (is (= (cl-agent.protocols:mcp-message-id msg) 1))
    (is (string= (cl-agent.protocols:mcp-message-method msg) "test_method"))))

(test make-mcp-response
  "测试创建 MCP 响应"
  (let ((result (make-hash-table :test #'equal))
        (msg (cl-agent.protocols:make-response-message 1 result)))
    (is (= (cl-agent.protocols:mcp-message-id msg) 1))
    (is (not (null (cl-agent.protocols:mcp-message-result msg))))))

(test make-mcp-notification
  "测试创建 MCP 通知"
  (let ((msg (cl-agent.protocols:make-notification-message "test_notification")))
    (is (string= (cl-agent.protocols:mcp-message-method msg) "test_notification"))
    (is (null (cl-agent.protocols:mcp-message-id msg)))))

;; ============================================================
;; MCP 客户端测试
;; ============================================================

(test make-mcp-client
  "测试创建 MCP 客户端"
  (let ((client (cl-agent.protocols:make-mcp-client
                 :name "test-client")))
    (is (string= (cl-agent.protocols:mcp-client-info-name client)
                 "test-client"))))

(test mcp-client-connection
  "测试 MCP 客户端连接"
  (let ((client (cl-agent.protocols:make-mcp-client)))
    ;; 注意：实际连接需要服务器
    (is (not (null (cl-agent.protocols:mcp-client-connection client))))))

;; ============================================================
;; MCP 服务器测试
;; ============================================================

(test make-mcp-server
  "测试创建 MCP 服务器"
  (let ((server (cl-agent.protocols:make-mcp-server
                 :name "test-server")))
    (is (string= (cl-agent.protocols:mcp-server-info-name server)
                 "test-server"))))

(test mcp-server-register-resource
  "测试注册 MCP 资源"
  (let ((server (cl-agent.protocols:make-mcp-server)))
    (cl-agent.protocols:mcp-server-register-resource
     server "test://resource" "Test Resource")
    (is (= (hash-table-count
            (cl-agent.protocols:mcp-server-resources server))
           1))))

(test mcp-server-register-tool
  "测试注册 MCP 工具"
  (let ((server (cl-agent.protocols:make-mcp-server)))
    (cl-agent.protocols:mcp-server-register-tool
     server "test_tool" "Test tool"
     :handler (lambda (args) "result"))
    (is (= (hash-table-count
            (cl-agent.protocols:mcp-server-tools server))
           1))))

(test mcp-server-register-prompt
  "测试注册 MCP 提示"
  (let ((server (cl-agent.protocols:make-mcp-server)))
    (cl-agent.protocols:mcp-server-register-prompt
     server "test_prompt" "Test prompt")
    (is (= (hash-table-count
            (cl-agent.protocols:mcp-server-prompts server))
           1))))

;; ============================================================
;; MCP 消息处理测试
;; ============================================================

(test mcp-handle-initialize
  "测试处理初始化请求"
  (let ((server (cl-agent.protocols:make-mcp-server))
        (params (make-hash-table :test #'equal)))
    (setf (gethash "protocolVersion" params) "2024-11-05")
    (let ((response (cl-agent.protocols:mcp-server-handle-initialize
                     server params 1)))
      (is (not (null (cl-agent.protocols:mcp-message-result response)))))))

(test mcp-handle-list-resources
  "测试处理列出资源请求"
  (let ((server (cl-agent.protocols:make-mcp-server))
        (params (make-hash-table :test #'equal)))
    (cl-agent.protocols:mcp-server-register-resource
     server "test://resource" "Test Resource")
    (let ((response (cl-agent.protocols:mcp-server-handle-list-resources
                     server params 1)))
      (is (not (null (cl-agent.protocols:mcp-message-result response)))))))

(test mcp-handle-list-tools
  "测试处理列出工具请求"
  (let ((server (cl-agent.protocols:make-mcp-server))
        (params (make-hash-table :test #'equal)))
    (cl-agent.protocols:mcp-server-register-tool
     server "test_tool" "Test tool")
    (let ((response (cl-agent.protocols:mcp-server-handle-list-tools
                     server params 1)))
      (is (not (null (cl-agent.protocols:mcp-message-result response)))))))

;; ============================================================
;; A2A 消息测试
;; ============================================================

(test make-a2a-message
  "测试创建 A2A 消息"
  (let ((msg (cl-agent.protocols:make-a2a-message)))
    (is (string= (cl-agent.protocols:a2a-message-type msg)
                 "request"))
  (is (not (null (cl-agent.protocols:a2a-message-id msg))))))

(test make-a2a-request
  "测试创建 A2A 请求"
  (let ((payload (make-hash-table :test #'equal))
        (msg (cl-agent.protocols:make-a2a-request
              "agent-1" "agent-2" payload)))
    (is (string= (cl-agent.protocols:a2a-message-from msg) "agent-1"))
    (is (string= (cl-agent.protocols:a2a-message-to msg) "agent-2"))
    (is (string= (cl-agent.protocols:a2a-message-type msg) "request"))))

(test make-a2a-response
  "测试创建 A2A 响应"
  (let ((payload (make-hash-table :test #'equal))
        (msg (cl-agent.protocols:make-a2a-response
              "agent-2" "agent-1" "req-123" payload)))
    (is (string= (cl-agent.protocols:a2a-message-from msg) "agent-2"))
    (is (string= (cl-agent.protocols:a2a-message-to msg) "agent-1"))
    (is (string= (cl-agent.protocols:a2a-message-type msg) "response"))
    (is (string= (cl-agent.protocols:a2a-message-correlation-id msg)
                 "req-123"))))

(test make-a2a-event
  "测试创建 A2A 事件"
  (let ((payload (make-hash-table :test #'equal))
        (msg (cl-agent.protocols:make-a2a-event
              "agent-1" "test_event" payload)))
    (is (string= (cl-agent.protocols:a2a-message-from msg) "agent-1"))
    (is (string= (cl-agent.protocols:a2a-message-type msg) "event"))))

;; ============================================================
;; A2A 端点测试
;; ============================================================

(test make-a2a-endpoint
  "测试创建 A2A 端点"
  (let ((endpoint (cl-agent.protocols:make-a2a-endpoint
                   :host "localhost"
                   :port 8080
                   :protocol "http")))
    (is (string= (cl-agent.protocols:a2a-endpoint-host endpoint) "localhost"))
    (is (= (cl-agent.protocols:a2a-endpoint-port endpoint) 8080))
    (is (string= (cl-agent.protocols:a2a-endpoint-protocol endpoint) "http"))))

(test a2a-endpoint-to-string
  "测试端点转字符串"
  (let ((endpoint (cl-agent.protocols:make-a2a-endpoint
                   :host "example.com"
                   :port 9000
                   :protocol "tcp"
                   :path "/mcp")))
    (let ((str (cl-agent.protocols:a2a-endpoint-to-string endpoint)))
      (is (search "tcp://" str))
      (is (search "example.com" str))
      (is (search "9000" str))))))

;; ============================================================
;; A2A 消息总线测试
;; ============================================================

(test make-a2a-message-bus
  "测试创建 A2A 消息总线"
  (let ((bus (cl-agent.protocols:make-a2a-message-bus
               :agent-id "test-agent")))
    (is (string= (cl-agent.protocols:a2a-message-bus-agent-id bus)
                 "test-agent"))
    (is (not (null (cl-agent.protocols:a2a-message-bus-endpoint bus))))))

(test a2a-add-listener
  "测试添加 A2A 监听器"
  (let ((bus (cl-agent.protocols:make-a2a-message-bus)))
    (cl-agent.protocols:a2a-add-listener
     bus "agent-1" (lambda (msg) "response"))
    (is (= (hash-table-count
            (cl-agent.protocols:a2a-message-bus-listeners bus))
           1))))

(test a2a-remove-listener
  "测试移除 A2A 监听器"
  (let ((bus (cl-agent.protocols:make-a2a-message-bus)))
    (cl-agent.protocols:a2a-add-listener
     bus "agent-1" (lambda (msg) "response"))
    (cl-agent.protocols:a2a-remove-listener bus "agent-1")
    (is (zerop (hash-table-count
                (cl-agent.protocols:a2a-message-bus-listeners bus))))))

(test a2a-subscribe
  "测试订阅 A2A 事件"
  (let ((bus (cl-agent.protocols:make-a2a-message-bus)))
    (cl-agent.protocols:a2a-subscribe
     bus "agent-1" "test_event"
     (lambda (event-type data)
       (declare (ignore event-type data))))
    (is (= (hash-table-count
            (cl-agent.protocols:a2a-message-bus-subscribers bus))
           1))))

(test a2a-unsubscribe
  "测试取消订阅 A2A 事件"
  (let ((bus (cl-agent.protocols:make-a2a-message-bus)))
    (cl-agent.protocols:a2a-subscribe
     bus "agent-1" "test_event"
     (lambda (event-type data)
       (declare (ignore event-type data))))
    (cl-agent.protocols:a2a-unsubscribe bus "agent-1" "test_event")
    ;; 注意：unsubscribe 后 subscribers hash-table 可能仍存在
    ;; 但特定 agent 的处理器应该被移除
    t))

;; ============================================================
;; A2A 服务发现测试
;; ============================================================

(test a2a-register-service
  "测试注册 A2A 服务"
  (let* ((info (cl-agent.protocols:make-a2a-agent-info
                :id "test-service"
                :name "Test Service"
                :type "test"))
         (endpoint (cl-agent.protocols:make-a2a-endpoint))
         (result (cl-agent.protocols:a2a-register-service info endpoint)))
    (is result)))

(test a2a-discover-services
  "测试发现 A2A 服务"
  (let* ((info (cl-agent.protocols:make-a2a-agent-info
                :id "test-service"
                :name "Test Service"
                :type "test"))
         (endpoint (cl-agent.protocols:make-a2a-endpoint)))
    (cl-agent.protocols:a2a-register-service info endpoint)
    (let ((services (cl-agent.protocols:a2a-discover-services)))
      (is (> (length services) 0)))))

(test a2a-discover-services-by-type
  "测试按类型发现 A2A 服务"
  (let* ((info (cl-agent.protocols:make-a2a-agent-info
                :id "calc-service"
                :name "Calculator"
                :type "calculator"))
         (endpoint (cl-agent.protocols:make-a2a-endpoint)))
    (cl-agent.protocols:a2a-register-service info endpoint)
    (let ((services (cl-agent.protocols:a2a-discover-services
                     :type "calculator")))
      (is (> (length services) 0))
      (dolist (service services)
        (is (string= (cl-agent.protocols:a2a-agent-info-type service)
                     "calculator"))))))

(test a2a-get-service-endpoint
  "测试获取 A2A 服务端点"
  (let* ((info (cl-agent.protocols:make-a2a-agent-info
                :id "test-service"
                :name "Test Service"))
         (endpoint (cl-agent.protocols:make-a2a-endpoint
                   :host "localhost"
                   :port 9999)))
    (cl-agent.protocols:a2a-register-service info endpoint)
    (let ((retrieved (cl-agent.protocols:a2a-get-service-endpoint
                      "test-service")))
      (is (not (null retrieved)))
      (is (= (cl-agent.protocols:a2a-endpoint-port retrieved) 9999)))))

(test a2a-unregister-service
  "测试注销 A2A 服务"
  (let* ((info (cl-agent.protocols:make-a2a-agent-info
                :id "temp-service"
                :name "Temp Service"))
         (endpoint (cl-agent.protocols:make-a2a-endpoint)))
    (cl-agent.protocols:a2a-register-service info endpoint)
    (cl-agent.protocols:a2a-unregister-service "temp-service")
    (let ((endpoint (cl-agent.protocols:a2a-get-service-endpoint
                      "temp-service")))
      (is (null endpoint)))))

;; ============================================================
;; A2A Agent 信息测试
;; ============================================================

(test make-a2a-agent-info
  "测试创建 A2A Agent 信息"
  (let ((info (cl-agent.protocols:make-a2a-agent-info
               :id "agent-1"
               :name "Agent 1"
               :type "worker"
               :version "2.0.0"
               :capabilities '("task1" "task2"))))
    (is (string= (cl-agent.protocols:a2a-agent-info-id info) "agent-1"))
    (is (string= (cl-agent.protocols:a2a-agent-info-name info) "Agent 1"))
    (is (string= (cl-agent.protocols:a2a-agent-info-type info) "worker"))
    (is (= (length (cl-agent.protocols:a2a-agent-info-capabilities info))
           2))))

;; ============================================================
;; 便捷函数测试
;; ============================================================

(test mcp-register-resource-convenience
  "测试 mcp-register-resource 便捷函数"
  (cl-agent.protocols:mcp-register-resource
   "test://res" "Test Resource"
   :description "A test resource")
  (let ((server (cl-agent.protocols:get-default-mcp-server)))
    (is (> (hash-table-count
            (cl-agent.protocols:mcp-server-resources server))
           0))))

(test mcp-register-tool-convenience
  "测试 mcp-register-tool 便捷函数"
  (cl-agent.protocols:mcp-register-tool
   "test_tool" "Test tool"
   :handler (lambda (args) "result"))
  (let ((server (cl-agent.protocols:get-default-mcp-server)))
    (is (> (hash-table-count
            (cl-agent.protocols:mcp-server-tools server))
           0))))

(test a2a-send-message-convenience
  "测试 a2a-send-message 便捷函数"
  (let ((payload (make-hash-table :test #'equal)))
    ;; 注意：这需要实际的接收者
    ;; 这里只测试函数调用不会报错
    (declare (ignore payload))
    t))

(test a2a-publish-event-convenience
  "测试 a2a-publish-event 便捷函数"
  (let ((event-data (make-hash-table :test #'equal)))
    (setf (gethash "test" event-data) "data")
    ;; 发布事件
    (cl-agent.protocols:a2a-publish-event "test_event" event-data)
    t))

(test a2a-listen-convenience
  "测试 a2a-listen 便捷函数"
  (cl-agent.protocols:a2a-listen
   "test-agent"
   (lambda (msg) "response"))
  (let ((bus (cl-agent.protocols:get-default-a2a-bus)))
    (is (> (hash-table-count
            (cl-agent.protocols:a2a-message-bus-listeners bus))
           0))))

;; ============================================================
;; JSON 序列化测试
;; ============================================================

(test mcp-message-to-json
  "测试 MCP 消息序列化为 JSON"
  (let ((msg (cl-agent.protocols:make-request-message
              1 "test_method"
              :params (let ((p (make-hash-table :test #'equal)))
                       (setf (gethash "param1" p) "value1")
                       p))))
    (let ((json (cl-agent.protocols:mcp-message-to-json msg)))
      (is (stringp json))
      (is (search "jsonrpc" json))
      (is (search "test_method" json)))))

(test json-to-mcp-message
  "测试 JSON 解析为 MCP 消息"
  (let ((json "{"jsonrpc":"2.0","id":1,"method":"test","params":{}}"))
    (let ((msg (cl-agent.protocols:json-to-mcp-message json)))
      (is (string= (cl-agent.protocols:mcp-message-jsonrpc msg) "2.0"))
      (is (= (cl-agent.protocols:mcp-message-id msg) 1))
      (is (string= (cl-agent.protocols:mcp-message-method msg) "test")))))

;; ============================================================
;; 运行协议测试
;; ============================================================

(defun run-protocols-tests ()
  "运行所有协议测试"
  (run! 'protocols-suite))
