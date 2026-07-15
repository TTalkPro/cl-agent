# Tool Calling Architecture: Advisor vs. Manager

[中文](tool-calling_CN.md)

This document explains why tool calling in cl-agent is split into
**ToolCallingAdvisor (the loop)** and **ToolCallingManager (the execution)**,
how those map onto Spring AI 2.0, and where we **deliberately or knowingly**
diverge from the reference implementation.

For the symbol-level quick reference, see the "Tool System" section of the
[API Reference](API.md).

## In one line

**The advisor owns the loop; the manager executes tools.**

```
advisor loop:  call model → tool-calls? → manager runs one round → build next prompt from history → call model again
                                          ↑ this single cell is the manager's entire job
```

The manager returns after one round. It does not know `max-iterations`, does not
know which iteration it is on, and does not decide whether to continue. All of
that lives in the advisor (`core/client/tool-advisor.lisp`).

## Mapping to Spring AI 2.0

| Spring AI 2.0 | cl-agent | Owns loop |
|---|---|---|
| `ToolCallingAdvisor` | `tool-calling-advisor` (`core/client/tool-advisor.lisp`) | **Yes** |
| `ToolCallingManager` | `tool-calling-manager` (`core/chat/tool.lisp`) | No |
| `ToolExecutionResult` | `tool-execution-result` | Result object |
| `ToolExecutionExceptionProcessor` | `process-tool-execution-error` generic function | Error handling |

A naming note: one of Spring AI 2.0's breaking changes renamed 1.1.x's
`ToolCallAdvisor` to `ToolCallingAdvisor`. The 1.1.x javadoc still shows the old
name.

## Why the split exists: the 1.x lesson

In Spring AI 1.x, **every ChatModel implementation carried its own private tool
execution loop** — the official blog's words are "functional, but buried. There
was no way to hook into it." Version 2.0 lifts the tool loop into the advisor
chain as a first-class, composable component, so that other advisors on the
chain (logging, memory, guardrails) can observe and intercept tool calling.

The split yields three execution modes; cl-agent supports all three:

1. **Framework-controlled** — ChatClient auto-registers the advisor; callers do nothing
2. **Advisor-controlled** — construct the advisor explicitly, inject a custom manager
3. **User-controlled** — the caller drives the loop with the manager directly

```lisp
;; 3. User-controlled: the manager used standalone, without any advisor
(let ((mgr (make-default-tool-calling-manager)))
  (loop for response = (chat-model-call model prompt)
        while (chat-response-tool-calls response)
        do (let ((result (execute-tool-calls mgr prompt response)))
             (setf prompt (prompt-copy
                           prompt
                           :messages (tool-execution-conversation-history result))))
        finally (return response)))
```

**That third mode is precisely why the manager must be independent of the
advisor**: it has to work standalone. It also explains the `auto-tool-advisor`
flag on `chat-client` (mirroring
`AdvisorParams.toolCallingAdvisorAutoRegister(false)`) — turning it off puts you
in user-controlled mode.

## The five things the manager does

Given a `chat-response` carrying `tool-calls` (`execute-tool-calls`), it:

1. **Resolves** — finds the callback by name (`find-callback-for-call`, `core/chat/tool.lisp`)
2. **Executes** — calls the callback with args and `tool-context`
3. **Isolates errors** — a throwing tool does not kill the conversation; the
   condition goes through `process-tool-execution-error` and comes back as error
   text returned to the model, which can then self-correct
4. **Assembles conversation history** — `original messages + assistant(tool-calls)
   + tool-response`, i.e. the message list for the next round's prompt
5. **Aggregates return-direct** — set to T if any tool declared `:return-direct`

The returned `tool-execution-result` has exactly two fields:
`conversation-history` and `return-direct`.

### Why it deserves to be a separate abstraction

If this were only "loop over callbacks," a `mapcar` inside the advisor would do.
It exists separately because there are two replaceable seams:

- **Execution strategy** — `default-tool-calling-manager` runs sequentially;
  `concurrent-tool-calling-manager` runs on an lparallel thread pool, which suits
  I/O-bound tool bodies (HTTP / DB). The two are semantically identical (results
  in original order, return-direct unioned, errors isolated the same way), so
  swapping implementations does not touch the loop. The concurrent one falls back
  to `call-next-method` for ≤1 tool call, avoiding pointless thread-pool overhead.
- **Error strategy** — `process-tool-execution-error` is a generic function.
  The default converts to text for the model; specialize it to re-signal instead
  and let errors propagate to the caller.

## A security boundary

`find-callback-for-call` **only consults this request's options; it does not fall
back to the global registry.**

This is deliberate. With a fallback, any `deftool`'d tool would execute as soon as
the model names it — a privilege escalation directly exploitable under prompt
injection. And if `deftool` auto-registered, an author would have no idea their
attack surface had widened.

The reference implementations have no such fallback either: clj-agent's
`find-function` only consults the kernel's `:tool-vars` and throws when it misses;
Spring's `ToolCallbackResolver` is an instance field on the manager, empty by
default.

## Known divergences

### 1. `resolveToolDefinitions` is not on the manager (structural gap)

Spring's manager interface is **bidirectional**:

```java
public interface ToolCallingManager {
    List<ToolDefinition> resolveToolDefinitions(ToolCallingChatOptions chatOptions);  // outbound
    ToolExecutionResult executeToolCalls(Prompt prompt, ChatResponse chatResponse);   // inbound
}
```

cl-agent's `tool-calling-manager` has only the inbound half (`execute-tool-calls`).
Outbound resolution goes through the free function `resolve-tool-callbacks`,
spread across three call sites: `core/chat/model.lisp`,
`core/client/chat-client.lisp`, and `core/client/tool-search-advisor.lisp`.

**Consequence**: Spring's "swap the manager and you change both tool exposure and
execution" is not available here — changing tool exposure means touching three
call sites. No current use case needs it, so it has not been filled in. If one
appears (per-tenant filtering of visible tools, say), promote
`resolve-tool-definitions` to a generic function on the manager.

### 2. ToolExecutionExceptionProcessor folded into the manager (deliberate)

Spring makes it a standalone functional interface, injected into the manager as a
strategy object:

```java
@FunctionalInterface
public interface ToolExecutionExceptionProcessor {
    String process(ToolExecutionException exception);
}
```

cl-agent makes it a three-argument generic function on the manager:

```lisp
(process-tool-execution-error manager condition tool-call)
```

**Rationale**: in CLOS, generic dispatch already replaces the strategy object —
there is no need to invent a class for a one-method interface. We also pass
`tool-call`, which is strictly more information than Spring's exception-only
signature: a specialization can branch per tool name.

### 3. Default error semantics differ (language gap, unavoidable)

Spring's `DefaultToolExecutionExceptionProcessor` branches on exception type:

| Exception type | Behavior |
|---|---|
| `RuntimeException` | Convert to text, return to model |
| Checked exception (e.g. `IOException`) | Throw to caller |
| `Error` (e.g. `OutOfMemoryError`) | Throw to caller |

cl-agent catches `tool-execution-error` / `tool-not-found-error` and converts them
to text; every other condition propagates naturally. The effect is close (serious
errors still propagate), but the classifier is "is this condition type in the
handler-case list" rather than "is it unchecked" — Common Lisp has no notion of
checked exceptions, so this divergence is unavoidable.

## References

- [Tool Calling in Spring AI 2.0: A Composable, Agentic Architecture](https://spring.io/blog/2026/06/15/spring-ai-composable-tool-calling/)
- [Tool Calling :: Spring AI Reference](https://docs.spring.io/spring-ai/reference/api/tools.html)
- [Recursive Advisors :: Spring AI Reference](https://docs.spring.io/spring-ai/reference/api/advisors-recursive.html)
- [Upgrade Notes :: Spring AI Reference](https://docs.spring.io/spring-ai/reference/upgrade-notes.html)
