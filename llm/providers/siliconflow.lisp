;;;; siliconflow.lisp
;;;; CL-Agent - SiliconFlow（硅基流动）提供商实现
;;;;
;;;; 概述：
;;;;   硅基流动是国内的多模型聚合平台，暴露 OpenAI 兼容接口，
;;;;   同一套密钥覆盖对话、多模态与嵌入三类模型。
;;;;
;;;; 端点：
;;;;   - 国内 https://api.siliconflow.cn/v1（默认）
;;;;   - 海外 https://api.siliconflow.com/v1（经 :api-url 切换）
;;;;
;;;; 模型名为 "<组织>/<模型>" 全路径：
;;;;   对话   deepseek-ai/DeepSeek-V3、Qwen/Qwen2.5-72B-Instruct、
;;;;          THUDM/GLM-4-9B-Chat
;;;;   多模态 Qwen/Qwen2.5-VL-72B-Instruct（走统一的 :media 通道）
;;;;   嵌入   BAAI/bge-m3、BAAI/bge-large-zh-v1.5（见 embeddings.lisp）

(in-package :cl-agent.llm.providers)

(define-openai-compat-provider siliconflow
  :base-url "https://api.siliconflow.cn/v1"
  :env-key "SILICONFLOW_API_KEY"
  :env-keys ("SILICON_API_KEY")
  :default-model "deepseek-ai/DeepSeek-V3"
  :documentation "SiliconFlow（硅基流动）提供商（OpenAI 兼容端点）

需要 SILICONFLOW_API_KEY 或显式 :api-key。
模型名用 \"<组织>/<模型>\" 全路径；嵌入模型见 provider-default-embedding-model。
海外站点：(make-siliconflow-provider :api-url \"https://api.siliconflow.com/v1\")")
