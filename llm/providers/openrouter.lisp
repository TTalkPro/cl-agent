;;;; openrouter.lisp
;;;; CL-Agent - OpenRouter 提供商实现
;;;;
;;;; 概述：
;;;;   OpenRouter 是多厂商聚合网关，暴露 OpenAI 兼容接口，
;;;;   模型名形如 "<厂商>/<模型>"（openai/gpt-4o、anthropic/claude-sonnet-4、
;;;;   deepseek/deepseek-chat、google/gemini-2.0-flash ...）。
;;;;
;;;; 与其它兼容厂商的唯一差异是两个可选的归因请求头
;;;; （出现在 OpenRouter 的应用排行榜上）：
;;;;   HTTP-Referer - 应用主页
;;;;   X-Title      - 应用名
;;;; 二者都不是鉴权必需项，缺省不发。

(in-package :cl-agent.llm.providers)

(define-openai-compat-provider openrouter
  :base-url "https://openrouter.ai/api/v1"
  :env-key "OPENROUTER_API_KEY"
  :default-model "openai/gpt-4o"
  :documentation "OpenRouter 聚合网关提供商（OpenAI 兼容端点）

需要 OPENROUTER_API_KEY 或显式 :api-key。
模型名为 \"<厂商>/<模型>\"，可经 :extra-params 下发 OpenRouter 专有的
provider / route / transforms 等路由字段。")

;;; ============================================================
;;; 归因请求头
;;; ============================================================

(defun make-openrouter-provider-with-attribution
    (&key referer title (api-url "https://openrouter.ai/api/v1")
          (model "openai/gpt-4o") api-key headers (timeout 120))
  "创建带归因请求头的 OpenRouter provider。

参数：
  REFERER - 应用主页 URL（HTTP-Referer 头，可选）
  TITLE   - 应用名（X-Title 头，可选）
  其余参数同 make-openrouter-provider。

归因头只影响 OpenRouter 的应用排行榜展示，不影响调用本身；
不需要归因时直接用 make-openrouter-provider。"
  (make-openrouter-provider
   :api-url api-url
   :model model
   :api-key api-key
   :timeout timeout
   :headers (merge-header-alists
             (append (when referer `(("HTTP-Referer" . ,referer)))
                     (when title `(("X-Title" . ,title))))
             headers)))
