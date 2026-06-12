;;;; cl-agent-extra.asd
;;;; CL-Agent Extra - Process Framework + Builtin Tools + ProcessAgent
;;;;
;;;; Version: 1.0.0
;;;; Author: David
;;;;
;;;; Overview:
;;;;   Optional extras built on top of cl-agent-core:
;;;;   - Process framework (events, steps, state machine, human-in-the-loop)
;;;;   - Tools system (provider/registry, builtin tools, security, resilience)
;;;;   - ProcessAgent (pauseable/resumable agent on the process framework)
;;;;
;;;; Usage:
;;;;   (asdf:load-system :cl-agent-extra)

(asdf:defsystem #:cl-agent-extra
  :description "CL-Agent Extra - Process Framework + Tools + ProcessAgent"
  :author "David"
  :license "MIT"
  :version "1.0.0"

  :depends-on (#:cl-agent-core      ; infrastructure + kernel + simpleagent
               #:quri               ; 域名检查（tools/security）
               #:bordeaux-threads   ; rate limiter / circuit breaker / agent threads
               #:cl-ppcre)          ; 输入验证

  :serial t
  :components
  (;; ============================================================
   ;; Process Framework
   ;; ============================================================
   (:module "process"
    :components
    ((:file "package")
     (:file "event")          ; Event system + Event Bus
     (:file "step")           ; Step abstraction
     (:file "state-machine")  ; Finite state machine
     (:file "human-loop")     ; Human-in-the-loop support
     (:file "process")        ; Process definition
     (:file "runtime")))      ; Process runtime execution

   ;; ============================================================
   ;; Tools System
   ;; ============================================================
   (:module "tools"
    :components
    ((:file "package")

     ;; Provider 系统核心
     (:file "protocol")
     (:file "registry")

     ;; 工具核心
     (:file "core")
     (:file "macros")
     (:file "tool-factories")

     ;; 工具实现
     (:file "search")
     (:file "shell")
     (:file "file")
     (:file "http")

     ;; Builtin Tools with Tags
     (:file "builtin")
     ;; Tool Presets
     (:file "presets")

     ;; Security and Resilience
     (:file "security")
     (:file "resilience")

     ;; Provider 实现
     (:file "providers/builtin")
     (:file "providers/custom")))

   ;; ============================================================
   ;; ProcessAgent (depends on process framework + simpleagent)
   ;; ============================================================
   (:module "agent"
    :components
    ((:file "package")
     (:file "process-agent"))))

  :in-order-to ((asdf:test-op (asdf:test-op #:cl-agent-test))))
