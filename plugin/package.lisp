;;;; package.lisp
;;;; CL-Agent Plugin - Package Definition
;;;;
;;;; Overview:
;;;;   Package definition for the enhanced plugin system.

(defpackage #:cl-agent.plugin
  (:use #:common-lisp
        #:cl-agent.core
        #:cl-agent.tools)
  (:local-nicknames (:bt :bordeaux-threads))
  (:nicknames #:cla.plugin #:plugin)
  (:export
   ;; ==================== Security Policies ====================
   ;; Security Policy Class
   #:security-policy
   #:make-security-policy
   #:policy-name
   #:policy-rate-limit
   #:policy-timeout
   #:policy-max-input-size
   #:policy-allowed-domains
   #:policy-blocked-patterns
   #:policy-sandbox-mode

   ;; Rate Limiter
   #:rate-limiter
   #:make-rate-limiter
   #:rate-limiter-check
   #:rate-limiter-reset
   #:rate-limiter-remaining

   ;; Input Validator
   #:input-validator
   #:make-input-validator
   #:validate-input
   #:add-validation-rule
   #:remove-validation-rule

   ;; Domain Filter
   #:domain-filter
   #:make-domain-filter
   #:domain-allowed-p
   #:add-allowed-domain
   #:add-blocked-domain

   ;; Secure Plugin Wrapper
   #:secure-plugin
   #:make-secure-plugin
   #:wrap-with-security
   #:execute-secure

   ;; Security Utilities
   #:sanitize-input
   #:check-rate-limit
   #:validate-domain

   ;; ==================== Resilience Patterns ====================
   ;; Retry Policy
   #:retry-policy
   #:make-retry-policy
   #:retry-max-attempts
   #:retry-backoff-strategy
   #:retry-initial-delay
   #:retry-max-delay
   #:retry-jitter

   ;; Timeout Policy
   #:timeout-policy
   #:make-timeout-policy
   #:timeout-duration
   #:timeout-on-timeout

   ;; Circuit Breaker
   #:circuit-breaker
   #:make-circuit-breaker
   #:breaker-state
   #:breaker-failure-count
   #:breaker-threshold
   #:breaker-reset-timeout
   #:circuit-breaker-execute
   #:circuit-breaker-reset
   #:circuit-breaker-trip

   ;; Resilience Wrapper
   #:resilient-call
   #:make-resilient-wrapper
   #:with-retry
   #:with-timeout
   #:with-circuit-breaker
   #:with-resilience

   ;; Backoff Strategies
   #:calculate-backoff
   #:constant-backoff
   #:linear-backoff
   #:exponential-backoff
   #:fibonacci-backoff

   ;; ==================== Builtin Plugins ====================
   ;; File Plugin
   #:file-plugin
   #:make-file-plugin
   #:file-plugin-read
   #:file-plugin-write
   #:file-plugin-delete
   #:file-plugin-list

   ;; HTTP Plugin
   #:http-plugin
   #:make-http-plugin
   #:http-plugin-get
   #:http-plugin-post
   #:http-plugin-request

   ;; Shell Plugin
   #:shell-plugin
   #:make-shell-plugin
   #:shell-plugin-execute
   #:shell-plugin-script

   ;; Utility Plugin
   #:utility-plugin
   #:make-utility-plugin
   #:utility-timestamp
   #:utility-uuid
   #:utility-json-parse
   #:utility-json-stringify

   ;; ==================== Plugin Aggregation ====================
   #:all-builtin-plugins
   #:create-default-plugins
   #:register-all-plugins
   #:plugin-collection
   #:make-plugin-collection
   #:collection-add
   #:collection-remove
   #:collection-get
   #:collection-list))

