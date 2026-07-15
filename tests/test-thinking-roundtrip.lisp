;;;; test-thinking-roundtrip.lisp
;;;; CL-Agent - Anthropic 扩展思考块回传测试
;;;;
;;;; 背景：
;;;;   Anthropic 的扩展思考块带密码学 signature。在工具调用对话中，
;;;;   API *要求* assistant 轮把 thinking 块连同 signature 原样回传，
;;;;   否则请求被拒。此前实现只把 thinking 的*文本*提取进 reasoning，
;;;;   signature 被丢弃，导致根本无法回传。
;;;;
;;;; 覆盖回传通路的每一层：
;;;;   provider 解析（流式 + 非流式）→ llm-response-reasoning-blocks
;;;;     → assistant-message metadata → message->neutral
;;;;       → parse-messages-for-anthropic 请求体
;;;;
;;;; 以及 SPI「存在才发送」契约：temperature 未指定时不得出现在请求体里。

(in-package :cl-agent/tests)

(def-suite thinking-roundtrip-suite :in cl-agent-suite
  :description "扩展思考块回传 + SPI 存在才发送契约")

(in-suite thinking-roundtrip-suite)

(defun ht (&rest kv)
  (let ((h (make-hash-table :test 'equal)))
    (loop for (k v) on kv by #'cddr do (setf (gethash k h) v))
    h))

;;; ============================================================
;;; provider 解析：保留 signature
;;; ============================================================

(test thinking-blocks-preserved-with-signature
  "非流式解析：thinking 块连同 signature 原样保留"
  (let* ((blocks (vector (ht "type" "thinking" "thinking" "先想想" "signature" "sig-abc")
                         (ht "type" "text" "text" "答案")))
         (kept (cl-agent.llm.providers::extract-thinking-blocks blocks)))
    (is (= 1 (length kept)))
    (is (string= "thinking" (gethash "type" (first kept))))
    (is (string= "先想想" (gethash "thinking" (first kept))))
    ;; 关键：signature 不能丢——丢了就无法回传
    (is (string= "sig-abc" (gethash "signature" (first kept))))))

(test thinking-blocks-keep-redacted
  "redacted_thinking（密文思考）同样必须保留回传"
  (let* ((blocks (vector (ht "type" "redacted_thinking" "data" "encrypted-payload")
                         (ht "type" "text" "text" "答案")))
         (kept (cl-agent.llm.providers::extract-thinking-blocks blocks)))
    (is (= 1 (length kept)))
    (is (string= "redacted_thinking" (gethash "type" (first kept))))
    (is (string= "encrypted-payload" (gethash "data" (first kept))))))

(test thinking-blocks-empty-when-absent
  "没有思考块时为 NIL，不影响不产生此类块的 provider"
  (is (null (cl-agent.llm.providers::extract-thinking-blocks
             (vector (ht "type" "text" "text" "答案"))))))

;;; ============================================================
;;; 流式解析：signature_delta 累积
;;; ============================================================

(test stream-thinking-block-rebuilt-with-signature
  "流式：signature_delta 被累积，thinking 块可还原（此前没有该分支，签名直接丢失）"
  (let ((response (run-anthropic-events
                   (list "{\"type\":\"message_start\",\"message\":{\"id\":\"m\",\"model\":\"m\",\"usage\":{\"input_tokens\":1}}}"
                         "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"thinking\"}}"
                         "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"先想\"}}"
                         "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"想\"}}"
                         "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"signature_delta\",\"signature\":\"sig-\"}}"
                         "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"signature_delta\",\"signature\":\"xyz\"}}"
                         "{\"type\":\"content_block_stop\",\"index\":0}"
                         "{\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}"
                         "{\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"text_delta\",\"text\":\"答案\"}}"
                         "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}"))))
    (let ((blocks (cl-agent.core:llm-response-reasoning-blocks response)))
      (is (= 1 (length blocks)))
      (is (string= "thinking" (gethash "type" (first blocks))))
      (is (string= "先想想" (gethash "thinking" (first blocks))))
      ;; 分片签名被拼接完整
      (is (string= "sig-xyz" (gethash "signature" (first blocks)))))
    ;; 思考仍不污染答案流
    (is (string= "答案" (cl-agent.core:llm-response-content response)))))

(test stream-thinking-block-omits-empty-signature
  "签名缺失时不写 signature 键——宁可让 API 明确报错，也不塞空签名"
  (let ((response (run-anthropic-events
                   (list "{\"type\":\"message_start\",\"message\":{\"id\":\"m\",\"model\":\"m\"}}"
                         "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"thinking\"}}"
                         "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"想\"}}"
                         "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"}}"))))
    (let ((block (first (cl-agent.core:llm-response-reasoning-blocks response))))
      (is (not (nth-value 1 (gethash "signature" block)))))))

;;; ============================================================
;;; 跨层通路：llm-response → assistant-message → 中立 plist
;;; ============================================================

(test reasoning-blocks-reach-assistant-metadata
  "llm-response->chat-response 把推理块放进 assistant-message 的 metadata"
  (let* ((blocks (list (ht "type" "thinking" "thinking" "想" "signature" "s1")))
         (response (cl-agent.chat:llm-response->chat-response
                    (cl-agent.core:make-llm-response
                     :content "答案"
                     :reasoning "想"
                     :reasoning-blocks blocks)))
         (msg (cl-agent.chat:chat-response-message response)))
    (is (eq blocks (getf (cl-agent.chat:message-metadata msg) :reasoning-blocks)))
    ;; 展示用文本仍在
    (is (string= "想" (getf (cl-agent.chat:message-metadata msg) :reasoning)))))

(test message->neutral-carries-reasoning-blocks
  "message->neutral 把推理块带过中立层——此前这里丢失，导致回传无从谈起"
  (let* ((blocks (list (ht "type" "thinking" "thinking" "想" "signature" "s1")))
         (msg (cl-agent.chat:assistant-message
               "答案"
               :tool-calls (list (cl-agent.chat:make-tool-call
                                  :id "c1" :name "t" :arguments (ht)))
               :metadata (list :reasoning-blocks blocks)))
         (neutral (first (cl-agent.chat:message->neutral msg))))
    (is (eq blocks (getf neutral :reasoning-blocks)))
    (is (string= "答案" (getf neutral :content)))
    (is (= 1 (length (getf neutral :tool-calls))))))

(test neutral->message-roundtrips-reasoning-blocks
  "CLOS ↔ 中立往返不丢推理块"
  (let* ((blocks (list (ht "type" "thinking" "thinking" "想" "signature" "s1")))
         (msg (cl-agent.chat:assistant-message
               "答案" :metadata (list :reasoning-blocks blocks)))
         (back (cl-agent.chat:neutral->message
                (first (cl-agent.chat:message->neutral msg)))))
    (is (eq blocks (getf (cl-agent.chat:message-metadata back) :reasoning-blocks)))))

;;; ============================================================
;;; 最后一层：写进 Anthropic 请求体
;;; ============================================================

;;; 注意：必须测 parse-messages-for-anthropic —— 那是 provider 真正走的
;;; 转换。此前 llm/schema/anthropic.lisp 里还有一份平行的死实现
;;; （convert-message-to-anthropic），导出却无人调用；对着它写测试会
;;; 绿着通过而线上依然是坏的。那个文件已删除，此处记下教训：
;;; 断言请求体时，认准 build-anthropic-request-body 实际调用的那一份。

(defun assistant-blocks-of (neutral-messages)
  "取 parse-messages-for-anthropic 产出的 assistant 消息 content 块类型列表，
以及块本身"
  (let* ((parsed (cl-agent.llm.providers::parse-messages-for-anthropic
                  neutral-messages))
         (msg (find "assistant" (getf parsed :messages)
                    :key (lambda (m) (gethash "role" m)) :test #'equal))
         (blocks (coerce (gethash "content" msg) 'list)))
    (values (mapcar (lambda (b) (gethash "type" b)) blocks) blocks)))

(test anthropic-request-replays-thinking-blocks-first
  "assistant 轮把 thinking 块排在最前原样回传（Anthropic 的硬性要求）"
  (let ((thinking (ht "type" "thinking" "thinking" "想" "signature" "s1")))
    (multiple-value-bind (types blocks)
        (assistant-blocks-of
         (list (list :role :assistant
                     :content "我查一下"
                     :tool-calls (list (list :id "c1" :name "weather"
                                             :arguments (ht "city" "东京")))
                     :reasoning-blocks (list thinking))))
      ;; 顺序：thinking → text → tool_use
      (is (equal '("thinking" "text" "tool_use") types))
      ;; 原样回传：同一个对象，未被重建或改写，签名完好
      (is (eq thinking (first blocks)))
      (is (string= "s1" (gethash "signature" (first blocks)))))))

(test anthropic-request-without-thinking-blocks-unchanged
  "没有推理块时请求体与既往一致（不产生此类块的 provider 不受影响）"
  (is (equal '("text" "tool_use")
             (assistant-blocks-of
              (list (list :role :assistant
                          :content "我查一下"
                          :tool-calls (list (list :id "c1" :name "weather"
                                                  :arguments (ht "city" "东京")))))))))

(test anthropic-request-thinking-without-text
  "assistant 无正文（只有思考 + 工具调用）时不产生空 text 块"
  (is (equal '("thinking" "tool_use")
             (assistant-blocks-of
              (list (list :role :assistant
                          :content ""
                          :tool-calls (list (list :id "c1" :name "weather"
                                                  :arguments (ht "city" "东京")))
                          :reasoning-blocks
                          (list (ht "type" "thinking" "thinking" "想"
                                    "signature" "s1"))))))))

;;; ============================================================
;;; SPI「存在才发送」契约
;;; ============================================================

(test temperature-not-sent-unless-specified
  "未指定 temperature 时不得出现在请求体里。

此前 llm-chat 的 lambda list 用 (temperature 0.7) 做默认值，
即使调用方不设温度也会发出 temperature=0.7：既让 chat-options 的
「未设置」语义失效，也会在开启扩展思考时被 Anthropic 拒绝
（扩展思考只接受 temperature=1）。"
  (let* ((provider (cl-agent.llm.providers:make-anthropic-provider
                    :api-key "test-key" :model "claude-sonnet-4-20250514"))
         (body (cl-agent.llm.providers::build-anthropic-request-body
                provider
                (list (list :role :user :content "hi"))
                :max-tokens 1024)))
    (is (not (nth-value 1 (gethash "temperature" body))))
    ;; max_tokens 是 Anthropic 强制字段，必须在
    (is (= 1024 (gethash "max_tokens" body)))))

(test temperature-sent-when-specified
  "显式指定 temperature 时正常下发"
  (let* ((provider (cl-agent.llm.providers:make-anthropic-provider
                    :api-key "test-key" :model "claude-sonnet-4-20250514"))
         (body (cl-agent.llm.providers::build-anthropic-request-body
                provider
                (list (list :role :user :content "hi"))
                :max-tokens 1024
                :temperature 0.3)))
    (is (= 0.3 (gethash "temperature" body)))))

(test thinking-param-reachable-via-extra-params
  "thinking 模式经 extra-params 逃生通道下发（MiniMax M 系列等推理模型用）"
  (let* ((provider (cl-agent.llm.providers:make-anthropic-provider
                    :api-key "test-key" :model "claude-sonnet-4-20250514"))
         (body (cl-agent.llm.providers::build-anthropic-request-body
                provider
                (list (list :role :user :content "hi"))
                :max-tokens 1024
                :extra-params (list :thinking (ht "type" "disabled")))))
    (is (string= "disabled" (gethash "type" (gethash "thinking" body))))))
