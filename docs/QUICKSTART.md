# CL-Agent Quick Start

[中文](QUICKSTART_CN.md)

This guide walks you through CL-Agent. Two ways to use it — pick per need:

- **SimpleAgent** (sections 3–6, recommended starting point): a stateful agent
  object handling the conversation, observability, error normalization and
  human-in-the-loop approval (HITL).
- **ChatClient + Filter** (section 7 onward, full control): the tri-chain onion
  middleware plus the tool loop.

The former is a thin wrapper over the latter — drop down whenever you need to.

## 1. Setup

- SBCL (2.4+ recommended) and Quicklisp

```lisp
(dolist (dir '("." "core/" "llm/" "mock/" "client/"))
  (pushnew (truename dir) asdf:*central-registry* :test #'equal))
(asdf:load-system :cl-agent)
```

### Packages and `:use`

There are only three packages to deal with: `cl-agent/core` (the framework
proper), `cl-agent/client` (SimpleAgent) and `cl-agent/llm` (providers).
**The first two can be `:use`d together directly; no shadowing of any kind is
needed:**

```lisp
(defpackage :my-app
  (:use :cl :cl-agent/core :cl-agent/client))
(in-package :my-app)
```

That is how `examples/chat-client-usage.lisp` and `scripts/live-test.lisp` are
written (they `:use` core only). Not `:use`-ing and fully qualifying every
symbol works too — the rest of this guide qualifies everything.

> The former `cl-agent/http` / `cl-agent/chat` / `cl-agent/chat-client` packages have
> been **merged into `cl-agent/core`**. In old code, rewrite
> `cl-agent/chat-client:build-chat-client`, `cl-agent/chat:deftool` and friends with the
> `cl-agent/core:` prefix; the nicknames `cla/chat-client` / `cla/chat` / `cla/http`
> all collapse into `cla/core`. The merge also eliminated every `:shadow` — any
> older passage telling you to write `:shadowing-import-from` is obsolete.

## 2. Create a ChatModel

```lisp
;; Anthropic (reads ANTHROPIC_API_KEY)
(defvar *model*
  (cl-agent/llm:create-chat-model :anthropic
    :model "claude-sonnet-4-20250514"))

;; Other providers: :openai :zhipu :ollama :dashscope :minimax ...
;; With model-level default options:
(cl-agent/llm:create-chat-model :openai :model "gpt-4o"
  :options (cl-agent/core:make-chat-options :temperature 0.3))

;; No API key? Use the mock provider:
(asdf:load-system :cl-agent-mock)
(defvar *model*
  (cl-agent/core:make-provider-chat-model (cl-agent/mock:make-mock-llm)))
```

### Retries

**Off by default.** Retrying is a ChatModel-layer capability — the provider only
handles low-level details and how to call; whether a failed call is worth
another attempt is an orchestration decision, so the same provider can sit
behind ChatModels with different retry budgets:

```lisp
(cl-agent/llm:create-chat-model :anthropic
  :model "claude-sonnet-4-20250514"
  :retry-policy (cl-agent/core:make-retry-policy
                  :max-attempts 4      ; total attempts, *including* the first
                  :initial-delay 1.0   ; seconds before the first retry
                  :backoff 2.0))       ; multiplier, plus ±10% jitter
```

What counts as retryable is decided by `cl-agent/core:error-retryable-p` alone:
transient HTTP statuses (408/409/425/429/5xx) and network-layer failures are;
auth and argument errors are not. When retries run out the original condition is
rethrown untouched.

> Tokens already handed to a streaming callback cannot be taken back — a stream
> that dies halfway and is retried shows the caller the first part twice. Leave
> `retry-policy` unset on streaming paths.

### Observation

Two levels, with different jobs:

```lisp
;; ChatModel level: wraps one *logical* call (retries included, one entry) — latency
(cl-agent/llm:create-chat-model :anthropic
  :observation-fn (lambda (model prompt thunk)
                    (declare (ignore model prompt))
                    (let ((start (get-internal-real-time)))
                      (prog1 (funcall thunk)
                        (format t "~Dms~%"
                                (round (- (get-internal-real-time) start)
                                       (/ internal-time-units-per-second 1000)))))))

;; Provider level: wraps every *real wire call* (three retries fire it thrice) — cost
(let* ((tally (cl-agent/core:make-llm-usage-tally))
       (cl-agent/core:*llm-call-observer*
         (cl-agent/core:usage-tally-observer tally)))
  (cl-agent/core:chat *chat-client* "Hello")
  (cl-agent/core:usage-tally-output-tokens tally))
```

`*llm-call-observer*` is a dynamic variable — one `let` binding covers **every**
provider.

## 3. First Chat: SimpleAgent

`make-agent` builds a stateful agent, `agent-chat` talks to it — context
accumulates automatically, with no conversation-id to pass around.

```lisp
(defvar *a*
  (cl-agent/client:make-agent
    :model *model*
    :system "You are a concise assistant"))

(cl-agent/client:agent-chat *a* "Hello!")
(cl-agent/client:agent-chat *a* "Describe Common Lisp in one sentence")
(cl-agent/client:agent-chat *a* "Shorter")      ; remembers the previous turn

(cl-agent/client:agent-history *a*)             ; full message history
(cl-agent/client:agent-turn-count *a*)          ; completed turns
(cl-agent/client:agent-reset *a*)               ; clear the session and start over
```

Common `make-agent` arguments:

```lisp
(cl-agent/client:make-agent
  :model *model*                          ; ChatModel (required unless :chat-client is given)
  :system "You are a weather assistant"   ; default system prompt
  :options (cl-agent/core:make-chat-options :temperature 0.3)
  :tools '(get-weather)                   ; tool symbols (section 5)
  :memory store                           ; omitted = a new sliding-window memory; nil = no memory
  :conversation-id "c1"                   ; auto-generated by default
  :max-tool-iterations 10
  :callbacks (list ...)                   ; observability (section 5)
  :chat-client prebuilt-chat-client)                ; your own chat-client (section 7)
```

> **`make-agent` does not accept `:filters`** — passing it **signals an error**
> with migration guidance. The agent layer exposes only `:callbacks`; to mount
> filters, build your own chat-client and pass it via `:chat-client` (section 7). This
> boundary is deliberate: once a simple layer starts forwarding filters, it
> slowly grows into a second chat-client.

### Results and errors: nothing is thrown

`agent-chat` returns `(values nil result)` on error. For the full result use
`agent-chat-result`:

```lisp
(let ((r (cl-agent/client:agent-chat-result *a* "Hello")))
  (cl-agent/client:agent-result-status r))
;; => :completed | :paused | :cancelled | :error
```

| status | Meaning | Where to read it |
|---|---|---|
| `:completed` | Finished normally | `agent-result-text` / `agent-result-response` |
| `:paused` | A tool awaits approval (section 6) | `agent-result-pending-tool` / `agent-result-pause-reason` |
| `:cancelled` | Short-circuited by a filter (e.g. the guard hit a keyword) | — |
| `:error` | LLM / tool / other exception | `agent-result-error` (the condition object) |

A failed LLM call is an **expected, ordinary event** (network hiccups, rate
limits, a model going sideways), so the agent layer normalizes it into a status
instead of throwing the condition at the caller. Neither `agent-chat-result`
nor `agent-resume` ever signals.

## 4. Tool Calling (deftool)

`deftool` mirrors Spring AI's `@Tool` annotation: it defines an ordinary
function while deriving the JSON Schema and registering a ToolCallback.

```lisp
(cl-agent/core:deftool get-weather (&key city (unit "celsius"))
  "Get the current weather for a city"
  (:param city :string "City name" :required t)
  (:param unit :string "Temperature unit")
  (format nil "Weather in ~A: 22°C (~A), sunny" city unit))

;; Still callable as a plain function
(get-weather :city "Tokyo")

;; Hand it to an agent: tools are executed and fed back to the model automatically
(defvar *a*
  (cl-agent/client:make-agent :model *model* :tools '(get-weather)))

(cl-agent/client:agent-chat *a* "What's the weather in Tokyo?")
```

Notes:

- The lambda-list must be `&key`-style (LLM tool arguments are named)
- Tool names become lowercase snake_case: `get-weather` → `"get_weather"`
- A tool's identity is its symbol; reference it as `:tools '(get-weather)`, with
  no global side effects
- `(:return-direct t)` returns the tool result directly to the caller (not fed
  back to the model)
- `(:serial t)` marks the tool as side-effecting: if any tool in a batch
  declares `:serial`, the whole batch degrades to sequential execution
  (the default is parallel)
- Declare a `tool-context` parameter to receive host-injected context:
  `(make-chat-options :tool-context '(:tenant "acme"))`

The tool loop lives in `cl-agent/core:run-tool-loop` — the terminal of the
`:turn` chain. It is not a filter, and it is not inside ChatModel
(`chat-model-call` is single-call semantics). The iteration cap comes from
settings (default 10):

```lisp
(cl-agent/client:make-agent
  :model *model*
  :tools '(get-weather)
  :max-tool-iterations 5)
```

You can also build callbacks at runtime without the macro:

```lisp
(cl-agent/core:make-tool-callback
  (lambda (&key expression) (calc expression))
  :name "calculate"
  :description "Evaluate a math expression"
  :parameters '((expression :string "Expression" :required-p t)))
```

## 5. Observability: callbacks

The agent layer's cross-cutting entry point is `:callbacks` — a plist:

```lisp
(defvar *a*
  (cl-agent/client:make-agent
    :model *model* :tools '(get-weather)
    :callbacks (list :on-turn-start  (lambda (a) (format t "~&start~%"))
                     :on-turn-end    (lambda (a r) (format t "~&done ~A~%"
                                                           (cl-agent/client:agent-result-status r)))
                     :on-turn-error  (lambda (a e) (format t "~&error ~A~%" e))
                     :on-tool-call   (lambda (name args) (format t "~&call ~A ~S~%" name args))
                     :on-tool-result (lambda (name text) (format t "~&result ~A: ~A~%" name text)))))
```

| Callback | Signature | When |
|---|---|---|
| `:on-turn-start` | `(agent)` | Before each turn |
| `:on-turn-end` | `(agent result)` | After a turn ends normally |
| `:on-turn-error` | `(agent condition)` | The turn raised |
| `:on-tool-call` | `(name args)` | **Before** a tool executes (its return value can trigger HITL, section 6) |
| `:on-tool-result` | `(name text)` | After a tool executes |
| `:on-interrupt` | `(agent result)` | The turn paused for approval |
| `:on-resume` | `(agent decision)` | Before `agent-resume` continues |

**A callback throwing does not capsize the turn** — callbacks are observation,
not control flow; the exception is logged and ignored.

## 6. Human Approval (HITL)

**Configure `:on-tool-call` to return `(:interrupt . reason)` and it is on** —
not a separate mechanism, just the callback's return value:

```lisp
(cl-agent/core:deftool rm-file (&key path)
  "Delete a file"
  (:param path :string "File path" :required t)
  (format nil "deleted ~A" path))

(defvar *a*
  (cl-agent/client:make-agent
    :model *model* :tools '(rm-file)
    :callbacks (list :on-tool-call
                     (lambda (name args)
                       (when (string= name "rm_file")
                         (cons :interrupt
                               (format nil "deleting ~A needs approval"
                                       (getf args :path))))))))

(let ((r (cl-agent/client:agent-chat-result *a* "delete /tmp/x.log")))
  (cl-agent/client:agent-result-status r)        ; => :paused
  (cl-agent/client:agent-result-pause-reason r)  ; => "deleting /tmp/x.log needs approval"
  (cl-agent/client:agent-result-pending-tool r)) ; => #<PENDING-TOOL rm_file (:PATH "/tmp/x.log")>
```

**Key invariant: while paused, not a single tool has executed.** Resume once
approved:

```lisp
;; Approve
(cl-agent/client:agent-resume *a* :approved)

;; Edit then approve (execute with new args)
(cl-agent/client:agent-resume *a* :approved :payload '(:args (:path "/tmp/safe.log")))

;; Reject (the reason goes back to the model as the tool result, saving it a round of guessing)
(cl-agent/client:agent-resume *a* :rejected :payload '(:message "no deletes in prod"))

;; Reply-as-result (ask-user semantics: the answer *is* the tool's result)
(cl-agent/client:agent-resume *a* :reply :payload '(:message "that file is already gone"))
```

| decision | Semantics |
|---|---|
| `:approved` | Approve execution; `:payload (:args ...)` rewrites the args first |
| `:rejected` | Do not execute; `(:message reason)` goes back to the model as the tool result |
| `:reply` | Do not execute; `(:message answer)` **is** the tool result (ask-user semantics) |

Inspecting the paused state:

```lisp
(cl-agent/client:agent-paused-p *a*)      ; => t / nil
(cl-agent/client:agent-pending-tool *a*)  ; => the tool-call awaiting approval
```

Resuming may pause **again** (another sensitive tool in the same batch, or a
later iteration triggering it) — loop on the status; do not assume one resume
runs to completion.

## 7. ChatClient: Full Control

When you need filters (memory strategy, guards, RAG, validation …), drop down to
the chat-client. `build-chat-client` assembles, the `chat` macro issues.

The ChatClient has **four slots** (mirroring Spring AI's ChatClient): `model`
(where to call), `filters` (who is on the chain), `default-request` (what a
request looks like by default: system / options / tools), and `tool-calling`
(how the tool loop runs). Deliberately **no** memory slot — memory is a filter,
not an intrinsic property.

`build-chat-client` takes flat arguments and aggregates them into the last two:

```lisp
(defvar *chat-client*
  (cl-agent/core:build-chat-client
    :model *model*                       ; the ChatModel
    :system "You are a weather assistant" ; default system (request-level (:system ...) overrides)
    :options (cl-agent/core:make-chat-options :temperature 0.3)  ; default options
    :tools '(get-weather)                ; default tools (request-level (:tools ...) unions with these)
    :filters (list ...)                  ; cross-cutting concerns (section 8)
    :max-tool-iterations 10              ; tool-loop cap
    :tool-gate nil))                     ; chat-client-level HITL gate (end of this section)

;; Derive a chat-client that differs in one place (mirrors ChatClient#mutate)
(cl-agent/core:chat-client-mutate *chat-client*
  :filters (cons my-filter (cl-agent/core:chat-client-filters *chat-client*)))

;; Swap one item inside the tool-loop config
(cl-agent/core:chat-client-mutate *chat-client*
  :tool-calling (cl-agent/core:tool-calling-config-mutate
                 (cl-agent/core:chat-client-tool-calling *chat-client*)
                 :tool-gate my-gate))
```

All four slots are immutable value objects, so sharing is safe. Read through the
aggregates with the convenience accessors:

```lisp
(cl-agent/core:chat-client-tools *chat-client*)
(cl-agent/core:chat-client-max-tool-iterations *chat-client*)
(cl-agent/core:chat-client-tool-gate *chat-client*)

;; The chat macro: simplest form
(cl-agent/core:chat *chat-client* "Hello!")

;; Full clauses
(cl-agent/core:chat *chat-client*
  (:system "You are a concise assistant")  ; overrides the chat-client's :system
  (:user "Describe Common Lisp in one sentence")
  (:tools 'get-weather)                    ; unioned with the chat-client's :tools
  (:options :temperature 0.2)              ; merged over the chat-client's :options, request-level wins
  (:conversation "c1")                     ; = (:context :conversation-id "c1")
  (:call :content))                        ; :content (default) | :response | :result | :entity
```

> `build-chat-client`'s `:model` is a **keyword** argument, not positional.
> `(build-chat-client :model *model*)` has no filters at all — model call + tool loop
> only.

A chat-client you built can be handed to an agent, buying back session management +
HITL + error normalization:

```lisp
(defvar *memory* (cl-agent/core:make-message-window-chat-memory))
(defvar *chat-client*
  (cl-agent/core:build-chat-client
    :model *model*
    :filters (list (cl-agent/core:memory-filter *memory*))))

(cl-agent/client:make-agent :chat-client *chat-client* :memory *memory*)
```

> When you pass `:chat-client`, mounting the `memory-filter` is **your** job —
> `make-agent` does not touch a prebuilt chat-client's filters. `:memory` merely
> tells the agent where to read `agent-history` from.

There is no Builder — assembling a chat-client *is* `build-chat-client`'s keyword
arguments. The old Builder's three defaults map straight across:

| Old Builder | Where it goes now |
|---|---|
| `default-tools` | `build-chat-client :tools` |
| `default-options` | `build-chat-client :options` (request-level `(:options ...)` merges over it) |
| `default-system` | `build-chat-client :system` (request-level `(:system ...)` overrides it) |

When arguments are assembled programmatically, the function forms are handier
than the macro (which expands into exactly these):

```lisp
(cl-agent/core:chat-client-text *chat-client*
  :system "You are a translator"
  :user (format nil "Translate: ~A" "hello world"))
```

`chat-client-call` returns a `chat-client-response`, `chat-client-text` the text,
`chat-client-entity` parsed JSON, and `chat-client-stream` streams.

### ChatClient-level HITL: tool-gate

The agent HITL of section 6 is a wrapper over this primitive. Using the chat-client
directly:

```lisp
(defvar *chat-client*
  (cl-agent/core:build-chat-client
    :model *model* :tools '(rm-file)
    ;; (tool-call) → :proceed | :pause | (:pause . reason)
    :tool-gate (lambda (tc)
                 (if (string= (cl-agent/core:tool-call-name tc) "rm_file")
                     (cons :pause "deletion needs approval")
                     :proceed))))

(let ((r (cl-agent/core:chat *chat-client* (:user "delete /tmp/x.log") (:call :result))))
  (cl-agent/core:chat-client-response-status r)        ; => :paused
  (cl-agent/core:chat-client-response-pending-tool r)  ; => pending-tool
  (cl-agent/core:chat-client-response-pause-reason r)  ; => "deletion needs approval"
  ;; Resume from the snapshot once approved
  (cl-agent/core:resume-turn *chat-client*
                             (cl-agent/core:chat-client-response-loop-state r)
                             :approved))
```

The gate is evaluated **before** batch execution, **exactly once** per tool-call
in the batch (gates often have side effects — audit logs, approval UI, counters
— so "exactly once" is part of the contract). Any `:pause` verdict pauses the
whole turn with **not one tool executed**.

## 8. Filters: the chat-client's onion chains

A filter is an around-layer of the onion (mirroring Spring AI's Advisor API).
Each filter carries up to four hooks — three chains plus a streaming
transducer:

| Hook | Wraps | Carrier |
|---|---|---|
| `:chat` | one LLM call (every loop iteration) | `prompt` → `chat-response` |
| `:tool` | one tool execution | `tool-request` → `tool-result` |
| `:turn` | one whole turn (the entire tool loop) | `chat-client-request` → `chat-client-response` |
| `:token-xform` | streaming token transformation | `(downstream) → (values emit finish)` |

Every hook is `(lambda (req chain) ...)`: rewrite `req` on the way in, call
`(funcall chain req)` to go downstream, post-process the return value —
**not calling `chain` short-circuits.**

```lisp
(defun timing-filter ()
  (cl-agent/core:make-filter
   :timing
   :turn (lambda (req chain)
           (let ((start (get-internal-real-time)))
             (prog1 (funcall chain req)
               (format t "took ~,2Fs~%"
                       (/ (- (get-internal-real-time) start)
                          internal-time-units-per-second)))))))

(defvar *chat-client*
  (cl-agent/core:build-chat-client
    :model *model*
    :filters (list (timing-filter)
                   (cl-agent/core:safeguard-turn-filter '("password"))
                   (cl-agent/core:logging-chat-filter))
    :tools '(get-weather)))
```

**The `filters` list order is the onion order: earlier = outer = runs first.**
There is no order field; position alone decides the layering. Above, the
layout is `timing → safeguard → run-tool-loop` (the `:turn` chain) and
`logging → chat-model-call` (the `:chat` chain).

Built-in filters:

| Filter | Chain | Purpose |
|---|---|---|
| `(memory-filter store &key window)` | `:chat` | Inject history as messages (mirrors `MessageChatMemoryAdvisor`) |
| `(logging-chat-filter &key log-fn preview)` | `:chat` | Request/response logging |
| `(logging-tool-filter &key log-fn)` | `:tool` | Tool name/args/result logging |
| `(safeguard-turn-filter keywords &key failure-response)` | `:turn` | Sensitive-keyword short-circuit guard |
| `(validation-turn-filter validate-fn &key max-retries)` | `:turn` | Validation failure → feedback re-entry |
| `(re-reading-filter &key template)` | `:turn` | Re2 re-reading prompt rewrite |
| `(qa-turn-filter retriever &key top-k)` | `:turn` | RAG retrieval injection |
| `(tool-search-filter index &key limit)` | `:chat` | Progressive tool disclosure (token savings on large tool sets) |
| `(timeout-filter milliseconds)` | `:tool` | Tool execution timeout |
| `(approval-filter &key approve-fn sensitive-names)` | `:tool` | Approval gate for sensitive tools |
| `(token-redact-filter patterns &key replacement)` | `:token-xform` | Streaming redaction |
| `(hold-release-filter &key approve-fn)` | `:token-xform` | Streaming hold / release |

The `defilter` macro defines a filter class plus its constructor in one form
(hook lambda-lists are `(self req chain)`):

```lisp
(cl-agent/core:defilter counting-filter ((count :initform 0 :accessor fc-count))
  (:turn (self req chain)
    (incf (fc-count self))
    (funcall chain req)))

(make-counting-filter)
```

## 9. Conversation Memory

With SimpleAgent, memory is automatic (a sliding-window memory is created by
default). Using the chat-client directly, memory is a filter mounted on the `:chat`
chain (so it applies on every iteration inside the loop):

```lisp
(defvar *memory* (cl-agent/core:make-message-window-chat-memory
                  :max-messages 20))

(defvar *chat-client*
  (cl-agent/core:build-chat-client
    :model *model*
    :filters (list (cl-agent/core:memory-filter *memory*))))

;; The same :conversation shares memory
(cl-agent/core:chat *chat-client* (:user "My name is David") (:conversation "c1"))
(cl-agent/core:chat *chat-client* (:user "What's my name?") (:conversation "c1"))

;; Inspect / clear
(cl-agent/core:memory-messages *memory* "c1")
(cl-agent/core:memory-clear *memory* "c1")
```

The chat-client itself has **no memory slot** — memory is a filter, not an intrinsic
property of the chat-client.

Custom storage backends implement `repository-find` / `repository-save` /
`repository-delete` / `repository-conversation-ids`.

## 10. Streaming & Structured Output

```lisp
(cl-agent/core:chat *chat-client*
  (:user "Write a short poem")
  (:stream (lambda (delta) (princ delta) (force-output))))

(cl-agent/core:chat *chat-client*
  (:user "Tokyo info as JSON (name/population)")
  (:call :entity))   ; → hash-table
```

> `(:call :entity)` **only parses JSON — it does not validate against a schema
> and does not retry.** It appends a "JSON only" system message, strips
> markdown fences, and calls `json-parse`. There is no schema argument —
> attach `validation-turn-filter` to validate (below).

Use `(:call :result)` when you want whole-turn information such as
`chat-client-response-status`:

```lisp
(let ((result (cl-agent/core:chat *chat-client* (:user "Hi") (:call :result))))
  (values (cl-agent/core:chat-client-response-status result)   ; :completed / :cancelled ...
          (cl-agent/core:chat-client-response-tool-calls-made result)))
```

For "re-prompt the model with the validation errors when the output does not
match the schema" (mirroring Spring AI 2.0's
`StructuredOutputValidationAdvisor`), mount `validation-turn-filter` on the
chat-client — it owns the verdict:

```lisp
(defvar *schema*
  "{\"type\":\"object\",
    \"properties\":{\"name\":{\"type\":\"string\"},
                   \"population\":{\"type\":\"integer\"}},
    \"required\":[\"name\",\"population\"]}")

(defvar *validating-chat-client*
  (cl-agent/core:build-chat-client
    :model *model*
    :filters (list (cl-agent/core:validation-turn-filter
                    ;; verdict fn: (response) → (values ok-p feedback-text)
                    (cl-agent/core:structured-output-validate-fn
                     *schema* :parse-fn #'cl-agent/core:json-parse)
                    :max-retries 2))))

(let ((entity (cl-agent/core:chat *validating-chat-client*
                (:user "Tokyo info as JSON")
                (:call :entity))))
  (gethash "population" entity))
```

`validation-turn-filter` sits on the `:turn` chain: on a mismatch it appends
the feedback text as a user message and **recursively re-enters the whole
loop** (`max-retries` defaults to 2, i.e. at most 3 passes). Once retries are
exhausted the last result is returned as-is — no condition is signalled.
Results with status `:paused` / `:cancelled` / `:error` pass straight through
without re-entry.

Always pass `:parse-fn` to `structured-output-validate-fn` — without a parser
it has no structured value to check and lets everything through.

> **Streaming note**: `(:stream cb)` really streams — both `:chat` filters and
> `:token-xform` apply. It does **not run the tool loop** (single call): a
> streaming request carrying tools signals an error instead of silently dropping
> tool execution, so use `(:call :content)` when you need tools. Providers
> without streaming degrade to one chunk holding the whole text.

## 11. Tests

```bash
# Test suite (all mock, runs offline)
sbcl --non-interactive --load run-tests.lisp

# End-to-end against a real provider (needs an API key)
MINIMAX_API_KEY=... sbcl --script scripts/live-test.lisp
```

`run-tests.lisp` is all mock: offline, deterministic, zero API spend. But a mock
can never prove "will a real model emit tool calls matching our schema", "did
the tool really not execute while paused", or "do real SSE chunks reassemble
correctly" — `scripts/live-test.lisp` covers exactly that gap (single Q&A /
tool loop / multi-turn memory / schema validation / HITL pause·approve·reject /
SSE chunking, 8 checks in total).

## Next

- [API Reference](API.md) — includes the [migration tables](API.md#migration)
- [Tool Calling Architecture](tool-calling.md) — Filter vs. Manager
- [Full examples](../examples/chat-client-usage.lisp) — eight progressive examples, all
  on the mock provider, no API key needed
