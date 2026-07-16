;;;; tool.lisp
;;;; CL-Agent Chat - 工具调用体系
;;;;
;;;; 概述（对标 Spring AI Tool Calling API）：
;;;;
;;;;   tool-definition      工具元数据（名称/描述/参数规格）
;;;;                        —— 对标 ToolDefinition
;;;;   tool-callback        可执行工具（definition + 函数）
;;;;                        —— 对标 ToolCallback / FunctionToolCallback
;;;;   deftool 宏           声明式定义工具
;;;;                        —— 对标 @Tool / @ToolParam 注解
;;;;   find-callback-for-call 按名在本次请求暴露的工具里定位 callback
;;;;
;;;; 工具的**执行**不在本层：解析响应中的 tool-calls 并执行是
;;;; cl-agent.kernel 的事（run-tool-loop / invoke-tool-batch /
;;;; sequential|virtual-thread|thread-pool 三个 ToolCallingManager）。
;;;; 本层只负责「工具是什么」——定义、注册、schema、按名解析。
;;;;
;;;; 工具的身份是**符号**：
;;;;   deftool 生成一个普通函数，并把 tool-callback 挂在符号属性上，
;;;;   不写任何全局状态。用符号把工具放进请求：
;;;;
;;;;     (chat client (:user "...") (:tools 'get-weather))
;;;;
;;;;   这与 clj-agent 一致——那边 deftool 生成 defn、schema 挂 var 元数据，
;;;;   再用 (build-kernel {:tools [#'get-weather]}) 显式传入。Clojure 的 var
;;;;   带元数据，CL 里对应的载体是符号的属性列表；#'get-weather 是裸函数
;;;;   对象，取不到 schema，因此不能用作工具引用。
;;;;
;;;;   工具执行只认本次请求实际暴露的工具（见 find-callback-for-call）。
;;;;   按字符串名解析是 opt-in 的（见 register-tool-callback）。
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
;;;;   - 生成 tool-callback（JSON Schema 自动派生）挂到符号属性
;;;;   - (get 'get-weather 'tool-callback) 可取回 callback
;;;;
;;;; 参数约定：
;;;;   LLM 的工具参数是命名参数（JSON object），因此 deftool 的
;;;;   lambda-list 必须为空或全为 &key 参数。

(in-package #:cl-agent.core)

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
  ;; 符号名**显式带包**打印。工具的身份是符号，而符号带包作用域——跨包引用
  ;; 是本设计最常见的绊脚点：别的包里 'get-weather 读出来是
  ;; THAT-PKG::GET-WEATHER，与定义处的符号并非同一对象。此时报「找不到工具：
  ;; GET-WEATHER」最误导人——调用方明明定义了 get-weather。
  ;;
  ;; 既不能用 ~A（绑定 *print-escape* 为 NIL，直接抹掉包前缀），也不能只靠 ~S
  ;; （只在符号于当前 *package* 中不可访问时才加前缀——而报错现场往往正是
  ;; 那个包，于是前缀照样不出现）。只有显式拼 package-name 才稳定可见。
  (:report (lambda (condition stream)
             (let ((name (tool-not-found-error-tool-name condition)))
               (format stream "找不到工具：~A"
                       (if (and (symbolp name) (not (keywordp name))
                                (symbol-package name))
                           (format nil "~A::~A"
                                   (package-name (symbol-package name))
                                   (symbol-name name))
                           (format nil "~S" name)))
               (when (and (symbolp name) (not (keywordp name)))
                 (format stream "~%提示：工具的身份是符号，带包作用域。~
若它定义在别的包，需在那边导出、这边用包限定引用（'other-pkg:~(~A~)）~
或 :use 那个包。"
                         (symbol-name name)))))))

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
    :documentation "为 T 时工具结果直接返回调用方，不再回传模型")
   (serial
    :initarg :serial
    :initform nil
    :reader tool-callback-serial-p
    :documentation "为 T 时该工具有副作用，批次内任一工具声明 :serial
则整批退化按序执行（kernel invoke-tool-batch 用）")
   (retry
    :initarg :retry
    :initform nil
    :reader tool-callback-retry-p
    :documentation "为 T 时瞬态故障（:transient）触发指数退避重试
（kernel barrier routing 用）"))
  (:documentation "可执行工具（对标 ToolCallback / FunctionToolCallback）"))

(defun make-tool-callback (function &key name (description "") parameters
                           return-direct serial retry)
  "从函数创建 tool-callback（对标 FunctionToolCallback.builder）。

参数：
  FUNCTION      - 执行函数（&key 风格）
  NAME          - 工具名（必填）
  DESCRIPTION   - 描述
  PARAMETERS    - 参数规格 ((name type description &key required-p default) ...)
  RETURN-DIRECT - 结果是否直接返回（不回传模型）
  SERIAL        - 有副作用，批次内存在则整批按序执行
  RETRY         - 瞬态故障触发指数退避重试

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
                 :return-direct return-direct
                 :serial serial
                 :retry retry))

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

;;; 全局注册表是 **opt-in 的逃生通道**，只服务一种场景：按*字符串*名
;;; 解析工具（工具名来自配置/DB 等，代码里拿不到符号）。
;;;
;;; deftool **不会**自动注册。工具的身份是它的符号，用 (:tools 'foo)
;;; 引用即可——那条路径查符号属性，与本表无关。
;;;
;;; 为什么不默认注册（两条都是实测出来的）：
;;;   - 越权：曾经工具执行会回退查本表，于是任何 deftool 过的工具，
;;;     模型只要报出名字就会被执行，哪怕从未暴露给它。
;;;   - 污染：光加载测试套件就会往表里塞 15 个工具，进程内永不消失；
;;;     且同名静默覆盖，两个模块各自 deftool 同名工具时后者赢、不告警。
;;;
;;; 参照实现都没有这种全局表：clj-agent 的工具表挂在 kernel 实例上
;;; （:tool-vars，由 (build-kernel {:tools [#'foo]}) 显式传入）；
;;; Spring 的 ToolCallbackResolver 是 ToolCallingManager 的实例字段，
;;; 默认是空的 DelegatingToolCallbackResolver。

(defvar *tool-registry* (make-hash-table :test #'equal)
  "全局工具注册表：名称字符串 → tool-callback。

默认为空——deftool 不写它。只有显式 register-tool-callback 才会填充。")

(defvar *tool-registry-lock* (bt:make-lock "chat-tool-registry")
  "注册表锁")

(defun register-tool-callback (callback)
  "把工具显式注册到全局注册表，供按字符串名解析（同名覆盖）。返回 callback。

仅在需要用*字符串*引用工具时才需要——例如工具名来自配置：

  (register-tool-callback (symbol-tool-callback 'get-weather))
  (chat client (:user \"...\") (:options :tool-names (list tool-name-from-config)))

用符号引用（(:tools 'get-weather)）不需要注册。

注意同名覆盖是静默的：本表是进程级全局，多模块共用时注意命名。"
  (bt:with-lock-held (*tool-registry-lock*)
    (setf (gethash (tool-callback-name callback) *tool-registry*) callback))
  callback)

(defun unregister-tool-callback (name)
  "从全局注册表移除工具。返回 T 表示有移除。"
  (bt:with-lock-held (*tool-registry-lock*)
    (remhash (normalize-tool-name name) *tool-registry*)))

(defun symbol-tool-callback (symbol)
  "取 SYMBOL 上由 deftool 挂载的 tool-callback（未定义返回 NIL）。

这是工具身份的正规取法——符号属性名是本包内部符号，调用方不该写
(get 'foo 'cl-agent.core:tool-callback)。

  (symbol-tool-callback 'get-weather)  ; => #<tool-callback get_weather>

对应 clj-agent 的 var 元数据读取（tool/get-schema）。"
  (get symbol 'tool-callback))

(defun find-tool-callback (name)
  "按名查找**全局注册表**中的工具（接受字符串/符号，未找到返回 NIL）。

注意本表默认为空——deftool 不写它，只有显式 register-tool-callback
才会填充。要取 deftool 定义的工具请用 symbol-tool-callback。"
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
  - 符号                → 取符号属性上的 callback（deftool 挂载），
                          再回退全局注册表（供显式注册的工具用符号引用）
  - 字符串              → 查全局注册表（需先 register-tool-callback）

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
  "解析 deftool body：docstring + (:param ...) / (:return-direct ...) /
(:serial ...) / (:retry ...) 子句 + 函数体。

返回：
  (values description param-specs return-direct serial retry real-body)"
  (let ((description nil)
        (param-specs nil)
        (return-direct nil)
        (serial nil)
        (retry nil)
        (rest body))
    ;; docstring
    (when (and (stringp (first rest)) (cdr rest))
      (setf description (pop rest)))
    ;; 选项子句
    (loop while (and (consp (first rest))
                     (member (first (first rest))
                             '(:param :return-direct :serial :retry)))
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
                  (setf return-direct (second clause)))
                 (:serial
                  (setf serial (second clause)))
                 (:retry
                  (setf retry (second clause))))))
    ;; lambda-list 校验
    (when (and lambda-list (not (eq (first lambda-list) '&key)))
      (error "deftool ~A：lambda-list 必须为空或以 &key 开头（工具参数是命名参数），~
              收到 ~S" name lambda-list))
    (values (or description "") (nreverse param-specs)
            return-direct serial retry rest)))

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
  2. 自动派生 JSON Schema，创建 tool-callback
  3. callback 挂到符号属性：(get '名称 'tool-callback)

**没有全局副作用**：deftool 不写任何全局注册表，工具的身份就是
它的符号。用符号把它放进请求即可：

  (chat client (:user \"...\") (:tools 'get-weather))

这与 clj-agent 的 deftool 一致——那边生成 defn 并把 schema 挂在
var 元数据上，再用 (build-kernel {:tools [#'get-weather]}) 显式传入；
Clojure 的 var 带元数据，CL 里对应的载体正是符号的属性列表
（#'get-weather 是裸函数对象，取不到 schema，不能用作工具引用）。

需要按*字符串*名解析（配置驱动等场景）时，显式调用
register-tool-callback 把它放进全局注册表——那是 opt-in 的逃生通道，
不是默认机制。

工具名自动转换为小写下划线风格（get-weather → \"get_weather\"）。

示例：
  (deftool get-weather (&key city (unit \"celsius\"))
    \"获取指定城市的当前天气\"
    (:param city :string \"城市名称\" :required t)
    (:param unit :string \"温度单位\")
    (format nil \"~A 的天气：22°C（~A），晴\" city unit))"
  (multiple-value-bind (description param-specs return-direct serial retry real-body)
      (parse-deftool-body name lambda-list body)
    `(progn
       (defun ,name ,lambda-list
         ,description
         ,@real-body)
       (setf (get ',name 'tool-callback)
             (make-tool-callback
              (lambda (&rest args) (apply #',name args))
              :name ',name
              :description ,description
              :parameters ',param-specs
              :return-direct ,return-direct
              :serial ,serial
              :retry ,retry))
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
;;; 工具解析：从本次请求的 options 定位 callback
;;; ============================================================
;;;
;;; 曾长在 ToolCallingManager 区块里。那套 manager（对标 Spring 的
;;; ToolCallingManager，(execute-tool-calls manager prompt response)）
;;; 已随 Advisor / ChatClient 一并退役——工具执行循环现在唯一住在
;;; cl-agent.core:run-tool-loop，批执行在 kernel/batch.lisp，
;;; 执行策略在 kernel/tool-calling-manager.lisp。
;;; 本函数与 manager 无关（它只是「按名找工具」），且 kernel 的
;;; batch / manager / tool-search filter 都依赖它，故保留在 chat 层。

(defun find-callback-for-call (options tool-call)
  "为一次 tool-call 定位 callback：只认本次请求 OPTIONS 里的工具。

**只查 options，不回退全局注册表**——这是刻意的安全边界：
模型只能调用我们实际暴露给它的工具。此前这里会回退到全局注册表，
于是任何 deftool 过的工具（哪怕从未出现在本次 tools 列表里）
只要模型报出名字就会被执行——提示注入下可直接利用的越权。
而 deftool 是自动注册的，作者根本意识不到攻击面被扩大了。

参照实现同样没有这种回退：clj-agent 的 find-function 只查
kernel 的 :tool-vars，找不到即抛；Spring 的 ToolCallbackResolver
是 manager 的实例字段，默认为空。

找不到时发 tool-not-found-error。调用方要负责把它转成文本回传模型
（行为友好，不中断对话）——kernel 侧由 batch.lisp 的 resolve-callback
捕获、经 tool-result->text 渲染成「错误：找不到工具 xxx」喂回模型，
让它自纠。直接调用本函数的代码若不捕获，条件会冒泡出整轮对话。"
  (let ((name (normalize-tool-name (tool-call-name tool-call))))
    (or (find name (append (chat-options-tool-callbacks options)
                           (ignore-errors
                            (resolve-tool-callbacks
                             (chat-options-tool-names options))))
              :key #'tool-callback-name
              :test #'string=)
        (error 'tool-not-found-error :tool-name name))))
