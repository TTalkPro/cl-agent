;;;; tool.lisp
;;;; CL-Agent Chat - 工具调用体系
;;;;
;;;; 概述（对标 Spring AI Tool Calling API）：
;;;;
;;;;   tool-definition      工具元数据（名称/描述/参数规格）
;;;;                        —— 对标 ToolDefinition
;;;;   tool-callback        可执行工具（definition + 函数）
;;;;                        —— 对标 ToolCallback / FunctionToolCallback
;;;;   deftool 宏           声明式定义工具并注册
;;;;                        —— 对标 @Tool / @ToolParam 注解
;;;;   tool-calling-manager 解析响应中的 tool-calls 并执行
;;;;                        —— 对标 ToolCallingManager
;;;;
;;;; deftool 示例：
;;;;   (deftool get-weather (&key city (unit "celsius"))
;;;;     "获取指定城市的当前天气"
;;;;     (:param city :string "城市名称" :required t)
;;;;     (:param unit :string "温度单位")
;;;;     (format nil "~A 的天气：22°C（~A），晴" city unit))
;;;;
;;;;   展开后：
;;;;   - (defun get-weather (&key city (unit "celsius")) ...) 普通函数照常可调
;;;;   - 生成 tool-callback（JSON Schema 自动派生）并注册到全局注册表
;;;;   - (get 'get-weather 'tool-callback) 可取回 callback
;;;;
;;;; 参数约定：
;;;;   LLM 的工具参数是命名参数（JSON object），因此 deftool 的
;;;;   lambda-list 必须为空或全为 &key 参数。

(in-package #:cl-agent.chat)

;;; ============================================================
;;; 条件
;;; ============================================================

(define-condition tool-execution-error (error)
  ((tool-name :initarg :tool-name :reader tool-execution-error-tool-name)
   (cause :initarg :cause :initform nil :reader tool-execution-error-cause))
  (:report (lambda (condition stream)
             (format stream "工具 ~A 执行失败~@[：~A~]"
                     (tool-execution-error-tool-name condition)
                     (tool-execution-error-cause condition)))))

(define-condition tool-not-found-error (error)
  ((tool-name :initarg :tool-name :reader tool-not-found-error-tool-name))
  (:report (lambda (condition stream)
             (format stream "找不到工具：~A"
                     (tool-not-found-error-tool-name condition)))))

;;; ============================================================
;;; ToolDefinition
;;; ============================================================

(defclass tool-definition ()
  ((name
    :initarg :name
    :reader tool-definition-name
    :documentation "工具名称（小写字符串，下划线风格）")
   (description
    :initarg :description
    :initform ""
    :reader tool-definition-description
    :documentation "工具用途描述（给模型看）")
   (parameters
    :initarg :parameters
    :initform nil
    :reader tool-definition-parameters
    :documentation "参数规格列表：((name type description
&key required-p default) ...)"))
  (:documentation "工具元数据（对标 ToolDefinition）"))

(defun normalize-tool-name (name)
  "统一工具名：小写字符串，- 转 _（匹配主流 provider 命名要求）"
  (substitute #\_ #\-
              (etypecase name
                (string (string-downcase name))
                (symbol (string-downcase (symbol-name name))))))

(defun make-tool-definition (&key name (description "") parameters)
  "创建 tool-definition"
  (make-instance 'tool-definition
                 :name (normalize-tool-name name)
                 :description description
                 :parameters parameters))

(defmethod print-object ((def tool-definition) stream)
  (print-unreadable-object (def stream :type t)
    (format stream "~A" (tool-definition-name def))))

;;; ============================================================
;;; ToolCallback
;;; ============================================================

(defclass tool-callback ()
  ((definition
    :initarg :definition
    :reader tool-callback-definition
    :documentation "tool-definition 实例")
   (function
    :initarg :function
    :reader tool-callback-function
    :documentation "执行函数，接收关键字 plist 参数")
   (return-direct
    :initarg :return-direct
    :initform nil
    :reader tool-callback-return-direct-p
    :documentation "为 T 时工具结果直接返回调用方，不再回传模型"))
  (:documentation "可执行工具（对标 ToolCallback / FunctionToolCallback）"))

(defun make-tool-callback (function &key name (description "") parameters return-direct)
  "从函数创建 tool-callback（对标 FunctionToolCallback.builder）。

参数：
  FUNCTION      - 执行函数（&key 风格）
  NAME          - 工具名（必填）
  DESCRIPTION   - 描述
  PARAMETERS    - 参数规格 ((name type description &key required-p default) ...)
  RETURN-DIRECT - 结果是否直接返回（不回传模型）

示例：
  (make-tool-callback
    (lambda (&key city) (format nil \"~A：晴\" city))
    :name \"get_weather\"
    :description \"查询天气\"
    :parameters '((city :string \"城市名称\" :required-p t)))"
  (unless name
    (error "tool-callback 需要 :name"))
  (make-instance 'tool-callback
                 :definition (make-tool-definition :name name
                                                   :description description
                                                   :parameters parameters)
                 :function function
                 :return-direct return-direct))

(defun tool-callback-name (callback)
  "工具名称字符串"
  (tool-definition-name (tool-callback-definition callback)))

(defgeneric tool-callback-call (callback arguments &optional tool-context)
  (:documentation "执行工具。

参数：
  CALLBACK     - tool-callback 实例
  ARGUMENTS    - 关键字 plist 参数
  TOOL-CONTEXT - 透传上下文 plist（工具声明 &key tool-context 时注入；
                 对标 Spring AI ToolContext）

返回：
  结果字符串（非字符串结果自动 format）"))

(defun tool-accepts-context-p (callback)
  "工具的参数规格中是否声明了 tool-context（声明才注入）"
  (member "TOOL-CONTEXT"
          (tool-definition-parameters (tool-callback-definition callback))
          :key (lambda (spec) (string (first spec)))
          :test #'string-equal))

(defmethod tool-callback-call ((callback tool-callback) arguments &optional tool-context)
  (let* ((args (if (and tool-context (tool-accepts-context-p callback))
                   (append arguments (list :tool-context tool-context))
                   arguments))
         (result (handler-case (apply (tool-callback-function callback) args)
                   (error (e)
                     (error 'tool-execution-error
                            :tool-name (tool-callback-name callback)
                            :cause e)))))
    (if (stringp result)
        result
        (format nil "~A" result))))

(defmethod print-object ((callback tool-callback) stream)
  (print-unreadable-object (callback stream :type t)
    (format stream "~A~@[ return-direct~]"
            (tool-callback-name callback)
            (tool-callback-return-direct-p callback))))

;;; ============================================================
;;; Provider Schema（发送给 LLM 的工具描述）
;;; ============================================================

(defun tool-callback->schema (callback)
  "把 tool-callback 转换为 provider 工具 schema plist。

格式与 provider 序列化层（llm/schema/*）的约定一致：
  (:type \"object\" :name ... :description ... :parameters <json-schema>)"
  (let ((def (tool-callback-definition callback)))
    (list :type "object"
          :name (tool-definition-name def)
          :description (tool-definition-description def)
          :parameters (params->json-schema
                       ;; tool-context 是宿主注入参数，不暴露给模型
                       (remove :tool-context (tool-definition-parameters def)
                               :key (lambda (spec)
                                      (intern (string-upcase (string (first spec)))
                                              :keyword)))))))

;;; ============================================================
;;; 全局工具注册表（deftool 注册目标）
;;; ============================================================

(defvar *tool-registry* (make-hash-table :test #'equal)
  "全局工具注册表：名称字符串 → tool-callback")

(defvar *tool-registry-lock* (bt:make-lock "chat-tool-registry")
  "注册表锁")

(defun register-tool-callback (callback)
  "注册工具到全局注册表（同名覆盖）。返回 callback。"
  (bt:with-lock-held (*tool-registry-lock*)
    (setf (gethash (tool-callback-name callback) *tool-registry*) callback))
  callback)

(defun unregister-tool-callback (name)
  "从全局注册表移除工具。返回 T 表示有移除。"
  (bt:with-lock-held (*tool-registry-lock*)
    (remhash (normalize-tool-name name) *tool-registry*)))

(defun find-tool-callback (name)
  "按名查找全局注册的工具（接受字符串/符号，未找到返回 NIL）"
  (bt:with-lock-held (*tool-registry-lock*)
    (gethash (normalize-tool-name name) *tool-registry*)))

(defun list-tool-callbacks ()
  "列出全局注册表中的所有工具"
  (bt:with-lock-held (*tool-registry-lock*)
    (loop for cb being the hash-values of *tool-registry*
          collect cb)))

(defun resolve-tool-callbacks (specs)
  "把工具引用列表解析为 tool-callback 列表。

每个引用可以是：
  - tool-callback 实例   → 原样
  - 符号                → 先取 (get sym 'tool-callback)，再按名查注册表
  - 字符串              → 按名查全局注册表

找不到时发出 tool-not-found-error。"
  (mapcar (lambda (spec)
            (etypecase spec
              (tool-callback spec)
              (symbol (or (get spec 'tool-callback)
                          (find-tool-callback spec)
                          (error 'tool-not-found-error :tool-name spec)))
              (string (or (find-tool-callback spec)
                          (error 'tool-not-found-error :tool-name spec)))))
          specs))

;;; ============================================================
;;; deftool 宏（对标 @Tool / @ToolParam）
;;; ============================================================

(defun parse-deftool-body (name lambda-list body)
  "解析 deftool body：docstring + (:param ...) / (:return-direct ...) 子句 + 函数体。

返回：
  (values description param-specs return-direct real-body)"
  (let ((description nil)
        (param-specs nil)
        (return-direct nil)
        (rest body))
    ;; docstring
    (when (and (stringp (first rest)) (cdr rest))
      (setf description (pop rest)))
    ;; 选项子句
    (loop while (and (consp (first rest))
                     (member (first (first rest)) '(:param :return-direct)))
          do (let ((clause (pop rest)))
               (ecase (first clause)
                 (:param
                  (destructuring-bind (param-name type desc &key required default)
                      (rest clause)
                    (push (list param-name type desc
                                :required-p required
                                :default default)
                          param-specs)))
                 (:return-direct
                  (setf return-direct (second clause))))))
    ;; lambda-list 校验：必须为空或 &key 风格（JSON 参数是命名参数）
    (when (and lambda-list (not (eq (first lambda-list) '&key)))
      (error "deftool ~A：lambda-list 必须为空或以 &key 开头（工具参数是命名参数），~
              收到 ~S" name lambda-list))
    (values (or description "") (nreverse param-specs) return-direct rest)))

(defmacro deftool (name lambda-list &body body)
  "定义一个工具函数并注册为 tool-callback（对标 Spring AI @Tool）。

语法：
  (deftool 名称 (&key 参数...)
    \"工具描述（docstring，给模型看）\"
    (:param 参数名 类型 \"参数描述\" [:required t] [:default 值])*
    [(:return-direct t)]
    函数体...)

效果：
  1. (defun 名称 (&key ...) ...) —— 普通函数照常可调
  2. 自动派生 JSON Schema，创建 tool-callback 并注册到全局注册表
  3. callback 挂到符号属性：(get '名称 'tool-callback)

工具名自动转换为小写下划线风格（get-weather → \"get_weather\"）。

示例：
  (deftool get-weather (&key city (unit \"celsius\"))
    \"获取指定城市的当前天气\"
    (:param city :string \"城市名称\" :required t)
    (:param unit :string \"温度单位\")
    (format nil \"~A 的天气：22°C（~A），晴\" city unit))"
  (multiple-value-bind (description param-specs return-direct real-body)
      (parse-deftool-body name lambda-list body)
    `(progn
       (defun ,name ,lambda-list
         ,description
         ,@real-body)
       (let ((callback (make-tool-callback
                        (lambda (&rest args) (apply #',name args))
                        :name ',name
                        :description ,description
                        :parameters ',param-specs
                        :return-direct ,return-direct)))
         (setf (get ',name 'tool-callback) callback)
         (register-tool-callback callback))
       ',name)))

;;; ============================================================
;;; 参数归一化
;;; ============================================================

(defun arguments->plist (raw)
  "把 LLM 返回的工具参数归一化为关键字 plist。

接受：hash-table（JSON 解析结果）/ JSON 字符串 / plist / NIL"
  (labels ((hash->plist (ht)
             (loop for k being the hash-keys of ht using (hash-value v)
                   collect (intern (string-upcase
                                    (substitute #\- #\_ (string k)))
                                   :keyword)
                   collect v)))
    (cond
      ((null raw) nil)
      ((hash-table-p raw) (hash->plist raw))
      ((stringp raw)
       (handler-case
           (let ((parsed (json-parse raw)))
             (if (hash-table-p parsed) (hash->plist parsed) nil))
         (error () nil)))
      ((and (listp raw) (keywordp (first raw))) raw)
      (t nil))))

;;; ============================================================
;;; ToolExecutionResult
;;; ============================================================

(defclass tool-execution-result ()
  ((conversation-history
    :initarg :conversation-history
    :initform nil
    :reader tool-execution-conversation-history
    :documentation "执行工具后的完整会话消息列表：
原 prompt 消息 + assistant(tool-calls) 消息 + tool-response 消息")
   (return-direct
    :initarg :return-direct
    :initform nil
    :reader tool-execution-return-direct-p
    :documentation "任一工具声明 :return-direct 时为 T"))
  (:documentation "一轮工具执行的结果（对标 Spring AI ToolExecutionResult）"))

(defun tool-execution-last-message (result)
  "取会话历史末尾的 tool-response-message（本轮工具结果）"
  (car (last (tool-execution-conversation-history result))))

;;; ============================================================
;;; ToolCallingManager
;;; ============================================================

(defclass tool-calling-manager ()
  ()
  (:documentation "工具调用执行器协议基类（对标 ToolCallingManager）"))

(defclass default-tool-calling-manager (tool-calling-manager)
  ()
  (:documentation "默认实现：按名解析 callback，执行并收集结果；
工具异常经 process-tool-execution-error 处理（默认转错误文本回传模型）。"))

(defun make-default-tool-calling-manager ()
  (make-instance 'default-tool-calling-manager))

(defgeneric process-tool-execution-error (manager condition tool-call)
  (:documentation "处理工具执行期的条件（对标 ToolExecutionExceptionProcessor）。

参数：
  MANAGER   - tool-calling-manager 实例
  CONDITION - tool-execution-error / tool-not-found-error 条件
  TOOL-CALL - 引发错误的 tool-call

返回：
  错误结果文本（回传模型，模型可自纠错）；
  也可选择直接重新 signal，让错误冒泡给调用方。"))

(defmethod process-tool-execution-error ((manager tool-calling-manager) condition tool-call)
  "默认：错误文本作为工具结果回传模型（Spring AI 默认语义）"
  (declare (ignore tool-call))
  (format nil "错误：~A" condition))

(defgeneric execute-tool-calls (manager prompt response)
  (:documentation "执行 RESPONSE 中的全部工具调用。

参数：
  MANAGER  - tool-calling-manager 实例
  PROMPT   - 本轮 prompt（从其 options 解析可用工具与 tool-context；
             其消息列表作为会话历史前缀）
  RESPONSE - 携带 tool-calls 的 chat-response

返回：
  tool-execution-result（conversation-history + return-direct-p）"))

(defun find-callback-for-call (options tool-call)
  "为一次 tool-call 定位 callback：先查 options 中的运行时工具，
再回退全局注册表。"
  (let ((name (normalize-tool-name (tool-call-name tool-call))))
    (or (find name (append (chat-options-tool-callbacks options)
                           (ignore-errors
                            (resolve-tool-callbacks
                             (chat-options-tool-names options))))
              :key #'tool-callback-name
              :test #'string=)
        (find-tool-callback name)
        (error 'tool-not-found-error :tool-name name))))

(defun execute-one-tool-call (manager options tool-context tool-call)
  "执行单个 tool-call，返回 (values tool-response return-direct-p)。

错误经 process-tool-execution-error 处理（默认转文本回传模型）。
不依赖任何动态绑定的特殊变量（tool-context 显式传入），
因而可安全用于并行 manager 的 worker 线程。"
  (multiple-value-bind (text direct-p)
      (handler-case
          (let ((callback (find-callback-for-call options tool-call)))
            (values (tool-callback-call callback
                                        (arguments->plist
                                         (tool-call-arguments tool-call))
                                        tool-context)
                    (tool-callback-return-direct-p callback)))
        (tool-not-found-error (e)
          (values (process-tool-execution-error manager e tool-call) nil))
        (tool-execution-error (e)
          (values (process-tool-execution-error manager e tool-call) nil)))
    (values (make-tool-response :id (tool-call-id tool-call)
                                :name (tool-call-name tool-call)
                                :text text)
            direct-p)))

(defun build-tool-execution-result (prompt response responses return-direct)
  "由工具结果列表组装 tool-execution-result（会话历史 = 原消息 +
assistant(tool-calls) + tool-response 消息）"
  (make-instance 'tool-execution-result
                 :conversation-history (append (prompt-messages prompt)
                                               (list (chat-response-message response)
                                                     (tool-response-message responses)))
                 :return-direct return-direct))

(defmethod execute-tool-calls ((manager default-tool-calling-manager) prompt response)
  "顺序执行全部工具调用（默认实现）"
  (let* ((options (prompt-options prompt))
         (tool-context (chat-options-tool-context options))
         (return-direct nil)
         (responses
           (mapcar
            (lambda (tc)
              (multiple-value-bind (resp direct-p)
                  (execute-one-tool-call manager options tool-context tc)
                (when direct-p (setf return-direct t))
                resp))
            (chat-response-tool-calls response))))
    (build-tool-execution-result prompt response responses return-direct)))

;;; ============================================================
;;; ConcurrentToolCallingManager（并行工具执行）
;;; ============================================================
;;; 对标 Spring AI 2.0 DefaultToolCallingManager 的并行执行模式
;;; （issue #5195）：多个工具调用在线程池上并发执行，适合工具体
;;; 以 I/O 为主（HTTP / DB / 外部服务）的场景。
;;;
;;; 语义与顺序执行完全一致（结果按 tool-call 原序、return-direct
;;; 取并集、错误经 process-tool-execution-error 隔离），只是并发。
;;;
;;; 注意：worker 线程不继承提交线程的动态绑定。工具若依赖调用方
;;; 用 let 绑定的特殊变量，并行下不可见；请改用 tool-context
;;; 显式传参（与 Spring 的 ToolContext 同语义）。

(defclass concurrent-tool-calling-manager (default-tool-calling-manager)
  ((kernel
    :initform nil
    :accessor manager-kernel
    :documentation "lparallel 内核（懒创建，实例私有）")
   (kernel-lock
    :initform (bt:make-lock "tool-manager-kernel")
    :reader manager-kernel-lock)
   (pool-size
    :initarg :pool-size
    :initform 4
    :reader manager-pool-size
    :documentation "线程池大小")
   (timeout
    :initarg :timeout
    :initform nil
    :reader manager-timeout
    :documentation "单工具执行超时（秒，NIL 不限；超时结果转错误文本）"))
  (:documentation "并行工具执行 manager（对标 Spring AI 并行 DefaultToolCallingManager）"))

(defun make-concurrent-tool-calling-manager (&key (pool-size 4) timeout)
  "创建并行工具执行 manager。

参数：
  POOL-SIZE - 线程池大小（默认 4）
  TIMEOUT   - 单工具超时秒数（默认 NIL 不限）

线程池在首次执行时懒创建；用完后调用
shutdown-tool-calling-manager 释放。"
  (make-instance 'concurrent-tool-calling-manager
                 :pool-size pool-size
                 :timeout timeout))

(defun ensure-manager-kernel (manager)
  "取（或懒创建）manager 的 lparallel 内核（双检锁）"
  (or (manager-kernel manager)
      (bt:with-lock-held ((manager-kernel-lock manager))
        (or (manager-kernel manager)
            (setf (manager-kernel manager)
                  (lparallel:make-kernel (manager-pool-size manager)
                                         :name "tool-exec-pool"))))))

(defun shutdown-tool-calling-manager (manager)
  "关闭并行 manager 的线程池（幂等）。返回 T 表示有释放。"
  (bt:with-lock-held ((manager-kernel-lock manager))
    (when (manager-kernel manager)
      (let ((lparallel:*kernel* (manager-kernel manager)))
        (lparallel:end-kernel :wait t))
      (setf (manager-kernel manager) nil)
      t)))

(defmacro with-concurrent-tool-calling-manager ((var &rest options) &body body)
  "词法作用域内绑定 VAR 为并行 manager，退出时（含非局部退出）
自动关闭线程池——避免用全局变量持有线程池。

OPTIONS 透传 make-concurrent-tool-calling-manager（:pool-size / :timeout）。

示例：
  (with-concurrent-tool-calling-manager (mgr :pool-size 8)
    (let ((client (make-chat-client model
                    :advisors (list (make-tool-calling-advisor :manager mgr)))))
      (chat client ...)))"
  `(let ((,var (make-concurrent-tool-calling-manager ,@options)))
     (unwind-protect (progn ,@body)
       (shutdown-tool-calling-manager ,var))))

(defun %force-tool-future (future tool-call timeout)
  "取 FUTURE 的值（cons: tool-response . direct-p）。
TIMEOUT 非空且超时时返回超时错误结果（worker 仍在后台跑完，
无法安全中断，故为 best-effort）。"
  (if (null timeout)
      (lparallel:force future)
      (let ((deadline (+ (get-internal-real-time)
                         (round (* timeout internal-time-units-per-second)))))
        (loop
          (when (lparallel:fulfilledp future)
            (return (lparallel:force future)))
          (when (>= (get-internal-real-time) deadline)
            (return (cons (make-tool-response
                           :id (tool-call-id tool-call)
                           :name (tool-call-name tool-call)
                           :text (format nil "错误：工具执行超时（~As）" timeout))
                          nil)))
          (sleep 0.005)))))

(defmethod execute-tool-calls ((manager concurrent-tool-calling-manager) prompt response)
  "并行执行全部工具调用。0/1 个工具时退化为顺序执行（无并发收益）。"
  (let ((tool-calls (chat-response-tool-calls response)))
    (if (<= (length tool-calls) 1)
        (call-next-method)                    ; 复用顺序实现
        (let* ((options (prompt-options prompt))
               (tool-context (chat-options-tool-context options))
               (timeout (manager-timeout manager))
               (lparallel:*kernel* (ensure-manager-kernel manager))
               ;; 每个工具提交为 future，worker 返回 (response . direct-p)
               (futures (mapcar
                         (lambda (tc)
                           (lparallel:future
                             (multiple-value-bind (resp direct-p)
                                 (execute-one-tool-call manager options tool-context tc)
                               (cons resp direct-p))))
                         tool-calls))
               ;; 按原序收集结果
               (pairs (mapcar (lambda (f tc) (%force-tool-future f tc timeout))
                              futures tool-calls)))
          (build-tool-execution-result
           prompt response
           (mapcar #'car pairs)
           (some #'cdr pairs))))))
