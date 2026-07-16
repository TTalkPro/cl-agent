;;;; package.lisp
;;;; CL-Agent Chat - 包定义
;;;;
;;;; 概述：
;;;;   对标 Spring AI 2.0 的 Chat Model API（org.springframework.ai.chat.*）：
;;;;
;;;;   - 消息体系：message / system-message / user-message /
;;;;     assistant-message / tool-response-message（CLOS 类层次）
;;;;   - Prompt：prompt = 消息列表 + chat-options
;;;;   - ChatOptions：可移植的模型调用选项（含工具执行选项）
;;;;   - ChatResponse：chat-response / generation / 元数据
;;;;   - 工具体系：tool-definition / tool-callback / deftool 宏 /
;;;;     find-callback-for-call（对标 @Tool / ToolCallback）
;;;;     —— 只管「工具是什么」；执行循环在 cl-agent.kernel
;;;;   - ChatModel 协议：chat-model-call / chat-model-stream +
;;;;     provider-chat-model 适配器（**单次调用**：注入工具 schema 但
;;;;     不执行工具；循环见 cl-agent.kernel:run-tool-loop）
;;;;   - ChatMemory：chat-memory-repository 协议 +
;;;;     message-window-chat-memory（对标 ChatMemory/ChatMemoryRepository）
;;;;
;;;; 设计说明：
;;;;   不 :use cl-agent.core（其导出的 plist 风格 system-message 等
;;;;   与本包 CLOS 类同名），按需 :import-from。

(defpackage #:cl-agent.chat
  (:use #:common-lisp)
  (:nicknames #:cla.chat)
  (:import-from #:cl-agent.core
                ;; 动态绑定继承（与 cl-agent.http 共用同一份名单）
                #:*inherited-special-variables*
                #:with-inherited-specials
                #:capture-special-bindings
                #:with-captured-special-bindings
                ;; LLM Provider SPI
                #:llm-chat
                #:llm-chat-stream
                #:provider-supports-streaming-p
                ;; 统一响应对象
                #:llm-response
                #:llm-response-content
                #:llm-response-tool-calls
                #:llm-response-usage
                #:llm-response-model
                #:llm-response-finish-reason
                #:llm-response-reasoning
                #:llm-response-reasoning-blocks
                #:llm-response-message-id
                #:llm-response-raw
                #:llm-tool-call-id
                #:llm-tool-call-name
                #:llm-tool-call-arguments
                #:llm-usage
                #:llm-usage-input-tokens
                #:llm-usage-output-tokens
                #:llm-usage-total-tokens
                ;; 工具函数
                #:json-parse
                #:json-stringify
                #:generate-uuid
                #:params->json-schema
                #:log-debug
                #:log-info
                #:log-warn)
  (:export
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
   ;; 工具执行循环唯一住在 cl-agent.kernel:run-tool-loop，执行策略见
   ;; cl-agent.kernel 的 sequential/virtual-thread/thread-pool 三个 manager。
   ;; *inherited-special-variables* / with-inherited-specials 属于
   ;; cl-agent.core（见 core/utils.lisp），需要时从那里取。
   #:arguments->plist
   ;; 条件
   #:tool-execution-error
   #:tool-not-found-error

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
   #:+default-conversation-id+))
