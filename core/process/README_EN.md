# Process Framework

[中文](README.md) | English

Event-driven process execution framework supporting external event injection, human-in-the-loop, and state machine control.

## Directory Structure

```
core/process/
├── package.lisp          # Package definition
├── event.lisp            # Event system
├── step.lisp             # Step abstraction
├── state-machine.lisp    # State machine
├── human-loop.lisp       # Human-in-the-loop
├── process.lisp          # Process definition
└── runtime.lisp          # Runtime
```

## Core Concepts

### Event System

```lisp
;; Event types
+event-type-input+      ; External input
+event-type-output+     ; Step output
+event-type-external+   ; External system event
+event-type-approval+   ; Human approval
+event-type-timeout+    ; Timeout
+event-type-error+      ; Error
+event-type-cancel+     ; Cancel

;; Create event
(make-event :type :external
            :name "data-ready"
            :data '(:file "data.csv")
            :source "external-system")

;; Event bus
(defvar *bus* (make-event-bus))

;; Subscribe to events
(event-bus-subscribe *bus* :approval
  (lambda (event)
    (format t "Received approval: ~A~%" (event-data event))))

;; Publish event
(event-bus-publish *bus*
  (make-event :type :approval :data t))
```

### Step

```lisp
;; Define step
(defstep process-data (:input data :context ctx)
  :description "Process data"
  :timeout 60
  :retry (:max-attempts 3 :backoff :exponential)
  :wait-for (:data-ready)
  :handler
  (let ((result (analyze data)))
    (step-completed :output result)))

;; Or create manually
(make-step "validate"
  :description "Validate input"
  :handler (lambda (ctx input)
             (if (valid-p input)
                 (step-completed :output input)
                 (step-failed "Invalid input")))
  :timeout 30)

;; Step results
(step-completed :output result)           ; Success
(step-failed error)                       ; Failure
(step-waiting :events '(:approval))       ; Waiting for events
(step-skipped :reason "Condition not met") ; Skipped
```

### State Machine

```lisp
;; Create state machine
(defvar *sm*
  (-> (state-machine-builder)
      (with-state :idle :initial t)
      (with-state :running)
      (with-state :paused)
      (with-state :completed)
      (with-state :failed)
      (with-transition-rule :idle :running :on :start)
      (with-transition-rule :running :paused :on :pause)
      (with-transition-rule :running :completed :on :complete)
      (with-transition-rule :paused :running :on :resume)))

;; Trigger transition
(state-machine-trigger *sm* :start context)
(state-machine-current-state *sm*)  ; => :running

;; Check if can trigger
(state-machine-can-trigger-p *sm* :pause context)
```

### Human-in-the-Loop

```lisp
;; Create manager
(defvar *hlm*
  (make-human-loop-manager
    :on-request (lambda (req)
                  (format t "Input needed: ~A~%" (input-request-prompt req)))
    :on-response (lambda (resp)
                   (format t "Received response: ~A~%" (input-response-value resp)))))

;; Request input (blocking)
(let ((response (wait-for-text *hlm* "Please enter your name:"
                               :timeout 60)))
  (format t "Hello, ~A!~%" (input-response-value response)))

;; Request approval
(if (wait-for-approval *hlm* "Approve this operation?"
                       :description "This will modify the database"
                       :timeout 300)
    (execute-operation)
    (cancel-operation))

;; Request choice
(let ((choice (wait-for-choice *hlm* "Select processing mode:"
                               '("Fast" "Standard" "Detailed"))))
  (process-with-mode choice))

;; Async request
(human-loop-request-input-async *hlm* request
  (lambda (response)
    (handle-response response)))

;; Submit response (from external)
(human-loop-submit-response *hlm*
  (make-input-response request-id
    :value "User input"
    :approved-p t))
```

### Process Definition

```lisp
;; Define process using macro
(defprocess document-approval
  :description "Document approval workflow"
  :version "1.0.0"

  :steps
  ((submit
    :description "Submit document"
    :handler (lambda (ctx input)
               (context-set-variable ctx :document input)
               (step-completed :output input)))

   (review
    :description "Review document"
    :wait-for (:approval)
    :timeout 86400  ; 24 hours
    :handler (lambda (ctx input)
               (let ((approved (context-get-variable ctx :approval-result)))
                 (if approved
                     (step-completed :output input
                                     :next-step "publish")
                     (step-completed :output input
                                     :next-step "revise")))))

   (revise
    :description "Revise document"
    :wait-for (:revision)
    :handler (lambda (ctx input)
               (step-completed :output (context-get-variable ctx :revised-doc)
                               :next-step "review")))

   (publish
    :description "Publish document"
    :handler (lambda (ctx input)
               (publish-document input)
               (step-completed :output input))))

  :on-event
  ((:approval . (lambda (ctx event)
                  (context-set-variable ctx :approval-result
                    (event-data event))))
   (:revision . (lambda (ctx event)
                  (context-set-variable ctx :revised-doc
                    (event-data event)))))

  :on-complete (lambda (ctx result)
                 (log-info "Document published")))
```

### Runtime

```lisp
;; Create runtime
(defvar *runtime*
  (make-process-runtime document-approval
    :on-step-start (lambda (ctx step)
                     (format t "Starting step: ~A~%" (step-name step)))
    :on-step-complete (lambda (ctx step result)
                        (format t "Completed step: ~A -> ~A~%"
                                (step-name step)
                                (step-result-status result)))
    :human-handler (lambda (request)
                     ;; Send to UI
                     (send-to-ui request))))

;; Start process
(runtime-start *runtime* :input document :async t)

;; Inject external event
(runtime-inject-event *runtime*
  (make-event :type :approval
              :data t
              :source "manager"))

;; Pause/Resume
(runtime-pause *runtime*)
(runtime-resume *runtime*)

;; Get state
(runtime-get-state *runtime*)
;; => (:state :waiting
;;     :current-step "review"
;;     :pending-inputs 1
;;     :history-count 5)

;; Get pending human inputs
(runtime-get-pending-inputs *runtime*)

;; Submit human input response
(runtime-submit-input *runtime*
  (make-input-response request-id :value "approved" :approved-p t))

;; Stop process
(runtime-stop *runtime*)
```

## Complete Examples

### Data Processing Pipeline (with Approval)

```lisp
(defprocess data-pipeline
  :description "Data processing pipeline"
  :timeout 3600  ; 1 hour total timeout

  :steps
  ((validate
    :description "Validate input data"
    :handler (lambda (ctx input)
               (if (validate-data input)
                   (step-completed :output input)
                   (step-failed "Data validation failed"))))

   (transform
    :description "Transform data"
    :handler (lambda (ctx input)
               (step-completed :output (transform-data input))))

   (review
    :description "Human review"
    :wait-for (:review-complete)
    :timeout 1800  ; 30 minutes
    :handler (lambda (ctx input)
               (let ((approved (context-get-variable ctx :review-approved)))
                 (if approved
                     (step-completed :output input)
                     (step-failed "Review not approved")))))

   (load
    :description "Load to database"
    :handler (lambda (ctx input)
               (load-to-database input)
               (step-completed :output {:status "loaded"}))))

  :on-event
  ((:review-complete . (lambda (ctx event)
                         (context-set-variable ctx :review-approved
                           (getf (event-data event) :approved))))))

;; Usage
(let ((runtime (make-process-runtime data-pipeline
                 :human-handler #'send-review-request)))

  ;; Start
  (runtime-start runtime :input raw-data :async t)

  ;; Wait for review step...
  ;; User reviews and submits in UI

  ;; Inject review result
  (runtime-inject-event runtime
    (make-event :type :review-complete
                :data '(:approved t :comment "Data is correct"))))
```

### Integration with SimpleAgent

ProcessAgent natively integrates core/process framework:

```lisp
;; Create ProcessAgent with event and human-in-the-loop support
(defvar *agent*
  (cl-agent.simpleagent:make-process-agent *kernel*
    :name "event-driven-agent"
    :event-handlers
    (list (cons :approval
                (lambda (event)
                  (format t "Approval event: ~A~%" (event-data event)))))
    :human-handler
    (lambda (request)
      (format t "Input needed: ~A~%" (input-request-prompt request)))))

;; Start Agent
(cl-agent.simpleagent:agent-start *agent*)

;; Inject external event (similar to C# Process Framework)
(cl-agent.simpleagent:agent-inject-event *agent*
  (make-event :type :external
              :name "data-ready"
              :data '(:file "data.csv")))

;; Request human approval
(let ((request (make-input-request
                 :type :approval
                 :prompt "Continue?")))
  (cl-agent.simpleagent:agent-request-input *agent* request))

;; Submit human response
(cl-agent.simpleagent:agent-submit-input *agent*
  (make-input-response request-id :approved-p t))
```

Using step-based workflow:

```lisp
;; Define workflow
(defprocess my-workflow
  :description "My workflow"
  :steps
  ((step-1 :handler (lambda (ctx input) (step-completed :output input)))
   (step-2 :wait-for (:approval) :handler ...)))

;; Create Agent with workflow
(defvar *workflow-agent*
  (cl-agent.simpleagent:make-process-agent *kernel*
    :process my-workflow))

(cl-agent.simpleagent:agent-start *workflow-agent*)
(cl-agent.simpleagent:agent-start-process *workflow-agent* :input data)
```

## API Summary

### Event
- `make-event` - Create event
- `event-bus-subscribe` - Subscribe to events
- `event-bus-publish` - Publish event

### Step
- `make-step` / `defstep` - Create step
- `step-completed` - Success result
- `step-failed` - Failure result
- `step-waiting` - Waiting result

### State Machine
- `make-state-machine` - Create state machine
- `state-machine-trigger` - Trigger transition
- `with-state` / `with-transition-rule` - Builder functions

### Human Loop
- `make-human-loop-manager` - Create manager
- `wait-for-text/confirmation/choice/approval` - Convenience functions
- `human-loop-submit-response` - Submit response

### Process
- `make-process` / `defprocess` - Define process
- `process-add-step` - Add step
- `process-add-event-handler` - Add event handler

### Runtime
- `make-process-runtime` - Create runtime
- `runtime-start/stop/pause/resume` - Lifecycle control
- `runtime-inject-event` - Inject event
- `runtime-submit-input` - Submit human input
- `runtime-get-state` - Get state
