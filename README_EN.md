# CL-Agent

[中文](README.md)

An AI Agent framework for Common Lisp: a **Kernel + Filter** tri-chain as the
one execution core, a **ChatModel** protocol decoupling multiple providers, and
CLOS + macros (`deftool` / `defilter` / `chat`) expressing what Java frameworks
express with annotations and builders.

Capabilities track Spring AI 2.0, but not its Java idioms — ChatClient, Builder,
fluent RequestSpec and the Advisor chain are all retired (see the migration note
below).

## Features

- **One entry point**: `build-kernel` assembles (model / filters / tools /
  settings), the `chat` macro issues requests. No Builder, no ClientRequestSpec.
- **Kernel + Filter tri-chain**: three onion chains — `:chat` / `:tool` / `:turn`
  (plus a `:token-xform` transducer). `build-chain` folds them into nested
  closures that capture only what is downstream, so recursive re-entry is free.
  Ten built-in filters: memory, logging (chat/tool), safety guard, structured
  output validation, re-reading, RAG QA, progressive tool disclosure, timeout,
  approval gate, token rewriting
- **ChatModel protocol**: `chat-model-call` / `chat-model-stream` (real SSE
  streaming), single-call semantics — the tool loop lives in
  `cl-agent.kernel:run-tool-loop`
- **Tool calling**: the `deftool` macro mirrors the `@Tool` annotation — JSON Schema
  derived automatically; a tool's identity is its symbol (no global side effects),
  referenced as `(:tools 'get-weather)`; ToolCallback / ToolCallingManager
  (sequential, virtual-thread, thread-pool) / `:return-direct` / ToolContext /
  three failure classes (semantic, transient, environment)
- **ChatMemory**: repository storage protocol + message-window memory with
  pairing-safe truncation
- **Multi-provider**: Anthropic, OpenAI, Zhipu GLM, DeepSeek, Gemini, Mistral,
  Ollama, DashScope, MiniMax (unified `llm-chat` SPI + `llm-response`, adapted
  via `provider-chat-model`; DeepSeek prefix completion supported)

## Architecture

```
┌──────────────────────────────────────────────────────┐
│  cl-agent.kernel   Kernel + Filter tri-chain (core)   │
│                    build-kernel + chat macro DSL +    │
│                    invoke-chat/tool/turn +            │
│                    run-tool-loop + ToolCallingManager │
├──────────────────────────────────────────────────────┤
│  cl-agent.chat     Message/Prompt/ChatOptions/        │
│                    ChatResponse + deftool tooling +   │
│                    ChatModel protocol + ChatMemory    │
├──────────────────────────────────────────────────────┤
│  cl-agent.core     infrastructure + llm-chat SPI +    │
│                    HTTP/SSE                           │
├──────────────────────────────────────────────────────┤
│  cl-agent.llm      providers (Anthropic/OpenAI/...)   │
└──────────────────────────────────────────────────────┘
```

How one `chat` call executes:

```
(chat kernel ...) → messages + context → turn-request
  → :turn chain (guard / validation / RAG / re-reading …)
      → run-tool-loop ─┬→ :chat chain (memory / logging / tool disclosure)
                       │     → chat-model-call
                       └→ :tool chain (timeout / approval / logging)
                             → tool execution
  → turn-result → text / chat-response / turn-result
```

Mapping to Spring AI:

| Spring AI 2.0 | CL-Agent |
|---|---|
| `ChatClient.builder(model).build()` | `(build-kernel :model m :filters ... :tools ...)` |
| `client.prompt().user(u).call().content()` | `(chat kernel (:user u))` |
| `@Tool` / `@ToolParam` | `deftool` macro |
| `CallAdvisor` / `AdvisorChain` | `make-filter` / `defilter` + `build-chain` tri-chain |
| `ToolCallingAdvisor` (2.0) | `cl-agent.kernel:run-tool-loop` (terminal of the `:turn` chain) |
| `ToolSearchToolCallingAdvisor` (2.0) | `tool-search-filter` (`:chat` chain) |
| `StructuredOutputValidationAdvisor` (2.0) | `validation-turn-filter` |
| `MessageChatMemoryAdvisor` | `memory-filter` (`:chat` chain, applied every loop iteration) |
| `SafeGuardAdvisor` / `SimpleLoggerAdvisor` | `safeguard-turn-filter` / `logging-chat-filter` |
| `MessageWindowChatMemory` | `message-window-chat-memory` |
| `ChatModel#call` | `chat-model-call` |
| `ToolCallingManager` | `cl-agent.kernel:tool-calling-manager` (three implementations) |

> **Both Spring AI porting layers are retired.**
> - **Advisor** (`defadvisor` / `advise-call` / `chain-next` + the six built-in
>   advisors) → kernel filter tri-chain. Migration: `:advisors (list ...)` →
>   `build-kernel :filters (list ...)`.
> - **ChatClient** (the whole `cl-agent.client` package: ChatClient / Builder /
>   fluent RequestSpec) → `build-kernel` keyword args + the `chat` macro.
>   Builders and chained specs are a Java idiom with no reason to exist in Lisp.
>   Migration: `make-kernel-client` → `build-kernel`; `(chat client ...)` works
>   unchanged, the symbol just comes from `cl-agent.kernel` now.

## Quick Start

```lisp
(asdf:load-system :cl-agent)

;; 1. Create a ChatModel (API key read from env var)
(defvar *model*
  (cl-agent.llm:create-chat-model :anthropic
    :model "claude-sonnet-4-20250514"))

;; 2. Define a tool (mirrors @Tool)
(cl-agent.chat:deftool get-weather (&key city (unit "celsius"))
  "Get the current weather for a city"
  (:param city :string "City name" :required t)
  (:param unit :string "Temperature unit")
  (format nil "Weather in ~A: 22°C (~A), sunny" city unit))

;; 3. Assemble a kernel (memory + logging filters)
(defvar *memory* (cl-agent.chat:make-message-window-chat-memory))
(defvar *kernel*
  (cl-agent.kernel:build-kernel
    :model *model*
    :filters (list (cl-agent.kernel:memory-filter *memory*)
                   (cl-agent.kernel:logging-chat-filter))
    :tools '(get-weather)))

;; 4. Chat — tools executed automatically, memory maintained automatically
(cl-agent.kernel:chat *kernel*
  (:system "You are a weather assistant")
  (:user "What's the weather in Tokyo?")
  (:conversation "conv-1"))
```

> The `filters` list is the onion order: earlier = outer = runs first.
> When you need no filters at all, `(build-kernel :model *model*)` is enough
> (model call + tool loop only).

Streaming and structured output:

```lisp
;; Streaming
(cl-agent.kernel:chat *kernel*
  (:user "Write a short poem")
  (:stream (lambda (delta) (princ delta))))

;; Structured JSON output (mirrors entity()) — parses only, does not validate
(cl-agent.kernel:chat *kernel*
  (:user "Give me Tokyo's info as JSON")
  (:call :entity))
```

To get "re-prompt the model with the validation error until it complies"
(mirroring Spring AI 2.0's `StructuredOutputValidationAdvisor`), attach a
`validation-turn-filter` to the kernel — it owns the verdict, while
`(:call :entity)` only parses:

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
                    ;; verdict: (response) → (values ok-p feedback).
                    ;; On failure the filter appends the feedback to messages
                    ;; and re-enters the whole loop so the model can correct
                    ;; itself (2 retries by default).
                    (cl-agent.kernel:structured-output-validate-fn
                     *schema* :parse-fn #'cl-agent.core:json-parse)
                    :max-retries 2))))

(cl-agent.kernel:chat *validating-kernel*
  (:user "Give me Tokyo's info as JSON")
  (:call :entity))
```

Custom filter:

```lisp
;; Every filter hook is (lambda (req chain) ...): rewrite req going in,
;; (funcall chain req) to go downstream, post-process the result coming out.
;; Not calling chain at all is a short-circuit (that's what the guard does).
(defun timing-filter ()
  (cl-agent.kernel:make-filter
   :timing
   :turn (lambda (req chain)
           (let ((start (get-internal-real-time)))
             (prog1 (funcall chain req)
               (format t "took ~,2Fs~%"
                       (/ (- (get-internal-real-time) start)
                          internal-time-units-per-second)))))))

(cl-agent.kernel:build-kernel
  :model *model*
  :filters (list (timing-filter)))
```

## Modules

| Module | Description |
|--------|-------------|
| **core** | Infrastructure (conditions/HTTP/SSE/JSON Schema), `llm-chat` SPI, `cl-agent.chat`, `cl-agent.kernel` |
| **llm** | Provider implementations, `create-chat-model` |
| **mock** | Mock provider (tests/demos, no API key needed) |
| **protocols** | A2A protocol support (standalone, not in main build) |

## Install & Test

```bash
sbcl --eval '(asdf:load-system :cl-agent)'

# Test suite (all mock, runs offline)
sbcl --non-interactive --load run-tests.lisp

# End-to-end against a real provider (needs an API key)
MINIMAX_API_KEY=... sbcl --script scripts/live-test.lisp
```

## Examples

See [examples/kernel-usage.lisp](examples/kernel-usage.lisp): eight progressive
examples covering the chat macro, build-kernel, deftool, memory, custom filters,
the functional entry point, structured-output validation, and streaming. All use
the mock provider — no API key needed.

For end-to-end verification against a real provider (tool loop / memory /
schema validation / SSE chunking):

```bash
MINIMAX_API_KEY=... sbcl --script scripts/live-test.lisp
```

## Documentation

- [Quick Start](docs/QUICKSTART.md)
- [API Reference](docs/API.md)
- [Tool Calling Architecture](docs/tool-calling.md) — filter/manager split,
  Spring AI 2.0 mapping, and known divergences

## License

MIT License
