;;;; function.lisp
;;;; CL-Agent Core Kernel - Tool Function（Symbol Plist 方案）
;;;;
;;;; 概述：
;;;;   工具函数的元数据附加在符号属性表上，类似 Clojure 的 var metadata。
;;;;   函数就是 defun，元数据通过 symbol plist 读取。
;;;;
;;;; Symbol Plist 约定：
;;;;   :kernel-function → T               ;; 标记为工具函数
;;;;   :description     → "描述字符串"     ;; LLM 用描述
;;;;   :parameters      → ((name type desc &key required-p default) ...)
;;;;   :category        → :general        ;; 分类
;;;;   :sensitive       → NIL             ;; 是否敏感
;;;;   :tool-name       → :GET-WEATHER    ;; keyword 名称（用于 LLM）

(in-package #:cl-agent.kernel)

;;; ============================================================
;;; 运行时注册 API
;;; ============================================================

(defun declare-tool (name &key description parameters category sensitive)
  "运行时注册工具元信息（无宏替代）

参数:
  NAME        - 工具符号
  DESCRIPTION - 函数描述
  PARAMETERS  - 参数规格列表
  CATEGORY    - 分类（默认 :general）
  SENSITIVE   - 是否敏感操作

返回:
  NAME 符号"
  (setf (get name :kernel-function) t
        (get name :description) description
        (get name :parameters) parameters
        (get name :tool-name) (intern (symbol-name name) :keyword)
        (get name :category) (or category :general)
        (get name :sensitive) sensitive)
  name)

;;; ============================================================
;;; 查询 API
;;; ============================================================

(defun tool-function-p (symbol)
  "检查符号是否标注为 kernel-function"
  (get symbol :kernel-function))

(defun tool-description (symbol)
  "获取工具描述"
  (get symbol :description))

(defun tool-parameters (symbol)
  "获取工具参数规格"
  (get symbol :parameters))

(defun tool-name (symbol)
  "获取工具的 keyword 名称"
  (get symbol :tool-name))

(defun tool-schema (symbol)
  "获取工具的 JSON Schema（hash-table 格式）"
  (schema-to-hash-table
   (params->json-schema (get symbol :parameters))))

;;; ============================================================
;;; 参数验证
;;; ============================================================

(defun validate-tool-args (tool-sym args)
  "验证工具参数（必需参数检查）

参数:
  TOOL-SYM - 工具符号
  ARGS     - 参数 plist

返回:
  T 如果验证通过

错误:
  如果必需参数缺失，抛出错误"
  (dolist (param-spec (get tool-sym :parameters))
    (destructuring-bind (pname ptype pdesc &key required-p default) param-spec
      (declare (ignore ptype pdesc default))
      (let ((param-key (if (keywordp pname)
                           pname
                           (intern (string-upcase (symbol-name pname)) :keyword))))
        (when (and required-p
                   (eq (getf args param-key :--missing--) :--missing--))
          (error "Missing required parameter: ~A for function ~A"
                 pname tool-sym)))))
  t)

;;; ============================================================
;;; Schema 生成工具
;;; ============================================================

(defun type-to-json-type (type-keyword)
  "将 Lisp 类型关键字转换为 JSON Schema 类型字符串

参数:
  TYPE-KEYWORD - :string, :int, :float, :bool, :array, :object

返回:
  JSON 类型字符串"
  (case type-keyword
    (:string "string")
    (:int "integer")
    (:integer "integer")
    (:float "number")
    (:number "number")
    (:bool "boolean")
    (:boolean "boolean")
    (:array "array")
    (:object "object")
    (otherwise "string")))

(defun params->json-schema (parameters)
  "将参数规格列表转换为 JSON Schema

参数:
  PARAMETERS - 参数规格列表
    格式: ((name type description &key required-p default) ...)

返回:
  JSON Schema plist:
  (:type \"object\"
   :properties ((:name (:type \"string\" :description \"...\")) ...)
   :required (\"name1\" \"name2\"))"
  (if (null parameters)
      (list :type "object" :properties nil :required nil)
      (let ((properties nil)
            (required nil))
        (dolist (param-spec parameters)
          (destructuring-bind (param-name param-type param-desc &key required-p default) param-spec
            (declare (ignore default))
            (let ((name-str (string-downcase (symbol-name param-name))))
              (push (list name-str
                          (list :type (type-to-json-type param-type)
                                :description param-desc))
                    properties)
              (when required-p
                (push name-str required)))))
        (list :type "object"
              :properties (nreverse properties)
              :required (nreverse required)))))

(defun schema-to-hash-table (schema)
  "将 params->json-schema 返回的 plist 结构转换为嵌套 hash-table

参数:
  SCHEMA - params->json-schema 返回的 plist

返回:
  嵌套 hash-table，可被 jzon 正确序列化为 JSON object"
  (when (null schema)
    (return-from schema-to-hash-table
      (let ((ht (make-hash-table :test 'equal)))
        (setf (gethash "type" ht) "object")
        (setf (gethash "properties" ht) (make-hash-table :test 'equal))
        (setf (gethash "required" ht) #())
        ht)))
  (let ((ht (make-hash-table :test 'equal))
        (type-val (getf schema :type))
        (properties (getf schema :properties))
        (required (getf schema :required)))
    ;; type
    (setf (gethash "type" ht) (or type-val "object"))
    ;; properties → hash-table of hash-tables
    (let ((props-ht (make-hash-table :test 'equal)))
      (dolist (prop properties)
        (destructuring-bind (name value-plist) prop
          (let ((prop-ht (make-hash-table :test 'equal)))
            (loop for (k v) on value-plist by #'cddr
                  do (setf (gethash (string-downcase (symbol-name k)) prop-ht) v))
            (setf (gethash name props-ht) prop-ht))))
      (setf (gethash "properties" ht) props-ht))
    ;; required → vector (JSON array)
    (setf (gethash "required" ht)
          (if required
              (coerce required 'vector)
              #()))
    ht))
