;;;; transport/sse.lisp
;;;; CL-Agent MCP - SSE (Server-Sent Events) Transport
;;;;
;;;; Overview:
;;;;   HTTP-based transport using Server-Sent Events for receiving
;;;;   messages and HTTP POST for sending.

(in-package #:cl-agent.mcp)

;;; ============================================================
;;; SSE Transport Class
;;; ============================================================

(defclass sse-transport (mcp-transport)
  ((base-url
    :initarg :base-url
    :accessor sse-transport-url
    :type string
    :documentation "Base URL for the MCP server")

   (sse-endpoint
    :initarg :sse-endpoint
    :accessor sse-transport-sse-endpoint
    :initform "/sse"
    :type string
    :documentation "SSE endpoint path")

   (message-endpoint
    :initarg :message-endpoint
    :accessor sse-transport-message-endpoint
    :initform "/message"
    :type string
    :documentation "Message POST endpoint path")

   (headers
    :initarg :headers
    :accessor sse-transport-headers
    :initform nil
    :type list
    :documentation "Additional HTTP headers")

   (session-id
    :initarg :session-id
    :accessor sse-transport-session-id
    :initform nil
    :documentation "Session ID from server")

   (sse-connection
    :initform nil
    :accessor sse-transport-connection
    :documentation "Active SSE connection")

   (sse-thread
    :initform nil
    :accessor sse-transport-thread
    :documentation "SSE reader thread")

   (message-queue
    :initform nil
    :accessor sse-transport-queue
    :documentation "Received message queue")

   (queue-lock
    :initform (bt:make-lock "sse-queue-lock")
    :reader sse-queue-lock
    :documentation "Queue lock")

   (queue-cv
    :initform (bt:make-condition-variable :name "sse-queue-cv")
    :reader sse-queue-cv
    :documentation "Queue condition variable"))
  (:documentation "SSE-based transport for MCP over HTTP."))

(defun make-sse-transport (base-url &key headers sse-endpoint message-endpoint)
  "Create an SSE transport.

Parameters:
  BASE-URL         - Base URL for the MCP server
  HEADERS          - Additional HTTP headers
  SSE-ENDPOINT     - SSE endpoint path (default: /sse)
  MESSAGE-ENDPOINT - Message endpoint path (default: /message)

Returns:
  sse-transport instance"
  (make-instance 'sse-transport
                 :base-url base-url
                 :headers headers
                 :sse-endpoint (or sse-endpoint "/sse")
                 :message-endpoint (or message-endpoint "/message")))

;;; ============================================================
;;; Transport Protocol Implementation
;;; ============================================================

(defmethod transport-connect ((transport sse-transport))
  "Connect to the SSE endpoint."
  (when (transport-connected-p transport)
    (return-from transport-connect t))

  (let ((url (format nil "~A~A"
                     (sse-transport-url transport)
                     (sse-transport-sse-endpoint transport))))

    ;; Start SSE connection in a thread
    (setf (sse-transport-thread transport)
          (bt:make-thread
           (lambda ()
             (sse-read-loop transport url))
           :name "sse-reader"))

    ;; Wait for connection
    (loop repeat 50 ; 5 seconds timeout
          until (transport-connected transport)
          do (sleep 0.1))

    (unless (transport-connected transport)
      (error 'transport-connection-error
             :transport transport
             :message "Failed to establish SSE connection")))
  t)

(defmethod transport-disconnect ((transport sse-transport))
  "Disconnect from the SSE endpoint."
  (setf (transport-connected transport) nil)
  ;; Connection cleanup will happen in the read loop
  (sleep 0.1)
  t)

(defmethod transport-send ((transport sse-transport) message)
  "Send a message via HTTP POST."
  (unless (transport-connected-p transport)
    (error 'transport-send-error
           :transport transport
           :message "Transport not connected"))

  (let ((url (format nil "~A~A"
                     (sse-transport-url transport)
                     (sse-transport-message-endpoint transport)))
        (msg-string (if (stringp message)
                        message
                        (encode-json-rpc message)))
        (headers (append (sse-transport-headers transport)
                         '(("Content-Type" . "application/json")))))

    ;; Add session ID if available
    (when (sse-transport-session-id transport)
      (push (cons "X-Session-Id" (sse-transport-session-id transport))
            headers))

    (handler-case
        (dex:post url
                  :headers headers
                  :content msg-string)
      (error (e)
        (error 'transport-send-error
               :transport transport
               :message (format nil "POST failed: ~A" e)))))
  t)

(defmethod transport-receive ((transport sse-transport) &key (timeout 30))
  "Receive a message from the queue."
  (unless (transport-connected-p transport)
    (error 'transport-receive-error
           :transport transport
           :message "Transport not connected"))

  (let ((deadline (+ (get-internal-real-time)
                     (* timeout internal-time-units-per-second))))
    (bt:with-lock-held ((sse-queue-lock transport))
      (loop
        (when (sse-transport-queue transport)
          (return (pop (sse-transport-queue transport))))

        (let ((remaining (/ (- deadline (get-internal-real-time))
                           internal-time-units-per-second)))
          (when (<= remaining 0)
            (return nil))

          (bt:condition-wait (sse-queue-cv transport)
                             (sse-queue-lock transport)
                             :timeout remaining))))))

;;; ============================================================
;;; SSE Reading
;;; ============================================================

(defun sse-read-loop (transport url)
  "Read loop for SSE connection."
  (handler-case
      (dex:get url
               :headers (append (sse-transport-headers transport)
                                '(("Accept" . "text/event-stream")))
               :want-stream t
               :force-binary t)
    (error (e)
      (log-sse-error transport "Connection failed: ~A" e)
      (return-from sse-read-loop)))

  ;; If we get here with the streaming approach, we need a different method
  ;; For now, use a simplified polling approach
  (setf (transport-connected transport) t)

  (loop while (transport-connected transport)
        do (handler-case
               (progn
                 ;; In a real implementation, we'd read from the SSE stream
                 ;; For now, sleep to avoid busy-waiting
                 (sleep 0.1))
             (error (e)
               (log-sse-error transport "Read error: ~A" e)
               (return)))))

(defun process-sse-event (transport event-type data)
  "Process an SSE event."
  (cond
    ((string-equal event-type "message")
     (enqueue-message transport data))

    ((string-equal event-type "endpoint")
     ;; Server provides message endpoint
     (setf (sse-transport-message-endpoint transport) data))

    ((string-equal event-type "session")
     ;; Server provides session ID
     (setf (sse-transport-session-id transport) data))

    (t
     (log-sse-debug transport "Unknown event type: ~A" event-type))))

(defun enqueue-message (transport message)
  "Add a message to the receive queue."
  (bt:with-lock-held ((sse-queue-lock transport))
    (setf (sse-transport-queue transport)
          (append (sse-transport-queue transport) (list message)))
    (bt:condition-notify (sse-queue-cv transport))))

;;; ============================================================
;;; Logging Helpers
;;; ============================================================

(defun log-sse-error (transport format-string &rest args)
  "Log an error."
  (format *error-output* "~&[MCP-SSE ERROR] ")
  (apply #'format *error-output* format-string args)
  (terpri *error-output*))

(defun log-sse-debug (transport format-string &rest args)
  "Log a debug message."
  (declare (ignore transport))
  (format *error-output* "~&[MCP-SSE DEBUG] ")
  (apply #'format *error-output* format-string args)
  (terpri *error-output*))

;;; ============================================================
;;; SSE Event Parsing
;;; ============================================================

(defun parse-sse-line (line)
  "Parse a single SSE line.

Returns: (values field value) or (values nil nil) for empty/comment lines"
  (cond
    ((or (zerop (length line))
         (char= (char line 0) #\:))
     ;; Empty line or comment
     (values nil nil))

    ((search ":" line)
     ;; Field: value
     (let ((pos (position #\: line)))
       (values (subseq line 0 pos)
               (string-trim '(#\Space) (subseq line (1+ pos))))))

    (t
     ;; Field only, empty value
     (values line ""))))

(defun parse-sse-event (lines)
  "Parse a complete SSE event from accumulated lines.

Returns: (values event-type data) or NIL if incomplete"
  (let ((event-type "message")
        (data-parts nil))
    (dolist (line lines)
      (multiple-value-bind (field value) (parse-sse-line line)
        (when field
          (cond
            ((string-equal field "event")
             (setf event-type value))
            ((string-equal field "data")
             (push value data-parts))
            ((string-equal field "id")
             ;; Ignore for now
             nil)
            ((string-equal field "retry")
             ;; Ignore for now
             nil)))))
    (when data-parts
      (values event-type
              (format nil "~{~A~^~%~}" (nreverse data-parts))))))

