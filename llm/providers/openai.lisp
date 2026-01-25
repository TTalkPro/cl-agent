;;;; openai.lisp
;;;; CL-Agent - OpenAI 提供商实现
;;;;
;;;; 概述：
;;;;   实现 OpenAI GPT 系列的 LLM 提供商接口
;;;;
;;;; 支持的模型：
;;;;   - gpt-4o
;;;;   - gpt-4o-mini
;;;;   - gpt-4-turbo
;;;;   - gpt-3.5-turbo

(in-package :cl-agent.llm.providers)

;;; ============================================================
;;; OpenAI 提供商类
;;; ============================================================

(defclass openai-provider (cl-agent.llm:base-provider)
  ((api-key :initarg :api-key
            :reader provider-api-key
            :documentation "OpenAI API 密钥"))
  (:documentation "OpenAI GPT 提供商

支持 GPT-4 和 GPT-3.5 系列模型"))

;;; ============================================================
;;; 工厂函数
;;; ============================================================

(defun make-openai-provider (&key
                             (api-url "https://api.openai.com/v1")
                             (model "gpt-4o")
                             api-key
                             (timeout 120))
  "创建 OpenAI 提供商

参数：
  API-URL  - API 基础 URL（默认官方 API）
  MODEL    - 默认模型（默认 gpt-4o）
  API-KEY  - API 密钥（可从 OPENAI_API_KEY 环境变量读取）
  TIMEOUT  - 请求超时时间（秒，默认 120）

返回：
  OpenAI 提供商实例

示例：
  ;; 使用默认配置
  (make-openai-provider)

  ;; 指定模型和 API 密钥
  (make-openai-provider :model \"gpt-4o-mini\"
                        :api-key \"sk-...\")

  ;; 使用兼容 API（如 Azure OpenAI）
  (make-openai-provider :api-url \"https://my-resource.openai.azure.com/v1\")"
  (let ((key (or api-key
                 (uiop:getenv "OPENAI_API_KEY"))))
    ;; 非本地 URL 需要 API 密钥
    (when (and (null key)
               (not (search "localhost" api-url)))
      (cl-agent.core:signal-error 'cl-agent.core:missing-api-key-error
                                  :message "OpenAI API 密钥未设置，请设置 OPENAI_API_KEY 环境变量"
                                  :config-key "OPENAI_API_KEY"))

    (make-instance 'openai-provider
                   :name :openai
                   :api-url api-url
                   :default-model model
                   :chat-endpoint "/chat/completions"
                   :stream-endpoint "/chat/completions"
                   :api-key (or key "")
                   :timeout timeout)))

;;; ============================================================
;;; 协议实现
;;; ============================================================

(defmethod cl-agent.llm:llm-chat ((provider openai-provider) messages
                                   &key
                                   max-tokens
                                   (temperature 0.7)
                                   model
                                   tools
                                   system)
  "发送聊天请求到 OpenAI

参数：
  PROVIDER    - OpenAI 提供商实例
  MESSAGES    - 消息列表
  MAX-TOKENS  - 最大 token 数（可选）
  TEMPERATURE - 温度参数（可选，默认 0.7）
  MODEL       - 模型名称（可选）
  TOOLS       - 工具列表（可选）
  SYSTEM      - 系统提示（可选）

返回：
  响应 plist"
  (declare (ignore system))  ; OpenAI 通过 messages 中的 system 角色处理
  (let* (;; 使用通用请求构建函数
         (request-body (build-openai-compatible-request
                        provider
                        messages
                        :max-tokens max-tokens
                        :temperature temperature
                        :model model
                        :tools tools))
         ;; 构建 URL
         (url (cl-agent.llm:build-api-url
               provider
               (cl-agent.llm:provider-chat-endpoint provider)))
         ;; 使用 Bearer Token 认证
         (headers (build-bearer-auth-headers provider))
         ;; 发送请求
         (response (cl-agent.llm:make-http-request
                    url
                    headers
                    (cl-agent.core:json-stringify request-body)
                    :timeout (cl-agent.llm:provider-timeout provider))))
    ;; 使用通用响应解析
    (parse-openai-compatible-response response)))

(defmethod cl-agent.llm:llm-available-p ((provider openai-provider))
  "检查 OpenAI 提供商是否可用"
  (and (slot-boundp provider 'api-key)
       (provider-api-key provider)
       (not (string= (provider-api-key provider) ""))))
