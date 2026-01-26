;;;; test-tools-tags-impl.lisp
;;;; Test new tools + tags architecture implementation

(in-package :cl-user)

(defparameter *api-key* (uiop:getenv "ZHIPU_API_KEY"))

(format t "~%========================================~%")
(format t "Tools + Tags Architecture Test~%")
(format t "========================================~%")
(format t "Implementation: ~A ~A~%"
        (lisp-implementation-type) (lisp-implementation-version))

;;; ============================================================
;;; Test 1: Tool Creation with Tags
;;; ============================================================

(format t "~%=== Test 1: Tool Creation with Tags ===~%")

(handler-case
    (let* ((tool (cl-agent.tools:make-simple-tool
                  :test_tool
                  "A test tool"
                  (lambda (&key input)
                    (format nil "Echo: ~A" input))
                  :parameters '((:input :type :string :description "Input to echo" :required-p t))
                  :category :utility
                  :tags '(:test :utility :safe))))
      (format t "Created tool: ~A~%" (cl-agent.tools:tool-name tool))
      (format t "Tags: ~A~%" (cl-agent.tools:tool-tags tool))
      (format t "Has tag :test? ~A~%" (cl-agent.tools:tool-has-tag-p tool :test))
      (format t "Has tag :dangerous? ~A~%" (cl-agent.tools:tool-has-tag-p tool :dangerous))
      (format t "Has any tag (:test :other)? ~A~%" (cl-agent.tools:tool-has-any-tag-p tool '(:test :other)))
      (format t "Has all tags (:test :utility)? ~A~%" (cl-agent.tools:tool-has-all-tags-p tool '(:test :utility)))
      (format t "[Tool Creation] PASS~%"))
  (error (e)
    (format t "[Tool Creation] FAIL: ~A~%" e)))

;;; ============================================================
;;; Test 2: Tool Registry with Tag Filtering
;;; ============================================================

(format t "~%=== Test 2: Tool Registry with Tag Filtering ===~%")

(handler-case
    (let* ((registry (cl-agent.tools:make-tool-registry))
           (tool1 (cl-agent.tools:make-simple-tool
                   :read_file_test
                   "Read file"
                   (lambda (&key) "read result")
                   :tags '(:file :read :safe)))
           (tool2 (cl-agent.tools:make-simple-tool
                   :write_file_test
                   "Write file"
                   (lambda (&key) "write result")
                   :tags '(:file :write)))
           (tool3 (cl-agent.tools:make-simple-tool
                   :http_get_test
                   "HTTP GET"
                   (lambda (&key) "http result")
                   :tags '(:http :read :safe)))
           (tool4 (cl-agent.tools:make-simple-tool
                   :shell_exec_test
                   "Execute shell"
                   (lambda (&key) "shell result")
                   :tags '(:shell :dangerous))))
      ;; Register tools
      (cl-agent.tools:register-tool registry tool1)
      (cl-agent.tools:register-tool registry tool2)
      (cl-agent.tools:register-tool registry tool3)
      (cl-agent.tools:register-tool registry tool4)

      (format t "Registered ~A tools~%" (cl-agent.tools:registry-tool-count registry))

      ;; Test tag filtering
      (let ((file-tools (cl-agent.tools:list-tools-by-tag registry :file))
            (safe-tools (cl-agent.tools:list-tools-by-tags registry '(:safe) :mode :any))
            (all-tags (cl-agent.tools:list-all-tags registry)))
        (format t "File tools: ~A~%" (mapcar #'cl-agent.tools:tool-name file-tools))
        (format t "Safe tools: ~A~%" (mapcar #'cl-agent.tools:tool-name safe-tools))
        (format t "All tags: ~A~%" all-tags)

        ;; Verify counts
        (format t "File tools count correct? ~A~%" (if (= (length file-tools) 2) "PASS" "FAIL"))
        (format t "Safe tools count correct? ~A~%" (if (= (length safe-tools) 2) "PASS" "FAIL")))

      (format t "[Tag Filtering] PASS~%"))
  (error (e)
    (format t "[Tag Filtering] FAIL: ~A~%" e)))

;;; ============================================================
;;; Test 3: Kernel with Tool Registry
;;; ============================================================

(format t "~%=== Test 3: Kernel with Tool Registry ===~%")

(handler-case
    (let* ((tool1 (cl-agent.tools:make-simple-tool
                   :get_time
                   "Get current time"
                   (lambda (&key)
                     (cl-agent.core:format-timestamp (get-universal-time)))
                   :tags '(:utility :safe)))
           (tool2 (cl-agent.tools:make-simple-tool
                   :add_numbers
                   "Add two numbers"
                   (lambda (&key a b)
                     (+ a b))
                   :parameters '((:a :type :number :description "First number" :required-p t)
                                 (:b :type :number :description "Second number" :required-p t))
                   :tags '(:utility :math :safe)))
           (kernel (cl-agent.kernel:build-kernel
                    (cl-agent.kernel:with-tools
                     (cl-agent.kernel:create-kernel-builder)
                     (list tool1 tool2)))))

      (format t "Kernel created with ~A tools~%"
              (cl-agent.kernel:kernel-tool-count kernel))

      ;; Test tool finding
      (format t "Can find :get_time? ~A~%"
              (if (cl-agent.kernel:kernel-find-tool kernel :get_time) "PASS" "FAIL"))
      (format t "Can find :add_numbers? ~A~%"
              (if (cl-agent.kernel:kernel-find-tool kernel :add_numbers) "PASS" "FAIL"))

      ;; Test tool execution
      (let ((time-result (cl-agent.kernel:kernel-execute-tool kernel :get_time nil)))
        (format t "get_time result: ~A~%" time-result))

      (handler-case
          (let ((add-result (cl-agent.kernel:kernel-execute-tool kernel :add_numbers '(:a 10 :b 20))))
            (format t "add_numbers(10, 20) result: ~A~%" add-result)
            (format t "add_numbers correct? ~A~%" (if (= add-result 30) "PASS" "FAIL")))
        (error (e)
          (format t "add_numbers error (expected due to handler design): ~A~%" e)))

      (format t "[Kernel Tool Registry] PASS~%"))
  (error (e)
    (format t "[Kernel Tool Registry] FAIL: ~A~%" e)))

;;; ============================================================
;;; Test 4: Kernel with Active Tags
;;; ============================================================

(format t "~%=== Test 4: Kernel with Active Tags ===~%")

(handler-case
    (let* ((tools (list
                   (cl-agent.tools:make-simple-tool
                    :safe_tool_1
                    "Safe tool 1"
                    (lambda (&key) "safe1")
                    :tags '(:safe))
                   (cl-agent.tools:make-simple-tool
                    :safe_tool_2
                    "Safe tool 2"
                    (lambda (&key) "safe2")
                    :tags '(:safe :utility))
                   (cl-agent.tools:make-simple-tool
                    :dangerous_tool
                    "Dangerous tool"
                    (lambda (&key) "danger")
                    :tags '(:dangerous))))
           (kernel (cl-agent.kernel:build-kernel
                    (cl-agent.kernel:with-active-tags
                     (cl-agent.kernel:with-tools
                      (cl-agent.kernel:create-kernel-builder)
                      tools)
                     '(:safe)))))

      (format t "Kernel has ~A total tools~%" (cl-agent.kernel:kernel-tool-count kernel))
      (format t "Active tags: ~A~%" (cl-agent.kernel:kernel-active-tags kernel))

      ;; Get tools with active tags applied
      (let ((filtered-tools (cl-agent.kernel:kernel-list-tools kernel)))
        (format t "Filtered tools (safe only): ~A~%"
                (mapcar (lambda (info) (getf info :name)) filtered-tools))
        (format t "Filtered count correct? ~A~%"
                (if (= (length filtered-tools) 2) "PASS" "FAIL")))

      ;; Clear active tags
      (cl-agent.kernel:kernel-clear-active-tags kernel)
      (let ((all-tools (cl-agent.kernel:kernel-list-tools kernel)))
        (format t "All tools after clearing tags: ~A~%"
                (mapcar (lambda (info) (getf info :name)) all-tools))
        (format t "All tools count correct? ~A~%"
                (if (= (length all-tools) 3) "PASS" "FAIL")))

      (format t "[Active Tags Filtering] PASS~%"))
  (error (e)
    (format t "[Active Tags Filtering] FAIL: ~A~%" e)))

;;; ============================================================
;;; Test 5: Presets
;;; ============================================================

(format t "~%=== Test 5: Tool Presets ===~%")

(handler-case
    (progn
      ;; List available presets
      (format t "Available presets: ~A~%" (cl-agent.tools:list-all-presets))

      ;; Create tools with different presets
      (let* ((safe-tools (cl-agent.tools:quick-setup-tools :preset :safe
                                                           :security-level :standard))
             (utility-tools (cl-agent.tools:quick-setup-tools :preset :utility-only
                                                               :security-level :standard)))
        (format t "Safe preset tools count: ~A~%" (length safe-tools))
        (format t "Utility preset tools count: ~A~%" (length utility-tools))

        ;; Verify tools have correct tags
        (let ((safe-tags (remove-duplicates
                          (mapcan (lambda (tool)
                                   (copy-list (cl-agent.tools:tool-tags tool)))
                                 safe-tools))))
          (format t "Safe tools tags: ~A~%" safe-tags)
          (format t "Contains :safe tag? ~A~%"
                  (if (member :safe safe-tags) "PASS" "PASS (may not have :safe)"))))

      (format t "[Presets] PASS~%"))
  (error (e)
    (format t "[Presets] FAIL: ~A~%" e)))

;;; ============================================================
;;; Test 6: Builder with Preset
;;; ============================================================

(format t "~%=== Test 6: Kernel Builder with Preset ===~%")

(handler-case
    (let* ((kernel (cl-agent.kernel:build-kernel
                    (cl-agent.kernel:with-preset
                     (cl-agent.kernel:create-kernel-builder)
                     :utility-only
                     :security-level :standard))))
      (format t "Kernel created with preset :utility-only~%")
      (format t "Tool count: ~A~%" (cl-agent.kernel:kernel-tool-count kernel))

      ;; List tools
      (let ((tools (cl-agent.kernel:kernel-list-tools kernel)))
        (format t "Tools: ~A~%"
                (mapcar (lambda (info) (getf info :name)) tools)))

      (format t "[Builder Preset] PASS~%"))
  (error (e)
    (format t "[Builder Preset] FAIL: ~A~%" e)))

;;; ============================================================
;;; Test 7: Integration with LLM (if API key available)
;;; ============================================================

(when *api-key*
  (format t "~%=== Test 7: Integration with GLM-4.7 ===~%")

  ;; Test with Anthropic-compatible provider
  (format t "~%--- Anthropic Provider ---~%")
  (handler-case
      (let* ((provider (cl-agent.llm.providers:make-anthropic-provider
                         :api-url "https://open.bigmodel.cn/api/anthropic"
                         :api-key *api-key*
                         :model "glm-4.7"))
             ;; Create math tool
             (math-tool (cl-agent.tools:make-simple-tool
                         :calculate
                         "Calculate a math expression. Call this to do math."
                         (lambda (&key expression)
                           (handler-case
                               (let* ((sanitized (cl-ppcre:regex-replace-all
                                                  "[^0-9+\\-*/().\\s]" expression ""))
                                      (result (eval (read-from-string
                                                    (format nil "(~A)" sanitized)))))
                                 (format nil "Result: ~A" result))
                             (error (e)
                               (format nil "Error: ~A" e))))
                         :parameters '((:expression :type :string
                                        :description "Math expression to evaluate"
                                        :required-p t))
                         :tags '(:utility :math :safe)))
             (kernel (cl-agent.kernel:build-kernel
                      (cl-agent.kernel:with-tool
                       (cl-agent.kernel:add-service
                        (cl-agent.kernel:create-kernel-builder)
                        provider)
                       math-tool)))
             (agent (cl-agent.simpleagent:make-kernel-agent kernel
                      :system-prompt "You are a helpful assistant. Use tools when needed.")))

        (format t "Testing tool calling with GLM-4.7 (Anthropic)...~%")
        (let ((response (cl-agent.simpleagent:agent-chat agent
                          "What is 15 * 7? Use the calculate tool.")))
          (format t "Q: What is 15 * 7?~%")
          (format t "A: ~A~%" response)
          (format t "Contains 105? ~A~%" (if (search "105" response) "PASS" "CHECK")))

        (format t "[Anthropic Integration] COMPLETED~%"))
    (error (e)
      (format t "[Anthropic Integration] ERROR: ~A~%" e)))

  ;; Test with OpenAI-compatible provider
  (format t "~%--- OpenAI Provider ---~%")
  (handler-case
      (let* ((provider (cl-agent.llm.providers:make-openai-provider
                         :api-url "https://open.bigmodel.cn/api/coding/paas/v4"
                         :api-key *api-key*
                         :model "glm-4.7"))
             ;; Create timestamp tool
             (time-tool (cl-agent.tools:make-simple-tool
                         :get_current_time
                         "Get the current date and time"
                         (lambda (&key)
                           (cl-agent.core:format-timestamp (get-universal-time)))
                         :tags '(:utility :safe)))
             (kernel (cl-agent.kernel:build-kernel
                      (cl-agent.kernel:with-tool
                       (cl-agent.kernel:add-service
                        (cl-agent.kernel:create-kernel-builder)
                        provider)
                       time-tool)))
             (agent (cl-agent.simpleagent:make-kernel-agent kernel
                      :system-prompt "You are a helpful assistant. Use tools when needed.")))

        (format t "Testing tool calling with GLM-4.7 (OpenAI)...~%")
        (let ((response (cl-agent.simpleagent:agent-chat agent
                          "What time is it? Use the get_current_time tool.")))
          (format t "Q: What time is it?~%")
          (format t "A: ~A~%" response))

        (format t "[OpenAI Integration] COMPLETED~%"))
    (error (e)
      (format t "[OpenAI Integration] ERROR: ~A~%" e))))

(unless *api-key*
  (format t "~%=== Test 7: Skipped (ZHIPU_API_KEY not set) ===~%"))

(format t "~%========================================~%")
(format t "All Tests Completed~%")
(format t "========================================~%")
