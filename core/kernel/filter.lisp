;;;; filter.lisp
;;;; CL-Agent Kernel - 洋葱式 Filter 管道（CLOS）
;;;;
;;;; 概述：
;;;;   Filter 的根抽象是 around：(lambda (request chain) -> response)，
;;;;   chain 代表"下游（后续 filter + 最内层 terminal）"。
;;;;   before/after 是 around 的语法糖；同一套执行器服务于两条链：
;;;;
;;;;   - :chat 链  — 包裹 LLM 调用（chat-request -> llm-response）
;;;;   - :tool 链  — 包裹工具执行（tool-request -> result）
;;;;
;;;;   旧的 4 类型（:pre/post-invocation、:pre/post-chat）继续兼容：
;;;;   它们映射到对应的 phase，并保持原有的嵌套位置
;;;;   （pre 在外层、post 在内层，详见 effective-rank）。
;;;;
;;;; 设计（参照 clj-agent design/onion-filter.md）：
;;;;   - 真洋葱：单个 filter 的 before/after 段共享闭包局部状态，
;;;;     可重试、可缓存短路（不调 chain）
;;;;   - 短路：filter 不调 chain，直接返回响应（或 :skip 结果）
;;;;   - CLOS：filter / 请求 / 结果均为类；子类可特化 filter-around
;;;;     （如 memory-filter、RAG augmentation filter）

(in-package #:cl-agent.kernel)

;;; ============================================================
;;; Filter 类型定义
;;; ============================================================

(deftype filter-phase ()
  "Filter 所属的链"
  '(member :chat :tool))

(deftype filter-type ()
  "有效的过滤器类型（含旧 4 类型，向后兼容）"
  '(member :chat :tool
           :pre-invocation :post-invocation :pre-chat :post-chat))

(deftype filter-action ()
  "有效的过滤器返回动作"
  '(member :continue :skip :error))

;;; ============================================================
;;; 请求对象（CLOS）
;;; ============================================================
;;; chat filter 可改写的全部在 chat-request 上：
;;; messages / tools / tool-choice / system-prompt / settings / context

(defclass chat-request ()
  ((messages
    :initarg :messages
    :initform nil
    :accessor chat-request-messages
    :documentation "中立消息列表")
   (tools
    :initarg :tools
    :initform nil
    :accessor chat-request-tools
    :documentation "工具 schema 列表")
   (tool-choice
    :initarg :tool-choice
    :initform :auto
    :accessor chat-request-tool-choice
    :documentation ":auto | :required | :none")
   (system-prompt
    :initarg :system-prompt
    :initform nil
    :accessor chat-request-system-prompt
    :documentation "系统提示")
   (settings
    :initarg :settings
    :initform nil
    :accessor chat-request-settings
    :documentation "设置 plist（max-tokens / temperature 等）")
   (context
    :initarg :context
    :initform nil
    :accessor chat-request-context
    :documentation "执行上下文（context 实例或 plist；conversation-id 在这里）")
   (kernel
    :initarg :kernel
    :initform nil
    :reader chat-request-kernel
    :documentation "发起请求的 Kernel"))
  (:documentation "Chat 链的请求对象，chat filter 可改写其全部可变槽位。"))

(defun make-chat-request (&rest initargs)
  "创建 chat-request 实例"
  (apply #'make-instance 'chat-request initargs))

(defclass tool-request ()
  ((tool-name
    :initarg :tool-name
    :accessor tool-request-name
    :documentation "工具名称（关键字）")
   (args
    :initarg :args
    :initform nil
    :accessor tool-request-args
    :documentation "参数 plist")
   (tool
    :initarg :tool
    :initform nil
    :reader tool-request-tool
    :documentation "工具实例（registry 中查到的）")
   (context
    :initarg :context
    :initform nil
    :accessor tool-request-context
    :documentation "执行上下文（plist，含 :tool-id / :context-object 等）")
   (kernel
    :initarg :kernel
    :initform nil
    :reader tool-request-kernel
    :documentation "发起请求的 Kernel"))
  (:documentation "Tool 链的请求对象。"))

(defun make-tool-request (&rest initargs)
  "创建 tool-request 实例"
  (apply #'make-instance 'tool-request initargs))

;;; ------------------------------------------------------------
;;; 统一字段访问：req-get 同时支持请求对象与 plist
;;; （供内置 filter 使用，兼容直接以 plist 调用 build-filter-chain 的旧代码）
;;; ------------------------------------------------------------

(defgeneric req-get (request key)
  (:documentation "从请求中读取字段。
KEY ∈ :tool-name :tool-args :kernel :messages :tools
      :tool-choice :system-prompt :settings :context"))

(defmethod req-get ((request list) key)
  "plist 请求（旧格式）"
  (case key
    (:tool-args (getf request :tool-args))
    (t (getf request key))))

(defmethod req-get ((request chat-request) key)
  (case key
    (:messages      (chat-request-messages request))
    (:tools         (chat-request-tools request))
    (:tool-choice   (chat-request-tool-choice request))
    (:system-prompt (chat-request-system-prompt request))
    (:settings      (chat-request-settings request))
    (:context       (chat-request-context request))
    (:kernel        (chat-request-kernel request))
    (t nil)))

(defmethod req-get ((request tool-request) key)
  (case key
    (:tool-name (tool-request-name request))
    (:tool-args (tool-request-args request))
    (:context   (tool-request-context request))
    (:kernel    (tool-request-kernel request))
    (t nil)))

;;; ============================================================
;;; Filter CLOS 类
;;; ============================================================

(defclass filter ()
  ((name
    :initarg :name
    :initform "unnamed"
    :accessor filter-name
    :documentation "过滤器名称（用于调试）")
   (type
    :initarg :type
    :initform :tool
    :accessor filter-type
    :documentation "phase（:chat / :tool）或旧 4 类型")
   (fn
    :initarg :fn
    :initform nil
    :accessor filter-fn
    :documentation "旧式 around 函数 (request next-fn) -> result
（与 around-fn 同形；保留以兼容旧 API）")
   (around-fn
    :initarg :around
    :initform nil
    :accessor filter-around-fn
    :documentation "around 函数 (request chain) -> response")
   (before-fn
    :initarg :before
    :initform nil
    :accessor filter-before-fn
    :documentation "before 段 (request) -> request（语法糖）")
   (after-fn
    :initarg :after
    :initform nil
    :accessor filter-after-fn
    :documentation "after 段 (response) -> response（语法糖）")
   (priority
    :initarg :priority
    :accessor filter-priority
    :initform 100
    :type integer
    :documentation "优先级（越小越靠外层：最先 before、最后 after）"))
  (:documentation "Filter 基类

根抽象是 around：(request chain) -> response。
三种定义方式（优先级从高到低）：
  1. :around — 完整 around，可短路（不调 chain）、可重试、可跨段共享状态
  2. :before / :after — 语法糖，等价 (after (chain (before request)))
  3. :fn — 旧式函数 (request next-fn)，可返回 filter-result 控制流

子类可直接特化 filter-around 泛型函数（如 memory-filter）。"))

;;; ============================================================
;;; Phase 解析
;;; ============================================================

(defgeneric filter-phase (filter)
  (:documentation "返回 filter 所属的链（:chat 或 :tool）。
旧 4 类型映射：:pre/post-invocation -> :tool；:pre/post-chat -> :chat"))

(defmethod filter-phase ((filter filter))
  (type->phase (filter-type filter)))

(defmethod filter-phase ((filter list))
  "plist filter"
  (type->phase (getf filter :type :tool)))

(defmethod filter-phase ((filter function))
  "裸函数默认挂 tool 链（兼容旧用法）"
  :tool)

(defun type->phase (type)
  "filter type -> phase"
  (case type
    ((:chat :pre-chat :post-chat) :chat)
    (t :tool)))

(defun effective-rank (filter)
  "组内排序辅助：同优先级时，旧 pre 类型在外层、旧 post 类型在内层，
新式 :chat/:tool 居中（保持旧 4 类型的嵌套几何）。"
  (let ((type (typecase filter
                (filter (filter-type filter))
                (list (getf filter :type))
                (t nil))))
    (case type
      ((:pre-invocation :pre-chat) 0)
      ((:post-invocation :post-chat) 2)
      (t 1))))

;;; ============================================================
;;; Filter 泛型方法
;;; ============================================================

(defgeneric filter-apply (filter context)
  (:documentation "对上下文应用 filter（类式 filter 的简化入口）。

子类只需实现本方法即可挂入链中（无 around/before/after/fn 时
filter-around 会以它为最后回退）。返回值约定与旧式 fn 相同：
:action plist / filter-result / 任意值（视为 :continue）。"))

(defmethod filter-apply ((filter filter) context)
  "默认实现：不做任何处理"
  (declare (ignore context))
  (list :action :continue))

;;; ============================================================
;;; Filter 构造函数
;;; ============================================================

(defun make-filter (&key type name fn around before after (priority 100))
  "创建 Filter 实例

参数：
  TYPE     - :chat / :tool（或旧 4 类型）
  NAME     - 过滤器名称
  AROUND   - around 函数 (request chain) -> response
  BEFORE   - before 段 (request) -> request
  AFTER    - after 段 (response) -> response
  FN       - 旧式函数 (request next-fn) -> result
  PRIORITY - 优先级（越小越靠外层）

返回：
  Filter 实例

示例：
  ;; before/after 语法糖
  (make-filter :type :chat :name \"trim\"
    :before (lambda (req) (trim-messages req) req))

  ;; 完整 around（可短路/重试/缓存）
  (make-filter :type :tool :name \"cache\"
    :around (lambda (req chain)
              (or (cache-lookup req)
                  (cache-put req (funcall chain req)))))"
  (make-instance 'filter
                 :type (or type :tool)
                 :name (or name "unnamed")
                 :fn fn
                 :around around
                 :before before
                 :after after
                 :priority priority))

;;; ============================================================
;;; Filter 谓词
;;; ============================================================

(defun filter-p (obj)
  "检查是否为 Filter 实例"
  (typep obj 'filter))

;;; ============================================================
;;; Filter 结果（CLOS）
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
    :documentation "修改后的请求（:continue 时替换下游入参）")
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
  (:documentation "Filter 执行结果（控制流指令）"))

(defun filter-result-p (obj)
  "检查是否为 filter-result 实例"
  (typep obj 'filter-result))

(defun make-filter-result (action &key context result message)
  "创建 Filter 结果

参数：
  ACTION  - :continue, :skip, 或 :error
  CONTEXT - 修改后的请求（可选）
  RESULT  - :skip 动作的结果值
  MESSAGE - :error 动作的错误消息

返回：
  filter-result 实例"
  (make-instance 'filter-result
                 :action action
                 :context context
                 :result result
                 :message message))

(defun normalize-filter (filter)
  "规范化过滤器为 Filter 实例或 plist

参数：
  FILTER - Filter 实例、裸函数或 plist

返回：
  规范化的过滤器"
  (cond
    ((filter-p filter) filter)
    ((functionp filter)                              ; 裸函数 (request next-fn)
     (list :fn filter :type :pre-invocation))
    ((and (listp filter) (getf filter :fn)) filter)  ; 已经是 plist
    (t (error "Invalid filter: ~A. Use make-filter to create filters." filter))))

;;; ============================================================
;;; around 解析（核心：把任意形态的 filter 折算成 around 函数）
;;; ============================================================

(defgeneric filter-around (filter)
  (:documentation "把 filter 解析为 around 函数 (request chain) -> response。

解析顺序：around-fn > before/after 组合 > 旧式 fn > filter-apply 回退。
子类可特化本方法实现完全自定义的 around 逻辑（如 memory-filter）。"))

(defmethod filter-around ((filter filter))
  (cond
    ;; 1. 完整 around
    ((filter-around-fn filter)
     (filter-around-fn filter))
    ;; 2. before/after 语法糖
    ((or (filter-before-fn filter) (filter-after-fn filter))
     (let ((before (or (filter-before-fn filter) #'identity))
           (after (or (filter-after-fn filter) #'identity)))
       (lambda (request chain)
         (funcall after (funcall chain (funcall before request))))))
    ;; 3. 旧式 fn —— 同形（request next-fn），控制流结果由执行器解释
    ((filter-fn filter)
     (filter-fn filter))
    ;; 4. 类式 filter：回退到 filter-apply
    (t
     (lambda (request chain)
       (interpret-filter-result (filter-apply filter request)
                                request chain)))))

(defmethod filter-around ((filter list))
  "plist filter：取 :around 或 :fn"
  (or (getf filter :around) (getf filter :fn)))

(defmethod filter-around ((filter function))
  "裸函数即 around"
  filter)

(defun interpret-filter-result (result request chain)
  "解释 filter 的控制流结果：
  - filter-result / :action plist：按 :continue/:skip/:error 处理
  - 其他值：视为 :continue（继续下游，请求不变）"
  (cond
    ;; CLOS filter-result
    ((filter-result-p result)
     (ecase (filter-result-action result)
       (:continue (funcall chain (or (filter-result-context result) request)))
       (:skip (filter-result-value result))
       (:error (error (or (filter-result-message result) "Filter error")))))
    ;; 旧 plist 格式
    ((and (listp result) (getf result :action))
     (case (getf result :action)
       (:continue (funcall chain (or (getf result :context) request)))
       (:skip (getf result :result))
       (:error (error (or (getf result :message) "Filter error")))))
    ;; 任意其他返回值 → 继续
    (t (funcall chain request))))

;;; ============================================================
;;; 洋葱链构建（执行器，形状无关：chat / tool 共用）
;;; ============================================================

(defun build-filter-chain (filters terminal)
  "把 filters 折成洋葱，最内层 terminal 真正干活。

参数：
  FILTERS  - 过滤器列表（从外到内，已排序）
  TERMINAL - 最内层执行函数 (request) -> response

返回：
  组合函数 (request) -> response

说明：
  如果 FILTERS 是 '(f1 f2 f3)，调用顺序是：
  f1 -> f2 -> f3 -> terminal -> f3 -> f2 -> f1
  （before 正序、after 逆序；f1 的 before 最先、after 最后）"
  (if (null filters)
      terminal
      (let ((chain terminal))
        (dolist (filter (reverse filters))
          (let ((advise (filter-around (normalize-filter filter)))
                (next chain))
            (setf chain
                  (lambda (request)
                    (let ((result (funcall advise request next)))
                      ;; 旧式 fn 可能返回控制流结果；around 直接返回响应
                      (if (or (filter-result-p result)
                              (and (listp result) (getf result :action)))
                          (interpret-filter-result result request next)
                          result))))))
        chain)))

(defun build-phase-chain (filters phase terminal)
  "为指定 phase 构建洋葱链。

参数：
  FILTERS  - 全部过滤器（混合 phase）
  PHASE    - :chat 或 :tool
  TERMINAL - 最内层执行函数 (request) -> response

返回：
  组合函数 (request) -> response

说明：
  按 (priority, 旧类型组位) 稳定排序——同优先级下旧 pre 类型在外、
  新式居中、旧 post 类型在内，保持升级前的嵌套几何。"
  (let ((phase-filters
          (remove-if-not (lambda (f)
                           (eq (filter-phase (normalize-filter f)) phase))
                         filters)))
    (build-filter-chain (sort-filters-for-phase phase-filters) terminal)))

(defun sort-filters-for-phase (filters)
  "按 (priority, effective-rank) 稳定排序"
  (stable-sort (copy-list filters)
               (lambda (a b)
                 (let ((pa (filter-sort-priority a))
                       (pb (filter-sort-priority b)))
                   (if (= pa pb)
                       (< (effective-rank a) (effective-rank b))
                       (< pa pb))))))

(defun filter-sort-priority (filter)
  "取 filter 的优先级（plist/实例/函数）"
  (let ((normalized (normalize-filter filter)))
    (if (filter-p normalized)
        (filter-priority normalized)
        (getf normalized :priority 100))))

(defun build-typed-filter-chain (filters type terminal)
  "为特定（旧）类型构建过滤器链（向后兼容入口）

参数：
  FILTERS  - 所有过滤器列表
  TYPE     - 要选择的过滤器类型
  TERMINAL - 内层函数

返回：
  该类型的过滤器链"
  (let ((typed-filters (filter-by-type filters type)))
    (setf typed-filters (sort-filters-by-priority typed-filters))
    (build-filter-chain typed-filters terminal)))

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
  "按（旧）类型精确筛选过滤器

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

(defun filter-by-phase (filters phase)
  "按 phase 筛选过滤器（含旧类型映射）

参数：
  FILTERS - 过滤器列表
  PHASE   - :chat 或 :tool

返回：
  属于该链的过滤器列表"
  (remove-if-not (lambda (f)
                   (eq (filter-phase (normalize-filter f)) phase))
                 filters))

(defun sort-filters-by-priority (filters)
  "按优先级排序过滤器（越小越先）

参数：
  FILTERS - 过滤器列表

返回：
  排序后的过滤器列表"
  (stable-sort (copy-list filters) #'<
               :key #'filter-sort-priority))

;;; ============================================================
;;; 内置过滤器工厂
;;; ============================================================
;;; 内置 filter 通过 req-get 读取请求字段，
;;; 同时兼容 CLOS 请求对象与旧 plist 请求。

(defun make-logging-filter (&key (stream *standard-output*) (type :tool))
  "创建工具日志过滤器（around：调用前后各记一笔）

参数：
  STREAM - 输出流（默认 *standard-output*）
  TYPE   - 过滤器类型（默认 :tool）

返回：
  Filter 实例"
  (make-filter
   :type type
   :name "logging"
   :around (lambda (request chain)
             (let ((tool-name (req-get request :tool-name))
                   (tool-args (req-get request :tool-args)))
               (format stream "[Filter] Calling tool: ~A with args: ~S~%"
                       tool-name tool-args)
               (let ((result (funcall chain request)))
                 (format stream "[Filter] Tool ~A returned: ~S~%"
                         tool-name result)
                 result)))))

(defun make-error-handling-filter (&key (type :tool))
  "创建错误处理过滤器：下游异常转为错误结果（不抛出）

参数：
  TYPE - 过滤器类型（默认 :tool）

返回：
  Filter 实例"
  (make-filter
   :type type
   :name "error-handling"
   :around (lambda (request chain)
             (handler-case
                 (funcall chain request)
               (error (condition)
                 (list :error t
                       :message (format nil "~A" condition)
                       :tool-name (req-get request :tool-name)))))))

(defun make-timeout-filter (seconds &key (type :tool))
  "创建超时过滤器（事后检测：执行超时返回错误结果）

参数：
  SECONDS - 超时秒数
  TYPE    - 过滤器类型（默认 :tool）

返回：
  Filter 实例"
  (make-filter
   :type type
   :name "timeout"
   :around (lambda (request chain)
             (let ((start-time (get-internal-real-time)))
               (let ((result (funcall chain request)))
                 (let ((elapsed (/ (- (get-internal-real-time) start-time)
                                   internal-time-units-per-second)))
                   (if (> elapsed seconds)
                       (list :error t
                             :message (format nil "Tool ~A timed out after ~A seconds"
                                              (req-get request :tool-name) elapsed)
                             :tool-name (req-get request :tool-name))
                       result)))))))

(defun make-approval-filter (&key sensitive-only approver-fn (type :tool))
  "创建审批过滤器：拒绝时短路（不调下游）

参数：
  SENSITIVE-ONLY - 仅检查带 :sensitive 标签的工具
  APPROVER-FN    - 审批函数 (request) -> boolean
  TYPE           - 过滤器类型（默认 :tool）

返回：
  Filter 实例"
  (make-filter
   :type type
   :name "approval"
   :around (lambda (request chain)
             (let* ((kernel (req-get request :kernel))
                    (tool-name (req-get request :tool-name))
                    (tool (when kernel
                            (kernel-find-tool kernel tool-name)))
                    (needs-approval (if sensitive-only
                                        (and tool
                                             (member :sensitive
                                                     (%tools-tool-tags tool)))
                                        t)))
               (if (and needs-approval approver-fn)
                   (if (funcall approver-fn request)
                       (funcall chain request)
                       ;; 拒绝 → 短路，直接返回错误结果
                       (list :error t
                             :message (format nil "Tool ~A was denied" tool-name)
                             :denied t
                             :tool-name tool-name))
                   (funcall chain request))))))

(defun make-retry-filter (&key (max-retries 3) (backoff-base 2) (type :tool))
  "创建重试过滤器（around：闭包持有重试计数，指数退避）

参数：
  MAX-RETRIES  - 最大重试次数
  BACKOFF-BASE - 指数退避基数
  TYPE         - 过滤器类型

返回：
  Filter 实例"
  (make-filter
   :type type
   :name "retry"
   :around (lambda (request chain)
             (let ((retries 0))
               (loop
                 (handler-case
                     (return (funcall chain request))
                   (error (e)
                     (if (< retries max-retries)
                         (progn
                           (incf retries)
                           (sleep (* (expt backoff-base retries) 0.1)))
                         (error e)))))))))

(defun make-tracing-filter (&key (type :tool))
  "创建追踪过滤器（记录到 context 对象的 trace）

参数：
  TYPE - 过滤器类型

返回：
  Filter 实例"
  (make-filter
   :type type
   :name "tracing"
   :around (lambda (request chain)
             (let* ((start-time (get-internal-real-time))
                    (req-context (req-get request :context))
                    (context-obj (when (listp req-context)
                                   (getf req-context :context-object))))
               (when (and context-obj (typep context-obj 'context))
                 (context-trace-add context-obj :tool-call
                                    :data (list :tool-name (req-get request :tool-name)
                                                :tool-args (req-get request :tool-args))))
               (let ((result (funcall chain request)))
                 (when (and context-obj (typep context-obj 'context))
                   (context-trace-add context-obj :tool-result
                                      :data (list :tool-name (req-get request :tool-name)
                                                  :result result
                                                  :duration-ms
                                                  (* 1000 (/ (- (get-internal-real-time) start-time)
                                                             internal-time-units-per-second)))))
                 result)))))

;;; ============================================================
;;; Chat 链内置过滤器
;;; ============================================================

(defun make-pre-chat-logging-filter (&key (stream *standard-output*))
  "创建 chat 请求日志过滤器（before 段）

参数：
  STREAM - 输出流

返回：
  Filter 实例"
  (make-filter
   :type :chat
   :name "pre-chat-logging"
   :before (lambda (request)
             (format stream "[Pre-Chat] Messages: ~A, Tools: ~A~%"
                     (length (req-get request :messages))
                     (length (req-get request :tools)))
             request)))

(defun make-post-chat-logging-filter (&key (stream *standard-output*))
  "创建 chat 响应日志过滤器（after 段）

参数：
  STREAM - 输出流

返回：
  Filter 实例"
  (make-filter
   :type :chat
   :name "post-chat-logging"
   :after (lambda (response)
            (format stream "[Post-Chat] Response: ~A tool-calls~%"
                    (length (cl-agent.core:llm-response-tool-calls response)))
            response)))

(defun make-message-transform-filter (transform-fn &key (type :chat))
  "创建消息转换过滤器（before 段改写 messages）

参数：
  TRANSFORM-FN - 转换函数 (messages) -> messages
  TYPE         - 过滤器类型（默认 :chat）

返回：
  Filter 实例"
  (make-filter
   :type type
   :name "message-transform"
   :before (lambda (request)
             (let ((new-messages (funcall transform-fn (req-get request :messages))))
               (typecase request
                 (chat-request
                  (setf (chat-request-messages request) new-messages)
                  request)
                 (list
                  (list* :messages new-messages request))
                 (t request))))))

;;; ============================================================
;;; 打印方法
;;; ============================================================

(defmethod print-object ((filter filter) stream)
  "打印 Filter 对象"
  (print-unreadable-object (filter stream :type t)
    (format stream "~A ~A priority=~A"
            (filter-name filter)
            (filter-type filter)
            (filter-priority filter))))

(defmethod print-object ((request chat-request) stream)
  (print-unreadable-object (request stream :type t)
    (format stream "~A msgs, ~A tools, tool-choice=~A"
            (length (chat-request-messages request))
            (length (chat-request-tools request))
            (chat-request-tool-choice request))))

(defmethod print-object ((request tool-request) stream)
  (print-unreadable-object (request stream :type t)
    (format stream "~A" (tool-request-name request))))
