;;;; define-provider.lisp
;;;; CL-Agent LLM - Provider 定义宏
;;;;
;;;; 概述：
;;;;   提供 define-provider 宏，消除 Provider 实现中的重复代码
;;;;   自动生成：类定义、工厂函数、llm-chat 方法等
;;;;
;;;; 设计原则：
;;;;   - 约定优于配置
;;;;   - 只覆盖需要自定义的部分
;;;;   - 保持与现有 API 的兼容性

(in-package :cl-agent.llm.providers)

;;; ============================================================
;;; define-provider 宏
;;; ============================================================

(defmacro define-provider (name &key
                                default-url
                                default-model
                                api-key-env
                                (chat-endpoint "/chat/completions")
                                (stream-endpoint "/chat/completions")
                                (timeout 120)
                                extra-slots
                                build-headers-fn
                                build-request-fn
                                parse-response-fn
                                available-check-fn
                                documentation)
  "定义 LLM Provider 的宏

自动生成：
  1. 类定义（继承 base-provider）
  2. 工厂函数 make-NAME-provider
  3. llm-chat 方法实现
  4. llm-available-p 方法实现

参数：
  NAME             - Provider 名称（关键字，如 :openai）
  DEFAULT-URL      - 默认 API URL
  DEFAULT-MODEL    - 默认模型名称
  API-KEY-ENV      - API 密钥环境变量名
  CHAT-ENDPOINT    - Chat API 端点（默认 /chat/completions）
  STREAM-ENDPOINT  - Stream API 端点
  TIMEOUT          - 请求超时时间（秒）
  EXTRA-SLOTS      - 额外的类槽位定义
  BUILD-HEADERS-FN - 构建请求头函数（接收 provider）
  BUILD-REQUEST-FN - 构建请求体函数（接收 provider messages &key ...）
  PARSE-RESPONSE-FN - 解析响应函数（接收 response）
  AVAILABLE-CHECK-FN - 可用性检查函数（接收 provider）
  DOCUMENTATION    - 类文档字符串

示例：
  (define-provider :openai
    :default-url \"https://api.openai.com/v1\"
    :default-model \"gpt-4o\"
    :api-key-env \"OPENAI_API_KEY\"
    :build-headers-fn #'build-openai-headers
    :build-request-fn #'build-openai-request-body
    :parse-response-fn #'parse-openai-response)"

  (let* ((name-str (string-downcase (symbol-name name)))
         (class-name (intern (format nil "~A-PROVIDER" (string-upcase name-str))
                             :cl-agent.llm.providers))
         (factory-name (intern (format nil "MAKE-~A-PROVIDER" (string-upcase name-str))
                               :cl-agent.llm.providers))
         (api-key-slot 'api-key)
         (missing-key-msg (format nil "~A API 密钥未设置，请设置 ~A 环境变量"
                                  (string-capitalize name-str)
                                  api-key-env)))

    `(progn
       ;; ============================================================
       ;; 1. 类定义
       ;; ============================================================
       (defclass ,class-name (cl-agent.llm:base-provider)
         ((,api-key-slot
           :initarg :api-key
           :reader provider-api-key
           :documentation "API 密钥")
          ,@extra-slots)
         (:documentation ,(or documentation
                              (format nil "~A Provider" (string-capitalize name-str)))))

       ;; ============================================================
       ;; 2. 工厂函数
       ;; ============================================================
       (defun ,factory-name (&key
                             (api-url ,default-url)
                             (model ,default-model)
                             api-key
                             (timeout ,timeout))
         ,(format nil "创建 ~A Provider

参数：
  API-URL  - API 基础 URL（默认 ~A）
  MODEL    - 默认模型（默认 ~A）
  API-KEY  - API 密钥（可从 ~A 环境变量读取）
  TIMEOUT  - 请求超时时间（秒，默认 ~A）

返回：
  ~A 实例"
                  (string-capitalize name-str)
                  default-url
                  default-model
                  api-key-env
                  timeout
                  class-name)
         (let ((key (or api-key
                        (uiop:getenv ,api-key-env))))
           ;; 检查 API 密钥
           ,@(when api-key-env
               `((when (and (null key)
                            (not (search "localhost" api-url)))
                   (cl-agent.core:signal-error
                    'cl-agent.core:missing-api-key-error
                    :message ,missing-key-msg
                    :config-key ,api-key-env))))

           (make-instance ',class-name
                          :name ,name
                          :api-url api-url
                          :default-model model
                          :chat-endpoint ,chat-endpoint
                          :stream-endpoint ,stream-endpoint
                          :api-key (or key "")
                          :timeout timeout)))

       ;; ============================================================
       ;; 3. llm-chat 方法
       ;; ============================================================
       (defmethod cl-agent.llm:llm-chat ((provider ,class-name) messages
                                          &key max-tokens
                                               (temperature 0.7)
                                               model
                                               tools
                                               system)
         ,(format nil "发送聊天请求到 ~A" (string-capitalize name-str))
         (let* (;; 构建请求体
                (request-body (funcall ,build-request-fn
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
                ;; 构建请求头
                (headers (funcall ,build-headers-fn provider))
                ;; 发送请求
                (response (cl-agent.llm:make-http-request
                           url
                           headers
                           (cl-agent.core:json-stringify request-body)
                           :timeout (cl-agent.llm:provider-timeout provider))))
           ;; 解析响应
           (funcall ,parse-response-fn response)))

       ;; ============================================================
       ;; 4. llm-available-p 方法
       ;; ============================================================
       (defmethod cl-agent.llm:llm-available-p ((provider ,class-name))
         ,(format nil "检查 ~A Provider 是否可用" (string-capitalize name-str))
         ,(if available-check-fn
              `(funcall ,available-check-fn provider)
              `(and (slot-boundp provider ',api-key-slot)
                    (provider-api-key provider)
                    (not (string= (provider-api-key provider) "")))))

       ;; 返回类名
       ',class-name)))

;;; ============================================================
;;; 通用辅助函数
;;; ============================================================

(defun make-keyword (str)
  "将字符串转换为关键字"
  (intern (string-upcase str) :keyword))

(defun format-tool-for-openai (tool)
  "将工具格式化为 OpenAI 格式

返回 hash-table 用于正确的 JSON 序列化"
  (let ((wrapper (make-hash-table :test 'equal))
        (function (make-hash-table :test 'equal))
        (name (getf tool :name))
        (description (getf tool :description))
        (schema (or (getf tool :input-schema)
                    (getf tool :parameters))))
    ;; 构建 function 对象
    (setf (gethash "name" function)
          (if (stringp name)
              name
              (string-downcase (string name))))
    (setf (gethash "description" function) (or description ""))
    (setf (gethash "parameters" function)
          (cond
            ((hash-table-p schema) schema)
            ((and (listp schema) (keywordp (first schema)))
             (cl-agent.kernel:schema-to-hash-table schema))
            (t (let ((empty (make-hash-table :test 'equal)))
                 (setf (gethash "type" empty) "object")
                 (setf (gethash "properties" empty) (make-hash-table :test 'equal))
                 (setf (gethash "required" empty) #())
                 empty))))
    ;; 构建 wrapper
    (setf (gethash "type" wrapper) "function")
    (setf (gethash "function" wrapper) function)
    wrapper))

(defun parse-tool-calls-openai-style (tool-calls)
  "解析 OpenAI 风格的工具调用（也适用于 OpenAI 兼容 API）

支持 hash-table 和 plist 两种输入格式"
  (loop for call in (if (vectorp tool-calls)
                        (coerce tool-calls 'list)
                        tool-calls)
        for id = (if (hash-table-p call)
                     (gethash "id" call)
                     (getf call :id))
        for function = (if (hash-table-p call)
                           (gethash "function" call)
                           (getf call :function))
        for name = (when function
                     (if (hash-table-p function)
                         (gethash "name" function)
                         (getf function :name)))
        for arguments-raw = (when function
                              (if (hash-table-p function)
                                  (gethash "arguments" function)
                                  (getf function :arguments)))
        ;; 解析 arguments（可能是 JSON 字符串或已解析的对象）
        for arguments = (cond
                          ((null arguments-raw) nil)
                          ((hash-table-p arguments-raw) arguments-raw)
                          ((stringp arguments-raw)
                           (handler-case
                               (cl-agent.core:json-parse arguments-raw)
                             (error () arguments-raw)))
                          (t arguments-raw))
        collect (list :id id
                      :name (when name (make-keyword (string-upcase name)))
                      :arguments arguments
                      :raw call)))

;;; ============================================================
;;; OpenAI 兼容的通用函数
;;; ============================================================

(defun build-openai-compatible-request (provider messages &key
                                                   max-tokens
                                                   temperature
                                                   model
                                                   tools
                                                   (stream nil))
  "构建 OpenAI 兼容的请求体

适用于 OpenAI、智谱 AI 等兼容 API"
  (let ((model-name (or model (cl-agent.llm:provider-default-model provider)))
        (body (make-hash-table :test 'equal)))
    ;; 基础字段
    (setf (gethash "model" body) model-name)
    (setf (gethash "messages" body)
          (convert-messages-for-openai messages))
    (setf (gethash "temperature" body) temperature)

    ;; 仅在启用流式时设置 stream: true
    ;; 不发送 stream: false 避免某些 API 的兼容性问题
    (when stream
      (setf (gethash "stream" body) t))

    ;; 可选字段
    (when max-tokens
      (setf (gethash "max_tokens" body) max-tokens))

    (when tools
      (setf (gethash "tools" body)
            (mapcar #'format-tool-for-openai tools)))

    body))

(defun convert-messages-for-openai (messages)
  "转换消息为 OpenAI 格式（返回 vector 用于 JSON 序列化）"
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
                      (convert-tool-calls-for-openai tool-calls)))
              (when tool-call-id
                (setf (gethash "tool_call_id" msg-hash) tool-call-id)))
         collect msg-hash)
   'vector))

(defun convert-tool-calls-for-openai (tool-calls)
  "转换工具调用为 OpenAI 格式"
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

(defun parse-openai-compatible-response (response)
  "解析 OpenAI 兼容的响应

返回标准化的响应 plist"
  (let* ((parsed (cl-agent.llm:parse-json-response response))
         (choices (gethash "choices" parsed))
         (first-choice (when choices (elt choices 0)))
         (message (when first-choice (gethash "message" first-choice)))
         (content (when message (gethash "content" message)))
         (tool-calls (when message (gethash "tool_calls" message)))
         (usage (gethash "usage" parsed)))

    (list :content (or content "")
          :tool-calls (when tool-calls
                        (parse-tool-calls-openai-style tool-calls))
          :usage (list :prompt-tokens (when usage (gethash "prompt_tokens" usage))
                       :completion-tokens (when usage (gethash "completion_tokens" usage))
                       :total-tokens (when usage (gethash "total_tokens" usage)))
          :model (gethash "model" parsed)
          :raw-response parsed)))

(defun build-bearer-auth-headers (provider)
  "构建 Bearer Token 认证头"
  (let ((api-key (provider-api-key provider)))
    `(("Content-Type" . "application/json")
      ("Authorization" . ,(format nil "Bearer ~A" api-key)))))
