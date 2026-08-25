# Tool Calling Architecture: Filter vs. Manager

[中文](tool-calling_CN.md)

This document explains why tool calling in cl-agent is split into three
concerns — **the kernel's loop (`run-tool-loop`)**, **Filters (composable
around-layers)**, and **Managers (execution strategy)** — how those map onto
Spring AI 2.0, and where we **deliberately or knowingly** diverge from the
reference implementation.

For the symbol-level quick reference, see the "Tool System" section of the
[API Reference](API.md).

## In one line

**The kernel owns the loop; filters wrap the loop; the manager executes tools.**

```
run-tool-loop:  invoke-chat → tool-calls & eligible? → run one batch → append messages → call model again
                ↑ :chat chain                          ↑ this cell is the manager / invoke-tool-batch
                                                         each tool in the batch also goes through the :tool chain
```

The loop lives in `cl-agent/core:run-tool-loop` (`core/kernel/invoke.lisp`).
It is **the terminal of the `:turn` chain, not a filter**, and it is **not
inside ChatModel** (`chat-model-call` is strictly single-call semantics).

Terminal does not mean fixed: `build-kernel :loop-fn` replaces it wholesale, so
a different loop skeleton (ReAct, plan-execute) is a kernel argument rather than
a fork. Because the swap happens *at* the terminal — the chain's single exit —
the `:turn` filters wrapping it are untouched, and so is the HITL resume path,
which works by substituting that same terminal. A custom loop that wants
pause/resume supplies `:resume-fn` alongside; see
[API Reference](API.md#loop-fn--resume-fn--swapping-the-loop-skeleton).

The execution layer returns after one batch. It does not know
`:max-tool-iterations`, does not know which iteration it is on, and does not
decide whether to continue. All of that belongs to `run-tool-loop`.

## Mapping to Spring AI 2.0

| Spring AI 2.0 | cl-agent | Owns loop |
|---|---|---|
| `ToolCallingAdvisor` (2.0) | `run-tool-loop` (`core/kernel/invoke.lisp`, `:turn` chain terminal) | **Yes** |
| `CallAdvisor` / `AdvisorChain` | `make-filter` / `defilter` + `build-chain` tri-chain | No (wraps) |
| `ToolCallingManager` | `cl-agent/core:tool-calling-manager` (three impls) | No |
| `ToolExecutionResult` | `make-tool-execution-result` plist | Result object |
| `ToolExecutionExceptionProcessor` | none; the kernel uses three failure classes (below) | Error handling |

A naming note: one of Spring AI 2.0's breaking changes renamed 1.1.x's
`ToolCallAdvisor` to `ToolCallingAdvisor`. The 1.1.x javadoc still shows the
old name.

> **Both of cl-agent's Spring AI porting layers are retired.** `defadvisor` /
> `advise-call` / `chain-next` / `tool-calling-advisor` / the
> `+*-advisor-order+` constants are all gone, and so is the ChatClient porting
> layer (ChatClient / Builder / fluent RequestSpec) — note the package name
> `cl-agent/client` has been **reused** and is now SimpleAgent.
> Spring's Advisor semantics are expressed here with the kernel + filter
> tri-chain: `:advisors (list ...)` → `build-kernel :filters (list ...)`; the
> entry point is `build-kernel` + the `chat` macro.
> "Advisor" below therefore always refers to the Spring-side component, and
> "the kernel path" means the one execution path:
> `build-kernel` → `chat` → `invoke-turn`.

## Why the split exists: the 1.x lesson

In Spring AI 1.x, **every ChatModel implementation carried its own private tool
execution loop** — the official blog's words are "functional, but buried. There
was no way to hook into it." Version 2.0 lifts the tool loop into the chain as a
first-class, composable component, so that other components (logging, memory,
guardrails) can observe and intercept tool calling.

cl-agent draws the same lesson but lands it further out: the loop is lifted into
the **kernel**, and the chain is split into **three**, which makes "which layer
you mount on" a meaningful choice by itself:

| Chain | Wraps | Typical filters |
|---|---|---|
| `:turn` | one whole turn (the **entire** tool loop) | guardrails, validation re-entry, RAG injection |
| `:chat` | **every** LLM call inside the loop | memory, logging, progressive tool disclosure |
| `:tool` | **every** tool execution | timeout, approval gate, tool logging |

This is exactly what 1.x could not do and 2.0 wanted: a guardrail can wrap the
whole loop (`:turn`) or re-check on every iteration (`:chat`); an approval gate
can sit precisely on a single tool (`:tool`) without understanding the loop at
all.

All three chains are folded by `build-chain`: earlier in the `filters` list =
outer = runs first, with no order field. Each layer's closure **captures only
its downstream**, which makes recursive re-entry free — when
`validation-turn-filter` rejects a result it simply calls `(funcall chain req)`
again to re-run the whole loop, without re-running the filters above it.

## Two execution modes

The split yields two execution modes; both go through the kernel:

1. **Framework-controlled** — `build-kernel` + the `chat` macro; the kernel runs
   the loop, callers do nothing
2. **Kernel-controlled** — inject a `:tool-manager` into the kernel to pick an
   execution strategy

```lisp
;; 1. Framework-controlled
(cl-agent/core:build-kernel
  :model model
  :filters (list (cl-agent/core:timeout-filter 5000))
  :tools '(get-weather))

;; 2. Kernel-controlled: inject an execution strategy
(cl-agent/core:build-kernel
  :model model
  :tools '(get-weather)
  :tool-manager (cl-agent/core:make-sequential-tool-calling-manager))
```

> **There used to be a third, "user-controlled" mode** — call `chat-model-call`
> yourself and drive the loop with the pre-merge `cl-agent/chat`'s own
> ToolCallingManager. It
> is gone. That whole chat-level manager
> (`default-tool-calling-manager` / `concurrent-tool-calling-manager` /
> `execute-tool-calls` with the `(manager prompt response)` arity /
> `tool-execution-result` and its accessors) was deleted. Tool execution now
> lives **only** in the kernel layer — `run-tool-loop`, `invoke-tool-batch`,
> and the three ToolCallingManagers. The kernel is the only path.
>
> A side benefit: with the chat-level `execute-tool-calls` gone and the kernel
> carrier renamed to `tool-result`, the two packages shared no exported names,
> so every `:shadow` disappeared — which is precisely what made merging
> `cl-agent/http` / `/chat` / `/kernel` into `cl-agent/core` possible.

## What the execution layer does

Once `run-tool-loop` sees `tool-calls` and `eligibility-fn` approves, it hands
the batch to the execution layer — `invoke-tool-batch`
(`core/kernel/batch.lisp`) when `kernel-tool-manager` is nil, or the
`execute-tool-calls` protocol when it is not. It:

1. **Resolves** — finds the callback by name (`find-callback-for-call`, `core/chat/tool.lisp`)
2. **Schedules** — **parallel by default** (`lparallel:future`); if any tool in
   the batch declares `:serial`, the whole batch degrades to sequential; a batch
   of ≤1 also degrades, avoiding pointless overhead
3. **Goes through the `:tool` chain** — each tool enters the `:tool` onion via
   `invoke-tool` (timeout / approval / logging all take effect at this layer)
4. **Isolates errors** — a throwing tool does not kill the conversation; the
   condition is captured into the `tool-result`'s `:error` slot and comes back
   as text returned to the model (via `tool-result->text`), which can then
   self-correct. This covers an **unknown tool name** too: `resolve-callback`
   catches `tool-not-found-error` and turns it into a `:semantic` error result
   rendered as "错误：找不到工具 xxx", instead of letting the condition escape
   `(chat ...)` and kill the turn
5. **Aggregates return-direct** — set to T only when **every** tool in the batch
   declared `:return-direct`; then the tool results are the final answer and are
   not fed back to the model

Results come back in the original `tool-calls` order — parallelism affects
timing, never message order.

### Why it deserves to be a separate abstraction

If this were only "loop over callbacks," a `mapcar` inside `run-tool-loop` would
do. It exists separately because **execution strategy** is a replaceable seam:

- `make-virtual-thread-tool-calling-manager` — parallel default, respects
  `:serial`; suits I/O-bound tool bodies (HTTP / DB)
- `make-sequential-tool-calling-manager` — fully serial; suits debugging or
  strict side-effect ordering
- `make-thread-pool-tool-calling-manager` — thread pool for rate-limited
  scenarios (configurable `pool-size`)

Swapping implementations touches neither the loop nor any filter.

## The three failure classes

`core/kernel/conditions.lisp` sorts tool failures into three classes;
`classify-tool-error` maps any condition onto one of them:

| Class | Meaning | Intended action |
|---|---|---|
| `:semantic` | model's fault: bad argument format, logic error, unsupported operation | no retry; return as text for the model to self-correct |
| `:transient` | transient fault: timeout, rate limit (429/503), connection reset | retryable |
| `:environment` | environment fault: permission denied, auth failure, dependency down | needs human intervention |

Classification runs in priority order: a `tool-failure` subclass yields its
`:class` slot directly → `tool-not-found-error` / `tool-execution-error` are
`:semantic` → otherwise a keyword heuristic over the error message
("timeout"/"429"/"503" → `:transient`; "permission denied"/"unauthorized"/
"forbidden" → `:environment`) → falling back to `:semantic` (conservative: no
retry).

Tool authors can signal the precise condition and bypass the heuristic:

```lisp
(cl-agent/core:deftool fetch-quote (&key symbol)
  "Fetch a stock quote"
  (:param symbol :string "Ticker symbol" :required t)
  (:retry t)
  (handler-case (http-get-quote symbol)
    (error (e)
      (error 'cl-agent/core:transient-tool-failure
             :message (princ-to-string e)))))
```

The classification drives the routing: `:transient` on a tool declaring
`(:retry t)` gets an exponential-backoff retry inside the framework; everything
else is labelled and parked in the `tool-result`'s `:error` slot, where `:tool`
filters and callers can read it, and the text goes back to the model. See known
divergence 3 below for the one branch that is still missing (`:environment` →
pause for a human).

> The classification has to see through a wrapper: `tool-callback-call` wraps
> **everything** a tool body signals into a `tool-execution-error`, stashing the
> original in `:cause`. `classify-tool-error` unwraps it recursively — without
> that, a tool signalling `transient-tool-failure` would come out the other side
> labelled `:semantic`, and all three classes would collapse into one.

## A security boundary

`find-callback-for-call` **only consults this request's options; it does not
fall back to the global registry.**

This is deliberate. With a fallback, any `deftool`'d tool would execute as soon
as the model names it — a privilege escalation directly exploitable under prompt
injection. And since `deftool` auto-registers, an author would have no idea their
attack surface had widened.

The reference implementations have no such fallback either: clj-agent's
`find-function` only consults the kernel's `:tool-vars` and throws when it
misses; Spring's `ToolCallbackResolver` is an instance field on the manager,
empty by default.

**Not-found is a semantic failure, not a crash.** `find-callback-for-call`
signals `tool-not-found-error` when it misses. That condition used to be raised
*outside* the batch path's `handler-case`, so a hallucinated tool name — a common
LLM failure — escaped all the way out of `(chat ...)` and killed the whole turn.
`resolve-callback` (`core/kernel/batch.lisp`) now catches it and produces a
`:semantic` error `tool-result`, which `tool-result->text` renders as
"错误：找不到工具 xxx" and feeds back to the model so it can self-correct — pick a
different tool, fix the arguments. The boundary itself is unchanged: a tool that
was not exposed is still never executed; the model just gets told so in words.

Moving to the kernel did not loosen this boundary — it tightened it by a layer.
The kernel's `resolve-kernel-tools` only honours `kernel-tools` (plus whatever
this request's `(:tools ...)` merged in via caller-options), and `run-tool-loop`
re-resolves on every iteration. Guardrails and approval gates are then an
**independent second line**: `safeguard-turn-filter` short-circuits on the
`:turn` chain (returning a `:cancelled` `turn-result` — the model is never
called at all), and `approval-filter` gates tool-by-tool on the `:tool` chain.
Neither depends on tool resolution being correct.

## Known divergences

### 1. `resolveToolDefinitions` is not on the manager (structural gap)

Spring's manager interface is **bidirectional**:

```java
public interface ToolCallingManager {
    List<ToolDefinition> resolveToolDefinitions(ToolCallingChatOptions chatOptions);  // outbound
    ToolExecutionResult executeToolCalls(Prompt prompt, ChatResponse chatResponse);   // inbound
}
```

cl-agent's kernel manager has only the inbound half (`execute-tool-calls`).
Outbound resolution goes through the free function `resolve-tool-callbacks`,
spread across three call sites: `core/chat/model.lisp` (resolving `:tool-names`
by name), `core/kernel/invoke.lisp` (`resolve-kernel-tools`: the kernel-level
`:tools`), and `core/kernel/chat.lisp` (`kernel-chat`: request-level
`(:tools ...)`).

**Consequence**: Spring's "swap the manager and you change both tool exposure
and execution" is not available here — changing tool exposure means touching
three call sites.

**The gap is narrower than it was**: after the move to filters, "change which
tools this request exposes" has a proper mounting point — `tool-search-filter`
does exactly that, rewriting the prompt options' `:tool-callbacks` on the
`:chat` chain to implement progressive disclosure. Per-tenant filtering of
visible tools is now a `:chat` filter, with no need to promote
`resolve-tool-definitions` to a generic function on the manager. What genuinely
remains missing is only the semantics of "exposure and execution must be decided
by the same object."

### 2. No ToolExecutionExceptionProcessor (deliberate)

Spring makes error handling a standalone functional interface, injected into the
manager as a strategy object:

```java
@FunctionalInterface
public interface ToolExecutionExceptionProcessor {
    String process(ToolExecutionException exception);
}
```

cl-agent has no such seam. Errors are captured in `tool-apply-terminal` into the
`tool-result`'s `:error` plist (`(:class ... :message ...)`), and
`tool-result->text` renders them for the model. To customize, write a `:tool`
filter around it — a filter sees both the request and the response sides, which
is strictly more than a processor that only receives an exception.

(The deleted old chat-level manager did have a counterpart: the generic function
`(process-tool-execution-error manager condition tool-call)`. It went away with
the manager. Its default behaviour — convert the failure to text and hand it back
to the model — is preserved by `tool-result->text`, which is why an unknown tool
name renders as "错误：找不到工具 xxx" rather than a useless placeholder.)

**The cost**: customizing error text has no one-line specialization; it takes a
filter.

### 3. `:environment` does not pause for a human (partial)

Graded retry **is** implemented: `:transient` + a tool declaring `(:retry t)` →
exponential backoff, up to `*transient-retry-attempts*` (default 3), with
`*transient-retry-base-delay*` (default 0.1s) doubling per attempt. Retry is
opt-in per tool because retrying means repeating side effects.

What is **not** implemented is the other half of the matrix: in clj-agent an
`:environment` failure **pauses for human intervention** (an `:env-retry`-class
pause). Here it still just converts to text and goes back to the model.

**Why it is not just "add a branch"**: the approval-class pause implemented here
(`:tool-gate` + `resume-turn`) hooks in *before* the batch runs — no tool has
executed, so the snapshot is trivially consistent. An environment-class pause
hooks in at the **barrier**, after the batch has already executed: some tools
succeeded, one hit a dead dependency. Resuming means re-running only the failed
ones while keeping the successful results — a different snapshot shape from what
`loop-state` carries today.

**Consequence today**: a dead dependency looks like any other error to the model.
It will usually apologise rather than wait for someone to fix the environment.

The classification itself is **accurate** (`classify-tool-error` is covered by
tests); what is missing is the routing from class to action. That is the next
cell on the kernel roadmap.

There is also a precision problem: `tool-apply-terminal` records *every* error
thrown by a tool body as `:semantic`, and `classify-tool-error` is only invoked
**outside the futures of the parallel batch path** — meaning it effectively only
classifies errors that escape from a `:tool` filter (e.g. `timeout-filter`'s
timeout). A `transient-tool-failure` signalled by the tool body itself will not
be recognized as `:transient`. The fix is to route `tool-apply-terminal` through
`classify-tool-error` too.

### 4. Default error semantics differ (language gap, unavoidable)

Spring's `DefaultToolExecutionExceptionProcessor` branches on exception type:

| Exception type | Behavior |
|---|---|
| `RuntimeException` | Convert to text, return to model |
| Checked exception (e.g. `IOException`) | Throw to caller |
| `Error` (e.g. `OutOfMemoryError`) | Throw to caller |

Common Lisp has no notion of checked exceptions, so an exact match is
impossible. cl-agent diverges further still: `tool-apply-terminal` catches
**all** `error`s, so nothing thrown by a tool body ever reaches the caller — it
all becomes text returned to the model. `resolve-callback` extends the same
treatment to `tool-not-found-error`. This is more permissive than Spring, and it
means `Error`-class problems get swallowed silently and treated as something the
model can self-correct. The only condition that escapes the kernel is
`max-tool-iterations-exceeded-error` (loop cap, signalled directly by
`run-tool-loop`). When you need errors to propagate, write a `:tool` filter that
inspects `tool-result-error` and re-signals.

## References

- [Tool Calling in Spring AI 2.0: A Composable, Agentic Architecture](https://spring.io/blog/2026/06/15/spring-ai-composable-tool-calling/)
- [Tool Calling :: Spring AI Reference](https://docs.spring.io/spring-ai/reference/api/tools.html)
- [Recursive Advisors :: Spring AI Reference](https://docs.spring.io/spring-ai/reference/api/advisors-recursive.html)
- [Upgrade Notes :: Spring AI Reference](https://docs.spring.io/spring-ai/reference/upgrade-notes.html)
