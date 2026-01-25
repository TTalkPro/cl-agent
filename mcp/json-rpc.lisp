;;;; json-rpc.lisp
;;;; CL-Agent MCP - JSON-RPC 2.0 Implementation
;;;;
;;;; Overview:
;;;;   JSON-RPC 2.0 message encoding and decoding for MCP protocol.
;;;;
;;;; Reference:
;;;;   https://www.jsonrpc.org/specification

(in-package #:cl-agent.mcp)

;;; ============================================================
;;; Error Codes
;;; ============================================================

(defconstant +parse-error+ -32700
  "Invalid JSON was received.")

(defconstant +invalid-request+ -32600
  "The JSON sent is not a valid Request object.")

(defconstant +method-not-found+ -32601
  "The method does not exist / is not available.")

(defconstant +invalid-params+ -32602
  "Invalid method parameter(s).")

(defconstant +internal-error+ -32603
  "Internal JSON-RPC error.")

(defconstant +server-error-start+ -32099
  "Start of server error range.")

(defconstant +server-error-end+ -32000
  "End of server error range.")

;;; ============================================================
;;; Request/Response Classes
;;; ============================================================

(defclass json-rpc-request ()
  ((jsonrpc
    :initarg :jsonrpc
    :accessor rpc-jsonrpc
    :initform "2.0"
    :type string)

   (id
    :initarg :id
    :accessor rpc-id
    :type (or string integer)
    :documentation "Request ID")

   (method
    :initarg :method
    :accessor rpc-method
    :type string
    :documentation "Method name")

   (params
    :initarg :params
    :accessor rpc-params
    :initform nil
    :documentation "Method parameters"))
  (:documentation "JSON-RPC 2.0 request."))

(defclass json-rpc-response ()
  ((jsonrpc
    :initarg :jsonrpc
    :accessor rpc-jsonrpc
    :initform "2.0"
    :type string)

   (id
    :initarg :id
    :accessor rpc-id
    :type (or string integer null)
    :documentation "Response ID (matches request)")

   (result
    :initarg :result
    :accessor rpc-result
    :initform nil
    :documentation "Result value")

   (error
    :initarg :error
    :accessor rpc-error
    :initform nil
    :documentation "Error object"))
  (:documentation "JSON-RPC 2.0 response."))

(defclass json-rpc-notification ()
  ((jsonrpc
    :initarg :jsonrpc
    :accessor rpc-jsonrpc
    :initform "2.0"
    :type string)

   (method
    :initarg :method
    :accessor rpc-method
    :type string
    :documentation "Notification method")

   (params
    :initarg :params
    :accessor rpc-params
    :initform nil
    :documentation "Notification parameters"))
  (:documentation "JSON-RPC 2.0 notification (no ID, no response)."))

(defclass json-rpc-error ()
  ((code
    :initarg :code
    :accessor rpc-error-code
    :type integer
    :documentation "Error code")

   (message
    :initarg :message
    :accessor rpc-error-message
    :type string
    :documentation "Error message")

   (data
    :initarg :data
    :accessor rpc-error-data
    :initform nil
    :documentation "Additional error data"))
  (:documentation "JSON-RPC 2.0 error object."))

;;; ============================================================
;;; Constructors
;;; ============================================================

(defvar *rpc-id-counter* 0
  "Counter for generating request IDs.")

(defvar *rpc-id-lock* (bt:make-lock "rpc-id-lock")
  "Lock for ID counter.")

(defun generate-rpc-id ()
  "Generate a unique request ID."
  (bt:with-lock-held (*rpc-id-lock*)
    (incf *rpc-id-counter*)))

(defun make-rpc-request (method &key params id)
  "Create a JSON-RPC request.

Parameters:
  METHOD - Method name
  PARAMS - Method parameters (optional)
  ID     - Request ID (optional, auto-generated)

Returns:
  json-rpc-request instance"
  (make-instance 'json-rpc-request
                 :id (or id (generate-rpc-id))
                 :method method
                 :params params))

(defun make-rpc-response (id result)
  "Create a JSON-RPC success response.

Parameters:
  ID     - Request ID
  RESULT - Result value

Returns:
  json-rpc-response instance"
  (make-instance 'json-rpc-response
                 :id id
                 :result result))

(defun make-rpc-error (id code message &optional data)
  "Create a JSON-RPC error response.

Parameters:
  ID      - Request ID
  CODE    - Error code
  MESSAGE - Error message
  DATA    - Additional error data (optional)

Returns:
  json-rpc-response with error"
  (make-instance 'json-rpc-response
                 :id id
                 :error (make-instance 'json-rpc-error
                                       :code code
                                       :message message
                                       :data data)))

(defun make-rpc-notification (method &key params)
  "Create a JSON-RPC notification.

Parameters:
  METHOD - Notification method
  PARAMS - Method parameters (optional)

Returns:
  json-rpc-notification instance"
  (make-instance 'json-rpc-notification
                 :method method
                 :params params))

;;; ============================================================
;;; Encoding
;;; ============================================================

(defgeneric encode-json-rpc (message)
  (:documentation "Encode a JSON-RPC message to JSON string."))

(defmethod encode-json-rpc ((req json-rpc-request))
  "Encode request to JSON."
  (let ((obj (make-hash-table :test 'equal)))
    (setf (gethash "jsonrpc" obj) "2.0")
    (setf (gethash "id" obj) (rpc-id req))
    (setf (gethash "method" obj) (rpc-method req))
    (when (rpc-params req)
      (setf (gethash "params" obj) (rpc-params req)))
    (com.inuoe.jzon:stringify obj)))

(defmethod encode-json-rpc ((resp json-rpc-response))
  "Encode response to JSON."
  (let ((obj (make-hash-table :test 'equal)))
    (setf (gethash "jsonrpc" obj) "2.0")
    (setf (gethash "id" obj) (rpc-id resp))
    (if (rpc-error resp)
        (setf (gethash "error" obj) (encode-rpc-error-obj (rpc-error resp)))
        (setf (gethash "result" obj) (or (rpc-result resp) :null)))
    (com.inuoe.jzon:stringify obj)))

(defmethod encode-json-rpc ((notif json-rpc-notification))
  "Encode notification to JSON."
  (let ((obj (make-hash-table :test 'equal)))
    (setf (gethash "jsonrpc" obj) "2.0")
    (setf (gethash "method" obj) (rpc-method notif))
    (when (rpc-params notif)
      (setf (gethash "params" obj) (rpc-params notif)))
    (com.inuoe.jzon:stringify obj)))

(defun encode-rpc-error-obj (err)
  "Encode error object to hash table."
  (let ((obj (make-hash-table :test 'equal)))
    (setf (gethash "code" obj) (rpc-error-code err))
    (setf (gethash "message" obj) (rpc-error-message err))
    (when (rpc-error-data err)
      (setf (gethash "data" obj) (rpc-error-data err)))
    obj))

;;; ============================================================
;;; Decoding
;;; ============================================================

(defun parse-json-rpc (json-string)
  "Parse a JSON-RPC message from JSON string.

Parameters:
  JSON-STRING - JSON string to parse

Returns:
  Parsed message (request, response, notification, or error response)

Signals:
  Error on invalid JSON or invalid JSON-RPC structure"
  (handler-case
      (let ((obj (com.inuoe.jzon:parse json-string)))
        (parse-json-rpc-object obj))
    (error (e)
      ;; Return parse error response
      (make-rpc-error nil +parse-error+
                      (format nil "Parse error: ~A" e)))))

(defun parse-json-rpc-object (obj)
  "Parse a JSON-RPC message from parsed JSON object."
  (unless (hash-table-p obj)
    (error "JSON-RPC message must be an object"))

  (let ((jsonrpc (gethash "jsonrpc" obj))
        (id (gethash "id" obj))
        (method (gethash "method" obj))
        (params (gethash "params" obj))
        (result (gethash "result" obj))
        (err (gethash "error" obj)))

    ;; Validate jsonrpc version
    (unless (equal jsonrpc "2.0")
      (error "Invalid JSON-RPC version: ~A" jsonrpc))

    (cond
      ;; Response (has id and either result or error)
      ((and id (or (nth-value 1 (gethash "result" obj))
                   (nth-value 1 (gethash "error" obj))))
       (make-instance 'json-rpc-response
                      :id id
                      :result result
                      :error (when err (parse-rpc-error err))))

      ;; Request (has id and method)
      ((and id method)
       (make-instance 'json-rpc-request
                      :id id
                      :method method
                      :params params))

      ;; Notification (has method but no id)
      ((and method (not id))
       (make-instance 'json-rpc-notification
                      :method method
                      :params params))

      ;; Invalid
      (t
       (error "Invalid JSON-RPC message structure")))))

(defun parse-rpc-error (err-obj)
  "Parse an error object from JSON."
  (when (hash-table-p err-obj)
    (make-instance 'json-rpc-error
                   :code (gethash "code" err-obj 0)
                   :message (gethash "message" err-obj "Unknown error")
                   :data (gethash "data" err-obj))))

;;; ============================================================
;;; Batch Support
;;; ============================================================

(defun encode-batch (messages)
  "Encode a batch of JSON-RPC messages.

Parameters:
  MESSAGES - List of JSON-RPC messages

Returns:
  JSON string (array)"
  (com.inuoe.jzon:stringify
   (mapcar (lambda (msg)
             (com.inuoe.jzon:parse (encode-json-rpc msg)))
           messages)))

(defun parse-batch (json-string)
  "Parse a batch of JSON-RPC messages.

Parameters:
  JSON-STRING - JSON string (array)

Returns:
  List of parsed messages"
  (let ((arr (com.inuoe.jzon:parse json-string)))
    (if (vectorp arr)
        (map 'list #'parse-json-rpc-object (coerce arr 'list))
        (list (parse-json-rpc-object arr)))))

;;; ============================================================
;;; Utility Functions
;;; ============================================================

(defun request-p (msg)
  "Check if message is a request."
  (typep msg 'json-rpc-request))

(defun response-p (msg)
  "Check if message is a response."
  (typep msg 'json-rpc-response))

(defun notification-p (msg)
  "Check if message is a notification."
  (typep msg 'json-rpc-notification))

(defun success-response-p (resp)
  "Check if response is successful (no error)."
  (and (response-p resp)
       (null (rpc-error resp))))

(defun error-response-p (resp)
  "Check if response is an error."
  (and (response-p resp)
       (not (null (rpc-error resp)))))

(defun standard-error-p (code)
  "Check if error code is a standard JSON-RPC error."
  (or (= code +parse-error+)
      (= code +invalid-request+)
      (= code +method-not-found+)
      (= code +invalid-params+)
      (= code +internal-error+)
      (and (>= code +server-error-start+)
           (<= code +server-error-end+))))

