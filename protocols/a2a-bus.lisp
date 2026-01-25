;;;; a2a-bus.lisp
;;;; CL-Agent - A2A 消息总线和消息构建
;;;;
;;;; 概述：
;;;;   定义 A2A 消息总线和消息构建函数
;;;;
;;;; 内容：
;;;;   - 消息总线结构
;;;;   - 消息构建函数

(in-package :cl-agent.protocols)

;;; ============================================================
;;; A2A 消息总线
;;; ============================================================

(defstruct a2a-message-bus
  "A2A 消息总线

  槽位说明：
    AGENT-ID         - Agent ID
    ENDPOINT         - 端点
    LISTENERS        - 监听器
    SUBSCRIBERS      - 订阅者
    PENDING-REQUESTS - 待处理请求"
  agent-id
  endpoint
  (listeners (make-hash-table :test #'equal))
  (subscribers (make-hash-table :test #'equal))
  (pending-requests (make-hash-table :test #'equal))
  (request-counter 0))

(defun make-a2a-message-bus (&key (agent-id nil)
                                 (endpoint nil))
  "创建 A2A 消息总线

  参数：
    AGENT-ID - Agent ID
    ENDPOINT - 端点

  返回：
    消息总线"
  (let ((id (or agent-id (cl-agent.core:generate-uuid)))
        (ep (or endpoint (make-a2a-endpoint))))
    (make-a2a-message-bus
     :agent-id id
     :endpoint ep)))

;;; ============================================================
;;; A2A 消息构建
;;; ============================================================

(defun make-a2a-message (&key (type +a2a-msg-type-request+)
                            (from nil)
                            (to nil)
                            (payload nil)
                            (headers nil)
                            (correlation-id nil))
  "创建 A2A 消息

  参数：
    TYPE           - 消息类型
    FROM           - 发送者 ID
    TO             - 接收者 ID
    PAYLOAD        - 载荷
    HEADERS        - 消息头
    CORRELATION-ID - 关联 ID

  返回：
    A2A 消息"
  (make-a2a-message
   :id (cl-agent.core:generate-uuid)
   :type type
   :from from
   :to to
   :timestamp (cl-agent.core:timestamp-now)
   :payload payload
   :headers headers
   :correlation-id correlation-id))

(defun make-a2a-request (from to payload &key (headers nil))
  "创建 A2A 请求

  参数：
    FROM    - 发送者 ID
    TO      - 接收者 ID
    PAYLOAD - 载荷
    HEADERS - 消息头

  返回：
    A2A 请求消息"
  (make-a2a-message
   :type +a2a-msg-type-request+
   :from from
   :to to
   :payload payload
   :headers headers))

(defun make-a2a-response (from to request-id payload &key (headers nil))
  "创建 A2A 响应

  参数：
    FROM       - 发送者 ID
    TO         - 接收者 ID
    REQUEST-ID - 请求 ID
    PAYLOAD    - 载荷
    HEADERS    - 消息头

  返回：
    A2A 响应消息"
  (make-a2a-message
   :type +a2a-msg-type-response+
   :from from
   :to to
   :payload payload
   :headers headers
   :correlation-id request-id))

(defun make-a2a-event (from event-type payload &key (to nil))
  "创建 A2A 事件

  参数：
    FROM       - 发送者 ID
    EVENT-TYPE - 事件类型
    PAYLOAD    - 载荷
    TO         - 接收者 ID（可选）

  返回：
    A2A 事件消息"
  (make-a2a-message
   :type +a2a-msg-type-event+
   :from from
   :to to
   :payload (let ((p (make-hash-table :test #'equal)))
              (setf (gethash "eventType" p) event-type)
              (setf (gethash "data" p) payload)
              p)))
