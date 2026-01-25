# LLM Module

[中文](README.md) | English

LLM provider implementations and unified interface module.

## Directory Structure

```
llm/
├── package.lisp              # Package definition
├── client.lisp               # Unified client interface
├── providers.lisp            # Provider registration
├── streaming.lisp            # Streaming support
├── schema/                   # Schema conversion
│   ├── openai.lisp          # OpenAI format
│   └── anthropic.lisp       # Anthropic format
├── providers/                # Provider implementations
│   ├── base.lisp            # Base class
│   ├── anthropic.lisp       # Anthropic Claude
│   ├── openai.lisp          # OpenAI GPT
│   └── zhipu.lisp           # ZhipuAI GLM
└── factory/                  # Factory pattern
    ├── registry.lisp        # Provider registry
    ├── config.lisp          # Configuration management
    └── builder.lisp         # Builder API
```

## Supported Providers

| Provider | Keyword | Default Model | Features |
|----------|---------|---------------|----------|
| Anthropic | `:anthropic` | claude-3-5-sonnet-20241022 | Tool calling, streaming |
| OpenAI | `:openai` | gpt-4o | Tool calling, streaming, embeddings |
| ZhipuAI | `:zhipu` | glm-4-turbo | Tool calling, streaming |
| Ollama | `:ollama` | llama2 | Local running |

## Quick Start

### Creating Clients

```lisp
;; Anthropic Claude
(defvar *claude*
  (make-client
    :provider :anthropic
    :model "claude-3-5-sonnet-20241022"
    :api-key (uiop:getenv "ANTHROPIC_API_KEY")))

;; OpenAI GPT
(defvar *gpt*
  (make-client
    :provider :openai
    :model "gpt-4o"
    :api-key (uiop:getenv "OPENAI_API_KEY")))

;; ZhipuAI
(defvar *glm*
  (make-client
    :provider :zhipu
    :model "glm-4-turbo"
    :api-key (uiop:getenv "ZHIPU_API_KEY")))

;; Ollama (local)
(defvar *local*
  (make-client
    :provider :ollama
    :model "llama2"
    :base-url "http://localhost:11434"))
```

### Basic Chat

```lisp
;; Simple string
(chat *claude* "Hello!")

;; Multi-turn conversation
(chat *claude*
  '((:role :user :content "My name is John")
    (:role :assistant :content "Hello, John!")
    (:role :user :content "What's my name?")))

;; With parameters
(chat *claude* "Write a poem"
  :temperature 0.9
  :max-tokens 500)
```

### Tool Calling

```lisp
;; Define tool schema
(defvar *tools*
  '((:name "get_weather"
     :description "Get weather information"
     :parameters (:type "object"
                  :properties (:city (:type "string"
                                      :description "City name"))
                  :required ("city")))))

;; Chat with tools
(let ((response (chat *claude* "What's the weather in Beijing?" :tools *tools*)))
  (when (response-tool-calls response)
    ;; Handle tool calls
    (dolist (call (response-tool-calls response))
      (format t "Calling tool: ~A~%" (tool-call-name call))
      (format t "Arguments: ~A~%" (tool-call-arguments call)))))
```

### Streaming Output

```lisp
;; Basic streaming
(chat-stream *claude* "Tell me a story"
  :on-token (lambda (token)
              (format t "~A" token)
              (force-output)))

;; Complete callbacks
(chat-stream *claude* messages
  :on-token (lambda (token) ...)
  :on-tool-call (lambda (tool-call) ...)
  :on-complete (lambda (response) ...)
  :on-error (lambda (error) ...))
```

### Embeddings

```lisp
;; Single text embedding
(embed *gpt* "Hello, world!")
;; => #(0.123 0.456 ...)

;; Batch embeddings
(embed-batch *gpt* '("Text 1" "Text 2" "Text 3"))
;; => (#(...) #(...) #(...))
```

### Token Counting

```lisp
(count-tokens *claude* "This is a test text")
;; => 5
```

## Client Configuration

```lisp
(make-client
  :provider :anthropic
  :model "claude-3-5-sonnet-20241022"
  :api-key "sk-..."

  ;; Optional configuration
  :base-url "https://api.anthropic.com"  ; Custom API URL
  :max-tokens 4096                        ; Max output tokens
  :temperature 0.7                        ; Sampling temperature
  :timeout 120                            ; Timeout (seconds)
  :retry-attempts 3                       ; Retry count
  :retry-delay 1000)                      ; Retry delay (milliseconds)
```

## Custom Providers

```lisp
;; Inherit base class
(defclass my-provider (base-provider)
  ((name :initform "my-provider")
   (api-url :initform "https://api.example.com")))

;; Implement chat method
(defmethod llm-chat ((provider my-provider) messages &key tools settings)
  ;; Implement API call
  ...)

;; Register provider
(register-provider :my-provider #'make-my-provider)

;; Use
(make-client :provider :my-provider :model "my-model")
```

## Schema Conversion

Different providers have different tool schema formats, the module handles conversion automatically:

```lisp
;; Internal unified format
(:name "tool_name"
 :description "Description"
 :parameters (:type "object"
              :properties (...)
              :required (...)))

;; Convert to OpenAI format
(convert-schema-to-openai schema)

;; Convert to Anthropic format
(convert-schema-to-anthropic schema)
```

## Error Handling

```lisp
(handler-case
    (chat *claude* "Hello")
  (llm-rate-limit-error (e)
    (format t "Rate limit: ~A~%" (error-retry-after e)))
  (llm-api-error (e)
    (format t "API error: ~A~%" (error-message e)))
  (llm-timeout-error (e)
    (format t "Timeout: ~A~%" e)))
```

## Integration with Kernel

```lisp
;; Create Service
(defvar *service*
  (make-service-from-client *claude*))

;; Or create manually
(defvar *service*
  (make-service
    :provider *claude*
    :chat-fn (lambda (messages tools settings)
               (chat *claude* messages
                     :tools tools
                     :temperature (getf settings :temperature)))
    :build-result-msgs-fn #'build-result-messages))

;; Use with Kernel
(defvar *kernel*
  (make-kernel :service *service*))
```
