# CL-Agent

[English](README_EN.md)

基于 Common Lisp 的 AI Agent 框架：**Kernel + Filter** 三链为唯一执行内核，
**ChatModel** 协议解耦多提供商实现，用 CLOS 与宏（`deftool` / `defilter` /
`chat`）表达 Java 框架用注解与 Builder 表达的东西。

能力对标 Spring AI 2.0，但不照搬它的 Java 表达习惯——ChatClient、Builder、
fluent RequestSpec、Advisor 链都已退役（见下方迁移说明）。

## 特性

- **一个入口**：`build-kernel` 装配（model / filters / tools / settings），
  `chat` 宏发起请求。没有 Builder，没有 ClientRequestSpec。
- **Kernel + Filter 三链**：`:chat` / `:tool` / `:turn` 三条洋葱链
  （外加 `:token-xform` transducer），`build-chain` 折叠为嵌套闭包——
  闭包只捕获下游，递归重入免费。内置 10 个 filter：记忆、日志（chat/tool）、
  安全护栏、结构化输出校验、re-reading、RAG 问答、渐进式工具披露、
  超时、审批门、token 改写
- **ChatModel 协议**：`chat-model-call` / `chat-model-stream`（真 SSE 流式），
  单次调用语义——工具循环由 `cl-agent.kernel:run-tool-loop` 承担
- **工具体系**：`deftool` 宏对标 `@Tool` 注解，自动派生 JSON Schema；
  工具身份即符号（无全局副作用），`(:tools 'get-weather)` 引用；
  ToolCallback / ToolCallingManager（串行/虚拟线程/线程池三实现）/
  `:return-direct` / ToolContext / 三故障分类（语义/瞬时/环境）
- **ChatMemory**：Repository 存储协议 + 滑动窗口记忆（pairing-safe 裁剪）
- **多提供商**：Anthropic、OpenAI、智谱 GLM、DeepSeek、Gemini、Mistral、
  Ollama、DashScope、MiniMax（统一 `llm-chat` SPI + `llm-response`，
  经 `provider-chat-model` 适配；DeepSeek 支持前缀续写 beta）

## 架构

```
┌──────────────────────────────────────────────────────┐
│  cl-agent.kernel   Kernel + Filter 三链（执行内核）    │
│                    build-kernel + chat 宏 DSL +       │
│                    invoke-chat/tool/turn +            │
│                    run-tool-loop + ToolCallingManager │
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

一次 `chat` 的执行路径：

```
(chat kernel ...) → messages + context → turn-request
  → :turn 链（护栏/校验/RAG/re-reading…）
      → run-tool-loop ─┬→ :chat 链（记忆/日志/工具披露）→ chat-model-call
                       └→ :tool 链（超时/审批/日志）→ 工具执行
  → turn-result → 文本 / chat-response / turn-result
```

与 Spring AI 的对应关系：

| Spring AI 2.0 | CL-Agent |
|---|---|
| `ChatClient.builder(model).build()` | `(build-kernel :model m :filters ... :tools ...)` |
| `client.prompt().user(u).call().content()` | `(chat kernel (:user u))` |
| `@Tool` / `@ToolParam` | `deftool` 宏 |
| `CallAdvisor` / `AdvisorChain` | `make-filter` / `defilter` + `build-chain` 三链 |
| `ToolCallingAdvisor`（2.0） | `cl-agent.kernel:run-tool-loop`（`:turn` 链终端） |
| `MessageChatMemoryAdvisor` | `memory-filter`（`:chat` 链，循环内每轮生效） |
| `SafeGuardAdvisor` | `safeguard-turn-filter` |
| `StructuredOutputValidationAdvisor` | `validation-turn-filter` |
| `ToolSearchToolCallingAdvisor` | `tool-search-filter` |
| `MessageWindowChatMemory` | `message-window-chat-memory` |
| `ChatModel#call` | `chat-model-call` |
| `ToolCallingManager` | `cl-agent.kernel:tool-calling-manager`（三实现） |

> **Spring AI 的两大移植层都已退役。**
> - **Advisor**（`defadvisor` / `advise-call` / `chain-next` + 六个内置
>   Advisor）→ kernel filter 三链。迁移：`:advisors (list ...)` →
>   `build-kernel :filters (list ...)`。
> - **ChatClient**（`cl-agent.client` 整包：ChatClient / Builder /
>   fluent RequestSpec）→ `build-kernel` 的关键字参数 + `chat` 宏。
>   Builder 与链式 spec 是 Java 的表达习惯，在 Lisp 里没有存在理由。
>   迁移：`make-kernel-client` → `build-kernel`；`(chat client ...)`
>   原样可用，只是符号来自 `cl-agent.kernel`。

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

;; 3. 装配 kernel（记忆 + 日志 filter）
(defvar *memory* (cl-agent.chat:make-message-window-chat-memory))
(defvar *kernel*
  (cl-agent.kernel:build-kernel
    :model *model*
    :filters (list (cl-agent.kernel:memory-filter *memory*)
                   (cl-agent.kernel:logging-chat-filter))
    :tools '(get-weather)))

;; 4. 对话（模型自动调用工具，记忆自动维护）
(cl-agent.kernel:chat *kernel*
  (:system "你是一个天气助手")
  (:user "东京的天气怎么样？")
  (:conversation "conv-1"))
```

> `filters` 的列表顺序即洋葱层级：靠前 = 靠外 = 先执行。
> 不需要任何 filter 时 `(build-kernel :model *model*)` 即可
> （只有模型调用 + 工具循环）。

流式与结构化输出：

```lisp
;; 流式
(cl-agent.kernel:chat *kernel*
  (:user "写一首短诗")
  (:stream (lambda (delta) (princ delta))))

;; JSON 结构化输出（对标 entity()）——只解析，不校验
(cl-agent.kernel:chat *kernel*
  (:user "用 JSON 给出东京的信息")
  (:call :entity))
```

要「不符合 schema 就带着校验错误让模型重新输出」（对标 Spring AI 2.0 的
`StructuredOutputValidationAdvisor`），给 kernel 挂 `validation-turn-filter`
——校验判据由它承担，`(:call :entity)` 本身只负责解析：

```lisp
(defvar *schema*
  "{\"type\":\"object\",
    \"properties\":{\"name\":{\"type\":\"string\"},
                   \"population\":{\"type\":\"integer\"}},
    \"required\":[\"name\",\"population\"]}")

(defvar *validating-kernel*
  (cl-agent.kernel:build-kernel
    :model *model*
    :filters (list (cl-agent.kernel:validation-turn-filter
                    ;; 判据：(response) → (values ok-p 反馈文本)。
                    ;; 不合格时 filter 把反馈追加进 messages 递归重入整条
                    ;; 循环，让模型自我纠正（缺省最多重试 2 次）。
                    (cl-agent.kernel:structured-output-validate-fn
                     *schema* :parse-fn #'cl-agent.core:json-parse)
                    :max-retries 2))))

(cl-agent.kernel:chat *validating-kernel*
  (:user "用 JSON 给出东京的信息")
  (:call :entity))
```

自定义 filter：

```lisp
;; filter 钩子统一是 (lambda (req chain) ...)：
;; 前置改写 req → (funcall chain req) 进下游 → 后置加工返回值；
;; 不调 chain 就是短路（护栏即如此）。
(defun timing-filter ()
  (cl-agent.kernel:make-filter
   :timing
   :turn (lambda (req chain)
           (let ((start (get-internal-real-time)))
             (prog1 (funcall chain req)
               (format t "耗时 ~,2Fs~%"
                       (/ (- (get-internal-real-time) start)
                          internal-time-units-per-second)))))))

(cl-agent.kernel:build-kernel
  :model *model*
  :filters (list (timing-filter)))
```

## 模块说明

| 模块 | 描述 |
|------|------|
| **core** | 基础设施（条件系统/HTTP/SSE/JSON Schema）、`llm-chat` SPI、`cl-agent.chat`、`cl-agent.kernel` |
| **llm** | 提供商实现，`create-chat-model` 一步创建 ChatModel |
| **mock** | Mock provider（测试/演示，无需 API 密钥） |
| **protocols** | A2A 协议支持（独立系统，未纳入主构建） |

## 安装与测试

```bash
# 加载（SBCL + Quicklisp）
sbcl --eval '(asdf:load-system :cl-agent)'

# 运行测试套件（全 mock，离线可跑）
sbcl --non-interactive --load run-tests.lisp

# 真实 provider 端到端验证（需 API 密钥）
MINIMAX_API_KEY=... sbcl --script scripts/live-test.lisp
```

## 示例

见 [examples/kernel-usage.lisp](examples/kernel-usage.lisp)：
8 个渐进示例覆盖 chat 宏、build-kernel、deftool、记忆、自定义 filter、
函数形态入口、结构化输出校验与流式。全部用 mock，无需 API 密钥。

真实 provider 的端到端验证（工具循环 / 记忆 / schema 校验 / SSE 分片）：

```bash
MINIMAX_API_KEY=... sbcl --script scripts/live-test.lisp
```

## 文档

- [快速开始指南](docs/QUICKSTART_CN.md)
- [API 参考](docs/API_CN.md)
- [工具调用架构](docs/tool-calling_CN.md) —— Filter 与 Manager 的分工、
  Spring AI 2.0 对应关系与已知偏差

## 许可证

MIT License
