;;;; cl-agent.asd
;;;; CL-Agent - Unified AI Agent Framework (Meta-System)
;;;;
;;;; Version: 7.0.0 (Semantic Kernel + clj-agent Architecture)
;;;; Author: David
;;;;
;;;; Overview:
;;;;   This is the meta-system for CL-Agent, aggregating all subsystems.
;;;;   Architecture follows clj-agent: a fat core (protocols + kernel +
;;;;   agent runtime) with optional capability modules around it.
;;;;
;;;; Architecture:
;;;;   Layer 1 - Core:   cl-agent-core (Infrastructure + Kernel + SimpleAgent)
;;;;   Layer 2 - LLM:    cl-agent-llm (Provider implementations, implements llm-chat protocol)
;;;;   Layer 3 - Extra:  cl-agent-extra (Checkpoint, Process framework, ProcessAgent)
;;;;
;;;; Usage:
;;;;   (asdf:load-system :cl-agent)
;;;;
;;;; Loading Individual Subsystems:
;;;;   (asdf:load-system :cl-agent-core)   ; Infrastructure + Kernel + SimpleAgent
;;;;   (asdf:load-system :cl-agent-llm)    ; LLM Provider implementations
;;;;   (asdf:load-system :cl-agent-extra)  ; Checkpoint + Process framework + ProcessAgent
;;;;
;;;; Major Changes (v6.0.0):
;;;;   - Core restructured: Process framework moved out, SimpleAgent moved in
;;;;   - New cl-agent-extra module: process framework + tools + ProcessAgent
;;;;   - Removed cl-agent-simpleagent and cl-agent-tools as standalone systems
;;;;   - Removed remaining graph engine leftovers (process is the only workflow story)
;;;;
;;;; Changelog:
;;;;   v7.0.0 - 减法：删除 RAG / MCP / tools 子系统（工具注册表内置到 core）；
;;;;            删除 cl-agent-memory（checkpoint 并入 cl-agent-extra）
;;;;   v6.0.0 - Core = infra + kernel + simpleagent; extras split out; graph leftovers removed
;;;;   v5.0.0 - clj-agent architecture alignment, 7 modules
;;;;   v4.0.0 - Semantic Kernel architecture
;;;;   v3.0.0 - Initial modular design

(asdf:defsystem #:cl-agent
  :description "Unified AI Agent Framework - Meta System (Semantic Kernel + clj-agent)"
  :author "David"
  :license "MIT"
  :version "7.0.0"

  ;; Meta-system contains no components, only declares dependencies
  :depends-on (;; Layer 1: Core (Infrastructure + Kernel + SimpleAgent)
               #:cl-agent-core

               ;; Layer 2: LLM (Provider implementations)
               #:cl-agent-llm

               ;; Layer 3: Extra (Checkpoint + Process framework + ProcessAgent)
               #:cl-agent-extra)

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
               #:cl-agent-mock
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

               ;; ChatMemory + Memory Filter tests
               ;; (依赖 test-kernel-chat 中的 sequenced mock)
               (:file "tests/test-memory-filter")

               ;; LLM tests
               (:file "tests/test-llm")

               ;; SimpleAgent tests
               (:file "tests/test-simpleagent")

               ;; Checkpoint tests
               (:file "tests/test-checkpoint")

               ;; Integration tests
               (:file "tests/test-integration-kernel"))

  :perform (asdf:test-op (op c)
             (uiop:symbol-call :fiveam :run! :cl-agent/tests)))
