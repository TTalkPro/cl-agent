;;;; process-agent.lisp
;;;; CL-Agent SimpleAgent - Process Agent
;;;;
;;;; Overview:
;;;;   Agent that runs in a background thread with pause/resume support.
;;;;   Uses message queues for communication.
;;;;
;;;; Usage:
;;;;   (let ((agent (make-process-agent kernel)))
;;;;     (agent-start agent)
;;;;     (agent-send agent "Hello!")
;;;;     (sleep 1)
;;;;     (agent-pause agent)
;;;;     (agent-resume agent)
;;;;     (agent-stop agent))

(in-package #:cl-agent.simpleagent)

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
    :documentation "Flag to signal thread to stop"))

  (:documentation "Agent that runs in background thread with pause/resume."))

;;; ============================================================
;;; Constructor
;;; ============================================================

(defun make-process-agent (kernel &key name system-prompt settings callbacks)
  "Create a Process Agent.

Parameters:
  KERNEL        - Kernel instance
  NAME          - Agent name (optional)
  SYSTEM-PROMPT - System prompt (optional)
  SETTINGS      - Settings plist (optional)
  CALLBACKS     - Callback functions (optional)

Returns:
  New process-agent instance"
  (make-instance 'process-agent
                 :kernel kernel
                 :name (or name "process-agent")
                 :system-prompt system-prompt
                 :settings (merge-settings (default-agent-settings) settings)
                 :callbacks callbacks
                 :context (make-context)))

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
