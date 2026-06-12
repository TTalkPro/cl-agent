;;;; common.lisp
;;;; CL-Agent SimpleAgent - Common Utilities
;;;;
;;;; Overview:
;;;;   Shared utilities for agent implementations.

(in-package #:cl-agent.simpleagent)

;;; ============================================================
;;; Agent Base Protocol
;;; ============================================================

(defgeneric agent-p (obj)
  (:documentation "Check if OBJ is an agent.")
  (:method ((obj t)) nil))

(defgeneric agent-id (agent)
  (:documentation "Get the unique ID of an agent."))

(defgeneric agent-name (agent)
  (:documentation "Get the name of an agent."))

;;; ============================================================
;;; Agent Base Class
;;; ============================================================

(defclass base-agent ()
  ((id
    :initform (cl-agent.core:generate-uuid)
    :reader agent-id
    :documentation "Unique agent identifier")

   (name
    :initarg :name
    :initform "agent"
    :accessor agent-name
    :documentation "Agent name")

   (created-at
    :initform (get-universal-time)
    :reader agent-created-at
    :documentation "Creation timestamp")

   (metadata
    :initarg :metadata
    :initform nil
    :accessor agent-metadata
    :documentation "Agent metadata plist"))

  (:documentation "Base class for all agents."))

(defmethod agent-p ((agent base-agent))
  "Base agents are agents."
  t)

(defmethod print-object ((agent base-agent) stream)
  "Print agent in readable format."
  (print-unreadable-object (agent stream :type t :identity t)
    (format stream "~A (~A)" (agent-name agent) (subseq (agent-id agent) 0 8))))

;;; ============================================================
;;; Agent Events
;;; ============================================================

(defstruct agent-event
  "Event fired during agent execution."
  (type :unknown :type keyword)
  (agent nil)
  (data nil)
  (timestamp (get-universal-time)))

(defun make-agent-event-of-type (type agent &rest data)
  "Create an agent event.

Parameters:
  TYPE  - Event type keyword
  AGENT - Agent instance
  DATA  - Event data plist"
  (make-agent-event :type type :agent agent :data data))

;;; ============================================================
;;; Event Handlers
;;; ============================================================

(defvar *agent-event-handlers* (make-hash-table :test 'eq)
  "Global event handlers by event type.")

(defun register-agent-handler (event-type handler)
  "Register a global event handler.

Parameters:
  EVENT-TYPE - Event type keyword
  HANDLER    - Function (event) -> result"
  (push handler (gethash event-type *agent-event-handlers*)))

(defun fire-agent-event (event)
  "Fire an agent event to all registered handlers.

Parameters:
  EVENT - Agent event"
  (dolist (handler (gethash (agent-event-type event) *agent-event-handlers*))
    (handler-case
        (funcall handler event)
      (error (e)
        (cl-agent.core:log-error "Event handler error: ~A" e)))))

;;; ============================================================
;;; Agent Settings
;;; ============================================================

(defun merge-settings (defaults overrides)
  "Merge settings plists.

Parameters:
  DEFAULTS  - Default settings plist
  OVERRIDES - Override settings plist

Returns:
  Merged settings plist"
  (let ((result (copy-list defaults)))
    (loop for (key value) on overrides by #'cddr
          do (setf (getf result key) value))
    result))

(defun default-agent-settings ()
  "Get default agent settings.

Returns:
  Default settings plist"
  (list :max-tokens 4096
        :temperature 0.7
        :max-attempts 10
        :tool-choice :auto))

;;; ============================================================
;;; Thread-Safe Queue
;;; ============================================================

(defclass message-queue ()
  ((items
    :initform nil
    :accessor queue-items)
   (lock
    :initform (bt:make-lock "queue-lock")
    :reader queue-lock)
   (condvar
    :initform (bt:make-condition-variable :name "queue-condvar")
    :reader queue-condvar))
  (:documentation "Thread-safe message queue."))

(defun make-message-queue ()
  "Create a new message queue."
  (make-instance 'message-queue))

(defun queue-enqueue (queue item)
  "Add item to queue.

Parameters:
  QUEUE - Message queue
  ITEM  - Item to add"
  (bt:with-lock-held ((queue-lock queue))
    (setf (queue-items queue)
          (append (queue-items queue) (list item)))
    (bt:condition-notify (queue-condvar queue))))

(defun queue-dequeue (queue &key (timeout nil))
  "Remove and return item from queue.

Parameters:
  QUEUE   - Message queue
  TIMEOUT - Timeout in seconds (NIL for blocking)

Returns:
  (values item found-p)"
  (bt:with-lock-held ((queue-lock queue))
    (loop
      (when (queue-items queue)
        (let ((item (pop (queue-items queue))))
          (return (values item t))))
      (unless (if timeout
                  (bt:condition-wait (queue-condvar queue)
                                     (queue-lock queue)
                                     :timeout timeout)
                  (bt:condition-wait (queue-condvar queue)
                                     (queue-lock queue)))
        (return (values nil nil))))))

(defun queue-peek (queue)
  "Peek at front item without removing.

Parameters:
  QUEUE - Message queue

Returns:
  Front item or NIL"
  (bt:with-lock-held ((queue-lock queue))
    (first (queue-items queue))))

(defun queue-empty-p (queue)
  "Check if queue is empty.

Parameters:
  QUEUE - Message queue

Returns:
  T if empty"
  (bt:with-lock-held ((queue-lock queue))
    (null (queue-items queue))))

(defun queue-length (queue)
  "Get queue length.

Parameters:
  QUEUE - Message queue

Returns:
  Number of items"
  (bt:with-lock-held ((queue-lock queue))
    (length (queue-items queue))))

(defun queue-clear (queue)
  "Clear all items from queue.

Parameters:
  QUEUE - Message queue"
  (bt:with-lock-held ((queue-lock queue))
    (setf (queue-items queue) nil)))
