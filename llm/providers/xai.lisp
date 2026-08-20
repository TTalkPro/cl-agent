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

(in-package :cl-agent/llm/providers)

(define-openai-compat-provider xai
  :base-url "https://api.x.ai/v1"
  :env-key "XAI_API_KEY"
  :default-model "grok-4.5"
  :documentation "xAI Grok 提供商（OpenAI 兼容端点）

需要 XAI_API_KEY 或显式 :api-key。
模型：grok-4.5、grok-4.3、grok-4.20-reasoning、grok-latest 等。")

;;; ============================================================
;;; xAI 专有参数
;;; ============================================================

(defparameter +xai-reasoning-efforts+ '(:low :high)
  "grok 推理档位取值（xAI 只支持 low / high，没有 medium）")

(defparameter +xai-search-modes+ '(:auto :on :off)
  "Live Search 模式：:auto 由模型决定，:on 强制检索，:off 关闭")

(defparameter +xai-source-types+ '(:web :x :news :rss)
  "Live Search 数据源类型")

(defun xai-extra-params (&key reasoning-effort
                              search-mode
                              max-search-results
                              (return-citations nil return-citations-p)
                              sources)
  "构造 xAI 专有参数，供 llm-chat / chat-options 的 :extra-params 使用。

参数：
  REASONING-EFFORT   - :low / :high（仅推理型 grok 支持）
  SEARCH-MODE        - :auto / :on / :off（Live Search）
  MAX-SEARCH-RESULTS - 检索结果上限（整数）
  RETURN-CITATIONS   - 是否返回引用来源（布尔，显式传入才下发）
  SOURCES            - 数据源类型列表，如 '(:web :news)

返回：
  可直接传给 :extra-params 的 plist；未指定的项不出现。

取值非法时报 validation-error —— 逃生通道拼错字段不会有任何报错，
这里把错误提前到构造时。

示例：
  (llm-chat provider messages
            :extra-params (xai-extra-params :reasoning-effort :high))

  (cl-agent/core:make-chat-options
    :extra-params (xai-extra-params :search-mode :on
                                    :sources '(:web :news)
                                    :return-citations t))"
  (let ((params nil)
        (effort (enum->wire reasoning-effort +xai-reasoning-efforts+
                            :field "reasoning-effort"))
        (mode (enum->wire search-mode +xai-search-modes+
                          :field "search-mode")))
    (when effort
      (setf params (append params (list :reasoning-effort effort))))
    ;; search_parameters 是嵌套对象，任一子项存在即下发
    (when (or mode max-search-results return-citations-p sources)
      (let ((search (wire-hash
                     "mode" mode
                     "max_search_results" max-search-results
                     "return_citations" (when return-citations-p
                                          (or return-citations :false))
                     "sources" (when sources
                                 (coerce
                                  (mapcar
                                   (lambda (source)
                                     (wire-hash
                                      "type" (enum->wire source +xai-source-types+
                                                         :field "sources")))
                                   sources)
                                  'vector)))))
        (setf params (append params (list :search-parameters search)))))
    params))
