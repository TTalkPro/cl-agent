;;;; package.lisp
;;;; CL-Agent Extra - ProcessAgent Package Definition
;;;;
;;;; Overview:
;;;;   Package for ProcessAgent, the pauseable/resumable background-thread
;;;;   agent built on the process framework (cl-agent.process).
;;;;   Extends KernelAgent from cl-agent.simpleagent (cl-agent-core).

(defpackage #:cl-agent.extra.agent
  (:use #:common-lisp
        #:cl-agent.core
        #:cl-agent.kernel
        #:cl-agent.simpleagent)
  (:nicknames #:cla.extra.agent #:process-agent)
  (:export
   ;; ==================== Process Agent ====================
   #:process-agent
   #:make-process-agent
   #:agent-state
   #:agent-thread
   #:agent-input-queue
   #:agent-output-queue

   ;; Process Agent Lifecycle
   #:agent-start
   #:agent-stop
   #:agent-pause
   #:agent-resume
   #:agent-running-p
   #:agent-paused-p
   #:agent-stopped-p

   ;; Process Agent Communication
   #:agent-send
   #:agent-receive
   #:agent-queue-message
   #:agent-ask

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
   #:agent-get-process-state))
