;;;; config.lisp
;;;; CL-Agent LLM - Provider Configuration
;;;;
;;;; Overview:
;;;;   Configuration management for LLM providers.
;;;;   Loads configuration from environment variables.

(in-package #:cl-agent.llm)

;;; ============================================================
;;; Default Configuration
;;; ============================================================

(defparameter *default-provider-config*
  '(:anthropic (:api-url "https://api.anthropic.com"
                :model "claude-sonnet-4-20250514"
                :api-key-env "ANTHROPIC_API_KEY"
                :max-tokens 4096
                :temperature 0.7)
    :openai (:api-url "https://api.openai.com/v1"
             :model "gpt-4o"
             :api-key-env "OPENAI_API_KEY"
             :max-tokens 4096
             :temperature 0.7)
    :zhipu (:api-url "https://open.bigmodel.cn/api/paas/v4"
            :model "glm-4-plus"
            :api-key-env "ZHIPU_API_KEY"
            :max-tokens 4096
            :temperature 0.7)
    :ollama (:api-url "http://localhost:11434"
             :model "llama3.2"
             :max-tokens 4096
             :temperature 0.7)
    :gemini (:api-url "https://generativelanguage.googleapis.com/v1beta"
             :model "gemini-pro"
             :api-key-env "GOOGLE_API_KEY"
             :max-tokens 4096
             :temperature 0.7)
    :mistral (:api-url "https://api.mistral.ai/v1"
              :model "mistral-large-latest"
              :api-key-env "MISTRAL_API_KEY"
              :max-tokens 4096
              :temperature 0.7))
  "Default configuration for each provider.")

;;; ============================================================
;;; Configuration Accessors
;;; ============================================================

(defun get-provider-config (provider-name)
  "Get default configuration for a provider.

Parameters:
  PROVIDER-NAME - Provider name keyword

Returns:
  Configuration plist"
  (getf *default-provider-config* provider-name))

(defun get-config-value (provider-name key &optional default)
  "Get a specific configuration value.

Parameters:
  PROVIDER-NAME - Provider name keyword
  KEY           - Configuration key
  DEFAULT       - Default value

Returns:
  Configuration value"
  (let ((config (get-provider-config provider-name)))
    (if config
        (getf config key default)
        default)))

;;; ============================================================
;;; Environment Variable Loading
;;; ============================================================

(defun load-api-key-from-env (provider-name)
  "Load API key from environment variable.

Parameters:
  PROVIDER-NAME - Provider name keyword

Returns:
  API key string, or NIL if not found"
  (let ((env-var (get-config-value provider-name :api-key-env)))
    (when env-var
      (cl-agent.core:get-env env-var))))

(defun load-provider-config-from-env (provider-name)
  "Load provider configuration from environment.

Parameters:
  PROVIDER-NAME - Provider name keyword

Returns:
  Configuration plist with environment overrides"
  (let ((base-config (copy-list (get-provider-config provider-name))))
    ;; Try to load API key
    (let ((api-key (load-api-key-from-env provider-name)))
      (when api-key
        (setf (getf base-config :api-key) api-key)))
    ;; Check for URL override
    (let ((url-env (cl-agent.core:get-env
                    (format nil "~A_API_URL"
                            (string-upcase (symbol-name provider-name))))))
      (when url-env
        (setf (getf base-config :api-url) url-env)))
    ;; Check for model override
    (let ((model-env (cl-agent.core:get-env
                      (format nil "~A_MODEL"
                              (string-upcase (symbol-name provider-name))))))
      (when model-env
        (setf (getf base-config :model) model-env)))
    base-config))

;;; ============================================================
;;; Configuration Validation
;;; ============================================================

(defun validate-provider-config (provider-name config)
  "Validate provider configuration.

Parameters:
  PROVIDER-NAME - Provider name keyword
  CONFIG        - Configuration plist

Returns:
  T if valid

Signals:
  Error if invalid"
  ;; Check for required API key (except for local providers like Ollama)
  (unless (member provider-name '(:ollama :local))
    (let ((api-key (getf config :api-key))
          (api-key-env (getf config :api-key-env)))
      (when (and (null api-key) api-key-env)
        (let ((env-key (cl-agent.core:get-env api-key-env)))
          (unless env-key
            (cl-agent.core:signal-error 'cl-agent.core:missing-api-key-error
                                        :message (format nil "API key not found for ~A. Set ~A environment variable."
                                                        provider-name api-key-env)
                                        :config-key api-key-env))))))
  t)

;;; ============================================================
;;; Configuration Builder
;;; ============================================================

(defun build-provider-config (provider-name &key api-key api-url model max-tokens temperature)
  "Build a complete provider configuration.

Parameters:
  PROVIDER-NAME - Provider name keyword
  API-KEY       - Override API key
  API-URL       - Override API URL
  MODEL         - Override model
  MAX-TOKENS    - Override max tokens
  TEMPERATURE   - Override temperature

Returns:
  Complete configuration plist"
  (let ((config (load-provider-config-from-env provider-name)))
    ;; Apply overrides
    (when api-key (setf (getf config :api-key) api-key))
    (when api-url (setf (getf config :api-url) api-url))
    (when model (setf (getf config :model) model))
    (when max-tokens (setf (getf config :max-tokens) max-tokens))
    (when temperature (setf (getf config :temperature) temperature))
    config))
