;;;; model.lisp
;;;; CL-Agent Chat - ChatModel 协议 + Provider 适配器
;;;;
;;;; 概述（对标 Spring AI ChatModel / StreamingChatModel）：
;;;;
;;;;   chat-model-call (model prompt) → chat-response      —— ChatModel#call
;;;;   chat-model-stream (model prompt on-chunk) → 最终响应 —— StreamingChatModel#stream
;;;;
;;;;   provider-chat-model 把实现了 cl-agent.core:llm-chat SPI 的任意
;;;;   provider（Anthropic/OpenAI/智谱/Ollama/Mock...）适配为 ChatModel，
;;;;   并承担内部工具执行循环（对标 internalToolExecutionEnabled=true 时
;;;;   Spring AI 在 ChatModel 内完成的 tool-call → 执行 → 回传 循环）。
;;;;
;;;; 调用流程：
;;;;   1. 合并选项：prompt options（运行时）覆盖 model 默认 options
;;;;   2. 解析工具：tool-callbacks + tool-names → schema 列表
;;;;   3. CLOS 消息 → 中立 plist → llm-chat → llm-response → chat-response
;;;;   4. 若响应携带 tool-calls 且启用内部执行：
;;;;      执行工具 → assistant 消息 + tool 消息追加进会话 → 回到 3
;;;;      （return-direct 工具立即终止循环）

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
  (:documentation "同步调用模型。

参数：
  MODEL  - chat-model 实例
  PROMPT - prompt 实例（或字符串/消息列表，自动包装）

返回：
  chat-response 实例"))

(defgeneric chat-model-stream (model prompt on-chunk)
  (:documentation "流式调用模型。

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
    :documentation "模型级默认 chat-options")
   (tool-calling-manager
    :initarg :tool-calling-manager
    :reader model-tool-calling-manager
    :documentation "工具执行器（默认 default-tool-calling-manager）"))
  (:documentation "把 llm-chat SPI provider 适配为 ChatModel"))

(defun make-provider-chat-model (provider &key default-options tool-calling-manager)
  "创建 provider 适配的 ChatModel。

参数：
  PROVIDER             - 实现 llm-chat 泛型函数的 provider 实例
  DEFAULT-OPTIONS      - 模型级默认 chat-options（可选）
  TOOL-CALLING-MANAGER - 自定义工具执行器（可选）

示例：
  (make-provider-chat-model
    (cl-agent.llm:make-anthropic-provider)
    :default-options (make-chat-options :temperature 0.3))"
  (make-instance 'provider-chat-model
                 :provider provider
                 :default-options default-options
                 :tool-calling-manager (or tool-calling-manager
                                           (make-default-tool-calling-manager))))

(defmethod chat-model-default-options ((model provider-chat-model))
  (%model-default-options model))

(defmethod print-object ((model provider-chat-model) stream)
  (print-unreadable-object (model stream :type t)
    (format stream "~A" (type-of (chat-model-provider model)))))

;;; ============================================================
;;; 调用实现
;;; ============================================================

(defun resolved-options-tools (options)
  "从合并后的选项解析出全部 tool-callback"
  (append (chat-options-tool-callbacks options)
          (resolve-tool-callbacks (chat-options-tool-names options))))

(defun call-provider (model messages options tool-schemas)
  "单次调用底层 provider，返回 chat-response"
  (let ((llm-response (llm-chat (chat-model-provider model)
                                (messages->neutral messages)
                                :tools tool-schemas
                                :model (chat-options-model options)
                                :max-tokens (chat-options-max-tokens options)
                                :temperature (chat-options-temperature options))))
    (llm-response->chat-response llm-response)))

(defmethod chat-model-call ((model provider-chat-model) (prompt prompt))
  (let* ((options (merge-chat-options (prompt-options prompt)
                                      (chat-model-default-options model)))
         (callbacks (resolved-options-tools options))
         (schemas (mapcar #'tool-callback->schema callbacks))
         (manager (model-tool-calling-manager model))
         (max-iterations (chat-options-max-tool-iterations options))
         (messages (prompt-messages prompt)))
    (loop for iteration from 0
          do (when (> iteration max-iterations)
               (error 'max-tool-iterations-exceeded-error :limit max-iterations))
             (let ((response (call-provider model messages options schemas)))
               (if (and (chat-response-has-tool-calls-p response)
                        callbacks
                        (chat-options-internal-tool-execution-enabled options))
                   ;; 内部工具执行：执行 → 追加会话 → 下一轮
                   (multiple-value-bind (tool-message return-direct-p)
                       (execute-tool-calls
                        manager
                        (prompt-copy prompt :messages messages :options options)
                        response)
                     (if return-direct-p
                         ;; return-direct：工具结果直接作为最终答案
                         (return
                           (make-chat-response
                            (make-generation
                             (assistant-message (message-text tool-message))
                             :finish-reason :stop)
                            :metadata (chat-response-metadata-of response)))
                         (setf messages
                               (append messages
                                       (list (chat-response-message response)
                                             tool-message)))))
                   ;; 无工具调用（或关闭内部执行）：返回响应
                   (return response))))))

;;; ============================================================
;;; 流式实现
;;; ============================================================

(defmethod chat-model-stream ((model provider-chat-model) (prompt prompt) on-chunk)
  (let* ((options (merge-chat-options (prompt-options prompt)
                                      (chat-model-default-options model)))
         (callbacks (resolved-options-tools options))
         (provider (chat-model-provider model)))
    (if (or callbacks
            (not (provider-supports-streaming-p provider)))
        ;; 工具循环 / 不支持流式：降级为一次性调用
        (let ((response (chat-model-call model prompt)))
          (funcall on-chunk (chat-response-text response))
          response)
        ;; 纯文本流式
        (let ((llm-response
                (llm-chat-stream provider
                                 (messages->neutral (prompt-messages prompt))
                                 (lambda (chunk)
                                   (let ((delta (getf chunk :delta)))
                                     (when (and delta (string/= delta ""))
                                       (funcall on-chunk delta))))
                                 :model (chat-options-model options)
                                 :max-tokens (chat-options-max-tokens options)
                                 :temperature (chat-options-temperature options))))
          (llm-response->chat-response llm-response)))))
