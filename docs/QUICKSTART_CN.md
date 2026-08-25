# CL-Agent 快速开始

[English](QUICKSTART.md)

本指南带你从零跑通 CL-Agent。两种用法，按需选：

- **SimpleAgent**（第 3～6 节，推荐入门）：一个有状态的 agent 对象，管住会话、
  可观测性、错误归一化与人工审批（HITL）。
- **ChatClient + Filter**（第 7 节起，完全控制）：三链洋葱中间件 + 工具循环。

前者是后者的薄封装，随时可下沉。

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
(dolist (dir '("." "core/" "llm/" "mock/" "client/"))
  (pushnew (truename dir) asdf:*central-registry* :test #'equal))
(asdf:load-system :cl-agent)
```

### 包与 :use

现在只有三个包要打交道：`cl-agent/core`（框架本体）、`cl-agent/client`
（SimpleAgent）、`cl-agent/llm`（提供商）。**前两个可以直接一起 `:use`，
无需任何 shadowing**：

```lisp
(defpackage :my-app
  (:use :cl :cl-agent/core :cl-agent/client))
(in-package :my-app)
```

`examples/chat-client-usage.lisp` 与 `scripts/live-test.lisp` 就是这么写的
（它们只 `:use` core）。不 `:use`、一律写全限定名亦可——本文其余部分
都用全限定名。

> 曾经的 `cl-agent/http` / `cl-agent/chat` / `cl-agent/chat-client` 三个包已
> **合并进 `cl-agent/core`**。旧代码里的 `cl-agent/chat-client:build-chat-client`、
> `cl-agent/chat:deftool` 一律改写成 `cl-agent/core:` 前缀即可；
> 昵称 `cla/chat-client` / `cla/chat` / `cla/http` 统一为 `cla/core`。
> 合并顺带消掉了所有 `:shadow`——旧文档里教你写 `:shadowing-import-from`
> 的段落已经作废。

## 2. 创建 ChatModel

ChatModel 是对具体 LLM 提供商的统一抽象（对标 Spring AI `ChatModel`）。

```lisp
;; Anthropic（读 ANTHROPIC_API_KEY 环境变量）
(defvar *model*
  (cl-agent/llm:create-chat-model :anthropic
    :model "claude-sonnet-4-20250514"))

;; OpenAI / 智谱 / Ollama / DashScope / MiniMax 同理
(cl-agent/llm:create-chat-model :openai :model "gpt-4o")
(cl-agent/llm:create-chat-model :zhipu :model "glm-4-plus")
(cl-agent/llm:create-chat-model :ollama :model "llama3")

;; 可携带模型级默认选项
(cl-agent/llm:create-chat-model :anthropic
  :model "claude-sonnet-4-20250514"
  :options (cl-agent/core:make-chat-options :temperature 0.3
                                           :max-tokens 1024))

;; 无 API 密钥时用 mock 演示
(asdf:load-system :cl-agent-mock)
(defvar *model*
  (cl-agent/core:make-provider-chat-model (cl-agent/mock:make-mock-llm)))
```

### 重试

**缺省不重试。** 重试是 ChatModel 层的能力——provider 只负责「底层信息 +
如何调用」，一次调用失败要不要再来一次是模型层的编排决策，所以同一个
provider 可以配不同的重试预算：

```lisp
(cl-agent/llm:create-chat-model :anthropic
  :model "claude-sonnet-4-20250514"
  :retry-policy (cl-agent/core:make-retry-policy
                  :max-attempts 4      ; 总尝试次数（**含**首次）
                  :initial-delay 1.0   ; 首次重试前延迟（秒）
                  :backoff 2.0))       ; 退避倍数，另带 ±10% 抖动
```

要不要重试由 `cl-agent/core:error-retryable-p` 单一裁定：瞬态 HTTP 状态
（408/409/425/429/5xx）与网络层失败可重试，鉴权/参数错不重试。重试耗尽后
原样抛出最后一次的条件，不做包装。

> 流式路径上已经吐给回调的 token 不会被撤回，流跑到一半断掉再重试会让
> 调用方看到前半段重复。流式通常应把 `retry-policy` 留空。

### 观测

两个层次，分工不同：

```lisp
;; ChatModel 层：包住一次**逻辑**调用（含重试，记一条）——算延迟用
(cl-agent/llm:create-chat-model :anthropic
  :observation-fn (lambda (model prompt thunk)
                    (declare (ignore model prompt))
                    (let ((start (get-internal-real-time)))
                      (prog1 (funcall thunk)
                        (format t "~Dms~%"
                                (round (- (get-internal-real-time) start)
                                       (/ internal-time-units-per-second 1000)))))))

;; Provider 层：包住每一次**真实 wire 调用**（重试三次触发三次）——算钱用
(let* ((tally (cl-agent/core:make-llm-usage-tally))
       (cl-agent/core:*llm-call-observer*
         (cl-agent/core:usage-tally-observer tally)))
  (cl-agent/core:chat *chat-client* "你好")
  (cl-agent/core:usage-tally-output-tokens tally))
```

`*llm-call-observer*` 是动态变量，一个 `let` 绑定即对**所有** provider 生效。

## 3. 第一次对话：SimpleAgent

`make-agent` 建一个有状态 agent，`agent-chat` 对话——上下文自动累积，
不用自己传 conversation-id。

```lisp
(defvar *a*
  (cl-agent/client:make-agent
    :model *model*
    :system "你是一个言简意赅的助手"))

(cl-agent/client:agent-chat *a* "你好！")
(cl-agent/client:agent-chat *a* "用一句话介绍 Common Lisp")
(cl-agent/client:agent-chat *a* "再短一点")   ; 记得上一轮

(cl-agent/client:agent-history *a*)          ; 完整消息历史
(cl-agent/client:agent-turn-count *a*)       ; 已完成轮数
(cl-agent/client:agent-reset *a*)            ; 清空会话重来
```

`make-agent` 的常用参数：

```lisp
(cl-agent/client:make-agent
  :model *model*                          ; ChatModel（不给 :chat-client 时必填）
  :system "你是一个天气助手"                ; 默认系统提示
  :options (cl-agent/core:make-chat-options :temperature 0.3)
  :tools '(get-weather)                   ; 工具符号列表（见第 4 节）
  :memory store                           ; 缺省 = 新建滑动窗口记忆；nil = 无记忆
  :conversation-id "c1"                   ; 缺省自动生成
  :max-tool-iterations 10
  :callbacks (list ...)                   ; 可观测性（见第 5 节）
  :chat-client prebuilt-chat-client)                ; 自建 chat-client（见第 7 节）
```

> **`make-agent` 不接受 `:filters`**——传了会**直接报错**并给出迁移指引。
> agent 层只暴露 `:callbacks`；要挂 filter 请自建 chat-client 经 `:chat-client` 传入
> （见第 7 节）。这条边界是刻意的：简单层一旦开始转发 filter，
> 就会慢慢长成第二个 chat-client。

### 结果与错误：不抛异常

`agent-chat` 出错时返回 `(values nil result)`。要完整结果用
`agent-chat-result`：

```lisp
(let ((r (cl-agent/client:agent-chat-result *a* "你好")))
  (cl-agent/client:agent-result-status r))
;; => :completed | :paused | :cancelled | :error
```

| status | 含义 | 取值处 |
|---|---|---|
| `:completed` | 正常完成 | `agent-result-text` / `agent-result-response` |
| `:paused` | 工具待审批（见第 6 节） | `agent-result-pending-tool` / `agent-result-pause-reason` |
| `:cancelled` | 被 filter 短路（如护栏命中敏感词） | — |
| `:error` | LLM/工具/其它异常 | `agent-result-error`（条件对象） |

一次 LLM 调用失败是**预期内的常态**（网络抖动、限流、模型抽风），
所以 agent 层把它归一化成状态，而不是把条件抛给调用方。
`agent-chat-result` 与 `agent-resume` **都不发条件**。

## 4. 工具调用（deftool）

`deftool` 对标 Spring AI 的 `@Tool` 注解：定义普通函数的同时，
自动派生 JSON Schema 并注册为 ToolCallback。

```lisp
(cl-agent/core:deftool get-weather (&key city (unit "celsius"))
  "获取指定城市的当前天气"
  (:param city :string "城市名称" :required t)
  (:param unit :string "温度单位")
  (format nil "~A 的天气：22°C（~A），晴" city unit))

;; 普通函数照常可调
(get-weather :city "东京")

;; 交给 agent：模型请求工具时自动执行并回传模型
(defvar *a*
  (cl-agent/client:make-agent :model *model* :tools '(get-weather)))

(cl-agent/client:agent-chat *a* "东京的天气怎么样？")
```

要点：

- lambda-list 必须是 `&key` 风格（LLM 工具参数是命名参数）
- 工具名自动转小写下划线风格：`get-weather` → `"get_weather"`
- 工具身份即符号，`:tools '(get-weather)` 引用，无全局副作用
- `(:return-direct t)` 子句让工具结果直接返回调用方（不回传模型）
- `(:serial t)` 声明该工具有副作用：批次内任一工具声明 `:serial`，
  整批退化为顺序执行（缺省整批并行）
- 声明 `tool-context` 参数可接收宿主注入的上下文：
  `(make-chat-options :tool-context '(:tenant "acme"))`

工具循环由 `cl-agent/core:run-tool-loop` 承担——它是 `:turn` 链的终端，
不是 filter，也不在 ChatModel 里（`chat-model-call` 是单次调用语义）。
最大迭代次数经 settings 配置（缺省 10）：

```lisp
(cl-agent/client:make-agent
  :model *model*
  :tools '(get-weather)
  :max-tool-iterations 5)
```

运行时也可以不用宏：

```lisp
(cl-agent/core:make-tool-callback
  (lambda (&key expression) (calc expression))
  :name "calculate"
  :description "计算数学表达式"
  :parameters '((expression :string "表达式" :required-p t)))
```

## 5. 可观测性：callbacks

agent 层的横切入口是 `:callbacks`——一个 plist：

```lisp
(defvar *a*
  (cl-agent/client:make-agent
    :model *model* :tools '(get-weather)
    :callbacks (list :on-turn-start  (lambda (a) (format t "~&开始~%"))
                     :on-turn-end    (lambda (a r) (format t "~&完成 ~A~%"
                                                           (cl-agent/client:agent-result-status r)))
                     :on-turn-error  (lambda (a e) (format t "~&出错 ~A~%" e))
                     :on-tool-call   (lambda (name args) (format t "~&调用 ~A ~S~%" name args))
                     :on-tool-result (lambda (name text) (format t "~&结果 ~A: ~A~%" name text)))))
```

| 回调 | 签名 | 时机 |
|---|---|---|
| `:on-turn-start` | `(agent)` | 每轮开始前 |
| `:on-turn-end` | `(agent result)` | 每轮正常结束 |
| `:on-turn-error` | `(agent condition)` | 该轮出异常 |
| `:on-tool-call` | `(name args)` | 工具**执行前**（返回值可触发 HITL，见第 6 节） |
| `:on-tool-result` | `(name text)` | 工具执行后 |
| `:on-interrupt` | `(agent result)` | 轮次因待审批而暂停 |
| `:on-resume` | `(agent decision)` | `agent-resume` 续跑前 |

**回调抛异常不会掀翻整轮对话**——它们是观测手段，不是控制流，
异常会被记进日志然后忽略。

## 6. 人工审批（HITL）

**配 `:on-tool-call` 让它返回 `(:interrupt . 原因)` 即启用**——不是另一套
机制，就是回调的返回值：

```lisp
(cl-agent/core:deftool rm-file (&key path)
  "删除文件"
  (:param path :string "文件路径" :required t)
  (format nil "已删除 ~A" path))

(defvar *a*
  (cl-agent/client:make-agent
    :model *model* :tools '(rm-file)
    :callbacks (list :on-tool-call
                     (lambda (name args)
                       (when (string= name "rm_file")
                         (cons :interrupt
                               (format nil "删除 ~A 需审批" (getf args :path))))))))

(let ((r (cl-agent/client:agent-chat-result *a* "删除 /tmp/x.log")))
  (cl-agent/client:agent-result-status r)        ; => :paused
  (cl-agent/client:agent-result-pause-reason r)  ; => "删除 /tmp/x.log 需审批"
  (cl-agent/client:agent-result-pending-tool r)) ; => #<PENDING-TOOL rm_file (:PATH "/tmp/x.log")>
```

**关键不变式：暂停时工具一个都没执行。** 审批后续跑：

```lisp
;; 批准
(cl-agent/client:agent-resume *a* :approved)

;; 编辑后批准（用新参数执行）
(cl-agent/client:agent-resume *a* :approved :payload '(:args (:path "/tmp/safe.log")))

;; 拒绝（理由作为工具结果回模型，省它一轮干猜）
(cl-agent/client:agent-resume *a* :rejected :payload '(:message "生产库禁止删除"))

;; 答复即结果（ask-user 语义：答复直接作为该工具的结果）
(cl-agent/client:agent-resume *a* :reply :payload '(:message "该文件已被清理"))
```

| decision | 语义 |
|---|---|
| `:approved` | 批准执行；`:payload (:args ...)` 可改参数后再执行 |
| `:rejected` | 不执行；`(:message 理由)` 作为工具结果回模型 |
| `:reply` | 不执行；`(:message 答复)` **直接**作为工具结果（ask-user 语义） |

查询暂停态：

```lisp
(cl-agent/client:agent-paused-p *a*)      ; => t / nil
(cl-agent/client:agent-pending-tool *a*)  ; => 待审批的 tool-call
```

续跑后可能**再次 `:paused`**（本批还有别的敏感工具，或后续轮次又触发）——
按状态循环处理即可，别假设 resume 一次就到底。

## 7. ChatClient：完全控制

需要 filter（记忆策略、护栏、RAG、校验…）时下沉到 chat-client。
`build-chat-client` 装配，`chat` 宏发起。

ChatClient 是**四个槽**（对标 Spring AI 的 ChatClient）：`model`（往哪调）、
`filters`（链上有谁）、`default-request`（请求默认长什么样：system / options /
tools）、`tool-calling`（工具循环怎么跑）。刻意**没有** memory 槽——记忆是
filter，不是它的固有属性。

`build-chat-client` 接受扁平参数，内部聚合成后两个值对象：

```lisp
(defvar *chat-client*
  (cl-agent/core:build-chat-client
    :model *model*                       ; ChatModel
    :system "你是一个天气助手"            ; 默认 system（请求级 (:system ...) 覆盖）
    :options (cl-agent/core:make-chat-options :temperature 0.3)  ; 默认选项
    :tools '(get-weather)                ; 默认工具（请求级 (:tools ...) 与之取并集）
    :filters (list ...)                  ; 横切能力（见第 8 节）
    :max-tool-iterations 10              ; 工具循环上限
    :tool-gate nil))                     ; chat-client 级 HITL 闸门（见本节末）

;; 派生一个「除了这一处以外都一样」的 chat-client（对标 ChatClient#mutate）
(cl-agent/core:chat-client-mutate *chat-client*
  :filters (cons my-filter (cl-agent/core:chat-client-filters *chat-client*)))

;; 只换工具循环里的某一项
(cl-agent/core:chat-client-mutate *chat-client*
  :tool-calling (cl-agent/core:tool-calling-config-mutate
                 (cl-agent/core:chat-client-tool-calling *chat-client*)
                 :tool-gate my-gate))
```

四个槽都是不可变值对象，共享安全。读取用便捷访问器穿过聚合：

```lisp
(cl-agent/core:chat-client-tools *chat-client*)
(cl-agent/core:chat-client-max-tool-iterations *chat-client*)
(cl-agent/core:chat-client-tool-gate *chat-client*)

;; chat 宏：最简形式
(cl-agent/core:chat *chat-client* "你好！")

;; 完整子句
(cl-agent/core:chat *chat-client*
  (:system "你是一个言简意赅的助手")   ; 覆盖 chat-client 的 :system
  (:user "用一句话介绍 Common Lisp")
  (:tools 'get-weather)                 ; 与 chat-client :tools 取并集
  (:options :temperature 0.2)           ; 与 chat-client :options 合并，请求级优先
  (:conversation "c1")                  ; = (:context :conversation-id "c1")
  (:call :content))                     ; :content(默认) | :response | :result | :entity
```

> `build-chat-client` 的 `:model` 是**关键字参数**，不是位置参数。
> `(build-chat-client :model *model*)` 建的 chat-client 没有任何 filter——只有模型调用 +
> 工具循环。

建好的 chat-client 可以交给 agent，拿回会话管理 + HITL + 错误归一化：

```lisp
(defvar *memory* (cl-agent/core:make-message-window-chat-memory))
(defvar *chat-client*
  (cl-agent/core:build-chat-client
    :model *model*
    :filters (list (cl-agent/core:memory-filter *memory*))))

(cl-agent/client:make-agent :chat-client *chat-client* :memory *memory*)
```

> 给 `:chat-client` 时，`memory-filter` 由**你自己**负责挂载——`make-agent` 不会
> 改动预构建 chat-client 的 filters。`:memory` 只是告诉 agent 去哪读
> `agent-history`。

没有 Builder——chat-client 的装配就是 `build-chat-client` 的关键字参数。
旧 Builder 的三个默认值一一对应：

| 旧 Builder | 现在放哪 |
|---|---|
| `default-tools` | `build-chat-client :tools` |
| `default-options` | `build-chat-client :options`（请求级 `(:options ...)` 合并覆盖） |
| `default-system` | `build-chat-client :system`（请求级 `(:system ...)` 覆盖） |

程序拼参数时，用函数形态比宏顺手（`chat` 宏正是展开到它们）：

```lisp
(cl-agent/core:chat-client-text *chat-client*
  :system "你是一个翻译"
  :user (format nil "翻译：~A" "hello world"))
```

`chat-client-call` 返回 `chat-client-response`，`chat-client-text` 取文本，
`chat-client-entity` 取 JSON，`chat-client-stream` 走流式。

### chat-client 级 HITL：tool-gate

第 6 节的 agent HITL 就是这个原语的封装。直接用 chat-client 时：

```lisp
(defvar *chat-client*
  (cl-agent/core:build-chat-client
    :model *model* :tools '(rm-file)
    ;; (tool-call) → :proceed | :pause | (:pause . 原因)
    :tool-gate (lambda (tc)
                 (if (string= (cl-agent/core:tool-call-name tc) "rm_file")
                     (cons :pause "删除需审批")
                     :proceed))))

(let ((r (cl-agent/core:chat *chat-client* (:user "删除 /tmp/x.log") (:call :result))))
  (cl-agent/core:chat-client-response-status r)        ; => :paused
  (cl-agent/core:chat-client-response-pending-tool r)  ; => pending-tool
  (cl-agent/core:chat-client-response-pause-reason r)  ; => "删除需审批"
  ;; 审批后从快照续跑
  (cl-agent/core:resume-turn *chat-client*
                             (cl-agent/core:chat-client-response-loop-state r)
                             :approved))
```

gate 在**批执行之前**对本批每个 tool-call **恰好评估一次**（gate 常带副作用
——审计日志、审批 UI、计数器，所以「恰好一次」是契约的一部分）。任一判
`:pause` 则整轮暂停，**工具一个都不执行**。

## 8. Filter：chat-client 的洋葱链

Filter 是环绕执行的洋葱层（对标 Spring AI 的 Advisor API）。每个 filter
最多挂四个钩子，对应三条链 + 流式 transducer：

| 钩子 | 环绕什么 | 载体 |
|---|---|---|
| `:chat` | 一次 LLM 调用（循环内每轮） | `prompt` → `chat-response` |
| `:tool` | 一次工具执行 | `tool-request` → `tool-result` |
| `:turn` | 一整轮对话（含整个工具循环） | `chat-client-request` → `chat-client-response` |
| `:token-xform` | 流式 token 变换 | `(downstream) → (values emit finish)` |

每个钩子统一是 `(lambda (req chain) ...)`：前置改写 `req` →
`(funcall chain req)` 进下游 → 后置加工返回值；**不调 `chain` 就是短路**。

```lisp
(defun timing-filter ()
  (cl-agent/core:make-filter
   :timing
   :turn (lambda (req chain)
           (let ((start (get-internal-real-time)))
             (prog1 (funcall chain req)
               (format t "耗时 ~,2Fs~%"
                       (/ (- (get-internal-real-time) start)
                          internal-time-units-per-second)))))))

(defvar *chat-client*
  (cl-agent/core:build-chat-client
    :model *model*
    :filters (list (timing-filter)
                   (cl-agent/core:safeguard-turn-filter '("密码"))
                   (cl-agent/core:logging-chat-filter))
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
(cl-agent/core:defilter counting-filter ((count :initform 0 :accessor fc-count))
  (:turn (self req chain)
    (incf (fc-count self))
    (funcall chain req)))

(make-counting-filter)
```

## 9. 会话记忆（ChatMemory）

用 SimpleAgent 时记忆是自动的（缺省就建了滑动窗口记忆）。直接用 chat-client 时，
记忆是一个 filter，挂在 `:chat` 链上（循环内每轮生效）：

```lisp
(defvar *memory* (cl-agent/core:make-message-window-chat-memory
                  :max-messages 20))

(defvar *chat-client*
  (cl-agent/core:build-chat-client
    :model *model*
    :filters (list (cl-agent/core:memory-filter *memory*))))

;; 同一 :conversation 共享记忆
(cl-agent/core:chat *chat-client* (:user "我叫大卫") (:conversation "c1"))
(cl-agent/core:chat *chat-client* (:user "我叫什么？") (:conversation "c1"))
;; => 模型能看到第一轮历史

;; 检查/清空记忆
(cl-agent/core:memory-messages *memory* "c1")
(cl-agent/core:memory-clear *memory* "c1")
```

chat-client 本身**没有 memory 字段**——记忆是 filter，不是 chat-client 的固有属性。

自定义存储后端：实现 `repository-find` / `repository-save` /
`repository-delete` / `repository-conversation-ids` 四个泛型函数即可。

## 10. 流式与结构化输出

```lisp
;; 流式
(cl-agent/core:chat *chat-client*
  (:user "写一首关于 Lisp 的短诗")
  (:stream (lambda (delta) (princ delta) (force-output))))

;; 结构化输出（JSON → hash-table）
(let ((entity (cl-agent/core:chat *chat-client*
                (:user "用 JSON 给出东京信息（name/population）")
                (:call :entity))))
  (gethash "name" entity))
```

> `(:call :entity)` **只解析 JSON，不校验 schema、不重试**：它给请求追加一条
> 「只输出 JSON」的系统消息，剥掉 markdown 围栏，然后 `json-parse`。
> 没有 schema 参数——校验挂 `validation-turn-filter`（见下）。

要看 `chat-client-response-status` 之类的整轮信息，用 `(:call :result)`：

```lisp
(let ((result (cl-agent/core:chat *chat-client* (:user "你好") (:call :result))))
  (values (cl-agent/core:chat-client-response-status result)          ; :completed / :cancelled ...
          (cl-agent/core:chat-client-response-tool-calls-made result)))
```

要「不符合 schema 就带着校验错误让模型重新输出」（对标 Spring AI 2.0 的
`StructuredOutputValidationAdvisor`），给 chat-client 挂 `validation-turn-filter`
——校验判据由它承担：

```lisp
(defvar *schema*
  "{\"type\":\"object\",
    \"properties\":{\"name\":{\"type\":\"string\"},
                   \"population\":{\"type\":\"integer\"}},
    \"required\":[\"name\",\"population\"]}")

(defvar *validating-chat-client*
  (cl-agent/core:build-chat-client
    :model *model*
    :filters (list (cl-agent/core:validation-turn-filter
                    ;; 判据：(response) → (values ok-p 反馈文本)
                    (cl-agent/core:structured-output-validate-fn
                     *schema* :parse-fn #'cl-agent/core:json-parse)
                    :max-retries 2))))

(let ((entity (cl-agent/core:chat *validating-chat-client*
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

> **流式说明**：`(:stream cb)` 是真流式——`:chat` filter 与 `:token-xform`
> 都生效。但它**不跑工具循环**（单次调用）：带工具的流式请求会报错而不是
> 静默丢掉工具执行，要工具请用 `(:call :content)`。provider 不支持流式时
> 降级为整段文本单个 chunk。

## 11. 运行测试

```bash
# 测试套件（全 mock，离线可跑）
sbcl --non-interactive --load run-tests.lisp

# 真实 provider 端到端验证（需 API 密钥）
MINIMAX_API_KEY=... sbcl --script scripts/live-test.lisp
```

`run-tests.lisp` 全用 mock：离线、确定性、零 API 花费。但 mock 证明不了
「真实模型会不会按我们的 schema 发工具调用」「暂停时工具是否真的没执行」
「真实 SSE 分片能不能拼回」——`scripts/live-test.lisp` 补的就是那一段
（单次问答 / 工具循环 / 多轮记忆 / schema 校验 / HITL 暂停·批准·拒绝 /
SSE 分片，共 8 项）。

## 下一步

- [API 参考](API_CN.md) —— 含 [迁移对照表](API_CN.md#迁移)
- [工具调用架构](tool-calling_CN.md) —— Filter 与 Manager 的分工
- [完整示例](../examples/chat-client-usage.lisp) —— 8 个渐进示例，全部用 mock，
  无需 API 密钥
