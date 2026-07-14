;;;; minimax.lisp
;;;; CL-Agent - MiniMax 提供商实现
;;;;
;;;; 概述（对齐 clj-agent provider/minimax.clj）：
;;;;   MiniMax —— Anthropic 兼容实现（MiniMax 官方推荐使用 Anthropic 格式）。
;;;;
;;;;   端点：https://api.minimaxi.com/anthropic/v1/messages
;;;;   鉴权：Authorization: Bearer <MINIMAX_API_KEY>（无需 anthropic-version 头）
;;;;
;;;;   通过继承 anthropic-provider，完整复用其请求构建/响应解析/
;;;;   工具调用实现 —— MiniMax 只是换了 base-url + 路径 + Bearer 鉴权
;;;;   （特化 build-anthropic-headers 扩展点）。
;;;;
;;;; 支持的模型（M 系列推理模型，思考过程计入输出 token，
;;;; 建议给足 :max-tokens）：
;;;;   - MiniMax-M3（最新，1M 上下文）
;;;;   - MiniMax-M2.7 / MiniMax-M2.7-highspeed
;;;;   - MiniMax-M2.5 / MiniMax-M2.1 / MiniMax-M2

(in-package :cl-agent.llm.providers)

;;; ============================================================
;;; MiniMax 提供商类（Anthropic 兼容）
;;; ============================================================

(defclass minimax-provider (anthropic-provider)
  ()
  (:documentation "MiniMax M 系列提供商（Anthropic 兼容端点）

复用 anthropic-provider 的全部实现，仅切换端点与 Bearer 鉴权。
content 中的 <think> 推理块自动剥离到 llm-response-reasoning。"))

(defmethod build-anthropic-headers ((provider minimax-provider))
  "MiniMax：Bearer 鉴权，无需 anthropic-version 头"
  `(("Content-Type" . "application/json")
    ("Authorization" . ,(format nil "Bearer ~A"
                                (anthropic-provider-api-key provider)))))

;;; ============================================================
;;; 工厂函数
;;; ============================================================

(defun make-minimax-provider (&key
                                (api-url "https://api.minimaxi.com")
                                (model "MiniMax-M2.7")
                                api-key
                                (timeout 120))
  "创建 MiniMax 提供商（Anthropic 兼容端点）

参数：
  API-URL - API 基础 URL（默认 https://api.minimaxi.com）
  MODEL   - 默认模型（默认 MiniMax-M2.7）
  API-KEY - API 密钥（可选，从 MINIMAX_API_KEY 环境变量读取）
  TIMEOUT - 请求超时（秒，默认 120）

返回：
  minimax-provider 实例

示例：
  (make-minimax-provider :model \"MiniMax-M3\")"
  (let ((key (or api-key (uiop:getenv "MINIMAX_API_KEY"))))
    (when (null key)
      (cl-agent.core:signal-error
       'cl-agent.core:missing-api-key-error
       :message "MiniMax API 密钥未设置，请设置 MINIMAX_API_KEY 环境变量"
       :config-key "MINIMAX_API_KEY"))
    (make-instance 'minimax-provider
                   :name :minimax
                   :api-url api-url
                   :default-model model
                   :chat-endpoint "/anthropic/v1/messages"
                   :stream-endpoint "/anthropic/v1/messages"
                   :api-key key
                   :timeout timeout)))

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
          ;; 不覆盖已有 reasoning（如 thinking block 已提取的内容）
          (unless (cl-agent.core:llm-response-reasoning response)
            (setf (cl-agent.core:llm-response-reasoning response) thinking)))))
    response))
