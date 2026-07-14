# CL-Agent

[中文](README.md)

An AI Agent framework for Common Lisp, architecturally aligned with
**Spring AI 2.0**: the **ChatClient + Advisor** programming model at the core,
a **ChatModel** protocol decoupling multiple providers, and CLOS + macros
(`deftool` / `defadvisor` / `chat`) expressing what Java does with annotations
and fluent builders.

## Features

- **ChatClient**: builder pattern + fluent request API + declarative `chat` macro DSL
- **Advisor onion chain**: `advise-call` / `advise-stream` protocol, ordered chain,
  `defadvisor` defines class + method + constructor in one form; built-in logger,
  message memory, prompt memory, and safe-guard advisors
- **ChatModel protocol**: `chat-model-call` / `chat-model-stream` (real SSE
  streaming), single-call semantics — the tool loop lives in
  `tool-calling-advisor` (2.0 architecture)
- **Tool calling**: the `deftool` macro mirrors the `@Tool` annotation — JSON Schema
  derived automatically, registered globally; ToolCallback / ToolCallingManager /
  `:return-direct` / ToolContext
- **ChatMemory**: repository storage protocol + message-window memory with
  pairing-safe truncation
- **Multi-provider**: Anthropic, OpenAI, Zhipu GLM, DeepSeek, Gemini, Mistral,
  Ollama, DashScope, MiniMax (unified `llm-chat` SPI + `llm-response`, adapted
  via `provider-chat-model`; DeepSeek prefix completion supported)

## Architecture

```
┌──────────────────────────────────────────────────────┐
│  cl-agent.client   ChatClient + Builder + chat macro │
│                    Advisor protocol/chain + defadvisor│
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

Mapping to Spring AI:

| Spring AI 2.0 | CL-Agent |
|---|---|
| `ChatClient.builder(model).build()` | `(-> (chat-client-builder model) ... (build-client))` |
| `client.prompt().user(u).call().content()` | `(chat client (:user u))` or fluent pipeline |
| `@Tool` / `@ToolParam` | `deftool` macro |
| `CallAdvisor` / `AdvisorChain` | `defadvisor` / `advise-call` / `chain-next` |
| `ToolCallingAdvisor` (2.0) | `tool-calling-advisor` (auto-registered, streaming tool loop) |
| `MessageChatMemoryAdvisor` | `message-chat-memory-advisor` |
| `MessageWindowChatMemory` | `message-window-chat-memory` |
| `ChatModel#call` | `chat-model-call` |
| `ToolCallingManager` | `tool-calling-manager` |

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

;; 3. Build a ChatClient (memory + logger advisors)
(defvar *memory* (cl-agent.chat:make-message-window-chat-memory))
(defvar *client*
  (cl-agent.client:make-chat-client *model*
    :system "You are a weather assistant"
    :advisors (list (cl-agent.client:make-message-chat-memory-advisor
                     :memory *memory*)
                    (cl-agent.client:make-simple-logger-advisor))))

;; 4. Chat — tools executed automatically, memory maintained automatically
(cl-agent.client:chat *client*
  (:user "What's the weather in Tokyo?")
  (:tools 'get-weather)
  (:conversation "conv-1"))
```

Streaming and structured output:

```lisp
;; Streaming
(cl-agent.client:chat *client*
  (:user "Write a short poem")
  (:stream (lambda (delta) (princ delta))))

;; Structured JSON output (mirrors entity())
(cl-agent.client:chat *client*
  (:user "Give me Tokyo's info as JSON")
  (:call :entity))
```

## Modules

| Module | Description |
|--------|-------------|
| **core** | Infrastructure (conditions/HTTP/SSE/JSON Schema), `llm-chat` SPI, `cl-agent.chat`, `cl-agent.client` |
| **llm** | Provider implementations, `create-chat-model` |
| **mock** | Mock provider (tests/demos, no API key needed) |
| **protocols** | A2A protocol support (standalone, not in main build) |

## Install & Test

```bash
sbcl --eval '(asdf:load-system :cl-agent)'
sbcl --non-interactive --load run-tests.lisp
```

## Examples

See [examples/chat-client-usage.lisp](examples/chat-client-usage.lisp): eight
progressive examples covering the chat macro, builder, deftool, memory, custom
advisors, fluent pipeline, structured output, and streaming.

## Documentation

- [Quick Start](docs/QUICKSTART.md)
- [API Reference](docs/API.md)

## License

MIT License
