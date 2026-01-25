;;;; glm47-dual-provider-test-impl.lisp
;;;; GLM-4.7 dual provider test implementation

(in-package :cl-user)

(defparameter *api-key* (uiop:getenv "ZHIPU_API_KEY"))

(format t "~%========================================~%")
(format t "GLM-4.7 Dual Provider Test~%")
(format t "========================================~%")
(format t "Implementation: ~A ~A~%"
        (lisp-implementation-type) (lisp-implementation-version))

(unless *api-key*
  (format t "~%ERROR: ZHIPU_API_KEY not set~%")
  #+sbcl (sb-ext:exit :code 1)
  #+ccl (ccl:quit 1))

;;; ============================================================
;;; Test 1: Anthropic-compatible Provider
;;; ============================================================

(format t "~%=== Test 1: Anthropic-compatible Provider ===~%")
(format t "URL: https://open.bigmodel.cn/api/anthropic~%")
(format t "Model: glm-4.7~%~%")

(handler-case
    (let* ((provider (cl-agent.llm.providers:make-anthropic-provider
                      :api-url "https://open.bigmodel.cn/api/anthropic"
                      :api-key *api-key*
                      :model "glm-4.7"))
           (kernel (cl-agent.kernel:make-kernel :chat-service provider))
           (agent (cl-agent.simpleagent:make-kernel-agent kernel
                    :system-prompt "You are a helpful assistant. Keep responses brief.")))

      ;; Single turn test
      (format t "Single turn test:~%")
      (let ((response (cl-agent.simpleagent:agent-chat agent
                        "What is 2+2? Reply with just the number.")))
        (format t "  Q: What is 2+2?~%")
        (format t "  A: ~A~%" response)
        (format t "  Result: ~A~%~%" (if (search "4" response) "PASS" "FAIL")))

      ;; Multi turn test
      (format t "Multi turn test:~%")
      (cl-agent.simpleagent:agent-reset agent :keep-system-prompt t)
      (cl-agent.simpleagent:agent-chat agent "My name is David.")
      (let ((response (cl-agent.simpleagent:agent-chat agent "What is my name?")))
        (format t "  Q1: My name is David.~%")
        (format t "  Q2: What is my name?~%")
        (format t "  A: ~A~%" response)
        (format t "  Result: ~A~%~%" (if (search "David" response) "PASS" "FAIL")))

      (format t "[Anthropic Provider] COMPLETED~%"))

  (error (e)
    (format t "[Anthropic Provider] ERROR: ~A~%~%" e)))

;;; ============================================================
;;; Test 2: OpenAI-compatible Provider
;;; ============================================================

(format t "~%=== Test 2: OpenAI-compatible Provider ===~%")
(format t "URL: https://open.bigmodel.cn/api/coding/paas/v4~%")
(format t "Model: glm-4.7~%~%")

(handler-case
    (let* ((provider (cl-agent.llm.providers:make-openai-provider
                      :api-url "https://open.bigmodel.cn/api/coding/paas/v4"
                      :api-key *api-key*
                      :model "glm-4.7"))
           (kernel (cl-agent.kernel:make-kernel :chat-service provider))
           (agent (cl-agent.simpleagent:make-kernel-agent kernel
                    :system-prompt "You are a helpful assistant. Keep responses brief.")))

      ;; Single turn test
      (format t "Single turn test:~%")
      (let ((response (cl-agent.simpleagent:agent-chat agent
                        "What is 3+3? Reply with just the number.")))
        (format t "  Q: What is 3+3?~%")
        (format t "  A: ~A~%" response)
        (format t "  Result: ~A~%~%" (if (search "6" response) "PASS" "FAIL")))

      ;; Multi turn test
      (format t "Multi turn test:~%")
      (cl-agent.simpleagent:agent-reset agent :keep-system-prompt t)
      (cl-agent.simpleagent:agent-chat agent "I like programming in Common Lisp.")
      (let ((response (cl-agent.simpleagent:agent-chat agent
                        "What programming language did I mention?")))
        (format t "  Q1: I like programming in Common Lisp.~%")
        (format t "  Q2: What programming language did I mention?~%")
        (format t "  A: ~A~%" response)
        (format t "  Result: ~A~%~%" (if (or (search "Lisp" response)
                                             (search "lisp" response))
                                        "PASS" "FAIL")))

      (format t "[OpenAI Provider] COMPLETED~%"))

  (error (e)
    (format t "[OpenAI Provider] ERROR: ~A~%~%" e)))

(format t "~%========================================~%")
(format t "All Tests Completed~%")
(format t "========================================~%")
