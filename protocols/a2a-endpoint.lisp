;;;; a2a-endpoint.lisp
;;;; CL-Agent - A2A 通信端点
;;;;
;;;; 概述：
;;;;   定义 A2A 通信端点结构和相关操作
;;;;
;;;; 内容：
;;;;   - 端点结构
;;;;   - 端点创建
;;;;   - 端点转换

(in-package :cl-agent.protocols)

;;; ============================================================
;;; A2A 通信端点
;;; ============================================================

(defstruct a2a-endpoint
  "A2A 通信端点

  槽位说明：
    HOST     - 主机
    PORT     - 端口
    PROTOCOL - 协议（tcp, http, websocket）
    PATH     - 路径"
  (host "localhost" :type string)
  (port *a2a-default-port* :type integer)
  (protocol "tcp" :type string)
  (path "/" :type string))

(defun make-a2a-endpoint (&key (host "localhost")
                               (port *a2a-default-port*)
                               (protocol "tcp")
                               (path "/"))
  "创建 A2A 端点

  参数：
    HOST     - 主机
    PORT     - 端口
    PROTOCOL - 协议
    PATH     - 路径

  返回：
    A2A 端点"
  (make-a2a-endpoint
   :host host
   :port port
   :protocol protocol
   :path path))

(defun a2a-endpoint-to-string (endpoint)
  "将端点转换为字符串

  参数：
    ENDPOINT - A2A 端点

  返回：
    端点字符串"
  (format nil "~A://~A:~A~A"
          (a2a-endpoint-protocol endpoint)
          (a2a-endpoint-host endpoint)
          (a2a-endpoint-port endpoint)
          (a2a-endpoint-path endpoint)))
