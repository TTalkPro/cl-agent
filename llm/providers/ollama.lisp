;;;; ollama.lisp
;;;; CL-Agent - Ollama 本地模型提供商
;;;;
;;;; 概述：
;;;;   Ollama 提供 OpenAI 兼容端点（/v1/chat/completions），
;;;;   直接复用 openai-compat 基座（与 clj-agent 的处理一致）。
;;;;   本地服务，无需 API 密钥。

(in-package :cl-agent.llm.providers)

(define-openai-compat-provider ollama
  :base-url "http://localhost:11434"
  :chat-endpoint "/v1/chat/completions"
  :default-model "llama3.2"
  :key-optional t
  :documentation "Ollama 本地模型提供商（OpenAI 兼容端点）

支持本地运行的开源模型，如 Llama、Mistral 等。无需 API 密钥。")

(defmethod cl-agent.llm:llm-available-p ((provider ollama-provider))
  "Ollama 是本地服务：不依赖 API 密钥，始终可用
（实际可用性取决于 Ollama 服务是否运行）"
  t)
