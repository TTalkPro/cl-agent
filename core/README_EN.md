# CL-Agent Core

[中文](README.md)

Core module (v8.0.0), layered after Spring AI 2.0.

## Packages

| Package | Counterpart | Contents |
|---|---|---|
| `cl-agent.core` | — | Conditions, utilities, HTTP/SSE client, JSON Schema generation, `llm-chat` provider SPI, unified `llm-response` |
| `cl-agent.chat` | `org.springframework.ai.chat.*` | CLOS message hierarchy, Prompt, ChatOptions, ChatResponse, `deftool` tooling, ChatModel protocol, ChatMemory |
| `cl-agent.client` | `org.springframework.ai.chat.client.*` | Advisor protocol & onion chain, `defadvisor` macro, built-in advisors, ChatClient + builder + `chat` macro |

## Layout

```
core/
├── package-core.lisp        cl-agent.core package
├── conditions.lisp / macros.lisp / utils.lisp / types.lisp
├── json-schema.lisp         params->json-schema / schema-to-hash-table
├── llm/                     llm-chat SPI + unified llm-response
├── http/                    HTTP client + SSE streaming + retry
├── chat/                    Chat Model API
│   ├── message.lisp         message hierarchy + neutral plist conversion
│   ├── options.lisp         ChatOptions (unset semantics + merging)
│   ├── prompt.lisp          Prompt (immutable augmentation)
│   ├── response.lisp        ChatResponse / Generation / metadata
│   ├── tool.lisp            deftool / ToolCallback / ToolCallingManager
│   ├── memory.lisp          ChatMemory / repository protocol
│   └── model.lisp           ChatModel protocol + provider adapter (tool loop)
└── client/                  ChatClient + Advisor
    ├── advisor.lisp         protocol / onion chain / defadvisor
    ├── advisors.lisp        logger / message memory / prompt memory / guard
    └── chat-client.lisp     ChatClient / builder / request spec / chat macro
```

## Design Notes

- **Neutral plist boundary**: CLOS messages never cross the provider SPI;
  `messages->neutral` / `neutral->messages` convert at the
  `provider-chat-model` adapter, providers only see `(:role ... :content ...)`.
- **Option merging**: unbound slots mean "unset"; `merge-chat-options`
  implements runtime > client defaults > model defaults, tool lists are unioned.
- **Internal tool execution**: as in Spring AI, the tool loop lives inside the
  ChatModel (`internal-tool-execution-enabled` defaults to true); the
  ChatClient/advisors only see the final response.
- **Advisor onion chain**: lower `order` = outer position; `advise-stream`
  defaults to delegating to `advise-call`, so non-streaming advisors don't
  need to know about the streaming path.

See the [API reference](../docs/API.md).
