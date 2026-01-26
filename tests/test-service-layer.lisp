;;;; test-service-layer.lisp
;;;; Test the Service Layer response normalization

(format t "~%=== Testing Service Layer ===~%")

;; Test 1: normalize-usage function
(format t "~%Test 1: normalize-usage~%")
(let ((usage-plist '(:prompt-tokens 100 :completion-tokens 50))
      (usage-hash (make-hash-table :test 'equal)))
  (setf (gethash "prompt_tokens" usage-hash) 200)
  (setf (gethash "completion_tokens" usage-hash) 75)

  ;; Test plist input
  (let ((result (cl-agent.llm:normalize-usage usage-plist :openai)))
    (format t "  Plist input: input=~A output=~A~%"
            (cl-agent.core:llm-usage-input-tokens result)
            (cl-agent.core:llm-usage-output-tokens result))
    (assert (= (cl-agent.core:llm-usage-input-tokens result) 100))
    (assert (= (cl-agent.core:llm-usage-output-tokens result) 50)))

  ;; Test hash-table input
  (let ((result (cl-agent.llm:normalize-usage usage-hash :openai)))
    (format t "  Hash input: input=~A output=~A~%"
            (cl-agent.core:llm-usage-input-tokens result)
            (cl-agent.core:llm-usage-output-tokens result))
    (assert (= (cl-agent.core:llm-usage-input-tokens result) 200))
    (assert (= (cl-agent.core:llm-usage-output-tokens result) 75))))
(format t "  [PASSED]~%")

;; Test 2: normalize-openai-response
(format t "~%Test 2: normalize-openai-response~%")
(let* ((raw '(:content "Hello, world!"
              :model "gpt-4o"
              :usage (:prompt-tokens 10 :completion-tokens 5)
              :finish-reason "stop"
              :id "chatcmpl-123"))
       (response (cl-agent.llm:normalize-openai-response raw)))
  (format t "  Content: ~A~%" (cl-agent.core:llm-response-content response))
  (format t "  Model: ~A~%" (cl-agent.core:llm-response-model response))
  (format t "  Finish-reason: ~A~%" (cl-agent.core:llm-response-finish-reason response))
  (assert (string= (cl-agent.core:llm-response-content response) "Hello, world!"))
  (assert (string= (cl-agent.core:llm-response-model response) "gpt-4o"))
  (assert (eq (cl-agent.core:llm-response-finish-reason response) :stop)))
(format t "  [PASSED]~%")

;; Test 3: normalize-zhipu-response with reasoning-content
(format t "~%Test 3: normalize-zhipu-response (with reasoning)~%")
(let* ((raw '(:content "The answer is 42."
              :reasoning-content "Let me think about this..."
              :model "GLM-4.7"
              :usage (:prompt-tokens 20 :completion-tokens 10)
              :finish-reason "stop"
              :id "zhipu-123"))
       (response (cl-agent.llm:normalize-zhipu-response raw)))
  (format t "  Content: ~A~%" (cl-agent.core:llm-response-content response))
  (format t "  Model: ~A~%" (cl-agent.core:llm-response-model response))
  ;; Extract reasoning content
  (let ((reasoning (cl-agent.llm:response-reasoning-content response)))
    (format t "  Reasoning: ~A~%" reasoning)
    (assert (string= reasoning "Let me think about this...")))
  (assert (string= (cl-agent.core:llm-response-content response) "The answer is 42.")))
(format t "  [PASSED]~%")

;; Test 4: normalize-response dispatcher
(format t "~%Test 4: normalize-response dispatcher~%")
(let ((openai-raw '(:content "OpenAI response" :model "gpt-4o"))
      (zhipu-raw '(:content "Zhipu response" :model "GLM-4.7")))
  (let ((r1 (cl-agent.llm:normalize-response openai-raw :openai))
        (r2 (cl-agent.llm:normalize-response zhipu-raw :zhipu)))
    (format t "  OpenAI: ~A~%" (cl-agent.core:llm-response-content r1))
    (format t "  Zhipu: ~A~%" (cl-agent.core:llm-response-content r2))
    (assert (string= (cl-agent.core:llm-response-content r1) "OpenAI response"))
    (assert (string= (cl-agent.core:llm-response-content r2) "Zhipu response"))))
(format t "  [PASSED]~%")

;; Test 5: response-complete-p
(format t "~%Test 5: response-complete-p~%")
(let ((complete-response (cl-agent.core:make-llm-response
                          :content "Done"
                          :finish-reason :stop))
      (truncated-response (cl-agent.core:make-llm-response
                           :content "Truncat..."
                           :finish-reason :length)))
  (format t "  Complete: ~A~%" (cl-agent.llm:response-complete-p complete-response))
  (format t "  Truncated: ~A~%" (cl-agent.llm:response-complete-p truncated-response))
  (assert (cl-agent.llm:response-complete-p complete-response))
  (assert (not (cl-agent.llm:response-complete-p truncated-response))))
(format t "  [PASSED]~%")

(format t "~%=== All Service Layer Tests PASSED ===~%")
