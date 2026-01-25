;;;; conditions.lisp
;;;; CL-Agent HTTP - 条件系统
;;;;
;;;; 概述：
;;;;   定义 HTTP 请求相关的错误条件
;;;;
;;;; 条件层次：
;;;;   http-error (error)
;;;;   ├── http-client-error   ; 4xx 错误
;;;;   ├── http-server-error   ; 5xx 错误
;;;;   ├── http-timeout-error  ; 超时错误
;;;;   └── http-connection-error ; 连接错误

(in-package #:cl-agent.http)

;;; ============================================================
;;; 基础 HTTP 错误
;;; ============================================================

(define-condition http-error (error)
  ((status :initarg :status
           :initform nil
           :reader http-error-status
           :documentation "HTTP 状态码")
   (body :initarg :body
         :initform nil
         :reader http-error-body
         :documentation "响应体")
   (uri :initarg :uri
        :initform nil
        :reader http-error-uri
        :documentation "请求 URI")
   (headers :initarg :headers
            :initform nil
            :reader http-error-headers
            :documentation "响应头")
   (cause :initarg :cause
          :initform nil
          :reader http-error-cause
          :documentation "原始异常"))
  (:documentation "HTTP 请求错误基类

槽位说明：
  STATUS  - HTTP 状态码（如 404, 500）
  BODY    - 响应体内容
  URI     - 请求的 URI
  HEADERS - 响应头
  CAUSE   - 原始异常（如果有）")
  (:report (lambda (condition stream)
             (format stream "HTTP 请求失败~@[ (状态码: ~A)~]~@[~%URI: ~A~]~@[~%原因: ~A~]"
                     (http-error-status condition)
                     (http-error-uri condition)
                     (http-error-cause condition)))))

;;; ============================================================
;;; 客户端错误 (4xx)
;;; ============================================================

(define-condition http-client-error (http-error)
  ()
  (:documentation "HTTP 客户端错误 (4xx)

表示客户端请求有误，如：
  - 400 Bad Request
  - 401 Unauthorized
  - 403 Forbidden
  - 404 Not Found
  - 429 Too Many Requests")
  (:report (lambda (condition stream)
             (format stream "HTTP 客户端错误 ~A~@[~%URI: ~A~]~@[~%响应: ~A~]"
                     (http-error-status condition)
                     (http-error-uri condition)
                     (http-error-body condition)))))

;;; ============================================================
;;; 服务端错误 (5xx)
;;; ============================================================

(define-condition http-server-error (http-error)
  ()
  (:documentation "HTTP 服务端错误 (5xx)

表示服务端处理失败，如：
  - 500 Internal Server Error
  - 502 Bad Gateway
  - 503 Service Unavailable
  - 504 Gateway Timeout")
  (:report (lambda (condition stream)
             (format stream "HTTP 服务端错误 ~A~@[~%URI: ~A~]~@[~%响应: ~A~]"
                     (http-error-status condition)
                     (http-error-uri condition)
                     (http-error-body condition)))))

;;; ============================================================
;;; 超时错误
;;; ============================================================

(define-condition http-timeout-error (http-error)
  ((timeout :initarg :timeout
            :initform nil
            :reader http-timeout-error-timeout
            :documentation "超时时间（秒）"))
  (:documentation "HTTP 请求超时错误

槽位说明：
  TIMEOUT - 配置的超时时间")
  (:report (lambda (condition stream)
             (format stream "HTTP 请求超时~@[ (~A 秒)~]~@[~%URI: ~A~]"
                     (http-timeout-error-timeout condition)
                     (http-error-uri condition)))))

;;; ============================================================
;;; 连接错误
;;; ============================================================

(define-condition http-connection-error (http-error)
  ((host :initarg :host
         :initform nil
         :reader http-connection-error-host
         :documentation "目标主机")
   (port :initarg :port
         :initform nil
         :reader http-connection-error-port
         :documentation "目标端口"))
  (:documentation "HTTP 连接错误

表示无法建立连接，如：
  - DNS 解析失败
  - 连接被拒绝
  - 网络不可达

槽位说明：
  HOST - 目标主机名
  PORT - 目标端口")
  (:report (lambda (condition stream)
             (format stream "HTTP 连接失败~@[: ~A~]~@[:~A~]~@[~%原因: ~A~]"
                     (http-connection-error-host condition)
                     (http-connection-error-port condition)
                     (http-error-cause condition)))))

;;; ============================================================
;;; 信号函数
;;; ============================================================

(defun signal-http-error (status &key body uri headers cause)
  "根据状态码信号适当的 HTTP 错误

参数：
  STATUS  - HTTP 状态码
  BODY    - 响应体
  URI     - 请求 URI
  HEADERS - 响应头
  CAUSE   - 原始异常

示例：
  (signal-http-error 404 :uri \"https://example.com/api\" :body \"Not Found\")"
  (let ((condition-type (cond
                          ((and status (>= status 400) (< status 500))
                           'http-client-error)
                          ((and status (>= status 500))
                           'http-server-error)
                          (t 'http-error))))
    (error condition-type
           :status status
           :body body
           :uri uri
           :headers headers
           :cause cause)))

(defun signal-timeout-error (uri &key timeout cause)
  "信号超时错误

参数：
  URI     - 请求 URI
  TIMEOUT - 超时时间
  CAUSE   - 原始异常"
  (error 'http-timeout-error
         :uri uri
         :timeout timeout
         :cause cause))

(defun signal-connection-error (host &key port uri cause)
  "信号连接错误

参数：
  HOST  - 目标主机
  PORT  - 目标端口
  URI   - 请求 URI
  CAUSE - 原始异常"
  (error 'http-connection-error
         :host host
         :port port
         :uri uri
         :cause cause))
