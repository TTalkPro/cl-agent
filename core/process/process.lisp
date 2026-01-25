;;;; process.lisp
;;;; CL-Agent Core - Process Definition
;;;;
;;;; Defines process workflows with steps, events, and flow control.

(in-package #:cl-agent.process)

;;; ============================================================
;;; Process Definition Class
;;; ============================================================

(defclass process-definition ()
  ((id
    :initarg :id
    :initform (generate-process-id)
    :reader process-id
    :documentation "Unique process identifier")

   (name
    :initarg :name
    :initform "unnamed-process"
    :accessor process-name
    :documentation "Process name")

   (description
    :initarg :description
    :initform nil
    :accessor process-description
    :documentation "Process description")

   (version
    :initarg :version
    :initform "1.0.0"
    :accessor process-version
    :documentation "Process version")

   (steps
    :initarg :steps
    :initform nil
    :accessor process-steps
    :documentation "Ordered list of steps or step graph")

   (step-map
    :initform (make-hash-table :test 'equal)
    :accessor process-step-map
    :documentation "Step name -> step mapping")

   (initial-step
    :initarg :initial-step
    :initform nil
    :accessor process-initial-step
    :documentation "Initial step name")

   (final-steps
    :initarg :final-steps
    :initform nil
    :accessor process-final-steps
    :documentation "List of final step names")

   (event-handlers
    :initarg :event-handlers
    :initform nil
    :accessor process-event-handlers
    :documentation "Event pattern -> handler mapping")

   (global-timeout
    :initarg :global-timeout
    :initform nil
    :accessor process-global-timeout
    :documentation "Overall process timeout")

   (on-start
    :initarg :on-start
    :initform nil
    :accessor process-on-start
    :documentation "Hook called when process starts")

   (on-complete
    :initarg :on-complete
    :initform nil
    :accessor process-on-complete
    :documentation "Hook called when process completes")

   (on-error
    :initarg :on-error
    :initform nil
    :accessor process-on-error
    :documentation "Hook called on error")

   (metadata
    :initarg :metadata
    :initform nil
    :accessor process-metadata
    :documentation "Additional metadata"))

  (:documentation "Defines a process workflow."))

(defun generate-process-id ()
  "Generate unique process ID."
  (format nil "proc-~A-~A"
          (get-universal-time)
          (random 100000)))

(defun make-process (name &key description version steps initial-step final-steps
                              event-handlers global-timeout
                              on-start on-complete on-error metadata)
  "Create a process definition.

Parameters:
  NAME           - Process name
  DESCRIPTION    - Process description
  VERSION        - Process version
  STEPS          - List of steps
  INITIAL-STEP   - Initial step name
  FINAL-STEPS    - Final step names
  EVENT-HANDLERS - Event handlers
  GLOBAL-TIMEOUT - Overall timeout
  ON-START       - Start hook
  ON-COMPLETE    - Complete hook
  ON-ERROR       - Error hook
  METADATA       - Additional metadata

Returns:
  New process-definition instance"
  (let ((process (make-instance 'process-definition
                                :name name
                                :description description
                                :version (or version "1.0.0")
                                :steps steps
                                :initial-step initial-step
                                :final-steps final-steps
                                :event-handlers event-handlers
                                :global-timeout global-timeout
                                :on-start on-start
                                :on-complete on-complete
                                :on-error on-error
                                :metadata metadata)))
    ;; Build step map
    (dolist (step steps)
      (setf (gethash (step-name step) (process-step-map process)) step))

    ;; Set initial step if not specified
    (unless (process-initial-step process)
      (when steps
        (setf (process-initial-step process) (step-name (first steps)))))

    process))

(defmethod print-object ((process process-definition) stream)
  (print-unreadable-object (process stream :type t)
    (format stream "~A v~A (~A steps)"
            (process-name process)
            (process-version process)
            (length (process-steps process)))))

;;; ============================================================
;;; Step Management
;;; ============================================================

(defun process-get-step (process step-name)
  "Get step by name.

Parameters:
  PROCESS   - Process definition
  STEP-NAME - Step name

Returns:
  Process step or NIL"
  (gethash step-name (process-step-map process)))

(defun process-add-step (process step &key after before)
  "Add a step to the process.

Parameters:
  PROCESS - Process definition
  STEP    - Process step
  AFTER   - Insert after this step name
  BEFORE  - Insert before this step name

Returns:
  The process"
  (setf (gethash (step-name step) (process-step-map process)) step)

  (cond
    (after
     (let ((pos (position after (process-steps process)
                          :key #'step-name :test 'equal)))
       (if pos
           (setf (process-steps process)
                 (append (subseq (process-steps process) 0 (1+ pos))
                         (list step)
                         (subseq (process-steps process) (1+ pos))))
           (push step (process-steps process)))))

    (before
     (let ((pos (position before (process-steps process)
                          :key #'step-name :test 'equal)))
       (if pos
           (setf (process-steps process)
                 (append (subseq (process-steps process) 0 pos)
                         (list step)
                         (subseq (process-steps process) pos)))
           (setf (process-steps process)
                 (append (process-steps process) (list step))))))

    (t
     (setf (process-steps process)
           (append (process-steps process) (list step)))))

  process)

(defun process-remove-step (process step-name)
  "Remove a step from the process.

Parameters:
  PROCESS   - Process definition
  STEP-NAME - Step name

Returns:
  The process"
  (remhash step-name (process-step-map process))
  (setf (process-steps process)
        (remove step-name (process-steps process) :key #'step-name :test 'equal))
  process)

(defun process-next-step (process current-step-name)
  "Get the next step after current.

Parameters:
  PROCESS           - Process definition
  CURRENT-STEP-NAME - Current step name

Returns:
  Next step name or NIL"
  (let ((steps (process-steps process)))
    (loop for (step next) on steps
          when (equal (step-name step) current-step-name)
            return (when next (step-name next)))))

;;; ============================================================
;;; Event Handling
;;; ============================================================

(defun process-add-event-handler (process pattern handler)
  "Add an event handler.

Parameters:
  PROCESS - Process definition
  PATTERN - Event pattern
  HANDLER - Handler function (context event) -> step-result

Returns:
  The process"
  (push (cons pattern handler) (process-event-handlers process))
  process)

(defun process-get-event-handler (process event)
  "Get handler for event.

Parameters:
  PROCESS - Process definition
  EVENT   - Process event

Returns:
  Handler function or NIL"
  (loop for (pattern . handler) in (process-event-handlers process)
        when (event-matches-p event pattern)
          return handler))

;;; ============================================================
;;; Process Builder
;;; ============================================================

(defclass process-builder ()
  ((process
    :initform nil
    :accessor builder-process)
   (current-step
    :initform nil
    :accessor builder-current-step))
  (:documentation "Fluent builder for process definitions."))

(defun build-process (name &key description version)
  "Start building a process.

Parameters:
  NAME        - Process name
  DESCRIPTION - Process description
  VERSION     - Process version

Returns:
  Process builder"
  (let ((builder (make-instance 'process-builder)))
    (setf (builder-process builder)
          (make-process name :description description :version version))
    builder))

(defun add-step-to-process (builder step)
  "Add a step to the process being built.

Parameters:
  BUILDER - Process builder
  STEP    - Process step

Returns:
  The builder"
  (process-add-step (builder-process builder) step)
  (setf (builder-current-step builder) (step-name step))
  builder)

(defun add-event-handler-to-process (builder pattern handler)
  "Add an event handler.

Parameters:
  BUILDER - Process builder
  PATTERN - Event pattern
  HANDLER - Handler function

Returns:
  The builder"
  (process-add-event-handler (builder-process builder) pattern handler)
  builder)

(defun set-initial-step (builder step-name)
  "Set the initial step.

Parameters:
  BUILDER   - Process builder
  STEP-NAME - Initial step name

Returns:
  The builder"
  (setf (process-initial-step (builder-process builder)) step-name)
  builder)

(defun set-final-steps (builder &rest step-names)
  "Set final steps.

Parameters:
  BUILDER    - Process builder
  STEP-NAMES - Final step names

Returns:
  The builder"
  (setf (process-final-steps (builder-process builder)) step-names)
  builder)

(defun set-global-timeout (builder timeout)
  "Set global timeout.

Parameters:
  BUILDER - Process builder
  TIMEOUT - Timeout in seconds

Returns:
  The builder"
  (setf (process-global-timeout (builder-process builder)) timeout)
  builder)

(defun on-process-start (builder hook)
  "Set start hook.

Parameters:
  BUILDER - Process builder
  HOOK    - Start hook function

Returns:
  The builder"
  (setf (process-on-start (builder-process builder)) hook)
  builder)

(defun on-process-complete (builder hook)
  "Set complete hook.

Parameters:
  BUILDER - Process builder
  HOOK    - Complete hook function

Returns:
  The builder"
  (setf (process-on-complete (builder-process builder)) hook)
  builder)

(defun on-process-error (builder hook)
  "Set error hook.

Parameters:
  BUILDER - Process builder
  HOOK    - Error hook function

Returns:
  The builder"
  (setf (process-on-error (builder-process builder)) hook)
  builder)

(defun finalize-process (builder)
  "Finalize and return the process.

Parameters:
  BUILDER - Process builder

Returns:
  Process definition"
  (builder-process builder))

;;; ============================================================
;;; Process Definition Macro
;;; ============================================================

(defmacro defprocess (name &body body)
  "Define a process.

Usage:
  (defprocess my-process
    :description \"Process description\"
    :version \"1.0.0\"

    :steps
    ((step-1
      :description \"First step\"
      :handler (lambda (ctx input)
                 (step-completed :output (process input))))

     (step-2
      :description \"Second step\"
      :wait-for (:approval)
      :handler (lambda (ctx input)
                 (step-completed :output input))))

    :on-event
    ((:cancel . (lambda (ctx event)
                  (step-failed \"Cancelled\"))))

    :on-start (lambda (ctx) (log \"Starting...\"))
    :on-complete (lambda (ctx result) (log \"Done: ~A\" result)))

Parameters:
  NAME - Process name
  BODY - Process specification"
  (let ((description (getf body :description))
        (version (getf body :version))
        (steps-spec (getf body :steps))
        (on-event (getf body :on-event))
        (initial (getf body :initial))
        (final (getf body :final))
        (timeout (getf body :timeout))
        (on-start (getf body :on-start))
        (on-complete (getf body :on-complete))
        (on-error (getf body :on-error)))

    `(defparameter ,name
       (let ((process (make-process ,(string-downcase (symbol-name name))
                                    :description ,description
                                    :version ,version
                                    :global-timeout ,timeout
                                    :on-start ,on-start
                                    :on-complete ,on-complete
                                    :on-error ,on-error)))
         ;; Add steps
         ,@(loop for (step-name . step-opts) in steps-spec
                 collect `(process-add-step process
                            (make-step ,(string-downcase (symbol-name step-name))
                                       ,@step-opts)))

         ;; Set initial/final
         ,(when initial `(setf (process-initial-step process) ,initial))
         ,(when final `(setf (process-final-steps process) ',final))

         ;; Add event handlers
         ,@(loop for (pattern . handler) in on-event
                 collect `(process-add-event-handler process ',pattern ,handler))

         process))))

;;; ============================================================
;;; Process Validation
;;; ============================================================

(defun validate-process (process)
  "Validate a process definition.

Parameters:
  PROCESS - Process definition

Returns:
  T if valid, or list of errors"
  (let ((errors nil))

    ;; Check steps exist
    (unless (process-steps process)
      (push "Process has no steps" errors))

    ;; Check initial step exists
    (when (process-initial-step process)
      (unless (process-get-step process (process-initial-step process))
        (push (format nil "Initial step '~A' not found"
                      (process-initial-step process))
              errors)))

    ;; Check final steps exist
    (dolist (final (process-final-steps process))
      (unless (process-get-step process final)
        (push (format nil "Final step '~A' not found" final) errors)))

    ;; Check step handlers
    (dolist (step (process-steps process))
      (unless (step-handler step)
        (push (format nil "Step '~A' has no handler" (step-name step)) errors)))

    (if errors
        (nreverse errors)
        t)))

;;; ============================================================
;;; Process Copying
;;; ============================================================

(defun copy-process (process &key name version)
  "Create a copy of a process definition.

Parameters:
  PROCESS - Process to copy
  NAME    - New name (optional)
  VERSION - New version (optional)

Returns:
  New process definition"
  (make-process (or name (process-name process))
                :description (process-description process)
                :version (or version (process-version process))
                :steps (mapcar #'copy-step (process-steps process))
                :initial-step (process-initial-step process)
                :final-steps (copy-list (process-final-steps process))
                :event-handlers (copy-list (process-event-handlers process))
                :global-timeout (process-global-timeout process)
                :on-start (process-on-start process)
                :on-complete (process-on-complete process)
                :on-error (process-on-error process)
                :metadata (copy-list (process-metadata process))))

(defun copy-step (step)
  "Create a copy of a step.

Parameters:
  STEP - Step to copy

Returns:
  New step"
  (make-step (step-name step)
             :description (step-description step)
             :handler (step-handler step)
             :input-schema (step-input-schema step)
             :output-schema (step-output-schema step)
             :wait-for-events (copy-list (step-wait-for-events step))
             :emit-events (copy-list (step-emit-events step))
             :timeout (step-timeout step)
             :retry-policy (step-retry-policy step)
             :condition (step-condition step)
             :on-enter (step-on-enter step)
             :on-exit (step-on-exit step)
             :metadata (copy-list (step-metadata step))))
