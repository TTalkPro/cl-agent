;;;; model.lisp
;;;; CL-Agent Chat - ChatModel 协议 + Provider 适配器
;;;;
;;;; 概述（对标 Spring AI 2.0 ChatModel / StreamingChatModel）：
;;;;
;;;;   chat-model-call (model prompt) → chat-response      —— ChatModel#call
;;;;   chat-model-stream (model prompt on-chunk) → 最终响应 —— StreamingChatModel#stream
;;;;
;;;;   provider-chat-model 把实现了 cl-agent.core:llm-chat SPI 的任意
;;;;   provider（Anthropic/OpenAI/智谱/MiniMax/Mock...）适配为 ChatModel。
;;;;
;;;; 2.0 架构变更（对齐 Spring AI 2.0 GA）：
;;;;   ChatModel 只负责单次模型调用——解析工具引用并向模型注入工具
;;;;   schema，但**不执行工具**。工具执行循环上移到
;;;;   cl-agent.kernel:run-tool-loop（由 invoke-turn 驱动，ChatClient
;;;;   经 kernel 自动走到）。1.x 的 internal-tool-execution-enabled
;;;;   选项已随之移除。
;;;;
;;;;   直接使用 chat-model-call 且响应携带 tool-calls 时，调用方自行
;;;;   决定处理方式（对标 user-controlled tool execution）：
;;;;     (execute-tool-calls manager prompt response)
;;;;     → tool-execution-result → 用 conversation-history 组新 prompt 再调。

(in-package #:cl-agent.chat)

;;; ============================================================
;;; 条件
;;; ============================================================

(define-condition max-tool-iterations-exceeded-error (error)
  ((limit :initarg :limit :reader max-tool-iterations-limit))
  (:report (lambda (condition stream)
             (format stream "工具执行循环超过最大轮数 ~A"
                     (max-tool-iterations-limit condition)))))

;;; ============================================================
;;; ChatModel 协议
;;; ============================================================

(defclass chat-model ()
  ()
  (:documentation "ChatModel 协议基类（对标 ChatModel 接口）"))

(defgeneric chat-model-call (model prompt)
  (:documentation "同步调用模型（单次，不执行工具）。

参数：
  MODEL  - chat-model 实例
  PROMPT - prompt 实例（或字符串/消息列表，自动包装）

返回：
  chat-response 实例（可能携带 tool-calls，由上层
  cl-agent.kernel:run-tool-loop 或调用方处理）"))

(defgeneric chat-model-stream (model prompt on-chunk)
  (:documentation "流式调用模型（单次，不执行工具）。

参数：
  MODEL    - chat-model 实例
  PROMPT   - prompt 实例
  ON-CHUNK - 回调 (delta-text)，每个文本增量调用一次

返回：
  最终 chat-response 实例

默认实现降级为一次性调用（完整文本作为单个 chunk 回调）。"))

(defgeneric chat-model-default-options (model)
  (:documentation "模型的默认 chat-options（可为 NIL）"))

(defmethod chat-model-default-options ((model chat-model))
  nil)

;;; 便捷：接受字符串 / 消息列表
(defmethod chat-model-call ((model chat-model) (prompt string))
  (chat-model-call model (make-prompt prompt)))

(defmethod chat-model-call ((model chat-model) (prompt list))
  (chat-model-call model (make-prompt prompt)))

(defmethod chat-model-stream ((model chat-model) (prompt string) on-chunk)
  (chat-model-stream model (make-prompt prompt) on-chunk))

(defmethod chat-model-stream ((model chat-model) (prompt list) on-chunk)
  (chat-model-stream model (make-prompt prompt) on-chunk))

;;; 默认流式实现：降级为一次性调用
(defmethod chat-model-stream ((model chat-model) (prompt prompt) on-chunk)
  (let ((response (chat-model-call model prompt)))
    (funcall on-chunk (chat-response-text response))
    response))

;;; ============================================================
;;; Provider 适配器
;;; ============================================================

(defclass provider-chat-model (chat-model)
  ((provider
    :initarg :provider
    :reader chat-model-provider
    :documentation "实现 cl-agent.core:llm-chat 的 provider 实例")
   (default-options
    :initarg :default-options
    :initform nil
    :reader %model-default-options
    :documentation "模型级默认 chat-options"))
  (:documentation "把 llm-chat SPI provider 适配为 ChatModel（单次调用）"))

(defun make-provider-chat-model (provider &key default-options)
  "创建 provider 适配的 ChatModel。

参数：
  PROVIDER        - 实现 llm-chat 泛型函数的 provider 实例
  DEFAULT-OPTIONS - 模型级默认 chat-options（可选）

示例：
  (make-provider-chat-model
    (cl-agent.llm:make-anthropic-provider)
    :default-options (make-chat-options :temperature 0.3))"
  (make-instance 'provider-chat-model
                 :provider provider
                 :default-options default-options))

(defmethod chat-model-default-options ((model provider-chat-model))
  (%model-default-options model))

(defmethod print-object ((model provider-chat-model) stream)
  (print-unreadable-object (model stream :type t)
    (format stream "~A" (type-of (chat-model-provider model)))))

;;; ============================================================
;;; 调用实现（单次，无工具循环）
;;; ============================================================

(defun resolved-options-tools (options)
  "从合并后的选项解析出全部 tool-callback"
  (append (chat-options-tool-callbacks options)
          (resolve-tool-callbacks (chat-options-tool-names options))))

(defun options->spi-args (options)
  "把 chat-options 展开为 llm-chat SPI 的关键字参数 plist
（存在才下发，与 SPI 的\"存在才发送\"约定一致）"
  (let ((args nil))
    (flet ((add (key value)
             (when value
               (push value args)
               (push key args))))
      (add :model (chat-options-model options))
      (add :max-tokens (chat-options-max-tokens options))
      (add :temperature (chat-options-temperature options))
      (add :top-p (chat-options-top-p options))
      (add :top-k (chat-options-top-k options))
      (add :stop (chat-options-stop-sequences options))
      (add :frequency-penalty (chat-options-frequency-penalty options))
      (add :presence-penalty (chat-options-presence-penalty options))
      (add :thinking (chat-options-thinking options))
      (add :extra-params (chat-options-extra-params options)))
    args))

(defmethod chat-model-call ((model provider-chat-model) (prompt prompt))
  "单次模型调用：注入工具 schema，不执行工具。"
  (let* ((options (merge-chat-options (prompt-options prompt)
                                      (chat-model-default-options model)))
         (schemas (mapcar #'tool-callback->schema
                          (resolved-options-tools options)))
         (llm-response (apply #'llm-chat (chat-model-provider model)
                              (messages->neutral (prompt-messages prompt))
                              :tools schemas
                              (options->spi-args options))))
    (llm-response->chat-response llm-response)))

;;; ============================================================
;;; 流式实现（单次；流处理器支持 tool_calls 分片累积）
;;; ============================================================

(defmethod chat-model-stream ((model provider-chat-model) (prompt prompt) on-chunk)
  (let* ((options (merge-chat-options (prompt-options prompt)
                                      (chat-model-default-options model)))
         (schemas (mapcar #'tool-callback->schema
                          (resolved-options-tools options)))
         (provider (chat-model-provider model)))
    (if (not (provider-supports-streaming-p provider))
        ;; provider 不支持流式：降级为一次性调用
        (let ((response (chat-model-call model prompt)))
          (funcall on-chunk (chat-response-text response))
          response)
        ;; 真流式（含工具 schema：tool-calls 由流处理器分片累积）
        (let ((llm-response
                (apply #'llm-chat-stream provider
                       (messages->neutral (prompt-messages prompt))
                       (lambda (chunk)
                         (let ((delta (getf chunk :delta)))
                           (when (and delta (string/= delta ""))
                             (funcall on-chunk delta))))
                       :tools schemas
                       (options->spi-args options))))
          (llm-response->chat-response llm-response)))))
