;;;; provider.lisp
;;;; CL-Agent Core LLM - ILLMProvider Protocol
;;;;
;;;; Overview:
;;;;   Defines the generic functions protocol for LLM providers.
;;;;   This is the interface that all LLM provider implementations
;;;;   must satisfy.
;;;;
;;;; Location:
;;;;   core/llm/provider.lisp - Protocol definitions in core to avoid
;;;;   circular dependencies between modules.
;;;;
;;;; Design:
;;;;   Following Common Lisp idioms, we use defgeneric to define
;;;;   the protocol. Provider implementations in cl-agent-llm
;;;;   will specialize these methods.

(in-package #:cl-agent.core)

;;; ============================================================
;;; Core LLM Protocol
;;; ============================================================

(defgeneric llm-chat (provider messages &key max-tokens temperature model tools system)
  (:documentation "Send a chat request to an LLM.

Parameters:
  PROVIDER    - Provider instance (implements this generic function)
  MESSAGES    - List of message plists
  MAX-TOKENS  - Maximum tokens in response (optional)
  TEMPERATURE - Temperature parameter (optional)
  MODEL       - Model name (optional, uses provider default)
  TOOLS       - List of tool schemas (optional)
  SYSTEM      - System prompt (optional)

Returns:
  Response plist:
    :content     - Text content
    :tool-calls  - Tool call list (if any)
    :usage       - Token usage plist (if available)
    :finish-reason - Reason for completion

Note:
  This generic function is defined in cl-agent.kernel but
  specialized by LLM provider modules (cl-agent-llm).
  Kernel uses this protocol to communicate with LLMs without
  knowing specific provider implementations."))

(defgeneric llm-chat-stream (provider messages callback &key max-tokens temperature model tools system)
  (:documentation "Send a streaming chat request to an LLM.

Parameters:
  PROVIDER    - Provider instance
  MESSAGES    - List of message plists
  CALLBACK    - Function (chunk) called for each chunk
  MAX-TOKENS  - Maximum tokens in response (optional)
  TEMPERATURE - Temperature parameter (optional)
  MODEL       - Model name (optional)
  TOOLS       - List of tool schemas (optional)
  SYSTEM      - System prompt (optional)

Returns:
  Final response plist (same as llm-chat)

Note:
  CALLBACK is called with each streaming chunk as a plist:
    :delta    - Content delta
    :done     - T when stream is complete"))

;;; ============================================================
;;; Provider Configuration Protocol
;;; ============================================================

(defgeneric provider-name (provider)
  (:documentation "Get the name of the provider.

Parameters:
  PROVIDER - Provider instance

Returns:
  Provider name string (e.g., \"anthropic\", \"openai\")"))

(defgeneric provider-model (provider)
  (:documentation "Get the default model of the provider.

Parameters:
  PROVIDER - Provider instance

Returns:
  Default model name string"))

(defgeneric provider-api-key (provider)
  (:documentation "Get the API key of the provider.

Parameters:
  PROVIDER - Provider instance

Returns:
  API key string"))

(defgeneric provider-base-url (provider)
  (:documentation "Get the base URL of the provider.

Parameters:
  PROVIDER - Provider instance

Returns:
  Base URL string"))

(defgeneric provider-supports-tools-p (provider)
  (:documentation "Check if the provider supports tool/function calling.

Parameters:
  PROVIDER - Provider instance

Returns:
  T if tools are supported, NIL otherwise"))

(defgeneric provider-supports-streaming-p (provider)
  (:documentation "Check if the provider supports streaming.

Parameters:
  PROVIDER - Provider instance

Returns:
  T if streaming is supported, NIL otherwise"))

;;; ============================================================
;;; Tool Schema Protocol
;;; ============================================================

(defgeneric provider-format-tools (provider tools)
  (:documentation "Format tool schemas for the provider's API.

Parameters:
  PROVIDER - Provider instance
  TOOLS    - List of tool schemas in generic format

Returns:
  Tool schemas formatted for the specific provider API.
  Different providers (OpenAI, Anthropic) have different formats."))

(defgeneric provider-parse-tool-calls (provider response)
  (:documentation "Parse tool calls from provider response.

Parameters:
  PROVIDER - Provider instance
  RESPONSE - Raw API response

Returns:
  List of normalized tool call plists:
    :id        - Tool call ID
    :name      - Function name
    :arguments - Arguments plist"))

;;; ============================================================
;;; Default Method Implementations
;;; ============================================================

(defmethod provider-supports-tools-p ((provider t))
  "Default: assume tools are not supported."
  nil)

(defmethod provider-supports-streaming-p ((provider t))
  "Default: assume streaming is not supported."
  nil)

(defmethod llm-chat-stream ((provider t) messages callback &key max-tokens temperature model tools system)
  "Default streaming implementation: fall back to non-streaming."
  (declare (ignore callback))
  (llm-chat provider messages
            :max-tokens max-tokens
            :temperature temperature
            :model model
            :tools tools
            :system system))

;;; ============================================================
;;; Provider Capability Checking
;;; ============================================================

(defun check-provider-tools-support (provider)
  "Check if provider supports tools, signal error if not.

Parameters:
  PROVIDER - Provider instance

Signals:
  Error if tools not supported"
  (unless (provider-supports-tools-p provider)
    (error "Provider ~A does not support tool calling"
           (provider-name provider))))

(defun check-provider-streaming-support (provider)
  "Check if provider supports streaming, signal error if not.

Parameters:
  PROVIDER - Provider instance

Signals:
  Error if streaming not supported"
  (unless (provider-supports-streaming-p provider)
    (error "Provider ~A does not support streaming"
           (provider-name provider))))

;;; ============================================================
;;; Provider Base Class
;;; ============================================================

(defclass base-llm-provider ()
  ((name
    :initarg :name
    :reader provider-name
    :documentation "Provider name")

   (api-key
    :initarg :api-key
    :accessor provider-api-key
    :documentation "API key for authentication")

   (base-url
    :initarg :base-url
    :accessor provider-base-url
    :documentation "Base URL for API requests")

   (model
    :initarg :model
    :accessor provider-model
    :documentation "Default model to use")

   (supports-tools
    :initarg :supports-tools
    :initform t
    :accessor provider-supports-tools-p
    :documentation "Whether provider supports tool calling")

   (supports-streaming
    :initarg :supports-streaming
    :initform t
    :accessor provider-supports-streaming-p
    :documentation "Whether provider supports streaming")

   (default-max-tokens
    :initarg :default-max-tokens
    :initform 4096
    :accessor provider-default-max-tokens
    :documentation "Default max tokens")

   (default-temperature
    :initarg :default-temperature
    :initform 0.7
    :accessor provider-default-temperature
    :documentation "Default temperature"))

  (:documentation "Base class for LLM providers.
Provides common slots and default method implementations."))

(defmethod print-object ((provider base-llm-provider) stream)
  "Print provider in a readable format."
  (print-unreadable-object (provider stream :type t :identity t)
    (format stream "~A ~A" (provider-name provider) (provider-model provider))))
