;;;; xai.lisp
;;;; CL-Agent - xAI Grok 提供商实现
;;;;
;;;; 概述（参照 ai-sdk packages/xai）：
;;;;   xAI 的 /v1/chat/completions 是 OpenAI 兼容接口，纯声明式定义。
;;;;
;;;; 支持的模型：
;;;;   - grok-4.5 / grok-4.3（推理）
;;;;   - grok-4.20-reasoning / grok-4.20-non-reasoning
;;;;   - grok-latest（滚动别名）
;;;;
;;;; 推理档位经 :extra-params 下发（wire 字段 reasoning_effort，
;;;; 取值 "low" / "high"）：
;;;;   (llm-chat provider msgs :extra-params '(:reasoning-effort "high"))

(in-package :cl-agent.llm.providers)

(define-openai-compat-provider xai
  :base-url "https://api.x.ai/v1"
  :env-key "XAI_API_KEY"
  :default-model "grok-4.5"
  :documentation "xAI Grok 提供商（OpenAI 兼容端点）

需要 XAI_API_KEY 或显式 :api-key。
模型：grok-4.5、grok-4.3、grok-4.20-reasoning、grok-latest 等。")
