;;;; package.lisp
;;;; CL-Agent Core Kernel - Package Definition
;;;;
;;;; Overview:
;;;;   Defines the complete Kernel framework:
;;;;   - Tool system with tag-based filtering
;;;;   - Context (state management)
;;;;   - Service (LLM abstraction)
;;;;   - Provider protocol (LLM interface)
;;;;   - Builder (fluent construction)
;;;;   - Filter Chain (4-type pipeline)
;;;;   - 3-Tier Invoke API:
;;;;     1. invoke-tool - Execute single tool through filter chain
;;;;     2. invoke-chat - Single LLM call (no tool loop)
;;;;     3. invoke-kernel - Full tool-calling loop

(defpackage #:cl-agent.kernel
  (:use #:common-lisp
        #:cl-agent.core)
  (:nicknames #:cla.kernel #:kernel)
  (:export
   ;; ==================== Tool Definition Macros ====================
   #:deftool
   #:defplugin

   ;; ==================== Tool Runtime Registration ====================
   #:declare-tool
   #:declare-plugin

   ;; ==================== Tool Query API ====================
   #:tool-function-p
   #:tool-description
   #:tool-parameters
   #:tool-schema
   #:tool-name
   #:validate-tool-args

   ;; ==================== Schema Tools ====================
   #:params->json-schema
   #:schema-to-hash-table
   #:type-to-json-type

   ;; ==================== Context ====================
   #:context
   #:make-context
   #:context-variables
   #:context-messages
   #:context-history
   #:context-trace
   #:context-metadata
   #:context-created-at
   #:context-get
   #:context-set
   #:context-remove
   #:context-has-p
   #:context-variables-alist
   #:context-add-message
   #:context-add-messages
   #:context-clear-messages
   #:context-get-messages
   #:context-message-count
   #:context-trace-add
   #:context-get-trace
   #:context-clear-trace
   #:context-meta-get
   #:context-meta-set
   #:context-clone
   #:context-to-plist
   #:context-from-plist
   #:with-context
   #:with-context-variable

   ;; ==================== Service ====================
   #:service
   #:make-service
   #:service-p
   #:service-chat-fn
   #:service-build-result-msgs-fn
   #:service-provider
   #:service-config
   #:service-chat
   #:service-build-result
   #:service-from-provider
   #:default-build-result-msgs
   #:wrap-service
   #:wrap-service-logging
   #:wrap-service-retry
   #:wrap-service-timeout

   ;; ==================== Provider Protocol ====================
   #:llm-chat
   #:llm-chat-stream
   #:provider-name
   #:provider-model
   #:provider-api-key
   #:provider-base-url
   #:provider-supports-tools-p
   #:provider-supports-streaming-p
   #:provider-format-tools
   #:provider-parse-tool-calls
   #:check-provider-tools-support
   #:check-provider-streaming-support
   #:base-llm-provider
   #:provider-default-max-tokens
   #:provider-default-temperature

   ;; ==================== Kernel Core ====================
   #:kernel
   #:make-kernel
   #:kernel-service
   #:kernel-chat-service
   #:kernel-config
   #:kernel-tool-registry
   #:kernel-active-tags
   #:kernel-tag-filter-mode
   #:kernel-filters
   #:kernel-tools-cache
   #:kernel-context

   ;; Kernel Query API
   #:kernel-find-tool
   #:kernel-find-tool-by-name
   #:kernel-execute-tool
   #:kernel-get-tools
   #:kernel-invalidate-tools-cache
   #:kernel-list-tools
   #:kernel-list-tags
   #:kernel-tool-count
   #:kernel-has-tool-p

   ;; Kernel Tool Management API
   #:kernel-register-tool
   #:kernel-register-tools
   #:kernel-unregister-tool
   #:kernel-set-active-tags
   #:kernel-clear-active-tags

   ;; Kernel Filter API
   #:kernel-add-filter
   #:kernel-clear-filters
   #:kernel-get-service
   #:kernel-set-service

   ;; ==================== Kernel Builder ====================
   #:kernel-builder
   #:create-kernel-builder
   ;; Tool management
   #:with-tool
   #:with-tools
   #:with-tool-registry
   #:with-active-tags
   #:with-preset
   ;; Service and filter
   #:add-service
   #:add-filter
   #:with-config
   #:builder-with-context
   #:build-kernel

   ;; ==================== 3-Tier Invoke API ====================
   ;; Tier 1: Tool Execution
   #:invoke
   #:invoke-tool

   ;; Tier 2: Single LLM Call
   #:invoke-chat
   #:invoke-chat-stream

   ;; Tier 3: Full Loop
   #:invoke-kernel
   #:invoke-chat-with-tools  ; backward compat
   #:chat-completion         ; backward compat

   ;; Convenience
   #:quick-chat
   #:chat-with-tools

   ;; ==================== Filter System ====================
   ;; Filter Class
   #:filter
   #:make-filter
   #:filter-p
   #:filter-type
   #:filter-name
   #:filter-fn
   #:filter-priority
   #:filter-apply
   #:normalize-filter

   ;; Filter Results
   #:make-filter-result
   #:filter-result-action
   #:filter-result-context
   #:filter-result-value
   #:filter-result-message

   ;; Filter Chain Building
   #:build-filter-chain
   #:build-typed-filter-chain
   #:combine-filters
   #:filter-by-type
   #:sort-filters-by-priority

   ;; Built-in Filters
   #:make-logging-filter
   #:make-error-handling-filter
   #:make-timeout-filter
   #:make-approval-filter
   #:make-retry-filter
   #:make-tracing-filter
   #:make-pre-chat-logging-filter
   #:make-post-chat-logging-filter
   #:make-message-transform-filter

   ;; ==================== Chat History (backward compat) ====================
   #:chat-history
   #:make-chat-history
   #:chat-history-messages
   #:chat-history-p
   #:history-add
   #:history-add-system

   ;; ==================== Helpers ====================
   #:parse-tool-arguments
   #:hash-to-plist))
