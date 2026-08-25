;;;; retry.lisp
;;;; CL-Agent HTTP - 重试策略
;;;;
;;;; 概述：
;;;;   提供 HTTP 请求的重试机制
;;;;
;;;; 特性：
;;;;   - 可配置的重试次数
;;;;   - 指数退避策略
;;;;   - 可定制的重试条件
;;;;   - 重试回调
;;;;
;;;; 使用示例：
;;;;   (http-request-with-retry "https://api.example.com/data"
;;;;     :retry-config (make-retry-config :max-retries 3
;;;;                                      :delay 1.0
;;;;                                      :backoff :exponential))

(in-package #:cl-agent/core)

;;; ============================================================
;;; 重试配置
;;; ============================================================

(defvar *default-retry-config* nil
  "默认重试配置

设置后，所有 http-request-with-retry 调用都会使用此配置")

(defclass retry-config ()
  ((max-retries
    :initarg :max-retries
    :initform 3
    :type fixnum
    :reader retry-config-max-retries
    :documentation "最大重试次数（**不含**首次请求）")
   (delay
    :initarg :delay
    :initform 1.0
    :type number
    :reader retry-config-delay
    :documentation "初始延迟时间（秒）")
   (backoff
    :initarg :backoff
    :initform :exponential
    :type keyword
    :reader retry-config-backoff
    :documentation "退避策略：:none | :linear | :exponential")
   (max-delay
    :initarg :max-delay
    :initform 60.0
    :type number
    :reader retry-config-max-delay
    :documentation "最大延迟时间（秒）")
   (retry-on
    :initarg :retry-on
    :initform nil
    :reader retry-config-retry-on
    :documentation "重试条件：函数 (condition) → boolean，或状态码列表。
NIL = 用 default-retry-predicate")
   (on-retry
    :initarg :on-retry
    :initform nil
    :reader retry-config-on-retry
    :documentation "重试回调 (condition attempt delay) → nil"))
  (:documentation "HTTP 传输层的重试配置。

  注意与 ChatModel 层的 retry-policy（core/chat/model.lisp）区分：
  - retry-config  管一次 **HTTP 请求**的重试，语义是「额外重试几次」
                  （max-retries 不含首次）
  - retry-policy  管一次 **模型调用**的重试，语义是「总共尝试几次」
                  （max-attempts 含首次），分类走 error-retryable-p

  两层各自有重试是刻意的：HTTP 层能看到连接与状态码，模型层能看到
  这是一次语义上的模型调用。调用方通常只配后者。"))

(defun make-retry-config (&key (max-retries 3) (delay 1.0) (backoff :exponential)
                               (max-delay 60.0) retry-on on-retry)
  "创建 HTTP 层重试配置。"
  (make-instance 'retry-config
                 :max-retries max-retries :delay delay :backoff backoff
                 :max-delay max-delay :retry-on retry-on :on-retry on-retry))

(definvariants retry-config (self)
  ;; 注意与 ChatModel 层 retry-policy 的语义差：这里的 max-retries 是
  ;; **额外**重试次数（不含首次），所以 0 是合法的「不重试」。
  (require-that self (>= (retry-config-max-retries self) 0)
                "max-retries 是额外重试次数（不含首次），不能为负")
  (require-member self 'backoff '(:none :linear :exponential)
                  "退避策略，calculate-delay 按它分派")
  (require-that self (>= (retry-config-delay self) 0) "delay 不能为负")
  (require-that self (>= (retry-config-max-delay self) 0) "max-delay 不能为负"))

(defmethod print-object ((config retry-config) stream)
  (print-unreadable-object (config stream :type t)
    (format stream "~Ax ~,2Fs ~(~A~)"
            (retry-config-max-retries config)
            (retry-config-delay config)
            (retry-config-backoff config))))

;;; ============================================================
;;; 退避策略
;;; ============================================================

(defun calculate-delay (config attempt)
  "计算第 N 次重试的延迟时间

参数：
  CONFIG  - retry-config 对象
  ATTEMPT - 重试次数（从 1 开始）

返回：
  延迟时间（秒）"
  (let* ((base-delay (retry-config-delay config))
         (max-delay (retry-config-max-delay config))
         (backoff (retry-config-backoff config))
         (delay (case backoff
                  (:none base-delay)
                  (:linear (* base-delay attempt))
                  (:exponential (* base-delay (expt 2 (1- attempt))))
                  (otherwise base-delay))))
    ;; 添加抖动（±10%）
    (let ((jitter (* delay 0.1 (- (random 2.0) 1.0))))
      (min (+ delay jitter) max-delay))))

;;; ============================================================
;;; 重试条件
;;; ============================================================

(defun default-retry-predicate (condition)
  "默认重试条件判断

参数：
  CONDITION - 错误条件

返回：
  t（应重试）或 nil（不重试）

默认规则：
  - 5xx 服务端错误：重试
  - 超时错误：重试
  - 连接错误：重试
  - 429 Too Many Requests：重试
  - 其他 4xx 错误：不重试"
  (typecase condition
    (http-server-error t)
    (http-timeout-error t)
    (http-connection-error t)
    (http-client-error
     (let ((status (http-error-status condition)))
       (= status 429)))  ; Too Many Requests
    (otherwise nil)))

(defun should-retry-p (condition config)
  "检查是否应该重试

参数：
  CONDITION - 错误条件
  CONFIG    - retry-config 对象

返回：
  t 或 nil"
  (let ((retry-on (retry-config-retry-on config)))
    (cond
      ;; 自定义函数
      ((functionp retry-on)
       (funcall retry-on condition))

      ;; 状态码列表
      ((and (listp retry-on)
            (typep condition 'http-error))
       (member (http-error-status condition) retry-on))

      ;; 使用默认判断
      (t (default-retry-predicate condition)))))

;;; ============================================================
;;; 重试执行
;;; ============================================================

(defmacro with-retry ((&key (config '*default-retry-config*)) &body body)
  "带重试策略执行代码块

参数：
  CONFIG - retry-config 对象或返回它的表达式

示例：
  (with-retry (:config (make-retry-config :max-retries 3))
    (http-request url))"
  (let ((cfg (gensym "config"))
        (attempt (gensym "attempt"))
        (max-attempts (gensym "max"))
        (result (gensym "result"))
        (success (gensym "success")))
    `(let* ((,cfg (or ,config (make-retry-config)))
            (,max-attempts (1+ (retry-config-max-retries ,cfg)))
            (,result nil)
            (,success nil))
       (loop for ,attempt from 1 to ,max-attempts
             until ,success
             do (handler-case
                    (progn
                      (setf ,result (progn ,@body))
                      (setf ,success t))
                  (error (e)
                    (if (and (< ,attempt ,max-attempts)
                             (should-retry-p e ,cfg))
                        (progn
                          ;; 调用重试回调
                          (when (retry-config-on-retry ,cfg)
                            (funcall (retry-config-on-retry ,cfg)
                                     ,attempt e))
                          ;; 等待
                          (sleep (calculate-delay ,cfg ,attempt)))
                        ;; 不重试，重新抛出
                        (error e)))))
       ,result)))

(defun http-request-with-retry (url &key
                                      (method :get)
                                      headers
                                      body
                                      (content-type nil)
                                      (timeout *default-timeout*)
                                      (parse-json t)
                                      (retry-config *default-retry-config*))
  "带重试策略的 HTTP 请求

参数：
  URL          - 请求 URL
  METHOD       - HTTP 方法
  HEADERS      - 请求头
  BODY         - 请求体
  CONTENT-TYPE - 内容类型
  TIMEOUT      - 超时时间
  PARSE-JSON   - 是否自动解析 JSON
  RETRY-CONFIG - 重试配置

返回：
  http-response 结构

示例：
  ;; 使用默认重试配置
  (http-request-with-retry \"https://api.example.com/data\")

  ;; 自定义重试配置
  (http-request-with-retry \"https://api.example.com/data\"
    :retry-config (make-retry-config
                    :max-retries 5
                    :delay 2.0
                    :backoff :exponential
                    :on-retry (lambda (attempt error)
                                (format t \"重试 #~A: ~A~%\" attempt error))))"
  (let ((config (or retry-config (make-retry-config))))
    (with-retry (:config config)
      (http-request url
                    :method method
                    :headers headers
                    :body body
                    :content-type content-type
                    :timeout timeout
                    :parse-json parse-json))))

;;; ============================================================
;;; 预定义重试配置
;;; ============================================================

(defun make-aggressive-retry-config ()
  "创建激进的重试配置

特点：
  - 5 次重试
  - 指数退避
  - 对所有可恢复错误重试"
  (make-retry-config
   :max-retries 5
   :delay 1.0
   :backoff :exponential
   :max-delay 30.0))

(defun make-conservative-retry-config ()
  "创建保守的重试配置

特点：
  - 2 次重试
  - 线性退避
  - 仅对服务端错误重试"
  (make-retry-config
   :max-retries 2
   :delay 2.0
   :backoff :linear
   :max-delay 10.0
   :retry-on (lambda (c)
               (typep c 'http-server-error))))

(defun make-no-retry-config ()
  "创建不重试配置"
  (make-retry-config :max-retries 0))
