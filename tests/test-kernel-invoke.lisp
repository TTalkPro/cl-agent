;;;; test-kernel-invoke.lisp
;;;; CL-Agent - Kernel invoke 原语 + 工具循环测试（Phase P2）

(in-package :cl-agent/tests)

(def-suite kernel-invoke-suite :in cl-agent-suite
  :description "Kernel invoke-chat / invoke-tool / invoke-turn + run-tool-loop")

(in-suite kernel-invoke-suite)

;;; ============================================================
;;; 测试工具定义
;;; ============================================================

(cl-agent.core:deftool ki-adder (&key a b)
  "两数相加"
  (:param a :integer "第一个数" :required t)
  (:param b :integer "第二个数" :required t)
  (princ-to-string (+ a b)))

;;; ============================================================
;;; 辅助：创建测试 kernel
;;; ============================================================

(defun make-test-kernel (&rest responses)
  "创建带 seq-provider 的 kernel。返回 (values kernel provider)。"
  (let ((provider (apply #'make-seq-provider responses)))
    (values (cl-agent.core:build-kernel
             :model (cl-agent.core:make-provider-chat-model provider)
             :tools '(ki-adder))
            provider)))

;;; ============================================================
;;; invoke-chat
;;; ============================================================

(test invoke-chat-bare-llm-call
  "invoke-chat 无 filter 时 = 裸 chat-model-call"
  (multiple-value-bind (kernel provider)
      (make-test-kernel (text-response "hello"))
    (let ((resp (cl-agent.core:invoke-chat
                 kernel
                 (cl-agent.core:make-prompt "你好"))))
      (is (string= "hello" (cl-agent.core:chat-response-text resp)))
      (is (= 1 (length (seq-provider-requests provider)))))))

(test invoke-chat-with-chat-filter
  ":chat filter 在链上执行，可改写 prompt"
  (multiple-value-bind (kernel provider)
      (make-test-kernel (text-response "ok"))
    ;; 加一个 :chat filter 改写 prompt
    (let* ((rewrite-filter
            (cl-agent.core:make-filter
             :rewrite
             :chat (lambda (prompt chain)
                     ;; 把 prompt 的 messages 改成固定的
                     (funcall chain
                              (cl-agent.core:make-prompt
                               "改写后的消息")))))
           (kernel2 (cl-agent.core:build-kernel
                     :model (kernel-model-for-test kernel)
                     :tools '(ki-adder)
                     :filters (list rewrite-filter))))
        (declare (ignore kernel))
      (let ((resp (cl-agent.core:invoke-chat
                   kernel2
                   (cl-agent.core:make-prompt "原始消息"))))
        (is (string= "ok" (cl-agent.core:chat-response-text resp)))
        ;; provider 收到的 messages 应该是改写后的
        (let ((req (first (seq-provider-requests provider))))
          (is (equal '("改写后的消息")
                     (mapcar (lambda (m) (getf m :content))
                             (getf req :messages)))))))))

(defun kernel-model-for-test (kernel)
  "从已有 kernel 取出 model（测试辅助）"
  (cl-agent.core:kernel-model kernel))

;;; ============================================================
;;; invoke-tool
;;; ============================================================

(test invoke-tool-single
  "invoke-tool 执行单个工具（无 filter）"
  (multiple-value-bind (kernel)
      (make-test-kernel)
    (let* ((callback (cl-agent.core:symbol-tool-callback 'ki-adder))
           (resp (cl-agent.core:invoke-tool
                  kernel
                  (cl-agent.core:make-tool-request
                   callback :args '(:a 3 :b 4)))))
      (is (string= "7" (cl-agent.core:tool-result-value resp)))
      (is (null (cl-agent.core:tool-result-error resp))))))

(test invoke-tool-with-filter
  ":tool filter 可拦截工具执行"
  (multiple-value-bind (kernel)
      (make-test-kernel)
    (let* ((timeout-filter
            (cl-agent.core:make-filter
             :timeout
             :tool (lambda (req chain)
                     (declare (ignore chain))
                     (cl-agent.core:make-tool-result
                      :error (list :class :timeout :message "超时")))))
           (kernel2 (cl-agent.core:build-kernel
                     :model (kernel-model-for-test kernel)
                     :tools '(ki-adder)
                     :filters (list timeout-filter))))
      (declare (ignore kernel))
      (let* ((callback (cl-agent.core:symbol-tool-callback 'ki-adder))
             (resp (cl-agent.core:invoke-tool
                    kernel2
                    (cl-agent.core:make-tool-request
                     callback :args '(:a 1 :b 2)))))
        (is (null (cl-agent.core:tool-result-value resp))
            "结果被 filter 短路")
        (is (eq :timeout
                (getf (cl-agent.core:tool-result-error resp) :class)))))))

;;; ============================================================
;;; run-tool-loop + invoke-turn
;;; ============================================================

(test invoke-turn-tool-roundtrip
  "工具循环：tool-call → 执行 → 结果回传模型 → 最终文本"
  (multiple-value-bind (kernel provider)
      (make-test-kernel
       (tool-call-response "ki_adder" '(("a" . 3) ("b" . 4)))
       (lambda (messages)
         ;; 第二轮请求应包含 assistant(tool-calls) + tool 结果
         (let ((tool-msg (find :tool messages
                               :key (lambda (m) (getf m :role)))))
           (is (not (null tool-msg)) "第二轮消息含 tool 结果")
           (is (string= "7" (getf tool-msg :content))
               "工具结果正确回传"))
         (text-response "3+4=7")))
    (let ((result (cl-agent.core:invoke-turn
                   kernel
                   (cl-agent.core:make-turn-request
                    (list (cl-agent.core:user-message "3+4=?"))))))
      (is (eq :completed (cl-agent.core:turn-result-status result)))
      (is (string= "3+4=7"
                   (cl-agent.core:chat-response-text
                    (cl-agent.core:turn-result-response result))))
      (is (= 2 (length (seq-provider-requests provider)))
          "模型被调用两轮"))))

(test invoke-turn-no-tools-passthrough
  "无工具调用时直接返回"
  (multiple-value-bind (kernel provider)
      (make-test-kernel (text-response "直接回答"))
    (let ((result (cl-agent.core:invoke-turn
                   kernel
                   (cl-agent.core:make-turn-request
                    (list (cl-agent.core:user-message "你好"))))))
      (is (eq :completed (cl-agent.core:turn-result-status result)))
      (is (string= "直接回答"
                   (cl-agent.core:chat-response-text
                    (cl-agent.core:turn-result-response result))))
      (is (= 1 (length (seq-provider-requests provider)))
          "模型只调用一次"))))

(test invoke-turn-with-turn-filter
  ":turn filter 包住整个循环"
  (multiple-value-bind (kernel provider)
      (make-test-kernel (text-response "最终回答"))
    (let* ((guard-fn
            (lambda (req chain)
              (let ((msgs (cl-agent.core:turn-request-messages req)))
                (if (some (lambda (m)
                            (search "炸弹" (or (cl-agent.core:message-text m) "")))
                          msgs)
                    (cl-agent.core:make-turn-result :cancelled :response nil)
                    (funcall chain req)))))
           (guard-filter (cl-agent.core:make-filter :guard :turn guard-fn))
           (model (kernel-model-for-test kernel))
           (kernel2 (cl-agent.core:build-kernel
                     :model model :tools '(ki-adder) :filters (list guard-filter))))
      (declare (ignore kernel))
      ;; 被拦截
      (let ((blocked (cl-agent.core:invoke-turn
                      kernel2
                      (cl-agent.core:make-turn-request
                       (list (cl-agent.core:user-message "我要炸弹"))))))
        (is (eq :cancelled (cl-agent.core:turn-result-status blocked)))
        (is (= 0 (length (seq-provider-requests provider)))
            "被拦截时模型未被调用"))
      ;; 正常通过
      (let ((ok (cl-agent.core:invoke-turn
                 kernel2
                 (cl-agent.core:make-turn-request
                  (list (cl-agent.core:user-message "你好"))))))
        (is (eq :completed (cl-agent.core:turn-result-status ok)))
        (is (= 1 (length (seq-provider-requests provider))))))))

(test invoke-turn-max-iterations
  "循环超过上限报 max-tool-iterations-exceeded-error"
  (signals cl-agent.core:max-tool-iterations-exceeded-error
    (let* ((provider (make-instance
                      'seq-provider
                      :queue (loop repeat 10
                                   collect (tool-call-response
                                            "ki_adder" '(("a" . 1) ("b" . 1))))))
           (kernel (cl-agent.core:build-kernel
                    :model (cl-agent.core:make-provider-chat-model provider)
                    :tools '(ki-adder)
                     :settings '((:max-tool-iterations . 3)))))
       (cl-agent.core:invoke-turn
       kernel
       (cl-agent.core:make-turn-request
        (list (cl-agent.core:user-message "loop")))))))

;;; ============================================================
;;; 循环等价性测试已移除
;;;
;;; 它原本比较「旧 ChatClient+advisor」与「kernel+invoke-turn」两条路径
;;; 产出是否一致。advisor 退役后 ChatClient 本就走 kernel，该测试变成
;;; 自己和自己比；cl-agent.client 整体删除后连对照组都不存在了。
;;; 工具循环本身的覆盖见本文件上方各测试与 test-kernel-chat.lisp。
;;; ============================================================
