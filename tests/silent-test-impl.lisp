;;;; silent-test-impl.lisp - Test implementations

(in-package :cl-user)

(handler-case
    (progn
      ;; Test 1: Event system
      (let* ((bus (cl-agent.process:make-event-bus))
             (queue (cl-agent.process:make-event-queue))
             (received nil))
        (cl-agent.process:event-bus-subscribe bus :test
          (lambda (e) (setf received (cl-agent.process:event-name e))))
        (cl-agent.process:event-bus-publish bus
          (cl-agent.process:make-event :type :test :name "ping"))
        (cl-agent.process:event-queue-push queue
          (cl-agent.process:make-event :type :test :name "q1"))
        (let ((e (cl-agent.process:event-queue-pop queue :timeout 0)))
          (format t "Event System: ~A~%" (if (and received e) "PASS" "FAIL"))))

      ;; Test 2: State machine
      (let ((sm (cl-agent.process:state-machine-builder)))
        (cl-agent.process:with-state sm :a :initial t)
        (cl-agent.process:with-state sm :b)
        (cl-agent.process:with-transition-rule sm :a :b :on :go)
        (cl-agent.process:state-machine-trigger sm :go)
        (format t "State Machine: ~A~%"
                (if (eq (cl-agent.process:state-machine-current-state sm) :b) "PASS" "FAIL")))

      ;; Test 3: Kernel create
      (let ((kernel (cl-agent.kernel:make-kernel)))
        (format t "Kernel Create: ~A~%" (if kernel "PASS" "FAIL")))

      ;; Test 4: Human loop manager
      (let ((hlm (cl-agent.process:make-human-loop-manager)))
        (format t "Human Loop: ~A~%" (if hlm "PASS" "FAIL")))

      ;; Test 5: Step framework
      (let ((step (cl-agent.process:make-step "test-step"
                    :handler (lambda (ctx input)
                               (declare (ignore ctx input))
                               (cl-agent.process:step-completed :output "done")))))
        (format t "Step Create: ~A~%" (if step "PASS" "FAIL")))

      (format t "~%ALL TESTS COMPLETED~%"))
  (error (e)
    (format t "ERROR: ~A~%" e)))
