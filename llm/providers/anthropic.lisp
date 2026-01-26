;;;; anthropic.lisp
;;;; CL-Agent - Anthropic Claude 提供商实现
;;;;
;;;; 概述：
;;;;   实现 Anthropic Claude 系列的 LLM 提供商接口
;;;;
;;;; 支持的模型：
;;;;   - claude-sonnet-4-20250514 (Claude Sonnet 4)
;;;;   - claude-3-5-sonnet-20241022 (Claude 3.5 Sonnet)
;;;;   - claude-3-5-haiku-20241022 (Claude 3.5 Haiku)
;;;;   - claude-3-opus-20240229 (Claude 3 Opus)
;;;;
;;;; API 特点：
;;;;   - 使用 x-api-key 请求头认证
;;;;   - 需要 anthropic-version 请求头
;;;;   - max_tokens 是必需参数
;;;;   - system 消息单独传递，不在 messages 数组中

(in-package :cl-agent.llm.providers)

;;; ============================================================
;;; Anthropic 提供商类
;;; ============================================================

(defclass anthropic-provider (cl-agent.llm:base-provider)
  ((api-key :initarg :api-key
            :reader anthropic-provider-api-key
            :documentation "Anthropic API 密钥")
   (anthropic-version :initarg :anthropic-version
                      :initform "2023-06-01"
                      :reader anthropic-provider-version
                      :documentation "Anthropic API 版本"))
  (:documentation "Anthropic Claude 提供商

支持 Claude 系列模型，包括 Claude Sonnet 4、Claude 3.5 和 Claude 3"))

;;; ============================================================
;;; 工厂函数
;;; ============================================================

(defun make-anthropic-provider (&key
                                  (api-url "https://api.anthropic.com")
                                  (model "claude-sonnet-4-20250514")
                                  api-key
                                  (anthropic-version "2023-06-01")
                                  (timeout 120))
  "创建 Anthropic 提供商

参数：
  API-URL           - API 基础 URL（可选，默认官方 API）
  MODEL             - 默认模型（可选，默认 claude-sonnet-4-20250514）
  API-KEY           - API 密钥（可选，从环境变量读取）
  ANTHROPIC-VERSION - API 版本（可选，默认 2023-06-01）
  TIMEOUT           - 请求超时时间（可选，默认 120 秒）

返回：
  Anthropic 提供商实例

示例：
  ;; 使用默认配置
  (make-anthropic-provider)

  ;; 指定模型和 API 密钥
  (make-anthropic-provider :model \"claude-3-5-sonnet-20241022\"
                           :api-key \"sk-ant-...\")

  ;; 使用较新的 API 版本
  (make-anthropic-provider :anthropic-version \"2024-01-01\")"

  ;; 获取 API 密钥
  (let ((key (or api-key
                 (uiop:getenv "ANTHROPIC_API_KEY"))))
    (when (null key)
      (cl-agent.core:signal-error 'cl-agent.core:missing-api-key-error
                                  :message "Anthropic API 密钥未设置，请设置 ANTHROPIC_API_KEY 环境变量"
                                  :config-key "ANTHROPIC_API_KEY"))

    (make-instance 'anthropic-provider
                   :name :anthropic
                   :api-url api-url
                   :default-model model
                   :chat-endpoint "/v1/messages"
                   :stream-endpoint "/v1/messages"
                   :api-key key
                   :anthropic-version anthropic-version
                   :timeout timeout)))

;;; ============================================================
;;; 协议实现
;;; ============================================================

(defmethod cl-agent.llm:llm-chat ((provider anthropic-provider) messages
                                   &key
                                   (max-tokens 4096)
                                   (temperature 0.7)
                                   model
                                   tools
                                   system)
  "发送聊天请求到 Anthropic

参数：
  PROVIDER    - Anthropic 提供商实例
  MESSAGES    - 消息列表
  MAX-TOKENS  - 最大 token 数（必需，默认 4096）
  TEMPERATURE - 温度参数（可选，默认 0.7）
  MODEL       - 模型名称（可选）
  TOOLS       - 工具列表（可选）
  SYSTEM      - 系统提示（可选）

返回：
  响应 plist"

  ;; 1. 构建请求体
  (let* ((request-body (build-anthropic-request-body
                        provider
                        messages
                        :max-tokens max-tokens
                        :temperature temperature
                        :model model
                        :tools tools
                        :system system))

         ;; 2. 构建 URL
         (url (cl-agent.llm:build-api-url
              provider
              (cl-agent.llm:base-provider-chat-endpoint provider)))

         ;; 3. 构建请求头
         (headers (build-anthropic-headers provider))

         ;; 4. 发送请求
         (response (cl-agent.llm:make-http-request
                    url
                    headers
                    (cl-agent.core:json-stringify request-body)
                    :timeout (cl-agent.llm:base-provider-timeout provider))))

    ;; 5. 解析响应
    (parse-anthropic-response response)))

(defmethod cl-agent.llm:llm-available-p ((provider anthropic-provider))
  "检查 Anthropic 提供商是否可用"
  (and (slot-boundp provider 'api-key)
       (anthropic-provider-api-key provider)
       (not (string= (anthropic-provider-api-key provider) ""))))

;;; ============================================================
;;; 请求构建
;;; ============================================================

(defun build-anthropic-request-body (provider messages &key
                                               max-tokens
                                               temperature
                                               model
                                               tools
                                               system)
  "构建 Anthropic API 请求体

参数：
  PROVIDER    - 提供商实例
  MESSAGES    - 消息列表
  MAX-TOKENS  - 最大 token 数（必需）
  TEMPERATURE - 温度
  MODEL       - 模型名称
  TOOLS       - 工具列表
  SYSTEM      - 系统提示

返回：
  请求体 hash-table（JSON 格式）"

  (let* ((model-name (or model (cl-agent.llm:base-provider-default-model provider)))
         ;; 分离系统消息和其他消息
         (parsed-messages (parse-messages-for-anthropic messages))
         (system-prompt (or system (getf parsed-messages :system)))
         (converted-messages (getf parsed-messages :messages))
         (body (make-hash-table :test 'equal)))

    ;; 构建基础请求体
    (setf (gethash "model" body) model-name)
    (setf (gethash "max_tokens" body) max-tokens)
    (setf (gethash "messages" body) (coerce converted-messages 'vector))

    ;; 添加 temperature
    (when temperature
      (setf (gethash "temperature" body) temperature))

    ;; 添加系统提示（Anthropic 使用单独的 system 参数）
    (when system-prompt
      (setf (gethash "system" body) system-prompt))

    ;; 添加工具
    (when tools
      (setf (gethash "tools" body) (coerce (convert-tools-to-anthropic tools) 'vector)))

    body))

(defun parse-messages-for-anthropic (messages)
  "解析消息，分离系统消息，处理工具调用消息

参数：
  MESSAGES - 消息列表

返回：
  plist 包含 :system 和 :messages

说明：
  处理以下消息格式：
  1. 普通消息：(:role :user :content \"...\")
  2. assistant 工具调用：(:role :assistant :content \"...\" :tool-calls (...))
  3. 工具结果：(:role :tool :tool-call-id \"...\" :content \"...\")

  Anthropic API 要求：
  - assistant 工具调用消息的 content 为 tool_use 块数组
  - 工具结果作为 user 消息的 tool_result 块发送"
  (let ((system-prompt nil)
        (other-messages '())
        ;; 收集连续的 tool result 消息，合并为一个 user 消息
        (pending-tool-results nil))

    (labels ((flush-tool-results ()
               "将累积的 tool results 合并为一个 user 消息"
               (when pending-tool-results
                 (let ((msg-hash (make-hash-table :test 'equal))
                       (content-blocks
                         (mapcar (lambda (tr)
                                   (let ((block (make-hash-table :test 'equal)))
                                     (setf (gethash "type" block) "tool_result")
                                     (setf (gethash "tool_use_id" block) (getf tr :tool-call-id))
                                     (setf (gethash "content" block) (or (getf tr :content) ""))
                                     block))
                                 (nreverse pending-tool-results))))
                   (setf (gethash "role" msg-hash) "user")
                   (setf (gethash "content" msg-hash)
                         (coerce content-blocks 'vector))
                   (push msg-hash other-messages))
                 (setf pending-tool-results nil)))

             (build-tool-use-content (tool-calls text-content)
               "构建包含 tool_use 块的 content 数组"
               (let ((blocks nil))
                 ;; 添加文本块（如果有）
                 (when (and text-content (not (string= text-content "")))
                   (let ((text-block (make-hash-table :test 'equal)))
                     (setf (gethash "type" text-block) "text")
                     (setf (gethash "text" text-block) text-content)
                     (push text-block blocks)))
                 ;; 添加 tool_use 块
                 (dolist (tc tool-calls)
                   (let ((tc-block (make-hash-table :test 'equal))
                         (tc-name (getf tc :name))
                         (tc-id (getf tc :id))
                         (tc-args (getf tc :arguments)))
                     (setf (gethash "type" tc-block) "tool_use")
                     (setf (gethash "id" tc-block) (or tc-id (cl-agent.core:generate-uuid)))
                     (setf (gethash "name" tc-block)
                           (if (keywordp tc-name)
                               (string-downcase (symbol-name tc-name))
                               (string-downcase (string tc-name))))
                     (setf (gethash "input" tc-block)
                           (cond
                             ((hash-table-p tc-args) tc-args)
                             ((and (listp tc-args) (keywordp (first tc-args)))
                              ;; plist → hash-table
                              (let ((ht (make-hash-table :test 'equal)))
                                (loop for (k v) on tc-args by #'cddr
                                      do (setf (gethash (string-downcase (symbol-name k)) ht) v))
                                ht))
                             (t (make-hash-table :test 'equal))))
                     (push tc-block blocks)))
                 (coerce (nreverse blocks) 'vector))))

      (dolist (msg messages)
        (let ((role (if (and (consp msg) (not (consp (cdr msg))))
                        (car msg)
                        (getf msg :role)))
              (content (if (and (consp msg) (not (consp (cdr msg))))
                           (cdr msg)
                           (getf msg :content)))
              (tool-calls (when (consp (cdr msg)) (getf msg :tool-calls)))
              (tool-call-id (when (consp (cdr msg)) (getf msg :tool-call-id))))
          (cond
            ;; 系统消息
            ((member role '(:system "system" system) :test #'equalp)
             (flush-tool-results)
             (if system-prompt
                 (setf system-prompt (concatenate 'string system-prompt "\n"
                                                  (if (stringp content) content "")))
                 (setf system-prompt (if (stringp content) content ""))))

            ;; 工具结果消息 → 累积后合并发送
            ((member role '(:tool "tool" tool) :test #'equalp)
             (push (list :tool-call-id (or tool-call-id "unknown")
                         :content (if (stringp content) content
                                      (format nil "~S" content)))
                   pending-tool-results))

            ;; assistant 带 tool-calls
            ((and (member role '(:assistant "assistant" assistant) :test #'equalp)
                  tool-calls)
             (flush-tool-results)
             (let ((msg-hash (make-hash-table :test 'equal)))
               (setf (gethash "role" msg-hash) "assistant")
               (setf (gethash "content" msg-hash)
                     (build-tool-use-content tool-calls
                                             (if (stringp content) content "")))
               (push msg-hash other-messages)))

            ;; 普通消息
            (t
             (flush-tool-results)
             (let ((msg-hash (make-hash-table :test 'equal)))
               (setf (gethash "role" msg-hash) (convert-role-to-anthropic role))
               (setf (gethash "content" msg-hash)
                     (if (stringp content) content
                         (format nil "~S" content)))
               (push msg-hash other-messages))))))

      ;; 刷新剩余的 tool results
      (flush-tool-results))

    (list :system system-prompt
          :messages (nreverse other-messages))))

(defun convert-role-to-anthropic (role)
  "转换角色为 Anthropic 格式

参数：
  ROLE - 角色标识（关键字或字符串）

返回：
  Anthropic 格式的角色字符串"
  (let ((role-str (string-downcase (string role))))
    (cond
      ((string= role-str "user") "user")
      ((string= role-str "assistant") "assistant")
      ((string= role-str "human") "user")
      ((string= role-str "ai") "assistant")
      (t "user"))))

(defun convert-tools-to-anthropic (tools)
  "转换工具为 Anthropic 格式

参数：
  TOOLS - 工具列表（每个工具为 plist: (:name ... :description ... :input-schema ...)）

返回：
  Anthropic 格式的工具列表（hash-table list）

说明：
  Anthropic 工具格式：
  {
    \"name\": \"tool_name\",
    \"description\": \"Tool description\",
    \"input_schema\": {
      \"type\": \"object\",
      \"properties\": {...},
      \"required\": [...]
    }
  }"
  (loop for tool in tools
        collect (let ((tool-hash (make-hash-table :test 'equal))
                      (schema-raw (or (getf tool :input-schema)
                                      (getf tool :parameters))))
                  (setf (gethash "name" tool-hash) (getf tool :name))
                  (setf (gethash "description" tool-hash) (getf tool :description))
                  (setf (gethash "input_schema" tool-hash)
                        (cond
                          ;; 已经是 hash-table（可直接序列化）
                          ((hash-table-p schema-raw) schema-raw)
                          ;; plist schema（来自 params->json-schema）→ 转换为 hash-table
                          ((and (consp schema-raw) (keywordp (first schema-raw)))
                           (cl-agent.kernel:schema-to-hash-table schema-raw))
                          ;; 默认空 schema
                          (t (let ((default-schema (make-hash-table :test 'equal)))
                               (setf (gethash "type" default-schema) "object")
                               (setf (gethash "properties" default-schema) (make-hash-table :test 'equal))
                               (setf (gethash "required" default-schema) #())
                               default-schema))))
                  tool-hash)))

(defun build-anthropic-headers (provider)
  "构建 Anthropic 请求头

参数：
  PROVIDER - 提供商实例

返回：
  请求头 alist

说明：
  - 标准 Anthropic 使用 x-api-key 和 anthropic-version 请求头"
  (let ((api-key (anthropic-provider-api-key provider))
        (version (anthropic-provider-version provider)))
    `(("Content-Type" . "application/json")
      ("x-api-key" . ,api-key)
      ("anthropic-version" . ,version))))
;;; ============================================================
;;; 响应解析
;;; ============================================================

(defun parse-anthropic-response (response)
  "解析 Anthropic API 响应

参数：
  RESPONSE - HTTP 响应

返回：
  标准化的响应 plist

说明：
  Anthropic 响应格式：
  {
    \"id\": \"msg_...\",
    \"type\": \"message\",
    \"role\": \"assistant\",
    \"content\": [{\"type\": \"text\", \"text\": \"...\"}],
    \"model\": \"claude-...\",
    \"stop_reason\": \"end_turn\",
    \"usage\": {
      \"input_tokens\": N,
      \"output_tokens\": N
    }
  }"

  (let* ((parsed (cl-agent.llm:parse-json-response response))
         ;; 从 hash-table 中提取值（使用字符串键）
         (content-blocks (if (hash-table-p parsed)
                             (gethash "content" parsed)
                             (getf parsed :content)))
         (content (extract-text-content content-blocks))
         (tool-use (extract-tool-use content-blocks))
         (usage (if (hash-table-p parsed)
                    (gethash "usage" parsed)
                    (getf parsed :usage))))

    ;; 构建标准响应
    (list :content content
          :tool-calls (when tool-use
                       (parse-anthropic-tool-use tool-use))
          :usage (list :prompt-tokens (if (hash-table-p usage)
                                          (gethash "input_tokens" usage)
                                          (getf usage :input_tokens))
                      :completion-tokens (if (hash-table-p usage)
                                             (gethash "output_tokens" usage)
                                             (getf usage :output_tokens))
                      :total-tokens (+ (or (if (hash-table-p usage)
                                               (gethash "input_tokens" usage)
                                               (getf usage :input_tokens)) 0)
                                       (or (if (hash-table-p usage)
                                               (gethash "output_tokens" usage)
                                               (getf usage :output_tokens)) 0)))
          :model (if (hash-table-p parsed)
                     (gethash "model" parsed)
                     (getf parsed :model))
          :stop-reason (if (hash-table-p parsed)
                           (gethash "stop_reason" parsed)
                           (getf parsed :stop_reason))
          :raw-response parsed)))

(defun extract-text-content (content-blocks)
  "从内容块中提取文本

参数：
  CONTENT-BLOCKS - Anthropic 内容块列表（vector、list、hash-table 或 string）

返回：
  文本字符串"
  ;; 处理各种可能的格式
  (cond
    ;; nil
    ((null content-blocks) "")

    ;; 直接是字符串
    ((stringp content-blocks) content-blocks)

    ;; 单个 hash-table（单个内容块）
    ((hash-table-p content-blocks)
     (let ((type (gethash "type" content-blocks))
           (text (gethash "text" content-blocks)))
       (if (string= type "text")
           (or text "")
           "")))

    ;; vector 或 list
    (t
     (let ((texts '())
           (blocks (if (vectorp content-blocks)
                       (coerce content-blocks 'list)
                       content-blocks)))
       (dolist (block blocks)
         (let ((type (if (hash-table-p block)
                         (gethash "type" block)
                         (getf block :type)))
               (text (if (hash-table-p block)
                         (gethash "text" block)
                         (getf block :text))))
           (when (and type (string= type "text"))
             (push text texts))))
       (if (= (length texts) 1)
           (first texts)
           (format nil "~{~A~^~%~}" (nreverse texts)))))))

(defun extract-tool-use (content-blocks)
  "从内容块中提取工具使用

参数：
  CONTENT-BLOCKS - Anthropic 内容块列表（vector、list、hash-table 或 string）

返回：
  工具使用块列表"
  ;; 处理各种可能的格式
  (cond
    ;; nil 或字符串 - 无工具使用
    ((or (null content-blocks) (stringp content-blocks))
     nil)

    ;; 单个 hash-table（单个内容块）
    ((hash-table-p content-blocks)
     (let ((type (gethash "type" content-blocks)))
       (if (and type (string= type "tool_use"))
           (list content-blocks)
           nil)))

    ;; vector 或 list
    (t
     (let ((blocks (if (vectorp content-blocks)
                       (coerce content-blocks 'list)
                       content-blocks)))
       (loop for block in blocks
             for type = (if (hash-table-p block)
                            (gethash "type" block)
                            (getf block :type))
             when (and type (string= type "tool_use"))
             collect block)))))

(defun parse-anthropic-tool-use (tool-blocks)
  "解析 Anthropic 工具使用

参数：
  TOOL-BLOCKS - 工具使用块列表

返回：
  标准化的工具调用列表"
  (loop for block in tool-blocks
        collect (list :id (if (hash-table-p block)
                              (gethash "id" block)
                              (getf block :id))
                      :name (let ((name (if (hash-table-p block)
                                            (gethash "name" block)
                                            (getf block :name))))
                             (intern (string-upcase name) :keyword))
                      :arguments (if (hash-table-p block)
                                     (gethash "input" block)
                                     (getf block :input))
                      :raw block)))

;;; ============================================================
;;; 辅助函数
;;; ============================================================

(defun anthropic-model-context-window (model)
  "获取模型的上下文窗口大小

参数：
  MODEL - 模型名称

返回：
  上下文窗口 token 数"
  (cond
    ((search "claude-3-opus" model) 200000)
    ((search "claude-3-5-sonnet" model) 200000)
    ((search "claude-3-5-haiku" model) 200000)
    ((search "claude-sonnet-4" model) 200000)
    ((search "claude-3-sonnet" model) 200000)
    ((search "claude-3-haiku" model) 200000)
    (t 100000)))  ; 默认值

(defun anthropic-model-max-output (model)
  "获取模型的最大输出 token 数

参数：
  MODEL - 模型名称

返回：
  最大输出 token 数"
  (cond
    ((search "claude-sonnet-4" model) 16384)
    ((search "claude-3-5" model) 8192)
    ((search "claude-3-opus" model) 4096)
    (t 4096)))  ; 默认值
