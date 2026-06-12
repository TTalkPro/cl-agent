;;;; openai-compat.lisp
;;;; CL-Agent LLM - OpenAI 兼容 Provider 基座
;;;;
;;;; 概述（参照 clj-agent provider/common/{base,openai_compat}.clj）：
;;;;   绝大多数厂商（OpenAI、智谱、DeepSeek、Ollama、Moonshot、MiniMax …）
;;;;   都暴露 OpenAI 兼容的 /chat/completions 接口。本文件提供：
;;;;
;;;;   1. openai-compat-provider 基类：llm-chat 的完整共享实现
;;;;      （构建请求 → HTTP → 归一化为 llm-response）
;;;;   2. CLOS 扩展点（泛型函数）：
;;;;      - provider-auth-headers       认证头（默认 Bearer）
;;;;      - provider-finalize-request   请求体最后修饰（默认原样）
;;;;   3. define-openai-compat-provider 宏：声明式定义一个厂商
;;;;      （类 + 工厂函数，约 5 行/厂商）
;;;;
;;;;   归一化是单一来源：parse-openai-compat-response 统一产出
;;;;   llm-response 对象（tool-calls 为 llm-tool-call 对象、usage 走
;;;;   cl-agent.core:normalize-usage 别名归一、reasoning_content 提取）。

(in-package :cl-agent.llm.providers)

;;; ============================================================
;;; OpenAI 兼容基类
;;; ============================================================

(defclass openai-compat-provider (cl-agent.llm:base-provider)
  ((api-key
    :initarg :api-key
    :reader provider-api-key
    :initform ""
    :documentation "API 密钥"))
  (:documentation "OpenAI 兼容 Provider 基类。

子类通常只需通过 define-openai-compat-provider 声明 base-url /
env-key / default-model；特殊认证或请求修饰通过特化
provider-auth-headers / provider-finalize-request 实现。"))

;;; ============================================================
;;; CLOS 扩展点
;;; ============================================================

(defgeneric provider-auth-headers (provider)
  (:documentation "构建认证请求头（alist）。默认 Bearer Token。"))

(defmethod provider-auth-headers ((provider openai-compat-provider))
  `(("Content-Type" . "application/json")
    ("Authorization" . ,(format nil "Bearer ~A" (provider-api-key provider)))))

(defgeneric provider-finalize-request (provider body)
  (:documentation "请求体发送前的最后修饰（hash-table -> hash-table）。
默认原样返回；子类可特化以增删厂商特有字段。"))

(defmethod provider-finalize-request ((provider openai-compat-provider) body)
  body)

;;; ============================================================
;;; 响应归一化（单一来源）
;;; ============================================================

(defun parse-openai-compat-response (response)
  "解析 OpenAI 兼容响应，统一产出 llm-response 对象。

- tool_calls -> llm-tool-call 对象（arguments 解析为对象，非 JSON 字符串）
- usage      -> cl-agent.core:normalize-usage（permissive 别名归一，
                含 cache 字段）
- reasoning_content（DeepSeek/GLM 思维链）-> :reasoning
- finish_reason -> cl-agent.core:normalize-finish-reason"
  (let* ((parsed (cl-agent.llm:parse-json-response response))
         (choices (gethash "choices" parsed))
         (first-choice (when (and choices (plusp (length choices)))
                         (elt choices 0)))
         (message (when first-choice (gethash "message" first-choice)))
         (content (when message (gethash "content" message)))
         (reasoning (when message (gethash "reasoning_content" message)))
         (tool-calls (when message (gethash "tool_calls" message)))
         (finish-reason (when first-choice (gethash "finish_reason" first-choice))))
    (cl-agent.core:make-llm-response
     :content (or content "")
     :tool-calls (when tool-calls
                   (parse-tool-calls-openai-style tool-calls))
     :usage (cl-agent.core:normalize-usage (gethash "usage" parsed))
     :model (gethash "model" parsed)
     :finish-reason (cl-agent.core:normalize-finish-reason finish-reason)
     :reasoning reasoning
     :message-id (gethash "id" parsed)
     :raw-response parsed)))

;;; ============================================================
;;; llm-chat 共享实现
;;; ============================================================

(defmethod cl-agent.llm:llm-chat ((provider openai-compat-provider) messages
                                  &key max-tokens
                                       (temperature 0.7)
                                       model
                                       tools
                                       system)
  "OpenAI 兼容的共享 llm-chat 实现。

SYSTEM 提示折叠进 messages（OpenAI 风格）；
返回统一的 llm-response 对象。"
  (let* ((effective-messages (if system
                                 (cons (list :role :system :content system)
                                       messages)
                                 messages))
         (request-body (provider-finalize-request
                        provider
                        (build-openai-compatible-request
                         provider
                         effective-messages
                         :max-tokens max-tokens
                         :temperature temperature
                         :model model
                         :tools tools)))
         (url (cl-agent.llm:build-api-url
               provider
               (cl-agent.llm:provider-chat-endpoint provider)))
         (headers (provider-auth-headers provider))
         (response (cl-agent.llm:make-http-request
                    url
                    headers
                    (cl-agent.core:json-stringify request-body)
                    :timeout (cl-agent.llm:provider-timeout provider))))
    (parse-openai-compat-response response)))

(defmethod cl-agent.llm:llm-available-p ((provider openai-compat-provider))
  "默认可用性检查：API 密钥非空"
  (let ((key (provider-api-key provider)))
    (and key (not (string= key "")))))

;;; ============================================================
;;; define-openai-compat-provider 宏
;;; ============================================================

(defmacro define-openai-compat-provider (name &key
                                              base-url
                                              env-key
                                              default-model
                                              (chat-endpoint "/chat/completions")
                                              (timeout 120)
                                              key-optional
                                              documentation)
  "声明式定义一个 OpenAI 兼容 Provider。

生成：
  1. 类 NAME-PROVIDER（继承 openai-compat-provider）
  2. 工厂函数 MAKE-NAME-PROVIDER (&key api-url model api-key timeout)

参数：
  NAME          - Provider 名称（符号，如 openai）
  BASE-URL      - 默认 API 基础 URL
  ENV-KEY       - API 密钥环境变量名
  DEFAULT-MODEL - 默认模型
  CHAT-ENDPOINT - 端点（默认 /chat/completions）
  TIMEOUT       - 超时秒数（默认 120）
  KEY-OPTIONAL  - T 则缺 key 不报错（本地服务如 Ollama）
  DOCUMENTATION - 类文档

示例：
  (define-openai-compat-provider deepseek
    :base-url \"https://api.deepseek.com/v1\"
    :env-key \"DEEPSEEK_API_KEY\"
    :default-model \"deepseek-chat\")

特殊认证/请求修饰通过特化 provider-auth-headers /
provider-finalize-request 于生成的类上实现。"
  (let* ((name-str (string-downcase (symbol-name name)))
         (keyword-name (intern (string-upcase name-str) :keyword))
         (class-name (intern (format nil "~A-PROVIDER" (string-upcase name-str))
                             :cl-agent.llm.providers))
         (factory-name (intern (format nil "MAKE-~A-PROVIDER" (string-upcase name-str))
                               :cl-agent.llm.providers)))
    `(progn
       (defclass ,class-name (openai-compat-provider)
         ()
         (:documentation ,(or documentation
                              (format nil "~A Provider（OpenAI 兼容）"
                                      (string-capitalize name-str)))))

       (defun ,factory-name (&key (api-url ,base-url)
                                  (model ,default-model)
                                  api-key
                                  (timeout ,timeout))
         ,(format nil "创建 ~A Provider

参数：
  API-URL  - API 基础 URL（默认 ~A）
  MODEL    - 默认模型（默认 ~A）
  API-KEY  - API 密钥~@[（可从 ~A 环境变量读取）~]
  TIMEOUT  - 请求超时（秒，默认 ~A）

返回：
  ~A 实例"
                  (string-capitalize name-str) base-url default-model
                  env-key timeout class-name)
         (let ((key (or api-key
                        ,@(when env-key `((uiop:getenv ,env-key))))))
           ,@(unless key-optional
               `((when (and (null key)
                            (not (search "localhost" api-url))
                            (not (search "127.0.0.1" api-url)))
                   (cl-agent.core:signal-error
                    'cl-agent.core:missing-api-key-error
                    :message ,(format nil "~A API 密钥未设置~@[，请设置 ~A 环境变量~]"
                                      (string-capitalize name-str) env-key)
                    :config-key ,(or env-key name-str)))))
           (make-instance ',class-name
                          :name ,keyword-name
                          :api-url api-url
                          :default-model model
                          :chat-endpoint ,chat-endpoint
                          :stream-endpoint ,chat-endpoint
                          :api-key (or key "")
                          :timeout timeout)))

       ',class-name)))
