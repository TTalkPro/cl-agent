;;;; json-schema.lisp
;;;; CL-Agent Core - JSON Schema 生成与校验工具
;;;;
;;;; 概述：
;;;;   1. 生成：把工具参数规格转换为 LLM 函数调用所需的 JSON Schema。
;;;;      供 cl-agent.chat（工具体系）与 cl-agent.llm（provider 序列化）共用。
;;;;
;;;;      参数规格格式：
;;;;        ((name type description &key required-p default) ...)
;;;;
;;;;   2. 校验：validate-json-schema 校验 JSON 值是否符合 schema。
;;;;      供 cl-agent.client 的 structured-output-validation-advisor
;;;;      （对标 Spring AI 2.0 StructuredOutputValidationAdvisor）使用。

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

;;; ============================================================
;;; JSON Schema 校验
;;; ============================================================
;;;
;;; 值表示遵循 jzon 的解析结果（json-parse 的返回）：
;;;   object → hash-table(equal)   array → simple-vector   string → string
;;;   true → T   false → NIL   null → 符号 NULL
;;;
;;; 两个易错点：
;;;   - JSON false 与「字段缺失」在 gethash 下都是 NIL，
;;;     判断字段是否存在必须用第二返回值。
;;;   - CL 中字符串也是 vector，判定 array 需排除字符串。
;;;
;;; 支持的关键字（面向 LLM 结构化输出的实用子集）：
;;;   type / enum / const
;;;   required / properties / additionalProperties
;;;   items / minItems / maxItems / uniqueItems
;;;   minimum / maximum / exclusiveMinimum / exclusiveMaximum / multipleOf
;;;   minLength / maxLength / pattern
;;;   allOf / anyOf / oneOf / not

(defun json-null-p (value)
  "VALUE 是否为 JSON null（jzon 用符号 NULL 表示，注意区别于 false 的 NIL）"
  (eq value 'null))

(defun json-array-p (value)
  "VALUE 是否为 JSON array（CL 中字符串也是 vector，需排除）"
  (and (vectorp value) (not (stringp value))))

(defun json-boolean-p (value)
  "VALUE 是否为 JSON boolean（true → T，false → NIL）"
  (or (eq value t) (eq value nil)))

(defun json-type-name (value)
  "VALUE 的 JSON 类型名（用于错误消息）"
  (cond ((json-null-p value) "null")
        ((json-boolean-p value) "boolean")
        ((stringp value) "string")
        ((integerp value) "integer")
        ((realp value) "number")
        ((json-array-p value) "array")
        ((hash-table-p value) "object")
        (t (string-downcase (princ-to-string (type-of value))))))

(defun json-type-match-p (value type-name)
  "VALUE 是否属于 JSON Schema 的 TYPE-NAME 类型。
TYPE-NAME 非字符串（schema 本身有瑕疵）时不施加约束。"
  (cond
    ((not (stringp type-name)) t)
    ((string= type-name "object") (hash-table-p value))
    ((string= type-name "array") (json-array-p value))
    ((string= type-name "string") (stringp value))
    ;; JSON Schema 规定 1.0 这类零小数部分的数也算 integer
    ((string= type-name "integer")
     (and (realp value)
          (or (integerp value) (= value (fround value)))))
    ((string= type-name "number") (realp value))
    ((string= type-name "boolean") (json-boolean-p value))
    ((string= type-name "null") (json-null-p value))
    ;; 未知类型名：不做限制
    (t t)))

(defun json-equal (a b)
  "JSON 值深度相等（用于 enum / const / uniqueItems）"
  (cond
    ((and (stringp a) (stringp b)) (string= a b))
    ((and (realp a) (realp b)) (= a b))
    ((and (json-array-p a) (json-array-p b))
     (and (= (length a) (length b))
          (every #'json-equal a b)))
    ((and (hash-table-p a) (hash-table-p b))
     (and (= (hash-table-count a) (hash-table-count b))
          (block compare
            (maphash (lambda (key value)
                       (multiple-value-bind (other found) (gethash key b)
                         (unless (and found (json-equal value other))
                           (return-from compare nil))))
                     a)
            t)))
    (t (eql a b))))

(defun ensure-json-schema (schema)
  "把 SCHEMA 归一化为 hash-table 形式。

接受：
  hash-table - 原样返回（json-parse 出来的 schema）
  字符串     - 按 JSON 解析
  list       - params->json-schema 的 plist 输出，转 hash-table"
  (etypecase schema
    (hash-table schema)
    (string (let ((parsed (json-parse schema)))
              (unless (hash-table-p parsed)
                (error "JSON Schema 必须是 JSON object，实际为 ~A"
                       (json-type-name parsed)))
              parsed))
    (list (schema-to-hash-table schema))))

(defun %validate-number-node (instance schema path errors)
  (let ((minimum (gethash "minimum" schema))
        (maximum (gethash "maximum" schema))
        (exclusive-minimum (gethash "exclusiveMinimum" schema))
        (exclusive-maximum (gethash "exclusiveMaximum" schema))
        (multiple-of (gethash "multipleOf" schema)))
    (when (and (realp minimum) (< instance minimum))
      (push (format nil "~A：值 ~A 小于 minimum ~A" path instance minimum) errors))
    (when (and (realp maximum) (> instance maximum))
      (push (format nil "~A：值 ~A 大于 maximum ~A" path instance maximum) errors))
    (when (and (realp exclusive-minimum) (<= instance exclusive-minimum))
      (push (format nil "~A：值 ~A 须大于 exclusiveMinimum ~A"
                    path instance exclusive-minimum)
            errors))
    (when (and (realp exclusive-maximum) (>= instance exclusive-maximum))
      (push (format nil "~A：值 ~A 须小于 exclusiveMaximum ~A"
                    path instance exclusive-maximum)
            errors))
    (when (and (realp multiple-of) (plusp multiple-of)
               (not (zerop (mod instance multiple-of))))
      (push (format nil "~A：值 ~A 不是 multipleOf ~A 的整数倍"
                    path instance multiple-of)
            errors)))
  errors)

(defun %validate-string-node (instance schema path errors)
  (let ((min-length (gethash "minLength" schema))
        (max-length (gethash "maxLength" schema))
        (pattern (gethash "pattern" schema)))
    (when (and (realp min-length) (< (length instance) min-length))
      (push (format nil "~A：字符串长度 ~A 小于 minLength ~A"
                    path (length instance) min-length)
            errors))
    (when (and (realp max-length) (> (length instance) max-length))
      (push (format nil "~A：字符串长度 ~A 超过 maxLength ~A"
                    path (length instance) max-length)
            errors))
    ;; pattern 本身非法时按「不施加约束」处理，避免 schema 瑕疵变成校验失败
    (when (stringp pattern)
      (unless (handler-case (cl-ppcre:scan pattern instance)
                (error () t))
        (push (format nil "~A：字符串不匹配 pattern ~S" path pattern) errors))))
  errors)

(defun %validate-array-node (instance schema path errors)
  (multiple-value-bind (items found) (gethash "items" schema)
    (when found
      (loop for value across instance
            for index from 0
            do (setf errors (%validate-node value items
                                            (format nil "~A[~A]" path index)
                                            errors)))))
  (let ((min-items (gethash "minItems" schema))
        (max-items (gethash "maxItems" schema))
        (count (length instance)))
    (when (and (realp min-items) (< count min-items))
      (push (format nil "~A：数组长度 ~A 小于 minItems ~A" path count min-items)
            errors))
    (when (and (realp max-items) (> count max-items))
      (push (format nil "~A：数组长度 ~A 超过 maxItems ~A" path count max-items)
            errors))
    (when (eq (gethash "uniqueItems" schema) t)
      (block unique
        (loop for i from 0 below count
              do (loop for j from (1+ i) below count
                       do (when (json-equal (aref instance i) (aref instance j))
                            (push (format nil "~A：uniqueItems 要求元素唯一（第 ~A 与第 ~A 项重复）"
                                          path i j)
                                  errors)
                            (return-from unique)))))))
  errors)

(defun %validate-object-node (instance schema path errors)
  (let ((properties (gethash "properties" schema)))
    ;; required：必须用 gethash 第二返回值，否则字段值为 false/null 会被误判为缺失
    (multiple-value-bind (required found) (gethash "required" schema)
      (when (and found (json-array-p required))
        (loop for name across required
              do (unless (nth-value 1 (gethash name instance))
                   (push (format nil "~A：缺少必填字段 ~S" path name) errors)))))
    ;; properties
    (when (hash-table-p properties)
      (maphash (lambda (name subschema)
                 (multiple-value-bind (value found) (gethash name instance)
                   (when found
                     (setf errors (%validate-node value subschema
                                                  (format nil "~A.~A" path name)
                                                  errors)))))
               properties))
    ;; additionalProperties：false 禁止额外字段；schema 则逐个校验
    (multiple-value-bind (additional found) (gethash "additionalProperties" schema)
      (when found
        (maphash (lambda (name value)
                   (unless (and (hash-table-p properties)
                                (nth-value 1 (gethash name properties)))
                     (if (eq additional nil)
                         (push (format nil "~A：不允许额外字段 ~S" path name) errors)
                         (setf errors (%validate-node value additional
                                                      (format nil "~A.~A" path name)
                                                      errors)))))
                 instance))))
  errors)

(defun %validate-combinators (instance schema path errors)
  (multiple-value-bind (all-of found) (gethash "allOf" schema)
    (when (and found (json-array-p all-of))
      (loop for sub across all-of
            do (setf errors (%validate-node instance sub path errors)))))
  (multiple-value-bind (any-of found) (gethash "anyOf" schema)
    (when (and found (json-array-p any-of))
      (unless (some (lambda (sub) (null (%validate-node instance sub path nil)))
                    any-of)
        (push (format nil "~A：不满足 anyOf 中的任何一个 schema" path) errors))))
  (multiple-value-bind (one-of found) (gethash "oneOf" schema)
    (when (and found (json-array-p one-of))
      (let ((matched (count-if (lambda (sub)
                                 (null (%validate-node instance sub path nil)))
                               one-of)))
        (unless (= matched 1)
          (push (format nil "~A：oneOf 要求恰好匹配 1 个 schema，实际匹配 ~A 个"
                        path matched)
                errors)))))
  (multiple-value-bind (not-schema found) (gethash "not" schema)
    (when found
      (when (null (%validate-node instance not-schema path nil))
        (push (format nil "~A：不应匹配 not 指定的 schema" path) errors))))
  errors)

(defun %validate-node (instance schema path errors)
  "校验单个节点，返回逆序累积的错误列表"
  ;; 布尔 schema：true 接受一切，false 拒绝一切
  (when (eq schema t)
    (return-from %validate-node errors))
  (when (eq schema nil)
    (return-from %validate-node
      (cons (format nil "~A：schema 为 false，不接受任何值" path) errors)))
  (unless (hash-table-p schema)
    (return-from %validate-node errors))
  ;; type：类型不符时后续针对性校验没有意义，直接返回
  (multiple-value-bind (type found) (gethash "type" schema)
    (when found
      (let ((types (if (json-array-p type) (coerce type 'list) (list type))))
        (unless (some (lambda (name) (json-type-match-p instance name)) types)
          (return-from %validate-node
            (cons (format nil "~A：期望类型 ~{~A~^ 或 ~}，实际为 ~A"
                          path types (json-type-name instance))
                  errors))))))
  (multiple-value-bind (enum found) (gethash "enum" schema)
    (when (and found (json-array-p enum))
      (unless (some (lambda (value) (json-equal instance value)) enum)
        (push (format nil "~A：值不在 enum 允许范围内" path) errors))))
  (multiple-value-bind (const found) (gethash "const" schema)
    (when found
      (unless (json-equal instance const)
        (push (format nil "~A：值与 const 不符" path) errors))))
  (setf errors (%validate-combinators instance schema path errors))
  (cond
    ((hash-table-p instance) (%validate-object-node instance schema path errors))
    ((json-array-p instance) (%validate-array-node instance schema path errors))
    ((stringp instance) (%validate-string-node instance schema path errors))
    ((realp instance) (%validate-number-node instance schema path errors))
    (t errors)))

(defun validate-json-schema (instance schema)
  "校验 INSTANCE 是否符合 SCHEMA。

参数：
  INSTANCE - json-parse 解析出的 JSON 值
  SCHEMA   - hash-table / JSON 字符串 / params->json-schema 的 plist

返回：
  错误消息字符串列表；NIL 表示校验通过。"
  (nreverse (%validate-node instance (ensure-json-schema schema) "$" nil)))

(defun validate-json-text (text schema)
  "解析 TEXT 并对 SCHEMA 校验。

返回两个值：
  1. 错误消息列表（NIL 表示通过）
  2. 解析出的 JSON 值（解析失败为 NIL）

TEXT 不是合法 JSON 时返回解析错误，而不是发条件。"
  (handler-case
      (let ((instance (json-parse text)))
        (values (validate-json-schema instance schema) instance))
    (error (e)
      (values (list (format nil "JSON 解析失败：~A" e)) nil))))
