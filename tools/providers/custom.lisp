;;;; custom.lisp
;;;; CL-Agent - Custom Tool Provider
;;;;
;;;; 概述：
;;;;   自定义工具提供者，允许用户定义和注册自己的工具
;;;;
;;;; 特性：
;;;;   - 简单的工具注册接口
;;;;   - 支持 lambda 和命名函数
;;;;   - 工具参数验证
;;;;   - 工具元数据管理
;;;;   - 运行时动态添加工具

(in-package #:cl-agent.tools)

;;; ============================================================
;;; Custom Tool Provider 类
;;; ============================================================

(defclass custom-tool-provider (tool-provider)
  ((auto-validate
    :initarg :auto-validate
    :accessor custom-auto-validate-p
    :initform t
    :type boolean
    :documentation "是否自动验证工具参数")

   (allow-overwrite
    :initarg :allow-overwrite
    :accessor custom-allow-overwrite-p
    :initform nil
    :type boolean
    :documentation "是否允许覆盖已存在的工具"))

  (:documentation "自定义工具提供者，允许用户动态注册自己的工具"))

;;; ============================================================
;;; 构造函数
;;; ============================================================

(defun make-custom-provider (&key
                               (name "custom")
                               (auto-validate t)
                               (allow-overwrite nil))
  "创建自定义工具提供者实例

  参数：
    NAME            - 提供者名称
    AUTO-VALIDATE   - 是否自动验证工具参数（默认启用）
    ALLOW-OVERWRITE - 是否允许覆盖已存在的工具（默认禁用）

  返回：
    custom-tool-provider 实例

  示例：
    (make-custom-provider :name \"my-tools\")"
  (make-instance 'custom-tool-provider
                 :name name
                 :auto-validate auto-validate
                 :allow-overwrite allow-overwrite))

;;; ============================================================
;;; Provider 初始化
;;; ============================================================

(defmethod initialize-provider ((provider custom-tool-provider))
  "初始化自定义工具提供者

  自定义提供者默认为空，用户需要手动添加工具"
  ;; 调用父类初始化
  (call-next-method)

  ;; 自定义提供者初始化时不注册任何工具
  ;; 用户需要使用 define-custom-tool 添加工具

  ;; 返回提供者
  provider)

;;; ============================================================
;;; 自定义工具定义
;;; ============================================================

(defun define-custom-tool (provider name description handler
                           &key
                             parameters
                             (category :custom)
                             permissions
                             metadata)
  "定义并注册自定义工具

  参数：
    PROVIDER    - custom-tool-provider 实例（必需）
    NAME        - 工具名称（关键字）（必需）
    DESCRIPTION - 工具描述（必需）
    HANDLER     - 工具处理函数（必需）
    PARAMETERS  - 参数定义列表（可选）
    CATEGORY    - 工具分类（默认 :custom）
    PERMISSIONS - 所需权限列表（可选）
    METADATA    - 额外元数据（可选）

  返回：
    注册的工具实例

  示例：
    (define-custom-tool *provider* :calculator
      \"Simple calculator\"
      (lambda (&key expression)
        (eval (read-from-string expression)))
      :parameters '((:expression :type string :required t))
      :category :utility)"
  (unless (typep provider 'custom-tool-provider)
    (error "PROVIDER must be a custom-tool-provider instance"))

  (unless (keywordp name)
    (error "NAME must be a keyword, got: ~A" name))

  (unless (stringp description)
    (error "DESCRIPTION must be a string, got: ~A" description))

  (unless (functionp handler)
    (error "HANDLER must be a function, got: ~A" handler))

  ;; 检查工具是否已存在
  (when (and (not (custom-allow-overwrite-p provider))
             (find-tool provider name))
    (error "Tool ~A already exists in provider ~A. Set :allow-overwrite t to overwrite."
           name (provider-name provider)))

  ;; 验证参数定义
  (when (and (custom-auto-validate-p provider) parameters)
    (validate-parameter-definition parameters))

  ;; 创建工具实例
  (let ((tool (make-simple-tool name description handler
                                :parameters parameters
                                :category category
                                :permissions permissions
                                :metadata metadata)))
    ;; 注册到提供者
    (register-tool provider tool)

    ;; 返回工具
    tool))

;;; ============================================================
;;; 批量工具定义
;;; ============================================================

(defmacro define-custom-tools (provider &body tool-definitions)
  "批量定义自定义工具（宏）

  参数：
    PROVIDER         - custom-tool-provider 实例
    TOOL-DEFINITIONS - 工具定义列表

  工具定义格式：
    (name description handler &key parameters category permissions metadata)

  示例：
    (define-custom-tools *provider*
      (:calculator
       \"Simple calculator\"
       (lambda (&key expression) (eval (read-from-string expression)))
       :parameters '((:expression :type string :required t)))

      (:greeter
       \"Greet user\"
       (lambda (&key name) (format nil \"Hello, ~A!\" name))
       :parameters '((:name :type string :required t))))"
  `(progn
     ,@(loop for def in tool-definitions
             collect `(define-custom-tool ,provider ,@def))))

;;; ============================================================
;;; 快速工具定义（简化接口）
;;; ============================================================

(defun add-simple-tool (provider name description handler)
  "添加简单工具（无参数验证）

  参数：
    PROVIDER    - custom-tool-provider 实例
    NAME        - 工具名称（关键字）
    DESCRIPTION - 工具描述
    HANDLER     - 工具处理函数

  返回：
    注册的工具实例

  示例：
    (add-simple-tool *provider* :echo
      \"Echo input\"
      (lambda (&key text) text))"
  (define-custom-tool provider name description handler
                      :parameters nil
                      :category :custom))

(defun add-lambda-tool (provider name description lambda-expr)
  "添加 lambda 工具（接受 lambda 表达式）

  参数：
    PROVIDER    - custom-tool-provider 实例
    NAME        - 工具名称（关键字）
    DESCRIPTION - 工具描述
    LAMBDA-EXPR - Lambda 表达式

  返回：
    注册的工具实例

  示例：
    (add-lambda-tool *provider* :reverse
      \"Reverse string\"
      (lambda (&key text) (reverse text)))"
  (add-simple-tool provider name description lambda-expr))

;;; ============================================================
;;; 工具移除
;;; ============================================================

(defun remove-custom-tool (provider name)
  "从自定义提供者中移除工具

  参数：
    PROVIDER - custom-tool-provider 实例
    NAME     - 工具名称（关键字）

  返回：
    T 如果成功移除，NIL 如果工具不存在

  示例：
    (remove-custom-tool *provider* :calculator)"
  (unless (typep provider 'custom-tool-provider)
    (error "PROVIDER must be a custom-tool-provider instance"))

  (unregister-tool provider name))

;;; ============================================================
;;; 参数验证辅助
;;; ============================================================

(defun validate-parameter-definition (parameters)
  "验证参数定义的格式

  参数：
    PARAMETERS - 参数定义列表

  参数定义格式：
    ((:param-name :type type :required boolean :default value) ...)

  抛出错误如果格式不正确"
  (unless (listp parameters)
    (error "PARAMETERS must be a list"))

  (dolist (param parameters)
    (unless (listp param)
      (error "Each parameter definition must be a list, got: ~A" param))

    (let ((name (first param)))
      (unless (keywordp name)
        (error "Parameter name must be a keyword, got: ~A" name)))

    ;; 验证 plist 格式
    (let ((plist (rest param)))
      (loop for (key value) on plist by #'cddr
            do (unless (keywordp key)
                 (error "Parameter property key must be a keyword, got: ~A" key))))))

;;; ============================================================
;;; 工具查询
;;; ============================================================

(defun list-custom-tools (provider)
  "列出自定义提供者中的所有工具

  参数：
    PROVIDER - custom-tool-provider 实例

  返回：
    工具名称列表（关键字列表）

  示例：
    (list-custom-tools *provider*)
    => (:calculator :greeter :echo)"
  (unless (typep provider 'custom-tool-provider)
    (error "PROVIDER must be a custom-tool-provider instance"))

  (list-tools provider))

(defun has-custom-tool-p (provider name)
  "检查自定义提供者是否包含指定工具

  参数：
    PROVIDER - custom-tool-provider 实例
    NAME     - 工具名称（关键字）

  返回：
    T 如果工具存在，NIL 否则

  示例：
    (has-custom-tool-p *provider* :calculator)
    => T"
  (unless (typep provider 'custom-tool-provider)
    (error "PROVIDER must be a custom-tool-provider instance"))

  (not (null (find-tool provider name))))

(defun get-custom-tool (provider name)
  "获取自定义工具实例

  参数：
    PROVIDER - custom-tool-provider 实例
    NAME     - 工具名称（关键字）

  返回：
    工具实例，或 NIL 如果不存在

  示例：
    (get-custom-tool *provider* :calculator)
    => #<TOOL :CALCULATOR>"
  (unless (typep provider 'custom-tool-provider)
    (error "PROVIDER must be a custom-tool-provider instance"))

  (find-tool provider name))

;;; ============================================================
;;; 便利函数
;;; ============================================================

(defun make-default-custom-provider ()
  "创建默认配置的自定义工具提供者

  返回：
    已初始化的 custom-tool-provider 实例

  示例：
    (defparameter *custom* (make-default-custom-provider))

    (define-custom-tool *custom* :my-tool
      \"My custom tool\"
      (lambda (&key input) (format nil \"Processing: ~A\" input)))"
  (let ((provider (make-custom-provider)))
    (initialize-provider provider)
    provider))

;;; ============================================================
;;; 工具定义宏（简化版）
;;; ============================================================

(defmacro with-custom-provider ((var &key name auto-validate allow-overwrite) &body body)
  "创建临时自定义提供者并在其上下文中执行代码

  参数：
    VAR             - 提供者变量名
    NAME            - 提供者名称（可选）
    AUTO-VALIDATE   - 是否自动验证（可选）
    ALLOW-OVERWRITE - 是否允许覆盖（可选）
    BODY            - 要执行的代码

  示例：
    (with-custom-provider (*provider* :name \"my-tools\")
      (define-custom-tool *provider* :tool1 \"Tool 1\" #'fn1)
      (define-custom-tool *provider* :tool2 \"Tool 2\" #'fn2)
      ;; 使用提供者
      (execute-tool *provider* :tool1))"
  `(let ((,var (make-custom-provider
                ,@(when name `(:name ,name))
                ,@(when auto-validate `(:auto-validate ,auto-validate))
                ,@(when allow-overwrite `(:allow-overwrite ,allow-overwrite)))))
     (initialize-provider ,var)
     ,@body))

;;; ============================================================
;;; 函数工具转换器
;;; ============================================================

(defun function-to-tool (provider name description function
                         &key parameters category permissions)
  "将普通函数转换为工具并注册

  参数：
    PROVIDER    - custom-tool-provider 实例
    NAME        - 工具名称（关键字）
    DESCRIPTION - 工具描述
    FUNCTION    - 函数（可以是 symbol 或 function）
    PARAMETERS  - 参数定义（可选）
    CATEGORY    - 分类（可选）
    PERMISSIONS - 权限（可选）

  返回：
    注册的工具实例

  示例：
    (defun my-calculator (&key expression)
      (eval (read-from-string expression)))

    (function-to-tool *provider* :calc \"Calculator\" #'my-calculator
      :parameters '((:expression :type string :required t)))"
  (let ((fn (if (symbolp function)
                (symbol-function function)
                function)))
    (define-custom-tool provider name description fn
                        :parameters parameters
                        :category (or category :custom)
                        :permissions permissions)))

;;; ============================================================
;;; 便利宏：快速定义工具
;;; ============================================================

(defmacro deftool (provider name description lambda-list &body body)
  "定义并注册自定义工具（简化宏）

  参数：
    PROVIDER     - custom-tool-provider 实例
    NAME         - 工具名称（关键字）
    DESCRIPTION  - 工具描述
    LAMBDA-LIST  - 参数列表（关键字参数）
    BODY         - 工具实现代码

  示例：
    (deftool *provider* :calculator \"Simple calculator\" (&key expression)
      (eval (read-from-string expression)))

  等价于：
    (define-custom-tool *provider* :calculator \"Simple calculator\"
      (lambda (&key expression)
        (eval (read-from-string expression))))"
  `(define-custom-tool ,provider ,name ,description
       (lambda ,lambda-list ,@body)))

;;; ============================================================
;;; 导出符号
;;; ============================================================

(export '(;; 类和构造
          custom-tool-provider
          make-custom-provider
          make-default-custom-provider
          custom-auto-validate-p
          custom-allow-overwrite-p

          ;; 工具定义
          define-custom-tool
          define-custom-tools
          add-simple-tool
          add-lambda-tool
          deftool

          ;; 工具管理
          remove-custom-tool
          list-custom-tools
          has-custom-tool-p
          get-custom-tool

          ;; 辅助功能
          validate-parameter-definition
          function-to-tool
          with-custom-provider))
