# CL-Agent Core

[中文](README.md)

Core module, layered after Spring AI 2.0.

## Packages

| Package | Counterpart | Contents |
|---|---|---|
| `cl-agent.core` | — | Conditions, utilities, HTTP/SSE client, JSON Schema generation & validation, `llm-chat` provider SPI, unified `llm-response` |
| `cl-agent.chat` | `org.springframework.ai.chat.*` | CLOS message hierarchy, Prompt, ChatOptions, ChatResponse, `deftool` tooling, ChatModel protocol, ChatMemory |
| `cl-agent.kernel` | `chat.client.*` + `chat.client.advisor.*` | Filter tri-chain + `build-chain`, Kernel + `build-kernel`, `invoke-chat/tool/turn`, `run-tool-loop`, ToolCallingManager, 10 built-in filters, `chat` macro DSL |

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
│   └── model.lisp           ChatModel protocol + provider adapter (single call)
└── kernel/                  Kernel + Filter execution core (sole path)
    ├── carriers.lisp        tri-chain request/response carriers
    ├── filter.lisp          filter CLOS + build-chain + defilter
    ├── kernel.lisp          kernel CLOS + build-kernel
    ├── conditions.lisp      tool failure classes (semantic/transient/environment)
    ├── batch.lisp           batch tool execution (parallel / :serial / failure routing)
    ├── tool-calling-manager.lisp  sequential / virtual-thread / thread-pool
    ├── invoke.lisp          invoke-chat/tool/turn + run-tool-loop
    ├── filters/             10 built-in filters
    │   ├── memory.lisp      memory (:chat, applied every loop iteration)
    │   ├── logging.lisp     logging (:chat / :tool)
    │   ├── safeguard.lisp   safety guard (:turn, short-circuits)
    │   ├── validation.lisp  structured-output validation (:turn, recursive re-entry)
    │   ├── re-reading.lisp  RE2 re-reading (:turn)
    │   ├── rag.lisp         RAG QA injection (:turn) + IRetriever
    │   ├── tool-search.lisp progressive tool disclosure (:chat) + IToolIndex
    │   ├── timeout.lisp     tool timeout (:tool)
    │   ├── approval.lisp    pre-execution approval gate (:tool)
    │   └── token-xform.lisp token rewriting (:token-xform transducer)
    └── chat.lisp            chat macro DSL + kernel-chat* entry points
```

## Design Notes

- **Neutral plist boundary**: CLOS messages never cross the provider SPI;
  `messages->neutral` / `neutral->messages` convert at the
  `provider-chat-model` adapter, providers only see `(:role ... :content ...)`.
- **Option merging**: unbound slots mean "unset"; `merge-chat-options`
  implements runtime > client defaults > model defaults, tool lists are unioned.
- **Tool execution is not inside ChatModel**: matching Spring AI 2.0,
  `chat-model-call` performs a single call only (it injects tool schemas but
  does not execute tools). The tool loop lives in
  `cl-agent.kernel:run-tool-loop`. The 1.x `internal-tool-execution-enabled`
  option is gone.
- **Filter tri-chain**: `:chat` / `:tool` / `:turn` (plus `:token-xform`).
  `build-chain` folds the filter list into nested closures that capture
  **only what is downstream** — so "recursive re-entry" is just calling the
  same `chain` again, with no extra machinery (this is how
  `validation-turn-filter` implements self-correcting retries).
  List order is onion order: earlier = outer = runs first.
- **Both Spring AI porting layers are retired**: the `defadvisor` /
  `advise-call` / `order` system, and the whole `cl-agent.client` package
  (ChatClient / Builder / fluent RequestSpec). Kernel + filter is the sole
  execution path; the entry point is `build-kernel`'s keyword args plus the
  `chat` macro.
- **Both packages can be `:use`d together**: `(:use :cl :cl-agent.chat
  :cl-agent.kernel)` needs no shadowing. It used to conflict — the two
  packages shared three exported names: `tool-response` /
  `make-tool-response` (chat's is the protocol-level "tool response" value
  object; kernel's was the tool-chain response carrier) and
  `execute-tool-calls` (two manager protocols with different signatures).
  Fixed at the root: the kernel carrier was renamed to `tool-request` /
  `tool-result` (symmetric with the turn chain's `turn-request` /
  `turn-result`), and chat's old ToolCallingManager was deleted outright.
  The kernel therefore needs no `:shadow` at all.

See the [API reference](../docs/API.md).
