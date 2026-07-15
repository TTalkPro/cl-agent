# Refactoring Plan: cl-agent Advisor → Kernel+Filter (Spring AI 2.0 full alignment)

## 0. Executive summary

cl-agent v8.0.0 implements Spring AI 2.0 via a **single onion Advisor chain** where the tool loop *is* an advisor (`tool-calling-advisor`) that re-enters its downstream chain, and `ToolCallingManager` executes one batch. The target is clj-agent's **kernel + three-chain filter** model: a minimal kernel (`invoke-chat`/`invoke-tool`/`invoke-turn`), three onion chains (`:tool`/`:chat`/`:turn`) assembled at three call sites, the loop as a plain function wrapped by the `:turn` terminal, memory *inside* the loop at `:chat`'s first position, and no `ToolCallingManager` (split into `execute-batch` + per-tool `:serial`).

The migration builds the new kernel+filter system **adjacent** to the advisor system, keeps the public `chat` macro / `ChatClient` behavior-equivalent via a bridge, and retires the advisor API only at the end. **Baseline: 715 checks (SBCL + CCL).** Each phase is additive-green.

## 1. Architecture mapping (current → target)

| Concept | cl-agent today | Target (clj-agent style) |
|---|---|---|
| Core abstraction | `advisor` + `advisor-chain` (single chain, numeric `order`) | `kernel` + `filter` (three chains, registration order) |
| Chain fold | `make-advisor-chain` / `chain-next` (advisor.lisp) | `build-chain` (reduce → nested closures) |
| Loop | `tool-calling-advisor` re-enters downstream (tool-advisor.lisp) | `run-tool-loop` plain fn = `:turn` terminal (NOT a filter) |
| Batch tool exec | `execute-tool-calls` on `ToolCallingManager` (tool.lisp) | `invoke-tool-batch` + `:serial` declaration |
| Memory | `message-chat-memory-advisor`, order 1000, **outside** loop by default | `memory-filter`, `:chat` chain **first position, inside loop** |
| Safeguard | `safe-guard-advisor`, order -500 | `safeguard-turn-filter`, `:turn` outermost |
| Logger | `simple-logger-advisor` | `logging-chat-filter` + `logging-tool-filter` |
| Structured output | `structured-output-validation-advisor` (loop-internal) | `validation-turn-filter` (`:turn`) + structured-output criteria |
| ToolSearch | `tool-search-tool-calling-advisor` (subclass of loop) | `tool-search` filter (`:chat`) + `search_tools` tool |
| Recursive re-entry | not directly supported | free via closure chain (multi `chain` call) |
| Failure routing | `process-tool-execution-error` (text to model) | 3 classes + barrier routing + `:retry` |
| Filter definition | `defadvisor` (class + `advise-call` method) | `defilter` (class + `:tool`/`:chat`/`:turn` hooks) or factory fn |

## 2. DECISION POINTS (need confirmation before execution)

- **DP1 — Ordering model.** clj-agent dropped numeric `order` in favor of **registration order**. cl-agent's current advisor system uses numeric `order` + constants. **Recommendation:** follow clj-agent — registration order, drop numeric order.
- **DP2 — End-state of `chat` macro / `ChatClient`.** **(A)** keep `chat`/`ChatClient` as public DSL, reimplemented on kernel+filter; **(B)** deprecate them. **Recommendation: (A)** — `chat` is a good CL-idiomatic DSL; kernel+filter is the lower-level assembly.
- **DP3 — Memory default behavior shift.** Current default stores only final Q&A (memory outside loop). Target stores full transcript per round (memory inside loop). This is a **real behavior change**. **Recommendation:** shift the default; re-baseline the memory tests in P4.
- **DP4 — Package placement.** **Recommendation:** new `cl-agent.kernel` package under `core/kernel/`; `cl-agent.chat` and `cl-agent.client` stay.
- **DP5 — Streaming.** clj-agent's `:token-xform` is a transducer. cl-agent's `advise-stream` currently threads an `on-chunk` callback. **Recommendation:** port `:token-xform` as a transducer; full streaming parity lands in P4/P5.

## 3. Preserve-unchanged components

| Component | Location | Why preserved |
|---|---|---|
| Message hierarchy | `core/chat/message.lisp` | CLOS messages + neutral-plist SPI boundary |
| Prompt | `core/chat/prompt.lisp` | immutable enhanced-copy; reused inside `chat-request` |
| ChatOptions | `core/chat/options.lisp` | merge semantics; carries tools |
| ChatResponse / Generation | `core/chat/response.lisp` | provider-agnostic response |
| ChatModel protocol | `core/chat/model.lisp` | single-call semantics preserved — loop stays OUT |
| `llm-chat` SPI + `llm-response` | `core/llm/*` | provider-neutral |
| Providers | `llm/providers/*`, `llm/stream/*` | 9 providers + SSE; untouched |
| HTTP/SSE infra | `core/http/*` | untouched |
| `deftool` / `ToolCallback` | `core/chat/tool.lisp` | tool identity = symbol; only `ToolCallingManager` removed |
| ChatMemory protocol + window | `core/chat/memory.lisp` | store protocol; memory *filter* wraps it |
| Conditions (`cl-agent-error` tree) | `core/conditions.lisp` | reused; new tool-failure conditions added |

## 4. CL-specific implementation design

### 4.1 Filter — CLOS class with per-chain hooks

```lisp
(defclass filter ()
  ((name        :initarg :name        :reader filter-name)
   (tool        :initarg :tool        :initform nil :reader filter-tool-hook)
   (chat        :initarg :chat        :initform nil :reader filter-chat-hook)
   (turn        :initarg :turn        :initform nil :reader filter-turn-hook)
   (token-xform :initarg :token-xform :initform nil :reader filter-token-xform)))
```

A filter may carry any subset of hooks (multi-chain). Filters with private state are CLOS instances with that state as a slot.

### 4.2 `build-chain` — direct reduce port

```lisp
(defun build-chain (filters hook-key terminal)
  (reduce (lambda (downstream f)
            (lambda (req) (funcall (funcall hook-key f) req downstream)))
          (reverse filters)
          :initial-value terminal))
```

`chain` is naturally "downstream-only" → recursive re-entry is free.

### 4.3 `defilter` macro — mirrors `defadvisor`

```lisp
(defmacro defilter (name (&rest slots) &body hooks)
  ;; (:chat (req chain) ...) / (:tool ...) / (:turn ...) / (:token-xform xform)
  ;; → defclass + make-NAME factory
  ...)
```

### 4.4 Kernel — CLOS class, NO memory, NO loop

```lisp
(defclass kernel ()
  ((model          :initarg :model          :reader kernel-model)
   (tools          :initarg :tools          :initform nil)
   (filters        :initarg :filters        :initform nil)
   (eligibility-fn :initarg :eligibility-fn :initform (constantly t))
   (settings       :initarg :settings       :initform nil)))
```

### 4.5 Three invoke primitives

```lisp
(defun invoke-chat (kernel chat-request)   ; :chat terminal = chat-model-call
  (funcall (build-chain (kernel-filters kernel) #'filter-chat-hook
                        (lambda (req) (chat-llm-terminal kernel req)))
          chat-request))

(defun invoke-tool (kernel tool-request)   ; :tool terminal = apply tool fn
  (funcall (build-chain (kernel-filters kernel) #'filter-tool-hook
                        (lambda (req) (tool-apply-terminal kernel req)))
          tool-request))

(defun invoke-turn (kernel turn-request)   ; :turn terminal = run-tool-loop
  (funcall (build-chain (kernel-filters kernel) #'filter-turn-hook
                        (lambda (req) (run-tool-loop kernel req)))
          turn-request))
```

### 4.6 Carriers — reuse + minimal new

Reuse `client-request`/`client-response` as `chat-request`/`chat-response`. Add: `tool-request` (`:function :args :context`), `tool-response` (`:result :writes :error`), `turn-request` (`:messages :context :resume-p`), `turn-result` (`:status :response :tool-context`).

### 4.7 Condition system — three failure classes + restarts

```lisp
(define-condition tool-failure (error) ((class :reader tool-failure-class)))
(define-condition semantic-tool-failure    (tool-failure) ())
(define-condition transient-tool-failure   (tool-failure) ())
(define-condition environment-tool-failure (tool-failure) ())

;; Barrier routing: :transient + :retry → backoff; :environment + :pause → HITL; default → text to model
```

## 5. The 5 phases (TDD, atomic-commit, green at every step)

**Baseline: 715 checks (SBCL + CCL), 0 skip, 0 fail.**

### PHASE P1 — Filter mechanism + Kernel skeleton (additive foundation)

**Goal:** onion filter mechanism + kernel CLOS skeleton as pure, un-integrated machinery. Advisor system untouched.

**TDD sequence (each = 1 commit):**
1. `build-chain` onion ordering test → implement `build-chain` + `filter` class
2. Short-circuit test (filter doesn't call `chain`)
3. Around-with-shared-state test
4. Recursive re-entry test (validation filter calls `chain` twice)
5. Multi-chain hook selection test
6. `kernel` class + `build-kernel` smoke test

**Files:**
- New: `core/kernel/package.lisp`, `core/kernel/filter.lisp`, `core/kernel/carriers.lisp`, `core/kernel/kernel.lisp`
- Modify: `core/cl-agent-core.asd`
- New tests: `tests/test-filter.lisp`, `tests/test-kernel-skeleton.lisp`

**Verification:** 715 + ~40-60 new checks. No integration.

---

### PHASE P2 — invoke-chat / invoke-tool / invoke-turn + run-tool-loop

**Goal:** three invoke primitives assemble three chains; `run-tool-loop` is the `:turn` terminal. Kernel works end-to-end with mock provider.

**TDD sequence:**
1. `invoke-chat` bare LLM call (mock model, no filters)
2. `:chat` filter applied (logging) → order verified
3. `invoke-tool` single tool (no filters)
4. `invoke-tool-batch` parallel default (spec only; full routing is P3)
5. `run-tool-loop`: 1 tool round-trip (mock → tool-call → result → final)
6. `invoke-turn`: wrap loop with `:turn` filter
7. **Loop equivalence test:** same mock script through `invoke-turn` (new) vs `tool-calling-advisor` (old) → identical `chat-response`

**Files:**
- New: `core/kernel/loop.lisp`; expand `core/kernel/kernel.lisp`
- New tests: `tests/test-kernel-invoke.lisp`, `test-kernel-loop.lisp`, `test-kernel-turn.lisp`

**Verification:** 715 + new. **Equivalence anchor** proves new and old produce identical results.

---

### PHASE P3 — Tool execution split + failure model

**Goal:** dismantle `ToolCallingManager` semantics *in new kernel only*. Add `:serial`, `:return-direct`, `:eligibility-fn`, three failure classes + barrier routing.

**TDD sequence:**
1. `:serial` slot on `tool-callback`/`tool-definition`; `deftool` accepts `(:serial t)`
2. `invoke-tool-batch` parallel-by-default
3. `:serial` degradation: one `:serial` tool → whole batch sequential
4. `:return-direct`: result is final answer; whole-batch semantics; multi-result concatenation
5. `:return-direct` persistence knife: history contains `user → assistant(tool_calls) → tool(results)`
6. `:eligibility-fn`: returns false → tools not executed
7. Three failure classes: `classify-tool-error` unit tests
8. Barrier routing: `:transient` + `:retry` → backoff; `:environment` + `:pause` → pause; default → text to model

**Files:**
- New: `core/kernel/conditions.lisp`, `core/kernel/batch.lisp`
- Modify: `core/chat/tool.lisp` (add `:serial`/`:retry`), `core/kernel/loop.lisp`
- New tests: `tests/test-kernel-batch.lisp`, `test-kernel-failures.lisp`, `test-tool-declarations.lisp`

**Verification:** 715 + new. Old `ToolCallingManager` untouched until P5.

---

### PHASE P4 — Built-in filters + memory placement migration + ChatClient bridge

**Goal:** all 10 filter types as native filters; `chat` macro gains kernel-backed path (bridge); memory moves to `:chat` first position **inside** loop. **This is the behavior-shift phase.**

**TDD sequence (filters):**
1. `memory-filter` (`:chat`, first, inside loop) — behavior shift test
2. `logging-chat-filter` + `logging-tool-filter`
3. `safeguard-turn-filter` (`:turn`, case-insensitive)
4. `validation-turn-filter` + structured-output criteria (`:turn`)
5. `re-reading-filter` (`:turn`, skips on `:resume-p`)
6. `qa-turn-filter` (RAG, `:turn`, `IRetriever`)
7. `tool-search` filter (`:chat`) + `search_tools` + `IToolIndex`
8. `timeout-filter` + `approval-filter` (`:tool`)
9. `token-xform` filters: `token-redact-filter`, `hold-release-filter`

**Bridge:**
10. `chat-client` kernel-backed path behind flag
11. **Equivalence harness:** run old advisor tests through *both* paths; assert identical `chat-response` (modulo documented memory-transcript shift)

**Files:**
- New: `core/kernel/filters/{memory,logging,safeguard,validation,re-reading,rag,tool-search,timeout,approval,token-xform}.lisp`; `core/kernel/retriever.lisp`
- Modify: `core/client/chat-client.lisp` (add kernel-backed path)
- New tests: per-filter tests + `test-kernel-client-bridge.lisp` + `test-advisor-kernel-equivalence.lisp`

**Verification:** 715 (advisor path) + new filter tests + equivalence harness green. Memory tests re-baselined.

**P4 is the long phase** — flag for ultrawork scheduling.

---

### PHASE P5 — Retire advisor API + full alignment audit + cleanup

**Goal:** remove advisor system + `ToolCallingManager`; flip default to kernel+filter; sync docs; alignment audit.

**TDD sequence:**
1. Flip `make-chat-client` / `chat` default to kernel-backed; harness green
2. Delete advisor files + `ToolCallingManager` from tool.lisp
3. Delete/adapt old advisor tests
4. Alignment audit test: all 10 filter types present + smoke-invokable
5. Update README, docs, examples

**Files:**
- Delete: `core/client/advisor.lisp`, `tool-advisor.lisp`, `tool-search-advisor.lisp`, `structured-output-advisor.lisp`; manager portions of `tool.lisp`
- Modify: chat-client.lisp, package.lisp, asd files, README, docs, examples
- New tests: `tests/test-spring-ai-alignment.lisp`

**Verification:** Final regression. Public `chat` macro behavior equivalent. All 10 filter types present.

## 6. Final API form (target end-state)

```lisp
;; ---- build a kernel (no :memory field — memory is a filter) ----
(defparameter *kernel*
  (build-kernel
    :model *model*
    :tools '(get-weather save-note handoff)
    :filters (list (memory-filter *memory*)                     ; :chat, FIRST, inside loop
                   (safeguard-turn-filter '("bomb" "hack"))     ; :turn, outermost guard
                   (qa-turn-filter *retriever* :top-k 4)        ; :turn, inject once per turn
                   (validation-turn-filter                       ; :turn, recursive re-entry retry
                     (structured-output:validate-fn schema))
                   (timeout-filter 5000)                         ; :tool
                   (logging-tool-filter)                         ; :tool
                   (logging-chat-filter :preview 200))           ; :chat
    :eligibility-fn (lambda (resp ctx) t)))

;; ---- low-level invoke ----
(invoke-turn *kernel* (make-turn-request :messages (list (user-message "..."))
                                          :context ctx))

;; ---- high-level DSL preserved, reimplemented on kernel ----
(chat *client* (:user "...") (:tools 'get-weather) (:conversation "c1"))

;; ---- custom filter (multi-chain) ----
(defilter timing-filter ()
  (:chat (req chain)
    (let ((start (get-internal-real-time)))
      (prog1 (funcall chain req)
        (format t "chat: ~,2Fs~%" (/ (- (get-internal-real-time) start)
                                     internal-time-units-per-second)))))
  (:tool (req chain)
    (format t "tool ~A~%" (tool-request-name req))
    (funcall chain req)))
```

## 7. Risks & mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Memory placement shift breaks downstream | High | DP3 explicit; re-baseline in P4; equivalence harness isolates |
| Registration vs numeric order (DP1) | Medium | Decide upfront; 1-line diff to switch |
| `:serial` / failure routing has no precedent | Medium | New kernel only; old manager untouched until P5 |
| Streaming + `:token-xform` hardest port | High | Defer to P4/P5; P1-P3 sync-only |
| `return-direct` persistence knife easy to miss | Medium | Dedicated test in P3 |
| Bridge complexity in P4 | Medium | Equivalence harness mandatory before P5 flip |
| CCL portability | Medium | No `#+sbcl`; use portable abstractions; CCL in CI |
| ToolSearch prompt-cache interaction | Low | Document trade-off; don't auto-enable |

## 8. Verification baseline & equivalence harness

- **Baseline:** 715 checks (SBCL + CCL), 0 skip, 0 fail
- **Per-phase gate:** suite green at every commit; phase boundary requires equivalence harness green
- **Equivalence harness:** parameterized runner — mock-script + tool set + config → executes through *both* old advisor and new kernel paths → asserts identical `chat-response` + memory state (modulo P4 transcript shift)
- **Alignment audit (P5):** single test asserting all 10 filter types present + smoke-invokable
