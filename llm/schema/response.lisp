;;;; response.lisp
;;;; CL-Agent LLM - Unified Response Schema (Re-export from Core)
;;;;
;;;; Overview:
;;;;   This file re-exports the unified LLM response schema from cl-agent.core.
;;;;   The actual implementation is in core/response.lisp to avoid circular
;;;;   dependencies between modules.
;;;;
;;;; Design:
;;;;   All response classes (llm-response, llm-usage, llm-tool-call) are
;;;;   defined in cl-agent.core and re-exported here for backward compatibility.

(in-package #:cl-agent.llm)

;; All symbols are already exported from cl-agent.core and imported via :use.
;; This file exists for documentation purposes and to maintain the module structure.

;; The following are available from cl-agent.core:
;;
;; Classes:
;;   - llm-response: Main response container
;;   - llm-usage: Token usage statistics
;;   - llm-tool-call: Normalized tool call representation
;;
;; Constructors:
;;   - make-llm-response
;;   - make-llm-usage
;;   - make-llm-tool-call
;;
;; Type:
;;   - finish-reason: Unified termination reason type
;;
;; Predicates:
;;   - llm-response-p
;;   - llm-response-has-tool-calls-p
;;   - llm-response-has-content-p
;;
;; Accessors:
;;   - llm-response-content, llm-response-tool-calls, llm-response-usage
;;   - llm-response-model, llm-response-finish-reason, llm-response-message-id
;;   - llm-response-raw
;;   - llm-usage-input-tokens, llm-usage-output-tokens, llm-usage-total-tokens
;;   - llm-usage-cache-read-tokens, llm-usage-cache-creation-tokens
;;   - llm-tool-call-id, llm-tool-call-name, llm-tool-call-arguments, llm-tool-call-raw
;;
;; Conversion functions:
;;   - plist-to-llm-response
;;   - llm-response-to-plist
;;   - normalize-finish-reason
;;
;; Convenience accessors (work with both objects and plists):
;;   - llm-response-text
;;   - llm-response-input-tokens
;;   - llm-response-output-tokens
;;   - llm-response-total-tokens
;;   - llm-response-first-tool-call
;;   - llm-response-get-tool-calls
;;   - llm-response-get-finish-reason
