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
  :description "CL-Agent LLM Service Layer - Multi-Provider LLM Client (v4.1.0)"
  :author "David"
  :license "MIT"
  :version "4.1.0"

  :depends-on (#:cl-agent-core
               #:alexandria
               #:cl-ppcre)

  :serial t
  :components
  (;; 1. Package definition
   (:file "package")

   ;; 2. Unified response schema（纯文档，实现在 core/llm/response.lisp）
   ;;
   ;; 这里曾有 openai.lisp / anthropic.lisp 两份「schema 转换器」，
   ;; 但请求路径从不经过它们——真正在用的是 providers/ 下的同名近亲：
   ;;   convert-messages-for-openai   （providers/define-provider.lisp）
   ;;   parse-messages-for-anthropic  （providers/anthropic.lisp）
   ;; 两份死实现只差一个介词（-to- vs -for-），改错一边不会有任何报错，
   ;; 已删除。新增 provider 侧转换逻辑请直接写在 providers/ 下。
   (:module "schema"
    :components
    ((:file "response")))    ; Unified response schema

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
    ((:file "define-provider")  ; Shared wire helpers (OpenAI style)
     (:file "openai-compat")    ; OpenAI 兼容基座 + define-openai-compat-provider
     (:file "anthropic")
     (:file "openai")
     (:file "zhipu")
     (:file "ollama")
     (:file "minimax")
     (:file "deepseek")         ; DeepSeek（含前缀续写 beta）
     (:file "gemini")           ; Google Gemini（OpenAI 兼容端点）
     (:file "mistral")          ; Mistral AI
     (:file "dashscope")))     ; 阿里云 DashScope（通义千问）

   ;; 6. SSE 流式实现（真流式：llm-chat-stream 特化）
   (:module "stream"
    :components
    ((:file "anthropic")       ; Anthropic 格式（anthropic + minimax）
     (:file "openai")))        ; OpenAI 兼容（openai/zhipu/deepseek/...）

   ;; 7. Service layer (response normalization)
   (:file "service")

   ;; 7. Factory (registry, config, builder)
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
