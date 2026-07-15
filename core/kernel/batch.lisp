;;;; batch.lisp
;;;; CL-Agent Kernel - 批量工具执行（并行默认 + :serial 退化 + 故障路由）
;;;;
;;;; 概述（对标 clj-agent 的 react/execute-batch）：
;;;;   批次内工具默认并行执行（lparallel）；任一工具声明 :serial
;;;;   则整批退化按序。故障按 :semantic/:transient/:environment 分类路由。
;;;;
;;;;   策略矩阵：
;;;;   | 分类          | 工具声明 :retry | 动作                          |
;;;;   |---------------|----------------|-------------------------------|
;;;;   | :semantic     | 任意           | 转文本回传模型（不中断循环）   |
;;;;   | :transient    | t              | 指数退避重试（默认 3 次）     |
;;;;   | :transient    | nil            | 转文本回传模型                 |
;;;;   | :environment  | 任意           | 转文本回传模型（P3 暂不暂停）  |

(in-package #:cl-agent.kernel)

;;; ============================================================
;;; 并行/串行执行
;;; ============================================================

(defun batch-has-serial-p (tool-calls options)
  "检查批次中是否有任一工具声明了 :serial。"
  (some (lambda (tc)
          (let ((cb (cl-agent.chat::find-callback-for-call options tc)))
            (and cb (cl-agent.chat:tool-callback-serial-p cb))))
        tool-calls))

(defun execute-batch-sequential (kernel tool-calls options context)
  "顺序执行整批工具调用。
返回 (values tool-responses return-direct-p errors)"
  (let ((return-direct t)
        (results nil)
        (errors nil))
    (dolist (tc tool-calls)
      (let* ((callback (cl-agent.chat::find-callback-for-call options tc))
             (direct-p (and callback (cl-agent.chat:tool-callback-return-direct-p callback)))
             (req (make-tool-request
                   callback
                   :args (cl-agent.chat:arguments->plist
                          (cl-agent.chat:tool-call-arguments tc))
                   :context context))
             (resp (invoke-tool kernel req)))
        (unless direct-p (setf return-direct nil))
        (push resp results)
        (when (tool-response-error resp)
          (push (cons tc (tool-response-error resp)) errors))))
    (values (nreverse results) return-direct errors)))

(defun execute-batch-parallel (kernel tool-calls options context)
  "并行执行整批工具调用（lparallel:future + force）。
≤1 个工具时退化顺序执行。
返回 (values tool-responses return-direct-p errors)"
  (if (<= (length tool-calls) 1)
      (execute-batch-sequential kernel tool-calls options context)
      ;; 预处理：解析 callback + 构建 req + 记录 direct-p
      (let* ((prepared
              (mapcar (lambda (tc)
                        (let* ((callback (cl-agent.chat::find-callback-for-call options tc))
                               (direct-p (and callback
                                              (cl-agent.chat:tool-callback-return-direct-p callback)))
                               (req (make-tool-request
                                     callback
                                     :args (cl-agent.chat:arguments->plist
                                            (cl-agent.chat:tool-call-arguments tc))
                                     :context context)))
                          (list callback direct-p req)))
                      tool-calls))
             ;; 并行提交
             (futures
              (mapcar (lambda (prep)
                        (let ((req (third prep)))
                          (lparallel:future
                            (handler-case
                                (invoke-tool kernel req)
                              (error (e)
                                (make-tool-response
                                 :error (list :class (classify-tool-error e)
                                              :message (princ-to-string e))))))))
                      prepared))
             ;; 收集结果（按序）
             (results (mapcar #'lparallel:force futures))
             (return-direct (every #'second prepared))
             (errors (remove-if-not #'tool-response-error results)))
        (values results return-direct errors))))

(defun invoke-tool-batch (kernel tool-calls options context)
  "批量执行 tool-call 列表。

  策略：
  - 默认并行（lparallel）
  - 批内任一工具声明 :serial → 整批顺序执行
  - 工具异常被捕获并分类为 :semantic/:transient/:environment
  - :transient + 工具声明 :retry → 指数退避重试（最多 3 次）
  - 其他故障 → 转文本回传模型（error 放进 tool-response）

  返回 (values tool-responses return-direct-p)：
  - tool-responses = kernel:tool-response 列表（与 tool-calls 同序）
  - return-direct-p = 批内所有工具都声明了 return-direct 时为 t"
  (if (batch-has-serial-p tool-calls options)
      ;; 有 :serial → 顺序执行
      (execute-batch-sequential kernel tool-calls options context)
      ;; 默认并行
      (execute-batch-parallel kernel tool-calls options context)))
