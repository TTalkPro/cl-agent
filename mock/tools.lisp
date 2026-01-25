;;;; tools.lisp
;;;; CL-Agent - Mock 工具实现
;;;;
;;;; 概述：
;;;;   提供模拟的工具实现，用于测试和演示
;;;;
;;;; 特性：
;;;;   - 无副作用（默认）
;;;;   - 可预测的行为
;;;;   - 支持延迟和错误模拟

(in-package :cl-agent.mock)

;;; ============================================================
;;; Mock 工具类
;;; ============================================================

(defclass mock-tool ()
  ((name :initarg :name :reader mock-tool-name)
   (description :initarg :description :reader mock-tool-description)
   (execute-fn :initarg :execute-fn :accessor tool-execute-fn)
   (delay :initarg :delay :initform 0 :accessor tool-delay)
   (error-rate :initarg :error-rate :initform 0 :accessor tool-error-rate))
  (:documentation "Mock 工具基类"))

;;; ============================================================
;;; Mock 工具生成宏
;;; ============================================================

(defmacro define-mock-tool (tool-name description input-params
                                    &key
                                      (delay 0)
                                      (error-rate 0)
                                      (result-fn nil))
  "定义 Mock 工具的宏，消除重复的工具创建代码

参数：
  TOOL-NAME     - 工具名称（关键字），如 :calculator, :search
  DESCRIPTION   - 工具描述（字符串）
  INPUT-PARAMS  - 输入参数列表，格式为 ((param-name param-keyword) ...)
                  例如：((expression :expression) (precision :precision))
  DELAY         - 默认执行延迟（秒）
  ERROR-RATE    - 默认错误率（0.0-1.0）
  RESULT-FN     - 结果生成函数（可选），接收提取的参数并返回结果

生成的函数：
  make-<tool-name>-tool (&key delay error-rate)

宏展开后创建一个函数，返回 mock-tool 实例

优势：
  - 消除 ~200 行重复代码
  - 统一错误处理
  - 统一参数验证
  - 易于添加新工具

示例：
  (define-mock-tool :calculator
    \"执行基本数学计算（Mock）\"
    ((expression :expression))
    :result-fn #'safe-evaluate-expression)

  (define-mock-tool :search
    \"搜索互联网信息（Mock）\"
    ((query :query))
    :result-fn #'generate-mock-search-results)"
  (let ((tool-fn-name (intern (format nil "MAKE-~A-TOOL"
                                        (string tool-name))
                               :cl-agent.mock)))
    `(defun ,tool-fn-name (&key (delay ,delay) (error-rate ,error-rate))
       ,(format nil "创建 Mock ~A 工具

参数：
  DELAY      - 执行延迟（秒）
  ERROR-RATE - 错误率（0.0-1.0）

返回：
  Mock ~A 工具实例" tool-name tool-name)
       (make-instance 'mock-tool
                      :name ,tool-name
                      :description ,description
                      :delay delay
                      :error-rate error-rate
                      :execute-fn
                      (lambda (input &key context)
                        (declare (ignore context))
                        (when (> delay 0) (sleep delay))

                        ;; 错误模拟
                        (if (and (> error-rate 0)
                                (< (random 1.0) error-rate))
                            (list :success nil
                                  :error ,(format nil "~A错误" tool-name))
                            ;; 参数提取和验证
                            (let ,(mapcar (lambda (param)
                                          `(,(second param)
                                            (if (stringp input)
                                                input
                                                (getf input ,(second param)))))
                                        input-params)
                              ;; 参数验证
                              (if (and ,@(mapcar (lambda (param)
                                                  `(and ,(second param)
                                                        (or (stringp ,(second param))
                                                            (and ,(not (eq (second param) :expression))
                                                                 (stringp ,(second param))))))
                                                input-params))
                                  ;; 成功执行
                                  (list :success t
                                        :result ,(if result-fn
                                                     `(funcall ,result-fn
                                                               ,@(mapcar #'second input-params))
                                                     '(values)))
                                        :metadata '(list
                                                    ,@(mapcar (lambda (p)
                                                                `(list ,(second p) ,(second p)))
                                                              input-params)))
                                  ;; 参数错误
                                  (list :success nil
                                        :error "缺少必需参数"))))))))

;;; ============================================================
;;; 宏使用说明
;;; ============================================================
;;;
;;; define-mock-tool 宏已创建，将在阶段 2 用于重构现有工具
;;;
;;; 当前策略：
;;;   1. 阶段 1：创建宏基础设施（已完成）
;;;   2. 阶段 2：逐步迁移工具使用宏
;;;      - 先迁移简单工具（search）
;;;      - 再迁移复杂工具（calculator, file, database）
;;;      - 每个工具迁移后进行测试验证
;;;
;;; 这样做的好处：
;;;   - 渐进式重构，降低风险
;;;   - 每步都可以验证
;;;   - 不会破坏现有功能

;;; ============================================================
;;; ============================================================
;;; 预定义 Mock 工具
;;; ============================================================

(defun make-calculator-tool (&key (delay 0) (error-rate 0))
  "创建 Mock 计算器工具

参数：
  DELAY      - 执行延迟（秒），默认 0
  ERROR-RATE - 错误率（0.0-1.0），默认 0

返回：
  Mock 计算器工具实例

示例：
  (make-calculator-tool :delay 0.5)

工具参数：
  :expression - 数学表达式字符串，如 \"1+1\"

返回：
  计算结果

错误：
  - 如果表达式无效，返回错误信息"

  (make-instance 'mock-tool
                 :name :calculator
                 :description "执行基本数学计算（Mock）"
                 :delay delay
                 :error-rate error-rate
                 :execute-fn
                 (lambda (input &key context)
                   (declare (ignore context))
                   (when (> delay 0) (sleep delay))

                   (if (and (> error-rate 0)
                           (< (random 1.0) error-rate))
                       (list :success nil :error "计算器错误")
                       (let ((expr (if (stringp input) input (getf input :expression))))
                         (if (and expr (stringp expr))
                             (handler-case
                                 (let ((result (safe-evaluate-expression expr)))
                                   (list :success t
                                         :result result
                                         :metadata (list :expression expr)))
                               (error (e)
                                 (list :success nil
                                       :error (format nil "表达式错误: ~A" e))))
                             (list :success nil
                                   :error "缺少 :expression 参数"))))))


(defun make-search-tool (&key (delay 0) (error-rate 0))
  "创建 Mock 搜索工具

参数：
  DELAY      - 执行延迟（秒）
  ERROR-RATE - 错误率

返回：
  Mock 搜索工具实例

工具参数：
  :query - 搜索查询字符串

返回：
  搜索结果（Mock 数据）"

  (make-instance 'mock-tool
                 :name :search
                 :description "搜索互联网信息（Mock）"
                 :delay delay
                 :error-rate error-rate
                 :execute-fn
                 (lambda (input &key context)
                   (declare (ignore context))
                   (when (> delay 0) (sleep delay))

                   (if (and (> error-rate 0)
                           (< (random 1.0) error-rate))
                       (list :success nil :error "搜索服务错误")
                       (let ((query (if (stringp input) input (getf input :query))))
                         (if (and query (stringp query))
                             (list :success t
                                   :result (generate-mock-search-results query)
                                   :metadata (list :query query :count 3))
                             (list :success nil
                                   :error "缺少 :query 参数"))))))

(defun make-file-tool (&key (delay 0) (error-rate 0))
  "创建 Mock 文件操作工具

参数：
  DELAY      - 执行延迟（秒）
  ERROR-RATE - 错误率

返回：
  Mock 文件工具实例

工具参数：
  :action - 操作类型 (:read, :write, :list)
  :path   - 文件路径
  :content - 文件内容（write 时使用）

返回：
  操作结果"

  (make-instance 'mock-tool
                 :name :file-ops
                 :description "文件操作（Mock）"
                 :delay delay
                 :error-rate error-rate
                 :execute-fn
                 (lambda (input &key context)
                   (declare (ignore context))
                   (when (> delay 0) (sleep delay))

                   (if (and (> error-rate 0)
                           (< (random 1.0) error-rate))
                       (list :success nil :error "文件系统错误")
                       (let ((action (getf input :action))
                             (path (getf input :path)))
                         (cond
                           ((eq action :read)
                            (list :success t
                                  :result (format nil "Mock file content: ~A" path)
                                  :metadata (list :path path)))
                           ((eq action :write)
                            (list :success t
                                  :result nil
                                  :metadata (list :path path :bytes-written 100)))
                           ((eq action :list)
                            (list :success t
                                  :result (list "file1.txt" "file2.txt" "file3.txt")
                                  :metadata (list :count 3)))
                           (t
                            (list :success nil
                                  :error (format nil "Unknown action: ~A" action))))))))

(defun make-database-tool (&key (delay 0) (error-rate 0))
  "创建 Mock 数据库工具

参数：
  DELAY      - 执行延迟（秒）
  ERROR-RATE - 错误率

返回：
  Mock 数据库工具实例

工具参数：
  :query - SQL 查询字符串

返回：
  查询结果（Mock 数据）"

  (make-instance 'mock-tool
                 :name :database
                 :description "数据库查询（Mock）"
                 :delay delay
                 :error-rate error-rate
                 :execute-fn
                 (lambda (input &key context)
                   (declare (ignore context))
                   (when (> delay 0) (sleep delay))

                   (let ((query (if (stringp input) input (getf input :query))))
                     (list :success t
                           :result (generate-mock-db-results query)
                           :metadata (list :rows-affected 1))))))

;;; ============================================================
;;; 工具包
;;; ============================================================

(defun make-mock-toolkit (&key (delay 0) (error-rate 0))
  "创建完整的 Mock 工具包

参数：
  DELAY      - 全局延迟（秒）
  ERROR-RATE - 全局错误率

返回：
  Mock 工具包列表

示例：
  (make-mock-toolkit :delay 0.1)

包含工具：
  :calculator - 计算器
  :search     - 搜索
  :file-ops   - 文件操作
  :database   - 数据库"

  (list
    (make-calculator-tool :delay delay :error-rate error-rate)
    (make-search-tool :delay delay :error-rate error-rate)
    (make-file-tool :delay delay :error-rate error-rate)
    (make-database-tool :delay delay :error-rate error-rate)))

;;; ============================================================
;;; 辅助函数
;;; ============================================================

(defun safe-evaluate-expression (expr)
  "安全地计算数学表达式

参数：
  EXPR - 表达式字符串

返回：
  计算结果

注意：
  - 只支持基本运算：+, -, *, /
  - 不支持函数调用和复杂表达式"

  ;; 简单实现：只处理数字和基本运算符
  (let ((cleaned (cl-ppcre:regex-replace-all "\\s+" expr "")))
    ;; 这里使用一个简化的方法
    ;; 实际应用中应该使用更安全的表达式求值器
    (handler-case
        (with-input-from-string (s cleaned)
          (read s))
      (error ()
        (values 0)))))

(defun generate-mock-search-results (query)
  "生成 Mock 搜索结果

参数：
  QUERY - 搜索查询

返回：
  搜索结果字符串"

  (format nil "~%关于「~A」的搜索结果：~%~%1. ~A 相关的第一条结果~%2. ~A 相关的第二条结果~%3. ~A 相关的第三条结果~%"
          query
          query
          query
          query))

(defun generate-mock-db-results (query)
  "生成 Mock 数据库查询结果

参数：
  QUERY - SQL 查询

返回：
  查询结果字符串"

  (format nil "~%查询结果：~%~%Mock 数据库响应~%~%执行 SQL: ~A~%~%返回 1 行数据~%"
          (or query "SELECT * FROM table")))

;;; ============================================================
;;; 工具协议实现
;;; ============================================================

(defmethod tool-name ((tool mock-tool))
  "获取 Mock 工具名称"
  (mock-tool-name tool))

(defmethod tool-description ((tool mock-tool))
  "获取 Mock 工具描述"
  (mock-tool-description tool))

(defmethod tool-execute ((tool mock-tool) input &key context)
  "执行 Mock 工具"
  (when (> (tool-delay tool) 0)
    (sleep (tool-delay tool)))

  (when (> (tool-error-rate tool) 0)
    (when (< (random 1.0) (tool-error-rate tool))
      (return-from tool-execute
        (list :success nil
              :error "Mock tool error"))))

  (funcall (tool-execute-fn tool) input :context context))

(defmethod tool-schema ((tool mock-tool))
  "获取 Mock 工具的 schema"
  (list :name (mock-tool-name tool)
        :description (mock-tool-description tool)
        :parameters (get-tool-parameters-schema (mock-tool-name tool))))

(defun get-tool-parameters-schema (tool-name)
  "根据工具名称返回参数 schema"

  (case tool-name
    (:calculator
     (list :type "object"
           :properties (list :expression (list :type "string"
                                              :description "数学表达式，如 1+1"))
           :required (list "expression")))

    (:search
     (list :type "object"
           :properties (list :query (list :type "string"
                                          :description "搜索查询"))
           :required (list "query")))

    (:file-ops
     (list :type "object"
           :properties (list :action (list :type "string"
                                            :description "操作类型: read, write, list"
                                            :enum (list "read" "write" "list"))
                             :path (list :type "string"
                                         :description "文件路径"))
           :required (list "action" "path")))

    (:database
     (list :type "object"
           :properties (list :query (list :type "string"
                                            :description "SQL 查询"))
           :required (list "query")))

    (t nil)))
))
)
