;;;; transport/stdio.lisp
;;;; CL-Agent MCP - Stdio Transport
;;;;
;;;; Overview:
;;;;   Standard input/output transport for MCP communication.
;;;;   Uses line-delimited JSON over stdin/stdout.

(in-package #:cl-agent.mcp)

;;; ============================================================
;;; Stdio Transport Class
;;; ============================================================

(defclass stdio-transport (mcp-transport)
  ((input-stream
    :initarg :input-stream
    :accessor stdio-input-stream
    :initform *standard-input*
    :documentation "Input stream (default: stdin)")

   (output-stream
    :initarg :output-stream
    :accessor stdio-output-stream
    :initform *standard-output*
    :documentation "Output stream (default: stdout)")

   (error-stream
    :initarg :error-stream
    :accessor stdio-error-stream
    :initform *error-output*
    :documentation "Error stream for logging")

   (buffer
    :initform (make-string-output-stream)
    :accessor stdio-buffer
    :documentation "Input buffer")

   (running
    :initform nil
    :accessor stdio-running
    :type boolean
    :documentation "Whether the read loop is running")

   (reader-thread
    :initform nil
    :accessor stdio-reader-thread
    :documentation "Reader thread"))
  (:documentation "Stdio transport using line-delimited JSON."))

(defun make-stdio-transport (&key (input *standard-input*)
                                   (output *standard-output*)
                                   (error-output *error-output*))
  "Create a stdio transport.

Parameters:
  INPUT        - Input stream (default: *standard-input*)
  OUTPUT       - Output stream (default: *standard-output*)
  ERROR-OUTPUT - Error stream (default: *error-output*)

Returns:
  stdio-transport instance"
  (make-instance 'stdio-transport
                 :input-stream input
                 :output-stream output
                 :error-stream error-output))

;;; ============================================================
;;; Transport Protocol Implementation
;;; ============================================================

(defmethod transport-connect ((transport stdio-transport))
  "Connect the stdio transport (mark as connected)."
  (bt:with-lock-held ((transport-lock transport))
    (setf (transport-connected transport) t))
  t)

(defmethod transport-disconnect ((transport stdio-transport))
  "Disconnect the stdio transport."
  (bt:with-lock-held ((transport-lock transport))
    ;; Stop reader thread if running
    (when (stdio-running transport)
      (setf (stdio-running transport) nil))
    (setf (transport-connected transport) nil))
  t)

(defmethod transport-send ((transport stdio-transport) message)
  "Send a message over stdio.

Parameters:
  TRANSPORT - Stdio transport
  MESSAGE   - Message (string or JSON-RPC object)

Returns:
  T on success"
  (unless (transport-connected-p transport)
    (error 'transport-send-error
           :transport transport
           :message "Transport not connected"))

  (let ((msg-string (if (stringp message)
                        message
                        (encode-json-rpc message)))
        (output (stdio-output-stream transport)))
    (bt:with-lock-held ((transport-lock transport))
      (write-string msg-string output)
      (write-char #\Newline output)
      (force-output output)))
  t)

(defmethod transport-receive ((transport stdio-transport) &key timeout)
  "Receive a message from stdio.

Parameters:
  TRANSPORT - Stdio transport
  TIMEOUT   - Timeout in seconds (not fully supported for stdio)

Returns:
  Message string or NIL"
  (declare (ignore timeout)) ; Stdio doesn't support timeout easily

  (unless (transport-connected-p transport)
    (error 'transport-receive-error
           :transport transport
           :message "Transport not connected"))

  (let ((input (stdio-input-stream transport)))
    (handler-case
        (let ((line (read-line input nil nil)))
          (when line
            (unframe-message line)))
      (end-of-file ()
        nil)
      (error (e)
        (error 'transport-receive-error
               :transport transport
               :message (format nil "Read error: ~A" e))))))

;;; ============================================================
;;; Async Message Loop
;;; ============================================================

(defmethod start-message-loop ((transport stdio-transport))
  "Start the async message reading loop."
  (when (stdio-running transport)
    (return-from start-message-loop nil))

  (setf (stdio-running transport) t)
  (setf (stdio-reader-thread transport)
        (bt:make-thread
         (lambda ()
           (stdio-read-loop transport))
         :name "stdio-reader"))
  t)

(defun stdio-read-loop (transport)
  "Internal read loop for stdio transport."
  (let ((input (stdio-input-stream transport)))
    (loop while (stdio-running transport)
          do (handler-case
                 (let ((line (read-line input nil :eof)))
                   (cond
                     ((eq line :eof)
                      (setf (stdio-running transport) nil))
                     ((and line (> (length line) 0))
                      (let ((handler (transport-handler transport)))
                        (when handler
                          (handler-case
                              (let* ((msg (parse-json-rpc (unframe-message line)))
                                     (response (funcall handler msg)))
                                (when response
                                  (transport-send transport response)))
                            (error (e)
                              (log-stdio-error transport
                                               "Handler error: ~A" e))))))))
               (error (e)
                 (log-stdio-error transport "Read loop error: ~A" e))))))

(defmethod stop-message-loop ((transport stdio-transport))
  "Stop the async message reading loop."
  (setf (stdio-running transport) nil)
  (when (stdio-reader-thread transport)
    ;; Give thread time to finish
    (sleep 0.1)
    (setf (stdio-reader-thread transport) nil))
  t)

;;; ============================================================
;;; Logging Helpers
;;; ============================================================

(defun log-stdio-error (transport format-string &rest args)
  "Log an error to the error stream."
  (let ((err-stream (stdio-error-stream transport)))
    (when err-stream
      (format err-stream "~&[MCP-STDIO] ")
      (apply #'format err-stream format-string args)
      (terpri err-stream)
      (force-output err-stream))))

(defun log-stdio-debug (transport format-string &rest args)
  "Log a debug message to the error stream."
  (let ((err-stream (stdio-error-stream transport)))
    (when err-stream
      (format err-stream "~&[MCP-STDIO DEBUG] ")
      (apply #'format err-stream format-string args)
      (terpri err-stream)
      (force-output err-stream))))

;;; ============================================================
;;; Convenience Functions
;;; ============================================================

(defun with-stdio-transport (handler)
  "Run a handler with a stdio transport.

Parameters:
  HANDLER - Function (transport) -> result

Returns:
  Handler result"
  (let ((transport (make-stdio-transport)))
    (unwind-protect
         (progn
           (transport-connect transport)
           (funcall handler transport))
      (transport-disconnect transport))))

