;;;; prompt.lisp
;;;; CL-Agent Chat - Prompt
;;;;
;;;; 概述（对标 Spring AI org.springframework.ai.chat.prompt.Prompt）：
;;;;   Prompt = 有序消息列表 + 本次调用的 chat-options。
;;;;   Advisor 通过 prompt-copy 产生增强副本（不可变风格），
;;;;   原 prompt 不被修改。

(in-package #:cl-agent.chat)

(defclass prompt ()
  ((messages
    :initarg :messages
    :initform nil
    :reader prompt-messages
    :documentation "message 实例的有序列表")
   (options
    :initarg :options
    :initform nil
    :reader prompt-options
    :documentation "chat-options 实例（可为 NIL）"))
  (:documentation "一次模型调用的完整输入（对标 Prompt）"))

(defun make-prompt (messages &key options system)
  "创建 prompt。

参数：
  MESSAGES - message 实例列表；也接受单条 message 或字符串
             （字符串包装为 user-message）
  OPTIONS  - chat-options（可选）
  SYSTEM   - 系统提示文本（可选，插入为首条 system-message）

示例：
  (make-prompt \"你好\")
  (make-prompt (list (user-message \"你好\")) :system \"你是一个助手\")"
  (let ((msgs (etypecase messages
                (string (list (user-message messages)))
                (message (list messages))
                (list (mapcar (lambda (m)
                                (etypecase m
                                  (string (user-message m))
                                  (message m)))
                              messages)))))
    (when system
      (push (system-message system) msgs))
    (make-instance 'prompt :messages msgs :options options)))

(defun prompt-copy (prompt &key (messages nil messages-p) (options nil options-p))
  "拷贝 prompt，可替换消息列表或选项（Advisor 增强用）"
  (make-instance 'prompt
                 :messages (if messages-p messages (prompt-messages prompt))
                 :options (if options-p options (prompt-options prompt))))

(defun prompt-append-messages (prompt new-messages)
  "返回追加了 NEW-MESSAGES 的 prompt 副本"
  (prompt-copy prompt
               :messages (append (prompt-messages prompt) new-messages)))

(defun prompt-system-messages (prompt)
  "取出全部 system-message"
  (remove-if-not #'system-message-p (prompt-messages prompt)))

(defun prompt-instruction-messages (prompt)
  "取出全部非 system 消息"
  (remove-if #'system-message-p (prompt-messages prompt)))

(defun prompt-last-user-text (prompt)
  "最后一条 user-message 的文本（无则 NIL），SafeGuard 等 Advisor 用"
  (let ((msg (find-if #'user-message-p (prompt-messages prompt)
                      :from-end t)))
    (when msg (message-text msg))))

(defmethod print-object ((prompt prompt) stream)
  (print-unreadable-object (prompt stream :type t)
    (format stream "~A messages~@[ +options~]"
            (length (prompt-messages prompt))
            (prompt-options prompt))))
