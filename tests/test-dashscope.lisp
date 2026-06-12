;;;; test-dashscope.lisp
;;;; Test DashScope/Bailian provider

(require :asdf)
(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))

(let ((root (make-pathname :directory (butlast (pathname-directory *load-truename*)))))
  (dolist (d '("" "core/" "llm/" "extra/"))
    (pushnew (merge-pathnames d root) asdf:*central-registry* :test #'equal)))

(ql:quickload :cl-agent-extra :silent t)

(load (merge-pathnames "test-dashscope-impl.lisp"
                       (make-pathname :directory (pathname-directory *load-truename*))))

#+sbcl (sb-ext:exit)
#+ccl (ccl:quit)
