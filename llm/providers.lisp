;;;; providers.lisp
;;;; CL-Agent - LLM 提供商工厂和配置
;;;;
;;;; 概述：
;;;;   提供 LLM 提供商的工厂函数和全局配置
;;;;
;;;; 支持的提供商：
;;;;   - Anthropic Claude
;;;;   - OpenAI GPT
;;;;   - Ollama（本地模型）
;;;;   - 智谱 AI GLM
;;;;
;;;; 设计说明：
;;;;   - 所有提供商都使用 CLOS 类实现（定义在 providers/ 目录）
;;;;   - 本文件提供统一的工厂函数和配置
;;;;   - 移除了旧的 defstruct 实现，统一使用 CLOS

(in-package :cl-agent/llm)

;;; ============================================================
;;; 注：这里曾有一组 *anthropic-api-url* / *default-anthropic-model*
;;; 之类的全局配置变量，但没有任何代码读取它们——端点与默认模型由各
;;; make-*-provider 自行持有。它们还已经过时（*default-anthropic-model*
;;; 停留在 claude-3-5-sonnet-20241022，而 provider 实际默认
;;; claude-sonnet-4-20250514），留着只会让人以为改它有用。已删除。
;;; ============================================================
;;; 注：这里曾有 make-anthropic-provider / make-ollama-provider /
;;; make-openai-provider / make-zhipu-provider 四个手写委托函数，
;;; 函数体都只是 (apply #'cl-agent/llm/providers:make-X-provider args)。
;;;
;;; 它们已被 package.lisp 的 :import-from 取代——主包直接重导出
;;; providers 的同一符号，语义完全等价，且不再需要手工同步：
;;; 正是这份手工同步漏掉了 dashscope（导出了却没有委托定义，
;;; 调用即 UNDEFINED-FUNCTION）。
;;; ============================================================
;;; 内部工厂函数（提取公共模式）
;;; ============================================================

(defun %make-provider-internal (provider-class
                                &key
                                name
                                api-url
                                default-model
                                chat-endpoint
                                stream-endpoint
                                (timeout 120)
                                api-key
                                api-key-env-var
                                require-api-key-p)
  "创建提供商实例的内部函数

参数：
  PROVIDER-CLASS    - 提供商类（符号）
  NAME              - 提供商名称（关键字，如 :anthropic）
  API-URL           - API 基础 URL
  DEFAULT-MODEL     - 默认模型名称
  CHAT-ENDPOINT     - 聊天端点路径
  STREAM-ENDPOINT   - 流式端点路径
  TIMEOUT           - 请求超时时间
  API-KEY           - API 密钥（可选）
  API-KEY-ENV-VAR   - API 密钥环境变量名
  REQUIRE-API-KEY-P - 是否必须有 API 密钥

返回：
  提供商实例

说明：
  提取 4 个 make-*-provider 工厂函数的公共模式，减少代码重复。"
  ;; 获取 API 密钥
  (let ((effective-key (or api-key
                           (when api-key-env-var
                             (cl-agent/core:get-env api-key-env-var)))))
    ;; 检查是否必须有 API 密钥
    (when (and require-api-key-p (null effective-key))
      (cl-agent/core:signal-error 'cl-agent/core:missing-api-key-error
                                  :message (format nil "~A API 密钥未设置，请设置 ~A 环境变量"
                                                   name api-key-env-var)
                                  :config-key api-key-env-var))

    ;; 创建实例
    (let ((instance (make-instance provider-class
                                   :name name
                                   :api-url api-url
                                   :default-model default-model
                                   :chat-endpoint chat-endpoint
                                   :stream-endpoint stream-endpoint
                                   :timeout timeout)))
      ;; 设置 API 密钥（如果提供商有该槽）
      (when (and effective-key (slot-exists-p instance 'api-key))
        (setf (slot-value instance 'api-key) effective-key))
      instance)))

;;; ============================================================
;;; 通用提供商工厂
;;; ============================================================

(defun make-provider (type &rest args)
  "通用提供商工厂——委托给 factory/registry.lisp 的注册表。

参数：
  TYPE - 提供商类型关键字或别名（见 list-providers / resolve-provider-name）
  ARGS - 提供商特定参数

返回：
  提供商实例

示例：
  (make-provider :anthropic)
  (make-provider :openai :model \"gpt-4o-mini\")
  (make-provider :deepseek)
  (make-provider \"claude\")                ; 别名

此前这里是一张手写 ECASE，只列了 anthropic/openai/ollama/zhipu/minimax/
dashscope——deepseek / gemini / mistral **全部 ECASE 落空报错**，别名也不认，
尽管注册表里它们一直都在。注册表才是单一事实来源：新增 provider 只需
register-provider，无需回来改这里。

注：registry 在本文件之后加载，但 create-provider 是运行时解析，
调用发生时注册表早已填充。"
  (apply #'create-provider type args))

;;; ============================================================
;;; 提供商访问器（统一接口）
;;; ============================================================
;;; 这些函数为所有提供商类型提供统一的访问接口
;;; 注意：provider-name 使用 cl-agent/core 中定义的泛型函数
;;;       方法实现在 providers/base.lisp 中

(defun provider-api-url (provider)
  "获取提供商 API URL

参数：
  PROVIDER - 提供商实例

返回：
  API 基础 URL 字符串"
  (base-provider-api-url provider))

(defun provider-default-model (provider)
  "获取提供商默认模型

参数：
  PROVIDER - 提供商实例

返回：
  默认模型名称字符串"
  (base-provider-default-model provider))

(defun provider-chat-endpoint (provider)
  "获取提供商聊天端点

参数：
  PROVIDER - 提供商实例

返回：
  聊天 API 端点路径"
  (base-provider-chat-endpoint provider))

(defun provider-stream-endpoint (provider)
  "获取提供商流式端点

参数：
  PROVIDER - 提供商实例

返回：
  流式 API 端点路径"
  (base-provider-stream-endpoint provider))

(defun provider-timeout (provider)
  "获取提供商超时设置

参数：
  PROVIDER - 提供商实例

返回：
  超时时间（秒）"
  (base-provider-timeout provider))

;;; ============================================================
;;; 提供商工具函数
;;; ============================================================

;; 注：这里曾有 build-provider-url，与 base.lisp 的 build-api-url 重复
;; 且无人调用（请求路径只走 build-api-url）。已删除。

(defun provider-headers (provider api-key)
  "生成提供商特定的请求头

参数：
  PROVIDER - 提供商实例
  API-KEY  - API 密钥

返回：
  请求头 alist

说明：
  不同提供商使用不同的认证方式：
  - Anthropic: x-api-key + anthropic-version
  - OpenAI: Authorization Bearer
  - Ollama: 无需认证"
  (let ((headers `(("Content-Type" . "application/json"))))
    (ecase (provider-name provider)
      (:anthropic
       ;; Anthropic 使用 x-api-key 和版本头
       (append headers
               `(("x-api-key" . ,api-key)
                 ("anthropic-version" . "2023-06-01"))))
      (:openai
       ;; OpenAI 使用 Bearer Token
       (append headers
               `(("Authorization" . ,(format nil "Bearer ~A" api-key)))))
      (:ollama
       ;; Ollama 不需要认证
       headers)
      (:zhipu
       ;; 智谱 AI 使用 Bearer Token（特殊格式）
       (append headers
               `(("Authorization" . ,api-key)))))))

;;; ============================================================
;;; 消息格式转换
;;; ============================================================

(defun convert-message-to-provider (message provider)
  "将通用消息格式转换为提供商特定格式

参数：
  MESSAGE  - 通用消息，支持格式：
             - cons: (role . content)
             - plist: (:role role :content content)
  PROVIDER - 提供商实例

返回：
  提供商特定消息格式（hash-table）"
  (declare (ignore provider))
  (let* ((dotted-p (and (consp message) (atom (cdr message))))
         (role (if dotted-p
                   ;; cons 格式: (role . content)
                   (car message)
                   ;; plist 格式: (:role role :content content)
                   (getf message :role)))
         (content (if dotted-p
                      (cdr message)
                      (getf message :content)))
         (msg-hash (make-hash-table :test 'equal)))
    ;; 统一输出为 hash-table 格式
    (setf (gethash "role" msg-hash)
          (if (keywordp role)
              (string-downcase (symbol-name role))
              role))
    (setf (gethash "content" msg-hash) content)
    msg-hash))

(defun convert-messages-to-provider (messages provider)
  "批量转换消息格式

参数：
  MESSAGES - 消息列表
  PROVIDER - 提供商实例

返回：
  提供商特定消息数组（vector）"
  (coerce
   (mapcar (lambda (msg)
             (convert-message-to-provider msg provider))
           messages)
   'vector))

;;; ============================================================
;;; 请求体构建
;;; ============================================================

(defun build-chat-request-body (provider messages &key
                                                     system
                                                     tools
                                                     temperature
                                                     max-tokens
                                                     (stream nil))
  "构建聊天请求体

参数：
  PROVIDER    - 提供商实例
  MESSAGES    - 消息列表
  SYSTEM      - 系统提示（可选）
  TOOLS       - 工具列表（可选）
  TEMPERATURE - 温度参数（可选）
  MAX-TOKENS  - 最大 token 数（可选）
  STREAM      - 是否流式（可选）

返回：
  请求体 hash-table"
  (let* ((model (provider-default-model provider))
         (converted-messages (convert-messages-to-provider messages provider))
         ;; 基础请求体（使用 hash-table）
         (body (make-hash-table :test 'equal)))

    ;; 设置必需字段
    (setf (gethash "model" body) model)
    (setf (gethash "messages" body) converted-messages)
    (setf (gethash "stream" body) stream)

    ;; 添加系统提示（Anthropic 格式）
    (when system
      (setf (gethash "system" body) system))

    ;; 添加温度
    (when temperature
      (setf (gethash "temperature" body) temperature))

    ;; 添加最大 tokens
    (when max-tokens
      (setf (gethash "max_tokens" body) max-tokens))

    ;; 添加工具（如果有）
    (when tools
      (setf (gethash "tools" body) (convert-tools-to-provider tools provider)))

    body))

;;; ============================================================
;;; 响应解析
;;; ============================================================

(defun alist-get (alist key)
  "从 alist 中获取值（支持字符串或符号 key）

参数：
  ALIST - 关联列表
  KEY   - 键（字符串或符号）

返回：
  关联的值，如果不存在则返回 nil

说明：
  也支持 hash-table（json-parse 的返回格式）"
  (let ((string-key (if (symbolp key)
                        (string-downcase (symbol-name key))
                        key)))
    (if (hash-table-p alist)
        (gethash string-key alist)
        (cdr (assoc string-key alist :test #'string-equal)))))

(defun parse-chat-response (response provider)
  "解析聊天响应

参数：
  RESPONSE - API 响应（JSON 字符串或已解析的对象）
  PROVIDER - 提供商实例

返回：
  解析后的响应 plist

错误处理：
  - 如果响应包含错误，发出 llm-error"
  (let ((parsed (if (stringp response)
                    (cl-agent/core:json-parse response)
                    response)))
    ;; 检查错误
    (when-let (error-info (alist-get parsed "error"))
      (cl-agent/core:signal-error 'cl-agent/core:llm-error
                                  :message (alist-get error-info "message")
                                  :provider (provider-name provider)
                                  :status-code (alist-get error-info "type")))
    ;; 解析成功响应
    (ecase (provider-name provider)
      (:anthropic
       (let* ((content-list (alist-get parsed "content"))
              (first-content (when (and content-list (plusp (length content-list)))
                               (elt content-list 0))))
         `(:content ,(alist-get first-content "text")
           :model ,(alist-get parsed "model")
           :usage ,(alist-get parsed "usage"))))
      (:openai
       (let* ((choices (alist-get parsed "choices"))
              (first-choice (when (and choices (plusp (length choices)))
                              (elt choices 0)))
              (message (alist-get first-choice "message")))
         `(:content ,(alist-get message "content")
           :model ,(alist-get parsed "model")
           :usage ,(alist-get parsed "usage"))))
      (:ollama
       (let ((message (alist-get parsed "message")))
         `(:content ,(alist-get message "content")
           :model ,(alist-get parsed "model")
           :done ,(alist-get parsed "done"))))
      (:zhipu
       (let* ((choices (alist-get parsed "choices"))
              (first-choice (first choices))
              (message (alist-get first-choice "message")))
         `(:content ,(alist-get message "content")
           :model ,(alist-get parsed "model")
           :usage ,(alist-get parsed "usage")))))))

;;; ============================================================
;;; 工具格式转换
;;; ============================================================

(defun convert-tools-to-provider (tools provider)
  "将工具定义转换为提供商格式

参数：
  TOOLS    - 工具定义列表
  PROVIDER - 提供商实例

返回：
  提供商特定工具格式"
  (declare (ignore provider))
  ;; OpenAI/Anthropic/智谱 AI 兼容格式
  (mapcar (lambda (tool)
            `(("type" . "function")
              ("function" . (("name" . ,(getf tool :name))
                            ("description" . ,(getf tool :description))
                            ("parameters" . ,(getf tool :parameters))))))
          tools))

;;; ============================================================
;;; 成本估算
;;; ============================================================
;;; 从已移除的 client.lisp 迁入。原实现接受 client 或 provider 两种入参，
;;; 而 client 类已随 P1 退役——现在只认 provider，与 count-tokens 同处一层。

(defparameter *provider-pricing*
  '(;; provider . (每 1M 输入 token 美元 . 每 1M 输出 token 美元)
    (:anthropic   . (3.0 . 15.0))    ; Claude Sonnet 档
    (:openai      . (5.0 . 15.0))    ; GPT-4o 档
    (:zhipu       . (1.0 . 2.0))     ; GLM（人民币折算）
    (:ollama      . (0.0 . 0.0)))    ; 本地推理，无 API 费用
  "provider → (输入单价 . 输出单价)，单位：美元 / 1M token。

只覆盖粗略估算所需的几家旗舰档位；未列出的 provider 按 0 计
（见 estimate-cost 的说明）。

注：此前这里是一张 ecase，只认 4 个 provider——其余（deepseek /
gemini / mistral / minimax / dashscope 以及后来加入的几家）一律
ecase 落空报错。成本估算这种边角功能不该把调用方整个打断，
改成查表 + 未知回落。

单位也随之修正：注释一直写「$3/1M tokens」，值却按「$/1K」写成
0.003，再乘 1e-6——算出来的成本比真实值小 1000 倍。现在表里的值
与注释同为「每 1M token 美元」，乘 1e-6 得到每 token 单价。")

(defun estimate-cost (provider input-tokens &optional (output-tokens 0))
  "估算请求成本

参数：
  PROVIDER      - provider 实例
  INPUT-TOKENS  - 输入 token 数
  OUTPUT-TOKENS - 输出 token 数（可选）

返回：
  估算成本（美元）；provider 不在定价表里时返回 0.0

注意：
  这是基于公开定价的粗略估算，按 provider 的旗舰档位计，
  不区分具体模型；实际成本以厂商账单为准。"
  (let* ((name (cl-agent/core:provider-name provider))
         (pricing (cdr (assoc name *provider-pricing*)))
         (input-price (if pricing (car pricing) 0.0))
         (output-price (if pricing (cdr pricing) 0.0)))
    (+ (* input-tokens input-price 1e-6)
       (* output-tokens output-price 1e-6))))

;;; ============================================================
;;; Token 计数（简化版本）
;;; ============================================================

(defun count-tokens (text &optional (provider :anthropic))
  "估算文本的 token 数量

参数：
  TEXT     - 输入文本
  PROVIDER - 提供商类型（可选，默认 :anthropic）

返回：
  估算的 token 数

注意：
  这是粗略估算，精确计数需要使用 tokenizer

估算规则：
  - 英文：约 4 字符/token
  - 中文：约 2 字符/token
  - 代码：约 3-4 字符/token"
  (declare (ignore provider))
  (let ((char-count (length text)))
    ;; 简单启发式：假设平均 4 字符/token
    ;; 对于更精确的计算，需要集成 tiktoken 或类似库
    (ceiling (/ char-count 4.0))))

;;; ============================================================
;;; 说明：提供商协议实现已收敛到 providers/ 目录
;;; ============================================================
;;; - openai / zhipu / ollama：providers/{openai,zhipu,ollama}.lisp
;;;   （基于 providers/openai-compat.lisp 基座，统一返回 llm-response）
;;; - anthropic：providers/anthropic.lisp（原生 Messages API）
;;; - dashscope：providers/bailian.lisp（DashScope 原生格式）
