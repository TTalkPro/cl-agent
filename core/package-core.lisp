;;;; package-core.lisp
;;;; CL-Agent - 核心包定义
;;;;
;;;; 概述：
;;;;   定义核心基础设施包
;;;;
;;;; 模块说明：
;;;;   - 核心工具：条件系统、工具函数、实用宏、ID 生成器/时间戳提供者
;;;;   - 数据转换、JSON Schema 生成与校验
;;;;   - LLM Provider SPI（llm-chat）+ 统一 llm-response

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

   ;; 注：此处曾导出 core/types.lisp 的一整套旧类型——消息（make-message /
   ;; system-message / user-message / ...）、ToolCall、Response、Usage、
   ;; InvokeResult，外加 5 个从未实现的 plugin-* defgeneric，共 34 个符号。
   ;; SBCL 调用图显示它们**全部零调用**：唯一的「调用」是文件内部的自闭环
   ;; （make-message 被 4 个构造器调用，而那 4 个本身零调用；message-p 同理），
   ;; 没有任何外部入口。它们与 cl-agent.chat 真正在用的 CLOS 消息体系
   ;; 有 11 个同名符号——合并 chat 进 core 时正面撞车。整体删除。
   ;; 消息/ToolCall/Response 请用下方 chat 层的 CLOS 版本。

   ;; === Utility Functions ===
   #:get-env
   #:make-standard-id-generator
   #:make-standard-timestamp-provider
   #:generate-uuid
   #:timestamp-now
   ;; 注：alist-get 已移除（原实现是伪装成 alist 访问器的 plist 访问器，
   ;; 且被 cl-agent.llm 的同名真实现静默覆盖）。plist 访问用 plist-get。
   #:plist-get
   #:json-parse
   #:json-stringify
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
   #:->
   #:->>
   #:as->
   #:with-temp-file
   #:do-alist
   #:do-plist

   ;; === 动态绑定继承（跨线程） ===
   #:*inherited-special-variables*
   #:with-inherited-specials
   #:capture-special-bindings
   #:with-captured-special-bindings

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
   #:*default-timestamp-provider*

   ;; === JSON Schema 工具 ===
   #:type-to-json-type
   #:params->json-schema
   #:schema-to-hash-table
   ;; JSON Schema 校验（cl-agent.core:validation-turn-filter 使用）
   #:validate-json-schema
   #:validate-json-text
   #:ensure-json-schema
   #:json-null-p
   #:json-array-p
   #:json-boolean-p
   #:json-type-name
   #:json-equal

   ;; === Unified LLM Response Schema ===
   ;; Response class
   #:llm-response
   #:make-llm-response
   #:llm-response-p
   #:llm-response-content
   #:llm-response-tool-calls
   #:llm-response-usage
   #:llm-response-model
   #:llm-response-finish-reason
   #:llm-response-reasoning
   #:llm-response-reasoning-blocks
   #:llm-response-message-id
   #:llm-response-raw

   ;; Usage class
   #:llm-usage
   #:make-llm-usage
   #:llm-usage-input-tokens
   #:llm-usage-output-tokens
   #:llm-usage-total-tokens
   #:llm-usage-cache-read-tokens
   #:llm-usage-cache-creation-tokens

   ;; Tool call class
   #:llm-tool-call
   #:make-llm-tool-call
   #:llm-tool-call-id
   #:llm-tool-call-name
   #:llm-tool-call-arguments
   #:llm-tool-call-raw

   ;; Finish reason type
   #:finish-reason
   #:normalize-finish-reason
   #:normalize-usage

   ;; Response predicates
   #:llm-response-has-tool-calls-p
   #:llm-response-has-content-p

   ;; Conversion function
   #:plist-to-llm-response

   ;; Convenience accessors
   #:llm-response-text
   #:llm-response-input-tokens
   #:llm-response-output-tokens
   #:llm-response-total-tokens
   #:llm-response-first-tool-call
   #:llm-response-get-tool-calls
   #:llm-response-get-finish-reason

   ;; === LLM Provider Protocol ===
   ;; Core protocol
   #:llm-chat
   #:llm-chat-stream
   ;; Provider configuration
   #:provider-name
   #:provider-model
   #:provider-api-key
   #:provider-base-url
   #:provider-supports-tools-p
   #:provider-supports-streaming-p
   ;; Tool schema protocol
   #:provider-format-tools
   #:provider-parse-tool-calls
   ;; Capability checking
   #:check-provider-tools-support
   #:check-provider-streaming-support
   ;; Base class
   #:base-llm-provider
   #:provider-default-max-tokens
   #:provider-default-temperature

   ;; ============================================================
   ;; HTTP 客户端（原 cl-agent.http）
   ;; ============================================================
   ;; ==================== 同步 API ====================
   ;; 核心请求函数
   #:http-request
   #:http-get
   #:http-post
   #:http-put
   #:http-delete
   #:http-patch
   #:http-head

   ;; ==================== 异步 API ====================
   ;; 异步请求
   #:http-request-async
   #:http-get-async
   #:http-post-async

   ;; 并行请求
   #:http-parallel
   #:http-parallel-map

   ;; Future 操作
   #:http-future
   #:http-future-p
   #:http-future-done-p
   #:http-future-value
   #:http-future-wait
   #:http-future-cancel

   ;; 动态绑定继承（转出 cl-agent.core 的同名符号，非副本）
   #:*inherited-special-variables*
   #:with-inherited-specials

   ;; ==================== 流式 API ====================
   ;; SSE 流式请求
   #:http-stream
   #:http-stream-sse

   ;; 注：HTTP 传输层的 SSE 上下文（stream-context / make-stream-context /
   ;; stream-context-buffer|callback|stop-p）不导出——它只在 http/streaming.lisp
   ;; 内部使用，对外的 SSE 入口是 http-stream-sse。
   ;; 而且 cl-agent.llm 另有一个同名但语义不同的 stream-context
   ;; （LLM 客户端层的累积器，带 accumulator 槽）。llm :use cl-agent.core，
   ;; 一旦这里导出，llm 的 defstruct 就会重定义 core 的 structure 并报错。
   ;; :use 只继承 external 符号——不导出，两者各自为政，互不干扰。

   ;; ==================== 重试策略 ====================
   ;; 重试配置
   #:retry-config
   #:make-retry-config
   #:retry-config-max-retries
   #:retry-config-delay
   #:retry-config-backoff
   #:retry-config-retry-on

   ;; 重试执行
   #:with-retry
   #:http-request-with-retry

   ;; ==================== 响应处理 ====================
   ;; 响应结构
   #:http-response
   #:make-http-response
   #:http-response-status
   #:http-response-headers
   #:http-response-body
   #:http-response-uri

   ;; 响应谓词
   #:http-success-p
   #:http-client-error-p
   #:http-server-error-p

   ;; ==================== 条件系统 ====================
   ;; HTTP 错误
   #:http-error
   #:http-error-status
   #:http-error-body
   #:http-error-uri

   #:http-client-error
   #:http-server-error
   #:http-timeout-error
   #:http-connection-error

   ;; ==================== 配置 ====================
   ;; 全局配置
   #:*default-timeout*
   #:*default-retry-config*
   #:*http-user-agent*

   ;; 线程池
   #:*http-thread-pool*
   #:initialize-http-thread-pool
   #:shutdown-http-thread-pool

   ;; ==================== 工具函数 ====================
   #:build-url
   #:encode-query-params
   #:parse-content-type
   #:json-body

   ;; ============================================================
   ;; Chat Model API（原 cl-agent.chat）
   ;; ============================================================
   ;; ==================== 消息体系 ====================
   #:message
   #:system-message
   #:user-message
   #:assistant-message
   #:tool-response-message
   #:message-role
   #:message-text
   #:message-metadata
   #:assistant-tool-calls
   #:tool-responses
   ;; tool-call / tool-response 值对象
   #:tool-call
   #:make-tool-call
   #:tool-call-id
   #:tool-call-name
   #:tool-call-arguments
   #:tool-response
   #:make-tool-response
   #:tool-response-id
   #:tool-response-name
   #:tool-response-text
   ;; 谓词
   #:messagep
   #:system-message-p
   #:user-message-p
   #:assistant-message-p
   #:tool-response-message-p
   ;; 中立 plist 互转（provider SPI 边界）
   #:message->neutral
   #:messages->neutral
   #:neutral->message
   #:neutral->messages

   ;; ==================== ChatOptions ====================
   #:chat-options
   #:make-chat-options
   #:copy-chat-options
   #:merge-chat-options
   #:chat-options-with-tools
   #:chat-options-model
   #:chat-options-temperature
   #:chat-options-max-tokens
   #:chat-options-top-p
   #:chat-options-top-k
   #:chat-options-stop-sequences
   #:chat-options-frequency-penalty
   #:chat-options-presence-penalty
   #:chat-options-thinking
   #:chat-options-extra-params
   #:chat-options-tool-callbacks
   #:chat-options-tool-names
   #:chat-options-tool-context

   ;; ==================== Prompt ====================
   #:prompt
   #:make-prompt
   #:prompt-messages
   #:prompt-options
   #:prompt-copy
   #:prompt-system-messages
   #:prompt-instruction-messages
   #:prompt-last-user-text
   #:prompt-last-user-or-tool-message
   #:prompt-augment-last-user-message
   #:prompt-append-messages

   ;; ==================== ChatResponse ====================
   #:generation
   #:make-generation
   #:generation-message
   #:generation-finish-reason
   #:chat-response-metadata
   #:make-chat-response-metadata
   #:response-metadata-id
   #:response-metadata-model
   #:response-metadata-usage
   #:response-metadata-raw
   #:chat-response
   #:make-chat-response
   #:chat-response-generations
   #:chat-response-metadata-of
   #:chat-response-generation
   #:chat-response-message
   #:chat-response-text
   #:chat-response-tool-calls
   #:chat-response-has-tool-calls-p
   #:chat-response-finish-reason
   #:chat-response-usage
   #:llm-response->chat-response

   ;; ==================== 工具体系 ====================
   #:tool-definition
   #:make-tool-definition
   #:tool-definition-name
   #:tool-definition-description
   #:tool-definition-parameters
   #:tool-callback
   #:make-tool-callback
   #:tool-callback-definition
   #:tool-callback-function
   #:tool-callback-return-direct-p
   #:tool-callback-serial-p
   #:tool-callback-retry-p
   #:tool-callback-name
   #:tool-callback-call
   #:tool-callback->schema
   ;; deftool 宏与全局注册表
   #:deftool
   #:register-tool-callback
   #:unregister-tool-callback
   #:symbol-tool-callback
   #:find-tool-callback
   #:list-tool-callbacks
   #:resolve-tool-callbacks
   ;; 工具解析（kernel 的 batch / manager / tool-search filter 依赖）
   #:find-callback-for-call
   ;; 注：ToolCallingManager（tool-calling-manager / execute-tool-calls /
   ;; concurrent-tool-calling-manager / tool-execution-result ...）已删除。
   ;; 工具执行循环唯一住在 cl-agent.core:run-tool-loop，执行策略见
   ;; cl-agent.kernel 的 sequential/virtual-thread/thread-pool 三个 manager。
   ;; *inherited-special-variables* / with-inherited-specials 属于
   ;; cl-agent.core（见 core/utils.lisp），需要时从那里取。
   #:arguments->plist
   ;; 条件
   #:tool-execution-error
   #:tool-execution-error-tool-name
   #:tool-execution-error-cause
   #:tool-not-found-error
   #:tool-not-found-error-tool-name

   ;; ==================== ChatModel ====================
   #:chat-model
   #:chat-model-call
   #:chat-model-stream
   #:chat-model-default-options
   #:provider-chat-model
   #:make-provider-chat-model
   #:chat-model-provider
   #:max-tool-iterations-exceeded-error

   ;; ==================== ChatMemory ====================
   ;; Repository 协议
   #:chat-memory-repository
   #:repository-find
   #:repository-save
   #:repository-delete
   #:repository-conversation-ids
   #:in-memory-chat-memory-repository
   #:make-in-memory-chat-memory-repository
   ;; ChatMemory 协议
   #:chat-memory
   #:memory-add
   #:memory-messages
   #:memory-clear
   #:message-window-chat-memory
   #:make-message-window-chat-memory
   #:+default-conversation-id+

   ;; ============================================================
   ;; Kernel + Filter（原 cl-agent.kernel）
   ;; ============================================================
   ;; ==================== Filter 类与构造 ====================
   #:filter
   #:filter-name
   #:filter-tool-hook
   #:filter-chat-hook
   #:filter-turn-hook
   #:filter-token-xform
   #:make-filter
   #:defilter

   ;; ==================== build-chain 洋葱折叠 ====================
   #:build-chain

   ;; ==================== Tool 链载体 ====================
   #:tool-request
   #:make-tool-request
   #:tool-request-function
   #:tool-request-args
   #:tool-request-context
   #:tool-result
   #:make-tool-result
   #:tool-result-value
   #:tool-result-writes
   #:tool-result-error
   #:tool-result->text

   ;; ==================== Turn 链载体 ====================
   #:turn-request
   #:make-turn-request
   #:turn-request-messages
   #:turn-request-context
   #:turn-request-resume-p
   #:turn-result
   #:make-turn-result
   #:turn-result-status
   #:turn-result-response
   #:turn-result-tool-context
   #:turn-result-tool-calls-made
   #:turn-result-loop-state
   #:turn-result-pending-tool
   #:turn-result-pause-reason
   ;; 暂停载体（HITL）
   #:loop-state
   #:make-loop-state
   #:loop-state-messages
   #:loop-state-response
   #:loop-state-tool-calls
   #:loop-state-pending-id
   #:loop-state-iteration
   #:loop-state-options
   #:loop-state-context
   #:pending-tool
   #:make-pending-tool
   #:pending-tool-name
   #:pending-tool-args
   #:pending-tool-id

    ;; ==================== Kernel ====================
    #:kernel
    #:make-kernel
    #:build-kernel
    #:kernel-model
    #:kernel-tools
    #:kernel-filters
    #:kernel-eligibility-fn
    #:kernel-settings
    #:kernel-tool-manager
    #:kernel-default-system
    #:kernel-default-options
    #:kernel-tool-gate
    #:kernel-state-slots

    ;; ==================== ToolCallingManager ====================
    #:tool-calling-manager
    #:execute-tool-calls
    #:make-tool-execution-result
    #:sequential-tool-calling-manager
    #:make-sequential-tool-calling-manager
    #:virtual-thread-tool-calling-manager
    #:make-virtual-thread-tool-calling-manager
    #:thread-pool-tool-calling-manager
    #:make-thread-pool-tool-calling-manager
    #:tcm-pool-size
    #:shutdown-tool-calling-manager
    #:with-thread-pool-tool-calling-manager
    #:default-tool-calling-manager

    ;; ==================== Invoke 原语 ====================
    #:invoke-chat
    #:invoke-tool
    #:invoke-tool-batch
    #:*tool-pool-size*
    #:ensure-tool-pool
    #:shutdown-tool-pool
    ;; 故障路由（瞬态重试）
    #:*transient-retry-attempts*
    #:*transient-retry-base-delay*
    ;; 写意图折叠（:writes + :state-slots 的 MapReduce 契约）
    #:apply-writes
    #:fold-batch-writes
    #:invoke-turn
    #:run-tool-loop
    #:resume-turn
    #:invoke-chat-stream
    #:compose-token-xforms

    ;; ==================== chat DSL（调用方入口） ====================
    #:chat
    #:kernel-chat
    #:kernel-chat-text
    #:kernel-chat-entity
    #:kernel-chat-stream
    #:strip-json-fences

    ;; ==================== 故障分类 ====================
    #:tool-failure
    #:tool-failure-class
    #:tool-failure-message
    #:semantic-tool-failure
    #:transient-tool-failure
    #:environment-tool-failure
    #:classify-tool-error

    ;; ==================== 内置 Filter ====================
    ;; Memory
    #:memory-filter
    ;; Logging
    #:logging-chat-filter
    #:logging-tool-filter
    ;; Safeguard
    #:safeguard-turn-filter
    ;; Validation
    #:validation-turn-filter
    #:structured-output-validate-fn
    #:strip-json-fences
    ;; Re-reading
    #:re-reading-filter
    ;; RAG
    #:retrieve
    #:qa-turn-filter
    ;; Tool-search
    #:search-tools
    #:keyword-tool-index
    #:make-keyword-tool-index
    #:tool-search-filter
    ;; Timeout
    #:timeout-filter
    ;; Approval
    #:approval-filter
    ;; Token-xform
    #:token-redact-filter
    #:hold-release-filter))
