;;;; runtime.lisp
;;;; CL-Agent Core - Process Runtime
;;;;
;;;; Executes process definitions with event handling, human-in-the-loop,
;;;; and state management.

(in-package #:cl-agent.process)

;;; ============================================================
;;; Runtime States
;;; ============================================================

(defconstant +runtime-state-idle+ :idle
  "Runtime is idle.")

(defconstant +runtime-state-running+ :running
  "Runtime is executing.")

(defconstant +runtime-state-paused+ :paused
  "Runtime is paused.")

(defconstant +runtime-state-waiting+ :waiting
  "Runtime is waiting for external input.")

(defconstant +runtime-state-completed+ :completed
  "Runtime completed successfully.")

(defconstant +runtime-state-failed+ :failed
  "Runtime failed with error.")

;;; ============================================================
;;; Execution Context
;;; ============================================================

(defclass execution-context ()
  ((id
    :initarg :id
    :initform (generate-context-id)
    :reader context-id
    :documentation "Unique context identifier")

   (process
    :initarg :process
    :accessor context-process
    :documentation "Process definition being executed")

   (current-step
    :initarg :current-step
    :initform nil
    :accessor context-current-step
    :documentation "Current step name")

   (state
    :initarg :state
    :initform +runtime-state-idle+
    :accessor context-state
    :documentation "Current runtime state")

   (variables
    :initform (make-hash-table :test 'equal)
    :accessor context-variables
    :documentation "Process variables")

   (step-outputs
    :initform (make-hash-table :test 'equal)
    :accessor context-step-outputs
    :documentation "Step name -> output mapping")

   (history
    :initform nil
    :accessor context-history
    :documentation "Execution history")

   (error
    :initform nil
    :accessor context-error
    :documentation "Current error if any")

   (start-time
    :initform nil
    :accessor context-start-time
    :documentation "Execution start time")

   (end-time
    :initform nil
    :accessor context-end-time
    :documentation "Execution end time")

   (metadata
    :initarg :metadata
    :initform nil
    :accessor context-metadata
    :documentation "Additional metadata"))

  (:documentation "Execution context for a process instance."))

(defun generate-context-id ()
  "Generate unique context ID."
  (format nil "ctx-~A-~A"
          (get-universal-time)
          (random 100000)))

(defun make-execution-context (process &key metadata)
  "Create an execution context.

Parameters:
  PROCESS  - Process definition
  METADATA - Additional metadata

Returns:
  New execution-context instance"
  (make-instance 'execution-context
                 :process process
                 :metadata metadata))

(defun context-get-variable (context key &optional default)
  "Get a variable from context.

Parameters:
  CONTEXT - Execution context
  KEY     - Variable key
  DEFAULT - Default value

Returns:
  Variable value"
  (gethash key (context-variables context) default))

(defun context-set-variable (context key value)
  "Set a variable in context.

Parameters:
  CONTEXT - Execution context
  KEY     - Variable key
  VALUE   - Variable value

Returns:
  The value"
  (setf (gethash key (context-variables context)) value))

(defun context-get-step-output (context step-name)
  "Get output from a completed step.

Parameters:
  CONTEXT   - Execution context
  STEP-NAME - Step name

Returns:
  Step output or NIL"
  (gethash step-name (context-step-outputs context)))

(defun context-add-history (context entry)
  "Add entry to execution history.

Parameters:
  CONTEXT - Execution context
  ENTRY   - History entry"
  (push (append entry (list :timestamp (get-universal-time)))
        (context-history context)))

;;; ============================================================
;;; Process Runtime
;;; ============================================================

(defclass process-runtime ()
  ((context
    :initarg :context
    :accessor runtime-context
    :documentation "Execution context")

   (event-bus
    :initform (make-event-bus)
    :accessor runtime-event-bus
    :documentation "Event bus for process events")

   (event-queue
    :initform (make-event-queue)
    :accessor runtime-event-queue
    :documentation "Queue for incoming events")

   (human-loop
    :initform (make-human-loop-manager)
    :accessor runtime-human-loop
    :documentation "Human-in-the-loop manager")

   (state-machine
    :initform (make-process-state-machine)
    :accessor runtime-state-machine
    :documentation "Process state machine")

   (thread
    :initform nil
    :accessor runtime-thread
    :documentation "Background execution thread")

   (lock
    :initform (make-lock "runtime-lock")
    :reader runtime-lock
    :documentation "Thread safety lock")

   (pause-condvar
    :initform (make-condition-variable :name "runtime-pause")
    :reader runtime-pause-condvar
    :documentation "Pause condition variable")

   (stop-flag
    :initform nil
    :accessor runtime-stop-flag
    :documentation "Stop flag")

   (on-step-start
    :initarg :on-step-start
    :initform nil
    :accessor runtime-on-step-start
    :documentation "Callback (context step)")

   (on-step-complete
    :initarg :on-step-complete
    :initform nil
    :accessor runtime-on-step-complete
    :documentation "Callback (context step result)")

   (on-state-change
    :initarg :on-state-change
    :initform nil
    :accessor runtime-on-state-change
    :documentation "Callback (old-state new-state)")

   (on-event
    :initarg :on-event
    :initform nil
    :accessor runtime-on-event
    :documentation "Callback (event)"))

  (:documentation "Runtime for executing process definitions."))

(defun make-process-runtime (process &key metadata
                                          on-step-start on-step-complete
                                          on-state-change on-event
                                          human-handler)
  "Create a process runtime.

Parameters:
  PROCESS          - Process definition
  METADATA         - Context metadata
  ON-STEP-START    - Step start callback
  ON-STEP-COMPLETE - Step complete callback
  ON-STATE-CHANGE  - State change callback
  ON-EVENT         - Event callback
  HUMAN-HANDLER    - Human input handler

Returns:
  New process-runtime instance"
  (let* ((context (make-execution-context process :metadata metadata))
         (runtime (make-instance 'process-runtime
                                 :context context
                                 :on-step-start on-step-start
                                 :on-step-complete on-step-complete
                                 :on-state-change on-state-change
                                 :on-event on-event)))
    ;; Set initial step
    (setf (context-current-step context) (process-initial-step process))

    ;; Configure human loop handler
    (when human-handler
      (human-loop-set-handler (runtime-human-loop runtime) human-handler))

    ;; Subscribe to event queue
    (event-bus-subscribe (runtime-event-bus runtime) :all
                         (lambda (event)
                           (event-queue-push (runtime-event-queue runtime) event)))

    runtime))

;;; ============================================================
;;; Runtime Control
;;; ============================================================

(defun runtime-start (runtime &key input async)
  "Start process execution.

Parameters:
  RUNTIME - Process runtime
  INPUT   - Initial input data
  ASYNC   - Run in background thread

Returns:
  For sync: final result
  For async: the runtime"
  (let ((context (runtime-context runtime)))
    ;; Validate state
    (unless (eq (context-state context) +runtime-state-idle+)
      (error "Runtime is not idle"))

    ;; Initialize
    (setf (context-start-time context) (get-universal-time))
    (setf (runtime-stop-flag runtime) nil)

    ;; Store initial input
    (context-set-variable context :input input)

    ;; Trigger state machine
    (state-machine-trigger (runtime-state-machine runtime) :start context)
    (setf (context-state context) +runtime-state-running+)

    ;; Call process on-start hook
    (when-let ((hook (process-on-start (context-process context))))
      (funcall hook context))

    (context-add-history context (list :event :started :input input))

    ;; Execute
    (if async
        (progn
          (setf (runtime-thread runtime)
                (make-thread (lambda () (runtime-execute-loop runtime input))
                             :name (format nil "process-~A" (context-id context))))
          runtime)
        (runtime-execute-loop runtime input))))

(defun runtime-stop (runtime)
  "Stop process execution.

Parameters:
  RUNTIME - Process runtime

Returns:
  The runtime"
  (with-lock-held ((runtime-lock runtime))
    (setf (runtime-stop-flag runtime) t)
    (setf (context-state (runtime-context runtime)) +runtime-state-failed+)
    (condition-notify (runtime-pause-condvar runtime))

    ;; Inject stop event
    (event-queue-push (runtime-event-queue runtime)
                      (make-event :type +event-type-cancel+ :name "stop")))

  ;; Cancel pending human inputs
  (dolist (req (human-loop-pending-requests (runtime-human-loop runtime)))
    (human-loop-cancel-request (runtime-human-loop runtime)
                               (input-request-id req)
                               :reason "Process stopped"))

  (context-add-history (runtime-context runtime) (list :event :stopped))

  runtime)

(defun runtime-pause (runtime)
  "Pause process execution.

Parameters:
  RUNTIME - Process runtime

Returns:
  The runtime"
  (with-lock-held ((runtime-lock runtime))
    (state-machine-trigger (runtime-state-machine runtime) :pause
                           (runtime-context runtime))
    (setf (context-state (runtime-context runtime)) +runtime-state-paused+))

  (context-add-history (runtime-context runtime) (list :event :paused))

  runtime)

(defun runtime-resume (runtime)
  "Resume paused execution.

Parameters:
  RUNTIME - Process runtime

Returns:
  The runtime"
  (with-lock-held ((runtime-lock runtime))
    (state-machine-trigger (runtime-state-machine runtime) :resume
                           (runtime-context runtime))
    (setf (context-state (runtime-context runtime)) +runtime-state-running+)
    (condition-notify (runtime-pause-condvar runtime)))

  (context-add-history (runtime-context runtime) (list :event :resumed))

  runtime)

;;; ============================================================
;;; Event Injection
;;; ============================================================

(defun runtime-inject-event (runtime event)
  "Inject an external event into the process.

Parameters:
  RUNTIME - Process runtime
  EVENT   - Process event or event spec

Returns:
  The event"
  (let ((evt (if (typep event 'process-event)
                 event
                 (apply #'make-event event))))
    (event-queue-push (runtime-event-queue runtime) evt)

    ;; Callback
    (when (runtime-on-event runtime)
      (funcall (runtime-on-event runtime) evt))

    (context-add-history (runtime-context runtime)
                         (list :event :external-event
                               :event-type (event-type evt)
                               :event-name (event-name evt)))
    evt))

;;; ============================================================
;;; Human Input Interface
;;; ============================================================

(defun runtime-get-pending-inputs (runtime)
  "Get pending human input requests.

Parameters:
  RUNTIME - Process runtime

Returns:
  List of input requests"
  (human-loop-pending-requests (runtime-human-loop runtime)))

(defun runtime-submit-input (runtime response)
  "Submit response to human input request.

Parameters:
  RUNTIME  - Process runtime
  RESPONSE - Input response

Returns:
  T if accepted"
  (let ((result (human-loop-submit-response (runtime-human-loop runtime) response)))
    (when result
      ;; Also inject as event
      (runtime-inject-event runtime
                            (make-event :type +event-type-input+
                                       :name "human-input"
                                       :data response
                                       :source :human)))
    result))

;;; ============================================================
;;; State Access
;;; ============================================================

(defun runtime-get-state (runtime)
  "Get current runtime state.

Parameters:
  RUNTIME - Process runtime

Returns:
  State plist"
  (let ((context (runtime-context runtime)))
    (list :state (context-state context)
          :current-step (context-current-step context)
          :variables (hash-table-to-plist (context-variables context))
          :pending-inputs (length (runtime-get-pending-inputs runtime))
          :history-count (length (context-history context)))))

(defun hash-table-to-plist (ht)
  "Convert hash table to plist."
  (loop for k being the hash-keys of ht using (hash-value v)
        collect k collect v))

;;; ============================================================
;;; Execution Loop
;;; ============================================================

(defun runtime-execute-loop (runtime initial-input)
  "Main execution loop.

Parameters:
  RUNTIME       - Process runtime
  INITIAL-INPUT - Initial input data

Returns:
  Final result or error"
  (let* ((context (runtime-context runtime))
         (process (context-process context))
         (current-input initial-input)
         (result nil))

    (handler-case
        (loop
          ;; Check stop flag
          (when (runtime-stop-flag runtime)
            (return (step-failed "Process stopped")))

          ;; Handle pause
          (when (eq (context-state context) +runtime-state-paused+)
            (with-lock-held ((runtime-lock runtime))
              (loop while (eq (context-state context) +runtime-state-paused+)
                    do (condition-wait (runtime-pause-condvar runtime)
                                       (runtime-lock runtime))))
            (when (runtime-stop-flag runtime)
              (return (step-failed "Process stopped"))))

          ;; Check for process events
          (loop
            (let ((event (event-queue-pop (runtime-event-queue runtime) :timeout 0)))
              (unless event (return))
              (runtime-handle-event runtime event)))

          ;; Get current step
          (let* ((step-name (context-current-step context))
                 (step (process-get-step process step-name)))

            (unless step
              ;; No more steps - complete
              (setf result (step-completed :output current-input))
              (return result))

            ;; Wait for required events
            (when (step-wait-for-events step)
              (setf (context-state context) +runtime-state-waiting+)
              (state-machine-trigger (runtime-state-machine runtime) :wait context)

              (let ((received-events (runtime-wait-for-events runtime
                                                              (step-wait-for-events step)
                                                              (step-timeout step))))
                (unless received-events
                  (setf result (step-failed "Timeout waiting for events"))
                  (return result))

                ;; Store received events in context
                (context-set-variable context :received-events received-events)
                (setf (context-state context) +runtime-state-running+)
                (state-machine-trigger (runtime-state-machine runtime) :continue context)))

            ;; Execute step
            (when (runtime-on-step-start runtime)
              (funcall (runtime-on-step-start runtime) context step))

            (context-add-history context
                                 (list :event :step-start :step step-name))

            (let ((step-result (execute-step step context current-input
                                             :event-bus (runtime-event-bus runtime))))

              (when (runtime-on-step-complete runtime)
                (funcall (runtime-on-step-complete runtime) context step step-result))

              (context-add-history context
                                   (list :event :step-complete
                                         :step step-name
                                         :status (step-result-status step-result)))

              ;; Handle result
              (case (step-result-status step-result)
                (:completed
                 ;; Store output
                 (setf (gethash step-name (context-step-outputs context))
                       (step-result-output step-result))
                 (setf current-input (step-result-output step-result))

                 ;; Determine next step
                 (let ((next (or (step-result-next-step step-result)
                                 (process-next-step process step-name))))
                   (if next
                       (setf (context-current-step context) next)
                       (progn
                         (setf result step-result)
                         (return result)))))

                (:waiting
                 ;; Step is waiting - will be resumed by event
                 (setf (context-state context) +runtime-state-waiting+)
                 (state-machine-trigger (runtime-state-machine runtime) :wait context))

                (:failed
                 (setf result step-result)
                 (return result))

                (:skipped
                 ;; Move to next step
                 (let ((next (process-next-step process step-name)))
                   (if next
                       (setf (context-current-step context) next)
                       (progn
                         (setf result (step-completed :output current-input))
                         (return result)))))))))

      (error (e)
        (setf (context-error context) e)
        (setf result (step-failed e))))

    ;; Finalize
    (setf (context-end-time context) (get-universal-time))

    (if (eq (step-result-status result) +step-status-completed+)
        (progn
          (setf (context-state context) +runtime-state-completed+)
          (state-machine-trigger (runtime-state-machine runtime) :complete context)
          (when-let ((hook (process-on-complete process)))
            (funcall hook context result)))
        (progn
          (setf (context-state context) +runtime-state-failed+)
          (state-machine-trigger (runtime-state-machine runtime) :fail context)
          (when-let ((hook (process-on-error process)))
            (funcall hook context (step-result-error result)))))

    (context-add-history context
                         (list :event :finished
                               :status (step-result-status result)))

    result))

(defun runtime-wait-for-events (runtime patterns timeout)
  "Wait for events matching patterns.

Parameters:
  RUNTIME  - Process runtime
  PATTERNS - Event patterns to wait for
  TIMEOUT  - Timeout in seconds

Returns:
  List of received events or NIL on timeout"
  (let ((received nil)
        (remaining (copy-list patterns))
        (deadline (when timeout
                    (+ (get-internal-real-time)
                       (* timeout internal-time-units-per-second)))))

    (loop
      ;; Check if all patterns matched
      (when (null remaining)
        (return (nreverse received)))

      ;; Check timeout
      (when (and deadline (>= (get-internal-real-time) deadline))
        (return nil))

      ;; Wait for event
      (let* ((wait-time (if deadline
                            (/ (- deadline (get-internal-real-time))
                               internal-time-units-per-second)
                            1.0))
             (event (event-queue-pop (runtime-event-queue runtime)
                                     :timeout (max 0.1 wait-time))))
        (when event
          ;; Check if event matches any remaining pattern
          (let ((matched-pattern (find-if (lambda (p) (event-matches-p event p))
                                          remaining)))
            (when matched-pattern
              (push event received)
              (setf remaining (remove matched-pattern remaining :count 1)))))))))

(defun runtime-handle-event (runtime event)
  "Handle a process event.

Parameters:
  RUNTIME - Process runtime
  EVENT   - Process event"
  (let* ((context (runtime-context runtime))
         (process (context-process context))
         (handler (process-get-event-handler process event)))

    (when handler
      (let ((result (funcall handler context event)))
        (when (typep result 'step-result)
          ;; Handler returned a step result - may change flow
          (when (step-result-next-step result)
            (setf (context-current-step context) (step-result-next-step result))))))))

;;; ============================================================
;;; README Documentation
;;; ============================================================

(defun create-process-readme ()
  "Generate README content for process module."
  "# Process Framework

Core process framework supporting:
- Event-driven workflow execution
- Human-in-the-loop interactions
- State machine-based flow control
- External event injection

## Usage

```lisp
;; Define a process
(defprocess approval-workflow
  :description \"Document approval workflow\"

  :steps
  ((submit
    :description \"Submit document\"
    :handler (lambda (ctx input)
               (step-completed :output input)))

   (review
    :description \"Review document\"
    :wait-for (:approval)
    :handler (lambda (ctx input)
               (if (context-get-variable ctx :approved)
                   (step-completed :output input)
                   (step-failed \"Rejected\")))))

  :on-event
  ((:approval . (lambda (ctx event)
                  (context-set-variable ctx :approved
                    (event-data event))))))

;; Create runtime
(let ((runtime (make-process-runtime approval-workflow
                 :human-handler #'my-input-handler)))

  ;; Start execution
  (runtime-start runtime :input document-data :async t)

  ;; Inject approval event
  (runtime-inject-event runtime
    (make-event :type :approval :data t))

  ;; Get state
  (runtime-get-state runtime))
```
")
