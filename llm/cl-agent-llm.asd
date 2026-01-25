;;;; cl-agent-llm.asd
;;;; CL-Agent LLM Service System
;;;;
;;;; Version: 4.0.0
;;;; Author: David
;;;;
;;;; Overview:
;;;;   LLM (Large Language Model) service layer supporting multiple providers
;;;;
;;;; Architecture:
;;;;   - schema/: Tool schema converters (OpenAI, Anthropic formats)
;;;;   - providers/: Provider implementations
;;;;   - factory/: Provider registry, config, builder
;;;;   - Unified client interface
;;;;
;;;; Supported Providers:
;;;;   - Anthropic Claude
;;;;   - OpenAI GPT
;;;;   - ZhipuAI GLM
;;;;   - Ollama (local)
;;;;
;;;; Usage:
;;;;   ;; Create a service for Kernel
;;;;   (create-service :anthropic :model "claude-sonnet-4-20250514")
;;;;
;;;;   ;; Use provider builder
;;;;   (-> (create-provider-builder :openai)
;;;;       (with-model "gpt-4o")
;;;;       (build-provider))

(asdf:defsystem #:cl-agent-llm
  :description "CL-Agent LLM Service Layer - Multi-Provider LLM Client (v4.0.0)"
  :author "David"
  :license "MIT"
  :version "4.0.0"

  :depends-on (#:cl-agent-core
               #:cl-ppcre)

  :serial t
  :components
  (;; 1. Package definition
   (:file "package")

   ;; 2. Schema converters
   (:module "schema"
    :components
    ((:file "openai")
     (:file "anthropic")))

   ;; 3. Provider base class
   (:module "provider-base"
    :pathname "providers/"
    :components ((:file "base")))

   ;; 4. Main modules
   (:file "providers")
   (:file "client")
   (:file "streaming")

   ;; 5. Provider implementations
   (:module "provider-impls"
    :pathname "providers/"
    :components
    ((:file "define-provider")  ; Common macros and functions
     (:file "anthropic")
     (:file "openai")
     (:file "zhipu")
     (:file "bailian")))       ; 阿里云百炼 DashScope

   ;; 6. Factory (registry, config, builder)
   (:module "factory"
    :components
    ((:file "registry")
     (:file "config")
     (:file "builder")))))

;; ============================================================
;; Changelog
;; ============================================================
;;
;; v4.0.0:
;; - Added schema/ module for tool schema converters
;; - Added factory/ module with registry, config, builder
;; - Added create-service for Kernel integration
;; - Provider builder with fluent API
;;
;; v3.0.0:
;; - Kernel integration via llm-chat generic function
;;
;; v2.0.0:
;; - HTTP client from cl-agent.http
;;
;; v1.0.0:
;; - Initial multi-provider support
