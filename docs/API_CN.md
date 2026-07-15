# CL-Agent API 参考

[English](API.md)

按包组织的 API 速查。与 Spring AI 2.0 的对应关系标注在各节标题中。

## cl-agent.chat —— Chat Model API

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

### Prompt / ChatOptions（`chat.prompt`）

```lisp
(make-prompt messages &key options system)   ; messages 可为字符串/消息/列表
(prompt-messages prompt) (prompt-options prompt)
(prompt-copy prompt &key messages options)   ; 不可变增强（Advisor 用）
(prompt-append-messages prompt new-messages)
(prompt-system-messages prompt) (prompt-instruction-messages prompt)
(prompt-last-user-text prompt)
```

```lisp
(make-chat-options :model "..." :temperature 0.3 :max-tokens 1024
                   :top-p 0.9 :top-k 40 :stop-sequences '("END")
                   :frequency-penalty 0.0 :presence-penalty 0.0
                   :thinking '(:enabled :budget-tokens 2048)  ; 扩展思考
                   :extra-params '(:seed 42)            ; 厂商专有参数逃生通道
                   :tool-callbacks (list cb) :tool-names '(get-weather)
                   :tool-context '(:tenant "acme"))
;; 工具循环选项已上移至 tool-calling-advisor（2.0 架构）
(merge-chat-options runtime defaults)  ; 运行时覆盖默认；工具取并集
(copy-chat-options options)
;; 读取器：chat-options-model / -temperature / -max-tokens / -thinking / ...
```

未显式传入的选项处于"未设置"状态，合并时回退默认值。

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

### 工具体系（`@Tool` / `ToolCallback` / `ToolCallingManager`）

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
(symbol-tool-callback 'get-weather)       ; 取 deftool 挂在符号上的 callback
(resolve-tool-callbacks specs)            ; 实例/符号/字符串 → callback
(arguments->plist raw)                    ; hash-table/JSON/plist 归一化

;; 全局注册表：opt-in 逃生通道，仅用于按*字符串*名解析（配置驱动场景）。
;; deftool 不写它；默认为空。
(register-tool-callback (symbol-tool-callback 'get-weather))
(find-tool-callback "get_weather")        ; 只查全局表，非 deftool 的默认路径
(unregister-tool-callback "get_weather")
(make-default-tool-calling-manager)          ; 顺序执行
;; 并行执行（对标 Spring AI 2.0 并行 DefaultToolCallingManager）：
(make-concurrent-tool-calling-manager :pool-size 4 :timeout nil
                                      :inherit-specials :default)
(shutdown-tool-calling-manager manager)      ; 释放线程池（懒创建）
;; 与顺序语义等价（结果按原序、return-direct 取并集、错误隔离），
;; 仅多工具时并发。工具参数走 tool-context；日志级别、request-id 这类
;; 环境上下文需列入继承名单才可见——未列入的特殊变量可见性不确定：
;; lparallel 可能让任务在 worker 上跑（看到全局值），也可能被提交线程
;; 窃取就地执行（看到调用方绑定）。列入名单即可消除不确定性：
(execute-tool-calls manager prompt response)
;; 提交时快照，在任务实际执行处经 progv 重建：
(with-inherited-specials (*request-id*)
  (let ((*request-id* "req-42")) (chat client ...)))  ; 工具体内保证可见
*inherited-special-variables*                ; 名单；:inherit-specials 优先
;; 机制定义在 cl-agent.core，与 cl-agent.http 的异步请求共用同一份名单：
;; (with-inherited-specials (*request-id*)
;;   (let ((*request-id* "req-42")) (setf f (http-get-async url))))  ; let 退出
;; (http-future-value f)                     ; 请求体仍看到 "req-42"
;; 生命周期用宏管理，避免全局变量持有线程池：
(with-concurrent-tool-calling-manager (mgr :pool-size 8)
  ...)                                        ; 退出时自动 shutdown
;; 覆盖自动注册 advisor 的默认 manager（无需改调用点）：
;; (let ((cl-agent.client:*tool-calling-manager* mgr)) (chat client ...))
;; => tool-execution-result（对标 ToolExecutionResult）
(tool-execution-conversation-history result) ; 完整会话历史
(tool-execution-return-direct-p result)
(tool-execution-last-message result)         ; 本轮 tool-response-message
;; 定制错误处理（对标 ToolExecutionExceptionProcessor）：
;; 特化 (process-tool-execution-error manager condition tool-call)
```

条件：`tool-execution-error`、`tool-not-found-error`。

### ChatModel 协议（`ChatModel` / `StreamingChatModel`）

```lisp
(chat-model-call model prompt)             ; prompt 可为字符串/消息列表
(chat-model-stream model prompt on-chunk)  ; on-chunk: (delta-text)
(chat-model-default-options model)

(make-provider-chat-model provider :default-options options)
```

2.0 架构：ChatModel 只做**单次**模型调用——解析工具引用并注入
schema，但不执行工具。携带 tool-calls 的响应原样返回，工具循环由
`cl-agent.client:tool-calling-advisor` 承担（ChatClient 自动注册）。

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

## cl-agent.client —— ChatClient + Advisor

### Advisor 协议（`CallAdvisor` / `AdvisorChain`）

```lisp
;; 载体
(make-client-request prompt &key context)   ; ChatClientRequest
(client-request-prompt r) (client-request-context r)
(client-request-copy r &key prompt)         ; context 共享
(make-client-response chat-response &key context)
(client-response-chat-response r) (client-response-context r)
(context-get holder key &optional default)  ; request/response 通用
(context-set holder key value)

;; 协议
(advise-call advisor request chain)          ; → client-response
(advise-stream advisor request chain on-chunk) ; 默认委托 advise-call
(advisor-name advisor) (advisor-order advisor) ; order 越小越靠外

;; 链
(make-advisor-chain advisors call-terminal :stream-terminal st)
(chain-next chain request)
(chain-next-stream chain request on-chunk)
```

### defadvisor 宏

```lisp
(defadvisor 名称 (:order N :documentation "...")
  [(:slots (槽定义...))]
  (:call (advisor request chain) 方法体...)
  [(:stream (advisor request chain on-chunk) 方法体...)])
;; 生成：defclass + advise-call [+ advise-stream] + make-名称 构造函数
```

### 内置 Advisor

```lisp
(make-simple-logger-advisor :stream s
                            :request-to-string #'my-fmt
                            :response-to-string #'my-fmt) ; order -1000
(make-safe-guard-advisor :sensitive-words '("...")
                         :failure-response "..."
                         :order -500)                     ; order -500
(make-message-chat-memory-advisor :memory m)              ; order 1000
+conversation-id-key+   ; 请求 context 中的会话 ID 键

;; 排序常量（对标 Spring 的 Ordered 语义，order 越小越靠外）
+simple-logger-advisor-order+                 ; -1000
+safe-guard-advisor-order+                    ;  -500
+chat-memory-advisor-order+                   ;  1000
+tool-calling-advisor-order+                  ;  2000
+structured-output-validation-advisor-order+  ;  3000
+advisor-highest-precedence+ / +advisor-lowest-precedence+

;; ToolCallingAdvisor（对标 Spring AI 2.0，ChatClient 自动注册）
(make-tool-calling-advisor :manager m :max-iterations 10
                           :eligibility #'default-tool-execution-eligible-p
                           :conversation-history-enabled t) ; order 2000
;; 递归重入下游链直到无 tool-calls；:return-direct 短路；
;; 记忆 Advisor（1000）默认在循环外，只记录最终问答；
;; order > 2000 的 Advisor 每轮工具循环都执行
;;
;; :conversation-history-enabled NIL —— 下一轮只带 system + 最后一条消息，
;;   完整历史交给记忆 Advisor 重建。记忆 Advisor 必须位于工具循环*内侧*
;;   （order > +tool-calling-advisor-order+）才会每轮迭代执行；放在默认
;;   order（循环外）每次请求只跑一次，补不上中间轮次，下一轮 prompt 会
;;   退化成 [system, 工具结果]，Anthropic 类提供商直接返回 HTTP 400：
;;     (make-chat-client model
;;       :advisors (list (make-message-chat-memory-advisor
;;                        :memory mem
;;                        :order (1+ +tool-calling-advisor-order+))
;;                       (make-tool-calling-advisor
;;                        :conversation-history-enabled nil)))
;;   自定义记忆 Advisor 请特化 memory-advisor-p 返回 T
;;   （对标 MemoryAdvisor 标记接口），否则会收到配置告警。
;; :eligibility —— (chat-response) → boolean，替换它可实现提供商特定的
;;   stop-reason 判定（对标 ToolExecutionEligibilityChecker）

;; 循环钩子（子类特化即可，对标 doInitializeLoop 等）
(tool-advisor-initialize-loop advisor request)
(tool-advisor-before-call advisor request iteration)
(tool-advisor-after-call advisor request response iteration)
(tool-advisor-finalize-loop advisor request response)
(tool-advisor-next-instructions advisor request response result) ; 决定下一轮消息

;; StructuredOutputValidationAdvisor（对标 Spring AI 2.0）
(make-structured-output-validation-advisor
  :json-schema "{\"type\":\"object\",\"required\":[\"city\"]}" ; 字符串/hash-table/plist
  :max-repeat-attempts 3)                                      ; order 3000
;; 校验响应 JSON；失败则把校验错误追加到 user 消息末尾让模型重新输出。
;; 位于工具循环内侧：带 tool-calls 的响应直接放行，只校验最终输出。
;; 重试用尽返回最后一次响应（不发条件）。流式不支持，会发
;; structured-output-streaming-unsupported-error。

;; 细粒度钩子（对标 doInitializeLoop/doBeforeCall/doAfterCall/doFinalizeLoop）
;; 子类特化即可在循环关键节点观察/改写，无需重写 advise-call：
(tool-advisor-initialize-loop advisor request)          ; 循环前，→ request
(tool-advisor-before-call advisor request iteration)    ; 每轮调用前，→ request
(tool-advisor-after-call advisor request response iteration) ; 每轮调用后，→ response
(tool-advisor-finalize-loop advisor request response)   ; 循环后，→ response

;; ToolSearch：渐进式工具披露（对标 ToolSearchToolCallingAdvisor）
;; 全量工具不直接发给模型；每轮只注入内置 tool_search + 已检索命中的工具
(make-chat-client model
  :advisors (list (make-tool-search-tool-calling-advisor
                   :match-mode :substring    ; 或 :regex
                   :max-results 5)))
```

### ChatClient（`ChatClient` / `Builder` / `RequestSpec`）

```lisp
;; 构建
(make-chat-client model :system s :options o :advisors a :tools ts
                        :auto-tool-advisor t) ; NIL = user-controlled 模式
(chat-client-builder model)          ; → builder
(default-system builder text)        ; 以下均返回 builder
(default-options builder options)
(default-advisors builder &rest advisors)
(default-tools builder &rest tools)
(build-client builder)               ; → chat-client

;; fluent 请求（每步返回 spec，配合 -> 线程宏）
(client-prompt client &optional user-text)
(prompt-system spec text &rest format-args)
(prompt-user spec text &rest format-args)
(prompt-add-messages spec &rest messages)
(prompt-with-options spec &rest options-or-kv)
(prompt-advisors spec &rest advisors)
(prompt-tools spec &rest tools)
(prompt-context spec key value)
(prompt-conversation spec conversation-id)

;; 终结操作
(call-content spec)          ; → 文本
(call-response spec)         ; → chat-response
(call-client-response spec)  ; → client-response
(call-entity spec)           ; → JSON 解析结果（hash-table）
(stream-content spec on-chunk) ; → 最终 chat-response
```

### chat 宏

```lisp
(chat client
  [(:system 文本 [format 参数...])]
  [(:user 文本 [format 参数...])]
  [(:messages 消息...)]
  [(:options :temperature 0.7 ...)]
  [(:advisors advisor...)]
  [(:tools 工具...)]
  [(:context 键 值)]
  [(:conversation 会话ID)]
  [(:call :content | :response | :client-response | :entity)]  ; 默认 :content
  [(:stream 回调)])

(chat client "你好")   ; 简写 ≡ (chat client (:user "你好"))
```

## cl-agent.llm —— 提供商层

```lisp
(create-chat-model :anthropic :model "..." :api-key "..." :options opts)
(create-chat-model-from-builder builder :options opts)
;; 支持：:anthropic :openai :zhipu :deepseek :gemini :mistral
;;       :ollama :dashscope :minimax（别名 google/qwen/bailian/claude/glm...）
```

DeepSeek 前缀续写（beta）：

```lisp
;; 最后一条 assistant 消息作为前缀，模型从其继续生成（建议搭配 :stop）
(cl-agent.llm.providers:deepseek-prefix-chat provider
  (list (list :role :user :content "写一句诗")
        (list :role :assistant :content "春天的风"))
  :max-tokens 256)
```

Provider SPI（自定义提供商实现）：

```lisp
(defmethod cl-agent.core:llm-chat ((p my-provider) messages
                                   &key max-tokens temperature model tools system)
  ;; messages 为中立 plist：(:role :user :content "...")
  ;; 返回 cl-agent.core:llm-response 对象
  ...)
```

## cl-agent.mock —— 测试支持

```lisp
(cl-agent.mock:make-mock-llm)          ; 智能规则响应，无需 API 密钥
(cl-agent.mock:make-quick-mock :smart)
;; 配合 (make-provider-chat-model (make-mock-llm)) 即可全链路演示
```
