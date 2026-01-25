# API Reference

[中文](API_CN.md)

## Table of Contents

- [Core](#core)
  - [Kernel](#kernel)
  - [Context](#context)
  - [Tool & Plugin](#tool--plugin)
  - [Filter](#filter)
  - [Service](#service)
- [LLM](#llm)
  - [Client](#client)
  - [Providers](#providers)
- [SimpleAgent](#simpleagent)
  - [KernelAgent](#kernelagent)
  - [ProcessAgent](#processagent)
- [Memory](#memory)
  - [Store](#store)
  - [Checkpoint](#checkpoint)
  - [Agent Memory](#agent-memory)
- [RAG](#rag)
  - [Pipeline](#pipeline)
  - [Vector Store](#vector-store)
- [MCP](#mcp)

---

## Core

### Kernel

The central coordinator that holds Service, Plugins, Filters, and Config.

#### `make-kernel`

```lisp
(make-kernel &key service plugins filters config) => kernel
```

Create a new Kernel instance.

**Parameters:**
- `service` - LLM service abstraction
- `plugins` - List of plugin symbols
- `filters` - List of filter objects
- `config` - Configuration plist

**Example:**
```lisp
(make-kernel
  :service my-service
  :plugins '(weather-plugin math-plugin)
  :filters (list logging-filter))
```

#### `kernel-get-tools`

```lisp
(kernel-get-tools kernel) => list
```

Get all tool schemas from registered plugins.

#### `kernel-get-schema`

```lisp
(kernel-get-schema kernel tool-name) => hash-table
```

Get schema for a specific tool.

#### `invoke-tool`

```lisp
(invoke-tool kernel context tool-name args) => result
```

Execute a single tool.

#### `invoke-chat`

```lisp
(invoke-chat kernel context messages settings) => response
```

Perform a single LLM call.

#### `invoke-kernel`

```lisp
(invoke-kernel kernel context messages) => response
```

Execute complete tool-calling loop until no more tool calls.

---

### Context

Execution context tracking variables, messages, history, and trace.

#### `make-context`

```lisp
(make-context &key messages metadata) => context
```

Create a new Context instance.

#### `context-get-variable`

```lisp
(context-get-variable context key) => value
```

Get a variable from context.

#### `context-set-variable`

```lisp
(context-set-variable context key value) => value
```

Set a variable in context.

#### `context-add-message`

```lisp
(context-add-message context message) => context
```

Add a message to context.

---

### Tool & Plugin

#### `deftool`

```lisp
(deftool name description parameters &body body)
```

Define a tool function with metadata.

**Parameters:**
- `name` - Tool function name
- `description` - Tool description for LLM
- `parameters` - Parameter specifications `((name type desc &key required-p default) ...)`
- `body` - Function body

**Example:**
```lisp
(deftool calculate "Perform calculation"
  ((expression :string "Math expression" :required-p t))
  (eval (read-from-string expression)))
```

#### `defplugin`

```lisp
(defplugin name description &rest tools)
```

Define a plugin grouping multiple tools.

**Example:**
```lisp
(defplugin math-plugin "Mathematical operations"
  calculate
  convert-units)
```

#### `declare-tool`

```lisp
(declare-tool symbol &key description parameters category)
```

Declare tool metadata on an existing function.

#### `declare-plugin`

```lisp
(declare-plugin symbol description tools)
```

Declare plugin metadata.

#### `tool-function-p`

```lisp
(tool-function-p symbol) => boolean
```

Check if symbol is a tool function.

#### `tool-schema`

```lisp
(tool-schema symbol) => hash-table
```

Get JSON Schema for a tool.

---

### Filter

Filters intercept execution at 4 points: pre-invocation, post-invocation, pre-chat, post-chat.

#### `make-filter`

```lisp
(make-filter &key type name fn priority) => filter
```

Create a filter.

**Parameters:**
- `type` - One of `:pre-invocation`, `:post-invocation`, `:pre-chat`, `:post-chat`
- `name` - Filter name string
- `fn` - Filter function `(context next-fn) => result`
- `priority` - Integer priority (higher = earlier)

**Example:**
```lisp
(make-filter
  :type :pre-invocation
  :name "logging"
  :fn (lambda (ctx next)
        (format t "Executing tool...~%")
        (funcall next ctx))
  :priority 10)
```

---

### Service

LLM abstraction decoupling Kernel from specific implementations.

#### `make-service`

```lisp
(make-service &key chat-fn build-result-msgs-fn provider) => service
```

Create a Service instance.

**Parameters:**
- `chat-fn` - Function for LLM chat
- `build-result-msgs-fn` - Function to build result messages
- `provider` - LLM provider instance

---

## LLM

### Client

#### `make-client`

```lisp
(make-client &key provider model api-key base-url max-tokens temperature) => client
```

Create an LLM client.

**Parameters:**
- `provider` - Provider keyword (`:anthropic`, `:openai`, `:zhipu`, `:ollama`)
- `model` - Model name string
- `api-key` - API key string
- `base-url` - Optional custom API base URL
- `max-tokens` - Maximum response tokens
- `temperature` - Sampling temperature

**Example:**
```lisp
(make-client
  :provider :anthropic
  :model "claude-3-5-sonnet-20241022"
  :api-key "sk-...")
```

#### `chat`

```lisp
(chat client messages &key tools temperature max-tokens) => response
```

Send chat request to LLM.

**Parameters:**
- `client` - LLM client
- `messages` - String or list of message plists
- `tools` - Optional tool schemas
- `temperature` - Optional temperature override
- `max-tokens` - Optional max tokens override

**Example:**
```lisp
;; Simple string
(chat client "Hello!")

;; Multi-turn conversation
(chat client
  '((:role :user :content "Hi")
    (:role :assistant :content "Hello!")
    (:role :user :content "How are you?")))
```

#### `chat-stream`

```lisp
(chat-stream client messages &key on-token on-complete) => nil
```

Stream chat response.

**Parameters:**
- `on-token` - Callback `(token) => nil` for each token
- `on-complete` - Callback `(full-response) => nil` when done

---

### Providers

Supported providers:

| Provider | Keyword | Default Model |
|----------|---------|---------------|
| Anthropic | `:anthropic` | claude-3-5-sonnet-20241022 |
| OpenAI | `:openai` | gpt-4o |
| ZhipuAI | `:zhipu` | glm-4-turbo |
| Ollama | `:ollama` | llama2 |

---

## SimpleAgent

### KernelAgent

Simple chat agent wrapping Kernel.

#### `make-kernel-agent`

```lisp
(make-kernel-agent kernel &key name system-prompt settings callbacks) => agent
```

Create a KernelAgent.

**Parameters:**
- `kernel` - Kernel instance
- `name` - Agent name
- `system-prompt` - System prompt string
- `settings` - Settings plist (`:max-iterations`, etc.)
- `callbacks` - Callback functions

#### `agent-chat`

```lisp
(agent-chat agent message &key verbose) => response
```

Chat with agent.

---

### ProcessAgent

Agent with pause/resume capabilities.

#### `make-process-agent`

```lisp
(make-process-agent kernel) => agent
```

#### `agent-start`

```lisp
(agent-start agent message) => nil
```

Start agent with initial message.

#### `agent-pause`

```lisp
(agent-pause agent) => nil
```

Pause agent execution.

#### `agent-resume`

```lisp
(agent-resume agent) => nil
```

Resume paused agent.

#### `agent-stop`

```lisp
(agent-stop agent) => nil
```

Stop agent.

---

## Memory

### Store

Long-term persistent storage protocol.

#### `make-memory-store-backend`

```lisp
(make-memory-store-backend) => store
```

Create in-memory store backend.

#### `make-sqlite-store-backend`

```lisp
(make-sqlite-store-backend &key db-path) => store
```

Create SQLite store backend.

#### `store-put`

```lisp
(store-put store namespace key value) => value
```

Store a value.

#### `store-get`

```lisp
(store-get store namespace key) => value
```

Retrieve a value.

#### `store-delete`

```lisp
(store-delete store namespace key) => boolean
```

Delete a value.

#### `store-list-keys`

```lisp
(store-list-keys store namespace) => list
```

List all keys in namespace.

---

### Checkpoint

Short-term state snapshots.

#### `save-checkpoint`

```lisp
(save-checkpoint checkpointer thread-id state) => checkpoint
```

Save a checkpoint.

#### `load-checkpoint`

```lisp
(load-checkpoint checkpointer thread-id) => checkpoint
```

Load latest checkpoint for thread.

---

### Agent Memory

Unified memory interface.

#### `make-agent-memory`

```lisp
(make-agent-memory &key context-store persistent-store default-thread-id) => memory
```

Create Agent Memory.

#### `am-add-message`

```lisp
(am-add-message memory thread-id role content) => message
```

Add message to thread.

#### `am-get-messages`

```lisp
(am-get-messages memory thread-id) => list
```

Get all messages in thread.

#### `am-save-checkpoint`

```lisp
(am-save-checkpoint memory thread-id state) => checkpoint
```

Save checkpoint.

#### `am-load-checkpoint`

```lisp
(am-load-checkpoint memory checkpoint-id) => checkpoint
```

Load checkpoint.

---

## RAG

### Pipeline

#### `make-rag-pipeline`

```lisp
(make-rag-pipeline &key embeddings-model vector-store splitter) => pipeline
```

Create RAG pipeline.

#### `rag-retrieve`

```lisp
(rag-retrieve pipeline query &key top-k) => list
```

Retrieve relevant documents.

#### `rag-query`

```lisp
(rag-query pipeline question &key top-k) => response
```

Query with RAG context.

---

### Vector Store

#### `make-vector-store`

```lisp
(make-vector-store) => store
```

Create vector store.

#### `vector-store-add-document`

```lisp
(vector-store-add-document store content embedding &key metadata) => document
```

Add document to store.

#### `vector-store-search`

```lisp
(vector-store-search store query-embedding &key top-k) => list
```

Search for similar documents.

---

## MCP

### Client

#### `make-mcp-client`

```lisp
(make-mcp-client &key transport) => client
```

Create MCP client.

#### `mcp-client-connect`

```lisp
(mcp-client-connect client) => nil
```

Connect to MCP server.

#### `mcp-client-call-tool`

```lisp
(mcp-client-call-tool client tool-name args) => result
```

Call tool via MCP.

### Server

#### `make-mcp-server`

```lisp
(make-mcp-server &key transport) => server
```

Create MCP server.

#### `mcp-server-start`

```lisp
(mcp-server-start server) => nil
```

Start MCP server.

#### `mcp-register-tool`

```lisp
(mcp-register-tool server tool-name fn) => nil
```

Register tool with server.
