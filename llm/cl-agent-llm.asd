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

   ;; 注：曾有 schema/ 模块，现已整体移除。
   ;;   - schema/openai.lisp、schema/anthropic.lisp：请求路径从不经过的死副本，
   ;;     与真正在用的 providers/ 下同名近亲只差一个介词
   ;;     （convert-messages-**to**-openai vs convert-messages-**for**-openai；
   ;;      convert-messages-**to**-anthropic vs parse-messages-**for**-anthropic），
   ;;     改错一边不会有任何报错。
   ;;   - schema/response.lisp：58 行注释、1 行代码（in-package），自称
   ;;     "exists for documentation purposes"。注释双向漂移——列了并不存在的
   ;;     llm-response-to-plist，又漏了真有的 reasoning / reasoning-blocks。
   ;; 统一响应 schema 的实现在 core/llm/response.lisp，以 docstring 为准；
   ;; provider 侧的 wire 转换写在 providers/ 下。

   ;; 2. Provider base class
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

   ;; 7. Factory (registry, builder)
   ;; 注：曾有 config.lisp（provider 配置表 + 环境变量加载），但它是个
   ;; 自封闭的死岛——6 个函数无一被 registry/builder/providers 调用，
   ;; 表里的 temperature/model 默认值流不进任何请求，只会误导读者。已删除。
   ;; API key 的读取实际发生在各 make-*-provider 里（读自家环境变量）。
   (:module "factory"
    :components
    ((:file "registry")
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
