;;;; kernel-usage.lisp
;;;; CL-Agent Examples - Kernel Framework Usage
;;;;
;;;; This example demonstrates direct usage of the Kernel framework,
;;;; including tool definition, kernel building, and chat invocation.

(in-package #:cl-user)

;;; ============================================================
;;; Setup
;;; ============================================================

(defpackage #:cl-agent.examples.kernel
  (:use #:cl)
  (:export #:run-kernel-examples))

(in-package #:cl-agent.examples.kernel)

;;; ============================================================
;;; Example 1: Basic Kernel Setup
;;; ============================================================

(defun example-basic-kernel ()
  "Demonstrate basic kernel creation and chat."
  (format t "~%=== Example 1: Basic Kernel ===~%")

  ;; Create a provider (using mock for demo)
  (let* ((provider (cl-agent.llm.providers:make-mock-provider))
         (kernel (cl-agent.kernel:make-kernel :provider provider)))

    ;; Simple chat
    (format t "Chat result: ~A~%"
            (cl-agent.kernel:kernel-chat kernel "Hello, world!"))))

;;; ============================================================
;;; Example 2: Kernel with Custom Tools
;;; ============================================================

(defun example-kernel-with-tools ()
  "Demonstrate kernel with custom tool functions."
  (format t "~%=== Example 2: Kernel with Tools ===~%")

  (let* ((provider (cl-agent.llm.providers:make-mock-provider))
         (kernel (cl-agent.kernel:make-kernel :provider provider)))

    ;; Add a simple tool
    (cl-agent.kernel:kernel-add-function kernel
      :get-current-time
      (lambda ()
        (multiple-value-bind (sec min hour day month year)
            (get-decoded-time)
          (format nil "~4,'0D-~2,'0D-~2,'0D ~2,'0D:~2,'0D:~2,'0D"
                  year month day hour min sec)))
      :description "Get current date and time")

    ;; Add a tool with parameters
    (cl-agent.kernel:kernel-add-function kernel
      :calculate
      (lambda (operation a b)
        (let ((num-a (if (numberp a) a (parse-integer a)))
              (num-b (if (numberp b) b (parse-integer b))))
          (case (intern (string-upcase operation) :keyword)
            (:add (+ num-a num-b))
            (:subtract (- num-a num-b))
            (:multiply (* num-a num-b))
            (:divide (/ num-a num-b))
            (otherwise (error "Unknown operation: ~A" operation)))))
      :description "Perform arithmetic calculation"
      :parameters '((:name "operation" :type "string" :description "Operation: add, subtract, multiply, divide")
                    (:name "a" :type "number" :description "First operand")
                    (:name "b" :type "number" :description "Second operand")))

    ;; List available functions
    (format t "Available functions:~%")
    (dolist (func (cl-agent.kernel:kernel-get-functions kernel))
      (format t "  - ~A: ~A~%"
              (cl-agent.kernel:kernel-function-name func)
              (cl-agent.kernel:kernel-function-description func)))

    ;; Test tool execution
    (format t "~%Direct tool test (calculate 3 + 5): ~A~%"
            (funcall (cl-agent.kernel:kernel-function-handler
                      (cl-agent.kernel:kernel-get-function kernel :calculate))
                     "add" 3 5))))

;;; ============================================================
;;; Example 3: Kernel Builder Pattern
;;; ============================================================

(defun example-kernel-builder ()
  "Demonstrate fluent builder pattern for kernel creation."
  (format t "~%=== Example 3: Kernel Builder ===~%")

  (let* ((provider (cl-agent.llm.providers:make-mock-provider))
         ;; Use builder pattern
         (kernel (cl-agent.kernel:kernel-builder provider
                   :name "my-kernel"
                   :with-functions
                   (list
                     (cons :echo (lambda (text) text))
                     (cons :greet (lambda (name) (format nil "Hello, ~A!" name)))))))

    (format t "Kernel created: ~A~%"
            (cl-agent.kernel:kernel-name kernel))
    (format t "Functions: ~{~A~^, ~}~%"
            (mapcar #'cl-agent.kernel:kernel-function-name
                    (cl-agent.kernel:kernel-get-functions kernel)))))

;;; ============================================================
;;; Example 4: Using Context
;;; ============================================================

(defun example-kernel-context ()
  "Demonstrate context management in kernel."
  (format t "~%=== Example 4: Context Management ===~%")

  (let* ((provider (cl-agent.llm.providers:make-mock-provider))
         (kernel (cl-agent.kernel:make-kernel :provider provider))
         (context (cl-agent.kernel:make-context)))

    ;; Store variables in context
    (cl-agent.kernel:context-set-variable context :user-name "Alice")
    (cl-agent.kernel:context-set-variable context :preferences
                                          '(:theme :dark :language :en))

    ;; Retrieve variables
    (format t "User: ~A~%"
            (cl-agent.kernel:context-get-variable context :user-name))
    (format t "Preferences: ~A~%"
            (cl-agent.kernel:context-get-variable context :preferences))

    ;; Add message to history
    (cl-agent.kernel:context-add-message context
      (cl-agent.core:make-message :role :user :content "Hello!"))
    (cl-agent.kernel:context-add-message context
      (cl-agent.core:make-message :role :assistant :content "Hi there!"))

    (format t "History length: ~A~%"
            (length (cl-agent.kernel:context-history context)))))

;;; ============================================================
;;; Example 5: Invoke API (3-tier)
;;; ============================================================

(defun example-invoke-api ()
  "Demonstrate the 3-tier invoke API."
  (format t "~%=== Example 5: 3-Tier Invoke API ===~%")

  (let* ((provider (cl-agent.llm.providers:make-mock-provider))
         (kernel (cl-agent.kernel:make-kernel :provider provider)))

    ;; Tier 1: Simple invoke (string -> string)
    (format t "Tier 1 (simple): ~A~%"
            (cl-agent.kernel:kernel-invoke kernel "What is 2+2?"))

    ;; Tier 2: With options
    (format t "Tier 2 (with options): ~A~%"
            (cl-agent.kernel:kernel-invoke kernel "Explain quantum computing"
              :max-tokens 100
              :temperature 0.7))

    ;; Tier 3: Full control with context
    (let ((context (cl-agent.kernel:make-context)))
      (cl-agent.kernel:context-set-variable context :mode :technical)
      (format t "Tier 3 (with context): ~A~%"
              (cl-agent.kernel:kernel-invoke-with-context kernel context
                "Summarize the conversation")))))

;;; ============================================================
;;; Run All Examples
;;; ============================================================

(defun run-kernel-examples ()
  "Run all kernel examples."
  (format t "~%========================================~%")
  (format t "CL-Agent Kernel Examples~%")
  (format t "========================================~%")

  (handler-case
      (progn
        (example-basic-kernel)
        (example-kernel-with-tools)
        (example-kernel-builder)
        (example-kernel-context)
        (example-invoke-api))
    (error (e)
      (format t "~%Error: ~A~%" e)))

  (format t "~%========================================~%")
  (format t "Examples Complete~%")
  (format t "========================================~%"))
