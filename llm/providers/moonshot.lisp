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

;;; ============================================================
;;; Moonshot 专有参数
;;; ============================================================

(defparameter +moonshot-thinking-types+ '(:enabled :disabled)
  "Kimi 思考开关取值")

(defparameter +moonshot-reasoning-efforts+ '(:max)
  "Kimi K3 的推理档位——目前官方只接受 max")

(defparameter +moonshot-reasoning-histories+ '(:disabled :interleaved :preserved)
  "多轮对话中思考内容的保留策略")

(defun moonshot-extra-params (&key thinking
                                   thinking-budget
                                   reasoning-effort
                                   reasoning-history)
  "构造 Moonshot（Kimi）专有参数，供 :extra-params 使用。

参数：
  THINKING          - :enabled / :disabled（思考开关）
  THINKING-BUDGET   - 思考预算 token 数（整数，>= 1024）
  REASONING-EFFORT  - :max（仅 K3）
  REASONING-HISTORY - :disabled / :interleaved / :preserved

返回：
  可直接传给 :extra-params 的 plist；未指定的项不出现。

注：中立的 :thinking 选项（chat-options 的 thinking 槽）目前只有
Anthropic 系 provider 实现。Kimi 的思考走自家 wire 字段，故单列于此；
两者语义相近但不是同一个旋钮，不要同时传。

示例：
  (llm-chat provider messages
            :extra-params (moonshot-extra-params :thinking :enabled
                                                 :thinking-budget 4096))"
  (let ((params nil)
        (type (enum->wire thinking +moonshot-thinking-types+
                          :field "thinking"))
        (effort (enum->wire reasoning-effort +moonshot-reasoning-efforts+
                            :field "reasoning-effort"))
        (history (enum->wire reasoning-history +moonshot-reasoning-histories+
                             :field "reasoning-history")))
    (when (and thinking-budget (< thinking-budget 1024))
      (cl-agent.core:signal-error
       'cl-agent.core:validation-error
       :message (format nil "thinking-budget 不得小于 1024，实际 ~S" thinking-budget)
       :field "thinking-budget"))
    (when (or type thinking-budget)
      (setf params (append params
                           (list :thinking (wire-hash
                                            "type" type
                                            "budget_tokens" thinking-budget)))))
    (when effort
      (setf params (append params (list :reasoning-effort effort))))
    (when history
      (setf params (append params (list :reasoning-history history))))
    params))
