;;;; test-provider-name.lisp
;;;; Test the provider-name generic function works for both tool-provider and base-provider

(format t "~%=== Testing provider-name generic function ===~%")

;; Test 1: Verify provider-name is a generic function
(format t "~%Test 1: Check if provider-name is a generic function~%")
(let ((is-generic (typep #'cl-agent.core:provider-name 'generic-function)))
  (format t "  provider-name is generic function: ~A~%" is-generic)
  (unless is-generic
    (error "provider-name should be a generic function")))

;; Test 2: Test with tool-provider
(format t "~%Test 2: Test provider-name with tool-provider~%")
(let ((tp (make-instance 'cl-agent.tools:tool-provider :name "test-tool-provider")))
  (let ((name (cl-agent.core:provider-name tp)))
    (format t "  tool-provider name: ~A~%" name)
    (unless (string= name "test-tool-provider")
      (error "Expected 'test-tool-provider', got ~A" name))))

;; Test 3: Test with base-provider (LLM)
(format t "~%Test 3: Test provider-name with base-provider~%")
(let ((bp (make-instance 'cl-agent.llm:base-provider
                         :name :test-llm-provider
                         :api-url "http://test.com"
                         :default-model "test-model"
                         :chat-endpoint "/chat"
                         :stream-endpoint "/stream")))
  (let ((name (cl-agent.core:provider-name bp)))
    (format t "  base-provider name: ~A~%" name)
    (unless (eq name :test-llm-provider)
      (error "Expected :TEST-LLM-PROVIDER, got ~A" name))))

(format t "~%=== All provider-name tests passed! ===~%")
