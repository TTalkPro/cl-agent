;;;; test-integration-kernel.lisp
;;;; CL-Agent Tests - Kernel Integration Tests
;;;;
;;;; 概述：
;;;;   使用 Mock LLM 进行集成测试。
;;;;   真实 LLM 测试需要设置 API 密钥后手动运行。

(in-package :cl-agent/tests)

(def-suite kernel-integration-suite :in cl-agent-suite
  :description "Kernel Integration 测试套件")

(in-suite kernel-integration-suite)

;;; ============================================================
;;; 测试辅助
;;; ============================================================

(defun setup-integration-tools ()
  "注册集成测试用工具和插件"
  (defun test-integ-add (&key a b)
    (+ a b))
  (cl-agent.kernel:declare-tool 'test-integ-add
    :description "Add numbers"
    :parameters '((a :int "First" :required-p t)
                  (b :int "Second" :required-p t)))

  (defun test-integ-greet (&key name)
    (format nil "Hello, ~A!" name))
  (cl-agent.kernel:declare-tool 'test-integ-greet
    :description "Greet someone"
    :parameters '((name :string "Name" :required-p t)))

  (cl-agent.kernel:declare-plugin 'test-integ-math-plugin
    "Math tools"
    '(test-integ-add))

  (cl-agent.kernel:declare-plugin 'test-integ-utils-plugin
    "Utilities"
    '(test-integ-greet)))

;;; ============================================================
;;; Mock 集成测试
;;; ============================================================

(test test-integration-mock-simple-chat
  "集成测试：Mock LLM 简单对话"
  (let* ((mock (cl-agent.mock:make-mock-llm))
         (kernel (cl-agent.kernel:make-kernel :service mock))
         (history (cl-agent.kernel:make-chat-history)))
    (cl-agent.kernel:history-add history :user "你好")
    (let ((result (cl-agent.kernel:invoke-kernel kernel history)))
      (is (stringp (getf result :text)))
      (is (> (length (getf result :text)) 0)))))

(test test-integration-mock-with-plugin
  "集成测试：Mock LLM + Plugin"
  (setup-integration-tools)
  (let* (;; 使用 sequenced mock 模拟工具调用
         (mock (make-instance 'sequenced-mock-llm
                 :responses (list
                             ;; 返回工具调用
                             (list :content ""
                                   :tool-calls (list (list :id "call_add"
                                                           :name "test-integ-add"
                                                           :arguments '(:a 3 :b 5))))
                             ;; 返回最终答案
                             (list :content "The answer is 8."))))
         (kernel (cl-agent.kernel:make-kernel
                  :service mock
                  :plugins '(test-integ-math-plugin)))
         (history (cl-agent.kernel:make-chat-history)))
    (cl-agent.kernel:history-add history :user "What is 3+5?")
    (let ((result (cl-agent.kernel:invoke-kernel kernel history)))
      (is (string= "The answer is 8." (getf result :text)))
      ;; 验证工具确实被调用了
      (let ((tool-calls (getf result :tool-calls-made)))
        (is (= 1 (length tool-calls)))
        (is (eq :test-integ-add (getf (first tool-calls) :name)))
        ;; 工具返回了正确结果
        (is (= 8 (getf (first tool-calls) :result)))))))

(test test-integration-full-pipeline
  "集成测试：完整管道（Plugin + Filter + Chat）"
  (setup-integration-tools)
  (let* ((log-output (make-string-output-stream))
         (mock (make-instance 'sequenced-mock-llm
                 :responses (list
                             (list :content ""
                                   :tool-calls (list (list :id "call_greet"
                                                           :name "test-integ-greet"
                                                           :arguments '(:name "World"))))
                             (list :content "Greeting sent!"))))
         (kernel (cl-agent.kernel:make-kernel
                  :service mock
                  :plugins '(test-integ-utils-plugin)
                  :filters (list (cl-agent.kernel:make-logging-filter
                                  :stream log-output))))
         (history (cl-agent.kernel:make-chat-history)))
    (cl-agent.kernel:history-add history :user "Say hello to World")
    (let ((result (cl-agent.kernel:invoke-kernel kernel history)))
      (is (string= "Greeting sent!" (getf result :text)))
      ;; 验证 logging filter 记录了日志
      (let ((logs (string-downcase (get-output-stream-string log-output))))
        (is (search "calling tool" logs))
        (is (search "greet" logs))))))

;;; ============================================================
;;; 真实 LLM 集成测试（需手动运行）
;;; ============================================================
;;; 取消注释以下代码并设置 API 密钥来运行真实测试：
;;;
;;; (test test-integration-zhipu-chat
;;;   "集成测试：ZhipuAI 简单对话"
;;;   (let* ((provider (cl-agent.llm:make-zhipu-provider :model "glm-4-flash"))
;;;          (kernel (cl-agent.kernel:make-kernel :service provider))
;;;          (history (cl-agent.kernel:make-chat-history)))
;;;     (cl-agent.kernel:history-add history :user "1+1=?")
;;;     (let ((result (cl-agent.kernel:invoke-kernel kernel history
;;;                     :settings '(:function-choice :none))))
;;;       (is (stringp (getf result :text)))
;;;       (is (search "2" (getf result :text))))))
