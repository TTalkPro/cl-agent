;;;; utils.lisp
;;;; CL-Agent - 核心工具函数

(in-package :cl-agent.core)

;;; ============================================================
;;; 协议默认实现
;;; ============================================================

(defparameter *default-id-generator* nil
  "默认 ID 生成器实例（延迟初始化）")

(defparameter *default-timestamp-provider* nil
  "默认时间戳提供者实例（延迟初始化）")

;; 延迟初始化函数
(defun init-default-id-generator ()
  "初始化默认 ID 生成器"
  (unless *default-id-generator*
    (setf *default-id-generator*
          (funcall (find-symbol (string :make-standard-id-generator)
                                (find-package :cl-agent.core.protocols)))))
  *default-id-generator*)

(defun init-default-timestamp-provider ()
  "初始化默认时间戳提供者"
  (unless *default-timestamp-provider*
    (setf *default-timestamp-provider*
          (funcall (find-symbol (string :make-standard-timestamp-provider)
                                (find-package :cl-agent.core.protocols)))))
  *default-timestamp-provider*)

;;; ============================================================
;;; 环境变量
;;; ============================================================

(defun get-env (var-name &optional (default nil))
  "获取环境变量

  参数：
    VAR-NAME - 变量名
    DEFAULT  - 默认值（可选）

  返回：
    环境变量值或默认值

  示例：
    (get-env "OPENAI_API_KEY")
    (get-env "PORT" 8080)"
  (let ((value (uiop:getenv var-name)))
    (if (and value (string> value ""))
        value
        default)))

(defun get-env-required (var-name)
  "获取必需的环境变量，不存在时错误"
  (let ((value (get-env var-name)))
    (unless value
      (signal-error 'missing-api-key-error
                    :message (format nil "Required environment variable not set: ~A" var-name)
                    :config-key var-name))
    value))

;;; ============================================================
;;; ID 生成
;;; ============================================================

(defun generate-uuid ()
  "生成 UUID 字符串（兼容性函数）

  这是默认实现，使用标准 ID 生成器。
  新代码建议直接使用协议接口：
    (funcall (cl-agent.core.protocols:make-standard-id-generator))

  保持向后兼容：现有代码无需修改"
  (funcall (init-default-id-generator)))

(defun generate-short-id (&optional (length 8))
  "生成短 ID（用于调试和日志）"
  (subseq (generate-uuid) 0 length))

;;; ============================================================
;;; 时间工具
;;; ============================================================

(defun timestamp-now ()
  "获取当前时间戳（兼容性函数）

  返回 Unix 时间戳（整数秒）。
  这是默认实现，使用标准时间戳提供者。
  新代码建议直接使用协议接口：
    (funcall (cl-agent.core.protocols:make-standard-timestamp-provider))

  保持向后兼容：现有代码无需修改"
  (funcall (init-default-timestamp-provider)))

(defun format-timestamp (timestamp &optional (format :rfc3339))
  "格式化时间戳

  参数：
    TIMESTAMP - Unix 时间戳
    FORMAT    - :rfc3339, :iso8601, :human"
  (let ((ts (local-time:unix-to-timestamp timestamp)))
    (ecase format
      (:rfc3339 (local-time:format-timestring nil ts :format '((:year 4) #\- (:month 2) #\- (:day 2) #\T (:hour 2) #\: (:min 2) #\: (:sec 2) #\Z)))
      (:iso8601 (local-time:format-timestring nil ts))
      (:human (local-time:format-timestring nil ts :timezone local-time:+utc-zone+)))))

;;; ============================================================
;;; JSON/Alist 操作
;;; ============================================================

(defun json-parse (string &key (as :alist))
  "解析 JSON 字符串

  参数：
    STRING - JSON 字符串
    AS     - :alist 或 :plist

  返回：
    Lisp 数据结构"
  (let ((parsed (com.inuoe.jzon:parse string)))
    (ecase as
      (:alist parsed)
      (:plist (alexandria:alist-plist parsed)))))

(defun json-stringify (object &key (pretty nil))
  "将 Lisp 对象转换为 JSON 字符串

  参数：
    OBJECT - Lisp 对象
    PRETTY - 是否美化输出"
  (if pretty
      (com.inuoe.jzon:stringify object :pretty t)
      (com.inuoe.jzon:stringify object)))

;;; 此处曾有一个 alist-get：名为 alist 访问器，函数体却是
;;; (getf alist key default)——getf 是 plist 访问器且以 eq 比较键，
;;; 用在真正的 alist 上，奇数长度直接抛 malformed property list，
;;; 偶数长度则恒返回 default（字符串键永不 eq）。它实际只对 plist 有效，
;;; 而那正是下面 plist-get 的功能，两者逐字等价。
;;; 它在 core 内零调用，且被 cl-agent.llm 中同名的真 alist 访问器
;;; （llm/providers.lisp，35 处调用）静默覆盖——那才是干活的那个。
;;; 故删除本副本并取消导出，让 alist-get 归 cl-agent.llm 私有。
;;; 需要 plist 访问用 plist-get；需要 alist 访问请另写正确实现。

(defun plist-get (plist key &optional default)
  "从属性列表中获取值"
  (getf plist key default))

(defun build-url (base-url params)
  "构建带有查询参数的 URL

  参数：
    BASE-URL - 基础 URL
    PARAMS   - 参数列表 ((\"key\" . \"value\") ...)

  返回：
    完整 URL 字符串"
  (let ((query-strings
         (loop for (key . value) in params
               when (and key (string-not-equal value ""))
               collect (format nil "~A=~A"
                              (cl-ppcre:regex-replace-all " " key "%20")
                              (cl-ppcre:regex-replace-all " " value "%20")))))
    (if query-strings
        (format nil "~A?~A"
                base-url
                (format nil "~{~A~^&~}" query-strings))
        base-url)))

;;; ============================================================
;;; 字符串工具
;;; ============================================================

(defun truncate-string (str length &optional (suffix "..."))
  "截断字符串到指定长度"
  (if (> (length str) length)
      (concatenate 'string (subseq str 0 (- length (length suffix))) suffix)
      str))

(defun clean-whitespace (str)
  "清理字符串中的多余空白"
  (cl-ppcre:regex-replace-all "\\s+" str " "))

(defun string-empty-p (str)
  "检查字符串是否为空"
  (or (null str)
      (string= str "")
      (string= (string-trim '(#\Space #\Tab #\Newline) str) "")))

(defun ensure-string (obj)
  "确保对象是字符串"
  (etypecase obj
    (string obj)
    (symbol (symbol-name obj))
    (number (write-to-string obj))
    (t (princ-to-string obj))))

;;; ============================================================
;;; 列表工具
;;; ============================================================

(defun take (n list)
  "取列表的前 N 个元素"
  (when (and list (plusp n))
    (cons (car list) (take (1- n) (cdr list)))))

(defun drop (n list)
  "丢弃列表的前 N 个元素"
  (if (or (zerop n) (null list))
      list
      (drop (1- n) (cdr list))))

(defun group-by (key-fn list)
  "按键函数分组列表"
  (let ((groups (make-hash-table :test 'equal)))
    (dolist (item list)
      (let ((key (funcall key-fn item)))
        (push item (gethash key groups))))
    (loop for key being each hash-key of groups
          collect (cons key (gethash key groups)))))

;;; ============================================================
;;; 函数组合
;;; ============================================================

(defmacro compose (&rest functions)
  "组合函数（从右到左）"
  (if (null functions)
      #'identity
      (let ((fn (car (last functions)))
            (rest (butlast functions)))
        (if rest
            `(lambda (&rest args)
               (funcall ,(loop for f in (reverse rest)
                               collect f into result
                               finally (return `#',result))
                        (apply #',fn args)))
            fn))))

(defmacro pipe (&rest functions)
  "管道函数（从左到右）"
  `(compose ,@(reverse functions)))

;;; 链式调用宏（-> / ->> / as->）定义在 macros.lisp 的控制流宏一节。
;;; 此处曾有一份与之逐字相同的 -> / ->> 副本（仅 docstring 微差），
;;; 因加载顺序在后而一直顶替 macros.lisp 的版本并产生重定义警告，已删除。

;;; ============================================================
;;; 动态绑定继承（跨线程）
;;; ============================================================
;;; 特殊变量的绑定是每线程独立的：新线程只能看到全局值，看不到
;;; 创建它的线程用 let 建立的绑定。基于线程池的并行代码（工具并行
;;; 执行、异步 HTTP）因此存在一个隐患——lparallel:force 遇到尚未
;;; 被 worker 领走的任务时会由调用线程就地执行（task stealing），
;;; 于是同一个变量在任务体内的可见性取决于调度竞争：被窃取时看到
;;; 调用方的绑定，被 worker 领走时看到全局值。
;;;
;;; 这里提供「提交时快照 + 执行处重建」的机制来消除这种不确定性：
;;; 提交线程用 capture-special-bindings 拍快照，任务体用
;;; with-captured-special-bindings（progv）重建，无论任务最终落在
;;; 哪个线程、何时执行，看到的都是提交时刻的绑定。

(defvar *inherited-special-variables* '()
  "需要跨线程继承的特殊变量名列表（符号列表）。

被 cl-agent.chat 的并行工具执行与 cl-agent.http 的异步请求共用：
列入的变量会在提交线程快照当前值，并在任务实际执行处重新绑定。

  (defvar *request-id* nil)
  (with-inherited-specials (*request-id*)
    (let ((*request-id* \"req-42\"))
      ...))   ; 任务体内保证看到 \"req-42\"

不在列表中的变量，其在任务体内的可见性不确定（见上方说明），
不要依赖——需要什么就列什么。

快照的是值引用而非深拷贝：若值是可变对象（哈希表、可变列表），
多个任务仍共享同一实例，需自行加锁。")

(defmacro with-inherited-specials ((&rest symbols) &body body)
  "在 BODY 内把 SYMBOLS 追加进 *inherited-special-variables*。

SYMBOLS 不求值，直接写变量名即可：

  (with-inherited-specials (*request-id* *tenant*)
    (let ((*request-id* \"req-42\")) ...))"
  `(let ((*inherited-special-variables*
           (append ',symbols *inherited-special-variables*)))
     ,@body))

(defun capture-special-bindings (&optional (symbols *inherited-special-variables*))
  "在当前线程快照 SYMBOLS 的值，返回 (符号列表 . 值列表)，
供 with-captured-special-bindings 在别处重建。

必须在提交线程调用——在任务体内调用毫无意义（那里已经看不到
调用方的绑定了）。

跳过未绑定符号与常量：progv 绑定常量是未定义行为；而未绑定符号
若进了变量列表却没有对应值，会被绑成「无值」状态，反倒遮蔽全局值。"
  (loop for sym in symbols
        when (and (symbolp sym) (not (constantp sym)) (boundp sym))
          collect sym into syms
          and collect (symbol-value sym) into vals
        finally (return (cons syms vals))))

(defmacro with-captured-special-bindings ((capture) &body body)
  "在 CAPTURE（capture-special-bindings 的返回值）的绑定下执行 BODY。

CAPTURE 为空时退化为普通 progn（progv 空列表即无绑定）。"
  (let ((c (gensym "CAPTURE")))
    `(let ((,c ,capture))
       (progv (car ,c) (cdr ,c)
         ,@body))))

;;; 日志工具（log-debug / log-info / log-warn / log-error）定义在
;;; macros.lisp 的日志系统一节：带级别过滤、时间戳与 *log-context*。
;;; 此处曾有一份无级别过滤的简易重复实现，因 macros.lisp 中 as-> 缺一个
;;; 右括号、导致其后全部定义（含整个日志系统）从未生效而长期顶替使用；
;;; 括号修复后已删除，以免覆盖真正的实现。

;;; ============================================================
;;; Tool Specification
;;; ============================================================

(defun make-tool (&key name description parameters handler)
  "Create a tool specification plist.

Parameters:
  NAME        - Tool name (string)
  DESCRIPTION - Tool description
  PARAMETERS  - Parameter specifications list
  HANDLER     - Handler function (lambda (args) ...)

Returns:
  Tool specification plist

Example:
  (make-tool :name \"search\"
             :description \"Search documents\"
             :parameters '((:name \"query\" :type :string :required t))
             :handler (lambda (args) (search (getf args :query))))"
  (list :name name
        :description description
        :parameters parameters
        :handler handler))
