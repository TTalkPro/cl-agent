;;;; process-framework-usage.lisp
;;;; CL-Agent Examples - Process Framework Usage
;;;;
;;;; This example demonstrates direct usage of the Process Framework,
;;;; including events, state machines, human-in-the-loop, and workflows.

(in-package #:cl-user)

;;; ============================================================
;;; Setup
;;; ============================================================

(defpackage #:cl-agent.examples.process
  (:use #:cl)
  (:export #:run-process-examples))

(in-package #:cl-agent.examples.process)

;;; ============================================================
;;; Example 1: Event System
;;; ============================================================

(defun example-event-system ()
  "Demonstrate the event bus and event queue."
  (format t "~%=== Example 1: Event System ===~%")

  ;; Create event bus
  (let ((bus (cl-agent.process:make-event-bus))
        (received-events nil))

    ;; Subscribe to events
    (cl-agent.process:event-bus-subscribe bus :external
      (lambda (event)
        (push (cl-agent.process:event-name event) received-events)
        (format t "  Received external event: ~A~%"
                (cl-agent.process:event-name event))))

    (cl-agent.process:event-bus-subscribe bus :approval
      (lambda (event)
        (format t "  Received approval event: ~A~%"
                (cl-agent.process:event-data event))))

    ;; Publish events
    (format t "Publishing events...~%")
    (cl-agent.process:event-bus-publish bus
      (cl-agent.process:make-event :type :external
                                    :name "data-ready"
                                    :data '(:file "test.csv")))

    (cl-agent.process:event-bus-publish bus
      (cl-agent.process:make-event :type :approval
                                    :name "review-result"
                                    :data t))

    (format t "Events received: ~A~%" (nreverse received-events)))

  ;; Event queue example
  (format t "~%Event Queue Example:~%")
  (let ((queue (cl-agent.process:make-event-queue)))
    (cl-agent.process:event-queue-push queue
      (cl-agent.process:make-event :type :external :name "event-1"))
    (cl-agent.process:event-queue-push queue
      (cl-agent.process:make-event :type :external :name "event-2"))

    (format t "  Queue empty? ~A~%" (cl-agent.process:event-queue-empty-p queue))

    (let ((e1 (cl-agent.process:event-queue-pop queue :timeout 0))
          (e2 (cl-agent.process:event-queue-pop queue :timeout 0)))
      (format t "  Popped: ~A, ~A~%"
              (cl-agent.process:event-name e1)
              (cl-agent.process:event-name e2)))))

;;; ============================================================
;;; Example 2: State Machine
;;; ============================================================

(defun example-state-machine ()
  "Demonstrate finite state machine."
  (format t "~%=== Example 2: State Machine ===~%")

  ;; Create state machine using builder
  (let ((sm (cl-agent.process:state-machine-builder)))

    ;; Add states
    (cl-agent.process:with-state sm :idle :initial t)
    (cl-agent.process:with-state sm :processing)
    (cl-agent.process:with-state sm :waiting)
    (cl-agent.process:with-state sm :completed)
    (cl-agent.process:with-state sm :failed)

    ;; Add transitions
    (cl-agent.process:with-transition-rule sm :idle :processing :on :start)
    (cl-agent.process:with-transition-rule sm :processing :waiting :on :wait)
    (cl-agent.process:with-transition-rule sm :processing :completed :on :complete)
    (cl-agent.process:with-transition-rule sm :waiting :processing :on :continue)
    (cl-agent.process:with-transition-rule sm :processing :failed :on :error)

    (format t "Initial state: ~A~%"
            (cl-agent.process:state-machine-current-state sm))

    ;; Trigger transitions
    (format t "Triggering :start...~%")
    (cl-agent.process:state-machine-trigger sm :start)
    (format t "Current state: ~A~%"
            (cl-agent.process:state-machine-current-state sm))

    (format t "Triggering :wait...~%")
    (cl-agent.process:state-machine-trigger sm :wait)
    (format t "Current state: ~A~%"
            (cl-agent.process:state-machine-current-state sm))

    (format t "Triggering :continue...~%")
    (cl-agent.process:state-machine-trigger sm :continue)
    (format t "Current state: ~A~%"
            (cl-agent.process:state-machine-current-state sm))

    (format t "Triggering :complete...~%")
    (cl-agent.process:state-machine-trigger sm :complete)
    (format t "Final state: ~A~%"
            (cl-agent.process:state-machine-current-state sm))))

;;; ============================================================
;;; Example 3: Step Definition
;;; ============================================================

(defun example-steps ()
  "Demonstrate step definition and execution."
  (format t "~%=== Example 3: Steps ===~%")

  ;; Create steps
  (let ((validate-step
          (cl-agent.process:make-step "validate"
            :description "Validate input data"
            :handler (lambda (ctx input)
                       (declare (ignore ctx))
                       (if (and input (listp input))
                           (cl-agent.process:step-completed :output input)
                           (cl-agent.process:step-failed "Invalid input")))))

        (process-step
          (cl-agent.process:make-step "process"
            :description "Process the data"
            :timeout 30
            :handler (lambda (ctx input)
                       (declare (ignore ctx))
                       (cl-agent.process:step-completed
                         :output (list :processed t :data input))))))

    (format t "Step 1: ~A - ~A~%"
            (cl-agent.process:step-name validate-step)
            (cl-agent.process:step-description validate-step))

    (format t "Step 2: ~A - ~A~%"
            (cl-agent.process:step-name process-step)
            (cl-agent.process:step-description process-step))

    ;; Execute steps
    (let* ((context (cl-agent.process:make-execution-context))
           (result1 (cl-agent.process:execute-step validate-step context '(:a 1 :b 2))))
      (format t "Validate result: ~A~%"
              (cl-agent.process:step-result-status result1))

      (let ((result2 (cl-agent.process:execute-step process-step context
                                                     (cl-agent.process:step-result-output result1))))
        (format t "Process result: ~A~%"
                (cl-agent.process:step-result-output result2))))))

;;; ============================================================
;;; Example 4: Process Definition
;;; ============================================================

(defun example-process-definition ()
  "Demonstrate process definition with defprocess macro."
  (format t "~%=== Example 4: Process Definition ===~%")

  ;; Define a simple process
  (let ((process (cl-agent.process:make-process "data-pipeline"
                   :description "Simple data processing pipeline"
                   :version "1.0.0")))

    ;; Add steps
    (cl-agent.process:process-add-step process
      (cl-agent.process:make-step "input"
        :description "Accept input"
        :handler (lambda (ctx input)
                   (declare (ignore ctx))
                   (cl-agent.process:step-completed :output input))))

    (cl-agent.process:process-add-step process
      (cl-agent.process:make-step "transform"
        :description "Transform data"
        :handler (lambda (ctx input)
                   (declare (ignore ctx))
                   (cl-agent.process:step-completed
                     :output (list :transformed input)))))

    (cl-agent.process:process-add-step process
      (cl-agent.process:make-step "output"
        :description "Output result"
        :handler (lambda (ctx input)
                   (declare (ignore ctx))
                   (cl-agent.process:step-completed :output input))))

    (format t "Process: ~A v~A~%"
            (cl-agent.process:process-name process)
            (cl-agent.process:process-version process))
    (format t "Steps: ~A~%"
            (length (cl-agent.process:process-steps process)))
    (format t "Initial step: ~A~%"
            (cl-agent.process:process-initial-step process))))

;;; ============================================================
;;; Example 5: Human-in-the-Loop (Simulated)
;;; ============================================================

(defun example-human-loop ()
  "Demonstrate human-in-the-loop mechanism (simulated)."
  (format t "~%=== Example 5: Human-in-the-Loop ===~%")

  (let ((hlm (cl-agent.process:make-human-loop-manager
               :on-request (lambda (req)
                             (format t "  [HLM] Request created: ~A~%"
                                     (cl-agent.process:input-request-prompt req)))
               :on-response (lambda (resp)
                              (format t "  [HLM] Response received: ~A~%"
                                      (cl-agent.process:input-response-value resp))))))

    ;; Create a request
    (let ((request (cl-agent.process:make-input-request
                     :type :approval
                     :prompt "Do you approve this action?"
                     :description "This will modify important data"
                     :timeout 5
                     :default t)))

      (format t "Request ID: ~A~%"
              (cl-agent.process:input-request-id request))
      (format t "Request type: ~A~%"
              (cl-agent.process:input-request-type request))

      ;; Simulate async response submission
      (format t "Simulating user approval...~%")
      (bordeaux-threads:make-thread
        (lambda ()
          (sleep 0.5)
          (cl-agent.process:human-loop-submit-response hlm
            (cl-agent.process:make-input-response
              (cl-agent.process:input-request-id request)
              :value "approved"
              :approved-p t
              :comment "Looks good!"
              :responder "admin"))))

      ;; This would block waiting for response
      ;; For demo, we just show the pending state
      (sleep 0.1)
      (format t "Pending requests: ~A~%"
              (length (cl-agent.process:human-loop-pending-requests hlm)))

      ;; Wait a bit for the response
      (sleep 0.6)
      (format t "After response, pending: ~A~%"
              (length (cl-agent.process:human-loop-pending-requests hlm))))))

;;; ============================================================
;;; Example 6: Event Matching
;;; ============================================================

(defun example-event-matching ()
  "Demonstrate event pattern matching."
  (format t "~%=== Example 6: Event Matching ===~%")

  (let ((event1 (cl-agent.process:make-event :type :external :name "data-ready"))
        (event2 (cl-agent.process:make-event :type :approval :name "review-done"))
        (event3 (cl-agent.process:make-event :type :error :name "process-failed")))

    ;; Match by type
    (format t "Event1 matches :external? ~A~%"
            (cl-agent.process:event-matches-p event1 :external))
    (format t "Event2 matches :external? ~A~%"
            (cl-agent.process:event-matches-p event2 :external))

    ;; Match by name pattern
    (format t "Event1 matches 'data-*'? ~A~%"
            (cl-agent.process:event-matches-p event1 "data-*"))
    (format t "Event3 matches '*-failed'? ~A~%"
            (cl-agent.process:event-matches-p event3 "*-failed"))

    ;; Match by compound pattern
    (format t "Event1 matches (:type :external :name \"data-ready\")? ~A~%"
            (cl-agent.process:event-matches-p event1
              '(:type :external :name "data-ready")))))

;;; ============================================================
;;; Run All Examples
;;; ============================================================

(defun run-process-examples ()
  "Run all process framework examples."
  (format t "~%========================================~%")
  (format t "CL-Agent Process Framework Examples~%")
  (format t "========================================~%")

  (handler-case
      (progn
        (example-event-system)
        (example-state-machine)
        (example-steps)
        (example-process-definition)
        (example-human-loop)
        (example-event-matching))
    (error (e)
      (format t "~%Error: ~A~%" e)))

  (format t "~%========================================~%")
  (format t "Examples Complete~%")
  (format t "========================================~%"))
