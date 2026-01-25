;;;; package.lisp
;;;; CL-Agent SimpleAgent - Package Definition
;;;;
;;;; Overview:
;;;;   Package for simple agent implementations.

(defpackage #:cl-agent.simpleagent
  (:use #:common-lisp
        #:cl-agent.core
        #:cl-agent.kernel)
  (:import-from #:cl-agent.process
                #:make-event-bus
                #:make-event-queue
                #:make-human-loop-manager
                #:event-bus-subscribe
                #:event-queue-push
                #:event-queue-pop
                #:event-matches-p
                #:make-event
                #:process-event
                #:event-type
                #:event-name
                #:event-data)
  (:nicknames #:cla.simpleagent #:simpleagent)
  (:export
   ;; ==================== Kernel Agent ====================
   #:kernel-agent
   #:make-kernel-agent
   #:agent-kernel
   #:agent-context
   #:agent-history
   #:agent-system-prompt
   #:agent-settings

   ;; Kernel Agent API
   #:agent-chat
   #:agent-chat-stream
   #:agent-reset
   #:agent-get-history
   #:agent-set-system-prompt

   ;; ==================== Process Agent ====================
   #:process-agent
   #:make-process-agent
   #:agent-state
   #:agent-thread

   ;; Process Agent Lifecycle
   #:agent-start
   #:agent-stop
   #:agent-pause
   #:agent-resume
   #:agent-running-p
   #:agent-paused-p

   ;; Process Agent Communication
   #:agent-send
   #:agent-receive
   #:agent-queue-message

   ;; Event Injection (C# Process Framework style)
   #:agent-inject-event
   #:agent-subscribe-event
   #:agent-unsubscribe-event
   #:agent-event-bus
   #:agent-event-queue

   ;; Human-in-the-Loop
   #:agent-human-loop
   #:agent-request-input
   #:agent-submit-input
   #:agent-wait-for-approval
   #:agent-wait-for-confirmation
   #:agent-get-pending-inputs

   ;; Process Runtime (Step-based workflows)
   #:agent-process-runtime
   #:agent-start-process
   #:agent-get-process-state

   ;; ==================== Agent Events ====================
   #:agent-event
   #:agent-on-message
   #:agent-on-tool-call
   #:agent-on-tool-result
   #:agent-on-response
   #:agent-on-error

   ;; ==================== Common ====================
   #:agent-p
   #:agent-id
   #:agent-name))
