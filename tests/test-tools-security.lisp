;;;; test-tools-security.lisp
;;;; CL-Agent - Tools Security and Resilience Tests

(in-package :cl-agent/tests)

(def-suite tools-security-suite
  :description "Tools security and resilience test suite"
  :in cl-agent-suite)

(in-suite tools-security-suite)

;;; ============================================================
;;; Security Policy Tests
;;; ============================================================

(test security-policy-creation
  "Test security policy creation"
  (let ((policy (cl-agent.tools:make-security-policy
                 :rate-limit 60
                 :timeout 30
                 :max-input-size (* 1024 1024))))
    (is (not (null policy)))
    (is (= 60 (cl-agent.tools:policy-rate-limit policy)))
    (is (= 30 (cl-agent.tools:policy-timeout policy)))))

(test security-policy-presets
  "Test security policy presets"
  (let ((permissive (cl-agent.tools:make-permissive-policy))
        (standard (cl-agent.tools:make-standard-policy))
        (strict (cl-agent.tools:make-strict-policy)))
    (is (not (null permissive)))
    (is (not (null standard)))
    (is (not (null strict)))
    ;; Strict should have lower limits
    (is (< (cl-agent.tools:policy-timeout strict)
           (cl-agent.tools:policy-timeout permissive)))))

;;; ============================================================
;;; Rate Limiter Tests
;;; ============================================================

(test rate-limiter-creation
  "Test rate limiter creation"
  (let ((limiter (cl-agent.tools:make-rate-limiter 10)))
    (is (not (null limiter)))))

(test rate-limiter-allow
  "Test rate limiter allows requests"
  (let ((limiter (cl-agent.tools:make-rate-limiter 100))) ; High limit
    ;; Should allow first request
    (is (cl-agent.tools:rate-limiter-check limiter))))

(test rate-limiter-refill
  "Test rate limiter token refill"
  (let ((limiter (cl-agent.tools:make-rate-limiter 10)))
    ;; Use some tokens
    (dotimes (i 5)
      (cl-agent.tools:rate-limiter-check limiter))
    ;; Should still have tokens
    (is (cl-agent.tools:rate-limiter-check limiter))))

(test rate-limiter-remaining
  "Test rate limiter remaining count"
  (let ((limiter (cl-agent.tools:make-rate-limiter 10)))
    ;; Initially should have all tokens
    (is (= 10 (cl-agent.tools:rate-limiter-remaining limiter)))
    ;; Use some
    (cl-agent.tools:rate-limiter-check limiter)
    (is (= 9 (cl-agent.tools:rate-limiter-remaining limiter)))))

;;; ============================================================
;;; Input Validator Tests
;;; ============================================================

(test input-validator-creation
  "Test input validator creation"
  (let ((validator (cl-agent.tools:make-input-validator
                    :max-size 1000)))
    (is (not (null validator)))))

(test input-validator-size-check
  "Test input validator size checking"
  (let ((validator (cl-agent.tools:make-input-validator :max-size 10)))
    ;; Short input should pass
    (multiple-value-bind (valid errors)
        (cl-agent.tools:validate-input validator "short")
      (is valid)
      (is (null errors)))
    ;; Long input should fail
    (multiple-value-bind (valid errors)
        (cl-agent.tools:validate-input validator "this is a very long input string")
      (is (not valid))
      (is (not (null errors))))))

(test input-validator-blocked-patterns
  "Test input validator blocked patterns"
  (let ((validator (cl-agent.tools:make-input-validator
                    :blocked-patterns '("(?i)password" "(?i)secret"))))
    ;; Normal input should pass
    (multiple-value-bind (valid errors)
        (cl-agent.tools:validate-input validator "hello world")
      (is valid)
      (is (null errors)))
    ;; Input with blocked pattern should fail
    (multiple-value-bind (valid errors)
        (cl-agent.tools:validate-input validator "my password is 123")
      (is (not valid))
      (is (not (null errors))))))

;;; ============================================================
;;; Domain Filter Tests
;;; ============================================================

(test domain-filter-creation
  "Test domain filter creation"
  (let ((filter (cl-agent.tools:make-domain-filter
                 :allowed-domains '("example.com" "test.org"))))
    (is (not (null filter)))))

(test domain-filter-allowed
  "Test domain filter allows valid domains"
  (let ((filter (cl-agent.tools:make-domain-filter
                 :allowed-domains '("example.com" "test.org"))))
    (is (cl-agent.tools:domain-allowed-p filter "https://example.com/path"))
    (is (cl-agent.tools:domain-allowed-p filter "https://test.org/page"))
    (is (not (cl-agent.tools:domain-allowed-p filter "https://evil.com/hack")))))

(test domain-filter-blocked
  "Test domain filter blocks specific domains"
  (let ((filter (cl-agent.tools:make-domain-filter
                 :blocked-domains '("blocked.com"))))
    ;; Should block specified domain
    (is (not (cl-agent.tools:domain-allowed-p filter "https://blocked.com/page")))
    ;; Should allow other domains
    (is (cl-agent.tools:domain-allowed-p filter "https://allowed.com/page"))))

;;; ============================================================
;;; Retry Policy Tests
;;; ============================================================

(test retry-policy-creation
  "Test retry policy creation"
  (let ((policy (cl-agent.tools:make-retry-policy
                 :max-attempts 3
                 :backoff-strategy :exponential
                 :initial-delay 1.0)))
    (is (not (null policy)))
    (is (= 3 (cl-agent.tools:retry-max-attempts policy)))))

(test retry-backoff-calculation
  "Test retry backoff delay calculation"
  (let ((policy (cl-agent.tools:make-retry-policy
                 :max-attempts 5
                 :backoff-strategy :exponential
                 :initial-delay 1.0
                 :jitter 0.0)))  ; No jitter for predictable tests
    ;; First attempt
    (let ((delay1 (cl-agent.tools:calculate-backoff policy 1)))
      (is (> delay1 0)))
    ;; Second attempt should be longer (exponential)
    (let ((delay1 (cl-agent.tools:calculate-backoff policy 1))
          (delay2 (cl-agent.tools:calculate-backoff policy 2)))
      (is (> delay2 delay1)))))

(test retry-backoff-strategies
  "Test different backoff strategies"
  ;; Constant backoff
  (let ((constant-delay1 (cl-agent.tools:constant-backoff 1 1.0 60.0))
        (constant-delay2 (cl-agent.tools:constant-backoff 2 1.0 60.0)))
    (is (= constant-delay1 constant-delay2)))
  ;; Linear backoff
  (let ((linear-delay1 (cl-agent.tools:linear-backoff 1 1.0 60.0))
        (linear-delay2 (cl-agent.tools:linear-backoff 2 1.0 60.0)))
    (is (> linear-delay2 linear-delay1)))
  ;; Exponential backoff
  (let ((exp-delay1 (cl-agent.tools:exponential-backoff 1 1.0 60.0))
        (exp-delay2 (cl-agent.tools:exponential-backoff 2 1.0 60.0)))
    (is (> exp-delay2 exp-delay1))))

;;; ============================================================
;;; Circuit Breaker Tests
;;; ============================================================

(test circuit-breaker-creation
  "Test circuit breaker creation"
  (let ((breaker (cl-agent.tools:make-circuit-breaker
                  :threshold 5
                  :reset-timeout 60)))
    (is (not (null breaker)))
    (is (eq :closed (cl-agent.tools:breaker-state breaker)))))

(test circuit-breaker-executes-when-closed
  "Test circuit breaker allows execution when closed"
  (let ((breaker (cl-agent.tools:make-circuit-breaker :threshold 5)))
    ;; Should execute successfully when closed
    (let ((result (cl-agent.tools:circuit-breaker-execute breaker
                    (lambda () 42))))
      (is (= 42 result)))))

(test circuit-breaker-manual-trip
  "Test circuit breaker manual trip"
  (let ((breaker (cl-agent.tools:make-circuit-breaker :threshold 5)))
    ;; Should be closed initially
    (is (eq :closed (cl-agent.tools:breaker-state breaker)))
    ;; Trip it
    (cl-agent.tools:circuit-breaker-trip breaker)
    (is (eq :open (cl-agent.tools:breaker-state breaker)))))

(test circuit-breaker-reset
  "Test circuit breaker reset"
  (let ((breaker (cl-agent.tools:make-circuit-breaker :threshold 5)))
    ;; Trip it
    (cl-agent.tools:circuit-breaker-trip breaker)
    (is (eq :open (cl-agent.tools:breaker-state breaker)))
    ;; Reset it
    (cl-agent.tools:circuit-breaker-reset breaker)
    (is (eq :closed (cl-agent.tools:breaker-state breaker)))))

;;; ============================================================
;;; Secure Tool Wrapper Tests
;;; ============================================================

(test secure-tool-creation
  "Test secure tool wrapper creation"
  (let* ((inner-tool (cl-agent.tools:make-simple-tool
                      :name "test-tool"
                      :description "A test tool"
                      :handler (lambda (&rest args) args)))
         (secure (cl-agent.tools:make-secure-tool inner-tool
                   :rate-limit 60
                   :timeout 30)))
    (is (not (null secure)))))

;;; ============================================================
;;; Resilience Macro Tests
;;; ============================================================

(test with-retry-macro
  "Test with-retry macro"
  (let ((call-count 0))
    ;; Should succeed on first try
    (let ((result (cl-agent.tools:with-retry (:attempts 3)
                    (incf call-count)
                    "success")))
      (is (string= "success" result))
      (is (= 1 call-count)))))

