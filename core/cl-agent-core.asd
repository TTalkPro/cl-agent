;;;; cl-agent-core.asd
;;;; CL-Agent Core - 框架本体（单包）
;;;;
;;;; Version: 10.0.0
;;;; Author: David
;;;;
;;;; Overview:
;;;;   CL-Agent 框架本体，全部装在**单一包 cl-agent.core** 里：
;;;;
;;;;   - 基础设施：条件系统、宏、工具函数、数据转换、JSON Schema 生成与校验
;;;;   - HTTP 客户端 + SSE 流式 + 重试
;;;;   - LLM Provider SPI：llm-chat 协议 + 统一 llm-response
;;;;   - Chat Model API：CLOS 消息体系 / Prompt / ChatOptions / ChatResponse /
;;;;     deftool 工具体系 / ChatModel 协议 / ChatMemory
;;;;   - Kernel + Filter（唯一执行路径）：Filter 三链 / build-chain / defilter /
;;;;     Kernel / build-kernel / invoke-chat|tool|turn / run-tool-loop /
;;;;     ToolCallingManager / 10 个内置 filter / chat 宏 DSL
;;;;
;;;; v10.0.0 包合并：cl-agent.http / cl-agent.chat / cl-agent.kernel 三个包
;;;; 并入 cl-agent.core，对齐 clj-agent 的 core/provider/client 三模块分层。
;;;; 合并前先清掉了三处死代码，否则会正面撞名：
;;;;   - types.lisp 整个文件（34 个零调用符号，与 chat 的 CLOS 消息体系撞 11 个）
;;;;   - core 的 build-url（零调用，与 http 的活实现撞名）
;;;;   - core 的 with-retry（零使用，与 http 的活实现撞名）
;;;;
;;;; v9.0.0 移除了 cl-agent.client（Spring AI 的 ChatClient + Builder +
;;;; fluent RequestSpec 移植）。该名字在 v10 被复用为 SimpleAgent 层。

(asdf:defsystem #:cl-agent-core
  :description "CL-Agent Core - 框架本体（基础设施 + HTTP + Chat API + Kernel/Filter）"
  :author "David"
  :license "MIT"
  :version "10.0.0"

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
   ;; 注：曾有 types.lisp（旧消息/ToolCall/Response/Usage/InvokeResult
   ;; + 5 个从未实现的 plugin-* defgeneric，共 34 个符号）。SBCL 调用图
   ;; 显示全部零调用——只有文件内部的自闭环，没有外部入口。它与
   ;; cl-agent.chat 在用的 CLOS 消息体系有 11 个同名符号，是合并的正面
   ;; 障碍。已整体删除。
   ;; 注：曾有 documentation.lisp（「文档宏系统」：defsection /
   ;; defun-documented / defstruct-documented 等 11 个宏与函数）。
   ;; 11 个符号全部零使用，也没有任何文档生成器消费它们，而且其中
   ;; 两个从提交起就没工作过——defsection 的 lambda list 缺 &body body
   ;; 却在展开体里用 ,@body（macroexpand 即报 unbound BODY）；
   ;; defstruct-documented 的字符串形态漏了守卫（对字符串 getf）。
   ;; 无人调用 → 无人执行 → 无人发现。它们还都被 export 出去，
   ;; 照导出列表使用的人会直接撞上。已整体删除。
   ;; 文档请写在各自的 docstring 里，包导出用 defpackage 的 :export。
   (:file "utils")                ; 工具函数 + ID 生成器/时间戳提供者
   ;; 注：曾有独立的 cl-agent.core.protocols 包（core/protocols/protocols.lisp），
   ;; 统共只导出 make-standard-id-generator / make-standard-timestamp-provider
   ;; 两个符号，却占着 `protocols` 这个极宽泛的昵称，还容易与 protocols/
   ;; 子系统（A2A，另一回事）混淆。它排在 utils 之后加载，逼得 utils 里的
   ;; 默认实现只能用 find-package + find-symbol 动态查找绕开加载顺序。
   ;; 已并入 utils.lisp，那层间接随之消失。
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
   ;; HTTP Client
   ;; ============================================================
   (:module "http"
    :components
    ((:file "conditions")
     (:file "client")
     (:file "async")
     (:file "retry")
     (:file "streaming")))

   ;; ============================================================
   ;; Chat Model API（对标 Spring AI org.springframework.ai.chat.*）
   ;; ============================================================
   (:module "chat"
    :components
    ((:file "message")            ; CLOS 消息体系 + 中立 plist 互转
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
      ((:file "carriers")             ; 三链请求/响应载体
       (:file "filter")               ; filter CLOS 类 + build-chain + defilter
       (:file "kernel")               ; kernel CLOS 类 + build-kernel
      (:file "conditions")           ; 工具故障分类条件体系
      (:file "batch")                ; 批量工具执行（并行/:serial/故障路由）
      (:file "tool-calling-manager") ; ToolCallingManager 协议 + 多实现
      (:file "invoke")               ; invoke-chat/tool/turn + run-tool-loop
       ;; 内置 filter（P4）
       (:module "filters"
        :components
        ((:file "memory")             ; memory-filter (:chat, 循环内首位)
         (:file "logging")            ; logging-chat/tool-filter
         (:file "safeguard")          ; safeguard-turn-filter (:turn)
         (:file "validation")         ; validation-turn-filter + structured-output
         (:file "re-reading")         ; re-reading-filter (:turn)
         (:file "rag")                ; qa-turn-filter (:turn) + IRetriever
         (:file "tool-search")        ; tool-search-filter (:chat) + IToolIndex
         (:file "timeout")            ; timeout-filter (:tool)
         (:file "approval")           ; approval-filter (:tool)
         (:file "token-xform")))     ; token-redact/hold-release (:token-xform)
       ;; chat 宏排在 filters 之后：kernel-chat-entity 用 filters/validation
       ;; 里定义的 strip-json-fences。
       (:file "chat")))))           ; chat 宏 DSL + kernel-chat* 调用方入口

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
