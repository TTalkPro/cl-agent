;;;; test-chat-model.lisp
;;;; CL-Agent - ChatModel 协议与内部工具执行循环测试

(in-package :cl-agent/tests)

(def-suite chat-model-suite :in cl-agent-suite
  :description "ChatModel 协议、Provider 适配器与工具执行循环")

(in-suite chat-model-suite)

;;; ============================================================
;;; 基本调用
;;; ============================================================

(test model-simple-call
  "简单调用返回 chat-response"
  (let* ((provider (make-seq-provider (text-response "你好！")))
         (model (cl-agent.chat:make-provider-chat-model provider))
         (response (cl-agent.chat:chat-model-call model "你好")))
    (is (typep response 'cl-agent.chat:chat-response))
    (is (string= "你好！" (cl-agent.chat:chat-response-text response)))
    (is (eq :stop (cl-agent.chat:chat-response-finish-reason response)))))

(test model-accepts-prompt-string-list
  "chat-model-call 接受字符串 / 消息列表 / prompt"
  (let ((make-model (lambda ()
                      (cl-agent.chat:make-provider-chat-model
                       (make-seq-provider (text-response "ok"))))))
    (is (string= "ok" (cl-agent.chat:chat-response-text
                       (cl-agent.chat:chat-model-call (funcall make-model) "hi"))))
    (is (string= "ok" (cl-agent.chat:chat-response-text
                       (cl-agent.chat:chat-model-call
                        (funcall make-model)
                        (list (cl-agent.chat:user-message "hi"))))))
    (is (string= "ok" (cl-agent.chat:chat-response-text
                       (cl-agent.chat:chat-model-call
                        (funcall make-model)
                        (cl-agent.chat:make-prompt "hi")))))))

(test model-metadata-passthrough
  "usage / model 元数据透传"
  (let* ((provider (make-seq-provider (text-response "ok")))
         (model (cl-agent.chat:make-provider-chat-model provider))
         (response (cl-agent.chat:chat-model-call model "hi"))
         (usage (cl-agent.chat:chat-response-usage response)))
    (is (= 10 (cl-agent.core:llm-usage-input-tokens usage)))
    (is (string= "seq-model"
                 (cl-agent.chat:response-metadata-model
                  (cl-agent.chat:chat-response-metadata-of response))))))

;;; ============================================================
;;; 选项合并与下发
;;; ============================================================

(test model-options-merged-to-provider
  "默认选项与运行时选项合并后下发 provider"
  (let* ((provider (make-seq-provider (text-response "ok")))
         (model (cl-agent.chat:make-provider-chat-model
                 provider
                 :default-options (cl-agent.chat:make-chat-options
                                   :max-tokens 100 :temperature 0.9))))
    (cl-agent.chat:chat-model-call
     model (cl-agent.chat:make-prompt
            "hi" :options (cl-agent.chat:make-chat-options :temperature 0.2)))
    (let ((request (first (seq-provider-requests provider))))
      ;; 运行时覆盖默认
      (is (= 0.2 (getf request :temperature)))
      ;; 未覆盖沿用默认
      (is (= 100 (getf request :max-tokens))))))

(test model-system-message-folded
  "system-message 折叠进中立消息列表"
  (let* ((provider (make-seq-provider (text-response "ok")))
         (model (cl-agent.chat:make-provider-chat-model provider)))
    (cl-agent.chat:chat-model-call
     model (cl-agent.chat:make-prompt "hi" :system "你是助手"))
    (let ((messages (getf (first (seq-provider-requests provider)) :messages)))
      (is (eq :system (getf (first messages) :role)))
      (is (string= "你是助手" (getf (first messages) :content))))))

;;; ============================================================
;;; 内部工具执行循环
;;; ============================================================

(test model-internal-tool-execution
  "tool-call 响应触发内部执行并回传，直到最终文本"
  (let* ((provider (make-seq-provider
                    (tool-call-response "test_adder" '(("a" . 3) ("b" . 4)))
                    (lambda (messages)
                      ;; 第二轮请求应包含 assistant(tool-calls) + tool 结果
                      (let ((roles (mapcar (lambda (m) (getf m :role)) messages)))
                        (assert (member :tool roles)))
                      (let ((tool-msg (find :tool messages
                                            :key (lambda (m) (getf m :role)))))
                        (assert (string= "7" (getf tool-msg :content))))
                      (text-response "3+4=7"))))
         (model (cl-agent.chat:make-provider-chat-model provider))
         (response (cl-agent.chat:chat-model-call
                    model (cl-agent.chat:make-prompt
                           "3+4=?"
                           :options (cl-agent.chat:make-chat-options
                                     :tool-names '("test_adder"))))))
    (is (string= "3+4=7" (cl-agent.chat:chat-response-text response)))
    ;; provider 被调用两轮
    (is (= 2 (length (seq-provider-requests provider))))
    ;; 两轮都带了工具 schema
    (is (every (lambda (req) (= 1 (length (getf req :tools))))
               (seq-provider-requests provider)))))

(test model-tool-execution-disabled
  "internal-tool-execution-enabled=NIL 时原样返回 tool-call 响应"
  (let* ((provider (make-seq-provider
                    (tool-call-response "test_adder" '(("a" . 1) ("b" . 1)))))
         (model (cl-agent.chat:make-provider-chat-model provider))
         (response (cl-agent.chat:chat-model-call
                    model (cl-agent.chat:make-prompt
                           "1+1=?"
                           :options (cl-agent.chat:make-chat-options
                                     :tool-names '("test_adder")
                                     :internal-tool-execution-enabled nil)))))
    (is-true (cl-agent.chat:chat-response-has-tool-calls-p response))
    (is (= 1 (length (seq-provider-requests provider))))))

(test model-return-direct-short-circuit
  "return-direct 工具结果直接作为最终答案，不再回传模型"
  (let* ((provider (make-seq-provider
                    (tool-call-response "test_direct_tool" '(("text" . "急停")))))
         (model (cl-agent.chat:make-provider-chat-model provider))
         (response (cl-agent.chat:chat-model-call
                    model (cl-agent.chat:make-prompt
                           "go"
                           :options (cl-agent.chat:make-chat-options
                                     :tool-names '("test_direct_tool"))))))
    (is (string= "直接结果：急停" (cl-agent.chat:chat-response-text response)))
    ;; 只调用了一轮
    (is (= 1 (length (seq-provider-requests provider))))))

(test model-max-tool-iterations
  "工具循环超过上限报 max-tool-iterations-exceeded-error"
  (let* ((provider (make-instance
                    'seq-provider
                    :queue (loop repeat 10
                                 collect (tool-call-response
                                          "test_adder" '(("a" . 1) ("b" . 1))))))
         (model (cl-agent.chat:make-provider-chat-model provider)))
    (signals cl-agent.chat:max-tool-iterations-exceeded-error
      (cl-agent.chat:chat-model-call
       model (cl-agent.chat:make-prompt
              "loop"
              :options (cl-agent.chat:make-chat-options
                        :tool-names '("test_adder")
                        :max-tool-iterations 3))))))

;;; ============================================================
;;; 流式
;;; ============================================================

(test model-stream-fallback
  "不支持流式的 provider 降级为一次性回调"
  (let* ((provider (make-seq-provider (text-response "完整内容")))
         (model (cl-agent.chat:make-provider-chat-model provider))
         (chunks nil)
         (response (cl-agent.chat:chat-model-stream
                    model "hi" (lambda (delta) (push delta chunks)))))
    (is (equal '("完整内容") (reverse chunks)))
    (is (string= "完整内容" (cl-agent.chat:chat-response-text response)))))
