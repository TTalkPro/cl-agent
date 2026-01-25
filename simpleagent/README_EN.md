# SimpleAgent Module

[中文](README.md) | English

Simple Agent implementation module providing ready-to-use Agent classes.

## Directory Structure

```
simpleagent/
├── package.lisp        # Package definition
├── common.lisp         # Base Agent class and protocol
├── kernel-agent.lisp   # KernelAgent implementation
└── process-agent.lisp  # ProcessAgent implementation
```

## Agent Types

| Type | Description | Use Case |
|------|-------------|----------|
| KernelAgent | Simple chat loop Agent | Basic conversation, tool calling |
| ProcessAgent | Pausable/resumable Agent | Long-running tasks, background execution |

## KernelAgent

### Basic Usage

```lisp
;; Create Agent
(defvar *agent*
  (make-kernel-agent *kernel*
    :name "my-assistant"
    :system-prompt "You are a helpful assistant."))

;; Chat
(agent-chat *agent* "Hello!")
;; => "Hello! How can I help you?"

;; Multi-turn conversation (context automatically maintained)
(agent-chat *agent* "My name is John")
(agent-chat *agent* "What's my name?")
;; => "Your name is John."
```

### Full Configuration

```lisp
(defvar *agent*
  (make-kernel-agent *kernel*
    :name "advanced-agent"
    :system-prompt "You are a professional data analyst."

    ;; Settings
    :settings '(:max-iterations 10      ; Max tool call rounds
                :temperature 0.7        ; Sampling temperature
                :max-tokens 2048        ; Max output tokens
                :stop-sequences ("END") ; Stop sequences
                :verbose nil)           ; Debug output

    ;; Callbacks
    :callbacks (list
                 :on-message (lambda (msg) (format t "Message: ~A~%" msg))
                 :on-tool-call (lambda (call) (format t "Tool: ~A~%" call))
                 :on-error (lambda (err) (format t "Error: ~A~%" err)))))
```

### Agent with Memory

```lisp
(defvar *memory* (make-agent-memory))

(defvar *agent*
  (make-kernel-agent *kernel*
    :name "memory-agent"
    :memory *memory*
    :system-prompt "Remember user preferences."))

;; Conversations automatically saved to memory
(agent-chat *agent* "I like blue")
(agent-chat *agent* "What color do I like?")
;; => "You like blue."
```

### Getting Agent Information

```lisp
(agent-id *agent*)          ; => "550e8400-..."
(agent-name *agent*)        ; => "my-assistant"
(agent-created-at *agent*)  ; => "2024-01-15T10:30:00Z"
(agent-history *agent*)     ; => Conversation history list
(agent-context *agent*)     ; => Current context
```

### Resetting Conversation

```lisp
;; Clear history, keep configuration
(agent-reset *agent*)

;; Full reinitialization
(agent-reinitialize *agent*)
```

## ProcessAgent

Pausable, resumable, stoppable Agent for long-running tasks. Integrates with core/process framework for event-driven and human-in-the-loop support.

### Basic Usage

```lisp
;; Create
(defvar *process-agent*
  (make-process-agent *kernel*
    :name "background-worker"))

;; Start (non-blocking)
(agent-start *process-agent*)
(agent-send *process-agent* "Analyze this large dataset...")

;; Check state
(agent-state *process-agent*)  ; => :running / :paused / :stopped

;; Pause
(agent-pause *process-agent*)

;; Resume
(agent-resume *process-agent*)

;; Stop
(agent-stop *process-agent*)
```

### Event Injection (Similar to C# Process Framework)

```lisp
;; Create Agent with event handling
(defvar *process-agent*
  (make-process-agent *kernel*
    :name "event-driven-agent"
    :event-handlers
    (list
      (cons :external
            (lambda (event)
              (format t "Received external event: ~A~%"
                      (cl-agent.process:event-data event)))))))

(agent-start *process-agent*)

;; Subscribe to events
(agent-subscribe-event *process-agent* :approval
  (lambda (event)
    (format t "Received approval: ~A~%" (cl-agent.process:event-data event))))

;; Inject external event (similar to C# InputEvent)
(agent-inject-event *process-agent*
  (cl-agent.process:make-event
    :type :external
    :name "data-ready"
    :data '(:file "data.csv" :rows 1000)))

;; Inject approval event
(agent-inject-event *process-agent*
  (cl-agent.process:make-event
    :type :approval
    :data t
    :source "manager"))
```

### Human-in-the-Loop

```lisp
;; Create Agent with human input handling
(defvar *process-agent*
  (make-process-agent *kernel*
    :name "hitl-agent"
    :human-handler
    (lambda (request)
      ;; Forward to UI or other processing
      (format t "Human input needed: ~A~%"
              (cl-agent.process:input-request-prompt request)))))

(agent-start *process-agent*)

;; Request human approval
(let ((request (cl-agent.process:make-input-request
                 :type :approval
                 :prompt "Approve deleting these files?"
                 :description "Will delete 100 temporary files"
                 :timeout 300)))
  (agent-request-input *process-agent* request))

;; View pending human inputs
(agent-get-pending-inputs *process-agent*)

;; Submit human response
(agent-submit-input *process-agent*
  (cl-agent.process:make-input-response request-id
    :value "approved"
    :approved-p t
    :responder "admin"))

;; Convenience function: wait for approval
(when (agent-wait-for-approval *process-agent*
                                "Continue?"
                                :timeout 60)
  (execute-dangerous-operation))

;; Convenience function: wait for confirmation
(when (agent-wait-for-confirmation *process-agent*
                                    "Save changes?"
                                    :default t)
  (save-changes))
```

### Waiting for Completion

```lisp
;; Blocking wait
(agent-wait *process-agent*)

;; Wait with timeout
(agent-wait *process-agent* :timeout 60)  ; 60 second timeout

;; Get result
(agent-result *process-agent*)
```

### State Callbacks

```lisp
(defvar *process-agent*
  (make-process-agent *kernel*
    :on-start (lambda (agent)
                (format t "Agent started~%"))
    :on-pause (lambda (agent)
                (format t "Agent paused~%"))
    :on-resume (lambda (agent)
                 (format t "Agent resumed~%"))
    :on-stop (lambda (agent result)
               (format t "Agent stopped, result: ~A~%" result))
    :on-error (lambda (agent error)
                (format t "Agent error: ~A~%" error))))
```

### Message Queue

```lisp
;; Send message to running Agent
(agent-send *process-agent* "New instructions...")

;; Get Agent output
(agent-receive *process-agent*)  ; Blocking
(agent-receive *process-agent* :timeout 5)  ; 5 second timeout
```

### Step-based Workflow

```lisp
;; Define workflow
(cl-agent.process:defprocess document-approval
  :description "Document approval workflow"

  :steps
  ((submit
    :description "Submit document"
    :handler (lambda (ctx input)
               (cl-agent.process:step-completed :output input)))

   (review
    :description "Review document"
    :wait-for (:approval)
    :timeout 3600
    :handler (lambda (ctx input)
               (if (cl-agent.process:context-get-variable ctx :approved)
                   (cl-agent.process:step-completed :output input)
                   (cl-agent.process:step-failed "Rejected")))))

  :on-event
  ((:approval . (lambda (ctx event)
                  (cl-agent.process:context-set-variable ctx :approved
                    (cl-agent.process:event-data event))))))

;; Create Agent with workflow
(defvar *workflow-agent*
  (make-process-agent *kernel*
    :name "workflow-agent"
    :process document-approval))

(agent-start *workflow-agent*)

;; Start workflow
(agent-start-process *workflow-agent* :input document-data)

;; Inject approval event
(agent-inject-event *workflow-agent*
  (cl-agent.process:make-event :type :approval :data t))

;; Get workflow state
(agent-get-process-state *workflow-agent*)
;; => (:state :running :current-step "review" ...)
```

## Custom Agents

Inherit `base-agent` to create custom Agents:

```lisp
(defclass my-custom-agent (base-agent)
  ((custom-slot :accessor agent-custom-slot
                :initarg :custom-slot)))

(defmethod agent-chat ((agent my-custom-agent) message &key &allow-other-keys)
  ;; Custom chat logic
  ...)

(defmethod agent-reset ((agent my-custom-agent))
  ;; Custom reset logic
  (call-next-method)  ; Call parent method
  ...)
```

## Agent Protocol

All Agents implement the following protocol:

```lisp
;; Basic properties
(defgeneric agent-id (agent))
(defgeneric agent-name (agent))
(defgeneric agent-created-at (agent))
(defgeneric agent-metadata (agent))

;; Core operations
(defgeneric agent-chat (agent message &key &allow-other-keys))
(defgeneric agent-reset (agent))

;; Optional operations (ProcessAgent)
(defgeneric agent-start (agent message))
(defgeneric agent-pause (agent))
(defgeneric agent-resume (agent))
(defgeneric agent-stop (agent))
(defgeneric agent-state (agent))
```

## Usage Examples

### Customer Service Bot

```lisp
(defvar *customer-service*
  (make-kernel-agent *kernel*
    :name "customer-service"
    :system-prompt "You are a professional customer service representative.
- Always be polite and patient
- Try to resolve customer issues
- Transfer to human agent when necessary"))

(agent-chat *customer-service* "I haven't received my order yet")
```

### Code Assistant

```lisp
(defvar *code-assistant*
  (make-kernel-agent *kernel*
    :name "code-assistant"
    :system-prompt "You are a programming assistant.
- Provide clear code examples
- Explain how code works
- Suggest best practices"
    :settings '(:temperature 0.3)))  ; Lower temperature for more deterministic output

(agent-chat *code-assistant* "How do I read a file in Common Lisp?")
```

### Background Data Processing

```lisp
(defvar *data-processor*
  (make-process-agent *kernel*
    :name "data-processor"))

;; Start background task
(agent-start *data-processor*
  "Analyze sales.csv file and generate monthly report")

;; Do other things...

;; Check progress
(when (eq (agent-state *data-processor*) :running)
  (format t "Still processing...~%"))

;; Wait for completion and get result
(let ((result (agent-wait *data-processor*)))
  (format t "Analysis complete: ~A~%" result))
```
