;;;; package-protocols.lisp
;;;; CL-Agent - 协议支持包定义

(defpackage #:cl-agent.protocols
  (:use #:common-lisp
        #:cl-agent.core)
  (:nicknames #:cla.protocols)
  (:export
   ;; ==================== MCP 协议 ====================
   ;; MCP 客户端
   #:mcp-client
   #:make-mcp-client
   #:mcp-client-transport
   #:mcp-client-connection

   ;; MCP 服务器
   #:mcp-server
   #:make-mcp-server
   #:mcp-server-info
   #:mcp-server-capabilities
   #:mcp-server-resources
   #:mcp-server-prompts
   #:mcp-server-tools

   ;; MCP 消息
   #:mcp-message
   #:make-message
   #:mcp-message-method
   #:mcp-message-params
   #:mcp-message-id

   ;; ==================== A2A 协议 ====================
   ;; A2A 消息类型
   #:a2a-message
   #:a2a-request
   #:a2a-response
   #:a2a-event

   ;; A2A 端点
   #:a2a-endpoint
   #:make-a2a-endpoint

   ;; A2A 总线
   #:a2a-bus
   #:make-a2a-bus
   #:a2a-send
   #:a2a-subscribe
   #:a2a-publish))
