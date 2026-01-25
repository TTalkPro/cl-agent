;;;; a2a-handlers.lisp
;;;; CL-Agent - A2A 消息处理器
;;;;
;;;; 概述：
;;;;   实现 A2A 各种消息类型的处理器
;;;;
;;;; 内容：
;;;;   - 请求处理器
;;;;   - 响应处理器
;;;;   - 事件处理器
;;;;   - 订阅处理器

(in-package :cl-agent.protocols)

;;; ============================================================
;;; 响应回调存储
;;; ============================================================

(defvar *a2a-response-callbacks* (make-hash-table :test #'equal)
  "响应回调表：request-id -> callback")

(defvar *a2a-event-handlers* (make-hash-table :test #'equal)
  "事件处理器表：event-type -> handler-list")

;;; ============================================================
;;; 消息处理器
;;; ============================================================

(defun a2a-handle-request (bus message)
  "处理请求消息

  参数：
    BUS     - 消息总线
    MESSAGE - 消息

  返回：
    是否成功"
  (let ((from (a2a-message-from message))
        (request-id (a2a-message-id message)))
    ;; 查找监听器
    (let ((listeners (gethash from (a2a-message-bus-listeners bus))))
      (if listeners
          (dolist (listener listeners)
            (when (functionp listener)
              (let ((response-payload (funcall listener message)))
                ;; 发送响应
                (let ((response (make-a2a-response
                                (a2a-message-bus-agent-id bus)
                                from
                                request-id
                                response-payload)))
                  (a2a-send bus response)))))
          (mcp-log :warn "No listeners for: ~A" from)))
    t))

(defun a2a-handle-response (bus message)
  "处理响应消息

  参数：
    BUS     - 消息总线
    MESSAGE - 消息

  返回：
    是否成功"
  (let ((correlation-id (a2a-message-correlation-id message)))
    ;; 查找待处理请求
    (let ((request (gethash correlation-id
                            (a2a-message-bus-pending-requests bus))))
      (if request
          (progn
            ;; 通知请求方（调用回调）
            (let ((callback (gethash correlation-id *a2a-response-callbacks*)))
              (when callback
                (handler-case
                    (funcall callback message)
                  (error (e)
                    (mcp-log :error "Response callback error: ~A" e)))
                ;; 移除回调
                (remhash correlation-id *a2a-response-callbacks*)))

            (when *mcp-verbose*
              (mcp-log :debug "Received response for request: ~A"
                       correlation-id))
            ;; 移除待处理请求
            (remhash correlation-id
                     (a2a-message-bus-pending-requests bus))
            t)
          (progn
            (mcp-log :warn "No pending request for: ~A"
                     correlation-id)
            nil)))))

(defun a2a-handle-event (bus message)
  "处理事件消息

  参数：
    BUS     - 消息总线
    MESSAGE - 消息

  返回：
    是否成功"
  (let* ((payload (a2a-message-payload message))
         (event-type (if (hash-table-p payload)
                         (gethash "eventType" payload)
                         (getf payload :event-type)))
         (data (if (hash-table-p payload)
                   (gethash "data" payload)
                   (getf payload :data))))
    (when *mcp-verbose*
      (mcp-log :info "Handling event: ~A" event-type))

    ;; 触发事件处理器
    (let ((handlers (gethash event-type *a2a-event-handlers*)))
      (when handlers
        (dolist (handler handlers)
          (handler-case
              (funcall handler bus message data)
            (error (e)
              (mcp-log :error "Event handler error for ~A: ~A" event-type e))))))

    ;; 触发通用事件处理器
    (let ((wildcard-handlers (gethash "*" *a2a-event-handlers*)))
      (when wildcard-handlers
        (dolist (handler wildcard-handlers)
          (handler-case
              (funcall handler bus message data)
            (error (e)
              (mcp-log :error "Wildcard event handler error: ~A" e))))))
    t))

(defun a2a-handle-subscribe (bus message)
  "处理订阅消息

  参数：
    BUS     - 消息总线
    MESSAGE - 消息

  返回：
    是否成功"
  (let* ((from (a2a-message-from message))
         (payload (a2a-message-payload message))
         (topics (if (hash-table-p payload)
                     (gethash "topics" payload)
                     (getf payload :topics))))
    (when *mcp-verbose*
      (mcp-log :info "Subscribe request from: ~A for topics: ~A" from topics))

    ;; 添加订阅
    (if topics
        ;; 订阅指定主题
        (dolist (topic (if (listp topics) topics (list topics)))
          (let ((subscribers (gethash topic (a2a-message-bus-subscribers bus))))
            (unless (member from subscribers :test #'equal)
              (setf (gethash topic (a2a-message-bus-subscribers bus))
                    (cons from subscribers)))))
        ;; 订阅所有（使用通配符）
        (let ((subscribers (gethash "*" (a2a-message-bus-subscribers bus))))
          (unless (member from subscribers :test #'equal)
            (setf (gethash "*" (a2a-message-bus-subscribers bus))
                  (cons from subscribers)))))
    t))

(defun a2a-handle-unsubscribe (bus message)
  "处理取消订阅消息

  参数：
    BUS     - 消息总线
    MESSAGE - 消息

  返回：
    是否成功"
  (let* ((from (a2a-message-from message))
         (payload (a2a-message-payload message))
         (topics (if (hash-table-p payload)
                     (gethash "topics" payload)
                     (getf payload :topics))))
    (when *mcp-verbose*
      (mcp-log :info "Unsubscribe request from: ~A for topics: ~A" from topics))

    ;; 移除订阅
    (if topics
        ;; 从指定主题取消订阅
        (dolist (topic (if (listp topics) topics (list topics)))
          (let ((subscribers (gethash topic (a2a-message-bus-subscribers bus))))
            (setf (gethash topic (a2a-message-bus-subscribers bus))
                  (remove from subscribers :test #'equal))))
        ;; 从所有主题取消订阅
        (maphash (lambda (topic subscribers)
                   (setf (gethash topic (a2a-message-bus-subscribers bus))
                         (remove from subscribers :test #'equal)))
                 (a2a-message-bus-subscribers bus)))
    t))

;;; ============================================================
;;; 辅助函数
;;; ============================================================

(defun a2a-register-response-callback (request-id callback)
  "注册响应回调

  参数：
    REQUEST-ID - 请求 ID
    CALLBACK   - 回调函数 (lambda (response-message) ...)"
  (setf (gethash request-id *a2a-response-callbacks*) callback))

(defun a2a-register-event-handler (event-type handler)
  "注册事件处理器

  参数：
    EVENT-TYPE - 事件类型（字符串，或 \"*\" 表示所有事件）
    HANDLER    - 处理器函数 (lambda (bus message data) ...)"
  (let ((handlers (gethash event-type *a2a-event-handlers*)))
    (setf (gethash event-type *a2a-event-handlers*)
          (cons handler handlers))))

(defun a2a-unregister-event-handler (event-type handler)
  "取消注册事件处理器

  参数：
    EVENT-TYPE - 事件类型
    HANDLER    - 处理器函数"
  (let ((handlers (gethash event-type *a2a-event-handlers*)))
    (setf (gethash event-type *a2a-event-handlers*)
          (remove handler handlers))))

(defun a2a-clear-event-handlers (&optional event-type)
  "清除事件处理器

  参数：
    EVENT-TYPE - 事件类型（可选，nil 表示清除所有）"
  (if event-type
      (remhash event-type *a2a-event-handlers*)
      (clrhash *a2a-event-handlers*)))

(defun a2a-get-subscribers (bus topic)
  "获取主题的订阅者列表

  参数：
    BUS   - 消息总线
    TOPIC - 主题

  返回：
    订阅者列表"
  (let ((specific (gethash topic (a2a-message-bus-subscribers bus)))
        (wildcard (gethash "*" (a2a-message-bus-subscribers bus))))
    (union specific wildcard :test #'equal)))

(defun a2a-broadcast-event (bus event-type data)
  "广播事件给所有订阅者

  参数：
    BUS        - 消息总线
    EVENT-TYPE - 事件类型
    DATA       - 事件数据

  返回：
    发送成功的订阅者数量"
  (let ((subscribers (a2a-get-subscribers bus event-type))
        (count 0))
    (dolist (subscriber subscribers)
      (let ((payload (make-hash-table :test #'equal)))
        (setf (gethash "eventType" payload) event-type)
        (setf (gethash "data" payload) data)
        (let ((event-msg (make-a2a-event
                          (a2a-message-bus-agent-id bus)
                          subscriber
                          payload)))
          (when (a2a-send bus event-msg)
            (incf count)))))
    count))
