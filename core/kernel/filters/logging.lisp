;;;; logging.lisp
;;;; CL-Agent Kernel Filters - 日志 Filter (:chat + :tool)
;;;;
;;;; 概述（对标 clj-agent logging-chat-filter / logging-filter）：
;;;;   记录请求/响应摘要，不影响行为。

(in-package #:cl-agent/core)

;;; ============================================================
;;; logging-chat-filter (:chat)
;;; ============================================================

(defun logging-chat-filter (&key (log-fn nil) (preview 100))
  "创建 :chat 链日志 filter。

  参数：
  - log-fn   自定义日志函数 (lambda (msg) ...)；缺省用 log-info
  - preview  文本预览截断长度（缺省 100 字符）"
  (let ((fn (or log-fn
                (lambda (msg) (cl-agent/core:log-info "[kernel:chat] ~A" msg)))))
    (make-filter
     :logging-chat
     :chat (lambda (prompt chain)
             (let ((n (length (cl-agent/core:prompt-messages prompt))))
               (funcall fn (format nil "→ messages=~A" n)))
             (let ((resp (funcall chain prompt)))
               (let ((text (cl-agent/core:chat-response-text resp))
                     (n-tools (length (cl-agent/core:chat-response-tool-calls resp))))
                 (funcall fn (format nil "← ~A~@[ tools=~A~]"
                                     (if (> (length text) preview)
                                         (subseq text 0 preview)
                                         text)
                                     (when (plusp n-tools) n-tools)))
                 resp))))))

;;; ============================================================
;;; logging-tool-filter (:tool)
;;; ============================================================

(defun logging-tool-filter (&key (log-fn nil))
  "创建 :tool 链日志 filter。记录工具名、参数、结果/错误。"
  (let ((fn (or log-fn
                (lambda (msg) (cl-agent/core:log-info "[kernel:tool] ~A" msg)))))
    (make-filter
     :logging-tool
     :tool (lambda (req chain)
             (let ((name (cl-agent/core:tool-callback-name
                          (tool-request-function req))))
               (funcall fn (format nil "→ ~A" name))
               (let ((resp (funcall chain req)))
                 (if (tool-result-error resp)
                     (funcall fn (format nil "← ~A ERROR: ~A"
                                         name
                                         (getf (tool-result-error resp) :message)))
                     (funcall fn (format nil "← ~A ok" name)))
                 resp))))))
