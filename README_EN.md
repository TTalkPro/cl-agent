# CL-Agent

[中文](README.md)

An AI Agent framework for Common Lisp. Two ways to use it — pick per need:

- **SimpleAgent** (recommended starting point): a stateful agent object that
  handles the conversation, observability, error normalization and
  human-in-the-loop approval (HITL).
- **ChatClient + Filter** (full control): the tri-chain onion middleware plus the
  tool loop — every knob is yours to turn.

Capabilities track Spring AI 2.0 and the architecture follows clj-agent
(the Clojure chat-client+filter implementation), but it does not copy Java's idioms —
ChatClient, Builder and the fluent RequestSpec are not used here (see the
migration note at the end).

## Features

- **Two entry points**: `make-agent` / `agent-chat` (easy) and `build-chat-client` /
  `chat` (full control). The former is a thin wrapper over the latter — drop
  down whenever you need to.
- **ChatClient + Filter tri-chain**: three onion chains — `:chat` / `:tool` /
  `:turn` (plus a `:token-xform` transducer). `build-chain` folds them into
  nested closures that capture only what is downstream, so recursive re-entry
  is free. Ten built-in filters: memory, logging (chat/tool), safety guard,
  structured output validation, re-reading, RAG QA, progressive tool
  disclosure, timeout, approval gate, token rewriting
- **HITL (human approval)**: enabled by having `:on-tool-call` return
  `(:interrupt . reason)`. **When paused, not a single tool has executed**;
  `agent-resume` supports approve / edit-then-approve / reject (with the
  reason going back to the model) / reply-as-result (ask-user semantics)
- **ChatModel protocol**: `chat-model-call` / `chat-model-stream` (real SSE
  streaming), single-call semantics — the tool loop is `run-tool-loop`'s job
- **Tool calling**: the `deftool` macro mirrors the `@Tool` annotation — JSON
  Schema derived automatically; a tool's identity is its symbol (no global side
  effects), referenced as `(:tools 'get-weather)`; ToolCallback /
  ToolCallingManager (the chat-client-bound execution model and isolation
  mechanism) / `:return-direct` / ToolContext
- **ChatMemory**: repository storage protocol + message-window memory with
  pairing-safe truncation
- **Multi-provider**: Anthropic, OpenAI, Zhipu GLM, DeepSeek, Gemini, Mistral,
  Ollama, DashScope, MiniMax (unified `llm-chat` SPI + `llm-response`, adapted
  via `provider-chat-model`; DeepSeek prefix completion beta supported)

## Architecture

Three packages, mirroring clj-agent's core / provider / client layering:

```
┌──────────────────────────────────────────────────────┐
│  cl-agent/client   SimpleAgent (stateful chat + HITL) │
│                    make-agent / agent-chat            │
├──────────────────────────────────────────────────────┤
│  cl-agent/core     the framework proper (one package) │
│                    ChatClient + Filter tri-chain + chat   │
│                    Message/Prompt/Options/Response     │
│                    deftool / ChatModel / ChatMemory    │
│                    infrastructure + HTTP/SSE + Schema  │
├──────────────────────────────────────────────────────┤
│  cl-agent/llm      providers (Anthropic/OpenAI/...)   │
└──────────────────────────────────────────────────────┘
```

`cl-agent/core` and `cl-agent/client` can be `:use`d together directly, with no
shadowing whatsoever:

```lisp
(defpackage :my-app
  (:use :cl :cl-agent/core :cl-agent/client))
```

How one conversation executes:

```
(agent-chat a "...")  or  (chat chat-client ...)
  → prompt + context → chat-client-request
  → :turn chain (guard / validation / RAG / re-reading …)
      → run-tool-loop ─┬→ :chat chain (memory/logging/tool disclosure)
                       │     → chat-model-call
                       │         → ChatModel: option merge / retry / observation
                       │             → provider
                       └→ :tool chain (timeout/approval/logging)
                            → tool execution
                              ↑ tool-gate is evaluated before this (HITL pause point)
  → chat-client-response → text / chat-response / chat-client-response
```

## Quick Start

```lisp
(asdf:load-system :cl-agent)

(defpackage :my-app
  (:use :cl :cl-agent/core :cl-agent/client))
(in-package :my-app)

;; 1. Create a ChatModel (API key read from env var automatically)
(defvar *model*
  (cl-agent/llm:create-chat-model :anthropic
    :model "claude-sonnet-4-20250514"))

;; 2. Define a tool (mirrors @Tool)
(deftool get-weather (&key city (unit "celsius"))
  "Get the current weather for a city"
  (:param city :string "City name" :required t)
  (:param unit :string "Temperature unit")
  (format nil "Weather in ~A: 22°C (~A), sunny" city unit))

;; 3. Build an agent
(defvar *a*
  (make-agent :model *model*
              :system "You are a weather assistant"
              :tools '(get-weather)))

;; 4. Chat — context accumulates automatically, no conversation-id to pass
(agent-chat *a* "What's the weather in Tokyo?")  ; => "Weather in Tokyo: 22°C..."
(agent-chat *a* "And Beijing?")                  ; remembers the previous turn
(agent-history *a*)                              ; => 4 messages
```

### Results and errors: nothing is thrown

`agent-chat` returns `(values nil result)` on error. For the full result use
`agent-chat-result`:

```lisp
(let ((r (agent-chat-result *a* "hi")))
  (agent-result-status r))   ; :completed | :paused | :cancelled | :error
```

A failed LLM call is an **expected, ordinary event** (network hiccups, rate
limits, a model going sideways), so the agent layer normalizes it into a status
instead of throwing the condition at the caller.

### Observability: callbacks

```lisp
(make-agent :model *model* :tools '(get-weather)
            :callbacks (list :on-turn-start  (lambda (a) ...)
                             :on-turn-end    (lambda (a r) ...)
                             :on-turn-error  (lambda (a e) ...)
                             :on-tool-call   (lambda (name args) ...)
                             :on-tool-result (lambda (name text) ...)))
```

A callback throwing does not capsize the turn — callbacks are observation, not
control flow.

### Human approval (HITL)

**Configure `:on-tool-call` to return `(:interrupt . reason)` and it is on** —
not a separate mechanism, just the callback's return value:

```lisp
(defvar *a*
  (make-agent :model *model* :tools '(rm-file)
              :callbacks (list :on-tool-call
                               (lambda (name args)
                                 (when (string= name "rm_file")
                                   (cons :interrupt
                                         (format nil "deleting ~A needs approval"
                                                 (getf args :path))))))))

(let ((r (agent-chat-result *a* "delete /tmp/x.log")))
  (agent-result-status r)        ; => :paused
  (agent-result-pause-reason r)  ; => "deleting /tmp/x.log needs approval"
  (agent-result-pending-tool r)) ; => #<PENDING-TOOL rm_file (:PATH "/tmp/x.log")>

;; While paused, **not one tool has executed**. Resume once approved:
(agent-resume *a* :approved)                                   ; approve
(agent-resume *a* :approved :payload '(:args (:path "/tmp/safe.log")))  ; edit then approve
(agent-resume *a* :rejected :payload '(:message "no deletes in prod"))  ; reject (reason goes back to the model)
(agent-resume *a* :reply    :payload '(:message "that file is already gone")) ; reply is the result
```

| decision | Semantics |
|---|---|
| `:approved` | Approve execution; `:payload (:args ...)` rewrites the args first |
| `:rejected` | Do not execute; `(:message reason)` goes back to the model as the tool result, saving it a round of guessing |
| `:reply` | Do not execute; `(:message answer)` **is** the tool result (ask-user semantics) |

Resuming may pause again (another sensitive tool in the same batch, or a later
iteration triggering the gate).

## ChatClient: full control

When you need filters (memory strategy, guards, RAG, validation …), drop down
to the chat-client. **The agent layer does not accept `:filters`** — build your own
chat-client and pass it in:

```lisp
(defvar *memory* (make-message-window-chat-memory))

(defvar *chat-client*
  (build-chat-client
    :model *model*
    :system "You are a weather assistant"
    :tools '(get-weather)
    :filters (list (memory-filter *memory*)      ; earlier = outer = runs first
                   (logging-chat-filter))
    :max-tool-iterations 10))

;; Use the chat-client directly
(chat *chat-client* (:user "Weather in Tokyo?") (:conversation "conv-1"))

;; Or hand it to an agent (gaining session management + HITL + error normalization)
(make-agent :chat-client *chat-client* :memory *memory*)
```

The `chat` macro:

```lisp
(chat *chat-client*
  (:system "You are a weather assistant")  ; overrides the chat-client's default :system
  (:user "Weather in ~A?" city)            ; format control strings supported
  (:tools 'get-weather)                    ; request-level tools, unioned with the chat-client's :tools
  (:options :temperature 0.3)              ; merged over the chat-client's :options, request-level wins
  (:conversation "conv-1")                 ; = (:context :conversation-id "conv-1")
  (:call :content))                        ; :content (default) | :response | :result | :entity
```

### Streaming and structured output

```lisp
;; Streaming (note: the chat-client layer currently degrades to synchronous;
;; for real SSE see chat-model-stream)
(chat *chat-client* (:user "Write a short poem")
      (:stream (lambda (delta) (princ delta))))

;; Structured JSON output — parses only, does not validate
(chat *chat-client* (:user "Give me Tokyo's info as JSON") (:call :entity))
```

To get "re-prompt the model with the validation error until it complies",
attach a `validation-turn-filter` — it owns the verdict, while `(:call :entity)`
only parses:

```lisp
(defvar *schema*
  "{\"type\":\"object\",
    \"properties\":{\"name\":{\"type\":\"string\"},
                   \"population\":{\"type\":\"integer\"}},
    \"required\":[\"name\",\"population\"]}")

(build-chat-client
  :model *model*
  :filters (list (validation-turn-filter
                  ;; verdict: (response) → (values ok-p feedback)
                  ;; On failure it appends the feedback to messages and
                  ;; recursively re-enters the whole loop so the model can
                  ;; correct itself (2 retries by default)
                  (structured-output-validate-fn *schema* :parse-fn #'json-parse)
                  :max-retries 2)))
```

### Custom filters

```lisp
;; Every filter hook is (lambda (req chain) ...): rewrite req going in,
;; (funcall chain req) to go downstream, post-process the value coming out.
;; Not calling chain at all is a short-circuit (that's what the guard does).
(defun timing-filter ()
  (make-filter
   :timing
   :turn (lambda (req chain)
           (let ((start (get-internal-real-time)))
             (prog1 (funcall chain req)
               (format t "took ~,2Fs~%"
                       (/ (- (get-internal-real-time) start)
                          internal-time-units-per-second)))))))

(build-chat-client :model *model* :filters (list (timing-filter)))
```

## Modules

| Module | Package | Description |
|------|---|------|
| **core** | `cl-agent/core` | The framework proper (one package): infrastructure + HTTP/SSE + JSON Schema + `llm-chat` SPI + Chat API (messages/Prompt/Options/Response/deftool/ChatModel/ChatMemory) + ChatClient/Filter tri-chain + the `chat` macro |
| **llm** | `cl-agent/llm` | Provider implementations; `create-chat-model` builds a ChatModel in one step |
| **client** | `cl-agent/client` | SimpleAgent: stateful chat + callbacks + error normalization + HITL |
| **mock** | `cl-agent/mock` | Mock provider (tests/demos, no API key needed) |

## Install & Test

```bash
# Load (SBCL + Quicklisp)
sbcl --eval '(asdf:load-system :cl-agent)'

# Run the test suite (all mock, runs offline)
sbcl --non-interactive --load run-tests.lisp

# End-to-end against a real provider (needs an API key)
MINIMAX_API_KEY=... sbcl --script scripts/live-test.lisp
```

Currently: **855 checks / 0 failures** (all mock, offline); live **11/11** (MiniMax).

## Examples

See [examples/chat-client-usage.lisp](examples/chat-client-usage.lisp): eight progressive
examples covering the chat macro, build-chat-client, deftool, memory, custom filters,
the functional entry point, structured-output validation and streaming. All use
mock — no API key needed.
(Run: `sbcl --load examples/chat-client-usage.lisp`)

End-to-end verification against a real provider (11 checks: single Q&A / tool
loop / multi-turn memory / schema validation / HITL pause·approve·reject /
progressive tool disclosure / token redaction / real SSE chunking /
state-folding writes):

```bash
MINIMAX_API_KEY=... sbcl --script scripts/live-test.lisp
```

> Mock can never prove things like "will a real model emit tool calls that match
> our schema" or "did the tool really not execute while paused" — the live
> script covers exactly that gap.

## Documentation

- [Quick Start](docs/QUICKSTART.md)
- [API Reference](docs/API.md)
- [Tool Calling Architecture](docs/tool-calling.md) — the filter/manager split,
  the Spring AI 2.0 mapping and known divergences
- [CHANGELOG](CHANGELOG.md) — version-to-version changes and migration notes
  (Keep a Changelog format)

## Migration Notes

### This rename: Kernel → ChatClient, the Service layer → the ChatModel layer

| Old | New |
|---|---|
| `build-kernel` | `build-chat-client` |
| the `kernel` class / `kernel-model`, `kernel-tools`, `kernel-filters` … | `chat-client` / `chat-client-model`, `chat-client-tools`, `chat-client-filters` … |
| `kernel-chat` | `chat-client-call` |
| `kernel-chat-text` / `-entity` / `-stream` | `chat-client-text` / `chat-client-entity` / `chat-client-stream` |
| `core/kernel/` (directory) | `core/chat-client/` |
| `llm/service.lisp` (the Service layer) | `llm/chat-model.lisp` (the ChatModel layer) |
| DI: `di-lazy-service` / `di-list-services` / `*app-services*` | `di-lazy-chat-model` / `di-list-chat-models` / `*app-chat-models*` |

A pure rename — no semantics or behaviour changed. `lparallel:*kernel*` (the
thread pool) and DashScope's `/api/v1/services/...` paths are not part of it and
were left alone.

> **Note the name reuse**: the "ChatClient porting layer" below is the Spring AI
> ChatClient + Builder + fluent RequestSpec port, deleted wholesale in v9.0.0. It
> is **not** the same thing as today's `chat-client` core — the names just collide.

### The old ChatClient porting layer (deleted in v9.0.0) → the ChatClient core / SimpleAgent

| Old (porting layer) | New |
|---|---|
| `make-chat-client` | `build-chat-client` (`:model` is a **keyword** argument) |
| `chat-client-builder` + `default-system` … | `build-chat-client :system ...` |
| fluent spec (`client-prompt` → `prompt-user` → `call-content`) | `chat` macro clauses, or `chat-client-text` |
| `(:call :client-response)` | `(:call :result)` (returns a chat-client-response) |

### Package merge (`cl-agent/http` / `/chat` / `/chat-client` → `cl-agent/core`)

| Old | New |
|---|---|
| `cl-agent/chat-client:build-chat-client` | `cl-agent/core:build-chat-client` |
| `cl-agent/chat:deftool` | `cl-agent/core:deftool` |
| `cl-agent/http:http-request` | `cl-agent/core:http-request` |
| `cl-agent/chat-client:tool-response` | `cl-agent/core:tool-result` (`make-tool-result :value ...`) |

The name `cl-agent/client` has been **reused**: it used to be the ChatClient
porting layer (deleted); it is now SimpleAgent.

For the capability mapping against Spring AI see
[docs/tool-calling.md](docs/tool-calling.md).

## License

MIT License
