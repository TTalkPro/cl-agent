# LLM 模块

中文 | [English](README_EN.md)

LLM 提供商实现和统一接口模块。

## 架构概览

```
┌─────────────────────────────────────────────────────────────────┐
│  Provider 层 (返回原始 API 响应 plist)                           │
│  ├── providers/anthropic.lisp  ──┐                               │
│  ├── providers/bailian.lisp      │                               │
│  ├── providers/zhipu.lisp        ├──→ llm-chat 返回原始 plist     │
│  ├── providers/openai.lisp       │                               │
│  └── providers.lisp            ──┘                               │
│           │                                                      │
│           ▼                                                      │
│  ChatModel 层 (chat-model.lisp)                                       │
│  └── normalize-response ─────────→ llm-response 对象             │
│           │                                                      │
│           ▼                                                      │
│  消费者 (ChatClient, Agent, 应用代码)                                 │
│  └── 统一使用 llm-response 对象                                   │
└─────────────────────────────────────────────────────────────────┘
```

## 目录结构

```
llm/
├── package.lisp              # 包定义
├── client.lisp               # 统一客户端接口
├── providers.lisp            # 提供商注册
├── streaming.lisp            # 流式支持
├── chat-model.lisp              # ChatModel 层（响应标准化）
├── providers/                # 提供商实现
│   ├── base.lisp            # 基类
│   ├── define-provider.lisp # 共享 wire 助手
│   ├── openai-compat.lisp   # OpenAI 兼容基座 + define-openai-compat-provider
│   ├── anthropic.lisp       # Anthropic Claude
│   ├── openai.lisp          # OpenAI GPT
│   ├── zhipu.lisp           # 智谱 AI GLM
│   ├── ollama.lisp          # Ollama（本地）
│   ├── minimax.lisp         # MiniMax
│   ├── deepseek.lisp        # DeepSeek
│   ├── gemini.lisp          # Google Gemini
│   ├── mistral.lisp         # Mistral AI
│   └── dashscope.lisp       # 阿里云 DashScope（通义千问）
├── stream/                   # 真 SSE 流式（llm-chat-stream 特化）
│   ├── anthropic.lisp       # Anthropic 格式（anthropic + minimax）
│   └── openai.lisp          # OpenAI 兼容格式
└── factory/                  # 工厂
    └── registry.lisp        # Provider 注册表 + 别名 + create-chat-model
```

## 支持的提供商

| 提供商 | 关键字 | 默认模型 | 特性 |
|--------|--------|----------|------|
| Anthropic | `:anthropic` | claude-3-5-sonnet-20241022 | 工具调用、流式 |
| OpenAI | `:openai` | gpt-4o | 工具调用、流式、嵌入 |
| 智谱 AI | `:zhipu` | GLM-4.7 | 工具调用、流式、思维链 |
| 阿里云百炼 | `:dashscope` | qwen-plus | 工具调用、流式 |
| Ollama | `:ollama` | llama2 | 本地运行 |

## ChatModel 层

ChatModel 层负责将各 Provider 返回的原始响应转换为统一的 `llm-response` 对象。

### 响应标准化

```lisp
;; Provider 返回原始 plist
(let ((raw-response (llm-chat provider messages)))
  ;; ChatModel 层标准化为 llm-response
  (normalize-response raw-response :zhipu))

;; 或使用高层 API（自动标准化）
(chat-with-normalization provider messages)
```

### llm-response 对象

```lisp
;; 统一的响应结构
(llm-response-content response)        ; 文本内容
(llm-response-tool-calls response)     ; 工具调用列表
(llm-response-usage response)          ; Token 使用信息
(llm-response-model response)          ; 模型名称
(llm-response-finish-reason response)  ; 结束原因（见下）
(llm-response-message-id response)     ; 消息 ID
(llm-response-reasoning response)      ; 思维链文本
(llm-response-reasoning-blocks response) ; provider 原生推理块（含签名）
(llm-response-raw response)            ; 原始响应

;; 便捷谓词
(llm-response-has-tool-calls-p response)
(llm-response-has-content-p response)

;; 便捷访问器
(llm-response-input-tokens response)
(llm-response-output-tokens response)
(llm-response-total-tokens response)
```

`finish-reason` 已归一为四个关键字，与提供商原始取值无关：

| 关键字 | 含义 | 提供商原始值示例 |
|---|---|---|
| `:stop` | 正常结束 | `stop` / `end_turn` / `stop_sequence` |
| `:tool-call` | 请求调用工具 | `tool_calls` / `tool_use` |
| `:max-tokens` | 达到 token 上限被截断 | `length` / `max_tokens` |
| `:content-filter` | 内容过滤 | `content_filter` |

> `llm-response-reasoning-blocks` 是 provider 原样保留的推理块（Anthropic 的
> thinking 块含密码学 signature），**只用于在后续轮次原样回传**——工具调用
> 对话中 Anthropic 要求 assistant 轮把它们不加修改地送回，否则 400。
> 展示思维链请用 `llm-response-reasoning` 或下面的 `response-reasoning-content`。

### llm-response 工具函数

不限于某一提供商——各家的思维链/结束原因都已在 ChatModel 层归一：

```lisp
;; 提取思维链内容：GLM / DeepSeek 的 reasoning_content、Anthropic 的
;; thinking 块都归到这里（并兼容旧版塞在 raw-response 里的形态）
(response-reasoning-content response)
;; => "让我思考一下这个问题..."

;; 检查响应是否完整（未被截断）
;; 接受 llm-response 或旧式 plist；未知类型返回 NIL
(response-complete-p response)
;; => T（:stop）/ NIL（被截断或其他原因）
```

## 快速开始

### 创建 ChatModel

`create-chat-model` 是本模块面向应用的推荐入口——它先建 provider，再包成
ChatModel。provider 只负责底层信息与如何调用；重试、观测、默认选项这些
归 ChatModel。

```lisp
;; Anthropic Claude
(defvar *claude*
  (create-chat-model :anthropic
    :model "claude-sonnet-4-20250514"
    :api-key (uiop:getenv "ANTHROPIC_API_KEY")))

;; OpenAI GPT
(defvar *gpt*
  (create-chat-model :openai
    :model "gpt-4o"
    :api-key (uiop:getenv "OPENAI_API_KEY")))

;; 智谱 AI
(defvar *glm*
  (create-chat-model :zhipu :model "glm-4-turbo"))

;; Ollama（本地）
(defvar *local*
  (create-chat-model :ollama
    :model "llama2"
    :api-url "http://localhost:11434"))
```

### 基本聊天

`chat-model-call` 是单次调用：它**不执行工具**，也不循环。要工具循环、
记忆、HITL，用 chat-client（见文末「与 chat-client 集成」）。

```lisp
;; 简单字符串（自动包装成 prompt）
(cl-agent/core:chat-response-text
  (cl-agent/core:chat-model-call *claude* "你好！"))

;; 多轮对话：消息列表
(cl-agent/core:chat-model-call *claude*
  (list (cl-agent/core:user-message "我叫小明")
        (cl-agent/core:assistant-message "你好，小明！")
        (cl-agent/core:user-message "我叫什么名字？")))

;; 带参数：走 prompt 的 options
(cl-agent/core:chat-model-call *claude*
  (cl-agent/core:make-prompt
    "写一首诗"
    :options (cl-agent/core:make-chat-options :temperature 0.9
                                              :max-tokens 500)))
```

### 工具调用

ChatModel 只向模型注入工具 schema 并把 tool-calls 原样带回，**不执行**。
调用方自己决定怎么处理（对标 Spring AI 的 user-controlled tool execution）。

```lisp
(cl-agent/core:deftool get-weather (city)
  "获取天气信息"
  (:city :type string :description "城市名")
  (format nil "~A：晴 22°C" city))

(let ((response
        (cl-agent/core:chat-model-call *claude*
          (cl-agent/core:make-prompt
            "北京天气怎么样？"
            :options (cl-agent/core:make-chat-options :tool-names '(get-weather))))))
  (dolist (call (cl-agent/core:chat-response-tool-calls response))
    (format t "调用工具: ~A~%" (cl-agent/core:tool-call-name call))
    (format t "参数: ~A~%" (cl-agent/core:tool-call-arguments call))))
```

### 流式输出

```lisp
;; ChatModel 层：增量文本回调，返回最终 chat-response
(cl-agent/core:chat-model-stream *claude* "讲一个故事"
  (lambda (delta)
    (format t "~A" delta)
    (force-output)))
```

provider 不支持流式时自动降级为一次性调用，整段文本作为单个增量送出。
要在流式路径上叠加 filter 链与 token 变换（脱敏、先审后放），用
`cl-agent/core:invoke-chat-stream`。

### 嵌入向量

```lisp
;; 单文本嵌入
(embed *openai-provider* "Hello, world!")
;; => #(0.123 0.456 ...)

;; 批量嵌入
(embed-batch *openai-provider* '("文本1" "文本2" "文本3"))
;; => (#(...) #(...) #(...))
```

嵌入 API 接受的是 **provider**，不是 ChatModel——它走的是 `llm-embed` SPI。

### Token 计数

```lisp
(count-tokens "这是一段测试文本")          ; 粗略估算
(count-tokens "text" :openai)
;; => 8
```

### 成本估算

```lisp
(estimate-cost (make-anthropic-provider) 1000 500)
;; => 0.0105   ; 美元，按 provider 旗舰档位粗算
```

## ChatModel 配置

```lisp
(create-chat-model :anthropic
  :model "claude-sonnet-4-20250514"
  :api-key "sk-..."
  :api-url "https://api.anthropic.com"     ; 自定义 API 地址

  ;; 模型级默认选项（请求级 options 优先，按 merge-chat-options 合并）
  :options (cl-agent/core:make-chat-options
             :max-tokens 4096
             :temperature 0.7)

  ;; 重试：ChatModel 层能力，缺省 nil = 不重试
  :retry-policy (cl-agent/core:make-retry-policy
                  :max-attempts 4        ; 总尝试次数（含首次）
                  :initial-delay 1.0     ; 首次重试前延迟（秒）
                  :backoff 2.0           ; 退避倍数
                  :max-delay 60.0        ; 单次延迟上限
                  :jitter 0.1)           ; ±10% 抖动

  ;; 观测：包住含重试的整次调用
  :observation-fn (lambda (model prompt thunk)
                    (declare (ignore model prompt))
                    (let ((start (get-internal-real-time)))
                      (prog1 (funcall thunk)
                        (format t "耗时 ~Dms~%"
                                (round (- (get-internal-real-time) start)
                                       (/ internal-time-units-per-second 1000)))))))
```

重试的分类由 `cl-agent/core:error-retryable-p` 单一裁定：瞬态 HTTP 状态
（408/409/425/429/5xx）与网络层失败可重试，鉴权/参数错不重试。

> **流式路径注意**：已经吐给回调的 token 不会被撤回。流跑到一半断掉再重试，
> 调用方会看到前半段重复。流式通常应把 `retry-policy` 留空。

## 自定义提供商

```lisp
;; 继承基类
(defclass my-provider (base-provider)
  ((name :initform "my-provider")
   (api-url :initform "https://api.example.com")))

;; 实现聊天方法——provider 只做「底层信息 + 如何调用」：
;; 端点、鉴权、请求体格式、响应解析。重试/观测/选项合并都不在这一层。
(defmethod llm-chat ((provider my-provider) messages
                     &key model max-tokens temperature tools
                     &allow-other-keys)
  ;; 实现 API 调用，返回 cl-agent/core:llm-response
  ...)

;; 注册提供商
(register-provider :my-provider #'make-my-provider)

;; 使用：注册后即可从 create-chat-model 取用
(create-chat-model :my-provider :model "my-model")
```

## Schema 转换

不同提供商的工具 schema 格式不同，模块自动处理转换：

```lisp
;; 内部统一格式（deftool 自动生成，也可手写）
(:name "tool_name"
 :description "描述"
 :parameters (:type "object"
              :properties (...)
              :required (...)))

;; 批量转成目标 provider 的 wire 格式
(convert-tools-to-provider tools provider)

;; 单个 provider 的转换规则由这个泛型方法定，新写 provider 时特化它
(cl-agent/core:provider-format-tools provider tools)
```

> 注：此处曾写 `convert-schema-to-openai` / `convert-schema-to-anthropic`——
> 那是早已删除的 `schema/` 模块里的函数（与 `providers/` 下真正在用的同名
> 近亲只差一个介词，是删它的原因之一）。真实入口是上面两个。

日常用不到这一层：`deftool` 定义的工具经 `chat-options` 的 `:tool-names` /
`:tool-callbacks` 传入后，schema 注入由 ChatModel 自动完成。

## 错误处理

条件体系的单一来源在 `core/conditions.lisp`：
`cl-agent-error → api-error → llm-error`，`execution-error → timeout-error`。
是否该重试统一由 `error-retryable-p` 裁定，不要在调用点另立一套规则。

```lisp
(handler-case
    (cl-agent/core:chat-model-call *claude* "Hello")
  (cl-agent/core:llm-error (e)
    (format t "LLM 错误 (~A): ~A~%"
            (cl-agent/core:api-status-code e)
            (cl-agent/core:error-message e))
    ;; 想自己决定要不要重试时，问同一个分类函数
    (when (cl-agent/core:error-retryable-p e)
      (format t "（这是瞬态错误，配上 :retry-policy 就会自动重试）~%")))
  (cl-agent/core:timeout-error (e)
    (format t "超时: ~A~%" e)))
```

## 与 chat-client 集成

```lisp
;; 一步创建 ChatModel（推荐入口）
(defvar *model*
  (cl-agent/llm:create-chat-model :anthropic
    :model "claude-sonnet-4-20250514"))

;; 或从已有 provider 适配
(defvar *model*
  (cl-agent/core:make-provider-chat-model
    (make-anthropic-provider)
    :default-options (cl-agent/core:make-chat-options :temperature 0.3)))

;; 装配 chat-client 后即可对话
(defvar *chat-client* (cl-agent/core:build-chat-client :model *model*))
(cl-agent/core:chat *chat-client* "你好")
```
