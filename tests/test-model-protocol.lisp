;;;; test-model-protocol.lisp
;;;; CL-Agent - Model 抽象协议（ModelRequest / ModelResponse / ModelResult）
;;;;
;;;; 这一层的价值全在「横切代码能不能不分模态地写一遍」。所以测试的重点
;;;; 不是各个访问器能不能取到值，而是：**同一段代码对 chat 与 embedding
;;;; 两种响应都成立**。只测前者的话，协议退化成一堆别名。

(in-package :cl-agent/tests)

(def-suite model-protocol-suite :in cl-agent-suite
  :description "Model 抽象协议：各模态接入 + 横切代码不分模态")

(in-suite model-protocol-suite)

;;; ============================================================
;;; 继承关系
;;; ============================================================

(test concrete-classes-plug-into-the-protocol
  "各模态的具体类都接进抽象基类——协议方法才有分派依据"
  (is (subtypep 'cl-agent/core:prompt 'cl-agent/core:model-request))
  (is (subtypep 'cl-agent/core:chat-response 'cl-agent/core:model-response))
  (is (subtypep 'cl-agent/core:generation 'cl-agent/core:model-result))
  (is (subtypep 'cl-agent/core:chat-options 'cl-agent/core:model-options))
  ;; embedding 是「不分模态」这句话的证人：它和 chat 在两个不同的模块里
  (is (subtypep 'cl-agent/core:embedding-response 'cl-agent/core:model-response)))

;;; ============================================================
;;; 请求协议
;;; ============================================================

(test prompt-answers-the-request-protocol
  "prompt 的领域访问器与协议访问器映射到同一对槽"
  (let* ((options (cl-agent/core:make-chat-options :temperature 0.5))
         (prompt (cl-agent/core:make-prompt
                  (list (cl-agent/core:user-message "hi")) :options options)))
    (is (eq (cl-agent/core:prompt-messages prompt)
            (cl-agent/core:request-instructions prompt)))
    (is (eq options (cl-agent/core:request-options prompt)))
    ;; 没有 options 时协议方法给 NIL，不报错
    (is (null (cl-agent/core:request-options (cl-agent/core:make-prompt "x"))))))

;;; ============================================================
;;; 响应协议
;;; ============================================================

(test chat-response-answers-the-response-protocol
  "chat-response：results = generations，result = 首个"
  (let* ((gen (cl-agent/core:make-generation
               (cl-agent/core:assistant-message "答案") :finish-reason :stop))
         (response (cl-agent/core:make-chat-response gen)))
    (is (eq gen (cl-agent/core:response-result response)))
    (is (equal (cl-agent/core:chat-response-generations response)
               (cl-agent/core:response-results response)))
    ;; result-output 取出候选承载的东西本身
    (is (string= "答案" (cl-agent/core:message-text
                         (cl-agent/core:result-output gen))))
    ;; 结果级元数据 ≠ 响应级：前者是这一个候选的 finish-reason
    (is (eq :stop (getf (cl-agent/core:result-metadata gen) :finish-reason)))))

(test response-result-defaults-to-first-of-results
  "只实现 response-results 就自动获得 response-result（基类缺省实现）"
  (let* ((g1 (cl-agent/core:make-generation
              (cl-agent/core:assistant-message "一") :finish-reason :stop))
         (g2 (cl-agent/core:make-generation
              (cl-agent/core:assistant-message "二") :finish-reason :stop))
         (response (cl-agent/core:make-chat-response (list g1 g2))))
    (is (= 2 (length (cl-agent/core:response-results response))))
    (is (eq g1 (cl-agent/core:response-result response)))))

(test empty-response-yields-nil-not-an-error
  "无候选的响应：response-result 给 NIL 而不是报错"
  (let ((response (cl-agent/core:make-chat-response nil)))
    (is (null (cl-agent/core:response-results response)))
    (is (null (cl-agent/core:response-result response)))))

;;; ============================================================
;;; 协议的意义：横切代码不分模态
;;; ============================================================

(defun %total-tokens-of (response)
  "一段**不知道自己在处理哪种模态**的计费代码。

它只认 model-response 协议——这正是协议层存在的理由。协议出现之前，
这个函数只能写成 typecase 分模态，每加一种模态就得改它。"
  (let ((usage (cl-agent/core:response-usage response)))
    (if usage
        (+ (or (cl-agent/core:llm-usage-input-tokens usage) 0)
           (or (cl-agent/core:llm-usage-output-tokens usage) 0))
        0)))

(test one-billing-function-serves-chat-and-embedding
  "同一段计费代码同时吃 chat-response 与 embedding-response"
  (let ((chat (cl-agent/core:make-chat-response
               (cl-agent/core:make-generation
                (cl-agent/core:assistant-message "x") :finish-reason :stop)
               :metadata (cl-agent/core:make-chat-response-metadata
                          :usage (cl-agent/core:make-llm-usage
                                  :input-tokens 12 :output-tokens 8))))
        (embedding (cl-agent/core:make-embedding-response
                    :embeddings (list #(0.1 0.2))
                    :usage (cl-agent/core:make-llm-usage
                            :input-tokens 5 :output-tokens 0))))
    (is (= 20 (%total-tokens-of chat)))
    (is (= 5 (%total-tokens-of embedding)))
    ;; 没有 usage 的响应也不能把它打断
    (is (= 0 (%total-tokens-of (cl-agent/core:make-chat-response nil))))))

(test embedding-response-answers-results-protocol
  "embedding-response 的 results = 向量列表"
  (let* ((v1 #(0.1 0.2)) (v2 #(0.3 0.4))
         (response (cl-agent/core:make-embedding-response
                    :embeddings (list v1 v2))))
    (is (equal (list v1 v2) (cl-agent/core:response-results response)))
    (is (eq v1 (cl-agent/core:response-result response)))))

(test metadata-usage-is-nil-for-unknown-metadata
  "不认识的元数据类型返回 NIL 而不是报错——横切代码遇到新模态时不该炸"
  (is (null (cl-agent/core:metadata-usage "不是元数据对象")))
  (is (null (cl-agent/core:metadata-usage 42))))
