# CL-Agent

[English](README_EN.md)

基于 Common Lisp 的 AI Agent 框架。两种用法，按需选：

- **SimpleAgent**（推荐入门）：一个有状态的 agent 对象，管住会话、可观测性、
  错误归一化与人工审批（HITL）。
- **Kernel + Filter**（完全控制）：三链洋葱中间件 + 工具循环，想拧哪个旋钮拧哪个。

能力对标 Spring AI 2.0，架构参照 clj-agent（Clojure 的 kernel+filter 实现），
但不照搬 Java 的表达习惯——ChatClient、Builder、fluent RequestSpec、Advisor 链
都已退役（见文末迁移说明）。

## 特性

- **两层入口**：`make-agent` / `agent-chat`（易用）与 `build-kernel` / `chat`
  （完全控制）。前者是后者的薄封装，随时可下沉。
- **Kernel + Filter 三链**：`:chat` / `:tool` / `:turn` 三条洋葱链
  （外加 `:token-xform` transducer），`build-chain` 折叠为嵌套闭包——
  闭包只捕获下游，递归重入免费。内置 10 个 filter：记忆、日志（chat/tool）、
  安全护栏、结构化输出校验、re-reading、RAG 问答、渐进式工具披露、
  超时、审批门、token 改写
- **HITL（人工审批）**：`:on-tool-call` 返回 `(:interrupt . 原因)` 即启用。
  **暂停时工具一个都不执行**；`agent-resume` 支持批准 / 编辑后批准 / 拒绝（带
  理由回模型）/ 答复即结果（ask-user 语义）
- **ChatModel 协议**：`chat-model-call` / `chat-model-stream`（真 SSE 流式），
  单次调用语义——工具循环由 `run-tool-loop` 承担
- **工具体系**：`deftool` 宏对标 `@Tool` 注解，自动派生 JSON Schema；
  工具身份即符号（无全局副作用），`(:tools 'get-weather)` 引用；
  ToolCallback / ToolCallingManager（kernel 级绑定的执行模型与隔离机制）/
  `:return-direct` / ToolContext
- **ChatMemory**：Repository 存储协议 + 滑动窗口记忆（pairing-safe 裁剪）
- **多提供商**：Anthropic、OpenAI、智谱 GLM、DeepSeek、Gemini、Mistral、
  Ollama、DashScope、MiniMax（统一 `llm-chat` SPI + `llm-response`，
  经 `provider-chat-model` 适配；DeepSeek 支持前缀续写 beta）

## 架构

三个包，对标 clj-agent 的 core / provider / client 分层：

```
┌──────────────────────────────────────────────────────┐
│  cl-agent.client   SimpleAgent（有状态对话 + HITL）    │
│                    make-agent / agent-chat            │
├──────────────────────────────────────────────────────┤
│  cl-agent.core     框架本体（单包）                    │
│                    Kernel + Filter 三链 + chat 宏      │
│                    Message/Prompt/Options/Response     │
│                    deftool / ChatModel / ChatMemory    │
│                    基础设施 + HTTP/SSE + JSON Schema   │
├──────────────────────────────────────────────────────┤
│  cl-agent.llm      提供商实现（Anthropic/OpenAI/...）  │
└──────────────────────────────────────────────────────┘
```

`cl-agent.core` 与 `cl-agent.client` 可以直接一起 `:use`，无需任何 shadowing：

```lisp
(defpackage :my-app
  (:use :cl :cl-agent.core :cl-agent.client))
```

一次对话的执行路径：

```
(agent-chat a "...")  或  (chat kernel ...)
  → messages + context → turn-request
  → :turn 链（护栏/校验/RAG/re-reading…）
      → run-tool-loop ─┬→ :chat 链（记忆/日志/工具披露）→ chat-model-call
                       └→ :tool 链（超时/审批/日志）→ 工具执行
                            ↑ tool-gate 在此之前评估（HITL 暂停点）
  → turn-result → 文本 / chat-response / turn-result
```

## 快速开始

```lisp
(asdf:load-system :cl-agent)

(defpackage :my-app
  (:use :cl :cl-agent.core :cl-agent.client))
(in-package :my-app)

;; 1. 创建 ChatModel（API 密钥自动读环境变量）
(defvar *model*
  (cl-agent.llm:create-chat-model :anthropic
    :model "claude-sonnet-4-20250514"))

;; 2. 定义工具（对标 @Tool）
(deftool get-weather (&key city (unit "celsius"))
  "获取指定城市的当前天气"
  (:param city :string "城市名称" :required t)
  (:param unit :string "温度单位")
  (format nil "~A 的天气：22°C（~A），晴" city unit))

;; 3. 建 agent
(defvar *a*
  (make-agent :model *model*
              :system "你是一个天气助手"
              :tools '(get-weather)))

;; 4. 对话——上下文自动累积，不用自己传 conversation-id
(agent-chat *a* "东京的天气怎么样？")   ; => "东京 的天气：22°C..."
(agent-chat *a* "那北京呢？")           ; 记得上一轮
(agent-history *a*)                     ; => 4 条消息
```

### 结果与错误：不抛异常

`agent-chat` 出错时返回 `(values nil result)`。要完整结果用 `agent-chat-result`：

```lisp
(let ((r (agent-chat-result *a* "hi")))
  (agent-result-status r))   ; :completed | :paused | :cancelled | :error
```

一次 LLM 调用失败是**预期内的常态**（网络抖动、限流、模型抽风），
所以 agent 层把它归一化成状态，而不是把条件抛给调用方。

### 可观测性：callbacks

```lisp
(make-agent :model *model* :tools '(get-weather)
            :callbacks (list :on-turn-start  (lambda (a) ...)
                             :on-turn-end    (lambda (a r) ...)
                             :on-turn-error  (lambda (a e) ...)
                             :on-tool-call   (lambda (name args) ...)
                             :on-tool-result (lambda (name text) ...)))
```

回调抛异常不会掀翻整轮对话——它们是观测手段，不是控制流。

### 人工审批（HITL）

**配 `:on-tool-call` 让它返回 `(:interrupt . 原因)` 即启用**——不是另一套机制，
就是回调的返回值：

```lisp
(defvar *a*
  (make-agent :model *model* :tools '(rm-file)
              :callbacks (list :on-tool-call
                               (lambda (name args)
                                 (when (string= name "rm_file")
                                   (cons :interrupt
                                         (format nil "删除 ~A 需审批" (getf args :path))))))))

(let ((r (agent-chat-result *a* "删除 /tmp/x.log")))
  (agent-result-status r)        ; => :paused
  (agent-result-pause-reason r)  ; => "删除 /tmp/x.log 需审批"
  (agent-result-pending-tool r)) ; => #<PENDING-TOOL rm_file (:PATH "/tmp/x.log")>

;; 暂停时工具**一个都没执行**。审批后续跑：
(agent-resume *a* :approved)                                   ; 批准
(agent-resume *a* :approved :payload '(:args (:path "/tmp/safe.log")))  ; 编辑后批准
(agent-resume *a* :rejected :payload '(:message "生产库禁止删除"))       ; 拒绝（理由回模型）
(agent-resume *a* :reply    :payload '(:message "该文件已被清理"))       ; 答复即结果
```

| decision | 语义 |
|---|---|
| `:approved` | 批准执行；`:payload (:args ...)` 可改参数后再执行 |
| `:rejected` | 不执行；`(:message 理由)` 作为工具结果回模型，省它一轮干猜 |
| `:reply` | 不执行；`(:message 答复)` **直接**作为工具结果（ask-user 语义） |

续跑后可能再次 `:paused`（本批还有别的敏感工具，或后续轮次又触发）。

## Kernel：完全控制

需要 filter（记忆策略、护栏、RAG、校验…）时下沉到 kernel。
**agent 层不接受 `:filters`**——自建 kernel 传进去：

```lisp
(defvar *memory* (make-message-window-chat-memory))

(defvar *kernel*
  (build-kernel
    :model *model*
    :system "你是一个天气助手"
    :tools '(get-weather)
    :filters (list (memory-filter *memory*)      ; 靠前 = 靠外 = 先执行
                   (logging-chat-filter))
    :settings '((:max-tool-iterations . 10))))

;; 直接用 kernel
(chat *kernel* (:user "东京天气？") (:conversation "conv-1"))

;; 或者把它交给 agent（拿到会话管理 + HITL + 错误归一化）
(make-agent :kernel *kernel* :memory *memory*)
```

`chat` 宏：

```lisp
(chat *kernel*
  (:system "你是一个天气助手")   ; 覆盖 kernel 的默认 :system
  (:user "~A 的天气？" city)      ; 支持 format 控制串
  (:tools 'get-weather)           ; 请求级工具，与 kernel :tools 取并集
  (:options :temperature 0.3)     ; 与 kernel :options 合并，请求级优先
  (:conversation "conv-1")        ; = (:context :conversation-id "conv-1")
  (:call :content))               ; :content(默认) | :response | :result | :entity
```

### 流式与结构化输出

```lisp
;; 流式（注意：kernel 层当前是同步降级，真 SSE 见 chat-model-stream）
(chat *kernel* (:user "写一首短诗")
      (:stream (lambda (delta) (princ delta))))

;; JSON 结构化输出——只解析，不校验
(chat *kernel* (:user "用 JSON 给出东京的信息") (:call :entity))
```

要「不符合 schema 就带着校验错误让模型重新输出」，挂 `validation-turn-filter`
——校验判据由它承担，`(:call :entity)` 本身只负责解析：

```lisp
(defvar *schema*
  "{\"type\":\"object\",
    \"properties\":{\"name\":{\"type\":\"string\"},
                   \"population\":{\"type\":\"integer\"}},
    \"required\":[\"name\",\"population\"]}")

(build-kernel
  :model *model*
  :filters (list (validation-turn-filter
                  ;; 判据：(response) → (values ok-p 反馈文本)
                  ;; 不合格时把反馈追加进 messages 递归重入整条循环，
                  ;; 让模型自我纠正（缺省最多重试 2 次）
                  (structured-output-validate-fn *schema* :parse-fn #'json-parse)
                  :max-retries 2)))
```

### 自定义 filter

```lisp
;; filter 钩子统一是 (lambda (req chain) ...)：
;; 前置改写 req → (funcall chain req) 进下游 → 后置加工返回值；
;; 不调 chain 就是短路（护栏即如此）。
(defun timing-filter ()
  (make-filter
   :timing
   :turn (lambda (req chain)
           (let ((start (get-internal-real-time)))
             (prog1 (funcall chain req)
               (format t "耗时 ~,2Fs~%"
                       (/ (- (get-internal-real-time) start)
                          internal-time-units-per-second)))))))

(build-kernel :model *model* :filters (list (timing-filter)))
```

## 模块说明

| 模块 | 包 | 描述 |
|------|---|------|
| **core** | `cl-agent.core` | 框架本体（单包）：基础设施 + HTTP/SSE + JSON Schema + `llm-chat` SPI + Chat API（消息/Prompt/Options/Response/deftool/ChatModel/ChatMemory）+ Kernel/Filter 三链 + `chat` 宏 |
| **llm** | `cl-agent.llm` | 提供商实现，`create-chat-model` 一步创建 ChatModel |
| **client** | `cl-agent.client` | SimpleAgent：有状态对话 + callbacks + 错误归一化 + HITL |
| **mock** | `cl-agent.mock` | Mock provider（测试/演示，无需 API 密钥） |
| **protocols** | — | A2A 协议支持（独立系统，**未完成且加载即报错**，不在主构建） |

## 安装与测试

```bash
# 加载（SBCL + Quicklisp）
sbcl --eval '(asdf:load-system :cl-agent)'

# 运行测试套件（全 mock，离线可跑）
sbcl --non-interactive --load run-tests.lisp

# 真实 provider 端到端验证（需 API 密钥）
MINIMAX_API_KEY=... sbcl --script scripts/live-test.lisp
```

当前：**761 checks / 0 failures**（全 mock，离线）；live **8/8**（MiniMax）。

## 示例

见 [examples/kernel-usage.lisp](examples/kernel-usage.lisp)：
8 个渐进示例覆盖 chat 宏、build-kernel、deftool、记忆、自定义 filter、
函数形态入口、结构化输出校验与流式。全部用 mock，无需 API 密钥。

真实 provider 的端到端验证（8 项：单次问答 / 工具循环 / 多轮记忆 /
schema 校验 / HITL 暂停·批准·拒绝 / SSE 分片）：

```bash
MINIMAX_API_KEY=... sbcl --script scripts/live-test.lisp
```

> mock 永远证明不了「真实模型会不会按我们的 schema 发工具调用」
> 「暂停时工具是否真的没执行」这类问题——live 脚本补的就是那一段。

## 文档

- [快速开始指南](docs/QUICKSTART_CN.md)
- [API 参考](docs/API_CN.md)
- [工具调用架构](docs/tool-calling_CN.md) —— Filter 与 Manager 的分工、
  Spring AI 2.0 对应关系与已知偏差

## 迁移说明

Spring AI 的两大移植层已整体退役，包结构也做过一轮合并。

**Advisor → Filter**

| 旧 | 新 |
|---|---|
| `defadvisor` / `advise-call` / `chain-next` | `make-filter` / `defilter` + `build-chain` 三链 |
| `:advisors (list ...)` | `build-kernel :filters (list ...)` |
| `message-chat-memory-advisor` | `memory-filter` |
| `safe-guard-advisor` | `safeguard-turn-filter` |
| `structured-output-validation-advisor` | `validation-turn-filter` |
| `tool-search-tool-calling-advisor` | `tool-search-filter` |
| `tool-calling-advisor` | `run-tool-loop`（`:turn` 链终端，非 filter） |

**ChatClient → Kernel / SimpleAgent**

| 旧 | 新 |
|---|---|
| `make-chat-client` / `make-kernel-client` | `build-kernel`（`:model` 是**关键字**参数） |
| `chat-client-builder` + `default-system` … | `build-kernel :system ...` |
| fluent spec（`client-prompt` → `prompt-user` → `call-content`） | `chat` 宏子句，或 `kernel-chat-text` |
| `(:call :client-response)` | `(:call :result)`（返回 turn-result） |

**包合并**（`cl-agent.http` / `.chat` / `.kernel` → `cl-agent.core`）

| 旧 | 新 |
|---|---|
| `cl-agent.kernel:build-kernel` | `cl-agent.core:build-kernel` |
| `cl-agent.chat:deftool` | `cl-agent.core:deftool` |
| `cl-agent.http:http-request` | `cl-agent.core:http-request` |
| `cl-agent.kernel:tool-response` | `cl-agent.core:tool-result`（`make-tool-result :value ...`） |

`cl-agent.client` 这个名字被**复用**了：它曾是 ChatClient 移植层（已删），
现在是 SimpleAgent。

与 Spring AI 的能力对应关系见 [docs/tool-calling_CN.md](docs/tool-calling_CN.md)。

## 许可证

MIT License
