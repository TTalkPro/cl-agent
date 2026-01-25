;;;; state-machine.lisp
;;;; CL-Agent Core - Process State Machine
;;;;
;;;; Finite state machine for process flow control.

(in-package #:cl-agent.process)

;;; ============================================================
;;; State Class
;;; ============================================================

(defclass process-state ()
  ((name
    :initarg :name
    :accessor state-name
    :documentation "State name (keyword)")

   (data
    :initarg :data
    :initform nil
    :accessor state-data
    :documentation "State-specific data")

   (enter-action
    :initarg :enter-action
    :initform nil
    :accessor state-enter-action
    :documentation "Action called when entering state")

   (exit-action
    :initarg :exit-action
    :initform nil
    :accessor state-exit-action
    :documentation "Action called when exiting state")

   (metadata
    :initarg :metadata
    :initform nil
    :accessor state-metadata
    :documentation "Additional metadata"))

  (:documentation "Represents a state in the state machine."))

(defun make-state (name &key data enter-action exit-action metadata)
  "Create a new state.

Parameters:
  NAME         - State name (keyword)
  DATA         - State-specific data
  ENTER-ACTION - Function called on enter (context state)
  EXIT-ACTION  - Function called on exit (context state)
  METADATA     - Additional metadata

Returns:
  New process-state instance"
  (make-instance 'process-state
                 :name name
                 :data data
                 :enter-action enter-action
                 :exit-action exit-action
                 :metadata metadata))

(defmethod print-object ((state process-state) stream)
  (print-unreadable-object (state stream :type t)
    (format stream "~A" (state-name state))))

;;; ============================================================
;;; Transition Class
;;; ============================================================

(defclass state-transition ()
  ((from
    :initarg :from
    :accessor transition-from
    :documentation "Source state name")

   (to
    :initarg :to
    :accessor transition-to
    :documentation "Target state name")

   (event
    :initarg :event
    :initform nil
    :accessor transition-event
    :documentation "Event that triggers transition (keyword or pattern)")

   (guard
    :initarg :guard
    :initform nil
    :accessor transition-guard
    :documentation "Guard function (context event) -> boolean")

   (action
    :initarg :action
    :initform nil
    :accessor transition-action
    :documentation "Action to execute during transition"))

  (:documentation "Represents a state transition."))

(defun make-transition (from to &key event guard action)
  "Create a state transition.

Parameters:
  FROM   - Source state name
  TO     - Target state name
  EVENT  - Triggering event
  GUARD  - Guard function
  ACTION - Transition action

Returns:
  New state-transition instance"
  (make-instance 'state-transition
                 :from from
                 :to to
                 :event event
                 :guard guard
                 :action action))

(defmethod print-object ((transition state-transition) stream)
  (print-unreadable-object (transition stream :type t)
    (format stream "~A -> ~A on ~A"
            (transition-from transition)
            (transition-to transition)
            (transition-event transition))))

;;; ============================================================
;;; State Machine Class
;;; ============================================================

(defclass state-machine ()
  ((states
    :initform (make-hash-table)
    :accessor state-machine-states
    :documentation "State name -> state mapping")

   (transitions
    :initform nil
    :accessor state-machine-transitions
    :documentation "List of transitions")

   (current-state
    :initarg :initial-state
    :initform nil
    :accessor state-machine-current-state
    :documentation "Current state name")

   (history
    :initform nil
    :accessor state-machine-history
    :documentation "State transition history")

   (lock
    :initform (make-lock "state-machine-lock")
    :reader state-machine-lock
    :documentation "Thread safety lock")

   (on-transition
    :initarg :on-transition
    :initform nil
    :accessor state-machine-on-transition
    :documentation "Callback (from to event) on transition")

   (on-error
    :initarg :on-error
    :initform nil
    :accessor state-machine-on-error
    :documentation "Callback (error) on error"))

  (:documentation "Finite state machine for process control."))

(defun make-state-machine (&key initial-state on-transition on-error)
  "Create a new state machine.

Parameters:
  INITIAL-STATE - Initial state name
  ON-TRANSITION - Transition callback
  ON-ERROR      - Error callback

Returns:
  New state-machine instance"
  (make-instance 'state-machine
                 :initial-state initial-state
                 :on-transition on-transition
                 :on-error on-error))

;;; ============================================================
;;; State Management
;;; ============================================================

(defun state-machine-add-state (machine state)
  "Add a state to the machine.

Parameters:
  MACHINE - State machine
  STATE   - Process state

Returns:
  The state"
  (with-lock-held ((state-machine-lock machine))
    (setf (gethash (state-name state) (state-machine-states machine))
          state))
  state)

(defun state-machine-get-state (machine name)
  "Get state by name.

Parameters:
  MACHINE - State machine
  NAME    - State name

Returns:
  Process state or NIL"
  (gethash name (state-machine-states machine)))

(defun state-machine-remove-state (machine name)
  "Remove a state from the machine.

Parameters:
  MACHINE - State machine
  NAME    - State name

Returns:
  T if removed"
  (with-lock-held ((state-machine-lock machine))
    (remhash name (state-machine-states machine))
    ;; Remove related transitions
    (setf (state-machine-transitions machine)
          (remove-if (lambda (tr)
                       (or (eq (transition-from tr) name)
                           (eq (transition-to tr) name)))
                     (state-machine-transitions machine)))
    t))

;;; ============================================================
;;; Transition Management
;;; ============================================================

(defun state-machine-add-transition (machine transition)
  "Add a transition to the machine.

Parameters:
  MACHINE    - State machine
  TRANSITION - State transition

Returns:
  The transition"
  (with-lock-held ((state-machine-lock machine))
    (push transition (state-machine-transitions machine)))
  transition)

(defun state-machine-get-transitions (machine from-state)
  "Get all transitions from a state.

Parameters:
  MACHINE    - State machine
  FROM-STATE - Source state name

Returns:
  List of transitions"
  (remove-if-not (lambda (tr) (eq (transition-from tr) from-state))
                 (state-machine-transitions machine)))

(defun state-machine-find-transition (machine event &optional context)
  "Find valid transition for event from current state.

Parameters:
  MACHINE - State machine
  EVENT   - Event (keyword or process-event)
  CONTEXT - Execution context for guard evaluation

Returns:
  Matching transition or NIL"
  (let ((current (state-machine-current-state machine))
        (event-key (if (typep event 'process-event)
                       (event-type event)
                       event)))
    (find-if (lambda (tr)
               (and (eq (transition-from tr) current)
                    (or (null (transition-event tr))
                        (eq (transition-event tr) event-key)
                        (and (typep event 'process-event)
                             (event-matches-p event (transition-event tr))))
                    (or (null (transition-guard tr))
                        (funcall (transition-guard tr) context event))))
             (state-machine-transitions machine))))

;;; ============================================================
;;; State Machine Operations
;;; ============================================================

(defun state-machine-trigger (machine event &optional context)
  "Trigger a state transition.

Parameters:
  MACHINE - State machine
  EVENT   - Triggering event
  CONTEXT - Execution context

Returns:
  T if transition occurred, NIL otherwise"
  (with-lock-held ((state-machine-lock machine))
    (let ((transition (state-machine-find-transition machine event context)))
      (unless transition
        (return-from state-machine-trigger nil))

      (handler-case
          (let ((from-state (state-machine-get-state machine
                                                     (transition-from transition)))
                (to-state (state-machine-get-state machine
                                                   (transition-to transition))))

            ;; Exit current state
            (when (and from-state (state-exit-action from-state))
              (funcall (state-exit-action from-state) context from-state))

            ;; Execute transition action
            (when (transition-action transition)
              (funcall (transition-action transition) context event))

            ;; Update current state
            (setf (state-machine-current-state machine) (transition-to transition))

            ;; Enter new state
            (when (and to-state (state-enter-action to-state))
              (funcall (state-enter-action to-state) context to-state))

            ;; Record history
            (push (list :from (transition-from transition)
                        :to (transition-to transition)
                        :event event
                        :timestamp (get-universal-time))
                  (state-machine-history machine))

            ;; Callback
            (when (state-machine-on-transition machine)
              (funcall (state-machine-on-transition machine)
                       (transition-from transition)
                       (transition-to transition)
                       event))

            t)

        (error (e)
          (when (state-machine-on-error machine)
            (funcall (state-machine-on-error machine) e))
          (error e))))))

(defun state-machine-can-trigger-p (machine event &optional context)
  "Check if event can trigger a transition.

Parameters:
  MACHINE - State machine
  EVENT   - Event to check
  CONTEXT - Execution context

Returns:
  T if transition is possible"
  (not (null (state-machine-find-transition machine event context))))

(defun state-machine-set-state (machine state-name &optional context)
  "Forcefully set current state (bypassing transitions).

Parameters:
  MACHINE    - State machine
  STATE-NAME - New state name
  CONTEXT    - Execution context

Returns:
  Previous state name"
  (with-lock-held ((state-machine-lock machine))
    (let ((previous (state-machine-current-state machine))
          (old-state (state-machine-get-state machine previous))
          (new-state (state-machine-get-state machine state-name)))

      ;; Exit old state
      (when (and old-state (state-exit-action old-state))
        (funcall (state-exit-action old-state) context old-state))

      ;; Update
      (setf (state-machine-current-state machine) state-name)

      ;; Enter new state
      (when (and new-state (state-enter-action new-state))
        (funcall (state-enter-action new-state) context new-state))

      previous)))

(defun state-machine-reset (machine &optional context)
  "Reset state machine to initial state.

Parameters:
  MACHINE - State machine
  CONTEXT - Execution context"
  (with-lock-held ((state-machine-lock machine))
    (setf (state-machine-history machine) nil)
    ;; Find initial state (first added or explicitly marked)
    (let ((initial (or (find :initial (hash-table-values (state-machine-states machine))
                            :key (lambda (s) (getf (state-metadata s) :initial)))
                       (first (hash-table-values (state-machine-states machine))))))
      (when initial
        (setf (state-machine-current-state machine) (state-name initial))
        (when (state-enter-action initial)
          (funcall (state-enter-action initial) context initial))))))

;;; ============================================================
;;; Builder Pattern
;;; ============================================================

(defun state-machine-builder ()
  "Start building a state machine.

Returns:
  New state machine for builder pattern"
  (make-state-machine))

(defun with-state (machine name &key data enter exit initial)
  "Add a state (builder pattern).

Parameters:
  MACHINE - State machine
  NAME    - State name
  DATA    - State data
  ENTER   - Enter action
  EXIT    - Exit action
  INITIAL - T if initial state

Returns:
  The machine"
  (let ((state (make-state name
                           :data data
                           :enter-action enter
                           :exit-action exit
                           :metadata (when initial '(:initial t)))))
    (state-machine-add-state machine state)
    (when initial
      (setf (state-machine-current-state machine) name)))
  machine)

(defun with-transition-rule (machine from to &key on guard action)
  "Add a transition (builder pattern).

Parameters:
  MACHINE - State machine
  FROM    - Source state
  TO      - Target state
  ON      - Triggering event
  GUARD   - Guard function
  ACTION  - Transition action

Returns:
  The machine"
  (state-machine-add-transition machine
    (make-transition from to :event on :guard guard :action action))
  machine)

;;; ============================================================
;;; Predefined State Machines
;;; ============================================================

(defun make-process-state-machine ()
  "Create a standard process state machine.

States: :idle -> :running -> :paused -> :completed/:failed

Returns:
  Configured state machine"
  (let ((sm (state-machine-builder)))
    ;; States
    (with-state sm :idle :initial t)
    (with-state sm :running)
    (with-state sm :paused)
    (with-state sm :waiting)
    (with-state sm :completed)
    (with-state sm :failed)

    ;; Transitions
    (with-transition-rule sm :idle :running :on :start)
    (with-transition-rule sm :running :paused :on :pause)
    (with-transition-rule sm :running :waiting :on :wait)
    (with-transition-rule sm :running :completed :on :complete)
    (with-transition-rule sm :running :failed :on :fail)
    (with-transition-rule sm :paused :running :on :resume)
    (with-transition-rule sm :paused :idle :on :stop)
    (with-transition-rule sm :waiting :running :on :continue)
    (with-transition-rule sm :waiting :failed :on :timeout)
    (with-transition-rule sm :completed :idle :on :reset)
    (with-transition-rule sm :failed :idle :on :reset)

    sm))
