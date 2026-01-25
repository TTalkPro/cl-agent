;;;; cl-agent-protocols.asd
;;;; CL-Agent 协议支持系统

(asdf:defsystem #:cl-agent-protocols
  :description "CL-Agent 协议支持（MCP、A2A）"
  :author "David"
  :license "MIT"
  :version "1.0.0"

  :depends-on (#:cl-agent-core      ; 包含 dexador, quri, jzon, bt, uuid
               #:cl-agent-llm)

  :serial t
  :components ((:file "package-protocols")
               (:file "mcp")
               (:file "mcp-client")
               (:file "mcp-server")
               (:file "a2a-types")
               (:file "a2a-endpoint")
               (:file "a2a-bus")
               (:file "a2a-messaging")
               (:file "a2a-handlers")
               (:file "a2a-listeners")
               (:file "a2a-service")
               (:file "a2a"))

  :in-order-to ((asdf:test-op (asdf:test-op #:cl-agent-test))))
