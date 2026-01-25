;;;; cl-agent-simpleagent.asd
;;;; CL-Agent SimpleAgent - Simple Agent Implementations
;;;;
;;;; Version: 1.0.0
;;;; Author: David
;;;;
;;;; Overview:
;;;;   Simple agent implementations for common use cases.
;;;;
;;;; Agents:
;;;;   - KernelAgent: Simple chat loop with tool calling
;;;;   - ProcessAgent: Pauseable/resumable agent with state
;;;;
;;;; Usage:
;;;;   ;; Simple agent
;;;;   (let ((agent (make-kernel-agent kernel)))
;;;;     (agent-chat agent "What's the weather in Tokyo?"))
;;;;
;;;;   ;; Process agent with pause/resume
;;;;   (let ((agent (make-process-agent kernel)))
;;;;     (agent-start agent)
;;;;     (agent-pause agent)
;;;;     (agent-resume agent))

(asdf:defsystem #:cl-agent-simpleagent
  :description "CL-Agent SimpleAgent - Simple Agent Implementations"
  :author "David"
  :license "MIT"
  :version "1.0.0"

  :depends-on (#:cl-agent-core
               #:cl-agent-llm
               #:bordeaux-threads)

  :serial t
  :components
  ((:file "package")
   (:file "common")
   (:file "kernel-agent")
   (:file "process-agent")))
