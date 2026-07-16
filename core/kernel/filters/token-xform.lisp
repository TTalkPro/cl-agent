;;;; token-xform.lisp
;;;; CL-Agent Kernel Filters - 流式 token 变换 (:token-xform)
;;;;
;;;; 概述（对标 clj-agent token-redact-filter / hold-release-filter）：
;;;;   :token-xform 是 transducer 风格的流式变换，不是 around filter。
;;;;   作用于出站 token 流：脱敏、缓冲审等。
;;;;
;;;;   transducer 形态：(fn [rf] -> rf')，其中 rf 是 reducing function。
;;;;   在流式 terminal 内组装，不在 build-chain 中。

(in-package #:cl-agent.core)

;;; ============================================================
;;; token-redact-filter（无状态脱敏）
;;; ============================================================

(defun token-redact-filter (patterns &key (replacement "***"))
  "创建 token-redact-filter（:token-xform）。

  参数：
  - patterns     需要脱敏的正则/字符串列表
  - replacement  替换文本（缺省 ***）

  返回：transducer 函数 (fn [rf] -> rf')

  行为：对每个输出 token 文本做字符串替换（无状态，逐 token 处理）。"
  (let ((lower-patterns (mapcar (lambda (p)
                                  (if (stringp p) (string-downcase p) p))
                                patterns)))
    (lambda (rf)
      (lambda (&optional (acc nil acc-p))
        (if acc-p
            (funcall rf acc)  ; completion arity (flush)
            (lambda (token)
              ;; token 是 plist: (:token "text") 或 (:reasoning-token "text")
              (let* ((text (getf token :token))
                     (redacted
                      (if text
                          (let ((lower (string-downcase text)))
                            (reduce (lambda (str pattern)
                                      (if (search pattern str :test #'char-equal)
                                          replacement
                                          str))
                                    lower-patterns
                                    :initial-value text))
                          text)))
                (funcall rf (if redacted
                                (list :token redacted)
                                token)))))))))

;;; ============================================================
;;; hold-release-filter（先审后放）
;;; ============================================================

(defun hold-release-filter (&key (approve-fn nil))
  "创建 hold-release-filter（:token-xform）。

  参数：
  - approve-fn  (full-text) → approved-p 的审批函数；缺省：总是放行

  返回：transducer 函数

  行为：
  - 缓冲所有 token（不即时输出）
  - 流结束时调 approve-fn 审批
  - approved → 一次性输出全部
  - rejected → 输出拒答文本"
  (let ((fn (or approve-fn (lambda (text) (declare (ignore text)) t))))
    (lambda (rf)
      (let ((buffer nil))
        (lambda (&optional (acc nil acc-p))
          (if acc-p
              ;; 流结束：审批
              (let* ((full-text (apply #'concatenate 'string (nreverse buffer)))
                     (approved (funcall fn full-text)))
                (funcall rf
                         (if approved
                             full-text
                             "（内容未通过审核，已拦截）")))
              ;; 正常 token：缓冲
              (lambda (token)
                (let ((text (getf token :token)))
                  (when text (push text buffer)))
                acc)))))))  ; 不调 rf，返回 acc（透传累积器）
