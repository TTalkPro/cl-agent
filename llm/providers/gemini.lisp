;;;; gemini.lisp
;;;; CL-Agent - Google Gemini 提供商实现
;;;;
;;;; 概述（参照 clj-agent provider/gemini.clj）：
;;;;   Google Gemini —— 经 Google 的 OpenAI 兼容端点，纯声明式定义。
;;;;
;;;; 注意：
;;;;   Google 的 OpenAI 兼容端点为 .../v1beta/openai/chat/completions，
;;;;   base-url 必须含 /openai（默认 endpoint 再拼 /chat/completions）。

(in-package :cl-agent/llm/providers)

(define-openai-compat-provider gemini
  :base-url "https://generativelanguage.googleapis.com/v1beta/openai"
  :env-key "GOOGLE_API_KEY"
  :default-model "gemini-2.0-flash"
  :documentation "Google Gemini 提供商（OpenAI 兼容端点）

需要 GOOGLE_API_KEY 或显式 :api-key。
模型：gemini-2.0-flash、gemini-1.5-pro 等。")
