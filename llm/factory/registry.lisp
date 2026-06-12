;;;; registry.lisp
;;;; CL-Agent LLM - Provider Registry
;;;;
;;;; Overview:
;;;;   Central registry for LLM providers.
;;;;   Allows registration and lookup of provider factories.

(in-package #:cl-agent.llm)

;;; ============================================================
;;; Provider Registry
;;; ============================================================

(defvar *provider-registry* (make-hash-table :test 'eq)
  "Registry mapping provider keywords to factory functions.")

(defun register-provider (name factory-fn)
  "Register a provider factory.

Parameters:
  NAME       - Provider name keyword (e.g., :anthropic, :openai)
  FACTORY-FN - Factory function (lambda (&key ...) -> provider)

Returns:
  NAME"
  (setf (gethash name *provider-registry*) factory-fn)
  name)

(defun get-provider-factory (name)
  "Get a provider factory by name.

Parameters:
  NAME - Provider name keyword

Returns:
  Factory function, or NIL if not found"
  (gethash name *provider-registry*))

(defun list-providers ()
  "List all registered provider names.

Returns:
  List of provider name keywords"
  (loop for name being the hash-keys of *provider-registry*
        collect name))

(defun provider-registered-p (name)
  "Check if a provider is registered.

Parameters:
  NAME - Provider name keyword

Returns:
  T if registered, NIL otherwise"
  (not (null (gethash name *provider-registry*))))

;;; ============================================================
;;; Built-in Provider Registration
;;; ============================================================

;; Register built-in providers
(register-provider :anthropic
  (lambda (&rest args)
    (apply #'cl-agent.llm.providers:make-anthropic-provider args)))

(register-provider :openai
  (lambda (&rest args)
    (apply #'cl-agent.llm.providers:make-openai-provider args)))

(register-provider :zhipu
  (lambda (&rest args)
    (apply #'cl-agent.llm.providers:make-zhipu-provider args)))

(register-provider :ollama
  (lambda (&rest args)
    (apply #'cl-agent.llm.providers:make-ollama-provider args)))

(register-provider :dashscope
  (lambda (&rest args)
    (apply #'cl-agent.llm.providers:make-dashscope-provider args)))

(register-provider :minimax
  (lambda (&rest args)
    (apply #'cl-agent.llm.providers:make-minimax-provider args)))

;;; ============================================================
;;; Provider Creation
;;; ============================================================

(defun create-provider (name &rest args)
  "Create a provider by name.

Parameters:
  NAME - Provider name keyword
  ARGS - Arguments to pass to factory

Returns:
  Provider instance

Signals:
  Error if provider not registered"
  (let ((factory (get-provider-factory name)))
    (unless factory
      (error "Unknown provider: ~A. Registered providers: ~A"
             name (list-providers)))
    (apply factory args)))

;;; ============================================================
;;; Provider Aliases
;;; ============================================================

(defvar *provider-aliases* (make-hash-table :test 'equal)
  "Aliases for provider names.")

(defun register-provider-alias (alias name)
  "Register an alias for a provider.

Parameters:
  ALIAS - Alias string or keyword
  NAME  - Actual provider name keyword"
  (setf (gethash (if (keywordp alias)
                     (string-downcase (symbol-name alias))
                     (string-downcase alias))
                 *provider-aliases*)
        name))

(defun resolve-provider-name (name-or-alias)
  "Resolve a provider name or alias to the canonical name.

Parameters:
  NAME-OR-ALIAS - Name or alias

Returns:
  Canonical provider name keyword"
  (if (keywordp name-or-alias)
      (or (gethash (string-downcase (symbol-name name-or-alias))
                   *provider-aliases*)
          name-or-alias)
      (or (gethash (string-downcase name-or-alias)
                   *provider-aliases*)
          (intern (string-upcase name-or-alias) :keyword))))

;; Register common aliases
(register-provider-alias "claude" :anthropic)
(register-provider-alias "gpt" :openai)
(register-provider-alias "glm" :zhipu)
(register-provider-alias "chatglm" :zhipu)
