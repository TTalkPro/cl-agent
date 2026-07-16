;;;; response.lisp
;;;; CL-Agent Chat - ChatResponse
;;;;
;;;; 概述（对标 Spring AI ChatResponse / Generation / ChatResponseMetadata）：
;;;;
;;;;   chat-response
;;;;   ├── generations: (generation ...)     每个候选一个 generation
;;;;   │     └── generation = assistant-message + finish-reason
;;;;   └── metadata: chat-response-metadata  (id / model / usage / raw)
;;;;
;;;;   底层 provider 产出统一的 cl-agent.core:llm-response，
;;;;   由 llm-response->chat-response 在 ChatModel 适配层转换。

(in-package #:cl-agent.core)

;;; ============================================================
;;; Generation
;;; ============================================================

(defclass generation ()
  ((message
    :initarg :message
    :reader generation-message
    :documentation "assistant-message 实例")
   (finish-reason
    :initarg :finish-reason
    :initform nil
    :reader generation-finish-reason
    :documentation "结束原因：:stop / :tool-call / :max-tokens /
:content-filter / :error / NIL"))
  (:documentation "单个模型候选输出（对标 Generation）"))

(defun make-generation (message &key finish-reason)
  "创建 generation。MESSAGE 为 assistant-message（或文本，自动包装）。"
  (make-instance 'generation
                 :message (etypecase message
                            (string (assistant-message message))
                            (assistant-message message))
                 :finish-reason finish-reason))

(defmethod print-object ((gen generation) stream)
  (print-unreadable-object (gen stream :type t)
    (format stream "~A" (generation-finish-reason gen))))

;;; ============================================================
;;; ChatResponse 元数据
;;; ============================================================

(defclass chat-response-metadata ()
  ((id
    :initarg :id
    :initform nil
    :reader response-metadata-id
    :documentation "Provider 分配的消息 ID")
   (model
    :initarg :model
    :initform nil
    :reader response-metadata-model
    :documentation "实际使用的模型名")
   (usage
    :initarg :usage
    :initform nil
    :reader response-metadata-usage
    :documentation "token 用量（cl-agent.core:llm-usage）")
   (raw
    :initarg :raw
    :initform nil
    :reader response-metadata-raw
    :documentation "Provider 原始响应"))
  (:documentation "响应级元数据（对标 ChatResponseMetadata）"))

(defun make-chat-response-metadata (&key id model usage raw)
  (make-instance 'chat-response-metadata
                 :id id :model model :usage usage :raw raw))

;;; ============================================================
;;; ChatResponse
;;; ============================================================

(defclass chat-response ()
  ((generations
    :initarg :generations
    :initform nil
    :reader chat-response-generations
    :documentation "generation 实例列表（至少一个）")
   (metadata
    :initarg :metadata
    :initform nil
    :reader chat-response-metadata-of
    :documentation "chat-response-metadata 实例"))
  (:documentation "一次模型调用的完整输出（对标 ChatResponse）"))

(defun make-chat-response (generations &key metadata)
  "创建 chat-response。GENERATIONS 为 generation 实例（或其列表）。"
  (make-instance 'chat-response
                 :generations (if (listp generations)
                                  generations
                                  (list generations))
                 :metadata (or metadata (make-chat-response-metadata))))

;;; ============================================================
;;; 便捷访问器（作用于首个 generation）
;;; ============================================================

(defun chat-response-generation (response)
  "首个 generation（对标 getResult()）"
  (first (chat-response-generations response)))

(defun chat-response-message (response)
  "首个 generation 的 assistant-message（对标 getResult().getOutput()）"
  (let ((gen (chat-response-generation response)))
    (when gen (generation-message gen))))

(defun chat-response-text (response)
  "首个 generation 的文本内容"
  (let ((msg (chat-response-message response)))
    (if msg (message-text msg) "")))

(defun chat-response-tool-calls (response)
  "首个 generation 携带的 tool-call 列表"
  (let ((msg (chat-response-message response)))
    (when msg (assistant-tool-calls msg))))

(defun chat-response-has-tool-calls-p (response)
  "是否携带工具调用（对标 hasToolCalls()）"
  (not (null (chat-response-tool-calls response))))

(defun chat-response-finish-reason (response)
  "首个 generation 的结束原因"
  (let ((gen (chat-response-generation response)))
    (when gen (generation-finish-reason gen))))

(defun chat-response-usage (response)
  "token 用量（llm-usage 或 NIL）"
  (let ((meta (chat-response-metadata-of response)))
    (when meta (response-metadata-usage meta))))

(defmethod print-object ((response chat-response) stream)
  (print-unreadable-object (response stream :type t)
    (format stream "~A~@[ model=~A~]~@[ tool-calls=~A~]"
            (chat-response-finish-reason response)
            (let ((meta (chat-response-metadata-of response)))
              (when meta (response-metadata-model meta)))
            (let ((n (length (chat-response-tool-calls response))))
              (when (plusp n) n)))))

;;; ============================================================
;;; llm-response → chat-response（适配层转换）
;;; ============================================================

(defun llm-response->chat-response (llm-response)
  "把 provider 统一响应（cl-agent.core:llm-response）转换为 chat-response"
  (let* ((tool-calls (mapcar (lambda (tc)
                               (make-tool-call
                                :id (llm-tool-call-id tc)
                                :name (let ((name (llm-tool-call-name tc)))
                                        (if (stringp name)
                                            name
                                            (string-downcase (string name))))
                                :arguments (llm-tool-call-arguments tc)))
                             (llm-response-tool-calls llm-response)))
         (msg (assistant-message
               (llm-response-content llm-response)
               :tool-calls tool-calls
               ;; :reasoning 是给人看的文本；:reasoning-blocks 是 provider 原生块
               ;; （含签名），message->neutral 会把它带回请求——工具调用多轮
               ;; 对话中 Anthropic 要求原样回传，丢了会被拒。
               :metadata (let ((reasoning (llm-response-reasoning llm-response))
                               (blocks (llm-response-reasoning-blocks llm-response)))
                           (append (when reasoning (list :reasoning reasoning))
                                   (when blocks (list :reasoning-blocks blocks)))))))
    (make-chat-response
     (make-generation msg :finish-reason (llm-response-finish-reason llm-response))
     :metadata (make-chat-response-metadata
                :id (llm-response-message-id llm-response)
                :model (llm-response-model llm-response)
                :usage (llm-response-usage llm-response)
                :raw (llm-response-raw llm-response)))))
