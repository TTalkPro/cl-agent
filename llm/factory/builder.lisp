;;;; builder.lisp
;;;; CL-Agent LLM - Provider Builder
;;;;
;;;; Overview:
;;;;   Fluent builder for creating LLM providers and services.
;;;;   Provides a convenient API for provider construction.

(in-package #:cl-agent.llm)

;;; ============================================================
;;; Provider Builder Class
;;; ============================================================

(defclass provider-builder ()
  ((provider-name
    :initarg :provider-name
    :initform nil
    :accessor builder-provider-name)
   (api-key
    :initarg :api-key
    :initform nil
    :accessor builder-api-key)
   (api-url
    :initarg :api-url
    :initform nil
    :accessor builder-api-url)
   (model
    :initarg :model
    :initform nil
    :accessor builder-model)
   (max-tokens
    :initarg :max-tokens
    :initform nil
    :accessor builder-max-tokens)
   (temperature
    :initarg :temperature
    :initform nil
    :accessor builder-temperature)
   (timeout
    :initarg :timeout
    :initform 120
    :accessor builder-timeout)
   (extra-config
    :initarg :extra-config
    :initform nil
    :accessor builder-extra-config))
  (:documentation "Builder for constructing LLM providers."))

;;; ============================================================
;;; Builder Construction
;;; ============================================================

(defun create-provider-builder (&optional provider-name)
  "Create a new provider builder.

Parameters:
  PROVIDER-NAME - Optional initial provider name

Returns:
  New provider-builder instance

Usage:
  (-> (create-provider-builder :anthropic)
      (with-model \"claude-sonnet-4-20250514\")
      (with-temperature 0.5)
      (build-provider))"
  (make-instance 'provider-builder :provider-name provider-name))

;;; ============================================================
;;; Builder Methods
;;; ============================================================

(defgeneric for-provider (builder provider-name)
  (:documentation "Set the provider type."))

(defmethod for-provider ((builder provider-builder) provider-name)
  "Set the provider type."
  (setf (builder-provider-name builder) provider-name)
  builder)

(defgeneric with-api-key (builder api-key)
  (:documentation "Set the API key."))

(defmethod with-api-key ((builder provider-builder) api-key)
  "Set the API key."
  (setf (builder-api-key builder) api-key)
  builder)

(defgeneric with-api-url (builder api-url)
  (:documentation "Set the API URL."))

(defmethod with-api-url ((builder provider-builder) api-url)
  "Set the API URL."
  (setf (builder-api-url builder) api-url)
  builder)

(defgeneric with-model (builder model)
  (:documentation "Set the model."))

(defmethod with-model ((builder provider-builder) model)
  "Set the model."
  (setf (builder-model builder) model)
  builder)

(defgeneric with-max-tokens (builder max-tokens)
  (:documentation "Set max tokens."))

(defmethod with-max-tokens ((builder provider-builder) max-tokens)
  "Set max tokens."
  (setf (builder-max-tokens builder) max-tokens)
  builder)

(defgeneric with-temperature (builder temperature)
  (:documentation "Set temperature."))

(defmethod with-temperature ((builder provider-builder) temperature)
  "Set temperature."
  (setf (builder-temperature builder) temperature)
  builder)

(defgeneric builder-with-timeout (builder timeout)
  (:documentation "Set request timeout."))

(defmethod builder-with-timeout ((builder provider-builder) timeout)
  "Set request timeout."
  (setf (builder-timeout builder) timeout)
  builder)

(defgeneric with-extra-config (builder key value)
  (:documentation "Add extra configuration."))

(defmethod with-extra-config ((builder provider-builder) key value)
  "Add extra configuration."
  (setf (getf (builder-extra-config builder) key) value)
  builder)

;;; ============================================================
;;; Build Methods
;;; ============================================================

(defgeneric build-provider (builder)
  (:documentation "Build the provider from builder state."))

(defmethod build-provider ((builder provider-builder))
  "Build the provider."
  (let ((provider-name (or (builder-provider-name builder)
                           (error "Provider name not specified"))))
    (apply #'create-provider provider-name
           (append
            (when (builder-api-key builder)
              (list :api-key (builder-api-key builder)))
            (when (builder-api-url builder)
              (list :api-url (builder-api-url builder)))
            (when (builder-model builder)
              (list :model (builder-model builder)))
            (when (builder-timeout builder)
              (list :timeout (builder-timeout builder)))
            (builder-extra-config builder)))))

;;; ============================================================
;;; ChatModel 桥接（对标 Spring AI ChatModel 自动装配）
;;; ============================================================

(defun create-chat-model (provider-name &rest args
                          &key model api-key api-url options &allow-other-keys)
  "从提供商规格创建 ChatModel（cl-agent-llm 与 cl-agent.chat 的桥梁）。

参数：
  PROVIDER-NAME - 提供商关键字（:anthropic、:openai 等）
  MODEL         - 模型名（可选）
  API-KEY       - API 密钥（可选，默认取环境变量）
  API-URL       - API 地址（可选，默认取提供商默认值）
  OPTIONS       - 默认 chat-options（可选）
  其余关键字参数透传给提供商工厂。

返回：
  cl-agent.chat:provider-chat-model 实例

用法：
  (create-chat-model :anthropic :model \"claude-sonnet-4-20250514\")
  (create-chat-model :openai :model \"gpt-4o\"
                     :options (cl-agent.chat:make-chat-options :temperature 0.3))"
  (declare (ignore model api-key api-url))
  (let* ((resolved-name (resolve-provider-name provider-name))
         (provider (apply #'create-provider resolved-name
                          (alexandria:remove-from-plist args :options))))
    (cl-agent.chat:make-provider-chat-model provider :default-options options)))

(defun create-chat-model-from-builder (builder &key options)
  "从 provider builder 创建 ChatModel。

参数：
  BUILDER - Provider builder
  OPTIONS - 默认 chat-options（可选）

返回：
  cl-agent.chat:provider-chat-model 实例"
  (cl-agent.chat:make-provider-chat-model (build-provider builder)
                                          :default-options options))
