;;;; step-load-test.lisp
;;;; Load things step by step to isolate the issue

(require :asdf)

(defparameter *base-dir*
  (make-pathname :directory (pathname-directory *load-truename*)))

(defparameter *project-root*
  (merge-pathnames "../" *base-dir*))

;; Load quicklisp
(let ((ql-setup (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname))))
  (when (probe-file ql-setup)
    (load ql-setup)))

;; Add just core path
(pushnew (merge-pathnames "core/" *project-root*) asdf:*central-registry* :test #'equal)

(format t "~%=== Step 1: Load core (without process module) ===~%")
(format t "Quickloading dependencies...~%")
(ql:quickload '(:alexandria :serapeum :cl-ppcre :local-time :log4cl :uuid
                :com.inuoe.jzon :lparallel :bordeaux-threads :closer-mop
                :dexador :quri :flexi-streams :usocket) :silent t)
(format t "Dependencies loaded.~%")

(format t "~%=== Step 2: Load core package ===~%")
(load (merge-pathnames "core/package-core.lisp" *project-root*))
(format t "Package loaded.~%")

(format t "~%=== Step 3: Load core infrastructure files ===~%")
(dolist (file '("conditions" "macros" "types" "documentation" "utils"
                "validation" "dependency-injection" "data-convert"))
  (format t "  Loading ~A...~%" file)
  (load (merge-pathnames (format nil "core/~A.lisp" file) *project-root*)))

(format t "~%=== Step 4: Load protocols ===~%")
(load (merge-pathnames "core/protocols/protocols.lisp" *project-root*))

(format t "~%=== Step 5: Load HTTP module ===~%")
(dolist (file '("package-http" "conditions" "client" "async" "retry" "streaming"))
  (format t "  Loading http/~A...~%" file)
  (load (merge-pathnames (format nil "core/http/~A.lisp" file) *project-root*)))

(format t "~%=== Step 6: Load kernel module ===~%")
(dolist (file '("package" "function" "macros" "plugin" "context" "provider"
                "service" "filter" "kernel" "chat"))
  (format t "  Loading kernel/~A...~%" file)
  (load (merge-pathnames (format nil "core/kernel/~A.lisp" file) *project-root*)))

(format t "~%=== Step 7: Load process module ===~%")
(dolist (file '("package" "event" "step" "state-machine" "human-loop" "process" "runtime"))
  (format t "  Loading process/~A...~%" file)
  (handler-case
      (load (merge-pathnames (format nil "core/process/~A.lisp" file) *project-root*))
    (error (e)
      (format t "  ERROR loading ~A: ~A~%" file e)
      (return))))

(format t "~%=== Step 8: Check process symbols ===~%")
(let ((pkg (find-package "CL-AGENT.PROCESS")))
  (if pkg
      (progn
        (format t "  Package exists: ~A~%" pkg)
        (format t "  make-event-bus: ~A~%" (find-symbol "MAKE-EVENT-BUS" pkg))
        (format t "  make-event-queue: ~A~%" (find-symbol "MAKE-EVENT-QUEUE" pkg)))
      (format t "  Package not found!~%")))

(format t "~%=== Load Test Complete ===~%")
