;;;; package.lisp
;;;; CL-Agent Client - 包定义
;;;;
;;;; 概述：
;;;;   对标 Spring AI 2.0 的 ChatClient API
;;;;   （org.springframework.ai.chat.client.*）：
;;;;
;;;;   - client-request / client-response：Advisor 链上流动的载体
;;;;     （对标 ChatClientRequest / ChatClientResponse）
;;;;   - Advisor 协议：advise-call / advise-stream + 有序洋葱链
;;;;     （对标 CallAdvisor / StreamAdvisor / AdvisorChain）
;;;;   - defadvisor 宏：一个表达式定义 Advisor 类 + 方法 + 构造函数
;;;;   - 内置 Advisor：日志 / 消息记忆 / 提示词记忆 / 安全护栏
;;;;   - chat-client + Builder + 请求 spec 流式 API + chat 宏 DSL
;;;;     （对标 ChatClient.builder() / client.prompt().user().call().content()）

(defpackage #:cl-agent.client
  (:use #:common-lisp #:cl-agent.chat)
  (:nicknames #:cla.client)
  (:import-from #:cl-agent.core
                #:json-parse
                #:log-debug
                #:log-info
                #:log-warn)
  (:export
   ;; ==================== 请求/响应载体 ====================
   #:client-request
   #:make-client-request
   #:client-request-prompt
   #:client-request-context
   #:client-request-copy
   #:client-response
   #:make-client-response
   #:client-response-chat-response
   #:client-response-context
   #:context-get
   #:context-set

   ;; ==================== Advisor 协议 ====================
   #:advisor
   #:advisor-name
   #:advisor-order
   #:advise-call
   #:advise-stream
   #:advisor-chain
   #:make-advisor-chain
   #:chain-next
   #:chain-next-stream
   #:defadvisor

   ;; ==================== 内置 Advisor ====================
   #:simple-logger-advisor
   #:make-simple-logger-advisor
   #:message-chat-memory-advisor
   #:make-message-chat-memory-advisor
   #:prompt-chat-memory-advisor
   #:make-prompt-chat-memory-advisor
   #:safe-guard-advisor
   #:make-safe-guard-advisor
   #:+conversation-id-key+

   ;; ==================== ToolCallingAdvisor（2.0 工具循环） ====================
   #:tool-calling-advisor
   #:make-tool-calling-advisor
   #:tool-advisor-manager
   #:tool-advisor-max-iterations
   #:+tool-calling-advisor-order+
   #:*tool-calling-manager*
   ;; 细粒度钩子（对标 doInitializeLoop/doBeforeCall/doAfterCall/doFinalizeLoop）
   #:tool-advisor-initialize-loop
   #:tool-advisor-before-call
   #:tool-advisor-after-call
   #:tool-advisor-finalize-loop

   ;; ==================== ToolSearchToolCallingAdvisor（渐进式披露） ====================
   #:tool-search-tool-calling-advisor
   #:make-tool-search-tool-calling-advisor
   #:tool-search-match-mode
   #:tool-search-max-results

   ;; ==================== ChatClient ====================
   #:chat-client
   #:make-chat-client
   #:chat-client-model
   ;; Builder
   #:chat-client-builder
   #:default-system
   #:default-options
   #:default-advisors
   #:default-tools
   #:build-client
   ;; 请求 spec（fluent API）
   #:chat-request-spec
   #:client-prompt
   #:prompt-system
   #:prompt-user
   #:prompt-add-messages
   #:prompt-with-options
   #:prompt-advisors
   #:prompt-tools
   #:prompt-context
   #:prompt-conversation
   ;; 终结操作
   #:call-client-response
   #:call-response
   #:call-content
   #:call-entity
   #:stream-content
   ;; DSL
   #:chat))
