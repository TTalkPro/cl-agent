;;;; prompt.lisp
;;;; CL-Agent Chat - Prompt
;;;;
;;;; 概述（对标 Spring AI org.springframework.ai.chat.prompt.Prompt）：
;;;;   Prompt = 有序消息列表 + 本次调用的 chat-options。
;;;;   Filter 通过 prompt-copy 产生增强副本（不可变风格），
;;;;   原 prompt 不被修改。

(in-package #:cl-agent/core)

(defclass prompt (model-request)
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
  (:documentation "一次模型调用的完整输入（对标 Prompt implements ModelRequest）。

  领域访问器是 prompt-messages / prompt-options；协议访问器
  request-instructions / request-options 映射到同一对槽，供不分模态的
  横切代码使用。"))

(definvariants prompt (self)
  ;; messages 槽里存的必须已经是 message 实例——make-prompt 负责把字符串
  ;; 归一过来（那是**入口的贴心**，不是类的性质）。这条不变式钉住的正是
  ;; 「归一发生在入口、槽里只有一种东西」，否则下游每处都得自己判类型。
  (require-that self (every (lambda (m) (typep m 'message)) (prompt-messages self))
                "messages 必须是 message 实例列表——字符串请经 make-prompt 归一")
  (require-type self 'options 'chat-options))

;;; 接入 model-request 协议
(defmethod request-instructions ((request prompt))
  (prompt-messages request))

(defmethod request-options ((request prompt))
  (prompt-options request))

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
  "拷贝 prompt，可替换消息列表或选项（filter 增强用）"
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
  "最后一条 user-message 的文本（无则 NIL），safeguard 等 filter 用"
  (let ((msg (find-if #'user-message-p (prompt-messages prompt)
                      :from-end t)))
    (when msg (message-text msg))))

(defun prompt-last-user-or-tool-message (prompt)
  "最后一条 user-message 或 tool-response-message（无则 NIL）
（对标 Prompt#getLastUserOrToolResponseMessage）。

记忆类 filter 用它确定「本轮新增的输入」——工具循环中
最后一条输入可能是工具结果而非用户消息。"
  (find-if (lambda (msg)
             (or (user-message-p msg) (tool-response-message-p msg)))
           (prompt-messages prompt)
           :from-end t))

(defun prompt-augment-last-user-message (prompt function)
  "用 FUNCTION 改写最后一条 user-message 的文本，返回 prompt 副本
（对标 Prompt#augmentUserMessage）。无 user-message 时原样返回。

FUNCTION：(旧文本) → 新文本"
  (let ((pos (position-if #'user-message-p (prompt-messages prompt)
                          :from-end t)))
    (if (null pos)
        prompt
        (let* ((messages (copy-list (prompt-messages prompt)))
               (old (nth pos messages)))
          (setf (nth pos messages)
                (user-message (funcall function (message-text old))))
          (prompt-copy prompt :messages messages)))))

(defmethod print-object ((prompt prompt) stream)
  (print-unreadable-object (prompt stream :type t)
    (format stream "~A messages~@[ +options~]"
            (length (prompt-messages prompt))
            (prompt-options prompt))))
