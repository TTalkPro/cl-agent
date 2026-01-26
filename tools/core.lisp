;;;; core.lisp
;;;; CL-Agent - 工具系统核心
;;;;
;;;; 概述：
;;;;   实现工具注册、管理和执行
;;;;
;;;; 特性：
;;;;   - 工具注册表
;;;;   - 工具定义结构
;;;;   - 工具执行引擎
;;;;   - 工具验证
;;;;   - 权限控制

(in-package :cl-agent.tools)

;;; ============================================================
;;; 注意：不再使用全局变量
;;; ============================================================
;;;
;;; 所有配置都通过 tool-registry 和 provider 对象管理
;;; 每个 agent 实例应该创建自己的 tool-registry
;;;
;;; 使用方法：
;;;   ;; 创建 registry
;;;   (defparameter *my-registry* (make-tool-registry))
;;;
;;;   ;; 添加 provider
;;;   (defparameter *builtin* (make-default-builtin-provider))
;;;   (add-provider *my-registry* *builtin*)
;;;
;;;   ;; 执行工具
;;;   (execute-tool *my-registry* :tool-name args)
;;;

;;; ============================================================
;;; 参数处理
;;; ============================================================

(defun normalize-parameters (parameters)
  "标准化参数规格

  参数：
    PARAMETERS - 原始参数规格

  返回：
    标准化后的参数规格"
  (mapcar (lambda (param)
            (if (symbolp param)
                (list param :type :any :description "")
                param))
          parameters))

(defun validate-arguments (tool arguments)
  "验证工具参数

  参数：
    TOOL      - 工具实例
    ARGUMENTS - 参数（plist、alist 或 hash-table）

  返回：
    (values validated-arguments errors)
    - validated-arguments: 验证并补全默认值后的参数 plist
    - errors: 错误列表，无错误时为 NIL

  说明：
    1. 检查必需参数
    2. 检查参数类型
    3. 应用默认值"
  (let* ((param-specs (tool-parameters tool))
         (args-plist (arguments-to-plist arguments))
         (errors nil)
         (validated-args nil))

    ;; 遍历参数规格
    (dolist (spec param-specs)
      (let* ((param-name (first spec))
             (param-props (rest spec))
             (param-key (if (keywordp param-name)
                            param-name
                            (intern (string-upcase (string param-name)) :keyword)))
             (param-type (getf param-props :type :any))
             (required-p (getf param-props :required))
             (default-value (getf param-props :default))
             (provided-value (getf args-plist param-key :not-provided)))

        ;; 1. 检查必需参数
        (cond
          ;; 参数已提供
          ((not (eq provided-value :not-provided))
           ;; 2. 检查参数类型
           (let ((type-error (validate-argument-type param-key provided-value param-type)))
             (if type-error
                 (push type-error errors)
                 (progn
                   (push param-key validated-args)
                   (push provided-value validated-args)))))

          ;; 参数未提供但有默认值
          (default-value
           (push param-key validated-args)
           (push default-value validated-args))

          ;; 必需参数未提供
          (required-p
           (push (format nil "Missing required argument: ~A" param-key) errors)))))

    ;; 保留未在规格中定义的额外参数
    (loop for (key value) on args-plist by #'cddr
          unless (find-parameter-spec key param-specs)
          do (progn
               (push key validated-args)
               (push value validated-args)))

    (values (nreverse validated-args) (nreverse errors))))

(defun arguments-to-plist (arguments)
  "将参数转换为 plist

  参数：
    ARGUMENTS - 参数（plist、alist、hash-table 或 nil）

  返回：
    plist"
  (cond
    ;; nil
    ((null arguments) nil)

    ;; 已经是 plist（关键字开头的列表）
    ((and (listp arguments)
          (evenp (length arguments))
          (or (null arguments)
              (keywordp (first arguments))))
     arguments)

    ;; alist（列表的列表）
    ((and (listp arguments)
          (listp (first arguments))
          (consp (first arguments)))
     (loop for (key . value) in arguments
           collect (if (keywordp key)
                       key
                       (intern (string-upcase (string key)) :keyword))
           collect value))

    ;; hash-table
    ((hash-table-p arguments)
     (let ((result nil))
       (maphash (lambda (k v)
                  (let ((key (if (keywordp k)
                                 k
                                 (intern (string-upcase (string k)) :keyword))))
                    (push key result)
                    (push v result)))
                arguments)
       (nreverse result)))

    ;; 其他情况，返回空 plist
    (t nil)))

(defun find-parameter-spec (key param-specs)
  "查找参数规格

  参数：
    KEY         - 参数关键字
    PARAM-SPECS - 参数规格列表

  返回：
    参数规格或 NIL"
  (find-if (lambda (spec)
             (let* ((param-name (first spec))
                    (param-key (if (keywordp param-name)
                                   param-name
                                   (intern (string-upcase (string param-name)) :keyword))))
               (eq param-key key)))
           param-specs))

(defun validate-argument-type (name value expected-type)
  "验证参数类型

  参数：
    NAME          - 参数名
    VALUE         - 参数值
    EXPECTED-TYPE - 期望类型

  返回：
    错误消息或 NIL"
  (let ((valid-p
          (case expected-type
            ;; 任意类型
            ((:any t) t)

            ;; 字符串
            (:string (stringp value))

            ;; 数字
            (:number (numberp value))

            ;; 整数
            (:integer (integerp value))

            ;; 布尔
            (:boolean (or (eq value t) (eq value nil)
                          (eq value :true) (eq value :false)
                          (equal value "true") (equal value "false")))

            ;; 数组/列表
            ((:array :list) (listp value))

            ;; 对象/哈希表/plist
            ((:object :hash-table :plist)
             (or (hash-table-p value)
                 (and (listp value)
                      (or (null value)
                          (keywordp (first value))))))

            ;; 函数
            (:function (functionp value))

            ;; 关键字
            (:keyword (keywordp value))

            ;; 符号
            (:symbol (symbolp value))

            ;; 路径/pathname
            (:pathname (or (pathnamep value) (stringp value)))

            ;; 默认：接受任何类型
            (otherwise t))))

    (unless valid-p
      (format nil "Argument ~A: expected ~A, got ~A (~A)"
              name expected-type (type-of value) value))))

(defun flatten-arguments (arguments)
  "将参数展平为函数调用参数

  参数：
    ARGUMENTS - 参数（plist、alist 或 hash-table）

  返回：
    展平的参数列表"
  (cond
    ;; plist
    ((and (listp arguments)
          (evenp (length arguments))
          (keywordp (first arguments)))
     arguments)

    ;; alist
    ((and (listp arguments)
          (consp (first arguments)))
     (loop for (key . value) in arguments
           when (keywordp key)
           collect key
           and collect value
           else
           collect (intern (string-upcase key) :keyword)
           and collect value))

    ;; hash-table
    ((hash-table-p arguments)
     (loop for key being the hash-keys of arguments
           for value being the hash-values of arguments
           when (keywordp key)
           collect key
           and collect value
           else
           collect (intern (string-upcase key) :keyword)
           and collect value))

    ;; 单个值
    (t
     (list arguments))))

;;; ============================================================
;;; 权限控制
;;; ============================================================

(defun check-permissions (registry tool)
  "检查工具权限

  参数：
    REGISTRY - tool-registry 实例
    TOOL     - 工具实例

  错误：
    - tool-permission-error: 权限不足"
  (when (registry-permissions-enabled-p registry)
    (let ((required (tool-permissions tool)))
      (dolist (perm required)
        (unless (permission-allowed-p registry perm)
          (signal-error 'tool-permission-error
                        :message (format nil "Permission denied: ~A" perm)
                        :permission perm))))))

(defun permission-allowed-p (registry permission)
  "检查权限是否允许

  参数：
    REGISTRY   - tool-registry 实例
    PERMISSION - 权限名称

  返回：
    T 或 NIL"
  (let ((allowed (registry-allowed-permissions registry)))
    (or (member :all allowed)
        (member permission allowed))))

(defun grant-permission (registry permission)
  "授予权限

  参数：
    REGISTRY   - tool-registry 实例
    PERMISSION - 权限名称"
  (pushnew permission (registry-allowed-permissions registry))
  (when (registry-verbose-p registry)
    (format t "[Tools] Granted permission: ~A~%" permission)))

(defun revoke-permission (registry permission)
  "撤销权限

  参数：
    REGISTRY   - tool-registry 实例
    PERMISSION - 权限名称"
  (setf (registry-allowed-permissions registry)
        (remove permission (registry-allowed-permissions registry)))
  (when (registry-verbose-p registry)
    (format t "[Tools] Revoked permission: ~A~%" permission)))

;;; ============================================================
;;; 工具信息
;;; ============================================================

(defun tool-info (tool)
  "获取工具信息

  参数：
    TOOL - 工具实例

  返回：
    信息 plist"
  `(:name ,(tool-name tool)
    :description ,(tool-description tool)
    :category ,(tool-category tool)
    :tags ,(tool-tags tool)
    :parameters ,(tool-parameters tool)
    :permissions ,(tool-permissions tool)))

(defun print-tool-info (tool &optional (stream t))
  "打印工具信息

  参数：
    TOOL   - 工具实例
    STREAM - 输出流"
  (let ((info (tool-info tool)))
    (format stream "~&=== Tool Info ===~%")
    (format stream "Name: ~A~%" (getf info :name))
    (format stream "Description: ~A~%" (getf info :description))
    (format stream "Category: ~A~%" (getf info :category))
    (format stream "Tags: ~A~%" (getf info :tags))
    (format stream "Parameters: ~A~%" (getf info :parameters))
    (format stream "Permissions: ~A~%" (getf info :permissions))
    (format stream "================~%")
    (values)))

(defun describe-tools (registry &key (category nil) (stream t))
  "描述所有工具（用于 LLM）

  参数：
    REGISTRY - tool-registry 实例
    CATEGORY - 过滤分类（可选）
    STREAM   - 输出流

  返回：
    描述字符串"
  (declare (ignore stream))  ; 简化实现，始终返回字符串
  (let ((tools (list-tools registry :category category)))
    (with-output-to-string (s)
      (format s "Available tools:~%")
      (dolist (tool tools)
        (format s "  - ~A: ~A~%"
                (tool-name tool)
                (tool-description tool))))))

;;; ============================================================
;;; 工具序列化
;;; ============================================================

(defun tool-to-plist (tool)
  "将工具转换为 plist

  参数：
    TOOL - 工具实例

  返回：
    plist 表示"
  `(:name ,(tool-name tool)
    :description ,(tool-description tool)
    :parameters ,(tool-parameters tool)
    :category ,(tool-category tool)
    :tags ,(tool-tags tool)
    :permissions ,(tool-permissions tool)))

(defun tool-from-plist (plist)
  "从 plist 创建工具

  参数：
    PLIST - plist 表示

  返回：
    工具实例

  说明：
    用于序列化恢复，但 function 需要单独设置"
  (make-tool
   :name (getf plist :name)
   :description (getf plist :description)
   :parameters (getf plist :parameters)
   :category (getf plist :category)
   :tags (getf plist :tags)
   :permissions (getf plist :permissions)))

(defun tool-to-json-schema (tool)
  "将工具转换为 JSON Schema 格式

  参数：
    TOOL - 工具实例

  返回：
    JSON Schema plist

  说明：
    用于 LLM 函数调用"
  `(:type "object"
    :name ,(string-downcase (string (tool-name tool)))
    :description ,(tool-description tool)
    :parameters
    (:type "object"
     :properties
     ,(let ((props (make-hash-table :test #'equal)))
        (dolist (param (tool-parameters tool))
          (let ((param-name (string-downcase (string (first param)))))
            (setf (gethash param-name props)
                  (parameter-to-json-schema param))))
        props)
     :required
     ,(mapcar #'(lambda (param)
                  (string-downcase (string (first param))))
              (remove-if-not (lambda (p)
                              (getf (cdr p) :required))
                            (tool-parameters tool))))))

(defun parameter-to-json-schema (param)
  "将参数规格转换为 JSON Schema

  参数：
    PARAM - 参数规格 (name . props)

  返回：
    JSON Schema plist"
  (let ((type-str (case (getf (cdr param) :type)
                     (:string "string")
                     (:number "number")
                     (:integer "integer")
                     (:boolean "boolean")
                     (:array "array")
                     (:object "object")
                     (otherwise "string"))))
    `(:type ,type-str
      :description ,(getf (cdr param) :description ""))))

