;;;; package-llm.lisp
;;;; CL-Agent - LLM 服务包定义
;;;;
;;;; 概述：
;;;;   定义 LLM 服务相关的包
;;;;
;;;; 包结构：
;;;;   - cl-agent.llm: LLM 客户端和工具
;;;;   - cl-agent.llm.providers: LLM 提供商实现
;;;;
;;;; 设计说明：
;;;;   - 错误条件从 cl-agent.core 重导出
;;;;   - 提供统一的 LLM 接口
;;;;   - 支持多个提供商（Anthropic、OpenAI、Ollama、智谱 AI）

;;; ============================================================
;;; LLM 主包
;;; ============================================================

(defpackage #:cl-agent.llm
  (:use #:common-lisp
        #:cl-agent.core)
  (:import-from #:cl-agent.kernel #:llm-chat)
  (:nicknames #:cla.llm #:llm)
  (:export
   ;; ==================== 客户端 ====================
   ;; 客户端结构和访问器
   #:client
   #:make-client
   #:client-provider
   #:client-api-key
   #:client-model
   #:client-base-url
   #:client-max-tokens
   #:client-temperature
   #:client-provider-name
   #:client-model-name

   ;; ==================== 提供商类 ====================
   ;; 基类
   #:base-provider
   #:base-provider-name
   #:base-provider-api-url
   #:base-provider-default-model
   #:base-provider-chat-endpoint
   #:base-provider-stream-endpoint
   #:base-provider-timeout

   ;; 提供商工厂
   #:make-provider
   #:make-anthropic-provider
   #:make-openai-provider
   #:make-ollama-provider
   #:make-zhipu-provider
   #:make-dashscope-provider
   #:make-bailian-provider
   #:make-qwen-provider

   ;; 提供商访问器（统一接口）
   ;; provider-name 使用 cl-agent.core 的泛型函数
   #:provider-api-url
   #:provider-default-model
   #:provider-chat-endpoint
   #:provider-stream-endpoint
   #:provider-timeout


   ;; ==================== Service Layer (响应标准化) ====================
   ;; 归一化（单一来源：provider 自身产出 llm-response，
   ;; usage/finish-reason 别名归一在 cl-agent.core）
   #:ensure-llm-response
   #:normalize-response
   #:chat-with-normalization
   #:normalize-usage            ; 重导出 cl-agent.core:normalize-usage
   ;; llm-response 工具函数
   #:response-reasoning-content
   #:response-complete-p

   ;; ==================== 聊天 API ====================
   ;; 核心 API
   #:chat
   #:chat-simple
   #:chat-with-tools
   #:chat-multi-turn
   #:batch-chat

   ;; 泛型函数
   #:llm-chat
   #:llm-stream
   #:llm-available-p
   #:llm-provider-name
   #:llm-default-model

   ;; ==================== 流式处理 ====================
   ;; 流式聊天
   #:chat-stream
   #:chat-stream-simple
   #:chat-stream-to-string
   #:chat-stream-to-file

   ;; 流式迭代器
   #:stream-iterator
   #:chat-stream-iterator
   #:stream-next
   #:stream-has-more-p

   ;; 流式上下文
   #:stream-context
   #:make-stream-context

   ;; ==================== Token 计算 ====================
   #:count-tokens
   #:count-tokens-for-client
   #:estimate-cost

   ;; ==================== 全局配置 ====================
   #:*anthropic-api-url*
   #:*openai-api-url*
   #:*ollama-api-url*
   #:*zhipu-api-url*
   #:*default-anthropic-model*
   #:*default-openai-model*
   #:*default-ollama-model*
   #:*default-zhipu-model*

   ;; ==================== 工具函数 ====================
   ;; HTTP 和 JSON
   #:make-http-request
   #:parse-json-response
   #:build-api-url
   #:build-headers
   #:build-provider-url
   #:provider-headers

   ;; 消息转换
   #:convert-message-to-provider
   #:convert-messages-to-provider
   #:convert-tools-to-provider
   #:normalize-messages

   ;; 请求/响应
   #:build-chat-request-body
   #:parse-chat-response

   ;; ==================== Schema Converters ====================
   ;; OpenAI format
   #:convert-tool-to-openai
   #:convert-tools-to-openai
   #:parse-openai-tool-calls
   #:convert-message-to-openai
   #:convert-messages-to-openai

   ;; Anthropic format
   #:convert-tool-to-anthropic
   #:convert-tools-to-anthropic-format
   #:parse-anthropic-tool-calls
   #:convert-message-to-anthropic
   #:convert-messages-to-anthropic

   ;; ==================== Unified Response Schema ====================
   ;; Response class
   #:llm-response
   #:make-llm-response
   #:llm-response-p
   #:llm-response-content
   #:llm-response-tool-calls
   #:llm-response-usage
   #:llm-response-model
   #:llm-response-finish-reason
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

   ;; ==================== Provider Registry ====================
   #:register-provider
   #:get-provider-factory
   #:list-providers
   #:provider-registered-p
   #:create-provider
   #:register-provider-alias
   #:resolve-provider-name

   ;; ==================== Provider Configuration ====================
   #:*default-provider-config*
   #:get-provider-config
   #:get-config-value
   #:load-api-key-from-env
   #:load-provider-config-from-env
   #:validate-provider-config
   #:build-provider-config

   ;; ==================== Provider Builder ====================
   #:provider-builder
   #:create-provider-builder
   #:for-provider
   #:with-api-key
   #:with-api-url
   #:with-model
   #:with-max-tokens
   #:with-temperature
   #:builder-with-timeout
   #:with-extra-config
   #:build-provider

   ;; ==================== Service Creation ====================
   #:create-service
   #:create-service-from-builder
   #:make-anthropic-service
   #:make-openai-service
   #:make-zhipu-service
   #:make-mock-service))

;;; ============================================================
;;; LLM 提供商包
;;; ============================================================

(defpackage #:cl-agent.llm.providers
  (:use #:common-lisp
        #:cl-agent.core)
  (:nicknames #:cla.llm.providers)
  (:export
   ;; ==================== Anthropic 提供商 ====================
   #:anthropic-provider
   #:make-anthropic-provider
   #:anthropic-provider-api-key
   #:anthropic-provider-version
   #:anthropic-model-context-window
   #:anthropic-model-max-output

   ;; ==================== OpenAI 兼容基座 ====================
   #:openai-compat-provider
   #:define-openai-compat-provider
   #:provider-auth-headers
   #:provider-finalize-request
   #:parse-openai-compat-response
   #:provider-api-key

   ;; ==================== OpenAI 提供商 ====================
   #:openai-provider
   #:make-openai-provider

   ;; ==================== Ollama 提供商 ====================
   #:ollama-provider
   #:make-ollama-provider

   ;; ==================== 智谱 AI 提供商 ====================
   #:zhipu-provider
   #:make-zhipu-provider
   #:extract-reasoning-content
   #:response-complete-p
   #:get-suggested-max-tokens

   ;; ==================== 阿里云百炼 DashScope 提供商 ====================
   #:dashscope-provider
   #:make-dashscope-provider
   #:make-bailian-provider
   #:make-qwen-provider
   #:dashscope-list-models))
