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
│  Service 层 (service.lisp)                                       │
│  └── normalize-response ─────────→ llm-response 对象             │
│           │                                                      │
│           ▼                                                      │
│  消费者 (Kernel, Agent, 应用代码)                                 │
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
├── service.lisp              # Service 层（响应标准化）
├── schema/                   # Schema 转换
│   ├── openai.lisp          # OpenAI 格式
│   ├── anthropic.lisp       # Anthropic 格式
│   └── response.lisp        # 响应 schema
├── providers/                # 提供商实现
│   ├── base.lisp            # 基类
│   ├── define-provider.lisp # 通用宏和函数
│   ├── anthropic.lisp       # Anthropic Claude
│   ├── openai.lisp          # OpenAI GPT
│   ├── zhipu.lisp           # 智谱 AI GLM
│   └── bailian.lisp         # 阿里云百炼 DashScope
└── factory/                  # 工厂模式
    ├── registry.lisp        # 提供商注册表
    ├── config.lisp          # 配置管理
    └── builder.lisp         # Builder API
```

## 支持的提供商

| 提供商 | 关键字 | 默认模型 | 特性 |
|--------|--------|----------|------|
| Anthropic | `:anthropic` | claude-3-5-sonnet-20241022 | 工具调用、流式 |
| OpenAI | `:openai` | gpt-4o | 工具调用、流式、嵌入 |
| 智谱 AI | `:zhipu` | GLM-4.7 | 工具调用、流式、思维链 |
| 阿里云百炼 | `:dashscope` | qwen-plus | 工具调用、流式 |
| Ollama | `:ollama` | llama2 | 本地运行 |

## Service 层

Service 层负责将各 Provider 返回的原始响应转换为统一的 `llm-response` 对象。

### 响应标准化

```lisp
;; Provider 返回原始 plist
(let ((raw-response (llm-chat provider messages)))
  ;; Service 层标准化为 llm-response
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
(llm-response-finish-reason response)  ; 结束原因 (:stop, :tool-call, :length)
(llm-response-message-id response)     ; 消息 ID
(llm-response-raw response)            ; 原始响应

;; 便捷谓词
(llm-response-has-tool-calls-p response)
(llm-response-has-content-p response)

;; 便捷访问器
(llm-response-input-tokens response)
(llm-response-output-tokens response)
(llm-response-total-tokens response)
```

### 智谱特有：思维链

```lisp
;; 提取智谱 AI 的思维链内容
(response-reasoning-content response)
;; => "让我思考一下这个问题..."

;; 检查响应是否完整
(response-complete-p response)
;; => T 或 NIL
```

## 快速开始

### 创建客户端

```lisp
;; Anthropic Claude
(defvar *claude*
  (make-client
    :provider :anthropic
    :model "claude-3-5-sonnet-20241022"
    :api-key (uiop:getenv "ANTHROPIC_API_KEY")))

;; OpenAI GPT
(defvar *gpt*
  (make-client
    :provider :openai
    :model "gpt-4o"
    :api-key (uiop:getenv "OPENAI_API_KEY")))

;; 智谱 AI
(defvar *glm*
  (make-client
    :provider :zhipu
    :model "glm-4-turbo"
    :api-key (uiop:getenv "ZHIPU_API_KEY")))

;; Ollama（本地）
(defvar *local*
  (make-client
    :provider :ollama
    :model "llama2"
    :base-url "http://localhost:11434"))
```

### 基本聊天

```lisp
;; 简单字符串
(chat *claude* "你好！")

;; 多轮对话
(chat *claude*
  '((:role :user :content "我叫小明")
    (:role :assistant :content "你好，小明！")
    (:role :user :content "我叫什么名字？")))

;; 带参数
(chat *claude* "写一首诗"
  :temperature 0.9
  :max-tokens 500)
```

### 工具调用

```lisp
;; 定义工具 schema
(defvar *tools*
  '((:name "get_weather"
     :description "获取天气信息"
     :parameters (:type "object"
                  :properties (:city (:type "string"
                                      :description "城市名"))
                  :required ("city")))))

;; 带工具的聊天
(let ((response (chat *claude* "北京天气怎么样？" :tools *tools*)))
  (when (response-tool-calls response)
    ;; 处理工具调用
    (dolist (call (response-tool-calls response))
      (format t "调用工具: ~A~%" (tool-call-name call))
      (format t "参数: ~A~%" (tool-call-arguments call)))))
```

### 流式输出

```lisp
;; 基本流式
(chat-stream *claude* "讲一个故事"
  :on-token (lambda (token)
              (format t "~A" token)
              (force-output)))

;; 完整回调
(chat-stream *claude* messages
  :on-token (lambda (token) ...)
  :on-tool-call (lambda (tool-call) ...)
  :on-complete (lambda (response) ...)
  :on-error (lambda (error) ...))
```

### 嵌入向量

```lisp
;; 单文本嵌入
(embed *gpt* "Hello, world!")
;; => #(0.123 0.456 ...)

;; 批量嵌入
(embed-batch *gpt* '("文本1" "文本2" "文本3"))
;; => (#(...) #(...) #(...))
```

### Token 计数

```lisp
(count-tokens *claude* "这是一段测试文本")
;; => 8
```

## 客户端配置

```lisp
(make-client
  :provider :anthropic
  :model "claude-3-5-sonnet-20241022"
  :api-key "sk-..."

  ;; 可选配置
  :base-url "https://api.anthropic.com"  ; 自定义 API 地址
  :max-tokens 4096                        ; 最大输出 token
  :temperature 0.7                        ; 采样温度
  :timeout 120                            ; 超时时间（秒）
  :retry-attempts 3                       ; 重试次数
  :retry-delay 1000)                      ; 重试延迟（毫秒）
```

## 自定义提供商

```lisp
;; 继承基类
(defclass my-provider (base-provider)
  ((name :initform "my-provider")
   (api-url :initform "https://api.example.com")))

;; 实现聊天方法
(defmethod llm-chat ((provider my-provider) messages &key tools settings)
  ;; 实现 API 调用
  ...)

;; 注册提供商
(register-provider :my-provider #'make-my-provider)

;; 使用
(make-client :provider :my-provider :model "my-model")
```

## Schema 转换

不同提供商的工具 schema 格式不同，模块自动处理转换：

```lisp
;; 内部统一格式
(:name "tool_name"
 :description "描述"
 :parameters (:type "object"
              :properties (...)
              :required (...)))

;; 转换为 OpenAI 格式
(convert-schema-to-openai schema)

;; 转换为 Anthropic 格式
(convert-schema-to-anthropic schema)
```

## 错误处理

```lisp
(handler-case
    (chat *claude* "Hello")
  (llm-rate-limit-error (e)
    (format t "速率限制: ~A~%" (error-retry-after e)))
  (llm-api-error (e)
    (format t "API 错误: ~A~%" (error-message e)))
  (llm-timeout-error (e)
    (format t "超时: ~A~%" e)))
```

## 与 Kernel 集成

```lisp
;; 创建 Service
(defvar *service*
  (make-service-from-client *claude*))

;; 或手动创建
(defvar *service*
  (make-service
    :provider *claude*
    :chat-fn (lambda (messages tools settings)
               (chat *claude* messages
                     :tools tools
                     :temperature (getf settings :temperature)))
    :build-result-msgs-fn #'build-result-messages))

;; 用于 Kernel
(defvar *kernel*
  (make-kernel :service *service*))
```
