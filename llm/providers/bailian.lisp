;;;; bailian.lisp
;;;; CL-Agent - 阿里云百炼 DashScope 提供商实现
;;;;
;;;; 概述：
;;;;   实现阿里云百炼平台 DashScope 原生 API 的 LLM 提供商接口
;;;;
;;;; 支持的模型：
;;;;   - qwen-max / qwen-max-latest
;;;;   - qwen-plus / qwen-plus-latest
;;;;   - qwen-turbo / qwen-turbo-latest
;;;;   - qwen-long
;;;;   - qwen3-max / qwen3-max-preview
;;;;   - qwen3-plus / qwen3-plus-preview
;;;;   - qwen3-coder-plus / qwen3-coder-flash
;;;;
;;;; API 端点：
;;;;   - https://dashscope.aliyuncs.com/api/v1/services/aigc/text-generation/generation

(in-package :cl-agent.llm.providers)

;;; ============================================================
;;; DashScope 提供商类
;;; ============================================================

(defclass dashscope-provider (cl-agent.llm:base-provider)
  ((api-key :initarg :api-key
            :reader provider-api-key
            :documentation "DashScope API 密钥"))
  (:documentation "阿里云百炼 DashScope 提供商

支持通义千问 Qwen 系列模型，使用 DashScope 原生 API"))

;;; ============================================================
;;; 工厂函数
;;; ============================================================

(defun make-dashscope-provider (&key
                                 (api-url "https://dashscope.aliyuncs.com")
                                 (model "qwen-plus")
                                 api-key
                                 (timeout 120))
  "创建阿里云百炼 DashScope 提供商

参数：
  API-URL  - API 基础 URL（可选，默认阿里云）
  MODEL    - 默认模型（默认 qwen-plus）
  API-KEY  - API 密钥（可从 DASHSCOPE_API_KEY 或 BAILIAN_API_KEY 环境变量读取）
  TIMEOUT  - 请求超时时间（秒，默认 120）

返回：
  DashScope 提供商实例

示例：
  ;; 使用默认配置
  (make-dashscope-provider)

  ;; 指定模型
  (make-dashscope-provider :model \"qwen-max\")

  ;; 使用 qwen3 系列
  (make-dashscope-provider :model \"qwen3-max\")"
  (let ((key (or api-key
                 (uiop:getenv "DASHSCOPE_API_KEY")
                 (uiop:getenv "BAILIAN_API_KEY"))))
    (unless key
      (cl-agent.core:signal-error 'cl-agent.core:missing-api-key-error
                                  :message "DashScope API 密钥未设置，请设置 DASHSCOPE_API_KEY 或 BAILIAN_API_KEY 环境变量"
                                  :config-key "DASHSCOPE_API_KEY"))

    (make-instance 'dashscope-provider
                   :name :dashscope
                   :api-url api-url
                   :default-model model
                   :chat-endpoint "/api/v1/services/aigc/text-generation/generation"
                   :stream-endpoint "/api/v1/services/aigc/text-generation/generation"
                   :api-key key
                   :timeout timeout)))

;; 别名函数
(defun make-bailian-provider (&rest args)
  "创建阿里云百炼提供商（make-dashscope-provider 的别名）"
  (apply #'make-dashscope-provider args))

(defun make-qwen-provider (&rest args)
  "创建通义千问提供商（make-dashscope-provider 的别名）"
  (apply #'make-dashscope-provider args))

;;; ============================================================
;;; 请求构建
;;; ============================================================

(defun build-dashscope-request (provider messages &key
                                                   max-tokens
                                                   temperature
                                                   model
                                                   tools)
  "构建 DashScope 原生 API 请求体

请求格式：
  {
    \"model\": \"qwen-plus\",
    \"input\": {
      \"messages\": [...]
    },
    \"parameters\": {
      \"result_format\": \"message\",
      \"temperature\": 0.7,
      \"max_tokens\": 2000
    }
  }"
  (let ((model-name (or model (cl-agent.llm:provider-default-model provider)))
        (body (make-hash-table :test 'equal))
        (input (make-hash-table :test 'equal))
        (parameters (make-hash-table :test 'equal)))
    ;; model
    (setf (gethash "model" body) model-name)

    ;; input.messages
    (setf (gethash "messages" input)
          (convert-messages-for-dashscope messages))
    (setf (gethash "input" body) input)

    ;; parameters
    (setf (gethash "result_format" parameters) "message")
    (when temperature
      (setf (gethash "temperature" parameters) temperature))
    (when max-tokens
      (setf (gethash "max_tokens" parameters) max-tokens))

    ;; tools (如果有)
    (when tools
      (setf (gethash "tools" parameters)
            (coerce (mapcar #'format-tool-for-dashscope tools) 'vector)))

    (setf (gethash "parameters" body) parameters)

    body))

(defun convert-messages-for-dashscope (messages)
  "转换消息为 DashScope 格式"
  (coerce
   (loop for msg in messages
         for role = (getf msg :role)
         for content = (getf msg :content)
         for tool-calls = (getf msg :tool-calls)
         for tool-call-id = (getf msg :tool-call-id)
         for msg-hash = (make-hash-table :test 'equal)
         do (progn
              (setf (gethash "role" msg-hash)
                    (if (keywordp role)
                        (string-downcase (symbol-name role))
                        role))
              (when content
                (setf (gethash "content" msg-hash) content))
              (when tool-calls
                (setf (gethash "tool_calls" msg-hash)
                      (convert-tool-calls-for-dashscope tool-calls)))
              (when tool-call-id
                (setf (gethash "tool_call_id" msg-hash) tool-call-id)))
         collect msg-hash)
   'vector))

(defun convert-tool-calls-for-dashscope (tool-calls)
  "转换工具调用为 DashScope 格式"
  (coerce
   (loop for tc in tool-calls
         for tc-hash = (make-hash-table :test 'equal)
         for fn-hash = (make-hash-table :test 'equal)
         do (progn
              (setf (gethash "id" tc-hash) (getf tc :id))
              (setf (gethash "type" tc-hash) "function")
              (setf (gethash "name" fn-hash)
                    (let ((name (getf tc :name)))
                      (if (keywordp name)
                          (string-downcase (symbol-name name))
                          name)))
              (setf (gethash "arguments" fn-hash) (getf tc :arguments))
              (setf (gethash "function" tc-hash) fn-hash))
         collect tc-hash)
   'vector))

(defun format-tool-for-dashscope (tool)
  "将工具格式化为 DashScope 格式"
  (let ((tool-hash (make-hash-table :test 'equal))
        (fn-hash (make-hash-table :test 'equal)))
    (setf (gethash "type" tool-hash) "function")
    (setf (gethash "name" fn-hash) (getf tool :name))
    (setf (gethash "description" fn-hash) (getf tool :description))
    (setf (gethash "parameters" fn-hash) (getf tool :parameters))
    (setf (gethash "function" tool-hash) fn-hash)
    tool-hash))

;;; ============================================================
;;; 响应解析
;;; ============================================================

(defun parse-dashscope-response (response)
  "解析 DashScope 响应

响应格式：
  {
    \"output\": {
      \"choices\": [{
        \"message\": {
          \"content\": \"...\",
          \"role\": \"assistant\"
        },
        \"finish_reason\": \"stop\"
      }]
    },
    \"usage\": {
      \"total_tokens\": 21,
      \"output_tokens\": 11,
      \"input_tokens\": 10
    },
    \"request_id\": \"...\"
  }

返回统一的 llm-response 对象"
  (let* ((parsed (cl-agent.llm:parse-json-response response))
         (output (gethash "output" parsed))
         (choices (when output (gethash "choices" output)))
         (first-choice (when (and choices (plusp (length choices)))
                         (elt choices 0)))
         (message (when first-choice (gethash "message" first-choice)))
         (content (when message (gethash "content" message)))
         (tool-calls (when message (gethash "tool_calls" message)))
         (finish-reason (when first-choice (gethash "finish_reason" first-choice))))

    (cl-agent.core:make-llm-response
     :content (or content "")
     :tool-calls (when tool-calls
                   (parse-dashscope-tool-calls tool-calls))
     :usage (cl-agent.core:normalize-usage (gethash "usage" parsed))
     :model (gethash "model" parsed)
     :finish-reason (cl-agent.core:normalize-finish-reason finish-reason)
     :message-id (gethash "request_id" parsed)
     :raw-response parsed)))

(defun parse-dashscope-tool-calls (tool-calls)
  "解析 DashScope 工具调用"
  (loop for call in (if (vectorp tool-calls)
                        (coerce tool-calls 'list)
                        tool-calls)
        for id = (gethash "id" call)
        for function = (gethash "function" call)
        for name = (when function (gethash "name" function))
        for arguments = (when function (gethash "arguments" function))
        collect (list :id id
                      :name (when name (make-keyword (string-downcase name)))
                      :arguments arguments
                      :raw call)))

;;; ============================================================
;;; 协议实现
;;; ============================================================

(defmethod cl-agent.llm:llm-chat ((provider dashscope-provider) messages
                                   &key
                                   max-tokens
                                   (temperature 0.7)
                                   model
                                   tools
                                   system)
  "发送聊天请求到 DashScope

参数：
  PROVIDER      - DashScope 提供商实例
  MESSAGES      - 消息列表
  MAX-TOKENS    - 最大 token 数（可选）
  TEMPERATURE   - 温度参数（可选，默认 0.7）
  MODEL         - 模型名称（可选）
  TOOLS         - 工具列表（可选）
  SYSTEM        - 系统提示（可选）

返回：
  响应 plist"
  (declare (ignore system))
  (let* (;; 构建请求体
         (request-body (build-dashscope-request
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
    ;; 解析响应
    (parse-dashscope-response response)))

(defmethod cl-agent.llm:llm-available-p ((provider dashscope-provider))
  "检查 DashScope 提供商是否可用"
  (and (slot-boundp provider 'api-key)
       (provider-api-key provider)
       (not (string= (provider-api-key provider) ""))))

;;; ============================================================
;;; 辅助函数
;;; ============================================================

(defun dashscope-list-models ()
  "列出 DashScope 支持的主要模型"
  '(;; Qwen Max 系列
    "qwen-max" "qwen-max-latest"
    "qwen3-max" "qwen3-max-preview"
    ;; Qwen Plus 系列
    "qwen-plus" "qwen-plus-latest"
    "qwen3-plus" "qwen3-plus-preview"
    ;; Qwen Turbo 系列
    "qwen-turbo" "qwen-turbo-latest"
    ;; Qwen Long（长文本）
    "qwen-long"
    ;; Qwen Coder 系列
    "qwen3-coder-plus" "qwen3-coder-flash"
    ;; 视觉模型
    "qwen-vl-max" "qwen-vl-plus"))
