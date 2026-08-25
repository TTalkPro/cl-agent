# Changelog

All notable changes to **cl-agent** are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [11.0.0] — 2026-08-25

> Two breaking changes ship together in this release: the
> `kernel` → `chat-client` rename (previously sitting unreleased) and the
> three-layer alignment below.

### Breaking changes

- **Three-layer alignment with Spring AI: Provider / ChatModel / ChatClient.**
  The boundaries were redrawn so each layer owns one thing. No compatibility
  shims — this is a pre-1.0 refactor and a shim layer would just freeze the debt.

  **1. The ChatModel now carries the weight of a single call; the `client` class
  is gone.** `cl-agent/llm`'s `client` class and everything built on it
  (`client-chat`, `chat-simple`, `chat-with-tools`, `chat-multi-turn`,
  `batch-chat`, `count-tokens-for-client`, the whole `chat-stream` /
  `stream-iterator` family, `llm/client.lisp` and `llm/streaming.lisp`) were
  removed. It duplicated `provider-chat-model`'s job on a path the chat-client
  trunk never took — and **the retry logic was stranded there**
  (`chat-with-retry`), so the trunk had no retries at all.

  Retrying and observation are now ChatModel-layer capabilities, applied by a
  `chat-model-call :around` on the base class so every subclass inherits them
  and none can forget to wrap itself:

  ```lisp
  (create-chat-model :anthropic
    :retry-policy (make-retry-policy :max-attempts 4)
    :observation-fn (lambda (model prompt thunk) ...))
  ```

  Retries are **off by default**. What counts as retryable stays single-sourced
  in `error-retryable-p`; `retryable-error-p`'s bare-HTTP classification moved
  there as a new `http-error` method. The original condition is rethrown
  untouched when retries run out.

  | Removed | Use instead |
  |---|---|
  | `make-client` / the `client` class / its accessors | `create-chat-model` / `make-provider-chat-model` |
  | `client-chat` / `chat-simple` / `chat-multi-turn` / `batch-chat` | `chat-model-call`, or the `chat` macro for the filter chain |
  | `chat-stream` / `chat-stream-simple` / `chat-stream-to-string` / `chat-stream-to-file` / `chat-stream-iterator` / `stream-next` | `chat-model-stream`, or `invoke-chat-stream` for the filter chain |
  | `chat-with-retry` / `retryable-error-p` | `retry-policy` on the ChatModel; `error-retryable-p` |
  | `count-tokens-for-client` | `(count-tokens text provider-name)` |
  | `(embed client ...)` / `(estimate-cost client ...)` | `(embed provider ...)` / `(estimate-cost provider ...)` — `estimate-cost` and `*provider-pricing*` moved to `llm/providers.lisp` |

  **2. Model protocol abstractions** (`core/model/protocol.lisp`, mirroring
  `org.springframework.ai.model`): `model-request`, `model-response`,
  `model-result`, `model-options` plus `request-instructions` /
  `request-options` / `response-result` / `response-results` /
  `response-metadata` / `response-usage` / `result-output`. `prompt`,
  `chat-response`, `generation`, `chat-options` and `embedding-response` all
  plug in, so cross-cutting code stops branching on modality — `(response-usage
  resp)` answers for a chat response and an embedding response alike.

  **3. The ChatClient carriers were renamed, and one of them fixed.**

  | Before | After |
  |---|---|
  | `turn-request` (held bare messages) | `chat-client-request` (holds a `prompt`) |
  | `turn-result` | `chat-client-response` |
  | `turn-result-response` | `chat-client-response-chat-response` |
  | `turn-result-tool-context` | `chat-client-response-context` |
  | `turn-result-status` / `-loop-state` / `-pending-tool` / `-pause-reason` / `-tool-calls-made` | `chat-client-response-…` (same suffixes) |

  The request holding a `prompt` rather than bare messages removed a
  back-channel: request-level options used to travel as a `:caller-options` key
  smuggled through `context`, which `run-tool-loop` fished back out to merge and
  then had to strip again when folding into `tool-context`. New:
  `chat-client-request-mutate` (mirroring `ChatClientRequest#mutate`) — filters
  rewrite requests through it instead of rebuilding by hand and dropping fields,
  which the rag filter was doing with `resume-p`.

  **4. The ChatClient narrowed from 12 flat slots to 4**: `model`, `filters`,
  `default-request`, `tool-calling`.

  | Before | After |
  |---|---|
  | `tools` / `system` / `options` | `default-request` — a `chat-client-default-request` |
  | `eligibility-fn` / `tool-gate` / `state-slots` / `tool-manager` / `loop-fn` / `resume-fn`, plus `settings`' `:max-tool-iterations` | `tool-calling` — a `tool-calling-config` (mirrors `ToolCallingAdvisor`) |
  | `chat-client-settings` / `chat-client-loop-fn` / `chat-client-resume-fn` | removed; use `chat-client-max-tool-iterations` etc., or reach through the aggregates |

  `build-chat-client` keeps every flat argument and gains
  `:max-tool-iterations`; **`:settings` was removed** and passing it now errors
  with the migration spelling (same for `make-agent`, which also gained
  `:max-tool-iterations`). Its one key was read via `(cdr (assoc ...))`, so a
  typo silently fell back to 10 — keeping a "still accepted" shim would have
  left that read exactly where it was, just behind a different door. New:
  `chat-client-mutate` and `tool-calling-config-mutate` (mirroring
  `ChatClient#mutate`) — deriving a ChatClient used to mean taking it apart slot
  by slot and rebuilding, which `client/agent.lisp` did, needing a new line for
  every new slot.

  **5. What should have been classes now are.**

  | Was | Now |
  |---|---|
  | `tool-execution-result` plist | `tool-execution-result` class |
  | `tool-result-error`'s `(:class … :message …)` plist | `tool-error-info` class |
  | `state-slots`' `((key :init v :reduce fn) …)` | list of `state-slot` instances |
  | `resume-turn`'s `payload` plist | `resume-payload` class (entry still takes a plist) |
  | `retry-config` `defstruct` | `retry-config` class |

  Each of these was silently failable. `tool-execution-result` is the contract
  between the three managers and the tool loop: a typo in `:return-direct`
  returned NIL, the legal value for "do not short-circuit", so it failed as
  "approved a return-direct tool and then called the model one more time".
  `tool-error-info`'s `:class` **is the failure-routing predicate** — only
  `:transient` on a tool declaring `:retry` gets retried — and as a plist key a
  typo just meant "the tool did not retry", with no error. A test in this repo
  had invented a `:timeout` class and stayed green for a dozen versions;
  turning it into a class broke that test immediately. `state-slots`' `:reduce`
  misspelled as `:reducer` degraded to last-writer, turning "accumulate" into
  "overwrite".

  **Class invariants across the board.** `make-instance` is a permanently
  reachable back door in CL, so "this object must satisfy X as long as it
  exists" now hangs off `initialize-instance :after` rather than living only in
  `make-*`. New facility in `core/invariants.lisp`: a `definvariants` macro plus
  five primitives (`require-slot` / `require-member` / `require-type` /
  `require-callable` / `require-that`), signalling `invariant-violation` — which
  inherits `validation-error`, so the shared classification correctly treats it
  as **not** retryable.

  **36 of 61 classes** carry invariants. The other 25 state why they do not at
  the definition site — protocol base classes have no slots, providers allow an
  API key to arrive later, the DI container's slots are self-built internal
  state. The most important non-case is `chat-options`: none of its slots has an
  `:initform` because an unbound slot **is** the "unset" signal that
  `merge-chat-options` and `options->spi-args` are built on. Not every unbound
  slot is a hole, and a test now guards that decision.

  One caveat learned the hard way, now written into `core/invariants.lisp`:
  **enum whitelists belong on values we control, not on values an external
  system returns.** `llm-response`'s `finish-reason` briefly carried one, which
  turned `normalize-finish-reason`'s fallback into a hard failure — that fallback
  deliberately interns any unmapped vendor value as a keyword, because vendors
  add new reasons (`"safety"`, `"refusal"`) and callers testing
  `(eq reason :tool-call)` correctly fall through. The whitelist made such a
  response crash at construction; every test used known values, so it stayed
  green and only real traffic would have hit it. That slot now checks the type
  only. Whitelists stay where the value space is ours: `retry-config`'s
  `backoff` (a user setting — `:fibonacci` silently degrading to a flat delay is
  worth an error), `chat-client-response`'s `status`, and classifications whose
  fallback is itself inside the whitelist (`tool-error-info` falls back to
  `:semantic`, `media` to `:document`).

  Rolling this out immediately caught two latent bugs that had been green for
  versions: a test constructing `tool-result` with `:writes '((:counter . 1))` —
  an *alist* where `apply-writes` walks a plist by `cddr`, so the fold would have
  read the key as `(:counter . 1)` and the value as NIL (the test only asserted
  round-tripping and never actually folded it); and a leftover plist-shaped
  `:error` that the earlier `tool-error-info` conversion had missed.

  **6. Provider-layer observation.** `*llm-call-observer*` and
  `*llm-stream-observer*` are `:around` methods on `(t)`, so one `let` binding
  covers every provider — including mocks and test stubs, and regardless of
  which base class it inherits from (the real providers inherit
  `cl-agent/llm:base-provider`, not core's `base-llm-provider`, so hanging the
  method on the latter would have missed them). Ships with an
  `llm-usage-tally` + `usage-tally-observer` for token accounting.

  Division of labour with the ChatModel's `observation-fn`: that one wraps a
  single *logical* call (retries included, one entry — latency), this one wraps
  every *real wire call* (three retries fire it thrice — cost).

  **7. Versions unified.** All subsystems were on four different numbers
  (`9.0.0` / `10.0.0` / `4.2.0` / `1.0.0`); they are now all `11.0.0`.

  **Dangling exports removed.** Three symbols were exported without ever being
  defined — `cl-agent/llm:llm-stream` (zero implementations; the real entry
  point is `cl-agent/core:llm-chat-stream`), `cl-agent/core:di-container-p`
  (`di-container` is a `defclass`, so no such predicate was ever generated), and
  `cl-agent/llm:normalize-messages` (lived in the removed `client.lisp`). The
  first two predate this change. A new test, `every-export-has-a-definition`,
  now checks every external symbol of every package, so this class of bug —
  which has recurred here — fails the suite instead of the caller.

  Baseline: **1396 checks, 0 failures** on SBCL 2.6.7 and CCL (was 1165), plus
  **13/13** on the live end-to-end script against MiniMax-M2.7
  (`scripts/live-test.lisp`), which gained two checks for this release: the
  provider-layer observer accounting real wire-call tokens, and a
  `retry-policy` leaving the happy path untouched.


- **Renamed: `kernel` → `chat-client`, and the LLM `service` layer → `chat-model`.**
  A pure rename — no semantics, no behaviour, no wire format changed. Every
  public symbol, file and directory that carried the old word moved:

  | Before | After |
  |---|---|
  | `build-kernel` | `build-chat-client` |
  | the `kernel` class, `kernel-model` / `kernel-tools` / `kernel-filters` / `kernel-settings` / `kernel-tool-manager` / `kernel-tool-gate` / `kernel-state-slots` / `kernel-loop-fn` / `kernel-resume-fn` / `kernel-default-system` / `kernel-default-options` / `kernel-eligibility-fn` | `chat-client`, `chat-client-model`, `chat-client-tools`, … (same suffixes) |
  | `kernel-chat` | `chat-client-call` |
  | `kernel-chat-text` / `kernel-chat-entity` / `kernel-chat-stream` | `chat-client-text` / `chat-client-entity` / `chat-client-stream` |
  | `core/kernel/` (with `kernel.lisp`) | `core/chat-client/` (with `chat-client.lisp`) |
  | `llm/service.lisp` (the "Service layer") | `llm/chat-model.lisp` (the "ChatModel layer") |
  | `di-lazy-service`, `di-list-services`, `di-request-scope-service-name`, `*app-services*`, `*core-services*`, `*global-services*` | `di-lazy-chat-model`, `di-list-chat-models`, `di-request-scope-chat-model-name`, `*app-chat-models*`, `*core-chat-models*`, `*global-chat-models*` |
  | `tests/test-kernel-{chat,invoke,skeleton}.lisp`, `examples/kernel-usage.lisp` | `tests/test-chat-client-{chat,invoke,skeleton}.lisp`, `examples/chat-client-usage.lisp` |

  Two things deliberately kept the old word because they are not ours:
  `lparallel:*kernel*` / `lparallel:make-kernel` / `lparallel:end-kernel` /
  `no-kernel-error` (lparallel's thread pool, including the `with-http-kernel`
  macro that binds it), and DashScope's `/api/v1/services/...` URL paths.

  Note the **name reuse**: the Spring AI ChatClient porting layer deleted in
  v9.0.0 also had symbols called `chat-client` / `make-chat-client`. Today's
  `cl-agent/core:chat-client` is the core class formerly known as `kernel` and is
  unrelated to it. See *Migration* in the README.

- **Package consolidation**: `cl-agent/chat-client`, `cl-agent/chat`, `cl-agent/http`
  collapsed into a single `cl-agent/core`. See *Migration* below — most direct
  symbols kept their names.
- **Removed `cl-agent/protocols`** (the A2A / MCP layer): it was never compiled
  in the main build and its `.asd` referenced files that didn't exist. Anyone
  importing this package will fail at `ASDF:LOAD-SYSTEM` time.
- **Tool execution now respects concurrency controls**. `thread-pool-tool-calling-manager`'s
  `pool-size` was previously honored in name only (lparallel work-stealing let
  it run at ~`worker+1`); it is now a hard ceiling via a channel-based scheduler.
  Users who relied on the silent "no limit" behaviour to chain calls will see
  genuinely capped parallelism.
- **Multi-tool batches no longer crash on the default path**. lparallel's
  `*KERNEL*` is `NIL` by default; cl-agent now lazily creates a process-level
  pool on first multi-tool invocation. As a side-effect, prior test setups that
  pinned `lparallel:*kernel*` to a single worker will still observe
  single-threaded execution — but default configs now actually run ≥2 tools.
- **`cl-agent/llm:chat` is gone**. The low-level Provider SPI was historically
  named `chat`, shadowing the `cl-agent/core:chat` macro. The function is now
  `cl-agent/llm:client-chat` and the shadow is removed; `:USE :cl-agent/llm`
  no longer needs any shadowing.
- **Tools are now symbols**, not plist specs. `(:tools 'get-weather)` is the
  reference; the old plist form (`(:tools (:get-weather ...))`) no longer works.
- **Filters are real CLOS objects**. The historical convenience of returning
  bare lambdas from filter constructors is removed: they must be
  `make-filter` instances, returned from `make-filter`/`defilter`.
- **Stream semantics**: `chat-client-stream` is a single-shot call (does not
  drive a tool loop). Calling it on a prompt that triggers tool use now errors
  with a pointer to `chat-client-call` / `make-agent`'s streaming path, instead of
  silently streaming the assistant's initial utterance and dropping the rest.

### Migration (from pre-v10)

The v9→v10 restructuring shipped three structural changes. They have stabilized
with this release; the table below is canonical.

| Before | After |
|---|---|
| `cl-agent/http:*`, `cl-agent/chat:*`, `cl-agent/chat-client:*` | `cl-agent/core:*` (single package) |
| `cl-agent/chat-client:build-chat-client`, `deftool`, `http-request`, `tool-response` | `cl-agent/core:build-chat-client`, `cl-agent/core:deftool`, `cl-agent/core:http-request`, `cl-agent/core:tool-result` |
| `make-chat-client` / `chat-client-builder` | `build-chat-client` (preferred for power) **or** `cl-agent/client:make-agent` (recommended for apps) |
| `cl-agent/chat-client:run-tool-loop` | `cl-agent/core:run-tool-loop` (exposed if you built a custom executor) |
| `cl-agent/llm:chat` | `cl-agent/llm:client-chat` (low-level SPI; most users did not import this) |
| `cl-agent/protocols:a2a-*`, `mcp-*` | **removed**; no direct replacement |
| `(:tools (:get-weather ...))` plist forms | `(:tools 'get-weather)` (symbol identity) |

You can `:USE :cl-agent/core :cl-agent/client` together with **no shadowing**
required.

### Added

#### Application surface

- **`cl-agent/client`**: `SimpleAgent` — a stateful, callback-driven entry
  point for applications. `make-agent`, `agent-chat`, `agent-chat-result`,
  `agent-resume`, `agent-history`, `agent-clear`. The companion `cl-agent/core`
  chat-client remains available for fully-controlled composition.
- **HITL / approval workflow**: `make-agent :tool-gate`. When the gate returns
  `(:interrupt . reason)`, the turn is paused — **no tools execute, state is
  consistent** — and the caller receives a `pending-tool` plus a
  `pause-reason`. `agent-resume` accepts four decisions:
  `:APPROVED`, `:APPROVED` with `:PAYLOAD (:ARGS ...)`, `:REJECTED` with
  `:PAYLOAD (:MESSAGE ...)`, and `:REPLY` with `:PAYLOAD (:MESSAGE ...)`.
- **Event callbacks**: `:on-turn-start`, `:on-turn-end`, `:on-turn-error`,
  `:on-tool-call`, `:on-tool-result` on `make-agent`. Callback exceptions are
  isolated — they do not destabilize the turn.

#### ChatClient & filter surface

- **Three onion chains**: `:chat` (model-call), `:tool` (execution),
  `:turn` (loop) — plus a `:token-xform` transducer chain for streaming.
  Built via `build-chain`; recursion is free because each filter only captures
  `downstream`.
- **`ToolCallingManager`** (chat-client-bound execution model):
  `thread-pool-tool-calling-manager` (hard-bounded via a channel scheduler —
  no work-stealing), `virtual-thread-tool-calling-manager`, and
  `sequential-tool-calling-manager`. Companion:
  `with-thread-pool-tool-calling-manager` macro and idempotent
  `shutdown-tool-calling-manager`.
- **Batch primitives**: `run-tool-loop`, `invoke-turn`, `resume-turn`,
  `%tool-loop` / `%execute-and-append` / `%resume-continuation`,
  shared skeleton `execute-tool-calls`, generic `manager-run-batch`.
- **`apply-writes` fold**: per-tool `(values result writes-plist)` declares
  write intents; `fold-batch-writes` is the barrier that folds them through
  `build-chat-client :state-slots` reducers, in tool-call original order, with
  last-writer detection. Failed calls do not contribute.
- **Real streaming**: `chat-client-stream` + `compose-token-xforms` over
  provider-side `chat-model-stream`. The `:token-xform` filter protocol
  is `(downstream-emit) → (values emit finish)`.
- **Tool-search with progressive disclosure**: rewritten with CJK bigram
  tokenization, ranked-length upper bound, an internally-exposed
  `search_tools`, per-conversation session table (LRU, max 256 by default),
  and one-time instruction injection per session.
- **Per-tool retry policy**: `deftool (:retry t)` opts in to exponential
  backoff (`*transient-retry-attempts*` × `*transient-retry-base-delay*`).
  Defaults: 3 attempts, 0.1s base. Retries are per-tool because re-running a
  side-effecting tool is the tool author's decision, not the framework's.
- **`classify-tool-error`** now recursively unwraps `tool-execution-error`'s
  `:cause`, surfacing `transient-tool-failure`, `connection timeout`, and
  friends as their actual class rather than collapsing to `:SEMANTIC`.

#### Built-in filters (10)

`memory-filter`, `logging-chat-filter`, `logging-tool-filter`,
`safeguard-turn-filter`, `validation-turn-filter`,
`re-reading-tool-filter` (re-attempt on transient error),
`rag-qa-turn-filter` (retrieval-augmented generation),
`tool-search-filter` (progressive disclosure),
`timeout-tool-filter` (per-tool `:TIMEOUT`), `approval-tool-filter`
(wraps `tool-gate`), and the `:token-xform` family
(`redact-pii-token-xform`, `truncate-token-xform`).

#### Providers (`cl-agent/llm`)

- Anthropic, OpenAI, Zhipu GLM, DeepSeek (incl. prefix-continuation beta),
  Google Gemini, Mistral, Ollama, Alibaba DashScope, **MiniMax** (text &
  image input, image generation, video generation, video understanding,
  music generation, voice cloning, voice design). Single `create-chat-model`
  factory; per-provider wire modules under `llm/providers` and
  `llm/stream/`.

#### Telemetry / tests

- FiveAM suite: **855 checks / 0 failures** (offline, mock providers).
- Live test (`scripts/live-test.lisp`): **11/11** against MiniMax,
  including streaming, write folding, progressive tool disclosure, token
  redaction, HITL pause·approve·reject·reply.

### Changed

- **All public APIs are zero-warning on full clean recompile** (was 0/8/0/...).
  All `(:shadow ...)` and `(:import-from ...)` for resolving clashes were
  eliminated.
- **Documentation rewritten**: top-level `README` / `docs/QUICKSTART` /
  `docs/API` / `docs/tool-calling` now lead with `SimpleAgent` (the
  recommended entry point) and demote `chat-client + filter` to "Full control".
  Migration tables cover `ChatClient → ChatClient / Agent` and the package
  consolidation.
- **Test system renamed**: secondary system `cl-agent-test` →
  `cl-agent/test` (ASDF convention; ASDF no longer warns about
  non-existent parent system).
- **Provider wire modules restructured**: shared OpenAI-compatible base under
  `llm/providers/openai-compat.lisp`; per-provider SSE under
  `llm/stream/{anthropic,openai}.lisp`. The old `factory/builder.lisp`
  fluent Builder is removed (`create-chat-model` covers it).
- **Default tool-call batch scheduler**: thread-pool(4) is process-level,
  lazy, idempotent; respects any caller-bound `lparallel:*kernel*` it
  doesn't own.

### Fixed

- `pool-size` of `thread-pool-tool-calling-manager` is now a hard ceiling
  (was effectively `~worker+1` due to lparallel's `force` semantics).
- `classify-tool-error` returns the right class for `transient-tool-failure`
  etc. (was `:SEMANTIC` 100% of the time, hiding the routing rules).
- `make-tool-execution-result` now carries `:return-direct` through the
  `ToolCallingManager` path — previously any user-configured `:tool-manager`
  (the README's recommended path) silently downgraded
  `:return-direct t` tools into ordinary tool messages sent back to the
  model.
- `resume-turn` now routes its continuation batch through the configured
  `manager-run-batch` (previously it called `invoke-tool-batch` directly,
  bypassing both throttling **and** the `return-direct` fix above).
- `tool-search-filter` sessions now evict LRU entries (was unbounded — a
  slow leak across long-lived services).
- `tool-search-filter` instruction message is injected **once per session**
  (was appended every turn, growing the prompt without bound).
- `filter.lisp` `token-xform` slot docstring documents the actual protocol
  (`(downstream) → (values emit finish)`) — was the old transducer
  description, with no consumer of either form.
- `(:chat)` filter's rewritten tools are now the ones actually executed
  (`invoke-chat` returns `(values response effective-prompt)`; tool
  resolution uses the model-visible list, not the request-options list).
- Streaming chats that emit tool calls now error explicitly instead of
  silently delivering the trailing assistant utterance with no tool
  execution.
- `examples/chat-client-usage.lisp` registers `client/` with ASDF so
  `sbcl --load examples/chat-client-usage.lisp` works out of the box (was
  failing with "Component `:CL-AGENT-CLIENT` not found").

### Removed

- **`protocols/`** (entire A2A / MCP subsystem) — 8 source files plus
  `cl-agent-protocols.asd`, `package-protocols.lisp`, two READMEs. The
  subtree was never compiled in the main build, was loaded as dead code,
  and advertised integrations that didn't exist.
- **`core/validation.lisp`** — 13 `validate-*` / `ensure-*` macros with
  zero callers.
- **`examples/llm-usage.lisp`**, **`examples/protocols-usage.lisp`** —
  both referenced deleted symbols and failed at `LOAD` time.
- **`llm/factory/builder.lisp`** — fluent Builder API with zero callers;
  `create-chat-model` is the supported entry point.
- **`mock/tools.lisp`** — pre-`deftool` mock-tool framework that did not
  produce valid `tool-callback`s; superseded by the modern
  `deftool`-based equivalents.
- **`tests/test-protocols.lisp`** — referenced a non-existent package
  `cl-agent-tests`.
- **`tests/test-provider-name.lisp`** — never wired into the test `.asd`.
- **Dead utilities in `core/utils.lisp`**: `take`, `drop`, `group-by`,
  `plist-get`, `make-tool` (plist-era), `truncate-string`,
  `clean-whitespace`, `string-empty-p`, `ensure-string`,
  `format-timestamp`, `generate-short-id`, `pipe`, and `compose` (its
  unrolling was itself broken).
- **Dead macros in `core/macros.lisp`**: ~20 macros; retained only
  `when-let` and the `log-debug / log-info / log-warn / log-error`
  helpers.
- **Over-engineered error helpers**: 9 macros and 4 `signal-*`
  convenience wrappers from `conditions.lisp`.
- **`cl-agent/llm:chat`** → renamed `client-chat`.
- **`:shadow #:chat`** in `cl-agent/llm` (the function and the macro no
  longer collide).
- **`*default-mock-responses*`** — never defined; was exported anyway.
- **`cl-agent-test`** secondary system name → replaced by `cl-agent/test`.

### Security

- `deftool` arguments are validated against the generated JSON Schema
  before execution; unknown or malformed arguments are rejected before
  the callback is invoked.
- Approval gate (`make-agent :tool-gate`) ensures **no** tool in a paused
  batch has executed; this is enforced in the execution model, not by
  convention.
- `:token-xform` filters can redact or replace streamed tokens; this
  closes the "I logged the whole prompt" failure mode.

---

## [10.0.0] — internal consolidation (not released externally)

Captured here for completeness; this entry documents the architectural
shape that preceded the public release.

- Initial package consolidation: `cl-agent/{http,chat,chat-client}` → `cl-agent/core`.
- New `cl-agent/client` (SimpleAgent).
- New `cl-agent/mock` (mock providers).
- Per-package `:version` bumped to `10.0.0` (core, client).

> Note: no `git tag` was created at this point; the project moved directly
> into hardening (P1–P4), which constitutes *this* release entry above.
