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
  (let ((provider (cl-agent.llm.providers:make-deepseek-provider
                   :api-key "test-key")))
    (is (typep provider 'cl-agent.llm.providers:deepseek-provider))
    (is (typep provider 'cl-agent.llm.providers:openai-compat-provider))
    (is (string= "https://api.deepseek.com"
                 (cl-agent.llm:base-provider-api-url provider)))
    (is (string= "deepseek-chat"
                 (cl-agent.llm:base-provider-default-model provider)))
    (is (eq :deepseek (cl-agent.llm:base-provider-name provider)))))

(test gemini-provider-factory
  "Gemini provider 默认配置（Google OpenAI 兼容端点）"
  (let ((provider (cl-agent.llm.providers:make-gemini-provider
                   :api-key "test-key")))
    (is (typep provider 'cl-agent.llm.providers:gemini-provider))
    ;; base-url 必须含 /openai（Google 兼容端点的特殊路径）
    (is (search "/v1beta/openai"
                (cl-agent.llm:base-provider-api-url provider)))
    (is (string= "gemini-2.0-flash"
                 (cl-agent.llm:base-provider-default-model provider)))))

(test mistral-provider-factory
  "Mistral provider 默认配置"
  (let ((provider (cl-agent.llm.providers:make-mistral-provider
                   :api-key "test-key")))
    (is (typep provider 'cl-agent.llm.providers:mistral-provider))
    (is (string= "https://api.mistral.ai/v1"
                 (cl-agent.llm:base-provider-api-url provider)))
    (is (string= "mistral-large-latest"
                 (cl-agent.llm:base-provider-default-model provider)))))

(test minimax-provider-anthropic-compat
  "MiniMax 走 Anthropic 兼容端点（对齐 clj-agent）"
  (let ((provider (cl-agent.llm.providers:make-minimax-provider
                   :api-key "test-key")))
    ;; 继承 anthropic-provider，复用其请求/响应实现
    (is (typep provider 'cl-agent.llm.providers:anthropic-provider))
    (is (string= "https://api.minimaxi.com"
                 (cl-agent.llm:base-provider-api-url provider)))
    (is (string= "/anthropic/v1/messages"
                 (cl-agent.llm:base-provider-chat-endpoint provider)))
    (is (string= "MiniMax-M2.7"
                 (cl-agent.llm:base-provider-default-model provider)))
    (is (eq :minimax (cl-agent.llm:base-provider-name provider)))
    ;; Bearer 鉴权，无 anthropic-version 头
    (let ((headers (cl-agent.llm.providers:build-anthropic-headers provider)))
      (is (string= "Bearer test-key"
                   (cdr (assoc "Authorization" headers :test #'string=))))
      (is (null (assoc "anthropic-version" headers :test #'string=)))
      (is (null (assoc "x-api-key" headers :test #'string=))))))

(test anthropic-headers-default
  "标准 Anthropic 仍用 x-api-key + anthropic-version"
  (let* ((provider (cl-agent.llm.providers:make-anthropic-provider
                    :api-key "sk-ant-test"))
         (headers (cl-agent.llm.providers:build-anthropic-headers provider)))
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
      (signals cl-agent.core:missing-api-key-error
        (cl-agent.llm.providers:make-mistral-provider))))

;;; ============================================================
;;; Registry
;;; ============================================================

(test registry-new-providers-registered
  "三个新 provider 已注册"
  (is-true (cl-agent.llm:provider-registered-p :deepseek))
  (is-true (cl-agent.llm:provider-registered-p :gemini))
  (is-true (cl-agent.llm:provider-registered-p :mistral)))

(test registry-aliases
  "别名解析到规范名"
  (is (eq :gemini (cl-agent.llm:resolve-provider-name "google")))
  (is (eq :dashscope (cl-agent.llm:resolve-provider-name "qwen")))
  (is (eq :dashscope (cl-agent.llm:resolve-provider-name "bailian")))
  (is (eq :anthropic (cl-agent.llm:resolve-provider-name :claude)))
  ;; 非别名原样透传
  (is (eq :deepseek (cl-agent.llm:resolve-provider-name :deepseek))))

(test registry-unregister
  "注册后可注销（对标 clj registry/unregister-provider!）"
  (cl-agent.llm:register-provider :test-temp-provider
                                  (lambda (&rest args)
                                    (declare (ignore args))
                                    :fake))
  (is-true (cl-agent.llm:provider-registered-p :test-temp-provider))
  (is-true (cl-agent.llm:unregister-provider :test-temp-provider))
  (is-false (cl-agent.llm:provider-registered-p :test-temp-provider))
  ;; 重复注销返回 NIL
  (is-false (cl-agent.llm:unregister-provider :test-temp-provider)))

(test registry-create-via-factory
  "create-provider 经工厂创建新 provider"
  (let ((provider (cl-agent.llm:create-provider :deepseek :api-key "k")))
    (is (typep provider 'cl-agent.llm.providers:deepseek-provider))))

;;; ============================================================
;;; OpenAI 兼容请求体：存在才发送
;;; ============================================================

(defun build-compat-request (&rest args)
  "用 mistral provider 构建请求体（任意 openai-compat provider 均可）"
  (apply #'cl-agent.llm.providers::build-openai-compatible-request
         (cl-agent.llm.providers:make-mistral-provider :api-key "k")
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
  (is (string= "auto" (cl-agent.llm.providers::tool-choice-to-wire :auto)))
  (is (string= "none" (cl-agent.llm.providers::tool-choice-to-wire :none)))
  (is (string= "custom" (cl-agent.llm.providers::tool-choice-to-wire "custom"))))

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
  (let* ((messages (cl-agent.llm.providers::convert-messages-for-openai
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
  (let* ((provider (cl-agent.llm.providers:make-anthropic-provider
                    :api-key "test-key"))
         (body (cl-agent.llm.providers::build-anthropic-request-body
                provider
                (list (list :role :user :content "hi"))
                :max-tokens 100
                :top-p 0.8
                :top-k 40
                :stop '("END")
                :extra-params '(:metadata "m")))
         (bare (cl-agent.llm.providers::build-anthropic-request-body
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
         (marked (cl-agent.llm.providers:mark-prefix messages)))
    (is (eq t (getf (second marked) :prefix)))
    ;; 原消息列表不被修改
    (is (null (getf (second messages) :prefix)))))

(test deepseek-mark-prefix-requires-assistant-tail
  "最后一条非 assistant 时报错"
  (signals error
    (cl-agent.llm.providers:mark-prefix
     (list (list :role :user :content "hi")))))

;;; ============================================================
;;; ChatModel 适配层选项下发
;;; ============================================================

(test chat-model-passes-sampling-options
  "chat-options 的采样选项完整下发到 llm-chat SPI"
  (let* ((provider (make-seq-provider (text-response "ok")))
         (model (cl-agent.chat:make-provider-chat-model provider)))
    (cl-agent.chat:chat-model-call
     model
     (cl-agent.chat:make-prompt
      "hi"
      :options (cl-agent.chat:make-chat-options
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
         (model (cl-agent.chat:make-provider-chat-model provider)))
    (cl-agent.chat:chat-model-call model "hi")
    (let ((request (first (seq-provider-requests provider))))
      (is (null (getf request :top-p)))
      (is (null (getf request :stop)))
      (is (null (getf request :extra-params))))))

(test chat-options-extra-params-merge
  "extra-params 参与选项合并（运行时覆盖默认）"
  (let ((merged (cl-agent.chat:merge-chat-options
                 (cl-agent.chat:make-chat-options :extra-params '(:seed 1))
                 (cl-agent.chat:make-chat-options :extra-params '(:seed 9)
                                                  :temperature 0.5))))
    (is (equal '(:seed 1) (cl-agent.chat:chat-options-extra-params merged)))
    (is (= 0.5 (cl-agent.chat:chat-options-temperature merged)))))

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
    (is (equal "hi" (cl-agent.llm::alist-get al "content")))
    ;; 符号键降级为小写字符串
    (is (equal "hi" (cl-agent.llm::alist-get al 'content)))
    ;; 大小写不敏感（string-equal）
    (is (equal "hi" (cl-agent.llm::alist-get al "CONTENT")))
    ;; 缺失键返回 nil
    (is (null (cl-agent.llm::alist-get al "nope"))))
  ;; hash-table（json-parse 的返回格式）
  (let ((ht (make-hash-table :test #'equal)))
    (setf (gethash "content" ht) "hi")
    (is (equal "hi" (cl-agent.llm::alist-get ht "content")))
    (is (null (cl-agent.llm::alist-get ht "nope"))))
  ;; 奇数长度的 alist 不应像旧 core 实现那样抛 malformed property list
  (is (equal 1 (cl-agent.llm::alist-get '(("a" . 1)) "a"))))
