# CL-Agent Examples

[中文](README.md)

## chat-client-usage.lisp — Full ChatClient + Filter Walkthrough

Standalone script using the mock provider (no API key needed):

```bash
sbcl --load examples/chat-client-usage.lisp
```

Then run any of:

| Function | Demonstrates |
|---|---|
| `(chat-client-examples::example-1)` | Minimal chat macro call |
| `(chat-client-examples::example-2)` | Request-level system + options |
| `(chat-client-examples::example-3)` | deftool + run-tool-loop tool loop |
| `(chat-client-examples::example-4)` | memory-filter multi-turn conversation |
| `(chat-client-examples::example-5)` | Custom filter + logging/safeguard onion chain |
| `(chat-client-examples::example-6)` | Functional entry point (chat-client-text) |
| `(chat-client-examples::example-7)` | Structured output + schema-validated self-correction |
| `(chat-client-examples::example-8)` | Streaming (:stream) |

To use a real provider, replace `*model*` with:

```lisp
(cl-agent/llm:create-chat-model :anthropic
  :model "claude-sonnet-4-20250514")
```

## ../scripts/live-test.lisp — Real-provider End-to-End Verification

A mock can never prove "will a real model actually emit a tool call matching
our schema". This script covers that gap (not part of the test suite; run it
by hand):

```bash
MINIMAX_API_KEY=... sbcl --script scripts/live-test.lisp
```

Covers: single turn / real tool loop (asserts the tool was actually executed) /
multi-turn memory / structured-output schema validation / real SSE chunking.

## llm-usage.lisp — Low-level Provider SPI

Direct use of the `cl-agent/llm` client and providers, bypassing the chat-client.

## di-usage-examples.lisp — DI Container (optional facility)

Examples for the dependency-injection container in `cl-agent/core`
(a standalone facility; the library itself does not use it).
