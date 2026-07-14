;;;; advisor.lisp
;;;; CL-Agent Client - Advisor 协议与洋葱链
;;;;
;;;; 概述（对标 Spring AI Advisor API）：
;;;;
;;;;   client-request  = prompt + context      —— ChatClientRequest
;;;;   client-response = chat-response + context —— ChatClientResponse
;;;;
;;;;   Advisor 协议：
;;;;     (advise-call advisor request chain)          —— CallAdvisor#adviseCall
;;;;     (advise-stream advisor request chain on-chunk) —— StreamAdvisor#adviseStream
;;;;
;;;;   Advisor 在链上可以：
;;;;   - 前置增强 request（改写 prompt / 写入 context）
;;;;   - 调 (chain-next chain request) 进入下游
;;;;   - 后置增强 response
;;;;   - 短路（不调下游直接返回，如安全护栏）
;;;;
;;;;   排序：order 越小越靠外（先执行），与 Spring AI Ordered 语义一致。
;;;;
;;;; defadvisor 宏：
;;;;   (defadvisor my-advisor (:order 100 :documentation "...")
;;;;     (:slots ((prefix :initarg :prefix :initform ">> ")))
;;;;     (:call (advisor request chain)
;;;;       ...
;;;;       (chain-next chain request)))
;;;;
;;;;   展开为：defclass + advise-call 方法 [+ advise-stream 方法]
;;;;   + make-my-advisor 构造函数。

(in-package #:cl-agent.client)

;;; ============================================================
;;; 请求/响应载体
;;; ============================================================

(defclass client-request ()
  ((prompt
    :initarg :prompt
    :accessor client-request-prompt
    :documentation "prompt 实例")
   (context
    :initarg :context
    :initform (make-hash-table :test #'equal)
    :reader client-request-context
    :documentation "Advisor 间共享的上下文（equal hash-table）"))
  (:documentation "Advisor 链上的请求载体（对标 ChatClientRequest）"))

(defun make-client-request (prompt &key context)
  "创建 client-request。CONTEXT 缺省为空 hash-table。"
  (make-instance 'client-request
                 :prompt prompt
                 :context (or context (make-hash-table :test #'equal))))

(defun client-request-copy (request &key prompt)
  "拷贝请求（可替换 prompt），context 共享——Advisor 通过 context 通信"
  (make-instance 'client-request
                 :prompt (or prompt (client-request-prompt request))
                 :context (client-request-context request)))

(defclass client-response ()
  ((chat-response
    :initarg :chat-response
    :reader client-response-chat-response
    :documentation "chat-response 实例")
   (context
    :initarg :context
    :initform (make-hash-table :test #'equal)
    :reader client-response-context
    :documentation "Advisor 间共享的上下文"))
  (:documentation "Advisor 链上的响应载体（对标 ChatClientResponse）"))

(defun make-client-response (chat-response &key context)
  (make-instance 'client-response
                 :chat-response chat-response
                 :context (or context (make-hash-table :test #'equal))))

;;; context 访问（request/response 通用）

(defgeneric context-get (holder key &optional default)
  (:documentation "读取 Advisor 上下文值"))

(defgeneric context-set (holder key value)
  (:documentation "写入 Advisor 上下文值，返回 VALUE"))

(defmethod context-get ((holder client-request) key &optional default)
  (gethash key (client-request-context holder) default))

(defmethod context-get ((holder client-response) key &optional default)
  (gethash key (client-response-context holder) default))

(defmethod context-set ((holder client-request) key value)
  (setf (gethash key (client-request-context holder)) value))

(defmethod context-set ((holder client-response) key value)
  (setf (gethash key (client-response-context holder)) value))

;;; ============================================================
;;; Advisor 协议
;;; ============================================================

(defclass advisor ()
  ((name
    :initarg :name
    :initform nil
    :documentation "Advisor 名称（缺省用类名）")
   (order
    :initarg :order
    :initform 0
    :documentation "排序值，越小越靠外（先执行）"))
  (:documentation "Advisor 基类（对标 Advisor/BaseAdvisor）"))

(defgeneric advisor-name (advisor)
  (:documentation "Advisor 名称字符串"))

(defmethod advisor-name ((advisor advisor))
  (or (slot-value advisor 'name)
      (string-downcase (symbol-name (type-of advisor)))))

(defgeneric advisor-order (advisor)
  (:documentation "Advisor 排序值"))

(defmethod advisor-order ((advisor advisor))
  (slot-value advisor 'order))

(defgeneric advise-call (advisor request chain)
  (:documentation "环绕一次同步调用（对标 CallAdvisor#adviseCall）。

实现应（通常）调用 (chain-next chain request) 进入下游，
并返回 client-response。"))

(defgeneric advise-stream (advisor request chain on-chunk)
  (:documentation "环绕一次流式调用（对标 StreamAdvisor#adviseStream）。

默认实现委托给 advise-call（把下游流式链适配为同步链）。"))

(defmethod advise-stream ((advisor advisor) request chain on-chunk)
  "默认：以同步语义参与流式链——advisor 的 advise-call 逻辑照常生效，
下游继续走流式路径。"
  (advise-call advisor request (chain-as-call chain on-chunk)))

(defmethod print-object ((advisor advisor) stream)
  (print-unreadable-object (advisor stream :type t)
    (format stream "~A order=~A"
            (advisor-name advisor) (advisor-order advisor))))

;;; ============================================================
;;; Advisor 链（洋葱）
;;; ============================================================

(defclass advisor-chain ()
  ((advisors
    :initarg :advisors
    :initform nil
    :reader chain-advisors
    :documentation "剩余 Advisor 列表（已按 order 升序）")
   (call-terminal
    :initarg :call-terminal
    :reader chain-call-terminal
    :documentation "同步终端：(request) → client-response（真正调 ChatModel）")
   (stream-terminal
    :initarg :stream-terminal
    :initform nil
    :reader chain-stream-terminal
    :documentation "流式终端：(request on-chunk) → client-response"))
  (:documentation "有序 Advisor 洋葱链（对标 Call/StreamAdvisorChain）"))

(defun make-advisor-chain (advisors call-terminal &key stream-terminal)
  "创建 Advisor 链。ADVISORS 自动按 order 升序稳定排序。"
  (make-instance 'advisor-chain
                 :advisors (stable-sort (copy-list advisors) #'<
                                        :key #'advisor-order)
                 :call-terminal call-terminal
                 :stream-terminal stream-terminal))

(defun chain-rest (chain)
  "去掉链头 Advisor 的剩余链"
  (make-instance 'advisor-chain
                 :advisors (rest (chain-advisors chain))
                 :call-terminal (chain-call-terminal chain)
                 :stream-terminal (chain-stream-terminal chain)))

(defun chain-next (chain request)
  "进入链的下一环：还有 Advisor 则调它的 advise-call，
否则调同步终端（真正的 ChatModel 调用）。"
  (let ((advisors (chain-advisors chain)))
    (if advisors
        (advise-call (first advisors) request (chain-rest chain))
        (funcall (chain-call-terminal chain) request))))

(defun chain-next-stream (chain request on-chunk)
  "流式进入链的下一环。无流式终端时降级为同步终端。"
  (let ((advisors (chain-advisors chain)))
    (if advisors
        (advise-stream (first advisors) request (chain-rest chain) on-chunk)
        (let ((terminal (chain-stream-terminal chain)))
          (if terminal
              (funcall terminal request on-chunk)
              (funcall (chain-call-terminal chain) request))))))

(defun chain-as-call (chain on-chunk)
  "把流式链包装成同步链视图：当前 Advisor 的 advise-call 里
调 (chain-next ...) 时，实际回到流式路径继续走剩余链
（后续 Advisor 仍按 advise-stream 分派）。
供 advise-stream 的默认实现复用 advise-call 逻辑。"
  (make-instance 'advisor-chain
                 :advisors nil
                 :call-terminal (lambda (request)
                                  (chain-next-stream chain request on-chunk))))

;;; ============================================================
;;; defadvisor 宏
;;; ============================================================

(defmacro defadvisor (name (&key (order 0) documentation) &body clauses)
  "定义一个 Advisor：类 + 方法 + 构造函数，一个表达式完成。

语法：
  (defadvisor 名称 (:order N :documentation \"...\")
    [(:slots (槽定义...))]
    (:call (advisor request chain) 方法体...)
    [(:stream (advisor request chain on-chunk) 方法体...)])

展开为：
  - (defclass 名称 (advisor) 槽... (:default-initargs :order N))
  - (defmethod advise-call ((advisor 名称) request chain) ...)
  - 可选的 advise-stream 方法
  - (defun make-名称 (&rest initargs) ...) 构造函数

示例：
  (defadvisor upcase-advisor (:order 10)
    (:call (advisor request chain)
      (declare (ignore advisor))
      (chain-next chain request)))"
  (let ((slots nil)
        (call-clause nil)
        (stream-clause nil))
    (dolist (clause clauses)
      (ecase (first clause)
        (:slots (setf slots (second clause)))
        (:call (setf call-clause (rest clause)))
        (:stream (setf stream-clause (rest clause)))))
    (unless call-clause
      (error "defadvisor ~A 缺少 (:call ...) 子句" name))
    (destructuring-bind (call-args &rest call-body) call-clause
      (destructuring-bind (advisor-var request-var chain-var) call-args
        `(progn
           (defclass ,name (advisor)
             ,slots
             (:default-initargs :order ,order)
             ,@(when documentation `((:documentation ,documentation))))
           (defmethod advise-call ((,advisor-var ,name) ,request-var ,chain-var)
             ,@call-body)
           ,@(when stream-clause
               (destructuring-bind ((a-var r-var c-var chunk-var) &rest stream-body)
                   stream-clause
                 `((defmethod advise-stream ((,a-var ,name) ,r-var ,c-var ,chunk-var)
                     ,@stream-body))))
           (defun ,(intern (format nil "MAKE-~A" (symbol-name name))
                           (symbol-package name))
               (&rest initargs)
             ,(format nil "创建 ~(~A~) 实例" name)
             (apply #'make-instance ',name initargs))
           ',name)))))
