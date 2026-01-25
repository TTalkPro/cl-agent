;;;; test-mcp.lisp
;;;; CL-Agent - MCP Module Tests

(in-package :cl-agent/tests)

(def-suite mcp-suite
  :description "MCP module test suite"
  :in cl-agent-suite)

(in-suite mcp-suite)

;;; ============================================================
;;; Protocol Tests
;;; ============================================================

(test mcp-version-constants
  "Test MCP version constants are defined"
  (is (stringp cl-agent.mcp:+mcp-version+))
  (is (stringp cl-agent.mcp:+mcp-protocol-version+)))

(test mcp-capability-creation
  "Test MCP capability creation"
  (let ((cap (cl-agent.mcp:make-capability "tools" :version "1.0")))
    (is (not (null cap)))
    (is (string= "tools" (cl-agent.mcp:capability-name cap)))
    (is (string= "1.0" (cl-agent.mcp:capability-version cap)))))

(test mcp-server-info-creation
  "Test MCP server info creation"
  (let ((info (cl-agent.mcp:make-server-info "test-server" "1.0.0")))
    (is (not (null info)))
    (is (string= "test-server" (cl-agent.mcp:server-info-name info)))
    (is (string= "1.0.0" (cl-agent.mcp:server-info-version info)))))

(test mcp-client-info-creation
  "Test MCP client info creation"
  (let ((info (cl-agent.mcp:make-client-info "test-client" "1.0.0")))
    (is (not (null info)))
    (is (string= "test-client" (cl-agent.mcp:client-info-name info)))))

;;; ============================================================
;;; Resource Tests
;;; ============================================================

(test mcp-resource-creation
  "Test MCP resource creation"
  (let ((res (cl-agent.mcp:make-resource "file:///test.txt" "Test File"
                                          :description "A test file"
                                          :mime-type "text/plain")))
    (is (not (null res)))
    (is (string= "file:///test.txt" (cl-agent.mcp:resource-uri res)))
    (is (string= "Test File" (cl-agent.mcp:resource-name res)))
    (is (string= "text/plain" (cl-agent.mcp:resource-mime-type res)))))

;;; ============================================================
;;; Tool Tests
;;; ============================================================

(test mcp-tool-creation
  "Test MCP tool creation"
  (let ((tool (cl-agent.mcp:make-mcp-tool "echo"
                                           :description "Echo input"
                                           :handler (lambda (args) args))))
    (is (not (null tool)))
    (is (string= "echo" (cl-agent.mcp:mcp-tool-name tool)))
    (is (string= "Echo input" (cl-agent.mcp:mcp-tool-description tool)))))

(test mcp-tool-with-schema
  "Test MCP tool with input schema"
  (let* ((schema (make-hash-table :test 'equal))
         (tool (cl-agent.mcp:make-mcp-tool "greet"
                                            :description "Greet someone"
                                            :input-schema schema)))
    (is (not (null (cl-agent.mcp:mcp-tool-input-schema tool))))))

;;; ============================================================
;;; Prompt Tests
;;; ============================================================

(test mcp-prompt-creation
  "Test MCP prompt creation"
  (let ((prompt (cl-agent.mcp:make-mcp-prompt "greeting"
                                               :description "Generate a greeting"
                                               :template "Hello, {name}!")))
    (is (not (null prompt)))
    (is (string= "greeting" (cl-agent.mcp:prompt-name prompt)))
    (is (string= "Generate a greeting" (cl-agent.mcp:prompt-description prompt)))))

;;; ============================================================
;;; JSON-RPC Tests
;;; ============================================================

(test json-rpc-error-codes
  "Test JSON-RPC error codes are defined"
  (is (= -32700 cl-agent.mcp:+parse-error+))
  (is (= -32600 cl-agent.mcp:+invalid-request+))
  (is (= -32601 cl-agent.mcp:+method-not-found+))
  (is (= -32602 cl-agent.mcp:+invalid-params+))
  (is (= -32603 cl-agent.mcp:+internal-error+)))

(test json-rpc-request-creation
  "Test JSON-RPC request creation"
  (let ((req (cl-agent.mcp:make-rpc-request "test-method"
                                             :params '(:key "value"))))
    (is (not (null req)))
    (is (string= "test-method" (cl-agent.mcp::rpc-method req)))
    (is (not (null (cl-agent.mcp::rpc-id req))))))

(test json-rpc-response-creation
  "Test JSON-RPC response creation"
  (let ((resp (cl-agent.mcp:make-rpc-response 1 '(:result "ok"))))
    (is (not (null resp)))
    (is (= 1 (cl-agent.mcp::rpc-id resp)))
    (is (not (null (cl-agent.mcp::rpc-result resp))))))

(test json-rpc-error-creation
  "Test JSON-RPC error response creation"
  (let ((resp (cl-agent.mcp:make-rpc-error 1 -32600 "Invalid request")))
    (is (not (null resp)))
    (is (not (null (cl-agent.mcp::rpc-error resp))))))

(test json-rpc-notification-creation
  "Test JSON-RPC notification creation"
  (let ((notif (cl-agent.mcp:make-rpc-notification "test-event"
                                                    :params '(:data "value"))))
    (is (not (null notif)))
    (is (string= "test-event" (cl-agent.mcp::rpc-method notif)))))

(test json-rpc-encoding
  "Test JSON-RPC message encoding"
  (let* ((req (cl-agent.mcp:make-rpc-request "test" :params nil :id 1))
         (json (cl-agent.mcp:encode-json-rpc req)))
    (is (stringp json))
    (is (search "jsonrpc" json))
    (is (search "2.0" json))
    (is (search "test" json))))

(test json-rpc-parsing
  "Test JSON-RPC message parsing"
  (let* ((json "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"test\"}")
         (parsed (cl-agent.mcp:parse-json-rpc json)))
    (is (not (null parsed)))
    (is (cl-agent.mcp::request-p parsed))))

;;; ============================================================
;;; Transport Tests
;;; ============================================================

(test stdio-transport-creation
  "Test stdio transport creation"
  (let ((transport (cl-agent.mcp:make-stdio-transport)))
    (is (not (null transport)))
    (is (not (cl-agent.mcp:transport-connected-p transport)))))

(test sse-transport-creation
  "Test SSE transport creation"
  (let ((transport (cl-agent.mcp:make-sse-transport "http://localhost:8080")))
    (is (not (null transport)))
    (is (string= "http://localhost:8080" (cl-agent.mcp:sse-transport-url transport)))))

;;; ============================================================
;;; Client Tests
;;; ============================================================

(test mcp-client-creation
  "Test MCP client creation"
  (let* ((transport (cl-agent.mcp:make-stdio-transport))
         (client (cl-agent.mcp:make-mcp-client transport :name "test-client")))
    (is (not (null client)))
    (is (string= "test-client" (cl-agent.mcp::client-name client)))))

;;; ============================================================
;;; Server Tests
;;; ============================================================

(test mcp-server-creation
  "Test MCP server creation"
  (let ((server (cl-agent.mcp:make-mcp-server
                 :name "test-server"
                 :version "1.0.0")))
    (is (not (null server)))
    (is (string= "test-server" (cl-agent.mcp:server-name server)))
    (is (string= "1.0.0" (cl-agent.mcp:server-version server)))))

(test mcp-server-tool-registration
  "Test MCP server tool registration"
  (let ((server (cl-agent.mcp:make-mcp-server :name "test"))
        (tool (cl-agent.mcp:make-mcp-tool "echo"
                                           :description "Echo input"
                                           :handler (lambda (args)
                                                      (gethash "message" args)))))
    ;; Register tool
    (cl-agent.mcp:server-register-tool server tool)

    ;; Should be retrievable
    (let ((retrieved (cl-agent.mcp::server-get-tool server "echo")))
      (is (not (null retrieved)))
      (is (string= "echo" (cl-agent.mcp:mcp-tool-name retrieved))))

    ;; Should be in list
    (let ((tools (cl-agent.mcp::server-list-tools server)))
      (is (= 1 (length tools))))))

(test mcp-server-resource-registration
  "Test MCP server resource registration"
  (let ((server (cl-agent.mcp:make-mcp-server :name "test"))
        (resource (cl-agent.mcp:make-resource "file:///test.txt" "Test")))
    ;; Register resource
    (cl-agent.mcp:server-register-resource server resource
                                            :handler (lambda (uri) "content"))

    ;; Should be retrievable
    (let ((retrieved (cl-agent.mcp::server-get-resource server "file:///test.txt")))
      (is (not (null retrieved))))))

(test mcp-server-prompt-registration
  "Test MCP server prompt registration"
  (let ((server (cl-agent.mcp:make-mcp-server :name "test"))
        (prompt (cl-agent.mcp:make-mcp-prompt "greeting"
                                               :description "Greet user"
                                               :template "Hello!")))
    ;; Register prompt
    (cl-agent.mcp:server-register-prompt server prompt)

    ;; Should be retrievable
    (let ((retrieved (cl-agent.mcp::server-get-prompt server "greeting")))
      (is (not (null retrieved))))))

(test mcp-server-unregister-tool
  "Test MCP server tool unregistration"
  (let ((server (cl-agent.mcp:make-mcp-server :name "test"))
        (tool (cl-agent.mcp:make-mcp-tool "temp" :description "Temporary")))
    ;; Register and unregister
    (cl-agent.mcp:server-register-tool server tool)
    (is (not (null (cl-agent.mcp::server-get-tool server "temp"))))

    (cl-agent.mcp:server-unregister-tool server "temp")
    (is (null (cl-agent.mcp::server-get-tool server "temp")))))

;;; ============================================================
;;; Server Builder Tests
;;; ============================================================

(test mcp-server-builder
  "Test MCP server builder pattern"
  (let* ((builder (cl-agent.mcp::create-server-builder
                   :name "builder-test"
                   :version "1.0"))
         (tool (cl-agent.mcp:make-mcp-tool "echo" :description "Echo")))

    ;; Add tool
    (cl-agent.mcp::builder-add-tool builder tool)

    ;; Build server
    (let ((server (cl-agent.mcp::builder-build builder)))
      (is (not (null server)))
      (is (string= "builder-test" (cl-agent.mcp:server-name server)))
      ;; Tool should be registered
      (is (not (null (cl-agent.mcp::server-get-tool server "echo")))))))

;;; ============================================================
;;; Example Server Tests
;;; ============================================================

(test example-server-creation
  "Test example server creation"
  (let ((server (cl-agent.mcp::create-example-server)))
    (is (not (null server)))
    (is (string= "example-server" (cl-agent.mcp:server-name server)))

    ;; Should have echo tool
    (is (not (null (cl-agent.mcp::server-get-tool server "echo"))))

    ;; Should have example resource
    (is (not (null (cl-agent.mcp::server-get-resource server "file:///example.txt"))))

    ;; Should have greeting prompt
    (is (not (null (cl-agent.mcp::server-get-prompt server "greeting"))))))

