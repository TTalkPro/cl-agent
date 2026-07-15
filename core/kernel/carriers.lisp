;;;; carriers.lisp
;;;; CL-Agent Kernel - 三链请求/响应载体
;;;;
;;;; 概述：
;;;;   Kernel 架构里 chat / tool / turn 三条链各自携带不同的请求/响应
;;;;   结构。Chat 链直接复用 cl-agent.client 已有的 client-request /
;;;;   client-response（不动现有代码），仅新增 tool 链与 turn 链的
;;;;   载体类。
;;;;
;;;;   Tool 链：
;;;;     tool-request  = function + args + context
;;;;     tool-response = result + writes + error
;;;;
;;;;   Turn 链：
;;;;     turn-request  = messages + context + resume-p
;;;;     turn-result   = status + response + tool-context + tool-calls-made
;;;;
;;;;   所有载体均为普通 CLOS 值对象，零行为、不含协议方法——filter 钩子
;;;;   直接对它们做 (req chain) → resp 的函数调用。

(in-package #:cl-agent.kernel)

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

(defclass tool-response ()
  ((result
    :initarg :result
    :initform nil
    :reader tool-response-result
    :documentation "工具返回结果（任意值；遵循 deftool 函数返回值）")
   (writes
    :initarg :writes
    :initform nil
    :reader tool-response-writes
    :documentation "状态写意图 alist（(key . value)...），
filter 可借此提交对外部状态（计数器/缓存/记忆）的写请求")
   (error
    :initarg :error
    :initform nil
    :reader tool-response-error
    :documentation "错误信息 plist（:class :message）或 nil"))
  (:documentation "Tool 链响应载体（kernel 工具执行结果）"))

(defun make-tool-response (&key result writes error)
  "创建 tool-response。"
  (make-instance 'tool-response
                 :result result
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

(defclass turn-result ()
  ((status
    :initarg :status
    :reader turn-result-status
    :documentation ":completed | :paused | :cancelled | :error")
   (response
    :initarg :response
    :initform nil
    :reader turn-result-response
    :documentation "最终 chat-response 或 nil（出错时为 nil）")
   (tool-context
    :initarg :tool-context
    :initform nil
    :reader turn-result-tool-context
    :documentation "本轮工具执行上下文（tool-calls + tool-responses）")
   (tool-calls-made
    :initarg :tool-calls-made
    :initform nil
    :reader turn-result-tool-calls-made
    :documentation "本轮已执行的工具调用计数（P2 循环上限判断用）"))
  (:documentation "Turn 链响应载体（一轮 LLM 调用的输出）"))

(defun make-turn-result (status &key response tool-context tool-calls-made)
  "创建 turn-result。STATUS 必填，其余缺省 nil。"
  (make-instance 'turn-result
                 :status status
                 :response response
                 :tool-context tool-context
                 :tool-calls-made tool-calls-made))
