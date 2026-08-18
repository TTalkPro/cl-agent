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

;;; ============================================================
;;; SiliconFlow 专有参数
;;; ============================================================

(defun siliconflow-extra-params (&key (enable-thinking nil enable-thinking-p)
                                      thinking-budget
                                      top-k
                                      min-p)
  "构造 SiliconFlow 专有参数，供 :extra-params 使用。

参数：
  ENABLE-THINKING - 是否开启思考（布尔，显式传入才下发；
                    Qwen3 / GLM 等混合推理模型支持）
  THINKING-BUDGET - 思考预算 token 数（整数）
  TOP-K           - Top-K 采样（SiliconFlow 支持，OpenAI 标准字段里没有）
  MIN-P           - 最小概率阈值（0.0 ~ 1.0）

返回：
  可直接传给 :extra-params 的 plist；未指定的项不出现。

示例：
  (llm-chat provider messages
            :extra-params (siliconflow-extra-params :enable-thinking t
                                                    :thinking-budget 2048))"
  (when (and min-p (or (< min-p 0) (> min-p 1)))
    (cl-agent.core:signal-error
     'cl-agent.core:validation-error
     :message (format nil "min-p 应在 [0, 1] 区间，实际 ~S" min-p)
     :field "min-p"))
  (let ((params nil))
    (when enable-thinking-p
      (setf params (append params (list :enable-thinking (and enable-thinking t)))))
    (when thinking-budget
      (setf params (append params (list :thinking-budget thinking-budget))))
    (when top-k
      (setf params (append params (list :top-k top-k))))
    (when min-p
      (setf params (append params (list :min-p min-p))))
    params))
