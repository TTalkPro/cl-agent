;;;; human-loop.lisp
;;;; CL-Agent Core - Human-in-the-Loop Support
;;;;
;;;; Provides mechanisms for human input, approval, and intervention
;;;; during process execution.

(in-package #:cl-agent.process)

;;; ============================================================
;;; Input Types
;;; ============================================================

(defconstant +input-type-text+ :text
  "Free-form text input.")

(defconstant +input-type-confirmation+ :confirmation
  "Yes/No confirmation.")

(defconstant +input-type-choice+ :choice
  "Selection from options.")

(defconstant +input-type-approval+ :approval
  "Approval with optional comment.")

(defconstant +input-type-form+ :form
  "Structured form input.")

;;; ============================================================
;;; Input Request
;;; ============================================================

(defclass input-request ()
  ((id
    :initarg :id
    :initform (generate-request-id)
    :reader input-request-id
    :documentation "Unique request identifier")

   (type
    :initarg :type
    :initform +input-type-text+
    :accessor input-request-type
    :documentation "Input type")

   (prompt
    :initarg :prompt
    :initform "Please provide input"
    :accessor input-request-prompt
    :documentation "Prompt message to display")

   (description
    :initarg :description
    :initform nil
    :accessor input-request-description
    :documentation "Detailed description")

   (schema
    :initarg :schema
    :initform nil
    :accessor input-request-schema
    :documentation "Input validation schema or options")

   (timeout
    :initarg :timeout
    :initform nil
    :accessor input-request-timeout
    :documentation "Timeout in seconds")

   (default
    :initarg :default
    :initform nil
    :accessor input-request-default
    :documentation "Default value if timeout")

   (required
    :initarg :required
    :initform t
    :accessor input-request-required
    :documentation "Whether input is required")

   (context-data
    :initarg :context-data
    :initform nil
    :accessor input-request-context-data
    :documentation "Context data for the request")

   (created-at
    :initform (get-universal-time)
    :reader input-request-created-at
    :documentation "Creation timestamp")

   (metadata
    :initarg :metadata
    :initform nil
    :accessor input-request-metadata
    :documentation "Additional metadata"))

  (:documentation "Request for human input."))

(defun generate-request-id ()
  "Generate unique request ID."
  (format nil "req-~A-~A"
          (get-universal-time)
          (random 100000)))

(defun make-input-request (&key type prompt description schema
                                timeout default required context-data metadata)
  "Create an input request.

Parameters:
  TYPE         - Input type
  PROMPT       - Prompt message
  DESCRIPTION  - Detailed description
  SCHEMA       - Validation schema or options
  TIMEOUT      - Timeout in seconds
  DEFAULT      - Default value
  REQUIRED     - Whether required
  CONTEXT-DATA - Context data
  METADATA     - Additional metadata

Returns:
  New input-request instance"
  (make-instance 'input-request
                 :type (or type +input-type-text+)
                 :prompt (or prompt "Please provide input")
                 :description description
                 :schema schema
                 :timeout timeout
                 :default default
                 :required (if (null required) t required)
                 :context-data context-data
                 :metadata metadata))

(defmethod print-object ((request input-request) stream)
  (print-unreadable-object (request stream :type t)
    (format stream "~A ~A" (input-request-type request) (input-request-id request))))

;; Convenience constructors
(defun request-text (prompt &key description timeout default required metadata)
  "Create a text input request."
  (make-input-request :type +input-type-text+
                      :prompt prompt
                      :description description
                      :timeout timeout
                      :default default
                      :required required
                      :metadata metadata))

(defun request-confirmation (prompt &key description timeout default metadata)
  "Create a confirmation request."
  (make-input-request :type +input-type-confirmation+
                      :prompt prompt
                      :description description
                      :timeout timeout
                      :default default
                      :metadata metadata))

(defun request-choice (prompt options &key description timeout default metadata)
  "Create a choice selection request."
  (make-input-request :type +input-type-choice+
                      :prompt prompt
                      :description description
                      :schema options
                      :timeout timeout
                      :default default
                      :metadata metadata))

(defun request-approval (prompt &key description context-data timeout metadata)
  "Create an approval request."
  (make-input-request :type +input-type-approval+
                      :prompt prompt
                      :description description
                      :context-data context-data
                      :timeout timeout
                      :metadata metadata))

(defun request-form (prompt schema &key description timeout default metadata)
  "Create a form input request."
  (make-input-request :type +input-type-form+
                      :prompt prompt
                      :description description
                      :schema schema
                      :timeout timeout
                      :default default
                      :metadata metadata))

;;; ============================================================
;;; Input Response
;;; ============================================================

(defclass input-response ()
  ((request-id
    :initarg :request-id
    :accessor input-response-request-id
    :documentation "Corresponding request ID")

   (value
    :initarg :value
    :initform nil
    :accessor input-response-value
    :documentation "Input value")

   (approved-p
    :initarg :approved-p
    :initform nil
    :accessor input-response-approved-p
    :documentation "Approval status (for approval requests)")

   (comment
    :initarg :comment
    :initform nil
    :accessor input-response-comment
    :documentation "Optional comment")

   (responder
    :initarg :responder
    :initform nil
    :accessor input-response-responder
    :documentation "Who provided the response")

   (timestamp
    :initform (get-universal-time)
    :reader input-response-timestamp
    :documentation "Response timestamp")

   (metadata
    :initarg :metadata
    :initform nil
    :accessor input-response-metadata
    :documentation "Additional metadata"))

  (:documentation "Response to an input request."))

(defun make-input-response (request-id &key value approved-p comment responder metadata)
  "Create an input response.

Parameters:
  REQUEST-ID - Corresponding request ID
  VALUE      - Input value
  APPROVED-P - Approval status
  COMMENT    - Optional comment
  RESPONDER  - Who provided response
  METADATA   - Additional metadata

Returns:
  New input-response instance"
  (make-instance 'input-response
                 :request-id request-id
                 :value value
                 :approved-p approved-p
                 :comment comment
                 :responder responder
                 :metadata metadata))

;;; ============================================================
;;; Human Loop Manager
;;; ============================================================

(defclass human-loop-manager ()
  ((pending-requests
    :initform (make-hash-table :test 'equal)
    :accessor hlm-pending-requests
    :documentation "Request ID -> (request . condvar) mapping")

   (responses
    :initform (make-hash-table :test 'equal)
    :accessor hlm-responses
    :documentation "Request ID -> response mapping")

   (handler
    :initarg :handler
    :initform nil
    :accessor hlm-handler
    :documentation "External handler for requests (request) -> nil")

   (lock
    :initform (make-lock "human-loop-lock")
    :reader hlm-lock
    :documentation "Thread safety lock")

   (timeout-thread
    :initform nil
    :accessor hlm-timeout-thread
    :documentation "Timeout monitoring thread")

   (on-request
    :initarg :on-request
    :initform nil
    :accessor hlm-on-request
    :documentation "Callback when request is created")

   (on-response
    :initarg :on-response
    :initform nil
    :accessor hlm-on-response
    :documentation "Callback when response is received")

   (on-timeout
    :initarg :on-timeout
    :initform nil
    :accessor hlm-on-timeout
    :documentation "Callback when request times out"))

  (:documentation "Manages human-in-the-loop interactions."))

(defun make-human-loop-manager (&key handler on-request on-response on-timeout)
  "Create a human loop manager.

Parameters:
  HANDLER     - External request handler
  ON-REQUEST  - Request callback
  ON-RESPONSE - Response callback
  ON-TIMEOUT  - Timeout callback

Returns:
  New human-loop-manager instance"
  (make-instance 'human-loop-manager
                 :handler handler
                 :on-request on-request
                 :on-response on-response
                 :on-timeout on-timeout))

(defun human-loop-set-handler (manager handler)
  "Set the external handler for requests.

Parameters:
  MANAGER - Human loop manager
  HANDLER - Handler function (request) -> nil"
  (setf (hlm-handler manager) handler))

;;; ============================================================
;;; Request Management
;;; ============================================================

(defun human-loop-request-input (manager request)
  "Request human input (blocking).

Parameters:
  MANAGER - Human loop manager
  REQUEST - Input request

Returns:
  Input response or NIL if timeout/cancelled"
  (let ((condvar (make-condition-variable :name "input-wait"))
        (request-id (input-request-id request)))

    ;; Register pending request
    (with-lock-held ((hlm-lock manager))
      (setf (gethash request-id (hlm-pending-requests manager))
            (cons request condvar)))

    ;; Notify callbacks/handlers
    (when (hlm-on-request manager)
      (funcall (hlm-on-request manager) request))

    (when (hlm-handler manager)
      (funcall (hlm-handler manager) request))

    ;; Wait for response
    (let* ((timeout (input-request-timeout request))
           (deadline (when timeout
                       (+ (get-internal-real-time)
                          (* timeout internal-time-units-per-second))))
           (response nil))

      (with-lock-held ((hlm-lock manager))
        (loop
          ;; Check for response
          (when-let ((resp (gethash request-id (hlm-responses manager))))
            (setf response resp)
            (return))

          ;; Check timeout
          (when (and deadline (>= (get-internal-real-time) deadline))
            ;; Handle timeout
            (when (hlm-on-timeout manager)
              (funcall (hlm-on-timeout manager) request))

            ;; Use default if available
            (when (input-request-default request)
              (setf response
                    (make-input-response request-id
                                         :value (input-request-default request)
                                         :metadata '(:source :timeout))))
            (return))

          ;; Wait
          (condition-wait condvar (hlm-lock manager))))

      ;; Cleanup
      (with-lock-held ((hlm-lock manager))
        (remhash request-id (hlm-pending-requests manager))
        (remhash request-id (hlm-responses manager)))

      response)))

(defun human-loop-request-input-async (manager request callback)
  "Request human input (non-blocking).

Parameters:
  MANAGER  - Human loop manager
  REQUEST  - Input request
  CALLBACK - Function (response) -> nil"
  (make-thread
   (lambda ()
     (let ((response (human-loop-request-input manager request)))
       (when callback
         (funcall callback response))))
   :name (format nil "input-wait-~A" (input-request-id request))))

(defun human-loop-submit-response (manager response)
  "Submit a response to a pending request.

Parameters:
  MANAGER  - Human loop manager
  RESPONSE - Input response

Returns:
  T if response was accepted, NIL if request not found"
  (let ((request-id (input-response-request-id response)))
    (with-lock-held ((hlm-lock manager))
      (let ((pending (gethash request-id (hlm-pending-requests manager))))
        (unless pending
          (return-from human-loop-submit-response nil))

        ;; Store response
        (setf (gethash request-id (hlm-responses manager)) response)

        ;; Wake up waiting thread
        (condition-notify (cdr pending))

        ;; Callback
        (when (hlm-on-response manager)
          (funcall (hlm-on-response manager) response))

        t))))

(defun human-loop-cancel-request (manager request-id &key reason)
  "Cancel a pending request.

Parameters:
  MANAGER    - Human loop manager
  REQUEST-ID - Request ID to cancel
  REASON     - Cancellation reason

Returns:
  T if cancelled"
  (with-lock-held ((hlm-lock manager))
    (let ((pending (gethash request-id (hlm-pending-requests manager))))
      (unless pending
        (return-from human-loop-cancel-request nil))

      ;; Store cancellation as response
      (setf (gethash request-id (hlm-responses manager))
            (make-input-response request-id
                                 :metadata (list :cancelled t :reason reason)))

      ;; Wake up waiting thread
      (condition-notify (cdr pending))

      t)))

(defun human-loop-pending-requests (manager)
  "Get list of pending requests.

Parameters:
  MANAGER - Human loop manager

Returns:
  List of input-request objects"
  (with-lock-held ((hlm-lock manager))
    (loop for (request . nil) being the hash-values of (hlm-pending-requests manager)
          collect request)))

(defun human-loop-has-pending-p (manager)
  "Check if there are pending requests.

Parameters:
  MANAGER - Human loop manager

Returns:
  T if pending requests exist"
  (with-lock-held ((hlm-lock manager))
    (> (hash-table-count (hlm-pending-requests manager)) 0)))

(defun human-loop-get-request (manager request-id)
  "Get a pending request by ID.

Parameters:
  MANAGER    - Human loop manager
  REQUEST-ID - Request ID

Returns:
  Input request or NIL"
  (with-lock-held ((hlm-lock manager))
    (let ((pending (gethash request-id (hlm-pending-requests manager))))
      (when pending (car pending)))))

;;; ============================================================
;;; Validation
;;; ============================================================

(defun validate-input-response (request response)
  "Validate response against request schema.

Parameters:
  REQUEST  - Input request
  RESPONSE - Input response

Returns:
  T if valid, or (NIL . error-message)"
  (let ((value (input-response-value response))
        (schema (input-request-schema request))
        (type (input-request-type request)))

    ;; Check required
    (when (and (input-request-required request)
               (null value))
      (return-from validate-input-response
        (values nil "Input is required")))

    ;; Type-specific validation
    (case type
      (:confirmation
       (unless (member value '(t nil :yes :no "yes" "no" "y" "n") :test 'equal)
         (return-from validate-input-response
           (values nil "Must be yes or no"))))

      (:choice
       (when (and schema (not (member value schema :test 'equal)))
         (return-from validate-input-response
           (values nil (format nil "Must be one of: ~A" schema)))))

      (:approval
       ;; Approval just needs approved-p set
       t)

      (:form
       ;; TODO: Validate against schema
       t))

    t))

;;; ============================================================
;;; Integration Helpers
;;; ============================================================

(defun wait-for-approval (manager prompt &key description context-data timeout)
  "Convenience function to wait for approval.

Parameters:
  MANAGER      - Human loop manager
  PROMPT       - Approval prompt
  DESCRIPTION  - Detailed description
  CONTEXT-DATA - Context data
  TIMEOUT      - Timeout in seconds

Returns:
  T if approved, NIL if rejected or timeout"
  (let* ((request (request-approval prompt
                                    :description description
                                    :context-data context-data
                                    :timeout timeout))
         (response (human-loop-request-input manager request)))
    (and response (input-response-approved-p response))))

(defun wait-for-confirmation (manager prompt &key timeout default)
  "Convenience function to wait for yes/no confirmation.

Parameters:
  MANAGER - Human loop manager
  PROMPT  - Confirmation prompt
  TIMEOUT - Timeout in seconds
  DEFAULT - Default value

Returns:
  T for yes, NIL for no"
  (let* ((request (request-confirmation prompt :timeout timeout :default default))
         (response (human-loop-request-input manager request)))
    (when response
      (let ((value (input-response-value response)))
        (member value '(t :yes "yes" "y") :test 'equal)))))

(defun wait-for-text (manager prompt &key timeout default)
  "Convenience function to wait for text input.

Parameters:
  MANAGER - Human loop manager
  PROMPT  - Input prompt
  TIMEOUT - Timeout in seconds
  DEFAULT - Default value

Returns:
  Input text or NIL"
  (let* ((request (request-text prompt :timeout timeout :default default))
         (response (human-loop-request-input manager request)))
    (when response
      (input-response-value response))))

(defun wait-for-choice (manager prompt options &key timeout default)
  "Convenience function to wait for choice selection.

Parameters:
  MANAGER - Human loop manager
  PROMPT  - Selection prompt
  OPTIONS - List of options
  TIMEOUT - Timeout in seconds
  DEFAULT - Default value

Returns:
  Selected option or NIL"
  (let* ((request (request-choice prompt options :timeout timeout :default default))
         (response (human-loop-request-input manager request)))
    (when response
      (input-response-value response))))
