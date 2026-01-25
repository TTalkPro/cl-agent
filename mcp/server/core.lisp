;;;; server/core.lisp
;;;; CL-Agent MCP - Server Implementation
;;;;
;;;; Overview:
;;;;   MCP server that exposes tools, resources, and prompts to clients.

(in-package #:cl-agent.mcp)

;;; ============================================================
;;; MCP Server Class
;;; ============================================================

(defclass mcp-server ()
  ((name
    :initarg :name
    :accessor server-name
    :initform "cl-agent-mcp-server"
    :type string
    :documentation "Server name")

   (version
    :initarg :version
    :accessor server-version
    :initform +mcp-version+
    :type string
    :documentation "Server version")

   (transport
    :initarg :transport
    :accessor server-transport
    :documentation "Transport layer")

   (tools
    :initform (make-hash-table :test 'equal)
    :accessor server-tools
    :documentation "Registered tools (name -> mcp-tool)")

   (resources
    :initform (make-hash-table :test 'equal)
    :accessor server-resources
    :documentation "Registered resources (uri -> mcp-resource)")

   (prompts
    :initform (make-hash-table :test 'equal)
    :accessor server-prompts
    :documentation "Registered prompts (name -> mcp-prompt)")

   (resource-handlers
    :initform (make-hash-table :test 'equal)
    :accessor server-resource-handlers
    :documentation "Resource read handlers (uri -> function)")

   (capabilities
    :initform nil
    :accessor server-capabilities
    :type list
    :documentation "Server capabilities")

   (client-info
    :initform nil
    :accessor server-client-info
    :documentation "Connected client info")

   (running
    :initform nil
    :accessor server-running-p
    :type boolean
    :documentation "Whether server is running")

   (lock
    :initform (bt:make-lock "mcp-server-lock")
    :reader server-lock
    :documentation "Thread safety lock"))
  (:documentation "MCP server for exposing tools, resources, and prompts."))

(defun make-mcp-server (&key name version transport)
  "Create an MCP server.

Parameters:
  NAME      - Server name
  VERSION   - Server version
  TRANSPORT - Transport layer (optional)

Returns:
  mcp-server instance"
  (make-instance 'mcp-server
                 :name (or name "cl-agent-mcp-server")
                 :version (or version +mcp-version+)
                 :transport transport))

;;; ============================================================
;;; Tool Registration
;;; ============================================================

(defmethod server-register-tool ((server mcp-server) tool)
  "Register a tool with the server.

Parameters:
  SERVER - MCP server
  TOOL   - MCP tool instance or tool spec

Returns:
  The registered tool"
  (let ((mcp-tool (if (typep tool 'mcp-tool)
                      tool
                      (make-mcp-tool
                       (getf tool :name)
                       :description (getf tool :description)
                       :input-schema (getf tool :input-schema)
                       :handler (getf tool :handler)))))
    (bt:with-lock-held ((server-lock server))
      (setf (gethash (mcp-tool-name mcp-tool) (server-tools server))
            mcp-tool))
    mcp-tool))

(defmethod server-unregister-tool ((server mcp-server) name)
  "Unregister a tool from the server.

Parameters:
  SERVER - MCP server
  NAME   - Tool name

Returns:
  T if tool was removed, NIL if not found"
  (bt:with-lock-held ((server-lock server))
    (remhash name (server-tools server))))

(defmethod server-get-tool ((server mcp-server) name)
  "Get a registered tool by name."
  (gethash name (server-tools server)))

(defmethod server-list-tools ((server mcp-server))
  "List all registered tools."
  (let ((tools nil))
    (maphash (lambda (name tool)
               (declare (ignore name))
               (push tool tools))
             (server-tools server))
    (nreverse tools)))

;;; ============================================================
;;; Resource Registration
;;; ============================================================

(defmethod server-register-resource ((server mcp-server) resource &key handler)
  "Register a resource with the server.

Parameters:
  SERVER   - MCP server
  RESOURCE - MCP resource instance or resource spec
  HANDLER  - Function to read the resource (uri) -> content

Returns:
  The registered resource"
  (let ((mcp-resource (if (typep resource 'mcp-resource)
                          resource
                          (make-resource
                           (getf resource :uri)
                           (getf resource :name)
                           :description (getf resource :description)
                           :mime-type (getf resource :mime-type "text/plain")))))
    (bt:with-lock-held ((server-lock server))
      (setf (gethash (resource-uri mcp-resource) (server-resources server))
            mcp-resource)
      (when handler
        (setf (gethash (resource-uri mcp-resource) (server-resource-handlers server))
              handler)))
    mcp-resource))

(defmethod server-get-resource ((server mcp-server) uri)
  "Get a registered resource by URI."
  (gethash uri (server-resources server)))

(defmethod server-list-resources ((server mcp-server))
  "List all registered resources."
  (let ((resources nil))
    (maphash (lambda (uri resource)
               (declare (ignore uri))
               (push resource resources))
             (server-resources server))
    (nreverse resources)))

;;; ============================================================
;;; Prompt Registration
;;; ============================================================

(defmethod server-register-prompt ((server mcp-server) prompt)
  "Register a prompt with the server.

Parameters:
  SERVER - MCP server
  PROMPT - MCP prompt instance or prompt spec

Returns:
  The registered prompt"
  (let ((mcp-prompt (if (typep prompt 'mcp-prompt)
                        prompt
                        (make-mcp-prompt
                         (getf prompt :name)
                         :description (getf prompt :description)
                         :arguments (getf prompt :arguments)
                         :template (getf prompt :template)))))
    (bt:with-lock-held ((server-lock server))
      (setf (gethash (prompt-name mcp-prompt) (server-prompts server))
            mcp-prompt))
    mcp-prompt))

(defmethod server-get-prompt ((server mcp-server) name)
  "Get a registered prompt by name."
  (gethash name (server-prompts server)))

(defmethod server-list-prompts ((server mcp-server))
  "List all registered prompts."
  (let ((prompts nil))
    (maphash (lambda (name prompt)
               (declare (ignore name))
               (push prompt prompts))
             (server-prompts server))
    (nreverse prompts)))

;;; ============================================================
;;; Request Handling
;;; ============================================================

(defmethod server-handle-request ((server mcp-server) request)
  "Handle an incoming request.

Parameters:
  SERVER  - MCP server
  REQUEST - JSON-RPC request

Returns:
  JSON-RPC response"
  (let ((method (rpc-method request))
        (params (rpc-params request))
        (id (rpc-id request)))

    (handler-case
        (let ((result (dispatch-request server method params)))
          (make-rpc-response id result))

      (error (e)
        (make-rpc-error id +internal-error+
                        (format nil "Internal error: ~A" e))))))

(defun dispatch-request (server method params)
  "Dispatch a request to the appropriate handler."
  (cond
    ;; Initialize
    ((string-equal method "initialize")
     (handle-initialize server params))

    ;; Tools
    ((string-equal method "tools/list")
     (handle-tools-list server params))

    ((string-equal method "tools/call")
     (handle-tools-call server params))

    ;; Resources
    ((string-equal method "resources/list")
     (handle-resources-list server params))

    ((string-equal method "resources/read")
     (handle-resources-read server params))

    ;; Prompts
    ((string-equal method "prompts/list")
     (handle-prompts-list server params))

    ((string-equal method "prompts/get")
     (handle-prompts-get server params))

    ;; Unknown
    (t
     (error "Method not found: ~A" method))))

;;; ============================================================
;;; Protocol Handlers
;;; ============================================================

(defun handle-initialize (server params)
  "Handle initialize request."
  (let ((client-info (gethash "clientInfo" params))
        (result (make-hash-table :test 'equal))
        (server-info (make-hash-table :test 'equal))
        (capabilities (make-hash-table :test 'equal)))

    ;; Store client info
    (when client-info
      (setf (server-client-info server) client-info))

    ;; Build server info
    (setf (gethash "name" server-info) (server-name server))
    (setf (gethash "version" server-info) (server-version server))

    ;; Build capabilities
    (when (> (hash-table-count (server-tools server)) 0)
      (setf (gethash "tools" capabilities) (make-hash-table :test 'equal)))
    (when (> (hash-table-count (server-resources server)) 0)
      (setf (gethash "resources" capabilities) (make-hash-table :test 'equal)))
    (when (> (hash-table-count (server-prompts server)) 0)
      (setf (gethash "prompts" capabilities) (make-hash-table :test 'equal)))

    ;; Build result
    (setf (gethash "protocolVersion" result) +mcp-protocol-version+)
    (setf (gethash "serverInfo" result) server-info)
    (setf (gethash "capabilities" result) capabilities)

    result))

(defun handle-tools-list (server params)
  "Handle tools/list request."
  (declare (ignore params))
  (let ((result (make-hash-table :test 'equal))
        (tools (mapcar #'to-json-object (server-list-tools server))))
    (setf (gethash "tools" result) (coerce tools 'vector))
    result))

(defun handle-tools-call (server params)
  "Handle tools/call request."
  (let* ((name (gethash "name" params))
         (arguments (gethash "arguments" params))
         (tool (server-get-tool server name)))

    (unless tool
      (error "Tool not found: ~A" name))

    (let ((handler (mcp-tool-handler tool)))
      (unless handler
        (error "Tool has no handler: ~A" name))

      (let ((output (funcall handler arguments))
            (result (make-hash-table :test 'equal))
            (content (make-hash-table :test 'equal)))

        ;; Format output as text content
        (setf (gethash "type" content) "text")
        (setf (gethash "text" content)
              (if (stringp output)
                  output
                  (com.inuoe.jzon:stringify output)))

        (setf (gethash "content" result) (vector content))
        result))))

(defun handle-resources-list (server params)
  "Handle resources/list request."
  (declare (ignore params))
  (let ((result (make-hash-table :test 'equal))
        (resources (mapcar #'to-json-object (server-list-resources server))))
    (setf (gethash "resources" result) (coerce resources 'vector))
    result))

(defun handle-resources-read (server params)
  "Handle resources/read request."
  (let* ((uri (gethash "uri" params))
         (resource (server-get-resource server uri))
         (handler (gethash uri (server-resource-handlers server))))

    (unless resource
      (error "Resource not found: ~A" uri))

    (let ((content (if handler
                       (funcall handler uri)
                       ""))
          (result (make-hash-table :test 'equal))
          (content-obj (make-hash-table :test 'equal)))

      (setf (gethash "uri" content-obj) uri)
      (setf (gethash "mimeType" content-obj) (resource-mime-type resource))
      (setf (gethash "text" content-obj) content)

      (setf (gethash "contents" result) (vector content-obj))
      result)))

(defun handle-prompts-list (server params)
  "Handle prompts/list request."
  (declare (ignore params))
  (let ((result (make-hash-table :test 'equal))
        (prompts (mapcar #'to-json-object (server-list-prompts server))))
    (setf (gethash "prompts" result) (coerce prompts 'vector))
    result))

(defun handle-prompts-get (server params)
  "Handle prompts/get request."
  (let* ((name (gethash "name" params))
         (arguments (gethash "arguments" params))
         (prompt (server-get-prompt server name)))

    (unless prompt
      (error "Prompt not found: ~A" name))

    (let ((template (prompt-template prompt))
          (result (make-hash-table :test 'equal))
          (messages nil))

      ;; Generate prompt messages
      (let ((content (cond
                       ((functionp template)
                        (funcall template arguments))
                       ((stringp template)
                        template)
                       (t
                        (format nil "~A" name)))))

        (let ((msg (make-hash-table :test 'equal)))
          (setf (gethash "role" msg) "user")
          (let ((content-obj (make-hash-table :test 'equal)))
            (setf (gethash "type" content-obj) "text")
            (setf (gethash "text" content-obj) content)
            (setf (gethash "content" msg) content-obj))
          (push msg messages)))

      (setf (gethash "messages" result) (coerce (nreverse messages) 'vector))
      result)))

;;; ============================================================
;;; Notification Handling
;;; ============================================================

(defmethod server-handle-notification ((server mcp-server) notification)
  "Handle an incoming notification.

Parameters:
  SERVER       - MCP server
  NOTIFICATION - JSON-RPC notification"
  (let ((method (rpc-method notification)))
    (cond
      ((string-equal method "notifications/initialized")
       ;; Client is ready
       nil)

      ((string-equal method "notifications/cancelled")
       ;; Request cancelled
       nil)

      (t
       ;; Unknown notification - ignore
       nil))))

;;; ============================================================
;;; Server Lifecycle
;;; ============================================================

(defmethod server-start ((server mcp-server) &key transport)
  "Start the server.

Parameters:
  SERVER    - MCP server
  TRANSPORT - Transport to use (overrides server's transport)

Returns:
  T on success"
  (when transport
    (setf (server-transport server) transport))

  (unless (server-transport server)
    (error "No transport configured"))

  (transport-connect (server-transport server))

  ;; Set up message handler
  (transport-set-handler
   (server-transport server)
   (lambda (message)
     (cond
       ((request-p message)
        (server-handle-request server message))

       ((notification-p message)
        (server-handle-notification server message)
        nil)

       (t
        nil))))

  (setf (server-running-p server) t)
  t)

(defmethod server-stop ((server mcp-server))
  "Stop the server.

Returns:
  T on success"
  (setf (server-running-p server) nil)
  (when (server-transport server)
    (transport-disconnect (server-transport server)))
  t)

;;; ============================================================
;;; Kernel Integration
;;; ============================================================

(defmethod server-register-kernel-tools ((server mcp-server) kernel)
  "Register all tools from a Kernel with the server.

Parameters:
  SERVER - MCP server
  KERNEL - CL-Agent Kernel instance

Returns:
  Number of tools registered"
  (let ((count 0))
    ;; Get tools from kernel and register them
    ;; This depends on the Kernel API
    (dolist (tool (kernel-list-tools kernel))
      (let ((name (tool-name tool))
            (desc (tool-description tool))
            (schema (tool-schema tool))
            (handler (getf tool :handler)))  ;; tool-handler not defined, use plist access
        (server-register-tool
         server
         (make-mcp-tool name
                        :description desc
                        :input-schema schema
                        :handler (lambda (args)
                                   (funcall handler args))))
        (incf count)))
    count))

