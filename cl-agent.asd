;;;; cl-agent.asd
;;;; CL-Agent - Unified AI Agent Framework (Meta-System)
;;;;
;;;; Version: 8.0.0 (Spring AI 2.0 Architecture)
;;;; Author: David
;;;;
;;;; Overview:
;;;;   CL-Agent 元系统，聚合全部子系统。
;;;;   架构全面对标 Spring AI 2.0：ChatClient + Advisor 为核心编程模型，
;;;;   ChatModel 协议解耦多提供商实现。
;;;;
;;;; Architecture:
;;;;   Layer 1 - Core: cl-agent-core
;;;;     基础设施 + cl-agent.chat（消息/Prompt/ChatOptions/ChatResponse/
;;;;     deftool 工具体系/ChatModel/ChatMemory）
;;;;     + cl-agent.client（Advisor + ChatClient + chat 宏 DSL）
;;;;   Layer 2 - LLM: cl-agent-llm
;;;;     提供商实现（Anthropic/OpenAI/智谱/Ollama/DashScope/MiniMax...），
;;;;     实现 core 的 llm-chat SPI，经 provider-chat-model 适配为 ChatModel
;;;;
;;;; Usage:
;;;;   (asdf:load-system :cl-agent)
;;;;
;;;; Changelog:
;;;;   v8.0.0 - Spring AI 2.0 对标重构：删除 Process/Checkpoint/Kernel/
;;;;            SimpleAgent 体系（cl-agent-extra 移除），新增 ChatClient +
;;;;            Advisor + ChatModel + ChatMemory + deftool/defadvisor 宏
;;;;   v7.0.0 - 减法：删除 RAG / MCP / tools 子系统
;;;;   v6.0.0 - Core = infra + kernel + simpleagent; extras split out
;;;;   v5.0.0 - clj-agent architecture alignment
;;;;   v4.0.0 - Semantic Kernel architecture
;;;;   v3.0.0 - Initial modular design

(asdf:defsystem #:cl-agent
  :description "Unified AI Agent Framework - Meta System (Spring AI 2.0 style)"
  :author "David"
  :license "MIT"
  :version "8.0.0"

  ;; Meta-system contains no components, only declares dependencies
  :depends-on (;; Layer 1: Core (Infrastructure + Chat + Client)
               #:cl-agent-core

               ;; Layer 2: LLM (Provider implementations)
               #:cl-agent-llm)

  :in-order-to ((asdf:test-op (asdf:test-op #:cl-agent-test))))

;;;; ============================================================
;;;; Test System
;;;; ============================================================

(asdf:defsystem #:cl-agent-test
  :description "CL-Agent Complete Test Suite"
  :author "David"
  :license "MIT"
  :version "8.0.0"

  :depends-on (#:cl-agent
               #:cl-agent-mock
               #:fiveam)

  :serial t
  :components (;; Test suite setup
               (:file "tests/suite")

               ;; Core infrastructure tests
               (:file "tests/test-core")

               ;; Chat Model API tests
               (:file "tests/test-message")     ; 消息体系 + 中立互转
               (:file "tests/test-options")     ; ChatOptions 合并语义
               (:file "tests/test-tool")        ; deftool / ToolCallback / Manager
               (:file "tests/test-chat-model")  ; ChatModel + 工具执行循环
               (:file "tests/test-memory")      ; ChatMemory / Repository

               ;; ChatClient + Advisor tests
               (:file "tests/test-advisor")     ; Advisor 协议 / 链 / defadvisor
               (:file "tests/test-chat-client") ; ChatClient / chat 宏 / 集成
               (:file "tests/test-tool-advisor") ; ToolCallingAdvisor（2.0 工具循环）
               (:file "tests/test-tool-search")  ; 循环钩子 + 渐进式工具披露
               (:file "tests/test-parallel-tools") ; 并行工具执行

               ;; LLM provider tests
               (:file "tests/test-llm")
               (:file "tests/test-providers")  ; 新 provider / registry / 请求参数
               (:file "tests/test-streaming")) ; SSE 流式处理器

  :perform (asdf:test-op (op c)
             (uiop:symbol-call :fiveam :run! :cl-agent/tests)))
