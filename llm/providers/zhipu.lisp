;;;; zhipu.lisp
;;;; CL-Agent - 智谱 AI (ZhipuAI) 提供商实现
;;;;
;;;; 概述：
;;;;   实现智谱 AI GLM 系列的 LLM 提供商接口
;;;;
;;;; 支持的模型：
;;;;   - GLM-4.7 (最新版本)
;;;;   - glm-4.6 (带思维链)
;;;;   - glm-4-plus
;;;;   - glm-4-air
;;;;   - glm-4-flash
;;;;
;;;; API 文档：https://open.bigmodel.cn/dev/api

(in-package :cl-agent.llm.providers)

;;; ============================================================
;;; 智谱 AI 提供商类
;;; ============================================================

(defclass zhipu-provider (cl-agent.llm:base-provider)
  ((api-key :initarg :api-key
            :reader provider-api-key
            :documentation "智谱 AI API 密钥"))
  (:documentation "智谱 AI GLM 提供商

支持 GLM-4 系列模型，包括最新的 GLM-4.7"))

;;; ============================================================
;;; 工厂函数
;;; ============================================================

(defun make-zhipu-provider (&key
                            (api-url "https://open.bigmodel.cn/api/paas/v4")
                            (model "GLM-4.7")
                            api-key
                            (timeout 120))
  "创建智谱 AI 提供商

参数：
  API-URL  - API 基础 URL（默认官方 API）
  MODEL    - 默认模型（默认 GLM-4.7）
  API-KEY  - API 密钥（可从 ZHIPU_API_KEY 环境变量读取）
  TIMEOUT  - 请求超时时间（秒，默认 120）

返回：
  智谱 AI 提供商实例

注意：
  GLM-4.7 是最新模型，建议使用
  glm-4.6 会输出思维链内容（reasoning_content）

示例：
  ;; 使用默认配置（推荐）
  (make-zhipu-provider)

  ;; 指定模型
  (make-zhipu-provider :model \"glm-4-flash\")

  ;; 使用自定义 API 密钥
  (make-zhipu-provider :api-key \"your-api-key\")"
  (let ((key (or api-key
                 (uiop:getenv "ZHIPU_API_KEY"))))
    (when (null key)
      (cl-agent.core:signal-error 'cl-agent.core:missing-api-key-error
                                  :message "智谱 AI API 密钥未设置，请设置 ZHIPU_API_KEY 环境变量"
                                  :config-key "ZHIPU_API_KEY"))

    (make-instance 'zhipu-provider
                   :name :zhipu
                   :api-url api-url
                   :default-model model
                   :chat-endpoint "/chat/completions"
                   :stream-endpoint "/chat/completions"
                   :api-key key
                   :timeout timeout)))

;;; ============================================================
;;; 协议实现
;;; ============================================================

(defmethod cl-agent.llm:llm-chat ((provider zhipu-provider) messages
                                   &key
                                   max-tokens
                                   (temperature 0.7)
                                   model
                                   tools
                                   system)
  "发送聊天请求到智谱 AI

参数：
  PROVIDER    - 智谱 AI 提供商实例
  MESSAGES    - 消息列表
  MAX-TOKENS  - 最大 token 数（可选，建议 4096 以容纳思维链）
  TEMPERATURE - 温度参数（可选，默认 0.7）
  MODEL       - 模型名称（可选）
  TOOLS       - 工具列表（可选）
  SYSTEM      - 系统提示（可选）

返回：
  响应 plist，包含:
    :content - 文本内容
    :reasoning-content - 思维链内容（如果模型输出）
    :tool-calls - 工具调用（如果有）
    :usage - token 使用信息"
  (declare (ignore system))
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
         ;; 构建请求头（智谱使用特殊的认证格式）
         (headers (build-zhipu-headers provider))
         ;; 发送请求
         (response (cl-agent.llm:make-http-request
                    url
                    headers
                    (cl-agent.core:json-stringify request-body)
                    :timeout (cl-agent.llm:provider-timeout provider))))
    ;; 解析响应（支持智谱特有的 reasoning_content）
    (parse-zhipu-response response)))

(defmethod cl-agent.llm:llm-available-p ((provider zhipu-provider))
  "检查智谱 AI 提供商是否可用"
  (and (slot-boundp provider 'api-key)
       (provider-api-key provider)
       (not (string= (provider-api-key provider) ""))))

;;; ============================================================
;;; 智谱特定函数
;;; ============================================================

(defun build-zhipu-headers (provider)
  "构建智谱 AI 请求头

参数：
  PROVIDER - 提供商实例

返回：
  请求头 alist

注意：
  智谱 AI 使用 Bearer Token 认证
  API 密钥格式为 id.secret 或直接使用 Bearer token"
  (let* ((api-key (provider-api-key provider))
         ;; 智谱 API 密钥格式可能是 id.secret 或直接 token
         (auth-header (if (search "." api-key)
                          api-key  ; 完整格式
                          (format nil "Bearer ~A" api-key))))
    `(("Content-Type" . "application/json")
      ("Authorization" . ,auth-header))))

(defun parse-zhipu-response (response)
  "解析智谱 AI API 响应

参数：
  RESPONSE - HTTP 响应

返回：
  标准化的响应 plist

特殊处理：
  - 提取 reasoning_content（思维链内容）
  - 处理空内容的情况（被截断时）"
  (let* ((parsed (cl-agent.llm:parse-json-response response))
         (choices (gethash "choices" parsed))
         (first-choice (elt choices 0))
         (message (gethash "message" first-choice))
         (content (gethash "content" message))
         (reasoning-content (gethash "reasoning_content" message))
         (tool-calls (gethash "tool_calls" message))
         (finish-reason (gethash "finish_reason" first-choice))
         (usage (gethash "usage" parsed)))

    ;; 构建标准响应
    (append (list :content (or content "")
                  :reasoning-content reasoning-content
                  :finish-reason finish-reason)
            ;; 添加工具调用
            (when tool-calls
              (list :tool-calls (parse-tool-calls-openai-style tool-calls)))
            ;; 添加使用信息
            (list :usage (list :prompt-tokens (gethash "prompt_tokens" usage)
                              :completion-tokens (gethash "completion_tokens" usage)
                              :total-tokens (gethash "total_tokens" usage)))
            ;; 添加原始信息
            (list :model (gethash "model" parsed)
                  :id (gethash "id" parsed)
                  :raw-response parsed))))

;;; ============================================================
;;; 智谱 AI 特定工具函数
;;; ============================================================

(defun extract-reasoning-content (response)
  "提取思维链内容

参数：
  RESPONSE - parse-zhipu-response 返回的响应

返回：
  思维链字符串，如果没有则返回 nil

用途：
  - 调试模型推理过程
  - 分析模型行为
  - 改进提示词"
  (getf response :reasoning-content))

(defun response-complete-p (response)
  "检查响应是否完整

参数：
  RESPONSE - parse-zhipu-response 返回的响应

返回：
  t 如果响应完整，nil 如果被截断

判断标准：
  - finish_reason = \"stop\" 表示正常完成
  - finish_reason = \"length\" 表示因长度限制被截断"
  (string= (getf response :finish-reason) "stop"))

(defun get-suggested-max-tokens (provider)
  "获取建议的 max-tokens 值

参数：
  PROVIDER - 智谱 AI 提供商实例

返回：
  建议的 max-tokens 值

说明：
  - GLM-4.7: 建议 4096
  - glm-4.6: 建议 4096 或更大（因为包含思维链）
  - 其他模型: 建议 2048"
  (let ((model (cl-agent.llm:provider-default-model provider)))
    (cond
      ((search "GLM-4.7" model) 4096)
      ((search "glm-4.6" model) 4096)
      (t 2048))))
