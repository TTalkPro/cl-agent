# CL-Agent

[中文](README.md)

A unified AI Agent framework for Common Lisp, featuring a Semantic Kernel architecture with a 7-layer modular design.

## Features

- **Multi-Provider LLM Support**: Anthropic Claude, OpenAI GPT, ZhipuAI GLM, Ollama
- **Flexible Tool System**: Symbol plist-based metadata with declarative macros
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
│ Memory │        │   Plugin   │        │   RAG    │
│(Store) │        │  (Tools)   │        │(Retrieve)│
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
| **simpleagent** | Simple agent implementations (KernelAgent, ProcessAgent) |
| **memory** | Unified memory management (checkpoints, stores, long-term memory) |
| **plugin** | Enhanced tool system with built-in tools (file, http, shell) |
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

### Agent with Tools

```lisp
;; Define a tool
(cl-agent.kernel:deftool get-weather
    "Get current weather for a city"
  ((city :string "City name" :required-p t))
  (format nil "Weather in ~A: 22°C, sunny" city))

;; Create plugin
(cl-agent.kernel:defplugin weather-plugin
    "Weather tools"
  get-weather)

;; Create kernel and agent
(defvar *kernel*
  (cl-agent.kernel:make-kernel
    :service *service*
    :plugins '(weather-plugin)))

(defvar *agent*
  (cl-agent.simpleagent:make-kernel-agent *kernel*
    :system-prompt "You are a helpful assistant."))

;; Chat with agent
(cl-agent.simpleagent:agent-chat *agent* "What's the weather in Tokyo?")
```

## Documentation

- [Quick Start Guide](docs/QUICKSTART.md)
- [API Reference](docs/API.md)

## License

MIT License

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.
