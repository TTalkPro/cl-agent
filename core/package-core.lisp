;;;; package-core.lisp
;;;; CL-Agent - 核心包定义
;;;;
;;;; 概述：
;;;;   定义核心基础设施包
;;;;
;;;; 模块说明：
;;;;   - 核心工具：条件系统、工具函数、实用宏
;;;;   - 协议接口：ID 生成器、时间戳提供者、序列化器
;;;;   - 图引擎：在 cl-agent.graph 包中定义
;;;;
;;;; 注意：
;;;;   - LLM 服务包已移至 llm/package-llm.lisp
;;;;   - 持久化功能（checkpoint, memory）已移至 cl-agent-memory
;;;;   - 时间旅行功能已集成到 CheckpointManager（cl-agent.memory:checkpoint-manager）

;;; ============================================================
;;; Core Infrastructure Package
;;; ============================================================

(defpackage :cl-agent.core
  (:use :cl)
  (:nicknames :cla.core :core)
  (:export
   ;; === Condition System ===
   #:cl-agent-error
   #:api-error
   #:api-status-code
   #:api-response-body
   #:api-request-url
   #:llm-error
   #:llm-error-provider
   #:llm-error-model
   #:tool-error
   #:config-error
   #:missing-api-key-error
   #:validation-error
   #:timeout-error
   #:execution-error
   #:error-message
   #:error-cause
   #:signal-error

   ;; === Message Types ===
   #:make-message
   #:system-message
   #:user-message
   #:assistant-message
   #:tool-message
   #:message-p
   #:system-message-p
   #:user-message-p
   #:assistant-message-p
   #:tool-message-p
   #:message-role
   #:message-content
   #:message-tool-calls
   #:message-tool-call-id

   ;; === ToolCall Type ===
   #:make-tool-call
   #:tool-call-p
   #:tool-call-id
   #:tool-call-name
   #:tool-call-arguments
   #:tool-call-type

   ;; === Response Type ===
   #:make-response
   #:response-p
   #:response-content
   #:response-tool-calls
   #:response-usage
   #:response-finish-reason
   #:response-has-tool-calls-p

   ;; === Usage Type ===
   #:make-usage

   ;; === Invoke Result Type ===
   #:make-invoke-result

   ;; === Plugin Protocol ===
   #:plugin-name
   #:plugin-description
   #:plugin-tools
   #:plugin-initialize
   #:plugin-shutdown

   ;; === Utility Functions ===
   #:get-env
   #:generate-uuid
   #:timestamp-now
   #:alist-get
   #:plist-get
   #:json-parse
   #:json-stringify
   #:build-url
   #:truncate-string
   #:clean-whitespace
   #:string-empty-p
   #:ensure-string
   #:take
   #:drop
   #:group-by
   #:format-timestamp
   #:make-tool

   ;; === Utility Macros ===
   #:when-let
   #:when-let*
   #:if-let
   #:unless-let
   #:awhen
   #:aif
   #:with-timing
   #:with-retry
   #:->
   #:->>
   #:as->
   #:with-temp-file
   #:do-alist
   #:do-plist

   ;; === Logging ===
   #:log-debug
   #:log-info
   #:log-warn
   #:log-error
   #:*log-level*
   #:*log-stream*
   #:set-log-level
   #:get-log-level
   #:with-log-context

   ;; === Data Conversion ===
   #:plist-to-hash
   #:hash-to-plist
   #:key-to-string
   #:string-to-keyword
   #:plist-p
   #:with-json-hash
   #:alist-to-hash
   #:hash-to-alist
   #:merge-plists
   #:deep-merge-plists

   ;; === Protocol Defaults ===
   #:*default-id-generator*
   #:*default-timestamp-provider*))
