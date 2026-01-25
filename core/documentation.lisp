;;;; documentation.lisp
;;;; CL-Agent - 统一文档宏系统
;;;;
;;;; 概述：
;;;;   提供标准化的文档宏，减少文档模板代码重复
;;;;
;;;; 特性：
;;;;   - 文件级文档宏
;;;;   - 函数文档宏
;;;;   - 自动格式化
;;;;   - 中文文档支持

(in-package :cl-agent.core)

;;; ============================================================
;;; 文件级文档宏
;;; ============================================================

(defmacro define-file-documentation ((module-name &key overview features examples)
                                     &body body)
  "定义文件级文档的标准化宏

  参数：
    MODULE-NAME - 模块名称（符号或字符串）
    OVERVIEW    - 概述字符串
    FEATURES    - 特性列表
    EXAMPLES    - 示例说明（可选）

  这个宏生成标准化的文件头注释，包含模块名称、概述和特性列表。

  示例：
    (define-file-documentation (\"工具系统核心\"
      :overview \"实现工具注册、管理和执行\"
      :features '(\"工具注册表\" \"工具定义结构\" \"工具执行引擎\"
                  \"工具验证\" \"权限控制\"))
      (in-package :cl-agent.tools)
      ...)"
  (declare (ignore module-name overview features examples))
  ;; 这个宏主要用于文档生成，实际编译时不起作用
  ;; 文档内容通过注释保留在源码中
  `(progn ,@body))

(defmacro defsection (name &key description exports)
  "定义代码段（section）及其导出符号

  参数：
    NAME        - 段名称
    DESCRIPTION - 描述字符串
    EXPORTS     - 导出符号列表

  示例：
    (defsection 工具注册
      :description \"工具注册和管理功能\"
      :exports '(register-tool unregister-tool find-tool))"
  `(progn
     ;; 段定义（用于文档生成）
     (eval-when (:compile-toplevel :load-toplevel :execute)
       ,@body)
     (export ',@(or exports '()))))

;;; ============================================================
;;; 函数文档宏
;;; ============================================================

(defmacro defun-documented (name args documentation &body body)
  "定义带标准化文档的函数

  参数：
    NAME          - 函数名称
    ARGS          - 参数列表
    DOCUMENTATION - 文档字符串（可以使用简化格式）
    BODY          - 函数体

  文档格式：
    DOCUMENTATION 可以是字符串或结构化文档列表：
    - 字符串：直接作为文档字符串
    - 列表：(:description \"描述\"
               :params ((param1 \"参数1描述\") ...)
               :return \"返回值描述\"
               :example \"示例代码\")

  示例：
    (defun-documented register-tool (name description function &key ...)
      (:description \"注册工具到全局注册表\"
       :params ((name \"工具名称（符号或关键字）\")
                (description \"工具描述\")
                (function \"执行函数\"))
       :return \"工具实例\"
       :example \"(register-tool :search \\\"Search\\\" #'search-fn)\")
      ...)"
  (let ((doc-string
         (if (stringp documentation)
             documentation
             (let ((desc (getf documentation :description ""))
                   (params (getf documentation :params nil))
                   (ret (getf documentation :return ""))
                   (example (getf documentation :example nil)))
               (with-output-to-string (s)
                 (format s "~A~%~%" desc)
                 (when params
                   (format s "参数：~%")
                   (dolist (param params)
                     (format s "  ~A - ~A~%" (car param) (cadr param)))
                   (format s "~%"))
                 (when ret
                   (format s "返回：~%  ~A~%~%" ret))
                 (when example
                   (format s "示例：~%  ~A" example)))))))
    `(defun ,name ,args
       ,doc-string
       ,@body)))


;;; ============================================================
;;; 泛函数文档宏
;;; ============================================================

(defmacro defgeneric-documented (name args documentation &body options)
  "定义带标准化文档的泛函数

  参数：
    NAME          - 泛函数名称
    ARGS          - 参数列表
    DOCUMENTATION - 文档字符串（格式同 defun-documented）
    OPTIONS       - 泛函数选项（:documentation, :method-combination 等）

  示例：
    (defgeneric-documented execute-tool (tool-name params)
      (:description \"执行工具\"
       :params ((tool-name \"工具名称\")
                (params \"参数列表\"))
       :return \"执行结果\")
      (:method-combination standard :most-specific-last))"
  (let ((doc-string
         (if (stringp documentation)
             documentation
             (let ((desc (getf documentation :description ""))
                   (params (getf documentation :params nil))
                   (ret (getf documentation :return "")))
               (with-output-to-string (s)
                 (format s "~A~%~%" desc)
                 (when params
                   (format s "参数：~%")
                   (dolist (param params)
                     (format s "  ~A - ~A~%" (car param) (cadr param)))
                   (format s "~%"))
                 (when ret
                   (format s "返回：~%  ~A~%" ret)))))))
    `(defgeneric ,name ,args
       (:documentation ,doc-string)
       ,@options)))

(defmacro defmethod-documented (name qualifs args documentation &body body)
  "定义带标准化文档的方法

  参数：
    NAME          - 泛函数名称
    QUALIFS       - 限定符列表（如 (:before (x) :around (x y))）
    ARGS          - 参数列表
    DOCUMENTATION - 文档字符串
    BODY          - 方法体

  示例：
    (defmethod-documented execute-tool (tool-name params)
      ()
      (:description \"默认工具执行方法\")
      ...)"
  (let ((doc-string
         (if (stringp documentation)
             documentation
             (let ((desc (getf documentation :description "")))
               desc))))
  `(defmethod ,name ,@qualifs ,args
     ,doc-string
     ,@body)))

;;; ============================================================
;;; 结构体文档宏
;;; ============================================================

(defmacro defstruct-documented (name-and-options documentation &body slots)
  "定义带标准化文档的结构体

  参数：
    NAME-AND-OPTIONS - 结构体名称和选项（如 (point :conc-name p-))
    DOCUMENTATION    - 文档字符串或结构化文档
    SLOTS            - 槽位定义列表

  文档格式：
    DOCUMENTATION 可以是：
    - 字符串：直接作为描述
    - 列表：(:description \"描述\" :slots ((slot1 \"槽位1描述\") ...))

  示例：
    (defstruct-documented tool
      (:description \"工具定义结构\"
       :slots ((name \"工具名称\")
               (description \"工具描述\")
               (function \"执行函数\")))
      name
      (description nil :type (or null string))
      function)"
  (let ((doc-string
         (if (stringp documentation)
             documentation
             (getf documentation :description ""))))
    ;; 生成结构体定义和注释
    `(progn
       ;; 结构体：,(if (consp name-and-options) (car name-and-options) name-and-options)
       ;; ,doc-string
       (defstruct ,name-and-options
         ,@(when slots
             (let ((slot-docs (getf documentation :slots nil)))
               (mapcar (lambda (slot)
                         (if (consp slot)
                             slot
                             (let ((slot-doc (cdr (assoc slot slot-docs))))
                               (if slot-doc
                                   `(,slot nil :type t
                                          ;; ,slot-doc
                                          )
                                   slot))))
                       slots)))))))

;;; ============================================================
;;; 变量文档宏
;;; ============================================================

(defmacro defvar-documented (name documentation &optional (value nil value-p))
  "定义带文档的全局变量

  参数：
    NAME          - 变量名称
    DOCUMENTATION - 文档字符串
    VALUE         - 初始值（可选）

  示例：
    (defvar-documented *tool-registry*
      \"全局工具注册表\"
      (make-hash-table :test #'equal))"
  `(defvar ,name
     ,(when value-p value)
     ,documentation))

(defmacro defparameter-documented (name documentation &optional (value nil value-p))
  "定义带文档的参数变量

  参数：
    NAME          - 参数名称
    DOCUMENTATION - 文档字符串
    VALUE         - 初始值（可选）

  示例：
    (defparameter-documented *tool-verbose*
      \"是否输出工具调试信息\"
      nil)"
  `(defparameter ,name
     ,(when value-p value)
     ,documentation))

;;; ============================================================
;;; 常量文档宏
;;; ============================================================

(defmacro defconstant-documented (name value documentation)
  "定义带文档的常量

  参数：
    NAME          - 常量名称
    VALUE         - 常量值
    DOCUMENTATION - 文档字符串

  示例：
    (defconstant-documented +max-retries+
      3
      \"最大重试次数\")"
  `(defconstant ,name
     ,value
     ,documentation))

;;; ============================================================
;;; 文档模板生成函数
;;; ============================================================

(defun make-function-documentation (description &key params return example)
  "生成标准化的函数文档字符串

  参数：
    DESCRIPTION - 函数描述
    PARAMS      - 参数列表 ((name description) ...)
    RETURN      - 返回值描述
    EXAMPLE     - 示例代码

  返回：
    格式化的文档字符串"
  (with-output-to-string (s)
    (format s "~A~%" description)
    (when params
      (format s "~%参数：~%")
      (dolist (param params)
        (format s "  ~A - ~A~%" (car param) (cadr param))))
    (when return
      (format s "~%返回：~%  ~A" return))
    (when example
      (format s "~%示例：~%  ~A" example))))

(defun make-method-documentation (description &key specialized-params)
  "生成标准化的方法文档字符串

  参数：
    DESCRIPTION          - 方法描述
    SPECIALIZED-PARAMS   - 特化参数列表

  返回：
    格式化的文档字符串"
  (with-output-to-string (s)
    (format s "~A" description)
    (when specialized-params
      (format s "~%特化参数：")
      (dolist (param specialized-params)
        (format s "  ~A" param)))))

;;; ============================================================
;;; 导出符号
;;; ============================================================

(export '(defun-documented
          defgeneric-documented
          defmethod-documented
          defstruct-documented
          defvar-documented
          defparameter-documented
          defconstant-documented
          make-function-documentation
          make-method-documentation
          define-file-documentation
          defsection))
