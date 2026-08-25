# LLM Module

[中文](README.md) | English

LLM provider implementations and unified interface module.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│  Provider Layer (returns raw API response plist)                │
│  ├── providers/anthropic.lisp  ──┐                              │
│  ├── providers/bailian.lisp      │                              │
│  ├── providers/zhipu.lisp        ├──→ llm-chat returns plist    │
│  ├── providers/openai.lisp       │                              │
│  └── providers.lisp            ──┘                              │
│           │                                                     │
│           ▼                                                     │
│  ChatModel Layer (chat-model.lisp)                                   │
│  └── normalize-response ─────────→ llm-response object          │
│           │                                                     │
│           ▼                                                     │
│  Consumers (ChatClient, Agent, Application code)                    │
│  └── Use unified llm-response objects                           │
└─────────────────────────────────────────────────────────────────┘
```

## Directory Structure

```
llm/
├── package.lisp              # Package definition
├── client.lisp               # Unified client interface
├── providers.lisp            # Provider registration
├── streaming.lisp            # Streaming support
├── chat-model.lisp              # ChatModel layer (response normalization)
├── providers/                # Provider implementations
│   ├── base.lisp            # base class
│   ├── define-provider.lisp # shared wire helpers
│   ├── openai-compat.lisp   # OpenAI-compat base + define-openai-compat-provider
│   ├── anthropic.lisp       # Anthropic Claude
│   ├── openai.lisp          # OpenAI GPT
│   ├── zhipu.lisp           # ZhipuAI GLM
│   ├── ollama.lisp          # Ollama (local)
│   ├── minimax.lisp         # MiniMax
│   ├── deepseek.lisp        # DeepSeek
│   ├── gemini.lisp          # Google Gemini
│   ├── mistral.lisp         # Mistral AI
│   └── dashscope.lisp       # Alibaba Cloud DashScope (Qwen)
├── stream/                   # real SSE streaming (llm-chat-stream)
│   ├── anthropic.lisp       # Anthropic format (anthropic + minimax)
│   └── openai.lisp          # OpenAI-compatible format
└── factory/                  # factory
    └── registry.lisp        # provider registry + aliases + create-chat-model
```

## Supported Providers

| Provider | Keyword | Default Model | Features |
|----------|---------|---------------|----------|
| Anthropic | `:anthropic` | claude-3-5-sonnet-20241022 | Tool calling, streaming |
| OpenAI | `:openai` | gpt-4o | Tool calling, streaming, embeddings |
| ZhipuAI | `:zhipu` | GLM-4.7 | Tool calling, streaming, reasoning chain |
| Alibaba DashScope | `:dashscope` | qwen-plus | Tool calling, streaming |
| Ollama | `:ollama` | llama2 | Local running |

## ChatModel Layer

The ChatModel layer normalizes raw provider responses into unified `llm-response` objects.

### Response Normalization

```lisp
;; Provider returns raw plist
(let ((raw-response (llm-chat provider messages)))
  ;; ChatModel layer normalizes to llm-response
  (normalize-response raw-response :zhipu))

;; Or use high-level API (auto-normalization)
(chat-with-normalization provider messages)
```

### llm-response Object

```lisp
;; Unified response structure
(llm-response-content response)        ; Text content
(llm-response-tool-calls response)     ; Tool calls list
(llm-response-usage response)          ; Token usage info
(llm-response-model response)          ; Model name
(llm-response-finish-reason response)  ; Finish reason (see below)
(llm-response-message-id response)     ; Message ID
(llm-response-reasoning response)      ; Reasoning-chain text
(llm-response-reasoning-blocks response) ; Provider-native reasoning blocks
(llm-response-raw response)            ; Raw response

;; Convenience predicates
(llm-response-has-tool-calls-p response)
(llm-response-has-content-p response)

;; Convenience accessors
(llm-response-input-tokens response)
(llm-response-output-tokens response)
(llm-response-total-tokens response)
```

`finish-reason` is normalized to four keywords, independent of what the provider
sent on the wire:

| Keyword | Meaning | Example provider values |
|---|---|---|
| `:stop` | Normal completion | `stop` / `end_turn` / `stop_sequence` |
| `:tool-call` | Model requested a tool | `tool_calls` / `tool_use` |
| `:max-tokens` | Truncated at the token limit | `length` / `max_tokens` |
| `:content-filter` | Content filtered | `content_filter` |

> `llm-response-reasoning-blocks` holds the provider's reasoning blocks verbatim
> (Anthropic thinking blocks carry a cryptographic signature). Its **only**
> supported use is echoing them back unchanged on a later turn — Anthropic
> *requires* the assistant turn of a tool-calling conversation to replay them, or
> the request is rejected with a 400. To display the reasoning, use
> `llm-response-reasoning` or `response-reasoning-content` below.

### llm-response Utilities

Not specific to any one provider — reasoning chains and finish reasons are
normalized in the ChatModel layer:

```lisp
;; Extract reasoning-chain content: GLM / DeepSeek `reasoning_content` and
;; Anthropic thinking blocks all land here (legacy raw-response form is
;; still accepted).
(response-reasoning-content response)
;; => "Let me think about this..."

;; Check whether the response is complete (not truncated).
;; Accepts an llm-response or a legacy plist; returns NIL for anything else.
(response-complete-p response)
;; => T (:stop) / NIL (truncated or ended for another reason)
```

## Quick Start

### Creating a ChatModel

`create-chat-model` is this module's application-facing entry point: it builds
the provider, then wraps it in a ChatModel. The provider is responsible only for
low-level details and how to call the API; retries, observation, and default
options belong to the ChatModel.

```lisp
;; Anthropic Claude
(defvar *claude*
  (create-chat-model :anthropic
    :model "claude-sonnet-4-20250514"
    :api-key (uiop:getenv "ANTHROPIC_API_KEY")))

;; OpenAI GPT
(defvar *gpt*
  (create-chat-model :openai
    :model "gpt-4o"
    :api-key (uiop:getenv "OPENAI_API_KEY")))

;; Zhipu AI
(defvar *glm*
  (create-chat-model :zhipu :model "glm-4-turbo"))

;; Ollama (local)
(defvar *local*
  (create-chat-model :ollama
    :model "llama2"
    :api-url "http://localhost:11434"))
```

### Basic Chat

`chat-model-call` is a single call: it does **not** execute tools and does not
loop. For the tool loop, memory, or HITL, use the chat-client (see "Integrating
with the chat-client" below).

```lisp
;; Plain string (wrapped into a prompt automatically)
(cl-agent/core:chat-response-text
  (cl-agent/core:chat-model-call *claude* "Hello!"))

;; Multi-turn: a message list
(cl-agent/core:chat-model-call *claude*
  (list (cl-agent/core:user-message "My name is Ming")
        (cl-agent/core:assistant-message "Nice to meet you, Ming!")
        (cl-agent/core:user-message "What is my name?")))

;; With parameters: via the prompt's options
(cl-agent/core:chat-model-call *claude*
  (cl-agent/core:make-prompt
    "Write a poem"
    :options (cl-agent/core:make-chat-options :temperature 0.9
                                              :max-tokens 500)))
```

### Tool Calling

The ChatModel injects tool schemas and hands tool-calls back untouched; it does
**not** execute them. The caller decides what to do (Spring AI calls this
user-controlled tool execution).

```lisp
(cl-agent/core:deftool get-weather (city)
  "Get weather information"
  (:city :type string :description "City name")
  (format nil "~A: sunny, 22°C" city))

(let ((response
        (cl-agent/core:chat-model-call *claude*
          (cl-agent/core:make-prompt
            "What is the weather in Beijing?"
            :options (cl-agent/core:make-chat-options :tool-names '(get-weather))))))
  (dolist (call (cl-agent/core:chat-response-tool-calls response))
    (format t "Tool: ~A~%" (cl-agent/core:tool-call-name call))
    (format t "Args: ~A~%" (cl-agent/core:tool-call-arguments call))))
```

### Streaming Output

```lisp
;; ChatModel layer: incremental text callback, returns the final chat-response
(cl-agent/core:chat-model-stream *claude* "Tell me a story"
  (lambda (delta)
    (format t "~A" delta)
    (force-output)))
```

When a provider does not support streaming this degrades to a single call, with
the whole text delivered as one delta. To layer the filter chain and token
transforms (redaction, hold-and-release) onto the streaming path, use
`cl-agent/core:invoke-chat-stream`.

### Embeddings

```lisp
;; Single text
(embed *openai-provider* "Hello, world!")
;; => #(0.123 0.456 ...)

;; Batch
(embed-batch *openai-provider* '("text1" "text2" "text3"))
;; => (#(...) #(...) #(...))
```

The embedding API takes a **provider**, not a ChatModel — it goes through the
`llm-embed` SPI.

### Token Counting

```lisp
(count-tokens "This is a test sentence")   ; rough estimate
(count-tokens "text" :openai)
;; => 8
```

### Cost Estimation

```lisp
(estimate-cost (make-anthropic-provider) 1000 500)
;; => 0.0105   ; USD, rough figure at the provider's flagship tier
```

## ChatModel Configuration

```lisp
(create-chat-model :anthropic
  :model "claude-sonnet-4-20250514"
  :api-key "sk-..."
  :api-url "https://api.anthropic.com"     ; custom endpoint

  ;; Model-level default options (request-level options win,
  ;; merged per merge-chat-options)
  :options (cl-agent/core:make-chat-options
             :max-tokens 4096
             :temperature 0.7)

  ;; Retry: a ChatModel-layer capability, nil (no retry) by default
  :retry-policy (cl-agent/core:make-retry-policy
                  :max-attempts 4        ; total attempts, including the first
                  :initial-delay 1.0     ; delay before the first retry (seconds)
                  :backoff 2.0           ; backoff multiplier
                  :max-delay 60.0        ; per-delay ceiling
                  :jitter 0.1)           ; ±10% jitter

  ;; Observation: wraps the whole call, retries included
  :observation-fn (lambda (model prompt thunk)
                    (declare (ignore model prompt))
                    (let ((start (get-internal-real-time)))
                      (prog1 (funcall thunk)
                        (format t "took ~Dms~%"
                                (round (- (get-internal-real-time) start)
                                       (/ internal-time-units-per-second 1000)))))))
```

Retry classification has a single source of truth,
`cl-agent/core:error-retryable-p`: transient HTTP statuses (408/409/425/429/5xx)
and network-layer failures are retryable; auth and argument errors are not.

> **Note on streaming**: tokens already handed to the callback cannot be taken
> back. If a stream dies halfway and is retried, the caller sees the first part
> twice. Leave `retry-policy` unset on streaming paths.

## Custom Providers

```lisp
;; Inherit base class
(defclass my-provider (base-provider)
  ((name :initform "my-provider")
   (api-url :initform "https://api.example.com")))

;; Implement chat method
(defmethod llm-chat ((provider my-provider) messages &key tools settings)
  ;; Implement API call
  ...)

;; Register provider
(register-provider :my-provider #'make-my-provider)

;; Use
(create-chat-model :my-provider :model "my-model")
```

## Schema Conversion

Different providers have different tool schema formats, the module handles conversion automatically:

```lisp
;; Internal unified format (deftool generates it; you can also write it by hand)
(:name "tool_name"
 :description "Description"
 :parameters (:type "object"
              :properties (...)
              :required (...)))

;; Convert a batch into a provider's wire format
(convert-tools-to-provider tools provider)

;; Each provider's rule lives in this generic — specialize it for a new provider
(cl-agent/core:provider-format-tools provider tools)
```

> Note: this section used to name `convert-schema-to-openai` /
> `convert-schema-to-anthropic` — functions from the long-deleted `schema/`
> module (their near-twins under `providers/` differed by a single preposition,
> which is part of why that module went away). The entry points above are the
> real ones.

You rarely touch this layer: pass `deftool`-defined tools through
`chat-options`' `:tool-names` / `:tool-callbacks` and the ChatModel injects the
schemas for you.

## Error Handling

The condition hierarchy has a single source of truth in `core/conditions.lisp`:
`cl-agent-error → api-error → llm-error`, and `execution-error → timeout-error`.
Whether something should be retried is decided by `error-retryable-p` — do not
grow a second set of rules at the call site.

```lisp
(handler-case
    (cl-agent/core:chat-model-call *claude* "Hello")
  (cl-agent/core:llm-error (e)
    (format t "LLM error (~A): ~A~%"
            (cl-agent/core:api-status-code e)
            (cl-agent/core:error-message e))
    ;; When deciding for yourself, ask the same classifier
    (when (cl-agent/core:error-retryable-p e)
      (format t "(transient — a :retry-policy would have retried this)~%")))
  (cl-agent/core:timeout-error (e)
    (format t "Timeout: ~A~%" e)))
```

## Integrating with the chat-client

```lisp
;; Create a ChatModel in one step (recommended entry point)
(defvar *model*
  (cl-agent/llm:create-chat-model :anthropic
    :model "claude-sonnet-4-20250514"))

;; Or adapt an existing provider
(defvar *model*
  (cl-agent/core:make-provider-chat-model
    (make-anthropic-provider)
    :default-options (cl-agent/core:make-chat-options :temperature 0.3)))

;; Assemble a chat-client, then chat
(defvar *chat-client* (cl-agent/core:build-chat-client :model *model*))
(cl-agent/core:chat *chat-client* "Hello")
```
