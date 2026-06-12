;;;; glm47-dual-provider-test.lisp
;;;; Test GLM-4.7 with both Anthropic and OpenAI compatible APIs

(require :asdf)
(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))

(let ((root (make-pathname :directory (butlast (pathname-directory *load-truename*)))))
  (dolist (d '("" "core/" "llm/" "extra/"))
    (pushnew (merge-pathnames d root) asdf:*central-registry* :test #'equal)))

(ql:quickload :cl-agent-extra :silent t)

;; Load test implementation
(load (merge-pathnames "glm47-dual-provider-test-impl.lisp"
                       (make-pathname :directory (pathname-directory *load-truename*))))

#+sbcl (sb-ext:exit)
#+ccl (ccl:quit)
