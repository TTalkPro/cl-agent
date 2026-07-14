;;;; json-schema.lisp
;;;; CL-Agent Core - JSON Schema 生成工具
;;;;
;;;; 概述：
;;;;   把工具参数规格转换为 LLM 函数调用所需的 JSON Schema。
;;;;   供 cl-agent.chat（工具体系）与 cl-agent.llm（provider 序列化）共用。
;;;;
;;;;   参数规格格式：
;;;;     ((name type description &key required-p default) ...)

(in-package #:cl-agent.core)

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
  SCHEMA - params->json-schema 返回的 plist（:properties 可以是 list 或 hash-table）

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
    (let ((props-ht
            (cond
              ;; 已经是 hash-table
              ((hash-table-p properties) properties)
              ;; list 格式（来自 params->json-schema）
              ((listp properties)
               (let ((props (make-hash-table :test 'equal)))
                 (dolist (prop properties)
                   (destructuring-bind (name value-plist) prop
                     (let ((prop-ht (make-hash-table :test 'equal)))
                       (loop for (k v) on value-plist by #'cddr
                             do (setf (gethash (string-downcase (symbol-name k)) prop-ht) v))
                       (setf (gethash name props) prop-ht))))
                 props))
              ;; 空
              (t (make-hash-table :test 'equal)))))
      (setf (gethash "properties" ht) props-ht))
    ;; required → vector (JSON array)
    (setf (gethash "required" ht)
          (cond
            ((vectorp required) required)
            ((listp required) (coerce required 'vector))
            (t #())))
    ht))
