;;;; a2a-types.lisp
;;;; CL-Agent - A2A 协议类型定义
;;;;
;;;; 概述：
;;;;   定义 A2A 协议的核心数据结构和常量
;;;;
;;;; 内容：
;;;;   - 协议常量
;;;;   - 消息类型
;;;;   - 消息结构
;;;;   - Agent 信息

(in-package :cl-agent.protocols)

;;; ============================================================
;;; A2A 协议常量
;;; ============================================================

(defparameter *a2a-protocol-version* "1.0.0"
  "A2A 协议版本")

(defparameter *a2a-default-port* 7777
  "A2A 默认端口")

;;; ============================================================
;;; A2A 消息类型
;;; ============================================================

(defconstant +a2a-msg-type-discovery+ "discovery"
  "服务发现消息")

(defconstant +a2a-msg-type-request+ "request"
  "请求消息")

(defconstant +a2a-msg-type-response+ "response"
  "响应消息")

(defconstant +a2a-msg-type-event+ "event"
  "事件消息")

(defconstant +a2a-msg-type-subscribe+ "subscribe"
  "订阅消息")

(defconstant +a2a-msg-type-unsubscribe+ "unsubscribe"
  "取消订阅消息")

;;; ============================================================
;;; A2A 消息结构
;;; ============================================================

(defstruct a2a-message
  "A2A 消息

  槽位说明：
    ID            - 消息 ID
    TYPE          - 消息类型
    FROM          - 发送者 ID
    TO            - 接收者 ID
    TIMESTAMP     - 时间戳
    PAYLOAD       - 消息载荷
    HEADERS       - 消息头
    CORRELATION-ID - 关联 ID（用于请求-响应）"
  (id nil :type (or null string))
  (type +a2a-msg-type-request+ :type string)
  (from nil :type (or null string))
  (to nil :type (or null string))
  (timestamp nil :type (or null string))
  (payload nil :type (or null hash-table))
  (headers nil :type (or null hash-table))
  (correlation-id nil :type (or null string)))

;;; ============================================================
;;; A2A Agent 信息
;;; ============================================================

(defstruct a2a-agent-info
  "A2A Agent 信息

  槽位说明：
    ID            - Agent ID
    NAME          - Agent 名称
    TYPE          - Agent 类型
    VERSION       - Agent 版本
    CAPABILITIES  - 能力列表
    ENDPOINT      - 通信端点
    METADATA      - 元数据"
  (id nil :type (or null string))
  (name "" :type string)
  (type "generic" :type string)
  (version "1.0.0" :type string)
  (capabilities nil :type (or null list))
  (endpoint nil :type (or null string))
  (metadata nil :type (or null hash-table)))
