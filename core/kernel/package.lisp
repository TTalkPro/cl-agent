;;;; package.lisp
;;;; CL-Agent Kernel - 包定义
;;;;
;;;; 概述（Phase P1：Filter 机制 + Kernel 骨架）：
;;;;
;;;;   对标 clj-agent 的 advisor→kernel+filter 架构重构。当前阶段只落地
;;;;   三链（chat / tool / turn）的 Filter 机制与 Kernel 骨架，不接入
;;;;   真实 LLM 调用；ChatClient/Advisor 仍走原 advisor 链，零影响。
;;;;
;;;;   关键抽象：
;;;;   - filter         CLOS 类，四个钩子槽（:tool/:chat/:turn/:token-xform）
;;;;   - build-chain    洋葱折叠函数（reduce → 嵌套闭包），对标 clj-agent
;;;;   - defilter       宏，对标 defadvisor：定义 filter 类 + 构造函数
;;;;   - kernel         CLOS 类（model / tools / filters / settings，无 memory）
;;;;   - build-kernel   构造函数
;;;;   - 载体类         tool-request/response、turn-request/result（chat 链
;;;;                    复用现有的 client-request/client-response）
;;;;
;;;; 设计要点：
;;;;   1. 注册顺序 = 执行顺序：靠前的 filter 在最外层，reverse + reduce
;;;;      实现洋葱折叠。
;;;;   2. filter 不需要 order 字段：层级完全由 :filters 列表中的位置决定。
;;;;   3. 钩子是普通函数：filter 的 :chat/:tool/:turn 槽存 (req chain) → resp。
;;;;   4. 闭包天然"仅下游"：build-chain 折叠出的 chain 参数只含更内层
;;;;      filter，递归重入无需特殊 API。
;;;;   5. kernel 极简：只存 model/tools/filters/settings，不认识 memory、
;;;;      不认识循环（invoke 是 P2 的事）。

(defpackage #:cl-agent.kernel
  (:use #:common-lisp #:cl-agent.chat)
  (:nicknames #:cla.kernel)
  ;; 屏蔽 cl-agent.chat 导出的同名符号：
  ;; - make-tool-response：chat 的语义是"工具响应消息"（id/name/text），
  ;;   kernel 的语义是"工具链响应载体"（result/writes/error）
  ;; - tool-response：同理，两个不同的类，必须 shadow 避免覆盖
  (:shadow #:make-tool-response #:tool-response)
  (:import-from #:cl-agent.core
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
   #:tool-response
   #:make-tool-response
   #:tool-response-result
   #:tool-response-writes
   #:tool-response-error

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

    ;; ==================== Invoke 原语 ====================
    #:invoke-chat
    #:invoke-tool
    #:invoke-tool-batch
    #:invoke-turn
    #:run-tool-loop))
