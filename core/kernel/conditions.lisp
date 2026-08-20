;;;; conditions.lisp
;;;; CL-Agent Kernel - 工具故障分类条件体系
;;;;
;;;; 概述：
;;;;   三类故障（对标 clj-agent 的 err/classify-exception）：
;;;;   - :semantic    模型问题（参数格式错误、逻辑错误）→ 不重试
;;;;   - :transient   瞬态故障（网络超时、限流、服务暂不可用）→ 指数退避重试
;;;;   - :environment 环境错误（依赖服务宕机、权限不足）→ 暂停等人介入
;;;;
;;;;   classify-tool-error 把任意 condition 映射到三类之一。
;;;;   屏障路由（barrier routing）在 invoke-tool-batch 中按分类决定策略。

(in-package #:cl-agent/core)

;;; ============================================================
;;; 条件层次
;;; ============================================================

(define-condition tool-failure (error)
  ((class :initarg :class :reader tool-failure-class
          :documentation "故障分类：:semantic / :transient / :environment")
   (message :initarg :message :initform nil :reader tool-failure-message))
  (:report (lambda (c stream)
             (format stream "工具执行失败 [~A]~@[：~A~]"
                     (tool-failure-class c)
                      (tool-failure-message c)))))

(define-condition semantic-tool-failure (tool-failure)
  ()
  (:default-initargs :class :semantic)
  (:documentation "模型问题：参数错误、逻辑错误、不支持的操作。不重试。"))

(define-condition transient-tool-failure (tool-failure)
  ()
  (:default-initargs :class :transient)
  (:documentation "瞬态故障：网络超时、限流、临时不可用。可重试。"))

(define-condition environment-tool-failure (tool-failure)
  ()
  (:default-initargs :class :environment)
  (:documentation "环境错误：依赖服务宕机、权限不足、配置缺失。需人工介入。"))

;;; ============================================================
;;; 故障分类器
;;; ============================================================

(defun classify-tool-error (condition)
  "把任意 condition 映射到 :semantic / :transient / :environment。

  分类规则（按优先级）：
  1. tool-failure 子类 → 直接取 :class
  2. tool-execution-error → **解包 cause 后递归分类**（见下）
  3. tool-not-found-error → :semantic（模型报了个不存在的工具名）
  4. 网络类错误（超时/连接拒绝/限流）→ :transient
  5. 权限/认证类错误 → :environment
  6. 其他 → :semantic（保守默认，不重试）

  关于第 2 条：cl-agent/core:tool-callback-call 会把工具体内抛出的
  **一切** condition 包成 tool-execution-error（原件塞进 :cause）。
  此前这里直接把 tool-execution-error 判成 :semantic，于是工具明明
  signal 了 transient-tool-failure，走完真实路径后也只剩 :semantic——
  三类故障在实际链路上退化成一类，分类体系形同虚设。
  必须解包 cause 才拿得到真分类。"
  (etypecase condition
    (tool-failure (tool-failure-class condition))
    (cl-agent/core:tool-not-found-error :semantic)
    (cl-agent/core:tool-execution-error
     ;; 包装层：真正的分类信息在 cause 里
     (let ((cause (tool-execution-error-cause condition)))
       (if cause
           (classify-tool-error cause)
           :semantic)))
    (error
     ;; 启发式分类：检查错误消息中的关键词
     (let ((msg (princ-to-string condition)))
       (cond
         ((or (search "timeout" msg :test #'char-equal)
              (search "超时" msg)
              (search "connection refused" msg :test #'char-equal)
              (search "connection reset" msg :test #'char-equal)
              (search "temporarily unavailable" msg :test #'char-equal)
              (search "429" msg)
              (search "503" msg))
          :transient)
         ((or (search "permission denied" msg :test #'char-equal)
              (search "unauthorized" msg :test #'char-equal)
              (search "forbidden" msg :test #'char-equal)
              (search "权限不足" msg)
              (search "认证失败" msg))
          :environment)
         (t :semantic))))))
