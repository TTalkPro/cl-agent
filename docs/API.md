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
                   :tool-context '(:tenant "acme"))
;; tool-loop options moved to tool-calling-advisor (2.0 architecture)
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
(make-default-tool-calling-manager)          ; sequential
;; parallel (mirrors Spring AI 2.0 concurrent DefaultToolCallingManager):
(make-concurrent-tool-calling-manager :pool-size 4 :timeout nil
                                      :inherit-specials :default)
(shutdown-tool-calling-manager manager)      ; release the (lazy) thread pool
;; semantics identical to sequential (original order, return-direct union,
;; error isolation); concurrent only for multi-tool rounds.
;; Tool arguments/state travel via tool-context. Ambient dynamic bindings
;; (log level, request id) are visible only if listed for inheritance —
;; unlisted specials have UNSPECIFIED visibility, since lparallel may run a
;; task either on a worker (global value) or steal it back onto the caller
;; (caller's binding). List them to make it deterministic:
(execute-tool-calls manager prompt response)
;; snapshot at submit, rebound (progv) wherever the task actually runs:
(with-inherited-specials (*request-id*)
  (let ((*request-id* "req-42")) (chat client ...)))  ; tools see "req-42"
*inherited-special-variables*                ; the list; :inherit-specials wins
;; Defined in cl-agent.core; the same list also covers cl-agent.http's async
;; requests, where the future outlives the caller's let:
;; (with-inherited-specials (*request-id*)
;;   (let ((*request-id* "req-42")) (setf f (http-get-async url))))  ; let exits
;; (http-future-value f)                     ; request body still sees "req-42"
;; manage lifetime with the macro instead of a global holding a pool:
(with-concurrent-tool-calling-manager (mgr :pool-size 8) ...) ; auto-shutdown
;; override the manager of auto-registered advisors (no call-site changes):
;; (let ((cl-agent.client:*tool-calling-manager* mgr)) (chat client ...))
;; => tool-execution-result (mirrors ToolExecutionResult)
(tool-execution-conversation-history result) ; full conversation history
(tool-execution-return-direct-p result)
(tool-execution-last-message result)
;; custom error handling (mirrors ToolExecutionExceptionProcessor):
;; specialize (process-tool-execution-error manager condition tool-call)
```

Conditions: `tool-execution-error`, `tool-not-found-error`.

### ChatModel protocol

```lisp
(chat-model-call model prompt)              ; prompt: string/messages/prompt
(chat-model-stream model prompt on-chunk)
(chat-model-default-options model)
(make-provider-chat-model provider :default-options options)
```

2.0 architecture: the ChatModel makes a **single** model call — it resolves
tool references and injects schemas but never executes tools. Responses
carrying tool calls are returned as-is; the loop belongs to
`cl-agent.client:tool-calling-advisor` (auto-registered by the ChatClient).

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
(make-simple-logger-advisor :stream s
                            :request-to-string #'my-fmt
                            :response-to-string #'my-fmt)  ; order -1000
(make-safe-guard-advisor :sensitive-words '("...")
                         :failure-response "..."
                         :order -500)                      ; order -500
(make-message-chat-memory-advisor :memory m)               ; order 1000
+conversation-id-key+

;; Order constants (mirrors Spring's Ordered semantics; lower = outer)
+simple-logger-advisor-order+                 ; -1000
+safe-guard-advisor-order+                    ;  -500
+chat-memory-advisor-order+                   ;  1000
+tool-calling-advisor-order+                  ;  2000
+structured-output-validation-advisor-order+  ;  3000
+advisor-highest-precedence+ / +advisor-lowest-precedence+

;; ToolCallingAdvisor (mirrors Spring AI 2.0, auto-registered by ChatClient)
(make-tool-calling-advisor :manager m :max-iterations 10
                           :eligibility #'default-tool-execution-eligible-p
                           :conversation-history-enabled t) ; order 2000
;; recursively re-enters the downstream chain until no tool calls remain;
;; memory advisors (1000) sit outside the loop by default;
;; advisors with order > 2000 run on every loop iteration
;;
;; :conversation-history-enabled nil -- next round carries only the system
;;   message plus the last message; a ChatMemory advisor then rebuilds the full
;;   history. That advisor MUST sit *inside* the tool loop
;;   (order > +tool-calling-advisor-order+) so it runs on every iteration. At
;;   its default order (outside the loop) it runs once per request, cannot fill
;;   in the intermediate rounds, and the next prompt degrades to
;;   [system, tool-result] -- which Anthropic-style providers reject with a
;;   bare HTTP 400:
;;     (make-chat-client model
;;       :advisors (list (make-message-chat-memory-advisor
;;                        :memory mem
;;                        :order (1+ +tool-calling-advisor-order+))
;;                       (make-tool-calling-advisor
;;                        :conversation-history-enabled nil)))
;;   Custom memory advisors should specialise memory-advisor-p to return t
;;   (mirrors the MemoryAdvisor marker interface) or they trigger a config warning.
;; :eligibility -- (chat-response) -> boolean; override for provider-specific
;;   stop-reason logic (mirrors ToolExecutionEligibilityChecker)

;; Loop hooks (specialise in a subclass; mirrors doInitializeLoop et al.)
(tool-advisor-initialize-loop advisor request)
(tool-advisor-before-call advisor request iteration)
(tool-advisor-after-call advisor request response iteration)
(tool-advisor-finalize-loop advisor request response)
(tool-advisor-next-instructions advisor request response result)

;; StructuredOutputValidationAdvisor (mirrors Spring AI 2.0)
(make-structured-output-validation-advisor
  :json-schema "{\"type\":\"object\",\"required\":[\"city\"]}" ; string/hash-table/plist
  :max-repeat-attempts 3)                                      ; order 3000
;; Validates the response JSON; on failure appends the validation error to the
;; user message and re-invokes the model. Sits inside the tool loop, so
;; tool-call responses pass straight through and only the final output is
;; validated. Returns the last response once retries are exhausted (no
;; condition signalled). Streaming is unsupported and signals
;; structured-output-streaming-unsupported-error.

;; fine-grained hooks (mirror doInitializeLoop/doBeforeCall/doAfterCall/doFinalizeLoop)
;; specialize on a subclass to observe/rewrite at loop checkpoints:
(tool-advisor-initialize-loop advisor request)          ; once, → request
(tool-advisor-before-call advisor request iteration)    ; per round, → request
(tool-advisor-after-call advisor request response iteration) ; per round, → response
(tool-advisor-finalize-loop advisor request response)   ; once, → response

;; ToolSearch: progressive tool disclosure (mirrors ToolSearchToolCallingAdvisor)
;; full tool set is never sent; each round exposes the built-in tool_search
;; plus previously discovered tools only
(make-chat-client model
  :advisors (list (make-tool-search-tool-calling-advisor
                   :match-mode :substring    ; or :regex
                   :max-results 5)))
```

### ChatClient

```lisp
(make-chat-client model :system s :options o :advisors a :tools ts
                        :auto-tool-advisor t) ; NIL = user-controlled mode
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
