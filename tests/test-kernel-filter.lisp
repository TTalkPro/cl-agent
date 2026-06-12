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

;;; ============================================================
;;; 洋葱式 Filter 测试（around / before / after / phase）
;;; ============================================================

(test test-onion-before-after-order
  "测试洋葱序：before 正序、after 逆序"
  (let* ((order nil)
         (f1 (cl-agent.kernel:make-filter
              :type :chat :name "f1" :priority 10
              :before (lambda (req) (push :f1-before order) req)
              :after (lambda (resp) (push :f1-after order) resp)))
         (f2 (cl-agent.kernel:make-filter
              :type :chat :name "f2" :priority 20
              :before (lambda (req) (push :f2-before order) req)
              :after (lambda (resp) (push :f2-after order) resp)))
         (terminal (lambda (req)
                     (declare (ignore req))
                     (push :terminal order)
                     :response))
         (chain (cl-agent.kernel:build-phase-chain (list f2 f1) :chat terminal)))
    (is (eq :response (funcall chain :request)))
    ;; priority 10 在外层：f1-before 最先、f1-after 最后
    (is (equal '(:f1-before :f2-before :terminal :f2-after :f1-after)
               (reverse order)))))

(test test-onion-around-short-circuit
  "测试 around 短路：不调 chain，下游不执行"
  (let* ((terminal-called nil)
         (cache (cl-agent.kernel:make-filter
                 :type :tool :name "cache"
                 :around (lambda (req chain)
                           (declare (ignore req chain))
                           "cached-result")))
         (terminal (lambda (req)
                     (declare (ignore req))
                     (setf terminal-called t)
                     "real-result"))
         (chain (cl-agent.kernel:build-phase-chain (list cache) :tool terminal)))
    (is (string= "cached-result" (funcall chain :request)))
    (is (null terminal-called))))

(test test-onion-around-retry
  "测试 around 重试：闭包跨 before/after 段共享状态"
  (let* ((attempts 0)
         (retry (cl-agent.kernel:make-filter
                 :type :tool :name "retry"
                 :around (lambda (req chain)
                           (loop
                             (handler-case
                                 (return (funcall chain req))
                               (error ()
                                 (when (>= attempts 3) (error "give up"))))))))
         (terminal (lambda (req)
                     (declare (ignore req))
                     (incf attempts)
                     (if (< attempts 3)
                         (error "flaky")
                         "ok")))
         (chain (cl-agent.kernel:build-phase-chain (list retry) :tool terminal)))
    (is (string= "ok" (funcall chain :request)))
    (is (= 3 attempts))))

(test test-phase-selection
  "测试 phase 选择：chat 链只挂 chat filter（含旧类型映射）"
  (let* ((hits nil)
         (chat-f (cl-agent.kernel:make-filter
                  :type :chat :name "c"
                  :before (lambda (req) (push :chat hits) req)))
         (tool-f (cl-agent.kernel:make-filter
                  :type :tool :name "t"
                  :before (lambda (req) (push :tool hits) req)))
         (legacy-pre-chat (cl-agent.kernel:make-filter
                           :type :pre-chat :name "lc"
                           :before (lambda (req) (push :legacy-chat hits) req)))
         (legacy-pre-inv (cl-agent.kernel:make-filter
                          :type :pre-invocation :name "li"
                          :before (lambda (req) (push :legacy-tool hits) req)))
         (all (list chat-f tool-f legacy-pre-chat legacy-pre-inv))
         (terminal (lambda (req) (declare (ignore req)) :done)))
    ;; chat 链
    (funcall (cl-agent.kernel:build-phase-chain all :chat terminal) :req)
    (is (null (set-difference hits '(:chat :legacy-chat))))
    (is (= 2 (length hits)))
    ;; tool 链
    (setf hits nil)
    (funcall (cl-agent.kernel:build-phase-chain all :tool terminal) :req)
    (is (null (set-difference hits '(:tool :legacy-tool))))
    (is (= 2 (length hits)))))

(test test-chat-request-rewrite
  "测试 chat filter 改写 chat-request 的 tools / tool-choice"
  (let* ((seen-tools nil)
         (seen-choice nil)
         (injector (cl-agent.kernel:make-filter
                    :type :chat :name "injector"
                    :before (lambda (req)
                              (setf (cl-agent.kernel:chat-request-tools req)
                                    '((:name "injected")))
                              (setf (cl-agent.kernel:chat-request-tool-choice req)
                                    :required)
                              req)))
         (terminal (lambda (req)
                     (setf seen-tools (cl-agent.kernel:chat-request-tools req)
                           seen-choice (cl-agent.kernel:chat-request-tool-choice req))
                     :resp))
         (chain (cl-agent.kernel:build-phase-chain (list injector) :chat terminal))
         (request (cl-agent.kernel:make-chat-request :messages nil)))
    (funcall chain request)
    (is (equal '((:name "injected")) seen-tools))
    (is (eq :required seen-choice))))

(test test-filter-result-clos
  "测试 CLOS filter-result 控制流（:skip 短路）"
  (let* ((skipper (cl-agent.kernel:make-filter
                   :type :tool :name "skipper"
                   :fn (lambda (req next-fn)
                         (declare (ignore req next-fn))
                         (cl-agent.kernel:make-filter-result
                          :skip :result "skipped-value"))))
         (terminal (lambda (req) (declare (ignore req)) "real"))
         (chain (cl-agent.kernel:build-filter-chain (list skipper) terminal)))
    (is (cl-agent.kernel:filter-result-p
         (cl-agent.kernel:make-filter-result :continue)))
    (is (string= "skipped-value" (funcall chain :req)))))

(test test-class-based-filter-apply
  "测试类式 filter：仅特化 filter-apply 也能挂入链"
  (let ((applied nil))
    (defclass test-apply-only-filter (cl-agent.kernel:filter) ())
    (defmethod cl-agent.kernel:filter-apply ((f test-apply-only-filter) request)
      (declare (ignore request))
      (setf applied t)
      (list :action :continue))
    (let* ((f (make-instance 'test-apply-only-filter :type :chat :name "apply-only"))
           (terminal (lambda (req) (declare (ignore req)) :done))
           (chain (cl-agent.kernel:build-phase-chain (list f) :chat terminal)))
      (is (eq :done (funcall chain :req)))
      (is (eq t applied)))))
