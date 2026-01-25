;;;; package.lisp
;;;; CL-Agent SimpleAgent - Package Definition
;;;;
;;;; Overview:
;;;;   Package for simple agent implementations.

(defpackage #:cl-agent.simpleagent
  (:use #:common-lisp
        #:cl-agent.core
        #:cl-agent.kernel)
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
