;;;; a2a.lisp
;;;; CL-Agent - Agent-to-Agent (A2A) 通信协议
;;;;
;;;; 概述：
;;;;   实现 Agent 之间的通信协议
;;
;;;; 模块结构：
;;;;   - a2a-types.lisp      - 类型定义和常量
;;;;   - a2a-endpoint.lisp   - 通信端点
;;;;   - a2a-bus.lisp        - 消息总线和构建
;;;;   - a2a-messaging.lisp  - 消息传递
;;;;   -a2a-handlers.lisp    - 消息处理器
;;;;   - a2a-listeners.lisp  - 监听器和订阅
;;;;   - a2a-service.lisp    - 服务发现
;;
;;;; 特性：
;;;;   - 消息传递
;;;;   - 服务发现
;;;;   - 消息路由
;;;;   - 事件订阅

(in-package :cl-agent.protocols)

;;; ============================================================
;;; 全局变量
;;; ============================================================

(defparameter *default-a2a-bus* nil
  "默认 A2A 消息总线")

(defun get-default-a2a-bus ()
  "获取或创建默认 A2A 消息总线"
  (unless *default-a2a-bus*
    (setf *default-a2a-bus* (make-a2a-message-bus)))
  *default-a2a-bus*)

;;; ============================================================
;;; 便捷函数
;;; ============================================================

(defun a2a-send-message (to payload &key (headers nil))
  "发送消息（使用默认总线）

  参数：
    TO      - 接收者 ID
    PAYLOAD - 载荷
    HEADERS - 消息头

  返回：
    响应消息"
  (let ((bus (get-default-a2a-bus)))
    (a2a-send-request bus to payload :headers headers)))

(defun a2a-publish-event (event-type payload)
  "发布事件（使用默认总线）

  参数：
    EVENT-TYPE - 事件类型
    PAYLOAD    - 载荷

  返回：
    发送数量"
  (let ((bus (get-default-a2a-bus)))
    (a2a-broadcast-event bus event-type payload)))

(defun a2a-listen (agent-id listener)
  "添加监听器（使用默认总线）

  参数：
    AGENT-ID - Agent ID
    LISTENER - 监听器函数

  返回：
    是否成功"
  (let ((bus (get-default-a2a-bus)))
    (a2a-add-listener bus agent-id listener)))
