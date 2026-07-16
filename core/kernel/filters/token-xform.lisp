;;;; token-xform.lisp
;;;; CL-Agent Kernel Filters - 流式 token 变换 (:token-xform)
;;;;
;;;; 概述（对标 clj-agent token-redact-filter / hold-release-filter）：
;;;;   :token-xform 不是 around filter——它作用于**出站 token 流**，
;;;;   在流式 terminal 内侧组装（见 invoke-chat-stream / compose-token-xforms），
;;;;   不参与 build-chain。
;;;;
;;;;   协议：(downstream-emit) → (values emit finish)
;;;;   - downstream-emit  往更内层送 token 的函数
;;;;   - emit             (token-plist) → nil；可改写、丢弃、缓冲
;;;;   - finish           () → nil；流结束时调用，缓冲型 xform 在此吐出；
;;;;                      无缓冲的给 nil 即可
;;;;
;;;;   token 是 plist：(:token "增量文本")。
;;;;
;;;; 历史：这两个 filter 曾是**装饰品**，而且是三重的：
;;;;   1. 没有任何代码读 filter-token-xform 去组装流——invoke-chat-stream
;;;;      当时根本不存在，kernel-chat-stream 是同步降级；
;;;;   2. 它们**返回裸 lambda 而不是 filter 实例**，压根放不进 :filters
;;;;      （名字叫 xxx-filter 却不是 filter）；
;;;;   3. 协议照搬 transducer 的 arity 重载，0-arity 竟然返回一个函数当
;;;;      step 用。
;;;; 三条互相掩护：因为放不进 :filters，也就从没被组装，于是没人发现
;;;; 协议是拧的。现在三条都修了。

(in-package #:cl-agent.core)

;;; ============================================================
;;; token-redact-filter（无状态脱敏）
;;; ============================================================

(defun token-redact-filter (patterns &key (replacement "***"))
  "创建 token-redact-filter（:token-xform）。

  参数：
  - patterns     需要脱敏的字符串列表（大小写不敏感）
  - replacement  命中后的替换文本（缺省 ***）

  行为：逐 token 检查，命中任一 pattern 就把**整个 token** 换成 replacement。
  无状态、不缓冲——token 即时透传，流式体验不受影响。

  局限（如实说明）：只在**单个 token 内**匹配。LLM 的增量切分是任意的，
  敏感词很可能被切在两个 token 里（\"pass\" + \"word\"），那样就匹配不到。
  要可靠拦截请用 hold-release-filter（全文到齐再审），代价是失去流式。"
  (let ((pats (remove-if-not #'stringp patterns)))
    (make-filter
     :token-redact
     :token-xform
     (lambda (downstream)
       (values
        (lambda (token)
          (let ((text (getf token :token)))
            (funcall downstream
                     (if (and text
                              (some (lambda (p) (search p text :test #'char-equal)) pats))
                         (list :token replacement)
                         token))))
        ;; 无缓冲 → 无需 flush
        nil)))))

;;; ============================================================
;;; hold-release-filter（先审后放）
;;; ============================================================

(defun hold-release-filter (&key (approve-fn nil))
  "创建 hold-release-filter（:token-xform）。

  参数：
  - approve-fn  (full-text) → approved-p；缺省总是放行

  行为：
  - 缓冲全部 token，**期间不向下游送任何东西**（故失去流式体验）
  - 流结束时把全文交给 approve-fn 审
  - 通过 → 一次性送出全文；否决 → 送出拒答文本

  这是 token-redact-filter 的补充：redact 保住流式但只能在单 token 内
  匹配；hold-release 能看到全文（可靠），代价是要等流结束。"
  (let ((fn (or approve-fn (lambda (text) (declare (ignore text)) t))))
    (make-filter
     :hold-release
     :token-xform
     (lambda (downstream)
       (let ((buffer nil))
         (values
          ;; emit：只缓冲，不下送
          (lambda (token)
            (let ((text (getf token :token)))
              (when text (push text buffer)))
            nil)
          ;; finish：审批后一次性下送
          (lambda ()
            (let ((full (apply #'concatenate 'string (nreverse buffer))))
              (setf buffer nil)
              (funcall downstream
                       (list :token (if (funcall fn full)
                                        full
                                        "（内容未通过审核，已拦截）")))))))))))
