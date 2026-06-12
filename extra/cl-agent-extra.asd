;;;; cl-agent-extra.asd
;;;; CL-Agent Extra - Process Framework + Builtin Tools + ProcessAgent
;;;;
;;;; Version: 1.0.0
;;;; Author: David
;;;;
;;;; Overview:
;;;;   Optional extras built on top of cl-agent-core:
;;;;   - Checkpoint (process state snapshots: store protocol + lineage
;;;;     + branching + time travel; merged from cl-agent-memory)
;;;;   - Process framework (events, steps, state machine, human-in-the-loop)
;;;;   - ProcessAgent (pauseable/resumable agent on the process framework)
;;;;
;;;; Usage:
;;;;   (asdf:load-system :cl-agent-extra)

(asdf:defsystem #:cl-agent-extra
  :description "CL-Agent Extra - Checkpoint + Process Framework + ProcessAgent"
  :author "David"
  :license "MIT"
  :version "1.0.0"

  :depends-on (#:cl-agent-core      ; infrastructure + kernel + simpleagent
               #:bordeaux-threads)  ; agent threads

  :serial t
  :components
  (;; ============================================================
   ;; Checkpoint（流程状态快照：Store 协议 + 内存后端 + 时间旅行）
   ;; ============================================================
   (:module "checkpoint"
    :components
    ((:file "package")
     (:file "store-protocol")  ; Store 协议 + store-item
     (:file "memory-backend")  ; 内存 Store 后端
     (:file "protocol")        ; Checkpoint 类 + 协议
     (:file "manager")))       ; CheckpointManager（谱系/分支/时间旅行）

   ;; ============================================================
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
   ;; ProcessAgent (depends on process framework + simpleagent)
   ;; ============================================================
   (:module "agent"
    :components
    ((:file "package")
     (:file "process-agent"))))

  :in-order-to ((asdf:test-op (asdf:test-op #:cl-agent-test))))
