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
         (kept (cl-agent/llm/providers::extract-thinking-blocks blocks)))
    (is (= 1 (length kept)))
    (is (string= "thinking" (gethash "type" (first kept))))
    (is (string= "先想想" (gethash "thinking" (first kept))))
    ;; 关键：signature 不能丢——丢了就无法回传
    (is (string= "sig-abc" (gethash "signature" (first kept))))))

(test thinking-blocks-keep-redacted
  "redacted_thinking（密文思考）同样必须保留回传"
  (let* ((blocks (vector (ht "type" "redacted_thinking" "data" "encrypted-payload")
                         (ht "type" "text" "text" "答案")))
         (kept (cl-agent/llm/providers::extract-thinking-blocks blocks)))
    (is (= 1 (length kept)))
    (is (string= "redacted_thinking" (gethash "type" (first kept))))
    (is (string= "encrypted-payload" (gethash "data" (first kept))))))

(test thinking-blocks-empty-when-absent
  "没有思考块时为 NIL，不影响不产生此类块的 provider"
  (is (null (cl-agent/llm/providers::extract-thinking-blocks
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
    (let ((blocks (cl-agent/core:llm-response-reasoning-blocks response)))
      (is (= 1 (length blocks)))
      (is (string= "thinking" (gethash "type" (first blocks))))
      (is (string= "先想想" (gethash "thinking" (first blocks))))
      ;; 分片签名被拼接完整
      (is (string= "sig-xyz" (gethash "signature" (first blocks)))))
    ;; 思考仍不污染答案流
    (is (string= "答案" (cl-agent/core:llm-response-content response)))))

(test stream-thinking-block-omits-empty-signature
  "签名缺失时不写 signature 键——宁可让 API 明确报错，也不塞空签名"
  (let ((response (run-anthropic-events
                   (list "{\"type\":\"message_start\",\"message\":{\"id\":\"m\",\"model\":\"m\"}}"
                         "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"thinking\"}}"
                         "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"想\"}}"
                         "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"}}"))))
    (let ((block (first (cl-agent/core:llm-response-reasoning-blocks response))))
      (is (not (nth-value 1 (gethash "signature" block)))))))

;;; ============================================================
;;; 跨层通路：llm-response → assistant-message → 中立 plist
;;; ============================================================

(test reasoning-blocks-reach-assistant-metadata
  "llm-response->chat-response 把推理块放进 assistant-message 的 metadata"
  (let* ((blocks (list (ht "type" "thinking" "thinking" "想" "signature" "s1")))
         (response (cl-agent/core:llm-response->chat-response
                    (cl-agent/core:make-llm-response
                     :content "答案"
                     :reasoning "想"
                     :reasoning-blocks blocks)))
         (msg (cl-agent/core:chat-response-message response)))
    (is (eq blocks (getf (cl-agent/core:message-metadata msg) :reasoning-blocks)))
    ;; 展示用文本仍在
    (is (string= "想" (getf (cl-agent/core:message-metadata msg) :reasoning)))))

(test message->neutral-carries-reasoning-blocks
  "message->neutral 把推理块带过中立层——此前这里丢失，导致回传无从谈起"
  (let* ((blocks (list (ht "type" "thinking" "thinking" "想" "signature" "s1")))
         (msg (cl-agent/core:assistant-message
               "答案"
               :tool-calls (list (cl-agent/core:make-tool-call
                                  :id "c1" :name "t" :arguments (ht)))
               :metadata (list :reasoning-blocks blocks)))
         (neutral (first (cl-agent/core:message->neutral msg))))
    (is (eq blocks (getf neutral :reasoning-blocks)))
    (is (string= "答案" (getf neutral :content)))
    (is (= 1 (length (getf neutral :tool-calls))))))

(test neutral->message-roundtrips-reasoning-blocks
  "CLOS ↔ 中立往返不丢推理块"
  (let* ((blocks (list (ht "type" "thinking" "thinking" "想" "signature" "s1")))
         (msg (cl-agent/core:assistant-message
               "答案" :metadata (list :reasoning-blocks blocks)))
         (back (cl-agent/core:neutral->message
                (first (cl-agent/core:message->neutral msg)))))
    (is (eq blocks (getf (cl-agent/core:message-metadata back) :reasoning-blocks)))))

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
  (let* ((parsed (cl-agent/llm/providers::parse-messages-for-anthropic
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
即使调用方不设温度也会发出 temperature=0.7。按 Anthropic 官方文档，
这会直接坏在两处：temperature/top_p/top_k 在 Claude Opus 4.7 及以后
（含 4.8）不受支持，设非默认值返回 400；且 Claude 4.1 Opus / 4.5 Sonnet
起 temperature 与 top_p 不能同时指定，调用方一传 :top-p 就被连坐。"
  (let* ((provider (cl-agent/llm/providers:make-anthropic-provider
                    :api-key "test-key" :model "claude-sonnet-4-20250514"))
         (body (cl-agent/llm/providers::build-anthropic-request-body
                provider
                (list (list :role :user :content "hi"))
                :max-tokens 1024)))
    (is (not (nth-value 1 (gethash "temperature" body))))
    ;; max_tokens 是 Anthropic 强制字段，必须在
    (is (= 1024 (gethash "max_tokens" body)))))

(test temperature-sent-when-specified
  "显式指定 temperature 时正常下发"
  (let* ((provider (cl-agent/llm/providers:make-anthropic-provider
                    :api-key "test-key" :model "claude-sonnet-4-20250514"))
         (body (cl-agent/llm/providers::build-anthropic-request-body
                provider
                (list (list :role :user :content "hi"))
                :max-tokens 1024
                :temperature 0.3)))
    (is (= 0.3 (gethash "temperature" body)))))

;;; ============================================================
;;; llm/README 承诺的 API 面
;;; ============================================================

(test llm-readme-accessors-are-exported
  "llm/README 的「llm-response 对象」一节列出的访问器必须真的从
cl-agent/llm 导出。

llm-response-reasoning 一直不在再导出列表里（cl-agent/core 导出了、
cl-agent/chat 也导入了，唯独 cl-agent/llm 漏了），照文档写
cl-agent/llm:llm-response-reasoning 会失败。"
  (dolist (name '("LLM-RESPONSE-CONTENT" "LLM-RESPONSE-TOOL-CALLS"
                  "LLM-RESPONSE-USAGE" "LLM-RESPONSE-MODEL"
                  "LLM-RESPONSE-FINISH-REASON" "LLM-RESPONSE-MESSAGE-ID"
                  "LLM-RESPONSE-REASONING" "LLM-RESPONSE-REASONING-BLOCKS"
                  "LLM-RESPONSE-RAW"
                  "RESPONSE-REASONING-CONTENT" "RESPONSE-COMPLETE-P"))
    (multiple-value-bind (sym status) (find-symbol name :cl-agent/llm)
      (is (eq :external status) "~A 未从 cl-agent/llm 导出" name)
      (is (and sym (fboundp sym)) "~A 无定义" name))))

(test llm-readme-finish-reason-table
  "llm/README 的 finish-reason 归一表必须与 normalize-finish-reason 一致。

README 此前写的是 (:stop, :tool-call, :length)——:length 是提供商侧的
原始值，归一后是 :max-tokens，照着写会取不到。"
  (dolist (row '(("stop" :stop) ("end_turn" :stop) ("stop_sequence" :stop)
                 ("tool_calls" :tool-call) ("tool_use" :tool-call)
                 ("length" :max-tokens) ("max_tokens" :max-tokens)
                 ("content_filter" :content-filter)))
    (destructuring-bind (raw expected) row
      (is (eq expected (cl-agent/core:normalize-finish-reason raw))
          "~S 应归一为 ~S" raw expected))))

;;; ============================================================
;;; 门面层重导出（cl-agent/llm ↔ cl-agent/llm/providers）
;;; ============================================================

(test facade-reexports-same-symbols
  "cl-agent/llm 的 make-*-provider / response-complete-p 与
cl-agent/llm/providers 必须是*同一符号*，不能各立一套。

此前是各立一套，后果：用户包 (:use :cl-agent/llm :cl-agent/llm/providers)
会撞 name conflict，而这两个包本是「门面 + 实现」，理应能一起 use。"
  (dolist (name '("MAKE-ANTHROPIC-PROVIDER" "MAKE-OPENAI-PROVIDER"
                  "MAKE-OLLAMA-PROVIDER" "MAKE-ZHIPU-PROVIDER"
                  "MAKE-DASHSCOPE-PROVIDER" "RESPONSE-COMPLETE-P"))
    (is (eq (find-symbol name :cl-agent/llm)
            (find-symbol name :cl-agent/llm/providers))
        "~A 在两个包里不是同一符号" name)))

(test every-export-has-a-definition
  "**每个**导出符号都必须真的有定义——不只是 make-*-provider 那几个。

导出一个不存在的符号，照导出列表使用的人直接撞 UNDEFINED-FUNCTION，
而这在本仓库反复发生过：make-dashscope-provider（门面层手工同步时漏了）、
llm-stream（全库零实现）、di-container-p（di-container 是 defclass，
从来没有过这个自动谓词）。删除一层实现时忘了清导出，也是同一个坑——
client 类退役时就漏了 normalize-messages。

判据：fbound（函数/宏/泛型）、类名、变量、条件类型、deftype，五者居其一。"
  (dolist (pkg-name '(:cl-agent/core :cl-agent/llm :cl-agent/client))
    (let ((pkg (find-package pkg-name))
          (dangling nil))
      (do-external-symbols (sym pkg)
        (unless (or (fboundp sym)
                    (find-class sym nil)
                    (boundp sym)
                    ;; deftype（如 finish-reason）
                    (ignore-errors (progn (typep nil sym) t)))
          (push sym dangling)))
      (is (null dangling)
          "~A 导出了没有定义的符号：~{~A~^ ~}" pkg-name
          (mapcar #'symbol-name (reverse dangling))))))

(test facade-exports-are-all-fbound
  "cl-agent/llm 导出的每个 make-*-provider 都必须真的有定义。

此前 make-dashscope-provider 只有导出、没有委托定义——门面层靠手工
同步，加 provider 时漏了它，调用直接 UNDEFINED-FUNCTION。"
  (dolist (name '("MAKE-ANTHROPIC-PROVIDER" "MAKE-OPENAI-PROVIDER"
                  "MAKE-OLLAMA-PROVIDER" "MAKE-ZHIPU-PROVIDER"
                  "MAKE-DASHSCOPE-PROVIDER"))
    (let ((sym (find-symbol name :cl-agent/llm)))
      (is (and sym (fboundp sym)) "~A 导出了但没有定义" name))))

(test response-complete-p-accepts-legacy-plist
  "统一后的 response-complete-p 是超集实现：llm-response + 旧式 plist +
未知类型返回 NIL。此前 cl-agent/llm 那份只认 llm-response，传 plist 报错。"
  (is (cl-agent/llm:response-complete-p
       (cl-agent/core:make-llm-response :finish-reason :stop)))
  (is (not (cl-agent/llm:response-complete-p
            (cl-agent/core:make-llm-response :finish-reason :max-tokens))))
  ;; 旧式 plist——旧实现在这里会报错
  (is (cl-agent/llm:response-complete-p (list :finish-reason "stop")))
  (is (not (cl-agent/llm:response-complete-p (list :finish-reason "length"))))
  ;; 未知类型不报错，返回 NIL
  (is (not (cl-agent/llm:response-complete-p 42))))

(test chat-model-does-not-default-temperature
  "ChatModel 的默认选项不凭空造出 temperature。

原防线立在 make-client 上（构造器默认 0.7 → 取值链 (or 调用点 client 值)
永远非 NIL → 每次请求都注入 temperature=0.7，Opus 4.7+ 直接 400）。
client 类已移除，防线随之搬到 ChatModel：不配 default-options 时
chat-model-default-options 为 NIL，配了也只带调用方显式给的字段。
下发侧的对应断言见 TEMPERATURE-NOT-SENT-UNLESS-SPECIFIED。"
  (let ((provider (cl-agent/llm:make-anthropic-provider :api-key "test-key")))
    ;; 不配默认选项：整个 default-options 就是 NIL，不可能注入 temperature
    (is (null (cl-agent/core:chat-model-default-options
               (cl-agent/core:make-provider-chat-model provider))))
    ;; 配了别的字段：temperature 仍为 NIL
    (let ((model (cl-agent/core:make-provider-chat-model
                  provider
                  :default-options (cl-agent/core:make-chat-options
                                    :max-tokens 100))))
      (is (null (cl-agent/core:chat-options-temperature
                 (cl-agent/core:chat-model-default-options model)))))
    ;; 显式指定仍然生效
    (let ((model (cl-agent/core:make-provider-chat-model
                  provider
                  :default-options (cl-agent/core:make-chat-options
                                    :temperature 0.3))))
      (is (= 0.3 (cl-agent/core:chat-options-temperature
                  (cl-agent/core:chat-model-default-options model)))))))

;;; ============================================================
;;; thinking 一等参数（对标 ThinkingConfigParam）
;;; ============================================================

(defun thinking-body (spec &key (max-tokens 4096))
  "取 thinking 规格在请求体里的 wire 形态"
  (let ((provider (cl-agent/llm/providers:make-anthropic-provider
                   :api-key "test-key" :model "claude-sonnet-4-20250514")))
    (gethash "thinking"
             (cl-agent/llm/providers::build-anthropic-request-body
              provider (list (list :role :user :content "hi"))
              :max-tokens max-tokens :thinking spec))))

(test thinking-disabled-wire
  ":disabled → {\"type\":\"disabled\"}"
  (let ((w (thinking-body :disabled)))
    (is (string= "disabled" (gethash "type" w)))
    (is (= 1 (hash-table-count w)))))

(test thinking-adaptive-wire
  ":adaptive → {\"type\":\"adaptive\"}，可带 :display"
  (is (string= "adaptive" (gethash "type" (thinking-body :adaptive))))
  (let ((w (thinking-body '(:adaptive :display :omitted))))
    (is (string= "adaptive" (gethash "type" w)))
    ;; display=omitted：思考内容隐去但仍返回 signature，多轮延续不受影响
    (is (string= "omitted" (gethash "display" w)))))

(test thinking-enabled-wire
  "(:enabled :budget-tokens N) → {\"type\":\"enabled\",\"budget_tokens\":N}"
  (let ((w (thinking-body '(:enabled :budget-tokens 2048))))
    (is (string= "enabled" (gethash "type" w)))
    (is (= 2048 (gethash "budget_tokens" w))))
  (is (string= "summarized"
               (gethash "display" (thinking-body
                                   '(:enabled :budget-tokens 2048
                                     :display :summarized))))))

(test thinking-not-sent-when-unset
  "未设置 thinking 时请求体里不得出现该字段（存在才发送）"
  (let* ((provider (cl-agent/llm/providers:make-anthropic-provider
                    :api-key "test-key" :model "claude-sonnet-4-20250514"))
         (body (cl-agent/llm/providers::build-anthropic-request-body
                provider (list (list :role :user :content "hi"))
                :max-tokens 1024)))
    (is (not (nth-value 1 (gethash "thinking" body))))))

(test thinking-budget-constraints-enforced
  "budget-tokens 的官方约束在构建请求时就报错，而不是发出去换一个裸 400：
必须 ≥1024，且必须小于 max-tokens（思考计入 max-tokens）"
  ;; < 1024
  (signals cl-agent/llm/providers:invalid-thinking-config-error
    (thinking-body '(:enabled :budget-tokens 512)))
  ;; >= max-tokens
  (signals cl-agent/llm/providers:invalid-thinking-config-error
    (thinking-body '(:enabled :budget-tokens 4096) :max-tokens 4096))
  ;; 边界：1024 且 < max-tokens 合法
  (is (= 1024 (gethash "budget_tokens"
                       (thinking-body '(:enabled :budget-tokens 1024)))))
  ;; :enabled 缺预算
  (signals cl-agent/llm/providers:invalid-thinking-config-error
    (thinking-body :enabled))
  ;; 非法 display
  (signals cl-agent/llm/providers:invalid-thinking-config-error
    (thinking-body '(:adaptive :display :bogus))))

(test thinking-hash-table-escape-hatch
  "hash-table 原样下发，供 wire 格式先行于本实现时使用"
  (let* ((raw (ht "type" "enabled" "budget_tokens" 8192 "future_field" "x"))
         (w (thinking-body raw :max-tokens 16384)))
    (is (eq raw w))
    (is (string= "x" (gethash "future_field" w)))))

(test thinking-flows-from-chat-options
  "thinking 是 chat-options 的一等槽位，经 options->spi-args 下发到 provider"
  (let ((options (cl-agent/core:make-chat-options
                  :thinking '(:enabled :budget-tokens 2048))))
    (is (equal '(:enabled :budget-tokens 2048)
               (cl-agent/core:chat-options-thinking options)))
    ;; 未设置时读出 NIL（保持「未设置」语义）
    (is (null (cl-agent/core:chat-options-thinking
               (cl-agent/core:make-chat-options :temperature 0.3))))))

(test thinking-merge-semantics
  "thinking 参与 merge-chat-options 的运行时 > 默认覆盖链"
  (let* ((defaults (cl-agent/core:make-chat-options :thinking :disabled))
         (runtime (cl-agent/core:make-chat-options
                   :thinking '(:enabled :budget-tokens 2048)))
         (merged (cl-agent/core:merge-chat-options runtime defaults)))
    (is (equal '(:enabled :budget-tokens 2048)
               (cl-agent/core:chat-options-thinking merged))))
  ;; 运行时未设置 → 沿用默认
  (let ((merged (cl-agent/core:merge-chat-options
                 (cl-agent/core:make-chat-options :temperature 0.3)
                 (cl-agent/core:make-chat-options :thinking :disabled))))
    (is (eq :disabled (cl-agent/core:chat-options-thinking merged)))))
