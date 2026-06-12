;;;; tool-registry.lisp
;;;; CL-Agent Kernel - 原生工具注册表（CLOS）
;;;;
;;;; 概述：
;;;;   Kernel 内置的最小工具系统（对齐 clj-agent：工具是 core 的一部分，
;;;;   不是独立模块）。取代原 cl-agent-tools 子系统中 Kernel 实际依赖的
;;;;   最小集合：
;;;;
;;;;   - tool 类：name / description / handler / parameters / tags
;;;;   - tool-registry：线程安全注册表（注册/查找/标签过滤）
;;;;   - validate-arguments：参数校验（必填、类型、默认值）
;;;;   - tool-to-json-schema：LLM 函数调用 schema
;;;;
;;;;   参数规格格式：((name :type TYPE :required BOOL
;;;;                       :description DESC :default V) ...)
;;;;
;;;;   注意：tool-name / tool-description / tool-parameters 是泛型函数，
;;;;   同时支持 tool 实例与 symbol-plist 工具（见 function.lisp）。

(in-package #:cl-agent.kernel)

;;; ============================================================
;;; Tool 类
;;; ============================================================

(defclass tool ()
  ((name
    :initarg :name
    :type keyword
    :documentation "工具名称（关键字）")
   (description
    :initarg :description
    :initform ""
    :documentation "工具描述")
   (handler
    :initarg :handler
    :documentation "工具执行函数（&key 参数）")
   (parameters
    :initarg :parameters
    :initform nil
    :documentation "参数规格列表
格式: ((name :type TYPE :required BOOL :description DESC) ...)")
   (category
    :initarg :category
    :initform :general
    :type keyword
    :documentation "工具分类")
   (tags
    :initarg :tags
    :initform nil
    :type list
    :documentation "工具标签列表（关键字，用于过滤和分组）")
   (metadata
    :initarg :metadata
    :initform nil
    :documentation "额外元数据（plist）"))
  (:documentation "Kernel 原生工具定义"))

;; 访问器以 defmethod 形式挂到 function.lisp 定义的泛型函数上
;; （泛型同时支持 symbol-plist 工具）

(defmethod tool-name ((tool tool))
  (slot-value tool 'name))

(defmethod tool-description ((tool tool))
  (slot-value tool 'description))

(defmethod tool-parameters ((tool tool))
  (slot-value tool 'parameters))

(defgeneric tool-handler (tool)
  (:documentation "获取工具执行函数"))

(defmethod tool-handler ((tool tool))
  (slot-value tool 'handler))

(defmethod tool-handler ((sym symbol))
  "symbol-plist 工具：函数本身"
  (symbol-function sym))

(defgeneric tool-tags (tool)
  (:documentation "获取工具标签列表"))

(defmethod tool-tags ((tool tool))
  (slot-value tool 'tags))

(defmethod tool-tags ((sym symbol))
  (get sym :tags))

(defgeneric tool-category (tool)
  (:documentation "获取工具分类"))

(defmethod tool-category ((tool tool))
  (slot-value tool 'category))

(defmethod tool-category ((sym symbol))
  (or (get sym :category) :general))

(defun make-tool (&key name description handler parameters
                       (category :general) tags metadata)
  "创建工具实例

参数：
  NAME        - 工具名称（关键字或符号）
  DESCRIPTION - 工具描述
  HANDLER     - 执行函数（接收 &key 参数）
  PARAMETERS  - 参数规格 ((name :type T :required B :description D) ...)
  CATEGORY    - 分类（默认 :general）
  TAGS        - 标签列表
  METADATA    - 元数据 plist

返回：
  tool 实例"
  (make-instance 'tool
                 :name (if (keywordp name)
                           name
                           (intern (string-upcase (string name)) :keyword))
                 :description (or description "")
                 :handler handler
                 :parameters parameters
                 :category category
                 :tags tags
                 :metadata metadata))

(defun tool-instance-p (obj)
  "检查是否为 tool 实例"
  (typep obj 'tool))

(defun tool-add-tag (tool tag)
  "为工具添加标签"
  (pushnew tag (slot-value tool 'tags))
  tool)

(defun tool-has-tag-p (tool tag)
  "检查工具是否具有指定标签"
  (member tag (tool-tags tool)))

(defun tool-has-any-tag-p (tool tags)
  "检查工具是否具有任一指定标签"
  (some (lambda (tag) (tool-has-tag-p tool tag)) tags))

(defun tool-has-all-tags-p (tool tags)
  "检查工具是否具有所有指定标签"
  (every (lambda (tag) (tool-has-tag-p tool tag)) tags))

(defmethod print-object ((tool tool) stream)
  (print-unreadable-object (tool stream :type t)
    (format stream "~A~@[ tags=~A~]"
            (tool-name tool)
            (tool-tags tool))))

;;; ============================================================
;;; 参数校验
;;; ============================================================

(defun arguments-to-plist (arguments)
  "将参数统一转换为关键字 plist（接受 plist / hash-table / nil）"
  (cond
    ((null arguments) nil)
    ((hash-table-p arguments)
     (let ((result nil))
       (maphash (lambda (k v)
                  (push v result)
                  (push (if (keywordp k)
                            k
                            (intern (string-upcase (string k)) :keyword))
                        result))
                arguments)
       result))
    ((listp arguments) arguments)
    (t nil)))

(defun validate-argument-type (name value expected-type)
  "校验参数类型，返回错误消息或 NIL"
  (let ((valid-p
          (case expected-type
            ((:any t nil) t)
            (:string (stringp value))
            (:number (numberp value))
            ((:integer :int) (integerp value))
            ((:boolean :bool) (or (eq value t) (eq value nil)
                                  (equal value "true") (equal value "false")))
            ((:array :list) (listp value))
            ((:object :hash-table :plist)
             (or (hash-table-p value)
                 (and (listp value)
                      (or (null value) (keywordp (first value))))))
            (:function (functionp value))
            (otherwise t))))
    (unless valid-p
      (format nil "Argument ~A: expected ~A, got ~S"
              name expected-type value))))

(defun find-parameter-spec (key param-specs)
  "在参数规格中查找指定参数"
  (find key param-specs
        :key (lambda (spec)
               (let ((name (first spec)))
                 (if (keywordp name)
                     name
                     (intern (string-upcase (string name)) :keyword))))))

(defun validate-arguments (tool arguments)
  "校验工具参数

返回：
  (values validated-arguments errors)
  - validated-arguments: 校验并补全默认值后的参数 plist
  - errors: 错误消息列表（无错误为 NIL）"
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
        (cond
          ;; 参数已提供：类型校验
          ((not (eq provided-value :not-provided))
           (let ((type-error (validate-argument-type param-key provided-value param-type)))
             (if type-error
                 (push type-error errors)
                 (progn
                   (push param-key validated-args)
                   (push provided-value validated-args)))))
          ;; 未提供但有默认值
          (default-value
           (push param-key validated-args)
           (push default-value validated-args))
          ;; 必填未提供
          (required-p
           (push (format nil "Missing required argument: ~A" param-key) errors)))))
    ;; 保留规格外的额外参数
    (loop for (key value) on args-plist by #'cddr
          unless (find-parameter-spec key param-specs)
            do (progn
                 (push key validated-args)
                 (push value validated-args)))
    (values (nreverse validated-args) (nreverse errors))))

;;; ============================================================
;;; JSON Schema
;;; ============================================================

(defun parameter-to-json-schema (param)
  "将参数规格 (name . props) 转换为 JSON Schema hash-table"
  (let ((type-str (case (getf (cdr param) :type)
                    (:string "string")
                    (:number "number")
                    ((:integer :int) "integer")
                    ((:boolean :bool) "boolean")
                    ((:array :list) "array")
                    (:object "object")
                    (otherwise "string")))
        (ht (make-hash-table :test 'equal)))
    (setf (gethash "type" ht) type-str)
    (setf (gethash "description" ht) (or (getf (cdr param) :description) ""))
    ht))

(defun tool-to-json-schema (tool)
  "将工具转换为 JSON Schema plist（用于 LLM 函数调用）"
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
     ,(mapcar (lambda (param)
                (string-downcase (string (first param))))
              (remove-if-not (lambda (p)
                               (or (getf (cdr p) :required)
                                   (getf (cdr p) :required-p)))
                             (tool-parameters tool))))))

;;; ============================================================
;;; Tool Registry（线程安全）
;;; ============================================================

(defclass tool-registry ()
  ((tools
    :initform (make-hash-table :test #'eq)
    :reader registry-tools
    :documentation "工具表（keyword -> tool）")
   (lock
    :initform (bt:make-lock "tool-registry-lock")
    :reader registry-lock))
  (:documentation "Kernel 原生工具注册表"))

(defun make-tool-registry ()
  "创建工具注册表"
  (make-instance 'tool-registry))

(defgeneric register-tool (registry tool)
  (:documentation "注册工具。返回工具实例。"))

(defmethod register-tool ((registry tool-registry) (tool tool))
  (bt:with-lock-held ((registry-lock registry))
    (setf (gethash (tool-name tool) (registry-tools registry)) tool))
  tool)

(defgeneric unregister-tool (registry tool-name)
  (:documentation "注销工具。返回 T 表示有移除。"))

(defmethod unregister-tool ((registry tool-registry) tool-name)
  (bt:with-lock-held ((registry-lock registry))
    (remhash tool-name (registry-tools registry))))

(defgeneric find-tool (registry tool-name)
  (:documentation "查找工具（keyword 名）。未找到返回 NIL。"))

(defmethod find-tool ((registry tool-registry) tool-name)
  (bt:with-lock-held ((registry-lock registry))
    (gethash tool-name (registry-tools registry))))

(defgeneric list-tools (registry &key category)
  (:documentation "列出所有工具（可按分类过滤）"))

(defmethod list-tools ((registry tool-registry) &key category)
  (bt:with-lock-held ((registry-lock registry))
    (let ((tools nil))
      (maphash (lambda (name tool)
                 (declare (ignore name))
                 (when (or (null category)
                           (eq category (tool-category tool)))
                   (push tool tools)))
               (registry-tools registry))
      (nreverse tools))))

(defun registry-tool-count (registry)
  "工具总数"
  (bt:with-lock-held ((registry-lock registry))
    (hash-table-count (registry-tools registry))))

(defun invalidate-cache (registry)
  "缓存失效（原生注册表无缓存，保留为 no-op 兼容入口）"
  (declare (ignore registry))
  nil)

;;; ------------------------------------------------------------
;;; 标签过滤
;;; ------------------------------------------------------------

(defun list-tools-by-tags (registry tags &key (mode :any))
  "按标签过滤工具

参数:
  TAGS - 标签列表（nil 表示不过滤）
  MODE - :any（任一标签匹配，默认）或 :all（全部匹配）"
  (if (null tags)
      (list-tools registry)
      (let ((matcher (case mode
                       (:all #'tool-has-all-tags-p)
                       (otherwise #'tool-has-any-tag-p))))
        (remove-if-not (lambda (tool) (funcall matcher tool tags))
                       (list-tools registry)))))

(defun get-tools-schema-by-tags (registry tags &key (mode :any))
  "获取按标签过滤后的工具 Schema 列表"
  (mapcar #'tool-to-json-schema
          (list-tools-by-tags registry tags :mode mode)))

(defun list-all-tags (registry)
  "列出注册表中出现过的所有标签"
  (let ((tags nil))
    (dolist (tool (list-tools registry))
      (dolist (tag (tool-tags tool))
        (pushnew tag tags)))
    tags))
