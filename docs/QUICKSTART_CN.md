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

`build-kernel` 装配，`chat` 宏发起——两步，没有别的层。

```lisp
(defvar *kernel* (cl-agent.kernel:build-kernel :model *model*))

;; chat 宏：最简形式
(cl-agent.kernel:chat *kernel* "你好！")

;; 完整子句
(cl-agent.kernel:chat *kernel*
  (:system "你是一个言简意赅的助手")
  (:user "用一句话介绍 Common Lisp")
  (:options :temperature 0.2))
```

> `build-kernel` 的 `:model` 是**关键字参数**，不是位置参数。
> `(build-kernel :model *model*)` 建的 kernel 没有任何 filter——只有模型调用 +
> 工具循环。要挂横切能力（记忆/护栏/日志…）见第 7 节的 `:filters`。

程序拼参数时，用函数形态比宏顺手（`chat` 宏正是展开到它们）：

```lisp
(cl-agent.kernel:kernel-chat-text *kernel*
  :system "你是一个翻译"
  :user (format nil "翻译：~A" "hello world"))
```

`kernel-chat` 返回 `turn-result`，`kernel-chat-text` 取文本，
`kernel-chat-entity` 取 JSON，`kernel-chat-stream` 走流式。

### 包与 :use —— 两个包可直接一起 :use

`cl-agent.chat` 与 `cl-agent.kernel` **无任何同名导出**，直接一起 `:use`
即可，不需要任何 shadowing：

```lisp
(defpackage :my-app
  (:use :cl :cl-agent.chat :cl-agent.kernel))
```

`examples/kernel-usage.lisp` 与 `scripts/live-test.lisp` 就是这么写的。
不 `:use`、一律写全限定名亦可——本文其余部分都用全限定名。

> 曾经不行：两个包一度共用 `tool-response` / `make-tool-response` 与
> `execute-tool-calls`，逼得 kernel 必须 `:shadow`，下游还得自己写
> `:shadowing-import-from`。现在 kernel 的载体已改名为 `tool-request` /
> `tool-result`，chat 的旧 ToolCallingManager 也已删除，kernel 不再有任何
> `:shadow`。

## 4. 装配 kernel：默认值放哪

**没有 Builder。** kernel 的装配就是 `build-kernel` 的关键字参数，一次请求的
覆盖就是 `chat` 宏的子句：

```lisp
(defvar *kernel*
  (cl-agent.kernel:build-kernel
    :model *model*                       ; ChatModel
    :system "你是一个天气助手"            ; 默认 system（请求级 (:system ...) 覆盖）
    :options (cl-agent.chat:make-chat-options :temperature 0.3)  ; 默认选项
    :tools '(get-weather)                ; 默认工具（请求级 (:tools ...) 与之取并集）
    :filters (list ...)                  ; 横切能力（见第 7 节）
    :settings '((:max-tool-iterations . 10))))
```

没有 Builder——kernel 的装配就是 `build-kernel` 的关键字参数。
旧 Builder 的三个默认值一一对应：

| 旧 Builder | 现在放哪 |
|---|---|
| `default-tools` | `build-kernel :tools` |
| `default-options` | `build-kernel :options`（请求级 `(:options ...)` 合并覆盖） |
| `default-system` | `build-kernel :system`（请求级 `(:system ...)` 覆盖） |

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

;; 对话中启用：模型请求工具时，kernel 的 run-tool-loop 执行工具并回传模型
(cl-agent.kernel:chat *kernel*
  (:user "东京的天气怎么样？")
  (:tools 'get-weather))
```

要点：

- lambda-list 必须是 `&key` 风格（LLM 工具参数是命名参数）
- 工具名自动转小写下划线风格：`get-weather` → `"get_weather"`
- 工具身份即符号，`(:tools 'get-weather)` 引用；也可在 kernel 上声明
  `:tools '(get-weather)` 作为 kernel 级默认——请求级与 kernel 级**取并集**
- `(:return-direct t)` 子句让工具结果直接返回调用方（不回传模型）
- `(:serial t)` 声明该工具有副作用：批次内任一工具声明 `:serial`，
  整批退化为顺序执行（缺省整批并行）
- 声明 `tool-context` 参数可接收宿主注入的上下文：
  `(make-chat-options :tool-context '(:tenant "acme"))`

工具循环由 `cl-agent.kernel:run-tool-loop` 承担——它是 `:turn` 链的终端，
不是 filter，也不在 ChatModel 里（`chat-model-call` 是单次调用语义）。
最大迭代次数经 kernel settings 配置（缺省 10）：

```lisp
(cl-agent.kernel:build-kernel
  :model *model*
  :tools '(get-weather)
  :settings '((:max-tool-iterations . 5)))
```

运行时也可以不用宏：

```lisp
(cl-agent.chat:make-tool-callback
  (lambda (&key expression) (calc expression))
  :name "calculate"
  :description "计算数学表达式"
  :parameters '((expression :string "表达式" :required-p t)))
```

## 6. 会话记忆（ChatMemory）

记忆是一个 filter，挂在 `:chat` 链上（循环内每轮生效）：

```lisp
(defvar *memory* (cl-agent.chat:make-message-window-chat-memory
                  :max-messages 20))

(defvar *kernel*
  (cl-agent.kernel:build-kernel
    :model *model*
    :filters (list (cl-agent.kernel:memory-filter *memory*))))

;; 同一 :conversation 共享记忆
(cl-agent.kernel:chat *kernel* (:user "我叫大卫") (:conversation "c1"))
(cl-agent.kernel:chat *kernel* (:user "我叫什么？") (:conversation "c1"))
;; => 模型能看到第一轮历史

;; 检查/清空记忆
(cl-agent.chat:memory-messages *memory* "c1")
(cl-agent.chat:memory-clear *memory* "c1")
```

自定义存储后端：实现 `repository-find` / `repository-save` /
`repository-delete` / `repository-conversation-ids` 四个泛型函数即可。

## 7. Filter：kernel 的洋葱链

Filter 是环绕执行的洋葱层（对标 Spring AI 的 Advisor API）。每个 filter
最多挂四个钩子，对应三条链 + 流式 transducer：

| 钩子 | 环绕什么 | 载体 |
|---|---|---|
| `:chat` | 一次 LLM 调用（循环内每轮） | `prompt` → `chat-response` |
| `:tool` | 一次工具执行 | `tool-request` → `tool-result` |
| `:turn` | 一整轮对话（含整个工具循环） | `turn-request` → `turn-result` |
| `:token-xform` | 流式 token 变换 | transducer 风格函数 |

每个钩子统一是 `(lambda (req chain) ...)`：前置改写 `req` →
`(funcall chain req)` 进下游 → 后置加工返回值；**不调 `chain` 就是短路**。

```lisp
(defun timing-filter ()
  (cl-agent.kernel:make-filter
   :timing
   :turn (lambda (req chain)
           (let ((start (get-internal-real-time)))
             (prog1 (funcall chain req)
               (format t "耗时 ~,2Fs~%"
                       (/ (- (get-internal-real-time) start)
                          internal-time-units-per-second)))))))

(defvar *kernel*
  (cl-agent.kernel:build-kernel
    :model *model*
    :filters (list (timing-filter)
                   (cl-agent.kernel:safeguard-turn-filter '("密码"))
                   (cl-agent.kernel:logging-chat-filter))
    :tools '(get-weather)))
```

**`filters` 的列表顺序即洋葱层级：靠前 = 靠外 = 先执行**——没有 order
字段，层级完全由位置决定。上例的层级是
`timing → safeguard → run-tool-loop`（`:turn` 链）与
`logging → chat-model-call`（`:chat` 链）。

内置 filter：

| Filter | 链 | 作用 |
|---|---|---|
| `(memory-filter store &key window)` | `:chat` | 历史作为消息注入（对标 `MessageChatMemoryAdvisor`） |
| `(logging-chat-filter &key log-fn preview)` | `:chat` | 请求/响应日志 |
| `(logging-tool-filter &key log-fn)` | `:tool` | 工具名/参数/结果日志 |
| `(safeguard-turn-filter keywords &key failure-response)` | `:turn` | 敏感词短路护栏 |
| `(validation-turn-filter validate-fn &key max-retries)` | `:turn` | 校验失败 → 反馈重入 |
| `(re-reading-filter &key template)` | `:turn` | Re2 重读提示改写 |
| `(qa-turn-filter retriever &key top-k)` | `:turn` | RAG 检索注入 |
| `(tool-search-filter index &key limit)` | `:chat` | 渐进式工具披露（大工具集省 token） |
| `(timeout-filter milliseconds)` | `:tool` | 工具执行超时 |
| `(approval-filter &key approve-fn sensitive-names)` | `:tool` | 敏感工具审批门 |
| `(token-redact-filter patterns &key replacement)` | `:token-xform` | 流式脱敏 |
| `(hold-release-filter &key approve-fn)` | `:token-xform` | 流式缓冲/放行 |

也可以用 `defilter` 宏一次定义 filter 类 + 构造函数（钩子 lambda-list 是
`(self req chain)`）：

```lisp
(cl-agent.kernel:defilter counting-filter ((count :initform 0 :accessor fc-count))
  (:turn (self req chain)
    (incf (fc-count self))
    (funcall chain req)))

(make-counting-filter)
```

> **Advisor 与 ChatClient 两层移植物均已退役。**
> - **Advisor**：`defadvisor` / `advise-call` / `chain-next` /
>   `make-simple-logger-advisor` 等符号已整体删除。
>   迁移：`:advisors (list ...)` → `build-kernel :filters (list ...)`。
> - **ChatClient**：`cl-agent.client` 整包（ChatClient / Builder / fluent
>   RequestSpec）已删除。迁移：`make-kernel-client` / `make-chat-client` →
>   `build-kernel`；fluent spec（`client-prompt` → `prompt-user` →
>   `call-content`）→ `chat` 宏子句或 `kernel-chat-text`；
>   `(:call :client-response)` → `(:call :result)`。
>
> `(chat kernel (:advisors ...))` 会**直接报错**并给出迁移指引（而不是静默
> 忽略——否则记忆/护栏会无声失效）。完整对照表见
> [API 参考](API_CN.md#迁移)。

## 8. 流式与结构化输出

```lisp
;; 流式
(cl-agent.kernel:chat *kernel*
  (:user "写一首关于 Lisp 的短诗")
  (:stream (lambda (delta) (princ delta) (force-output))))

;; 结构化输出（JSON → hash-table）
(let ((entity (cl-agent.kernel:chat *kernel*
                (:user "用 JSON 给出东京信息（name/population）")
                (:call :entity))))
  (gethash "name" entity))
```

> `(:call :entity)` **只解析 JSON，不校验 schema、不重试**：它给请求追加一条
> 「只输出 JSON」的系统消息，剥掉 markdown 围栏，然后 `json-parse`。
> 没有 schema 参数——校验挂 `validation-turn-filter`（见下）。

要看 `turn-result-status` 之类的整轮信息，用 `(:call :result)`：

```lisp
(let ((result (cl-agent.kernel:chat *kernel* (:user "你好") (:call :result))))
  (values (cl-agent.kernel:turn-result-status result)          ; :completed / :cancelled ...
          (cl-agent.kernel:turn-result-tool-calls-made result)))
```

要「不符合 schema 就带着校验错误让模型重新输出」（对标 Spring AI 2.0 的
`StructuredOutputValidationAdvisor`），给 kernel 挂 `validation-turn-filter`
——校验判据由它承担：

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
                    ;; 判据：(response) → (values ok-p 反馈文本)
                    (cl-agent.kernel:structured-output-validate-fn
                     *schema* :parse-fn #'cl-agent.core:json-parse)
                    :max-retries 2))))

(let ((entity (cl-agent.kernel:chat *validating-kernel*
                (:user "用 JSON 给出东京信息")
                (:call :entity))))
  (gethash "population" entity))
```

`validation-turn-filter` 挂在 `:turn` 链上：不合格时把反馈文本作为 user 消息
追加进 messages，**递归重入整条循环**（`max-retries` 缺省 2，即最多 3 次）；
重试用尽仍不合格则原样返回最后一次结果，不发条件。
`:paused` / `:cancelled` / `:error` 状态的结果直接透传、不重入。

`structured-output-validate-fn` 的 `:parse-fn` 必须给——不给解析器时它无从
校验结构，一律放行。

> **流式说明**：`(:stream cb)` 当前降级为同步调用（完整文本作为单个 chunk
> 回调）。真 SSE 流式在 ChatModel 层（`cl-agent.chat:chat-model-stream`）；
> kernel 的流式 invoke 尚未落地。

## 9. 运行测试

```bash
# 测试套件（全 mock，离线可跑）
sbcl --non-interactive --load run-tests.lisp

# 真实 provider 端到端验证（需 API 密钥）
MINIMAX_API_KEY=... sbcl --script scripts/live-test.lisp
```

`run-tests.lisp` 全用 mock：离线、确定性、零 API 花费。但 mock 证明不了
「真实模型会不会按我们的 schema 发工具调用」「真实 SSE 分片能不能拼回」——
`scripts/live-test.lisp` 补的就是那一段（工具循环 / 记忆 / schema 校验 / 流式）。

## 下一步

- [API 参考](API_CN.md) —— 含 [ChatClient / Advisor 迁移对照表](API_CN.md#迁移)
- [工具调用架构](tool-calling_CN.md) —— Filter 与 Manager 的分工
- [完整示例](../examples/kernel-usage.lisp) —— 8 个渐进示例，全部用 mock，
  无需 API 密钥
