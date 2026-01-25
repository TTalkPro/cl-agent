;;;; types.lisp
;;;; CL-Agent Core - Core Data Types
;;;;
;;;; Overview:
;;;;   Defines core data types: ToolCall, Response, Message constructors.
;;;;   These types are used throughout the Kernel system for communication.
;;;;
;;;; Design:
;;;;   - Use plists for simplicity and consistency
;;;;   - Provide constructor functions for type safety
;;;;   - Follow the clj-agent pattern

(in-package #:cl-agent.core)

;;; ============================================================
;;; Message Types
;;; ============================================================

(defun make-message (role content &key tool-calls tool-call-id name)
  "Create a message plist.

Parameters:
  ROLE         - Message role (:system, :user, :assistant, :tool)
  CONTENT      - Message content string
  TOOL-CALLS   - Tool calls list (for assistant messages)
  TOOL-CALL-ID - Tool call ID (for tool response messages)
  NAME         - Optional name for the message sender

Returns:
  Message plist with :role, :content, and optional keys"
  (let ((msg (list :role role :content content)))
    (when tool-calls
      (setf (getf msg :tool-calls) tool-calls))
    (when tool-call-id
      (setf (getf msg :tool-call-id) tool-call-id))
    (when name
      (setf (getf msg :name) name))
    msg))

(defun system-message (content)
  "Create a system message.

Parameters:
  CONTENT - System prompt content

Returns:
  Message plist with :role :system"
  (make-message :system content))

(defun user-message (content &key name)
  "Create a user message.

Parameters:
  CONTENT - User message content
  NAME    - Optional user name

Returns:
  Message plist with :role :user"
  (make-message :user content :name name))

(defun assistant-message (content &key tool-calls)
  "Create an assistant message.

Parameters:
  CONTENT    - Assistant response content
  TOOL-CALLS - Optional tool calls list

Returns:
  Message plist with :role :assistant"
  (make-message :assistant content :tool-calls tool-calls))

(defun tool-message (content tool-call-id &key name)
  "Create a tool result message.

Parameters:
  CONTENT      - Tool execution result
  TOOL-CALL-ID - ID of the tool call this responds to
  NAME         - Optional tool name

Returns:
  Message plist with :role :tool"
  (make-message :tool content :tool-call-id tool-call-id :name name))

;;; ============================================================
;;; Message Predicates
;;; ============================================================

(defun message-p (obj)
  "Check if OBJ is a valid message plist."
  (and (listp obj)
       (getf obj :role)
       (member (getf obj :role) '(:system :user :assistant :tool))))

(defun system-message-p (msg)
  "Check if MSG is a system message."
  (and (message-p msg) (eq (getf msg :role) :system)))

(defun user-message-p (msg)
  "Check if MSG is a user message."
  (and (message-p msg) (eq (getf msg :role) :user)))

(defun assistant-message-p (msg)
  "Check if MSG is an assistant message."
  (and (message-p msg) (eq (getf msg :role) :assistant)))

(defun tool-message-p (msg)
  "Check if MSG is a tool result message."
  (and (message-p msg) (eq (getf msg :role) :tool)))

;;; ============================================================
;;; Message Accessors
;;; ============================================================

(defun message-role (msg)
  "Get the role of a message."
  (getf msg :role))

(defun message-content (msg)
  "Get the content of a message."
  (getf msg :content))

(defun message-tool-calls (msg)
  "Get tool calls from an assistant message."
  (getf msg :tool-calls))

(defun message-tool-call-id (msg)
  "Get tool call ID from a tool message."
  (getf msg :tool-call-id))

;;; ============================================================
;;; ToolCall Type
;;; ============================================================

(defun make-tool-call (id name arguments &key type)
  "Create a tool call plist.

Parameters:
  ID        - Unique identifier for the tool call
  NAME      - Name of the tool/function to call
  ARGUMENTS - Arguments plist or hash-table
  TYPE      - Tool type (default :function)

Returns:
  ToolCall plist"
  (list :id id
        :type (or type :function)
        :name name
        :arguments arguments))

(defun tool-call-p (obj)
  "Check if OBJ is a valid tool call plist."
  (and (listp obj)
       (getf obj :id)
       (getf obj :name)))

(defun tool-call-id (tc)
  "Get the ID of a tool call."
  (getf tc :id))

(defun tool-call-name (tc)
  "Get the name of a tool call."
  (getf tc :name))

(defun tool-call-arguments (tc)
  "Get the arguments of a tool call."
  (getf tc :arguments))

(defun tool-call-type (tc)
  "Get the type of a tool call."
  (or (getf tc :type) :function))

;;; ============================================================
;;; Response Type
;;; ============================================================

(defun make-response (&key content tool-calls usage finish-reason model id)
  "Create a response plist.

Parameters:
  CONTENT       - Text content from the LLM
  TOOL-CALLS    - List of tool calls (if any)
  USAGE         - Token usage plist (:prompt-tokens :completion-tokens :total-tokens)
  FINISH-REASON - Reason for completion (:stop, :tool-calls, :length, etc.)
  MODEL         - Model identifier used
  ID            - Response ID

Returns:
  Response plist"
  (let ((resp nil))
    (when id
      (setf (getf resp :id) id))
    (when model
      (setf (getf resp :model) model))
    (when content
      (setf (getf resp :content) content))
    (when tool-calls
      (setf (getf resp :tool-calls) tool-calls))
    (when usage
      (setf (getf resp :usage) usage))
    (when finish-reason
      (setf (getf resp :finish-reason) finish-reason))
    resp))

(defun response-p (obj)
  "Check if OBJ is a valid response plist."
  (and (listp obj)
       (or (getf obj :content)
           (getf obj :tool-calls))))

(defun response-content (resp)
  "Get the content of a response."
  (getf resp :content))

(defun response-tool-calls (resp)
  "Get tool calls from a response."
  (getf resp :tool-calls))

(defun response-usage (resp)
  "Get token usage from a response."
  (getf resp :usage))

(defun response-finish-reason (resp)
  "Get finish reason from a response."
  (getf resp :finish-reason))

(defun response-has-tool-calls-p (resp)
  "Check if response contains tool calls."
  (and (getf resp :tool-calls)
       (not (null (getf resp :tool-calls)))))

;;; ============================================================
;;; Usage Type
;;; ============================================================

(defun make-usage (&key prompt-tokens completion-tokens total-tokens)
  "Create a usage plist.

Parameters:
  PROMPT-TOKENS     - Number of tokens in the prompt
  COMPLETION-TOKENS - Number of tokens in the completion
  TOTAL-TOKENS      - Total tokens used

Returns:
  Usage plist"
  (list :prompt-tokens (or prompt-tokens 0)
        :completion-tokens (or completion-tokens 0)
        :total-tokens (or total-tokens
                          (+ (or prompt-tokens 0)
                             (or completion-tokens 0)))))

;;; ============================================================
;;; Invoke Result Type
;;; ============================================================

(defun make-invoke-result (&key text tool-calls-made history context)
  "Create an invoke result plist (returned by invoke/invoke-chat-with-tools).

Parameters:
  TEXT            - Final text response
  TOOL-CALLS-MADE - List of tool calls that were executed
  HISTORY         - Message history after execution
  CONTEXT         - Final context state

Returns:
  InvokeResult plist"
  (list :text text
        :tool-calls-made tool-calls-made
        :history history
        :context context))

;;; ============================================================
;;; Plugin Protocol (for class-based plugins)
;;; ============================================================

(defgeneric plugin-name (plugin)
  (:documentation "Get the name of a plugin.

Parameters:
  PLUGIN - Plugin instance

Returns:
  Plugin name (string or keyword)"))

(defgeneric plugin-description (plugin)
  (:documentation "Get the description of a plugin.

Parameters:
  PLUGIN - Plugin instance

Returns:
  Plugin description string"))

(defgeneric plugin-tools (plugin)
  (:documentation "Get the tools provided by a plugin.

Parameters:
  PLUGIN - Plugin instance

Returns:
  List of tool specifications"))

(defgeneric plugin-initialize (plugin context)
  (:documentation "Initialize a plugin with context.

Parameters:
  PLUGIN  - Plugin instance
  CONTEXT - Initialization context

Returns:
  T on success"))

(defgeneric plugin-shutdown (plugin)
  (:documentation "Shutdown a plugin and cleanup resources.

Parameters:
  PLUGIN - Plugin instance

Returns:
  T on success"))
