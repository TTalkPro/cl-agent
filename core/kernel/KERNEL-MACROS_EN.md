# Kernel Macros

[中文](KERNEL-MACROS.md) | English

## `defkernel` - Declarative Tool Function Definition

Core purpose: **Single declaration, generates both callable function and LLM tool schema**.

```lisp
(defkernel get-weather "Get weather"
  ((city :string "City name" :required-p t)
   (unit :string "Temperature unit" :default "celsius"))
  (format nil "~A weather: sunny, 22°~A" city unit))
```

Expands to two things:

1. **A regular defun** (can be called directly in Lisp):
   ```lisp
   (defun get-weather (&key city (unit "celsius")) ...)
   ```

2. **A `kernel-function` instance** (stores schema metadata for LLM recognition):
   ```lisp
   (defparameter *kf-get-weather*
     (make-kernel-function
       :name :get-weather
       :description "Get weather"
       :handler #'get-weather
       :parameters '((city :string "City name" :required-p t) ...)
       ...))
   ```

The `:string`, `:required-p`, `:default` in parameter specs are automatically converted to JSON Schema, sent to LLM as tool definition. This way function signature and schema always stay in sync, never inconsistent.

---

## `defplugin` - Organize Multiple kernel-functions as Plugin

Core purpose: **Bundle related tools into a named collection**, easy to register to kernel.

```lisp
(defplugin weather-plugin "Weather tools collection"
  *kf-get-weather*
  *kf-get-forecast*)
```

Expands to:
```lisp
(defparameter *plugin-weather-plugin*
  (create-plugin :weather-plugin "Weather tools collection"
                 (list *kf-get-weather* *kf-get-forecast*)))
```

Then mount as needed when creating kernel:
```lisp
(make-kernel :chat-service provider
             :plugins (list *plugin-weather-plugin*
                            *plugin-math-plugin*))
```

---

## Overall Relationship

```
defkernel  →  *kf-xxx*  (single tool definition)
                ↓
defplugin  →  *plugin-xxx*  (tool collection)
                ↓
make-kernel  →  kernel instance  (mount plugins, provide chat-completion)
```

This pattern is inspired by Microsoft Semantic Kernel's design: kernel-function is the minimum execution unit, plugin is a grouping container, kernel is the runtime coordinator. The benefit is tool definitions are completely decoupled from LLM call logic — the same set of plugins can be mounted to different kernels (different models/providers).
