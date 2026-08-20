;;;; re-reading.lisp
;;;; CL-Agent Kernel Filters - RE2 重读增强 (:turn)
;;;;
;;;; 概述（对标 clj-agent re-reading-filter + Spring ReReadingAdvisor）：
;;;;   RE2 技巧：把入口用户问题重复一遍附在其后。
;;;;   只改写入口消息（挂 :chat 会把循环内每轮的历史都重读，无意义又污染）。
;;;;   :resume-p 时跳过（恢复时入口消息已在首次进入时改写）。

(in-package #:cl-agent/core)

(defun re-reading-filter (&key (template nil))
  "创建 re-reading-filter（:turn 链）。

  参数：
  - template  自定义重读模板函数 (lambda (text) → new-text)；
              缺省：把问题重复一遍

  行为：
  - 取入口最后一条 user 消息的文本
  - 用 template 改写（默认：原文 + 换行 + 原文）
  - 替换该消息的 content
  - :resume-p 时跳过（不改写）"
  (let ((fn (or template
                (lambda (text)
                  (format nil "~A~%~%~A" text text)))))
    (make-filter
     :re-reading
     :turn (lambda (req chain)
             (if (turn-request-resume-p req)
                 (funcall chain req)
                 (let* ((messages (turn-request-messages req))
                        ;; 找最后一条 user 消息
                        (last-user (find-if (lambda (m)
                                              (typep m 'cl-agent/core:user-message))
                                            messages :from-end t)))
                   (if last-user
                       (let* ((original (cl-agent/core:message-text last-user))
                              (enhanced (funcall fn original))
                              (new-messages
                                (loop for m in messages
                                      collect (if (eq m last-user)
                                                  (cl-agent/core:user-message enhanced)
                                                  m))))
                         (funcall chain
                                  (make-turn-request new-messages
                                                     :context (turn-request-context req)
                                                     :resume-p (turn-request-resume-p req))))
                       ;; 无 user 消息 → 不改写
                       (funcall chain req))))))))
