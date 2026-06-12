;;;; process-agent.lisp
;;;; CL-Agent Extra - Process Agent
;;;;
;;;; Overview:
;;;;   Agent that runs in a background thread with pause/resume support.
;;;;   Uses message queues for communication and integrates with the process
;;;;   framework for event-driven workflows and human-in-the-loop.
;;;;
;;;; Usage:
;;;;   (let ((agent (make-process-agent kernel)))
;;;;     (agent-start agent)
;;;;     (agent-send agent "Hello!")
;;;;     (sleep 1)
;;;;     ;; Inject external event
;;;;     (agent-inject-event agent (cl-agent.process:make-event
;;;;                                 :type :external
;;;;                                 :name "data-ready"
;;;;                                 :data '(:file "data.csv")))
;;;;     (agent-pause agent)
;;;;     (agent-resume agent)
;;;;     (agent-stop agent))

(in-package #:cl-agent.extra.agent)

;;; ============================================================
;;; Agent State
;;; ============================================================

(deftype agent-state ()
  "Valid agent states."
  '(member :stopped :running :paused :error))

;;; ============================================================
;;; Process Agent Class
;;; ============================================================

(defclass process-agent (kernel-agent)
  ((state
    :initform :stopped
    :accessor agent-state
    :documentation "Current agent state")

   (thread
    :initform nil
    :accessor agent-thread
    :documentation "Background thread")

   (input-queue
    :initform (make-message-queue)
    :reader agent-input-queue
    :documentation "Queue for incoming messages")

   (output-queue
    :initform (make-message-queue)
    :reader agent-output-queue
    :documentation "Queue for outgoing responses")

   (pause-lock
    :initform (bt:make-lock "pause-lock")
    :reader agent-pause-lock)

   (pause-condvar
    :initform (bt:make-condition-variable :name "pause-condvar")
    :reader agent-pause-condvar)

   (stop-flag
    :initform nil
    :accessor agent-stop-flag
    :documentation "Flag to signal thread to stop")

   ;; ============================================================
   ;; Process Framework Integration
   ;; ============================================================

   (event-bus
    :initform nil
    :accessor agent-event-bus
    :documentation "Event bus for process events")

   (event-queue
    :initform nil
    :accessor agent-event-queue
    :documentation "Queue for incoming events")

   (human-loop
    :initform nil
    :accessor agent-human-loop
    :documentation "Human-in-the-loop manager")

   (process-runtime
    :initform nil
    :accessor agent-process-runtime
    :documentation "Optional process runtime for step-based workflows")

   (event-handlers
    :initform nil
    :accessor agent-event-handlers
    :documentation "Event type -> handler alist"))

  (:documentation "Agent that runs in background thread with pause/resume.
Integrates with the process framework for event-driven workflows."))

;;; ============================================================
;;; Constructor
;;; ============================================================

(defun make-process-agent (kernel &key name system-prompt settings callbacks
                                       process event-handlers human-handler)
  "Create a Process Agent.

Parameters:
  KERNEL         - Kernel instance
  NAME           - Agent name (optional)
  SYSTEM-PROMPT  - System prompt (optional)
  SETTINGS       - Settings plist (optional)
  CALLBACKS      - Callback functions (optional)
  PROCESS        - Process definition for step-based workflow (optional)
  EVENT-HANDLERS - Event type -> handler alist (optional)
  HUMAN-HANDLER  - Handler for human input requests (optional)

Returns:
  New process-agent instance"
  (let ((agent (make-instance 'process-agent
                              :kernel kernel
                              :name (or name "process-agent")
                              :system-prompt system-prompt
                              :settings (merge-settings (default-agent-settings) settings)
                              :callbacks callbacks
                              :context (make-context))))

    ;; Initialize event system
    (setf (agent-event-bus agent) (cl-agent.process:make-event-bus))
    (setf (agent-event-queue agent) (cl-agent.process:make-event-queue))

    ;; Initialize human-in-the-loop manager
    (setf (agent-human-loop agent) (cl-agent.process:make-human-loop-manager
                                     :handler human-handler
                                     :on-request (lambda (req)
                                                   (queue-enqueue (agent-output-queue agent)
                                                                  (list :type :human-input-request
                                                                        :request req)))))

    ;; Set up event handlers
    (when event-handlers
      (setf (agent-event-handlers agent) event-handlers))

    ;; Subscribe event bus to queue
    (cl-agent.process:event-bus-subscribe
     (agent-event-bus agent) :all
     (lambda (event)
       (cl-agent.process:event-queue-push (agent-event-queue agent) event)))

    ;; Create process runtime if process is provided
    (when process
      (setf (agent-process-runtime agent)
            (cl-agent.process:make-process-runtime
             process
             :human-handler human-handler
             :on-step-start (lambda (ctx step)
                              (queue-enqueue (agent-output-queue agent)
                                             (list :type :step-start
                                                   :step (cl-agent.process:step-name step))))
             :on-step-complete (lambda (ctx step result)
                                 (queue-enqueue (agent-output-queue agent)
                                                (list :type :step-complete
                                                      :step (cl-agent.process:step-name step)
                                                      :result result)))
             :on-event (lambda (event)
                         (queue-enqueue (agent-output-queue agent)
                                        (list :type :event
                                              :event event))))))

    agent))

;;; ============================================================
;;; State Predicates
;;; ============================================================

(defun agent-running-p (agent)
  "Check if agent is running.

Parameters:
  AGENT - Process agent

Returns:
  T if running"
  (eq (agent-state agent) :running))

(defun agent-paused-p (agent)
  "Check if agent is paused.

Parameters:
  AGENT - Process agent

Returns:
  T if paused"
  (eq (agent-state agent) :paused))

(defun agent-stopped-p (agent)
  "Check if agent is stopped.

Parameters:
  AGENT - Process agent

Returns:
  T if stopped"
  (eq (agent-state agent) :stopped))

;;; ============================================================
;;; Lifecycle Management
;;; ============================================================

(defun agent-start (agent)
  "Start the agent in a background thread.

Parameters:
  AGENT - Process agent

Returns:
  The agent"
  (when (agent-running-p agent)
    (error "Agent is already running"))

  (setf (agent-stop-flag agent) nil)
  (setf (agent-state agent) :running)

  ;; Start background thread
  (setf (agent-thread agent)
        (bt:make-thread
         (lambda ()
           (agent-run-loop agent))
         :name (format nil "agent-~A" (agent-id agent))))

  (fire-agent-event
   (make-agent-event-of-type :started agent))

  agent)

(defun agent-stop (agent)
  "Stop the agent.

Parameters:
  AGENT - Process agent

Returns:
  The agent"
  (when (agent-stopped-p agent)
    (return-from agent-stop agent))

  (setf (agent-stop-flag agent) t)
  (setf (agent-state agent) :stopped)

  ;; Wake up paused thread
  (bt:with-lock-held ((agent-pause-lock agent))
    (bt:condition-notify (agent-pause-condvar agent)))

  ;; Wake up waiting dequeue
  (queue-enqueue (agent-input-queue agent) :stop)

  ;; Wait for thread to finish
  (when (and (agent-thread agent)
             (bt:thread-alive-p (agent-thread agent)))
    (bt:join-thread (agent-thread agent)))

  (fire-agent-event
   (make-agent-event-of-type :stopped agent))

  agent)

(defun agent-pause (agent)
  "Pause the agent.

Parameters:
  AGENT - Process agent

Returns:
  The agent"
  (unless (agent-running-p agent)
    (error "Agent is not running"))

  (setf (agent-state agent) :paused)

  (fire-agent-event
   (make-agent-event-of-type :paused agent))

  agent)

(defun agent-resume (agent)
  "Resume a paused agent.

Parameters:
  AGENT - Process agent

Returns:
  The agent"
  (unless (agent-paused-p agent)
    (error "Agent is not paused"))

  (setf (agent-state agent) :running)

  ;; Wake up paused thread
  (bt:with-lock-held ((agent-pause-lock agent))
    (bt:condition-notify (agent-pause-condvar agent)))

  (fire-agent-event
   (make-agent-event-of-type :resumed agent))

  agent)

;;; ============================================================
;;; Helper Functions (defined before main loop)
;;; ============================================================

(defun process-pending-events (agent)
  "Process pending events from the event queue.

Parameters:
  AGENT - Process agent"
  (loop
    (let ((event (cl-agent.process:event-queue-pop (agent-event-queue agent) :timeout 0)))
      (unless event (return))

      ;; Find matching handler
      (let ((handlers (agent-event-handlers agent)))
        (dolist (handler-pair handlers)
          (let ((pattern (car handler-pair))
                (handler (cdr handler-pair)))
            (when (or (eq pattern :all)
                      (cl-agent.process:event-matches-p event pattern))
              (handler-case
                  (funcall handler event)
                (error (err)
                  (cl-agent.core:log-error "Event handler error: ~A" err)
                  (queue-enqueue (agent-output-queue agent)
                                 (list :type :event-error
                                       :event event
                                       :error (format nil "~A" err)))))))))

      ;; Notify output
      (queue-enqueue (agent-output-queue agent)
                     (list :type :event-processed
                           :event-type (cl-agent.process:event-type event)
                           :event-name (cl-agent.process:event-name event))))))

(defun process-agent-command (agent command)
  "Process an agent command.

Parameters:
  AGENT   - Process agent
  COMMAND - Command plist"
  (case (first command)
    (:reset
     (agent-reset agent)
     (queue-enqueue (agent-output-queue agent)
                    (list :type :ack :command :reset)))

    (:set-system-prompt
     (agent-set-system-prompt agent (second command))
     (queue-enqueue (agent-output-queue agent)
                    (list :type :ack :command :set-system-prompt)))

    (otherwise
     (cl-agent.core:log-warn "Unknown command: ~A" (first command)))))

;;; ============================================================
;;; Main Loop
;;; ============================================================

(defun agent-run-loop (agent)
  "Main agent loop (runs in background thread).

Parameters:
  AGENT - Process agent"
  (loop
    ;; Check for stop
    (when (agent-stop-flag agent)
      (return))

    ;; Handle pause
    (when (agent-paused-p agent)
      (bt:with-lock-held ((agent-pause-lock agent))
        (loop while (agent-paused-p agent)
              do (bt:condition-wait (agent-pause-condvar agent)
                                    (agent-pause-lock agent))))
      ;; Re-check stop after resume
      (when (agent-stop-flag agent)
        (return)))

    ;; Process events from event queue (non-blocking)
    (process-pending-events agent)

    ;; Wait for message
    (multiple-value-bind (message found)
        (queue-dequeue (agent-input-queue agent) :timeout 1.0)
      (when found
        (cond
          ;; Stop sentinel
          ((eq message :stop)
           (return))

          ;; Process message
          ((stringp message)
           (handler-case
               (let ((response (agent-chat agent message)))
                 (queue-enqueue (agent-output-queue agent)
                                (list :type :response :content response)))
             (error (e)
               (setf (agent-state agent) :error)
               (queue-enqueue (agent-output-queue agent)
                              (list :type :error :message (format nil "~A" e)))
               (fire-agent-event
                (make-agent-event-of-type :error agent :error e)))))

          ;; Command plist
          ((and (listp message) (keywordp (first message)))
           (process-agent-command agent message)))))))

;;; ============================================================
;;; Communication
;;; ============================================================

(defun agent-send (agent message)
  "Send a message to the agent.

Parameters:
  AGENT   - Process agent
  MESSAGE - Message string or command plist"
  (queue-enqueue (agent-input-queue agent) message))

(defun agent-receive (agent &key (timeout nil))
  "Receive a response from the agent.

Parameters:
  AGENT   - Process agent
  TIMEOUT - Timeout in seconds

Returns:
  Response plist or NIL"
  (multiple-value-bind (response found)
      (queue-dequeue (agent-output-queue agent) :timeout timeout)
    (if found response nil)))

(defun agent-queue-message (agent message)
  "Alias for agent-send for clarity.

Parameters:
  AGENT   - Process agent
  MESSAGE - Message to queue"
  (agent-send agent message))

;;; ============================================================
;;; Synchronous API
;;; ============================================================

(defun agent-ask (agent message &key (timeout 60.0))
  "Send a message and wait for response.

Parameters:
  AGENT   - Process agent
  MESSAGE - Message string
  TIMEOUT - Timeout in seconds

Returns:
  Response content or NIL"
  (agent-send agent message)
  (let ((response (agent-receive agent :timeout timeout)))
    (when response
      (case (getf response :type)
        (:response (getf response :content))
        (:error (error (getf response :message)))
        (otherwise nil)))))

;;; ============================================================
;;; Cleanup
;;; ============================================================

(defmethod agent-p ((agent process-agent))
  "Process agents are agents."
  t)

;;; ============================================================
;;; Event Injection (C# Process Framework style)
;;; ============================================================

(defun agent-inject-event (agent event)
  "Inject an external event into the agent's event system.

This is similar to C# Process Framework's InputEvent pattern,
allowing external systems to inject events that the agent can
respond to.

Parameters:
  AGENT - Process agent
  EVENT - Process event or event specification plist

Returns:
  The injected event

Example:
  ;; Inject a data-ready event
  (agent-inject-event agent
    (cl-agent.process:make-event
      :type :external
      :name \"data-ready\"
      :data '(:file \"data.csv\")))

  ;; Or with plist specification
  (agent-inject-event agent
    '(:type :approval :data t :source \"manager\"))"
  (let ((evt (if (typep event 'cl-agent.process:process-event)
                 event
                 (apply #'cl-agent.process:make-event event))))
    ;; Push to event queue
    (cl-agent.process:event-queue-push (agent-event-queue agent) evt)

    ;; Publish to event bus for subscribed handlers
    (cl-agent.process:event-bus-publish (agent-event-bus agent) evt)

    ;; Also inject into process runtime if present
    (when (agent-process-runtime agent)
      (cl-agent.process:runtime-inject-event (agent-process-runtime agent) evt))

    evt))

(defun agent-subscribe-event (agent event-type handler)
  "Subscribe to events of a specific type.

Parameters:
  AGENT      - Process agent
  EVENT-TYPE - Event type keyword or pattern
  HANDLER    - Function (event) -> result

Example:
  (agent-subscribe-event agent :approval
    (lambda (event)
      (format t \"Got approval: ~A~%\" (cl-agent.process:event-data event))))"
  (cl-agent.process:event-bus-subscribe (agent-event-bus agent) event-type handler)
  (push (cons event-type handler) (agent-event-handlers agent)))

(defun agent-unsubscribe-event (agent subscription-id)
  "Unsubscribe from events.

Parameters:
  AGENT           - Process agent
  SUBSCRIPTION-ID - Subscription ID returned by subscribe"
  (cl-agent.process:event-bus-unsubscribe (agent-event-bus agent) subscription-id))

;;; ============================================================
;;; Human-in-the-Loop Support
;;; ============================================================

(defun agent-request-input (agent request)
  "Request human input (non-blocking).

Parameters:
  AGENT   - Process agent
  REQUEST - Input request

Returns:
  Request ID

Example:
  (agent-request-input agent
    (cl-agent.process:make-input-request
      :type :approval
      :prompt \"Do you approve this action?\"))"
  (cl-agent.process:human-loop-request-input-async
   (agent-human-loop agent) request nil)
  (cl-agent.process:input-request-id request))

(defun agent-submit-input (agent response)
  "Submit a response to a human input request.

Parameters:
  AGENT    - Process agent
  RESPONSE - Input response

Returns:
  T if accepted

Example:
  (agent-submit-input agent
    (cl-agent.process:make-input-response request-id
      :value \"approved\"
      :approved-p t))"
  (let ((result (cl-agent.process:human-loop-submit-response
                 (agent-human-loop agent) response)))
    (when result
      ;; Also inject as event
      (agent-inject-event agent
                          (cl-agent.process:make-event
                           :type cl-agent.process:+event-type-input+
                           :name "human-input"
                           :data response
                           :source :human)))
    result))

(defun agent-wait-for-approval (agent prompt &key description timeout)
  "Convenience function to wait for approval.

Parameters:
  AGENT       - Process agent
  PROMPT      - Approval prompt
  DESCRIPTION - Detailed description
  TIMEOUT     - Timeout in seconds

Returns:
  T if approved, NIL if rejected or timeout"
  (cl-agent.process:wait-for-approval (agent-human-loop agent) prompt
                                       :description description
                                       :timeout timeout))

(defun agent-wait-for-confirmation (agent prompt &key timeout default)
  "Convenience function to wait for yes/no confirmation.

Parameters:
  AGENT   - Process agent
  PROMPT  - Confirmation prompt
  TIMEOUT - Timeout in seconds
  DEFAULT - Default value

Returns:
  T for yes, NIL for no"
  (cl-agent.process:wait-for-confirmation (agent-human-loop agent) prompt
                                           :timeout timeout
                                           :default default))

(defun agent-get-pending-inputs (agent)
  "Get pending human input requests.

Parameters:
  AGENT - Process agent

Returns:
  List of input requests"
  (cl-agent.process:human-loop-pending-requests (agent-human-loop agent)))

;;; ============================================================
;;; Process Runtime Control
;;; ============================================================

(defun agent-start-process (agent &key input)
  "Start the process runtime (for step-based workflows).

Parameters:
  AGENT - Process agent
  INPUT - Initial input data

Returns:
  The agent"
  (when (agent-process-runtime agent)
    (cl-agent.process:runtime-start (agent-process-runtime agent)
                                     :input input
                                     :async t))
  agent)

(defun agent-get-process-state (agent)
  "Get process runtime state.

Parameters:
  AGENT - Process agent

Returns:
  State plist or NIL if no process runtime"
  (when (agent-process-runtime agent)
    (cl-agent.process:runtime-get-state (agent-process-runtime agent))))

