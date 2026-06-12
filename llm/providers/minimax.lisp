;;;; minimax.lisp
;;;; CL-Agent - MiniMax 提供商实现
;;;;
;;;; 概述：
;;;;   MiniMax M 系列推理模型——OpenAI 兼容端点，声明式定义 + 一处特化：
;;;;   M 系列把推理过程放在 content 的 <think>...</think> 块中，
;;;;   通过 llm-chat 的 :around 方法剥离到 llm-response 的 :reasoning 槽。
;;;;
;;;; 支持的模型：
;;;;   - MiniMax-M3（最新，1M 上下文）
;;;;   - MiniMax-M2.7 / MiniMax-M2.7-highspeed
;;;;   - MiniMax-M2.5 / MiniMax-M2.1 / MiniMax-M2
;;;;
;;;; 说明：
;;;;   推理模型建议给足 :max-tokens（思考过程计入输出 token）。

(in-package :cl-agent.llm.providers)

(define-openai-compat-provider minimax
  :base-url "https://api.minimaxi.com/v1"
  :env-key "MINIMAX_AUTH_TOKEN"
  :default-model "MiniMax-M2.7"
  :documentation "MiniMax M 系列提供商（OpenAI 兼容端点）

推理模型：content 中的 <think> 块自动剥离到 llm-response-reasoning。")

;;; ============================================================
;;; MiniMax 特化：剥离 <think> 推理块
;;; ============================================================

(defun split-think-block (content)
  "把 content 开头的 <think>...</think> 块拆出。

返回：
  (values 正文 思考内容)；无 think 块时思考内容为 NIL"
  (let ((start (search "<think>" content))
        (end (search "</think>" content)))
    (if (and start end (< start end))
        (values (string-trim '(#\Space #\Newline #\Tab)
                             (subseq content (+ end (length "</think>"))))
                (string-trim '(#\Space #\Newline #\Tab)
                             (subseq content (+ start (length "<think>")) end)))
        (values content nil))))

(defmethod cl-agent.llm:llm-chat :around ((provider minimax-provider) messages
                                          &key &allow-other-keys)
  "MiniMax M 系列：把 content 中的 <think> 推理块剥离到 reasoning 槽"
  (declare (ignore messages))
  (let ((response (call-next-method)))
    (when (typep response 'cl-agent.core:llm-response)
      (multiple-value-bind (body thinking)
          (split-think-block (cl-agent.core:llm-response-content response))
        (when thinking
          (setf (cl-agent.core:llm-response-content response) body)
          ;; 不覆盖已有 reasoning（如 reasoning_content 字段）
          (unless (cl-agent.core:llm-response-reasoning response)
            (setf (cl-agent.core:llm-response-reasoning response) thinking)))))
    response))
