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

(defun alist-get (alist key &optional default)
  "从关联表中获取值（支持嵌套键路径）"
  (etypecase key
    (symbol (getf alist key default))
    (string (getf alist key default))
    (cons
     ;; 嵌套路径：'("user" "name")
     (let ((current alist))
       (dolist (k key)
         (setf current (alist-get current k)))
       current))
    (keyword (getf alist key default))))

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

;;; ============================================================
;;; 链式调用宏
;;; ============================================================

(defmacro -> (initial-form &rest forms)
  "线程首个宏（thread-first）"
  (loop for form in forms
        with result = initial-form
        do (setf result
                 (if (listp form)
                     (cons (car form) (cons result (cdr form)))
                     (list form result)))
        finally (return result)))

(defmacro ->> (initial-form &rest forms)
  "线程最后一个宏（thread-last）"
  (loop for form in forms
        with result = initial-form
        do (setf result
                 (if (listp form)
                     (append form (list result))
                     (list form result)))
        finally (return result)))

;;; ============================================================
;;; 日志工具
;;; ============================================================

(defun log-debug (format-string &rest args)
  "调试日志"
  (apply #'format *debug-io* (concatenate 'string "[DEBUG] " format-string "~%") args))

(defun log-info (format-string &rest args)
  "信息日志"
  (apply #'format *standard-output* (concatenate 'string "[INFO] " format-string "~%") args))

(defun log-warn (format-string &rest args)
  "警告日志"
  (apply #'format *error-output* (concatenate 'string "[WARN] " format-string "~%") args))

(defun log-error (format-string &rest args)
  "错误日志"
  (apply #'format *error-output* (concatenate 'string "[ERROR] " format-string "~%") args))

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
