;;;; client.lisp
;;;; CL-Agent - 统一 LLM 客户端接口
;;;;
;;;; 概述：
;;;;   提供统一的 LLM 客户端接口，支持多个提供商
;;;;
;;;; 特性：
;;;;   - 多提供商支持（Anthropic、OpenAI、Ollama、智谱 AI）
;;;;   - 统一的 API 接口
;;;;   - 自动重试和错误处理
;;;;   - 工具调用支持
;;;;
;;;; 使用示例：
;;;;   ;; 创建客户端
;;;;   (let ((client (make-client :provider :openai)))
;;;;     ;; 简单聊天
;;;;     (chat-simple client "Hello!")
;;;;     ;; 多轮对话
;;;;     (chat client '((:user . "Hi") (:assistant . "Hello!") (:user . "How are you?"))))

(in-package :cl-agent.llm)

;;; ============================================================
;;; 客户端类（CLOS 重构）
;;; ============================================================

(defclass client ()
  ((provider
    :initarg :provider
    :accessor client-provider
    :documentation "提供商实例（base-provider 子类）")

   (api-key
    :initarg :api-key
    :accessor client-api-key
    :documentation "API 密钥")

   (model
    :initarg :model
    :accessor client-model
    :documentation "模型名称")

   (base-url
    :initarg :base-url
    :accessor client-base-url
    :documentation "基础 URL")

   (max-tokens
    :initarg :max-tokens
    :accessor client-max-tokens
    :documentation "最大 token 数")

   (temperature
    :initarg :temperature
    :accessor client-temperature
    :documentation "默认温度"))

  (:documentation "LLM 客户端

槽位说明：
  PROVIDER    - 提供商实例（base-provider 子类）
  API-KEY     - API 密钥
  MODEL       - 模型名称（可选，覆盖提供商默认值）
  BASE-URL    - 基础 URL（可选，覆盖提供商默认值）
  MAX-TOKENS  - 最大 token 数（可选）
  TEMPERATURE - 默认温度（可选）"))

;;; ============================================================
;;; 客户端工厂
;;; ============================================================

(defun make-client (&key
                     (provider :anthropic)
                     (model nil)
                     (api-key nil)
                     (base-url nil)
                     (max-tokens 4096)
                     (temperature 0.7))
  "创建 LLM 客户端

参数：
  PROVIDER    - 提供商类型（:anthropic, :openai, :ollama, :zhipu）或提供商实例
  MODEL       - 模型名称（可选）
  API-KEY     - API 密钥（可选，从环境变量读取）
  BASE-URL    - 基础 URL（可选）
  MAX-TOKENS  - 最大 token 数（可选，默认 4096）
  TEMPERATURE - 默认温度（可选，默认 0.7）

返回：
  客户端实例

示例：
  ;; 使用默认配置
  (make-client)

  ;; 指定提供商和模型
  (make-client :provider :openai
              :model \"gpt-4o-mini\")

  ;; 使用 Ollama
  (make-client :provider :ollama
              :base-url \"http://localhost:11434\"
              :model \"llama3.2\")

  ;; 使用智谱 AI
  (make-client :provider :zhipu
              :model \"glm-4-flash\")"

  ;; 1. 创建或使用提供商实例
  (let ((prov (if (typep provider 'base-provider)
                  provider
                  (apply #'make-provider provider
                         (append
                          (when base-url (list :api-url base-url))
                          (when api-key (list :api-key api-key)))))))

    ;; 2. 获取 API 密钥（如果提供商需要）
    (let ((key (get-api-key-for-provider prov api-key)))

      ;; 3. 创建客户端（使用 CLOS）
      (make-instance 'client
                     :provider prov
                     :api-key key
                     :model (or model (provider-default-model prov))
                     :base-url (or base-url (provider-api-url prov))
                     :max-tokens max-tokens
                     :temperature temperature))))

(defun get-api-key-for-provider (provider provided-key)
  "获取提供商的 API 密钥

参数：
  PROVIDER     - 提供商实例
  PROVIDED-KEY - 用户提供的密钥（可选）

返回：
  API 密钥字符串

说明：
  - Ollama 不需要 API 密钥
  - 其他提供商按优先级：用户提供 > 环境变量"
  (let ((provider-type (provider-name provider)))
    (case provider-type
      (:ollama
       ;; Ollama 不需要 API 密钥
       "dummy")
      (otherwise
       ;; 其他提供商需要 API 密钥
       (or provided-key
           (cl-agent.core:get-env
            (ecase provider-type
              (:anthropic "ANTHROPIC_API_KEY")
              (:openai "OPENAI_API_KEY")
              (:zhipu "ZHIPU_API_KEY"))))))))

;;; ============================================================
;;; 核心聊天 API
;;; ============================================================

(defun chat (client messages &key
                            (system nil)
                            (tools nil)
                            (temperature nil)
                            (max-tokens nil)
                            (retry 3)
                            (retry-delay 1.0)
                            (retry-backoff 2.0))
  "发送聊天请求到 LLM

参数：
  CLIENT        - 客户端实例
  MESSAGES      - 消息列表，格式：((role . content) ...) 或 ((:role ... :content ...) ...)
  SYSTEM        - 系统提示（可选）
  TOOLS         - 工具定义列表（可选）
  TEMPERATURE   - 温度参数（可选，使用客户端默认值）
  MAX-TOKENS    - 最大 token 数（可选，使用客户端默认值）
  RETRY         - 重试次数（可选，默认 3）
  RETRY-DELAY   - 初始重试延迟（秒，默认 1.0）
  RETRY-BACKOFF - 重试延迟倍数（默认 2.0，指数退避）

返回：
  llm-response 对象（包含 content、model、usage 等属性）

错误处理：
  - 自动重试临时错误（网络错误、速率限制、服务器错误）
  - 发出 llm-error 表示永久错误

示例：
  (let ((client (make-client)))
    ;; 简单对话
    (chat client '((:user . \"Hello!\")))

    ;; 带系统提示
    (chat client '((:user . \"Write a poem\"))
          :system \"You are a poet.\")

    ;; 带工具
    (chat client '((:user . \"What's the weather?\"))
          :tools *weather-tools*)

    ;; 自定义重试策略
    (chat client '((:user . \"Hello\"))
          :retry 5
          :retry-delay 2.0))"

  (let* ((provider (client-provider client))
         (temp (or temperature (client-temperature client)))
         (tokens (or max-tokens (client-max-tokens client)))
         (normalized-messages (normalize-messages messages)))

    ;; 使用重试逻辑
    (chat-with-retry provider normalized-messages
                     :temperature temp
                     :max-tokens tokens
                     :model (client-model client)
                     :tools tools
                     :system system
                     :max-retries retry
                     :initial-delay retry-delay
                     :backoff-multiplier retry-backoff)))

(defun chat-with-retry (provider messages &key
                                           temperature
                                           max-tokens
                                           model
                                           tools
                                           system
                                           (max-retries 3)
                                           (initial-delay 1.0)
                                           (backoff-multiplier 2.0))
  "带重试逻辑的聊天请求

参数：
  PROVIDER           - 提供商实例
  MESSAGES           - 消息列表
  TEMPERATURE        - 温度
  MAX-TOKENS         - 最大 token 数
  MODEL              - 模型名称
  TOOLS              - 工具列表
  SYSTEM             - 系统提示
  MAX-RETRIES        - 最大重试次数
  INITIAL-DELAY      - 初始延迟（秒）
  BACKOFF-MULTIPLIER - 退避倍数

返回：
  响应 plist"
  (let ((attempt 0)
        (delay initial-delay))
    (loop
      (handler-case
          (return (llm-chat provider messages
                           :temperature temperature
                           :max-tokens max-tokens
                           :model model
                           :tools tools
                           :system system))
        (error (condition)
          (incf attempt)
          (if (and (< attempt max-retries)
                   (retryable-error-p condition))
              (progn
                ;; 记录重试信息
                (cl-agent.core:log-warn
                 "LLM request failed (attempt ~A/~A): ~A. Retrying in ~,1F seconds..."
                 attempt max-retries condition delay)
                ;; 等待后重试
                (sleep delay)
                ;; 增加延迟（指数退避）
                (setf delay (* delay backoff-multiplier)))
              ;; 不可重试或超过重试次数
              (progn
                (cl-agent.core:log-error
                 "LLM request failed after ~A attempts: ~A"
                 attempt condition)
                (error condition))))))))

(defun retryable-error-p (condition)
  "检查错误是否可重试

参数：
  CONDITION - 错误条件

返回：
  T 如果可重试，NIL 否则

可重试的错误类型：
  - 网络/连接错误
  - 速率限制（429）
  - 服务器错误（5xx）
  - 超时错误"
  (typecase condition
    ;; HTTP 错误
    (cl-agent.http:http-error
     (let ((status (cl-agent.http:http-error-status condition)))
       (or (null status)                  ; 连接错误
           (= status 429)                 ; 速率限制
           (>= status 500))))            ; 服务器错误

    ;; API 错误（包括 LLM 错误，检查状态码）
    (cl-agent.core:api-error
     (let ((status (cl-agent.core:api-status-code condition)))
       (or (null status)
           (= status 429)
           (>= status 500))))

    ;; 超时错误
    (cl-agent.core:timeout-error t)

    ;; 其他错误 - 默认不重试
    (otherwise nil)))

(defun normalize-messages (messages)
  "标准化消息格式

参数：
  MESSAGES - 消息列表

返回：
  标准化的消息列表（plist 格式）

支持的输入格式：
  - cons: (role . content)  例如: (:user . \"hello\") 或 (\"user\" . \"hello\")
  - plist: (:role role :content content)  例如: (:role :user :content \"hello\")"
  (mapcar (lambda (msg)
            (cond
              ;; 判断是否是 plist 格式：检查 cdr 是否是列表
              ((and (consp msg) (consp (cdr msg)))
               ;; plist 格式: (:role :user :content "hello")
               msg)
              ;; 判断是否是 cons 格式：cdr 不是列表
              ((and (consp msg) (not (consp (cdr msg))))
               ;; cons 格式: (:user . "hello") 或 ("user" . "hello")
               (list :role (car msg) :content (cdr msg)))
              ;; 其他情况，返回原样
              (t msg)))
          messages))

(defun chat-generic (client messages &key system tools temperature max-tokens)
  "通用聊天实现（回退方案）

参数：
  CLIENT      - 客户端实例
  MESSAGES    - 消息列表
  SYSTEM      - 系统提示
  TOOLS       - 工具列表
  TEMPERATURE - 温度
  MAX-TOKENS  - 最大 token 数

返回：
  响应 plist"
  (let* ((provider (client-provider client))
         ;; 构建请求体
         (request-body (build-chat-request-body
                        provider
                        messages
                        :system system
                        :tools (when tools (convert-tools-to-provider tools provider))
                        :temperature temperature
                        :max-tokens max-tokens
                        :stream nil))
         ;; 构建 URL
         (request-url (concatenate 'string
                                   (client-base-url client)
                                   (provider-chat-endpoint provider)))
         ;; 构建请求头
         (request-headers (provider-headers provider (client-api-key client))))

    ;; 发送请求
    (handler-case
        (let* ((http-response
                 (cl-agent.http:http-post request-url
                                          :body (cl-agent.core:json-stringify request-body)
                                          :headers request-headers
                                          :timeout 120
                                          :parse-json nil))
               (response-body (cl-agent.http:http-response-body http-response))
               ;; 解析响应
               (parsed-response
                 (if (stringp response-body)
                     (cl-agent.core:json-parse response-body)
                     response-body)))

          (parse-chat-response parsed-response provider))

      ;; HTTP 错误处理
      (cl-agent.http:http-error (condition)
        (cl-agent.core:signal-error 'cl-agent.core:llm-error
                                    :message (format nil "HTTP 请求失败: ~A"
                                                     (cl-agent.http:http-error-status condition))
                                    :provider (provider-name provider)
                                    :status-code (cl-agent.http:http-error-status condition)
                                    :url request-url
                                    :cause condition))

      (error (condition)
        (cl-agent.core:signal-error 'cl-agent.core:llm-error
                                    :message (format nil "未知错误: ~A" condition)
                                    :provider (provider-name provider)
                                    :url request-url
                                    :cause condition)))))

;;; ============================================================
;;; 便捷 API
;;; ============================================================

(defun chat-simple (client prompt &key (system nil) (temperature nil))
  "简化的聊天接口

参数：
  CLIENT      - 客户端实例
  PROMPT      - 用户提示
  SYSTEM      - 系统提示（可选）
  TEMPERATURE - 温度（可选）

返回：
  响应内容字符串

示例：
  (chat-simple *client* \"Explain recursion in Lisp\")
  (chat-simple *client* \"Write a poem\"
              :system \"You are a poet\")"
  (let ((response (chat client `((:user . ,prompt))
                       :system system
                       :temperature temperature)))
    (cl-agent.core:llm-response-content response)))

(defun chat-with-tools (client prompt tools &key (system nil))
  "带工具的聊天

参数：
  CLIENT - 客户端实例
  PROMPT - 用户提示
  TOOLS  - 工具列表
  SYSTEM - 系统提示（可选）

返回：
  llm-response 对象，可能包含工具调用

示例：
  (chat-with-tools *client* \"Search for AI news\"
                   *search-tools*)"
  (chat client `((:user . ,prompt))
        :tools tools
        :system system))

(defun chat-multi-turn (client conversation &key (system nil))
  "多轮对话

参数：
  CLIENT       - 客户端实例
  CONVERSATION - 消息历史，格式：((role . content) ...)
  SYSTEM       - 系统提示（可选）

返回：
  响应内容字符串

示例：
  (chat-multi-turn *client*
                   '((:user . \"Hi\")
                     (:assistant . \"Hello!\")
                     (:user . \"How are you?\")))"
  (let ((response (chat client conversation :system system)))
    (getf response :content)))

;;; ============================================================
;;; 客户端查询
;;; ============================================================

(defun client-provider-name (client)
  "获取客户端的提供商名称"
  (provider-name (client-provider client)))

(defun client-model-name (client)
  "获取客户端的模型名称"
  (client-model client))

(defun (setf client-model-name) (new-model client)
  "设置客户端的模型名称"
  (setf (client-model client) new-model)
  new-model)

;;; ============================================================
;;; 批量处理
;;; ============================================================

(defun batch-chat (client prompts &key (system nil) (parallel nil))
  "批量处理多个聊天请求

参数：
  CLIENT   - 客户端实例
  PROMPTS  - 提示列表
  SYSTEM   - 系统提示（可选）
  PARALLEL - 是否并行处理（可选，目前不支持）

返回：
  响应列表

示例：
  (batch-chat *client*
              '(\"What is AI?\" \"What is ML?\" \"What is DL?\"))"
  (declare (ignore parallel))
  ;; 串行处理（并行处理待实现）
  (mapcar (lambda (prompt)
            (chat-simple client prompt :system system))
          prompts))

;;; ============================================================
;;; Token 计数和成本估算
;;; ============================================================

(defun count-tokens-for-client (client text)
  "为特定客户端计算 token 数

参数：
  CLIENT - 客户端实例
  TEXT   - 输入文本

返回：
  估算的 token 数"
  (count-tokens text (client-provider-name client)))

(defun estimate-cost (client input-tokens &optional (output-tokens 0))
  "估算请求成本

参数：
  CLIENT        - 客户端实例
  INPUT-TOKENS  - 输入 token 数
  OUTPUT-TOKENS - 输出 token 数（可选）

返回：
  估算成本（美元）

注意：
  这是基于公开定价的粗略估算
  实际成本可能有所不同"
  (let ((provider (client-provider-name client))
        (input-price 0.0)
        (output-price 0.0))
    (ecase provider
      (:anthropic
       (setf input-price 0.003)    ; $3/1M tokens (input)
       (setf output-price 0.015))  ; $15/1M tokens (output)
      (:openai
       (setf input-price 0.005)    ; GPT-4o: $5/1M tokens
       (setf output-price 0.015))  ; $15/1M tokens
      (:ollama
       ;; Ollama 是免费的
       (setf input-price 0.0)
       (setf output-price 0.0))
      (:zhipu
       ;; 智谱 AI 定价（人民币转美元估算）
       (setf input-price 0.001)
       (setf output-price 0.002)))
    (+ (* input-tokens input-price 1e-6)
       (* output-tokens output-price 1e-6))))
