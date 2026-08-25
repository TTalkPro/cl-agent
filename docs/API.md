# CL-Agent API Reference

[中文](API_CN.md)

API quick reference by package. Spring AI 2.0 counterparts noted per section.

Two entry points:

- **SimpleAgent** (`cl-agent/client`): stateful chat + callbacks + error
  normalization + HITL. See
  [cl-agent/client](#cl-agentclient--simpleagent-stateful-chat--hitl).
- **ChatClient + Filter** (`cl-agent/core`): the `chat` macro / `chat-client-call` →
  `cl-agent/core:invoke-turn` tri-chain. The former is a thin wrapper over the
  latter.

## Packages and `:use`

These are all the packages there are:

| Package | Nickname | Role |
|---|---|---|
| `cl-agent/core` | `cla/core` | The framework proper (one package): infrastructure + HTTP/SSE + JSON Schema + `llm-chat` SPI + Chat API + ChatClient/Filter tri-chain + the `chat` macro |
| `cl-agent/client` | `cla/client` | SimpleAgent |
| `cl-agent/llm` | `cla/llm` | Provider implementations, `create-chat-model` |
| `cl-agent/llm/providers` | — | The nine provider implementations |
| `cl-agent/mock` | `mock` | Mock provider (tests/demos) |

`cl-agent/core` and `cl-agent/client` **share no exported names**. `:use` both
directly; no shadowing of any kind is needed:

```lisp
(defpackage :my-app
  (:use :cl :cl-agent/core :cl-agent/client))
```

This is exactly the `defpackage` used by `examples/chat-client-usage.lisp` and
`scripts/live-test.lisp` (they `:use` core only).

> **The `cl-agent/http` / `cl-agent/chat` / `cl-agent/chat-client` packages have been
> merged into `cl-agent/core`**, and the nicknames `cla/http` / `cla/chat` /
> `cla/chat-client` all collapse into `cla/core`. Before the merge, chat and chat-client
> shared three exported names: `tool-response` / `make-tool-response` (chat's is
> the protocol-level message value object; the chat-client's was the execution-chain
> response carrier) and `execute-tool-calls` (two manager protocols with
> different signatures). That forced the chat-client to `:shadow`, and forced
> downstream packages to write their own `:shadowing-import-from`. Fixed at the
> root: the chat-client carrier was renamed to `tool-request` / `tool-result`, chat's
> old ToolCallingManager was deleted outright, and the three packages were then
> merged. **Every "you must shadowing-import" claim in older docs is obsolete.**
> See [Migration](#migration).
>
> The library is now **shadow-free**: `cl-agent/llm` used to `(:shadow #:chat)`
> because its low-level function collided with core's `chat` macro; that
> function is now `client-chat` and the shadow is gone. You can `:use` any
> combination of this library's packages without name conflicts.

## cl-agent/core — Chat Model API

### Messages (`org.springframework.ai.chat.messages`)

| Symbol | Description |
|---|---|
| `message` | Abstract base; `message-role` / `message-text` / `message-metadata` |
| `(system-message text)` | System instruction |
| `(user-message text)` | User input |
| `(assistant-message text &key tool-calls)` | Model reply; `assistant-tool-calls` |
| `(tool-response-message responses)` | Tool results; `tool-responses` |
| `(make-tool-call &key id name arguments)` | Tool call value object |
| `(make-tool-response &key id name text)` | Tool result value object |
| `message->neutral` / `messages->neutral` | CLOS → neutral plists (provider SPI boundary) |
| `neutral->message` / `neutral->messages` | Reverse conversion |

> This `tool-response` is the **protocol-level** value object (id/name/text) that
> goes inside a role=:tool message sent back to the model. It is a **different
> thing at a different layer** from the chat-client's execution-chain response carrier
> `cl-agent/core:tool-result` (value/writes/error, see
> [Chain carriers](#chain-carriers)) — and the two no longer share a name.

### Prompt / ChatOptions

```lisp
(make-prompt messages &key options system)     ; messages: string/message/list
(prompt-messages prompt) (prompt-options prompt)
(prompt-copy prompt &key messages options)     ; immutable augmentation (filters use this)
(prompt-append-messages prompt new-messages)
(prompt-system-messages p) (prompt-instruction-messages p)
(prompt-last-user-text p)
(prompt-last-user-or-tool-message p)
(prompt-augment-last-user-message p text)
```

```lisp
(make-chat-options :model "..." :temperature 0.3 :max-tokens 1024
                   :top-p 0.9 :top-k 40 :stop-sequences '("END")
                   :frequency-penalty 0.0 :presence-penalty 0.0
                   :thinking '(:enabled :budget-tokens 2048)  ; extended thinking
                   :extra-params '(:seed 42)            ; vendor-specific escape hatch
                   :tool-callbacks (list cb) :tool-names '(get-weather)
                   :tool-context '(:tenant "acme"))
(merge-chat-options runtime defaults)   ; runtime wins; tools are unioned
(copy-chat-options options)
(chat-options-with-tools options callbacks)   ; swap tool-callbacks (used by filters)
;; readers: chat-options-model / -temperature / -max-tokens / -thinking /
;;          -tool-callbacks / -tool-names / -tool-context / ...
```

Options not explicitly passed are "unset" and fall back on merge.

> **Tool-loop options do not live in chat-options.** The iteration cap is a chat-client
> setting: `(build-chat-client :settings '((:max-tool-iterations . 10)))`; the
> continue-or-stop verdict is `:eligibility-fn`. chat-options describes **one**
> model call.

### Extended thinking (`:thinking`)

Mirrors Spring AI's `ThinkingConfigParam`. A neutral spec that each provider
translates into its own wire format:

```lisp
:thinking :disabled                      ; {"type":"disabled"}
:thinking :adaptive                      ; {"type":"adaptive"} — model decides
:thinking '(:adaptive :display :omitted)
:thinking '(:enabled :budget-tokens 2048)
:thinking '(:enabled :budget-tokens 2048 :display :omitted)
:thinking <hash-table>                   ; sent verbatim (escape hatch)
```

- `:budget-tokens` must be **>= 1024 and less than `:max-tokens`** (thinking counts
  towards `max-tokens`). Violations signal `invalid-thinking-config-error` while
  building the request rather than shipping it for a bare 400.
- `:display` is `:summarized` (default) or `:omitted`. `:omitted` redacts the
  thinking text but **still returns the signature**, so multi-turn tool-calling
  continuity is preserved.
- Unset means the field is omitted entirely; the server default applies.
- Implemented by the Anthropic-family providers (`anthropic` / `minimax`); other
  providers ignore it.

> MiniMax M-series models always reason, and thinking counts toward output
> tokens. Use `:thinking :disabled` to cut output cost or turn thinking off.

### ChatResponse

```lisp
(chat-response-text r)             ; text of the first generation
(chat-response-message r)          ; assistant-message
(chat-response-tool-calls r) (chat-response-has-tool-calls-p r)
(chat-response-finish-reason r)    ; :stop/:tool-call/:max-tokens/...
(chat-response-usage r)            ; llm-usage
(chat-response-generations r)
(chat-response-metadata-of r)      ; id/model/usage/raw
(llm-response->chat-response llm-response)
```

### Tools (`@Tool` / `ToolCallback`)

```lisp
(deftool name (&key args...)
  "description for the model"
  (:param name type "description" [:required t] [:default v])*
  [(:return-direct t)]
  body...)
;; Generates a plain function plus a tool-callback stored on the SYMBOL.
;; No global side effect — a tool's identity IS its symbol:
;;   (chat chat-client (:user "...") (:tools 'get-weather))
;; Type keywords: :string :number :integer :boolean :array :object
;; Mirrors clj-agent, where deftool emits a defn with the schema in var
;; metadata and tools are passed explicitly: (build-chat-client {:tools [#'foo]}).
;; A Clojure var carries metadata; the CL equivalent is the symbol plist —
;; #'get-weather is a bare function object with no schema, so it cannot be
;; used as a tool reference.

(make-tool-callback fn :name "n" :description "d"
                    :parameters '((p :string "desc" :required-p t))
                    :return-direct nil)
(tool-callback-call callback args-plist &optional tool-context)
(tool-callback->schema callback)
(tool-callback-name cb) (tool-callback-definition cb)
(tool-callback-return-direct-p cb) (tool-callback-serial-p cb) (tool-callback-retry-p cb)
(symbol-tool-callback 'get-weather) ; the callback deftool put on the symbol
(resolve-tool-callbacks specs)      ; instances/symbols/strings
(arguments->plist raw)              ; hash-table/JSON/plist normalization

;; Global registry: an opt-in escape hatch, only for resolving tools by
;; *string* name (config-driven setups). deftool does not write to it; empty
;; by default.
(register-tool-callback (symbol-tool-callback 'get-weather))
(find-tool-callback "get_weather")  ; registry only — not deftool's path
(unregister-tool-callback "get_weather")
```

**Tool resolution** (the chat-client's batch / manager / tool-search filter depend on
this):

```lisp
(find-callback-for-call options tool-call)   ; one tool-call → callback
;; Resolves by name using ONLY the tools exposed in this request's options;
;; signals tool-not-found-error if absent. It deliberately does NOT fall back
;; to the global registry — that is the prompt-injection / privilege-escalation
;; boundary: a tool the model was not given is never executed.
```

> Models hallucinate tool names routinely. The chat-client's `batch.lisp`
> catches `tool-not-found-error` and turns it into a `:semantic` error
> `tool-result`, which `tool-result->text` renders as "错误：找不到工具 xxx" and
> feeds back to the model so it can self-correct — the condition does not escape
> `(chat ...)` and kill the turn. The security boundary is unchanged: an
> unexposed tool is still never executed.

Conditions: `tool-execution-error`, `tool-not-found-error`,
`max-tool-iterations-exceeded-error`.

> **Chat's old ToolCallingManager is deleted entirely**: `tool-calling-manager`,
> `default-tool-calling-manager`, `concurrent-tool-calling-manager`,
> `execute-tool-calls` (the `(manager prompt response)` arity),
> `tool-execution-result`, `process-tool-execution-error`,
> `with-concurrent-tool-calling-manager` and friends no longer exist. Tool
> execution lives ONLY in the chat-client layer: `run-tool-loop` +
> `invoke-tool-batch` + the three
> [ToolCallingManagers](#toolcallingmanager-implementations). The
> "user-controlled" path — call `chat-model-call` yourself and drive the loop
> with `execute-tool-calls` — is gone; the chat-client is the only path.
>
> `*inherited-special-variables*` / `with-inherited-specials` did not belong to
> the deleted manager: they still live in `core/utils.lisp`, sharing one list
> with the HTTP async requests. Take them from `cl-agent/core`.

### ChatModel protocol

```lisp
(chat-model-call model prompt)              ; prompt: string/messages/prompt
(chat-model-stream model prompt on-chunk)   ; on-chunk: (delta-text); real SSE
(chat-model-default-options model)
(make-provider-chat-model provider :default-options options)
```

The ChatModel makes a **single** model call — it resolves tool references and
injects schemas but never executes tools. Responses carrying tool calls are
returned as-is; the loop belongs to `cl-agent/core:run-tool-loop` (the terminal
of the `:turn` chain).

### ChatMemory

```lisp
(memory-add memory conversation-id messages)
(memory-messages memory conversation-id)
(memory-clear memory conversation-id)
(make-message-window-chat-memory :repository repo :max-messages 20)

;; Storage protocol (implement for custom backends)
(repository-find repo cid) (repository-save repo cid messages)
(repository-delete repo cid) (repository-conversation-ids repo)
(make-in-memory-chat-memory-repository)
+default-conversation-id+   ; "default"
```

Window truncation is pairing-safe: system messages are kept and don't count;
orphaned leading tool messages are dropped.

Memory is **not** a chat-client field — attach it as a filter:
`(cl-agent/core:memory-filter memory)`.

## cl-agent/core — ChatClient + Filter tri-chain (execution core)

Three onion chains, each with its own carriers and terminal:

| Chain | Hook slot | Request → response | Terminal |
|---|---|---|---|
| `:chat` | `filter-chat-hook` | `prompt` → `chat-response` | `chat-model-call` |
| `:tool` | `filter-tool-hook` | `tool-request` → `tool-result` | tool execution |
| `:turn` | `filter-turn-hook` | `turn-request` → `turn-result` | `run-tool-loop` |
| `:token-xform` | `filter-token-xform` | `(downstream) → (values emit finish)` | streaming token flow |

```
invoke-turn → [:turn filters] → run-tool-loop
  ├── invoke-chat → [:chat filters] → chat-model-call
  ├── tool calls present and eligible → invoke-tool-batch → [:tool filters] → tool
  │     append messages → repeat
  └── otherwise → turn-result(:completed)
```

### Filter (mirrors `CallAdvisor` / `AdvisorChain`)

```lisp
(make-filter name &key chat tool turn token-xform)   ; generic factory
(filter-name f)
(filter-chat-hook f) (filter-tool-hook f) (filter-turn-hook f) (filter-token-xform f)
```

**Every hook is `(lambda (req chain) ...)`**:

- going in: rewrite `req`
- `(funcall chain req)`: go downstream (inner filters, ultimately the terminal)
- coming out: post-process the result
- **not calling `chain` = short-circuit** (that is exactly what
  `safeguard-turn-filter` does)
- calling `chain` more than once = recursive re-entry of the whole downstream
  chain (that is how `validation-turn-filter` retries)

Hooks you don't supply are `nil`, and `build-chain` skips that filter when
building the corresponding chain — one filter may serve several chains, or just one.

```lisp
;; all four hook slots are optional
(cl-agent/core:make-filter
 :timing
 :turn (lambda (req chain)
         (let ((start (get-internal-real-time)))
           (prog1 (funcall chain req)
             (format t "took ~,2Fs~%"
                     (/ (- (get-internal-real-time) start)
                        internal-time-units-per-second))))))
```

### defilter macro

```lisp
(defilter name (slot-defs...)
  [(:chat (self req chain) body...)]
  [(:tool (self req chain) body...)]
  [(:turn (self req chain) body...)]
  [(:token-xform xform-form)])
;; expands to: (defclass name (filter) slots...) + a make-name constructor
;; (&rest initargs passed through to make-instance).
;; Hook lambda-list is (SELF REQ CHAIN); SELF is the filter instance (captured).
```

```lisp
(defilter counting-filter ((count :initform 0 :accessor cf-count))
  (:turn (self req chain)
    (incf (cf-count self))
    (funcall chain req)))

(make-counting-filter)
```

### build-chain — the onion fold

```lisp
(build-chain filters hook-key terminal)   ; → (lambda (req) ...) → resp
;; filters   filter instances; earlier = outer = runs first
;; hook-key  accessor function, e.g. #'filter-chat-hook; filters whose hook is
;;           nil are skipped automatically
;; terminal  innermost one-arg function (req) → resp
```

`reverse` + `reduce` nests the hooks. Each closure holds **only what is
downstream** — upstream can never be re-run, and recursive re-entry is free.

> **The filters list order IS the onion order: earlier = outer = runs first.**
> Filters have no order field.

### Chain carriers

```lisp
;; Tool chain
(make-tool-request function &key args context)
(tool-request-function r)   ; tool-callback instance or deftool symbol
(tool-request-args r)       ; argument plist
(tool-request-context r)    ; tool context plist

(make-tool-result &key value writes error)
(tool-result-value r)       ; the tool's return value
(tool-result-writes r)      ; state-write intents plist (see ":writes state folding")
(tool-result-error r)       ; (:class :semantic|:transient|:environment :message "...") or nil

(tool-result->text r)       ; → text sent back to the model; error results
                            ; render as "错误：<message>"

;; Turn chain
(make-turn-request messages &key context resume-p)
(turn-request-messages r) (turn-request-context r) (turn-request-resume-p r)

(make-turn-result status &key response tool-context tool-calls-made
                              loop-state pending-tool pause-reason)
(turn-result-status r)          ; :completed | :paused | :cancelled | :error
(turn-result-response r)        ; final chat-response (nil on error)
(turn-result-tool-context r)    ; final context after folding every batch's :writes
(turn-result-tool-calls-made r) ; tool-call count for this turn
;; Set only when :paused (see "HITL: pause and resume")
(turn-result-loop-state r)      ; resume snapshot, fed to resume-turn
(turn-result-pending-tool r)    ; the tool awaiting approval (name/args/id)
(turn-result-pause-reason r)    ; the reason text the gate supplied
```

> The `:chat` chain has **no** wrapper carrier: the request is a
> `cl-agent/core:prompt` and the response is a `chat-response`.
>
> Naming: `tool-request` → `tool-result` is symmetric with the turn chain's
> `turn-request` → `turn-result`. `tool-result` was once called `tool-response`
> (initarg `:result`, reader `tool-response-result`), which collided with
> `cl-agent/core:tool-response` — a protocol-level value object at a different
> layer. The rename removed the collision.

### ChatClient

```lisp
(build-chat-client &key model tools filters eligibility-fn settings tool-manager
                   system options tool-gate state-slots loop-fn resume-fn)
;; model          chat-model instance
;; tools          list of tool symbols or tool-callbacks (default nil)
;; filters        list of filter instances (order = onion order; default nil)
;; eligibility-fn (response context) → boolean — should tool iteration continue?
;;                (default (constantly t))
;; settings       config alist, e.g. '((:max-tool-iterations . 10))
;; tool-manager   ToolCallingManager instance; nil = the invoke-tool-batch path
;; system         default system prompt; a request-level (:system ...) overrides it
;; options        default chat-options; a request-level (:options ...) merges over it
;; tool-gate      the approval gate (HITL): (tool-call) → :proceed | :pause
;;                | (:pause . reason); nil (default) = no approval, all execute
;; state-slots    state-slot declarations ((key :init v0 :reduce fn) ...) —
;;                merge semantics for tool-batch :writes (see below)
;; loop-fn        custom tool loop: (chat-client turn-request) → turn-result;
;;                nil (default) = run-tool-loop. It IS the :turn chain's
;;                terminal — replacing it replaces the whole loop skeleton
;; resume-fn      custom pause continuation:
;;                (chat-client loop-state decision payload) → turn-result;
;;                nil (default) = the built-in one. Pairs with loop-fn

(chat-client-model k) (chat-client-tools k) (chat-client-filters k)
(chat-client-eligibility-fn k) (chat-client-settings k) (chat-client-tool-manager k)
(chat-client-default-system k) (chat-client-default-options k) (chat-client-tool-gate k)
(chat-client-state-slots k) (chat-client-loop-fn k) (chat-client-resume-fn k)
```

### :loop-fn / :resume-fn — swapping the loop skeleton

`run-tool-loop` is the **default** terminal of the `:turn` chain, not a fixed
one. `:loop-fn` replaces it wholesale, which is how you get a different loop
shape (ReAct, plan-execute, reflexion) without touching the chains: `:turn`
filters still wrap it, `:chat` / `:tool` filters still apply to whatever it
invokes.

```lisp
(build-chat-client :model m
              :loop-fn (lambda (chat-client turn-request) ... ))   ; → turn-result
```

**HITL is opt-in for a custom loop.** The built-in pause continuation reads the
`loop-state` snapshot that `run-tool-loop` produces; it cannot understand a
different loop's pause point. So a custom loop that wants pause/resume must
supply `:resume-fn` as well — the two are a pair. A custom loop that never
returns `turn-result(:paused)` simply never reaches the resume path, so
omitting `:resume-fn` costs a capability rather than breaking behaviour.

Leaving both unset is the default path, byte-for-byte unchanged.

### :writes state folding (the tool-batch MapReduce contract)

The context a tool sees during a parallel batch is a **read-only snapshot** —
mutating it directly would race. Write intents are declared through the return
value; once the whole batch has collected (the barrier), they fold into the
context in the **original tool-call order**, so the actual parallel
interleaving never affects the merged result:

```lisp
;; a tool declares writes via (values result writes-plist)
(deftool take-note (&key text)
  "Take a note"
  (:param text :string "content" :required t)
  (values (format nil "noted: ~A" text)
          (list :notes (list text))))      ; write intent: takes no effect here

;; :state-slots declares the merge semantics
(build-chat-client :model m :tools '(take-note)
              :state-slots (list (list :notes :init nil
                                       :reduce (lambda (old new)
                                                 (append old new)))))

;; one batch of take-note("a") take-note("b") → barrier fold → (:notes ("a" "b"))
;; next-round tools see the folded snapshot via tool-context;
;; (turn-result-tool-context result) hands the final state back to the caller
```

Rules:
- a slot with `:reduce` folds through it (`:init` supplies the old value when
  the context has none)
- undeclared slots are **last-writer** — later writes win, deterministic by
  call order
- a key written ≥2 times in one batch with no reducer triggers a `log-warn`
- **writes of a failed call (error non-nil) never take effect** (transactional)
- HITL resume folds the same way: the calls that actually ran commit their
  writes; rejected/replied ones have none

Low-level primitives (rarely needed directly):

```lisp
(apply-writes context writes-seq &optional slots)
;; → (values new-context conflict-keys); pure, does not mutate its arguments
(fold-batch-writes chat-client tool-results context)
;; → new-context; skips failed calls' writes, warns on conflicts
```

The chat-client is minimal: **no memory field** — memory is a filter, not an intrinsic
property of the chat-client.

> **There is no Builder.** Assembling a chat-client *is* `build-chat-client`'s keyword
> arguments — the old Builder's `default-system` / `default-options` /
> `default-tools` map to `:system` / `:options` / `:tools`.

How the two levels combine:

| Item | ChatClient level | Request level | Combination |
|---|---|---|---|
| system | `build-chat-client :system` | `(:system ...)` | request **overrides** |
| options | `build-chat-client :options` | `(:options ...)` | request **wins**; untouched defaults survive |
| tools | `build-chat-client :tools` | `(:tools ...)` | **union** |

### HITL: pause and resume (chat-client primitive)

`:tool-gate` is the low-level primitive behind human approval
(`cl-agent/client`'s [SimpleAgent HITL](#human-approval-hitl) wraps it).

```lisp
(build-chat-client
  :model *model* :tools '(rm-file)
  ;; (tool-call) → :proceed | :pause | (:pause . reason)
  :tool-gate (lambda (tc)
               (if (string= (tool-call-name tc) "rm_file")
                   (cons :pause "deletion needs approval")
                   :proceed)))
```

The gate runs **before** batch execution, **exactly once** per tool-call in the
batch — gates often have side effects (audit logs, approval UI, counters), so
"exactly once" is part of the contract. Any `:pause` verdict pauses the whole
turn: **not one tool executes**, and `run-tool-loop` returns
`turn-result(:paused)`.

```lisp
(resume-turn chat-client loop-state decision &key payload)
;; loop-state  (turn-result-loop-state r) from the paused turn-result
;; decision    :approved | :rejected | :reply
;; payload     :approved + (:args new-args) → edit-then-approve (run with new args)
;;             :rejected + (:message reason) → "rejected: <reason>" goes back to the model
;;             :reply    + (:message answer) → the answer **is** that tool's result
;;                                             (ask-user semantics; the tool never runs)
;; → same shape as invoke-turn: :completed, or :paused **again** (another sensitive
;;   tool in the batch, or a later iteration tripping the gate)
```

`resume-turn` also goes through the `:turn` filter chain — filters such as
validation must be able to act on the resumed result.

Pause carriers:

```lisp
(make-loop-state &key messages response tool-calls pending-id
                      iteration options context)
(loop-state-messages ls)    ; messages at pause time (no assistant/tool results yet)
(loop-state-response ls)    ; the assistant response that triggered the pause
(loop-state-tool-calls ls)  ; every tool-call in the batch — **none executed**
(loop-state-pending-id ls)  ; id of the tool-call the gate paused on
(loop-state-iteration ls)   ; which iteration paused (resume keeps counting)
(loop-state-options ls) (loop-state-context ls)

(make-pending-tool &key name args id)
(pending-tool-name p) (pending-tool-args p) (pending-tool-id p)
```

`loop-state` deliberately holds **no** chat-client / gate / callbacks — those are
code-side things, re-supplied at resume; this class carries only the data
needed to continue.

### The chat macro — declarative request DSL (the caller's entry point)

```lisp
(chat chat-client
  [(:system text [format-args...])]
  [(:user text [format-args...])]
  [(:messages msg...)]
  [(:options :temperature 0.7 ...)]     ; or (:options <a chat-options instance>)
  [(:tools tool...)]
  [(:context key value)]
  [(:conversation cid)]
  [(:call :content | :response | :result | :entity)]   ; default (:call :content)
  [(:stream callback)])

(chat chat-client "Hi")   ; shorthand for (chat chat-client (:user "Hi"))
```

Terminal operations:

| Terminal clause | Returns |
|---|---|
| `(:call :content)` (default) | the reply text (a string) |
| `(:call :response)` | a `chat-response` instance |
| `(:call :result)` | a `turn-result` instance (use it to inspect `turn-result-status`) |
| `(:call :entity)` | the reply parsed as JSON (**parses only, does not validate**) |
| `(:stream fn)` | calls `(fn delta)` per text delta; returns the final `chat-response` |

- `(:tools ...)` are **request-level** tools, **unioned** with `build-chat-client`'s
  `:tools`.
- `(:conversation id)` ≡ `(:context :conversation-id id)`; `memory-filter` reads it.
- `(:options ...)` with a single non-keyword argument is treated as a ready-made
  `chat-options` instance; otherwise the arguments pass through to
  `make-chat-options`.

```lisp
(chat *chat-client*
  (:system "You are a weather assistant")
  (:user "What's the weather in ~A?" city)   ; extra args → format
  (:tools 'get-weather)
  (:conversation "conv-1"))
```

### Function-form entry points

Handier than the macro when arguments are assembled programmatically:

```lisp
(chat-client-call chat-client &key system user messages options tools context)  ; → turn-result
(chat-client-text chat-client &rest args)                                  ; → text
(chat-client-entity chat-client &rest args)                                ; → JSON value (parse only)
(chat-client-stream chat-client on-chunk &rest args)                       ; → chat-response
```

`args` are `chat-client-call`'s keyword arguments. The `chat` macro expands into
exactly these four functions.

```lisp
(chat-client-text k
                  :system "You are a translator"
                  :user (format nil "Translate ~S into French" "hello, world")
                  :options (make-chat-options :temperature 0.1))
```

- `messages` are spliced after `system` and before `user`.
- `system`/`user`/`messages` must together yield **at least one non-system
  message**, or the call errors immediately — a system-only request is meaningless
  to the model, and failing early beats a cryptic provider 400.

### (:call :entity) — parses only, does not validate

Appends a "JSON only" system instruction → takes the text back →
`strip-json-fences` → `json-parse`. **No schema validation, no retry** (there is
no schema parameter).

```lisp
(cl-agent/core:strip-json-fences text)   ; strip ```json ... ``` fences; usable on its own
```

To get "re-prompt the model with the validation error until it complies", attach a
`validation-turn-filter` to the chat-client — it owns the verdict:

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
                    (cl-agent/core:structured-output-validate-fn
                     *schema* :parse-fn #'cl-agent/core:json-parse)
                    :max-retries 2))))

(cl-agent/core:chat *validating-chat-client*
  (:user "Give me Tokyo's info as JSON")
  (:call :entity))
```

> **Streaming**: `(:stream fn)` / `chat-client-stream` go through
> `invoke-chat-stream` — the `:chat` filter chain applies as usual and the
> `:token-xform` pipeline is assembled inside the streaming terminal. Two limits:
> - **No tool loop** (it is a single streaming call). A request that would send
>   tools to the model **signals an error** rather than silently dropping tool
>   execution; use `chat-client-call` when you need tools.
> - If the provider has no streaming, `chat-model-stream` degrades to a one-shot
>   call and the whole text arrives as a single chunk (`:token-xform` still runs).

### Invoke primitives

```lisp
(invoke-chat chat-client prompt)          ; :chat chain → chat-model-call. Single call,
                                     ; executes no tools
                                     ; → (values chat-response effective-prompt)
                                     ; The 2nd value is the prompt **as rewritten by
                                     ; the :chat chain**: tool execution must use the
                                     ; options the model actually saw, else filter-
                                     ; injected tools (e.g. tool-search's search_tools)
                                     ; come back as "tool not found"
(invoke-chat-stream chat-client prompt on-token)
                                     ; :chat chain → chat-model-stream; the
                                     ; :token-xform pipeline is assembled inside the
                                     ; terminal → chat-response
                                     ; Single call — does NOT run the tool loop
(invoke-tool chat-client tool-request)    ; :tool chain → tool execution → chat-client:tool-result
(invoke-tool-batch chat-client tool-calls options context)
                                     ; → (values tool-results return-direct-p)
                                     ; parallel by default (lparallel); if any tool
                                     ; in the batch declares :serial the whole batch
                                     ; goes sequential; errors are classified/routed
(invoke-turn chat-client turn-request)    ; :turn chain → run-tool-loop → turn-result
(run-tool-loop chat-client turn-request)  ; the loop itself (terminal of the :turn chain,
                                     ; NOT a filter)
(resume-turn chat-client loop-state decision &key payload)
                                     ; resume from a pause (see "HITL: pause and resume")
```

Each `run-tool-loop` iteration: build a prompt (messages + chat-client tools, merged
with the caller's options) → `invoke-chat` → if the response has tool calls and
`eligibility-fn` says continue → execute tools → append the assistant(tool-calls)
message and the tool-result message → next iteration; otherwise return
`turn-result(:completed)`.

- The cap comes from settings `:max-tool-iterations` (default 10); exceeding it
  signals `cl-agent/core:max-tool-iterations-exceeded-error`
- `:return-direct` tools: when the whole batch declares it, the loop short-circuits
  and the tool output becomes the final answer without going back to the model
- A non-nil `chat-client-tool-manager` routes execution through `execute-tool-calls`;
  otherwise `invoke-tool-batch` is used
- A hallucinated tool name does not break the loop: `batch.lisp` turns
  `tool-not-found-error` into a `:semantic` error result, which
  `tool-result->text` renders as "错误：找不到工具 xxx" and feeds back to the
  model to self-correct
- When `chat-client-tool-gate` is non-nil, every batch passes the gate **before**
  execution; a `:pause` verdict returns `turn-result(:paused)` with not one tool
  executed (see [HITL: pause and resume](#hitl-pause-and-resume-chat-client-primitive))

### ToolCallingManager implementations

Mirrors Spring's `ToolCallingManager` — it promotes the *execution entry point* to
an injectable protocol. Loop control, eligibility and the `:tool` filter chain all
stay on the chat-client side; the manager only picks the scheduling strategy. This is
the project's **only** ToolCallingManager (chat's old one is deleted).

```lisp
(cl-agent/core:execute-tool-calls manager chat-client response options)
;; options plist: (:tool-context ctx ...)
;; → tool-execution-result plist: (:messages ... :records ... :context ... :errors ...)
(make-tool-execution-result &key messages records context errors)

(make-sequential-tool-calling-manager)        ; fully serial (debugging/strict side effects)
(make-virtual-thread-tool-calling-manager)    ; parallel default, respects :serial
(make-thread-pool-tool-calling-manager &optional (pool-size 4))  ; thread pool (rate limiting)
(default-tool-calling-manager)                ; = virtual-thread
```

> There is only one signature now: `(manager chat-client response options)`.
> The pre-merge `cl-agent/chat` once had a same-named generic function taking
> `(manager prompt response)`, which forced the chat-client to `shadow` the symbol;
> that layer is deleted, so `execute-tool-calls` now belongs solely to
> `cl-agent/core`.
>
> `thread-pool-tool-calling-manager` currently behaves exactly like
> virtual-thread (lparallel is already pool-backed); `pool-size` does not yet bind
> a dedicated chat-client.

### Failure classification

```lisp
(classify-tool-error condition)  ; → :semantic | :transient | :environment
;; condition hierarchy
tool-failure                     ; tool-failure-class / tool-failure-message
semantic-tool-failure            ; model's fault (bad args/logic) → no retry
transient-tool-failure           ; transient (timeout/rate limit/503/429) → backoff retry
environment-tool-failure         ; environment (service down/permissions) → needs a human
```

Rules: subclasses of `tool-failure` yield their `:class` directly; everything else
is classified heuristically from the error message (timeout/connection refused/
429/503 → `:transient`; permission denied/unauthorized/forbidden →
`:environment`); the conservative fallback is `:semantic` (no retry).

Batch routing (`invoke-tool-batch`) — **all three classes currently take the same
action**:

| Class | Tool declares `:retry` | Actual action |
|---|---|---|
| `:semantic` | any | Feed the error text back to the model (loop continues) |
| `:transient` | `t` | **Exponential-backoff retry**, up to `*transient-retry-attempts*` (default 3) |
| `:transient` | `nil` | Feed the error text back to the model |
| `:environment` | any | Feed the error text back to the model (see divergence below) |

Retry knobs (both are `defparameter`s on `cl-agent/core`):

| Variable | Default | Meaning |
|---|---|---|
| `*transient-retry-attempts*` | 3 | Max attempts **including** the first |
| `*transient-retry-base-delay*` | 0.1 | Backoff base in seconds: attempt *n* waits `base * 2^(n-1)` |

Retry is **opt-in per tool** — only a tool declaring `(:retry t)` is ever retried.
Retrying means repeating side effects, so the framework never decides that for
the tool author.

> **Known divergence:** `:environment` still only converts to text. In clj-agent
> it pauses for a human (an `:env-retry`-class pause). HITL's approval-class pause
> is implemented here (`:tool-gate` + `resume-turn`); the environment-class one is
> not — it needs to hook in at the barrier (after the whole batch) rather than at
> tool resolution. See [Tool Calling Architecture](tool-calling.md).

### Built-in filters (10 kinds)

```lisp
;; 1. memory-filter (:chat) — mirrors MessageChatMemoryAdvisor
(memory-filter store &key (window 20))
;; store = a chat-memory instance. The conversation key is :conversation-id read
;; from the prompt options' tool-context; without one the filter passes straight
;; through (reads nothing, records nothing).
;; Per LLM call: store the delta messages, replace prompt messages with the full
;; history, then store the reply.
;; **Deliberately inside the loop** (Spring puts it outside): every round lands a
;; complete transcript. Register it first so other filters see the full history.

;; 2. logging-chat-filter (:chat) — mirrors SimpleLoggerAdvisor
(logging-chat-filter &key log-fn (preview 100))
;; log-fn  (lambda (msg) ...); defaults to log-info. preview = truncation length

;; 3. logging-tool-filter (:tool)
(logging-tool-filter &key log-fn)
;; logs the tool name plus result/error

;; 4. safeguard-turn-filter (:turn) — mirrors SafeGuardAdvisor
(safeguard-turn-filter keywords &key (failure-response "抱歉，无法处理该请求。"))
;; Inbound messages hitting a keyword (case-insensitive) → chain is never called;
;; returns turn-result(:cancelled). Short-circuiting at the :turn layer means the
;; :chat memory filter never runs — neither the blocked input nor the refusal is
;; persisted. Only inbound messages are scanned; use :token-xform for the output side.

;; 5. validation-turn-filter (:turn) — mirrors StructuredOutputValidationAdvisor
(validation-turn-filter validate-fn &key (max-retries 2))
;; validate-fn  (response) → (values ok-p feedback)
;; On failure the feedback is appended as a user message and (chain req) is called
;; again — re-entering the entire loop so the model can self-correct.
;; max-retries defaults to 2 (at most 3 passes).
;; Hard rule: :paused/:cancelled/:error results pass through without re-entry;
;; once retries are exhausted the last result is returned as-is.
(structured-output-validate-fn schema &key parse-fn)  ; → validate-fn
;; schema    JSON Schema (hash-table / plist / string)
;; parse-fn  e.g. #'cl-agent/core:json-parse; default nil = no structured value
;;           to judge, so everything passes
;; Verdict order: empty text → fail; no parse-fn → pass; parse-fn present but
;; parsing fails → fail; parsed → validate against the schema, feeding each error back
(cl-agent/core:strip-json-fences text)  ; strip ```json ... ``` fences

;; 6. re-reading-filter (:turn) — mirrors ReReadingAdvisor (RE2)
(re-reading-filter &key template)
;; template  (lambda (text) → new-text); default repeats the question once
;; Rewrites only the last inbound user message; skipped when :resume-p

;; 7. qa-turn-filter (:turn) — mirrors QuestionAnswerAdvisor
(qa-turn-filter retriever &key (top-k 4) inject-when-empty template)
;; retriever          implements (retrieve retriever query &key top-k) → list of strings
;; inject-when-empty  inject even when retrieval is empty (default nil = don't)
;; template           (lambda (query docs) → new-text); default Q&A template
(defgeneric retrieve (retriever query &key top-k))   ; you implement it; no retrieval dep
;; Injected once per turn: take the last inbound user question → retrieve → splice
;; into the messages. Nothing is injected when retrieval is empty (a deliberate
;; divergence from Spring's strict grounding semantics).

;; 8. tool-search-filter (:chat) — mirrors ToolSearchToolCallingAdvisor
(tool-search-filter index &key (limit 5))
(defgeneric search-tools (index query &key limit))   ; → list of tool-callbacks
(make-keyword-tool-index tools)                      ; zero-dep keyword index (CJK bigram)
;; Each round it rewrites the tools exposed to the model to
;; [search_tools] + whatever this conversation has already discovered.
;; **The first round carries a single schema (search_tools)** — that is where the
;; token saving comes from. The model calls search_tools(query) → retrieval →
;; the hits are recorded for this conversation → next round it can call them.
;; search_tools is created and injected by the filter — do NOT add it to :tools.
;; The discovered set is isolated per conversation-id.
;;
;; Measured (MiniMax, 12 tools): first round 1 vs 12; 13 vs 24 schemas over the
;; whole turn — 46% saved. The more tools, the bigger the saving.

(build-chat-client :model m
              :tools '(get-weather get-stock send-mail ...)   ; the full set
              :filters (list (tool-search-filter
                              (make-keyword-tool-index
                               '(get-weather get-stock send-mail ...)))))

;; 9. timeout-filter (:tool)
(timeout-filter milliseconds)
;; Runs the tool on a separate bordeaux-threads thread; on timeout returns a
;; tool-result with (:error (:class :transient ...)), which can trigger :retry

;; 10. approval-filter (:tool)
(approval-filter &key approve-fn sensitive-names)
;; approve-fn       (tool-name args) → (values approved-p reason);
;;                  defaults to reading y/n from stdin
;; sensitive-names  tool names requiring approval; default nil = approve everything
;; Rejected → returns tool-result(value=rejection text) without executing; the
;; text goes back to the model

;; 11. token-xform (:token-xform — transducer style (rf) → rf', not an around chain)
(token-redact-filter patterns &key (replacement "***"))  ; per-token redaction (stateless)
(hold-release-filter &key approve-fn)                    ; buffers every token, then at
;; end of stream (approve-fn full-text) → approved emits it all at once / rejected
;; emits the refusal text
```

> `:token-xform` is assembled inside the streaming terminal — it does **not** go
> through `build-chain`.

## cl-agent/client — SimpleAgent (stateful chat + HITL)

The application-facing convenience layer: a stateful agent object that handles
the conversation, observability, error normalization and human approval. It is a
thin wrapper over the chat-client — `agent-chat` ultimately lands on `chat-client-call`.

The agent **does not store history itself**: history is still managed by core's
`memory-filter` keyed by conversation-id; the agent only holds the
conversation-id plus lightweight control state.

### make-agent

```lisp
(make-agent &key model system options tools memory conversation-id
                 callbacks chat-client settings)
;; model           chat-model instance (required unless :chat-client is given)
;; system          default system prompt
;; options         default chat-options
;; tools           list of tool symbols
;; memory          chat-memory store; omitted = a new sliding-window memory;
;;                 nil = no memory (each turn independent)
;; conversation-id conversation ID (auto-generated by default)
;; callbacks       callback plist (below)
;; settings        chat-client settings alist, e.g. '((:max-tool-iterations . 10))
;; chat-client          prebuilt chat-client (use this when you need filters)

(agent-id a) (agent-chat-client a) (agent-memory a) (agent-conversation-id a)
(agent-callbacks a) (agent-turn-count a)
```

> **This layer does not accept `:filters`** — passing it **signals an error**
> with migration guidance rather than silently ignoring it. The agent exposes
> only `:callbacks`; to mount filters, build your own chat-client and pass it via
> `:chat-client`. The boundary is deliberate: once a simple layer starts forwarding
> filters it slowly grows into a second chat-client — exactly how the ChatClient this
> repo just deleted rotted.
>
> When you pass `:chat-client`, mounting the `memory-filter` is **the caller's** job
> (`make-agent` does not touch a prebuilt chat-client's filters); `:memory` merely
> tells the agent where to read `agent-history` from.

Thread safety: a single agent instance **must not** be driven by concurrent
`agent-chat` calls. Each agent is bound to one conversation thread; for
concurrency, create one agent per conversation (they can share one persistent
store and stay isolated by `:conversation-id`).

### Chatting

```lisp
(agent-chat agent message &key options tools)
;; → reply text; on error → (values nil result)
(agent-chat-result agent message &key options tools)  ; → agent-result (**never signals**)
(agent-history agent)      ; → message list (nil when there is no memory)
(agent-reset agent)        ; clear the conversation
```

### agent-result (normalized; signals nothing)

```lisp
(agent-result-status r)        ; :completed | :paused | :cancelled | :error
(agent-result-text r)          ; reply text when :completed
(agent-result-response r)      ; chat-response
(agent-result-error r)         ; the condition object when :error
(agent-result-pending-tool r)  ; the tool awaiting approval when :paused
(agent-result-pause-reason r)  ; why it paused
```

| status | Meaning |
|---|---|
| `:completed` | Finished normally |
| `:paused` | A tool awaits approval (`:on-tool-call` returned `:interrupt`) |
| `:cancelled` | Short-circuited by a filter (e.g. safeguard hit a keyword) |
| `:error` | LLM / tool / other exception |

> Core's `chat` macro signals on error; the agent layer normalizes that into a
> result object. Rationale: the agent is the application-facing entry point, and
> a failed LLM call is an **expected** everyday event (network hiccups, rate
> limits, a model going sideways) — the caller should get a status, not be
> capsized by a condition.

### callbacks

```lisp
(make-agent :model m :tools '(get-weather)
            :callbacks (list :on-turn-start  (lambda (agent) ...)
                             :on-turn-end    (lambda (agent result) ...)
                             :on-turn-error  (lambda (agent condition) ...)
                             :on-tool-call   (lambda (name args) ...)
                             :on-tool-result (lambda (name text) ...)
                             :on-interrupt   (lambda (agent result) ...)
                             :on-resume      (lambda (agent decision) ...)))
```

| Callback | Signature | When |
|---|---|---|
| `:on-turn-start` | `(agent)` | Before each turn |
| `:on-turn-end` | `(agent result)` | After a turn ends normally |
| `:on-turn-error` | `(agent condition)` | The turn raised |
| `:on-tool-call` | `(name args)` | **Before** a tool executes; its return value can trigger HITL (below) |
| `:on-tool-result` | `(name text)` | After a tool executes |
| `:on-interrupt` | `(agent result)` | The turn paused for approval |
| `:on-resume` | `(agent decision)` | Before `agent-resume` continues |

**A callback throwing does not capsize the turn** — callbacks are observation,
not control flow; the exception is logged and ignored. Even if `:on-tool-call`
throws, it is treated as "no opinion" (proceed).

Internally: `:on-tool-result` is bridged to a `:tool` filter (a result only
exists after execution), and `:on-tool-call` is bridged to the chat-client's
`tool-gate` (it must be able to veto **before** execution).

### Human approval (HITL)

**Configure `:on-tool-call` to return `(:interrupt . reason)` and it is on** —
not a separate mechanism, just the callback's return value:

```lisp
(make-agent :model m :tools '(rm-file)
            :callbacks (list :on-tool-call
                             (lambda (name args)
                               (when (string= name "rm_file")
                                 (cons :interrupt
                                       (format nil "deleting ~A needs approval"
                                               (getf args :path)))))))
```

`:on-tool-call`'s return value → the gate's verdict:

| Return value | Verdict |
|---|---|
| `nil` / anything else | Proceed |
| `:interrupt` | Pause for approval (no reason) |
| `(:interrupt . reason)` or `(:interrupt reason)` | Pause, carrying the reason |

```lisp
(agent-paused-p agent)      ; → t / nil
(agent-pending-tool agent)  ; → the tool-call awaiting approval (nil when not paused)

(agent-resume agent decision &key payload)   ; → agent-result (**never signals**)
;; :approved  approve. payload (:args new-args) → edit-then-approve (run with new args)
;; :rejected  reject.  payload (:message reason) → "rejected: <reason>" back to the model
;; :reply     reply-as-result (ask-user semantics). payload (:message answer) is
;;            **required** → the pending tool never runs; the answer is its result
```

**Key invariant: while paused, not a single tool has executed.** Resuming may
pause **again** (another sensitive tool in the batch, or a later iteration
tripping the gate) — loop on the status; do not assume one resume runs to
completion.

Calling `agent-resume` while not paused signals an error (check
`agent-paused-p` first).

## Migration

### Package merge (`cl-agent/http` / `/chat` / `/chat-client` → `cl-agent/core`)

The three packages have been merged into a single `cl-agent/core`. A mechanical
rename, one for one:

| Old | New |
|---|---|
| `cl-agent/chat-client:X` | `cl-agent/core:X` |
| `cl-agent/chat:X` | `cl-agent/core:X` |
| `cl-agent/http:X` | `cl-agent/core:X` |
| nicknames `cla/chat-client` / `cla/chat` / `cla/http` | `cla/core` |
| `cl-agent/chat-client:build-chat-client` | `cl-agent/core:build-chat-client` |
| `cl-agent/chat:deftool` | `cl-agent/core:deftool` |
| `cl-agent/http:http-request` | `cl-agent/core:http-request` |
| any `:shadowing-import-from` incantation | **no longer needed** — delete it |

Code written against the old package names hits
`Package CL-AGENT/CHAT-CLIENT does not exist` immediately.

### Migrating from ChatClient

**The ChatClient porting layer is deleted** — it was a port of Spring AI's
ChatClient + Builder + fluent RequestSpec. Builders and chained specs are a Java
idiom; in Lisp, `build-chat-client`'s keyword arguments plus the declarative `chat`
macro cover the same ground with one layer less.

> **Note: the package name `cl-agent/client` has been reused.** It used to be
> the ChatClient porting layer (deleted); it is **now SimpleAgent** (see
> [cl-agent/client](#cl-agentclient--simpleagent-stateful-chat--hitl)). The
> package and the name are still there, but what is inside is a completely
> different thing — not one of the old ChatClient symbols remains.

These symbols **no longer exist**:
`make-chat-client`, `chat-client-builder`,
`default-system`, `default-options`, `default-tools`, `build-client`,
`client-prompt`, `prompt-system`, `prompt-user`, `prompt-add-messages`,
`prompt-with-options`, `prompt-tools`, `prompt-context`, `prompt-conversation`,
`call-client-response`, `call-response`, `call-content`, `call-entity`,
`stream-content`, `client-request`, `client-response`, `make-client-request`,
`make-client-response`, `context-get`, `context-set`, `client-chat-client`,
`client-default-system`, `client-default-options`, `client-default-tools`.

> The porting layer also had a class called `chat-client`, deleted along with the
> rest. **That name was later reused**: today's `cl-agent/core:chat-client` is
> this framework's core class (formerly `kernel`) and has nothing to do with the
> porting layer's class of the same name.

The `chat` macro **survived** — the syntax is unchanged, the symbol just comes
from `cl-agent/core` now.

For the "stateful conversation, one object holding the session" feel (the common
ChatClient usage), use
[SimpleAgent](#cl-agentclient--simpleagent-stateful-chat--hitl) now:
`(make-agent :model m :system "..." :tools '(...))` + `(agent-chat a "...")`.

| Old (ChatClient porting layer, deleted in v9.0.0) | New (ChatClient core) |
|---|---|
| `(make-chat-client model)` | `(build-chat-client :model model)` — `:model` is a **keyword** argument, not positional |
| `(chat client ...)` | `(chat chat-client ...)` — clauses unchanged |
| fluent spec (`client-prompt` → `prompt-user` → `call-content`) | `chat` macro clauses, or the `chat-client-text` function forms |
| `(call-content spec)` | `(:call :content)` / `chat-client-text` |
| `(call-response spec)` | `(:call :response)` |
| `(call-client-response spec)` | `(:call :result)` → a `turn-result` (the `client-response` carrier is gone) |
| `(call-entity spec :schema s)` | `(:call :entity)` / `chat-client-entity` — **no schema parameter**; attach `validation-turn-filter` to validate |
| `(stream-content spec fn)` | `(:stream fn)` / `chat-client-stream` |
| `(prompt-context spec k v)` | `(:context k v)` |
| `(prompt-conversation spec id)` | `(:conversation id)` |
| `default-tools` (Builder) | `build-chat-client :tools` (request-level `(:tools ...)` unions with it) |
| `default-options` (Builder) | `build-chat-client :options` (request-level `(:options ...)` merges over it) |
| `default-system` (Builder) | `build-chat-client :system` (request-level `(:system ...)` overrides it) |
| `client-request` / `client-response` / `context-get` / `context-set` | `turn-request` / `turn-result` + `turn-request-context` (a plist) |

### Migrating from `chat-client:tool-response` (carrier rename)

The chat-client tool chain's response carrier was renamed to `tool-result`, symmetric
with the turn chain's `turn-request` / `turn-result`, which also removed the
collision with the protocol-message-layer `tool-response` (once that collision
was gone, the three packages could be merged).

| Old (gone) | New |
|---|---|
| `cl-agent/chat-client:tool-response` (the class) | `cl-agent/core:tool-result` |
| `cl-agent/chat-client:make-tool-response` | `cl-agent/core:make-tool-result` |
| `(make-tool-response :result X)` | `(make-tool-result :value X)` — **the initarg changed from `:result` to `:value`** |
| `tool-response-result` | `tool-result-value` |
| `tool-response-writes` | `tool-result-writes` |
| `tool-response-error` | `tool-result-error` |

`tool-request` / `make-tool-request` / `tool-request-function` /
`tool-request-args` / `tool-request-context` are **unchanged** (the prefix
becomes `cl-agent/core:`). `cl-agent/core:tool-result->text` is a new export.

> **Do not confuse the two**: `cl-agent/core:tool-response` /
> `make-tool-response` / `tool-response-message` / `tool-response-text` **still
> exist** — that is the **protocol-message-layer** value object (id/name/text)
> that goes inside a role=:tool message back to the model, a different thing at a
> different layer from the chat-client's `tool-result` (value/writes/error). It lived
> in `cl-agent/chat` before the merge and now shares `cl-agent/core` with
> `tool-result`; since they no longer share a name, both coexist.

### Migrating from chat's ToolCallingManager (deleted)

These pre-merge `cl-agent/chat` symbols **no longer exist**: `tool-calling-manager`,
`default-tool-calling-manager`, `make-default-tool-calling-manager`,
`execute-tool-calls` (the `(manager prompt response)` arity),
`execute-one-tool-call`, `process-tool-execution-error`,
`concurrent-tool-calling-manager`, `make-concurrent-tool-calling-manager`,
`manager-pool-size`, `manager-timeout`, `manager-inherit-specials`,
`shutdown-tool-calling-manager`, `with-concurrent-tool-calling-manager`,
`tool-execution-result`, `tool-execution-conversation-history`,
`tool-execution-return-direct-p`, `tool-execution-last-message`.

| Old (chat-level manager) | New (chat-client) |
|---|---|
| `(make-default-tool-calling-manager)` | `(make-sequential-tool-calling-manager)` |
| `(make-concurrent-tool-calling-manager :pool-size 4)` | `(make-thread-pool-tool-calling-manager 4)` |
| parallel default | `(make-virtual-thread-tool-calling-manager)` = `(default-tool-calling-manager)` |
| `(execute-tool-calls mgr prompt response)` | `(execute-tool-calls mgr chat-client response options)` |
| driving the loop yourself: `chat-model-call` + `execute-tool-calls` | `(chat chat-client ...)` / `chat-client-call` — the chat-client is the only path |
| `(shutdown-tool-calling-manager mgr)` / `with-concurrent-tool-calling-manager` | not needed — chat-client managers hold no pool requiring explicit release |
| `tool-execution-conversation-history` / `-last-message` / `-return-direct-p` | `turn-result-response` / `turn-result-tool-context`; at the manager layer, `make-tool-execution-result`'s `:messages` |
| specializing `process-tool-execution-error` | a `:tool` filter, or read `tool-result-error`'s `:class` |
| `:inherit-specials` / `manager-inherit-specials` | `cl-agent/core:with-inherited-specials` + `*inherited-special-variables*` |

> **Note**: `cl-agent/core` now also exports a `default-tool-calling-manager`, but
> it is a **zero-argument factory function** (returning a virtual-thread manager),
> unrelated to the deleted chat-level **class** of the same name.

## cl-agent/llm — Providers

```lisp
(create-chat-model :anthropic :model "..." :api-key "..." :options opts)
;; providers: :anthropic :openai :zhipu :deepseek :gemini :mistral
;;            :ollama :dashscope :minimax (aliases google/qwen/bailian/claude/glm...)
```

DeepSeek prefix completion (beta):

```lisp
;; The last assistant message is the prefix; the model continues from it
;; (pair it with :stop)
(cl-agent/llm/providers:deepseek-prefix-chat provider
  (list (list :role :user :content "Write a line of poetry")
        (list :role :assistant :content "The spring wind"))
  :max-tokens 256)
```

Provider SPI for custom providers:

```lisp
(defmethod cl-agent/core:llm-chat ((p my-provider) messages
                                   &key max-tokens temperature model tools system)
  ;; messages are neutral plists (:role :user :content "...")
  ;; return a cl-agent/core:llm-response
  ...)
```

## cl-agent/mock — Test Support

```lisp
(cl-agent/mock:make-mock-llm)   ; rule-based responses, no API key
(cl-agent/mock:make-quick-mock :smart)
;; wrap with (make-provider-chat-model (make-mock-llm)) for full-stack demos
```
