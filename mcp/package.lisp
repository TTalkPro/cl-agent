;;;; package.lisp
;;;; CL-Agent MCP - Package Definition
;;;;
;;;; Overview:
;;;;   Package definition for the MCP (Model Context Protocol) module
;;;;   with JSON-RPC 2.0, transports, client and server.

(defpackage #:cl-agent.mcp
  (:use #:common-lisp
        #:cl-agent.core
        #:cl-agent.kernel)
  (:nicknames #:cla.mcp #:mcp)
  (:export

   ;; ==================== Protocol ====================
   ;; Protocol version
   #:+mcp-version+
   #:+mcp-protocol-version+

   ;; Message types
   #:mcp-message
   #:mcp-request
   #:mcp-response
   #:mcp-notification
   #:mcp-error

   ;; Message accessors
   #:message-id
   #:message-method
   #:message-params
   #:message-result
   #:message-error

   ;; Capability
   #:mcp-capability
   #:make-capability
   #:capability-name
   #:capability-version
   #:capability-options

   ;; Server info
   #:mcp-server-info
   #:make-server-info
   #:server-info-name
   #:server-info-version
   #:server-info-capabilities

   ;; Client info
   #:mcp-client-info
   #:make-client-info
   #:client-info-name
   #:client-info-version
   #:client-info-capabilities

   ;; Resource types
   #:mcp-resource
   #:make-resource
   #:resource-uri
   #:resource-name
   #:resource-description
   #:resource-mime-type

   ;; Tool types
   #:mcp-tool
   #:make-mcp-tool
   #:mcp-tool-name
   #:mcp-tool-description
   #:mcp-tool-input-schema

   ;; Prompt types
   #:mcp-prompt
   #:make-mcp-prompt
   #:prompt-name
   #:prompt-description
   #:prompt-arguments

   ;; ==================== JSON-RPC ====================
   ;; Request/Response
   #:json-rpc-request
   #:json-rpc-response
   #:json-rpc-notification
   #:json-rpc-error

   ;; Constructors
   #:make-rpc-request
   #:make-rpc-response
   #:make-rpc-error
   #:make-rpc-notification

   ;; Parsing
   #:parse-json-rpc
   #:encode-json-rpc

   ;; Error codes
   #:+parse-error+
   #:+invalid-request+
   #:+method-not-found+
   #:+invalid-params+
   #:+internal-error+
   #:+server-error-start+
   #:+server-error-end+

   ;; ==================== Transport ====================
   ;; Protocol
   #:mcp-transport
   #:transport-connect
   #:transport-disconnect
   #:transport-connected-p
   #:transport-send
   #:transport-receive
   #:transport-set-handler

   ;; Stdio transport
   #:stdio-transport
   #:make-stdio-transport

   ;; SSE transport
   #:sse-transport
   #:make-sse-transport
   #:sse-transport-url
   #:sse-transport-headers

   ;; ==================== Client ====================
   #:mcp-client
   #:make-mcp-client
   #:client-transport
   #:client-server-info
   #:client-connected-p

   ;; Client operations
   #:client-connect
   #:client-disconnect
   #:client-initialize
   #:client-list-tools
   #:client-call-tool
   #:client-list-resources
   #:client-read-resource
   #:client-list-prompts
   #:client-get-prompt

   ;; ==================== Server ====================
   #:mcp-server
   #:make-mcp-server
   #:server-name
   #:server-version
   #:server-transport
   #:server-running-p

   ;; Server operations
   #:server-start
   #:server-stop
   #:server-register-tool
   #:server-unregister-tool
   #:server-register-resource
   #:server-register-prompt

   ;; Server handlers
   #:server-handle-request
   #:server-handle-notification

   ;; Entry point
   #:run-mcp-server
   #:start-stdio-server))

