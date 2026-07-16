# CL-Agent Quick Start

[中文](QUICKSTART_CN.md)

This guide walks you through CL-Agent (Spring AI 2.0-aligned architecture).

## 1. Setup

- SBCL (2.4+ recommended) and Quicklisp

```lisp
(dolist (dir '("." "core/" "llm/" "mock/"))
  (pushnew (truename dir) asdf:*central-registry* :test #'equal))
(asdf:load-system :cl-agent)
```

## 2. Create a ChatModel

```lisp
;; Anthropic (reads ANTHROPIC_API_KEY)
(defvar *model*
  (cl-agent.llm:create-chat-model :anthropic
    :model "claude-sonnet-4-20250514"))

;; Other providers: :openai :zhipu :ollama :dashscope :minimax ...
;; With model-level default options:
(cl-agent.llm:create-chat-model :openai :model "gpt-4o"
  :options (cl-agent.chat:make-chat-options :temperature 0.3))

;; No API key? Use the mock provider:
(asdf:load-system :cl-agent-mock)
(defvar *model*
  (cl-agent.chat:make-provider-chat-model (cl-agent.mock:make-mock-llm)))
```

## 3. First Chat

`build-kernel` assembles, the `chat` macro issues — two steps, no other layer.

```lisp
(defvar *kernel* (cl-agent.kernel:build-kernel :model *model*))

(cl-agent.kernel:chat *kernel* "Hello!")

(cl-agent.kernel:chat *kernel*
  (:system "You are a concise assistant")
  (:user "Describe Common Lisp in one sentence")
  (:options :temperature 0.2))
```

> `build-kernel`'s `:model` is a **keyword** argument, not positional.
> `(build-kernel :model *model*)` has no filters at all — model call + tool loop
> only. To mount cross-cutting concerns (memory / guardrails / logging …) see
> `:filters` in section 7.

When arguments are assembled programmatically, the function forms are handier
than the macro (which expands into exactly these):

```lisp
(cl-agent.kernel:kernel-chat-text *kernel*
  :system "You are a translator"
  :user (format nil "Translate: ~A" "hello world"))
```

`kernel-chat` returns a `turn-result`, `kernel-chat-text` the text,
`kernel-chat-entity` parsed JSON, and `kernel-chat-stream` streams.

### Packages and `:use` — both can be `:use`d together

`cl-agent.chat` and `cl-agent.kernel` **share no exported names**. `:use` both
directly; no shadowing of any kind is needed:

```lisp
(defpackage :my-app
  (:use :cl :cl-agent.chat :cl-agent.kernel))
```

That is exactly what `examples/kernel-usage.lisp` and `scripts/live-test.lisp`
do. Not `:use`-ing and fully qualifying every symbol works too — the rest of this
guide qualifies everything.

> It used to conflict: the two packages once shared `tool-response` /
> `make-tool-response` and `execute-tool-calls`, so the kernel had to `:shadow`
> and you had to write `:shadowing-import-from` yourself. The kernel carrier is
> now `tool-request` / `tool-result` and chat's old ToolCallingManager is gone,
> so the kernel has no `:shadow` at all.

## 4. Assembling a kernel: where defaults live

**There is no Builder.** Assembling a kernel *is* `build-kernel`'s keyword
arguments; a request's overrides are the `chat` macro's clauses:

```lisp
(defvar *kernel*
  (cl-agent.kernel:build-kernel
    :model *model*                       ; the ChatModel
    :system "You are a weather assistant" ; default system (request-level (:system ...) overrides)
    :options (cl-agent.chat:make-chat-options :temperature 0.3)  ; default options
    :tools '(get-weather)                ; default tools (request-level (:tools ...) unions with these)
    :filters (list ...)                  ; cross-cutting concerns (section 7)
    :settings '((:max-tool-iterations . 10))))
```

There is no Builder — assembling a kernel *is* `build-kernel`'s keyword
arguments. The old Builder's three defaults map straight across:

| Old Builder | Where it goes now |
|---|---|
| `default-tools` | `build-kernel :tools` |
| `default-options` | `build-kernel :options` (request-level `(:options ...)` merges over it) |
| `default-system` | `build-kernel :system` (request-level `(:system ...)` overrides it) |

## 5. Tool Calling (deftool)

`deftool` mirrors Spring AI's `@Tool` annotation: it defines an ordinary
function while deriving the JSON Schema and registering a ToolCallback.

```lisp
(cl-agent.chat:deftool get-weather (&key city (unit "celsius"))
  "Get the current weather for a city"
  (:param city :string "City name" :required t)
  (:param unit :string "Temperature unit")
  (format nil "Weather in ~A: 22°C (~A), sunny" city unit))

;; Still callable as a plain function
(get-weather :city "Tokyo")

;; In a conversation: when the model requests a tool, the kernel's
;; run-tool-loop executes it and feeds the result back to the model
(cl-agent.kernel:chat *kernel*
  (:user "What's the weather in Tokyo?")
  (:tools 'get-weather))
```

Notes:

- The lambda-list must be `&key`-style (LLM tool arguments are named)
- Tool names become lowercase snake_case: `get-weather` → `"get_weather"`
- A tool's identity is its symbol; reference it as `(:tools 'get-weather)`, or
  declare `:tools '(get-weather)` on the kernel as a kernel-level default —
  request-level and kernel-level tools are **unioned**
- `(:return-direct t)` returns the tool result directly to the caller
- `(:serial t)` marks the tool as side-effecting: if any tool in a batch
  declares `:serial`, the whole batch degrades to sequential execution
  (the default is parallel)
- Declare a `tool-context` parameter to receive host-injected context:
  `(make-chat-options :tool-context '(:tenant "acme"))`

The tool loop lives in `cl-agent.kernel:run-tool-loop` — the terminal of the
`:turn` chain. It is not a filter, and it is not inside ChatModel
(`chat-model-call` is single-call semantics). The iteration cap comes from
kernel settings (default 10):

```lisp
(cl-agent.kernel:build-kernel
  :model *model*
  :tools '(get-weather)
  :settings '((:max-tool-iterations . 5)))
```

You can also build callbacks at runtime without the macro:

```lisp
(cl-agent.chat:make-tool-callback
  (lambda (&key expression) (calc expression))
  :name "calculate"
  :description "Evaluate a math expression"
  :parameters '((expression :string "Expression" :required-p t)))
```

## 6. Conversation Memory

Memory is a filter, mounted on the `:chat` chain (so it applies on every
iteration inside the loop):

```lisp
(defvar *memory* (cl-agent.chat:make-message-window-chat-memory
                  :max-messages 20))

(defvar *kernel*
  (cl-agent.kernel:build-kernel
    :model *model*
    :filters (list (cl-agent.kernel:memory-filter *memory*))))

;; The same :conversation shares memory
(cl-agent.kernel:chat *kernel* (:user "My name is David") (:conversation "c1"))
(cl-agent.kernel:chat *kernel* (:user "What's my name?") (:conversation "c1"))

;; Inspect / clear
(cl-agent.chat:memory-messages *memory* "c1")
(cl-agent.chat:memory-clear *memory* "c1")
```

Custom storage backends implement `repository-find` / `repository-save` /
`repository-delete` / `repository-conversation-ids`.

## 7. Filters: the kernel's onion chains

A filter is an around-layer of the onion (mirroring Spring AI's Advisor API).
Each filter carries up to four hooks — three chains plus a streaming
transducer:

| Hook | Wraps | Carrier |
|---|---|---|
| `:chat` | one LLM call (every loop iteration) | `prompt` → `chat-response` |
| `:tool` | one tool execution | `tool-request` → `tool-result` |
| `:turn` | one whole turn (the entire tool loop) | `turn-request` → `turn-result` |
| `:token-xform` | streaming token transformation | transducer-style function |

Every hook is `(lambda (req chain) ...)`: rewrite `req` on the way in, call
`(funcall chain req)` to go downstream, post-process the return value —
**not calling `chain` short-circuits.**

```lisp
(defun timing-filter ()
  (cl-agent.kernel:make-filter
   :timing
   :turn (lambda (req chain)
           (let ((start (get-internal-real-time)))
             (prog1 (funcall chain req)
               (format t "took ~,2Fs~%"
                       (/ (- (get-internal-real-time) start)
                          internal-time-units-per-second)))))))

(defvar *kernel*
  (cl-agent.kernel:build-kernel
    :model *model*
    :filters (list (timing-filter)
                   (cl-agent.kernel:safeguard-turn-filter '("password"))
                   (cl-agent.kernel:logging-chat-filter))
    :tools '(get-weather)))
```

**The `filters` list order is the onion order: earlier = outer = runs first.**
There is no order field; position alone decides the layering. Above, the
layout is `timing → safeguard → run-tool-loop` (the `:turn` chain) and
`logging → chat-model-call` (the `:chat` chain).

Built-in filters:

| Filter | Chain | Purpose |
|---|---|---|
| `(memory-filter store &key window)` | `:chat` | Inject history as messages (mirrors `MessageChatMemoryAdvisor`) |
| `(logging-chat-filter &key log-fn preview)` | `:chat` | Request/response logging |
| `(logging-tool-filter &key log-fn)` | `:tool` | Tool name/args/result logging |
| `(safeguard-turn-filter keywords &key failure-response)` | `:turn` | Sensitive-keyword short-circuit guard |
| `(validation-turn-filter validate-fn &key max-retries)` | `:turn` | Validation failure → feedback re-entry |
| `(re-reading-filter &key template)` | `:turn` | Re2 re-reading prompt rewrite |
| `(qa-turn-filter retriever &key top-k)` | `:turn` | RAG retrieval injection |
| `(tool-search-filter index &key limit)` | `:chat` | Progressive tool disclosure (token savings on large tool sets) |
| `(timeout-filter milliseconds)` | `:tool` | Tool execution timeout |
| `(approval-filter &key approve-fn sensitive-names)` | `:tool` | Approval gate for sensitive tools |
| `(token-redact-filter patterns &key replacement)` | `:token-xform` | Streaming redaction |
| `(hold-release-filter &key approve-fn)` | `:token-xform` | Streaming hold / release |

The `defilter` macro defines a filter class plus its constructor in one form
(hook lambda-lists are `(self req chain)`):

```lisp
(cl-agent.kernel:defilter counting-filter ((count :initform 0 :accessor fc-count))
  (:turn (self req chain)
    (incf (fc-count self))
    (funcall chain req)))

(make-counting-filter)
```

> **Both Spring AI porting layers are retired.**
> - **Advisor**: `defadvisor` / `advise-call` / `chain-next` /
>   `make-simple-logger-advisor` and friends are gone. Migration:
>   `:advisors (list ...)` → `build-kernel :filters (list ...)`.
> - **ChatClient**: the whole `cl-agent.client` package (ChatClient / Builder /
>   fluent RequestSpec) is deleted. Migration: `make-kernel-client` /
>   `make-chat-client` → `build-kernel`; the fluent spec (`client-prompt` →
>   `prompt-user` → `call-content`) → `chat` macro clauses or
>   `kernel-chat-text`; `(:call :client-response)` → `(:call :result)`.
>
> `(chat kernel (:advisors ...))` **signals an error** with migration guidance
> rather than silently dropping the clause (a silent drop would make
> memory/guardrails fail quietly). Full mapping tables live in the
> [API Reference](API.md#migration).

## 8. Streaming & Structured Output

```lisp
(cl-agent.kernel:chat *kernel*
  (:user "Write a short poem")
  (:stream (lambda (delta) (princ delta) (force-output))))

(cl-agent.kernel:chat *kernel*
  (:user "Tokyo info as JSON (name/population)")
  (:call :entity))   ; → hash-table
```

> `(:call :entity)` **only parses JSON — it does not validate against a schema
> and does not retry.** It appends a "JSON only" system message, strips
> markdown fences, and calls `json-parse`. There is no schema argument —
> attach `validation-turn-filter` to validate (below).

Use `(:call :result)` when you want whole-turn information such as
`turn-result-status`:

```lisp
(let ((result (cl-agent.kernel:chat *kernel* (:user "Hi") (:call :result))))
  (values (cl-agent.kernel:turn-result-status result)   ; :completed / :cancelled ...
          (cl-agent.kernel:turn-result-tool-calls-made result)))
```

For "re-prompt the model with the validation errors when the output does not
match the schema" (mirroring Spring AI 2.0's
`StructuredOutputValidationAdvisor`), mount `validation-turn-filter` on the
kernel — it owns the verdict:

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
                    ;; verdict fn: (response) → (values ok-p feedback-text)
                    (cl-agent.kernel:structured-output-validate-fn
                     *schema* :parse-fn #'cl-agent.core:json-parse)
                    :max-retries 2))))

(let ((entity (cl-agent.kernel:chat *validating-kernel*
                (:user "Tokyo info as JSON")
                (:call :entity))))
  (gethash "population" entity))
```

`validation-turn-filter` sits on the `:turn` chain: on a mismatch it appends
the feedback text as a user message and **recursively re-enters the whole
loop** (`max-retries` defaults to 2, i.e. at most 3 passes). Once retries are
exhausted the last result is returned as-is — no condition is signalled.
Results with status `:paused` / `:cancelled` / `:error` pass straight through
without re-entry.

Always pass `:parse-fn` to `structured-output-validate-fn` — without a parser
it has no structured value to check and lets everything through.

> **Streaming note**: `(:stream cb)` currently degrades to a synchronous call
> (the full text arrives as a single chunk). Real SSE streaming lives at the
> ChatModel layer (`cl-agent.chat:chat-model-stream`); a streaming kernel
> invoke is not implemented yet.

## 9. Tests

```bash
# Test suite (all mock, runs offline)
sbcl --non-interactive --load run-tests.lisp

# End-to-end against a real provider (needs an API key)
MINIMAX_API_KEY=... sbcl --script scripts/live-test.lisp
```

`run-tests.lisp` is all mock: offline, deterministic, zero API spend. But a mock
can never prove "will a real model emit tool calls matching our schema" or "do
real SSE chunks reassemble correctly" — `scripts/live-test.lisp` covers exactly
that gap (tool loop / memory / schema validation / streaming).

## Next

- [API Reference](API.md) — includes the [ChatClient / Advisor migration tables](API.md#migration)
- [Tool Calling Architecture](tool-calling.md) — Filter vs. Manager
- [Full examples](../examples/kernel-usage.lisp) — eight progressive examples, all
  on the mock provider, no API key needed
