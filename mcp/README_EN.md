# MCP Module

[中文](README.md) | English

Model Context Protocol implementation module.

## Directory Structure

```
mcp/
├── package.lisp              # Package definition
├── protocol.lisp             # Protocol definition
├── json-rpc.lisp             # JSON-RPC 2.0 implementation
├── transport/                # Transport layer
│   ├── base.lisp            # Base transport interface
│   ├── stdio.lisp           # Standard I/O
│   └── sse.lisp             # Server-Sent Events
├── client/
│   └── core.lisp            # MCP client
└── server/
    ├── core.lisp            # MCP server core
    └── main.lisp            # MCP server entry point
```

## MCP Overview

MCP (Model Context Protocol) is a standardized protocol for:
- Communication between AI models and external tools
- Context information passing
- Resource access and management

## JSON-RPC Messages

### Request

```lisp
(defclass mcp-request ()
  ((jsonrpc :initform "2.0")
   (id :accessor request-id)
   (method :accessor request-method)
   (params :accessor request-params)))

;; Create request
(make-mcp-request
  :id "1"
  :method "tools/call"
  :params '(:name "get-weather" :arguments (:city "Tokyo")))
```

### Response

```lisp
(defclass mcp-response ()
  ((jsonrpc :initform "2.0")
   (id :accessor response-id)
   (result :accessor response-result)
   (error :accessor response-error)))

;; Success response
(make-mcp-response
  :id "1"
  :result '(:content "Weather in Tokyo: 22°C"))

;; Error response
(make-mcp-response
  :id "1"
  :error '(:code -32600 :message "Invalid Request"))
```

### Notification

```lisp
(defclass mcp-notification ()
  ((jsonrpc :initform "2.0")
   (method :accessor notification-method)
   (params :accessor notification-params)))

(make-mcp-notification
  :method "notifications/message"
  :params '(:level "info" :message "Processing..."))
```

## Transport Layer

### STDIO Transport

Communication via standard I/O:

```lisp
(defvar *transport*
  (make-stdio-transport))

;; Send message
(transport-send *transport* message)

;; Receive message
(transport-receive *transport*)

;; Close
(transport-close *transport*)
```

### SSE Transport

Communication via Server-Sent Events:

```lisp
(defvar *transport*
  (make-sse-transport
    :url "http://localhost:8080/events"))

;; Connect
(transport-connect *transport*)

;; Listen for events
(transport-on-event *transport*
  (lambda (event)
    (format t "Received event: ~A~%" event)))
```

## MCP Client

### Creating Client

```lisp
(defvar *client*
  (make-mcp-client
    :transport (make-stdio-transport)))

;; Connect
(mcp-client-connect *client*)
```

### Initialization

```lisp
;; Send initialize request
(mcp-client-initialize *client*
  :protocol-version "2024-11-05"
  :capabilities '(:tools t :resources t)
  :client-info '(:name "cl-agent" :version "1.0.0"))
```

### Tool Operations

```lisp
;; List available tools
(mcp-client-list-tools *client*)
;; => ((:name "get-weather" :description "Get weather" :input-schema {...})
;;     (:name "search" :description "Search" :input-schema {...}))

;; Call tool
(mcp-client-call-tool *client* "get-weather"
  '(:city "Tokyo"))
;; => (:content "Weather in Tokyo: 22°C, sunny")
```

### Resource Operations

```lisp
;; List resources
(mcp-client-list-resources *client*)
;; => ((:uri "file:///docs/readme.md" :name "README" :mime-type "text/markdown"))

;; Read resource
(mcp-client-read-resource *client* "file:///docs/readme.md")
;; => (:contents "# README\n...")
```

### Prompt Operations

```lisp
;; List prompts
(mcp-client-list-prompts *client*)

;; Get prompt
(mcp-client-get-prompt *client* "code-review"
  '(:language "lisp"))
```

## MCP Server

### Creating Server

```lisp
(defvar *server*
  (make-mcp-server
    :transport (make-stdio-transport)
    :name "my-mcp-server"
    :version "1.0.0"))
```

### Registering Tools

```lisp
;; Register tool
(mcp-register-tool *server* "get-weather"
  :description "Get weather for specified city"
  :input-schema '(:type "object"
                  :properties (:city (:type "string"
                                      :description "City name"))
                  :required ("city"))
  :handler (lambda (args)
             (let ((city (getf args :city)))
               `(:content ,(format nil "~A: 22°C" city)))))

;; Register tool with validation
(mcp-register-tool *server* "calculate"
  :description "Perform calculation"
  :input-schema '(:type "object"
                  :properties (:expression (:type "string")))
  :validator (lambda (args)
               (handler-case
                   (progn (read-from-string (getf args :expression)) t)
                 (error () nil)))
  :handler #'handle-calculate)
```

### Registering Resources

```lisp
;; Static resource
(mcp-register-resource *server*
  :uri "file:///config.json"
  :name "Configuration"
  :mime-type "application/json"
  :handler (lambda ()
             (read-file-into-string "/path/to/config.json")))

;; Dynamic resource
(mcp-register-resource-template *server*
  :uri-template "db://records/{id}"
  :name "Database Record"
  :handler (lambda (params)
             (get-record (getf params :id))))
```

### Registering Prompts

```lisp
(mcp-register-prompt *server* "code-review"
  :description "Code review prompt"
  :arguments '((:name "language" :description "Programming language" :required t))
  :handler (lambda (args)
             `(:messages ((:role "user"
                           :content ,(format nil "Please review the following ~A code:"
                                            (getf args :language)))))))
```

### Starting Server

```lisp
;; Start (blocking)
(mcp-server-start *server*)

;; Start in background
(mcp-server-start-async *server*)

;; Stop
(mcp-server-stop *server*)
```

## Integration with Kernel

### As Tool Provider

```lisp
;; Get tools from MCP server
(defvar *mcp-tools*
  (mcp-client-list-tools *client*))

;; Create MCP tool plugin
(defvar *mcp-plugin*
  (make-mcp-plugin *client*))

;; Add to Kernel
(defvar *kernel*
  (make-kernel
    :service *service*
    :plugins (list *mcp-plugin*)))
```

### Exposing Kernel Tools

```lisp
;; Expose Kernel plugin as MCP tools
(mcp-expose-plugin *server* 'my-plugin)

;; Or expose all tools
(mcp-expose-kernel *server* *kernel*)
```

## Error Handling

```lisp
;; MCP standard error codes
-32700  ; Parse error
-32600  ; Invalid Request
-32601  ; Method not found
-32602  ; Invalid params
-32603  ; Internal error

;; Handle errors
(handler-case
    (mcp-client-call-tool *client* "unknown-tool" '())
  (mcp-error (e)
    (format t "MCP error: ~A (code: ~A)~%"
            (mcp-error-message e)
            (mcp-error-code e))))
```

## Usage Examples

### Weather Service MCP Server

```lisp
(defvar *weather-server*
  (make-mcp-server
    :transport (make-stdio-transport)
    :name "weather-service"
    :version "1.0.0"))

(mcp-register-tool *weather-server* "get-weather"
  :description "Get weather information"
  :input-schema '(:type "object"
                  :properties (:city (:type "string")
                               :unit (:type "string"
                                      :enum ("celsius" "fahrenheit")))
                  :required ("city"))
  :handler (lambda (args)
             (let ((city (getf args :city))
                   (unit (or (getf args :unit) "celsius")))
               ;; Call weather API
               `(:content ,(get-weather-from-api city unit)))))

(mcp-register-tool *weather-server* "get-forecast"
  :description "Get weather forecast"
  :input-schema '(:type "object"
                  :properties (:city (:type "string")
                               :days (:type "integer")))
  :handler #'handle-forecast)

(mcp-server-start *weather-server*)
```

### Agent Connected to MCP Service

```lisp
;; Connect to MCP server
(defvar *mcp-client*
  (make-mcp-client
    :transport (make-stdio-transport
                 :command '("node" "weather-server.js"))))

(mcp-client-connect *mcp-client*)
(mcp-client-initialize *mcp-client*)

;; Create Agent with MCP tools
(defvar *agent*
  (make-kernel-agent
    (make-kernel
      :service *service*
      :plugins (list (make-mcp-plugin *mcp-client*)))
    :system-prompt "You can query weather information."))

(agent-chat *agent* "What's the weather in Beijing tomorrow?")
```
