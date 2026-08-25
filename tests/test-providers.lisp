;;;; test-providers.lisp
;;;; CL-Agent - Provider 层完善测试（参照 clj-agent provider 模块）
;;;;
;;;; 覆盖：
;;;;   - 新 provider（deepseek/gemini/mistral）工厂与默认配置
;;;;   - Registry 注册/别名/注销
;;;;   - OpenAI 兼容请求体：可选参数"存在才发送"
;;;;   - Anthropic 请求体：top_p/top_k/stop_sequences/extra-params
;;;;   - DeepSeek 前缀续写（mark-prefix）
;;;;   - ChatModel 适配层选项下发

(in-package :cl-agent/tests)

(def-suite providers-suite :in cl-agent-suite
  :description "Provider 层：新提供商 / registry / 请求参数")

(in-suite providers-suite)

;;; ============================================================
;;; 新 Provider 工厂
;;; ============================================================

(test deepseek-provider-factory
  "DeepSeek provider 默认配置"
  (let ((provider (cl-agent/llm/providers:make-deepseek-provider
                   :api-key "test-key")))
    (is (typep provider 'cl-agent/llm/providers:deepseek-provider))
    (is (typep provider 'cl-agent/llm/providers:openai-compat-provider))
    (is (string= "https://api.deepseek.com"
                 (cl-agent/llm:base-provider-api-url provider)))
    (is (string= "deepseek-chat"
                 (cl-agent/llm:base-provider-default-model provider)))
    (is (eq :deepseek (cl-agent/llm:base-provider-name provider)))))

(test gemini-provider-factory
  "Gemini provider 默认配置（Google OpenAI 兼容端点）"
  (let ((provider (cl-agent/llm/providers:make-gemini-provider
                   :api-key "test-key")))
    (is (typep provider 'cl-agent/llm/providers:gemini-provider))
    ;; base-url 必须含 /openai（Google 兼容端点的特殊路径）
    (is (search "/v1beta/openai"
                (cl-agent/llm:base-provider-api-url provider)))
    (is (string= "gemini-2.0-flash"
                 (cl-agent/llm:base-provider-default-model provider)))))

(test mistral-provider-factory
  "Mistral provider 默认配置"
  (let ((provider (cl-agent/llm/providers:make-mistral-provider
                   :api-key "test-key")))
    (is (typep provider 'cl-agent/llm/providers:mistral-provider))
    (is (string= "https://api.mistral.ai/v1"
                 (cl-agent/llm:base-provider-api-url provider)))
    (is (string= "mistral-large-latest"
                 (cl-agent/llm:base-provider-default-model provider)))))

(test minimax-provider-anthropic-compat
  "MiniMax 走 Anthropic 兼容端点（对齐 clj-agent）"
  (let ((provider (cl-agent/llm/providers:make-minimax-provider
                   :api-key "test-key")))
    ;; 继承 anthropic-provider，复用其请求/响应实现
    (is (typep provider 'cl-agent/llm/providers:anthropic-provider))
    (is (string= "https://api.minimaxi.com"
                 (cl-agent/llm:base-provider-api-url provider)))
    (is (string= "/anthropic/v1/messages"
                 (cl-agent/llm:base-provider-chat-endpoint provider)))
    (is (string= "MiniMax-M2.7"
                 (cl-agent/llm:base-provider-default-model provider)))
    (is (eq :minimax (cl-agent/llm:base-provider-name provider)))
    ;; Bearer 鉴权，无 anthropic-version 头
    (let ((headers (cl-agent/llm/providers:build-anthropic-headers provider)))
      (is (string= "Bearer test-key"
                   (cdr (assoc "Authorization" headers :test #'string=))))
      (is (null (assoc "anthropic-version" headers :test #'string=)))
      (is (null (assoc "x-api-key" headers :test #'string=))))))

(test anthropic-headers-default
  "标准 Anthropic 仍用 x-api-key + anthropic-version"
  (let* ((provider (cl-agent/llm/providers:make-anthropic-provider
                    :api-key "sk-ant-test"))
         (headers (cl-agent/llm/providers:build-anthropic-headers provider)))
    (is (string= "sk-ant-test"
                 (cdr (assoc "x-api-key" headers :test #'string=))))
    (is (string= "2023-06-01"
                 (cdr (assoc "anthropic-version" headers :test #'string=))))
    (is (null (assoc "Authorization" headers :test #'string=)))))

(test new-providers-require-api-key
  "无 api-key 且环境变量缺失时报 missing-api-key-error"
  ;; 环境变量存在时跳过（本地开发机可能配了 key）
  (if (or (uiop:getenv "MISTRAL_API_KEY"))
      (skip "MISTRAL_API_KEY 已设置，跳过缺失校验")
      (signals cl-agent/core:missing-api-key-error
        (cl-agent/llm/providers:make-mistral-provider))))

(test xai-provider-factory
  "xAI Grok provider 默认配置"
  (let ((provider (cl-agent/llm/providers:make-xai-provider :api-key "k")))
    (is (typep provider 'cl-agent/llm/providers:openai-compat-provider))
    (is (string= "https://api.x.ai/v1"
                 (cl-agent/llm:base-provider-api-url provider)))
    (is (eq :xai (cl-agent/llm:base-provider-name provider)))))

(test moonshot-provider-factory
  "Moonshot（Kimi）provider 默认配置"
  (let ((provider (cl-agent/llm/providers:make-moonshot-provider :api-key "k")))
    (is (string= "https://api.moonshot.ai/v1"
                 (cl-agent/llm:base-provider-api-url provider)))
    (is (eq :moonshot (cl-agent/llm:base-provider-name provider)))
    ;; 国内站点经 :api-url 切换
    (is (string= "https://api.moonshot.cn/v1"
                 (cl-agent/llm:base-provider-api-url
                  (cl-agent/llm/providers:make-moonshot-provider
                   :api-key "k" :api-url "https://api.moonshot.cn/v1"))))))

(test siliconflow-provider-factory
  "SiliconFlow provider 默认配置"
  (let ((provider (cl-agent/llm/providers:make-siliconflow-provider :api-key "k")))
    (is (string= "https://api.siliconflow.cn/v1"
                 (cl-agent/llm:base-provider-api-url provider)))
    (is (eq :siliconflow (cl-agent/llm:base-provider-name provider)))
    (is (string= "deepseek-ai/DeepSeek-V3"
                 (cl-agent/llm:base-provider-default-model provider)))))

(test openrouter-provider-factory
  "OpenRouter provider 默认配置"
  (let ((provider (cl-agent/llm/providers:make-openrouter-provider :api-key "k")))
    (is (string= "https://openrouter.ai/api/v1"
                 (cl-agent/llm:base-provider-api-url provider)))
    (is (eq :openrouter (cl-agent/llm:base-provider-name provider)))))

;;; ============================================================
;;; 附加请求头（extra-headers）
;;; ============================================================

(test provider-request-headers-merge-extra
  "extra-headers 与认证头合并后下发"
  (let* ((provider (cl-agent/llm/providers:make-xai-provider
                    :api-key "k" :headers '(("X-Tenant" . "team-a"))))
         (headers (cl-agent/llm/providers:provider-request-headers provider)))
    (is (string= "Bearer k"
                 (cdr (assoc "Authorization" headers :test #'string=))))
    (is (string= "team-a"
                 (cdr (assoc "X-Tenant" headers :test #'string=))))))

(test provider-request-headers-override-auth
  "同名头由 extra-headers 覆盖，且只出现一次（HTTP 头名大小写不敏感）"
  (let* ((provider (cl-agent/llm/providers:make-xai-provider
                    :api-key "k"
                    :headers '(("authorization" . "Bearer override"))))
         (headers (cl-agent/llm/providers:provider-request-headers provider)))
    (is (= 1 (count-if (lambda (pair)
                         (string-equal "Authorization" (car pair)))
                       headers)))
    (is (string= "Bearer override"
                 (cdr (assoc "Authorization" headers :test #'string-equal))))))

(test provider-request-headers-default-empty
  "未传 :headers 时行为与从前一致（只有认证头）"
  (let ((headers (cl-agent/llm/providers:provider-request-headers
                  (cl-agent/llm/providers:make-xai-provider :api-key "k"))))
    (is (= 2 (length headers)))))

(test openrouter-attribution-headers
  "OpenRouter 归因头写入 extra-headers"
  (let ((headers (cl-agent/llm/providers:provider-request-headers
                  (cl-agent/llm/providers:make-openrouter-provider-with-attribution
                   :api-key "k"
                   :referer "https://app.example.com"
                   :title "MyApp"))))
    (is (string= "https://app.example.com"
                 (cdr (assoc "HTTP-Referer" headers :test #'string=))))
    (is (string= "MyApp" (cdr (assoc "X-Title" headers :test #'string=))))
    (is (string= "Bearer k"
                 (cdr (assoc "Authorization" headers :test #'string=))))))

;;; ============================================================
;;; 厂商错误体归一
;;; ============================================================

(test error-message-extracted-openai-shape
  "OpenAI 形状：error.message (+ type)"
  (is (string= "Invalid model (invalid_request_error)"
               (cl-agent/llm:extract-api-error-message
                "{\"error\":{\"message\":\"Invalid model\",\"type\":\"invalid_request_error\"}}"))))

(test error-message-extracted-anthropic-shape
  "Anthropic 形状：顶层 type=error + error.message"
  (is (string= "max_tokens is required (invalid_request_error)"
               (cl-agent/llm:extract-api-error-message
                "{\"type\":\"error\",\"error\":{\"type\":\"invalid_request_error\",\"message\":\"max_tokens is required\"}}"))))

(test error-message-extracted-flat-shape
  "DashScope 形状：顶层 code + message"
  (is (string= "Range of input length should be [1, 6000] (InvalidParameter)"
               (cl-agent/llm:extract-api-error-message
                "{\"code\":\"InvalidParameter\",\"message\":\"Range of input length should be [1, 6000]\"}"))))

(test error-message-extracted-string-error
  "Ollama 形状：error 直接是字符串"
  (is (string= "model 'llama9' not found"
               (cl-agent/llm:extract-api-error-message
                "{\"error\":\"model 'llama9' not found\"}"))))

(test error-message-non-json-passthrough
  "非 JSON（网关的 HTML/纯文本）原样带出，超长截断"
  (is (string= "502 Bad Gateway"
               (cl-agent/llm:extract-api-error-message "  502 Bad Gateway  ")))
  (let ((long (cl-agent/llm:extract-api-error-message
               (make-string 500 :initial-element #\x))))
    (is (= 303 (length long)))
    (is (string= "..." (subseq long 300)))))

(test error-message-empty-body
  "空响应体提取不出信息，返回 NIL（调用方回落到状态码）"
  (is (null (cl-agent/llm:extract-api-error-message nil)))
  (is (null (cl-agent/llm:extract-api-error-message "")))
  ;; 合法 JSON 但没有任何可读字段
  (is (null (cl-agent/llm:extract-api-error-message "{\"ok\":true}"))))

(test error-message-decodes-octets
  "字节形态的响应体先解码再提取（dexador 的 force-binary 路径）"
  (let ((octets (flexi-streams:string-to-octets
                 "{\"error\":{\"message\":\"配额不足\"}}"
                 :external-format :utf-8)))
    (is (string= "配额不足"
                 (cl-agent/llm:extract-api-error-message octets)))))

;;; ============================================================
;;; Registry
;;; ============================================================

(test registry-new-providers-registered
  "新 provider 已注册"
  (dolist (name '(:deepseek :gemini :mistral :xai :moonshot :siliconflow
                  :openrouter))
    (is-true (cl-agent/llm:provider-registered-p name)
             "~S 未注册" name)))

(test registry-table-matches-registry
  "工厂表是单一事实来源：表里每一项都注册了，且工厂函数存在"
  (dolist (entry cl-agent/llm:+builtin-provider-factories+)
    (is-true (cl-agent/llm:provider-registered-p (car entry))
             "~S 在表里但没注册" (car entry))
    (is-true (fboundp (cdr entry))
             "~S 的工厂函数 ~S 不存在" (car entry) (cdr entry))))

(test registry-aliases
  "别名解析到规范名"
  (is (eq :gemini (cl-agent/llm:resolve-provider-name "google")))
  (is (eq :dashscope (cl-agent/llm:resolve-provider-name "qwen")))
  (is (eq :dashscope (cl-agent/llm:resolve-provider-name "bailian")))
  (is (eq :anthropic (cl-agent/llm:resolve-provider-name :claude)))
  (is (eq :xai (cl-agent/llm:resolve-provider-name "grok")))
  (is (eq :moonshot (cl-agent/llm:resolve-provider-name "kimi")))
  (is (eq :siliconflow (cl-agent/llm:resolve-provider-name "silicon")))
  ;; 非别名原样透传
  (is (eq :deepseek (cl-agent/llm:resolve-provider-name :deepseek))))

(test registry-unregister
  "注册后可注销（对标 clj registry/unregister-provider!）"
  (cl-agent/llm:register-provider :test-temp-provider
                                  (lambda (&rest args)
                                    (declare (ignore args))
                                    :fake))
  (is-true (cl-agent/llm:provider-registered-p :test-temp-provider))
  (is-true (cl-agent/llm:unregister-provider :test-temp-provider))
  (is-false (cl-agent/llm:provider-registered-p :test-temp-provider))
  ;; 重复注销返回 NIL
  (is-false (cl-agent/llm:unregister-provider :test-temp-provider)))

(test registry-create-via-factory
  "create-provider 经工厂创建新 provider"
  (let ((provider (cl-agent/llm:create-provider :deepseek :api-key "k")))
    (is (typep provider 'cl-agent/llm/providers:deepseek-provider))))

;;; ============================================================
;;; OpenAI 兼容请求体：存在才发送
;;; ============================================================

(defun build-compat-request (&rest args)
  "用 mistral provider 构建请求体（任意 openai-compat provider 均可）"
  (apply #'cl-agent/llm/providers::build-openai-compatible-request
         (cl-agent/llm/providers:make-mistral-provider :api-key "k")
         (list (list :role :user :content "hi"))
         args))

(test compat-request-optional-params-sent
  "显式传入的可选参数写入请求体"
  (let ((body (build-compat-request :top-p 0.9
                                    :stop '("END" "STOP")
                                    :frequency-penalty 0.5
                                    :presence-penalty 0.3
                                    :tool-choice :required)))
    (is (= 0.9 (gethash "top_p" body)))
    (is (equalp #("END" "STOP") (gethash "stop" body)))
    (is (= 0.5 (gethash "frequency_penalty" body)))
    (is (= 0.3 (gethash "presence_penalty" body)))
    (is (string= "required" (gethash "tool_choice" body)))))

(test compat-request-params-absent-when-nil
  "未传入的可选参数不出现在请求体（不发 null）"
  (let ((body (build-compat-request)))
    (is-false (nth-value 1 (gethash "top_p" body)))
    (is-false (nth-value 1 (gethash "stop" body)))
    (is-false (nth-value 1 (gethash "frequency_penalty" body)))
    (is-false (nth-value 1 (gethash "presence_penalty" body)))
    (is-false (nth-value 1 (gethash "tool_choice" body)))
    (is-false (nth-value 1 (gethash "stream" body)))))

(test compat-request-tool-choice-wire
  "tool-choice 中立关键字翻译为 wire 字符串，其余透传"
  (is (string= "auto" (cl-agent/llm/providers::tool-choice-to-wire :auto)))
  (is (string= "none" (cl-agent/llm/providers::tool-choice-to-wire :none)))
  (is (string= "custom" (cl-agent/llm/providers::tool-choice-to-wire "custom"))))

(test compat-request-extra-params
  "extra-params 逃生通道：直接并入顶层，关键字转下划线风格"
  (let ((body (build-compat-request :extra-params '(:seed 42
                                                    :reasoning-effort "high"
                                                    "verbatim_key" "v"))))
    (is (= 42 (gethash "seed" body)))
    (is (string= "high" (gethash "reasoning_effort" body)))
    (is (string= "v" (gethash "verbatim_key" body)))))

(test compat-request-extra-params-override
  "extra-params 可覆盖标准字段（最后并入）"
  (let ((body (build-compat-request :extra-params '(:model "override-model"))))
    (is (string= "override-model" (gethash "model" body)))))

(test compat-request-prefix-message
  "assistant 消息的 :prefix 标记写入 wire（DeepSeek 前缀续写）"
  (let* ((messages (cl-agent/llm/providers::convert-messages-for-openai
                    (list (list :role :user :content "写诗")
                          (list :role :assistant :content "春天的风" :prefix t))))
         (last-msg (elt messages 1)))
    (is (eq t (gethash "prefix" last-msg)))
    ;; 未标记的消息没有 prefix 字段
    (is-false (nth-value 1 (gethash "prefix" (elt messages 0))))))

;;; ============================================================
;;; Anthropic 请求体
;;; ============================================================

(test anthropic-request-sampling-params
  "Anthropic：top_p/top_k/stop_sequences/extra-params 存在才发送"
  (let* ((provider (cl-agent/llm/providers:make-anthropic-provider
                    :api-key "test-key"))
         (body (cl-agent/llm/providers::build-anthropic-request-body
                provider
                (list (list :role :user :content "hi"))
                :max-tokens 100
                :top-p 0.8
                :top-k 40
                :stop '("END")
                :extra-params '(:metadata "m")))
         (bare (cl-agent/llm/providers::build-anthropic-request-body
                provider
                (list (list :role :user :content "hi"))
                :max-tokens 100)))
    (is (= 0.8 (gethash "top_p" body)))
    (is (= 40 (gethash "top_k" body)))
    (is (equalp #("END") (gethash "stop_sequences" body)))
    (is (string= "m" (gethash "metadata" body)))
    ;; 不传不出现
    (is-false (nth-value 1 (gethash "top_p" bare)))
    (is-false (nth-value 1 (gethash "top_k" bare)))
    (is-false (nth-value 1 (gethash "stop_sequences" bare)))))

;;; ============================================================
;;; DeepSeek 前缀续写
;;; ============================================================

(test deepseek-mark-prefix
  "mark-prefix 标记最后一条 assistant 消息"
  (let* ((messages (list (list :role :user :content "写一句诗")
                         (list :role :assistant :content "春天的风")))
         (marked (cl-agent/llm/providers:mark-prefix messages)))
    (is (eq t (getf (second marked) :prefix)))
    ;; 原消息列表不被修改
    (is (null (getf (second messages) :prefix)))))

(test deepseek-mark-prefix-requires-assistant-tail
  "最后一条非 assistant 时报错"
  (signals error
    (cl-agent/llm/providers:mark-prefix
     (list (list :role :user :content "hi")))))

;;; ============================================================
;;; ChatModel 适配层选项下发
;;; ============================================================

(test chat-model-passes-sampling-options
  "chat-options 的采样选项完整下发到 llm-chat SPI"
  (let* ((provider (make-seq-provider (text-response "ok")))
         (model (cl-agent/core:make-provider-chat-model provider)))
    (cl-agent/core:chat-model-call
     model
     (cl-agent/core:make-prompt
      "hi"
      :options (cl-agent/core:make-chat-options
                :top-p 0.9
                :top-k 50
                :stop-sequences '("END")
                :frequency-penalty 0.1
                :presence-penalty 0.2
                :extra-params '(:seed 7))))
    (let ((request (first (seq-provider-requests provider))))
      (is (= 0.9 (getf request :top-p)))
      (is (= 50 (getf request :top-k)))
      (is (equal '("END") (getf request :stop)))
      (is (= 0.1 (getf request :frequency-penalty)))
      (is (= 0.2 (getf request :presence-penalty)))
      (is (equal '(:seed 7) (getf request :extra-params))))))

(test chat-model-omits-unset-options
  "未设置的选项不下发（SPI 收到 NIL）"
  (let* ((provider (make-seq-provider (text-response "ok")))
         (model (cl-agent/core:make-provider-chat-model provider)))
    (cl-agent/core:chat-model-call model "hi")
    (let ((request (first (seq-provider-requests provider))))
      (is (null (getf request :top-p)))
      (is (null (getf request :stop)))
      (is (null (getf request :extra-params))))))

(test chat-options-extra-params-merge
  "extra-params 参与选项合并（运行时覆盖默认）"
  (let ((merged (cl-agent/core:merge-chat-options
                 (cl-agent/core:make-chat-options :extra-params '(:seed 1))
                 (cl-agent/core:make-chat-options :extra-params '(:seed 9)
                                                  :temperature 0.5))))
    (is (equal '(:seed 1) (cl-agent/core:chat-options-extra-params merged)))
    (is (= 0.5 (cl-agent/core:chat-options-temperature merged)))))

;;; ============================================================
;;; alist-get（响应解析的取值原语）
;;; ============================================================
;;; core 里曾有一个同名的假 alist 访问器（函数体是 getf，只对 plist
;;; 有效），因加载顺序在前而被此处的真实现静默覆盖，只留下一条
;;; redefining 警告。core 那个已删除，这里锁住真实现的语义。

(test alist-get-semantics
  "alist-get：字符串/符号键、hash-table、缺失键"
  (let ((al '(("content" . "hi") ("model" . "m1"))))
    ;; 字符串键
    (is (equal "hi" (cl-agent/llm::alist-get al "content")))
    ;; 符号键降级为小写字符串
    (is (equal "hi" (cl-agent/llm::alist-get al 'content)))
    ;; 大小写不敏感（string-equal）
    (is (equal "hi" (cl-agent/llm::alist-get al "CONTENT")))
    ;; 缺失键返回 nil
    (is (null (cl-agent/llm::alist-get al "nope"))))
  ;; hash-table（json-parse 的返回格式）
  (let ((ht (make-hash-table :test #'equal)))
    (setf (gethash "content" ht) "hi")
    (is (equal "hi" (cl-agent/llm::alist-get ht "content")))
    (is (null (cl-agent/llm::alist-get ht "nope"))))
  ;; 奇数长度的 alist 不应像旧 core 实现那样抛 malformed property list
  (is (equal 1 (cl-agent/llm::alist-get '(("a" . 1)) "a"))))

;;; ============================================================
;;; make-provider 覆盖全部注册的 provider
;;; ============================================================

(test make-provider-covers-every-registered-provider
  "make-provider 必须支持注册表里的每一个 provider。

此前它是一张手写 ECASE，只列了 6 个——deepseek / gemini / mistral 全部
ECASE 落空报错，尽管注册表里一直有它们。现改为委托 create-provider，
注册表是单一事实来源，新增 provider 无需再回来改这张表。"
  (dolist (name (cl-agent/llm:list-providers))
    (let ((made (handler-case
                    (cl-agent/llm:make-provider name :api-key "test-key")
                  (error (e) e))))
      (is (typep made 'cl-agent/llm:base-provider)
          "make-provider ~S 失败：~A" name made))))

(test estimate-cost-covers-every-registered-provider
  "estimate-cost 不能对任何注册的 provider 报错。

此前是一张 ecase，只认 anthropic/openai/ollama/zhipu——其余
provider 一律 ecase 落空，成本估算把整个调用打断。"
  (dolist (name (cl-agent/llm:list-providers))
    (let* ((provider (cl-agent/llm:make-provider name :api-key "test-key"))
           (cost (handler-case (cl-agent/llm:estimate-cost provider 1000 500)
                   (error (e) e))))
      (is (numberp cost) "estimate-cost ~S 失败：~A" name cost)
      (is (>= cost 0) "~S 估算出负成本" name))))

(test estimate-cost-unit-is-per-million-tokens
  "定价表单位为「美元 / 1M token」，与算式一致"
  (let ((provider (cl-agent/llm:make-provider :anthropic :api-key "k")))
    ;; Anthropic 档位 $3/1M 输入 + $15/1M 输出
    ;; 1M 输入 + 1M 输出 = $18
    (is (< (abs (- 18.0 (cl-agent/llm:estimate-cost provider 1000000 1000000)))
           0.01))))

(test make-provider-accepts-aliases
  "别名经注册表解析（此前手写 ECASE 完全不认别名）"
  (dolist (alias '("claude" "gpt" "glm" "qwen"))
    (is (typep (cl-agent/llm:make-provider alias :api-key "test-key")
               'cl-agent/llm:base-provider)
        "别名 ~S 无法创建" alias)))

(test every-provider-implements-provider-api-key
  "每个 provider 都必须实现 cl-agent/core:provider-api-key 协议。

这是取密钥的唯一入口。此前 Anthropic 系（含 minimax）没实现它，于是当年
的 client 层只好维护一张手写的「provider → 环境变量名」ECASE 表，而那张表
漏了 5 个 provider。client 类已退役，协议留下。"
  (dolist (name (cl-agent/llm:list-providers))
    (let ((p (cl-agent/llm:make-provider name :api-key "test-key")))
      (is (stringp (cl-agent/core:provider-api-key p))
          "~S 未实现 provider-api-key" name))))
