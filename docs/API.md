# CL-Agent API Reference

[中文](API_CN.md)

API quick reference by package. Spring AI 2.0 counterparts noted per section.

## cl-agent.chat — Chat Model API

### Messages (`org.springframework.ai.chat.messages`)

| Symbol | Description |
|---|---|
| `message` | Abstract base; `message-role` / `message-text` / `message-metadata` |
| `(system-message text)` | System instruction |
| `(user-message text)` | User input |
| `(assistant-message text &key tool-calls)` | Model reply; `assistant-tool-calls` |
| `(tool-response-message responses)` | Tool results; `tool-responses` |
| `(make-tool-call &key id name arguments)` | Tool call value object |
| `(make-tool-response &key id name text)` | Tool result value object |
| `message->neutral` / `messages->neutral` | CLOS → neutral plists (provider SPI boundary) |
| `neutral->message` / `neutral->messages` | Reverse conversion |

### Prompt / ChatOptions

```lisp
(make-prompt messages &key options system)
(prompt-copy prompt &key messages options)     ; immutable augmentation
(prompt-append-messages prompt new-messages)
(prompt-system-messages p) (prompt-instruction-messages p)
(prompt-last-user-text p)

(make-chat-options :model "..." :temperature 0.3 :max-tokens 1024
                   :tool-callbacks (list cb) :tool-names '("get_weather")
                   :tool-context '(:tenant "acme")
                   :internal-tool-execution-enabled t   ; default T
                   :max-tool-iterations 10)             ; default 10
(merge-chat-options runtime defaults)   ; runtime wins; tools are unioned
```

Options not explicitly passed are "unset" and fall back on merge.

### ChatResponse

```lisp
(chat-response-text r) (chat-response-message r)
(chat-response-tool-calls r) (chat-response-has-tool-calls-p r)
(chat-response-finish-reason r)   ; :stop/:tool-call/:max-tokens/...
(chat-response-usage r) (chat-response-metadata-of r)
(llm-response->chat-response llm-response)
```

### Tools (`@Tool` / `ToolCallback` / `ToolCallingManager`)

```lisp
(deftool name (&key args...)
  "description for the model"
  (:param name type "description" [:required t] [:default v])*
  [(:return-direct t)]
  body...)

(make-tool-callback fn :name "n" :description "d"
                    :parameters '((p :string "desc" :required-p t)))
(tool-callback-call callback args-plist &optional tool-context)
(tool-callback->schema callback)
(find-tool-callback "get_weather") (register-tool-callback cb)
(resolve-tool-callbacks specs)     ; instances/symbols/strings
(arguments->plist raw)             ; hash-table/JSON/plist normalization
(make-default-tool-calling-manager)
(execute-tool-calls manager prompt response)
;; => (values tool-response-message return-direct-p)
```

Conditions: `tool-execution-error`, `tool-not-found-error`.

### ChatModel protocol

```lisp
(chat-model-call model prompt)              ; prompt: string/messages/prompt
(chat-model-stream model prompt on-chunk)
(chat-model-default-options model)
(make-provider-chat-model provider
  :default-options options :tool-calling-manager manager)
```

`provider-chat-model` runs the internal tool-execution loop when a response
carries tool calls and `internal-tool-execution-enabled` is true; exceeding
`max-tool-iterations` signals `max-tool-iterations-exceeded-error`;
`:return-direct` tools terminate the loop immediately.

### ChatMemory

```lisp
(memory-add memory conversation-id messages)
(memory-messages memory conversation-id)
(memory-clear memory conversation-id)
(make-message-window-chat-memory :repository repo :max-messages 20)

;; Storage protocol (implement for custom backends)
(repository-find repo cid) (repository-save repo cid messages)
(repository-delete repo cid) (repository-conversation-ids repo)
(make-in-memory-chat-memory-repository)
+default-conversation-id+   ; "default"
```

Window truncation is pairing-safe: system messages are kept and don't count;
orphaned leading tool messages are dropped.

## cl-agent.client — ChatClient + Advisor

### Advisor protocol

```lisp
(make-client-request prompt &key context)    ; ChatClientRequest
(client-request-copy r &key prompt)          ; context is shared
(make-client-response chat-response &key context)
(context-get holder key &optional default) (context-set holder key value)

(advise-call advisor request chain)             ; → client-response
(advise-stream advisor request chain on-chunk)  ; defaults to advise-call
(advisor-order advisor)                         ; lower = outer

(make-advisor-chain advisors call-terminal :stream-terminal st)
(chain-next chain request)
(chain-next-stream chain request on-chunk)
```

### defadvisor

```lisp
(defadvisor name (:order N :documentation "...")
  [(:slots (slot-defs...))]
  (:call (advisor request chain) body...)
  [(:stream (advisor request chain on-chunk) body...)])
;; expands to: defclass + methods + make-name constructor
```

### Built-in advisors

```lisp
(make-simple-logger-advisor :stream s)                     ; order -1000
(make-safe-guard-advisor :sensitive-words '("...")
                         :failure-response "...")          ; order -500
(make-message-chat-memory-advisor :memory m)               ; order 1000
(make-prompt-chat-memory-advisor :memory m :template "~A") ; order 1000
+conversation-id-key+
```

### ChatClient

```lisp
(make-chat-client model :system s :options o :advisors a :tools ts)
(chat-client-builder model)
(default-system builder text) (default-options builder options)
(default-advisors builder &rest advisors) (default-tools builder &rest tools)
(build-client builder)

;; fluent request spec
(client-prompt client &optional user-text)
(prompt-system spec text &rest format-args)
(prompt-user spec text &rest format-args)
(prompt-add-messages spec &rest messages)
(prompt-with-options spec &rest options-or-kv)
(prompt-advisors spec &rest advisors) (prompt-tools spec &rest tools)
(prompt-context spec key value) (prompt-conversation spec cid)

;; terminal operations
(call-content spec) (call-response spec) (call-client-response spec)
(call-entity spec) (stream-content spec on-chunk)
```

### chat macro

```lisp
(chat client
  [(:system text [format-args...])]
  [(:user text [format-args...])]
  [(:messages msg...)] [(:options :temperature 0.7 ...)]
  [(:advisors adv...)] [(:tools tool...)]
  [(:context key value)] [(:conversation cid)]
  [(:call :content | :response | :client-response | :entity)]  ; default :content
  [(:stream callback)])

(chat client "Hi")   ; shorthand for (:user "Hi")
```

## cl-agent.llm — Providers

```lisp
(create-chat-model :anthropic :model "..." :api-key "..." :options opts)
;; providers: :anthropic :openai :zhipu :deepseek :gemini :mistral
;;            :ollama :dashscope :minimax (aliases google/qwen/bailian/claude/glm...)
```

DeepSeek prefix completion (beta):

```lisp
;; The last assistant message is the prefix; the model continues from it
(cl-agent.llm.providers:deepseek-prefix-chat provider
  (list (list :role :user :content "Write a line of poetry")
        (list :role :assistant :content "The spring wind"))
  :max-tokens 256)
```

Provider SPI for custom providers:

```lisp
(defmethod cl-agent.core:llm-chat ((p my-provider) messages
                                   &key max-tokens temperature model tools system)
  ;; messages are neutral plists (:role :user :content "...")
  ;; return a cl-agent.core:llm-response
  ...)
```

## cl-agent.mock — Test Support

```lisp
(cl-agent.mock:make-mock-llm)   ; rule-based responses, no API key
;; wrap with (make-provider-chat-model (make-mock-llm)) for full-stack demos
```
