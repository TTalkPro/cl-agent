;;;; run-tests.lisp
;;;; Quick test runner for cross-implementation tests

(require :asdf)

;; Add paths
(dolist (dir '("." "core/" "llm/" "memory/" "extra/" "mock/"))
  (pushnew (truename dir) asdf:*central-registry* :test #'equal))

;; Load quicklisp if available
(let ((ql-setup (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname))))
  (when (probe-file ql-setup)
    (load ql-setup)))

;; Load fiveam
(format t "~%Loading fiveam...~%")
(ql:quickload :fiveam :silent t)

;; Load core modules
(format t "Loading cl-agent-core...~%")
(asdf:load-system :cl-agent-core)

(format t "Loading cl-agent-memory...~%")
(asdf:load-system :cl-agent-memory)

(format t "Loading cl-agent-llm...~%")
(asdf:load-system :cl-agent-llm)

(format t "Loading cl-agent-extra...~%")
(asdf:load-system :cl-agent-extra)

(format t "~%All modules loaded successfully!~%~%")

;; Load and run tests
(format t "Loading test files...~%")
(load "tests/test-cross-impl.lisp")
(load "tests/process-agent-test.lisp")

(format t "~%Running cross-implementation tests...~%~%")
(cl-agent.tests.cross-impl:run-cross-impl-tests)

;; Process agent tests (requires API key)
(format t "~%~%=== Process Agent Tests ===~%")
(format t "To run process-agent tests with GLM-4.7:~%")
(format t "  1. Set GLM_API_KEY environment variable~%")
(format t "  2. Run: (cl-agent.test.process-agent:run-all-tests)~%")
(format t "  Or for local tests without API:~%")
(format t "  Run: (cl-agent.test.process-agent:test-event-system-local)~%")
