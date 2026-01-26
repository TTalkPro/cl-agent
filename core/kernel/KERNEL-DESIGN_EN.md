# CL-Agent Kernel Design

[中文](KERNEL-DESIGN.md) | English

## Design Principles

1. **Direct Tool Registration** — Kernel directly holds Tool Registry, no intermediate Plugin layer
2. **Tag-Based Filtering** — Tools are classified by tags, supporting runtime filtering
3. **Builder Pattern** — Fluent API for building Kernel
4. **Preset Configuration** — Built-in security levels and feature presets

---

## Architecture Overview

```
┌──────────────────────────────────────────────────┐
│  User Code                                        │
│  ┌──────────────────────────────────────────────┐ │
│  │ make-simple-tool                              │ │
│  │ (Create tools with tags)                      │ │
│  └──────────────────┬───────────────────────────┘ │
│                     │                             │
│                     ▼                             │
│  ┌──────────────────────────────────────────────┐ │
│  │ Tool Registry                                 │ │
│  │ (Manage tools + Tag filtering)                │ │
│  └──────────────────┬───────────────────────────┘ │
├─────────────────────┼───────────────────────────────┤
│  Kernel Layer                                      │
│                     ▼                             │
│  ┌──────────────────────────────────────────────┐ │
│  │ Kernel                                        │ │
│  │ - tool-registry (Tool registry)               │ │
│  │ - active-tags (Active tag filter)             │ │
│  │ - service (LLM service)                       │ │
│  │ - filters (Filter chain)                      │ │
│  └──────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────┘
```

---

## Core Components

### Tool

```lisp
(defclass tool ()
  ((name :type keyword)
   (description :type string)
   (handler :type function)
   (parameters :type list)
   (category :type keyword)
   (tags :type list)        ; Tag list
   (metadata :type list)))
```

### Tool Registry

```lisp
;; Create registry
(make-tool-registry)

;; Register tool
(register-tool registry tool)

;; Tag filtering
(list-tools-by-tag registry :safe)
(list-tools-by-tags registry '(:file :read) :mode :any)
```

### Kernel

```lisp
(defclass kernel ()
  ((service)            ; LLM service
   (config)             ; Configuration
   (tool-registry)      ; Tool registry
   (active-tags)        ; Active tags (for filtering)
   (tag-filter-mode)    ; Filter mode :any or :all
   (filters)            ; Filter chain
   (context)))          ; Execution context
```

---

## Creating Tools

### Using make-simple-tool

```lisp
(defvar *weather-tool*
  (cl-agent.tools:make-simple-tool
    :get_weather
    "Get weather information for a city"
    (lambda (&key city unit)
      (format nil "~A: sunny, 22°~A" city (or unit "C")))
    :parameters '((:city :type :string :description "City name" :required-p t)
                  (:unit :type :string :description "Temperature unit"))
    :category :utility
    :tags '(:utility :weather :safe)))
```

### Built-in Tools

```lisp
;; File tools
(cl-agent.tools:make-read-file-tool)   ; Tags: (:file :io :read :safe)
(cl-agent.tools:make-write-file-tool)  ; Tags: (:file :io :write)

;; HTTP tools
(cl-agent.tools:make-http-get-tool)    ; Tags: (:http :network :read :safe)
(cl-agent.tools:make-http-post-tool)   ; Tags: (:http :network :write)

;; Utility tools
(cl-agent.tools:make-get-timestamp-tool)  ; Tags: (:utility :safe)
(cl-agent.tools:make-generate-uuid-tool)  ; Tags: (:utility :safe)
```

---

## Kernel Builder

### Basic Usage

```lisp
(defvar *kernel*
  (cl-agent.kernel:build-kernel
    (cl-agent.kernel:with-tool
      (cl-agent.kernel:add-service
        (cl-agent.kernel:create-kernel-builder)
        *provider*)
      *weather-tool*)))
```

### Adding Multiple Tools

```lisp
(defvar *kernel*
  (cl-agent.kernel:build-kernel
    (cl-agent.kernel:with-tools
      (cl-agent.kernel:add-service
        (cl-agent.kernel:create-kernel-builder)
        *provider*)
      (list *tool1* *tool2* *tool3*))))
```

### Using Presets

```lisp
(defvar *kernel*
  (cl-agent.kernel:build-kernel
    (cl-agent.kernel:with-preset
      (cl-agent.kernel:add-service
        (cl-agent.kernel:create-kernel-builder)
        *provider*)
      :safe                      ; Preset
      :security-level :standard))) ; Security level
```

### Setting Tag Filters

```lisp
(defvar *kernel*
  (cl-agent.kernel:build-kernel
    (cl-agent.kernel:with-active-tags
      (cl-agent.kernel:with-preset
        (cl-agent.kernel:add-service
          (cl-agent.kernel:create-kernel-builder)
          *provider*)
        :full)
      '(:safe :utility)    ; Only enable these tags
      :mode :any)))        ; :any or :all
```

---

## Tag Filtering

### At Kernel Level

```lisp
;; Set active tags
(kernel-set-active-tags kernel '(:safe :utility))

;; Clear tag filter
(kernel-clear-active-tags kernel)

;; Get filtered tools
(kernel-list-tools kernel)
(kernel-get-tools kernel)
```

### At Query Time

```lisp
;; Query with specific tags
(kernel-list-tools kernel :tags '(:file))
(kernel-get-tools kernel :tags '(:safe :read))
```

---

## 3-Tier Invoke API

### Tier 1: Tool Execution

```lisp
(invoke kernel :tool-name args)
(invoke-tool kernel context :tool-name args)
```

### Tier 2: Single LLM Call

```lisp
(invoke-chat kernel messages)
(invoke-chat-stream kernel messages :on-token #'handler)
```

### Tier 3: Complete Tool Loop

```lisp
(invoke-kernel kernel messages)
(invoke-chat-with-tools kernel messages)
```

---

## Preset Configuration

### Security Levels

| Level | Description |
|-------|-------------|
| `:permissive` | Permissive mode |
| `:standard` | Standard mode (recommended) |
| `:strict` | Strict mode |

### Tool Presets

| Preset | Included Tools |
|--------|----------------|
| `:standard` | File + HTTP + Utility |
| `:safe` | Read-only operations |
| `:full` | All (including Shell) |
| `:file-only` | File only |
| `:http-only` | HTTP only |
| `:utility-only` | Utility only |

---

## Usage Example

### Complete Example

```lisp
;; 1. Create Provider
(defvar *provider*
  (cl-agent.llm.providers:make-anthropic-provider
    :api-key (uiop:getenv "ANTHROPIC_API_KEY")
    :model "claude-3-5-sonnet-20241022"))

;; 2. Create custom tool
(defvar *calc-tool*
  (cl-agent.tools:make-simple-tool
    :calculate
    "Evaluate math expression"
    (lambda (&key expression)
      (format nil "~A" (eval (read-from-string expression))))
    :parameters '((:expression :type :string
                   :description "Math expression"
                   :required-p t))
    :tags '(:utility :math :safe)))

;; 3. Create Kernel
(defvar *kernel*
  (cl-agent.kernel:build-kernel
    (cl-agent.kernel:with-tool
      (cl-agent.kernel:with-preset
        (cl-agent.kernel:add-service
          (cl-agent.kernel:create-kernel-builder)
          *provider*)
        :utility-only
        :security-level :standard)
      *calc-tool*)))

;; 4. Create Agent
(defvar *agent*
  (cl-agent.simpleagent:make-kernel-agent *kernel*
    :system-prompt "You are a helpful assistant."))

;; 5. Chat
(cl-agent.simpleagent:agent-chat *agent* "Calculate 15 * 7")
```

---

## Key Advantages

| Feature | Description |
|---------|-------------|
| Direct Tool Registration | No Plugin intermediate layer, simpler |
| Tag Filtering | Flexible runtime tool filtering |
| Preset Configuration | Quick setup for common scenarios |
| Builder Pattern | Fluent API, easy to compose |
| Security Levels | Built-in security controls |
