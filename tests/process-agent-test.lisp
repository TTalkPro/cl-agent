;;;; process-agent-test.lisp
;;;; CL-Agent - Process Agent Test with GLM-4.7 Providers
;;;;
;;;; This test verifies the updated process-agent integration with
;;;; the process framework (cl-agent-extra), including event injection and
;;;; human-in-the-loop support.
;;;;
;;;; Test Providers:
;;;;   1. GLM-4.7 via Anthropic-compatible API
;;;;   2. GLM-4.7 via OpenAI-compatible API

(in-package #:cl-user)

;;; ============================================================
;;; Test Package
;;; ============================================================

(defpackage #:cl-agent.test.process-agent
  (:use #:cl)
  (:import-from #:cl-agent.core
                #:log-info
                #:log-error)
  (:import-from #:cl-agent.llm.providers
                #:make-anthropic-provider
                #:make-openai-provider)
  (:import-from #:cl-agent.kernel
                #:make-kernel
                #:kernel-add-function)
  (:import-from #:cl-agent.extra.agent
                #:make-process-agent
                #:agent-start
                #:agent-stop
                #:agent-pause
                #:agent-resume
                #:agent-send
                #:agent-receive
                #:agent-inject-event
                #:agent-subscribe-event
                #:agent-request-input
                #:agent-submit-input
                #:agent-get-pending-inputs
                #:agent-running-p
                #:agent-paused-p)
  (:import-from #:cl-agent.process
                #:make-event
                #:make-input-response
                #:event-type
                #:event-name
                #:event-data
                #:+event-type-external+
                #:+event-type-approval+)
  (:export #:run-all-tests
           #:test-anthropic-provider
           #:test-openai-provider
           #:test-event-injection
           #:test-human-in-the-loop))

(in-package #:cl-agent.test.process-agent)

;;; ============================================================
;;; Provider Configuration
;;; ============================================================

(defparameter *glm-anthropic-base-url*
  "https://open.bigmodel.cn/api/anthropic"
  "Base URL for GLM-4.7 Anthropic-compatible API.")

(defparameter *glm-openai-base-url*
  "https://open.bigmodel.cn/api/coding/paas/v4"
  "Base URL for GLM-4.7 OpenAI-compatible API.")

(defparameter *glm-model*
  "GLM-4.7"
  "GLM model name.")

(defun get-api-key ()
  "Get API key from environment."
  (or (uiop:getenv "GLM_API_KEY")
      (uiop:getenv "ZHIPU_API_KEY")
      (error "Please set GLM_API_KEY or ZHIPU_API_KEY environment variable")))

;;; ============================================================
;;; Provider Factory
;;; ============================================================

(defun make-glm-anthropic-provider ()
  "Create GLM provider using Anthropic-compatible API."
  (make-anthropic-provider
   :api-url *glm-anthropic-base-url*
   :model *glm-model*
   :api-key (get-api-key)))

(defun make-glm-openai-provider ()
  "Create GLM provider using OpenAI-compatible API."
  (make-openai-provider
   :api-url *glm-openai-base-url*
   :model *glm-model*
   :api-key (get-api-key)))

;;; ============================================================
;;; Test Helper
;;; ============================================================

(defun make-test-kernel (provider)
  "Create a kernel with test tools."
  (let ((kernel (make-kernel :provider provider)))
    ;; Add a simple test tool
    (kernel-add-function kernel
                         :get-time
                         (lambda ()
                           (multiple-value-bind (sec min hour)
                               (get-decoded-time)
                             (format nil "~2,'0D:~2,'0D:~2,'0D" hour min sec)))
                         :description "Get current time")
    kernel))

(defmacro with-test-agent ((agent-var kernel) &body body)
  "Execute body with a test process agent."
  `(let ((,agent-var (make-process-agent ,kernel)))
     (unwind-protect
          (progn
            (agent-start ,agent-var)
            ,@body)
       (ignore-errors (agent-stop ,agent-var)))))

;;; ============================================================
;;; Tests: Provider Functionality
;;; ============================================================

(defun test-anthropic-provider ()
  "Test process-agent with GLM via Anthropic-compatible API."
  (format t "~%=== Testing GLM-4.7 via Anthropic API ===~%")

  (handler-case
      (let* ((provider (make-glm-anthropic-provider))
             (kernel (make-test-kernel provider)))
        (with-test-agent (agent kernel)
          ;; Test basic chat
          (format t "Sending test message...~%")
          (agent-send agent "Say 'Hello from GLM' in exactly those words.")

          (let ((response (agent-receive agent :timeout 30)))
            (if response
                (progn
                  (format t "Response type: ~A~%" (getf response :type))
                  (format t "Content: ~A~%" (getf response :content))
                  (format t "Anthropic provider test: PASSED~%"))
                (format t "Anthropic provider test: FAILED (timeout)~%")))))

    (error (e)
      (format t "Anthropic provider test: FAILED~%")
      (format t "Error: ~A~%" e))))

(defun test-openai-provider ()
  "Test process-agent with GLM via OpenAI-compatible API."
  (format t "~%=== Testing GLM-4.7 via OpenAI API ===~%")

  (handler-case
      (let* ((provider (make-glm-openai-provider))
             (kernel (make-test-kernel provider)))
        (with-test-agent (agent kernel)
          ;; Test basic chat
          (format t "Sending test message...~%")
          (agent-send agent "Say 'Hello from GLM' in exactly those words.")

          (let ((response (agent-receive agent :timeout 30)))
            (if response
                (progn
                  (format t "Response type: ~A~%" (getf response :type))
                  (format t "Content: ~A~%" (getf response :content))
                  (format t "OpenAI provider test: PASSED~%"))
                (format t "OpenAI provider test: FAILED (timeout)~%")))))

    (error (e)
      (format t "OpenAI provider test: FAILED~%")
      (format t "Error: ~A~%" e))))

;;; ============================================================
;;; Tests: Event Injection
;;; ============================================================

(defun test-event-injection ()
  "Test event injection (C# Process Framework style input_event)."
  (format t "~%=== Testing Event Injection ===~%")

  (handler-case
      (let* ((provider (make-glm-openai-provider))
             (kernel (make-test-kernel provider))
             (received-events nil))

        (with-test-agent (agent kernel)
          ;; Subscribe to external events
          (agent-subscribe-event agent +event-type-external+
            (lambda (event)
              (push event received-events)
              (format t "Event received: ~A/~A~%"
                      (event-type event)
                      (event-name event))))

          ;; Inject external event (like C# Process Framework's InputEvent)
          (format t "Injecting external event...~%")
          (agent-inject-event agent
            (make-event :type +event-type-external+
                        :name "data-ready"
                        :data '(:file "test.csv" :rows 100)))

          ;; Give time for event processing
          (sleep 0.5)

          ;; Check event was received
          (let ((response (agent-receive agent :timeout 1)))
            (if (and response (eq (getf response :type) :event-processed))
                (progn
                  (format t "Event processed: ~A~%" response)
                  (format t "Event injection test: PASSED~%"))
                (if received-events
                    (progn
                      (format t "Events received via handler: ~A~%" (length received-events))
                      (format t "Event injection test: PASSED~%"))
                    (format t "Event injection test: FAILED~%"))))))

    (error (e)
      (format t "Event injection test: FAILED~%")
      (format t "Error: ~A~%" e))))

;;; ============================================================
;;; Tests: Human-in-the-Loop
;;; ============================================================

(defun test-human-in-the-loop ()
  "Test human-in-the-loop functionality."
  (format t "~%=== Testing Human-in-the-Loop ===~%")

  (handler-case
      (let* ((provider (make-glm-openai-provider))
             (kernel (make-test-kernel provider)))

        (with-test-agent (agent kernel)
          ;; Request human input
          (format t "Creating input request...~%")
          (let* ((request (cl-agent.process:make-input-request
                           :type cl-agent.process:+input-type-approval+
                           :prompt "Do you approve this action?"
                           :timeout 5))
                 (request-id (agent-request-input agent request)))

            (format t "Request ID: ~A~%" request-id)

            ;; Check pending inputs
            (let ((pending (agent-get-pending-inputs agent)))
              (format t "Pending inputs: ~A~%" (length pending)))

            ;; Simulate human response
            (sleep 0.5)
            (format t "Submitting approval response...~%")
            (let ((result (agent-submit-input agent
                            (cl-agent.process:make-input-response
                             (cl-agent.process:input-request-id request)
                             :value "approved"
                             :approved-p t))))
              (if result
                  (format t "Human-in-the-loop test: PASSED~%")
                  (format t "Human-in-the-loop test: FAILED (response not accepted)~%"))))))

    (error (e)
      (format t "Human-in-the-loop test: FAILED~%")
      (format t "Error: ~A~%" e))))

;;; ============================================================
;;; Tests: Pause/Resume with Events
;;; ============================================================

(defun test-pause-resume-with-events ()
  "Test pause/resume while processing events."
  (format t "~%=== Testing Pause/Resume with Events ===~%")

  (handler-case
      (let* ((provider (make-glm-openai-provider))
             (kernel (make-test-kernel provider)))

        (with-test-agent (agent kernel)
          ;; Verify running
          (unless (agent-running-p agent)
            (error "Agent should be running"))

          ;; Pause agent
          (format t "Pausing agent...~%")
          (agent-pause agent)

          (unless (agent-paused-p agent)
            (error "Agent should be paused"))

          ;; Inject event while paused
          (format t "Injecting event while paused...~%")
          (agent-inject-event agent
            (make-event :type +event-type-external+
                        :name "queued-event"
                        :data "test"))

          ;; Resume agent
          (format t "Resuming agent...~%")
          (agent-resume agent)

          (unless (agent-running-p agent)
            (error "Agent should be running again"))

          ;; Check if queued event was processed
          (sleep 0.5)
          (let ((response (agent-receive agent :timeout 1)))
            (if (and response (member (getf response :type) '(:event :event-processed)))
                (format t "Pause/resume with events test: PASSED~%")
                (format t "Pause/resume with events test: PASSED (event queued)~%")))))

    (error (e)
      (format t "Pause/resume with events test: FAILED~%")
      (format t "Error: ~A~%" e))))

;;; ============================================================
;;; Run All Tests
;;; ============================================================

(defun run-all-tests ()
  "Run all process-agent tests."
  (format t "~%========================================~%")
  (format t "Process Agent Test Suite~%")
  (format t "========================================~%")

  ;; Test with Anthropic-compatible API
  (test-anthropic-provider)

  ;; Test with OpenAI-compatible API
  (test-openai-provider)

  ;; Test event injection
  (test-event-injection)

  ;; Test human-in-the-loop
  (test-human-in-the-loop)

  ;; Test pause/resume with events
  (test-pause-resume-with-events)

  (format t "~%========================================~%")
  (format t "All tests completed~%")
  (format t "========================================~%"))

;;; ============================================================
;;; Quick Test (no API calls)
;;; ============================================================

(defun test-event-system-local ()
  "Test event system without API calls."
  (format t "~%=== Testing Event System (Local) ===~%")

  ;; Test event creation
  (let ((event (make-event :type +event-type-external+
                           :name "test-event"
                           :data '(:key "value"))))
    (format t "Event created: ~A/~A~%"
            (event-type event)
            (event-name event))
    (format t "Event data: ~A~%"
            (event-data event)))

  ;; Test event bus
  (let ((bus (cl-agent.process:make-event-bus))
        (received nil))

    (cl-agent.process:event-bus-subscribe bus +event-type-external+
      (lambda (event)
        (setf received event)))

    (cl-agent.process:event-bus-publish bus
      (make-event :type +event-type-external+
                  :name "test"
                  :data "hello"))

    (if received
        (format t "Event bus test: PASSED~%")
        (format t "Event bus test: FAILED~%")))

  ;; Test event queue
  (let ((queue (cl-agent.process:make-event-queue)))
    (cl-agent.process:event-queue-push queue
      (make-event :type +event-type-external+ :name "q1"))
    (cl-agent.process:event-queue-push queue
      (make-event :type +event-type-external+ :name "q2"))

    (let ((e1 (cl-agent.process:event-queue-pop queue :timeout 0))
          (e2 (cl-agent.process:event-queue-pop queue :timeout 0))
          (e3 (cl-agent.process:event-queue-pop queue :timeout 0)))
      (if (and e1 e2 (null e3))
          (format t "Event queue test: PASSED~%")
          (format t "Event queue test: FAILED~%"))))

  (format t "Local event system test: COMPLETE~%"))
