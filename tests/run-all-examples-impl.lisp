;;;; run-all-examples-impl.lisp
;;;; Run all examples with GLM-4.7

(in-package :cl-user)

(defparameter *api-key* (uiop:getenv "ZHIPU_API_KEY"))
(defparameter *test-results* nil)

(defun record-result (name status &optional error-msg)
  (push (list :name name :status status :error error-msg) *test-results*))

(defmacro with-test ((name) &body body)
  `(handler-case
       (progn
         (format t "~%--- ~A ---~%" ,name)
         ,@body
         (format t "  [PASS]~%")
         (record-result ,name :pass))
     (error (e)
       (format t "  [FAIL] ~A~%" e)
       (record-result ,name :fail (format nil "~A" e)))))

(format t "~%")
(format t "================================================================~%")
(format t "  CL-Agent Examples Test Suite~%")
(format t "  GLM-4.7 Providers~%")
(format t "================================================================~%")
(format t "~%Implementation: ~A ~A~%"
        (lisp-implementation-type) (lisp-implementation-version))

(unless *api-key*
  (format t "~%ERROR: ZHIPU_API_KEY not set~%")
  #+sbcl (sb-ext:exit :code 1)
  #+ccl (ccl:quit 1))

;;; ============================================================
;;; Create Providers
;;; ============================================================

(format t "~%=== Creating Providers ===~%")

(defparameter *anthropic-provider*
  (cl-agent.llm.providers:make-anthropic-provider
   :api-url "https://open.bigmodel.cn/api/anthropic"
   :api-key *api-key*
   :model "glm-4.7"))
(format t "  Anthropic Provider: OK~%")

(defparameter *openai-provider*
  (cl-agent.llm.providers:make-openai-provider
   :api-url "https://open.bigmodel.cn/api/coding/paas/v4"
   :api-key *api-key*
   :model "glm-4.7"))
(format t "  OpenAI Provider: OK~%")

;;; ============================================================
;;; Part 1: Process Framework Examples
;;; ============================================================

(format t "~%~%================================================================~%")
(format t "  PART 1: Process Framework Examples~%")
(format t "================================================================~%")

(with-test ("Event Bus")
  (let* ((bus (cl-agent.process:make-event-bus))
         (received nil))
    (cl-agent.process:event-bus-subscribe bus :test
      (lambda (e) (setf received (cl-agent.process:event-name e))))
    (cl-agent.process:event-bus-publish bus
      (cl-agent.process:make-event :type :test :name "ping" :data "hello"))
    (assert received () "Event not received")))

(with-test ("Event Queue")
  (let ((queue (cl-agent.process:make-event-queue)))
    (cl-agent.process:event-queue-push queue
      (cl-agent.process:make-event :type :test :name "e1"))
    (cl-agent.process:event-queue-push queue
      (cl-agent.process:make-event :type :test :name "e2"))
    (let ((e1 (cl-agent.process:event-queue-pop queue :timeout 0))
          (e2 (cl-agent.process:event-queue-pop queue :timeout 0)))
      (assert (and e1 e2) () "Events not popped"))))

(with-test ("State Machine")
  (let ((sm (cl-agent.process:state-machine-builder)))
    (cl-agent.process:with-state sm :idle :initial t)
    (cl-agent.process:with-state sm :running)
    (cl-agent.process:with-state sm :done)
    (cl-agent.process:with-transition-rule sm :idle :running :on :start)
    (cl-agent.process:with-transition-rule sm :running :done :on :finish)
    (assert (eq (cl-agent.process:state-machine-current-state sm) :idle))
    (cl-agent.process:state-machine-trigger sm :start)
    (assert (eq (cl-agent.process:state-machine-current-state sm) :running))
    (cl-agent.process:state-machine-trigger sm :finish)
    (assert (eq (cl-agent.process:state-machine-current-state sm) :done))))

(with-test ("Step Definition")
  (let ((step (cl-agent.process:make-step "test-step"
                :description "A test step"
                :handler (lambda (ctx input)
                           (declare (ignore ctx))
                           (cl-agent.process:step-completed
                            :output (list :processed input))))))
    (assert (string= (cl-agent.process:step-name step) "test-step"))))

(with-test ("Human Loop Manager")
  (let ((hlm (cl-agent.process:make-human-loop-manager)))
    (assert hlm () "Human loop manager not created")))

(with-test ("Event Matching")
  (let ((e1 (cl-agent.process:make-event :type :external :name "data-ready"))
        (e2 (cl-agent.process:make-event :type :approval :name "review")))
    (assert (cl-agent.process:event-matches-p e1 :external))
    (assert (not (cl-agent.process:event-matches-p e2 :external)))))

;;; ============================================================
;;; Part 2: Kernel Framework Examples
;;; ============================================================

(format t "~%~%================================================================~%")
(format t "  PART 2: Kernel Framework Examples~%")
(format t "================================================================~%")

(with-test ("Kernel Creation")
  (let ((kernel (cl-agent.kernel:make-kernel :service *anthropic-provider*)))
    (assert kernel () "Kernel not created")))

(with-test ("Kernel Context")
  (let ((ctx (cl-agent.kernel:make-context)))
    (cl-agent.kernel:context-set ctx :user "Alice")
    (assert (string= (cl-agent.kernel:context-get ctx :user) "Alice"))))

;;; ============================================================
;;; Part 3: SimpleAgent Examples (Anthropic Provider)
;;; ============================================================

(format t "~%~%================================================================~%")
(format t "  PART 3: SimpleAgent Examples (Anthropic Provider)~%")
(format t "================================================================~%")

(with-test ("Kernel Agent Creation (Anthropic)")
  (let* ((kernel (cl-agent.kernel:make-kernel :service *anthropic-provider*))
         (agent (cl-agent.simpleagent:make-kernel-agent kernel
                  :name "test-agent"
                  :system-prompt "You are helpful.")))
    (assert agent () "Agent not created")))

(with-test ("Single Turn Chat (Anthropic)")
  (let* ((kernel (cl-agent.kernel:make-kernel :service *anthropic-provider*))
         (agent (cl-agent.simpleagent:make-kernel-agent kernel
                  :system-prompt "Reply briefly.")))
    (let ((response (cl-agent.simpleagent:agent-chat agent "Say hello")))
      (format t "    Response: ~A~%" (subseq response 0 (min 50 (length response))))
      (assert (> (length response) 0)))))

(with-test ("Multi Turn Chat (Anthropic)")
  (let* ((kernel (cl-agent.kernel:make-kernel :service *anthropic-provider*))
         (agent (cl-agent.simpleagent:make-kernel-agent kernel
                  :system-prompt "Remember context.")))
    (cl-agent.simpleagent:agent-chat agent "My favorite color is blue.")
    (let ((response (cl-agent.simpleagent:agent-chat agent "What color did I say?")))
      (format t "    Response: ~A~%" response)
      (assert (search "blue" (string-downcase response))))))

(with-test ("Agent History (Anthropic)")
  (let* ((kernel (cl-agent.kernel:make-kernel :service *anthropic-provider*))
         (agent (cl-agent.simpleagent:make-kernel-agent kernel)))
    (cl-agent.simpleagent:agent-chat agent "Test message")
    (let ((history (cl-agent.simpleagent:agent-get-history agent)))
      (assert (>= (length history) 2)))))

(with-test ("Agent Reset (Anthropic)")
  (let* ((kernel (cl-agent.kernel:make-kernel :service *anthropic-provider*))
         (agent (cl-agent.simpleagent:make-kernel-agent kernel
                  :system-prompt "System prompt")))
    (cl-agent.simpleagent:agent-chat agent "Message 1")
    (cl-agent.simpleagent:agent-reset agent :keep-system-prompt t)
    (let ((history (cl-agent.simpleagent:agent-get-history agent :include-system t)))
      (assert (= (length history) 1)))))

;;; ============================================================
;;; Part 4: SimpleAgent Examples (OpenAI Provider)
;;; ============================================================

(format t "~%~%================================================================~%")
(format t "  PART 4: SimpleAgent Examples (OpenAI Provider)~%")
(format t "================================================================~%")

(with-test ("Single Turn Chat (OpenAI)")
  (let* ((kernel (cl-agent.kernel:make-kernel :service *openai-provider*))
         (agent (cl-agent.simpleagent:make-kernel-agent kernel
                  :system-prompt "Reply briefly.")))
    (let ((response (cl-agent.simpleagent:agent-chat agent "What is 5+5?")))
      (format t "    Response: ~A~%" response)
      (assert (search "10" response)))))

(with-test ("Multi Turn Chat (OpenAI)")
  (let* ((kernel (cl-agent.kernel:make-kernel :service *openai-provider*))
         (agent (cl-agent.simpleagent:make-kernel-agent kernel
                  :system-prompt "Remember context.")))
    (cl-agent.simpleagent:agent-chat agent "I am learning Lisp.")
    (let ((response (cl-agent.simpleagent:agent-chat agent "What am I learning?")))
      (format t "    Response: ~A~%" response)
      (assert (or (search "Lisp" response) (search "lisp" response))))))

;;; ============================================================
;;; Part 5: Process Agent Examples
;;; ============================================================

(format t "~%~%================================================================~%")
(format t "  PART 5: Process Agent Examples~%")
(format t "================================================================~%")

(with-test ("Process Agent Creation")
  (let* ((kernel (cl-agent.kernel:make-kernel :service *anthropic-provider*))
         (agent (cl-agent.simpleagent:make-process-agent kernel
                  :name "process-test")))
    (assert agent () "Process agent not created")))

(with-test ("Event Bus Integration")
  (let ((bus (cl-agent.simpleagent:agent-event-bus
               (cl-agent.simpleagent:make-process-agent
                 (cl-agent.kernel:make-kernel :service *anthropic-provider*)))))
    (assert bus () "Event bus not created")))

(with-test ("Event Queue Integration")
  (let ((queue (cl-agent.simpleagent:agent-event-queue
                 (cl-agent.simpleagent:make-process-agent
                   (cl-agent.kernel:make-kernel :service *anthropic-provider*)))))
    (assert queue () "Event queue not created")))

;;; ============================================================
;;; Summary
;;; ============================================================

(format t "~%~%================================================================~%")
(format t "  TEST SUMMARY~%")
(format t "================================================================~%")

(let ((passed (count :pass *test-results* :key (lambda (r) (getf r :status))))
      (failed (count :fail *test-results* :key (lambda (r) (getf r :status))))
      (total (length *test-results*)))
  (format t "~%Total: ~A  Passed: ~A  Failed: ~A~%~%" total passed failed)

  (when (> failed 0)
    (format t "Failed tests:~%")
    (dolist (r (reverse *test-results*))
      (when (eq (getf r :status) :fail)
        (format t "  - ~A: ~A~%" (getf r :name) (getf r :error)))))

  (format t "~%================================================================~%")
  (if (= failed 0)
      (format t "  ALL TESTS PASSED!~%")
      (format t "  SOME TESTS FAILED~%"))
  (format t "================================================================~%"))
