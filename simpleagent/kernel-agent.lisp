;;;; kernel-agent.lisp
;;;; CL-Agent SimpleAgent - Kernel Agent
;;;;
;;;; Overview:
;;;;   Simple chat agent built on top of Kernel.
;;;;   Provides a stateful chat interface with history management.
;;;;
;;;; Usage:
;;;;   (let ((agent (make-kernel-agent kernel :system-prompt "You are helpful.")))
;;;;     (agent-chat agent "Hello!")
;;;;     (agent-chat agent "What did I just say?"))

(in-package #:cl-agent.simpleagent)

;;; ============================================================
;;; Kernel Agent Class
;;; ============================================================

(defclass kernel-agent (base-agent)
  ((kernel
    :initarg :kernel
    :reader agent-kernel
    :documentation "The Kernel instance for tool execution")

   (context
    :initarg :context
    :accessor agent-context
    :documentation "Execution context")

   (history
    :initform nil
    :accessor agent-history
    :documentation "Conversation history")

   (system-prompt
    :initarg :system-prompt
    :initform nil
    :accessor agent-system-prompt
    :documentation "System prompt for the agent")

   (settings
    :initarg :settings
    :initform nil
    :accessor agent-settings
    :documentation "Agent settings plist")

   (callbacks
    :initarg :callbacks
    :initform nil
    :accessor agent-callbacks
    :documentation "Callback functions plist"))

  (:documentation "Simple chat agent using Kernel for tool execution."))

;;; ============================================================
;;; Constructor
;;; ============================================================

(defun make-kernel-agent (kernel &key name system-prompt settings callbacks)
  "Create a Kernel Agent.

Parameters:
  KERNEL        - Kernel instance
  NAME          - Agent name (optional)
  SYSTEM-PROMPT - System prompt (optional)
  SETTINGS      - Settings plist (optional)
  CALLBACKS     - Callback functions (optional)

Returns:
  New kernel-agent instance"
  (let ((agent (make-instance 'kernel-agent
                              :kernel kernel
                              :name (or name "kernel-agent")
                              :system-prompt system-prompt
                              :settings (merge-settings (default-agent-settings) settings)
                              :callbacks callbacks
                              :context (make-context))))
    ;; Add system message to history if provided
    (when system-prompt
      (push (list :role :system :content system-prompt)
            (agent-history agent)))
    agent))

;;; ============================================================
;;; Chat API
;;; ============================================================

(defun agent-chat (agent user-message &key settings)
  "Send a message and get a response.

Parameters:
  AGENT        - Kernel agent
  USER-MESSAGE - User message string
  SETTINGS     - Override settings (optional)

Returns:
  Response text string"
  (let* ((kernel (agent-kernel agent))
         (merged-settings (merge-settings (agent-settings agent) settings))
         (on-tool-call (getf (agent-callbacks agent) :on-tool-call))
         (on-tool-result (getf (agent-callbacks agent) :on-tool-result)))
    ;; Add user message to history
    (push (list :role :user :content user-message)
          (agent-history agent))

    ;; Update context
    (context-add-message (agent-context agent)
                         (list :role :user :content user-message))

    ;; Call kernel
    (let ((result (invoke-kernel kernel
                                 (reverse (agent-history agent))
                                 :settings (list* :system-prompt (agent-system-prompt agent)
                                                  :on-tool-call on-tool-call
                                                  :on-tool-result on-tool-result
                                                  merged-settings)
                                 :context (agent-context agent))))
      ;; Update history with assistant response
      (let ((response-text (getf result :text)))
        (push (list :role :assistant :content response-text)
              (agent-history agent))
        (context-add-message (agent-context agent)
                             (list :role :assistant :content response-text))

        ;; Fire event
        (fire-agent-event
         (make-agent-event-of-type :response agent
                                   :text response-text
                                   :tool-calls (getf result :tool-calls-made)))

        response-text))))

(defun agent-chat-stream (agent user-message callback &key settings)
  "Send a message and stream the response.

Parameters:
  AGENT        - Kernel agent
  USER-MESSAGE - User message string
  CALLBACK     - Function (chunk) called for each chunk
  SETTINGS     - Override settings (optional)

Returns:
  Final response text"
  (let* ((kernel (agent-kernel agent))
         (merged-settings (merge-settings (agent-settings agent) settings)))
    ;; Add user message to history
    (push (list :role :user :content user-message)
          (agent-history agent))

    ;; Call streaming
    (let ((response (invoke-chat-stream kernel
                                        (reverse (agent-history agent))
                                        callback
                                        :settings (list* :system-prompt (agent-system-prompt agent)
                                                        merged-settings)
                                        :context (agent-context agent))))
      ;; Update history
      (let ((response-text (getf response :content)))
        (push (list :role :assistant :content response-text)
              (agent-history agent))
        response-text))))

;;; ============================================================
;;; History Management
;;; ============================================================

(defun agent-reset (agent &key keep-system-prompt)
  "Reset agent state.

Parameters:
  AGENT             - Kernel agent
  KEEP-SYSTEM-PROMPT - Keep system prompt in history

Returns:
  The agent"
  (if (and keep-system-prompt (agent-system-prompt agent))
      (setf (agent-history agent)
            (list (list :role :system :content (agent-system-prompt agent))))
      (setf (agent-history agent) nil))
  (setf (agent-context agent) (make-context))
  agent)

(defun agent-get-history (agent &key (include-system nil))
  "Get conversation history.

Parameters:
  AGENT          - Kernel agent
  INCLUDE-SYSTEM - Include system messages

Returns:
  History list (oldest first)"
  (let ((history (reverse (agent-history agent))))
    (if include-system
        history
        (remove-if (lambda (msg) (eq (getf msg :role) :system))
                   history))))

(defun agent-set-system-prompt (agent prompt)
  "Set or update system prompt.

Parameters:
  AGENT  - Kernel agent
  PROMPT - New system prompt

Returns:
  The agent"
  (setf (agent-system-prompt agent) prompt)
  ;; Update history
  (let ((history (agent-history agent)))
    (if (and history (eq (getf (car (last history)) :role) :system))
        (setf (getf (car (last history)) :content) prompt)
        (setf (agent-history agent)
              (append history (list (list :role :system :content prompt))))))
  agent)

;;; ============================================================
;;; Callback Helpers
;;; ============================================================

(defun agent-on-message (agent callback)
  "Set callback for user messages.

Parameters:
  AGENT    - Kernel agent
  CALLBACK - Function (message)"
  (setf (getf (agent-callbacks agent) :on-message) callback))

(defun agent-on-tool-call (agent callback)
  "Set callback for tool calls.

Parameters:
  AGENT    - Kernel agent
  CALLBACK - Function (name args)"
  (setf (getf (agent-callbacks agent) :on-tool-call) callback))

(defun agent-on-tool-result (agent callback)
  "Set callback for tool results.

Parameters:
  AGENT    - Kernel agent
  CALLBACK - Function (name result)"
  (setf (getf (agent-callbacks agent) :on-tool-result) callback))

(defun agent-on-response (agent callback)
  "Set callback for responses.

Parameters:
  AGENT    - Kernel agent
  CALLBACK - Function (response-text)"
  (setf (getf (agent-callbacks agent) :on-response) callback))

(defun agent-on-error (agent callback)
  "Set callback for errors.

Parameters:
  AGENT    - Kernel agent
  CALLBACK - Function (error)"
  (setf (getf (agent-callbacks agent) :on-error) callback))

;;; ============================================================
;;; Convenience Methods
;;; ============================================================

(defmethod agent-p ((agent kernel-agent))
  "Kernel agents are agents."
  t)

(defun agent-add-plugin (agent plugin-sym)
  "Add a plugin to the agent's kernel.

Parameters:
  AGENT      - Kernel agent
  PLUGIN-SYM - Plugin symbol"
  (kernel-add-plugin (agent-kernel agent) plugin-sym))

(defun agent-add-filter (agent filter)
  "Add a filter to the agent's kernel.

Parameters:
  AGENT  - Kernel agent
  FILTER - Filter function or plist"
  (kernel-add-filter (agent-kernel agent) filter))
