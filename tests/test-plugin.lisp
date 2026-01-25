;;;; test-plugin.lisp
;;;; CL-Agent - Plugin Module Tests

(in-package :cl-agent/tests)

(def-suite plugin-suite
  :description "Plugin module test suite"
  :in cl-agent-suite)

(in-suite plugin-suite)

;;; ============================================================
;;; Security Policy Tests
;;; ============================================================

(test security-policy-creation
  "Test security policy creation"
  (let ((policy (cl-agent.plugin:make-security-policy
                 :rate-limit 60
                 :timeout 30
                 :max-input-size (* 1024 1024))))
    (is (not (null policy)))
    (is (= 60 (cl-agent.plugin:policy-rate-limit policy)))
    (is (= 30 (cl-agent.plugin:policy-timeout policy)))))

(test security-policy-presets
  "Test security policy presets"
  (let ((permissive (cl-agent.plugin:make-permissive-policy))
        (standard (cl-agent.plugin:make-standard-policy))
        (strict (cl-agent.plugin:make-strict-policy)))
    (is (not (null permissive)))
    (is (not (null standard)))
    (is (not (null strict)))
    ;; Strict should have lower limits
    (is (< (cl-agent.plugin:policy-timeout strict)
           (cl-agent.plugin:policy-timeout permissive)))))

;;; ============================================================
;;; Rate Limiter Tests
;;; ============================================================

(test rate-limiter-creation
  "Test rate limiter creation"
  (let ((limiter (cl-agent.plugin:make-rate-limiter 10)))
    (is (not (null limiter)))))

(test rate-limiter-allow
  "Test rate limiter allows requests"
  (let ((limiter (cl-agent.plugin:make-rate-limiter 100))) ; High limit
    ;; Should allow first request
    (is (cl-agent.plugin:rate-limiter-check limiter))))

(test rate-limiter-refill
  "Test rate limiter token refill"
  (let ((limiter (cl-agent.plugin:make-rate-limiter 10)))
    ;; Use some tokens
    (dotimes (i 5)
      (cl-agent.plugin:rate-limiter-check limiter))
    ;; Should still have tokens
    (is (cl-agent.plugin:rate-limiter-check limiter))))

;;; ============================================================
;;; Input Validator Tests
;;; ============================================================

(test input-validator-creation
  "Test input validator creation"
  (let ((validator (cl-agent.plugin:make-input-validator
                    :max-size 1000
                    :allowed-chars nil)))
    (is (not (null validator)))))

(test input-validator-size-check
  "Test input validator size checking"
  (let ((validator (cl-agent.plugin:make-input-validator :max-size 10)))
    ;; Short input should pass
    (is (cl-agent.plugin:validate-input validator "short"))
    ;; Long input should fail
    (signals error
      (cl-agent.plugin:validate-input validator "this is a very long input string"))))

;;; ============================================================
;;; Retry Policy Tests
;;; ============================================================

(test retry-policy-creation
  "Test retry policy creation"
  (let ((policy (cl-agent.plugin:make-retry-policy
                 :max-retries 3
                 :backoff-type :exponential
                 :initial-delay 1.0)))
    (is (not (null policy)))
    (is (= 3 (cl-agent.plugin:retry-policy-max-retries policy)))))

(test retry-backoff-calculation
  "Test retry backoff delay calculation"
  (let ((policy (cl-agent.plugin:make-retry-policy
                 :max-retries 5
                 :backoff-type :exponential
                 :initial-delay 1.0
                 :multiplier 2.0)))
    ;; First retry
    (let ((delay1 (cl-agent.plugin:calculate-backoff policy 1)))
      (is (> delay1 0)))
    ;; Second retry should be longer
    (let ((delay1 (cl-agent.plugin:calculate-backoff policy 1))
          (delay2 (cl-agent.plugin:calculate-backoff policy 2)))
      (is (> delay2 delay1)))))

;;; ============================================================
;;; Circuit Breaker Tests
;;; ============================================================

(test circuit-breaker-creation
  "Test circuit breaker creation"
  (let ((breaker (cl-agent.plugin:make-circuit-breaker
                  :threshold 5
                  :reset-timeout 60)))
    (is (not (null breaker)))
    (is (eq :closed (cl-agent.plugin:circuit-breaker-state breaker)))))

(test circuit-breaker-closed-state
  "Test circuit breaker allows calls when closed"
  (let ((breaker (cl-agent.plugin:make-circuit-breaker :threshold 5)))
    (is (cl-agent.plugin:circuit-breaker-allow-p breaker))))

(test circuit-breaker-record-success
  "Test circuit breaker records success"
  (let ((breaker (cl-agent.plugin:make-circuit-breaker :threshold 5)))
    (cl-agent.plugin:circuit-breaker-record-success breaker)
    (is (eq :closed (cl-agent.plugin:circuit-breaker-state breaker)))))

(test circuit-breaker-opens-on-failures
  "Test circuit breaker opens after failures"
  (let ((breaker (cl-agent.plugin:make-circuit-breaker :threshold 3)))
    ;; Record failures
    (dotimes (i 3)
      (cl-agent.plugin:circuit-breaker-record-failure breaker))
    ;; Should be open now
    (is (eq :open (cl-agent.plugin:circuit-breaker-state breaker)))
    (is (not (cl-agent.plugin:circuit-breaker-allow-p breaker)))))

;;; ============================================================
;;; File Plugin Tests
;;; ============================================================

(test file-plugin-creation
  "Test file plugin creation"
  (let ((plugin (cl-agent.plugin:make-file-plugin
                 :allowed-paths '("/tmp/")
                 :max-file-size (* 1024 1024))))
    (is (not (null plugin)))
    (is (string= "file" (cl-agent.plugin:plugin-name plugin)))))

(test file-plugin-tools
  "Test file plugin tools registration"
  (let* ((plugin (cl-agent.plugin:make-file-plugin))
         (tools (cl-agent.plugin:file-plugin-tools plugin)))
    (is (listp tools))
    (is (> (length tools) 0))
    ;; Should have read_file tool
    (is (find "read_file" tools
              :key (lambda (t) (cl-agent.core:tool-name t))
              :test #'string=))))

;;; ============================================================
;;; HTTP Plugin Tests
;;; ============================================================

(test http-plugin-creation
  "Test HTTP plugin creation"
  (let ((plugin (cl-agent.plugin:make-http-plugin
                 :blocked-domains '("localhost" "127.0.0.1")
                 :timeout 30)))
    (is (not (null plugin)))
    (is (string= "http" (cl-agent.plugin:plugin-name plugin)))))

(test http-plugin-tools
  "Test HTTP plugin tools registration"
  (let* ((plugin (cl-agent.plugin:make-http-plugin))
         (tools (cl-agent.plugin:http-plugin-tools plugin)))
    (is (listp tools))
    ;; Should have http_get and http_post tools
    (is (find "http_get" tools
              :key (lambda (t) (cl-agent.core:tool-name t))
              :test #'string=))))

;;; ============================================================
;;; Shell Plugin Tests
;;; ============================================================

(test shell-plugin-creation
  "Test shell plugin creation"
  (let ((plugin (cl-agent.plugin:make-shell-plugin
                 :timeout 60
                 :blocked-commands '("rm -rf" "sudo"))))
    (is (not (null plugin)))
    (is (string= "shell" (cl-agent.plugin:plugin-name plugin)))))

(test shell-plugin-tools
  "Test shell plugin tools registration"
  (let* ((plugin (cl-agent.plugin:make-shell-plugin))
         (tools (cl-agent.plugin:shell-plugin-tools plugin)))
    (is (listp tools))
    ;; Should have execute_command tool
    (is (find "execute_command" tools
              :key (lambda (t) (cl-agent.core:tool-name t))
              :test #'string=))))

;;; ============================================================
;;; Utility Plugin Tests
;;; ============================================================

(test utility-plugin-creation
  "Test utility plugin creation"
  (let ((plugin (cl-agent.plugin:make-utility-plugin)))
    (is (not (null plugin)))
    (is (string= "utility" (cl-agent.plugin:plugin-name plugin)))))

(test utility-plugin-tools
  "Test utility plugin tools registration"
  (let* ((plugin (cl-agent.plugin:make-utility-plugin))
         (tools (cl-agent.plugin:utility-plugin-tools plugin)))
    (is (listp tools))
    ;; Should have timestamp and uuid tools
    (is (find "get_timestamp" tools
              :key (lambda (t) (cl-agent.core:tool-name t))
              :test #'string=))
    (is (find "generate_uuid" tools
              :key (lambda (t) (cl-agent.core:tool-name t))
              :test #'string=))))

;;; ============================================================
;;; Plugin Collection Tests
;;; ============================================================

(test plugin-collection-creation
  "Test plugin collection creation"
  (let ((collection (cl-agent.plugin:make-plugin-collection)))
    (is (not (null collection)))))

(test plugin-collection-operations
  "Test plugin collection add/get/remove"
  (let ((collection (cl-agent.plugin:make-plugin-collection))
        (plugin (cl-agent.plugin:make-utility-plugin)))
    ;; Add
    (cl-agent.plugin:collection-add collection "test" plugin)
    ;; Get
    (let ((retrieved (cl-agent.plugin:collection-get collection "test")))
      (is (eq plugin retrieved)))
    ;; Remove
    (cl-agent.plugin:collection-remove collection "test")
    (is (null (cl-agent.plugin:collection-get collection "test")))))

(test all-builtin-plugins
  "Test creating all builtin plugins"
  (let ((collection (cl-agent.plugin:all-builtin-plugins)))
    (is (not (null collection)))
    ;; Should have all standard plugins
    (is (not (null (cl-agent.plugin:collection-get collection "file"))))
    (is (not (null (cl-agent.plugin:collection-get collection "http"))))
    (is (not (null (cl-agent.plugin:collection-get collection "shell"))))
    (is (not (null (cl-agent.plugin:collection-get collection "utility"))))))

