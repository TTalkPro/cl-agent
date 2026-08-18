;;;; test-vendor-params.lisp
;;;; CL-Agent - 厂商专有参数构造器测试
;;;;
;;;; 覆盖：
;;;;   - xai / moonshot / siliconflow / openrouter 的 <vendor>-extra-params
;;;;   - 取值校验（非法枚举 / 越界 报 validation-error）
;;;;   - 「存在才发送」：未指定的项不出现
;;;;   - 布尔的三态：t / 显式 false / 不传
;;;;   - 产出的 plist 经 build-openai-compatible-request 落到请求体顶层

(in-package :cl-agent/tests)

(def-suite vendor-params-suite :in cl-agent-suite
  :description "厂商专有参数：构造 + 校验 + 下发")

(in-suite vendor-params-suite)

;;; ============================================================
;;; xAI
;;; ============================================================

(test xai-params-reasoning-effort
  "推理档位翻译为 wire 字符串"
  (is (equal '(:reasoning-effort "high")
             (cl-agent.llm.providers:xai-extra-params :reasoning-effort :high)))
  (is (equal '(:reasoning-effort "low")
             (cl-agent.llm.providers:xai-extra-params :reasoning-effort :low))))

(test xai-params-rejects-unsupported-effort
  "xAI 没有 medium 档 —— 拼错的取值当场报错，而不是静默不生效"
  (signals cl-agent.core:validation-error
    (cl-agent.llm.providers:xai-extra-params :reasoning-effort :medium)))

(test xai-params-search-parameters
  "Live Search 组装为嵌套对象"
  (let* ((params (cl-agent.llm.providers:xai-extra-params
                  :search-mode :on
                  :max-search-results 5
                  :return-citations t
                  :sources '(:web :news)))
         (search (getf params :search-parameters)))
    (is (string= "on" (gethash "mode" search)))
    (is (= 5 (gethash "max_search_results" search)))
    (is (eq t (gethash "return_citations" search)))
    (is (= 2 (length (gethash "sources" search))))
    (is (string= "web" (gethash "type" (elt (gethash "sources" search) 0))))
    (is (string= "news" (gethash "type" (elt (gethash "sources" search) 1))))))

(test xai-params-empty-when-nothing-given
  "什么都不传就什么都不发"
  (is (null (cl-agent.llm.providers:xai-extra-params))))

(test xai-params-no-search-object-without-search-fields
  "只给推理档位时不凭空造出 search_parameters"
  (let ((params (cl-agent.llm.providers:xai-extra-params :reasoning-effort :high)))
    (is-false (getf params :search-parameters))))

;;; ============================================================
;;; Moonshot
;;; ============================================================

(test moonshot-params-thinking
  "thinking 组装为 {type, budget_tokens}"
  (let* ((params (cl-agent.llm.providers:moonshot-extra-params
                  :thinking :enabled :thinking-budget 4096))
         (thinking (getf params :thinking)))
    (is (string= "enabled" (gethash "type" thinking)))
    (is (= 4096 (gethash "budget_tokens" thinking)))))

(test moonshot-params-thinking-disabled
  "关闭思考时不带预算"
  (let ((thinking (getf (cl-agent.llm.providers:moonshot-extra-params
                         :thinking :disabled)
                        :thinking)))
    (is (string= "disabled" (gethash "type" thinking)))
    (is-false (nth-value 1 (gethash "budget_tokens" thinking)))))

(test moonshot-params-budget-lower-bound
  "预算下界 1024（官方约束），越界当场报错"
  (signals cl-agent.core:validation-error
    (cl-agent.llm.providers:moonshot-extra-params :thinking-budget 512)))

(test moonshot-params-reasoning-effort-only-max
  "K3 目前只接受 max"
  (is (equal "max" (getf (cl-agent.llm.providers:moonshot-extra-params
                          :reasoning-effort :max)
                         :reasoning-effort)))
  (signals cl-agent.core:validation-error
    (cl-agent.llm.providers:moonshot-extra-params :reasoning-effort :high)))

(test moonshot-params-reasoning-history
  "多轮思考保留策略"
  (is (equal "interleaved"
             (getf (cl-agent.llm.providers:moonshot-extra-params
                    :reasoning-history :interleaved)
                   :reasoning-history)))
  (signals cl-agent.core:validation-error
    (cl-agent.llm.providers:moonshot-extra-params :reasoning-history :keep)))

;;; ============================================================
;;; SiliconFlow
;;; ============================================================

(test siliconflow-params-thinking
  "思考开关 + 预算"
  (let ((params (cl-agent.llm.providers:siliconflow-extra-params
                 :enable-thinking t :thinking-budget 2048)))
    (is (eq t (getf params :enable-thinking)))
    (is (= 2048 (getf params :thinking-budget)))))

(test siliconflow-params-explicit-false
  "显式关闭思考要能发出 false —— 与「不传」区分开"
  (let ((off (cl-agent.llm.providers:siliconflow-extra-params
              :enable-thinking nil))
        (absent (cl-agent.llm.providers:siliconflow-extra-params)))
    ;; 键在，值为 NIL（序列化为 JSON false）
    (is (member :enable-thinking off))
    (is (null (getf off :enable-thinking)))
    ;; 不传时键根本不出现
    (is-false (member :enable-thinking absent))))

(test siliconflow-params-min-p-range
  "min-p 越界报错"
  (is (= 0.05 (getf (cl-agent.llm.providers:siliconflow-extra-params :min-p 0.05)
                    :min-p)))
  (signals cl-agent.core:validation-error
    (cl-agent.llm.providers:siliconflow-extra-params :min-p 1.5)))

;;; ============================================================
;;; OpenRouter
;;; ============================================================

(test openrouter-params-provider-routing
  "路由字段组装为 provider 嵌套对象"
  (let* ((params (cl-agent.llm.providers:openrouter-extra-params
                  :provider-order '("anthropic" "together")
                  :allow-fallbacks nil
                  :data-collection :deny
                  :sort :throughput))
         (provider (getf params :provider)))
    (is (equalp #("anthropic" "together") (gethash "order" provider)))
    ;; 显式 false 必须发出去：allow_fallbacks 缺省是 true，
    ;; 不发就等于没关掉回落
    (is (member "allow_fallbacks" (loop for k being the hash-keys of provider
                                        collect k)
                :test #'string=))
    (is (null (gethash "allow_fallbacks" provider)))
    (is (string= "deny" (gethash "data_collection" provider)))
    (is (string= "throughput" (gethash "sort" provider)))))

(test openrouter-params-model-fallbacks
  "模型级回落列表与上下文压缩策略"
  (let ((params (cl-agent.llm.providers:openrouter-extra-params
                 :models '("openai/gpt-4o" "anthropic/claude-sonnet-4")
                 :transforms '("middle-out"))))
    (is (equalp #("openai/gpt-4o" "anthropic/claude-sonnet-4")
                (getf params :models)))
    (is (equalp #("middle-out") (getf params :transforms)))
    ;; 没给路由字段就不造 provider 对象
    (is-false (getf params :provider))))

(test openrouter-params-rejects-bad-enum
  "非法枚举当场报错"
  (signals cl-agent.core:validation-error
    (cl-agent.llm.providers:openrouter-extra-params :data-collection :maybe))
  (signals cl-agent.core:validation-error
    (cl-agent.llm.providers:openrouter-extra-params :sort :quality)))

;;; ============================================================
;;; 落到请求体
;;; ============================================================

(test vendor-params-reach-request-body
  "构造器产出的 plist 经 :extra-params 落到请求体顶层，键名转下划线风格"
  (let ((body (cl-agent.llm.providers::build-openai-compatible-request
               (cl-agent.llm.providers:make-xai-provider :api-key "k")
               (list (list :role :user :content "hi"))
               :extra-params (cl-agent.llm.providers:xai-extra-params
                              :reasoning-effort :high
                              :search-mode :auto))))
    (is (string= "high" (gethash "reasoning_effort" body)))
    (is (string= "auto" (gethash "mode" (gethash "search_parameters" body))))))

(test vendor-params-flow-through-chat-options
  "也能经 chat-options 的 extra-params 一路下发到 SPI"
  (let* ((provider (make-seq-provider (text-response "ok")))
         (model (cl-agent.core:make-provider-chat-model provider)))
    (cl-agent.core:chat-model-call
     model
     (cl-agent.core:make-prompt
      "hi"
      :options (cl-agent.core:make-chat-options
                :extra-params (cl-agent.llm.providers:moonshot-extra-params
                               :thinking :enabled :thinking-budget 2048))))
    (let ((thinking (getf (getf (first (seq-provider-requests provider))
                                :extra-params)
                          :thinking)))
      (is (string= "enabled" (gethash "type" thinking)))
      (is (= 2048 (gethash "budget_tokens" thinking))))))
