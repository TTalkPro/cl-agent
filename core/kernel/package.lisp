;;;; package.lisp
;;;; CL-Agent Kernel - 包定义
;;;;
;;;; 概述：
;;;;
;;;;   cl-agent 的唯一执行路径与调用方入口（对标 clj-agent 的 kernel+filter
;;;;   架构）。Spring AI 的两个移植层——Advisor 与 ChatClient——都已退役。
;;;;
;;;;   关键抽象：
;;;;   - filter         CLOS 类，四个钩子槽（:tool/:chat/:turn/:token-xform）
;;;;   - build-chain    洋葱折叠函数（reduce → 嵌套闭包）
;;;;   - defilter       宏：定义 filter 类 + 构造函数
;;;;   - kernel         CLOS 类（model/tools/filters/settings/tool-manager +
;;;;                    默认 system/options，无 memory）
;;;;   - build-kernel   构造函数（装配）
;;;;   - invoke-chat/tool/turn + run-tool-loop（执行）
;;;;   - chat 宏 / kernel-chat*（调用方入口）
;;;;   - 载体类         tool-request/tool-result、turn-request/turn-result
;;;;                    （chat 链不用专门载体：请求是 prompt，响应是
;;;;                     chat-response）
;;;;
;;;; 设计要点：
;;;;   1. 注册顺序 = 执行顺序：靠前的 filter 在最外层，reverse + reduce
;;;;      实现洋葱折叠。
;;;;   2. filter 不需要 order 字段：层级完全由 :filters 列表中的位置决定。
;;;;   3. 钩子是普通函数：filter 的 :chat/:tool/:turn 槽存 (req chain) → resp。
;;;;   4. 闭包天然"仅下游"：build-chain 折叠出的 chain 参数只含更内层
;;;;      filter，递归重入无需特殊 API（validation-turn-filter 的自纠即此）。
;;;;   5. kernel 不认识 memory：记忆是 memory-filter 的事。
;;;;
;;;; 命名：tool 链的载体叫 tool-request / tool-result（与 turn 链的
;;;; turn-request / turn-result 对称）。它曾叫 tool-response，与
;;;; cl-agent.chat:tool-response（协议消息层的值对象）撞名——两者分属
;;;; 不同层，撞名纯属巧合。
;;;;
;;;; 该撞名连同 execute-tool-calls（chat 的旧 ToolCallingManager 已删除）
;;;; 一并消除后，本包不再需要任何 :shadow，下游也就不用为了同时
;;;; :use 两个包而自己写 shadowing-import。

(defpackage #:cl-agent.kernel
  (:use #:common-lisp #:cl-agent.chat)
  (:nicknames #:cla.kernel)
  ;; 无 :shadow —— 与 cl-agent.chat 已无同名导出，下游可放心
  ;; (:use :cl-agent.chat :cl-agent.kernel) 而不必自己写 shadowing-import。
  (:import-from #:cl-agent.core
                #:json-parse
                #:log-debug
                #:log-info
                #:log-warn)
  (:export
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
    #:default-tool-calling-manager

    ;; ==================== Invoke 原语 ====================
    #:invoke-chat
    #:invoke-tool
    #:invoke-tool-batch
    #:invoke-turn
    #:run-tool-loop

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
