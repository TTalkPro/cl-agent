;;;; test-tools-tags.lisp
;;;; Test new tools + tags architecture

(require :asdf)
(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))

(let ((root (make-pathname :directory (butlast (pathname-directory *load-truename*)))))
  (dolist (d '("" "core/" "llm/" "extra/" "plugin/"))
    (pushnew (merge-pathnames d root) asdf:*central-registry* :test #'equal)))

;; Load tools first, then simpleagent
(ql:quickload :cl-agent-extra :silent t)
(ql:quickload :cl-agent-extra :silent t)

;; Load test implementation
(load (merge-pathnames "test-tools-tags-impl.lisp"
                       (make-pathname :directory (pathname-directory *load-truename*))))

#+sbcl (sb-ext:exit)
#+ccl (ccl:quit)
