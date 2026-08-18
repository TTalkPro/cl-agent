;;;; moonshot.lisp
;;;; CL-Agent - 月之暗面 Moonshot AI（Kimi）提供商实现
;;;;
;;;; 概述（参照 ai-sdk packages/moonshotai）：
;;;;   Kimi 系列，OpenAI 兼容接口，纯声明式定义。
;;;;
;;;; 端点：
;;;;   - 海外 https://api.moonshot.ai/v1（默认，与 ai-sdk 一致）
;;;;   - 国内 https://api.moonshot.cn/v1（经 :api-url 切换）
;;;;
;;;; 支持的模型：
;;;;   - kimi-k3 / kimi-k2.7-code / kimi-k2.6 / kimi-k2.5
;;;;   - moonshot-v1-8k / -32k / -128k（按上下文长度计费的旧系列）
;;;;
;;;; 思考预算经 :extra-params 下发（wire 字段 thinking）。

(in-package :cl-agent.llm.providers)

(define-openai-compat-provider moonshot
  :base-url "https://api.moonshot.ai/v1"
  :env-key "MOONSHOT_API_KEY"
  :default-model "kimi-k3"
  :documentation "Moonshot AI（Kimi）提供商（OpenAI 兼容端点）

需要 MOONSHOT_API_KEY 或显式 :api-key。
国内端点：(make-moonshot-provider :api-url \"https://api.moonshot.cn/v1\")")
