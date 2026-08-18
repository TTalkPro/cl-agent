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
;;;;     (client-chat client '((:user . "Hi") (:assistant . "Hello!") (:user . "How are you?"))))

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
    :initform nil
    :accessor client-temperature
    :documentation "客户端级默认温度。NIL 表示不下发 temperature 字段
（见 make-client 的 TEMPERATURE 说明）"))

  (:documentation "LLM 客户端

槽位说明：
  PROVIDER    - 提供商实例（base-provider 子类）
  API-KEY     - API 密钥
  MODEL       - 模型名称（可选，覆盖提供商默认值）
  BASE-URL    - 基础 URL（可选，覆盖提供商默认值）
  MAX-TOKENS  - 最大 token 数（可选）
  TEMPERATURE - 客户端级默认温度（可选；NIL 表示不下发）"))

;;; ============================================================
;;; 客户端工厂
;;; ============================================================

(defun make-client (&key
                     (provider :anthropic)
                     (model nil)
                     (api-key nil)
                     (base-url nil)
                     (max-tokens 4096)
                     (temperature nil))
  "创建 LLM 客户端

参数：
  PROVIDER    - 提供商类型（:anthropic, :openai, :ollama, :zhipu）或提供商实例
  MODEL       - 模型名称（可选）
  API-KEY     - API 密钥（可选，从环境变量读取）
  BASE-URL    - 基础 URL（可选）
  MAX-TOKENS  - 最大 token 数（可选，默认 4096——Anthropic 强制要求该字段）
  TEMPERATURE - 客户端级默认温度（可选）。NIL（缺省）表示不下发 temperature，
                由服务端取默认值。

                此前默认 0.7，意味着每次请求都被注入 temperature=0.7。
                按 Anthropic 官方文档这会直接坏在两处：
                  1. temperature / top_p / top_k 在 Claude Opus 4.7 及以后
                     （含 4.8）不受支持，设非默认值返回 400，文档要求
                     「omit them from request payloads」；
                  2. Claude 4.1 Opus / 4.5 Sonnet 起 temperature 与 top_p
                     不能同时指定，否则 400。
                需要固定温度时显式传入即可。

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
  优先级：用户显式提供 > provider 自己持有的密钥。

  provider 在构造时就已按自家规则取得密钥（各 make-*-provider 读自己的
  环境变量，如 make-minimax-provider 读 MINIMAX_API_KEY），这里直接问它要，
  不再自行推导。

  此前这里维护着一张手写的「provider → 环境变量名」ECASE 表，只列了
  anthropic/openai/zhipu——minimax / deepseek / gemini / mistral / dashscope
  会直接 ECASE 落空报错，除非显式传 :api-key。又一个手工同步终将漂移的清单：
  新增 provider 时没人记得回来改它。"
  (or provided-key
      ;; provider-api-key 是 cl-agent.core 的协议，各 provider 均已实现
      (cl-agent.core:provider-api-key provider)))

;;; ============================================================
;;; 核心聊天 API
;;; ============================================================

(defun client-chat (client messages &key
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
    (client-chat client '((:user . \"Hello!\")))

    ;; 带系统提示
    (client-chat client '((:user . \"Write a poem\"))
          :system \"You are a poet.\")

    ;; 带工具
    (client-chat client '((:user . \"What's the weather?\"))
          :tools *weather-tools*)

    ;; 自定义重试策略
    (client-chat client '((:user . \"Hello\"))
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
  "检查错误是否可重试（委托 cl-agent.core:error-retryable-p 统一分类）

参数：
  CONDITION - 错误条件

返回：
  T 如果可重试，NIL 否则

分类约定（单一来源在 core/conditions.lisp）：
  - 瞬态 HTTP 状态（408/409/425/429/5xx）可重试
  - 鉴权/参数错误（400/401/403/404 等）不可重试
  - 无状态码的网络层失败、超时可重试"
  (typecase condition
    ;; 裸 HTTP 错误（cl-agent.http 条件，不在 core 体系内）
    (cl-agent.core:http-error
     (let ((status (cl-agent.core:http-error-status condition)))
       (or (null status)
           (cl-agent.core:transient-status-p status))))
    ;; core 条件体系：统一分类
    (otherwise (cl-agent.core:error-retryable-p condition))))

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
  (let ((response (client-chat client `((:user . ,prompt))
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
  (client-chat client `((:user . ,prompt))
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
  (let ((response (client-chat client conversation :system system)))
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

(defun batch-chat (client prompts &key (system nil) (parallel nil) (pool-size 4))
  "批量处理多个聊天请求

参数：
  CLIENT    - 客户端实例
  PROMPTS   - 提示列表
  SYSTEM    - 系统提示（可选）
  PARALLEL  - 是否并行处理（默认 NIL 串行）
  POOL-SIZE - 并行时的线程池大小（默认 4，仅 PARALLEL 为真时有意义）

返回：
  响应列表，**顺序与 PROMPTS 一致**（并行不改变结果顺序）

说明：
  批量请求以 HTTP I/O 为主，并行能显著缩短墙钟时间。
  线程池按需创建、用完即释放（含非局部退出），不留全局状态——
  与 with-concurrent-tool-calling-manager 同一惯例。

  单个提示时并行无收益，直接退化为串行（不创建线程池）。

  注：此前本函数 (declare (ignore parallel))——参数被**静默忽略**，
  调用方传 :parallel t 得到的仍是串行，而 examples/llm-usage.lisp
  正是这么调的。docstring 虽写了「目前不支持」，但静默忽略一个
  显式传入的参数仍是错的：要么实现，要么报错，不该假装接受。

示例：
  (batch-chat *client* '(\"What is AI?\" \"What is ML?\"))
  (batch-chat *client* prompts :parallel t :pool-size 8)"
  (flet ((ask (prompt) (chat-simple client prompt :system system)))
    (if (and parallel (rest prompts))
        (let ((kernel (lparallel:make-kernel pool-size :name "batch-chat-pool")))
          (unwind-protect
               (let ((lparallel:*kernel* kernel))
                 ;; pmapcar 保序：结果顺序与 PROMPTS 一致
                 (lparallel:pmapcar #'ask prompts))
            (let ((lparallel:*kernel* kernel))
              (lparallel:end-kernel :wait t))))
        (mapcar #'ask prompts))))

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

(defun estimate-cost (client input-tokens &optional (output-tokens 0))
  "估算请求成本

参数：
  CLIENT        - 客户端实例
  INPUT-TOKENS  - 输入 token 数
  OUTPUT-TOKENS - 输出 token 数（可选）

返回：
  估算成本（美元）；provider 不在定价表里时返回 0.0

注意：
  这是基于公开定价的粗略估算，按 provider 的旗舰档位计，
  不区分具体模型；实际成本以厂商账单为准。
  CLIENT 也可以直接传 provider 实例"
  (let* ((provider (if (typep client 'client)
                       (client-provider-name client)
                       (cl-agent.core:provider-name client)))
         (pricing (cdr (assoc provider *provider-pricing*)))
         (input-price (if pricing (car pricing) 0.0))
         (output-price (if pricing (cdr pricing) 0.0)))
    (+ (* input-tokens input-price 1e-6)
       (* output-tokens output-price 1e-6))))
