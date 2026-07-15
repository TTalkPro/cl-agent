# CL-Agent 快速开始

[English](QUICKSTART.md)

本指南带你从零跑通 CL-Agent（Spring AI 2.0 对标架构）。

## 1. 环境准备

- SBCL（推荐 2.4+）
- Quicklisp

```bash
git clone https://github.com/example/cl-agent.git
cd cl-agent
sbcl
```

```lisp
;; 注册本地系统路径后加载
(dolist (dir '("." "core/" "llm/" "mock/"))
  (pushnew (truename dir) asdf:*central-registry* :test #'equal))
(asdf:load-system :cl-agent)
```

## 2. 创建 ChatModel

ChatModel 是对具体 LLM 提供商的统一抽象（对标 Spring AI `ChatModel`）。

```lisp
;; Anthropic（读 ANTHROPIC_API_KEY 环境变量）
(defvar *model*
  (cl-agent.llm:create-chat-model :anthropic
    :model "claude-sonnet-4-20250514"))

;; OpenAI / 智谱 / Ollama / DashScope / MiniMax 同理
(cl-agent.llm:create-chat-model :openai :model "gpt-4o")
(cl-agent.llm:create-chat-model :zhipu :model "glm-4-plus")
(cl-agent.llm:create-chat-model :ollama :model "llama3")

;; 可携带模型级默认选项
(cl-agent.llm:create-chat-model :anthropic
  :model "claude-sonnet-4-20250514"
  :options (cl-agent.chat:make-chat-options :temperature 0.3
                                            :max-tokens 1024))

;; 无 API 密钥时用 mock 演示
(asdf:load-system :cl-agent-mock)
(defvar *model*
  (cl-agent.chat:make-provider-chat-model (cl-agent.mock:make-mock-llm)))
```

## 3. 第一次对话

```lisp
(defvar *client* (cl-agent.client:make-chat-client *model*))

;; chat 宏：最简形式
(cl-agent.client:chat *client* "你好！")

;; 完整子句
(cl-agent.client:chat *client*
  (:system "你是一个言简意赅的助手")
  (:user "用一句话介绍 Common Lisp")
  (:options :temperature 0.2))
```

也可以用 fluent 管道（对标 Java 链式调用）：

```lisp
(cl-agent.core:->
  (cl-agent.client:client-prompt *client*)
  (cl-agent.client:prompt-system "你是一个翻译")
  (cl-agent.client:prompt-user "翻译：~A" "hello world")
  (cl-agent.client:call-content))
```

## 4. Builder 模式

```lisp
(defvar *client*
  (cl-agent.core:->
    (cl-agent.client:chat-client-builder *model*)
    (cl-agent.client:default-system "你是一个助手")
    (cl-agent.client:default-options
      (cl-agent.chat:make-chat-options :temperature 0.3))
    (cl-agent.client:default-advisors
      (cl-agent.client:make-simple-logger-advisor))
    (cl-agent.client:build-client)))
```

## 5. 工具调用（deftool）

`deftool` 对标 Spring AI 的 `@Tool` 注解：定义普通函数的同时，
自动派生 JSON Schema 并注册为 ToolCallback。

```lisp
(cl-agent.chat:deftool get-weather (&key city (unit "celsius"))
  "获取指定城市的当前天气"
  (:param city :string "城市名称" :required t)
  (:param unit :string "温度单位")
  (format nil "~A 的天气：22°C（~A），晴" city unit))

;; 普通函数照常可调
(get-weather :city "东京")

;; 对话中启用：模型请求工具时，自动注册的 tool-calling-advisor
;; 执行工具并回传模型（2.0 架构，循环在 Advisor 链中）
(cl-agent.client:chat *client*
  (:user "东京的天气怎么样？")
  (:tools 'get-weather))
```

要点：

- lambda-list 必须是 `&key` 风格（LLM 工具参数是命名参数）
- 工具名自动转小写下划线风格：`get-weather` → `"get_weather"`
- `(:return-direct t)` 子句让工具结果直接返回调用方（不回传模型）
- 声明 `tool-context` 参数可接收宿主注入的上下文：
  `(make-chat-options :tool-context '(:tenant "acme"))`

运行时也可以不用宏：

```lisp
(cl-agent.chat:make-tool-callback
  (lambda (&key expression) (calc expression))
  :name "calculate"
  :description "计算数学表达式"
  :parameters '((expression :string "表达式" :required-p t)))
```

## 6. 会话记忆（ChatMemory）

```lisp
(defvar *memory* (cl-agent.chat:make-message-window-chat-memory
                  :max-messages 20))

(defvar *client*
  (cl-agent.client:make-chat-client *model*
    :advisors (list (cl-agent.client:make-message-chat-memory-advisor
                     :memory *memory*))))

;; 同一 :conversation 共享记忆
(cl-agent.client:chat *client* (:user "我叫大卫") (:conversation "c1"))
(cl-agent.client:chat *client* (:user "我叫什么？") (:conversation "c1"))
;; => 模型能看到第一轮历史

;; 检查/清空记忆
(cl-agent.chat:memory-messages *memory* "c1")
(cl-agent.chat:memory-clear *memory* "c1")
```

自定义存储后端：实现 `repository-find` / `repository-save` /
`repository-delete` / `repository-conversation-ids` 四个泛型函数即可。

## 7. 自定义 Advisor

Advisor 是环绕每次调用的洋葱链（对标 Spring AI Advisor API）。
`order` 越小越靠外。

```lisp
(cl-agent.client:defadvisor timing-advisor (:order -100)
  (:call (advisor request chain)
    (declare (ignore advisor))
    (let ((start (get-internal-real-time)))
      (prog1 (cl-agent.client:chain-next chain request)
        (format t "耗时 ~,2Fs~%"
                (/ (- (get-internal-real-time) start)
                   internal-time-units-per-second))))))

;; 请求级挂载
(cl-agent.client:chat *client*
  (:user "hi")
  (:advisors (make-timing-advisor)))
```

内置 Advisor：

| Advisor | 作用 | 默认 order |
|---|---|---|
| `simple-logger-advisor` | 请求/响应日志 | `+simple-logger-advisor-order+`（-1000） |
| `safe-guard-advisor` | 敏感词短路护栏 | `+safe-guard-advisor-order+`（-500） |
| `message-chat-memory-advisor` | 历史作为消息注入 | `+chat-memory-advisor-order+`（1000） |
| `tool-calling-advisor` | 工具执行循环（自动注册） | `+tool-calling-advisor-order+`（2000） |
| `tool-search-tool-calling-advisor` | 渐进式工具披露（大工具集省 token） | 同上（2000） |
| `structured-output-validation-advisor` | JSON Schema 校验 + 失败自纠 | `+structured-output-validation-advisor-order+`（3000） |

order 越小越靠外。默认布局（由外到内）：

```
logger → safe-guard → memory → tool-calling → structured-output → ChatModel
```

> **与 Spring AI 2.0 的差异**：Spring 把 `SafeGuardAdvisor`/`SimpleLoggerAdvisor`
> 放在工具循环*内侧*（order 0），好处是每轮迭代都重新检查、能拦住工具结果里的
> 敏感内容，代价是记忆在护栏外侧——敏感输入会先写进记忆才被拦下。
> 本实现把护栏放在记忆外侧，优先保证敏感输入不进入记忆。需要 Spring 那种语义时
> 显式传 `:order (1+ +tool-calling-advisor-order+)` 即可。
>
> `PromptChatMemoryAdvisor` 在 Spring AI 2.0 中已被移除，本实现同步移除。

## 8. 流式与结构化输出

```lisp
;; 流式
(cl-agent.client:chat *client*
  (:user "写一首关于 Lisp 的短诗")
  (:stream (lambda (delta) (princ delta) (force-output))))

;; 结构化输出（JSON → hash-table）
(let ((entity (cl-agent.client:chat *client*
                (:user "用 JSON 给出东京信息（name/population）")
                (:call :entity))))
  (gethash "name" entity))

;; 带 JSON Schema 校验（对标 StructuredOutputValidationAdvisor）：
;; 输出不符合 schema 时，把校验错误追加到 user 消息让模型重新输出，
;; 默认最多重试 3 次；用尽仍不合格则返回最后一次响应，不发条件。
(let ((entity (cl-agent.client:chat *client*
                (:user "用 JSON 给出东京信息")
                (:call :entity
                       "{\"type\":\"object\",
                         \"properties\":{\"name\":{\"type\":\"string\"},
                                        \"population\":{\"type\":\"integer\"}},
                         \"required\":[\"name\",\"population\"]}"))))
  (gethash "population" entity))

;; 或显式挂载，精确控制重试次数
(cl-agent.client:make-chat-client *model*
  :advisors (list (cl-agent.client:make-structured-output-validation-advisor
                   :json-schema schema
                   :max-repeat-attempts 5)))
```

> 结构化输出校验 Advisor 不支持流式（校验需要完整 JSON 文本），
> 用在流式链上会发 `structured-output-streaming-unsupported-error`。

## 9. 运行测试

```bash
sbcl --non-interactive --load run-tests.lisp
```

## 下一步

- [API 参考](API_CN.md)
- [完整示例](../examples/chat-client-usage.lisp)
