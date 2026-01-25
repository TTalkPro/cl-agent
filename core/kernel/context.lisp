;;;; context.lisp
;;;; CL-Agent Kernel - Context Management
;;;;
;;;; Overview:
;;;;   Context is a first-class object that tracks:
;;;;   - Variables: Key-value store for execution state
;;;;   - Messages: Working message buffer
;;;;   - History: Append-only log of all messages
;;;;   - Trace: Execution trace for debugging
;;;;
;;;; Design:
;;;;   Following the clj-agent pattern, Context encapsulates all
;;;;   state needed during a conversation/execution session.

(in-package #:cl-agent.kernel)

;;; ============================================================
;;; Context Class
;;; ============================================================

(defclass context ()
  ((variables
    :initform (make-hash-table :test 'equal)
    :accessor context-variables
    :documentation "Key-value store for execution variables")

   (messages
    :initarg :messages
    :initform nil
    :accessor context-messages
    :documentation "Working message buffer for current conversation")

   (history
    :initform nil
    :accessor context-history
    :documentation "Append-only log of all messages (for debugging/replay)")

   (trace
    :initform nil
    :accessor context-trace
    :documentation "Execution trace for debugging")

   (metadata
    :initarg :metadata
    :initform nil
    :accessor context-metadata
    :documentation "Additional context metadata plist")

   (created-at
    :initform (get-universal-time)
    :reader context-created-at
    :documentation "Timestamp when context was created")

   (lock
    :initform (bt:make-lock "context-lock")
    :reader context-lock
    :documentation "Thread-safe lock for context modifications"))

  (:documentation "Execution context for Kernel operations.
Tracks variables, messages, history, and execution trace."))

;;; ============================================================
;;; Constructor
;;; ============================================================

(defun make-context (&key messages metadata variables)
  "Create a new Context instance.

Parameters:
  MESSAGES  - Initial message list
  METADATA  - Context metadata plist
  VARIABLES - Initial variables (alist or hash-table)

Returns:
  New context instance"
  (let ((ctx (make-instance 'context
                            :messages messages
                            :metadata metadata)))
    ;; Initialize variables if provided
    (when variables
      (etypecase variables
        (hash-table
         (setf (context-variables ctx) (alexandria:copy-hash-table variables)))
        (list
         (loop for (k v) on variables by #'cddr
               do (setf (gethash k (context-variables ctx)) v)))))
    ctx))

;;; ============================================================
;;; Variable Operations
;;; ============================================================

(defun context-get (context key &optional default)
  "Get a variable from context.

Parameters:
  CONTEXT - Context instance
  KEY     - Variable key
  DEFAULT - Default value if not found

Returns:
  Variable value or default"
  (bt:with-lock-held ((context-lock context))
    (gethash key (context-variables context) default)))

(defun (setf context-get) (value context key)
  "Set a variable in context.

Parameters:
  VALUE   - Value to set
  CONTEXT - Context instance
  KEY     - Variable key

Returns:
  The value"
  (bt:with-lock-held ((context-lock context))
    (setf (gethash key (context-variables context)) value)))

(defun context-set (context key value)
  "Set a variable in context (functional style).

Parameters:
  CONTEXT - Context instance
  KEY     - Variable key
  VALUE   - Value to set

Returns:
  The context (for chaining)"
  (setf (context-get context key) value)
  context)

(defun context-remove (context key)
  "Remove a variable from context.

Parameters:
  CONTEXT - Context instance
  KEY     - Variable key

Returns:
  T if removed, NIL if not found"
  (bt:with-lock-held ((context-lock context))
    (remhash key (context-variables context))))

(defun context-has-p (context key)
  "Check if context has a variable.

Parameters:
  CONTEXT - Context instance
  KEY     - Variable key

Returns:
  T if present, NIL otherwise"
  (bt:with-lock-held ((context-lock context))
    (nth-value 1 (gethash key (context-variables context)))))

(defun context-variables-alist (context)
  "Get all variables as an alist.

Parameters:
  CONTEXT - Context instance

Returns:
  Alist of (key . value) pairs"
  (bt:with-lock-held ((context-lock context))
    (alexandria:hash-table-alist (context-variables context))))

;;; ============================================================
;;; Message Operations
;;; ============================================================

(defun context-add-message (context message)
  "Add a message to the working buffer and history.

Parameters:
  CONTEXT - Context instance
  MESSAGE - Message plist

Returns:
  The context (for chaining)"
  (bt:with-lock-held ((context-lock context))
    (setf (context-messages context)
          (append (context-messages context) (list message)))
    (push message (context-history context)))
  context)

(defun context-add-messages (context messages)
  "Add multiple messages to context.

Parameters:
  CONTEXT  - Context instance
  MESSAGES - List of message plists

Returns:
  The context (for chaining)"
  (dolist (msg messages)
    (context-add-message context msg))
  context)

(defun context-clear-messages (context)
  "Clear the working message buffer (history is preserved).

Parameters:
  CONTEXT - Context instance

Returns:
  The context (for chaining)"
  (bt:with-lock-held ((context-lock context))
    (setf (context-messages context) nil))
  context)

(defun context-get-messages (context)
  "Get all messages from the working buffer.

Parameters:
  CONTEXT - Context instance

Returns:
  List of messages"
  (bt:with-lock-held ((context-lock context))
    (copy-list (context-messages context))))

(defun context-message-count (context)
  "Get the number of messages in the working buffer.

Parameters:
  CONTEXT - Context instance

Returns:
  Message count"
  (bt:with-lock-held ((context-lock context))
    (length (context-messages context))))

;;; ============================================================
;;; Trace Operations
;;; ============================================================

(defun context-trace-add (context event &key data timestamp)
  "Add an event to the execution trace.

Parameters:
  CONTEXT   - Context instance
  EVENT     - Event type keyword (e.g., :tool-call, :llm-response)
  DATA      - Event data plist
  TIMESTAMP - Optional timestamp (defaults to now)

Returns:
  The context (for chaining)"
  (bt:with-lock-held ((context-lock context))
    (push (list :event event
                :timestamp (or timestamp (get-universal-time))
                :data data)
          (context-trace context)))
  context)

(defun context-get-trace (context)
  "Get the execution trace (newest first).

Parameters:
  CONTEXT - Context instance

Returns:
  List of trace events"
  (bt:with-lock-held ((context-lock context))
    (copy-list (context-trace context))))

(defun context-clear-trace (context)
  "Clear the execution trace.

Parameters:
  CONTEXT - Context instance

Returns:
  The context (for chaining)"
  (bt:with-lock-held ((context-lock context))
    (setf (context-trace context) nil))
  context)

;;; ============================================================
;;; Metadata Operations
;;; ============================================================

(defun context-meta-get (context key &optional default)
  "Get a metadata value from context.

Parameters:
  CONTEXT - Context instance
  KEY     - Metadata key
  DEFAULT - Default value if not found

Returns:
  Metadata value or default"
  (getf (context-metadata context) key default))

(defun context-meta-set (context key value)
  "Set a metadata value in context.

Parameters:
  CONTEXT - Context instance
  KEY     - Metadata key
  VALUE   - Value to set

Returns:
  The context (for chaining)"
  (bt:with-lock-held ((context-lock context))
    (setf (getf (context-metadata context) key) value))
  context)

;;; ============================================================
;;; Context Cloning
;;; ============================================================

(defun context-clone (context &key messages metadata)
  "Create a copy of context with optional overrides.

Parameters:
  CONTEXT  - Context to clone
  MESSAGES - Override messages (if provided)
  METADATA - Override metadata (if provided)

Returns:
  New context instance"
  (bt:with-lock-held ((context-lock context))
    (let ((new-ctx (make-instance 'context)))
      ;; Copy variables
      (setf (context-variables new-ctx)
            (alexandria:copy-hash-table (context-variables context)))
      ;; Copy or override messages
      (setf (context-messages new-ctx)
            (copy-list (or messages (context-messages context))))
      ;; Copy history
      (setf (context-history new-ctx)
            (copy-list (context-history context)))
      ;; Copy trace
      (setf (context-trace new-ctx)
            (copy-list (context-trace context)))
      ;; Copy or override metadata
      (setf (context-metadata new-ctx)
            (copy-list (or metadata (context-metadata context))))
      new-ctx)))

;;; ============================================================
;;; Context Serialization
;;; ============================================================

(defun context-to-plist (context)
  "Serialize context to a plist.

Parameters:
  CONTEXT - Context instance

Returns:
  Plist representation of context"
  (bt:with-lock-held ((context-lock context))
    (list :variables (context-variables-alist context)
          :messages (copy-list (context-messages context))
          :history (copy-list (context-history context))
          :trace (copy-list (context-trace context))
          :metadata (copy-list (context-metadata context))
          :created-at (context-created-at context))))

(defun context-from-plist (plist)
  "Deserialize context from a plist.

Parameters:
  PLIST - Plist representation of context

Returns:
  New context instance"
  (let ((ctx (make-context :messages (getf plist :messages)
                           :metadata (getf plist :metadata)
                           :variables (getf plist :variables))))
    (setf (context-history ctx) (getf plist :history))
    (setf (context-trace ctx) (getf plist :trace))
    ctx))

;;; ============================================================
;;; Convenience Macros
;;; ============================================================

(defmacro with-context ((var &rest initargs) &body body)
  "Execute body with a new context bound to VAR.

Parameters:
  VAR      - Variable to bind context to
  INITARGS - Arguments to make-context

Returns:
  Result of body execution"
  `(let ((,var (make-context ,@initargs)))
     ,@body))

(defmacro with-context-variable ((context key value) &body body)
  "Execute body with a temporary context variable.

Parameters:
  CONTEXT - Context instance
  KEY     - Variable key
  VALUE   - Variable value

Returns:
  Result of body execution"
  (let ((old-value (gensym "OLD-VALUE"))
        (had-value (gensym "HAD-VALUE")))
    `(let ((,old-value (context-get ,context ,key))
           (,had-value (context-has-p ,context ,key)))
       (unwind-protect
            (progn
              (context-set ,context ,key ,value)
              ,@body)
         (if ,had-value
             (context-set ,context ,key ,old-value)
             (context-remove ,context ,key))))))
