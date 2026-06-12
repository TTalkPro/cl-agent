;;;; test-simpleagent.lisp
;;;; CL-Agent - SimpleAgent Module Tests (KernelAgent in core, ProcessAgent in extra)

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
                (cl-agent.kernel:make-kernel)
                :name "test-agent"
                :system-prompt "You are a test assistant.")))
    (is (not (null agent)))
    (is (string= "test-agent" (cl-agent.simpleagent:agent-name agent)))
    (is (string= "You are a test assistant."
                 (cl-agent.simpleagent:agent-system-prompt agent)))))

(test kernel-agent-with-kernel
  "Test KernelAgent with explicit kernel"
  (let* ((kernel (cl-agent.kernel:make-kernel))
         (agent (cl-agent.simpleagent:make-kernel-agent
                 kernel
                 :name "kernel-agent")))
    (is (not (null agent)))
    (is (eq kernel (cl-agent.simpleagent:agent-kernel agent)))))

(test kernel-agent-history
  "Test KernelAgent conversation history management"
  (let ((agent (cl-agent.simpleagent:make-kernel-agent
                (cl-agent.kernel:make-kernel)
                :name "history-test")))
    ;; Initially empty (no system prompt)
    (is (null (cl-agent.simpleagent:agent-history agent)))

    ;; Reset should work on empty
    (cl-agent.simpleagent:agent-reset agent)
    (is (null (cl-agent.simpleagent:agent-history agent)))))

;;; ============================================================
;;; ProcessAgent Tests (cl-agent-extra)
;;; ============================================================

(test process-agent-creation
  "Test ProcessAgent creation"
  (let ((agent (cl-agent.extra.agent:make-process-agent
                (cl-agent.kernel:make-kernel)
                :name "process-agent"
                :system-prompt "Process test")))
    (is (not (null agent)))
    (is (string= "process-agent" (cl-agent.simpleagent:agent-name agent)))))

(test process-agent-state
  "Test ProcessAgent state management"
  (let ((agent (cl-agent.extra.agent:make-process-agent
                (cl-agent.kernel:make-kernel)
                :name "state-test")))
    ;; Initial state
    (is (eq :stopped (cl-agent.extra.agent:agent-state agent)))
    (is (not (cl-agent.extra.agent:agent-running-p agent)))
    (is (not (cl-agent.extra.agent:agent-paused-p agent)))
    (is (cl-agent.extra.agent:agent-stopped-p agent))))

(test process-agent-pause-resume
  "Test ProcessAgent pause/resume functionality"
  (let ((agent (cl-agent.extra.agent:make-process-agent
                (cl-agent.kernel:make-kernel)
                :name "pause-test")))
    (cl-agent.extra.agent:agent-start agent)
    (unwind-protect
        (progn
          (is (cl-agent.extra.agent:agent-running-p agent))

          ;; Pause
          (cl-agent.extra.agent:agent-pause agent)
          (is (cl-agent.extra.agent:agent-paused-p agent))

          ;; Resume
          (cl-agent.extra.agent:agent-resume agent)
          (is (not (cl-agent.extra.agent:agent-paused-p agent)))
          (is (cl-agent.extra.agent:agent-running-p agent)))
      (cl-agent.extra.agent:agent-stop agent))
    (is (cl-agent.extra.agent:agent-stopped-p agent))))

;;; ============================================================
;;; Agent Protocol Tests
;;; ============================================================

(test agent-protocol-interface
  "Test common agent protocol interface"
  (let ((agent (cl-agent.simpleagent:make-kernel-agent
                (cl-agent.kernel:make-kernel)
                :name "protocol-test")))
    ;; Agent predicate and identity
    (is (cl-agent.simpleagent:agent-p agent))
    (is (stringp (cl-agent.simpleagent:agent-id agent)))

    ;; Name accessor
    (is (stringp (cl-agent.simpleagent:agent-name agent)))

    ;; History accessor
    (is (listp (cl-agent.simpleagent:agent-history agent)))

    ;; Reset method
    (cl-agent.simpleagent:agent-reset agent)
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
