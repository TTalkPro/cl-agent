;;;; server/main.lisp
;;;; CL-Agent MCP - Server Entry Point
;;;;
;;;; Overview:
;;;;   Main entry point for running an MCP server, with support
;;;;   for stdio transport and easy configuration.

(in-package #:cl-agent.mcp)

;;; ============================================================
;;; Server Runner
;;; ============================================================

(defun run-mcp-server (server &key (transport :stdio))
  "Run an MCP server with the specified transport.

Parameters:
  SERVER    - MCP server instance
  TRANSPORT - Transport type (:stdio or transport instance)

Returns:
  Never returns (runs server loop)"

  ;; Set up transport
  (let ((transport-instance
          (case transport
            (:stdio (make-stdio-transport))
            (otherwise transport))))

    (setf (server-transport server) transport-instance)

    ;; Connect transport
    (transport-connect transport-instance)
    (setf (server-running-p server) t)

    (format *error-output* "~&[MCP] Server started: ~A v~A~%"
            (server-name server)
            (server-version server))
    (force-output *error-output*)

    ;; Main server loop
    (unwind-protect
         (server-loop server)
      (progn
        (format *error-output* "~&[MCP] Server stopping~%")
        (force-output *error-output*)
        (server-stop server)))))

(defun server-loop (server)
  "Main server loop - read and process messages."
  (let ((transport (server-transport server)))
    (loop while (server-running-p server)
          do (handler-case
                 (let ((message-str (transport-receive transport :timeout 1)))
                   (when (and message-str (> (length message-str) 0))
                     (let* ((message (parse-json-rpc message-str))
                            (response (process-server-message server message)))
                       (when response
                         (transport-send transport response)))))

               (error (e)
                 (format *error-output* "~&[MCP] Error: ~A~%" e)
                 (force-output *error-output*))))))

(defun process-server-message (server message)
  "Process a single message and return response (if any)."
  (cond
    ((request-p message)
     (server-handle-request server message))

    ((notification-p message)
     (server-handle-notification server message)
     nil)

    ((response-p message)
     ;; Unexpected response - log and ignore
     (format *error-output* "~&[MCP] Unexpected response received~%")
     nil)

    (t
     (make-rpc-error nil +invalid-request+ "Invalid message"))))

;;; ============================================================
;;; Stdio Server Convenience
;;; ============================================================

(defun start-stdio-server (&key name version tools resources prompts)
  "Start a stdio MCP server with the given configuration.

Parameters:
  NAME      - Server name
  VERSION   - Server version
  TOOLS     - List of tools to register
  RESOURCES - List of resources to register
  PROMPTS   - List of prompts to register

Example:
  (start-stdio-server
   :name \"my-server\"
   :tools (list (make-mcp-tool \"hello\"
                  :description \"Say hello\"
                  :handler (lambda (args) \"Hello!\"))))"

  (let ((server (make-mcp-server
                 :name (or name "cl-agent-mcp-server")
                 :version (or version +mcp-version+))))

    ;; Register tools
    (dolist (tool tools)
      (server-register-tool server tool))

    ;; Register resources
    (dolist (resource resources)
      (if (consp resource)
          (server-register-resource server (car resource) :handler (cdr resource))
          (server-register-resource server resource)))

    ;; Register prompts
    (dolist (prompt prompts)
      (server-register-prompt server prompt))

    ;; Run server
    (run-mcp-server server :transport :stdio)))

;;; ============================================================
;;; Server Builder
;;; ============================================================

(defclass mcp-server-builder ()
  ((name
    :initarg :name
    :accessor builder-name
    :initform "cl-agent-mcp-server")

   (version
    :initarg :version
    :accessor builder-version
    :initform +mcp-version+)

   (tools
    :initform nil
    :accessor builder-tools)

   (resources
    :initform nil
    :accessor builder-resources)

   (prompts
    :initform nil
    :accessor builder-prompts))
  (:documentation "Builder for MCP servers."))

(defun create-server-builder (&key name version)
  "Create a server builder."
  (make-instance 'mcp-server-builder
                 :name (or name "cl-agent-mcp-server")
                 :version (or version +mcp-version+)))

(defmethod builder-add-tool ((builder mcp-server-builder) tool)
  "Add a tool to the builder."
  (push tool (builder-tools builder))
  builder)

(defmethod builder-add-resource ((builder mcp-server-builder) resource &key handler)
  "Add a resource to the builder."
  (push (cons resource handler) (builder-resources builder))
  builder)

(defmethod builder-add-prompt ((builder mcp-server-builder) prompt)
  "Add a prompt to the builder."
  (push prompt (builder-prompts builder))
  builder)

(defmethod builder-build ((builder mcp-server-builder))
  "Build the MCP server."
  (let ((server (make-mcp-server
                 :name (builder-name builder)
                 :version (builder-version builder))))

    ;; Register tools
    (dolist (tool (nreverse (builder-tools builder)))
      (server-register-tool server tool))

    ;; Register resources
    (dolist (res-entry (nreverse (builder-resources builder)))
      (server-register-resource server (car res-entry)
                                :handler (cdr res-entry)))

    ;; Register prompts
    (dolist (prompt (nreverse (builder-prompts builder)))
      (server-register-prompt server prompt))

    server))

;;; ============================================================
;;; Quick Tool Definition Macro
;;; ============================================================

(defmacro define-mcp-tool (name (&rest params) &body body)
  "Define an MCP tool with automatic schema generation.

Parameters:
  NAME   - Tool name (symbol or string)
  PARAMS - Parameter specs: (name type &optional description required)
  BODY   - Tool implementation

Example:
  (define-mcp-tool greet ((name string \"Name to greet\" t))
    (format nil \"Hello, ~A!\" name))"
  (let ((name-str (if (stringp name) name (string-downcase (symbol-name name))))
        (args-sym (gensym "ARGS")))
    `(make-mcp-tool
      ,name-str
      :input-schema ,(build-tool-schema params)
      :handler (lambda (,args-sym)
                 (let (,@(mapcar (lambda (p)
                                   (let ((pname (first p)))
                                     `(,pname (gethash ,(string-downcase (symbol-name pname))
                                                       ,args-sym))))
                                 params))
                   ,@body)))))

(defun build-tool-schema (params)
  "Build JSON Schema from parameter specs."
  (let ((schema (make-hash-table :test 'equal))
        (properties (make-hash-table :test 'equal))
        (required nil))
    (setf (gethash "type" schema) "object")

    (dolist (param params)
      (destructuring-bind (name type &optional description required-p) param
        (let ((prop (make-hash-table :test 'equal))
              (name-str (string-downcase (symbol-name name))))
          (setf (gethash "type" prop) (string-downcase (symbol-name type)))
          (when description
            (setf (gethash "description" prop) description))
          (setf (gethash name-str properties) prop)
          (when required-p
            (push name-str required)))))

    (setf (gethash "properties" schema) properties)
    (when required
      (setf (gethash "required" schema) (coerce (nreverse required) 'vector)))

    schema))

;;; ============================================================
;;; Example Server
;;; ============================================================

(defun create-example-server ()
  "Create an example MCP server for testing."
  (let ((server (make-mcp-server :name "example-server"
                                  :version "1.0.0")))

    ;; Add a simple tool
    (server-register-tool
     server
     (make-mcp-tool "echo"
                    :description "Echo the input back"
                    :input-schema (let ((schema (make-hash-table :test 'equal))
                                        (props (make-hash-table :test 'equal))
                                        (msg (make-hash-table :test 'equal)))
                                    (setf (gethash "type" schema) "object")
                                    (setf (gethash "type" msg) "string")
                                    (setf (gethash "description" msg) "Message to echo")
                                    (setf (gethash "message" props) msg)
                                    (setf (gethash "properties" schema) props)
                                    (setf (gethash "required" schema) #("message"))
                                    schema)
                    :handler (lambda (args)
                               (gethash "message" args))))

    ;; Add a simple resource
    (server-register-resource
     server
     (make-resource "file:///example.txt" "Example File"
                    :description "An example text file"
                    :mime-type "text/plain")
     :handler (lambda (uri)
                (declare (ignore uri))
                "This is example content."))

    ;; Add a simple prompt
    (server-register-prompt
     server
     (make-mcp-prompt "greeting"
                      :description "Generate a greeting"
                      :arguments (list (let ((arg (make-hash-table :test 'equal)))
                                         (setf (gethash "name" arg) "name")
                                         (setf (gethash "description" arg) "Name to greet")
                                         (setf (gethash "required" arg) t)
                                         arg))
                      :template (lambda (args)
                                  (format nil "Please greet ~A warmly."
                                          (gethash "name" args "user")))))

    server))

