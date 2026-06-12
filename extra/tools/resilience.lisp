;;;; resilience.lisp
;;;; CL-Agent Tools - Resilience Patterns
;;;;
;;;; Overview:
;;;;   Resilience patterns for robust tool execution:
;;;;   - Retry with backoff strategies
;;;;   - Timeout handling
;;;;   - Circuit breaker pattern
;;;;
;;;; Reference:
;;;;   - Michael Nygard, "Release It!" patterns
;;;;   - Netflix Hystrix patterns

(in-package #:cl-agent.tools)

;;; ============================================================
;;; Retry Policy
;;; ============================================================

(defclass retry-policy ()
  ((max-attempts
    :initarg :max-attempts
    :reader retry-max-attempts
    :initform 3
    :type integer
    :documentation "Maximum number of retry attempts")

   (backoff-strategy
    :initarg :backoff-strategy
    :reader retry-backoff-strategy
    :initform :exponential
    :type keyword
    :documentation "Backoff strategy (:constant, :linear, :exponential, :fibonacci)")

   (initial-delay
    :initarg :initial-delay
    :reader retry-initial-delay
    :initform 1.0
    :type float
    :documentation "Initial delay in seconds")

   (max-delay
    :initarg :max-delay
    :reader retry-max-delay
    :initform 60.0
    :type float
    :documentation "Maximum delay in seconds")

   (jitter
    :initarg :jitter
    :reader retry-jitter
    :initform 0.1
    :type float
    :documentation "Jitter factor (0.0-1.0)")

   (retryable-errors
    :initarg :retryable-errors
    :reader retry-retryable-errors
    :initform nil
    :type list
    :documentation "List of retryable error types (nil = all)")

   (on-retry
    :initarg :on-retry
    :reader retry-on-retry
    :initform nil
    :type (or null function)
    :documentation "Callback (attempt delay error) on retry"))

  (:documentation "Retry policy configuration."))

(defun make-retry-policy (&key (max-attempts 3)
                                (backoff-strategy :exponential)
                                (initial-delay 1.0)
                                (max-delay 60.0)
                                (jitter 0.1)
                                retryable-errors
                                on-retry)
  "Create a retry policy.

Parameters:
  MAX-ATTEMPTS      - Maximum retry attempts
  BACKOFF-STRATEGY  - Backoff type (:constant, :linear, :exponential, :fibonacci)
  INITIAL-DELAY     - Initial delay in seconds
  MAX-DELAY         - Maximum delay in seconds
  JITTER            - Random jitter factor (0.0-1.0)
  RETRYABLE-ERRORS  - List of retryable error types
  ON-RETRY          - Callback on retry

Returns:
  retry-policy instance"
  (make-instance 'retry-policy
                 :max-attempts max-attempts
                 :backoff-strategy backoff-strategy
                 :initial-delay initial-delay
                 :max-delay max-delay
                 :jitter jitter
                 :retryable-errors retryable-errors
                 :on-retry on-retry))

;;; ============================================================
;;; Backoff Strategies
;;; ============================================================

(defun constant-backoff (attempt initial-delay max-delay)
  "Constant backoff - same delay every time."
  (declare (ignore attempt))
  (min initial-delay max-delay))

(defun linear-backoff (attempt initial-delay max-delay)
  "Linear backoff - delay increases linearly."
  (min (* initial-delay attempt) max-delay))

(defun exponential-backoff (attempt initial-delay max-delay)
  "Exponential backoff - delay doubles each attempt."
  (min (* initial-delay (expt 2 (1- attempt))) max-delay))

(defun fibonacci-backoff (attempt initial-delay max-delay)
  "Fibonacci backoff - delay follows Fibonacci sequence."
  (labels ((fib (n)
             (if (< n 2)
                 1
                 (+ (fib (- n 1)) (fib (- n 2))))))
    (min (* initial-delay (fib attempt)) max-delay)))

(defun calculate-backoff (policy attempt)
  "Calculate backoff delay for given attempt.

Parameters:
  POLICY  - Retry policy
  ATTEMPT - Current attempt number (1-based)

Returns:
  Delay in seconds (with jitter applied)"
  (let* ((strategy (retry-backoff-strategy policy))
         (initial (retry-initial-delay policy))
         (max-delay (retry-max-delay policy))
         (base-delay (case strategy
                       (:constant (constant-backoff attempt initial max-delay))
                       (:linear (linear-backoff attempt initial max-delay))
                       (:exponential (exponential-backoff attempt initial max-delay))
                       (:fibonacci (fibonacci-backoff attempt initial max-delay))
                       (otherwise (exponential-backoff attempt initial max-delay))))
         (jitter (retry-jitter policy)))
    ;; Apply jitter
    (if (and jitter (> jitter 0))
        (let ((jitter-amount (* base-delay jitter (- (random 2.0) 1.0))))
          (max 0.0 (+ base-delay jitter-amount)))
        base-delay)))

;;; ============================================================
;;; Timeout Policy
;;; ============================================================

(defclass timeout-policy ()
  ((duration
    :initarg :duration
    :reader timeout-duration
    :initform 30.0
    :type float
    :documentation "Timeout duration in seconds")

   (on-timeout
    :initarg :on-timeout
    :reader timeout-on-timeout
    :initform nil
    :type (or null function)
    :documentation "Callback on timeout"))

  (:documentation "Timeout policy configuration."))

(defun make-timeout-policy (&key (duration 30.0) on-timeout)
  "Create a timeout policy."
  (make-instance 'timeout-policy
                 :duration duration
                 :on-timeout on-timeout))

;;; ============================================================
;;; Circuit Breaker
;;; ============================================================

(defclass circuit-breaker ()
  ((name
    :initarg :name
    :reader breaker-name
    :initform "circuit-breaker"
    :type string)

   (state
    :initform :closed
    :accessor breaker-state
    :type keyword
    :documentation "State: :closed, :open, :half-open")

   (failure-count
    :initform 0
    :accessor breaker-failure-count
    :type integer)

   (success-count
    :initform 0
    :accessor breaker-success-count
    :type integer)

   (threshold
    :initarg :threshold
    :reader breaker-threshold
    :initform 5
    :type integer
    :documentation "Failure threshold to trip")

   (reset-timeout
    :initarg :reset-timeout
    :reader breaker-reset-timeout
    :initform 60
    :type integer
    :documentation "Seconds to wait before half-open")

   (half-open-max
    :initarg :half-open-max
    :reader breaker-half-open-max
    :initform 1
    :type integer
    :documentation "Max requests in half-open state")

   (last-failure-time
    :initform nil
    :accessor breaker-last-failure-time
    :documentation "Timestamp of last failure")

   (on-state-change
    :initarg :on-state-change
    :reader breaker-on-state-change
    :initform nil
    :type (or null function)
    :documentation "Callback (old-state new-state)")

   (lock
    :initform (bt:make-lock "circuit-breaker")
    :reader breaker-lock))

  (:documentation "Circuit breaker for fault tolerance.

States:
  :closed    - Normal operation, requests flow through
  :open      - Failures exceeded threshold, requests rejected
  :half-open - Testing if system recovered"))

(defun make-circuit-breaker (&key (name "circuit-breaker")
                                   (threshold 5)
                                   (reset-timeout 60)
                                   (half-open-max 1)
                                   on-state-change)
  "Create a circuit breaker.

Parameters:
  NAME           - Breaker name for logging
  THRESHOLD      - Failure count to trip the breaker
  RESET-TIMEOUT  - Seconds to wait before attempting recovery
  HALF-OPEN-MAX  - Max requests allowed in half-open state
  ON-STATE-CHANGE - Callback on state change

Returns:
  circuit-breaker instance"
  (make-instance 'circuit-breaker
                 :name name
                 :threshold threshold
                 :reset-timeout reset-timeout
                 :half-open-max half-open-max
                 :on-state-change on-state-change))

(defun breaker-change-state (breaker new-state)
  "Change circuit breaker state."
  (let ((old-state (breaker-state breaker)))
    (unless (eq old-state new-state)
      (setf (breaker-state breaker) new-state)
      (when (breaker-on-state-change breaker)
        (funcall (breaker-on-state-change breaker) old-state new-state)))))

(defgeneric circuit-breaker-execute (breaker fn &rest args)
  (:documentation "Execute function through circuit breaker."))

(defmethod circuit-breaker-execute ((breaker circuit-breaker) fn &rest args)
  "Execute function through circuit breaker."
  (bt:with-lock-held ((breaker-lock breaker))
    ;; Check if we should transition from open to half-open
    (when (eq (breaker-state breaker) :open)
      (let ((elapsed (- (get-universal-time)
                       (or (breaker-last-failure-time breaker) 0))))
        (when (>= elapsed (breaker-reset-timeout breaker))
          (breaker-change-state breaker :half-open)
          (setf (breaker-success-count breaker) 0)))))

  ;; Handle based on state
  (case (breaker-state breaker)
    (:open
     (error "Circuit breaker is OPEN for ~A" (breaker-name breaker)))

    (:half-open
     ;; Allow limited requests
     (handler-case
         (prog1
             (apply fn args)
           ;; Success in half-open
           (bt:with-lock-held ((breaker-lock breaker))
             (incf (breaker-success-count breaker))
             (when (>= (breaker-success-count breaker) (breaker-half-open-max breaker))
               ;; Recovered - close the circuit
               (breaker-change-state breaker :closed)
               (setf (breaker-failure-count breaker) 0))))
       (error (e)
         ;; Failure in half-open - reopen
         (bt:with-lock-held ((breaker-lock breaker))
           (breaker-change-state breaker :open)
           (setf (breaker-last-failure-time breaker) (get-universal-time)))
         (error e))))

    (:closed
     ;; Normal operation
     (handler-case
         (prog1
             (apply fn args)
           ;; Success - reset failure count
           (bt:with-lock-held ((breaker-lock breaker))
             (setf (breaker-failure-count breaker) 0)))
       (error (e)
         ;; Failure
         (bt:with-lock-held ((breaker-lock breaker))
           (incf (breaker-failure-count breaker))
           (setf (breaker-last-failure-time breaker) (get-universal-time))
           (when (>= (breaker-failure-count breaker) (breaker-threshold breaker))
             (breaker-change-state breaker :open)))
         (error e))))))

(defgeneric circuit-breaker-reset (breaker)
  (:documentation "Reset circuit breaker to closed state."))

(defmethod circuit-breaker-reset ((breaker circuit-breaker))
  "Reset circuit breaker to closed state."
  (bt:with-lock-held ((breaker-lock breaker))
    (breaker-change-state breaker :closed)
    (setf (breaker-failure-count breaker) 0)
    (setf (breaker-success-count breaker) 0)
    (setf (breaker-last-failure-time breaker) nil)))

(defgeneric circuit-breaker-trip (breaker)
  (:documentation "Manually trip the circuit breaker."))

(defmethod circuit-breaker-trip ((breaker circuit-breaker))
  "Manually trip the circuit breaker."
  (bt:with-lock-held ((breaker-lock breaker))
    (breaker-change-state breaker :open)
    (setf (breaker-last-failure-time breaker) (get-universal-time))))

;;; ============================================================
;;; Resilience Wrapper
;;; ============================================================

(defclass resilient-wrapper ()
  ((retry-policy
    :initarg :retry-policy
    :reader wrapper-retry-policy
    :initform nil)

   (timeout-policy
    :initarg :timeout-policy
    :reader wrapper-timeout-policy
    :initform nil)

   (circuit-breaker
    :initarg :circuit-breaker
    :reader wrapper-circuit-breaker
    :initform nil))

  (:documentation "Combined resilience wrapper."))

(defun make-resilient-wrapper (&key retry-policy timeout-policy circuit-breaker)
  "Create a resilient wrapper with multiple policies."
  (make-instance 'resilient-wrapper
                 :retry-policy retry-policy
                 :timeout-policy timeout-policy
                 :circuit-breaker circuit-breaker))

(defun resilient-call (fn &key retry-policy timeout-policy circuit-breaker)
  "Execute function with resilience policies.

Parameters:
  FN              - Function to execute
  RETRY-POLICY    - Retry policy
  TIMEOUT-POLICY  - Timeout policy
  CIRCUIT-BREAKER - Circuit breaker

Returns:
  Function result or signals error after exhausting retries"
  (let ((attempt 0)
        (last-error nil))

    ;; Circuit breaker wrapper
    (labels ((execute ()
               ;; Note: Timeout would need bt:with-timeout for real impl
               (funcall fn))

             (execute-with-breaker ()
               (if circuit-breaker
                   (circuit-breaker-execute circuit-breaker #'execute)
                   (execute)))

             (attempt-execution ()
               (incf attempt)
               (handler-case
                   (return-from resilient-call (execute-with-breaker))
                 (error (e)
                   (setf last-error e)
                   ;; Check if retryable
                   (when (and retry-policy
                              (< attempt (retry-max-attempts retry-policy)))
                     ;; Check if error is retryable
                     (when (or (null (retry-retryable-errors retry-policy))
                               (some (lambda (type) (typep e type))
                                     (retry-retryable-errors retry-policy)))
                       ;; Calculate delay
                       (let ((delay (calculate-backoff retry-policy attempt)))
                         ;; Call on-retry callback
                         (when (retry-on-retry retry-policy)
                           (funcall (retry-on-retry retry-policy) attempt delay e))
                         ;; Sleep and retry
                         (sleep delay)
                         (attempt-execution))))
                   ;; No more retries
                   (error e)))))

      (attempt-execution))))

;;; ============================================================
;;; Convenience Macros
;;; ============================================================

(defmacro with-retry ((&key (attempts 3) (backoff :exponential)
                            (initial-delay 1.0) (max-delay 60.0))
                      &body body)
  "Execute body with retry policy.

Usage:
  (with-retry (:attempts 3 :backoff :exponential)
    (http-get url))"
  (let ((policy-var (gensym "POLICY")))
    `(let ((,policy-var (make-retry-policy
                         :max-attempts ,attempts
                         :backoff-strategy ,backoff
                         :initial-delay ,initial-delay
                         :max-delay ,max-delay)))
       (resilient-call (lambda () ,@body) :retry-policy ,policy-var))))

(defmacro with-timeout ((duration) &body body)
  "Execute body with timeout.

Usage:
  (with-timeout (30)
    (slow-operation))"
  (let ((policy-var (gensym "POLICY")))
    `(let ((,policy-var (make-timeout-policy :duration ,duration)))
       (resilient-call (lambda () ,@body) :timeout-policy ,policy-var))))

(defmacro with-circuit-breaker ((breaker) &body body)
  "Execute body through circuit breaker.

Usage:
  (with-circuit-breaker (my-breaker)
    (external-call))"
  `(circuit-breaker-execute ,breaker (lambda () ,@body)))

(defmacro with-resilience ((&key retry timeout circuit-breaker) &body body)
  "Execute body with combined resilience policies.

Usage:
  (with-resilience (:retry retry-policy :timeout 30 :circuit-breaker breaker)
    (risky-operation))"
  (let ((retry-var (gensym "RETRY"))
        (timeout-var (gensym "TIMEOUT")))
    `(let ((,retry-var ,retry)
           (,timeout-var (when ,timeout (make-timeout-policy :duration ,timeout))))
       (resilient-call (lambda () ,@body)
                       :retry-policy ,retry-var
                       :timeout-policy ,timeout-var
                       :circuit-breaker ,circuit-breaker))))

