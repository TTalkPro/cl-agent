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
                   :extra-params '(:seed 42)            ; 厂商专有参数逃生通道
                   :tool-callbacks (list cb) :tool-names '("get_weather")
                   :tool-context '(:tenant "acme")
                   :internal-tool-execution-enabled t   ; 默认 T
                   :max-tool-iterations 10)             ; 默认 10
(merge-chat-options runtime defaults)  ; 运行时覆盖默认；工具取并集
(copy-chat-options options)
;; 读取器：chat-options-model / -temperature / -max-tokens / ...
```

未显式传入的选项处于"未设置"状态，合并时回退默认值。

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

- 同时生成普通函数、tool-callback、全局注册与符号属性绑定
- 类型关键字：`:string :number :integer :boolean :array :object`

```lisp
(make-tool-callback fn :name "n" :description "d"
                    :parameters '((p :string "desc" :required-p t))
                    :return-direct nil)
(tool-callback-call callback args-plist &optional tool-context)
(tool-callback->schema callback)          ; provider 工具 schema
(find-tool-callback "get_weather")        ; 全局注册表查找
(register-tool-callback cb) (unregister-tool-callback name)
(resolve-tool-callbacks specs)            ; 实例/符号/字符串 → callback
(arguments->plist raw)                    ; hash-table/JSON/plist 归一化
(make-default-tool-calling-manager)
(execute-tool-calls manager prompt response)
;; => (values tool-response-message return-direct-p)
```

条件：`tool-execution-error`、`tool-not-found-error`。

### ChatModel 协议（`ChatModel` / `StreamingChatModel`）

```lisp
(chat-model-call model prompt)             ; prompt 可为字符串/消息列表
(chat-model-stream model prompt on-chunk)  ; on-chunk: (delta-text)
(chat-model-default-options model)

(make-provider-chat-model provider
  :default-options options
  :tool-calling-manager manager)
```

`provider-chat-model` 的内部工具执行循环：响应携带 tool-calls 且
`internal-tool-execution-enabled` 为真时自动执行工具并回传模型，
直到产生文本回复；超过 `max-tool-iterations` 发
`max-tool-iterations-exceeded-error`；`:return-direct` 工具立即终止循环。

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
(make-simple-logger-advisor :stream s)                    ; order -1000
(make-safe-guard-advisor :sensitive-words '("...")
                         :failure-response "...")         ; order -500
(make-message-chat-memory-advisor :memory m)              ; order 1000
(make-prompt-chat-memory-advisor :memory m :template "~A"); order 1000
+conversation-id-key+   ; 请求 context 中的会话 ID 键
```

### ChatClient（`ChatClient` / `Builder` / `RequestSpec`）

```lisp
;; 构建
(make-chat-client model :system s :options o :advisors a :tools ts)
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
