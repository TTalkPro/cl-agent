;;;; cl-agent-plugin.asd
;;;; CL-Agent Plugin - Enhanced Plugin System
;;;;
;;;; Version: 1.0.0
;;;; Author: David
;;;;
;;;; Overview:
;;;;   Enhanced plugin system with security policies and resilience patterns.
;;;;   Builds upon cl-agent-tools with additional enterprise features.
;;;;
;;;; Features:
;;;;   - Security policies (rate limiting, input validation, sandboxing)
;;;;   - Resilience patterns (retry, timeout, circuit breaker)
;;;;   - Builtin plugin collection
;;;;   - Plugin aggregation utilities
;;;;
;;;; Directory Structure:
;;;;   plugin/
;;;;   ├── package.lisp       - Package definition
;;;;   ├── security.lisp      - Security policies
;;;;   ├── resilience.lisp    - Resilience patterns
;;;;   ├── builtin/           - Builtin plugins
;;;;   │   ├── file.lisp      - File operations plugin
;;;;   │   ├── http.lisp      - HTTP requests plugin
;;;;   │   ├── shell.lisp     - Shell execution plugin
;;;;   │   └── utility.lisp   - Utility tools plugin
;;;;   └── all.lisp           - Aggregate all plugins
;;;;
;;;; Usage:
;;;;   (asdf:load-system :cl-agent-plugin)
;;;;
;;;;   ;; Create a plugin with security
;;;;   (let ((plugin (make-secure-plugin "my-plugin"
;;;;                   :rate-limit 100
;;;;                   :timeout 30)))
;;;;     ...)
;;;;
;;;;   ;; Use resilience wrapper
;;;;   (with-retry (:attempts 3 :backoff :exponential)
;;;;     (http-get url))

(asdf:defsystem #:cl-agent-plugin
  :description "CL-Agent Plugin - Enhanced Plugin System with Security and Resilience"
  :author "David"
  :license "MIT"
  :version "1.0.0"

  :depends-on (#:cl-agent-core
               #:cl-agent-tools
               #:bordeaux-threads
               #:local-time)

  :serial t
  :components
  (;; === Package Definition ===
   (:file "package")

   ;; === Security Layer ===
   (:file "security")

   ;; === Resilience Patterns ===
   (:file "resilience")

   ;; === Builtin Plugins ===
   (:module "builtin"
    :serial t
    :components
    ((:file "file")
     (:file "http")
     (:file "shell")
     (:file "utility")))

   ;; === Plugin Aggregation ===
   (:file "all")))

