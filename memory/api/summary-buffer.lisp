;;;; summary-buffer.lisp
;;;; CL-Agent Memory - Conversation Summary Buffer
;;;;
;;;; Overview:
;;;;   对话总结缓冲区实现
;;;;   当对话历史超出 token 限制时，自动调用 LLM 总结旧对话
;;;;
;;;; Design:
;;;;   参考 LangChain ConversationSummaryBufferMemory
;;;;   - summary: 历史对话的总结
;;;;   - buffer: 最近的完整对话
;;;;   - 当 buffer 超限时，将旧消息总结后合并到 summary

(in-package #:cl-agent.memory)

;;; ============================================================
;;; Conversation Summary Buffer 类
;;; ============================================================

(defclass conversation-summary-buffer ()
  ((summary
    :initarg :summary
    :accessor summary-buffer-summary
    :initform nil
    :type (or null string)
    :documentation "历史对话的总结文本")

   (buffer
    :initarg :buffer
    :accessor summary-buffer-buffer
    :initform '()
    :type list
    :documentation "最近的消息列表（完整保留）")

   (max-buffer-tokens
    :initarg :max-buffer-tokens
    :accessor summary-buffer-max-buffer-tokens
    :initform 2000
    :type integer
    :documentation "Buffer 的最大 token 数")

   (max-summary-tokens
    :initarg :max-summary-tokens
    :accessor summary-buffer-max-summary-tokens
    :initform 500
    :type integer
    :documentation "Summary 的最大 token 数")

   (summarizer-fn
    :initarg :summarizer-fn
    :accessor summary-buffer-summarizer-fn
    :initform nil
    :type (or null function)
    :documentation "总结函数 (lambda (messages &optional existing-summary) -> string)")

   (system-prompt
    :initarg :system-prompt
    :accessor summary-buffer-system-prompt
    :initform nil
    :type (or null string)
    :documentation "系统提示")

   (auto-summarize
    :initarg :auto-summarize
    :accessor summary-buffer-auto-summarize
    :initform t
    :type boolean
    :documentation "是否自动触发总结")

   (human-prefix
    :initarg :human-prefix
    :accessor summary-buffer-human-prefix
    :initform "Human"
    :type string
    :documentation "用户消息前缀")

   (ai-prefix
    :initarg :ai-prefix
    :accessor summary-buffer-ai-prefix
    :initform "AI"
    :type string
    :documentation "AI 消息前缀")

   (verbose
    :initarg :verbose
    :accessor summary-buffer-verbose
    :initform nil
    :type boolean
    :documentation "是否启用详细日志输出"))

  (:documentation "Conversation Summary Buffer

对话总结缓冲区，结合了完整 buffer 和总结功能：

结构：
  ┌─────────────────────────────────────────────┐
  │ [Summary]  历史总结 (压缩的旧对话)          │
  ├─────────────────────────────────────────────┤
  │ [Buffer]   最近对话 (完整保留)              │
  │   - Message 1                               │
  │   - Message 2                               │
  │   - ...                                     │
  └─────────────────────────────────────────────┘

工作流程：
  1. 新消息添加到 buffer
  2. 当 buffer 超过 max-buffer-tokens
  3. 将旧消息用 LLM 总结
  4. 总结合并到 summary
  5. 从 buffer 中移除已总结的消息"))

(defun conversation-summary-buffer-p (obj)
  "检查对象是否是 conversation-summary-buffer 实例"
  (typep obj 'conversation-summary-buffer))

(defun make-conversation-summary-buffer (&key (max-buffer-tokens 2000)
                                              (max-summary-tokens 500)
                                              summarizer-fn
                                              system-prompt
                                              (auto-summarize t)
                                              (human-prefix "Human")
                                              (ai-prefix "AI"))
  "创建 conversation-summary-buffer 实例

参数：
  MAX-BUFFER-TOKENS  - Buffer 最大 token 数（默认 2000）
  MAX-SUMMARY-TOKENS - Summary 最大 token 数（默认 500）
  SUMMARIZER-FN      - 总结函数 (lambda (messages &optional existing-summary) -> string)
  SYSTEM-PROMPT      - 系统提示（可选）
  AUTO-SUMMARIZE     - 是否自动总结（默认 T）
  HUMAN-PREFIX       - 用户消息前缀（默认 \"Human\"）
  AI-PREFIX          - AI 消息前缀（默认 \"AI\"）

返回：
  conversation-summary-buffer 实例

示例：
  ;; 创建带自定义总结函数的 buffer
  (make-conversation-summary-buffer
   :summarizer-fn (lambda (msgs summary)
                    (llm-summarize msgs summary))
   :max-buffer-tokens 1500)"
  (make-instance 'conversation-summary-buffer
                 :max-buffer-tokens max-buffer-tokens
                 :max-summary-tokens max-summary-tokens
                 :summarizer-fn summarizer-fn
                 :system-prompt system-prompt
                 :auto-summarize auto-summarize
                 :human-prefix human-prefix
                 :ai-prefix ai-prefix))

(defmethod print-object ((csb conversation-summary-buffer) stream)
  (print-unreadable-object (csb stream :type t)
    (format stream "~A msgs in buffer, summary: ~A"
            (length (summary-buffer-buffer csb))
            (if (summary-buffer-summary csb) "yes" "no"))))

;;; ============================================================
;;; Summary Buffer 协议定义
;;; ============================================================

(defgeneric csb-add-message (csb message)
  (:documentation "添加消息到 summary buffer"))

(defgeneric csb-get-messages (csb &key include-system-prompt include-summary)
  (:documentation "获取消息列表（包含总结）"))

(defgeneric csb-summarize (csb &key force)
  (:documentation "触发总结操作"))

(defgeneric csb-clear (csb &key keep-summary)
  (:documentation "清空 buffer"))

(defgeneric csb-buffer-tokens (csb)
  (:documentation "计算 buffer 当前 token 数"))

(defgeneric csb-needs-summarize-p (csb)
  (:documentation "检查是否需要总结"))

(defgeneric csb-get-context (csb)
  (:documentation "获取完整上下文（summary + buffer）"))

;;; ============================================================
;;; Summary Buffer 方法实现
;;; ============================================================

(defmethod csb-add-message ((csb conversation-summary-buffer) message)
  "添加消息到 summary buffer

参数：
  CSB     - conversation-summary-buffer 实例
  MESSAGE - memory-message 实例

返回：
  更新后的 conversation-summary-buffer"
  ;; 添加到 buffer
  (setf (summary-buffer-buffer csb)
        (append (summary-buffer-buffer csb) (list message)))

  ;; 检查是否需要总结
  (when (and (summary-buffer-auto-summarize csb)
             (csb-needs-summarize-p csb))
    (csb-summarize csb))

  csb)

(defmethod csb-get-messages ((csb conversation-summary-buffer)
                             &key (include-system-prompt t)
                                  (include-summary t))
  "获取消息列表

参数：
  CSB                   - conversation-summary-buffer 实例
  INCLUDE-SYSTEM-PROMPT - 是否包含系统提示（默认 T）
  INCLUDE-SUMMARY       - 是否包含总结（默认 T）

返回：
  memory-message 列表"
  (let ((messages '()))
    ;; 1. 系统提示
    (when (and include-system-prompt
               (summary-buffer-system-prompt csb))
      (push (make-system-message (summary-buffer-system-prompt csb))
            messages))

    ;; 2. 历史总结（作为系统消息）
    (when (and include-summary
               (summary-buffer-summary csb))
      (push (make-system-message
             (format nil "以下是之前对话的总结：~%~A"
                     (summary-buffer-summary csb)))
            messages))

    ;; 3. Buffer 中的消息
    (setf messages (append (nreverse messages)
                           (summary-buffer-buffer csb)))

    messages))

(defmethod csb-buffer-tokens ((csb conversation-summary-buffer))
  "计算 buffer 当前 token 数

参数：
  CSB - conversation-summary-buffer 实例

返回：
  token 数量"
  (reduce #'+ (summary-buffer-buffer csb)
          :key (lambda (msg)
                 (estimate-tokens (memory-message-content msg)))
          :initial-value 0))

(defmethod csb-needs-summarize-p ((csb conversation-summary-buffer))
  "检查是否需要总结

参数：
  CSB - conversation-summary-buffer 实例

返回：
  T 或 NIL"
  (> (csb-buffer-tokens csb)
     (summary-buffer-max-buffer-tokens csb)))

(defmethod csb-summarize ((csb conversation-summary-buffer) &key force)
  "触发总结操作

参数：
  CSB   - conversation-summary-buffer 实例
  FORCE - 是否强制总结（即使未超限）

返回：
  新的总结文本，或 NIL（如果没有总结函数）"
  ;; 检查是否需要总结
  (unless (or force (csb-needs-summarize-p csb))
    (return-from csb-summarize nil))

  ;; 检查是否有总结函数
  (unless (summary-buffer-summarizer-fn csb)
    (warn "No summarizer function provided, falling back to truncation")
    (csb-truncate-buffer csb)
    (return-from csb-summarize nil))

  (let* ((buffer (summary-buffer-buffer csb))
         (max-tokens (summary-buffer-max-buffer-tokens csb))
         (current-tokens (csb-buffer-tokens csb))
         (target-tokens (floor max-tokens 2))  ; 目标：减少到一半
         (messages-to-summarize '())
         (messages-to-keep '())
         (running-tokens 0))

    ;; 从最新开始，决定保留哪些消息
    (dolist (msg (reverse buffer))
      (let ((msg-tokens (estimate-tokens (memory-message-content msg))))
        (if (<= (+ running-tokens msg-tokens) target-tokens)
            (progn
              (push msg messages-to-keep)
              (incf running-tokens msg-tokens))
            (push msg messages-to-summarize))))

    ;; 反转得到正确顺序
    (setf messages-to-summarize (nreverse messages-to-summarize))

    ;; 如果有消息需要总结
    (when messages-to-summarize
      (let* ((existing-summary (summary-buffer-summary csb))
             (new-summary (funcall (summary-buffer-summarizer-fn csb)
                                  messages-to-summarize
                                  existing-summary)))
        ;; 更新总结
        (setf (summary-buffer-summary csb) new-summary)

        ;; 更新 buffer（只保留未总结的消息）
        (setf (summary-buffer-buffer csb) messages-to-keep)

        (when (summary-buffer-verbose csb)
          (format t "[Memory] Summarized ~A messages, ~A remaining in buffer~%"
                  (length messages-to-summarize)
                  (length messages-to-keep)))

        new-summary))))

(defmethod csb-clear ((csb conversation-summary-buffer) &key keep-summary)
  "清空 buffer

参数：
  CSB          - conversation-summary-buffer 实例
  KEEP-SUMMARY - 是否保留总结（默认 NIL）

返回：
  更新后的 conversation-summary-buffer"
  (setf (summary-buffer-buffer csb) '())
  (unless keep-summary
    (setf (summary-buffer-summary csb) nil))
  csb)

(defmethod csb-get-context ((csb conversation-summary-buffer))
  "获取完整上下文（格式化为字符串）

参数：
  CSB - conversation-summary-buffer 实例

返回：
  上下文字符串"
  (with-output-to-string (s)
    ;; 总结部分
    (when (summary-buffer-summary csb)
      (format s "=== 历史总结 ===~%~A~%~%" (summary-buffer-summary csb)))

    ;; Buffer 部分
    (format s "=== 最近对话 ===~%")
    (dolist (msg (summary-buffer-buffer csb))
      (let ((role (memory-message-role msg))
            (content (memory-message-content msg)))
        (format s "~A: ~A~%"
                (case role
                  (:user (summary-buffer-human-prefix csb))
                  (:assistant (summary-buffer-ai-prefix csb))
                  (:system "System")
                  (otherwise (string-capitalize (symbol-name role))))
                content)))))

;;; ============================================================
;;; 辅助方法
;;; ============================================================

(defun csb-truncate-buffer (csb)
  "简单截断 buffer（当没有总结函数时的后备方案）

参数：
  CSB - conversation-summary-buffer 实例

返回：
  移除的消息数量"
  (let* ((buffer (summary-buffer-buffer csb))
         (max-tokens (summary-buffer-max-buffer-tokens csb))
         (new-buffer '())
         (running-tokens 0)
         (removed-count 0))

    ;; 从最新开始保留
    (dolist (msg (reverse buffer))
      (let ((msg-tokens (estimate-tokens (memory-message-content msg))))
        (if (<= (+ running-tokens msg-tokens) max-tokens)
            (progn
              (push msg new-buffer)
              (incf running-tokens msg-tokens))
            (incf removed-count))))

    (setf (summary-buffer-buffer csb) new-buffer)

    (when (summary-buffer-verbose csb)
      (format t "[Memory] Truncated ~A messages (no summarizer)~%" removed-count))

    removed-count))

;;; ============================================================
;;; 默认总结 Prompt 模板
;;; ============================================================

(defparameter *default-summary-prompt-template*
  "请对以下对话进行简洁总结，保留关键信息：

~@[之前的总结：
~A

~]新对话：
~A

请用 2-3 句话总结上述对话的要点："
  "默认的总结 prompt 模板")

(defun format-messages-for-summary (messages &key (human-prefix "Human") (ai-prefix "AI"))
  "将消息列表格式化为总结用的文本

参数：
  MESSAGES     - memory-message 列表
  HUMAN-PREFIX - 用户前缀
  AI-PREFIX    - AI 前缀

返回：
  格式化的对话文本"
  (with-output-to-string (s)
    (dolist (msg messages)
      (let ((role (memory-message-role msg))
            (content (memory-message-content msg)))
        (format s "~A: ~A~%"
                (case role
                  (:user human-prefix)
                  (:assistant ai-prefix)
                  (:system "System")
                  (otherwise (string-capitalize (symbol-name role))))
                content)))))

(defun make-summary-prompt (messages existing-summary &key (human-prefix "Human") (ai-prefix "AI"))
  "生成总结 prompt

参数：
  MESSAGES         - 需要总结的消息列表
  EXISTING-SUMMARY - 已有的总结（可选）
  HUMAN-PREFIX     - 用户前缀
  AI-PREFIX        - AI 前缀

返回：
  完整的 prompt 字符串"
  (format nil *default-summary-prompt-template*
          existing-summary
          (format-messages-for-summary messages
                                       :human-prefix human-prefix
                                       :ai-prefix ai-prefix)))

;;; ============================================================
;;; 便捷函数：创建带 LLM 的 Summary Buffer
;;; ============================================================

(defun make-llm-summary-buffer (llm-fn &key (max-buffer-tokens 2000)
                                           (max-summary-tokens 500)
                                           system-prompt
                                           (human-prefix "Human")
                                           (ai-prefix "AI"))
  "创建带 LLM 总结功能的 conversation-summary-buffer

参数：
  LLM-FN             - LLM 调用函数 (lambda (prompt) -> response-string)
  MAX-BUFFER-TOKENS  - Buffer 最大 token 数
  MAX-SUMMARY-TOKENS - Summary 最大 token 数
  SYSTEM-PROMPT      - 系统提示
  HUMAN-PREFIX       - 用户消息前缀
  AI-PREFIX          - AI 消息前缀

返回：
  conversation-summary-buffer 实例

示例：
  ;; 使用 OpenAI
  (make-llm-summary-buffer
   (lambda (prompt)
     (openai-chat prompt :model \"gpt-3.5-turbo\")))"
  (make-conversation-summary-buffer
   :max-buffer-tokens max-buffer-tokens
   :max-summary-tokens max-summary-tokens
   :system-prompt system-prompt
   :human-prefix human-prefix
   :ai-prefix ai-prefix
   :summarizer-fn
   (lambda (messages existing-summary)
     (let ((prompt (make-summary-prompt messages existing-summary
                                        :human-prefix human-prefix
                                        :ai-prefix ai-prefix)))
       (funcall llm-fn prompt)))))

