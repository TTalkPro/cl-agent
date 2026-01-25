# CL-Agent Kernel Plugin Design

[中文](KERNEL-DESIGN.md) | English

## Design Principles

1. **No Global Variables** — Tool instances are held by plugin objects, no dependency on `defparameter`
2. **CLOS Double Dispatch** — `tool-invoke (plugin-class × eql-tool-name)` determines call path at compile time
3. **Protocol as Skeleton** — Framework only defines `defgeneric`, users implement `defmethod`
4. **Macros as Syntactic Sugar** — `defplugin` / `deftool` simplify declarations but are not required

---

## Architecture Overview

```
┌──────────────────────────────────────────────────┐
│  User Code                                        │
│  ┌──────────────┐   ┌──────────────────────────┐ │
│  │ defplugin    │   │ deftool                  │ │
│  │ (sugar)      │   │ (sugar)                  │ │
│  └──────┬───────┘   └───────────┬──────────────┘ │
│         │                       │                 │
│         ▼                       ▼                 │
│  ┌──────────────┐   ┌──────────────────────────┐ │
│  │ defclass     │   │ defmethod                │ │
│  │ defmethod    │   │  tool-invoke             │ │
│  │  plugin-name │   │  tool-description        │ │
│  │  plugin-desc │   │  tool-schema             │ │
│  └──────┬───────┘   └───────────┬──────────────┘ │
├─────────┼───────────────────────┼─────────────────┤
│  Framework Protocol Layer                         │
│         ▼                       ▼                 │
│  ┌────────────────────────────────────────────┐   │
│  │ CLOS Double Dispatch                       │   │
│  │ (plugin-class × eql-tool-name) → method    │   │
│  └────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────┘
```

---

## Layer 1: CLOS Protocol (Core, No Macros)

### Base Class

```lisp
(defclass kernel-plugin ()
  ((tools-cache :initform nil :accessor plugin-tools-cache))
  (:documentation "Base class for all plugins"))
```

### Plugin-Level Protocol

```lisp
(defgeneric plugin-name (plugin)
  (:documentation "Returns plugin name keyword"))

(defgeneric plugin-description (plugin)
  (:documentation "Returns plugin description string"))

(defgeneric plugin-tools (plugin)
  (:documentation "Returns list of tool name keywords supported by this plugin"))
```

### Tool-Level Protocol (Double Dispatch)

```lisp
(defgeneric tool-invoke (plugin tool-name args)
  (:documentation "Execute tool.
  PLUGIN    - Plugin instance (provides class dispatch)
  TOOL-NAME - Tool name keyword (provides EQL dispatch)
  ARGS      - Arguments plist"))

(defgeneric tool-description (plugin tool-name)
  (:documentation "Returns tool description string"))

(defgeneric tool-schema (plugin tool-name)
  (:documentation "Returns tool parameter JSON Schema (hash-table)"))
```

### Pure Protocol Usage (Without Any Macros)

```lisp
(defclass weather-plugin (kernel-plugin)
  ((api-key :initarg :api-key :reader plugin-api-key)))

(defmethod plugin-name ((p weather-plugin)) :weather-plugin)
(defmethod plugin-description ((p weather-plugin)) "Weather tools collection")
(defmethod plugin-tools ((p weather-plugin)) '(:get-weather :get-forecast))

;; --- :get-weather ---
(defmethod tool-description ((p weather-plugin) (name (eql :get-weather)))
  "Get current weather for specified city")

(defmethod tool-schema ((p weather-plugin) (name (eql :get-weather)))
  (params->json-schema
   '((city :string "City name" :required t)
     (unit :string "Temperature unit" :default "celsius"))))

(defmethod tool-invoke ((p weather-plugin) (name (eql :get-weather)) args)
  (let ((city (getf args :city))
        (unit (getf args :unit "celsius")))
    (format nil "~A: sunny, 22°~A" city unit)))

;; --- :get-forecast ---
(defmethod tool-description ((p weather-plugin) (name (eql :get-forecast)))
  "Get weather forecast")

(defmethod tool-schema ((p weather-plugin) (name (eql :get-forecast)))
  (params->json-schema
   '((city :string "City name" :required t)
     (days :int "Forecast days" :default 3))))

(defmethod tool-invoke ((p weather-plugin) (name (eql :get-forecast)) args)
  (format nil "~A next ~A days: sunny to cloudy" (getf args :city) (getf args :days 3)))
```

---

## Layer 2: Macro Syntactic Sugar

### defplugin

```lisp
(defplugin weather-plugin ()
  "Weather tools collection"
  ((api-key :initarg :api-key :reader plugin-api-key)
   (base-url :initarg :base-url :initform "https://api.weather.com")))
```

Expands to:

```lisp
(progn
  (defclass weather-plugin (kernel-plugin)
    ((api-key :initarg :api-key :reader plugin-api-key)
     (base-url :initarg :base-url :initform "https://api.weather.com")))

  (defmethod plugin-name ((p weather-plugin))
    :weather-plugin)

  (defmethod plugin-description ((p weather-plugin))
    "Weather tools collection"))
```

### deftool

```lisp
(deftool (weather-plugin :get-weather)
  "Get weather information for specified city"
  ((city :string "City name" :required t)
   (unit :string "Temperature unit" :default "celsius"))
  (format nil "~A: sunny, 22°~A (via ~A)"
          city unit (plugin-api-key plugin)))
```

Expands to:

```lisp
(progn
  ;; Register tool name to class metadata
  (register-tool-name 'weather-plugin :get-weather)

  ;; Description
  (defmethod tool-description ((plugin weather-plugin)
                               (name (eql :get-weather)))
    "Get weather information for specified city")

  ;; Schema
  (defmethod tool-schema ((plugin weather-plugin)
                          (name (eql :get-weather)))
    (params->json-schema
     '((city :string "City name" :required t)
       (unit :string "Temperature unit" :default "celsius"))))

  ;; Execution (plugin variable available in body)
  (defmethod tool-invoke ((plugin weather-plugin)
                          (name (eql :get-weather))
                          args)
    (let ((city (getf args :city))
          (unit (getf args :unit "celsius")))
      (format nil "~A: sunny, 22°~A (via ~A)"
              city unit (plugin-api-key plugin)))))
```

### Tool Name Registration (plugin-tools Auto Implementation)

```lisp
;; Compile-time metadata (only stores class-name → tool-names mapping)
(defvar *plugin-tool-registry* (make-hash-table :test #'eq))

(defun register-tool-name (class-name tool-name)
  (pushnew tool-name (gethash class-name *plugin-tool-registry*)))

;; plugin-tools default implementation: read from registry
(defmethod plugin-tools ((p kernel-plugin))
  (gethash (class-name (class-of p)) *plugin-tool-registry*))
```

Note: `*plugin-tool-registry*` is **compile-time metadata** (similar to CLOS's own class registry), not tool instances. Users can manually `defmethod plugin-tools` to override this behavior.

---

## Layer 3: Kernel Integration

### tool_call Stage Dispatch Path

```
LLM returns: {name: "get_weather", arguments: {"city": "Beijing"}}
        │
        ▼
kernel-execute-tool(kernel, :get-weather, (:city "Beijing"))
        │
        ├── find-plugin-for-tool  →  Iterate plugins, check plugin-tools
        │
        ▼
(tool-invoke <weather-plugin> :get-weather (:city "Beijing"))
        │
        ▼
CLOS discriminating function:
   specializer-1: (typep obj 'weather-plugin)  → class test
   specializer-2: (eq name :get-weather)       → eq test
        │
        ▼
Direct jump to method body (no hash-table lookup)
```

### Kernel Implementation

```lisp
(defun kernel-get-tools (kernel)
  "Collect all plugin tool schemas (passed to LLM tools parameter)"
  (loop for plugin in (kernel-plugins kernel)
        nconc (loop for tool-name in (plugin-tools plugin)
                    collect
                    (list :name (string-downcase (symbol-name tool-name))
                          :description (tool-description plugin tool-name)
                          :input-schema (tool-schema plugin tool-name)))))

(defun kernel-execute-tool (kernel fn-name args)
  "Find and execute tool"
  (let ((plugin (find-plugin-for-tool kernel fn-name)))
    (unless plugin
      (error "Tool ~A not found in any plugin" fn-name))
    (tool-invoke plugin fn-name args)))

(defun find-plugin-for-tool (kernel fn-name)
  "Find plugin containing specified tool"
  (loop for plugin in (kernel-plugins kernel)
        when (member fn-name (plugin-tools plugin))
          return plugin))
```

---

## Usage Examples

### Using Macros (Recommended, Concise)

```lisp
(defplugin weather-plugin ()
  "Weather tools collection"
  ((api-key :initarg :api-key :reader plugin-api-key)))

(deftool (weather-plugin :get-weather)
  "Get weather information for specified city"
  ((city :string "City name" :required t)
   (unit :string "Temperature unit" :default "celsius"))
  (format nil "~A: sunny, 22°~A (via ~A)"
          city unit (plugin-api-key plugin)))

(deftool (weather-plugin :get-forecast)
  "Get weather forecast"
  ((city :string "City name" :required t)
   (days :int "Forecast days" :default 3))
  (format nil "~A next ~A days: sunny to cloudy" city days))

;; Instantiate (no global variables)
(let* ((wp (make-instance 'weather-plugin :api-key "my-key"))
       (kernel (make-kernel
                 :chat-service provider
                 :plugins (list wp))))
  (chat-completion kernel history
    :settings '(:system-prompt "You are a helpful assistant")))
```

### Without Macros (Pure CLOS)

```lisp
(defclass weather-plugin (kernel-plugin)
  ((api-key :initarg :api-key :reader plugin-api-key)))

(defmethod plugin-name ((p weather-plugin)) :weather-plugin)
(defmethod plugin-description ((p weather-plugin)) "Weather tools collection")
(defmethod plugin-tools ((p weather-plugin)) '(:get-weather))

(defmethod tool-description ((p weather-plugin) (name (eql :get-weather)))
  "Get weather")

(defmethod tool-schema ((p weather-plugin) (name (eql :get-weather)))
  (params->json-schema '((city :string "City name" :required t))))

(defmethod tool-invoke ((p weather-plugin) (name (eql :get-weather)) args)
  (format nil "~A: sunny" (getf args :city)))

;; Usage is exactly the same
(let* ((wp (make-instance 'weather-plugin :api-key "my-key"))
       (kernel (make-kernel :chat-service provider :plugins (list wp))))
  (chat-completion kernel history :settings ...))
```

---

## Key Advantages

| Feature | Description |
|---------|-------------|
| No Global Variables | Tool lifecycle managed by plugin instances |
| Compile-time Dispatch | CLOS method caching, no runtime hash-table |
| Plugin Can Hold State | api-key, config etc. accessed via slots |
| Multiple Instances Coexist | Same plugin class can create multiple differently configured instances |
| Testable | Pass in mock plugin instances, no need to mock global state |
| Extensible | Any package can defmethod to add new tools to existing plugin |
| Two Styles Coexist | Macros and pure CLOS can be mixed, macros are just sugar |
