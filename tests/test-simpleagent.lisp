;;;; test-simpleagent.lisp
;;;; CL-Agent - SimpleAgent Module Tests

(in-package :cl-agent/tests)

(def-suite simpleagent-suite
  :description "SimpleAgent module test suite"
  :in cl-agent-suite)

(in-suite simpleagent-suite)

;;; ============================================================
;;; KernelAgent Tests
;;; ============================================================

(test kernel-agent-creation
  "Test KernelAgent creation"
  (let ((agent (cl-agent.simpleagent:make-kernel-agent
                :name "test-agent"
                :system-prompt "You are a test assistant.")))
    (is (not (null agent)))
    (is (string= "test-agent" (cl-agent.simpleagent:agent-name agent)))
    (is (string= "You are a test assistant."
                 (cl-agent.simpleagent:agent-system-prompt agent)))))

(test kernel-agent-with-kernel
  "Test KernelAgent with explicit kernel"
  (let* ((kernel (cl-agent.core:make-kernel))
         (agent (cl-agent.simpleagent:make-kernel-agent
                 :kernel kernel
                 :name "kernel-agent")))
    (is (not (null agent)))
    (is (eq kernel (cl-agent.simpleagent:agent-kernel agent)))))

(test kernel-agent-history
  "Test KernelAgent conversation history management"
  (let ((agent (cl-agent.simpleagent:make-kernel-agent :name "history-test")))
    ;; Initially empty
    (is (null (cl-agent.simpleagent:agent-history agent)))

    ;; Clear history should work on empty
    (cl-agent.simpleagent:agent-clear-history agent)
    (is (null (cl-agent.simpleagent:agent-history agent)))))

;;; ============================================================
;;; ProcessAgent Tests
;;; ============================================================

(test process-agent-creation
  "Test ProcessAgent creation"
  (let ((agent (cl-agent.simpleagent:make-process-agent
                :name "process-agent"
                :system-prompt "Process test")))
    (is (not (null agent)))
    (is (string= "process-agent" (cl-agent.simpleagent:agent-name agent)))))

(test process-agent-state
  "Test ProcessAgent state management"
  (let ((agent (cl-agent.simpleagent:make-process-agent :name "state-test")))
    ;; Initial state
    (is (eq :idle (cl-agent.simpleagent:process-agent-state agent)))

    ;; State transitions
    (setf (cl-agent.simpleagent:process-agent-state agent) :running)
    (is (eq :running (cl-agent.simpleagent:process-agent-state agent)))

    (setf (cl-agent.simpleagent:process-agent-state agent) :paused)
    (is (eq :paused (cl-agent.simpleagent:process-agent-state agent)))))

(test process-agent-pause-resume
  "Test ProcessAgent pause/resume functionality"
  (let ((agent (cl-agent.simpleagent:make-process-agent :name "pause-test")))
    ;; Pause
    (cl-agent.simpleagent:process-agent-pause agent)
    (is (cl-agent.simpleagent:process-agent-paused-p agent))

    ;; Resume
    (cl-agent.simpleagent:process-agent-resume agent)
    (is (not (cl-agent.simpleagent:process-agent-paused-p agent)))))

;;; ============================================================
;;; Agent Protocol Tests
;;; ============================================================

(test agent-protocol-interface
  "Test common agent protocol interface"
  (let ((agent (cl-agent.simpleagent:make-kernel-agent :name "protocol-test")))
    ;; Name accessor
    (is (stringp (cl-agent.simpleagent:agent-name agent)))

    ;; History accessor
    (is (listp (cl-agent.simpleagent:agent-history agent)))

    ;; Clear history method
    (cl-agent.simpleagent:agent-clear-history agent)
    (is (null (cl-agent.simpleagent:agent-history agent)))))

;;; ============================================================
;;; Message Handling Tests
;;; ============================================================

(test agent-message-creation
  "Test creating messages for agent"
  (let* ((user-msg (cl-agent.core:user-message "Hello"))
         (system-msg (cl-agent.core:system-message "You are helpful")))
    (is (eq :user (cl-agent.core:message-role user-msg)))
    (is (eq :system (cl-agent.core:message-role system-msg)))
    (is (string= "Hello" (cl-agent.core:message-content user-msg)))))

