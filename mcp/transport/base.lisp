;;;; transport/base.lisp
;;;; CL-Agent MCP - Transport Base Protocol
;;;;
;;;; Overview:
;;;;   Base transport protocol definition for MCP communication.

(in-package #:cl-agent.mcp)

;;; ============================================================
;;; Transport Protocol
;;; ============================================================

(defgeneric transport-connect (transport)
  (:documentation "Connect the transport.

Parameters:
  TRANSPORT - Transport instance

Returns:
  T on success, signals error on failure"))

(defgeneric transport-disconnect (transport)
  (:documentation "Disconnect the transport.

Parameters:
  TRANSPORT - Transport instance

Returns:
  T on success"))

(defgeneric transport-connected-p (transport)
  (:documentation "Check if transport is connected.

Parameters:
  TRANSPORT - Transport instance

Returns:
  T if connected, NIL otherwise"))

(defgeneric transport-send (transport message)
  (:documentation "Send a message over the transport.

Parameters:
  TRANSPORT - Transport instance
  MESSAGE   - JSON-RPC message (string or object)

Returns:
  T on success, signals error on failure"))

(defgeneric transport-receive (transport &key timeout)
  (:documentation "Receive a message from the transport.

Parameters:
  TRANSPORT - Transport instance
  TIMEOUT   - Timeout in seconds (optional)

Returns:
  Received message string, or NIL on timeout"))

(defgeneric transport-set-handler (transport handler)
  (:documentation "Set the message handler for async transport.

Parameters:
  TRANSPORT - Transport instance
  HANDLER   - Function (message) -> response

Returns:
  Previous handler or NIL"))

;;; ============================================================
;;; Base Transport Class
;;; ============================================================

(defclass mcp-transport ()
  ((connected
    :initform nil
    :accessor transport-connected
    :type boolean
    :documentation "Connection state")

   (handler
    :initform nil
    :accessor transport-handler
    :type (or null function)
    :documentation "Message handler function")

   (lock
    :initform (bt:make-lock "transport-lock")
    :reader transport-lock
    :documentation "Thread safety lock"))
  (:documentation "Base class for MCP transports."))

(defmethod transport-connected-p ((transport mcp-transport))
  (transport-connected transport))

(defmethod transport-set-handler ((transport mcp-transport) handler)
  (let ((old (transport-handler transport)))
    (setf (transport-handler transport) handler)
    old))

;;; ============================================================
;;; Message Framing
;;; ============================================================

(defparameter *message-delimiter* #\Newline
  "Delimiter between messages (newline for line-delimited JSON).")

(defun frame-message (message)
  "Frame a message for transport.

Parameters:
  MESSAGE - Message string

Returns:
  Framed message string"
  (format nil "~A~C" message *message-delimiter*))

(defun unframe-message (framed)
  "Unframe a received message.

Parameters:
  FRAMED - Framed message string

Returns:
  Unframed message string"
  (string-trim '(#\Newline #\Return #\Space) framed))

;;; ============================================================
;;; Transport Error Conditions
;;; ============================================================

(define-condition transport-error (error)
  ((transport :initarg :transport :reader transport-error-transport)
   (message :initarg :message :reader transport-error-message))
  (:report (lambda (condition stream)
             (format stream "Transport error: ~A"
                     (transport-error-message condition))))
  (:documentation "Error during transport operation."))

(define-condition transport-connection-error (transport-error)
  ()
  (:documentation "Error connecting transport."))

(define-condition transport-send-error (transport-error)
  ()
  (:documentation "Error sending message."))

(define-condition transport-receive-error (transport-error)
  ()
  (:documentation "Error receiving message."))

(define-condition transport-timeout-error (transport-error)
  ((timeout :initarg :timeout :reader transport-timeout))
  (:report (lambda (condition stream)
             (format stream "Transport timeout after ~A seconds"
                     (transport-timeout condition))))
  (:documentation "Timeout during transport operation."))

