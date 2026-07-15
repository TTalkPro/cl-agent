;;;; advisors.lisp
;;;; CL-Agent Client - 内置 Advisor
;;;;
;;;; 概述（对标 Spring AI 2.0 内置 Advisor）：
;;;;
;;;;   simple-logger-advisor        —— SimpleLoggerAdvisor
;;;;   message-chat-memory-advisor  —— MessageChatMemoryAdvisor
;;;;   safe-guard-advisor           —— SafeGuardAdvisor
;;;;
;;;; 另见同目录：
;;;;   tool-advisor.lisp              —— ToolCallingAdvisor
;;;;   tool-search-advisor.lisp       —— ToolSearchToolCallingAdvisor
;;;;   structured-output-advisor.lisp —— StructuredOutputValidationAdvisor
;;;;
;;;; 注：PromptChatMemoryAdvisor 在 Spring AI 2.0 中已被移除
;;;;     （1.0 → 2.0 唯一被移除的 Advisor），本实现同步移除。
;;;;     需要「历史渲染进系统提示」的场景请改用 message-chat-memory-advisor，
;;;;     或用 defadvisor 自行实现。
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

(defun default-log-request-to-string (request)
  "simple-logger-advisor 的默认请求格式化"
  (let ((prompt (client-request-prompt request)))
    (format nil "request: ~A messages, last-user=~S"
            (length (prompt-messages prompt))
            (prompt-last-user-text prompt))))

(defun default-log-response-to-string (chat-response)
  "simple-logger-advisor 的默认响应格式化"
  (format nil "response: ~S" (chat-response-text chat-response)))

(defadvisor simple-logger-advisor
    (:order +simple-logger-advisor-order+
     :documentation "记录请求与响应摘要的日志 Advisor
（对标 SimpleLoggerAdvisor）。order 极小，位于链最外层。

格式化函数可替换（对标 Builder 的 requestToString / responseToString）：
  (make-simple-logger-advisor
    :response-to-string (lambda (chat-response)
                          (format nil \"~A tokens\" ...)))")
  (:slots ((stream
            :initarg :stream
            :initform nil
            :documentation "输出流（NIL 时走 log-debug）")
           (request-to-string
            :initarg :request-to-string
            :initform #'default-log-request-to-string
            :documentation "(client-request) → 字符串
（对标 SimpleLoggerAdvisor.Builder#requestToString）")
           (response-to-string
            :initarg :response-to-string
            :initform #'default-log-response-to-string
            :documentation "(chat-response) → 字符串
（对标 SimpleLoggerAdvisor.Builder#responseToString）")))
  (:call (advisor request chain)
    (flet ((emit (text)
             (let ((out (slot-value advisor 'stream)))
               (if out
                   (format out "~&[chat-client] ~A~%" text)
                   (log-debug "~A" text)))))
      (emit (funcall (slot-value advisor 'request-to-string) request))
      (let ((response (chain-next chain request)))
        (emit (funcall (slot-value advisor 'response-to-string)
                       (client-response-chat-response response)))
        response))))

;;; ============================================================
;;; MessageChatMemoryAdvisor —— 消息级会话记忆
;;; ============================================================

(defun message-value-equal-p (a b)
  "两条消息在「角色 + 文本」意义上相等。

memory-already-in-prompt-p 用它做幂等判断——对标 Spring 用
Message#equals（值相等）而非对象同一性：调用方手动把历史塞进
prompt 时，不应再被前插一遍。"
  (and (eq (message-role a) (message-role b))
       (equal (message-text a) (message-text b))))

(defun memory-already-in-prompt-p (prompt-messages memory-messages)
  "记忆是否已作为连续子序列出现在 PROMPT-MESSAGES 中
（对标 MessageChatMemoryAdvisor#isMemoryAlreadyInPrompt）。

用于避免重复前插：记忆为空视为「已在」（无需前插）。"
  (let ((memory-count (length memory-messages))
        (prompt-count (length prompt-messages)))
    (cond
      ((zerop memory-count) t)
      ((< prompt-count memory-count) nil)
      (t (loop for offset from 0 to (- prompt-count memory-count)
               thereis (every #'message-value-equal-p
                              memory-messages
                              (nthcdr offset prompt-messages)))))))

(defun hoist-system-message (messages)
  "把首个 system 消息移到列表最前（对标 Spring 的 system-first 处理）。
记忆前插后 system 消息可能不再位于首位，部分提供商对此敏感。"
  (let ((pos (position-if #'system-message-p messages)))
    (if (or (null pos) (zerop pos))
        messages
        (cons (nth pos messages)
              (append (subseq messages 0 pos)
                      (subseq messages (1+ pos)))))))

(defadvisor message-chat-memory-advisor
    (:order +chat-memory-advisor-order+
     :documentation "把会话历史作为消息注入 prompt 的记忆 Advisor
（对标 MessageChatMemoryAdvisor）：

before：取记忆 → 前插到 prompt 消息之前（已在则跳过）→ system 置顶
        → 把本轮最后一条 user/tool 消息存入记忆
after： 模型的 assistant 回复存入记忆

注意存入记忆的是「最后一条 user/tool 消息」而非全部新消息——
与 Spring 的 getLastUserOrToolResponseMessage 一致。")
  (:slots ((memory
            :initarg :memory
            :reader advisor-memory
            :documentation "chat-memory 实例（必填）")))
  (:call (advisor request chain)
    (let* ((memory (advisor-memory advisor))
           (cid (request-conversation-id request))
           (prompt (client-request-prompt request))
           (history (memory-messages memory cid))
           (prompt-messages (prompt-messages prompt))
           ;; before：前插记忆（幂等），再把 system 提到最前
           (processed (hoist-system-message
                       (if (memory-already-in-prompt-p prompt-messages history)
                           prompt-messages
                           (append history prompt-messages))))
           (augmented (prompt-copy prompt :messages processed)))
      ;; 本轮新增输入存入记忆（在 augmented 构造之后，不影响本次 prompt）
      (let ((last-input (prompt-last-user-or-tool-message augmented)))
        (when last-input
          (memory-add memory cid (list last-input))))
      (let* ((response (chain-next chain
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

(defmethod memory-advisor-p ((advisor message-chat-memory-advisor))
  t)

;;; ============================================================
;;; SafeGuardAdvisor —— 敏感词安全护栏
;;; ============================================================

(defadvisor safe-guard-advisor
    (:order +safe-guard-advisor-order+
     :documentation "敏感词护栏（对标 SafeGuardAdvisor）：
用户输入命中敏感词时短路返回固定回复，不再调用模型。

默认 order 位于记忆类 Advisor 之外，敏感输入不会进入记忆
（Spring 默认 order 为 0，即工具循环内侧——差异说明见 advisor.lisp
的排序常量一节）。传 :order 可覆盖：

  ;; 每轮工具迭代都过护栏（含工具返回结果），对齐 Spring 的默认语义
  (make-safe-guard-advisor :sensitive-words '(\"...\")
                           :order (1+ +tool-calling-advisor-order+))")
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
