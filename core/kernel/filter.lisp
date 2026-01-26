;;;; filter.lisp
;;;; CL-Agent Kernel - 4-Type Filter Pipeline (CLOS)
;;;;
;;;; 概述：
;;;;   实现 4 种类型的过滤器管道：
;;;;   - :pre-invocation  - 工具执行前
;;;;   - :post-invocation - 工具执行后
;;;;   - :pre-chat        - LLM 调用前
;;;;   - :post-chat       - LLM 调用后
;;;;
;;;; 设计：
;;;;   - 使用 CLOS 类替代 plist
;;;;   - 洋葱模型：外层过滤器包裹内层
;;;;   - 每个过滤器返回 (:action :continue/:skip/:error :context ctx)
;;;;   - 过滤器可以修改上下文、跳过执行或发出错误

(in-package #:cl-agent.kernel)

;;; ============================================================
;;; Filter 类型定义
;;; ============================================================

(deftype filter-type ()
  "有效的过滤器类型"
  '(member :pre-invocation :post-invocation :pre-chat :post-chat))

(deftype filter-action ()
  "有效的过滤器返回动作"
  '(member :continue :skip :error))

;;; ============================================================
;;; Filter CLOS 类
;;; ============================================================

(defclass filter ()
  ((name
    :initarg :name
    :accessor filter-name
    :type string
    :documentation "过滤器名称（用于调试）")
   (type
    :initarg :type
    :accessor filter-type
    :type keyword
    :documentation "过滤器类型")
   (fn
    :initarg :fn
    :accessor filter-fn
    :type function
    :documentation "过滤器函数 (context next-fn) -> result")
   (priority
    :initarg :priority
    :accessor filter-priority
    :initform 100
    :type integer
    :documentation "优先级（越小越先执行）"))
  (:documentation "Filter 基类

过滤器用于在工具执行和 LLM 调用前后进行处理。
每个过滤器接收上下文和下一个函数，返回结果或过滤器结果。

类型：
  :pre-invocation  - 工具执行前
  :post-invocation - 工具执行后
  :pre-chat        - LLM 调用前
  :post-chat       - LLM 调用后"))

;;; ============================================================
;;; Filter 泛型方法
;;; ============================================================

(defgeneric filter-apply (filter context)
  (:documentation "Apply a filter to the given context.

Parameters:
  FILTER  - Filter instance
  CONTEXT - Execution context

Returns:
  Modified context or filter-result

Note:
  This generic allows class-based filters (like RAG augmentation)
  to implement custom application logic as methods."))

;;; ============================================================
;;; Filter 构造函数
;;; ============================================================

(defun make-filter (&key type name fn (priority 100))
  "创建 Filter 实例

参数：
  TYPE     - 过滤器类型
  NAME     - 过滤器名称
  FN       - 过滤器函数 (context next-fn) -> result
  PRIORITY - 优先级（越小越先执行）

返回：
  Filter 实例

示例：
  (make-filter
    :type :pre-invocation
    :name \"logging\"
    :fn (lambda (ctx next) (log-call ctx) (funcall next ctx)))"
  (make-instance 'filter
                 :type type
                 :name (or name "unnamed")
                 :fn fn
                 :priority priority))

;;; ============================================================
;;; Filter 谓词
;;; ============================================================

(defun filter-p (obj)
  "检查是否为 Filter 实例"
  (typep obj 'filter))

;;; ============================================================
;;; Filter 结果
;;; ============================================================

(defclass filter-result ()
  ((action
    :initarg :action
    :accessor filter-result-action
    :type keyword
    :documentation "动作：:continue, :skip, :error")
   (context
    :initarg :context
    :accessor filter-result-context
    :initform nil
    :documentation "修改后的上下文")
   (result
    :initarg :result
    :accessor filter-result-value
    :initform nil
    :documentation ":skip 动作的结果值")
   (message
    :initarg :message
    :accessor filter-result-message
    :initform nil
    :type (or null string)
    :documentation ":error 动作的错误消息"))
  (:documentation "Filter 执行结果"))

(defun make-filter-result (action &key context result message)
  "创建 Filter 结果

参数：
  ACTION  - :continue, :skip, 或 :error
  CONTEXT - 修改后的上下文（可选）
  RESULT  - :skip 动作的结果值
  MESSAGE - :error 动作的错误消息

返回：
  Filter 结果 plist（为兼容性保持 plist 格式）"
  (let ((res (list :action action)))
    (when context (setf (getf res :context) context))
    (when result (setf (getf res :result) result))
    (when message (setf (getf res :message) message))
    res))

(defun normalize-filter (filter)
  "规范化过滤器为 Filter 实例或 plist

参数：
  FILTER - Filter 实例或 plist

返回：
  规范化的过滤器"
  (cond
    ((filter-p filter) filter)
    ((and (listp filter) (getf filter :fn)) filter)  ; 已经是 plist
    (t (error "Invalid filter: ~A. Use make-filter to create filters." filter))))

;;; ============================================================
;;; Filter 链构建
;;; ============================================================

(defun build-filter-chain (filters execute-fn)
  "构建洋葱模型过滤器链

参数：
  FILTERS    - 过滤器列表（从外到内）
  EXECUTE-FN - 最内层执行函数 (context) -> result

返回：
  组合函数 (context) -> result

说明：
  如果 FILTERS 是 '(f1 f2 f3)，调用顺序是：
  f1 -> f2 -> f3 -> execute-fn -> f3 -> f2 -> f1"
  (if (null filters)
      execute-fn
      (let ((chain execute-fn))
        (dolist (filter (reverse filters))
          (let* ((normalized (normalize-filter filter))
                 (filter-fn (if (filter-p normalized)
                                (filter-fn normalized)
                                (getf normalized :fn)))
                 (next chain))
            (setf chain
                  (lambda (context)
                    (let ((result (funcall filter-fn context next)))
                      ;; 处理 filter-result 格式
                      (cond
                        ;; plist 结果
                        ((and (listp result) (getf result :action))
                         (case (getf result :action)
                           (:continue
                            (funcall next (or (getf result :context) context)))
                           (:skip
                            (getf result :result))
                           (:error
                            (error (or (getf result :message) "Filter error")))))
                        ;; 遗留格式：直接返回结果
                        (t result)))))))
        chain)))

(defun build-typed-filter-chain (filters type execute-fn)
  "为特定类型构建过滤器链

参数：
  FILTERS    - 所有过滤器列表
  TYPE       - 要选择的过滤器类型
  EXECUTE-FN - 内层函数

返回：
  该类型的过滤器链"
  (let ((typed-filters (filter-by-type filters type)))
    (setf typed-filters (sort-filters-by-priority typed-filters))
    (build-filter-chain typed-filters execute-fn)))

;;; ============================================================
;;; Filter 操作函数
;;; ============================================================

(defun combine-filters (&rest filter-lists)
  "合并多个过滤器列表

参数：
  FILTER-LISTS - 要合并的过滤器列表

返回：
  合并后的过滤器列表"
  (apply #'append filter-lists))

(defun filter-by-type (filters type)
  "按类型筛选过滤器

参数：
  FILTERS - 过滤器列表
  TYPE    - 过滤器类型

返回：
  指定类型的过滤器列表"
  (remove-if-not
   (lambda (f)
     (let ((normalized (normalize-filter f)))
       (eq (if (filter-p normalized)
               (filter-type normalized)
               (getf normalized :type))
           type)))
   filters))

(defun sort-filters-by-priority (filters)
  "按优先级排序过滤器（越小越先）

参数：
  FILTERS - 过滤器列表

返回：
  排序后的过滤器列表"
  (sort (copy-list filters) #'<
        :key (lambda (f)
               (let ((normalized (normalize-filter f)))
                 (if (filter-p normalized)
                     (filter-priority normalized)
                     (getf normalized :priority 100))))))

;;; ============================================================
;;; 内置过滤器工厂
;;; ============================================================

(defun make-logging-filter (&key (stream *standard-output*) (type :pre-invocation))
  "创建日志过滤器

参数：
  STREAM - 输出流（默认 *standard-output*）
  TYPE   - 过滤器类型（默认 :pre-invocation）

返回：
  Filter 实例"
  (make-filter
   :type type
   :name "logging"
   :fn (lambda (context next-fn)
         (let ((tool-name (getf context :tool-name))
               (tool-args (getf context :tool-args)))
           (format stream "[Filter] Calling tool: ~A with args: ~S~%"
                   tool-name tool-args)
           (let ((result (funcall next-fn context)))
             (format stream "[Filter] Tool ~A returned: ~S~%"
                     tool-name result)
             result)))))

(defun make-error-handling-filter (&key (type :pre-invocation))
  "创建错误处理过滤器

参数：
  TYPE - 过滤器类型（默认 :pre-invocation）

返回：
  Filter 实例"
  (make-filter
   :type type
   :name "error-handling"
   :fn (lambda (context next-fn)
         (handler-case
             (funcall next-fn context)
           (error (condition)
             (list :error t
                   :message (format nil "~A" condition)
                   :tool-name (getf context :tool-name)))))))

(defun make-timeout-filter (seconds &key (type :pre-invocation))
  "创建超时过滤器

参数：
  SECONDS - 超时秒数
  TYPE    - 过滤器类型（默认 :pre-invocation）

返回：
  Filter 实例"
  (make-filter
   :type type
   :name "timeout"
   :fn (lambda (context next-fn)
         (let ((start-time (get-internal-real-time)))
           (let ((result (funcall next-fn context)))
             (let ((elapsed (/ (- (get-internal-real-time) start-time)
                               internal-time-units-per-second)))
               (if (> elapsed seconds)
                   (list :error t
                         :message (format nil "Tool ~A timed out after ~A seconds"
                                          (getf context :tool-name) elapsed)
                         :tool-name (getf context :tool-name))
                   result)))))))

(defun make-approval-filter (&key sensitive-only approver-fn (type :pre-invocation))
  "创建审批过滤器

参数：
  SENSITIVE-ONLY - 仅检查敏感操作
  APPROVER-FN    - 审批函数 (context) -> boolean
  TYPE           - 过滤器类型（默认 :pre-invocation）

返回：
  Filter 实例"
  (make-filter
   :type type
   :name "approval"
   :fn (lambda (context next-fn)
         (let* ((kernel (getf context :kernel))
                (tool-name (getf context :tool-name))
                (tool (when kernel
                        (kernel-find-tool kernel tool-name)))
                ;; Check for :sensitive tag on the tool
                (needs-approval (if sensitive-only
                                    (and tool
                                         (member :sensitive
                                                 (%tools-tool-tags tool)))
                                    t)))
           (if (and needs-approval approver-fn)
               (if (funcall approver-fn context)
                   (funcall next-fn context)
                   (make-filter-result :skip
                                       :result (list :error t
                                                     :message (format nil "Tool ~A was denied"
                                                                      tool-name)
                                                     :denied t
                                                     :tool-name tool-name)))
               (funcall next-fn context))))))

(defun make-retry-filter (&key (max-retries 3) (backoff-base 2) (type :pre-invocation))
  "创建重试过滤器

参数：
  MAX-RETRIES  - 最大重试次数
  BACKOFF-BASE - 指数退避基数
  TYPE         - 过滤器类型

返回：
  Filter 实例"
  (make-filter
   :type type
   :name "retry"
   :fn (lambda (context next-fn)
         (let ((retries 0))
           (loop
             (handler-case
                 (return (funcall next-fn context))
               (error (e)
                 (if (< retries max-retries)
                     (progn
                       (incf retries)
                       (sleep (* (expt backoff-base retries) 0.1)))
                     (error e)))))))))

(defun make-tracing-filter (&key (type :pre-invocation))
  "创建追踪过滤器（记录到 context）

参数：
  TYPE - 过滤器类型

返回：
  Filter 实例"
  (make-filter
   :type type
   :name "tracing"
   :fn (lambda (context next-fn)
         (let ((start-time (get-internal-real-time))
               (context-obj (getf context :context-object)))
           ;; 记录调用
           (when (and context-obj (typep context-obj 'context))
             (context-trace-add context-obj :tool-call
                                :data (list :tool-name (getf context :tool-name)
                                            :tool-args (getf context :tool-args))))
           (let ((result (funcall next-fn context)))
             ;; 记录结果
             (when (and context-obj (typep context-obj 'context))
               (context-trace-add context-obj :tool-result
                                  :data (list :tool-name (getf context :tool-name)
                                              :result result
                                              :duration-ms
                                              (* 1000 (/ (- (get-internal-real-time) start-time)
                                                         internal-time-units-per-second)))))
             result)))))

;;; ============================================================
;;; Pre-Chat / Post-Chat 过滤器
;;; ============================================================

(defun make-pre-chat-logging-filter (&key (stream *standard-output*))
  "创建 pre-chat 日志过滤器

参数：
  STREAM - 输出流

返回：
  Filter 实例"
  (make-filter
   :type :pre-chat
   :name "pre-chat-logging"
   :fn (lambda (context next-fn)
         (format stream "[Pre-Chat] Messages: ~A, Tools: ~A~%"
                 (length (getf context :messages))
                 (length (getf context :tools)))
         (funcall next-fn context))))

(defun make-post-chat-logging-filter (&key (stream *standard-output*))
  "创建 post-chat 日志过滤器

参数：
  STREAM - 输出流

返回：
  Filter 实例"
  (make-filter
   :type :post-chat
   :name "post-chat-logging"
   :fn (lambda (context next-fn)
         (let ((result (funcall next-fn context)))
           (format stream "[Post-Chat] Response: ~A tool-calls~%"
                   (length (getf result :tool-calls)))
           result))))

(defun make-message-transform-filter (transform-fn &key (type :pre-chat))
  "创建消息转换过滤器

参数：
  TRANSFORM-FN - 转换函数 (messages) -> messages
  TYPE         - 过滤器类型（:pre-chat 或 :post-chat）

返回：
  Filter 实例"
  (make-filter
   :type type
   :name "message-transform"
   :fn (lambda (context next-fn)
         (if (eq type :pre-chat)
             ;; Pre-chat：转换消息
             (let ((new-messages (funcall transform-fn (getf context :messages))))
               (funcall next-fn (list* :messages new-messages context)))
             ;; Post-chat：直接传递
             (funcall next-fn context)))))

;;; ============================================================
;;; 打印方法
;;; ============================================================

(defmethod print-object ((filter filter) stream)
  "打印 Filter 对象"
  (print-unreadable-object (filter stream :type t)
    (format stream "~A ~A priority=~A"
            (filter-type filter)
            (filter-name filter)
            (filter-priority filter))))
