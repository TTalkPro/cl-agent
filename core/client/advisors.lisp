;;;; advisors.lisp
;;;; CL-Agent Client - 内置 Advisor
;;;;
;;;; 概述（对标 Spring AI 内置 Advisor）：
;;;;
;;;;   simple-logger-advisor        —— SimpleLoggerAdvisor
;;;;   message-chat-memory-advisor  —— MessageChatMemoryAdvisor
;;;;   prompt-chat-memory-advisor   —— PromptChatMemoryAdvisor
;;;;   safe-guard-advisor           —— SafeGuardAdvisor
;;;;
;;;; 会话 ID：
;;;;   记忆类 Advisor 从请求 context 的 +conversation-id-key+ 读取会话 ID
;;;;   （对标 ChatMemory.CONVERSATION_ID conversation context key），
;;;;   ChatClient 的 (prompt-conversation spec "id") / (:conversation "id")
;;;;   负责写入。未提供时使用 +default-conversation-id+。

(in-package #:cl-agent.client)

(alexandria:define-constant +conversation-id-key+ "chat_memory_conversation_id"
  :test #'equal
  :documentation "请求 context 中的会话 ID 键
（对标 ChatMemory.CONVERSATION_ID）")

(defun request-conversation-id (request)
  "从请求 context 读会话 ID，缺省 +default-conversation-id+"
  (context-get request +conversation-id-key+ +default-conversation-id+))

;;; ============================================================
;;; SimpleLoggerAdvisor —— 请求/响应日志
;;; ============================================================

(defadvisor simple-logger-advisor
    (:order -1000
     :documentation "记录请求与响应摘要的日志 Advisor
（对标 SimpleLoggerAdvisor）。order 极小，位于链最外层。")
  (:slots ((stream
            :initarg :stream
            :initform nil
            :documentation "输出流（NIL 时走 log-debug）")))
  (:call (advisor request chain)
    (flet ((emit (fmt &rest args)
             (let ((out (slot-value advisor 'stream)))
               (if out
                   (format out "~&[chat-client] ~A~%" (apply #'format nil fmt args))
                   (apply #'log-debug fmt args)))))
      (let ((prompt (client-request-prompt request)))
        (emit "request: ~A messages, last-user=~S"
              (length (prompt-messages prompt))
              (prompt-last-user-text prompt)))
      (let ((response (chain-next chain request)))
        (emit "response: ~S"
              (chat-response-text (client-response-chat-response response)))
        response))))

;;; ============================================================
;;; MessageChatMemoryAdvisor —— 消息级会话记忆
;;; ============================================================

(defadvisor message-chat-memory-advisor
    (:order 1000
     :documentation "把会话历史作为消息注入 prompt 的记忆 Advisor
（对标 MessageChatMemoryAdvisor）：

before：新消息（非 system）存入记忆，再用完整记忆替换 prompt 的
        非 system 消息（记忆是会话的唯一事实来源）
after： 模型的 assistant 回复存入记忆")
  (:slots ((memory
            :initarg :memory
            :reader advisor-memory
            :documentation "chat-memory 实例（必填）")))
  (:call (advisor request chain)
    (let* ((memory (advisor-memory advisor))
           (cid (request-conversation-id request))
           (prompt (client-request-prompt request))
           (new-messages (prompt-instruction-messages prompt)))
      ;; before：存增量，取全量
      (memory-add memory cid new-messages)
      (let* ((augmented (prompt-copy prompt
                                     :messages (append
                                                (prompt-system-messages prompt)
                                                (memory-messages memory cid))))
             (response (chain-next chain
                                   (client-request-copy request
                                                        :prompt augmented)))
             (assistant (chat-response-message
                         (client-response-chat-response response))))
        ;; after：存回复
        (when assistant
          (memory-add memory cid (list assistant)))
        response))))

(defmethod initialize-instance :after ((advisor message-chat-memory-advisor) &key)
  (unless (slot-boundp advisor 'memory)
    (error "message-chat-memory-advisor 需要 :memory（chat-memory 实例）")))

;;; ============================================================
;;; PromptChatMemoryAdvisor —— 提示词级会话记忆
;;; ============================================================

(defadvisor prompt-chat-memory-advisor
    (:order 1000
     :documentation "把会话历史渲染为文本追加进系统提示的记忆 Advisor
（对标 PromptChatMemoryAdvisor）。适合不支持多轮消息的场景。")
  (:slots ((memory
            :initarg :memory
            :reader advisor-memory
            :documentation "chat-memory 实例（必填）")
           (template
            :initarg :template
            :initform "~%~%以下是此前的对话记忆：~%~A"
            :documentation "历史文本注入模板（一个 ~A 占位）")))
  (:call (advisor request chain)
    (let* ((memory (advisor-memory advisor))
           (cid (request-conversation-id request))
           (prompt (client-request-prompt request))
           (history (memory-messages memory cid))
           (new-messages (prompt-instruction-messages prompt)))
      (memory-add memory cid new-messages)
      (let* ((history-text
               (format nil "~{~A~^~%~}"
                       (mapcar (lambda (msg)
                                 (format nil "~A: ~A"
                                         (ecase (message-role msg)
                                           (:user "USER")
                                           (:assistant "ASSISTANT")
                                           (:tool "TOOL"))
                                         (message-text msg)))
                               (remove-if #'system-message-p history))))
             (system-text
               (concatenate
                'string
                (let ((systems (prompt-system-messages prompt)))
                  (if systems
                      (format nil "~{~A~^~%~}" (mapcar #'message-text systems))
                      ""))
                (if (string= history-text "")
                    ""
                    (format nil (slot-value advisor 'template) history-text))))
             (augmented (prompt-copy prompt
                                     :messages (append
                                                (when (string/= system-text "")
                                                  (list (system-message system-text)))
                                                new-messages)))
             (response (chain-next chain
                                   (client-request-copy request
                                                        :prompt augmented)))
             (assistant (chat-response-message
                         (client-response-chat-response response))))
        (when assistant
          (memory-add memory cid (list assistant)))
        response))))

(defmethod initialize-instance :after ((advisor prompt-chat-memory-advisor) &key)
  (unless (slot-boundp advisor 'memory)
    (error "prompt-chat-memory-advisor 需要 :memory（chat-memory 实例）")))

;;; ============================================================
;;; SafeGuardAdvisor —— 敏感词安全护栏
;;; ============================================================

(defadvisor safe-guard-advisor
    (:order -500
     :documentation "敏感词护栏（对标 SafeGuardAdvisor）：
用户输入命中敏感词时短路返回固定回复，不再调用模型。
order 较小，位于记忆等 Advisor 之外，避免敏感输入进入记忆。")
  (:slots ((sensitive-words
            :initarg :sensitive-words
            :initform nil
            :documentation "敏感词字符串列表")
           (failure-response
            :initarg :failure-response
            :initform "抱歉，我无法协助处理该请求。"
            :documentation "命中时返回的固定文本")))
  (:call (advisor request chain)
    (let ((user-text (prompt-last-user-text
                      (client-request-prompt request))))
      (if (and user-text
               (some (lambda (word) (search word user-text))
                     (slot-value advisor 'sensitive-words)))
          ;; 短路：合成固定响应，不进入下游
          (make-client-response
           (make-chat-response
            (make-generation
             (assistant-message (slot-value advisor 'failure-response))
             :finish-reason :stop))
           :context (client-request-context request))
          (chain-next chain request)))))
