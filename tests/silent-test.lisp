;;;; silent-test.lisp - Quick verification tests

(require :asdf)
(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))

(let ((root (make-pathname :directory (butlast (pathname-directory *load-truename*)))))
  (dolist (d '("" "core/" "llm/" "simpleagent/"))
    (pushnew (merge-pathnames d root) asdf:*central-registry* :test #'equal)))

(ql:quickload :cl-agent-simpleagent :silent t)

;; Now load the actual tests after packages exist
(load (merge-pathnames "silent-test-impl.lisp"
                       (make-pathname :directory (pathname-directory *load-truename*))))

#+sbcl (sb-ext:exit)
#+ccl (ccl:quit)
