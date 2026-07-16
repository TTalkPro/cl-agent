;;;; cl-agent.asd
;;;; CL-Agent - Unified AI Agent Framework (Meta-System)
;;;;
;;;; Version: 9.0.0 (Kernel + Filter Architecture)
;;;; Author: David
;;;;
;;;; Overview:
;;;;   CL-Agent 元系统，聚合全部子系统。
;;;;   核心编程模型：Kernel + Filter 三链；ChatModel 协议解耦多提供商实现。
;;;;
;;;; Architecture:
;;;;   Layer 1 - Core: cl-agent-core
;;;;     基础设施 + cl-agent.chat（消息/Prompt/ChatOptions/ChatResponse/
;;;;     deftool 工具体系/ChatModel/ChatMemory）
;;;;     + cl-agent.kernel（Filter 三链 + Kernel + invoke-* +
;;;;       run-tool-loop + 10 个内置 filter + chat 宏 DSL）
;;;;   Layer 2 - LLM: cl-agent-llm
;;;;     提供商实现（Anthropic/OpenAI/智谱/Ollama/DashScope/MiniMax...），
;;;;     实现 core 的 llm-chat SPI，经 provider-chat-model 适配为 ChatModel
;;;;
;;;; Usage:
;;;;   (asdf:load-system :cl-agent)
;;;;
;;;; Changelog:
;;;;   v9.0.0 - 移除 cl-agent.client（Spring AI 的 ChatClient + Builder +
;;;;            fluent RequestSpec 移植）；chat 宏搬入 cl-agent.kernel。
;;;;            至此 Spring AI 的两大移植层（Advisor、ChatClient）全部退役，
;;;;            kernel+filter 成为唯一编程模型。
;;;;   v8.0.0 - Spring AI 2.0 对标重构：删除 Process/Checkpoint/Kernel/
;;;;            SimpleAgent 体系（cl-agent-extra 移除），新增 ChatClient +
;;;;            Advisor + ChatModel + ChatMemory + deftool/defadvisor 宏
;;;;   v7.0.0 - 减法：删除 RAG / MCP / tools 子系统
;;;;   v6.0.0 - Core = infra + kernel + simpleagent; extras split out
;;;;   v5.0.0 - clj-agent architecture alignment
;;;;   v4.0.0 - Semantic Kernel architecture
;;;;   v3.0.0 - Initial modular design

(asdf:defsystem #:cl-agent
  :description "Unified AI Agent Framework - Meta System (Kernel + Filter)"
  :author "David"
  :license "MIT"
  :version "9.0.0"

  ;; Meta-system contains no components, only declares dependencies
  :depends-on (;; Layer 1: Core (Infrastructure + Chat + Kernel)
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
  :version "9.0.0"

  :depends-on (#:cl-agent
               #:cl-agent-mock
               #:fiveam)

  :serial t
  :components (;; Test suite setup
               (:file "tests/suite")

               ;; Core infrastructure tests
               (:file "tests/test-core")
               (:file "tests/test-json-schema") ; JSON Schema 校验器
               (:file "tests/test-http-async")  ; 异步 HTTP + 动态绑定继承

               ;; Chat Model API tests
               (:file "tests/test-message")     ; 消息体系 + 中立互转
               (:file "tests/test-options")     ; ChatOptions 合并语义
               (:file "tests/test-tool")        ; deftool / ToolCallback / Manager
               (:file "tests/test-chat-model")  ; ChatModel + 工具执行循环
               (:file "tests/test-memory")      ; ChatMemory / Repository

               ;; Kernel + Filter 测试
               (:file "tests/test-filter")          ; filter 机制 + build-chain
               (:file "tests/test-kernel-skeleton") ; kernel 骨架 + 载体
               (:file "tests/test-kernel-invoke")   ; invoke 原语 + 工具循环
               (:file "tests/test-spring-ai-alignment") ; P5 对齐审计

               ;; kernel chat 宏 DSL + 端到端集成
               ;; （前身 test-chat-client：Builder / fluent spec 随
               ;;   cl-agent.client 一并退役）
               (:file "tests/test-kernel-chat")

               ;; LLM provider tests
               (:file "tests/test-llm")
               (:file "tests/test-providers")  ; 新 provider / registry / 请求参数
               (:file "tests/test-streaming")  ; SSE 流式处理器
               ;; 复用 test-streaming 的事件驱动 harness，须排其后
               (:file "tests/test-thinking-roundtrip")) ; 思考块回传 + SPI 契约

  :perform (asdf:test-op (op c)
             (uiop:symbol-call :fiveam :run! :cl-agent/tests)))
