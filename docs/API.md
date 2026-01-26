# API Reference

[中文](API_CN.md)

## Table of Contents

- [Core](#core)
  - [Kernel](#kernel)
  - [Context](#context)
  - [Filter](#filter)
  - [Service](#service)
- [Tools](#tools)
  - [Tool Class](#tool-class)
  - [Tool Registry](#tool-registry)
  - [Tag Filtering](#tag-filtering)
  - [Presets](#presets)
  - [Built-in Tools](#built-in-tools)
- [LLM](#llm)
  - [Client](#client)
  - [Providers](#providers)
- [SimpleAgent](#simpleagent)
  - [KernelAgent](#kernelagent)
  - [ProcessAgent](#processagent)
- [Memory](#memory)
- [RAG](#rag)
- [MCP](#mcp)

---

## Core

### Kernel

The central coordinator that holds Service, Tool Registry, Filters, and Config.

#### `make-kernel`

```lisp
(make-kernel &key service tool-registry active-tags tag-filter-mode filters config context) => kernel
```

Create a new Kernel instance.

**Parameters:**
- `service` - LLM service abstraction
- `tool-registry` - Tool registry
- `active-tags` - Active tags (for filtering)
- `tag-filter-mode` - Filter mode (`:any` or `:all`)
- `filters` - List of filter objects
- `config` - Configuration plist
- `context` - Execution context

**Example:**
```lisp
(make-kernel
  :service my-service
  :tool-registry registry
  :active-tags '(:safe :utility)
  :filters (list logging-filter))
```

#### `create-kernel-builder`

```lisp
(create-kernel-builder) => kernel-builder
```

Create a Kernel Builder.

#### `build-kernel`

```lisp
(build-kernel builder) => kernel
```

Build Kernel from Builder.

#### Builder Methods

```lisp
;; Add service
(add-service builder provider) => builder

;; Add single tool
(with-tool builder tool) => builder

;; Add multiple tools
(with-tools builder tool-list) => builder

;; Use preset
(with-preset builder preset &key security-level) => builder

;; Set active tags
(with-active-tags builder tags &key mode) => builder

;; Add filter
(add-filter builder filter) => builder
```

**Example:**
```lisp
(build-kernel
  (with-active-tags
    (with-preset
      (add-service
        (create-kernel-builder)
        *provider*)
      :safe
      :security-level :standard)
    '(:safe :utility)
    :mode :any))
```

#### Kernel Query API

```lisp
;; Find tool
(kernel-find-tool kernel tool-name) => tool

;; Execute tool
(kernel-execute-tool kernel tool-name args) => result

;; Get tool schemas (supports Tag filtering)
(kernel-get-tools kernel &key tags) => list

;; List tool info (supports Tag filtering)
(kernel-list-tools kernel &key tags) => list

;; Tool count
(kernel-tool-count kernel) => integer

;; Has tool
(kernel-has-tool-p kernel tool-name) => boolean
```

#### Kernel Tool Management API

```lisp
;; Register tool
(kernel-register-tool kernel tool) => kernel

;; Batch register
(kernel-register-tools kernel tools) => kernel

;; Unregister tool
(kernel-unregister-tool kernel tool-name) => kernel

;; Set active tags
(kernel-set-active-tags kernel tags) => kernel

;; Clear active tags
(kernel-clear-active-tags kernel) => kernel
```

#### 3-Tier Invoke API

```lisp
;; Tier 1: Tool execution
(invoke kernel tool-name args &key context) => result
(invoke-tool kernel context tool-name args) => result

;; Tier 2: Single LLM call
(invoke-chat kernel messages &key settings) => response
(invoke-chat-stream kernel messages &key on-token) => nil

;; Tier 3: Complete tool loop
(invoke-kernel kernel messages &key settings) => response
(invoke-chat-with-tools kernel messages &key settings) => response
```

---

### Context

Execution context tracking variables, messages, history, and trace.

```lisp
(make-context &key messages metadata) => context
(context-get context key) => value
(context-set context key value) => value
(context-add-message context message) => context
(context-get-messages context) => list
```

---

### Filter

Filters intercept execution at 4 points.

```lisp
(make-filter &key type name fn priority) => filter
```

**Types:**
- `:pre-invocation` - Before tool execution
- `:post-invocation` - After tool execution
- `:pre-chat` - Before LLM call
- `:post-chat` - After LLM call

---

### Service

LLM abstraction.

```lisp
(make-service &key chat-fn build-result-msgs-fn provider) => service
(service-from-provider provider) => service
```

---

## Tools

### Tool Class

```lisp
(defclass tool ()
  ((name :type keyword)
   (description :type string)
   (handler :type function)
   (parameters :type list)
   (category :type keyword)
   (tags :type list)
   (permissions :type list)
   (metadata)))
```

#### `make-simple-tool`

```lisp
(make-simple-tool name description handler &key parameters category tags permissions metadata) => tool
```

Create a tool instance.

**Parameters:**
- `name` - Tool name (keyword)
- `description` - Tool description
- `handler` - Execution function `(lambda (&key ...) ...)`
- `parameters` - Parameter definition list
- `category` - Category (default `:custom`)
- `tags` - Tag list
- `permissions` - Permission list
- `metadata` - Metadata

**Example:**
```lisp
(make-simple-tool
  :greet
  "Greet user"
  (lambda (&key name)
    (format nil "Hello, ~A!" name))
  :parameters '((:name :type :string :description "User name" :required-p t))
  :tags '(:utility :safe))
```

#### Tag Helper Functions

```lisp
(tool-has-tag-p tool tag) => boolean
(tool-has-any-tag-p tool tags) => boolean
(tool-has-all-tags-p tool tags) => boolean
(tool-add-tag tool tag) => tool
(tool-remove-tag tool tag) => tool
(tool-set-tags tool tags) => tool
```

---

### Tool Registry

```lisp
(make-tool-registry) => registry
(register-tool registry tool) => tool
(unregister-tool registry tool-name) => boolean
(find-tool registry tool-name) => tool
(list-tools registry &key category) => list
(registry-tool-count registry) => integer
```

---

### Tag Filtering

```lisp
;; By single tag
(list-tools-by-tag registry tag) => list

;; By multiple tags
(list-tools-by-tags registry tags &key mode) => list
;; mode: :any (default) or :all

;; Get filtered schemas
(get-tools-schema-by-tags registry tags &key mode) => list

;; List all tags
(list-all-tags registry) => list

;; Statistics
(count-tools-by-tag registry tag) => integer
```

---

### Presets

#### Security Levels

| Level | Keyword | Description |
|-------|---------|-------------|
| Permissive | `:permissive` | Least restrictions |
| Standard | `:standard` | Balanced mode |
| Strict | `:strict` | Maximum restrictions |

#### Tool Presets

| Preset | Keyword | Description |
|--------|---------|-------------|
| Standard | `:standard` | File + HTTP + Utility tools |
| Safe | `:safe` | Read-only operations |
| Full | `:full` | All tools (including Shell) |
| File Only | `:file-only` | File operations only |
| HTTP Only | `:http-only` | HTTP operations only |
| Utility Only | `:utility-only` | Utility tools only |

```lisp
;; Quick setup with preset
(quick-setup-tools &key preset security-level) => list

;; List available presets
(list-all-presets) => list

;; Describe preset
(describe-preset preset) => string
```

---

### Built-in Tools

#### File Tools

```lisp
(make-read-file-tool) => tool      ; Tags: (:file :io :read :safe)
(make-write-file-tool) => tool     ; Tags: (:file :io :write)
(make-delete-file-tool) => tool    ; Tags: (:file :io :write :dangerous)
(make-list-directory-tool) => tool ; Tags: (:file :io :read :safe)
(create-file-tools) => list
```

#### HTTP Tools

```lisp
(make-http-get-tool) => tool   ; Tags: (:http :network :read :safe)
(make-http-post-tool) => tool  ; Tags: (:http :network :write)
(create-http-tools) => list
```

#### Shell Tools

```lisp
(make-execute-command-tool) => tool  ; Tags: (:shell :system :dangerous)
(create-shell-tools) => list
```

#### Utility Tools

```lisp
(make-get-timestamp-tool) => tool    ; Tags: (:utility :safe)
(make-generate-uuid-tool) => tool    ; Tags: (:utility :safe)
(make-json-parse-tool) => tool       ; Tags: (:utility :safe)
(make-json-stringify-tool) => tool   ; Tags: (:utility :safe)
(make-string-replace-tool) => tool   ; Tags: (:utility :safe)
(make-math-eval-tool) => tool        ; Tags: (:utility :safe)
(create-utility-tools) => list
```

---

## LLM

### Client

```lisp
(make-client &key provider model api-key base-url max-tokens temperature) => client
(chat client messages &key tools temperature max-tokens) => response
(chat-stream client messages &key on-token on-complete) => nil
```

### Providers

| Provider | Keyword | Default Model |
|----------|---------|---------------|
| Anthropic | `:anthropic` | claude-3-5-sonnet-20241022 |
| OpenAI | `:openai` | gpt-4o |
| ZhipuAI | `:zhipu` | glm-4-turbo |
| Ollama | `:ollama` | llama2 |

---

## SimpleAgent

### KernelAgent

```lisp
(make-kernel-agent kernel &key name system-prompt settings callbacks) => agent
(agent-chat agent message &key verbose) => response
```

### ProcessAgent

```lisp
(make-process-agent kernel) => agent
(agent-start agent message) => nil
(agent-pause agent) => nil
(agent-resume agent) => nil
(agent-stop agent) => nil
```

---

## Memory

### Store

```lisp
(make-memory-store-backend) => store
(make-sqlite-store-backend &key db-path) => store
(store-put store namespace key value) => value
(store-get store namespace key) => value
(store-delete store namespace key) => boolean
(store-list-keys store namespace) => list
```

### Checkpoint

```lisp
(save-checkpoint checkpointer thread-id state) => checkpoint
(load-checkpoint checkpointer thread-id) => checkpoint
```

### Agent Memory

```lisp
(make-agent-memory &key context-store persistent-store default-thread-id) => memory
(am-add-message memory thread-id role content) => message
(am-get-messages memory thread-id) => list
(am-save-checkpoint memory thread-id state) => checkpoint
(am-load-checkpoint memory checkpoint-id) => checkpoint
```

---

## RAG

### Pipeline

```lisp
(make-rag-pipeline &key embeddings-model vector-store splitter) => pipeline
(rag-retrieve pipeline query &key top-k) => list
(rag-query pipeline question &key top-k) => response
```

### Vector Store

```lisp
(make-vector-store) => store
(vector-store-add-document store content embedding &key metadata) => document
(vector-store-search store query-embedding &key top-k) => list
```

---

## MCP

### Client

```lisp
(make-mcp-client &key transport) => client
(mcp-client-connect client) => nil
(mcp-client-call-tool client tool-name args) => result
```

### Server

```lisp
(make-mcp-server &key transport) => server
(mcp-server-start server) => nil
(mcp-register-tool server tool-name fn) => nil
```
