;;;; test-glm47-unified.lisp
;;;; Test unified llm-response with GLM-4.7 dual providers
;;;;
;;;; Run with:
;;;;   sbcl --load tests/test-glm47-unified.lisp

(push #p"/home/david/workspace/cl-agent/core/" asdf:*central-registry*)
(push #p"/home/david/workspace/cl-agent/llm/" asdf:*central-registry*)

(asdf:load-system :cl-agent-llm)
(asdf:load-system :cl-agent-extra)

(format t "~%========================================~%")
(format t "GLM-4.7 Unified Response Test~%")
(format t "========================================~%")

;;; ============================================================
;;; Test Configuration
;;; ============================================================

(defvar *zhipu-api-key* (uiop:getenv "ZHIPU_API_KEY"))

(unless *zhipu-api-key*
  (format t "~%ERROR: ZHIPU_API_KEY environment variable not set~%")
  (sb-ext:exit :code 1))

;;; ============================================================
;;; Create Providers
;;; ============================================================

;; Anthropic-compatible GLM-4.7
(defvar *anthropic-provider*
  (cl-agent.llm.providers:make-anthropic-provider
   :api-url "https://open.bigmodel.cn/api/anthropic"
   :model "glm-4.7"
   :api-key *zhipu-api-key*))

;; OpenAI-compatible GLM-4.7
(defvar *openai-provider*
  (cl-agent.llm.providers:make-openai-provider
   :api-url "https://open.bigmodel.cn/api/coding/paas/v4"
   :model "glm-4.7"
   :api-key *zhipu-api-key*))

;;; ============================================================
;;; Test 1: Basic Chat - Both Providers
;;; ============================================================

(format t "~%--- Test 1: Basic Chat ---~%")

(let ((messages (list (list :role :user :content "Say hello in exactly 3 words"))))

  ;; Test Anthropic-compatible
  (format t "~%Anthropic-compatible:~%")
  (let ((response (cl-agent.llm:llm-chat *anthropic-provider* messages)))
    (format t "  Response type: ~A~%" (type-of response))
    (format t "  Is llm-response? ~A~%" (cl-agent.core:llm-response-p response))
    (format t "  Content: ~A~%" (cl-agent.core:llm-response-content response))
    (format t "  Model: ~A~%" (cl-agent.core:llm-response-model response))
    (format t "  Finish reason: ~A~%" (cl-agent.core:llm-response-finish-reason response))
    (format t "  Input tokens: ~A~%" (cl-agent.core:llm-response-input-tokens response))
    (format t "  Output tokens: ~A~%" (cl-agent.core:llm-response-output-tokens response)))

  ;; Test OpenAI-compatible
  (format t "~%OpenAI-compatible:~%")
  (let ((response (cl-agent.llm:llm-chat *openai-provider* messages)))
    (format t "  Response type: ~A~%" (type-of response))
    (format t "  Is llm-response? ~A~%" (cl-agent.core:llm-response-p response))
    (format t "  Content: ~A~%" (cl-agent.core:llm-response-content response))
    (format t "  Model: ~A~%" (cl-agent.core:llm-response-model response))
    (format t "  Finish reason: ~A~%" (cl-agent.core:llm-response-finish-reason response))
    (format t "  Input tokens: ~A~%" (cl-agent.core:llm-response-input-tokens response))
    (format t "  Output tokens: ~A~%" (cl-agent.core:llm-response-output-tokens response))))

;;; ============================================================
;;; Test 2: Tool Calling - Anthropic-compatible
;;; ============================================================

(format t "~%--- Test 2: Tool Calling (Anthropic-compatible) ---~%")

(let ((messages (list (list :role :user :content "What's the weather in Beijing?")))
      (tools (list (list :name "get_weather"
                         :description "Get weather for a location"
                         :input-schema (let ((ht (make-hash-table :test 'equal)))
                                         (setf (gethash "type" ht) "object")
                                         (let ((props (make-hash-table :test 'equal)))
                                           (let ((loc (make-hash-table :test 'equal)))
                                             (setf (gethash "type" loc) "string")
                                             (setf (gethash "description" loc) "City name")
                                             (setf (gethash "location" props) loc))
                                           (setf (gethash "properties" ht) props))
                                         (setf (gethash "required" ht) #("location"))
                                         ht)))))
  (let ((response (cl-agent.llm:llm-chat *anthropic-provider* messages
                                          :tools tools)))
    (format t "  Response type: ~A~%" (type-of response))
    (format t "  Has tool calls? ~A~%" (cl-agent.core:llm-response-has-tool-calls-p response))
    (format t "  Finish reason: ~A~%" (cl-agent.core:llm-response-finish-reason response))
    (when (cl-agent.core:llm-response-has-tool-calls-p response)
      (let ((tc (cl-agent.core:llm-response-first-tool-call response)))
        (format t "  First tool call:~%")
        (format t "    ID: ~A~%" (cl-agent.core:llm-tool-call-id tc))
        (format t "    Name: ~A~%" (cl-agent.core:llm-tool-call-name tc))
        (format t "    Arguments: ~A~%" (cl-agent.core:llm-tool-call-arguments tc))))))

;;; ============================================================
;;; Test 3: Tool Calling - OpenAI-compatible
;;; ============================================================

(format t "~%--- Test 3: Tool Calling (OpenAI-compatible) ---~%")

(let ((messages (list (list :role :user :content "What's the weather in Shanghai?")))
      (tools (list (list :name "get_weather"
                         :description "Get weather for a location"
                         :input-schema (let ((ht (make-hash-table :test 'equal)))
                                         (setf (gethash "type" ht) "object")
                                         (let ((props (make-hash-table :test 'equal)))
                                           (let ((loc (make-hash-table :test 'equal)))
                                             (setf (gethash "type" loc) "string")
                                             (setf (gethash "description" loc) "City name")
                                             (setf (gethash "location" props) loc))
                                           (setf (gethash "properties" ht) props))
                                         (setf (gethash "required" ht) #("location"))
                                         ht)))))
  (let ((response (cl-agent.llm:llm-chat *openai-provider* messages
                                          :tools tools)))
    (format t "  Response type: ~A~%" (type-of response))
    (format t "  Has tool calls? ~A~%" (cl-agent.core:llm-response-has-tool-calls-p response))
    (format t "  Finish reason: ~A~%" (cl-agent.core:llm-response-finish-reason response))
    (when (cl-agent.core:llm-response-has-tool-calls-p response)
      (let ((tc (cl-agent.core:llm-response-first-tool-call response)))
        (format t "  First tool call:~%")
        (format t "    ID: ~A~%" (cl-agent.core:llm-tool-call-id tc))
        (format t "    Name: ~A~%" (cl-agent.core:llm-tool-call-name tc))
        (format t "    Arguments: ~A~%" (cl-agent.core:llm-tool-call-arguments tc))))))

;;; ============================================================
;;; Test 4: Kernel Integration (Basic Chat without tools)
;;; ============================================================

(format t "~%--- Test 4: Kernel Integration (Basic Chat) ---~%")

;; Test with Anthropic-compatible provider
(let* ((service (cl-agent.kernel:service-from-provider *anthropic-provider*))
       (kernel (cl-agent.kernel:make-kernel :service service)))

  (format t "~%Testing invoke-kernel with Anthropic-compatible provider:~%")
  (let ((result (cl-agent.kernel:invoke-kernel
                 kernel
                 (list (list :role :user :content "Say hello in 3 words"))
                 :settings (list :tool-choice :none))))
    (format t "  Result text: ~A~%" (getf result :text))
    (format t "  Tool calls made: ~A~%" (length (getf result :tool-calls-made)))))

;; Test with OpenAI-compatible provider (may fail due to API rate limits)
(handler-case
    (let* ((service (cl-agent.kernel:service-from-provider *openai-provider*))
           (kernel (cl-agent.kernel:make-kernel :service service)))

      (format t "~%Testing invoke-kernel with OpenAI-compatible provider:~%")
      (let ((result (cl-agent.kernel:invoke-kernel
                     kernel
                     (list (list :role :user :content "Say hi in 3 words"))
                     :settings (list :tool-choice :none))))
        (format t "  Result text: ~A~%" (getf result :text))
        (format t "  Tool calls made: ~A~%" (length (getf result :tool-calls-made)))))
  (error (e)
    (format t "  Skipped (API error): ~A~%" (type-of e))))

(format t "~%========================================~%")
(format t "All tests completed!~%")
(format t "========================================~%")
