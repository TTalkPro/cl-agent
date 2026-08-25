;;;; package.lisp
;;;; CL-Agent Client - 包定义
;;;;
;;;; 概述（对标 clj-agent 的 clj-agent-client / SimpleAgent）：
;;;;
;;;;   cl-agent/core 是**执行内核**：三链、filter、工具循环——完全控制，
;;;;   但每次调用都得自己拼 conversation-id、自己接错误。
;;;;   本包是**面向应用的易用层**：一个有状态的 agent 对象，
;;;;   开箱即用地管住会话、可观测性与错误归一化。
;;;;
;;;;     (defvar *a* (make-agent :model m :system "你是助手" :tools '(get-weather)))
;;;;     (agent-chat *a* "东京天气？")   ; 自动累积上下文
;;;;     (agent-chat *a* "那北京呢？")   ; 记得上一轮
;;;;
;;;; 设计边界（照搬 clj-agent 的一条重要决策）：
;;;;   **agent 层不暴露 kernel filter**。想挂 filter 就自己 build-kernel
;;;;   再用 :kernel 传进来。理由：简单层一旦开始转发 filter，就会慢慢长成
;;;;   第二个 kernel——本仓库刚删掉的 ChatClient 正是这么烂掉的
;;;;   （最后只剩一堆静默 no-op 的横切槽位）。
;;;;   agent 层只暴露 :callbacks（可观测性），职责边界一刀切干净。
;;;;
;;;; agent 不自己存历史：历史仍由 core 的 memory-filter 按 conversation-id
;;;; 管，agent 只持 conversation-id + 轻量控制状态。

(defpackage #:cl-agent/client
  (:use #:common-lisp)
  (:nicknames #:cla/client)
  (:import-from #:cl-agent/core
                #:log-debug #:log-info #:log-warn)
  (:export
   ;; ==================== Agent ====================
   #:agent
   #:make-agent
   #:agent-id
   #:agent-kernel
   #:agent-memory
   #:agent-conversation-id
   #:agent-callbacks
   #:agent-turn-count

   ;; ==================== 对话 ====================
   #:agent-chat
   #:agent-chat-result
   #:agent-history
   #:agent-reset

   ;; ==================== pause / resume（HITL） ====================
   #:agent-paused-p
   #:agent-pending-tool
   #:agent-resume

   ;; ==================== 结果访问（归一化，不抛异常） ====================
   #:agent-result
   #:agent-result-p
   #:agent-result-status
   #:agent-result-text
   #:agent-result-error
   #:agent-result-response
   #:agent-result-pending-tool
   #:agent-result-pause-reason))
