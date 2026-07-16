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
         (model (cl-agent.core:make-provider-chat-model provider))
         (response (cl-agent.core:chat-model-call model "你好")))
    (is (typep response 'cl-agent.core:chat-response))
    (is (string= "你好！" (cl-agent.core:chat-response-text response)))
    (is (eq :stop (cl-agent.core:chat-response-finish-reason response)))))

(test model-accepts-prompt-string-list
  "chat-model-call 接受字符串 / 消息列表 / prompt"
  (let ((make-model (lambda ()
                      (cl-agent.core:make-provider-chat-model
                       (make-seq-provider (text-response "ok"))))))
    (is (string= "ok" (cl-agent.core:chat-response-text
                       (cl-agent.core:chat-model-call (funcall make-model) "hi"))))
    (is (string= "ok" (cl-agent.core:chat-response-text
                       (cl-agent.core:chat-model-call
                        (funcall make-model)
                        (list (cl-agent.core:user-message "hi"))))))
    (is (string= "ok" (cl-agent.core:chat-response-text
                       (cl-agent.core:chat-model-call
                        (funcall make-model)
                        (cl-agent.core:make-prompt "hi")))))))

(test model-metadata-passthrough
  "usage / model 元数据透传"
  (let* ((provider (make-seq-provider (text-response "ok")))
         (model (cl-agent.core:make-provider-chat-model provider))
         (response (cl-agent.core:chat-model-call model "hi"))
         (usage (cl-agent.core:chat-response-usage response)))
    (is (= 10 (cl-agent.core:llm-usage-input-tokens usage)))
    (is (string= "seq-model"
                 (cl-agent.core:response-metadata-model
                  (cl-agent.core:chat-response-metadata-of response))))))

;;; ============================================================
;;; 选项合并与下发
;;; ============================================================

(test model-options-merged-to-provider
  "默认选项与运行时选项合并后下发 provider"
  (let* ((provider (make-seq-provider (text-response "ok")))
         (model (cl-agent.core:make-provider-chat-model
                 provider
                 :default-options (cl-agent.core:make-chat-options
                                   :max-tokens 100 :temperature 0.9))))
    (cl-agent.core:chat-model-call
     model (cl-agent.core:make-prompt
            "hi" :options (cl-agent.core:make-chat-options :temperature 0.2)))
    (let ((request (first (seq-provider-requests provider))))
      ;; 运行时覆盖默认
      (is (= 0.2 (getf request :temperature)))
      ;; 未覆盖沿用默认
      (is (= 100 (getf request :max-tokens))))))

(test model-system-message-folded
  "system-message 折叠进中立消息列表"
  (let* ((provider (make-seq-provider (text-response "ok")))
         (model (cl-agent.core:make-provider-chat-model provider)))
    (cl-agent.core:chat-model-call
     model (cl-agent.core:make-prompt "hi" :system "你是助手"))
    (let ((messages (getf (first (seq-provider-requests provider)) :messages)))
      (is (eq :system (getf (first messages) :role)))
      (is (string= "你是助手" (getf (first messages) :content))))))

;;; ============================================================
;;; 单次调用语义（2.0：ChatModel 不执行工具）
;;; ============================================================

(test model-injects-tool-schema
  "工具引用解析为 schema 下发 provider（但不执行）"
  (let* ((provider (make-seq-provider (text-response "ok")))
         (model (cl-agent.core:make-provider-chat-model provider)))
    (cl-agent.core:chat-model-call
     model (cl-agent.core:make-prompt
            "hi" :options (cl-agent.core:make-chat-options
                           :tool-names '(test-adder))))
    (let ((tools (getf (first (seq-provider-requests provider)) :tools)))
      (is (= 1 (length tools)))
      (is (string= "test_adder" (getf (first tools) :name))))))

(test model-returns-tool-calls-as-is
  "携带 tool-calls 的响应原样返回（工具循环属于 tool-calling-advisor）"
  (let* ((provider (make-seq-provider
                    (tool-call-response "test_adder" '(("a" . 1) ("b" . 1)))))
         (model (cl-agent.core:make-provider-chat-model provider))
         (response (cl-agent.core:chat-model-call
                    model (cl-agent.core:make-prompt
                           "1+1=?"
                           :options (cl-agent.core:make-chat-options
                                     :tool-names '(test-adder))))))
    (is-true (cl-agent.core:chat-response-has-tool-calls-p response))
    ;; 只调用一轮：ChatModel 不执行工具
    (is (= 1 (length (seq-provider-requests provider))))))

;;; ============================================================
;;; 流式
;;; ============================================================

(test model-stream-fallback
  "不支持流式的 provider 降级为一次性回调"
  (let* ((provider (make-seq-provider (text-response "完整内容")))
         (model (cl-agent.core:make-provider-chat-model provider))
         (chunks nil)
         (response (cl-agent.core:chat-model-stream
                    model "hi" (lambda (delta) (push delta chunks)))))
    (is (equal '("完整内容") (reverse chunks)))
    (is (string= "完整内容" (cl-agent.core:chat-response-text response)))))
