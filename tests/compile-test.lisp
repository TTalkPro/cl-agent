;;;; compile-test.lisp
;;;; Test compiling process-agent.lisp

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

(format t "~%Loading cl-agent-core...~%")
(ql:quickload :cl-agent-core :silent t)

(format t "~%Testing simpleagent package...~%")
(unless (find-package "CL-AGENT.SIMPLEAGENT")
  (format t "Loading simpleagent package...~%")
  (load (merge-pathnames "simpleagent/package.lisp" *project-root*)))

(format t "~%Loading common.lisp...~%")
(load (merge-pathnames "simpleagent/common.lisp" *project-root*))

(format t "~%Loading kernel-agent.lisp...~%")
(load (merge-pathnames "simpleagent/kernel-agent.lisp" *project-root*))

(format t "~%Compiling process-agent.lisp...~%")
(handler-case
    (progn
      (compile-file (merge-pathnames "simpleagent/process-agent.lisp" *project-root*))
      (format t "~%Compile test: PASSED~%"))
  (error (e)
    (format t "~%Compile test: FAILED~%")
    (format t "Error: ~A~%" e)))
