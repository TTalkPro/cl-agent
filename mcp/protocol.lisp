;;;; protocol.lisp
;;;; CL-Agent MCP - Protocol Definitions
;;;;
;;;; Overview:
;;;;   Core MCP protocol type definitions and structures.
;;;;
;;;; Reference:
;;;;   https://spec.modelcontextprotocol.io/

(in-package #:cl-agent.mcp)

;;; ============================================================
;;; Protocol Version
;;; ============================================================

;; Use alexandria's define-constant to avoid SBCL redefinition warning
(eval-when (:compile-toplevel :load-toplevel :execute)
  (defun constant-equal-p (a b)
    (or (eq a b) (equal a b))))

(defconstant +mcp-version+
  (if (boundp '+mcp-version+)
      (symbol-value '+mcp-version+)
      "1.0.0")
  "MCP implementation version.")

(defconstant +mcp-protocol-version+
  (if (boundp '+mcp-protocol-version+)
      (symbol-value '+mcp-protocol-version+)
      "2024-11-05")
  "MCP protocol version.")

;;; ============================================================
;;; Base Message Types
;;; ============================================================

(defclass mcp-message ()
  ((jsonrpc
    :initarg :jsonrpc
    :accessor message-jsonrpc
    :initform "2.0"
    :type string
    :documentation "JSON-RPC version"))
  (:documentation "Base class for all MCP messages."))

(defclass mcp-request (mcp-message)
  ((id
    :initarg :id
    :accessor message-id
    :type (or string integer)
    :documentation "Request ID")

   (method
    :initarg :method
    :accessor message-method
    :type string
    :documentation "Method name")

   (params
    :initarg :params
    :accessor message-params
    :initform nil
    :documentation "Request parameters"))
  (:documentation "MCP request message."))

(defclass mcp-response (mcp-message)
  ((id
    :initarg :id
    :accessor message-id
    :type (or string integer null)
    :documentation "Response ID (matches request)")

   (result
    :initarg :result
    :accessor message-result
    :initform nil
    :documentation "Result value")

   (error
    :initarg :error
    :accessor message-error
    :initform nil
    :documentation "Error object if failed"))
  (:documentation "MCP response message."))

(defclass mcp-notification (mcp-message)
  ((method
    :initarg :method
    :accessor message-method
    :type string
    :documentation "Notification method")

   (params
    :initarg :params
    :accessor message-params
    :initform nil
    :documentation "Notification parameters"))
  (:documentation "MCP notification (no response expected)."))

(defclass mcp-error ()
  ((code
    :initarg :code
    :accessor error-code
    :type integer
    :documentation "Error code")

   (message
    :initarg :message
    :accessor error-message
    :type string
    :documentation "Error message")

   (data
    :initarg :data
    :accessor error-data
    :initform nil
    :documentation "Additional error data"))
  (:documentation "MCP error object."))

;;; ============================================================
;;; Capability
;;; ============================================================

(defclass mcp-capability ()
  ((name
    :initarg :name
    :accessor capability-name
    :type string
    :documentation "Capability name")

   (version
    :initarg :version
    :accessor capability-version
    :initform nil
    :type (or null string)
    :documentation "Capability version")

   (options
    :initarg :options
    :accessor capability-options
    :initform nil
    :documentation "Capability options"))
  (:documentation "MCP capability declaration."))

(defun make-capability (name &key version options)
  "Create a capability instance."
  (make-instance 'mcp-capability
                 :name name
                 :version version
                 :options options))

;;; ============================================================
;;; Server Info
;;; ============================================================

(defclass mcp-server-info ()
  ((name
    :initarg :name
    :accessor server-info-name
    :type string
    :documentation "Server name")

   (version
    :initarg :version
    :accessor server-info-version
    :type string
    :documentation "Server version")

   (protocol-version
    :initarg :protocol-version
    :accessor server-info-protocol-version
    :initform +mcp-protocol-version+
    :type string
    :documentation "Protocol version")

   (capabilities
    :initarg :capabilities
    :accessor server-info-capabilities
    :initform nil
    :type list
    :documentation "List of capabilities"))
  (:documentation "MCP server information."))

(defun make-server-info (name version &key capabilities)
  "Create server info instance."
  (make-instance 'mcp-server-info
                 :name name
                 :version version
                 :capabilities capabilities))

;;; ============================================================
;;; Client Info
;;; ============================================================

(defclass mcp-client-info ()
  ((name
    :initarg :name
    :accessor client-info-name
    :type string
    :documentation "Client name")

   (version
    :initarg :version
    :accessor client-info-version
    :type string
    :documentation "Client version")

   (capabilities
    :initarg :capabilities
    :accessor client-info-capabilities
    :initform nil
    :type list
    :documentation "Client capabilities"))
  (:documentation "MCP client information."))

(defun make-client-info (name version &key capabilities)
  "Create client info instance."
  (make-instance 'mcp-client-info
                 :name name
                 :version version
                 :capabilities capabilities))

;;; ============================================================
;;; Resource
;;; ============================================================

(defclass mcp-resource ()
  ((uri
    :initarg :uri
    :accessor resource-uri
    :type string
    :documentation "Resource URI")

   (name
    :initarg :name
    :accessor resource-name
    :type string
    :documentation "Resource name")

   (description
    :initarg :description
    :accessor resource-description
    :initform nil
    :type (or null string)
    :documentation "Resource description")

   (mime-type
    :initarg :mime-type
    :accessor resource-mime-type
    :initform "text/plain"
    :type string
    :documentation "MIME type"))
  (:documentation "MCP resource definition."))

(defun make-resource (uri name &key description (mime-type "text/plain"))
  "Create a resource instance."
  (make-instance 'mcp-resource
                 :uri uri
                 :name name
                 :description description
                 :mime-type mime-type))

;;; ============================================================
;;; Tool
;;; ============================================================

(defclass mcp-tool ()
  ((name
    :initarg :name
    :accessor mcp-tool-name
    :type string
    :documentation "Tool name")

   (description
    :initarg :description
    :accessor mcp-tool-description
    :initform nil
    :type (or null string)
    :documentation "Tool description")

   (input-schema
    :initarg :input-schema
    :accessor mcp-tool-input-schema
    :initform nil
    :documentation "JSON Schema for input")

   (handler
    :initarg :handler
    :accessor mcp-tool-handler
    :initform nil
    :type (or null function)
    :documentation "Tool handler function"))
  (:documentation "MCP tool definition."))

(defun make-mcp-tool (name &key description input-schema handler)
  "Create an MCP tool instance."
  (make-instance 'mcp-tool
                 :name name
                 :description description
                 :input-schema input-schema
                 :handler handler))

;;; ============================================================
;;; Prompt
;;; ============================================================

(defclass mcp-prompt ()
  ((name
    :initarg :name
    :accessor prompt-name
    :type string
    :documentation "Prompt name")

   (description
    :initarg :description
    :accessor prompt-description
    :initform nil
    :type (or null string)
    :documentation "Prompt description")

   (arguments
    :initarg :arguments
    :accessor prompt-arguments
    :initform nil
    :type list
    :documentation "Prompt argument definitions")

   (template
    :initarg :template
    :accessor prompt-template
    :initform nil
    :type (or null string function)
    :documentation "Prompt template or generator"))
  (:documentation "MCP prompt definition."))

(defun make-mcp-prompt (name &key description arguments template)
  "Create an MCP prompt instance."
  (make-instance 'mcp-prompt
                 :name name
                 :description description
                 :arguments arguments
                 :template template))

;;; ============================================================
;;; Protocol Methods
;;; ============================================================

(defparameter *mcp-methods*
  '(;; Lifecycle
    "initialize"
    "initialized"
    "shutdown"

    ;; Tools
    "tools/list"
    "tools/call"

    ;; Resources
    "resources/list"
    "resources/read"
    "resources/subscribe"
    "resources/unsubscribe"

    ;; Prompts
    "prompts/list"
    "prompts/get"

    ;; Logging
    "logging/setLevel"

    ;; Notifications
    "notifications/initialized"
    "notifications/progress"
    "notifications/message"
    "notifications/resources/updated"
    "notifications/resources/list_changed"
    "notifications/tools/list_changed"
    "notifications/prompts/list_changed")
  "Standard MCP method names.")

;;; ============================================================
;;; Serialization Helpers
;;; ============================================================

(defgeneric to-json-object (object)
  (:documentation "Convert MCP object to JSON-compatible hash table."))

(defmethod to-json-object ((cap mcp-capability))
  (let ((obj (make-hash-table :test 'equal)))
    (setf (gethash "name" obj) (capability-name cap))
    (when (capability-version cap)
      (setf (gethash "version" obj) (capability-version cap)))
    (when (capability-options cap)
      (setf (gethash "options" obj) (capability-options cap)))
    obj))

(defmethod to-json-object ((info mcp-server-info))
  (let ((obj (make-hash-table :test 'equal)))
    (setf (gethash "name" obj) (server-info-name info))
    (setf (gethash "version" obj) (server-info-version info))
    (setf (gethash "protocolVersion" obj) (server-info-protocol-version info))
    (when (server-info-capabilities info)
      (setf (gethash "capabilities" obj)
            (let ((caps (make-hash-table :test 'equal)))
              (dolist (cap (server-info-capabilities info))
                (setf (gethash (capability-name cap) caps)
                      (capability-options cap)))
              caps)))
    obj))

(defmethod to-json-object ((res mcp-resource))
  (let ((obj (make-hash-table :test 'equal)))
    (setf (gethash "uri" obj) (resource-uri res))
    (setf (gethash "name" obj) (resource-name res))
    (when (resource-description res)
      (setf (gethash "description" obj) (resource-description res)))
    (setf (gethash "mimeType" obj) (resource-mime-type res))
    obj))

(defmethod to-json-object ((tool mcp-tool))
  (let ((obj (make-hash-table :test 'equal)))
    (setf (gethash "name" obj) (mcp-tool-name tool))
    (when (mcp-tool-description tool)
      (setf (gethash "description" obj) (mcp-tool-description tool)))
    (when (mcp-tool-input-schema tool)
      (setf (gethash "inputSchema" obj) (mcp-tool-input-schema tool)))
    obj))

(defmethod to-json-object ((prompt mcp-prompt))
  (let ((obj (make-hash-table :test 'equal)))
    (setf (gethash "name" obj) (prompt-name prompt))
    (when (prompt-description prompt)
      (setf (gethash "description" obj) (prompt-description prompt)))
    (when (prompt-arguments prompt)
      (setf (gethash "arguments" obj) (prompt-arguments prompt)))
    obj))

(defmethod to-json-object ((err mcp-error))
  (let ((obj (make-hash-table :test 'equal)))
    (setf (gethash "code" obj) (error-code err))
    (setf (gethash "message" obj) (error-message err))
    (when (error-data err)
      (setf (gethash "data" obj) (error-data err)))
    obj))

