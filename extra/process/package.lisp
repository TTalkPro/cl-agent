;;;; package.lisp
;;;; CL-Agent Core - Process Framework Package Definition
;;;;
;;;; A process framework supporting external events, human-in-the-loop,
;;;; and event-driven workflow execution.

(defpackage #:cl-agent.process
  (:use #:cl)
  (:import-from #:alexandria
                #:when-let
                #:if-let
                #:hash-table-keys
                #:hash-table-values)
  (:import-from #:bordeaux-threads
                #:make-lock
                #:with-lock-held
                #:make-condition-variable
                #:condition-wait
                #:condition-notify
                #:make-thread
                #:thread-alive-p
                #:join-thread)

  ;; Event System
  (:export
   ;; Event class
   #:process-event
   #:make-event
   #:event-id
   #:event-type
   #:event-name
   #:event-data
   #:event-source
   #:event-timestamp
   #:event-metadata

   ;; Event types
   #:+event-type-input+
   #:+event-type-output+
   #:+event-type-external+
   #:+event-type-approval+
   #:+event-type-timeout+
   #:+event-type-error+
   #:+event-type-cancel+
   #:+event-type-complete+

   ;; Event Matching
   #:event-matches-p

   ;; Event Bus
   #:event-bus
   #:make-event-bus
   #:event-bus-subscribe
   #:event-bus-unsubscribe
   #:event-bus-publish
   #:event-bus-clear

   ;; Event Queue
   #:event-queue
   #:make-event-queue
   #:event-queue-push
   #:event-queue-pop
   #:event-queue-peek
   #:event-queue-empty-p
   #:event-queue-clear)

  ;; Step System
  (:export
   ;; Step class
   #:process-step
   #:make-step
   #:step-id
   #:step-name
   #:step-description
   #:step-handler
   #:step-input-schema
   #:step-output-schema
   #:step-wait-for-events
   #:step-timeout
   #:step-retry-policy
   #:step-metadata

   ;; Step Result
   #:step-result
   #:make-step-result
   #:step-result-status
   #:step-result-output
   #:step-result-error
   #:step-result-next-step
   #:step-result-events

   ;; Step status
   #:+step-status-pending+
   #:+step-status-running+
   #:+step-status-waiting+
   #:+step-status-completed+
   #:+step-status-failed+
   #:+step-status-skipped+

   ;; Result constructors
   #:step-completed
   #:step-failed
   #:step-waiting
   #:step-skipped

   ;; Step execution
   #:execute-step

   ;; Macros
   #:defstep)

  ;; State Machine
  (:export
   ;; State
   #:process-state
   #:make-state
   #:state-name
   #:state-data
   #:state-enter-action
   #:state-exit-action

   ;; Transition
   #:state-transition
   #:make-transition
   #:transition-from
   #:transition-to
   #:transition-event
   #:transition-guard
   #:transition-action

   ;; State Machine
   #:state-machine
   #:make-state-machine
   #:state-machine-current-state
   #:state-machine-states
   #:state-machine-transitions
   #:state-machine-trigger
   #:state-machine-can-trigger-p
   #:state-machine-add-state
   #:state-machine-add-transition
   #:state-machine-builder
   #:with-state
   #:with-transition-rule)

  ;; Human-in-the-loop
  (:export
   ;; Input Request
   #:input-request
   #:make-input-request
   #:input-request-id
   #:input-request-type
   #:input-request-prompt
   #:input-request-schema
   #:input-request-timeout
   #:input-request-default
   #:input-request-metadata

   ;; Input types
   #:+input-type-text+
   #:+input-type-confirmation+
   #:+input-type-choice+
   #:+input-type-approval+
   #:+input-type-form+

   ;; Input Response
   #:input-response
   #:make-input-response
   #:input-response-request-id
   #:input-response-value
   #:input-response-approved-p
   #:input-response-metadata

   ;; Human Loop Manager
   #:human-loop-manager
   #:make-human-loop-manager
   #:human-loop-request-input
   #:human-loop-request-input-async
   #:human-loop-submit-response
   #:human-loop-cancel-request
   #:human-loop-pending-requests
   #:human-loop-set-handler

   ;; Convenience functions
   #:wait-for-approval
   #:wait-for-confirmation
   #:wait-for-text
   #:wait-for-choice)

  ;; Process Definition
  (:export
   ;; Process class
   #:process-definition
   #:make-process
   #:process-id
   #:process-name
   #:process-description
   #:process-version
   #:process-steps
   #:process-initial-step
   #:process-event-handlers
   #:process-metadata

   ;; Macros
   #:defprocess)

  ;; Process Runtime
  (:export
   ;; Execution Context
   #:execution-context
   #:make-execution-context
   #:context-id
   #:context-process
   #:context-current-step
   #:context-state
   #:context-variables
   #:context-history
   #:context-get-variable
   #:context-set-variable

   ;; Process Runtime
   #:process-runtime
   #:make-process-runtime
   #:runtime-start
   #:runtime-stop
   #:runtime-pause
   #:runtime-resume
   #:runtime-inject-event
   #:runtime-get-state
   #:runtime-get-pending-inputs
   #:runtime-submit-input

   ;; Runtime states
   #:+runtime-state-idle+
   #:+runtime-state-running+
   #:+runtime-state-paused+
   #:+runtime-state-waiting+
   #:+runtime-state-completed+
   #:+runtime-state-failed+))
