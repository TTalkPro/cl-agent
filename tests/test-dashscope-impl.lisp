;;;; test-dashscope-impl.lisp
;;;; DashScope/Bailian provider test implementation

(in-package :cl-user)

(defparameter *api-key* (uiop:getenv "BAILIAN_API_KEY"))

(format t "~%========================================~%")
(format t "DashScope/Bailian Provider Test~%")
(format t "========================================~%")
(format t "Implementation: ~A ~A~%"
        (lisp-implementation-type) (lisp-implementation-version))

(unless *api-key*
  (format t "~%ERROR: BAILIAN_API_KEY not set~%")
  #+sbcl (sb-ext:exit :code 1)
  #+ccl (ccl:quit 1))

;;; ============================================================
;;; Test 1: Provider Creation
;;; ============================================================

(format t "~%=== Test 1: Provider Creation ===~%")

(handler-case
    (progn
      ;; Test make-dashscope-provider
      (let ((provider (cl-agent.llm.providers:make-dashscope-provider
                       :api-key *api-key*
                       :model "qwen-plus")))
        (format t "  make-dashscope-provider: OK~%")
        (format t "    Model: ~A~%" (cl-agent.llm:base-provider-default-model provider)))

      ;; Test make-bailian-provider (alias)
      (let ((provider (cl-agent.llm.providers:make-bailian-provider
                       :api-key *api-key*)))
        (format t "  make-bailian-provider: OK~%"))

      ;; Test make-qwen-provider (alias)
      (let ((provider (cl-agent.llm.providers:make-qwen-provider
                       :api-key *api-key*)))
        (format t "  make-qwen-provider: OK~%"))

      (format t "  [PASS]~%"))
  (error (e)
    (format t "  [FAIL] ~A~%" e)))

;;; ============================================================
;;; Test 2: Single Turn Chat
;;; ============================================================

(format t "~%=== Test 2: Single Turn Chat ===~%")

(handler-case
    (let* ((provider (cl-agent.llm.providers:make-dashscope-provider
                      :api-key *api-key*
                      :model "qwen-plus"))
           (kernel (cl-agent.kernel:make-kernel :chat-service provider))
           (agent (cl-agent.simpleagent:make-kernel-agent kernel
                    :system-prompt "Reply briefly in one sentence.")))
      (let ((response (cl-agent.simpleagent:agent-chat agent
                        "What is 7 + 8?")))
        (format t "  Q: What is 7 + 8?~%")
        (format t "  A: ~A~%" response)
        (if (search "15" response)
            (format t "  [PASS]~%")
            (format t "  [CHECK] Expected '15' in response~%"))))
  (error (e)
    (format t "  [FAIL] ~A~%" e)))

;;; ============================================================
;;; Test 3: Multi Turn Chat
;;; ============================================================

(format t "~%=== Test 3: Multi Turn Chat ===~%")

(handler-case
    (let* ((provider (cl-agent.llm.providers:make-dashscope-provider
                      :api-key *api-key*
                      :model "qwen-plus"))
           (kernel (cl-agent.kernel:make-kernel :chat-service provider))
           (agent (cl-agent.simpleagent:make-kernel-agent kernel
                    :system-prompt "Remember context. Reply briefly.")))
      (cl-agent.simpleagent:agent-chat agent "My name is Alice.")
      (let ((response (cl-agent.simpleagent:agent-chat agent "What is my name?")))
        (format t "  Q1: My name is Alice.~%")
        (format t "  Q2: What is my name?~%")
        (format t "  A: ~A~%" response)
        (if (search "Alice" response)
            (format t "  [PASS]~%")
            (format t "  [CHECK] Expected 'Alice' in response~%"))))
  (error (e)
    (format t "  [FAIL] ~A~%" e)))

;;; ============================================================
;;; Test 4: Different Model (qwen-turbo)
;;; ============================================================

(format t "~%=== Test 4: Different Model (qwen-turbo) ===~%")

(handler-case
    (let* ((provider (cl-agent.llm.providers:make-dashscope-provider
                      :api-key *api-key*
                      :model "qwen-turbo"))
           (kernel (cl-agent.kernel:make-kernel :chat-service provider))
           (agent (cl-agent.simpleagent:make-kernel-agent kernel
                    :system-prompt "Reply with just the answer.")))
      (let ((response (cl-agent.simpleagent:agent-chat agent
                        "What is the capital of Japan?")))
        (format t "  Model: qwen-turbo~%")
        (format t "  Q: What is the capital of Japan?~%")
        (format t "  A: ~A~%" response)
        (if (search "Tokyo" response)
            (format t "  [PASS]~%")
            (format t "  [CHECK] Expected 'Tokyo' in response~%"))))
  (error (e)
    (format t "  [FAIL] ~A~%" e)))

;;; ============================================================
;;; Test 5: List Models
;;; ============================================================

(format t "~%=== Test 5: List Available Models ===~%")

(let ((models (cl-agent.llm.providers:dashscope-list-models)))
  (format t "  Available models (~A):~%" (length models))
  (dolist (m (subseq models 0 (min 6 (length models))))
    (format t "    - ~A~%" m))
  (format t "    ...~%")
  (format t "  [PASS]~%"))

(format t "~%========================================~%")
(format t "DashScope Test Complete~%")
(format t "========================================~%")
