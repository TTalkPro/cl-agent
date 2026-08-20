# CL-Agent API 参考

[English](API.md)

按包组织的 API 速查。与 Spring AI 2.0 的对应关系标注在各节标题中。

两层入口：

- **SimpleAgent**（`cl-agent/client`）：有状态对话 + callbacks + 错误归一化
  + HITL。见 [cl-agent/client](#cl-agentclient--simpleagent有状态对话--hitl)。
- **Kernel + Filter**（`cl-agent/core`）：`chat` 宏 / `kernel-chat` →
  `cl-agent/core:invoke-turn` 三链。前者是后者的薄封装。

Advisor 与 ChatClient 两层移植物均已整体退役，见文末[迁移指引](#迁移)。

## 包与 :use

现在只有这几个包：

| 包 | 昵称 | 角色 |
|---|---|---|
| `cl-agent/core` | `cla/core` | 框架本体（单包）：基础设施 + HTTP/SSE + JSON Schema + `llm-chat` SPI + Chat API + Kernel/Filter 三链 + `chat` 宏 |
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

`examples/kernel-usage.lisp` 与 `scripts/live-test.lisp` 的 `defpackage`
即是这一形式（它们只 `:use` core）。

> **`cl-agent/http` / `cl-agent/chat` / `cl-agent/kernel` 三个包已合并进
> `cl-agent/core`**，昵称 `cla/http` / `cla/chat` / `cla/kernel` 统一为
> `cla/core`。合并前 chat 与 kernel 有三个同名导出：`tool-response` /
> `make-tool-response`（chat 是协议消息层的值对象，kernel 是执行链的响应
> 载体）与 `execute-tool-calls`（两套签名不同的 manager 协议），逼得
> kernel 必须 `:shadow`，下游还得自己写 `:shadowing-import-from`。
> 已从根上消除：kernel 的载体改名为 `tool-request` / `tool-result`，chat
> 的旧 ToolCallingManager 整体删除，随后三包合并。**旧文档里所有
> 「必须 shadowing-import」的说法都已作废。** 迁移见文末[迁移指引](#迁移)。
>
> 全库已**零 shadow**：`cl-agent/llm` 曾因低层函数与 core 的 `chat` 宏
> 撞名而 `(:shadow #:chat)`，该函数已改名 `client-chat`，shadow 随之消失。
> 现在同时 `:use` 任意本库的包都不会撞名。

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
> role=:tool 的消息里发回模型。它与 kernel 执行链的响应载体
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

> **工具循环选项不在 chat-options 里。** 循环上限由 kernel 的 settings 承担：
> `(build-kernel :settings '((:max-tool-iterations . 10)))`；续跑判据由
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
> 再用 `(build-kernel {:tools [#'get-weather]})` 显式传入。Clojure 的 var 带
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

**工具解析**（kernel 的 batch / manager / tool-search filter 依赖）：

```lisp
(find-callback-for-call options tool-call)   ; 一次 tool-call → callback
;; 只在**本次请求 options 暴露的工具**里按名解析；找不到发
;; tool-not-found-error。它**不回退全局注册表**——这是防注入 /
;; 防提权的安全边界：模型报出一个没暴露给它的工具名，绝不执行。
```

> 模型幻觉工具名很常见。kernel 的 `batch.lisp` 会捕获
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
> 住在 kernel 层：`run-tool-loop` + `invoke-tool-batch` + 三个
> [ToolCallingManager](#toolcallingmanager实现)。「自己调
> `chat-model-call` 再用 `execute-tool-calls` 驱动循环」这条 user-controlled
> 路径已不存在，kernel 是唯一路径。
>
> `*inherited-special-variables*` / `with-inherited-specials` 不属于已删除的
> manager，它们仍在（`core/utils.lisp`），与 HTTP 异步请求共用同一份名单，
> 需要时从 `cl-agent/core` 取。

### ChatModel 协议（`ChatModel` / `StreamingChatModel`）

```lisp
(chat-model-call model prompt)             ; prompt 可为字符串/消息列表
(chat-model-stream model prompt on-chunk)  ; on-chunk: (delta-text)，真 SSE
(chat-model-default-options model)

(make-provider-chat-model provider :default-options options)
```

ChatModel 只做**单次**模型调用——解析工具引用并注入 schema，但不执行工具。
携带 tool-calls 的响应原样返回，工具循环由 `cl-agent/core:run-tool-loop`
（`:turn` 链的 terminal）承担。

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

记忆本身**不是** kernel 的字段——把它挂成 filter：
`(cl-agent/core:memory-filter memory)`。

## cl-agent/core —— Kernel + Filter 三链（执行内核）

三条洋葱链，各自有独立的载体与 terminal：

| 链 | 钩子槽 | 请求 → 响应 | terminal |
|---|---|---|---|
| `:chat` | `filter-chat-hook` | `prompt` → `chat-response` | `chat-model-call` |
| `:tool` | `filter-tool-hook` | `tool-request` → `tool-result` | 工具执行 |
| `:turn` | `filter-turn-hook` | `turn-request` → `turn-result` | `run-tool-loop` |
| `:token-xform` | `filter-token-xform` | `(downstream) → (values emit finish)` | 流式 token 流 |

```
invoke-turn → [:turn filters] → run-tool-loop
  ├── invoke-chat → [:chat filters] → chat-model-call
  ├── 有 tool-calls 且 eligible → invoke-tool-batch → [:tool filters] → 工具
  │     追加消息 → 回到上一步
  └── 否则 → turn-result(:completed)
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

### defilter 宏（对标 `defadvisor`，但无泛型分发）

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

> **filters 列表顺序即洋葱层级：靠前 = 靠外 = 先执行。** filter 没有 order 字段
> （对比 Advisor 时代的 `+*-advisor-order+` 常量：那套东西连同 Advisor 一起没了）。

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
(tool-result-error r)       ; (:class :semantic|:transient|:environment :message "...") 或 nil

(tool-result->text r)       ; → 回传模型的文本；错误结果渲染为「错误：<message>」

;; Turn 链
(make-turn-request messages &key context resume-p)
(turn-request-messages r) (turn-request-context r) (turn-request-resume-p r)

(make-turn-result status &key response tool-context tool-calls-made
                              loop-state pending-tool pause-reason)
(turn-result-status r)          ; :completed | :paused | :cancelled | :error
(turn-result-response r)        ; 最终 chat-response（出错时 nil）
(turn-result-tool-context r)    ; 折叠完全部批次 :writes 后的最终 context
(turn-result-tool-calls-made r) ; 本轮工具调用计数
;; 仅 :paused 时有值（见「HITL：暂停与续跑」）
(turn-result-loop-state r)      ; 续跑快照，喂给 resume-turn
(turn-result-pending-tool r)    ; 待审批的工具（name/args/id）
(turn-result-pause-reason r)    ; gate 给的原因文本
```

> `:chat` 链**不用**包装载体：请求就是 `cl-agent/core:prompt`，响应就是
> `chat-response`。
>
> 命名：`tool-request` → `tool-result` 与 turn 链的 `turn-request` →
> `turn-result` 对称。`tool-result` 曾叫 `tool-response`（初始参数 `:result`，
> 读取器 `tool-response-result`），与 `cl-agent/core:tool-response` 撞名——
> 后者是协议消息层的值对象，两者分属不同层。改名后撞名消失。

### Kernel

```lisp
(build-kernel &key model tools filters eligibility-fn settings tool-manager
                   system options tool-gate state-slots)
;; model          chat-model 实例
;; tools          工具符号列表或 tool-callback 列表（缺省 nil）
;; filters        filter 实例列表（顺序 = 洋葱层级；缺省 nil）
;; eligibility-fn (response context) → boolean，判断是否继续工具迭代
;;                （缺省 (constantly t)）
;; settings       配置 alist，如 '((:max-tool-iterations . 10))
;; tool-manager   ToolCallingManager 实例；nil = 走 invoke-tool-batch 原路径
;; system         默认系统提示文本；请求级 (:system ...) 覆盖它
;; options        默认 chat-options；请求级 (:options ...) 合并覆盖
;; tool-gate      工具审批闸门（HITL）：(tool-call) → :proceed | :pause
;;                | (:pause . 原因)；nil（缺省）= 不审批，全部直接执行
;; state-slots    状态槽声明 ((key :init v0 :reduce fn) ...)——工具批次
;;                :writes 的合并语义（见「:writes 状态折叠」）

(kernel-model k) (kernel-tools k) (kernel-filters k)
(kernel-eligibility-fn k) (kernel-settings k) (kernel-tool-manager k)
(kernel-default-system k) (kernel-default-options k) (kernel-tool-gate k)
(kernel-state-slots k)
```

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
(build-kernel :model m :tools '(take-note)
              :state-slots (list (list :notes :init nil
                                       :reduce (lambda (old new)
                                                 (append old new)))))

;; 一批两个 take-note("a") take-note("b") → 屏障折叠 → (:notes ("a" "b"))
;; 下一轮工具经 tool-context 看到折叠后的快照；
;; 最终由 (turn-result-tool-context result) 交还调用方
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
(fold-batch-writes kernel tool-results context)
;; → 新context；跳过失败调用的 writes，冲突自动告警
```

kernel 极简：**没有 memory 字段**——记忆是 filter，不是 kernel 的固有属性。

> **没有 Builder。** kernel 的装配就是 `build-kernel` 的关键字参数——
> 旧 Builder 的 `default-system` / `default-options` / `default-tools`
> 分别对应 `:system` / `:options` / `:tools`。

三层默认值的合并语义：

| 项 | kernel 级 | 请求级 | 合并 |
|---|---|---|---|
| system | `build-kernel :system` | `(:system ...)` | 请求级**覆盖** |
| options | `build-kernel :options` | `(:options ...)` | 请求级**优先**，未提及的默认项保留 |
| tools | `build-kernel :tools` | `(:tools ...)` | **取并集** |

### HITL：暂停与续跑（kernel 原语）

`:tool-gate` 是人工审批的底层原语（`cl-agent/client` 的
[SimpleAgent HITL](#人工审批hitl) 就是它的封装）。

```lisp
(build-kernel
  :model *model* :tools '(rm-file)
  ;; (tool-call) → :proceed | :pause | (:pause . 原因)
  :tool-gate (lambda (tc)
               (if (string= (tool-call-name tc) "rm_file")
                   (cons :pause "删除需审批")
                   :proceed)))
```

gate 在**批执行之前**对本批每个 tool-call **恰好评估一次**——gate 常带副作用
（审计日志、审批 UI、计数器），「恰好一次」是契约的一部分。任一判 `:pause`
则整轮暂停：**工具一个都不执行**，`run-tool-loop` 返回 `turn-result(:paused)`。

```lisp
(resume-turn kernel loop-state decision &key payload)
;; loop-state  turn-result(:paused) 上的 (turn-result-loop-state r)
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

`loop-state` 刻意**不含** kernel / gate / callbacks——那些是代码侧的东西，
resume 时重新提供；本类只装「续跑所需的数据」。

### chat 宏 —— 声明式请求 DSL（调用方入口）

```lisp
(chat kernel
  [(:system 文本 [format 参数...])]
  [(:user 文本 [format 参数...])]
  [(:messages 消息...)]
  [(:options :temperature 0.7 ...)]     ; 或 (:options <现成的 chat-options 实例>)
  [(:tools 工具...)]
  [(:context 键 值)]
  [(:conversation 会话ID)]
  [(:call :content | :response | :result | :entity)]   ; 缺省 (:call :content)
  [(:stream 回调)])

(chat kernel "你好")   ; 简写 ≡ (chat kernel (:user "你好"))
```

终结操作：

| 终结子句 | 返回 |
|---|---|
| `(:call :content)`（缺省） | 回复文本（字符串） |
| `(:call :response)` | `chat-response` 实例 |
| `(:call :result)` | `turn-result` 实例（要看 `turn-result-status` 时用） |
| `(:call :entity)` | 回复解析为 JSON 值（**只解析，不校验**） |
| `(:stream fn)` | 每个文本增量回调 `(fn delta)`，返回最终 `chat-response` |

- `(:tools ...)` 是**请求级**工具，与 `build-kernel` 的 `:tools` **取并集**。
- `(:conversation id)` ≡ `(:context :conversation-id id)`，`memory-filter` 读它。
- `(:options ...)` 单个非关键字实参视为现成的 `chat-options` 实例，否则透传给
  `make-chat-options`。
- `(:advisors ...)` 已移除：写了会在**宏展开期直接报错**并给出迁移指引
  （不是静默忽略——若被悄悄丢掉，记忆/护栏会无声失效）。

```lisp
(chat *kernel*
  (:system "你是一个天气助手")
  (:user "~A 的天气怎么样？" city)     ; 多参数时按 format 处理
  (:tools 'get-weather)
  (:conversation "conv-1"))
```

### 函数形态入口

参数由程序拼时比宏顺手：

```lisp
(kernel-chat kernel &key system user messages options tools context)   ; → turn-result
(kernel-chat-text kernel &rest args)                                   ; → 文本
(kernel-chat-entity kernel &rest args)                                 ; → JSON 值（只解析）
(kernel-chat-stream kernel on-chunk &rest args)                        ; → chat-response
```

`args` 即 `kernel-chat` 的关键字参数。`chat` 宏正是展开到这四个函数。

```lisp
(kernel-chat-text k
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

要「不符合 schema 就带着校验错误让模型重新输出」，给 kernel 挂
`validation-turn-filter`——校验判据由它承担：

```lisp
(defvar *schema*
  "{\"type\":\"object\",
    \"properties\":{\"name\":{\"type\":\"string\"},
                   \"population\":{\"type\":\"integer\"}},
    \"required\":[\"name\",\"population\"]}")

(defvar *validating-kernel*
  (cl-agent/core:build-kernel
    :model *model*
    :filters (list (cl-agent/core:validation-turn-filter
                    (cl-agent/core:structured-output-validate-fn
                     *schema* :parse-fn #'cl-agent/core:json-parse)
                    :max-retries 2))))

(cl-agent/core:chat *validating-kernel*
  (:user "用 JSON 给出东京的信息")
  (:call :entity))
```

> **流式**：`(:stream fn)` / `kernel-chat-stream` 走 `invoke-chat-stream` —
> `:chat` filter 链照常生效，`:token-xform` 管道组装在流式 terminal 内侧。
> 两条限制：
> - **不跑工具循环**（单次流式调用）。会把工具发给模型的请求直接**报错**，
>   不静默丢掉工具执行；带工具请用 `kernel-chat`。
> - provider 不支持流式时 `chat-model-stream` 降级为一次性调用，整段文本作为
>   单个 chunk 送出（`:token-xform` 仍生效）。

### Invoke 原语

```lisp
(invoke-chat kernel prompt)          ; :chat 链 → chat-model-call。单次，不执行工具
                                     ; → (values chat-response effective-prompt)
                                     ; 第二值是**经 :chat 链改写后**的 prompt：
                                     ; 工具执行必须按模型实际看到的那份 options 来，
                                     ; 否则 filter 注入的工具（如 tool-search 的
                                     ; search_tools）会「找不到工具」
(invoke-chat-stream kernel prompt on-token)
                                     ; :chat 链 → chat-model-stream，:token-xform
                                     ; 管道在 terminal 内侧组装 → chat-response
                                     ; 单次调用，**不跑工具循环**
(invoke-tool kernel tool-request)    ; :tool 链 → 工具执行 → kernel:tool-result
(invoke-tool-batch kernel tool-calls options context)
                                     ; → (values tool-results return-direct-p)
                                     ; 默认并行（lparallel）；批内任一工具声明
                                     ; :serial → 整批顺序；异常按三类分类路由
(invoke-turn kernel turn-request)    ; :turn 链 → run-tool-loop → turn-result
(run-tool-loop kernel turn-request)  ; 工具循环本体（:turn 链的 terminal，不是 filter）
(resume-turn kernel loop-state decision &key payload)
                                     ; 从暂停点续跑（见「HITL：暂停与续跑」）
```

`run-tool-loop` 每轮：构建 prompt（messages + kernel tools，与调用方 options
合并）→ `invoke-chat` → 若响应带 tool-calls 且通过 `eligibility-fn` → 执行工具
→ 把 assistant(tool-calls) 与 tool 结果消息追加进 messages → 下一轮；否则返回
`turn-result(:completed)`。

- 循环上限取自 settings `:max-tool-iterations`（缺省 10），超限发
  `cl-agent/core:max-tool-iterations-exceeded-error`
- `:return-direct` 工具：整批都声明时短路，工具结果直接成为最终答案，不回传模型
- `kernel-tool-manager` 非 nil 时经 `execute-tool-calls` 协议执行，否则走
  `invoke-tool-batch`
- 模型报出不存在的工具名时不中断循环：`batch.lisp` 把 `tool-not-found-error`
  转成 `:semantic` 错误结果，`tool-result->text` 渲染为「错误：找不到工具 xxx」
  回传模型自纠
- `kernel-tool-gate` 非 nil 时，每批工具执行**前**过一遍 gate；判 `:pause`
  则返回 `turn-result(:paused)`，工具一个都不执行（见
  [HITL：暂停与续跑](#hitl暂停与续跑kernel-原语)）

### ToolCallingManager（实现）

对标 Spring `ToolCallingManager`——把「执行入口」升格为可注入协议。循环控制、
eligibility、`:tool` filter 链都仍在 kernel 侧，manager 只决定调度策略。
这是本项目**唯一**的 ToolCallingManager（chat 层那套旧的已删除）。

```lisp
(cl-agent/core:execute-tool-calls manager kernel response options)
;; options plist：(:tool-context ctx ...)
;; → tool-execution-result plist：(:messages ... :records ... :context ... :errors ...)
(make-tool-execution-result &key messages records context errors)

(make-sequential-tool-calling-manager)        ; 全串行（调试/严格副作用）
(make-virtual-thread-tool-calling-manager)    ; 并行默认，尊重 :serial
(make-thread-pool-tool-calling-manager &optional (pool-size 4))  ; 线程池（限流）
(default-tool-calling-manager)                ; = virtual-thread
```

> 签名只有这一个：`(manager kernel response options)`。合并前的
> `cl-agent/chat` 还有一套 `(manager prompt response)` 的同名泛型函数，
> 逼得 kernel `shadow` 这个符号；那套已整体删除，`execute-tool-calls`
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
;; turn-result(:cancelled)。短路在 :turn 层，:chat 的 memory 不执行——
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

(build-kernel :model m
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
与人工审批。它是 kernel 的薄封装——`agent-chat` 最终落到 `kernel-chat`。

agent **不自己存历史**：历史仍由 core 的 `memory-filter` 按 conversation-id
管，agent 只持 conversation-id + 轻量控制状态。

### make-agent

```lisp
(make-agent &key model system options tools memory conversation-id
                 callbacks kernel settings)
;; model           chat-model 实例（不给 :kernel 时必填）
;; system          默认系统提示
;; options         默认 chat-options
;; tools           工具符号列表
;; memory          chat-memory store；缺省 = 新建滑动窗口记忆；
;;                 nil = 无记忆（每轮独立）
;; conversation-id 会话 ID（缺省自动生成）
;; callbacks       回调 plist（见下）
;; settings        kernel settings alist，如 '((:max-tool-iterations . 10))
;; kernel          预构建 kernel（要挂 filter 时用这个）

(agent-id a) (agent-kernel a) (agent-memory a) (agent-conversation-id a)
(agent-callbacks a) (agent-turn-count a)
```

> **本层不接受 `:filters`**——传了会**直接报错**并给出迁移指引（而不是静默
> 忽略）。agent 只暴露 `:callbacks`；要挂 filter 请自建 kernel 后经 `:kernel`
> 传入。这条边界是刻意的：简单层一旦开始转发 filter，就会慢慢长成第二个
> kernel——本仓库刚删掉的 ChatClient 正是这么烂掉的。
>
> 给 `:kernel` 时，`memory-filter` 由**调用方自己**负责挂载
> （`make-agent` 不改动预构建 kernel 的 filters）；`:memory` 只是告诉 agent
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
`:on-tool-call` 桥接为 kernel 的 `tool-gate`（要能在执行**前**否决）。

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

### 包合并（`cl-agent/http` / `/chat` / `/kernel` → `cl-agent/core`）

三个包已合并为一个 `cl-agent/core`。机械改名，逐一对应：

| 旧 | 新 |
|---|---|
| `cl-agent/kernel:X` | `cl-agent/core:X` |
| `cl-agent/chat:X` | `cl-agent/core:X` |
| `cl-agent/http:X` | `cl-agent/core:X` |
| 昵称 `cla/kernel` / `cla/chat` / `cla/http` | `cla/core` |
| `cl-agent/kernel:build-kernel` | `cl-agent/core:build-kernel` |
| `cl-agent/chat:deftool` | `cl-agent/core:deftool` |
| `cl-agent/http:http-request` | `cl-agent/core:http-request` |
| `:shadowing-import-from` 相关写法 | **不再需要**，整体删掉 |

照旧包名写的代码会直接撞上
`Package CL-AGENT/KERNEL does not exist`。

### 从 ChatClient 迁移

**ChatClient 移植层已整体删除**——它是 Spring AI 的 ChatClient + Builder +
fluent RequestSpec 移植。Builder 与链式 spec 是 Java 的表达习惯：在 Lisp 里
`build-kernel` 的关键字参数 + 声明式 `chat` 宏覆盖同样的地面，且少一层。

> **注意：`cl-agent/client` 这个包名被复用了。** 它曾是 ChatClient 移植层
> （已删），**现在是 SimpleAgent**（见
> [cl-agent/client](#cl-agentclient--simpleagent有状态对话--hitl)）。
> 也就是说包还在、名字还在，但里面是完全不同的东西——旧的 ChatClient
> 符号一个都不剩。

以下符号**不再存在**：`make-kernel-client`、
`make-chat-client`、`chat-client`、`chat-client-builder`、`default-system`、
`default-options`、`default-tools`、`build-client`、`client-prompt`、
`prompt-system`、`prompt-user`、`prompt-add-messages`、`prompt-with-options`、
`prompt-tools`、`prompt-context`、`prompt-conversation`、`call-client-response`、
`call-response`、`call-content`、`call-entity`、`stream-content`、
`client-request`、`client-response`、`make-client-request`、
`make-client-response`、`context-get`、`context-set`、`client-kernel`、
`client-default-system`、`client-default-options`、`client-default-tools`。

`chat` 宏**幸存**，语法原样可用——只是符号现在来自 `cl-agent/core`。

要「有状态对话 + 一个对象管住会话」的那种手感（ChatClient 常见用法），
现在用 [SimpleAgent](#cl-agentclient--simpleagent有状态对话--hitl)：
`(make-agent :model m :system "..." :tools '(...))` + `(agent-chat a "...")`。

| 旧（ChatClient） | 新（Kernel） |
|---|---|
| `(make-kernel-client model :filters ... :tools ...)` | `(build-kernel :model model :filters ... :tools ...)`（`:model` 是**关键字**参数，不是位置参数） |
| `(make-chat-client model)` | `(build-kernel :model model)` |
| `(chat client ...)` | `(chat kernel ...)`——子句不变 |
| fluent spec（`client-prompt` → `prompt-user` → `call-content`） | `chat` 宏子句，或 `kernel-chat-text` 等函数形态 |
| `(call-content spec)` | `(:call :content)` / `kernel-chat-text` |
| `(call-response spec)` | `(:call :response)` |
| `(call-client-response spec)` | `(:call :result)` → `turn-result`（`client-response` 载体已不存在） |
| `(call-entity spec :schema s)` | `(:call :entity)` / `kernel-chat-entity`——**无 schema 参数**，校验挂 `validation-turn-filter` |
| `(stream-content spec fn)` | `(:stream fn)` / `kernel-chat-stream` |
| `(prompt-context spec k v)` | `(:context k v)` |
| `(prompt-conversation spec id)` | `(:conversation id)` |
| `default-tools` (Builder) | `build-kernel :tools`（请求级 `(:tools ...)` 与之取并集） |
| `default-options` (Builder) | `build-kernel :options`（请求级 `(:options ...)` 合并覆盖） |
| `default-system` (Builder) | `build-kernel :system`（请求级 `(:system ...)` 覆盖） |
| `client-request` / `client-response` / `context-get` / `context-set` | `turn-request` / `turn-result` + `turn-request-context`（plist） |

### 从 Advisor 迁移

Advisor 体系已整体删除。以下符号**不再存在**：`defadvisor`、`advise-call`、
`advise-stream`、`advisor-chain`、`make-advisor-chain`、`chain-next`、
`chain-next-stream`、`memory-advisor-p`、`simple-logger-advisor`、
`message-chat-memory-advisor`、`safe-guard-advisor`、`tool-calling-advisor`、
`tool-search-tool-calling-advisor`、`structured-output-validation-advisor`
及其 `make-*` 构造函数、`+conversation-id-key+`、全部 `+*-advisor-order+` 常量、
`default-advisors`、`prompt-advisors`、`client-default-advisors`。
`(chat kernel (:advisors ...))` 直接报错并给出迁移指引。

| 旧（Advisor） | 新（Filter） |
|---|---|
| `:advisors (list ...)` | `build-kernel :filters (list ...)` |
| `(defadvisor ... (:call (a req chain) ...))` | `(defilter ... (:turn (self req chain) ...))` |
| `(chain-next chain req)` | `(funcall chain req)` |
| `advisor-order`（越小越靠外） | filters 列表位置（越靠前越靠外） |
| `make-simple-logger-advisor` | `logging-chat-filter` / `logging-tool-filter` |
| `make-safe-guard-advisor` | `safeguard-turn-filter` |
| `make-message-chat-memory-advisor` | `memory-filter`（`:chat` 链，循环内每轮生效） |
| `make-tool-calling-advisor` | `run-tool-loop`（`:turn` 链 terminal，无需注册） |
| `make-structured-output-validation-advisor` | `validation-turn-filter` + `structured-output-validate-fn` |
| `make-tool-search-tool-calling-advisor` | `tool-search-filter` |
| `+tool-calling-advisor-order+` 内外之分 | `:chat` 链天然在循环内、`:turn` 链天然在循环外 |

### 从 kernel:tool-response 迁移（载体改名）

kernel 工具链的响应载体改名为 `tool-result`，与 turn 链的 `turn-request` /
`turn-result` 对称，并借此消除与协议消息层 `tool-response` 的撞名
（撞名消失后三个包才得以合并）。

| 旧（已不存在） | 新 |
|---|---|
| `cl-agent/kernel:tool-response`（类） | `cl-agent/core:tool-result` |
| `cl-agent/kernel:make-tool-response` | `cl-agent/core:make-tool-result` |
| `(make-tool-response :result X)` | `(make-tool-result :value X)`——**初始参数由 `:result` 改为 `:value`** |
| `tool-response-result` | `tool-result-value` |
| `tool-response-writes` | `tool-result-writes` |
| `tool-response-error` | `tool-result-error` |

`tool-request` / `make-tool-request` / `tool-request-function` /
`tool-request-args` / `tool-request-context` **不变**（前缀改为
`cl-agent/core:`）。新增导出 `cl-agent/core:tool-result->text`。

> **别混淆**：`cl-agent/core:tool-response` / `make-tool-response` /
> `tool-response-message` / `tool-response-text` **依然存在**——那是**协议消息层**
> 的值对象（id/name/text），放进 role=:tool 的消息发回模型，与 kernel 执行链的
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

| 旧（chat 层 manager） | 新（kernel） |
|---|---|
| `(make-default-tool-calling-manager)` | `(make-sequential-tool-calling-manager)` |
| `(make-concurrent-tool-calling-manager :pool-size 4)` | `(make-thread-pool-tool-calling-manager 4)` |
| 并行默认 | `(make-virtual-thread-tool-calling-manager)` = `(default-tool-calling-manager)` |
| `(execute-tool-calls mgr prompt response)` | `(execute-tool-calls mgr kernel response options)` |
| 自己驱动循环：`chat-model-call` + `execute-tool-calls` | `(chat kernel ...)` / `kernel-chat`——kernel 是唯一路径 |
| `(shutdown-tool-calling-manager mgr)` / `with-concurrent-tool-calling-manager` | 无需——kernel manager 不持有需显式释放的线程池 |
| `tool-execution-conversation-history` / `-last-message` / `-return-direct-p` | `turn-result-response` / `turn-result-tool-context`；manager 层用 `make-tool-execution-result` 的 `:messages` |
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
