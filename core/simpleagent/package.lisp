;;;; package.lisp
;;;; CL-Agent SimpleAgent - Package Definition
;;;;
;;;; Overview:
;;;;   Package for the SimpleAgent runtime (part of cl-agent-core).
;;;;   Contains the base agent protocol, shared utilities and KernelAgent.
;;;;   ProcessAgent lives in cl-agent-extra (cl-agent.extra.agent).

(defpackage #:cl-agent.simpleagent
  (:use #:common-lisp
        #:cl-agent.core
        #:cl-agent.kernel)
  (:nicknames #:cla.simpleagent #:simpleagent)
  (:export
   ;; ==================== Base Agent Protocol ====================
   #:agent-p
   #:agent-id
   #:agent-name
   #:base-agent
   #:agent-created-at
   #:agent-metadata

   ;; ==================== Agent Events ====================
   #:agent-event
   #:make-agent-event
   #:make-agent-event-of-type
   #:agent-event-type
   #:agent-event-agent
   #:agent-event-data
   #:agent-event-timestamp
   #:register-agent-handler
   #:fire-agent-event

   ;; ==================== Agent Settings ====================
   #:merge-settings
   #:default-agent-settings

   ;; ==================== Thread-Safe Message Queue ====================
   #:message-queue
   #:make-message-queue
   #:queue-enqueue
   #:queue-dequeue
   #:queue-peek
   #:queue-empty-p
   #:queue-length
   #:queue-clear

   ;; ==================== Callback Registry ====================
   #:callback-registry
   #:make-callback-registry
   #:callback-registry-p
   #:callback-entry
   #:callback-entry-name
   #:callback-entry-fn
   #:callback-entry-priority
   #:callback-entry-once-p
   #:register-callback
   #:unregister-callback
   #:clear-callbacks
   #:callback-count
   #:fire-callbacks

   ;; ==================== Kernel Agent ====================
   #:kernel-agent
   #:make-kernel-agent
   #:agent-kernel
   #:agent-context
   #:agent-history
   #:agent-system-prompt
   #:agent-settings
   #:agent-callbacks
   #:agent-memory
   #:agent-conversation-id
   #:agent-fire

   ;; Kernel Agent API
   #:agent-chat
   #:agent-chat-stream
   #:agent-reset
   #:agent-get-history
   #:agent-set-system-prompt
   #:agent-add-plugin
   #:agent-add-filter

   ;; Kernel Agent Callbacks
   #:agent-on-message
   #:agent-on-tool-call
   #:agent-on-tool-result
   #:agent-on-response
   #:agent-on-error
   #:agent-on-chunk
   #:agent-remove-callback))
