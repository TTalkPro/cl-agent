;;;; mistral.lisp
;;;; CL-Agent - Mistral AI 提供商实现
;;;;
;;;; 概述（参照 clj-agent provider/mistral.clj）：
;;;;   Mistral AI —— OpenAI 兼容实现，纯声明式定义。

(in-package :cl-agent.llm.providers)

(define-openai-compat-provider mistral
  :base-url "https://api.mistral.ai/v1"
  :env-key "MISTRAL_API_KEY"
  :default-model "mistral-large-latest"
  :documentation "Mistral AI 提供商（OpenAI 兼容端点）

需要 MISTRAL_API_KEY 或显式 :api-key。
模型：mistral-large-latest、mistral-small-latest、codestral-latest 等。")
