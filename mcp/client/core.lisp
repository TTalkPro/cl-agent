;;;; client/core.lisp
;;;; CL-Agent MCP - Client Implementation
;;;;
;;;; Overview:
;;;;   MCP client for connecting to MCP servers and calling tools,
;;;;   reading resources, and getting prompts.

(in-package #:cl-agent.mcp)

;;; ============================================================
;;; MCP Client Class
;;; ============================================================

(defclass mcp-client ()
  ((name
    :initarg :name
    :accessor client-name
    :initform "cl-agent-mcp-client"
    :type string
    :documentation "Client name")

   (version
    :initarg :version
    :accessor client-version
    :initform +mcp-version+
    :type string
    :documentation "Client version")

   (transport
    :initarg :transport
    :accessor client-transport
    :documentation "Transport layer")

   (server-info
    :initform nil
    :accessor client-server-info
    :documentation "Server information after initialization")

   (pending-requests
    :initform (make-hash-table :test 'equal)
    :accessor client-pending-requests
    :documentation "Pending request ID -> callback")

   (lock
    :initform (bt:make-lock "mcp-client-lock")
    :reader client-lock
    :documentation "Thread safety lock")

   (initialized
    :initform nil
    :accessor client-initialized-p
    :type boolean
    :documentation "Whether client has been initialized"))
  (:documentation "MCP client for communicating with MCP servers."))

(defun make-mcp-client (transport &key name version)
  "Create an MCP client.

Parameters:
  TRANSPORT - Transport instance (stdio or SSE)
  NAME      - Client name (optional)
  VERSION   - Client version (optional)

Returns:
  mcp-client instance"
  (make-instance 'mcp-client
                 :transport transport
                 :name (or name "cl-agent-mcp-client")
                 :version (or version +mcp-version+)))

;;; ============================================================
;;; Connection Management
;;; ============================================================

(defmethod client-connect ((client mcp-client))
  "Connect the client to the server."
  (transport-connect (client-transport client))
  t)

(defmethod client-disconnect ((client mcp-client))
  "Disconnect the client from the server."
  (transport-disconnect (client-transport client))
  (setf (client-initialized-p client) nil)
  (setf (client-server-info client) nil)
  t)

(defmethod client-connected-p ((client mcp-client))
  "Check if client is connected."
  (transport-connected-p (client-transport client)))

;;; ============================================================
;;; Request/Response Handling
;;; ============================================================

(defmethod send-request ((client mcp-client) method &key params)
  "Send a request and wait for response.

Parameters:
  CLIENT - MCP client
  METHOD - Method name
  PARAMS - Method parameters

Returns:
  Response result

Signals:
  Error if request fails"
  (let* ((request (make-rpc-request method :params params))
         (id (rpc-id request)))

    ;; Send request
    (transport-send (client-transport client) request)

    ;; Wait for response
    (let ((response (wait-for-response client id)))
      (cond
        ((null response)
         (error "Request timeout for method: ~A" method))

        ((error-response-p response)
         (let ((err (rpc-error response)))
           (error "RPC error (~A): ~A"
                  (rpc-error-code err)
                  (rpc-error-message err))))

        (t
         (rpc-result response))))))

(defun wait-for-response (client id &key (timeout 30))
  "Wait for a response with the given ID.

Parameters:
  CLIENT  - MCP client
  ID      - Request ID
  TIMEOUT - Timeout in seconds

Returns:
  Response or NIL on timeout"
  (let ((deadline (+ (get-internal-real-time)
                     (* timeout internal-time-units-per-second))))
    (loop
      (let ((response (transport-receive (client-transport client)
                                         :timeout 1)))
        (when response
          (let ((parsed (parse-json-rpc response)))
            (when (and (response-p parsed)
                       (equal (rpc-id parsed) id))
              (return parsed)))))

      (when (> (get-internal-real-time) deadline)
        (return nil)))))

(defmethod send-notification ((client mcp-client) method &key params)
  "Send a notification (no response expected).

Parameters:
  CLIENT - MCP client
  METHOD - Method name
  PARAMS - Method parameters"
  (let ((notif (make-rpc-notification method :params params)))
    (transport-send (client-transport client) notif))
  nil)

;;; ============================================================
;;; MCP Protocol Methods
;;; ============================================================

(defmethod client-initialize ((client mcp-client))
  "Initialize the MCP session.

Returns:
  Server info"
  (when (client-initialized-p client)
    (return-from client-initialize (client-server-info client)))

  (let* ((client-info (make-hash-table :test 'equal))
         (capabilities (make-hash-table :test 'equal)))

    ;; Set client info
    (setf (gethash "name" client-info) (client-name client))
    (setf (gethash "version" client-info) (client-version client))

    ;; Set capabilities (what this client supports)
    (setf (gethash "tools" capabilities) (make-hash-table :test 'equal))
    (setf (gethash "resources" capabilities) (make-hash-table :test 'equal))

    (let* ((params (make-hash-table :test 'equal)))
      (setf (gethash "protocolVersion" params) +mcp-protocol-version+)
      (setf (gethash "clientInfo" params) client-info)
      (setf (gethash "capabilities" params) capabilities)

      (let ((result (send-request client "initialize" :params params)))
        ;; Parse server info from result
        (when result
          (setf (client-server-info client)
                (make-server-info
                 (gethash "name" (gethash "serverInfo" result) "unknown")
                 (gethash "version" (gethash "serverInfo" result) "unknown")
                 :capabilities nil))
          (setf (client-initialized-p client) t)

          ;; Send initialized notification
          (send-notification client "notifications/initialized")

          (client-server-info client))))))

;;; ============================================================
;;; Tools
;;; ============================================================

(defmethod client-list-tools ((client mcp-client))
  "List available tools on the server.

Returns:
  List of tool definitions"
  (unless (client-initialized-p client)
    (client-initialize client))

  (let ((result (send-request client "tools/list")))
    (when result
      (let ((tools (gethash "tools" result)))
        (when tools
          (map 'list
               (lambda (tool)
                 (make-mcp-tool
                  (gethash "name" tool)
                  :description (gethash "description" tool)
                  :input-schema (gethash "inputSchema" tool)))
               tools))))))

(defmethod client-call-tool ((client mcp-client) tool-name arguments)
  "Call a tool on the server.

Parameters:
  CLIENT    - MCP client
  TOOL-NAME - Tool name
  ARGUMENTS - Tool arguments (hash table or plist)

Returns:
  Tool result"
  (unless (client-initialized-p client)
    (client-initialize client))

  (let ((params (make-hash-table :test 'equal)))
    (setf (gethash "name" params) tool-name)
    (setf (gethash "arguments" params)
          (if (hash-table-p arguments)
              arguments
              (plist-to-hash arguments)))

    (let ((result (send-request client "tools/call" :params params)))
      (when result
        (gethash "content" result)))))

;;; ============================================================
;;; Resources
;;; ============================================================

(defmethod client-list-resources ((client mcp-client))
  "List available resources on the server.

Returns:
  List of resource definitions"
  (unless (client-initialized-p client)
    (client-initialize client))

  (let ((result (send-request client "resources/list")))
    (when result
      (let ((resources (gethash "resources" result)))
        (when resources
          (map 'list
               (lambda (r)
                 (make-resource
                  (gethash "uri" r)
                  (gethash "name" r)
                  :description (gethash "description" r)
                  :mime-type (gethash "mimeType" r "text/plain")))
               resources))))))

(defmethod client-read-resource ((client mcp-client) uri)
  "Read a resource from the server.

Parameters:
  CLIENT - MCP client
  URI    - Resource URI

Returns:
  Resource content"
  (unless (client-initialized-p client)
    (client-initialize client))

  (let ((params (make-hash-table :test 'equal)))
    (setf (gethash "uri" params) uri)

    (let ((result (send-request client "resources/read" :params params)))
      (when result
        (gethash "contents" result)))))

;;; ============================================================
;;; Prompts
;;; ============================================================

(defmethod client-list-prompts ((client mcp-client))
  "List available prompts on the server.

Returns:
  List of prompt definitions"
  (unless (client-initialized-p client)
    (client-initialize client))

  (let ((result (send-request client "prompts/list")))
    (when result
      (let ((prompts (gethash "prompts" result)))
        (when prompts
          (map 'list
               (lambda (p)
                 (make-mcp-prompt
                  (gethash "name" p)
                  :description (gethash "description" p)
                  :arguments (gethash "arguments" p)))
               prompts))))))

(defmethod client-get-prompt ((client mcp-client) prompt-name &key arguments)
  "Get a prompt from the server.

Parameters:
  CLIENT      - MCP client
  PROMPT-NAME - Prompt name
  ARGUMENTS   - Prompt arguments

Returns:
  Prompt messages"
  (unless (client-initialized-p client)
    (client-initialize client))

  (let ((params (make-hash-table :test 'equal)))
    (setf (gethash "name" params) prompt-name)
    (when arguments
      (setf (gethash "arguments" params)
            (if (hash-table-p arguments)
                arguments
                (plist-to-hash arguments))))

    (let ((result (send-request client "prompts/get" :params params)))
      (when result
        (gethash "messages" result)))))

;;; ============================================================
;;; Utility Functions
;;; ============================================================

(defun plist-to-hash (plist)
  "Convert a plist to a hash table."
  (let ((ht (make-hash-table :test 'equal)))
    (loop for (key value) on plist by #'cddr
          do (setf (gethash (string-downcase (symbol-name key)) ht) value))
    ht))

;;; ============================================================
;;; Convenience Constructors
;;; ============================================================

(defun connect-stdio-client (&key name version)
  "Create and connect an MCP client over stdio.

Parameters:
  NAME    - Client name
  VERSION - Client version

Returns:
  Connected and initialized mcp-client"
  (let* ((transport (make-stdio-transport))
         (client (make-mcp-client transport :name name :version version)))
    (client-connect client)
    (client-initialize client)
    client))

(defun connect-sse-client (url &key name version headers)
  "Create and connect an MCP client over SSE.

Parameters:
  URL     - Server URL
  NAME    - Client name
  VERSION - Client version
  HEADERS - Additional HTTP headers

Returns:
  Connected and initialized mcp-client"
  (let* ((transport (make-sse-transport url :headers headers))
         (client (make-mcp-client transport :name name :version version)))
    (client-connect client)
    (client-initialize client)
    client))

