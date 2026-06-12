;;;; step-load-test2.lisp
;;;; Complete load test including simpleagent

(require :asdf)

(defparameter *base-dir*
  (make-pathname :directory (pathname-directory *load-truename*)))

(defparameter *project-root*
  (merge-pathnames "../" *base-dir*))

;; Load quicklisp
(let ((ql-setup (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname))))
  (when (probe-file ql-setup)
    (load ql-setup)))

;; Add paths
(dolist (dir '("" "core/" "llm/" "extra/"))
  (pushnew (merge-pathnames dir *project-root*) asdf:*central-registry* :test #'equal))

(format t "~%=== Loading cl-agent-core ===~%")
(handler-case
    (ql:quickload :cl-agent-core :silent t)
  (error (e)
    (format t "Error loading core: ~A~%" e)))

(format t "~%=== Loading cl-agent-llm ===~%")
(handler-case
    (ql:quickload :cl-agent-llm :silent t)
  (error (e)
    (format t "Error loading llm: ~A~%" e)))

(format t "~%=== Loading simpleagent manually ===~%")
(format t "  Loading package...~%")
(load (merge-pathnames "simpleagent/package.lisp" *project-root*))

(format t "  Loading common...~%")
(load (merge-pathnames "simpleagent/common.lisp" *project-root*))

(format t "  Loading kernel-agent...~%")
(load (merge-pathnames "simpleagent/kernel-agent.lisp" *project-root*))

(format t "  Loading process-agent...~%")
(handler-case
    (load (merge-pathnames "simpleagent/process-agent.lisp" *project-root*))
  (error (e)
    (format t "Error loading process-agent: ~A~%" e)))

(format t "~%=== Checking symbols ===~%")
(let ((pkg (find-package "CL-AGENT.SIMPLEAGENT")))
  (format t "  agent-inject-event: ~A~%" (find-symbol "AGENT-INJECT-EVENT" pkg))
  (format t "  make-process-agent: ~A~%" (find-symbol "MAKE-PROCESS-AGENT" pkg)))

(format t "~%=== Load Test Complete ===~%")
