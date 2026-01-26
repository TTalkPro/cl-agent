# CL-Agent

[中文](README.md)

A unified AI Agent framework for Common Lisp, featuring a Semantic Kernel architecture with a 7-layer modular design.

## Features

- **Multi-Provider LLM Support**: Anthropic Claude, OpenAI GPT, ZhipuAI GLM, Ollama
- **Flexible Tool System**: Direct tool registration + Tag-based filtering
- **Tool Presets**: Built-in security levels and feature presets for quick configuration
- **Comprehensive Memory**: Short-term checkpoints + Long-term persistent storage
- **RAG Pipeline**: Text splitting, embeddings, vector storage, retrieval
- **Protocol Support**: MCP (Model Context Protocol) + A2A (Agent-to-Agent)
- **Security & Resilience**: Rate limiting, input validation, retry, timeout, circuit breaker

## Architecture

```
┌─────────────────────────────────────────────────────┐
│                    CL-Agent                         │
└─────────────────────────────────────────────────────┘
                         │
    ┌────────────────────┼────────────────────┐
    │                    │                    │
    ▼                    ▼                    ▼
┌────────┐        ┌────────────┐        ┌──────────┐
│  Core  │        │    LLM     │        │SimpleAgent│
│(Kernel)│        │(Providers) │        │ (Agents)  │
└────────┘        └────────────┘        └──────────┘
    │                    │                    │
    ├────────────────────┼────────────────────┤
    │                    │                    │
    ▼                    ▼                    ▼
┌────────┐        ┌────────────┐        ┌──────────┐
│ Memory │        │   Tools    │        │   RAG    │
│(Store) │        │(Tags+Reg.) │        │(Retrieve)│
└────────┘        └────────────┘        └──────────┘
                         │
                         ▼
                  ┌────────────┐
                  │    MCP     │
                  │(Protocols) │
                  └────────────┘
```

## Modules

| Module | Description |
|--------|-------------|
| **core** | Core infrastructure: Kernel, Context, Filter, Service abstractions |
| **llm** | LLM provider implementations (Anthropic, OpenAI, ZhipuAI, Ollama) |
| **tools** | Tool system: Tool Registry + Tag filtering + Presets |
| **simpleagent** | Simple agent implementations (KernelAgent, ProcessAgent) |
| **memory** | Unified memory management (checkpoints, stores, long-term memory) |
| **rag** | Retrieval-Augmented Generation pipeline |
| **mcp** | Model Context Protocol implementation |
| **protocols** | Protocol support (MCP, A2A) |

## Installation

### Prerequisites

- SBCL or other Common Lisp implementation
- Quicklisp

### Setup

```bash
# Clone the repository
git clone https://github.com/example/cl-agent.git
cd cl-agent

# Load with ASDF
(asdf:load-system :cl-agent)
```

## Quick Start

### Basic Chat

```lisp
(ql:quickload :cl-agent)

;; Create LLM client
(defvar *client*
  (cl-agent.llm:make-client
    :provider :anthropic
    :model "claude-3-5-sonnet-20241022"
    :api-key (uiop:getenv "ANTHROPIC_API_KEY")))

;; Simple chat
(cl-agent.llm:chat *client* "Hello, how are you?")
```

### Agent with Tools (New API)

```lisp
;; Create a tool
(defvar *weather-tool*
  (cl-agent.tools:make-simple-tool
    :get_weather
    "Get current weather for a city"
    (lambda (&key city)
      (format nil "Weather in ~A: 22°C, sunny" city))
    :parameters '((:city :type :string :description "City name" :required-p t))
    :tags '(:utility :weather :safe)))

;; Create kernel using Builder pattern
(defvar *kernel*
  (cl-agent.kernel:build-kernel
    (cl-agent.kernel:with-tool
      (cl-agent.kernel:add-service
        (cl-agent.kernel:create-kernel-builder)
        *provider*)
      *weather-tool*)))

;; Create agent
(defvar *agent*
  (cl-agent.simpleagent:make-kernel-agent *kernel*
    :system-prompt "You are a helpful assistant."))

;; Chat with agent
(cl-agent.simpleagent:agent-chat *agent* "What's the weather in Tokyo?")
```

### Quick Setup with Presets

```lisp
;; Create kernel with preset tools
(defvar *kernel*
  (cl-agent.kernel:build-kernel
    (cl-agent.kernel:with-preset
      (cl-agent.kernel:add-service
        (cl-agent.kernel:create-kernel-builder)
        *provider*)
      :safe                     ; Presets: :standard :safe :full :file-only :http-only :utility-only
      :security-level :standard))) ; Security: :permissive :standard :strict
```

### Tag Filtering

```lisp
;; Create kernel with tag filtering (only enable :safe and :utility tagged tools)
(defvar *kernel*
  (cl-agent.kernel:build-kernel
    (cl-agent.kernel:with-active-tags
      (cl-agent.kernel:with-preset
        (cl-agent.kernel:add-service
          (cl-agent.kernel:create-kernel-builder)
          *provider*)
        :full)
      '(:safe :utility)     ; Only enable tools with these tags
      :mode :any)))         ; :any = match any tag, :all = match all tags
```

## Tool Tags

Built-in tools use these tags:

| Tag | Description |
|-----|-------------|
| `:file` | File operation tools |
| `:http` | HTTP request tools |
| `:shell` | Shell command tools |
| `:utility` | General utility tools |
| `:safe` | Safe read-only operations |
| `:read` | Read operations |
| `:write` | Write operations |
| `:dangerous` | Dangerous operations (use with caution) |

## Documentation

- [Quick Start Guide](docs/QUICKSTART.md)
- [API Reference](docs/API.md)

## License

MIT License

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.
