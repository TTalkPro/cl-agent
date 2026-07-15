# CL-Agent

[English](README_EN.md)

基于 Common Lisp 的 AI Agent 框架，架构全面对标 **Spring AI 2.0**：以
**ChatClient + Advisor** 为核心编程模型，**ChatModel** 协议解耦多提供商实现，
用 CLOS 与宏（`deftool` / `defadvisor` / `chat`）表达 Java 注解与流式 API 的语义。

## 特性

- **ChatClient**：Builder 模式 + fluent 请求 API + 声明式 `chat` 宏 DSL
- **Advisor 洋葱链**：`advise-call` / `advise-stream` 协议、有序链、
  `defadvisor` 一个表达式定义类 + 方法 + 构造函数；
  内置日志、消息记忆、安全护栏、工具循环、渐进式工具披露、
  结构化输出校验六个 Advisor（与 Spring AI 2.0 一一对应）
- **ChatModel 协议**：`chat-model-call` / `chat-model-stream`（真 SSE 流式），
  单次调用语义——工具循环由 `tool-calling-advisor` 承担（2.0 架构）
- **工具体系**：`deftool` 宏对标 `@Tool` 注解，自动派生 JSON Schema；
  工具身份即符号（无全局副作用），`(:tools 'get-weather)` 引用；
  ToolCallback / ToolCallingManager（顺序/并行）/ `:return-direct` / ToolContext
- **ChatMemory**：Repository 存储协议 + 滑动窗口记忆（pairing-safe 裁剪）
- **多提供商**：Anthropic、OpenAI、智谱 GLM、DeepSeek、Gemini、Mistral、
  Ollama、DashScope、MiniMax（统一 `llm-chat` SPI + `llm-response`，
  经 `provider-chat-model` 适配；DeepSeek 支持前缀续写 beta）

## 架构

```
┌──────────────────────────────────────────────────────┐
│  cl-agent.client   ChatClient + Builder + chat 宏     │
│                    Advisor 协议/洋葱链 + defadvisor    │
├──────────────────────────────────────────────────────┤
│  cl-agent.chat     Message/Prompt/ChatOptions/        │
│                    ChatResponse + deftool 工具体系 +   │
│                    ChatModel 协议 + ChatMemory         │
├──────────────────────────────────────────────────────┤
│  cl-agent.core     基础设施 + llm-chat SPI + HTTP/SSE  │
├──────────────────────────────────────────────────────┤
│  cl-agent.llm      提供商实现（Anthropic/OpenAI/...）  │
└──────────────────────────────────────────────────────┘
```

与 Spring AI 的对应关系：

| Spring AI 2.0 | CL-Agent |
|---|---|
| `ChatClient.builder(model).build()` | `(-> (chat-client-builder model) ... (build-client))` |
| `client.prompt().user(u).call().content()` | `(chat client (:user u))` 或 fluent 管道 |
| `@Tool` / `@ToolParam` | `deftool` 宏 |
| `CallAdvisor` / `AdvisorChain` | `defadvisor` / `advise-call` / `chain-next` |
| `ToolCallingAdvisor`（2.0） | `tool-calling-advisor`（自动注册，流式工具循环） |
| `MessageChatMemoryAdvisor` | `message-chat-memory-advisor` |
| `MessageWindowChatMemory` | `message-window-chat-memory` |
| `ChatModel#call` | `chat-model-call` |
| `ToolCallingManager` | `tool-calling-manager` |

## 快速开始

```lisp
(asdf:load-system :cl-agent)

;; 1. 创建 ChatModel（API 密钥自动读环境变量）
(defvar *model*
  (cl-agent.llm:create-chat-model :anthropic
    :model "claude-sonnet-4-20250514"))

;; 2. 定义工具（对标 @Tool）
(cl-agent.chat:deftool get-weather (&key city (unit "celsius"))
  "获取指定城市的当前天气"
  (:param city :string "城市名称" :required t)
  (:param unit :string "温度单位")
  (format nil "~A 的天气：22°C（~A），晴" city unit))

;; 3. 构建 ChatClient（记忆 + 日志 Advisor）
(defvar *memory* (cl-agent.chat:make-message-window-chat-memory))
(defvar *client*
  (cl-agent.client:make-chat-client *model*
    :system "你是一个天气助手"
    :advisors (list (cl-agent.client:make-message-chat-memory-advisor
                     :memory *memory*)
                    (cl-agent.client:make-simple-logger-advisor))))

;; 4. 对话（模型自动调用工具，记忆自动维护）
(cl-agent.client:chat *client*
  (:user "东京的天气怎么样？")
  (:tools 'get-weather)
  (:conversation "conv-1"))
```

流式与结构化输出：

```lisp
;; 流式
(cl-agent.client:chat *client*
  (:user "写一首短诗")
  (:stream (lambda (delta) (princ delta))))

;; JSON 结构化输出（对标 entity()）
(cl-agent.client:chat *client*
  (:user "用 JSON 给出东京的信息")
  (:call :entity))

;; 带 JSON Schema 校验：不符合就带着校验错误让模型重新输出（最多 3 次）
;; —— 对标 Spring AI 2.0 的 StructuredOutputValidationAdvisor
(cl-agent.client:chat *client*
  (:user "用 JSON 给出东京的信息")
  (:call :entity "{\"type\":\"object\",
                   \"properties\":{\"name\":{\"type\":\"string\"},
                                  \"population\":{\"type\":\"integer\"}},
                   \"required\":[\"name\",\"population\"]}"))
```

自定义 Advisor：

```lisp
(cl-agent.client:defadvisor timing-advisor (:order -100)
  (:call (advisor request chain)
    (declare (ignore advisor))
    (let ((start (get-internal-real-time)))
      (prog1 (cl-agent.client:chain-next chain request)
        (format t "耗时 ~,2Fs~%"
                (/ (- (get-internal-real-time) start)
                   internal-time-units-per-second))))))
```

## 模块说明

| 模块 | 描述 |
|------|------|
| **core** | 基础设施（条件系统/HTTP/SSE/JSON Schema）、`llm-chat` SPI、`cl-agent.chat`、`cl-agent.client` |
| **llm** | 提供商实现，`create-chat-model` 一步创建 ChatModel |
| **mock** | Mock provider（测试/演示，无需 API 密钥） |
| **protocols** | A2A 协议支持（独立系统，未纳入主构建） |

## 安装与测试

```bash
# 加载（SBCL + Quicklisp）
sbcl --eval '(asdf:load-system :cl-agent)'

# 运行测试套件
sbcl --non-interactive --load run-tests.lisp
```

## 示例

见 [examples/chat-client-usage.lisp](examples/chat-client-usage.lisp)：
8 个渐进示例覆盖 chat 宏、Builder、deftool、记忆、自定义 Advisor、
fluent 管道、结构化输出与流式。

## 文档

- [快速开始指南](docs/QUICKSTART_CN.md)
- [API 参考](docs/API_CN.md)

## 许可证

MIT License
