;;;; test-service-layer.lisp
;;;; Test the Service Layer response normalization (single-source path)

(format t "~%=== Testing Service Layer ===~%")

;; Test 1: cl-agent.core:normalize-usage (permissive aliases)
(format t "~%Test 1: normalize-usage (permissive)~%")
(let ((usage-plist '(:prompt-tokens 100 :completion-tokens 50))
      (usage-hash (make-hash-table :test 'equal)))
  (setf (gethash "prompt_tokens" usage-hash) 200)
  (setf (gethash "completion_tokens" usage-hash) 75)

  ;; Test plist input
  (let ((result (cl-agent.core:normalize-usage usage-plist)))
    (assert (= (cl-agent.core:llm-usage-input-tokens result) 100))
    (assert (= (cl-agent.core:llm-usage-output-tokens result) 50)))

  ;; Test hash-table input (OpenAI naming)
  (let ((result (cl-agent.core:normalize-usage usage-hash)))
    (assert (= (cl-agent.core:llm-usage-input-tokens result) 200))
    (assert (= (cl-agent.core:llm-usage-output-tokens result) 75)))

  ;; Test hash-table input (Anthropic naming)
  (let ((anthropic-hash (make-hash-table :test 'equal)))
    (setf (gethash "input_tokens" anthropic-hash) 30)
    (setf (gethash "output_tokens" anthropic-hash) 40)
    (setf (gethash "cache_read_input_tokens" anthropic-hash) 12)
    (let ((result (cl-agent.core:normalize-usage anthropic-hash)))
      (assert (= (cl-agent.core:llm-usage-input-tokens result) 30))
      (assert (= (cl-agent.core:llm-usage-output-tokens result) 40))
      (assert (= (cl-agent.core:llm-usage-cache-read-tokens result) 12)))))
(format t "  [PASSED]~%")

;; Test 2: ensure-llm-response (idempotent)
(format t "~%Test 2: ensure-llm-response~%")
(let* ((raw '(:content "Hello, world!"
              :model "gpt-4o"
              :usage (:prompt-tokens 10 :completion-tokens 5)
              :finish-reason "stop"
              :id "chatcmpl-123"))
       (response (cl-agent.llm:ensure-llm-response raw)))
  (assert (string= (cl-agent.core:llm-response-content response) "Hello, world!"))
  (assert (string= (cl-agent.core:llm-response-model response) "gpt-4o"))
  (assert (eq (cl-agent.core:llm-response-finish-reason response) :stop))
  ;; 幂等：再转一次返回同一对象
  (assert (eq response (cl-agent.llm:ensure-llm-response response))))
(format t "  [PASSED]~%")

;; Test 3: llm-response :reasoning slot + response-reasoning-content
(format t "~%Test 3: reasoning content~%")
(let ((response (cl-agent.core:make-llm-response
                 :content "The answer is 42."
                 :reasoning "Let me think about this..."
                 :model "GLM-4.7")))
  (assert (string= (cl-agent.llm:response-reasoning-content response)
                   "Let me think about this...")))
(format t "  [PASSED]~%")

;; Test 4: normalize-response compat shim
(format t "~%Test 4: normalize-response (compat shim)~%")
(let ((r1 (cl-agent.llm:normalize-response '(:content "OpenAI response" :model "gpt-4o")))
      (r2 (cl-agent.llm:normalize-response '(:content "Zhipu response" :model "GLM-4.7") :zhipu)))
  (assert (string= (cl-agent.core:llm-response-content r1) "OpenAI response"))
  (assert (string= (cl-agent.core:llm-response-content r2) "Zhipu response")))
(format t "  [PASSED]~%")

;; Test 5: response-complete-p
(format t "~%Test 5: response-complete-p~%")
(let ((complete-response (cl-agent.core:make-llm-response
                          :content "Done"
                          :finish-reason :stop))
      (truncated-response (cl-agent.core:make-llm-response
                           :content "Truncat..."
                           :finish-reason :max-tokens)))
  (assert (cl-agent.llm:response-complete-p complete-response))
  (assert (not (cl-agent.llm:response-complete-p truncated-response))))
(format t "  [PASSED]~%")

(format t "~%=== All Service Layer Tests PASSED ===~%")
