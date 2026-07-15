;;;; run-tests.lisp
;;;; CL-Agent 测试入口：
;;;;   sbcl --non-interactive --load run-tests.lisp
;;;;   ccl  --no-init --batch --load run-tests.lisp
;;;;
;;;; 退出码：0 全部通过，1 有失败——两条路径都显式 quit。
;;;; 成功时也必须显式 quit：SBCL 的 --non-interactive 跑完即退，
;;;; 但 CCL 的 --batch 跑完会去读 stdin，stdin 不是 EOF 时直接挂住
;;;; （CI 里就是挂到 job 超时）。在这里统一收口，好过让每个调用方
;;;; 各自记得补 </dev/null 或 --eval '(quit)'。

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
      (progn (format t "~%All tests passed.~%")
             (uiop:quit 0))
      (uiop:quit 1)))
