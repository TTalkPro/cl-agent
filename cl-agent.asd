;;;; cl-agent.asd
;;;; CL-Agent - Unified AI Agent Framework (Meta-System)
;;;;
;;;; Version: 5.0.0 (Semantic Kernel + clj-agent Architecture)
;;;; Author: David
;;;;
;;;; Overview:
;;;;   This is the meta-system for CL-Agent, aggregating all subsystems.
;;;;   Architecture matches clj-agent with 7 ASDF modules.
;;;;
;;;; Architecture:
;;;;   Layer 1 - Core:        cl-agent-core (Infrastructure + Full Kernel Framework)
;;;;   Layer 2 - LLM:         cl-agent-llm (Provider implementations, implements llm-chat protocol)
;;;;   Layer 3 - SimpleAgent: cl-agent-simpleagent (KernelAgent, ProcessAgent)
;;;;   Layer 4 - Memory:      cl-agent-memory (Store + Snapshot + Long-term Memory)
;;;;   Layer 5 - Plugin:      cl-agent-plugin (Builtin tools, security, resilience)
;;;;   Layer 6 - RAG:         cl-agent-rag (Retrieval-Augmented Generation)
;;;;   Layer 7 - MCP:         cl-agent-mcp (Model Context Protocol)
;;;;
;;;; Usage:
;;;;   (asdf:load-system :cl-agent)
;;;;
;;;; Loading Individual Subsystems:
;;;;   (asdf:load-system :cl-agent-core)        ; Infrastructure + Full Kernel
;;;;   (asdf:load-system :cl-agent-llm)         ; LLM Provider implementations
;;;;   (asdf:load-system :cl-agent-simpleagent) ; Simple agent implementations
;;;;   (asdf:load-system :cl-agent-memory)      ; Unified memory management
;;;;   (asdf:load-system :cl-agent-plugin)      ; Plugin system with builtins
;;;;   (asdf:load-system :cl-agent-rag)         ; RAG pipeline
;;;;   (asdf:load-system :cl-agent-mcp)         ; MCP client/server
;;;;
;;;; Major Changes (v5.0.0):
;;;;   - Restructured to match clj-agent architecture (7 modules)
;;;;   - Added cl-agent-simpleagent for KernelAgent/ProcessAgent
;;;;   - Renamed cl-agent-tools -> cl-agent-plugin
;;;;   - Added cl-agent-mcp for Model Context Protocol
;;;;   - Enhanced memory module with long-term memory types
;;;;   - Enhanced RAG module with multiple splitters and Kernel integration
;;;;   - 3-tier Invoke API in Kernel (invoke-tool, invoke-chat, invoke)
;;;;   - Builder pattern for Kernel construction
;;;;   - Service abstraction for LLM integration
;;;;
;;;; Changelog:
;;;;   v5.0.0 - clj-agent architecture alignment, 7 modules
;;;;   v4.0.0 - Semantic Kernel architecture
;;;;   v3.0.0 - Initial modular design

(asdf:defsystem #:cl-agent
  :description "Unified AI Agent Framework - Meta System (Semantic Kernel + clj-agent)"
  :author "David"
  :license "MIT"
  :version "5.0.0"

  ;; Meta-system contains no components, only declares dependencies
  :depends-on (;; Layer 1: Core (Kernel functions and plugins)
               #:cl-agent-core

               ;; Layer 2: LLM (Provider implementations)
               #:cl-agent-llm

               ;; Layer 3: SimpleAgent (Agent implementations)
               #:cl-agent-simpleagent

               ;; Layer 4: Memory (Unified memory management)
               #:cl-agent-memory

               ;; Layer 5: Plugin (Builtin tools)
               #:cl-agent-plugin

               ;; Layer 6: RAG (Retrieval-Augmented Generation)
               #:cl-agent-rag

               ;; Layer 7: MCP (Model Context Protocol)
               #:cl-agent-mcp)

  :in-order-to ((asdf:test-op (asdf:test-op #:cl-agent-test))))

;;;; ============================================================
;;;; Test System
;;;; ============================================================

(asdf:defsystem #:cl-agent-test
  :description "CL-Agent Complete Test Suite"
  :author "David"
  :license "MIT"
  :version "3.0.0"

  :depends-on (#:cl-agent
               #:fiveam)

  :serial t
  :components (;; Test suite setup
               (:file "tests/suite")

               ;; Core tests
               (:file "tests/test-core")
               (:file "tests/test-kernel-function")
               (:file "tests/test-kernel-plugin")
               (:file "tests/test-kernel-core")
               (:file "tests/test-kernel-filter")
               (:file "tests/test-kernel-chat")

               ;; LLM tests
               (:file "tests/test-llm")

               ;; SimpleAgent tests
               (:file "tests/test-simpleagent")

               ;; Memory tests
               (:file "tests/test-memory")

               ;; Plugin tests
               (:file "tests/test-plugin")

               ;; RAG tests
               (:file "tests/test-rag")

               ;; MCP tests
               (:file "tests/test-mcp")

               ;; Integration tests
               (:file "tests/test-integration-kernel"))

  :perform (asdf:test-op (op c)
             (uiop:symbol-call :fiveam :run! :cl-agent/tests)))

