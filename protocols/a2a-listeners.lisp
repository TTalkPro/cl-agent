;;;; a2a-listeners.lisp
;;;; CL-Agent - A2A 监听器和订阅管理
;;;;
;;;; 概述：
;;;;   实现 A2A 监听器和事件订阅管理
;;;;
;;;; 内容：
;;;;   - 监听器管理
;;;;   - 订阅管理

(in-package :cl-agent.protocols)

;;; ============================================================
;;; 监听器管理
;;; ============================================================

(defun a2a-add-listener (bus agent-id listener)
  "添加消息监听器

  参数：
    BUS      - 消息总线
    AGENT-ID - Agent ID
    LISTENER - 监听器函数

  返回：
    是否成功"
  (let ((listeners (gethash agent-id
                            (a2a-message-bus-listeners bus))))
    (unless listeners
      (setf listeners '())
      (setf (gethash agent-id
                     (a2a-message-bus-listeners bus))
            listeners))
    (push listener listeners)
    (when *mcp-verbose*
      (mcp-log :info "Added listener for: ~A" agent-id))
    t))

(defun a2a-remove-listener (bus agent-id)
  "移除消息监听器

  参数：
    BUS      - 消息总线
    AGENT-ID - Agent ID

  返回：
    是否成功"
  (remhash agent-id (a2a-message-bus-listeners bus))
  (when *mcp-verbose*
    (mcp-log :info "Removed listeners for: ~A" agent-id))
  t)

;;; ============================================================
;;; 订阅管理
;;; ============================================================

(defun a2a-subscribe (bus agent-id event-type handler)
  "订阅事件

  参数：
    BUS        - 消息总线
    AGENT-ID   - Agent ID
    EVENT-TYPE - 事件类型
    HANDLER    - 处理函数

  返回：
    是否成功"
  (let ((subscribers (gethash event-type
                              (a2a-message-bus-subscribers bus))))
    (unless subscribers
      (setf subscribers (make-hash-table :test #'equal))
      (setf (gethash event-type
                     (a2a-message-bus-subscribers bus))
            subscribers))
    (let ((handlers (gethash agent-id subscribers)))
      (unless handlers
        (setf handlers '())
        (setf (gethash agent-id subscribers) handlers))
      (push handler handlers)))
  (when *mcp-verbose*
    (mcp-log :info "Subscribed ~A to event: ~A"
             agent-id event-type))
  t)

(defun a2a-unsubscribe (bus agent-id event-type)
  "取消订阅事件

  参数：
    BUS        - 消息总线
    AGENT-ID   - Agent ID
    EVENT-TYPE - 事件类型

  返回：
    是否成功"
  (let ((subscribers (gethash event-type
                              (a2a-message-bus-subscribers bus))))
    (when subscribers
      (remhash agent-id subscribers)))
  (when *mcp-verbose*
    (mcp-log :info "Unsubscribed ~A from event: ~A"
             agent-id event-type))
  t)
