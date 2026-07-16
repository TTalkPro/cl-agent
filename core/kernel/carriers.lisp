;;;; carriers.lisp
;;;; CL-Agent Kernel - 三链请求/响应载体
;;;;
;;;; 概述：
;;;;   Kernel 架构里 chat / tool / turn 三条链各自携带不同的请求/响应
;;;;   结构。Chat 链不用专门的载体——请求就是 cl-agent.core:prompt，
;;;;   响应就是 chat-response，够用且少一层包装。本文件定义 tool 链与
;;;;   turn 链的载体类。
;;;;
;;;;   （历史：早期 chat 链复用过 cl-agent.client 的 client-request /
;;;;   client-response；该包已随 Spring AI 移植层一并删除。）
;;;;
;;;;   Tool 链：
;;;;     tool-request  = function + args + context
;;;;     tool-result   = value + writes + error
;;;;
;;;;   Turn 链：
;;;;     turn-request  = messages + context + resume-p
;;;;     turn-result   = status + response + tool-context + tool-calls-made
;;;;
;;;;   所有载体均为普通 CLOS 值对象，零行为、不含协议方法——filter 钩子
;;;;   直接对它们做 (req chain) → resp 的函数调用。

(in-package #:cl-agent.core)

;;; ============================================================
;;; Tool 链载体
;;; ============================================================

(defclass tool-request ()
  ((function
    :initarg :function
    :reader tool-request-function
    :documentation "tool-callback 或工具元数据（符号/ToolCallback/function）")
   (args
    :initarg :args
    :initform nil
    :reader tool-request-args
    :documentation "工具参数 plist")
   (context
    :initarg :context
    :initform nil
    :reader tool-request-context
    :documentation "工具上下文 plist（filter 间共享）"))
  (:documentation "Tool 链请求载体（kernel 工具调用请求）"))

(defun make-tool-request (function &key args context)
  "创建 tool-request。ARGS 缺省 nil，CONTEXT 缺省 nil。"
  (make-instance 'tool-request
                 :function function
                 :args args
                 :context context))

(defclass tool-result ()
  ((value
    :initarg :value
    :initform nil
    :reader tool-result-value
    :documentation "工具返回结果（任意值；遵循 deftool 函数返回值）")
   (writes
    :initarg :writes
    :initform nil
    :reader tool-result-writes
    :documentation "状态写意图 plist（:key value ...）。

来源：工具函数返回 (values 结果 writes-plist)，或 :tool filter 自己
构造带 :writes 的 tool-result。工具在并行中拿到的 context 是**只读
快照**，写经此声明——批次屏障（fold-batch-writes → apply-writes）
按 tool-call 原始序折叠进 context，合并语义由 kernel 的 :state-slots
声明（未声明的槽 last-writer）。失败调用（error 非 nil）的写意图
不生效。")
   (error
    :initarg :error
    :initform nil
    :reader tool-result-error
    :documentation "错误信息 plist（:class :message）或 nil"))
  (:documentation "Tool 链响应载体（kernel 工具执行结果）。

命名：与 turn 链的 turn-request → turn-result 对称。
曾叫 tool-response——与 cl-agent.core:tool-response（协议消息层的
「工具响应」值对象：id/name/text）撞名，逼得 kernel 必须 shadow，
下游想同时 :use 两个包还得自己写 shadowing-import。两者本就是不同
层的东西：chat 的是发回模型的消息，kernel 的是执行链的结果载体。
改名后撞名消失，shadow 也随之删除。"))

(defun make-tool-result (&key value writes error)
  "创建 tool-result。"
  (make-instance 'tool-result
                 :value value
                 :writes writes
                 :error error))

;;; ============================================================
;;; Turn 链载体
;;; ============================================================

(defclass turn-request ()
  ((messages
    :initarg :messages
    :initform nil
    :reader turn-request-messages
    :documentation "中立消息列表（hash-table 或 message 实例列表）")
   (context
    :initarg :context
    :initform nil
    :reader turn-request-context
    :documentation "上下文 plist（filter 间共享）")
   (resume-p
    :initarg :resume-p
    :initform nil
    :reader turn-request-resume-p
    :documentation "是否从暂停恢复（kernel 循环续跑用）"))
  (:documentation "Turn 链请求载体（一轮 LLM 调用的输入）"))

(defun make-turn-request (messages &key context resume-p)
  "创建 turn-request。MESSAGES 缺省 nil。"
  (make-instance 'turn-request
                 :messages messages
                 :context context
                 :resume-p resume-p))

;;; ============================================================
;;; 暂停载体（HITL）
;;; ============================================================

(defclass loop-state ()
  ((messages
    :initarg :messages
    :initform nil
    :reader loop-state-messages
    :documentation "暂停时刻的消息列表（尚未含本轮 assistant/工具结果）")
   (response
    :initarg :response
    :initform nil
    :reader loop-state-response
    :documentation "触发暂停的那条 assistant 响应（携带 tool-calls）")
   (tool-calls
    :initarg :tool-calls
    :initform nil
    :reader loop-state-tool-calls
    :documentation "本批全部 tool-call——**都还没执行**")
   (pending-id
    :initarg :pending-id
    :initform nil
    :reader loop-state-pending-id
    :documentation "被 gate 判为 :pause 的那个 tool-call 的 id（resume 定位用）")
   (iteration
    :initarg :iteration
    :initform 0
    :reader loop-state-iteration
    :documentation "暂停发生在第几轮（resume 后接着数，仍受 max-tool-iterations 约束）")
   (options
    :initarg :options
    :initform nil
    :reader loop-state-options
    :documentation "本轮已解析的 chat-options（含 tool-callbacks）")
   (context
    :initarg :context
    :initform nil
    :reader loop-state-context
    :documentation "暂停时刻的 turn context"))
  (:documentation "工具循环的暂停快照——resume 靠它从中点续跑。

刻意不含 kernel/gate/callbacks：那些是代码侧的东西，resume 时重新提供。
本类只装「续跑所需的数据」。"))

(defun make-loop-state (&key messages response tool-calls pending-id
                             (iteration 0) options context)
  "创建 loop-state。"
  (make-instance 'loop-state
                 :messages messages :response response
                 :tool-calls tool-calls :pending-id pending-id
                 :iteration iteration :options options :context context))

(defclass pending-tool ()
  ((name
    :initarg :name
    :reader pending-tool-name
    :documentation "待审批的工具名")
   (args
    :initarg :args
    :initform nil
    :reader pending-tool-args
    :documentation "待审批的工具参数 plist")
   (id
    :initarg :id
    :initform nil
    :reader pending-tool-id
    :documentation "对应的 tool-call id"))
  (:documentation "待审批工具的描述（给审批方看的，不含执行逻辑）"))

(defun make-pending-tool (&key name args id)
  (make-instance 'pending-tool :name name :args args :id id))

(defmethod print-object ((p pending-tool) stream)
  (print-unreadable-object (p stream :type t)
    (format stream "~A ~S" (pending-tool-name p) (pending-tool-args p))))

(defclass turn-result ()
  ((status
    :initarg :status
    :reader turn-result-status
    :documentation ":completed | :paused | :cancelled | :error")
   (loop-state
    :initarg :loop-state
    :initform nil
    :reader turn-result-loop-state
    :documentation ":paused 时的续跑快照（喂给 resume-turn）；其余状态为 nil")
   (pending-tool
    :initarg :pending-tool
    :initform nil
    :reader turn-result-pending-tool
    :documentation ":paused 时待审批的工具（name/args/id）；其余状态为 nil")
   (pause-reason
    :initarg :pause-reason
    :initform nil
    :reader turn-result-pause-reason
    :documentation ":paused 的原因（gate 给的说明文本）")
   (response
    :initarg :response
    :initform nil
    :reader turn-result-response
    :documentation "最终 chat-response 或 nil（出错时为 nil）")
   (tool-context
    :initarg :tool-context
    :initform nil
    :reader turn-result-tool-context
    :documentation "折叠完全部工具批次 :writes 后的最终 context plist——
工具经写意图累积的状态由此交还调用方。无工具/无写意图时
是轮初 context 原样。
（此前这个槽是装饰品：docstring 说装 tool-calls + tool-results，
实际全库无人赋值，恒 nil。）")
   (tool-calls-made
    :initarg :tool-calls-made
    :initform nil
    :reader turn-result-tool-calls-made
    :documentation "本轮已执行的工具调用计数（P2 循环上限判断用）"))
  (:documentation "Turn 链响应载体（一轮 LLM 调用的输出）"))

(defun make-turn-result (status &key response tool-context tool-calls-made
                                     loop-state pending-tool pause-reason)
  "创建 turn-result。STATUS 必填，其余缺省 nil。

STATUS = :paused 时应同时给 loop-state / pending-tool / pause-reason——
resume-turn 靠 loop-state 续跑，审批方靠 pending-tool 知道在批什么。"
  (make-instance 'turn-result
                 :status status
                 :response response
                 :tool-context tool-context
                 :tool-calls-made tool-calls-made
                 :loop-state loop-state
                 :pending-tool pending-tool
                 :pause-reason pause-reason))
