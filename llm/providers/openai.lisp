;;;; openai.lisp
;;;; CL-Agent - OpenAI 提供商实现
;;;;
;;;; 概述：
;;;;   OpenAI GPT 系列提供商——纯声明式定义，
;;;;   完整实现复用 openai-compat 基座。
;;;;
;;;; 支持的模型：
;;;;   - gpt-4o / gpt-4o-mini
;;;;   - gpt-4-turbo / gpt-3.5-turbo

(in-package :cl-agent.llm.providers)

(define-openai-compat-provider openai
  :base-url "https://api.openai.com/v1"
  :env-key "OPENAI_API_KEY"
  :default-model "gpt-4o"
  :documentation "OpenAI GPT 提供商

支持 GPT-4 和 GPT-3.5 系列模型。
兼容端点（如 Azure OpenAI）通过 :api-url 指定。")
