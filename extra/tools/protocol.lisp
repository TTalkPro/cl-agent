;;;; protocol.lisp
;;;; CL-Agent Tools - 核心协议和基类
;;;;
;;;; 概述：
;;;;   定义 Tool Provider 系统的核心类、泛型函数和协议
;;;;
;;;; 架构：
;;;;   - tool: 工具定义
;;;;   - tool-provider: 工具提供者基类
;;;;   - 泛型函数协议

(in-package #:cl-agent.tools)

;;; ============================================================
;;; 工具类
;;; ============================================================

(defclass tool ()
  ((name
    :initarg :name
    :accessor tool-name
    :type keyword
    :documentation "工具名称（关键字）")

   (description
    :initarg :description
    :accessor tool-description
    :type string
    :documentation "工具描述")

   (handler
    :initarg :handler
    :accessor tool-handler
    :type function
    :documentation "工具执行函数")

   (parameters
    :initarg :parameters
    :accessor tool-parameters
    :initform nil
    :documentation "参数定义列表
格式: ((name :type TYPE :required BOOL :description DESC) ...)")

   (category
    :initarg :category
    :accessor tool-category
    :initform :general
    :type keyword
    :documentation "工具分类 (:http, :file, :search, :shell, :mcp, :custom)")

   (permissions
    :initarg :permissions
    :accessor tool-permissions
    :initform nil
    :type list
    :documentation "所需权限列表")

   (tags
    :initarg :tags
    :accessor tool-tags
    :initform nil
    :type list
    :documentation "工具标签列表（关键字列表，用于过滤和分组）")

   (metadata
    :initarg :metadata
    :accessor tool-metadata
    :initform nil
    :documentation "额外元数据（plist）"))

  (:documentation "工具定义"))

;;; ============================================================
;;; 工具提供者基类
;;; ============================================================

(defclass tool-provider ()
  ((name
    :initarg :name
    :accessor tool-provider-name
    :type string
    :documentation "提供者名称")

   (enabled
    :initarg :enabled
    :accessor provider-enabled-p
    :initform t
    :type boolean
    :documentation "是否启用此提供者")

   (tools
    :accessor provider-tools
    :initform (make-hash-table :test #'eq)
    :documentation "工具注册表 (keyword -> tool)")

   (metadata
    :initarg :metadata
    :accessor provider-metadata
    :initform nil
    :documentation "提供者元数据（plist）"))

  (:documentation "工具提供者基类"))

;; Provide method for core's provider-name generic function
(defmethod cl-agent.core:provider-name ((provider tool-provider))
  "Get the name of the tool provider."
  (tool-provider-name provider))

;;; ============================================================
;;; 生命周期协议
;;; ============================================================

(defgeneric initialize-provider (provider)
  (:documentation "初始化提供者

参数:
  PROVIDER - 提供者实例

返回:
  provider

说明:
  子类应重写此方法以注册工具、初始化连接等"))

(defmethod initialize-provider ((provider tool-provider))
  "默认实现：不做任何事"
  provider)

(defgeneric shutdown-provider (provider)
  (:documentation "关闭提供者，清理资源

参数:
  PROVIDER - 提供者实例

返回:
  provider"))

(defmethod shutdown-provider ((provider tool-provider))
  "默认实现：清空工具表"
  (clrhash (provider-tools provider))
  provider)

;;; ============================================================
;;; 工具管理协议
;;; ============================================================

(defgeneric register-tool (provider tool)
  (:documentation "注册工具到提供者

参数:
  PROVIDER - 提供者实例
  TOOL     - 工具实例

返回:
  tool

错误:
  如果工具名称已存在，发出警告但仍然注册（覆盖）"))

(defmethod register-tool ((provider tool-provider) (tool tool))
  "注册工具（默认实现）"
  (let ((tool-name (tool-name tool)))
    ;; 检查是否已存在
    (when (gethash tool-name (provider-tools provider))
      (warn "Tool ~A already exists in provider ~A, overwriting"
            tool-name (provider-name provider)))

    ;; 注册工具
    (setf (gethash tool-name (provider-tools provider)) tool)
    tool))

(defgeneric unregister-tool (provider tool-name)
  (:documentation "从提供者注销工具

参数:
  PROVIDER  - 提供者实例
  TOOL-NAME - 工具名称（关键字）

返回:
  t 如果工具存在并被删除，nil 如果工具不存在"))

(defmethod unregister-tool ((provider tool-provider) tool-name)
  "注销工具（默认实现）"
  (remhash tool-name (provider-tools provider)))

(defgeneric find-tool (provider tool-name)
  (:documentation "在提供者中查找工具

参数:
  PROVIDER  - 提供者实例
  TOOL-NAME - 工具名称（关键字）

返回:
  tool 实例，如果未找到返回 nil"))

(defmethod find-tool ((provider tool-provider) tool-name)
  "查找工具（默认实现）"
  (gethash tool-name (provider-tools provider)))

(defgeneric list-tools (provider &key category)
  (:documentation "列出提供者中的所有工具

参数:
  PROVIDER - 提供者实例
  CATEGORY - 可选，按分类过滤

返回:
  工具列表"))

(defmethod list-tools ((provider tool-provider) &key category)
  "列出所有工具（默认实现）"
  (let ((tools nil))
    (maphash (lambda (name tool)
               (declare (ignore name))
               (when (or (null category)
                        (eq (tool-category tool) category))
                 (push tool tools)))
             (provider-tools provider))
    (nreverse tools)))

;;; ============================================================
;;; 工具执行协议
;;; ============================================================

(defgeneric execute-tool (provider tool-name &rest args)
  (:documentation "执行工具

参数:
  PROVIDER  - 提供者实例
  TOOL-NAME - 工具名称（关键字）
  ARGS      - 工具参数（关键字参数）

返回:
  工具执行结果

错误:
  - 如果提供者被禁用，抛出错误
  - 如果工具未找到，抛出错误
  - 工具执行中的错误会被传播"))

(defmethod execute-tool ((provider tool-provider) tool-name &rest args)
  "执行工具（默认实现）"
  ;; 检查提供者是否启用
  (unless (provider-enabled-p provider)
    (error "Provider ~A is disabled" (provider-name provider)))

  ;; 查找工具
  (let ((tool (find-tool provider tool-name)))
    (unless tool
      (error "Tool ~A not found in provider ~A"
             tool-name (provider-name provider)))

    ;; 执行工具
    (apply (tool-handler tool) args)))

(defgeneric validate-tool-call (provider tool-name args)
  (:documentation "验证工具调用参数

参数:
  PROVIDER  - 提供者实例
  TOOL-NAME - 工具名称
  ARGS      - 参数列表（plist）

返回:
  t 如果验证通过

错误:
  如果验证失败，抛出错误"))

(defmethod validate-tool-call ((provider tool-provider) tool-name args)
  "验证工具调用（默认实现）"
  (let ((tool (find-tool provider tool-name)))
    (unless tool
      (error "Tool ~A not found" tool-name))

    ;; 验证必需参数
    (dolist (param-spec (tool-parameters tool))
      (let ((param-name (first param-spec))
            (param-props (rest param-spec)))
        (when (getf param-props :required)
          (unless (getf args param-name)
            (error "Missing required parameter: ~A for tool ~A"
                   param-name tool-name)))))

    t))

;;; ============================================================
;;; 状态管理协议
;;; ============================================================

(defgeneric enable-provider (provider)
  (:documentation "启用提供者

参数:
  PROVIDER - 提供者实例

返回:
  provider"))

(defmethod enable-provider ((provider tool-provider))
  "启用提供者（默认实现）"
  (setf (provider-enabled-p provider) t)
  provider)

(defgeneric disable-provider (provider)
  (:documentation "禁用提供者

参数:
  PROVIDER - 提供者实例

返回:
  provider"))

(defmethod disable-provider ((provider tool-provider))
  "禁用提供者（默认实现）"
  (setf (provider-enabled-p provider) nil)
  provider)

;;; ============================================================
;;; 辅助函数
;;; ============================================================

(defun make-simple-tool (name description handler &key parameters category permissions tags metadata)
  "创建简单工具的辅助函数

参数:
  NAME        - 工具名称（关键字）
  DESCRIPTION - 工具描述
  HANDLER     - 处理函数
  PARAMETERS  - 参数定义（可选）
  CATEGORY    - 分类（可选，默认 :custom）
  PERMISSIONS - 权限列表（可选）
  TAGS        - 标签列表（可选，用于过滤和分组）
  METADATA    - 元数据（可选）

返回:
  tool 实例

示例:
  (make-simple-tool :calculator
                    \"Simple calculator\"
                    (lambda (&key expression)
                      (eval (read-from-string expression)))
                    :parameters '((:expression :type string :required t))
                    :category :custom
                    :tags '(:math :utility))"
  (make-instance 'tool
    :name name
    :description description
    :handler handler
    :parameters parameters
    :category (or category :custom)
    :permissions permissions
    :tags tags
    :metadata metadata))

(defun provider-tool-count (provider)
  "获取提供者中的工具数量

参数:
  PROVIDER - 提供者实例

返回:
  工具数量（整数）"
  (hash-table-count (provider-tools provider)))

(defun provider-tool-names (provider)
  "获取提供者中所有工具的名称列表

参数:
  PROVIDER - 提供者实例

返回:
  工具名称列表（关键字列表）"
  (let ((names nil))
    (maphash (lambda (name tool)
               (declare (ignore tool))
               (push name names))
             (provider-tools provider))
    (nreverse names)))

;;; ============================================================
;;; Tag 相关函数
;;; ============================================================

(defun tool-has-tag-p (tool tag)
  "检查工具是否具有指定标签

参数:
  TOOL - 工具实例
  TAG  - 标签（关键字）

返回:
  T 如果工具具有该标签，NIL 否则"
  (member tag (tool-tags tool) :test #'eq))

(defun tool-has-any-tag-p (tool tags)
  "检查工具是否具有任一指定标签

参数:
  TOOL - 工具实例
  TAGS - 标签列表

返回:
  T 如果工具具有任一标签，NIL 否则"
  (some (lambda (tag) (tool-has-tag-p tool tag)) tags))

(defun tool-has-all-tags-p (tool tags)
  "检查工具是否具有所有指定标签

参数:
  TOOL - 工具实例
  TAGS - 标签列表

返回:
  T 如果工具具有所有标签，NIL 否则"
  (every (lambda (tag) (tool-has-tag-p tool tag)) tags))

(defun tool-add-tag (tool tag)
  "为工具添加标签

参数:
  TOOL - 工具实例
  TAG  - 标签（关键字）

返回:
  工具实例"
  (pushnew tag (tool-tags tool) :test #'eq)
  tool)

(defun tool-remove-tag (tool tag)
  "从工具移除标签

参数:
  TOOL - 工具实例
  TAG  - 标签（关键字）

返回:
  工具实例"
  (setf (tool-tags tool) (remove tag (tool-tags tool) :test #'eq))
  tool)

(defun tool-set-tags (tool tags)
  "设置工具的标签列表

参数:
  TOOL - 工具实例
  TAGS - 标签列表

返回:
  工具实例"
  (setf (tool-tags tool) (copy-list tags))
  tool)
