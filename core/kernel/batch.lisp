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
;;; 工具解析（找不到 ≠ 崩掉整轮对话）
;;; ============================================================

(defun resolve-callback (options tool-call)
  "为一次 tool-call 解析 callback。

返回 (values callback error-result)：
  - 找到   → (values callback nil)
  - 找不到 → (values nil tool-result(:error :semantic))

find-callback-for-call 找不到工具时是 signal 而非返回 nil。它的调用点
在构造 tool-request **之前**，落在 invoke-tool → tool-apply-terminal
的 handler-case 之外——于是模型只要报出一个不存在的工具名（LLM 幻觉
工具名很常见），条件就会一路冒泡出 (chat ...)，整轮对话直接中断。

正确语义是把「找不到工具」当作一次**语义故障**：转成文本回传模型，
让它自纠（旧 ToolCallingManager 的 process-tool-execution-error 就是
这么做的，Spring 的默认语义亦然）。安全边界不受影响——找不到就是
找不到，绝不回退全局注册表去执行未暴露的工具。"
  (handler-case (values (cl-agent.chat:find-callback-for-call options tool-call)
                        nil)
    (cl-agent.chat:tool-not-found-error (e)
      (values nil (make-tool-result
                   :error (list :class :semantic
                                :message (princ-to-string e)))))))

(defun tool-result->text (tool-result)
  "把 tool-result 转成回传模型的文本。

错误结果要把原因说清楚：模型看到「找不到工具 xxx」才可能自纠
（改用别的工具、修参数）；只说「（执行失败）」等于让它盲猜。
这也是旧 ToolCallingManager 的 process-tool-execution-error 默认语义。"
  (or (tool-result-value tool-result)
      (let ((err (tool-result-error tool-result)))
        (if err
            (format nil "错误：~A" (or (getf err :message) "工具执行失败"))
            "（执行失败）"))))

;;; ============================================================
;;; 并行/串行执行
;;; ============================================================

(defun batch-has-serial-p (tool-calls options)
  "检查批次中是否有任一工具声明了 :serial。
解析不到的工具当作非 serial——它根本不会被执行。"
  (some (lambda (tc)
          (let ((cb (resolve-callback options tc)))
            (and cb (cl-agent.chat:tool-callback-serial-p cb))))
        tool-calls))

(defun execute-batch-sequential (kernel tool-calls options context)
  "顺序执行整批工具调用。
返回 (values tool-results return-direct-p errors)"
  (let ((return-direct t)
        (results nil)
        (errors nil))
    (dolist (tc tool-calls)
      (multiple-value-bind (callback resolve-error) (resolve-callback options tc)
        (let* ((direct-p (and callback (cl-agent.chat:tool-callback-return-direct-p callback)))
               ;; 解析不到就不进 :tool 链——没有工具可执行，
               ;; 直接产出语义错误结果回传模型
               (resp (or resolve-error
                         (invoke-tool kernel
                                      (make-tool-request
                                       callback
                                       :args (cl-agent.chat:arguments->plist
                                              (cl-agent.chat:tool-call-arguments tc))
                                       :context context)))))
          (unless direct-p (setf return-direct nil))
          (push resp results)
          (when (tool-result-error resp)
            (push (cons tc (tool-result-error resp)) errors)))))
    (values (nreverse results) return-direct errors)))

(defun execute-batch-parallel (kernel tool-calls options context)
  "并行执行整批工具调用（lparallel:future + force）。
≤1 个工具时退化顺序执行。
返回 (values tool-results return-direct-p errors)"
  (if (<= (length tool-calls) 1)
      (execute-batch-sequential kernel tool-calls options context)
      ;; 预处理：解析 callback + 构建 req + 记录 direct-p
      ;; 解析在**提交并行任务之前**完成：解析失败直接产出错误结果，
      ;; 不占用 worker，也不会把条件抛出这个 mapcar（那会中断整轮对话）。
      (let* ((prepared
              (mapcar (lambda (tc)
                        (multiple-value-bind (callback resolve-error)
                            (resolve-callback options tc)
                          (let ((direct-p (and callback
                                               (cl-agent.chat:tool-callback-return-direct-p callback))))
                            (list direct-p
                                  resolve-error
                                  (when callback
                                    (make-tool-request
                                     callback
                                     :args (cl-agent.chat:arguments->plist
                                            (cl-agent.chat:tool-call-arguments tc))
                                     :context context))))))
                      tool-calls))
             ;; 并行提交（解析失败的不提交，直接用现成的错误结果）
             (futures
              (mapcar (lambda (prep)
                        (destructuring-bind (direct-p resolve-error req) prep
                          (declare (ignore direct-p))
                          (if resolve-error
                              resolve-error
                              (lparallel:future
                                (handler-case
                                    (invoke-tool kernel req)
                                  (error (e)
                                    (make-tool-result
                                     :error (list :class (classify-tool-error e)
                                                  :message (princ-to-string e)))))))))
                      prepared))
             ;; 收集结果（按序）。futures 里混着两种东西：真 future，
             ;; 以及解析失败时直接放进去的现成 tool-result——后者不能 force。
             (results (mapcar (lambda (f)
                                (if (typep f 'tool-result) f (lparallel:force f)))
                              futures))
             ;; prepared 的元素是 (direct-p resolve-error req)
             (return-direct (every #'first prepared))
             (errors (remove-if-not #'tool-result-error results)))
        (values results return-direct errors))))

(defun invoke-tool-batch (kernel tool-calls options context)
  "批量执行 tool-call 列表。

  策略：
  - 默认并行（lparallel）
  - 批内任一工具声明 :serial → 整批顺序执行
  - 工具异常被捕获并分类为 :semantic/:transient/:environment
  - :transient + 工具声明 :retry → 指数退避重试（最多 3 次）
  - 其他故障 → 转文本回传模型（error 放进 tool-result）

  返回 (values tool-results return-direct-p)：
  - tool-results = kernel:tool-result 列表（与 tool-calls 同序）
  - return-direct-p = 批内所有工具都声明了 return-direct 时为 t"
  (if (batch-has-serial-p tool-calls options)
      ;; 有 :serial → 顺序执行
      (execute-batch-sequential kernel tool-calls options context)
      ;; 默认并行
      (execute-batch-parallel kernel tool-calls options context)))
