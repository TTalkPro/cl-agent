;;;; run-tests.lisp
;;;; CL-Agent 测试入口：sbcl --non-interactive --load run-tests.lisp

(require :asdf)

;; Add paths
(dolist (dir '("." "core/" "llm/" "mock/"))
  (pushnew (truename dir) asdf:*central-registry* :test #'equal))

;; Load quicklisp if available
(let ((ql-setup (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname))))
  (when (probe-file ql-setup)
    (load ql-setup)))

(format t "~%Loading cl-agent-test...~%")
;; cl-agent-test 与 cl-agent 定义在同一 asd 文件，先解析主系统
(asdf:find-system :cl-agent)
(asdf:load-system :cl-agent-test)

(format t "~%Running test suite...~%~%")
(let ((results (uiop:symbol-call :fiveam :run
                                 (uiop:find-symbol* :cl-agent-suite :cl-agent/tests))))
  (uiop:symbol-call :fiveam :explain! results)
  (if (uiop:symbol-call :fiveam :results-status results)
      (format t "~%All tests passed.~%")
      (uiop:quit 1)))
