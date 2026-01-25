;;;; validation.lisp
;;;; CL-Agent - 统一参数验证系统
;;;;
;;;; 概述：
;;;;   提供统一的参数验证宏，减少重复的验证代码
;;;;
;;;; 特性：
;;;;   - 参数非空验证
;;;;   - 类型验证
;;;;   - 条件验证
;;;;   - 批量验证
;;;;   - 集合验证
;;;;
;;;; 设计原则：
;;;;   - 减少重复代码
;;;;   - 提供清晰的错误消息
;;;;   - 支持批量验证

(in-package :cl-agent.core)

;;; ============================================================
;;; 基础验证宏
;;; ============================================================

(defmacro validate-required (place &optional (place-name (string place)))
  "验证参数非空

  参数：
    PLACE      - 要验证的参数
    PLACE-NAME - 参数名称（可选，默认为 PLACE 的字符串形式）

  说明：
    如果参数为 nil，抛出 validation-error

  示例：
    (validate-required llm-client \"LLM client\")
    (validate-required config)"

  `(unless ,place
     (error 'validation-error
            :message (format nil "Required parameter ~A cannot be nil" ,place-name)
            :field ,place-name)))

(defmacro validate-type (place expected-type &optional (place-name (string place)))
  "验证参数类型

  参数：
    PLACE         - 要验证的参数
    EXPECTED-TYPE - 期望的类型
    PLACE-NAME    - 参数名称（可选）

  说明：
    如果参数不是指定类型，抛出 validation-error

  示例：
    (validate-type model string \"model name\")
    (validate-type count integer)"

  `(unless (typep ,place ',expected-type)
     (error 'validation-error
            :message (format nil "Parameter ~A should be of type ~A, got ~S"
                            ,place-name ',expected-type (type-of ,place))
            :field ,place-name)))

(defmacro validate-not-nil (value &optional (message "Value cannot be nil"))
  "断言值非空

  参数：
    VALUE   - 要验证的值
    MESSAGE - 错误消息（可选）

  说明：
    如果值为 nil，抛出 validation-error

  示例：
    (validate-not-nil agent \"Agent must not be nil\")"

  `(unless ,value
     (error 'validation-error
            :message ,message)))

;;; ============================================================
;;; 扩展验证宏
;;; ============================================================

(defmacro ensure-not-null (value &optional (message "Value cannot be nil"))
  "确保值非空（简洁版本）

  参数：
    VALUE   - 要验证的值
    MESSAGE - 错误消息（可选）

  说明：
    与 validate-not-nil 类似，但名称更清晰
    适用于快速检查

  示例：
    (ensure-not-null x \"x must be provided\")"

  `(unless ,value
     (error 'validation-error :message ,message)))

(defmacro ensure-type (value expected-type &optional (value-name "value"))
  "确保值类型匹配

  参数：
    VALUE         - 要验证的值
    EXPECTED-TYPE - 期望的类型
    VALUE-NAME    - 值名称（可选）

  说明：
    如果值类型不匹配，抛出 validation-error

  示例：
    (ensure-type x string \"x\")
    (ensure-type config hash-table)"

  `(unless (typep ,value ',expected-type)
     (error 'validation-error
            :message (format nil "~A should be of type ~A, got ~S"
                            ,value-name ',expected-type (type-of ,value)))))

(defmacro validate-condition (condition-form &optional (message "Condition failed"))
  "验证条件成立

  参数：
    CONDITION-FORM - 条件表达式
    MESSAGE        - 错误消息（可选）

  说明：
    如果条件不成立，抛出 validation-error

  示例：
    (validate-condition (> x 0) \"x must be positive\")
    (validate-condition (stringp s) \"s must be a string\")"

  `(unless ,condition-form
     (error 'validation-error :message ,message)))

(defmacro validate-args (&body validations)
  "批量验证参数

  参数：
    VALIDATIONS - 验证规则列表

  说明：
    支持三种验证类型：
    - (:required PLACE &optional NAME)
    - (:type PLACE TYPE &optional NAME)
    - (:condition FORM &optional MESSAGE)

  示例：
    (validate-args
      (:required llm-client \"LLM client\")
      (:type model string \"model name\")
      (:condition (> max-iterations 0) \"max-iterations must be positive\"))"

  `(progn
     ,@(loop for validation in validations
             collect (let ((type (first validation))
                            (args (rest validation)))
                       (case type
                         (:required
                          `(validate-required ,(first args) ,@(rest args)))
                         (:type
                          `(ensure-type ,(first args) ,(second args) ,@(cddr args)))
                         (:condition
                          `(validate-condition ,(first args) ,@(rest args)))
                         (otherwise
                          (error "Unknown validation type: ~A" type)))))))

(defmacro ensure-not-empty (collection &optional (message "Collection cannot be empty"))
  "确保集合非空

  参数：
    COLLECTION - 要验证的集合
    MESSAGE    - 错误消息（可选）

  说明：
    如果集合为空或 nil，抛出 validation-error

  示例：
    (ensure-not-empty list \"list cannot be empty\")
    (ensure-not-empty tools \"tools must not be empty\")"

  `(unless (and ,collection (plusp (length ,collection)))
     (error 'validation-error :message ,message)))

(defmacro ensure-member (value collection &optional (value-name "value"))
  "确保值是集合成员

  参数：
    VALUE       - 要验证的值
    COLLECTION   - 集合
    VALUE-NAME  - 值名称（可选）

  说明：
    如果值不在集合中，抛出 validation-error

  示例：
    (ensure-member strategy '(:sequential :parallel) \"strategy\")
    (ensure-member key (state-keys state) \"key\")"

  `(unless (member ,value ,collection)
     (error 'validation-error
            :message (format nil "~A must be one of ~S, got ~S"
                            ,value-name ,collection ,value))))

(defmacro validate-file-path (path &key (must-exist nil)
                                       (type :file)
                                       (path-name "path"))
  "验证文件路径

  参数：
    PATH        - 文件路径
    MUST-EXIST  - 是否必须存在（默认 nil）
    TYPE        - 类型（:file 或 :directory，默认 :file）
    PATH-NAME   - 路径名称（可选）

  说明：
    如果路径无效，抛出 validation-error

  示例：
    (validate-file-path filepath :must-exist t :type :file)
    (validate-file-path dir :type :directory)"

  `(let ((path-string ,path))
     (when ,must-exist
       (let ((exists-p
               ,(ecase type
                  (:file '(uiop:file-exists-p path-string))
                  (:directory '(uiop:directory-exists-p path-string)))))
         (unless exists-p
           (error 'validation-error
                  :message (format nil "~A does not exist: ~A"
                                  ,path-name path-string)))))
     path-string))

(defmacro validate-in-range (value min max &optional (value-name "value"))
  "验证值在指定范围内

  参数：
    VALUE     - 要验证的值
    MIN       - 最小值（包含）
    MAX       - 最大值（包含）
    VALUE-NAME - 值名称（可选）

  说明：
    如果值不在 [min, max] 范围内，抛出 validation-error

  示例：
    (validate-in-range count 1 10 \"count\")
    (validate-in-range index 0 (length list) \"index\")"

  `(unless (and (>= ,value ,min) (<= ,value ,max))
     (error 'validation-error
            :message (format nil "~A must be between ~A and ~A, got ~A"
                            ,value-name ,min ,max ,value))))

(defmacro validate-positive (value &optional (value-name "value"))
  "验证值为正数

  参数：
    VALUE      - 要验证的值
    VALUE-NAME - 值名称（可选）

  说明：
    如果值不是正数，抛出 validation-error

  示例：
    (validate-positive count \"count\")
    (validate-positive max-iterations)"

  `(unless (and (numberp ,value) (> ,value 0))
     (error 'validation-error
            :message (format nil "~A must be a positive number, got ~A"
                            ,value-name ,value))))

(defmacro validate-non-negative (value &optional (value-name "value"))
  "验证值为非负数

  参数：
    VALUE      - 要验证的值
    VALUE-NAME - 值名称（可选）

  说明：
    如果值是负数，抛出 validation-error

  示例：
    (validate-non-negative index \"index\")"

  `(unless (and (numberp ,value) (>= ,value 0))
     (error 'validation-error
            :message (format nil "~A must be a non-negative number, got ~A"
                            ,value-name ,value))))

;;; ============================================================
;;; 导出符号
;;; ============================================================

(export '(validate-required
          validate-type
          validate-not-nil
          ensure-not-null
          ensure-type
          validate-condition
          validate-args
          ensure-not-empty
          ensure-member
          validate-file-path
          validate-in-range
          validate-positive
          validate-non-negative))
