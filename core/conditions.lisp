;;;; conditions.lisp
;;;; CL-Agent - 统一错误处理系统

(in-package :cl-agent.core)

;;; ============================================================
;;; 基础错误条件
;;; ============================================================

(define-condition cl-agent-error (error)
  ((message :initarg :message
            :reader error-message
            :initform "An error occurred")
   (timestamp :initarg :timestamp
              :reader error-timestamp
              :initform (local-time:now))
   (cause :initarg :cause
          :reader error-cause
          :initform nil))
  (:report (lambda (condition stream)
             (format stream "CL-Agent Error: ~A"
                     (error-message condition)))))

;;; ============================================================
;;; API 错误
;;; ============================================================

(define-condition api-error (cl-agent-error)
  ((status-code :initarg :status-code
                :reader api-status-code
                :initform nil)
   (response-body :initarg :response-body
                  :reader api-response-body
                  :initform nil)
   (request-url :initarg :request-url
                :reader api-request-url
                :initform nil))
  (:report (lambda (condition stream)
             (format stream "API Error: ~A~%~
                            Status: ~A~%~
                            URL: ~A"
                     (error-message condition)
                     (api-status-code condition)
                     (api-request-url condition)))))

(define-condition llm-error (api-error)
  ((provider :initarg :provider
             :reader llm-error-provider
             :initform nil)
   (model :initarg :model
          :reader llm-error-model
          :initform nil))
  (:report (lambda (condition stream)
             (format stream "LLM Error: ~A~%~
                            Provider: ~A~%~
                            Model: ~A"
                     (error-message condition)
                     (llm-error-provider condition)
                     (llm-error-model condition)))))

(define-condition embedding-error (api-error)
  ()
  (:report (lambda (condition stream)
             (format stream "Embedding Error: ~A"
                     (error-message condition)))))

;;; ============================================================
;;; 配置错误
;;; ============================================================

(define-condition config-error (cl-agent-error)
  ((config-key :initarg :config-key
               :reader config-error-key
               :initform nil))
  (:report (lambda (condition stream)
             (format stream "Configuration Error: ~A~%~
                            Key: ~A"
                     (error-message condition)
                     (config-error-key condition)))))

(define-condition missing-api-key-error (config-error)
  ()
  (:report (lambda (condition stream)
             (format stream "Missing API Key: ~A"
                     (config-error-key condition)))))

;;; ============================================================
;;; 验证错误
;;; ============================================================

(define-condition validation-error (cl-agent-error)
  ((field :initarg :field
          :reader validation-error-field
          :initform nil))
  (:report (lambda (condition stream)
             (format stream "Validation Error: ~A~%~
                            Field: ~A"
                     (error-message condition)
                     (validation-error-field condition)))))

;;; ============================================================
;;; 执行错误
;;; ============================================================

(define-condition execution-error (cl-agent-error)
  ((node-id :initarg :node-id
            :reader execution-error-node
            :initform nil))
  (:report (lambda (condition stream)
             (format stream "Execution Error: ~A~%~
                            Node: ~A"
                     (error-message condition)
                     (execution-error-node condition)))))

(define-condition tool-error (execution-error)
  ((tool-name :initarg :tool-name
              :reader tool-error-name
              :initform nil))
  (:report (lambda (condition stream)
             (format stream "Tool Error: ~A~%~
                            Tool: ~A"
                     (error-message condition)
                     (tool-error-name condition)))))

(define-condition timeout-error (execution-error)
  ()
  (:report (lambda (condition stream)
             (format stream "Timeout Error: ~A"
                     (error-message condition)))))

;;; ============================================================
;;; 便捷函数
;;; ============================================================

(defun signal-error (type &rest rest &key message cause (status-code nil) (url nil) &allow-other-keys)
  "统一错误信号函数

   支持传递任意关键字参数到错误条件"
  (let ((args '()))
    ;; 添加 message
    (when message (push :message args) (push message args))
    ;; 添加 cause
    (when cause (push :cause args) (push cause args))
    ;; 添加 status-code
    (when status-code (push :status-code args) (push status-code args))
    ;; 添加 request-url
    (when url (push :request-url args) (push url args))
    ;; 从 rest 中提取其他关键字参数（除了已知参数）
    (loop for (key value) on rest by #'cddr
          unless (member key '(:message :cause :status-code :url))
            do (push key args) (push value args))
    (apply #'error type (nreverse args))))

(defun signal-llm-error (provider model &key message (status-code nil) (url nil))
  "信号 LLM 错误"
  (signal-error 'llm-error
                :message message
                :provider provider
                :model model
                :status-code status-code
                :url url))

(defun signal-config-error (key &key message)
  "信号配置错误"
  (signal-error 'config-error
                :message (or message (format nil "Invalid configuration: ~A" key))
                :config-key key))

(defun signal-validation-error (field &key message)
  "信号验证错误"
  (signal-error 'validation-error
                :message (or message (format nil "Invalid value for: ~A" field))
                :field field))

(defun signal-tool-error (tool-name &key message)
  "信号工具错误"
  (signal-error 'tool-error
                :message (or message (format nil "Tool execution failed: ~A" tool-name))
                :tool-name tool-name
                :node-id tool-name))

(defun ensure-api-key (provider)
  "确保 API 密钥存在"
  (let ((key (get-env (string provider) nil)))
    (unless key
      (signal-error 'missing-api-key-error
                    :message (format nil "API key not found for provider: ~A" provider)
                    :config-key (format nil "~A-API-KEY" provider)))
    key))

;;; ============================================================
;;; 错误处理宏
;;; ============================================================

(defmacro with-error-handling ((&key (restart-p t)) &body body)
  "统一错误处理宏

  参数：
    RESTART-P - 是否尝试重启恢复（默认 T）

  捕获所有 CL-AGENT-ERROR 并记录日志，可选地尝试恢复"
  `(handler-case
       (progn ,@body)
     (cl-agent-error (condition)
       ;; 记录错误日志
       (log-error "Error: ~A" (error-message condition))
       (when ,restart-p
         (let ((restart (find-restart 'continue-condition condition)))
           (when restart
             (invoke-restart restart))))
       (values nil condition))))

(defmacro with-api-retry ((&key (max-retries 3) (backoff-base 2)) &body body)
  "API 调用重试宏

  参数：
    MAX-RETRIES   - 最大重试次数（默认 3）
    BACKOFF-BASE  - 退避基数（默认 2，指数退避）

  在 API 错误时自动重试，使用指数退避策略"
  `(let ((retries 0))
     (loop
       (handler-case
           (return (progn ,@body))
         (api-error (condition)
           (if (< retries ,max-retries)
               (progn
                 (incf retries)
                 ;; 记录警告日志
                 (log-warn "API error (attempt ~A/~A): ~A"
                           retries ,max-retries (error-message condition))
                 (sleep (* (expt ,backoff-base retries) 0.1)))
               (error condition)))))))

(defmacro with-tool-error-handling ((tool-name &key (on-error :error)) &body body)
  "工具错误处理宏

  参数：
    TOOL-NAME - 工具名称（用于错误消息）
    ON-ERROR  - 错误处理策略
                :error   - 重新发出错误信号（默认）
                :nil     - 返回 nil
                :value   - 返回指定值

  专门处理工具执行中的错误，提供灵活的错误处理策略"
  `(handler-case
       (progn ,@body)
     (tool-error (condition)
       (ecase ,on-error
         (:error
          (error 'tool-error
                 :message (format nil "Tool '~A' failed: ~A"
                                 ,tool-name (error-message condition))
                 :tool-name ,tool-name))
         (:nil
          nil)
         ((:value :values)
          (values nil condition))))))

(defmacro with-timeout ((seconds) &body body)
  "超时控制宏

  参数：
    SECONDS - 超时秒数

  在指定时间内执行，超时则发出 TIMEOUT-ERROR 信号"
  `(let ((start-time (get-internal-real-time))
         (timeout-seconds ,seconds))
     (handler-case
         (progn ,@body)
       (timeout-error ()
         (error 'timeout-error
                :message (format nil "Operation timed out after ~A seconds"
                                timeout-seconds))))))

(defmacro with-validation-error-handling ((field &key (on-error :error)) &body body)
  "验证错误处理宏

  参数：
    FIELD    - 字段名称
    ON-ERROR - 错误处理策略

  专门处理验证错误，提供清晰的错误消息"
  `(handler-case
       (progn ,@body)
     (validation-error (condition)
       (ecase ,on-error
         (:error
          (error 'validation-error
                 :message (format nil "Validation failed for field '~A': ~A"
                                 ,field (error-message condition))
                 :field ,field))
         (:nil
          nil)
         (:value
          (values nil condition))))))

(defmacro ignore-errors-or-default (default-value &body body)
  "忽略错误并返回默认值

  参数：
    DEFAULT-VALUE - 错误时返回的默认值

  简化的错误处理，捕获所有错误并返回默认值"
  `(handler-case
       (progn ,@body)
     (error (condition)
       (declare (ignore condition))
       ,default-value)))

(defmacro with-error-context ((context-info) &body body)
  "带上下文的错误处理

  参数：
    CONTEXT-INFO - 上下文信息字符串

  在错误消息中添加上下文信息，便于调试"
  `(handler-case
       (progn ,@body)
     (cl-agent-error (condition)
       (error (type-of condition)
              :message (format nil "~A~%  Context: ~A"
                              (error-message condition)
                              ,context-info)
              :cause condition))))

(defmacro mvbind-with-error-handling (bindings value-form &body body)
  "带错误处理的多值绑定

  参数：
    BINDINGS    - 绑定列表
    VALUE-FORM  - 值表达式
    BODY        - 主体表单式

  类似 MULTIPLE-VALUE-BIND，但在绑定过程中处理错误"
  `(multiple-value-bind ,bindings
       ,value-form
     (handler-case
         (progn ,@body)
       (cl-agent-error (condition)
         (values nil condition)))))

(defmacro with-fallback ((&key (condition-type 'cl-agent-error)
                                (fallback-value nil)
                                (log-error-p t)) &body body)
  "带回退值的错误处理

  参数：
    CONDITION-TYPE  - 捕获的错误类型（默认 CL-AGENT-ERROR）
    FALLBACK-VALUE  - 回退值（默认 NIL）
    LOG-ERROR-P     - 是否记录错误（默认 T）

  尝试执行主体，失败时返回回退值"
  `(handler-case
       (progn ,@body)
     (,condition-type (condition)
       (when ,log-error-p
         ;; 记录错误日志
         (log-error "Error occurred, using fallback: ~A" (error-message condition)))
       ,fallback-value)))

;;; ============================================================
;;; 导出符号
;;; ============================================================

(export '(with-error-handling
          with-api-retry
          with-tool-error-handling
          with-timeout
          with-validation-error-handling
          ignore-errors-or-default
          with-error-context
          mvbind-with-error-handling
          with-fallback
          signal-error
          signal-llm-error
          signal-config-error
          signal-validation-error
          signal-tool-error
          ensure-api-key))

;;; ============================================================
;;; 统一错误分类（retryable 判断的单一来源）
;;; ============================================================
;;; 参照 clj-agent design/error-model-unification.md：
;;; 一次操作失败 = 一个条件对象 + 一套分类约定，
;;; 任意层的调用方用一致方式决定是否重试。

(defun transient-status-p (status)
  "HTTP 状态码是否为瞬态（可重试）。

瞬态：408 / 409 / 425 / 429 / 5xx
非瞬态：其余 4xx（400 参数错、401/403 鉴权、404 等）"
  (and (integerp status)
       (or (member status '(408 409 425 429))
           (>= status 500))))

(defgeneric error-retryable-p (condition)
  (:documentation "判断错误是否可重试（统一分类入口）。

分类约定：
  - api-error / llm-error：有状态码按 transient-status-p；
    无状态码视为网络层失败 → 可重试
  - timeout-error：可重试
  - validation-error / config-error / missing-api-key-error：不可重试
  - 其他错误：不可重试（保守默认）"))

(defmethod error-retryable-p ((condition error))
  "保守默认：未知错误不重试"
  nil)

(defmethod error-retryable-p ((condition api-error))
  "API 错误：按 HTTP 状态码分类；无状态码视为网络失败（可重试）"
  (let ((status (api-status-code condition)))
    (if status
        (transient-status-p status)
        t)))

(defmethod error-retryable-p ((condition timeout-error))
  "超时：可重试"
  t)

(defmethod error-retryable-p ((condition validation-error))
  "参数验证失败：不可重试"
  nil)

(defmethod error-retryable-p ((condition config-error))
  "配置错误（含缺 API key）：不可重试"
  nil)

(export '(error-retryable-p
          transient-status-p))
