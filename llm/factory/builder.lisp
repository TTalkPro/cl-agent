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
;;; Service Creation
;;; ============================================================

(defun create-service (provider-name &rest args &key model api-key api-url &allow-other-keys)
  "Create a Kernel service from a provider specification.

This is the bridge between cl-agent-llm and cl-agent.kernel.

Parameters:
  PROVIDER-NAME - Provider name keyword (:anthropic, :openai, etc.)
  MODEL         - Model name (optional)
  API-KEY       - API key (optional, uses env var)
  API-URL       - API URL (optional, uses default)
  Other keyword args passed to provider factory.

Returns:
  Service plist suitable for Kernel

Usage:
  (create-service :anthropic :model \"claude-sonnet-4-20250514\")
  (create-service :openai :model \"gpt-4o\")"
  (declare (ignore model api-key api-url))
  (let* ((resolved-name (resolve-provider-name provider-name))
         (provider (apply #'create-provider resolved-name args)))
    (cl-agent.kernel:service-from-provider provider)))

(defun create-service-from-builder (builder)
  "Create a Kernel service from a provider builder.

Parameters:
  BUILDER - Provider builder

Returns:
  Service plist"
  (let ((provider (build-provider builder)))
    (cl-agent.kernel:service-from-provider provider)))

;;; ============================================================
;;; Convenience Functions
;;; ============================================================

(defun make-anthropic-service (&key (model "claude-sonnet-4-20250514") api-key)
  "Create an Anthropic service.

Parameters:
  MODEL   - Model name
  API-KEY - API key (optional, uses env var)

Returns:
  Service plist"
  (create-service :anthropic :model model :api-key api-key))

(defun make-openai-service (&key (model "gpt-4o") api-key)
  "Create an OpenAI service.

Parameters:
  MODEL   - Model name
  API-KEY - API key (optional, uses env var)

Returns:
  Service plist"
  (create-service :openai :model model :api-key api-key))

(defun make-zhipu-service (&key (model "glm-4-plus") api-key)
  "Create a ZhipuAI service.

Parameters:
  MODEL   - Model name
  API-KEY - API key (optional, uses env var)

Returns:
  Service plist"
  (create-service :zhipu :model model :api-key api-key))

(defun make-mock-service (&key responses)
  "Create a mock service for testing.

Parameters:
  RESPONSES - List of response plists to return in sequence

Returns:
  Service plist"
  (let ((response-queue (copy-list responses))
        (call-count 0))
    (cl-agent.kernel:make-service
     :provider :mock
     :config (list :responses responses)
     :chat-fn (lambda (messages tools settings)
                (declare (ignore messages tools settings))
                (incf call-count)
                (if response-queue
                    (pop response-queue)
                    (list :content (format nil "Mock response ~A" call-count)
                          :tool-calls nil))))))
