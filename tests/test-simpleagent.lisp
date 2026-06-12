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

;;; ============================================================
;;; Callback Registry Tests（CLOS 回调机制）
;;; ============================================================

(test callback-registry-register-fire
  "测试回调注册与触发"
  (let ((registry (cl-agent.simpleagent:make-callback-registry))
        (received nil))
    (cl-agent.simpleagent:register-callback
     registry :on-test (lambda (x) (push x received)))
    (is (= 1 (cl-agent.simpleagent:callback-count registry :on-test)))
    (is (= 1 (cl-agent.simpleagent:fire-callbacks registry :on-test 42)))
    (is (equal '(42) received))))

(test callback-registry-priority-order
  "测试回调按优先级触发（越小越先）"
  (let ((registry (cl-agent.simpleagent:make-callback-registry))
        (order nil))
    (cl-agent.simpleagent:register-callback
     registry :ev (lambda () (push :late order)) :name :late :priority 200)
    (cl-agent.simpleagent:register-callback
     registry :ev (lambda () (push :early order)) :name :early :priority 10)
    (cl-agent.simpleagent:fire-callbacks registry :ev)
    (is (equal '(:early :late) (reverse order)))))

(test callback-registry-same-name-replaces
  "测试同名注册替换旧回调"
  (let ((registry (cl-agent.simpleagent:make-callback-registry))
        (hits nil))
    (cl-agent.simpleagent:register-callback
     registry :ev (lambda () (push :v1 hits)) :name :x)
    (cl-agent.simpleagent:register-callback
     registry :ev (lambda () (push :v2 hits)) :name :x)
    (is (= 1 (cl-agent.simpleagent:callback-count registry :ev)))
    (cl-agent.simpleagent:fire-callbacks registry :ev)
    (is (equal '(:v2) hits))))

(test callback-registry-unregister
  "测试注销回调"
  (let ((registry (cl-agent.simpleagent:make-callback-registry)))
    (cl-agent.simpleagent:register-callback
     registry :ev (lambda ()) :name :x)
    (is (cl-agent.simpleagent:unregister-callback registry :ev :x))
    (is (zerop (cl-agent.simpleagent:callback-count registry :ev)))
    (is (not (cl-agent.simpleagent:unregister-callback registry :ev :x)))))

(test callback-registry-error-isolation
  "测试错误隔离：单个回调出错不影响其他回调"
  (let ((registry (cl-agent.simpleagent:make-callback-registry))
        (survived nil))
    (cl-agent.simpleagent:register-callback
     registry :ev (lambda () (error "boom")) :name :bad :priority 1)
    (cl-agent.simpleagent:register-callback
     registry :ev (lambda () (setf survived t)) :name :good :priority 2)
    ;; 出错回调不计入 fired，但好回调仍触发
    (is (= 1 (cl-agent.simpleagent:fire-callbacks registry :ev)))
    (is (eq t survived))))

(test callback-registry-once
  "测试一次性回调：触发后自动注销"
  (let ((registry (cl-agent.simpleagent:make-callback-registry))
        (count 0))
    (cl-agent.simpleagent:register-callback
     registry :ev (lambda () (incf count)) :name :once :once t)
    (cl-agent.simpleagent:fire-callbacks registry :ev)
    (cl-agent.simpleagent:fire-callbacks registry :ev)
    (is (= 1 count))
    (is (zerop (cl-agent.simpleagent:callback-count registry :ev)))))

(test callback-registry-plist-compat
  "测试旧式 plist 回调的兼容转换"
  (let* ((hits nil)
         (registry (cl-agent.simpleagent:make-callback-registry
                    (list :on-message (lambda (msg) (push msg hits))))))
    (is (cl-agent.simpleagent:callback-registry-p registry))
    (cl-agent.simpleagent:fire-callbacks registry :on-message "hi")
    (is (equal '("hi") hits))))

(test agent-callback-events
  "测试 agent-chat 的完整事件流：message / tool-call / tool-result / response"
  (setup-chat-test-tools)
  (let* ((events nil)
         (mock (make-sequenced-mock
                (list :content ""
                      :tool-calls (list (list :id "c1"
                                              :name "test-chat-get-weather"
                                              :arguments '(:city "Tokyo"))))
                (list :content "Sunny day.")))
         (kernel (cl-agent.kernel:make-kernel
                  :service mock
                  :plugins '(test-chat-tools-plugin)))
         (agent (cl-agent.simpleagent:make-kernel-agent kernel :name "cb-agent")))
    (cl-agent.simpleagent:agent-on-message
     agent (lambda (msg) (declare (ignore msg)) (push :message events)))
    (cl-agent.simpleagent:agent-on-tool-call
     agent (lambda (name args) (declare (ignore name args)) (push :tool-call events)))
    (cl-agent.simpleagent:agent-on-tool-result
     agent (lambda (name result) (declare (ignore name result)) (push :tool-result events)))
    (cl-agent.simpleagent:agent-on-response
     agent (lambda (text) (declare (ignore text)) (push :response events)))
    (is (string= "Sunny day." (cl-agent.simpleagent:agent-chat agent "weather?")))
    (is (equal '(:message :tool-call :tool-result :response)
               (reverse events)))))

(test agent-callback-on-error
  "测试出错时触发 :on-error 且错误继续抛出"
  (let* ((caught nil)
         (kernel (cl-agent.kernel:make-kernel
                  :service (cl-agent.mock:make-mock-llm)))
         (agent (cl-agent.simpleagent:make-kernel-agent
                 kernel :name "err-agent"
                 :settings '(:max-attempts 0))))   ; 立即超限报错
    (cl-agent.simpleagent:agent-on-error
     agent (lambda (e) (declare (ignore e)) (setf caught t)))
    (signals error
      (cl-agent.simpleagent:agent-chat agent "hello"))
    (is (eq t caught))))
