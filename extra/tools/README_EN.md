# Tools Module

[中文](README.md) | English

Tool system: Tool Registry + Tag filtering + Preset configuration.

## Directory Structure

```
tools/
├── package.lisp              # Package definition
├── protocol.lisp             # Tool class and protocols
├── registry.lisp             # Tool registry (with Tag filtering)
├── core.lisp                 # Core tool functions
├── builtin.lisp              # Built-in tools with tags
├── presets.lisp              # Tool preset configuration
├── tool-factories.lisp       # Tool factories
└── providers/                # Provider implementations
    ├── builtin.lisp
    └── custom.lisp
```

## Core Concepts

### Tool

Each tool contains the following properties:

- `name` - Tool name (keyword)
- `description` - Tool description
- `handler` - Execution function
- `parameters` - Parameter definitions
- `category` - Category
- `tags` - Tag list (for filtering)
- `metadata` - Metadata

### Creating Tools

```lisp
;; Using make-simple-tool
(defvar *my-tool*
  (cl-agent.tools:make-simple-tool
    :greet
    "Greet user"
    (lambda (&key name)
      (format nil "Hello, ~A!" name))
    :parameters '((:name :type :string :description "User name" :required-p t))
    :category :utility
    :tags '(:utility :safe)))
```

### Tags

Tags are used for tool classification and filtering:

```lisp
;; Check tool tags
(cl-agent.tools:tool-has-tag-p tool :safe)
(cl-agent.tools:tool-has-any-tag-p tool '(:safe :utility))
(cl-agent.tools:tool-has-all-tags-p tool '(:file :read))

;; Modify tags
(cl-agent.tools:tool-add-tag tool :new-tag)
(cl-agent.tools:tool-remove-tag tool :old-tag)
(cl-agent.tools:tool-set-tags tool '(:tag1 :tag2))
```

## Tool Registry

```lisp
;; Create registry
(defvar *registry* (cl-agent.tools:make-tool-registry))

;; Register tool
(cl-agent.tools:register-tool *registry* *my-tool*)

;; Find tool
(cl-agent.tools:find-tool *registry* :greet)

;; List all tools
(cl-agent.tools:list-tools *registry*)

;; Tag filtering
(cl-agent.tools:list-tools-by-tag *registry* :safe)
(cl-agent.tools:list-tools-by-tags *registry* '(:file :read) :mode :any)
```

## Presets

| Preset | Description |
|--------|-------------|
| `:standard` | File + HTTP + Utility tools |
| `:safe` | Read-only operations |
| `:full` | All tools (including Shell) |
| `:file-only` | File operations only |
| `:http-only` | HTTP operations only |
| `:utility-only` | Utility tools only |

## Built-in Tools

| Tool Factory | Tags |
|--------------|------|
| `make-read-file-tool` | `:file :io :read :safe` |
| `make-write-file-tool` | `:file :io :write` |
| `make-http-get-tool` | `:http :network :read :safe` |
| `make-http-post-tool` | `:http :network :write` |
| `make-execute-command-tool` | `:shell :system :dangerous` |
| `make-get-timestamp-tool` | `:utility :safe` |

## Integration with Kernel

```lisp
;; Using Builder pattern
(defvar *kernel*
  (cl-agent.kernel:build-kernel
    (cl-agent.kernel:with-preset
      (cl-agent.kernel:add-service
        (cl-agent.kernel:create-kernel-builder)
        *provider*)
      :safe
      :security-level :standard)))
```

## Tag Reference

| Tag | Description |
|-----|-------------|
| `:file` | File operations |
| `:http` | HTTP requests |
| `:shell` | Shell commands |
| `:utility` | General utilities |
| `:safe` | Safe read-only operations |
| `:read` | Read operations |
| `:write` | Write operations |
| `:dangerous` | Dangerous operations |
