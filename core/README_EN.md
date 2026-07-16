# CL-Agent Core

[中文](README.md)

Core module, the framework proper. Capabilities track Spring AI 2.0; the
architecture follows clj-agent.

## Packages

**One package**: `cl-agent.core` (nickname `cla.core`). The former
`cl-agent.http` / `cl-agent.chat` / `cl-agent.kernel` have all been merged into
it — `http/`, `chat/` and `kernel/` under `core/` are now just asd modules (file
grouping), no longer packages; every file is `(in-package #:cl-agent.core)`.

| Layer | Counterpart | Contents |
|---|---|---|
| Infrastructure | — | Conditions, utilities, DI container, JSON Schema generation & validation, HTTP/SSE client, `llm-chat` provider SPI, unified `llm-response` |
| Chat API | `org.springframework.ai.chat.*` | CLOS message hierarchy, Prompt, ChatOptions, ChatResponse, `deftool` tooling, ChatModel protocol, ChatMemory |
| Kernel | `chat.client.*` + `chat.client.advisor.*` | Filter tri-chain + `build-chain`, Kernel + `build-kernel`, `invoke-chat/tool/turn`, `run-tool-loop`, `resume-turn`, ToolCallingManager, 10 built-in filters, `chat` macro DSL |

After the merge, `cl-agent.core` and `cl-agent.client` (SimpleAgent) can be
`:use`d together directly, with no shadowing whatsoever:

```lisp
(defpackage :my-app
  (:use :cl :cl-agent.core :cl-agent.client))
```

## Layout

```
core/
├── package-core.lisp        cl-agent.core package (single package)
├── conditions.lisp          condition system
├── macros.lisp              utility macros (-> ->> when-let ...)
├── utils.lisp               utilities + ID generator / timestamp provider
├── validation.lisp          data validation
├── dependency-injection.lisp  DI container (standalone facility, unused internally)
├── data-convert.lisp        plist <-> hash-table conversion
├── json-schema.lisp         params->json-schema / validator
├── llm/
│   ├── response.lisp        unified llm-response / llm-usage / llm-tool-call
│   └── provider.lisp        llm-chat / llm-chat-stream SPI
├── http/                    HTTP client + async + retry + SSE streaming
├── chat/                    Chat Model API
│   ├── message.lisp         message hierarchy + neutral plist conversion
│   ├── options.lisp         ChatOptions (unset semantics + merging)
│   ├── prompt.lisp          Prompt (immutable augmentation)
│   ├── response.lisp        ChatResponse / Generation / metadata
│   ├── tool.lisp            deftool / ToolCallback
│   ├── memory.lisp          ChatMemory / repository protocol
│   └── model.lisp           ChatModel protocol + provider adapter (single call)
└── kernel/                  Kernel + Filter execution core (sole path)
    ├── carriers.lisp        tri-chain carriers + pause carriers (loop-state / pending-tool)
    ├── filter.lisp          filter CLOS + build-chain + defilter
    ├── kernel.lisp          kernel CLOS + build-kernel (incl. :tool-gate)
    ├── conditions.lisp      tool failure classes (semantic/transient/environment)
    ├── batch.lisp           batch tool execution (parallel / :serial / failure routing)
    ├── tool-calling-manager.lisp  sequential / virtual-thread / thread-pool
    ├── invoke.lisp          invoke-chat/tool/turn + run-tool-loop + resume-turn
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
  implements runtime > kernel defaults > model defaults, tool lists are unioned.
- **Tool execution is not inside ChatModel**: matching Spring AI 2.0,
  `chat-model-call` performs a single call only (it injects tool schemas but
  does not execute tools). The tool loop lives in `run-tool-loop`. The 1.x
  `internal-tool-execution-enabled` option is gone.
- **Filter tri-chain**: `:chat` / `:tool` / `:turn` (plus `:token-xform`).
  `build-chain` folds the filter list into nested closures that capture
  **only what is downstream** — so "recursive re-entry" is just calling the
  same `chain` again, with no extra machinery (this is how
  `validation-turn-filter` implements self-correcting retries).
  List order is onion order: earlier = outer = runs first.
- **HITL is a kernel primitive**: `build-kernel :tool-gate` takes a
  `(tool-call) → :proceed | :pause | (:pause . reason)` function, evaluated
  **before** batch execution, exactly once per tool-call (gates often have side
  effects — audit logs, approval UI, counters — so "exactly once" is part of
  the contract). A `:pause` verdict pauses the whole turn with **not one tool
  executed**; `run-tool-loop` returns `turn-result(:paused)` carrying a
  `loop-state` snapshot, and `resume-turn` continues from that midpoint once
  approved.
- **Both Spring AI porting layers are retired**: the `defadvisor` /
  `advise-call` / `order` system, and the old ChatClient / Builder / fluent
  RequestSpec. Kernel + filter is the sole execution path; the entry point is
  `build-kernel`'s keyword args plus the `chat` macro. (The name
  `cl-agent.client` has been **reused**: it is now SimpleAgent.)
- **The merge eliminated all shadowing**: `cl-agent.chat` and `cl-agent.kernel`
  used to share three exported names: `tool-response` / `make-tool-response`
  (chat's is the protocol-level "tool response" value object with id/name/text;
  kernel's was the tool-chain response carrier) and `execute-tool-calls` (two
  manager protocols with different signatures). Fixed at the root: the kernel
  carrier was renamed to `tool-request` / `tool-result` (symmetric with the turn
  chain's `turn-request` / `turn-result`), and chat's old ToolCallingManager was
  deleted outright. The three packages were then merged into `cl-agent.core`,
  and every `:shadow` disappeared.

See the [API reference](../docs/API.md).
