;;;; conditions.lisp
;;;; CL-Agent - 统一错误处理系统

(in-package :cl-agent/core)

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

;;; 注：此处曾有 signal-llm-error / signal-config-error /
;;; signal-validation-error / signal-tool-error / ensure-api-key
;;; 五个便捷封装——全库零调用（各处都直接 error / signal-error），
;;; 已删除。

;;; 注：此处曾有 9 个错误处理宏（with-error-handling / with-api-retry /
;;; with-tool-error-handling / with-timeout / with-validation-error-handling /
;;; ignore-errors-or-default / with-error-context /
;;; mvbind-with-error-handling / with-fallback）并在 load 时 (export ...)
;;; 导出。全库零调用，且 load 时 export 违反「导出只发生在 defpackage」
;;; 的纪律（Google CL Style）。已整体删除；错误处理直接用
;;; handler-case / handler-bind，重试用 http 层的 with-retry。

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

;;; error-retryable-p / transient-status-p 的导出在 package-core.lisp
;;; 的 defpackage（此前是 load 时 (export ...)，已收口）。
