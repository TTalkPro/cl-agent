;;;; step.lisp
;;;; CL-Agent Core - Process Step System
;;;;
;;;; Defines process steps with input/output schemas, event triggers,
;;;; and execution handlers.

(in-package #:cl-agent.process)

;;; ============================================================
;;; Step Status
;;; ============================================================

(defconstant +step-status-pending+ :pending
  "Step has not started.")

(defconstant +step-status-running+ :running
  "Step is currently executing.")

(defconstant +step-status-waiting+ :waiting
  "Step is waiting for external event.")

(defconstant +step-status-completed+ :completed
  "Step completed successfully.")

(defconstant +step-status-failed+ :failed
  "Step failed with error.")

(defconstant +step-status-skipped+ :skipped
  "Step was skipped.")

;;; ============================================================
;;; Retry Policy
;;; ============================================================

(defclass retry-policy ()
  ((max-attempts
    :initarg :max-attempts
    :initform 3
    :accessor retry-max-attempts
    :documentation "Maximum retry attempts")

   (delay
    :initarg :delay
    :initform 1.0
    :accessor retry-delay
    :documentation "Delay between retries in seconds")

   (backoff
    :initarg :backoff
    :initform :linear
    :accessor retry-backoff
    :documentation "Backoff strategy: :linear, :exponential")

   (retry-on
    :initarg :retry-on
    :initform '(error)
    :accessor retry-on-conditions
    :documentation "Conditions to retry on"))

  (:documentation "Retry policy for step execution."))

(defun make-retry-policy (&key (max-attempts 3) (delay 1.0) (backoff :linear) retry-on)
  "Create a retry policy."
  (make-instance 'retry-policy
                 :max-attempts max-attempts
                 :delay delay
                 :backoff backoff
                 :retry-on (or retry-on '(error))))

(defun calculate-retry-delay (policy attempt)
  "Calculate delay for retry attempt."
  (let ((base-delay (retry-delay policy)))
    (case (retry-backoff policy)
      (:linear (* base-delay attempt))
      (:exponential (* base-delay (expt 2 (1- attempt))))
      (otherwise base-delay))))

;;; ============================================================
;;; Step Class
;;; ============================================================

(defclass process-step ()
  ((id
    :initarg :id
    :initform (generate-step-id)
    :reader step-id
    :documentation "Unique step identifier")

   (name
    :initarg :name
    :initform "unnamed-step"
    :accessor step-name
    :documentation "Step name")

   (description
    :initarg :description
    :initform nil
    :accessor step-description
    :documentation "Step description")

   (handler
    :initarg :handler
    :initform nil
    :accessor step-handler
    :documentation "Step execution function (context input) -> step-result")

   (input-schema
    :initarg :input-schema
    :initform nil
    :accessor step-input-schema
    :documentation "Input validation schema")

   (output-schema
    :initarg :output-schema
    :initform nil
    :accessor step-output-schema
    :documentation "Output validation schema")

   (wait-for-events
    :initarg :wait-for-events
    :initform nil
    :accessor step-wait-for-events
    :documentation "Event patterns to wait for before/during execution")

   (emit-events
    :initarg :emit-events
    :initform nil
    :accessor step-emit-events
    :documentation "Events to emit on completion")

   (timeout
    :initarg :timeout
    :initform nil
    :accessor step-timeout
    :documentation "Step timeout in seconds")

   (retry-policy
    :initarg :retry-policy
    :initform nil
    :accessor step-retry-policy
    :documentation "Retry policy for failures")

   (condition
    :initarg :condition
    :initform nil
    :accessor step-condition
    :documentation "Condition function (context) -> boolean to run step")

   (on-enter
    :initarg :on-enter
    :initform nil
    :accessor step-on-enter
    :documentation "Hook called when entering step")

   (on-exit
    :initarg :on-exit
    :initform nil
    :accessor step-on-exit
    :documentation "Hook called when exiting step")

   (metadata
    :initarg :metadata
    :initform nil
    :accessor step-metadata
    :documentation "Additional metadata"))

  (:documentation "Represents a single step in a process."))

(defun generate-step-id ()
  "Generate unique step ID."
  (format nil "step-~A-~A"
          (get-universal-time)
          (random 100000)))

(defun make-step (name &key description handler
                         input-schema output-schema
                         wait-for-events emit-events
                         timeout retry-policy condition
                         on-enter on-exit metadata)
  "Create a new process step.

Parameters:
  NAME            - Step name
  DESCRIPTION     - Step description
  HANDLER         - Execution function (context input) -> step-result
  INPUT-SCHEMA    - Input validation schema
  OUTPUT-SCHEMA   - Output validation schema
  WAIT-FOR-EVENTS - Events to wait for
  EMIT-EVENTS     - Events to emit on completion
  TIMEOUT         - Timeout in seconds
  RETRY-POLICY    - Retry policy
  CONDITION       - Condition to run step
  ON-ENTER        - Enter hook
  ON-EXIT         - Exit hook
  METADATA        - Additional metadata

Returns:
  New process-step instance"
  (make-instance 'process-step
                 :name name
                 :description description
                 :handler handler
                 :input-schema input-schema
                 :output-schema output-schema
                 :wait-for-events wait-for-events
                 :emit-events emit-events
                 :timeout timeout
                 :retry-policy retry-policy
                 :condition condition
                 :on-enter on-enter
                 :on-exit on-exit
                 :metadata metadata))

(defmethod print-object ((step process-step) stream)
  (print-unreadable-object (step stream :type t)
    (format stream "~A" (step-name step))))

;;; ============================================================
;;; Step Result
;;; ============================================================

(defclass step-result ()
  ((status
    :initarg :status
    :initform +step-status-completed+
    :accessor step-result-status
    :documentation "Result status")

   (output
    :initarg :output
    :initform nil
    :accessor step-result-output
    :documentation "Step output data")

   (error
    :initarg :error
    :initform nil
    :accessor step-result-error
    :documentation "Error if failed")

   (next-step
    :initarg :next-step
    :initform nil
    :accessor step-result-next-step
    :documentation "Override next step")

   (events
    :initarg :events
    :initform nil
    :accessor step-result-events
    :documentation "Events to emit")

   (metadata
    :initarg :metadata
    :initform nil
    :accessor step-result-metadata
    :documentation "Additional metadata"))

  (:documentation "Result of step execution."))

(defun make-step-result (&key (status +step-status-completed+)
                              output error next-step events metadata)
  "Create a step result.

Parameters:
  STATUS    - Result status
  OUTPUT    - Output data
  ERROR     - Error if failed
  NEXT-STEP - Override next step
  EVENTS    - Events to emit
  METADATA  - Additional metadata

Returns:
  New step-result instance"
  (make-instance 'step-result
                 :status status
                 :output output
                 :error error
                 :next-step next-step
                 :events events
                 :metadata metadata))

;; Convenience constructors
(defun step-completed (&key output next-step events metadata)
  "Create a successful step result."
  (make-step-result :status +step-status-completed+
                    :output output
                    :next-step next-step
                    :events events
                    :metadata metadata))

(defun step-failed (error &key metadata)
  "Create a failed step result."
  (make-step-result :status +step-status-failed+
                    :error error
                    :metadata metadata))

(defun step-waiting (&key events metadata)
  "Create a waiting step result."
  (make-step-result :status +step-status-waiting+
                    :events events
                    :metadata metadata))

(defun step-skipped (&key reason metadata)
  "Create a skipped step result."
  (make-step-result :status +step-status-skipped+
                    :metadata (append (list :reason reason) metadata)))

;;; ============================================================
;;; Step Execution
;;; ============================================================

(defun execute-step (step context input &key event-bus)
  "Execute a process step.

Parameters:
  STEP      - Process step
  CONTEXT   - Execution context
  INPUT     - Step input data
  EVENT-BUS - Optional event bus for events

Returns:
  step-result"
  ;; Check condition
  (when (step-condition step)
    (unless (funcall (step-condition step) context)
      (return-from execute-step
        (step-skipped :reason "Condition not met"))))

  ;; Call on-enter hook
  (when (step-on-enter step)
    (funcall (step-on-enter step) context input))

  ;; Execute with retry
  (let ((result (execute-step-with-retry step context input)))

    ;; Call on-exit hook
    (when (step-on-exit step)
      (funcall (step-on-exit step) context result))

    ;; Emit events
    (when event-bus
      (dolist (event (or (step-result-events result)
                         (step-emit-events step)))
        (event-bus-publish event-bus
          (if (typep event 'process-event)
              event
              (make-event :type +event-type-output+
                         :name (step-name step)
                         :data event
                         :source (step-id step))))))

    result))

(defun execute-step-with-retry (step context input)
  "Execute step with retry policy.

Parameters:
  STEP    - Process step
  CONTEXT - Execution context
  INPUT   - Step input

Returns:
  step-result"
  (let* ((policy (step-retry-policy step))
         (max-attempts (if policy (retry-max-attempts policy) 1))
         (handler (step-handler step)))

    (unless handler
      (return-from execute-step-with-retry
        (step-completed :output input)))

    (loop for attempt from 1 to max-attempts
          do (handler-case
                 (let ((result (if (step-timeout step)
                                   (execute-with-timeout
                                    (step-timeout step)
                                    (lambda () (funcall handler context input)))
                                   (funcall handler context input))))
                   ;; Normalize result
                   (return (if (typep result 'step-result)
                               result
                               (step-completed :output result))))

               (error (e)
                 (if (and policy (< attempt max-attempts))
                     (progn
                       (sleep (calculate-retry-delay policy attempt))
                       nil)  ; Continue loop
                     (return (step-failed e)))))

          finally (return (step-failed "Max retries exceeded")))))

(defun execute-with-timeout (timeout fn)
  "Execute function with timeout.

Parameters:
  TIMEOUT - Timeout in seconds
  FN      - Function to execute

Returns:
  Function result or signals timeout"
  ;; Simple implementation - in production would use proper timeout
  (let ((result nil)
        (done nil)
        (error-val nil))
    (let ((thread (make-thread
                   (lambda ()
                     (handler-case
                         (setf result (funcall fn)
                               done t)
                       (error (e)
                         (setf error-val e
                               done t)))))))
      ;; Wait with timeout
      (let ((deadline (+ (get-internal-real-time)
                        (* timeout internal-time-units-per-second))))
        (loop while (and (not done)
                         (< (get-internal-real-time) deadline))
              do (sleep 0.1))

        (if done
            (if error-val
                (error error-val)
                result)
            (progn
              ;; Timeout - try to kill thread
              (ignore-errors (bt:destroy-thread thread))
              (error "Step timeout after ~A seconds" timeout)))))))

;;; ============================================================
;;; Step Definition Macro
;;; ============================================================

(defmacro defstep (name (&rest args) &body body)
  "Define a process step.

Usage:
  (defstep my-step (:input data :context ctx)
    :description \"Process data\"
    :wait-for (:approval)
    :timeout 60
    :handler
    (let ((result (process-data data)))
      (step-completed :output result)))

Parameters:
  NAME - Step name
  ARGS - Argument spec (:input var :context var)
  BODY - Step options and handler"
  (let ((input-var (or (getf args :input) 'input))
        (context-var (or (getf args :context) 'context))
        (description (getf body :description))
        (wait-for (getf body :wait-for))
        (emit (getf body :emit))
        (timeout (getf body :timeout))
        (retry (getf body :retry))
        (condition-form (getf body :condition))
        (on-enter (getf body :on-enter))
        (on-exit (getf body :on-exit))
        (handler-body (getf body :handler)))

    `(defparameter ,name
       (make-step ,(string-downcase (symbol-name name))
                  :description ,description
                  :wait-for-events ',wait-for
                  :emit-events ',emit
                  :timeout ,timeout
                  :retry-policy ,(when retry `(make-retry-policy ,@retry))
                  :condition ,(when condition-form
                               `(lambda (,context-var)
                                  (declare (ignorable ,context-var))
                                  ,condition-form))
                  :on-enter ,(when on-enter
                              `(lambda (,context-var ,input-var)
                                 (declare (ignorable ,context-var ,input-var))
                                 ,on-enter))
                  :on-exit ,(when on-exit
                             `(lambda (,context-var result)
                                (declare (ignorable ,context-var result))
                                ,on-exit))
                  :handler (lambda (,context-var ,input-var)
                             (declare (ignorable ,context-var ,input-var))
                             ,@(if handler-body
                                   (list handler-body)
                                   '((step-completed))))))))
