;;;; cl-agent-core.asd
;;;; CL-Agent Core - Infrastructure + Kernel Framework + SimpleAgent
;;;;
;;;; Version: 6.0.0
;;;; Author: David
;;;;
;;;; Overview:
;;;;   CL-Agent core module providing infrastructure, the complete Kernel
;;;;   framework and the SimpleAgent runtime (KernelAgent).
;;;;
;;;; Architecture:
;;;;   - Core infrastructure (conditions, macros, utils, types)
;;;;   - HTTP client with SSE streaming
;;;;   - Complete Kernel framework:
;;;;     - Tool/Plugin system (Symbol Plist pattern)
;;;;     - Context (state management)
;;;;     - Service (LLM abstraction)
;;;;     - Provider protocol (LLM interface)
;;;;     - Builder (fluent construction)
;;;;     - Filter Chain (4-type pipeline)
;;;;     - 3-Tier Invoke API
;;;;   - SimpleAgent runtime (KernelAgent chat loop)
;;;;
;;;; Note:
;;;;   The Process framework and ProcessAgent live in cl-agent-extra.

(asdf:defsystem #:cl-agent-core
  :description "CL-Agent Core - Infrastructure + Kernel Framework + SimpleAgent (v6.0.0)"
  :author "David"
  :license "MIT"
  :version "6.0.0"

  :depends-on (#:alexandria
               #:serapeum
               #:cl-ppcre
               #:local-time
               #:log4cl
               #:uuid
               #:uiop
               #:com.inuoe.jzon
               #:lparallel
               #:bordeaux-threads
               #:closer-mop
               ;; HTTP module dependencies
               #:dexador            ; HTTP client
               #:quri               ; URL handling
               #:flexi-streams      ; Stream handling
               #:usocket)           ; Network sockets

  :serial t
  :components
  (;; ============================================================
   ;; Package Definitions
   ;; ============================================================
   (:file "package-core")

   ;; ============================================================
   ;; Core Infrastructure
   ;; ============================================================
   (:file "conditions")           ; Condition system
   (:file "macros")               ; Utility macros
   (:file "types")                ; Core data types (Message, ToolCall, Response)
   (:file "documentation")        ; Documentation system
   (:file "utils")                ; Utility functions
   (:file "validation")           ; Data validation
   (:file "dependency-injection") ; DI container
   (:file "data-convert")         ; Data conversion (plist <-> hash-table)

   ;; ============================================================
   ;; LLM Protocol Layer (in core for dependency management)
   ;; ============================================================
   (:module "llm"
    :components
    ((:file "response")           ; Unified LLM Response Schema
     (:file "provider")))         ; ILLMProvider protocol

   ;; ============================================================
   ;; Protocol Layer
   ;; ============================================================
   (:module "protocols"
    :components
    ((:file "protocols")))

   ;; ============================================================
   ;; HTTP Client
   ;; ============================================================
   (:module "http"
    :components
    ((:file "package-http")
     (:file "conditions")
     (:file "client")
     (:file "async")
     (:file "retry")
     (:file "streaming")))

   ;; ============================================================
   ;; Kernel Framework
   ;; ============================================================
   (:module "kernel"
    :components
    ((:file "package")
     (:file "function")       ; Tool function metadata
     (:file "macros")         ; deftool/defplugin macros
     (:file "plugin")         ; Plugin metadata
     (:file "context")        ; Context state management
     (:file "service")        ; Service abstraction
     (:file "filter")         ; 4-type filter pipeline
     (:file "kernel")         ; Kernel class + Builder
     (:file "chat")))         ; 3-tier Invoke API

   ;; ============================================================
   ;; SimpleAgent Runtime
   ;; ============================================================
   (:module "simpleagent"
    :components
    ((:file "package")
     (:file "common")         ; Base agent, events, message queue
     (:file "kernel-agent"))))) ; KernelAgent chat loop

;; ============================================================
;; Changelog
;; ============================================================
;;
;; v6.0.0:
;; - Moved Process framework to cl-agent-extra
;; - Absorbed SimpleAgent (KernelAgent) into core
;; - ProcessAgent moved to cl-agent-extra (depends on process framework)
;; - Removed leftover graph protocol placeholders
;;
;; v5.0.0:
;; - Added types.lisp for core data types (Message, ToolCall, Response)
;; - Added kernel/context.lisp for Context state management
;; - Added kernel/service.lisp for Service abstraction
;; - Added kernel/provider.lisp for ILLMProvider protocol
;; - Enhanced filter.lisp with 4-type filter pipeline
;; - Enhanced kernel.lisp with Builder pattern
;; - Enhanced chat.lisp with 3-tier Invoke API
;;
;; v4.0.0:
;; - Complete Semantic Kernel architecture
;; - Symbol Plist pattern for tool metadata
;; - Filter chain with onion model
;;
;; v3.0.0:
;; - Removed Pregel graph engine
;; - Added initial Kernel framework
