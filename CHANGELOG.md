# Changelog

All notable changes to **cl-agent** are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

### Breaking changes

- **Package consolidation**: `cl-agent.kernel`, `cl-agent.chat`, `cl-agent.http`
  collapsed into a single `cl-agent.core`. See *Migration* below — most direct
  symbols kept their names.
- **Removed `cl-agent.protocols`** (the A2A / MCP layer): it was never compiled
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
- **`cl-agent.llm:chat` is gone**. The low-level Provider SPI was historically
  named `chat`, shadowing the `cl-agent.core:chat` macro. The function is now
  `cl-agent.llm:client-chat` and the shadow is removed; `:USE :cl-agent.llm`
  no longer needs any shadowing.
- **Tools are now symbols**, not plist specs. `(:tools 'get-weather)` is the
  reference; the old plist form (`(:tools (:get-weather ...))`) no longer works.
- **Filters are real CLOS objects**. The historical convenience of returning
  bare lambdas from filter constructors is removed: they must be
  `make-filter` instances, returned from `make-filter`/`defilter`.
- **Stream semantics**: `kernel-chat-stream` is a single-shot call (does not
  drive a tool loop). Calling it on a prompt that triggers tool use now errors
  with a pointer to `kernel-chat` / `make-agent`'s streaming path, instead of
  silently streaming the assistant's initial utterance and dropping the rest.

### Migration (from pre-v10)

The v9→v10 restructuring shipped three structural changes. They have stabilized
with this release; the table below is canonical.

| Before | After |
|---|---|
| `cl-agent.http:*`, `cl-agent.chat:*`, `cl-agent.kernel:*` | `cl-agent.core:*` (single package) |
| `cl-agent.kernel:build-kernel`, `deftool`, `http-request`, `tool-response` | `cl-agent.core:build-kernel`, `cl-agent.core:deftool`, `cl-agent.core:http-request`, `cl-agent.core:tool-result` |
| `defadvisor` / `(:advisors ...)` | `make-filter` / `defilter` + `:filters` |
| `make-chat-client` / `chat-client-builder` | `build-kernel` (preferred for power) **or** `cl-agent.client:make-agent` (recommended for apps) |
| `cl-agent.kernel:run-tool-loop` | `cl-agent.core:run-tool-loop` (exposed if you built a custom executor) |
| `cl-agent.llm:chat` | `cl-agent.llm:client-chat` (low-level SPI; most users did not import this) |
| `cl-agent.protocols:a2a-*`, `mcp-*` | **removed**; no direct replacement |
| `(:tools (:get-weather ...))` plist forms | `(:tools 'get-weather)` (symbol identity) |

You can `:USE :cl-agent.core :cl-agent.client` together with **no shadowing**
required.

### Added

#### Application surface

- **`cl-agent.client`**: `SimpleAgent` — a stateful, callback-driven entry
  point for applications. `make-agent`, `agent-chat`, `agent-chat-result`,
  `agent-resume`, `agent-history`, `agent-clear`. The companion `cl-agent.core`
  kernel remains available for fully-controlled composition.
- **HITL / approval workflow**: `make-agent :tool-gate`. When the gate returns
  `(:interrupt . reason)`, the turn is paused — **no tools execute, state is
  consistent** — and the caller receives a `pending-tool` plus a
  `pause-reason`. `agent-resume` accepts four decisions:
  `:APPROVED`, `:APPROVED` with `:PAYLOAD (:ARGS ...)`, `:REJECTED` with
  `:PAYLOAD (:MESSAGE ...)`, and `:REPLY` with `:PAYLOAD (:MESSAGE ...)`.
- **Event callbacks**: `:on-turn-start`, `:on-turn-end`, `:on-turn-error`,
  `:on-tool-call`, `:on-tool-result` on `make-agent`. Callback exceptions are
  isolated — they do not destabilize the turn.

#### Kernel & filter surface

- **Three onion chains**: `:chat` (model-call), `:tool` (execution),
  `:turn` (loop) — plus a `:token-xform` transducer chain for streaming.
  Built via `build-chain`; recursion is free because each filter only captures
  `downstream`.
- **`ToolCallingManager`** (kernel-bound execution model):
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
  `build-kernel :state-slots` reducers, in tool-call original order, with
  last-writer detection. Failed calls do not contribute.
- **Real streaming**: `kernel-chat-stream` + `compose-token-xforms` over
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

#### Providers (`cl-agent.llm`)

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
  recommended entry point) and demote `kernel + filter` to "Full control".
  Migration tables cover `Advisor → Filter`, `ChatClient → Kernel / Agent`,
  and the package consolidation.
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
- `examples/kernel-usage.lisp` registers `client/` with ASDF so
  `sbcl --load examples/kernel-usage.lisp` works out of the box (was
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
- **`cl-agent.llm:chat`** → renamed `client-chat`.
- **`:shadow #:chat`** in `cl-agent.llm` (the function and the macro no
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

- Initial package consolidation: `cl-agent.{http,chat,kernel}` → `cl-agent.core`.
- New `cl-agent.client` (SimpleAgent).
- New `cl-agent.mock` (mock providers).
- Per-package `:version` bumped to `10.0.0` (core, client).

> Note: no `git tag` was created at this point; the project moved directly
> into hardening (P1–P4), which constitutes *this* release entry above.
