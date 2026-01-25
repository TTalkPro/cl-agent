;;;; cl-agent-mcp.asd
;;;; CL-Agent MCP - Model Context Protocol Implementation
;;;;
;;;; Overview:
;;;;   Full MCP (Model Context Protocol) implementation including
;;;;   JSON-RPC 2.0, multiple transports, client and server.
;;;;
;;;; Changelog:
;;;;   v1.0.0 - Initial implementation

(asdf:defsystem #:cl-agent-mcp
  :description "CL-Agent MCP - Model Context Protocol"
  :author "David"
  :license "MIT"
  :version "1.0.0"

  :depends-on (#:cl-agent-core
               #:cl-agent-llm
               #:bordeaux-threads
               #:com.inuoe.jzon
               #:usocket
               #:flexi-streams)

  :serial t
  :components ((:file "package")
               (:file "protocol")
               (:file "json-rpc")
               (:module "transport"
                :components ((:file "base")
                             (:file "stdio")
                             (:file "sse")))
               (:module "client"
                :components ((:file "core")))
               (:module "server"
                :components ((:file "core")
                             (:file "main"))))

  :in-order-to ((asdf:test-op (asdf:test-op #:cl-agent-test))))

