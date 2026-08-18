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

;;; ============================================================
;;; OpenRouter 专有参数（路由控制）
;;; ============================================================

(defparameter +openrouter-data-collections+ '(:allow :deny)
  "是否允许下游厂商留存数据")

(defparameter +openrouter-sort-strategies+ '(:price :throughput :latency)
  "多个可用厂商之间的排序策略")

(defun openrouter-extra-params (&key provider-order
                                     (allow-fallbacks nil allow-fallbacks-p)
                                     (require-parameters nil require-parameters-p)
                                     data-collection
                                     sort
                                     models
                                     transforms)
  "构造 OpenRouter 的路由参数，供 :extra-params 使用。

OpenRouter 是网关：同一个模型名可能由多家下游厂商提供，
下面这些字段决定它替你选谁、以及选不到时怎么办。

参数：
  PROVIDER-ORDER     - 优先尝试的下游厂商名列表，如 '(\"anthropic\" \"together\")
  ALLOW-FALLBACKS    - 首选厂商不可用时是否回落（布尔，显式传入才下发）
  REQUIRE-PARAMETERS - 是否只选支持全部请求参数的厂商（布尔）
  DATA-COLLECTION    - :allow / :deny（是否允许下游留存数据）
  SORT               - :price / :throughput / :latency（排序策略）
  MODELS             - 模型级回落列表，如 '(\"openai/gpt-4o\" \"anthropic/claude-sonnet-4\")
  TRANSFORMS         - 上下文压缩策略列表，如 '(\"middle-out\")

返回：
  可直接传给 :extra-params 的 plist；未指定的项不出现。

示例：
  ;; 只走 anthropic，且不允许回落到别家
  (llm-chat provider messages
            :extra-params (openrouter-extra-params
                           :provider-order '(\"anthropic\")
                           :allow-fallbacks nil
                           :data-collection :deny))"
  (let ((params nil)
        (collection (enum->wire data-collection +openrouter-data-collections+
                                :field "data-collection"))
        (sort-by (enum->wire sort +openrouter-sort-strategies+
                             :field "sort")))
    ;; provider 是嵌套对象，任一子项存在即下发
    (when (or provider-order allow-fallbacks-p require-parameters-p
              collection sort-by)
      (setf params
            (append params
                    (list :provider
                          (wire-hash
                           "order" (when provider-order
                                     (coerce provider-order 'vector))
                           "allow_fallbacks" (when allow-fallbacks-p
                                               (or allow-fallbacks :false))
                           "require_parameters" (when require-parameters-p
                                                  (or require-parameters :false))
                           "data_collection" collection
                           "sort" sort-by)))))
    (when models
      (setf params (append params (list :models (coerce models 'vector)))))
    (when transforms
      (setf params (append params (list :transforms (coerce transforms 'vector)))))
    params))
