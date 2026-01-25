# Tools Module

[中文](README.md) | English

Basic tool definitions and tool registration system.

## Directory Structure

```
tools/
├── package-tools.lisp        # Package definition
├── registry.lisp             # Tool registry
├── executor.lisp             # Tool executor
├── schema.lisp               # Schema generation
└── builtin/                  # Built-in tool definitions
    └── ...
```

## Tool Registration

### Registering Tools

```lisp
;; Use register-tool
(register-tool :get-time
  :description "Get current time"
  :parameters '()
  :handler (lambda ()
             (format nil "~A" (get-universal-time))))

;; Tool with parameters
(register-tool :greet
  :description "Greet user"
  :parameters '((:name :type :string :description "User name" :required t))
  :handler (lambda (name)
             (format nil "Hello, ~A!" name)))
```

### Querying Tools

```lisp
;; Get tool information
(get-tool :get-time)
;; => (:name :get-time :description "Get current time" ...)

;; List all tools
(list-tools)
;; => (:get-time :greet ...)

;; Check if tool exists
(tool-exists-p :get-time)
;; => T
```

### Executing Tools

```lisp
;; Execute tool
(execute-tool :greet '("John"))
;; => "Hello, John!"

;; With keyword arguments
(execute-tool :greet '(:name "John"))
;; => "Hello, John!"
```

## Schema Generation

```lisp
;; Generate JSON Schema
(tool-to-json-schema :greet)
;; => {"name": "greet",
;;     "description": "Greet user",
;;     "parameters": {
;;       "type": "object",
;;       "properties": {
;;         "name": {"type": "string", "description": "User name"}
;;       },
;;       "required": ["name"]
;;     }}

;; Batch generation
(tools-to-json-schemas '(:get-time :greet))
```

## Integration with Kernel

```lisp
;; Tools are automatically used by Kernel's plugin system
;; See core/kernel/function.lisp and plugin/ module
```

## Parameter Types

Supported parameter types:

| Type | Keyword | JSON Schema Type |
|------|---------|------------------|
| String | `:string` | `string` |
| Integer | `:int` / `:integer` | `integer` |
| Number | `:number` / `:float` | `number` |
| Boolean | `:bool` / `:boolean` | `boolean` |
| Array | `:array` / `:list` | `array` |
| Object | `:object` / `:hash` | `object` |
