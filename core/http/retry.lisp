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

(in-package #:cl-agent.http)

;;; ============================================================
;;; 重试配置
;;; ============================================================

(defvar *default-retry-config* nil
  "默认重试配置

设置后，所有 http-request-with-retry 调用都会使用此配置")

(defstruct retry-config
  "重试配置

槽位说明：
  MAX-RETRIES    - 最大重试次数（不含首次请求）
  DELAY          - 初始延迟时间（秒）
  BACKOFF        - 退避策略（:none, :linear, :exponential）
  MAX-DELAY      - 最大延迟时间（秒）
  RETRY-ON       - 重试条件函数或状态码列表
  ON-RETRY       - 重试时的回调函数"
  (max-retries 3 :type fixnum)
  (delay 1.0 :type number)
  (backoff :exponential :type keyword)
  (max-delay 60.0 :type number)
  (retry-on nil)
  (on-retry nil))

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
