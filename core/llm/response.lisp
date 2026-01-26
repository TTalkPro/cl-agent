;;;; response.lisp
;;;; CL-Agent Core LLM - Unified LLM Response Schema
;;;;
;;;; Overview:
;;;;   Defines unified CLOS classes for LLM responses.
;;;;   These classes provide a consistent interface regardless of the
;;;;   underlying provider (Anthropic, OpenAI, etc.).
;;;;
;;;; Location:
;;;;   core/llm/response.lisp - Type definitions in core to avoid
;;;;   circular dependencies between modules.
;;;;
;;;; Design:
;;;;   - llm-response: Main response container
;;;;   - llm-usage: Token usage statistics
;;;;   - llm-tool-call: Normalized tool call representation
;;;;   - finish-reason: Unified termination reason
;;;;
;;;; IMPORTANT:
;;;;   All functions now work ONLY with CLOS objects (llm-response, llm-usage,
;;;;   llm-tool-call). Plist support has been removed. Use plist-to-llm-response
;;;;   to convert provider output to unified objects.

(in-package #:cl-agent.core)

;;; ============================================================
;;; Finish Reason Type
;;; ============================================================

(deftype finish-reason ()
  "Unified finish/stop reason for LLM responses.

Values:
  :stop         - Normal completion (end_turn, stop)
  :tool-call    - Stopped to make tool calls (tool_use)
  :max-tokens   - Hit token limit (max_tokens, length)
  :content-filter - Content was filtered
  :error        - An error occurred"
  '(member :stop :tool-call :max-tokens :content-filter :error nil))

;;; ============================================================
;;; LLM Usage Class
;;; ============================================================

(defclass llm-usage ()
  ((input-tokens
    :initarg :input-tokens
    :accessor llm-usage-input-tokens
    :initform 0
    :type integer
    :documentation "Number of tokens in the input/prompt")
   (output-tokens
    :initarg :output-tokens
    :accessor llm-usage-output-tokens
    :initform 0
    :type integer
    :documentation "Number of tokens in the output/completion")
   (total-tokens
    :initarg :total-tokens
    :accessor llm-usage-total-tokens
    :initform nil
    :type (or integer null)
    :documentation "Total tokens (computed if not provided)")
   (cache-read-tokens
    :initarg :cache-read-tokens
    :accessor llm-usage-cache-read-tokens
    :initform nil
    :type (or integer null)
    :documentation "Tokens read from cache (Anthropic)")
   (cache-creation-tokens
    :initarg :cache-creation-tokens
    :accessor llm-usage-cache-creation-tokens
    :initform nil
    :type (or integer null)
    :documentation "Tokens written to cache (Anthropic)"))
  (:documentation "Token usage statistics for an LLM response.

Provides unified access to token counts regardless of provider naming:
  - Anthropic: input_tokens, output_tokens
  - OpenAI: prompt_tokens, completion_tokens, total_tokens"))

(defun make-llm-usage (&key (input-tokens 0)
                            (output-tokens 0)
                            total-tokens
                            cache-read-tokens
                            cache-creation-tokens)
  "Create an llm-usage instance.

Parameters:
  INPUT-TOKENS         - Number of input/prompt tokens
  OUTPUT-TOKENS        - Number of output/completion tokens
  TOTAL-TOKENS         - Total tokens (computed if nil)
  CACHE-READ-TOKENS    - Tokens read from cache
  CACHE-CREATION-TOKENS - Tokens written to cache

Returns:
  llm-usage instance"
  (make-instance 'llm-usage
                 :input-tokens input-tokens
                 :output-tokens output-tokens
                 :total-tokens (or total-tokens (+ input-tokens output-tokens))
                 :cache-read-tokens cache-read-tokens
                 :cache-creation-tokens cache-creation-tokens))

(defmethod print-object ((usage llm-usage) stream)
  "Print llm-usage object"
  (print-unreadable-object (usage stream :type t)
    (format stream "in=~A out=~A total=~A"
            (llm-usage-input-tokens usage)
            (llm-usage-output-tokens usage)
            (llm-usage-total-tokens usage))))

;;; ============================================================
;;; LLM Tool Call Class
;;; ============================================================

(defclass llm-tool-call ()
  ((id
    :initarg :id
    :accessor llm-tool-call-id
    :type string
    :documentation "Unique identifier for this tool call")
   (name
    :initarg :name
    :accessor llm-tool-call-name
    :type (or keyword string)
    :documentation "Name of the tool to call")
   (arguments
    :initarg :arguments
    :accessor llm-tool-call-arguments
    :initform nil
    :documentation "Arguments for the tool (parsed, not JSON string)")
   (raw
    :initarg :raw
    :accessor llm-tool-call-raw
    :initform nil
    :documentation "Raw tool call data from provider"))
  (:documentation "Normalized tool call from LLM response.

Tool call format differences:
  - Anthropic: embedded in content blocks as 'tool_use', arguments in 'input' (parsed)
  - OpenAI: separate 'tool_calls' array, arguments in 'arguments' (JSON string)

This class normalizes to:
  - Parsed arguments (hash-table or plist, not JSON string)
  - Keyword name for consistency"))

(defun make-llm-tool-call (&key id name arguments raw)
  "Create an llm-tool-call instance.

Parameters:
  ID        - Unique identifier (generated if nil)
  NAME      - Tool name (string or keyword)
  ARGUMENTS - Tool arguments (parsed, not JSON string)
  RAW       - Raw provider data

Returns:
  llm-tool-call instance"
  (make-instance 'llm-tool-call
                 :id (or id (generate-uuid))
                 :name (if (keywordp name)
                           name
                           (intern (string-upcase (string name)) :keyword))
                 :arguments arguments
                 :raw raw))

(defmethod print-object ((tc llm-tool-call) stream)
  "Print llm-tool-call object"
  (print-unreadable-object (tc stream :type t)
    (format stream "~A id=~A"
            (llm-tool-call-name tc)
            (llm-tool-call-id tc))))

;;; ============================================================
;;; LLM Response Class
;;; ============================================================

(defclass llm-response ()
  ((content
    :initarg :content
    :accessor llm-response-content
    :initform ""
    :type string
    :documentation "Text content of the response")
   (tool-calls
    :initarg :tool-calls
    :accessor llm-response-tool-calls
    :initform nil
    :type list
    :documentation "List of llm-tool-call objects")
   (usage
    :initarg :usage
    :accessor llm-response-usage
    :initform nil
    :type (or llm-usage null)
    :documentation "Token usage statistics")
   (model
    :initarg :model
    :accessor llm-response-model
    :initform nil
    :type (or string null)
    :documentation "Model that generated this response")
   (finish-reason
    :initarg :finish-reason
    :accessor llm-response-finish-reason
    :initform nil
    :type (or keyword null)
    :documentation "Why the response ended (:stop, :tool-call, :max-tokens, etc.)")
   (message-id
    :initarg :message-id
    :accessor llm-response-message-id
    :initform nil
    :type (or string null)
    :documentation "Provider-assigned message ID")
   (raw-response
    :initarg :raw-response
    :accessor llm-response-raw
    :initform nil
    :documentation "Raw response from provider"))
  (:documentation "Unified LLM response container.

Provides consistent access to response data regardless of provider:

Content:
  - Anthropic: extracted from content blocks of type 'text'
  - OpenAI: from choices[0].message.content

Tool Calls:
  - Anthropic: from content blocks of type 'tool_use'
  - OpenAI: from choices[0].message.tool_calls

Usage:
  - Anthropic: usage.input_tokens, usage.output_tokens
  - OpenAI: usage.prompt_tokens, usage.completion_tokens, usage.total_tokens

Finish Reason:
  - Anthropic stop_reason: end_turn -> :stop, tool_use -> :tool-call, max_tokens -> :max-tokens
  - OpenAI finish_reason: stop -> :stop, tool_calls -> :tool-call, length -> :max-tokens"))

(defun make-llm-response (&key (content "")
                               tool-calls
                               usage
                               model
                               finish-reason
                               message-id
                               raw-response)
  "Create an llm-response instance.

Parameters:
  CONTENT       - Text content
  TOOL-CALLS    - List of llm-tool-call objects or plists (converted automatically)
  USAGE         - llm-usage object or plist (converted automatically)
  MODEL         - Model name string
  FINISH-REASON - Finish reason keyword
  MESSAGE-ID    - Provider message ID
  RAW-RESPONSE  - Raw provider response

Returns:
  llm-response instance"
  (make-instance 'llm-response
                 :content (or content "")
                 :tool-calls (mapcar (lambda (tc)
                                       (if (typep tc 'llm-tool-call)
                                           tc
                                           (make-llm-tool-call
                                            :id (getf tc :id)
                                            :name (getf tc :name)
                                            :arguments (getf tc :arguments)
                                            :raw (getf tc :raw))))
                                     (or tool-calls nil))
                 :usage (cond
                          ((typep usage 'llm-usage) usage)
                          ((listp usage)
                           (make-llm-usage
                            :input-tokens (or (getf usage :prompt-tokens)
                                              (getf usage :input-tokens)
                                              0)
                            :output-tokens (or (getf usage :completion-tokens)
                                               (getf usage :output-tokens)
                                               0)
                            :total-tokens (getf usage :total-tokens)
                            :cache-read-tokens (getf usage :cache-read-tokens)
                            :cache-creation-tokens (getf usage :cache-creation-tokens)))
                          (t nil))
                 :model model
                 :finish-reason finish-reason
                 :message-id message-id
                 :raw-response raw-response))

(defmethod print-object ((response llm-response) stream)
  "Print llm-response object"
  (print-unreadable-object (response stream :type t)
    (format stream "~A ~A tool-calls=~A"
            (or (llm-response-model response) "unknown")
            (or (llm-response-finish-reason response) "?")
            (length (llm-response-tool-calls response)))))

;;; ============================================================
;;; Predicates
;;; ============================================================

(defun llm-response-p (obj)
  "Check if OBJ is an llm-response instance"
  (typep obj 'llm-response))

(defun llm-response-has-tool-calls-p (response)
  "Check if response contains tool calls.
RESPONSE must be an llm-response object."
  (not (null (llm-response-tool-calls response))))

(defun llm-response-has-content-p (response)
  "Check if response contains non-empty content.
RESPONSE must be an llm-response object."
  (let ((content (llm-response-content response)))
    (and content (not (string= content "")))))

;;; ============================================================
;;; Normalize Finish Reason
;;; ============================================================

(defun normalize-finish-reason (reason)
  "Normalize provider-specific finish reasons to unified keywords.

Parameters:
  REASON - Finish reason from provider (string or keyword)

Returns:
  Unified finish reason keyword

Mappings:
  stop, end_turn      -> :stop
  tool_calls, tool_use -> :tool-call
  length, max_tokens  -> :max-tokens
  content_filter      -> :content-filter"
  (when reason
    (let ((reason-str (string-downcase (string reason))))
      (cond
        ;; Stop/complete
        ((or (string= reason-str "stop")
             (string= reason-str "end_turn"))
         :stop)
        ;; Tool calls
        ((or (string= reason-str "tool_calls")
             (string= reason-str "tool_use"))
         :tool-call)
        ;; Max tokens
        ((or (string= reason-str "length")
             (string= reason-str "max_tokens"))
         :max-tokens)
        ;; Content filter
        ((string= reason-str "content_filter")
         :content-filter)
        ;; Default - convert to keyword as-is
        (t (intern (string-upcase reason-str) :keyword))))))

;;; ============================================================
;;; Conversion: plist -> llm-response
;;; ============================================================

(defun plist-to-llm-response (plist)
  "Convert a response plist to llm-response object.

Parameters:
  PLIST - Response plist from provider parser

Returns:
  llm-response instance

This function normalizes the various plist formats returned by
different provider parsers into a unified llm-response object."
  (make-llm-response
   :content (getf plist :content)
   :tool-calls (getf plist :tool-calls)
   :usage (getf plist :usage)
   :model (getf plist :model)
   :finish-reason (normalize-finish-reason
                   (or (getf plist :finish-reason)
                       (getf plist :stop-reason)))
   :message-id (or (getf plist :id)
                   (getf plist :message-id))
   :raw-response (getf plist :raw-response)))

;;; ============================================================
;;; Convenience Accessors (llm-response objects only)
;;; ============================================================

(defun llm-response-text (response)
  "Get text content from response.
RESPONSE must be an llm-response object."
  (llm-response-content response))

(defun llm-response-input-tokens (response)
  "Get input token count from response.
RESPONSE must be an llm-response object."
  (let ((usage (llm-response-usage response)))
    (when usage (llm-usage-input-tokens usage))))

(defun llm-response-output-tokens (response)
  "Get output token count from response.
RESPONSE must be an llm-response object."
  (let ((usage (llm-response-usage response)))
    (when usage (llm-usage-output-tokens usage))))

(defun llm-response-total-tokens (response)
  "Get total token count from response.
RESPONSE must be an llm-response object."
  (let ((usage (llm-response-usage response)))
    (when usage (llm-usage-total-tokens usage))))

(defun llm-response-first-tool-call (response)
  "Get the first tool call from response, if any.
RESPONSE must be an llm-response object."
  (first (llm-response-tool-calls response)))

(defun llm-response-get-tool-calls (response)
  "Get all tool calls from response.
RESPONSE must be an llm-response object.
Returns a list of llm-tool-call objects."
  (llm-response-tool-calls response))

(defun llm-response-get-finish-reason (response)
  "Get finish reason from response.
RESPONSE must be an llm-response object."
  (llm-response-finish-reason response))
