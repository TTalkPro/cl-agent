# CL-Agent Quick Start

[中文](QUICKSTART_CN.md)

This guide walks you through CL-Agent (Spring AI 2.0-aligned architecture).

## 1. Setup

- SBCL (2.4+ recommended) and Quicklisp

```lisp
(dolist (dir '("." "core/" "llm/" "mock/"))
  (pushnew (truename dir) asdf:*central-registry* :test #'equal))
(asdf:load-system :cl-agent)
```

## 2. Create a ChatModel

```lisp
;; Anthropic (reads ANTHROPIC_API_KEY)
(defvar *model*
  (cl-agent.llm:create-chat-model :anthropic
    :model "claude-sonnet-4-20250514"))

;; Other providers: :openai :zhipu :ollama :dashscope :minimax ...
;; With model-level default options:
(cl-agent.llm:create-chat-model :openai :model "gpt-4o"
  :options (cl-agent.chat:make-chat-options :temperature 0.3))

;; No API key? Use the mock provider:
(asdf:load-system :cl-agent-mock)
(defvar *model*
  (cl-agent.chat:make-provider-chat-model (cl-agent.mock:make-mock-llm)))
```

## 3. First Chat

```lisp
(defvar *client* (cl-agent.client:make-chat-client *model*))

(cl-agent.client:chat *client* "Hello!")

(cl-agent.client:chat *client*
  (:system "You are a concise assistant")
  (:user "Describe Common Lisp in one sentence")
  (:options :temperature 0.2))
```

Fluent pipeline style:

```lisp
(cl-agent.core:->
  (cl-agent.client:client-prompt *client*)
  (cl-agent.client:prompt-user "Translate: ~A" "hello world")
  (cl-agent.client:call-content))
```

## 4. Builder

```lisp
(defvar *client*
  (cl-agent.core:->
    (cl-agent.client:chat-client-builder *model*)
    (cl-agent.client:default-system "You are an assistant")
    (cl-agent.client:default-advisors
      (cl-agent.client:make-simple-logger-advisor))
    (cl-agent.client:build-client)))
```

## 5. Tool Calling (deftool)

```lisp
(cl-agent.chat:deftool get-weather (&key city (unit "celsius"))
  "Get the current weather for a city"
  (:param city :string "City name" :required t)
  (:param unit :string "Temperature unit")
  (format nil "Weather in ~A: 22°C (~A), sunny" city unit))

(cl-agent.client:chat *client*
  (:user "What's the weather in Tokyo?")
  (:tools 'get-weather))
```

Notes:

- The lambda-list must be `&key`-style (LLM tool arguments are named)
- Tool names become lowercase snake_case: `get-weather` → `"get_weather"`
- `(:return-direct t)` returns the tool result directly to the caller
- Declare a `tool-context` parameter to receive host-injected context

## 6. Conversation Memory

```lisp
(defvar *memory* (cl-agent.chat:make-message-window-chat-memory))
(defvar *client*
  (cl-agent.client:make-chat-client *model*
    :advisors (list (cl-agent.client:make-message-chat-memory-advisor
                     :memory *memory*))))

(cl-agent.client:chat *client* (:user "My name is David") (:conversation "c1"))
(cl-agent.client:chat *client* (:user "What's my name?") (:conversation "c1"))
```

Custom storage backends implement `repository-find` / `repository-save` /
`repository-delete` / `repository-conversation-ids`.

## 7. Custom Advisors

```lisp
(cl-agent.client:defadvisor timing-advisor (:order -100)
  (:call (advisor request chain)
    (declare (ignore advisor))
    (let ((start (get-internal-real-time)))
      (prog1 (cl-agent.client:chain-next chain request)
        (format t "took ~,2Fs~%"
                (/ (- (get-internal-real-time) start)
                   internal-time-units-per-second))))))
```

Built-ins: `simple-logger-advisor` (-1000), `safe-guard-advisor` (-500),
`message-chat-memory-advisor` (1000), `prompt-chat-memory-advisor` (1000).
Lower order = outer position in the onion chain.

## 8. Streaming & Structured Output

```lisp
(cl-agent.client:chat *client*
  (:user "Write a short poem")
  (:stream (lambda (delta) (princ delta) (force-output))))

(cl-agent.client:chat *client*
  (:user "Tokyo info as JSON (name/population)")
  (:call :entity))   ; → hash-table
```

## 9. Tests

```bash
sbcl --non-interactive --load run-tests.lisp
```

## Next

- [API Reference](API.md)
- [Full examples](../examples/chat-client-usage.lisp)
