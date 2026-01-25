# Protocols Module

[中文](README.md) | English

Protocol support module providing MCP and A2A (Agent-to-Agent) communication protocol implementations.

## Directory Structure

```
protocols/
├── package-protocols.lisp    # Package definition
├── mcp.lisp                  # MCP protocol
├── mcp-client.lisp           # MCP client
├── mcp-server.lisp           # MCP server
├── a2a-types.lisp            # A2A type definitions
├── a2a-endpoint.lisp         # A2A endpoint
├── a2a-bus.lisp              # A2A message bus
├── a2a-messaging.lisp        # A2A messaging
├── a2a-handlers.lisp         # A2A handlers
├── a2a-listeners.lisp        # A2A listeners
├── a2a-service.lisp          # A2A service
└── a2a.lisp                  # A2A entry point
```

## MCP Protocol

See [MCP Module Documentation](../mcp/README_EN.md).

## A2A Protocol

A2A (Agent-to-Agent) is a protocol for inter-Agent communication.

### Core Concepts

```
┌─────────┐         ┌─────────┐
│ Agent A │ ←─────→ │ Agent B │
└─────────┘   A2A   └─────────┘
     ↓                   ↓
┌─────────────────────────────┐
│        Message Bus          │
└─────────────────────────────┘
     ↓         ↓         ↓
┌─────────┐ ┌─────────┐ ┌─────────┐
│Handler 1│ │Handler 2│ │Handler 3│
└─────────┘ └─────────┘ └─────────┘
```

### A2A Messages

```lisp
;; Message structure
(defstruct a2a-message
  id              ; Message ID
  from            ; Sender Agent ID
  to              ; Receiver Agent ID (optional, nil for broadcast)
  type            ; Message type
  content         ; Message content
  correlation-id  ; Correlation ID (for request-response)
  timestamp       ; Timestamp
  metadata)       ; Metadata

;; Create message
(make-a2a-message
  :from "agent-a"
  :to "agent-b"
  :type :request
  :content '(:action "analyze" :data "..."))
```

### Message Types

```lisp
:request    ; Request message (expects response)
:response   ; Response message
:notify     ; Notification message (no response expected)
:broadcast  ; Broadcast message
:error      ; Error message
```

## A2A Endpoint

### Creating Endpoint

```lisp
(defvar *endpoint*
  (make-a2a-endpoint
    :id "my-agent"
    :name "My Agent"
    :capabilities '(:chat :tools :rag)))
```

### Registering Handlers

```lisp
;; Handle specific message types
(a2a-register-handler *endpoint* :request
  (lambda (message)
    (let ((action (getf (a2a-message-content message) :action)))
      (case (intern (string-upcase action) :keyword)
        (:analyze (handle-analyze message))
        (:summarize (handle-summarize message))
        (t (make-error-response "Unknown action"))))))

;; Handle all messages
(a2a-register-handler *endpoint* :all
  (lambda (message)
    (format t "Received message: ~A~%" message)))
```

### Sending Messages

```lisp
;; Send request (wait for response)
(let ((response (a2a-request *endpoint* "other-agent"
                  '(:action "analyze" :data "..."))))
  (format t "Response: ~A~%" response))

;; Send notification (don't wait for response)
(a2a-notify *endpoint* "other-agent"
  '(:event "task-completed" :result "..."))

;; Broadcast
(a2a-broadcast *endpoint*
  '(:announcement "New capability available"))
```

## A2A Message Bus

### Creating Message Bus

```lisp
(defvar *bus* (make-a2a-bus))

;; Register endpoints
(a2a-bus-register *bus* *endpoint-a*)
(a2a-bus-register *bus* *endpoint-b*)
(a2a-bus-register *bus* *endpoint-c*)
```

### Message Routing

```lisp
;; Point-to-point
(a2a-bus-send *bus*
  (make-a2a-message :from "a" :to "b" :content "..."))

;; Broadcast
(a2a-bus-broadcast *bus*
  (make-a2a-message :from "a" :content "..."))

;; Route by capability
(a2a-bus-route-by-capability *bus* :rag
  (make-a2a-message :from "a" :content "..."))
```

### Subscription Pattern

```lisp
;; Subscribe to specific topics
(a2a-bus-subscribe *bus* "agent-a" "news/*")
(a2a-bus-subscribe *bus* "agent-b" "alerts/critical")

;; Publish to topic
(a2a-bus-publish *bus* "news/tech"
  (make-a2a-message :content '(:headline "...")))
```

## A2A Service

### Creating Service

```lisp
(defvar *service*
  (make-a2a-service
    :endpoint *endpoint*
    :bus *bus*))

;; Start service
(a2a-service-start *service*)
```

### Service Discovery

```lisp
;; Discover other Agents
(a2a-service-discover *service*)
;; => ((:id "agent-b" :name "Agent B" :capabilities (:chat :tools))
;;     (:id "agent-c" :name "Agent C" :capabilities (:rag)))

;; Find by capability
(a2a-service-find-by-capability *service* :rag)
;; => ((:id "agent-c" ...))
```

### Health Check

```lisp
;; Check Agent status
(a2a-service-ping *service* "agent-b")
;; => (:status :alive :latency 50)

;; Check all
(a2a-service-health-check *service*)
;; => ((:id "agent-b" :status :alive)
;;     (:id "agent-c" :status :unreachable))
```

## Integration with Kernel

### Creating A2A Agent

```lisp
(defvar *kernel* (make-kernel :service *llm-service*))

(defvar *a2a-agent*
  (make-a2a-agent *kernel*
    :id "smart-agent"
    :name "Smart Agent"
    :capabilities '(:chat :tools :reasoning)))

;; Register to bus
(a2a-bus-register *bus* (a2a-agent-endpoint *a2a-agent*))
```

### Handling A2A Requests

```lisp
;; Auto-forward A2A requests to Kernel
(a2a-agent-enable-auto-dispatch *a2a-agent*)

;; Or custom handling
(a2a-agent-on-request *a2a-agent*
  (lambda (message)
    (let ((content (a2a-message-content message)))
      (agent-chat (a2a-agent-kernel-agent *a2a-agent*)
                  (getf content :query)))))
```

### Delegating to Other Agents

```lisp
;; Delegate task to other Agents
(defun delegate-to-rag-agent (query)
  (let ((rag-agents (a2a-service-find-by-capability *service* :rag)))
    (when rag-agents
      (a2a-request (a2a-agent-endpoint *a2a-agent*)
                   (getf (first rag-agents) :id)
                   `(:action "search" :query ,query)))))
```

## Usage Examples

### Multi-Agent Collaboration

```lisp
;; Create specialized Agents
(defvar *research-agent*
  (make-a2a-agent *research-kernel*
    :id "researcher"
    :capabilities '(:research :web-search)))

(defvar *writer-agent*
  (make-a2a-agent *writer-kernel*
    :id "writer"
    :capabilities '(:writing :summarization)))

(defvar *coordinator-agent*
  (make-a2a-agent *coordinator-kernel*
    :id "coordinator"
    :capabilities '(:coordination :planning)))

;; Register to bus
(dolist (agent (list *research-agent* *writer-agent* *coordinator-agent*))
  (a2a-bus-register *bus* (a2a-agent-endpoint agent)))

;; Coordinator assigns tasks
(defun coordinate-article (topic)
  ;; 1. Have research Agent collect information
  (let ((research-result
          (a2a-request (a2a-agent-endpoint *coordinator-agent*)
                       "researcher"
                       `(:action "research" :topic ,topic))))
    ;; 2. Have writer Agent write article
    (a2a-request (a2a-agent-endpoint *coordinator-agent*)
                 "writer"
                 `(:action "write-article"
                   :topic ,topic
                   :research ,(getf research-result :data)))))
```

### Load Balancing

```lisp
;; Create multiple worker Agents
(defvar *workers*
  (loop for i from 1 to 5
        collect (make-a2a-agent (make-kernel :service *service*)
                  :id (format nil "worker-~A" i)
                  :capabilities '(:processing))))

;; Load balancer
(defvar *load-balancer*
  (make-a2a-load-balancer
    :strategy :round-robin  ; Or :least-connections, :random
    :agents *workers*))

;; Dispatch tasks
(a2a-lb-dispatch *load-balancer*
  '(:action "process" :data "..."))
```

### Event-Driven Architecture

```lisp
;; Define events
(a2a-define-event :task-completed
  :schema '(:task-id :string
            :result :any
            :duration :number))

;; Subscribe to events
(a2a-subscribe *endpoint* :task-completed
  (lambda (event)
    (format t "Task ~A completed, took ~A ms~%"
            (getf event :task-id)
            (getf event :duration))))

;; Publish events
(a2a-publish *endpoint* :task-completed
  '(:task-id "task-123"
    :result "success"
    :duration 1500))
```
