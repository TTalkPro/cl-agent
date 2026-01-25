;;;; a2a-messaging.lisp
;;;; CL-Agent - A2A 消息传递
;;;;
;;;; 概述：
;;;;   实现 A2A 消息的发送和接收
;;;;
;;;; 内容：
;;;;   - 消息发送
;;;;   - 消息接收
;;;;   - 消息路由

(in-package :cl-agent.protocols)

;;; ============================================================
;;; A2A 消息发送和接收
;;; ============================================================

(defun a2a-send (bus message)
  "发送 A2A 消息

  参数：
    BUS     - 消息总线
    MESSAGE - 消息

  返回：
    是否成功"
  ;; 设置发送者
  (unless (a2a-message-from message)
    (setf (a2a-message-from message)
          (a2a-message-bus-agent-id bus)))

  (when *mcp-verbose*
    (mcp-log :info "Sending A2A message: ~A -> ~A"
             (a2a-message-from message)
             (a2a-message-to message))
    (mcp-log :debug "Message type: ~A" (a2a-message-type message)))

  ;; TODO: 实际发送消息
  ;; 这里简化处理，实际需要通过网络发送
  t)

(defun a2a-send-request (bus to payload &key (headers nil)
                                        (timeout 30000))
  "发送请求并等待响应

  参数：
    BUS     - 消息总线
    TO      - 接收者 ID
    PAYLOAD - 载荷
    HEADERS - 消息头
    TIMEOUT - 超时（毫秒）

  返回：
    响应消息"
  (let ((request (make-a2a-request
                  (a2a-message-bus-agent-id bus)
                  to
                  payload
                  :headers headers)))
    ;; 存储待处理请求
    (setf (gethash (a2a-message-id request)
                   (a2a-message-bus-pending-requests bus))
          request)

    ;; 发送请求
    (a2a-send bus request)

    ;; TODO: 等待响应
    ;; 这里简化处理
    (when *mcp-verbose*
      (mcp-log :debug "Waiting for response to ~A"
               (a2a-message-id request)))

    ;; 模拟响应
    (make-a2a-response to
                       (a2a-message-bus-agent-id bus)
                       (a2a-message-id request)
                       (make-hash-table :test #'equal))))

(defun a2a-broadcast-event (bus event-type payload)
  "广播事件到所有订阅者

  参数：
    BUS        - 消息总线
    EVENT-TYPE - 事件类型
    PAYLOAD    - 载荷

  返回：
    发送数量"
  (let ((event (make-a2a-event
                (a2a-message-bus-agent-id bus)
                event-type
                payload))
        (count 0))
    ;; 发送给所有订阅者
    (maphash (lambda (agent-id listeners)
               (dolist (listener listeners)
                 (setf (a2a-message-to event) agent-id)
                 (a2a-send bus event)
                 (incf count)))
             (a2a-message-bus-subscribers bus))
    count))

(defun a2a-handle-message (bus message)
  "处理接收到的 A2A 消息

  参数：
    BUS     - 消息总线
    MESSAGE - 消息

  返回：
    是否成功"
  (when *mcp-verbose*
    (mcp-log :info "Handling A2A message: ~A"
             (a2a-message-type message))
    (mcp-log :debug "From: ~A, To: ~A"
             (a2a-message-from message)
             (a2a-message-to message)))

  (let ((type (a2a-message-type message)))
    (cond
      ;; 请求
      ((string= type +a2a-msg-type-request+)
       (a2a-handle-request bus message))

      ;; 响应
      ((string= type +a2a-msg-type-response+)
       (a2a-handle-response bus message))

      ;; 事件
      ((string= type +a2a-msg-type-event+)
       (a2a-handle-event bus message))

      ;; 订阅
      ((string= type +a2a-msg-type-subscribe+)
       (a2a-handle-subscribe bus message))

      ;; 取消订阅
      ((string= type +a2a-msg-type-unsubscribe+)
       (a2a-handle-unsubscribe bus message))

      ;; 未知类型
      (t
       (mcp-log :warn "Unknown message type: ~A" type)
       nil))))
