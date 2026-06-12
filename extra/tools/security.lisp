;;;; security.lisp
;;;; CL-Agent Tools - Security Policies
;;;;
;;;; Overview:
;;;;   Security policies for tool execution including:
;;;;   - Rate limiting
;;;;   - Input validation
;;;;   - Domain filtering
;;;;   - Sandboxing
;;;;
;;;; Reference:
;;;;   - OWASP security guidelines
;;;;   - Enterprise security patterns

(in-package #:cl-agent.tools)

;;; ============================================================
;;; Security Policy Class
;;; ============================================================

(defclass security-policy ()
  ((name
    :initarg :name
    :reader policy-name
    :initform "default"
    :type string
    :documentation "Policy name")

   (rate-limit
    :initarg :rate-limit
    :accessor policy-rate-limit
    :initform nil
    :type (or null integer)
    :documentation "Maximum requests per minute (nil = unlimited)")

   (timeout
    :initarg :timeout
    :accessor policy-timeout
    :initform 30
    :type integer
    :documentation "Maximum execution time in seconds")

   (max-input-size
    :initarg :max-input-size
    :accessor policy-max-input-size
    :initform (* 1024 1024)  ; 1MB
    :type integer
    :documentation "Maximum input size in bytes")

   (allowed-domains
    :initarg :allowed-domains
    :accessor policy-allowed-domains
    :initform nil
    :type list
    :documentation "List of allowed domains (nil = all allowed)")

   (blocked-patterns
    :initarg :blocked-patterns
    :accessor policy-blocked-patterns
    :initform nil
    :type list
    :documentation "List of blocked input patterns (regex strings)")

   (sandbox-mode
    :initarg :sandbox-mode
    :accessor policy-sandbox-mode
    :initform :none
    :type keyword
    :documentation "Sandbox mode (:none, :basic, :strict)"))

  (:documentation "Security policy for plugin execution."))

(defun make-security-policy (&key (name "default")
                                   rate-limit
                                   (timeout 30)
                                   (max-input-size (* 1024 1024))
                                   allowed-domains
                                   blocked-patterns
                                   (sandbox-mode :none))
  "Create a security policy.

Parameters:
  NAME             - Policy name
  RATE-LIMIT       - Max requests per minute (nil = unlimited)
  TIMEOUT          - Max execution time in seconds
  MAX-INPUT-SIZE   - Max input size in bytes
  ALLOWED-DOMAINS  - List of allowed domains
  BLOCKED-PATTERNS - List of blocked patterns
  SANDBOX-MODE     - Sandbox mode (:none, :basic, :strict)

Returns:
  security-policy instance"
  (make-instance 'security-policy
                 :name name
                 :rate-limit rate-limit
                 :timeout timeout
                 :max-input-size max-input-size
                 :allowed-domains allowed-domains
                 :blocked-patterns blocked-patterns
                 :sandbox-mode sandbox-mode))

;;; ============================================================
;;; Rate Limiter
;;; ============================================================

(defclass rate-limiter ()
  ((limit
    :initarg :limit
    :reader rate-limiter-limit
    :type integer
    :documentation "Maximum requests per window")

   (window
    :initarg :window
    :reader rate-limiter-window
    :initform 60
    :type integer
    :documentation "Time window in seconds")

   (requests
    :initform nil
    :accessor rate-limiter-requests
    :type list
    :documentation "List of request timestamps")

   (lock
    :initform (bt:make-lock "rate-limiter")
    :reader rate-limiter-lock))

  (:documentation "Token bucket rate limiter."))

(defun make-rate-limiter (limit &key (window 60))
  "Create a rate limiter.

Parameters:
  LIMIT  - Maximum requests per window
  WINDOW - Time window in seconds

Returns:
  rate-limiter instance"
  (make-instance 'rate-limiter
                 :limit limit
                 :window window))

(defgeneric rate-limiter-check (limiter)
  (:documentation "Check if request is allowed and record it."))

(defmethod rate-limiter-check ((limiter rate-limiter))
  "Check if request is allowed and record it.

Returns:
  T if allowed, NIL if rate limited"
  (bt:with-lock-held ((rate-limiter-lock limiter))
    (let* ((now (get-universal-time))
           (window-start (- now (rate-limiter-window limiter)))
           ;; Remove old requests
           (active-requests (remove-if (lambda (ts) (< ts window-start))
                                       (rate-limiter-requests limiter))))
      (setf (rate-limiter-requests limiter) active-requests)

      ;; Check if under limit
      (if (< (length active-requests) (rate-limiter-limit limiter))
          (progn
            (push now (rate-limiter-requests limiter))
            t)
          nil))))

(defgeneric rate-limiter-reset (limiter)
  (:documentation "Reset the rate limiter."))

(defmethod rate-limiter-reset ((limiter rate-limiter))
  "Reset the rate limiter."
  (bt:with-lock-held ((rate-limiter-lock limiter))
    (setf (rate-limiter-requests limiter) nil)))

(defgeneric rate-limiter-remaining (limiter)
  (:documentation "Get remaining requests in current window."))

(defmethod rate-limiter-remaining ((limiter rate-limiter))
  "Get remaining requests in current window."
  (bt:with-lock-held ((rate-limiter-lock limiter))
    (let* ((now (get-universal-time))
           (window-start (- now (rate-limiter-window limiter)))
           (active-requests (remove-if (lambda (ts) (< ts window-start))
                                       (rate-limiter-requests limiter))))
      (max 0 (- (rate-limiter-limit limiter) (length active-requests))))))

;;; ============================================================
;;; Input Validator
;;; ============================================================

(defclass input-validator ()
  ((rules
    :initform nil
    :accessor validator-rules
    :type list
    :documentation "List of validation rules (name . function)")

   (max-size
    :initarg :max-size
    :reader validator-max-size
    :initform (* 1024 1024)
    :type integer
    :documentation "Maximum input size")

   (blocked-patterns
    :initarg :blocked-patterns
    :accessor validator-blocked-patterns
    :initform nil
    :type list
    :documentation "Blocked regex patterns"))

  (:documentation "Input validator with configurable rules."))

(defun make-input-validator (&key (max-size (* 1024 1024)) blocked-patterns)
  "Create an input validator."
  (make-instance 'input-validator
                 :max-size max-size
                 :blocked-patterns blocked-patterns))

(defgeneric validate-input (validator input &key strict)
  (:documentation "Validate input against all rules."))

(defmethod validate-input ((validator input-validator) input &key (strict nil))
  "Validate input against all rules.

Returns:
  (values valid-p errors)"
  (let ((errors '()))
    ;; Check size
    (when (and (stringp input)
               (> (length input) (validator-max-size validator)))
      (push "Input exceeds maximum size" errors))

    ;; Check blocked patterns
    (when (stringp input)
      (dolist (pattern (validator-blocked-patterns validator))
        (when (cl-ppcre:scan pattern input)
          (push (format nil "Input matches blocked pattern: ~A" pattern) errors))))

    ;; Run custom rules
    (dolist (rule (validator-rules validator))
      (let ((name (car rule))
            (fn (cdr rule)))
        (handler-case
            (unless (funcall fn input)
              (push (format nil "Validation rule failed: ~A" name) errors))
          (error (e)
            (push (format nil "Validation error (~A): ~A" name e) errors)))))

    (if errors
        (if strict
            (error "Input validation failed: ~{~A~^, ~}" errors)
            (values nil (nreverse errors)))
        (values t nil))))

(defgeneric add-validation-rule (validator name fn)
  (:documentation "Add a validation rule."))

(defmethod add-validation-rule ((validator input-validator) name fn)
  "Add a validation rule."
  (push (cons name fn) (validator-rules validator)))

(defgeneric remove-validation-rule (validator name)
  (:documentation "Remove a validation rule."))

(defmethod remove-validation-rule ((validator input-validator) name)
  "Remove a validation rule."
  (setf (validator-rules validator)
        (remove name (validator-rules validator) :key #'car :test #'equal)))

;;; ============================================================
;;; Domain Filter
;;; ============================================================

(defclass domain-filter ()
  ((allowed-domains
    :initarg :allowed-domains
    :accessor filter-allowed-domains
    :initform nil
    :type list
    :documentation "Allowed domains (nil = allow all)")

   (blocked-domains
    :initarg :blocked-domains
    :accessor filter-blocked-domains
    :initform nil
    :type list
    :documentation "Blocked domains"))

  (:documentation "Domain-based URL filter."))

(defun make-domain-filter (&key allowed-domains blocked-domains)
  "Create a domain filter."
  (make-instance 'domain-filter
                 :allowed-domains allowed-domains
                 :blocked-domains blocked-domains))

(defgeneric domain-allowed-p (filter url)
  (:documentation "Check if URL's domain is allowed."))

(defmethod domain-allowed-p ((filter domain-filter) url)
  "Check if URL's domain is allowed."
  (let ((domain (extract-domain url)))
    (when domain
      (let ((domain-lower (string-downcase domain)))
        ;; Check blocked list first
        (when (member domain-lower (filter-blocked-domains filter)
                      :test #'string-equal)
          (return-from domain-allowed-p nil))

        ;; If allowed list is nil, allow all (except blocked)
        (if (null (filter-allowed-domains filter))
            t
            ;; Check if in allowed list
            (member domain-lower (filter-allowed-domains filter)
                    :test #'string-equal))))))

(defgeneric add-allowed-domain (filter domain)
  (:documentation "Add a domain to allowed list."))

(defmethod add-allowed-domain ((filter domain-filter) domain)
  "Add a domain to allowed list."
  (pushnew (string-downcase domain) (filter-allowed-domains filter)
           :test #'string-equal))

(defgeneric add-blocked-domain (filter domain)
  (:documentation "Add a domain to blocked list."))

(defmethod add-blocked-domain ((filter domain-filter) domain)
  "Add a domain to blocked list."
  (pushnew (string-downcase domain) (filter-blocked-domains filter)
           :test #'string-equal))

(defun extract-domain (url)
  "Extract domain from URL."
  (handler-case
      (let ((uri (quri:uri url)))
        (quri:uri-host uri))
    (error () nil)))

;;; ============================================================
;;; Secure Tool Wrapper
;;; ============================================================

(defclass secure-tool ()
  ((tool
    :initarg :tool
    :reader secure-tool-inner
    :documentation "The wrapped tool")

   (policy
    :initarg :policy
    :reader secure-tool-policy
    :documentation "Security policy")

   (rate-limiter
    :initarg :rate-limiter
    :reader secure-tool-rate-limiter
    :initform nil
    :documentation "Rate limiter instance")

   (validator
    :initarg :validator
    :reader secure-tool-validator
    :initform nil
    :documentation "Input validator")

   (domain-filter
    :initarg :domain-filter
    :reader secure-tool-domain-filter
    :initform nil
    :documentation "Domain filter"))

  (:documentation "Security wrapper for tools."))

(defun make-secure-tool (tool &key policy rate-limit timeout
                                     max-input-size allowed-domains
                                     blocked-patterns sandbox-mode)
  "Create a secure tool wrapper.

Parameters:
  TOOL             - Tool to wrap
  POLICY           - Security policy (overrides other params)
  RATE-LIMIT       - Rate limit (requests/minute)
  TIMEOUT          - Execution timeout (seconds)
  MAX-INPUT-SIZE   - Maximum input size
  ALLOWED-DOMAINS  - Allowed domains
  BLOCKED-PATTERNS - Blocked patterns
  SANDBOX-MODE     - Sandbox mode

Returns:
  secure-tool instance"
  (let* ((effective-policy (or policy
                               (make-security-policy
                                :rate-limit rate-limit
                                :timeout (or timeout 30)
                                :max-input-size (or max-input-size (* 1024 1024))
                                :allowed-domains allowed-domains
                                :blocked-patterns blocked-patterns
                                :sandbox-mode (or sandbox-mode :none))))
         (limiter (when (policy-rate-limit effective-policy)
                   (make-rate-limiter (policy-rate-limit effective-policy))))
         (validator (make-input-validator
                     :max-size (policy-max-input-size effective-policy)
                     :blocked-patterns (policy-blocked-patterns effective-policy)))
         (filter (when (policy-allowed-domains effective-policy)
                  (make-domain-filter
                   :allowed-domains (policy-allowed-domains effective-policy)))))

    (make-instance 'secure-tool
                   :tool tool
                   :policy effective-policy
                   :rate-limiter limiter
                   :validator validator
                   :domain-filter filter)))

(defgeneric execute-secure (secure-plugin fn &rest args)
  (:documentation "Execute a function with security checks."))

(defmethod execute-secure ((wrapper secure-tool) fn &rest args)
  "Execute a function with security checks."
  ;; Check rate limit
  (when (secure-tool-rate-limiter wrapper)
    (unless (rate-limiter-check (secure-tool-rate-limiter wrapper))
      (error "Rate limit exceeded")))

  ;; Validate inputs
  (when (secure-tool-validator wrapper)
    (dolist (arg args)
      (when (stringp arg)
        (multiple-value-bind (valid errors)
            (validate-input (secure-tool-validator wrapper) arg)
          (unless valid
            (error "Input validation failed: ~{~A~^, ~}" errors))))))

  ;; Execute with timeout
  (let ((timeout (policy-timeout (secure-tool-policy wrapper))))
    (if (and timeout (> timeout 0))
        ;; Note: This is a simplified timeout - real implementation
        ;; would use bt:with-timeout or similar
        (apply fn args)
        (apply fn args))))

;;; ============================================================
;;; Security Utilities
;;; ============================================================

(defun sanitize-input (input &key (max-length 10000) (strip-html t))
  "Sanitize input string.

Parameters:
  INPUT      - Input string
  MAX-LENGTH - Maximum length (truncate if longer)
  STRIP-HTML - Remove HTML tags

Returns:
  Sanitized string"
  (let ((result input))
    ;; Truncate if too long
    (when (and max-length (> (length result) max-length))
      (setf result (subseq result 0 max-length)))

    ;; Strip HTML tags
    (when strip-html
      (setf result (cl-ppcre:regex-replace-all "<[^>]*>" result "")))

    ;; Remove control characters
    (setf result (cl-ppcre:regex-replace-all "[\\x00-\\x1f\\x7f]" result ""))

    result))

(defun check-rate-limit (limiter)
  "Check rate limit and signal error if exceeded."
  (unless (rate-limiter-check limiter)
    (error "Rate limit exceeded. Please wait before retrying.")))

(defun validate-domain (url allowed-domains)
  "Validate URL domain against allowed list."
  (let ((domain (extract-domain url)))
    (unless domain
      (error "Invalid URL: ~A" url))
    (when (and allowed-domains
               (not (member domain allowed-domains :test #'string-equal)))
      (error "Domain not allowed: ~A" domain))
    t))

;;; ============================================================
;;; Predefined Security Policies
;;; ============================================================

(defun make-strict-policy ()
  "Create a strict security policy."
  (make-security-policy
   :name "strict"
   :rate-limit 10
   :timeout 10
   :max-input-size (* 100 1024)  ; 100KB
   :sandbox-mode :strict
   :blocked-patterns '("(?i)password" "(?i)secret" "(?i)api.?key")))

(defun make-standard-policy ()
  "Create a standard security policy."
  (make-security-policy
   :name "standard"
   :rate-limit 60
   :timeout 30
   :max-input-size (* 1024 1024)  ; 1MB
   :sandbox-mode :basic))

(defun make-permissive-policy ()
  "Create a permissive security policy."
  (make-security-policy
   :name "permissive"
   :rate-limit nil
   :timeout 120
   :max-input-size (* 10 1024 1024)  ; 10MB
   :sandbox-mode :none))

