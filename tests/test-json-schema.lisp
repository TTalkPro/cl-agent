;;;; test-json-schema.lisp
;;;; CL-Agent - JSON Schema 校验器测试
;;;;
;;;; 覆盖：
;;;;   - 基本类型判定（含 jzon 表示的两个坑：false→NIL、字符串也是 vector）
;;;;   - required 与「字段值为 false/null」的区分
;;;;   - 数值/字符串/数组约束、enum/const、组合关键字
;;;;   - plist（params->json-schema 输出）形式的 schema

(in-package :cl-agent/tests)

(def-suite json-schema-suite :in cl-agent-suite
  :description "JSON Schema 校验")

(in-suite json-schema-suite)

(defun js-valid-p (json schema)
  "JSON 文本是否通过 SCHEMA 校验"
  (null (cl-agent.core:validate-json-schema
         (cl-agent.core:json-parse json) schema)))

(defparameter +person-schema+
  "{\"type\":\"object\",
    \"properties\":{\"name\":{\"type\":\"string\"},
                   \"age\":{\"type\":\"integer\",\"minimum\":0},
                   \"active\":{\"type\":\"boolean\"},
                   \"tags\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}}},
    \"required\":[\"name\",\"age\"]}")

;;; ============================================================
;;; 基本校验
;;; ============================================================

(test json-schema-accepts-valid-object
  "合法对象通过校验"
  (is (js-valid-p "{\"name\":\"a\",\"age\":3}" +person-schema+))
  (is (js-valid-p "{\"name\":\"a\",\"age\":3,\"tags\":[\"x\",\"y\"]}" +person-schema+)))

(test json-schema-rejects-missing-required
  "缺少必填字段被拒绝"
  (is (not (js-valid-p "{\"name\":\"a\"}" +person-schema+))))

(test json-schema-rejects-wrong-type
  "类型不符被拒绝"
  (is (not (js-valid-p "{\"name\":1,\"age\":3}" +person-schema+)))
  (is (not (js-valid-p "{\"name\":\"a\",\"age\":\"3\"}" +person-schema+))))

(test json-schema-nested-array-items
  "数组元素类型被逐个校验"
  (is (not (js-valid-p "{\"name\":\"a\",\"age\":1,\"tags\":[1]}" +person-schema+))))

(test json-schema-error-messages-mention-path
  "错误消息带上出错路径，便于模型自我纠正"
  (let ((errors (cl-agent.core:validate-json-schema
                 (cl-agent.core:json-parse "{\"name\":\"a\",\"age\":1,\"tags\":[1]}")
                 +person-schema+)))
    (is (= 1 (length errors)))
    (is (search "$.tags[0]" (first errors)))))

;;; ============================================================
;;; jzon 表示的两个坑
;;; ============================================================

(test json-schema-false-is-not-missing
  "字段值为 false 不能被当成「字段缺失」——jzon 把 false 解析为 NIL"
  (is (js-valid-p "{\"name\":\"a\",\"age\":1,\"active\":false}" +person-schema+))
  ;; required 字段值为假值（0）同样不算缺失
  (is (js-valid-p "{\"name\":\"a\",\"age\":0}" +person-schema+)))

(test json-schema-distinguishes-false-from-null
  "false 与 null 是不同的 JSON 值"
  (is (js-valid-p "false" "{\"type\":\"boolean\"}"))
  (is (not (js-valid-p "null" "{\"type\":\"boolean\"}")))
  (is (js-valid-p "null" "{\"type\":\"null\"}"))
  (is (not (js-valid-p "false" "{\"type\":\"null\"}"))))

(test json-schema-string-is-not-array
  "字符串在 CL 中也是 vector，但不是 JSON array"
  (is (not (js-valid-p "\"abc\"" "{\"type\":\"array\"}")))
  (is (js-valid-p "[]" "{\"type\":\"array\"}")))

;;; ============================================================
;;; 各类约束
;;; ============================================================

(test json-schema-number-constraints
  "数值约束"
  (is (not (js-valid-p "{\"name\":\"a\",\"age\":-1}" +person-schema+)))
  (is (js-valid-p "5" "{\"type\":\"number\",\"minimum\":5,\"maximum\":5}"))
  (is (not (js-valid-p "5" "{\"type\":\"number\",\"exclusiveMinimum\":5}")))
  (is (js-valid-p "6" "{\"type\":\"integer\",\"multipleOf\":3}"))
  (is (not (js-valid-p "7" "{\"type\":\"integer\",\"multipleOf\":3}"))))

(test json-schema-integer-accepts-zero-fraction
  "JSON Schema 规定 1.0 这类零小数部分的数也算 integer"
  (is (js-valid-p "1.0" "{\"type\":\"integer\"}"))
  (is (not (js-valid-p "1.5" "{\"type\":\"integer\"}"))))

(test json-schema-string-constraints
  "字符串约束"
  (is (not (js-valid-p "\"ab\"" "{\"type\":\"string\",\"minLength\":3}")))
  (is (not (js-valid-p "\"abcd\"" "{\"type\":\"string\",\"maxLength\":3}")))
  (is (js-valid-p "\"a1\"" "{\"type\":\"string\",\"pattern\":\"^[a-z][0-9]$\"}"))
  (is (not (js-valid-p "\"11\"" "{\"type\":\"string\",\"pattern\":\"^[a-z][0-9]$\"}"))))

(test json-schema-array-constraints
  "数组长度与唯一性约束"
  (is (not (js-valid-p "[1]" "{\"type\":\"array\",\"minItems\":2}")))
  (is (not (js-valid-p "[1,2,3]" "{\"type\":\"array\",\"maxItems\":2}")))
  (is (not (js-valid-p "[1,1]" "{\"type\":\"array\",\"uniqueItems\":true}")))
  (is (js-valid-p "[1,2]" "{\"type\":\"array\",\"uniqueItems\":true}")))

(test json-schema-enum-and-const
  "enum 与 const"
  (is (js-valid-p "\"b\"" "{\"enum\":[\"a\",\"b\"]}"))
  (is (not (js-valid-p "\"z\"" "{\"enum\":[\"a\",\"b\"]}")))
  (is (js-valid-p "42" "{\"const\":42}"))
  (is (not (js-valid-p "43" "{\"const\":42}"))))

(test json-schema-additional-properties
  "additionalProperties:false 禁止额外字段"
  (let ((schema "{\"type\":\"object\",\"properties\":{\"a\":{}},
                  \"additionalProperties\":false}"))
    (is (js-valid-p "{\"a\":1}" schema))
    (is (not (js-valid-p "{\"a\":1,\"b\":2}" schema)))))

(test json-schema-combinators
  "anyOf / oneOf / not"
  (is (js-valid-p "5" "{\"anyOf\":[{\"type\":\"string\"},{\"type\":\"integer\"}]}"))
  (is (not (js-valid-p "true" "{\"anyOf\":[{\"type\":\"string\"},{\"type\":\"integer\"}]}")))
  ;; oneOf 要求恰好匹配一个：integer 同时满足 integer 与 number，故失败
  (is (not (js-valid-p "5" "{\"oneOf\":[{\"type\":\"integer\"},{\"type\":\"number\"}]}")))
  (is (js-valid-p "\"s\"" "{\"oneOf\":[{\"type\":\"integer\"},{\"type\":\"string\"}]}"))
  (is (not (js-valid-p "5" "{\"not\":{\"type\":\"integer\"}}"))))

;;; ============================================================
;;; schema 形式归一化
;;; ============================================================

(test json-schema-accepts-plist-schema
  "params->json-schema 的 plist 输出可直接用作 schema"
  (let ((schema (cl-agent.core:params->json-schema
                 '((city :string "城市" :required-p t)))))
    (is (js-valid-p "{\"city\":\"东京\"}" schema))
    (is (not (js-valid-p "{}" schema)))))

(test json-schema-validate-json-text-reports-parse-error
  "validate-json-text 对非法 JSON 返回解析错误而非发条件"
  (multiple-value-bind (errors instance)
      (cl-agent.core:validate-json-text "{不是 JSON" "{\"type\":\"object\"}")
    (is (not (null errors)))
    (is (null instance))
    (is (search "解析失败" (first errors)))))
