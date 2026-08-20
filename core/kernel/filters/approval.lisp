;;;; approval.lisp
;;;; CL-Agent Kernel Filters - 工具审批 (:tool)
;;;;
;;;; 概述（对标 clj-agent approval-filter）：
;;;;   敏感工具执行前要求审批。审批通过 → 执行；拒绝 → 返回拒绝文本回传模型。

(in-package #:cl-agent/core)

(defun approval-filter (&key (approve-fn nil) (sensitive-names nil))
  "创建 approval-filter（:tool 链）。

  参数：
  - approve-fn       (tool-name args) → (values approved-p reason) 的审批函数；
                     缺省：从 stdin 读取 y/n
  - sensitive-names  需要审批的工具名列表（字符串/符号）；缺省：全部审批

  行为：
  - 工具名不在 sensitive-names 且 sensitive-names 非空 → 直接执行
  - 否则调 approve-fn
  - approved → 执行
  - rejected → 返回 tool-result(value=拒绝文本)，不执行"
  (let ((fn (or approve-fn
                (lambda (name args)
                  (format t "~&[审批] 工具 ~A 参数 ~S~%批准？(y/n): " name args)
                  (finish-output)
                  (let ((line (string-trim '(#\Space #\Newline)
                                            (read-line))))
                    (values (string-equal line "y")
                            (unless (string-equal line "y") "用户拒绝"))))))
        (lower-names (when sensitive-names
                       (mapcar (lambda (n) (string-downcase (string n))) sensitive-names))))
    (make-filter
     :approval
     :tool (lambda (req chain)
             (let* ((callback (tool-request-function req))
                    (name (cl-agent/core:tool-callback-name callback))
                    (lname (string-downcase name))
                    (args (tool-request-args req)))
               ;; 判断是否需要审批
               (if (and lower-names
                        (not (member lname lower-names :test #'string=)))
                   ;; 不在敏感列表 → 直接执行
                   (funcall chain req)
                   ;; 需要审批
                   (multiple-value-bind (approved reason)
                       (funcall fn name args)
                     (if approved
                         (funcall chain req)
                         ;; 拒绝：返回拒绝文本
                         (make-tool-result
                          :value (format nil "工具 ~A 被拒绝执行~@[：~A~]"
                                         name reason))))))))))
