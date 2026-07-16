;;;; timeout.lisp
;;;; CL-Agent Kernel Filters - 超时拦截 (:tool)
;;;;
;;;; 概述（对标 clj-agent timeout-filter）：
;;;;   工具执行超时 → 返回 :transient 错误（可触发 :retry）。

(in-package #:cl-agent.core)

(defun timeout-filter (milliseconds)
  "创建 timeout-filter（:tool 链）。

  参数：
  - milliseconds  超时毫秒数

  行为：
  - 用 bordeaux-threads 在独立线程执行工具
  - 超时 → 返回 tool-result(:error :class :transient)
  - 未超时 → 正常返回结果"
  (make-filter
   :timeout
   :tool (lambda (req chain)
           (let ((result-box (cons nil nil))
                 (done (bt:make-condition-variable))
                 (lock (bt:make-lock))
                 (timed-out nil))
             ;; 启动执行线程
             (bt:make-thread
              (lambda ()
                (let ((resp (funcall chain req)))
                  (bt:with-lock-held (lock)
                    (setf (car result-box) resp)
                    (bt:condition-notify done)))))
             ;; 等待结果或超时
             (bt:with-lock-held (lock)
               (unless (car result-box)
                 (bt:condition-wait done lock
                                    :timeout (/ milliseconds 1000.0))
                 (unless (car result-box)
                   (setf timed-out t))))
             (if timed-out
                 (make-tool-result
                  :error (list :class :transient
                               :message (format nil "工具执行超时（~Ams）" milliseconds)))
                 (car result-box))))))
