;;;; package-llm.lisp
;;;; CL-Agent - LLM 服务包定义
;;;;
;;;; 概述：
;;;;   定义 LLM 服务相关的包
;;;;
;;;; 包结构：
;;;;   - cl-agent/llm: LLM 客户端和工具
;;;;   - cl-agent/llm/providers: LLM 提供商实现
;;;;
;;;; 设计说明：
;;;;   - 错误条件从 cl-agent/core 重导出
;;;;   - 提供统一的 LLM 接口
;;;;   - 支持多个提供商（Anthropic、OpenAI、Ollama、智谱 AI）


;;; 定义顺序说明：
;;;   cl-agent/llm/providers 必须先于 cl-agent/llm 定义——主包用
;;;   :import-from 引入 providers 的 make-*-provider / response-complete-p
;;;   再导出，而 :import-from 要求源包在求值时已存在。
;;;   两个包之间没有 :use 关系，所以这个顺序是安全的。
;;; ============================================================
;;; LLM 提供商包
;;; ============================================================

(defpackage #:cl-agent/llm/providers
  (:use #:common-lisp
        #:cl-agent/core)
  (:nicknames #:cla/llm/providers)
  (:export
   ;; ==================== Anthropic 提供商 ====================
   #:anthropic-provider
   #:make-anthropic-provider
   #:anthropic-provider-api-key
   #:anthropic-provider-version
   #:build-anthropic-headers
   #:anthropic-model-context-window
   #:anthropic-model-max-output

   ;; ==================== OpenAI 兼容基座 ====================
   #:openai-compat-provider
   #:define-openai-compat-provider
   #:provider-auth-headers
   #:provider-request-headers
   #:provider-finalize-request
   #:parse-openai-compat-response
   #:provider-api-key
   #:provider-extra-headers
   #:merge-header-alists
   ;; 厂商专有参数的构造助手（<vendor>-extra-params 用它做取值校验）
   #:enum->wire
   #:wire-hash

   ;; ==================== OpenAI 提供商 ====================
   #:openai-provider
   #:make-openai-provider

   ;; ==================== Ollama 提供商 ====================
   #:ollama-provider
   #:make-ollama-provider

   ;; ==================== MiniMax 提供商 ====================
   #:minimax-provider
   #:make-minimax-provider
   ;; 扩展思考（Anthropic 系）
   #:thinking->anthropic
   #:invalid-thinking-config-error
   #:split-think-block

   ;; ==================== DeepSeek 提供商 ====================
   #:deepseek-provider
   #:make-deepseek-provider
   #:deepseek-prefix-chat
   #:mark-prefix
   #:+deepseek-beta-base-url+

   ;; ==================== Gemini 提供商 ====================
   #:gemini-provider
   #:make-gemini-provider

   ;; ==================== Mistral 提供商 ====================
   #:mistral-provider
   #:make-mistral-provider

   ;; ==================== 智谱 AI 提供商 ====================
   #:zhipu-provider
   #:make-zhipu-provider
   #:extract-reasoning-content
   #:response-complete-p
   #:get-suggested-max-tokens

   ;; ==================== xAI Grok 提供商 ====================
   #:xai-provider
   #:make-xai-provider
   #:xai-extra-params
   #:+xai-reasoning-efforts+
   #:+xai-search-modes+
   #:+xai-source-types+

   ;; ==================== Moonshot（Kimi）提供商 ====================
   #:moonshot-provider
   #:make-moonshot-provider
   #:moonshot-extra-params
   #:+moonshot-thinking-types+
   #:+moonshot-reasoning-efforts+
   #:+moonshot-reasoning-histories+

   ;; ==================== SiliconFlow（硅基流动）提供商 ====================
   #:siliconflow-provider
   #:make-siliconflow-provider
   #:siliconflow-extra-params

   ;; ==================== OpenRouter 聚合网关 ====================
   #:openrouter-provider
   #:make-openrouter-provider
   #:make-openrouter-provider-with-attribution
   #:openrouter-extra-params
   #:+openrouter-data-collections+
   #:+openrouter-sort-strategies+

   ;; ==================== 阿里云 DashScope 提供商 ====================
   #:dashscope-provider
   #:make-dashscope-provider
   #:dashscope-list-models))


;;; ============================================================
;;; LLM 主包
;;; ============================================================

(defpackage #:cl-agent/llm
  (:use #:common-lisp
        #:cl-agent/core)
  (:nicknames #:cla/llm)
  ;; 注：本包曾 (:shadow #:chat)——低层 client 函数与 cl-agent/core 的
  ;; chat 宏（chat-client 声明式 DSL）同名。shadow 是给读者埋雷（同一个名字
  ;; 在不同包里一个是宏一个是函数），函数已改名 client-chat，shadow 随之
  ;; 消失。全库不再 shadow 任何符号。
  ;; 门面层：这些符号的实现属于 cl-agent/llm/providers，此处引入*同一符号*
  ;; 再导出，而不是在本包另立同名符号。
  ;;
  ;; 此前是后者：两个包各自导出一套独立的同名符号，后果有三——
  ;;   1. 用户包一旦 (:use :cl-agent/llm :cl-agent/llm/providers) 就撞 6 个
  ;;      name conflict，而这两个包本是「门面 + 实现」，理应能一起 use；
  ;;   2. make-dashscope-provider 在本包只有导出、没有对应的委托定义，
  ;;      调用直接 UNDEFINED-FUNCTION——导出了一个不存在的函数；
  ;;   3. response-complete-p 两处实现语义分叉（本包那份不接受旧式 plist）。
  ;; 改为 :import-from 后，三者同时消失，且新增 provider 无需再手工同步。
  (:import-from #:cl-agent/llm/providers
                #:make-anthropic-provider
                #:make-openai-provider
                #:make-ollama-provider
                #:make-zhipu-provider
                #:make-dashscope-provider
                #:make-minimax-provider
                #:make-deepseek-provider
                #:make-gemini-provider
                #:make-mistral-provider
                #:make-xai-provider
                #:make-moonshot-provider
                #:make-siliconflow-provider
                #:make-openrouter-provider
                ;; 厂商专有参数构造器（门面层同一符号）
                #:xai-extra-params
                #:moonshot-extra-params
                #:siliconflow-extra-params
                #:openrouter-extra-params
                #:response-complete-p)
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

   ;; 提供商工厂（门面：符号本体来自 cl-agent/llm/providers）
   #:make-provider
   #:make-anthropic-provider
   #:make-openai-provider
   #:make-ollama-provider
   #:make-zhipu-provider
   #:make-dashscope-provider
   #:make-minimax-provider
   #:make-deepseek-provider
   #:make-gemini-provider
   #:make-mistral-provider
   #:make-xai-provider
   #:make-moonshot-provider
   #:make-siliconflow-provider
   #:make-openrouter-provider
   ;; 厂商专有参数构造器（校验取值后产出 :extra-params plist）
   #:xai-extra-params
   #:moonshot-extra-params
   #:siliconflow-extra-params
   #:openrouter-extra-params

   ;; 提供商访问器（统一接口）
   ;; provider-name 使用 cl-agent/core 的泛型函数
   #:provider-api-url
   #:provider-default-model
   #:provider-chat-endpoint
   #:provider-stream-endpoint
   #:provider-timeout


   ;; ==================== ChatModel Layer (响应标准化) ====================
   ;; 归一化（单一来源：provider 自身产出 llm-response，
   ;; usage/finish-reason 别名归一在 cl-agent/core）
   #:ensure-llm-response
   #:normalize-response
   #:chat-with-normalization
   #:normalize-usage            ; 重导出 cl-agent/core:normalize-usage
   ;; llm-response 工具函数
   #:response-reasoning-content
   #:response-complete-p

   ;; ==================== 聊天 API ====================
   ;; 核心 API
   #:client-chat
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

   ;; 流式上下文
   #:stream-context
   #:make-stream-context

   ;; ==================== 嵌入向量 ====================
   ;; SPI 与统一响应定义在 cl-agent/core（core/llm/embedding.lisp），
   ;; 这里是 OpenAI 兼容实现 + 面向应用的便捷函数
   #:llm-embed
   #:embed
   #:embed-batch
   #:embed-response
   #:cosine-similarity
   #:provider-embedding-endpoint
   #:provider-default-embedding-model
   #:provider-supports-embedding-p
   #:build-embedding-request
   #:parse-embedding-response
   ;; embedding-response 访问器（重导出 cl-agent/core）
   #:embedding-response
   #:make-embedding-response
   #:embedding-response-p
   #:embedding-response-embeddings
   #:embedding-response-model
   #:embedding-response-usage
   #:embedding-response-raw
   #:embedding-response-first
   #:embedding-dimensions

   ;; ==================== Token 计算 ====================
   #:count-tokens
   #:count-tokens-for-client
   #:estimate-cost
   #:*provider-pricing*

   ;; 注：曾在此导出 *anthropic-api-url* / *default-anthropic-model* 一类
   ;; 全局配置变量，但无人读取且已过时——端点与默认模型由各
   ;; make-*-provider 自行持有。已删除。

   ;; ==================== 工具函数 ====================
   ;; HTTP 和 JSON
   #:make-http-request
   #:parse-json-response
   #:build-api-url
   #:provider-headers
   ;; 厂商错误体归一（llm-error 的 message 由它填充）
   #:extract-api-error-message

   ;; 消息转换
   #:convert-message-to-provider
   #:convert-messages-to-provider
   #:convert-tools-to-provider
   #:normalize-messages

   ;; 请求/响应
   #:build-chat-request-body
   #:parse-chat-response

   ;; ==================== Schema Converters ====================
   ;; 消息/工具的 wire 格式转换器不在此导出：它们是 cl-agent/llm/providers
   ;; 的内部实现（convert-messages-for-openai / parse-messages-for-anthropic
   ;; 等），随各 provider 的 API 演进，不作为公开 API。

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
   ;; 思维链：reasoning 是展示用文本；reasoning-blocks 是 provider 原生块
   ;; （含签名），只用于后续轮次原样回传
   #:llm-response-reasoning
   #:llm-response-reasoning-blocks
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
   #:unregister-provider
   #:get-provider-factory
   #:list-providers
   #:provider-registered-p
   #:create-provider
   #:register-provider-alias
   #:resolve-provider-name
   #:+builtin-provider-factories+

   ;; 注：曾在此导出 factory/config.lisp 的一组 provider 配置函数，
   ;; 但那是个自封闭的死岛（registry/builder/providers 均不调用），
   ;; API key 实际由各 make-*-provider 读自家环境变量。整个文件已删除。

   ;; 注：曾在此导出 Provider Builder（provider-builder 类 +
   ;; create-provider-builder + 8 个 fluent 泛型 + build-provider +
   ;; create-chat-model-from-builder）。Builder/fluent 链是 Java 表达习惯，
   ;; 与已退役的 ChatClient Builder 同一模式，且全库零真实消费者；
   ;; create-chat-model 的关键字参数覆盖全部场景。整体删除。

   ;; ==================== ChatModel 桥接 ====================
   #:create-chat-model))
