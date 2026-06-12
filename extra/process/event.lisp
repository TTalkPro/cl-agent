;;;; event.lisp
;;;; CL-Agent Core - Process Event System
;;;;
;;;; Provides event types, event bus for pub/sub pattern.

(in-package #:cl-agent.process)

;;; ============================================================
;;; Event Types
;;; ============================================================

(defconstant +event-type-input+ :input
  "External input event.")

(defconstant +event-type-output+ :output
  "Output event from step.")

(defconstant +event-type-external+ :external
  "External system event.")

(defconstant +event-type-approval+ :approval
  "Human approval event.")

(defconstant +event-type-timeout+ :timeout
  "Timeout event.")

(defconstant +event-type-error+ :error
  "Error event.")

(defconstant +event-type-cancel+ :cancel
  "Cancellation event.")

(defconstant +event-type-complete+ :complete
  "Completion event.")

;;; ============================================================
;;; Event Class
;;; ============================================================

(defclass process-event ()
  ((id
    :initarg :id
    :initform (generate-event-id)
    :reader event-id
    :documentation "Unique event identifier")

   (type
    :initarg :type
    :initform +event-type-external+
    :accessor event-type
    :documentation "Event type keyword")

   (name
    :initarg :name
    :initform nil
    :accessor event-name
    :documentation "Event name for routing")

   (data
    :initarg :data
    :initform nil
    :accessor event-data
    :documentation "Event payload data")

   (source
    :initarg :source
    :initform nil
    :accessor event-source
    :documentation "Event source identifier")

   (timestamp
    :initarg :timestamp
    :initform (get-universal-time)
    :reader event-timestamp
    :documentation "Event creation timestamp")

   (metadata
    :initarg :metadata
    :initform nil
    :accessor event-metadata
    :documentation "Additional metadata"))

  (:documentation "Represents an event in the process system."))

(defun generate-event-id ()
  "Generate a unique event ID."
  (format nil "evt-~A-~A"
          (get-universal-time)
          (random 100000)))

(defun make-event (&key type name data source metadata)
  "Create a new process event.

Parameters:
  TYPE     - Event type keyword
  NAME     - Event name for routing
  DATA     - Event payload
  SOURCE   - Event source identifier
  METADATA - Additional metadata

Returns:
  New process-event instance"
  (make-instance 'process-event
                 :type (or type +event-type-external+)
                 :name name
                 :data data
                 :source source
                 :metadata metadata))

(defmethod print-object ((event process-event) stream)
  (print-unreadable-object (event stream :type t :identity t)
    (format stream "~A/~A" (event-type event) (event-name event))))

;;; ============================================================
;;; Event Matching
;;; ============================================================

(defun event-matches-p (event pattern)
  "Check if event matches a pattern.

Pattern can be:
  - Keyword: matches event type
  - String: matches event name (supports wildcards)
  - List (:type TYPE :name NAME): matches both
  - Function: called with event, returns boolean

Parameters:
  EVENT   - Process event
  PATTERN - Match pattern

Returns:
  T if matches"
  (etypecase pattern
    (keyword
     (eq (event-type event) pattern))

    (string
     (event-name-matches-p (event-name event) pattern))

    (list
     (and (or (null (getf pattern :type))
              (eq (event-type event) (getf pattern :type)))
          (or (null (getf pattern :name))
              (event-name-matches-p (event-name event) (getf pattern :name)))))

    (function
     (funcall pattern event))))

(defun event-name-matches-p (name pattern)
  "Check if event name matches pattern (supports * wildcard).

Parameters:
  NAME    - Event name
  PATTERN - Pattern string

Returns:
  T if matches"
  (when (and name pattern)
    (if (find #\* pattern)
        ;; Simple wildcard matching
        (let ((parts (split-string pattern #\*)))
          (and (if (string= (first parts) "")
                   t
                   (and (>= (length name) (length (first parts)))
                        (string= (subseq name 0 (length (first parts)))
                                 (first parts))))
               (if (string= (car (last parts)) "")
                   t
                   (and (>= (length name) (length (car (last parts))))
                        (string= (subseq name (- (length name) (length (car (last parts)))))
                                 (car (last parts)))))))
        ;; Exact match
        (string= name pattern))))

(defun split-string (string delimiter)
  "Split string by delimiter character."
  (loop with result = nil
        with start = 0
        for i from 0 to (length string)
        when (or (= i (length string))
                 (char= (char string i) delimiter))
          do (push (subseq string start i) result)
             (setf start (1+ i))
        finally (return (nreverse result))))

;;; ============================================================
;;; Event Bus
;;; ============================================================

(defclass event-bus ()
  ((subscriptions
    :initform (make-hash-table :test 'equal)
    :accessor bus-subscriptions
    :documentation "Pattern -> list of (id . handler) subscriptions")

   (lock
    :initform (make-lock "event-bus-lock")
    :reader bus-lock
    :documentation "Thread safety lock")

   (next-sub-id
    :initform 0
    :accessor bus-next-sub-id
    :documentation "Next subscription ID"))

  (:documentation "Pub/sub event bus for process events."))

(defun make-event-bus ()
  "Create a new event bus.

Returns:
  New event-bus instance"
  (make-instance 'event-bus))

(defun event-bus-subscribe (bus pattern handler)
  "Subscribe to events matching pattern.

Parameters:
  BUS     - Event bus
  PATTERN - Event pattern (see event-matches-p)
  HANDLER - Function (event) -> nil

Returns:
  Subscription ID for unsubscribe"
  (with-lock-held ((bus-lock bus))
    (let ((sub-id (incf (bus-next-sub-id bus)))
          (pattern-key (pattern-to-key pattern)))
      (push (cons sub-id handler)
            (gethash pattern-key (bus-subscriptions bus)))
      sub-id)))

(defun event-bus-unsubscribe (bus subscription-id)
  "Unsubscribe from events.

Parameters:
  BUS             - Event bus
  SUBSCRIPTION-ID - ID from subscribe

Returns:
  T if unsubscribed"
  (with-lock-held ((bus-lock bus))
    (maphash (lambda (pattern subs)
               (let ((new-subs (remove subscription-id subs :key #'car)))
                 (if new-subs
                     (setf (gethash pattern (bus-subscriptions bus)) new-subs)
                     (remhash pattern (bus-subscriptions bus)))))
             (bus-subscriptions bus))
    t))

(defun event-bus-publish (bus event)
  "Publish an event to all matching subscribers.

Parameters:
  BUS   - Event bus
  EVENT - Process event

Returns:
  Number of handlers called"
  (let ((handlers nil))
    ;; Collect matching handlers under lock
    (with-lock-held ((bus-lock bus))
      (maphash (lambda (pattern subs)
                 (when (event-matches-pattern-key event pattern)
                   (dolist (sub subs)
                     (push (cdr sub) handlers))))
               (bus-subscriptions bus)))

    ;; Call handlers outside lock
    (dolist (handler handlers)
      (handler-case
          (funcall handler event)
        (error (e)
          (warn "Event handler error: ~A" e))))

    (length handlers)))

(defun event-bus-clear (bus)
  "Clear all subscriptions.

Parameters:
  BUS - Event bus"
  (with-lock-held ((bus-lock bus))
    (clrhash (bus-subscriptions bus))))

(defun pattern-to-key (pattern)
  "Convert pattern to hash key."
  (etypecase pattern
    (keyword (format nil "type:~A" pattern))
    (string (format nil "name:~A" pattern))
    (list (format nil "~A" pattern))
    (function "function")))

(defun event-matches-pattern-key (event pattern-key)
  "Check if event matches pattern key."
  (cond
    ((string= pattern-key "function")
     ;; Function patterns always need explicit matching
     nil)

    ((and (> (length pattern-key) 5)
          (string= (subseq pattern-key 0 5) "type:"))
     (eq (event-type event)
         (intern (string-upcase (subseq pattern-key 5)) :keyword)))

    ((and (> (length pattern-key) 5)
          (string= (subseq pattern-key 0 5) "name:"))
     (event-name-matches-p (event-name event)
                           (subseq pattern-key 5)))

    (t
     ;; List pattern - parse and match
     (let ((pattern (read-from-string pattern-key nil)))
       (when (listp pattern)
         (event-matches-p event pattern))))))

;;; ============================================================
;;; Event Queue
;;; ============================================================

(defclass event-queue ()
  ((queue
    :initform nil
    :accessor queue-items
    :documentation "Event queue")

   (lock
    :initform (make-lock "event-queue-lock")
    :reader queue-lock)

   (condvar
    :initform (make-condition-variable :name "event-queue-condvar")
    :reader queue-condvar))

  (:documentation "Thread-safe event queue."))

(defun make-event-queue ()
  "Create a new event queue."
  (make-instance 'event-queue))

(defun event-queue-push (queue event)
  "Push event to queue.

Parameters:
  QUEUE - Event queue
  EVENT - Process event"
  (with-lock-held ((queue-lock queue))
    (setf (queue-items queue)
          (append (queue-items queue) (list event)))
    (condition-notify (queue-condvar queue))))

(defun event-queue-pop (queue &key timeout)
  "Pop event from queue.

Parameters:
  QUEUE   - Event queue
  TIMEOUT - Timeout in seconds

Returns:
  Event or NIL if timeout"
  (with-lock-held ((queue-lock queue))
    (loop
      (when (queue-items queue)
        (return (pop (queue-items queue))))

      (if timeout
          (let ((deadline (+ (get-internal-real-time)
                            (* timeout internal-time-units-per-second))))
            (condition-wait (queue-condvar queue)
                           (queue-lock queue))
            (when (>= (get-internal-real-time) deadline)
              (return nil)))
          (condition-wait (queue-condvar queue)
                         (queue-lock queue))))))

(defun event-queue-peek (queue)
  "Peek at next event without removing.

Parameters:
  QUEUE - Event queue

Returns:
  Event or NIL"
  (with-lock-held ((queue-lock queue))
    (first (queue-items queue))))

(defun event-queue-empty-p (queue)
  "Check if queue is empty.

Parameters:
  QUEUE - Event queue

Returns:
  T if empty"
  (with-lock-held ((queue-lock queue))
    (null (queue-items queue))))

(defun event-queue-clear (queue)
  "Clear all events from queue.

Parameters:
  QUEUE - Event queue"
  (with-lock-held ((queue-lock queue))
    (setf (queue-items queue) nil)))
