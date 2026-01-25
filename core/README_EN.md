# Core Module

[中文](README.md) | English

Core infrastructure module providing Kernel framework, HTTP client, condition system and utility functions.

## Directory Structure

```
core/
├── package-core.lisp          # Package definition
├── conditions.lisp            # Condition system
├── types.lisp                 # Core data types
├── utils.lisp                 # Utility functions
├── macros.lisp                # Utility macros
├── validation.lisp            # Data validation
├── dependency-injection.lisp  # Dependency injection container
├── data-convert.lisp          # Data conversion
├── http/                      # HTTP client module
│   ├── client.lisp
│   ├── async.lisp
│   ├── retry.lisp
│   └── streaming.lisp
└── kernel/                    # Kernel framework
    ├── function.lisp          # Tool metadata
    ├── plugin.lisp            # Plugin metadata
    ├── macros.lisp            # deftool/defplugin macros
    ├── context.lisp           # Context class
    ├── service.lisp           # Service abstraction
    ├── filter.lisp            # Filter pipeline
    ├── kernel.lisp            # Kernel class
    └── chat.lisp              # Invoke API
```

## Core Concepts

### 1. Condition System

```lisp
;; Defined condition types
cl-agent-error        ; Base error
├── api-error         ; API related errors
├── llm-error         ; LLM call errors
├── tool-error        ; Tool execution errors
├── validation-error  ; Validation errors
└── config-error      ; Configuration errors
```

### 2. Core Data Types

```lisp
;; Message construction
(make-message :role :user :content "Hello")
(make-message :role :assistant :content "Hi" :tool-calls [...])
(make-message :role :tool :content "Result" :tool-call-id "123")

;; ToolCall construction
(make-tool-call :id "call_123" :name "get-weather" :arguments '(:city "Tokyo"))

;; Response construction
(make-response :content "..." :tool-calls [...] :metadata {...})
```

### 3. Utility Functions

```lisp
;; Environment variables
(get-env "API_KEY")
(get-env "PORT" "8080")  ; With default value

;; UUID generation
(generate-uuid)  ; => "550e8400-e29b-41d4-a716-446655440000"

;; Timestamp
(timestamp-now)  ; => "2024-01-15T10:30:00Z"

;; JSON operations
(json-encode object)
(json-decode string)
```

### 4. Utility Macros

```lisp
;; Conditional binding
(when-let ((value (get-value)))
  (process value))

(if-let ((value (get-value)))
  (process value)
  (handle-nil))

;; Timing
(with-timing ("operation")
  (do-something))

;; Threading macros (Clojure-like)
(-> value
    (transform-1)
    (transform-2 extra-arg)
    (transform-3))
```

## Kernel Framework

### Tool Function

Use Symbol Plist to store tool metadata:

```lisp
;; Declarative definition
(deftool get-weather "Get weather information"
  ((city :string "City name" :required-p t)
   (unit :string "Temperature unit" :default "celsius"))
  (format nil "~A: 22°C" city))

;; Runtime registration
(declare-tool 'my-tool
  :description "Tool description"
  :parameters '((param1 :string "Parameter 1" :required-p t)))

;; Query metadata
(tool-function-p 'get-weather)    ; => T
(tool-description 'get-weather)   ; => "Get weather information"
(tool-parameters 'get-weather)    ; => (...)
(tool-schema 'get-weather)        ; => JSON Schema
```

### Plugin

Logical grouping of tools:

```lisp
;; Declarative definition
(defplugin weather-plugin "Weather related tools"
  get-weather
  get-forecast)

;; Runtime registration
(declare-plugin 'my-plugin "Plugin description" '(tool1 tool2))

;; Query
(plugin-p 'weather-plugin)           ; => T
(plugin-tool-symbols 'weather-plugin) ; => (GET-WEATHER GET-FORECAST)
(plugin-get-schemas 'weather-plugin)  ; => All tool schemas
```

### Context

Execution context:

```lisp
(let ((ctx (make-context :messages messages)))
  ;; Variable management
  (context-set-variable ctx "key" "value")
  (context-get-variable ctx "key")

  ;; Message management
  (context-add-message ctx message)
  (context-messages ctx)

  ;; History and tracing
  (context-history ctx)
  (context-trace ctx))
```

### Service

LLM service abstraction:

```lisp
(make-service
  :chat-fn (lambda (messages tools settings)
             ;; Call LLM
             ...)
  :build-result-msgs-fn (lambda (response)
                          ;; Build result messages
                          ...)
  :provider provider-instance)
```

### Filter

4 types of filters:

```lisp
;; Filter types
:pre-invocation   ; Before tool execution
:post-invocation  ; After tool execution
:pre-chat         ; Before LLM call
:post-chat        ; After LLM call

;; Create filter
(make-filter
  :type :pre-chat
  :name "rag-injection"
  :fn (lambda (ctx next)
        ;; Pre-processing
        (inject-rag-context ctx)
        ;; Call next
        (let ((result (funcall next ctx)))
          ;; Post-processing
          result))
  :priority 10)
```

### Kernel

Central coordinator:

```lisp
;; Create Kernel
(defvar *kernel*
  (make-kernel
    :service *service*
    :plugins '(plugin1 plugin2)
    :filters (list filter1 filter2)
    :config '(:max-iterations 10)))

;; Builder pattern
(defvar *kernel*
  (-> (make-kernel)
      (with-service service)
      (with-plugins '(plugin1))
      (with-filter filter)
      (with-config '(:debug t))
      (build)))

;; Get tool information
(kernel-get-tools *kernel*)
(kernel-get-schema *kernel* "tool-name")
```

### 3-Tier Invoke API

```lisp
;; Tier 1: Execute single tool
(invoke-tool kernel context "get-weather" '(:city "Tokyo"))

;; Tier 2: Single LLM call
(invoke-chat kernel context messages settings)

;; Tier 3: Complete tool call loop
(invoke-kernel kernel context messages)
```

## HTTP Client

```lisp
;; Basic requests
(http-get url :headers headers)
(http-post url :body body :headers headers)

;; Async requests
(http-async url :method :post
            :on-success (lambda (response) ...)
            :on-error (lambda (error) ...))

;; Streaming requests (SSE)
(http-stream url
  :on-event (lambda (event) ...)
  :on-error (lambda (error) ...))

;; With retry
(with-retry (:attempts 3 :backoff :exponential)
  (http-get url))
```

## Dependency Injection

```lisp
;; Create container
(defvar *container* (make-di-container))

;; Register service
(di-register *container* :llm-client
  (lambda () (make-client :provider :anthropic)))

;; Resolve service
(di-resolve *container* :llm-client)

;; Scopes
(di-scoped *container* :request
  (lambda ()
    ;; Request-scoped service
    ...))
```
