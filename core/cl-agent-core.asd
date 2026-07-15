;;;; cl-agent-core.asd
;;;; CL-Agent Core - Infrastructure + Chat Model API + ChatClient/Advisor
;;;;
;;;; Version: 8.0.0
;;;; Author: David
;;;;
;;;; Overview:
;;;;   CL-Agent 核心模块，对标 Spring AI 2.0 的分层设计：
;;;;
;;;;   - 基础设施：条件系统、工具函数、HTTP 客户端（SSE 流式）
;;;;   - LLM Provider SPI：llm-chat 协议 + 统一 llm-response
;;;;   - cl-agent.chat（对标 org.springframework.ai.chat.*）：
;;;;     CLOS 消息体系 / Prompt / ChatOptions / ChatResponse /
;;;;     deftool 工具体系 / ChatModel 协议 / ChatMemory
;;;;   - cl-agent.kernel（Phase P1：Filter 机制 + Kernel 骨架）：
;;;;     Filter CLOS / build-chain / defilter / Kernel CLOS /
;;;;     三链请求/响应载体（不连接 ChatClient，P2 才接入）
;;;;   - cl-agent.client（对标 org.springframework.ai.chat.client.*）：
;;;;     Advisor 协议与洋葱链 / defadvisor 宏 / 内置 Advisor /
;;;;     ChatClient + Builder + chat 宏 DSL

(asdf:defsystem #:cl-agent-core
  :description "CL-Agent Core - Infrastructure + ChatClient/Advisor (Spring AI style, v8.0.0)"
  :author "David"
  :license "MIT"
  :version "8.0.0"

  :depends-on (#:alexandria
               #:serapeum
               #:cl-ppcre
               #:local-time
               #:log4cl
               #:uuid
               #:uiop
               #:com.inuoe.jzon
               #:lparallel
               #:bordeaux-threads
               #:closer-mop
               ;; HTTP module dependencies
               #:dexador            ; HTTP client
               #:quri               ; URL handling
               #:flexi-streams      ; Stream handling
               #:usocket)           ; Network sockets

  :serial t
  :components
  (;; ============================================================
   ;; Package Definitions
   ;; ============================================================
   (:file "package-core")

   ;; ============================================================
   ;; Core Infrastructure
   ;; ============================================================
   (:file "conditions")           ; Condition system
   (:file "macros")               ; Utility macros
   (:file "types")                ; Core data types
   ;; 注：曾有 documentation.lisp（「文档宏系统」：defsection /
   ;; defun-documented / defstruct-documented 等 11 个宏与函数）。
   ;; 11 个符号全部零使用，也没有任何文档生成器消费它们，而且其中
   ;; 两个从提交起就没工作过——defsection 的 lambda list 缺 &body body
   ;; 却在展开体里用 ,@body（macroexpand 即报 unbound BODY）；
   ;; defstruct-documented 的字符串形态漏了守卫（对字符串 getf）。
   ;; 无人调用 → 无人执行 → 无人发现。它们还都被 export 出去，
   ;; 照导出列表使用的人会直接撞上。已整体删除。
   ;; 文档请写在各自的 docstring 里，包导出用 defpackage 的 :export。
   (:file "utils")                ; Utility functions
   (:file "validation")           ; Data validation
   ;; DI container：独立设施，库内部不使用（protocols 也不用——此前这里
   ;; 注明「protocols 系统使用」是错的）。作为公开设施提供，
   ;; 用例见 examples/di-usage-examples.lisp。
   (:file "dependency-injection")
   (:file "data-convert")         ; Data conversion (plist <-> hash-table)
   (:file "json-schema")          ; JSON Schema 生成（工具参数规格 → schema）

   ;; ============================================================
   ;; LLM Provider SPI (in core for dependency management)
   ;; ============================================================
   (:module "llm"
    :components
    ((:file "response")           ; Unified LLM Response Schema
     (:file "provider")))         ; ILLMProvider protocol

   ;; ============================================================
   ;; Protocol Layer
   ;; ============================================================
   (:module "protocols"
    :components
    ((:file "protocols")))

   ;; ============================================================
   ;; HTTP Client
   ;; ============================================================
   (:module "http"
    :components
    ((:file "package-http")
     (:file "conditions")
     (:file "client")
     (:file "async")
     (:file "retry")
     (:file "streaming")))

   ;; ============================================================
   ;; Chat Model API（对标 Spring AI org.springframework.ai.chat.*）
   ;; ============================================================
   (:module "chat"
    :components
    ((:file "package")
     (:file "message")            ; CLOS 消息体系 + 中立 plist 互转
     (:file "options")            ; ChatOptions（合并语义）
     (:file "prompt")             ; Prompt
     (:file "response")           ; ChatResponse / Generation / 元数据
     (:file "tool")               ; deftool / ToolCallback / ToolCallingManager
     (:file "memory")             ; ChatMemory / Repository 协议
     (:file "model")))            ; ChatModel 协议 + Provider 适配器

   ;; ============================================================
   ;; Kernel + Filter（clj-agent kernel+filter 架构，全量对齐 Spring AI 2.0）
   ;; ============================================================
    (:module "kernel"
     :components
     ((:file "package")              ; cl-agent.kernel 包定义
      (:file "carriers")             ; 三链请求/响应载体
      (:file "filter")               ; filter CLOS 类 + build-chain + defilter
      (:file "kernel")               ; kernel CLOS 类 + build-kernel
      (:file "invoke")))             ; invoke-chat/tool/turn + run-tool-loop

   ;; ============================================================
   ;; ChatClient + Advisor（对标 org.springframework.ai.chat.client.*）
   ;; ============================================================
    (:module "client"
    :components
    ((:file "package")
     (:file "advisor")            ; Advisor 协议 + 洋葱链 + defadvisor
     (:file "advisors")           ; 内置 Advisor（日志/记忆/护栏）
     (:file "tool-advisor")       ; ToolCallingAdvisor（2.0 递归工具循环 + 钩子）
     (:file "tool-search-advisor") ; ToolSearch（渐进式工具披露）
     (:file "structured-output-advisor") ; StructuredOutputValidationAdvisor
     (:file "chat-client")))))    ; ChatClient + Builder + chat 宏

;; ============================================================
;; Changelog
;; ============================================================
;;
;; v8.2.0 —— Phase P1：Filter 机制 + Kernel 骨架（新增 cl-agent.kernel）：
;; - filter CLOS 类，四钩子槽（:tool/:chat/:turn/:token-xform）
;; - build-chain 洋葱折叠函数（reduce → 嵌套闭包），对标 clj-agent
;; - defilter 宏（对标 defadvisor，简化版）
;; - kernel CLOS 类（model/tools/filters/settings，无 memory）
;; - build-kernel 构造函数
;; - 三链请求/响应载体：tool-request/response、turn-request/result
;;   （chat 链复用现有 client-request/client-response，零修改现有代码）
;; - 纯加法，不接入 ChatClient——invoke-chat/invoke-tool/invoke-turn
;;   是 P2 的事
;;
;; v8.1.0 —— 全面对齐 Spring AI 2.0 的 Advisor 体系：
;; - 新增 structured-output-validation-advisor（对标
;;   StructuredOutputValidationAdvisor）：JSON Schema 校验 + 失败自我纠正重试；
;;   call-entity / (:call :entity schema) 可自动挂载
;; - 新增 JSON Schema 校验器（cl-agent.core:validate-json-schema /
;;   validate-json-text），支持 type/required/properties/items/enum/const/
;;   数值与字符串约束/allOf-anyOf-oneOf-not
;; - 移除 prompt-chat-memory-advisor：Spring AI 2.0 已移除
;;   PromptChatMemoryAdvisor（1.0 → 2.0 唯一被移除的 Advisor）
;; - tool-calling-advisor 补齐 conversation-history-enabled 开关、
;;   tool-advisor-next-instructions 钩子（对标
;;   doGetNextInstructionsForToolCall）、可插拔的 eligibility 判定
;;   （对标 ToolExecutionEligibilityChecker）
;; - tool-search-tool-calling-advisor 增加会话级索引（指纹判定 + LRU 淘汰）
;;   与 system-message-suffix（对标 systemMessageSuffix）
;; - message-chat-memory-advisor 对齐 Spring 语义：记忆前插 + 幂等检查 +
;;   system 置顶 + 只存最后一条 user/tool 消息
;; - simple-logger-advisor 支持可插拔的 request-to-string / response-to-string
;; - Advisor 排序改用具名常量（+chat-memory-advisor-order+ 等），
;;   并在 advisor.lisp 中说明与 Spring 默认布局的差异及理由
;;
;; v8.0.0:
;; - 全面对标 Spring AI 2.0：删除 Kernel/Filter/SimpleAgent 体系，
;;   新增 cl-agent.chat（消息/Prompt/ChatOptions/ChatResponse/
;;   deftool 工具体系/ChatModel/ChatMemory）与 cl-agent.client
;;   （Advisor 协议 + defadvisor + 内置 Advisor + ChatClient + chat 宏）
;; - Process 框架与 Checkpoint 存储体系随 cl-agent-extra 一并移除
;; - JSON Schema 工具函数（params->json-schema 等）上移至 cl-agent.core
;;
;; v6.x/v5.x/v4.x/v3.x: 见 git 历史（Semantic Kernel 时期）
