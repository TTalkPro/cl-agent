;;;; test-kernel-filter.lisp
;;;; CL-Agent Tests - Kernel Filter Chain

(in-package :cl-agent/tests)

(def-suite kernel-filter-suite :in cl-agent-suite
  :description "Kernel Filter Chain 测试套件")

(in-suite kernel-filter-suite)

;;; ============================================================
;;; 测试用例
;;; ============================================================

(test test-chain-empty
  "测试空 filter chain 直接执行"
  (let* ((executed nil)
         (execute-fn (lambda (context)
                       (setf executed t)
                       (getf context :tool-name)))
         (chain (cl-agent.kernel:build-filter-chain nil execute-fn))
         (result (funcall chain '(:tool-name :test-tool))))
    (is (eq t executed))
    (is (eq :test-tool result))))

(test test-chain-single
  "测试单个 filter 包装执行器"
  (let* ((filter-called nil)
         (filter (lambda (context next-fn)
                   (setf filter-called t)
                   (funcall next-fn context)))
         (execute-fn (lambda (context)
                       (getf context :tool-name)))
         (chain (cl-agent.kernel:build-filter-chain (list filter) execute-fn))
         (result (funcall chain '(:tool-name :wrapped-tool))))
    (is (eq t filter-called))
    (is (eq :wrapped-tool result))))

(test test-chain-order
  "测试多个 filter 的洋葱顺序"
  (let* ((call-order nil)
         (filter1 (lambda (context next-fn)
                    (push :f1-before call-order)
                    (let ((result (funcall next-fn context)))
                      (push :f1-after call-order)
                      result)))
         (filter2 (lambda (context next-fn)
                    (push :f2-before call-order)
                    (let ((result (funcall next-fn context)))
                      (push :f2-after call-order)
                      result)))
         (execute-fn (lambda (context)
                       (push :exec call-order)
                       (getf context :tool-name)))
         (chain (cl-agent.kernel:build-filter-chain
                 (list filter1 filter2) execute-fn)))
    (funcall chain '(:tool-name :test))
    ;; 顺序应该是: f1-before, f2-before, exec, f2-after, f1-after
    (let ((order (nreverse call-order)))
      (is (equal '(:f1-before :f2-before :exec :f2-after :f1-after) order)))))

(test test-logging-filter
  "测试 logging filter"
  (let* ((output (make-string-output-stream))
         (filter (cl-agent.kernel:make-logging-filter :stream output))
         (execute-fn (lambda (context)
                       (declare (ignore context))
                       "result-value"))
         (chain (cl-agent.kernel:build-filter-chain (list filter) execute-fn))
         (result (funcall chain '(:tool-name :test-tool :tool-args (:x 1)))))
    (is (string= "result-value" result))
    (let ((log-output (string-downcase (get-output-stream-string output))))
      (is (search "calling tool" log-output))
      (is (search "test-tool" log-output)))))

(test test-error-handling-filter
  "测试 error-handling filter 捕获错误"
  (let* ((filter (cl-agent.kernel:make-error-handling-filter))
         (execute-fn (lambda (context)
                       (declare (ignore context))
                       (error "Something went wrong")))
         (chain (cl-agent.kernel:build-filter-chain (list filter) execute-fn))
         (result (funcall chain '(:tool-name :failing-tool))))
    (is (getf result :error))
    (is (search "Something went wrong" (getf result :message)))))

(test test-error-handling-filter-pass-through
  "测试 error-handling filter 正常情况下直接传递"
  (let* ((filter (cl-agent.kernel:make-error-handling-filter))
         (execute-fn (lambda (context)
                       (declare (ignore context))
                       "success"))
         (chain (cl-agent.kernel:build-filter-chain (list filter) execute-fn))
         (result (funcall chain '(:tool-name :ok-tool))))
    (is (string= "success" result))))

(test test-approval-filter-allow
  "测试 approval filter 允许执行"
  (let* ((filter (cl-agent.kernel:make-approval-filter
                  :approver-fn (lambda (ctx)
                                 (declare (ignore ctx))
                                 t)))
         (execute-fn (lambda (context)
                       (declare (ignore context))
                       "approved-result"))
         (chain (cl-agent.kernel:build-filter-chain (list filter) execute-fn))
         (result (funcall chain '(:tool-name :some-tool))))
    (is (string= "approved-result" result))))

(test test-approval-filter-deny
  "测试 approval filter 拒绝执行"
  (let* ((filter (cl-agent.kernel:make-approval-filter
                  :approver-fn (lambda (ctx)
                                 (declare (ignore ctx))
                                 nil)))
         (execute-fn (lambda (context)
                       (declare (ignore context))
                       "should-not-reach"))
         (chain (cl-agent.kernel:build-filter-chain (list filter) execute-fn))
         (result (funcall chain '(:tool-name :blocked-tool))))
    (is (getf result :error))
    (is (getf result :denied))
    (is (search "denied" (getf result :message)))))

(test test-approval-filter-sensitive-only
  "测试 sensitive-only 审批 filter"
  ;; 定义敏感工具
  (defun test-filter-dangerous-op (&key)
    "boom")
  (cl-agent.kernel:declare-tool 'test-filter-dangerous-op
    :description "Dangerous"
    :parameters nil
    :sensitive t)
  (cl-agent.kernel:declare-plugin 'test-filter-plugin
    "Test"
    '(test-filter-dangerous-op))

  (let* ((kernel (cl-agent.kernel:make-kernel
                  :service (cl-agent.mock:make-mock-llm)
                  :plugins '(test-filter-plugin)))
         (filter (cl-agent.kernel:make-approval-filter
                  :sensitive-only t
                  :approver-fn (lambda (ctx)
                                 (declare (ignore ctx))
                                 nil)))
         (execute-fn (lambda (context)
                       (declare (ignore context))
                       "executed"))
         (chain (cl-agent.kernel:build-filter-chain (list filter) execute-fn)))
    ;; 没有 kernel 时不检查敏感性，直接执行
    (let ((result (funcall chain '(:tool-name :test-filter-dangerous-op :kernel nil))))
      (is (string= "executed" result)))
    ;; 有 kernel 时检查敏感性（审批被拒 → 返回 :error 结果）
    (let ((result (funcall chain (list :tool-name :test-filter-dangerous-op :kernel kernel))))
      (is (getf result :error))
      (is (search "denied" (getf result :message))))))
