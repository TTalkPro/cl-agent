;;;; test-llm.lisp
;;;; CL-Agent - LLM 服务层测试

(in-package :cl-agent/tests)

;; LLM API 测试套件
(def-suite llm-suite :in cl-agent-tests:lisp-in-agents-suite
  :description "LLM 服务层测试")

(in-suite llm-suite)

;; ============================================================
;; 提供商测试
;; ============================================================

(test make-provider-anthropic
  "测试创建 Anthropic 提供商"
  (let ((provider (cl-agent.llm:make-provider :anthropic)))
    (is (eq (cl-agent.llm:provider-name provider) :anthropic))
    (is (stringp (cl-agent.llm:provider-api-url provider)))
    (is (stringp (cl-agent.llm:provider-default-model provider)))))

(test make-provider-openai
  "测试创建 OpenAI 提供商"
  (let ((provider (cl-agent.llm:make-provider :openai)))
    (is (eq (cl-agent.llm:provider-name provider) :openai))
    (is (stringp (cl-agent.llm:provider-api-url provider)))))

(test make-provider-ollama
  "测试创建 Ollama 提供商"
  (let ((provider (cl-agent.llm:make-provider :ollama)))
    (is (eq (cl-agent.llm:provider-name provider) :ollama))
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
  (let ((provider (cl-agent.llm:make-provider :anthropic)))
    (let ((cost (cl-agent.llm:estimate-cost provider 1000 500)))
      (is (numberp cost))
      (is (> cost 0)))))

(test estimate-cost-openai
  "测试 OpenAI 成本估算"
  (let ((provider (cl-agent.llm:make-provider :openai)))
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
  (let ((provider (cl-agent.llm:make-provider :anthropic))
        (message '(:user . "Hello")))
    (let ((converted (cl-agent.llm:convert-message-to-provider message provider)))
      (is (consp converted))
      (is (assoc "role" converted :test #'string=))
      (is (assoc "content" converted :test #'string=)))))

;; ============================================================
;; 请求体构建测试
;; ============================================================

(test build-request-body-basic
  "测试基本请求体构建"
  (let ((provider (cl-agent.llm:make-provider :anthropic))
        (messages '((:user . "Hello"))))
    (let ((body (cl-agent.llm:build-chat-request-body
                   provider messages)))
      (is (consp body))
      (is (assoc "model" body :test #'string=))
      (is (assoc "messages" body :test #'string=))
      (is (assoc "stream" body :test #'string=)))))

(test build-request-body-with-system
  "测试带系统提示的请求体构建"
  (let ((provider (cl-agent.llm:make-provider :anthropic))
        (messages '((:user . "Hello"))))
    (let ((body (cl-agent.llm:build-chat-request-body
                   provider messages
                   :system "You are a helpful assistant.")))
      (is (assoc "system" body :test #'string=))
      (is (string= (getf (assoc "system" body :test #'string=) "system")
                   "You are a helpful assistant.")))))

(test build-request-body-with-temperature
  "测试带温度的请求体构建"
  (let ((provider (cl-agent.llm:make-provider :anthropic))
        (messages '((:user . "Hello"))))
    (let ((body (cl-agent.llm:build-chat-request-body
                   provider messages
                   :temperature 0.5)))
      (is (assoc "temperature" body :test #'string=))
      (is (= (getf (assoc "temperature" body :test #'string=) "temperature")
             0.5)))))

;; ============================================================
;; 响应解析测试
;; ============================================================

(test parse-response-anthropic
  "测试解析 Anthropic 响应"
  (let ((provider (cl-agent.llm:make-provider :anthropic))
        (response "{ "content": [{"text": "Hello!"}], "model": "claude-3", "usage": {"input_tokens": 10, "output_tokens": 5}}"))
    (let ((parsed (cl-agent.llm:parse-chat-response response provider)))
      (is (consp parsed))
      (is (assoc :content parsed))
      (is (assoc :model parsed))
      (is (assoc :usage parsed)))))

(test parse-response-openai
  "测试解析 OpenAI 响应"
  (let ((provider (cl-agent.llm:make-provider :openai))
        (response "{ "choices": [{"message": {"content": "Hi!"}}], "model": "gpt-4", "usage": {"prompt_tokens": 10, "completion_tokens": 5}}"))
    (let ((parsed (cl-agent.llm:parse-chat-response response provider)))
      (is (consp parsed))
      (is (assoc :content parsed))
      (is (assoc :model parsed)))))

;; ============================================================
;; 集成测试（需要 API 密钥）
;; ============================================================

(test-integration chat-with-api
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
