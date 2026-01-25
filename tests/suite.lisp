;;;; suite.lisp
;;;; CL-Agent - Test Suite Definition

(in-package :cl-user)

(defpackage :cl-agent/tests
  (:use :cl :fiveam)
  (:export #:cl-agent-suite
           #:run-cl-agent-tests
           #:run-kernel-tests
           #:run-module-tests))

(in-package :cl-agent/tests)

;; Define main test suite
(def-suite cl-agent-suite
  :description "CL-Agent Complete Test Suite")

(in-suite cl-agent-suite)

;;; ============================================================
;;; Convenience Functions
;;; ============================================================

(defun run-cl-agent-tests ()
  "Run all tests"
  (run! 'cl-agent-suite))

(defun run-kernel-tests ()
  "Run all Kernel module tests"
  (format t "~%=== Kernel Module Tests ===~%")
  (format t "~%--- Kernel Function ---~%")
  (run! 'kernel-function-suite)
  (format t "~%--- Kernel Plugin ---~%")
  (run! 'kernel-plugin-suite)
  (format t "~%--- Kernel Core ---~%")
  (run! 'kernel-core-suite)
  (format t "~%--- Kernel Filter ---~%")
  (run! 'kernel-filter-suite)
  (format t "~%--- Kernel Chat ---~%")
  (run! 'kernel-chat-suite)
  (format t "~%--- Kernel Integration ---~%")
  (run! 'kernel-integration-suite)
  (format t "~%=== Kernel Tests Complete ===~%"))

(defun run-module-tests ()
  "Run all module tests (excluding Kernel)"
  (format t "~%=== Module Tests ===~%")
  (format t "~%--- Core ---~%")
  (run! 'core-suite)
  (format t "~%--- LLM ---~%")
  (run! 'llm-suite)
  (format t "~%--- SimpleAgent ---~%")
  (run! 'simpleagent-suite)
  (format t "~%--- Memory ---~%")
  (run! 'memory-suite)
  (format t "~%--- Plugin ---~%")
  (run! 'plugin-suite)
  (format t "~%--- RAG ---~%")
  (run! 'rag-suite)
  (format t "~%--- MCP ---~%")
  (run! 'mcp-suite)
  (format t "~%=== Module Tests Complete ===~%"))

(defun run-quick-tests ()
  "Run quick smoke tests"
  (format t "~%=== Quick Smoke Tests ===~%")
  (run! 'core-suite)
  (run! 'kernel-core-suite)
  (format t "~%=== Quick Tests Complete ===~%"))

