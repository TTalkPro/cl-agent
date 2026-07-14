# CL-Agent Examples

[中文](README.md)

## chat-client-usage.lisp — Full ChatClient Walkthrough

Standalone script using the mock provider (no API key needed):

```bash
sbcl --load examples/chat-client-usage.lisp
```

Then run any of:

| Function | Demonstrates |
|---|---|
| `(chat-client-examples::example-1)` | Minimal chat macro call |
| `(chat-client-examples::example-2)` | Builder-style construction |
| `(chat-client-examples::example-3)` | deftool + internal tool-execution loop |
| `(chat-client-examples::example-4)` | ChatMemory multi-turn conversation |
| `(chat-client-examples::example-5)` | defadvisor + logger/safe-guard advisors |
| `(chat-client-examples::example-6)` | Fluent pipeline style (-> threading macro) |
| `(chat-client-examples::example-7)` | Structured output (:call :entity) |
| `(chat-client-examples::example-8)` | Streaming (:stream) |

To use a real provider, replace `*model*` with:

```lisp
(cl-agent.llm:create-chat-model :anthropic
  :model "claude-sonnet-4-20250514")
```

## llm-usage.lisp — Low-level Provider SPI

Direct use of the `cl-agent.llm` client and providers, bypassing ChatClient.

## di-usage-examples.lisp — DI Container (optional facility)

Examples for the dependency-injection container in `cl-agent.core`
(used by the protocols subsystem).
