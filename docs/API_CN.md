# CL-Agent API 参考

[English](API.md)

按包组织的 API 速查。与 Spring AI 2.0 的对应关系标注在各节标题中。

两层入口：

- **SimpleAgent**（`cl-agent/client`）：有状态对话 + callbacks + 错误归一化
  + HITL。见 [cl-agent/client](#cl-agentclient--simpleagent有状态对话--hitl)。
- **ChatClient + Filter**（`cl-agent/core`）：`chat` 宏 / `chat-client-call` →
  `cl-agent/core:invoke-turn` 三链。前者是后者的薄封装。

## 包与 :use

现在只有这几个包：

| 包 | 昵称 | 角色 |
|---|---|---|
| `cl-agent/core` | `cla/core` | 框架本体（单包）：基础设施 + HTTP/SSE + JSON Schema + `llm-chat` SPI + Chat API + ChatClient/Filter 三链 + `chat` 宏 |
| `cl-agent/client` | `cla/client` | SimpleAgent |
| `cl-agent/llm` | `cla/llm` | 提供商实现，`create-chat-model` |
| `cl-agent/llm/providers` | — | 9 个 provider 实现 |
| `cl-agent/mock` | `mock` | mock provider（测试/演示） |

`cl-agent/core` 与 `cl-agent/client` **无任何同名导出**，直接一起 `:use`
即可，不需要任何 shadowing：

```lisp
(defpackage :my-app
  (:use :cl :cl-agent/core :cl-agent/client))
```

`examples/chat-client-usage.lisp` 与 `scripts/live-test.lisp` 的 `defpackage`
即是这一形式（它们只 `:use` core）。

> **`cl-agent/http` / `cl-agent/chat` / `cl-agent/chat-client` 三个包已合并进
> `cl-agent/core`**，昵称 `cla/http` / `cla/chat` / `cla/chat-client` 统一为
> `cla/core`。合并前 chat 与 chat-client 有三个同名导出：`tool-response` /
> `make-tool-response`（chat 是协议消息层的值对象，chat-client 是执行链的响应
> 载体）与 `execute-tool-calls`（两套签名不同的 manager 协议），逼得
> chat-client 必须 `:shadow`，下游还得自己写 `:shadowing-import-from`。
> 已从根上消除：chat-client 的载体改名为 `tool-request` / `tool-result`，chat
> 的旧 ToolCallingManager 整体删除，随后三包合并。**旧文档里所有
> 「必须 shadowing-import」的说法都已作废。** 迁移见文末[迁移指引](#迁移)。
>
> 全库已**零 shadow**：`cl-agent/llm` 曾因低层 `chat` 函数与 core 的 `chat` 宏
> 撞名而 `(:shadow #:chat)`。该函数先改名 `client-chat`，随后连同 `client` 类
> 一并移除（见文末[迁移指引](#迁移)）。现在同时 `:use` 任意本库的包都不会撞名。

## 类不变式（`definvariants`）

CL 里 `make-instance` 是**永远可达的后门**——`(defun make-foo ...)` 只是约定
俗成的入口，没人拦得住调用方直接 `(make-instance 'foo ...)`。所以「这个对象
只要存在就必须满足 X」挂在 `initialize-instance :after` 上，而不是只写在
`make-*` 里。违反时**在构造点**报错，而不是几层调用之后表现为一个难懂的症状。

```lisp
(definvariants tool-call (self)
  (require-slot self 'id "模型靠它把结果对回请求")
  (require-slot self 'name "工具分派靠它"))
```

五个原语：

| 原语 | 用途 |
|---|---|
| `(require-slot obj slot why)` | 必填：未绑定或 NIL 都算缺失。`why` 会进错误消息 |
| `(require-member obj slot allowed &optional why)` | 枚举值——写错 keyword 不报错、只会静默走错分支，这类最值得校验 |
| `(require-type obj slot type &optional why)` | 「可选，但给了就得是这个类型」（NIL 放行） |
| `(require-callable obj slot &optional why)` | 函数或函数名（NIL 放行） |
| `(require-that obj test fmt &rest args)` | 任意跨槽约束 |

违反时发 `invariant-violation`，继承 `validation-error`——按统一分类它**不可
重试**（重试一个构造错误不会有不同结果，否则 `retry-policy` 会白白重试三次
再抛同一个错）。

### 什么该写成不变式，什么不该

三分类，判据写在 `core/invariants.lisp` 头注：

- **A 类（写）**——「对象存在就必须满足」。典型：`tool-call` 必须有 id、
  `chat-client-response(:paused)` 必须带 `loop-state`。
- **B 类（不写，留在构造函数）**——输入归一。`make-prompt` 接受
  string / message / list 并统一成消息列表，那是**入口的贴心**，不是类的性质
  （prompt 的性质是「messages 槽里存 message 实例列表」）。搬进
  `initialize-instance` 反而会让 `make-instance` 也吃字符串，模糊了「槽里到底
  存什么」。
- **C 类（不写）**——纯缺省值，那是 `:initform` 的活。例外是缺省值依赖别的槽
  （`filter` 的「没给名字就用类名」，`:initform` 表达不了）。

### 刻意的例外

`chat-options` **没有**不变式，这是结论不是遗漏：它十几个槽全部没有
`:initform`，槽 unbound **就是**「未设置」的语义——`merge-chat-options` 靠
`slot-boundp` 实现覆盖链，`options->spi-args` 靠它实现「存在才下发」（凭空补
一个 temperature 会让 Opus 4.7+ 直接 400）。**不是每个 unbound 槽都是漏洞。**

其余不挂的也都在类定义处写明了理由：协议基类不带槽（无槽即无约束）、
provider 允许延迟提供 API key、DI 容器的槽全是自建内部状态。

## cl-agent/core —— Chat Model API

### 消息体系（`org.springframework.ai.chat.messages`）

| 符号 | 说明 |
|---|---|
| `message` | 抽象基类；`message-role` / `message-text` / `message-metadata` |
| `(system-message text)` | 系统指令消息 |
| `(user-message text)` | 用户消息 |
| `(assistant-message text &key tool-calls)` | 模型回复；`assistant-tool-calls` |
| `(tool-response-message responses)` | 工具结果消息；`tool-responses` |
| `(make-tool-call &key id name arguments)` | 工具调用值对象 |
| `(make-tool-response &key id name text)` | 工具结果值对象 |
| `message->neutral` / `messages->neutral` | CLOS 消息 → 中立 plist（provider SPI 边界） |
| `neutral->message` / `neutral->messages` | 反向转换 |

> 这里的 `tool-response` 是**协议消息层**的值对象（id/name/text），放进
> role=:tool 的消息里发回模型。它与 chat-client 执行链的响应载体
> `cl-agent/core:tool-result`（value/writes/error，见
> [Tool 链载体](#三链载体)）是**不同层的不同东西**，现已不再同名。

### Prompt / ChatOptions（`chat.prompt`）

```lisp
(make-prompt messages &key options system)   ; messages 可为字符串/消息/列表
(prompt-messages prompt) (prompt-options prompt)
(prompt-copy prompt &key messages options)   ; 不可变增强（filter 改写 prompt 用）
(prompt-append-messages prompt new-messages)
(prompt-system-messages prompt) (prompt-instruction-messages prompt)
(prompt-last-user-text prompt)
(prompt-last-user-or-tool-message prompt)
(prompt-augment-last-user-message prompt text)
```

```lisp
(make-chat-options :model "..." :temperature 0.3 :max-tokens 1024
                   :top-p 0.9 :top-k 40 :stop-sequences '("END")
                   :frequency-penalty 0.0 :presence-penalty 0.0
                   :thinking '(:enabled :budget-tokens 2048)  ; 扩展思考
                   :extra-params '(:seed 42)            ; 厂商专有参数逃生通道
                   :tool-callbacks (list cb) :tool-names '(get-weather)
                   :tool-context '(:tenant "acme"))
(merge-chat-options runtime defaults)  ; 运行时覆盖默认；工具取并集
(copy-chat-options options)
(chat-options-with-tools options callbacks)   ; 换掉 tool-callbacks（filter 用）
;; 读取器：chat-options-model / -temperature / -max-tokens / -thinking /
;;         -tool-callbacks / -tool-names / -tool-context / ...
```

未显式传入的选项处于"未设置"状态，合并时回退默认值。

> **工具循环选项不在 chat-options 里。** 循环上限由 chat-client 的 settings 承担：
> `(build-chat-client :max-tool-iterations 10)`；续跑判据由
> `:eligibility-fn` 承担。chat-options 只描述**一次**模型调用。

### 扩展思考（:thinking）

对标 Spring AI 的 `ThinkingConfigParam`。中立规格由 provider 翻译为自家 wire 格式：

```lisp
:thinking :disabled                      ; {"type":"disabled"}
:thinking :adaptive                      ; {"type":"adaptive"} 由模型自行决定思考量
:thinking '(:adaptive :display :omitted)
:thinking '(:enabled :budget-tokens 2048)
:thinking '(:enabled :budget-tokens 2048 :display :omitted)
:thinking <hash-table>                   ; 原样下发（wire 格式先行于本实现时用）
```

- `:budget-tokens` 必须 **≥1024 且小于 `:max-tokens`**（思考计入 `max-tokens`）。
  违反时在构建请求阶段就发 `invalid-thinking-config-error`，而不是发出去换一个裸 400。
- `:display` 为 `:summarized`（默认）或 `:omitted`。`:omitted` 隐去思考内容但
  **仍返回 signature**，多轮工具调用的延续性不受影响。
- 未设置时不下发该字段，用服务端默认。
- 目前由 Anthropic 系 provider（`anthropic` / `minimax`）实现；其它 provider 忽略。

> MiniMax M 系列是常驻推理模型，思考计入输出 token。需要压缩输出成本或
> 关闭思考时，用 `:thinking :disabled`。

### ChatResponse（`chat.model.ChatResponse`）

```lisp
(chat-response-text response)              ; 首个 generation 文本
(chat-response-message response)           ; assistant-message
(chat-response-tool-calls response)
(chat-response-has-tool-calls-p response)
(chat-response-finish-reason response)     ; :stop/:tool-call/:max-tokens/...
(chat-response-usage response)             ; llm-usage
(chat-response-generations response)
(chat-response-metadata-of response)       ; id/model/usage/raw
(llm-response->chat-response llm-response) ; 适配层转换
```

### 工具体系（`@Tool` / `ToolCallback`）

```lisp
(deftool 名称 (&key 参数...)
  "描述（给模型看）"
  (:param 参数名 类型 "描述" [:required t] [:default 值])*
  [(:return-direct t)]
  函数体...)
```

- 生成普通函数 + tool-callback，callback 挂在**符号属性**上
- **无全局副作用**：工具的身份就是它的符号，用 `(:tools 'get-weather)` 引用
- 类型关键字：`:string :number :integer :boolean :array :object`

> 对齐 clj-agent：那边 `deftool` 生成 `defn`、schema 挂 var 元数据，
> 再用 `(build-chat-client {:tools [#'get-weather]})` 显式传入。Clojure 的 var 带
> 元数据，CL 里对应的载体是符号的属性列表——`#'get-weather` 是裸函数对象，
> 取不到 schema，**不能**用作工具引用。

```lisp
(make-tool-callback fn :name "n" :description "d"
                    :parameters '((p :string "desc" :required-p t))
                    :return-direct nil)
(tool-callback-call callback args-plist &optional tool-context)
(tool-callback->schema callback)          ; provider 工具 schema
(tool-callback-name cb) (tool-callback-definition cb)
(tool-callback-return-direct-p cb) (tool-callback-serial-p cb) (tool-callback-retry-p cb)
(symbol-tool-callback 'get-weather)       ; 取 deftool 挂在符号上的 callback
(resolve-tool-callbacks specs)            ; 实例/符号/字符串 → callback
(arguments->plist raw)                    ; hash-table/JSON/plist 归一化

;; 全局注册表：opt-in 逃生通道，仅用于按*字符串*名解析（配置驱动场景）。
;; deftool 不写它；默认为空。
(register-tool-callback (symbol-tool-callback 'get-weather))
(find-tool-callback "get_weather")        ; 只查全局表，非 deftool 的默认路径
(unregister-tool-callback "get_weather")
```

**工具解析**（chat-client 的 batch / manager / tool-search filter 依赖）：

```lisp
(find-callback-for-call options tool-call)   ; 一次 tool-call → callback
;; 只在**本次请求 options 暴露的工具**里按名解析；找不到发
;; tool-not-found-error。它**不回退全局注册表**——这是防注入 /
;; 防提权的安全边界：模型报出一个没暴露给它的工具名，绝不执行。
```

> 模型幻觉工具名很常见。chat-client 的 `batch.lisp` 会捕获
> `tool-not-found-error`，转成 `:semantic` 错误的 `tool-result`，经
> `tool-result->text` 渲染为「错误：找不到工具 xxx」回传模型让它自纠——
> 条件不会冒泡出 `(chat ...)` 中断整轮对话。安全边界不变：未暴露的工具
> 依然绝不执行。

条件：`tool-execution-error`、`tool-not-found-error`、
`max-tool-iterations-exceeded-error`。

> **chat 层的旧 ToolCallingManager 已整体删除**：`tool-calling-manager` /
> `default-tool-calling-manager` / `concurrent-tool-calling-manager` /
> `execute-tool-calls`（`(manager prompt response)` 签名）/
> `tool-execution-result` / `process-tool-execution-error` /
> `with-concurrent-tool-calling-manager` 等符号均已不存在。工具执行唯一
> 住在 chat-client 层：`run-tool-loop` + `invoke-tool-batch` + 三个
> [ToolCallingManager](#toolcallingmanager实现)。「自己调
> `chat-model-call` 再用 `execute-tool-calls` 驱动循环」这条 user-controlled
> 路径已不存在，chat-client 是唯一路径。
>
> `*inherited-special-variables*` / `with-inherited-specials` 不属于已删除的
> manager，它们仍在（`core/utils.lisp`），与 HTTP 异步请求共用同一份名单，
> 需要时从 `cl-agent/core` 取。

### ChatModel 协议（`ChatModel` / `StreamingChatModel`）

```lisp
(chat-model-call model prompt)             ; prompt 可为字符串/消息列表
(chat-model-stream model prompt on-chunk)  ; on-chunk: (delta-text)，真 SSE
(chat-model-default-options model)
(chat-model-retry-policy model)
(chat-model-observation-fn model)

(make-provider-chat-model provider &key default-options retry-policy observation-fn)
```

**职责边界。** ChatModel 承担**单次调用范围内的全部重活**——options 解析
合并、重试、观测、响应规范化、流式聚合；provider 只负责「底层信息 + 如何
调用」（端点、鉴权、请求体格式、响应解析）。

ChatModel **不含**工具循环：携带 tool-calls 的响应原样返回，循环由
`cl-agent/core:run-tool-loop`（`:turn` 链的 terminal）承担。这与新版
Spring AI 一致——那边也已经把循环从 `XxxChatModel` 移到了 ChatClient 层的
`ToolCallingAdvisor`。

#### 重试（`retry-policy`）

```lisp
(make-retry-policy &key max-attempts    ; 总尝试次数（**含**首次），缺省 3
                        initial-delay   ; 首次重试前延迟（秒），缺省 1.0
                        backoff         ; 退避倍数，缺省 2.0
                        max-delay       ; 单次延迟上限（秒），缺省 60.0
                        jitter          ; 抖动比例，缺省 0.1（±10%）
                        retryable-p     ; (condition) → boolean，缺省 error-retryable-p
                        on-retry)       ; (condition attempt delay) → nil

(create-chat-model :anthropic
  :retry-policy (make-retry-policy :max-attempts 4))
```

重试属于 ChatModel、不属于 provider：同一个 provider 在不同 ChatModel 实例
下可以配不同的重试预算。实现是挂在基类上的 `chat-model-call :around`——
新写一个 ChatModel 子类不需要记得调重试封装，也不可能漏。

**缺省不重试**（`retry-policy` 为 nil 时走零开销路径）。

要不要重试由 `error-retryable-p` 单一裁定（`core/conditions.lisp`）：
瞬态 HTTP 状态（408/409/425/429/5xx）与网络层失败可重试，鉴权/参数错不
重试。重试耗尽后**原样抛出**最后一次的条件，不包装——包装成新类型会断掉
上层按同一套分类做的决策。

> **流式路径注意**：已经吐给回调的 token 不会被撤回。流跑到一半断掉再重试，
> 调用方会看到前半段重复。流式通常应把 `retry-policy` 留空。

> 与 HTTP 层的 `retry-config`（`core/http/retry.lisp`）区分：那个管一次 HTTP
> 请求的重试，`max-retries` 是「额外重试几次」（不含首次）；`retry-policy`
> 管一次模型调用，`max-attempts` 是「总共尝试几次」（含首次）。两层各自有
> 重试是刻意的，调用方通常只配后者。

#### 观测（`observation-fn`）

```lisp
;; (model prompt thunk) → response
:observation-fn (lambda (model prompt thunk)
                  (declare (ignore model prompt))
                  (let ((start (get-internal-real-time)))
                    (prog1 (funcall thunk)
                      (log-latency (- (get-internal-real-time) start)))))
```

钩子包住的是**含重试的整次调用**，所以记到的是一次逻辑调用的总耗时与最终
结果，而不是每次尝试各记一条。要按尝试观测，用 `retry-policy` 的 `:on-retry`。

### ChatMemory（`ChatMemory` / `ChatMemoryRepository`）

```lisp
;; 记忆协议
(memory-add memory conversation-id messages)
(memory-messages memory conversation-id)
(memory-clear memory conversation-id)
(make-message-window-chat-memory :repository repo :max-messages 20)

;; 存储协议（自定义后端实现这四个泛型函数）
(repository-find repo conversation-id)
(repository-save repo conversation-id messages)
(repository-delete repo conversation-id)
(repository-conversation-ids repo)
(make-in-memory-chat-memory-repository)

+default-conversation-id+   ; "default"
```

窗口裁剪 pairing-safe：system 消息不计入且保留；孤立 tool 消息头连带丢弃。

记忆本身**不是** chat-client 的字段——把它挂成 filter：
`(cl-agent/core:memory-filter memory)`。

## cl-agent/core —— ChatClient + Filter 三链（执行内核）

三条洋葱链，各自有独立的载体与 terminal：

| 链 | 钩子槽 | 请求 → 响应 | terminal |
|---|---|---|---|
| `:chat` | `filter-chat-hook` | `prompt` → `chat-response` | `chat-model-call` |
| `:tool` | `filter-tool-hook` | `tool-request` → `tool-result` | 工具执行 |
| `:turn` | `filter-turn-hook` | `chat-client-request` → `chat-client-response` | `run-tool-loop` |
| `:token-xform` | `filter-token-xform` | `(downstream) → (values emit finish)` | 流式 token 流 |

```
invoke-turn → [:turn filters] → run-tool-loop
  ├── invoke-chat → [:chat filters] → chat-model-call
  ├── 有 tool-calls 且 eligible → invoke-tool-batch → [:tool filters] → 工具
  │     追加消息 → 回到上一步
  └── 否则 → chat-client-response(:completed)
```

### Filter（对标 `CallAdvisor` / `AdvisorChain`）

```lisp
(make-filter name &key chat tool turn token-xform)   ; 通用工厂
(filter-name f)
(filter-chat-hook f) (filter-tool-hook f) (filter-turn-hook f) (filter-token-xform f)
```

**每个钩子都是 `(lambda (req chain) ...)`**：

- 前置：改写 `req`
- `(funcall chain req)`：进下游（更内层的 filter，最终到 terminal）
- 后置：加工返回值
- **不调 `chain` = 短路**（`safeguard-turn-filter` 就是这么拦的）
- 多次调 `chain` = 递归重入整条下游链（`validation-turn-filter` 就是这么重试的）

没提供的钩子槽为 `nil`，`build-chain` 构建对应链时自动跳过——一个 filter 可以
同时挂多条链，也可以只挂一条。

```lisp
;; 钩子的四个槽都可选
(cl-agent/core:make-filter
 :timing
 :turn (lambda (req chain)
         (let ((start (get-internal-real-time)))
           (prog1 (funcall chain req)
             (format t "耗时 ~,2Fs~%"
                     (/ (- (get-internal-real-time) start)
                        internal-time-units-per-second))))))
```

### defilter 宏

```lisp
(defilter 名称 (槽定义...)
  [(:chat (self req chain) 方法体...)]
  [(:tool (self req chain) 方法体...)]
  [(:turn (self req chain) 方法体...)]
  [(:token-xform xform-表达式)])
;; 生成：defclass 名称 (filter) + make-名称 构造函数（&rest initargs 透传 make-instance）
;; 钩子 lambda-list 是 (SELF REQ CHAIN)，SELF 绑定到 filter 实例（闭包捕获）。
```

```lisp
(defilter counting-filter ((count :initform 0 :accessor cf-count))
  (:turn (self req chain)
    (incf (cf-count self))
    (funcall chain req)))

(make-counting-filter)
```

### build-chain —— 洋葱折叠

```lisp
(build-chain filters hook-key terminal)   ; → (lambda (req) ...) → resp
;; filters   filter 实例列表，靠前 = 最外层 = 先执行
;; hook-key  访问器函数，如 #'filter-chat-hook；该钩子为 nil 的 filter 自动跳过
;; terminal  最内层单参函数 (req) → resp
```

`reverse` + `reduce` 把钩子层层嵌套。每层闭包**只持有更内层的引用**——不可能
重跑上游，递归重入是免费性质。

> **filters 列表顺序即洋葱层级：靠前 = 靠外 = 先执行。** filter 没有 order 字段。

### 三链载体

```lisp
;; Tool 链
(make-tool-request function &key args context)
(tool-request-function r)   ; tool-callback 实例或 deftool 符号
(tool-request-args r)       ; 参数 plist
(tool-request-context r)    ; 工具上下文 plist

(make-tool-result &key value writes error)
(tool-result-value r)       ; 工具返回值
(tool-result-writes r)      ; 状态写意图 plist（见下方「:writes 状态折叠」）
(tool-result-error r)       ; tool-error-info 实例，或 nil（成功）

;; 故障描述——分类是具名槽，构造时校验必须是三者之一
(make-tool-error-info &key class message cause)
(tool-error-class r)        ; :semantic | :transient | :environment
(tool-error-message r)      ; 回传模型的那句
(tool-error-cause r)        ; 原 condition（可为 nil）

(tool-result->text r)       ; → 回传模型的文本；错误结果渲染为「错误：<message>」

;; Turn 链（ChatClient 层，对标 Spring AI ChatClientRequest / ChatClientResponse）
(make-chat-client-request prompt &key context resume-p)
;; PROMPT 可以是 prompt 实例、消息列表或字符串——后两者自动包装
(chat-client-request-prompt r)      ; 本轮完整输入（messages + options）
(chat-client-request-messages r)    ; 便捷读：prompt 的消息列表
(chat-client-request-options r)     ; 便捷读：prompt 的 chat-options
(chat-client-request-context r)     ; 开放字典 plist（filter 间共享）
(chat-client-request-resume-p r)    ; 是否从暂停恢复

;; 改写请求用 mutate，不要手工重建——未指定的字段原样保留
(chat-client-request-mutate r &key messages options context resume-p)

(make-chat-client-response status &key chat-response context tool-calls-made
                                       loop-state pending-tool pause-reason)
(chat-client-response-status r)           ; :completed | :paused | :cancelled | :error
(chat-client-response-chat-response r)    ; 最终 chat-response（出错/被拦时 nil）
(chat-client-response-text r)             ; 便捷读：最终回复文本
(chat-client-response-context r)          ; 折叠完全部批次 :writes 后的最终 context
(chat-client-response-tool-calls-made r)  ; 本轮工具调用轮数
;; 仅 :paused 时有值（见「HITL：暂停与续跑」）
(chat-client-response-loop-state r)       ; 续跑快照，喂给 resume-turn
(chat-client-response-pending-tool r)     ; 待审批的工具（name/args/id）
(chat-client-response-pause-reason r)     ; gate 给的原因文本
```

> `:chat` 链**不用**包装载体：请求就是 `cl-agent/core:prompt`，响应就是
> `chat-response`。
>
> **请求持有 prompt，不是裸 messages。** 请求级 options 是 prompt 的一部分，
> 与 messages 平级。此前 options 是塞进 `context` 的 `:caller-options` 键偷传给
> `run-tool-loop` 的，循环里再捞出来合并、折进 `tool-context` 时还得特意剔除
> 「不外泄」——那条暗管道已随载体改造消失。
>
> **改写请求一律用 `chat-client-request-mutate`。** 手工
> `make-chat-client-request` 重建很容易漏字段：旧代码里 rag filter 就只传了
> `:context`、把 `resume-p` 丢成 nil（当时靠分支条件恰好绕开）。
>
> `:paused` 的响应**必须**带 `loop-state`，构造时即校验——否则调用方拿到一个
> 「暂停了但无法续跑」的响应，而这只会在它真的去 resume 时才炸。
>
> 命名：`tool-request` → `tool-result` 与 turn 链的 `chat-client-request` →
> `chat-client-response` 对称。`tool-result` 曾叫 `tool-response`（初始参数 `:result`，
> 读取器 `tool-response-result`），与 `cl-agent/core:tool-response` 撞名——
> 后者是协议消息层的值对象，两者分属不同层。改名后撞名消失。

### ChatClient

ChatClient 是**四个槽**（对标 Spring AI 的 ChatClient）：

| 槽 | 装什么 | 对标 |
|---|---|---|
| `model` | 往哪调 | `ChatModel` |
| `filters` | 链上有谁 | `advisors` |
| `default-request` | 请求默认长什么样（system / options / tools） | `DefaultChatClientRequestSpec` |
| `tool-calling` | 工具循环怎么跑 | `ToolCallingAdvisor` |

刻意**没有** memory 槽：记忆是 filter，不是 ChatClient 的固有属性。

`build-chat-client` 接受扁平参数，内部聚合成上面两个值对象：

```lisp
(build-chat-client &key model filters
                        ;; → default-request
                        system options tools
                        ;; → tool-calling
                        max-tool-iterations eligibility-fn tool-gate
                        state-slots tool-manager loop-fn resume-fn
                        ;; 或直接给聚合对象（给了就整体覆盖上面对应的扁平参数）
                        default-request tool-calling
                        ;; 已废弃，仍接受
                        settings)
;; model               chat-model 实例
;; filters             filter 实例列表（顺序 = 洋葱层级；缺省 nil）
;;
;; ---- 默认请求 ----
;; system              默认系统提示文本；请求级 (:system ...) 覆盖它
;; options             默认 chat-options；请求级 (:options ...) 合并覆盖
;; tools               默认工具引用（符号/tool-callback 列表；缺省 nil）
;;
;; ---- 工具循环 ----
;; max-tool-iterations 循环上限（缺省 10）
;; eligibility-fn      (response context) → boolean，判断是否继续工具迭代
;;                     （缺省 (constantly t)）
;; tool-gate           工具审批闸门（HITL）：(tool-call) → :proceed | :pause
;;                     | (:pause . 原因)；nil（缺省）= 不审批，全部直接执行
;; state-slots         状态槽声明 ((key :init v0 :reduce fn) ...)——工具批次
;;                     :writes 的合并语义（见「:writes 状态折叠」）
;; tool-manager        ToolCallingManager 实例；nil = 走 invoke-tool-batch 原路径
;; loop-fn             自定义工具循环 (chat-client request) → chat-client-response；
;;                     nil（缺省）= run-tool-loop。它就是 :turn 链的 terminal，
;;                     换掉它即换掉整个循环骨架
;; resume-fn           自定义暂停延续 (chat-client loop-state decision payload)
;;                     → chat-client-response；nil（缺省）= 内建实现。与 loop-fn 成对
;;
;; settings            配置 alist。**已废弃**：唯一的键 :max-tool-iterations
;;                     现在是具名参数。仍然接受，但只在没有显式
;;                     :max-tool-iterations 时读它。

;; 槽访问器
(chat-client-model k) (chat-client-filters k)
(chat-client-default-request k) (chat-client-tool-calling k)

;; 便捷访问器：穿过聚合直接读叶子
(chat-client-tools k) (chat-client-default-system k) (chat-client-default-options k)
(chat-client-max-tool-iterations k) (chat-client-eligibility-fn k)
(chat-client-tool-gate k) (chat-client-state-slots k) (chat-client-tool-manager k)

;; 聚合对象本身
(make-chat-client-default-request &key system options tools)
(default-request-system r) (default-request-options r) (default-request-tools r)

(make-tool-calling-config &key max-iterations eligibility-fn tool-gate
                               state-slots tool-manager loop-fn resume-fn)
(tool-calling-max-iterations c) (tool-calling-eligibility-fn c)
(tool-calling-tool-gate c) (tool-calling-state-slots c)
(tool-calling-tool-manager c) (tool-calling-loop-fn c) (tool-calling-resume-fn c)
```

**派生一个改了若干处的 ChatClient**（对标 `ChatClient#mutate`）：

```lisp
;; 加一个 filter，其余原样共享
(chat-client-mutate k :filters (cons my-filter (chat-client-filters k)))

;; 只换 tool-gate：先 mutate 配置，再 mutate chat-client
(chat-client-mutate k
  :tool-calling (tool-calling-config-mutate (chat-client-tool-calling k)
                                            :tool-gate my-gate))
```

四个槽都是不可变值对象，共享安全。此前要派生一个 ChatClient 只能把它
逐槽拆开再 `build-chat-client` 一遍——每加一个槽都要记得补一行，漏了就
静默丢配置（`client/agent.lisp` 里就是这么写的）。

### 状态槽与续跑载荷

```lisp
;; 状态槽：决定工具批次 :writes 在屏障处怎么合并
(make-state-slot key &key init reduce-fn)
(state-slot-key s) (state-slot-init s) (state-slot-reduce-fn s)
(find-state-slot slots key)

;; :notes 累加而非覆盖
(build-chat-client :model m
  :state-slots (list (make-state-slot :notes :init nil :reduce-fn #'append)))

;; HITL 续跑载荷
(make-resume-payload &key message args)
(resume-payload-message p) (resume-payload-args p)
(coerce-resume-payload plist-or-instance-or-nil)   ; resume-turn 入口处归一
```

`resume-turn` 的 `:payload` 仍接受 plist（最自然的调用写法），入口处归一成
实例，内部不再各处 `getf`。

> 状态槽曾是 `(key :init v0 :reduce fn)` 这样的 alist 套 plist，靠
> `(rest (assoc key slots))` + `getf` 现场解读——`:reduce` 拼成 `:reducer`
> 就退化成 last-writer，「累加」悄悄变成「覆盖」，不报错。

### :loop-fn / :resume-fn —— 替换循环骨架

`run-tool-loop` 是 `:turn` 链的**缺省** terminal，不是固定的。`:loop-fn`
整体替换它——这就是换循环形状（ReAct、plan-execute、reflexion）的口子，
且不动三链结构：`:turn` filter 照常环绕它，`:chat` / `:tool` filter 照常
作用于它发起的调用。

```lisp
(build-chat-client :model m
              :loop-fn (lambda (chat-client chat-client-request) ... ))   ; → chat-client-response
```

**自定义循环的 HITL 是 opt-in 的。** 内建的暂停延续读的是 `run-tool-loop`
产出的 `loop-state` 快照，看不懂别的循环的暂停点。所以自定义循环若要支持
暂停/续跑，必须**同时**给 `:resume-fn`——两者成对。反过来，一个从不返回
`chat-client-response(:paused)` 的循环永远走不到 resume 路径，不给 `:resume-fn`
只是少一项能力，不会让行为出错。

两个都不给就是默认路径，行为一字不变。

### :writes 状态折叠（工具批次的 MapReduce 契约）

工具在并行批次中拿到的 context 是**只读快照**——直接改它会引入竞态。
写意图经返回值声明，整批收齐后（屏障）按 tool-call **原始序**折叠，
并行的实际交错不影响合并结果：

```lisp
;; 工具用 (values 结果 writes-plist) 声明写意图
(deftool take-note (&key text)
  "记一条笔记"
  (:param text :string "内容" :required t)
  (values (format nil "已记：~A" text)
          (list :notes (list text))))       ; 写意图：不在这里生效

;; :state-slots 声明合并语义
(build-chat-client :model m :tools '(take-note)
              :state-slots (list (list :notes :init nil
                                       :reduce (lambda (old new)
                                                 (append old new)))))

;; 一批两个 take-note("a") take-note("b") → 屏障折叠 → (:notes ("a" "b"))
;; 下一轮工具经 tool-context 看到折叠后的快照；
;; 最终由 (chat-client-response-context result) 交还调用方
```

规则：
- 声明了 `:reduce` 的槽用它折叠（context 里无老值时用 `:init`）
- 未声明的槽 **last-writer**——后写覆盖，按 call 序确定
- 同批被写 ≥2 次且无 reducer 的键会 `log-warn` 告警
- **失败调用（error 非 nil）的写意图不生效**（事务性）
- HITL 续跑同样折叠：真执行的部分提交写意图，被拒/被答复的没有写

底层原语（一般不直接用）：

```lisp
(apply-writes context writes-seq &optional slots)
;; → (values 新context 冲突键列表)；纯函数，不修改实参
(fold-batch-writes chat-client tool-results context)
;; → 新context；跳过失败调用的 writes，冲突自动告警
```

chat-client 极简：**没有 memory 字段**——记忆是 filter，不是 chat-client 的固有属性。

> **没有 Builder。** chat-client 的装配就是 `build-chat-client` 的关键字参数——
> 旧 Builder 的 `default-system` / `default-options` / `default-tools`
> 分别对应 `:system` / `:options` / `:tools`。

三层默认值的合并语义：

| 项 | chat-client 级 | 请求级 | 合并 |
|---|---|---|---|
| system | `build-chat-client :system` | `(:system ...)` | 请求级**覆盖** |
| options | `build-chat-client :options` | `(:options ...)` | 请求级**优先**，未提及的默认项保留 |
| tools | `build-chat-client :tools` | `(:tools ...)` | **取并集** |

### HITL：暂停与续跑（chat-client 原语）

`:tool-gate` 是人工审批的底层原语（`cl-agent/client` 的
[SimpleAgent HITL](#人工审批hitl) 就是它的封装）。

```lisp
(build-chat-client
  :model *model* :tools '(rm-file)
  ;; (tool-call) → :proceed | :pause | (:pause . 原因)
  :tool-gate (lambda (tc)
               (if (string= (tool-call-name tc) "rm_file")
                   (cons :pause "删除需审批")
                   :proceed)))
```

gate 在**批执行之前**对本批每个 tool-call **恰好评估一次**——gate 常带副作用
（审计日志、审批 UI、计数器），「恰好一次」是契约的一部分。任一判 `:pause`
则整轮暂停：**工具一个都不执行**，`run-tool-loop` 返回 `chat-client-response(:paused)`。

```lisp
(resume-turn chat-client loop-state decision &key payload)
;; loop-state  chat-client-response(:paused) 上的 (chat-client-response-loop-state r)
;; decision    :approved | :rejected | :reply
;; payload     :approved + (:args 新参数)  → 编辑后批准（用新参数执行）
;;             :rejected + (:message 理由) → 结果「已拒绝执行：<理由>」回模型
;;             :reply    + (:message 答复) → 答复**直接**作为该工具的结果
;;                                           （ask-user 语义，工具不执行）
;; → 同 invoke-turn：:completed，或**再次** :paused（批里还有别的敏感工具，
;;   或后续轮次又触发 gate）
```

`resume-turn` 同样过 `:turn` filter 链——validation 之类的 filter 要能作用于
续跑后的结果。

暂停载体：

```lisp
(make-loop-state &key messages response tool-calls pending-id
                      iteration options context)
(loop-state-messages ls)    ; 暂停时刻的消息（尚未含本轮 assistant/工具结果）
(loop-state-response ls)    ; 触发暂停的那条 assistant 响应（携带 tool-calls）
(loop-state-tool-calls ls)  ; 本批全部 tool-call——**都还没执行**
(loop-state-pending-id ls)  ; 被判 :pause 的那个 tool-call 的 id
(loop-state-iteration ls)   ; 暂停发生在第几轮（续跑后接着数）
(loop-state-options ls) (loop-state-context ls)

(make-pending-tool &key name args id)
(pending-tool-name p) (pending-tool-args p) (pending-tool-id p)
```

`loop-state` 刻意**不含** chat-client / gate / callbacks——那些是代码侧的东西，
resume 时重新提供；本类只装「续跑所需的数据」。

### chat 宏 —— 声明式请求 DSL（调用方入口）

```lisp
(chat chat-client
  [(:system 文本 [format 参数...])]
  [(:user 文本 [format 参数...])]
  [(:messages 消息...)]
  [(:options :temperature 0.7 ...)]     ; 或 (:options <现成的 chat-options 实例>)
  [(:tools 工具...)]
  [(:context 键 值)]
  [(:conversation 会话ID)]
  [(:call :content | :response | :result | :entity)]   ; 缺省 (:call :content)
  [(:stream 回调)])

(chat chat-client "你好")   ; 简写 ≡ (chat chat-client (:user "你好"))
```

终结操作：

| 终结子句 | 返回 |
|---|---|
| `(:call :content)`（缺省） | 回复文本（字符串） |
| `(:call :response)` | `chat-response` 实例 |
| `(:call :result)` | `chat-client-response` 实例（要看 `chat-client-response-status` 时用） |
| `(:call :entity)` | 回复解析为 JSON 值（**只解析，不校验**） |
| `(:stream fn)` | 每个文本增量回调 `(fn delta)`，返回最终 `chat-response` |

- `(:tools ...)` 是**请求级**工具，与 `build-chat-client` 的 `:tools` **取并集**。
- `(:conversation id)` ≡ `(:context :conversation-id id)`，`memory-filter` 读它。
- `(:options ...)` 单个非关键字实参视为现成的 `chat-options` 实例，否则透传给
  `make-chat-options`。

```lisp
(chat *chat-client*
  (:system "你是一个天气助手")
  (:user "~A 的天气怎么样？" city)     ; 多参数时按 format 处理
  (:tools 'get-weather)
  (:conversation "conv-1"))
```

### 函数形态入口

参数由程序拼时比宏顺手：

```lisp
(chat-client-call chat-client &key system user messages options tools context)   ; → chat-client-response
(chat-client-text chat-client &rest args)                                   ; → 文本
(chat-client-entity chat-client &rest args)                                 ; → JSON 值（只解析）
(chat-client-stream chat-client on-chunk &rest args)                        ; → chat-response
```

`args` 即 `chat-client-call` 的关键字参数。`chat` 宏正是展开到这四个函数。

```lisp
(chat-client-text k
                  :system "你是一个翻译"
                  :user (format nil "把「~A」翻译成英文" "你好，世界")
                  :options (make-chat-options :temperature 0.1))
```

- `messages` 插在 `system` 之后、`user` 之前。
- `system`/`user`/`messages` 至少要凑出**一条非 system 消息**，否则直接报错
  ——只有 system 的请求对模型没有意义，早失败好过换一个难懂的 provider 400。

### (:call :entity) —— 只解析，不校验

追加一条「只输出 JSON」的 system 指令 → 取回文本 → `strip-json-fences` →
`json-parse`。**不做 schema 校验、不重试**（没有 schema 参数）。

```lisp
(cl-agent/core:strip-json-fences text)   ; 剥离 ```json ... ``` 围栏，可单独使用
```

要「不符合 schema 就带着校验错误让模型重新输出」，给 chat-client 挂
`validation-turn-filter`——校验判据由它承担：

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
                    (cl-agent/core:structured-output-validate-fn
                     *schema* :parse-fn #'cl-agent/core:json-parse)
                    :max-retries 2))))

(cl-agent/core:chat *validating-chat-client*
  (:user "用 JSON 给出东京的信息")
  (:call :entity))
```

> **流式**：`(:stream fn)` / `chat-client-stream` 走 `invoke-chat-stream` —
> `:chat` filter 链照常生效，`:token-xform` 管道组装在流式 terminal 内侧。
> 两条限制：
> - **不跑工具循环**（单次流式调用）。会把工具发给模型的请求直接**报错**，
>   不静默丢掉工具执行；带工具请用 `chat-client-call`。
> - provider 不支持流式时 `chat-model-stream` 降级为一次性调用，整段文本作为
>   单个 chunk 送出（`:token-xform` 仍生效）。

### Invoke 原语

```lisp
(invoke-chat chat-client prompt)          ; :chat 链 → chat-model-call。单次，不执行工具
                                     ; → (values chat-response effective-prompt)
                                     ; 第二值是**经 :chat 链改写后**的 prompt：
                                     ; 工具执行必须按模型实际看到的那份 options 来，
                                     ; 否则 filter 注入的工具（如 tool-search 的
                                     ; search_tools）会「找不到工具」
(invoke-chat-stream chat-client prompt on-token)
                                     ; :chat 链 → chat-model-stream，:token-xform
                                     ; 管道在 terminal 内侧组装 → chat-response
                                     ; 单次调用，**不跑工具循环**
(invoke-tool chat-client tool-request)    ; :tool 链 → 工具执行 → chat-client:tool-result
(invoke-tool-batch chat-client tool-calls options context)
                                     ; → (values tool-results return-direct-p)
                                     ; 默认并行（lparallel）；批内任一工具声明
                                     ; :serial → 整批顺序；异常按三类分类路由
(invoke-turn chat-client chat-client-request)    ; :turn 链 → run-tool-loop → chat-client-response
(run-tool-loop chat-client chat-client-request)  ; 工具循环本体（:turn 链的 terminal，不是 filter）
(resume-turn chat-client loop-state decision &key payload)
                                     ; 从暂停点续跑（见「HITL：暂停与续跑」）
```

`run-tool-loop` 每轮：构建 prompt（messages + chat-client tools，与调用方 options
合并）→ `invoke-chat` → 若响应带 tool-calls 且通过 `eligibility-fn` → 执行工具
→ 把 assistant(tool-calls) 与 tool 结果消息追加进 messages → 下一轮；否则返回
`chat-client-response(:completed)`。

- 循环上限取自 settings `:max-tool-iterations`（缺省 10），超限发
  `cl-agent/core:max-tool-iterations-exceeded-error`
- `:return-direct` 工具：整批都声明时短路，工具结果直接成为最终答案，不回传模型
- `chat-client-tool-manager` 非 nil 时经 `execute-tool-calls` 协议执行，否则走
  `invoke-tool-batch`
- 模型报出不存在的工具名时不中断循环：`batch.lisp` 把 `tool-not-found-error`
  转成 `:semantic` 错误结果，`tool-result->text` 渲染为「错误：找不到工具 xxx」
  回传模型自纠
- `chat-client-tool-gate` 非 nil 时，每批工具执行**前**过一遍 gate；判 `:pause`
  则返回 `chat-client-response(:paused)`，工具一个都不执行（见
  [HITL：暂停与续跑](#hitl暂停与续跑chat-client-原语)）

### ToolCallingManager（实现）

对标 Spring `ToolCallingManager`——把「执行入口」升格为可注入协议。循环控制、
eligibility、`:tool` filter 链都仍在 chat-client 侧，manager 只决定调度策略。
这是本项目**唯一**的 ToolCallingManager（chat 层那套旧的已删除）。

```lisp
(cl-agent/core:execute-tool-calls manager chat-client response options)
;; options plist：(:tool-context ctx ...)
;; → tool-execution-result plist：(:messages ... :records ... :context ... :errors ...)
(make-tool-execution-result &key messages records context errors)

(make-sequential-tool-calling-manager)        ; 全串行（调试/严格副作用）
(make-virtual-thread-tool-calling-manager)    ; 并行默认，尊重 :serial
(make-thread-pool-tool-calling-manager &optional (pool-size 4))  ; 线程池（限流）
(default-tool-calling-manager)                ; = virtual-thread
```

> 签名只有这一个：`(manager chat-client response options)`。合并前的
> `cl-agent/chat` 还有一套 `(manager prompt response)` 的同名泛型函数，
> 逼得 chat-client `shadow` 这个符号；那套已整体删除，`execute-tool-calls`
> 现在唯一属于 `cl-agent/core`。
>
> `thread-pool-tool-calling-manager` 首版行为与 virtual-thread 相同
> （lparallel 内部已是线程池），`pool-size` 暂未绑定独立 kernel。

### 故障分类

```lisp
(classify-tool-error condition)  ; → :semantic | :transient | :environment
;; 条件层次
tool-failure                     ; tool-failure-class / tool-failure-message
semantic-tool-failure            ; 模型问题（参数/逻辑错误）→ 不重试
transient-tool-failure           ; 瞬态（超时/限流/503/429）→ 指数退避重试
environment-tool-failure         ; 环境（服务宕机/权限不足）→ 需人工介入
```

分类规则：`tool-failure` 子类直接取 `:class`；其余按错误消息关键词启发式判定
（timeout/连接拒绝/429/503 → `:transient`；permission denied/unauthorized/
forbidden → `:environment`）；兜底 `:semantic`（保守，不重试）。

批次路由（`invoke-tool-batch`）：

| 分类 | 工具声明 `:retry` | 实际动作 |
|---|---|---|
| `:semantic` | 任意 | 转文本回传模型（不中断循环） |
| `:transient` | `t` | **指数退避重试**，最多 `*transient-retry-attempts*` 次（缺省 3） |
| `:transient` | `nil` | 转文本回传模型 |
| `:environment` | 任意 | 转文本回传模型（见下方偏差） |

重试旋钮（都是 `cl-agent/core` 上的 `defparameter`）：

| 变量 | 缺省 | 含义 |
|---|---|---|
| `*transient-retry-attempts*` | 3 | 最大尝试次数（**含**首次） |
| `*transient-retry-base-delay*` | 0.1 | 退避基数秒：第 n 次尝试前睡 `base * 2^(n-1)` |

重试是**逐工具 opt-in** 的——只有声明了 `(:retry t)` 的工具才会被重试。
重试意味着重复副作用，框架不替工具作者做这个决定。

> **已知偏差：** `:environment` 目前仍只转文本。在 clj-agent 里它会
> **暂停等人**（`:env-retry` 类暂停）。本仓库的 HITL 已实现审批类暂停
> （`:tool-gate` + `resume-turn`），环境类暂停未做——它需要在屏障处
> （整批执行完）切入，而非工具解析处。详见
> [工具调用架构](tool-calling_CN.md)的「已知偏差」第 3 条。

### 内置 Filter（10 类）

```lisp
;; 1. memory-filter (:chat) —— 对标 MessageChatMemoryAdvisor
(memory-filter store &key (window 20))
;; store = chat-memory 实例。会话键从 prompt options 的 tool-context 取
;; :conversation-id；取不到 → 直接透传（不记不读）。
;; 每轮 LLM 调用前存 delta 消息、用完整历史替换 prompt messages，调用后存回复。
;; **刻意放循环内**（Spring 放循环外）：每轮落完整 transcript。
;; 建议注册为 filters 列表首位，让其它 filter 看到完整历史。

;; 2. logging-chat-filter (:chat) —— 对标 SimpleLoggerAdvisor
(logging-chat-filter &key log-fn (preview 100))
;; log-fn  (lambda (msg) ...)；缺省 log-info。preview = 文本预览截断长度

;; 3. logging-tool-filter (:tool)
(logging-tool-filter &key log-fn)
;; 记录工具名 + 结果/错误

;; 4. safeguard-turn-filter (:turn) —— 对标 SafeGuardAdvisor
(safeguard-turn-filter keywords &key (failure-response "抱歉，无法处理该请求。"))
;; 入口 messages 命中敏感词（大小写不敏感）→ 不调 chain，直接返回
;; chat-client-response(:cancelled)。短路在 :turn 层，:chat 的 memory 不执行——
;; 被拦的输入与拒答都不落库。只查入口消息，输出侧请用 :token-xform。

;; 5. validation-turn-filter (:turn) —— 对标 StructuredOutputValidationAdvisor
(validation-turn-filter validate-fn &key (max-retries 2))
;; validate-fn  (response) → (values ok-p feedback)
;; 不合格 → 把 feedback 作为 user 消息追加进 messages → 再调 (chain req)
;; 重入整条循环，让模型自我纠正。max-retries 缺省 2（最多 3 次循环）。
;; 硬规则：:paused/:cancelled/:error 结果透传、不重入；重试耗尽返回最后结果。
(structured-output-validate-fn schema &key parse-fn)  ; → validate-fn
;; schema    JSON Schema（hash-table / plist / 字符串）
;; parse-fn  如 #'cl-agent/core:json-parse；缺省 nil = 拿不到结构化值，一律放行
;; 判定：空文本 → 不合格；无 parse-fn → 放行；有 parse-fn 但解析失败 → 不合格；
;;      解析成功 → 按 schema 校验，错误逐条回喂
(cl-agent/core:strip-json-fences text)  ; 剥离 ```json ... ``` 围栏

;; 6. re-reading-filter (:turn) —— 对标 ReReadingAdvisor（RE2）
(re-reading-filter &key template)
;; template  (lambda (text) → new-text)；缺省把问题重复一遍
;; 只改写入口最后一条 user 消息；:resume-p 时跳过

;; 7. qa-turn-filter (:turn) —— 对标 QuestionAnswerAdvisor
(qa-turn-filter retriever &key (top-k 4) inject-when-empty template)
;; retriever          实现 (retrieve retriever query &key top-k) → 字符串列表
;; inject-when-empty  检索为空时是否仍注入（缺省 nil = 不注入，原样进循环）
;; template           (lambda (query docs) → new-text)；缺省标准问答模板
(defgeneric retrieve (retriever query &key top-k))   ; 用户实现，无检索依赖
;; 每 turn 注入一次：取入口最后一条 user 问题 → 检索 → 拼进消息。
;; 检索为空时不注入（偏离 Spring 的严格 grounding 语义）。

;; 8. tool-search-filter (:chat) —— 渐进式工具披露，对标 ToolSearchToolCallingAdvisor
(tool-search-filter index &key (limit 5) (instruction *tool-search-instruction*))
(defgeneric search-tools (index query &key limit))   ; → tool-callback 列表
(make-keyword-tool-index tools)                      ; 零依赖关键词索引（中文 bigram）
;; 每轮把暴露给模型的工具改写为 [search_tools] + 本会话已发现的工具。
;; **首轮只有 search_tools 一个 schema** —— 这才是省 token 的来源。
;; 模型调 search_tools(query) → 检索 → 记入本会话发现集合 → 下轮可直接调用。
;; search_tools 由 filter 内部创建并注入，**不要**自己加进 :tools。
;; 发现集合按 conversation-id 隔离。
;;
;; 实测（MiniMax，12 个工具）：首轮 1 vs 12；整轮 13 vs 24 个 schema，省 46%。
;; 工具越多省越多。

(build-chat-client :model m
              :tools '(get-weather get-stock send-mail ...)   ; 全量
              :filters (list (tool-search-filter
                              (make-keyword-tool-index
                               '(get-weather get-stock send-mail ...)))))

;; 9. timeout-filter (:tool)
(timeout-filter milliseconds)
;; 用 bordeaux-threads 在独立线程执行工具；超时 → tool-result
;; (:error (:class :transient ...))，可触发 :retry

;; 10. approval-filter (:tool)
(approval-filter &key approve-fn sensitive-names)
;; approve-fn       (tool-name args) → (values approved-p reason)；
;;                  缺省从 stdin 读 y/n
;; sensitive-names  需审批的工具名列表；缺省 nil = 全部审批
;; 拒绝 → 返回 tool-result(value=拒绝文本)，不执行，文本回传模型

;; 11. token-xform（:token-xform，(downstream) → (values emit finish)，非 around 链）
(token-redact-filter patterns &key (replacement "***"))  ; 逐 token 脱敏（无状态）
(hold-release-filter &key approve-fn)                    ; 缓冲全部 token →
;; 流结束时 (approve-fn full-text) → approved 一次性输出 / rejected 输出拒答文本
```

> `:token-xform` 在流式 terminal 内组装，**不经 `build-chain`**。

## cl-agent/client —— SimpleAgent（有状态对话 + HITL）

面向应用的易用层：一个有状态的 agent 对象，管住会话、可观测性、错误归一化
与人工审批。它是 chat-client 的薄封装——`agent-chat` 最终落到 `chat-client-call`。

agent **不自己存历史**：历史仍由 core 的 `memory-filter` 按 conversation-id
管，agent 只持 conversation-id + 轻量控制状态。

### make-agent

```lisp
(make-agent &key model system options tools memory conversation-id
                 callbacks chat-client settings)
;; model           chat-model 实例（不给 :chat-client 时必填）
;; system          默认系统提示
;; options         默认 chat-options
;; tools           工具符号列表
;; memory          chat-memory store；缺省 = 新建滑动窗口记忆；
;;                 nil = 无记忆（每轮独立）
;; conversation-id 会话 ID（缺省自动生成）
;; callbacks       回调 plist（见下）
;; settings        chat-client settings alist，如 '((:max-tool-iterations . 10))
;; chat-client          预构建 chat-client（要挂 filter 时用这个）

(agent-id a) (agent-chat-client a) (agent-memory a) (agent-conversation-id a)
(agent-callbacks a) (agent-turn-count a)
```

> **本层不接受 `:filters`**——传了会**直接报错**并给出迁移指引（而不是静默
> 忽略）。agent 只暴露 `:callbacks`；要挂 filter 请自建 chat-client 后经 `:chat-client`
> 传入。这条边界是刻意的：简单层一旦开始转发 filter，就会慢慢长成第二个
> chat-client——本仓库刚删掉的 ChatClient 正是这么烂掉的。
>
> 给 `:chat-client` 时，`memory-filter` 由**调用方自己**负责挂载
> （`make-agent` 不改动预构建 chat-client 的 filters）；`:memory` 只是告诉 agent
> 去哪读 `agent-history`。

线程安全：单个 agent 实例**不可**被多线程并发 `agent-chat`。每个 agent 绑定
单一对话线程；要并发就按会话各建一个 agent（共享同一个持久 store、
各自 `:conversation-id` 即可隔离）。

### 对话

```lisp
(agent-chat agent message &key options tools)
;; → 回复文本；出错时 → (values nil result)
(agent-chat-result agent message &key options tools)   ; → agent-result（**不抛异常**）
(agent-history agent)      ; → 消息列表（无记忆时 nil）
(agent-reset agent)        ; 清空会话
```

### agent-result（归一化，不发条件）

```lisp
(agent-result-status r)        ; :completed | :paused | :cancelled | :error
(agent-result-text r)          ; :completed 时的回复文本
(agent-result-response r)      ; chat-response
(agent-result-error r)         ; :error 时的条件对象
(agent-result-pending-tool r)  ; :paused 时待审批的工具
(agent-result-pause-reason r)  ; :paused 的原因
```

| status | 含义 |
|---|---|
| `:completed` | 正常完成 |
| `:paused` | 工具待审批（`:on-tool-call` 返回了 `:interrupt`） |
| `:cancelled` | 被 filter 短路（如 safeguard 命中敏感词） |
| `:error` | LLM/工具/其它异常 |

> core 的 `chat` 宏出错就抛条件；agent 层把它归一化成结果对象。理由：
> agent 是面向应用的入口，一次 LLM 调用失败是**预期内**的常态（网络抖动、
> 限流、模型抽风），调用方该拿到状态而不是被条件掀翻。

### callbacks

```lisp
(make-agent :model m :tools '(get-weather)
            :callbacks (list :on-turn-start  (lambda (agent) ...)
                             :on-turn-end    (lambda (agent result) ...)
                             :on-turn-error  (lambda (agent condition) ...)
                             :on-tool-call   (lambda (name args) ...)
                             :on-tool-result (lambda (name text) ...)
                             :on-interrupt   (lambda (agent result) ...)
                             :on-resume      (lambda (agent decision) ...)))
```

| 回调 | 签名 | 时机 |
|---|---|---|
| `:on-turn-start` | `(agent)` | 每轮开始前 |
| `:on-turn-end` | `(agent result)` | 每轮正常结束 |
| `:on-turn-error` | `(agent condition)` | 该轮出异常 |
| `:on-tool-call` | `(name args)` | 工具**执行前**；返回值可触发 HITL（见下） |
| `:on-tool-result` | `(name text)` | 工具执行后 |
| `:on-interrupt` | `(agent result)` | 轮次因待审批而暂停 |
| `:on-resume` | `(agent decision)` | `agent-resume` 续跑前 |

**回调抛异常不会掀翻整轮对话**——它们是观测手段，不是控制流，异常记进日志
后忽略。`:on-tool-call` 即便抛异常也按「没表态」处理（放行）。

内部实现：`:on-tool-result` 桥接为一个 `:tool` filter（结果只能在执行后拿到），
`:on-tool-call` 桥接为 chat-client 的 `tool-gate`（要能在执行**前**否决）。

### 人工审批（HITL）

**配 `:on-tool-call` 让它返回 `(:interrupt . 原因)` 即启用**——不是另一套
机制，就是回调的返回值：

```lisp
(make-agent :model m :tools '(rm-file)
            :callbacks (list :on-tool-call
                             (lambda (name args)
                               (when (string= name "rm_file")
                                 (cons :interrupt
                                       (format nil "删除 ~A 需审批"
                                               (getf args :path)))))))
```

`:on-tool-call` 的返回值 → gate 判决：

| 返回值 | 判决 |
|---|---|
| `nil` / 其它 | 放行 |
| `:interrupt` | 暂停待审批（无原因） |
| `(:interrupt . 原因)` 或 `(:interrupt 原因)` | 暂停，并带上原因 |

```lisp
(agent-paused-p agent)      ; → t / nil
(agent-pending-tool agent)  ; → 当前待审批的 tool-call（未暂停时 nil）

(agent-resume agent decision &key payload)   ; → agent-result（**不抛异常**）
;; :approved  批准。payload (:args 新参数) → 编辑后批准（用新参数执行）
;; :rejected  拒绝。payload (:message 理由) → 「已拒绝执行：<理由>」回模型
;; :reply     答复即结果（ask-user 语义）。payload (:message 答复) **必填**
;;            → pending 工具不执行，答复直接作为它的结果回模型
```

**关键不变式：暂停时工具一个都没执行。** 续跑后可能**再次** `:paused`
（本批还有别的敏感工具，或后续轮次又触发）——按状态循环处理，别假设
resume 一次就到底。

未处于暂停状态时调 `agent-resume` 会报错（用 `agent-paused-p` 先判）。

## 迁移

### 包合并（`cl-agent/http` / `/chat` / `/chat-client` → `cl-agent/core`）

三个包已合并为一个 `cl-agent/core`。机械改名，逐一对应：

| 旧 | 新 |
|---|---|
| `cl-agent/chat-client:X` | `cl-agent/core:X` |
| `cl-agent/chat:X` | `cl-agent/core:X` |
| `cl-agent/http:X` | `cl-agent/core:X` |
| 昵称 `cla/chat-client` / `cla/chat` / `cla/http` | `cla/core` |
| `cl-agent/chat-client:build-chat-client` | `cl-agent/core:build-chat-client` |
| `cl-agent/chat:deftool` | `cl-agent/core:deftool` |
| `cl-agent/http:http-request` | `cl-agent/core:http-request` |
| `:shadowing-import-from` 相关写法 | **不再需要**，整体删掉 |

照旧包名写的代码会直接撞上
`Package CL-AGENT/CHAT-CLIENT does not exist`。

### 从 ChatClient 迁移

**ChatClient 移植层已整体删除**——它是 Spring AI 的 ChatClient + Builder +
fluent RequestSpec 移植。Builder 与链式 spec 是 Java 的表达习惯：在 Lisp 里
`build-chat-client` 的关键字参数 + 声明式 `chat` 宏覆盖同样的地面，且少一层。

> **注意：`cl-agent/client` 这个包名被复用了。** 它曾是 ChatClient 移植层
> （已删），**现在是 SimpleAgent**（见
> [cl-agent/client](#cl-agentclient--simpleagent有状态对话--hitl)）。
> 也就是说包还在、名字还在，但里面是完全不同的东西——旧的 ChatClient
> 符号一个都不剩。

以下符号**不再存在**：
`make-chat-client`、`chat-client-builder`、`default-system`、
`default-options`、`default-tools`、`build-client`、`client-prompt`、
`prompt-system`、`prompt-user`、`prompt-add-messages`、`prompt-with-options`、
`prompt-tools`、`prompt-context`、`prompt-conversation`、`call-client-response`、
`call-response`、`call-content`、`call-entity`、`stream-content`、
`client-request`、`client-response`、`make-client-request`、
`make-client-response`、`context-get`、`context-set`、`client-chat-client`、
`client-default-system`、`client-default-options`、`client-default-tools`。

> 移植层里还有一个叫 `chat-client` 的类，也一并删了。**这个名字后来被复用**：
> 现在的 `cl-agent/core:chat-client` 是本框架的内核类（原 `kernel`），
> 与移植层那个同名类没有任何关系。

`chat` 宏**幸存**，语法原样可用——只是符号现在来自 `cl-agent/core`。

要「有状态对话 + 一个对象管住会话」的那种手感（ChatClient 常见用法），
现在用 [SimpleAgent](#cl-agentclient--simpleagent有状态对话--hitl)：
`(make-agent :model m :system "..." :tools '(...))` + `(agent-chat a "...")`。

| 旧（ChatClient 移植层，v9.0.0 已删） | 新（ChatClient 内核） |
|---|---|
| `(make-chat-client model)` | `(build-chat-client :model model)`（`:model` 是**关键字**参数，不是位置参数） |
| `(chat client ...)` | `(chat chat-client ...)`——子句不变 |
| fluent spec（`client-prompt` → `prompt-user` → `call-content`） | `chat` 宏子句，或 `chat-client-text` 等函数形态 |
| `(call-content spec)` | `(:call :content)` / `chat-client-text` |
| `(call-response spec)` | `(:call :response)` |
| `(call-client-response spec)` | `(:call :result)` → `chat-client-response`（`client-response` 载体已不存在） |
| `(call-entity spec :schema s)` | `(:call :entity)` / `chat-client-entity`——**无 schema 参数**，校验挂 `validation-turn-filter` |
| `(stream-content spec fn)` | `(:stream fn)` / `chat-client-stream` |
| `(prompt-context spec k v)` | `(:context k v)` |
| `(prompt-conversation spec id)` | `(:conversation id)` |
| `default-tools` (Builder) | `build-chat-client :tools`（请求级 `(:tools ...)` 与之取并集） |
| `default-options` (Builder) | `build-chat-client :options`（请求级 `(:options ...)` 合并覆盖） |
| `default-system` (Builder) | `build-chat-client :system`（请求级 `(:system ...)` 覆盖） |
| `client-request` / `client-response` / `context-get` / `context-set` | `chat-client-request` / `chat-client-response` + `chat-client-request-context`（plist） |

### 三层职责对齐 Spring AI（未发布）

Provider / ChatModel / ChatClient 的职责边界重新划分，**不保向后兼容**。

**1. ChatModel 承重，`client` 类退役。**

`cl-agent/llm` 的 `client` 类连同 `client-chat` / `chat-simple` /
`chat-with-tools` / `chat-multi-turn` / `batch-chat` / `chat-stream` 一族整体
移除——它是一条与 `chat-model` 平行的死路径，重复 `provider-chat-model` 的
职责，而 chat-client 主干从不经过它。**重试逻辑当时就困在这条路径里
（`chat-with-retry`），于是整条主干无重试**。

| 旧 | 新 |
|---|---|
| `(make-client :provider :anthropic :model "...")` | `(create-chat-model :anthropic :model "...")` |
| `(client-chat client messages ...)` | `(chat-model-call model prompt)` |
| `(chat-simple client "...")` | `(chat-response-text (chat-model-call model "..."))` |
| `(chat-stream client msgs cb ...)` | `(chat-model-stream model prompt on-delta)`，或带 filter 链的 `invoke-chat-stream` |
| `:retry` / `:retry-delay` / `chat-with-retry` | `:retry-policy (make-retry-policy ...)`（见 [ChatModel 协议](#chatmodel-协议chatmodel--streamingchatmodel)） |
| `(embed client "...")` | `(embed provider "...")`——嵌入走 `llm-embed` SPI，接受 provider |
| `(estimate-cost client in out)` | `(estimate-cost provider in out)` |
| `count-tokens-for-client` | `(count-tokens text provider-name)` |

`retryable-error-p` 的裸 HTTP 分类逻辑收归 `error-retryable-p`（新增
`http-error` 方法），分类仍是单一来源。

**2. Model 抽象协议。**

新增 `model-request` / `model-response` / `model-result` / `model-options`
四个抽象类与访问协议（对标 `org.springframework.ai.model`）。`prompt`、
`chat-response`、`generation`、`chat-options`、`embedding-response` 接入其中，
横切代码（计费、配额、观测）由此可以不分模态：

```lisp
(response-usage resp)   ; chat-response 与 embedding-response 都答得上来
(response-results resp) ; generation 列表 / 向量列表
(request-instructions p) ; prompt 的消息列表
```

**3. 载体改名 + 语义摆正。**

| 旧 | 新 |
|---|---|
| `turn-request`（持有裸 messages） | `chat-client-request`（持有 `prompt`） |
| `turn-result` | `chat-client-response` |
| `turn-result-response` | `chat-client-response-chat-response` |
| `turn-result-tool-context` | `chat-client-response-context` |
| `context` 里的 `:caller-options` 暗管道 | 请求级 options 是 `prompt` 的一部分 |
| 手工 `make-turn-request` 重建 | `chat-client-request-mutate` |

**4. ChatClient 收窄到四个槽。**

| 旧（12 个平级槽） | 新 |
|---|---|
| `tools` / `system` / `options` | `default-request`（`chat-client-default-request`） |
| `eligibility-fn` / `tool-gate` / `state-slots` / `tool-manager` / `loop-fn` / `resume-fn` / `settings` 的 `:max-tool-iterations` | `tool-calling`（`tool-calling-config`） |
| 逐槽拆开再 `build-chat-client` 一遍 | `chat-client-mutate` / `tool-calling-config-mutate` |

`build-chat-client` 的扁平参数**全部保留**，另加 `:max-tool-iterations`。
`:settings` **已移除**——传了直接报错并给出迁移写法（`make-agent` 同）。留一层
「仍然接受」的兼容壳等于把 `(cdr (assoc :max-tool-iterations ...))` 那个读法
留在原地，只是换了个入口。读取侧：`chat-client-settings` / `chat-client-loop-fn` /
`chat-client-resume-fn` 不再存在，改用便捷访问器或穿过聚合读。

**5. 该是类的成了类。**

| 旧 | 新 |
|---|---|
| `tool-execution-result` plist（`getf`） | `tool-execution-result` 类（`tool-execution-messages` / `-context` / `-return-direct-p` / `-errors`） |
| `tool-result-error` 的 `(:class ... :message ...)` plist | `tool-error-info` 类（`tool-error-class` / `-message` / `-cause`），构造时校验分类 |
| `state-slots` 的 `((key :init v :reduce fn) ...)` | `state-slot` 类列表（`make-state-slot :notes :reduce-fn #'append`） |
| `resume-turn` 的 `payload` plist | `resume-payload` 类（入口仍接受 plist，归一一次） |
| `retry-config` struct | `retry-config` 类 |
| `settings` alist | `tool-calling-config` 的具名槽 |

`tool-error-info` 那条最要紧：`:class` **是故障路由的判据**（只有 `:transient`
且工具声明了 `:retry` 才重试）。它当年是 plist 里的一个键，拼错就静默变 `NIL`，
表现出来只是「声明了 `:retry` 的工具没重试」——不报错、不告警。仓库里的测试
甚至编造过一个 `:timeout` 分类并绿了十几个版本；改成类之后那个测试当场就断了。

`initialize-instance :after` 不变式：filter 的缺省名不再为 NIL；
`chat-client-response(:paused)` 不带 `loop-state` 时构造即报错；
`tool-error-info` 的分类必须是三者之一；`state-slot` 的键必须是 keyword、
reducer 必须可调用。

**6. Provider 层横切观测。**

```lisp
(let* ((tally (make-llm-usage-tally))
       (*llm-call-observer* (usage-tally-observer tally)))
  (chat *chat-client* "...")
  (usage-tally-output-tokens tally))
```

`*llm-call-observer*` / `*llm-stream-observer*` 是挂在 `(t)` 上的 `:around`，
覆盖每一个 provider（含 mock 与测试桩），无论它继承自哪个基类。与 ChatModel
的 `observation-fn` 分工：那边包住一次**逻辑**调用（含重试记一条，算延迟），
这边包住每一次**真实 wire 调用**（重试三次触发三次，算钱）。

### 从 chat-client:tool-response 迁移（载体改名）

chat-client 工具链的响应载体改名为 `tool-result`，与 turn 链的 `chat-client-request` /
`chat-client-response` 对称，并借此消除与协议消息层 `tool-response` 的撞名
（撞名消失后三个包才得以合并）。

| 旧（已不存在） | 新 |
|---|---|
| `cl-agent/chat-client:tool-response`（类） | `cl-agent/core:tool-result` |
| `cl-agent/chat-client:make-tool-response` | `cl-agent/core:make-tool-result` |
| `(make-tool-response :result X)` | `(make-tool-result :value X)`——**初始参数由 `:result` 改为 `:value`** |
| `tool-response-result` | `tool-result-value` |
| `tool-response-writes` | `tool-result-writes` |
| `tool-response-error` | `tool-result-error` |

`tool-request` / `make-tool-request` / `tool-request-function` /
`tool-request-args` / `tool-request-context` **不变**（前缀改为
`cl-agent/core:`）。新增导出 `cl-agent/core:tool-result->text`。

> **别混淆**：`cl-agent/core:tool-response` / `make-tool-response` /
> `tool-response-message` / `tool-response-text` **依然存在**——那是**协议消息层**
> 的值对象（id/name/text），放进 role=:tool 的消息发回模型，与 chat-client 执行链的
> `tool-result`（value/writes/error）是不同层的不同东西。合并前它属于
> `cl-agent/chat`，现在同在 `cl-agent/core`，两者不再同名，可以共存。

### 从 chat 层 ToolCallingManager 迁移（已删除）

以下旧 `cl-agent/chat` 符号**不再存在**：`tool-calling-manager`、
`default-tool-calling-manager`、`make-default-tool-calling-manager`、
`execute-tool-calls`（`(manager prompt response)` 签名）、
`execute-one-tool-call`、`process-tool-execution-error`、
`concurrent-tool-calling-manager`、`make-concurrent-tool-calling-manager`、
`manager-pool-size`、`manager-timeout`、`manager-inherit-specials`、
`shutdown-tool-calling-manager`、`with-concurrent-tool-calling-manager`、
`tool-execution-result`、`tool-execution-conversation-history`、
`tool-execution-return-direct-p`、`tool-execution-last-message`。

| 旧（chat 层 manager） | 新（chat-client） |
|---|---|
| `(make-default-tool-calling-manager)` | `(make-sequential-tool-calling-manager)` |
| `(make-concurrent-tool-calling-manager :pool-size 4)` | `(make-thread-pool-tool-calling-manager 4)` |
| 并行默认 | `(make-virtual-thread-tool-calling-manager)` = `(default-tool-calling-manager)` |
| `(execute-tool-calls mgr prompt response)` | `(execute-tool-calls mgr chat-client response options)` |
| 自己驱动循环：`chat-model-call` + `execute-tool-calls` | `(chat chat-client ...)` / `chat-client-call`——chat-client 是唯一路径 |
| `(shutdown-tool-calling-manager mgr)` / `with-concurrent-tool-calling-manager` | 无需——chat-client manager 不持有需显式释放的线程池 |
| `tool-execution-conversation-history` / `-last-message` / `-return-direct-p` | `chat-client-response-chat-response` / `chat-client-response-context`；manager 层用 `make-tool-execution-result` 的 `:messages` |
| 特化 `process-tool-execution-error` | `:tool` filter，或读 `tool-result-error` 的 `:class` |
| `:inherit-specials` / `manager-inherit-specials` | `cl-agent/core:with-inherited-specials` + `*inherited-special-variables*` |

> **注意**：`cl-agent/core` 现在也有一个 `default-tool-calling-manager`，但它是
> **零参工厂函数**（返回 virtual-thread manager），与已删除的 chat 层同名
> **类**无关。

## cl-agent/llm —— 提供商层

```lisp
(create-chat-model :anthropic :model "..." :api-key "..." :options opts)
;; 支持：:anthropic :openai :zhipu :deepseek :gemini :mistral
;;       :ollama :dashscope :minimax（别名 google/qwen/bailian/claude/glm...）
```

DeepSeek 前缀续写（beta）：

```lisp
;; 最后一条 assistant 消息作为前缀，模型从其继续生成（建议搭配 :stop）
(cl-agent/llm/providers:deepseek-prefix-chat provider
  (list (list :role :user :content "写一句诗")
        (list :role :assistant :content "春天的风"))
  :max-tokens 256)
```

Provider SPI（自定义提供商实现）：

```lisp
(defmethod cl-agent/core:llm-chat ((p my-provider) messages
                                   &key max-tokens temperature model tools system)
  ;; messages 为中立 plist：(:role :user :content "...")
  ;; 返回 cl-agent/core:llm-response 对象
  ...)
```

## cl-agent/mock —— 测试支持

```lisp
(cl-agent/mock:make-mock-llm)          ; 智能规则响应，无需 API 密钥
(cl-agent/mock:make-quick-mock :smart)
;; 配合 (make-provider-chat-model (make-mock-llm)) 即可全链路演示
```
