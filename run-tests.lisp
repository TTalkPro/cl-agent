;;;; run-tests.lisp
;;;; Quick test runner for cross-implementation tests

(require :asdf)

;; Add paths
(dolist (dir '("." "core/" "llm/" "memory/" "tools/" "mock/"))
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

(format t "Loading cl-agent-tools...~%")
(asdf:load-system :cl-agent-tools)

(format t "~%All modules loaded successfully!~%~%")

;; Load and run tests
(format t "Loading test file...~%")
(load "tests/test-cross-impl.lisp")

(format t "~%Running cross-implementation tests...~%~%")
(cl-agent.tests.cross-impl:run-cross-impl-tests)
