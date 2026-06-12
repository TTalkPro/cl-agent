;;;; test-llm.lisp
;;;; CL-Agent - LLM 服务层测试

(in-package :cl-agent/tests)

;; LLM API 测试套件
(def-suite llm-suite :in cl-agent-suite
  :description "LLM 服务层测试")

(in-suite llm-suite)

;; ============================================================
;; 提供商测试
;; ============================================================

(test make-provider-anthropic
  "测试创建 Anthropic 提供商"
  (let ((provider (cl-agent.llm:make-provider :anthropic :api-key "test-key")))
    (is (eq (cl-agent.core:provider-name provider) :anthropic))
    (is (stringp (cl-agent.llm:provider-api-url provider)))
    (is (stringp (cl-agent.llm:provider-default-model provider)))))

(test make-provider-openai
  "测试创建 OpenAI 提供商"
  (let ((provider (cl-agent.llm:make-provider :openai :api-key "test-key")))
    (is (eq (cl-agent.core:provider-name provider) :openai))
    (is (stringp (cl-agent.llm:provider-api-url provider)))))

(test make-provider-ollama
  "测试创建 Ollama 提供商"
  (let ((provider (cl-agent.llm:make-provider :ollama)))
    (is (eq (cl-agent.core:provider-name provider) :ollama))
    (is (stringp (cl-agent.llm:provider-api-url provider)))))

;; ============================================================
;; 客户端测试
;; ============================================================

(test make-client-default
  "测试创建默认客户端"
  ;; 注意：这个测试需要 ANTHROPIC_API_KEY 环境变量
  ;; 如果没有设置，会跳过测试
  (handler-case
      (let ((client (cl-agent.llm:make-client)))
        (is (typep client 'cl-agent.llm:client))
        (is (cl-agent.llm:client-provider-name client))
        (is (cl-agent.llm:client-model-name client))
        (is (cl-agent.llm:client-api-key client)))
    (cl-agent.core:missing-api-key-error ()
      ;; 跳过测试
      (pass "Skipping test: API key not set"))))

(test make-client-custom-model
  "测试创建自定义模型客户端"
  (handler-case
      (let ((client (cl-agent.llm:make-client
                     :provider :openai
                     :model "gpt-4o-mini")))
        (is (string= (cl-agent.llm:client-model-name client) "gpt-4o-mini"))
        (is (eq (cl-agent.llm:client-provider-name client) :openai)))
    (cl-agent.core:missing-api-key-error ()
      (pass "Skipping test: API key not set"))))

;; ============================================================
;; Token 计数测试
;; ============================================================

(test count-tokens-simple
  "测试简单的 token 计数"
  (let ((text "Hello, world!"))
    (let ((tokens (cl-agent.llm:count-tokens text)))
      (is (integerp tokens))
      (is (> tokens 0)))))

(test count-tokens-longer
  "测试较长文本的 token 计数"
  (let ((text "This is a longer text with more words to count tokens for."))
    (let ((tokens (cl-agent.llm:count-tokens text)))
      (is (integerp tokens))
      (is (> tokens 0))
      (is (> tokens 10)))))  ; 至少应该有 10 个 tokens

;; ============================================================
;; 成本估算测试
;; ============================================================

(test estimate-cost-anthropic
  "测试 Anthropic 成本估算"
  (let ((provider (cl-agent.llm:make-provider :anthropic :api-key "test-key")))
    (let ((cost (cl-agent.llm:estimate-cost provider 1000 500)))
      (is (numberp cost))
      (is (> cost 0)))))

(test estimate-cost-openai
  "测试 OpenAI 成本估算"
  (let ((provider (cl-agent.llm:make-provider :openai :api-key "test-key")))
    (let ((cost (cl-agent.llm:estimate-cost provider 1000 500)))
      (is (numberp cost))
      (is (> cost 0)))))

(test estimate-cost-ollama
  "测试 Ollama 成本估算（应该为 0）"
  (let ((provider (cl-agent.llm:make-provider :ollama)))
    (let ((cost (cl-agent.llm:estimate-cost provider 1000 500)))
      (is (numberp cost))
      (is (= cost 0)))))

;; ============================================================
;; 消息转换测试
;; ============================================================

(test convert-message-simple
  "测试简单消息转换"
  (let ((provider (cl-agent.llm:make-provider :anthropic :api-key "test-key"))
        (message '(:user . "Hello")))
    (let ((converted (cl-agent.llm:convert-message-to-provider message provider)))
      (is (hash-table-p converted))
      (is (string= "user" (gethash "role" converted)))
      (is (string= "Hello" (gethash "content" converted))))))

;; ============================================================
;; 请求体构建测试
;; ============================================================

(test build-request-body-basic
  "测试基本请求体构建"
  (let ((provider (cl-agent.llm:make-provider :anthropic :api-key "test-key"))
        (messages '((:user . "Hello"))))
    (let ((body (cl-agent.llm:build-chat-request-body
                   provider messages)))
      (is (hash-table-p body))
      (is (stringp (gethash "model" body)))
      (is (vectorp (gethash "messages" body)))
      (multiple-value-bind (val present) (gethash "stream" body)
        (declare (ignore val))
        (is (not (null present)))))))

(test build-request-body-with-system
  "测试带系统提示的请求体构建"
  (let ((provider (cl-agent.llm:make-provider :anthropic :api-key "test-key"))
        (messages '((:user . "Hello"))))
    (let ((body (cl-agent.llm:build-chat-request-body
                   provider messages
                   :system "You are a helpful assistant.")))
      (is (string= (gethash "system" body)
                   "You are a helpful assistant.")))))

(test build-request-body-with-temperature
  "测试带温度的请求体构建"
  (let ((provider (cl-agent.llm:make-provider :anthropic :api-key "test-key"))
        (messages '((:user . "Hello"))))
    (let ((body (cl-agent.llm:build-chat-request-body
                   provider messages
                   :temperature 0.5)))
      (is (= 0.5 (gethash "temperature" body))))))

;; ============================================================
;; 响应解析测试
;; ============================================================

(test parse-response-anthropic
  "测试解析 Anthropic 响应"
  (let ((provider (cl-agent.llm:make-provider :anthropic :api-key "test-key"))
        (response "{\"content\": [{\"text\": \"Hello!\"}], \"model\": \"claude-3\", \"usage\": {\"input_tokens\": 10, \"output_tokens\": 5}}"))
    (let ((parsed (cl-agent.llm:parse-chat-response response provider)))
      (is (consp parsed))
      (is (string= "Hello!" (getf parsed :content)))
      (is (string= "claude-3" (getf parsed :model)))
      (is (not (null (getf parsed :usage)))))))

(test parse-response-openai
  "测试解析 OpenAI 响应"
  (let ((provider (cl-agent.llm:make-provider :openai :api-key "test-key"))
        (response "{\"choices\": [{\"message\": {\"content\": \"Hi!\"}}], \"model\": \"gpt-4\", \"usage\": {\"prompt_tokens\": 10, \"completion_tokens\": 5}}"))
    (let ((parsed (cl-agent.llm:parse-chat-response response provider)))
      (is (consp parsed))
      (is (string= "Hi!" (getf parsed :content)))
      (is (string= "gpt-4" (getf parsed :model))))))

;; ============================================================
;; 集成测试（需要 API 密钥）
;; ============================================================

(test chat-with-api
  "集成测试：实际 API 调用"
  ;; 注意：这个测试需要真实的 API 密钥和网络连接
  ;; 默认跳过，仅在设置环境变量时运行
  (when (cl-agent.core:get-env "RUN_INTEGRATION_TESTS")
    (let ((client (cl-agent.llm:make-client)))
      (let ((response (cl-agent.llm:chat-simple client "Say 'Hello!'")))
        (is (stringp response))
        (is (> (length response) 0))
        (format t "~%API Response: ~A~%" response)))))

;; ============================================================
;; 运行 LLM 测试
;; ============================================================

(defun run-llm-tests ()
  "运行所有 LLM 测试"
  (run! 'llm-suite))

;; ============================================================
;; OpenAI 兼容基座测试（统一归一化路径）
;; ============================================================

(test openai-compat-provider-hierarchy
  "测试 openai/zhipu/ollama 均为 openai-compat 子类"
  (is (typep (cl-agent.llm:make-provider :openai :api-key "test-key")
             'cl-agent.llm.providers:openai-compat-provider))
  (is (typep (cl-agent.llm:make-provider :zhipu :api-key "test-key")
             'cl-agent.llm.providers:openai-compat-provider))
  (is (typep (cl-agent.llm:make-provider :ollama)
             'cl-agent.llm.providers:openai-compat-provider)))

(test openai-compat-parse-response
  "测试统一响应解析：内容 / 工具调用对象化 / usage 别名 / reasoning"
  (let* ((response "{\"id\": \"chatcmpl-1\", \"model\": \"glm-4.6\",
                     \"choices\": [{\"finish_reason\": \"tool_calls\",
                       \"message\": {\"content\": \"checking\",
                         \"reasoning_content\": \"think step by step\",
                         \"tool_calls\": [{\"id\": \"call_1\",
                           \"function\": {\"name\": \"get_weather\",
                             \"arguments\": \"{\\\"city\\\": \\\"Tokyo\\\"}\"}}]}}],
                     \"usage\": {\"prompt_tokens\": 11, \"completion_tokens\": 7,
                       \"prompt_tokens_details\": {\"cached_tokens\": 4}}}")
         (parsed (cl-agent.llm.providers:parse-openai-compat-response response)))
    ;; 统一返回 llm-response 对象
    (is (cl-agent.core:llm-response-p parsed))
    (is (string= "checking" (cl-agent.core:llm-response-content parsed)))
    ;; reasoning 提取到独立槽位
    (is (string= "think step by step" (cl-agent.core:llm-response-reasoning parsed)))
    ;; finish-reason 归一化
    (is (eq :tool-call (cl-agent.core:llm-response-finish-reason parsed)))
    ;; tool-calls 是 llm-tool-call 对象，arguments 已解析
    (let ((tc (first (cl-agent.core:llm-response-tool-calls parsed))))
      (is (typep tc 'cl-agent.core:llm-tool-call))
      (is (string= "call_1" (cl-agent.core:llm-tool-call-id tc)))
      (is (eq :get_weather (cl-agent.core:llm-tool-call-name tc)))
      (is (hash-table-p (cl-agent.core:llm-tool-call-arguments tc))))
    ;; usage 别名归一（含 cached_tokens）
    (let ((usage (cl-agent.core:llm-response-usage parsed)))
      (is (= 11 (cl-agent.core:llm-usage-input-tokens usage)))
      (is (= 7 (cl-agent.core:llm-usage-output-tokens usage)))
      (is (= 4 (cl-agent.core:llm-usage-cache-read-tokens usage))))))

(test zhipu-auth-headers
  "测试智谱认证头特化：id.secret 直传，普通 key 走 Bearer"
  (let* ((dotted (cl-agent.llm:make-provider :zhipu :api-key "id.secret"))
         (plain (cl-agent.llm:make-provider :zhipu :api-key "plainkey"))
         (h1 (cdr (assoc "Authorization"
                         (cl-agent.llm.providers:provider-auth-headers dotted)
                         :test #'string=)))
         (h2 (cdr (assoc "Authorization"
                         (cl-agent.llm.providers:provider-auth-headers plain)
                         :test #'string=))))
    (is (string= "id.secret" h1))
    (is (string= "Bearer plainkey" h2))))

(test ollama-openai-compat-endpoint
  "测试 Ollama 走 OpenAI 兼容端点"
  (let ((provider (cl-agent.llm:make-provider :ollama)))
    (is (string= "/v1/chat/completions"
                 (cl-agent.llm:provider-chat-endpoint provider)))
    (is (cl-agent.llm:llm-available-p provider))))

;; ============================================================
;; 统一错误分类测试
;; ============================================================

(test error-retryable-classification
  "测试 error-retryable-p 统一分类"
  ;; 鉴权/参数错误：不可重试
  (is (not (cl-agent.core:error-retryable-p
            (make-condition 'cl-agent.core:llm-error
                            :message "auth" :status-code 401))))
  (is (not (cl-agent.core:error-retryable-p
            (make-condition 'cl-agent.core:llm-error
                            :message "bad" :status-code 400))))
  ;; 瞬态错误：可重试
  (is (cl-agent.core:error-retryable-p
       (make-condition 'cl-agent.core:llm-error
                       :message "rate" :status-code 429)))
  (is (cl-agent.core:error-retryable-p
       (make-condition 'cl-agent.core:llm-error
                       :message "server" :status-code 503)))
  ;; 无状态码（网络层失败）：可重试
  (is (cl-agent.core:error-retryable-p
       (make-condition 'cl-agent.core:llm-error :message "network")))
  ;; 超时：可重试
  (is (cl-agent.core:error-retryable-p
       (make-condition 'cl-agent.core:timeout-error :message "timeout")))
  ;; 验证/配置错误：不可重试
  (is (not (cl-agent.core:error-retryable-p
            (make-condition 'cl-agent.core:validation-error :message "invalid"))))
  (is (not (cl-agent.core:error-retryable-p
            (make-condition 'cl-agent.core:missing-api-key-error :message "no key")))))

(test transient-status-classification
  "测试 HTTP 瞬态状态码分类"
  (is (cl-agent.core:transient-status-p 429))
  (is (cl-agent.core:transient-status-p 500))
  (is (cl-agent.core:transient-status-p 503))
  (is (cl-agent.core:transient-status-p 408))
  (is (not (cl-agent.core:transient-status-p 400)))
  (is (not (cl-agent.core:transient-status-p 401)))
  (is (not (cl-agent.core:transient-status-p 403)))
  (is (not (cl-agent.core:transient-status-p 404)))
  (is (not (cl-agent.core:transient-status-p 200))))
