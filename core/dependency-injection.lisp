;;;; dependency-injection.lisp
;;;; CL-Agent - 依赖注入框架
;;;;
;;;; 概述：
;;;;   提供轻量级的依赖注入容器，实现控制反转和松耦合
;;;;
;;;; 特性：
;;;;   - 服务绑定和解析
;;;;   - 单例和原型作用域
;;;;   - 层级容器支持
;;;;   - 生命周期管理
;;;;
;;;; 使用示例：
;;;;   (defvar *container* (make-di-container))
;;;;   (di-bind *container* :memory-store #'make-memory-store)
;;;;   (di-with-dependencies *container*
;;;;       ((memory (:memory-store))
;;;;        (tools (:tool-registry)))
;;;;     (use-services memory tools))

(in-package :cl-agent.core)

;;; ============================================================
;;; 导出符号
;;; ============================================================

(export '(di-container
          di-container-p
          make-di-container
          di-container-parent
          di-bind
          di-bind*
          di-resolve
          di-with-dependencies
          di-release
          di-clear
          di-cleanup
          di-cleanup-p
          di-lazy-dependency
          di-lazy-service
          di-boundp
          di-resolve-or-default
          di-list-services
          di-container-stats
          di-print-container))

;;; ============================================================
;;; DI 容器类
;;; ============================================================

(defclass di-container ()
  ((bindings :initform (make-hash-table :test #'equal)
            :reader di-bindings
            :documentation "服务绑定表 (name -> factory/config)")

   (singletons :initform (make-hash-table :test #'equal)
              :reader di-singletons
              :documentation "单例实例缓存 (name -> instance)")

   (parent :initarg :parent
          :initform nil
          :reader di-container-parent
          :documentation "父容器（用于层级依赖）")

   (name :initarg :name
         :initform (gensym "CONTAINER-")
          :reader di-container-name
          :documentation "容器名称（用于调试）"))
  (:documentation "依赖注入容器

  提供服务绑定、解析和生命周期管理功能

  作用域类型：
    - :singleton - 单例模式（默认）
    - :prototype - 原型模式（每次创建新实例）
    - :request - 请求作用域（未实现）

  示例：
    (let ((container (make-di-container)))
      (di-bind container :service #'make-service)
      (di-resolve container :service))"))

(defmethod print-object ((container di-container) stream)
  (print-unreadable-object (container stream :type t)
    (format stream "~A" (di-container-name container))))

;;; ============================================================
;;; 服务绑定
;;; ============================================================

(defun make-di-container (&key parent name)
  "创建依赖注入容器

参数：
  PARENT - 父容器（可选，用于层级依赖）
  NAME   - 容器名称（可选，用于调试）

返回：
  新的 DI 容器实例

示例：
  (make-di-container)
  (make-di-container :name \"app-container\")
  (make-di-container :parent parent-container)"
  (make-instance 'di-container
                 :parent parent
                 :name (or name (gensym "CONTAINER-"))))

(defgeneric di-bind (container name factory &key singleton scope)
  (:documentation "
绑定服务到容器

参数：
  CONTAINER - DI 容器实例
  NAME      - 服务名称（关键字或符号）
  FACTORY   - 工厂函数，返回服务实例
  SINGLETON - 是否单例（默认 t）
  SCOPE     - 作用域：:singleton, :prototype, :request

返回：
  NAME

工厂函数签名：
  - 无参数：(lambda () service-instance)
  - 带参数：(lambda (&key params) service-instance)

示例：
  ;; 单例服务
  (di-bind container :database
    (lambda () (make-database-connection)))

  ;; 原型服务
  (di-bind container :request
    (lambda () (make-request))
    :singleton nil)

  ;; 带参数的工厂
  (di-bind container :config
    (lambda (&key params)
      (load-config params)))

注意：
  - 如果服务已存在，会覆盖旧绑定
  - 单例缓存会被清除"))

(defmethod di-bind ((container di-container) name factory
                   &key (singleton t) (scope (if singleton :singleton :prototype)))
  "绑定服务到容器（默认方法）

参数：
  CONTAINER - DI 容器实例
  NAME      - 服务名称（关键字或符号）
  FACTORY   - 工厂函数
  SINGLETON - 是否单例（默认 t）
  SCOPE     - 作用域（默认根据 SINGLETON 自动设置）

返回：
  NAME

实现：
  1. 标准化服务名称
  2. 存储绑定到 bindings 表
  3. 清除单例缓存（如果存在）
  4. 返回服务名称"
  (declare (type (or symbol keyword) name))

  ;; 标准化名称
  (let ((binding-name (if (keywordp name)
                        name
                        (make-keyword (string name)))))

    ;; 存储绑定配置
    (setf (gethash binding-name (di-bindings container))
          (list :factory factory
                :singleton singleton
                :scope scope
                :name name))

    ;; 清除单例缓存（如果已存在）
    (when singleton
      (remhash binding-name (di-singletons container)))

    binding-name))

(defmacro di-bind* (container &body bindings)
  "批量绑定服务的宏

参数：
  CONTAINER - 容器变量
  BINDINGS  - 绑定列表，格式为 ((name factory &key options) ...)

返回：
  绑定名称列表

示例：
  (di-bind* container
    (:memory-store #'make-memory-store)
    (:tool-registry #'make-tool-registry)
    (:llm-provider (lambda () (make-openai-provider))
                    :scope :singleton))
    (:database (lambda () (make-db :pool-size 10)))
                :singleton nil))

展开为：
  (progn
    (di-bind container :memory-store #'make-memory-store)
    (di-bind container :tool-registry #'make-tool-registry)
    ...)

优势：
  - 批量绑定语法更简洁
  - 一次性配置多个服务
  - 提高可读性"
  `(progn
     ,@(mapcar (lambda (binding)
                 `(di-bind ,container
                          ,(first binding)
                          ,(second binding)
                          ,@(cddr binding)))
               bindings)))

;;; ============================================================
;;; 服务解析
;;; ============================================================

(defgeneric di-resolve (container name &key params)
  (:documentation "
从容器解析服务

参数：
  CONTAINER - DI 容器实例
  NAME      - 服务名称（关键字或符号）
  PARAMS    - 构造参数（可选）

返回：
  服务实例

解析流程：
  1. 在当前容器查找绑定
  2. 如果未找到，尝试从父容器解析
  3. 根据作用域创建或返回实例：
     - :singleton - 单例，从缓存获取或创建并缓存
     - :prototype - 原型，每次创建新实例
     - :request - 请求作用域（未实现）

示例：
  (di-resolve container :database)
  (di-resolve container :database :params \"config.json\")"))

(defmethod di-resolve ((container di-container) name &key (params nil))
  "从容器解析服务（默认方法）

参数：
  CONTAINER - DI 容器实例
  NAME      - 服务名称（关键字或符号）
  PARAMS    - 构造参数（可选）

返回：
  服务实例

实现：
  1. 标准化名称
  2. 查找绑定配置
  3. 根据作用域返回实例
  4. 如果未找到，尝试父容器

异常：
  - 如果服务未注册，发出错误"
  (declare (type (or symbol keyword) name))

  ;; 标准化名称
  (let ((binding-name (if (keywordp name)
                          name
                          (make-keyword (string name)))))

    ;; 查找绑定配置
    (let ((binding (gethash binding-name (di-bindings container))))

      ;; 如果未找到，尝试父容器
      (unless binding
        (if (di-container-parent container)
            (return-from di-resolve
              (di-resolve (di-container-parent container) name :params params))
            (error "Service not registered: ~A" name)))

      ;; 根据作用域返回实例
      (let ((factory (getf binding :factory))
            (singleton-p (getf binding :singleton t))
            (scope (getf binding :scope :singleton)))

        (case scope
          (:singleton
           ;; 单例模式：检查缓存
           (multiple-value-bind (instance cached-p)
               (gethash binding-name (di-singletons container))
             (if cached-p
                 instance
                 ;; 创建并缓存
                 (let ((new-instance (if params
                                        (apply factory params)
                                        (funcall factory))))
                   (setf (gethash binding-name (di-singletons container))
                         new-instance)
                   new-instance))))

          (:prototype
           ;; 原型模式：每次创建新实例
           (if params
               (apply factory params)
               (funcall factory)))

          (:request
           ;; 请求作用域：未实现
           (if params
               (apply factory params)
               (funcall factory)))

          (otherwise
           (error "Unknown scope: ~A" scope)))))))

;;; ============================================================
;;; 便捷宏
;;; ============================================================

(defmacro di-with-dependencies (container dependencies &body body)
  "依赖注入的 let* 宏

参数：
  CONTAINER   - 容器变量（求值的容器或容器名）
  DEPENDENCIES - 依赖列表，格式为 ((var (name &rest args)) ...)
  BODY        - 执行体

返回：
  BODY 的最后一个表达式的值

示例：
  (di-with-dependencies container
      ((memory (:memory-store))
       (registry (:tool-registry))
       (provider (:llm-provider :api-key *key*)))
    (use-services memory registry provider))

展开为：
  (let ((memory (di-resolve container :memory-store))
        (registry (di-resolve container :tool-registry))
        (provider (di-resolve container :llm-provider :api-key *key*)))
    (use-services memory registry provider))

优势：
  - 自动解析和管理依赖
  - 语法类似 let*，易于理解
  - 减少手动服务解析代码

注意：
  - 依赖按顺序解析（后面的依赖可以使用前面的）
  - 如果解析失败，会抛出异常"
  `(let ,(mapcar (lambda (dep)
                   (let ((var (first dep))
                         (spec (second dep)))
                     `(,var (di-resolve ,container
                                          ,(first spec)
                                          ,@(rest spec)))))
                 dependencies)
     ,@body))

(defmacro di-lazy-dependency (container name &body body)
  "延迟依赖解析宏

参数：
  CONTAINER - 容器变量
  NAME      - 服务名称
  BODY      - 执行体（使用延迟服务）

返回：
  BODY 的最后一个表达式的值

示例：
  (di-lazy-dependency container :database
    (query-database database))

展开为：
  (let ((database (di-resolve container :database)))
    (query-database database))

优势：
  - 延迟服务创建（只在需要时解析）
  - 用于循环依赖或可选依赖
  - 提高性能（避免不必要的初始化）"
  `(let ((,name (di-resolve ,container ,name)))
     ,@body))

(defmacro di-lazy-service (container name var &body body)
  "延迟服务绑定和解析宏

参数：
  CONTAINER - 容器变量
  NAME      - 服务名称
  VAR       - 绑定变量名
  BODY      - 执行体

返回：
  BODY 的最后一个表达式的值

示例：
  (di-lazy-service container :database db
    (query-db db \"SELECT * FROM users\"))

展开为：
  (let ((db (di-resolve container :database)))
    (query-db db \"SELECT * FROM users\"))

优势：
  - 结合绑定和解析
  - 变量名可自定义
  - 语法简洁"
  `(let ((,var (di-resolve ,container ,name)))
     ,@body))

;;; ============================================================
;;; 生命周期管理
;;; ============================================================

(defgeneric di-release (container name)
  (:documentation "
释放服务（清理资源）

参数：
  CONTAINER - DI 容器实例
  NAME      - 服务名称

返回：
  是否成功释放

实现：
  1. 从单例缓存移除
  2. 如果服务实现了 di-cleanup，调用清理方法
  3. 返回 t 或 nil

示例：
  (di-release container :database)

注意：
  - 只影响单例服务
  - 原型服务每次都是新实例，无需释放"))

(defmethod di-release ((container di-container) name)
  "释放服务（默认方法）

参数：
  CONTAINER - DI 容器实例
  NAME      - 服务名称

实现：
  1. 标准化名称
  2. 从缓存获取实例
  3. 如果实例实现了清理协议，调用清理
  4. 从缓存移除"
  (declare (type (or symbol keyword) name))

  ;; 标准化名称
  (let ((binding-name (if (keywordp name)
                          name
                          (make-keyword (string name)))))

    ;; 从缓存获取实例
    (let ((instance (gethash binding-name (di-singletons container))))
      (when instance
        ;; 调用清理方法（如果实现）
        (when (typep instance 'di-cleanup-p)
          (di-cleanup instance))

        ;; 从缓存移除
        (remhash binding-name (di-singletons container))
        t))))

(defun di-clear (container)
  "清空容器（释放所有服务）

参数：
  CONTAINER - DI 容器实例

返回：
  释放的服务数量

实现：
  1. 调用所有服务的清理方法
  2. 清空单例缓存
  3. 清空绑定表

示例：
  (di-clear container)

注意：
  - 会释放所有单例服务
  - 容器可以重新使用"
  (let ((count 0))
    ;; 调用所有单例的清理方法
    (maphash (lambda (name instance)
               (declare (ignore name))
               (when (typep instance 'di-cleanup-p)
                 (di-cleanup instance))
               (incf count))
             (di-singletons container))

    ;; 清空哈希表
    (clrhash (di-singletons container))
    (clrhash (di-bindings container))

    count))

;;; ============================================================
;;; 清理协议
;;; ============================================================

(defclass di-cleanup-p ()
  ()
  (:documentation "实现清理协议的类应该继承此类

如果服务实现了此协议，di-release 会自动调用清理方法

示例：
  (defclass database-connection (di-cleanup-p)
    ((connection :initarg :connection :accessor db-connection))
    (:documentation \"数据库连接，支持清理\"))

  (defmethod di-cleanup ((db database-connection))
    (close (db-connection db)))"))

(defgeneric di-cleanup (object)
  (:documentation "
清理对象的资源

参数：
  OBJECT - 对象实例

实现：
  具体的清理逻辑，如关闭连接、释放文件句柄等

示例：
  (defmethod di-cleanup ((db database-connection))
    (close (db-connection db))

  (defmethod di-cleanup ((file file-stream))
    (close file))"))

;;; ============================================================
;;; 辅助函数
;;; ============================================================

(defun di-container-size (container)
  "获取容器中绑定的服务数量

参数：
  CONTAINER - DI 容器实例

返回：
  绑定的服务数量"
  (hash-table-count (di-bindings container)))

(defun di-singleton-count (container)
  "获取容器中已创建的单例数量

参数：
  CONTAINER - DI 容器实例

返回：
  单例实例数量"
  (hash-table-count (di-singletons container)))

(defun di-list-services (container)
  "列出容器中所有绑定的服务

参数：
  CONTAINER - DI 容器实例

返回：
  服务名称列表"
  (loop for key being the hash-keys of (di-bindings container)
        collect key))

(defun di-boundp (container name)
  "检查服务是否已绑定

参数：
  CONTAINER - DI 容器实例
  NAME      - 服务名称

返回：
  t 如果已绑定，nil 否则

示例：
  (if (di-boundp container :database)
      (use-database)
      (register-database))"
  (declare (type (or symbol keyword) name))
  (let ((binding-name (if (keywordp name)
                          name
                          (make-keyword (string name)))))
    (not (null (gethash binding-name (di-bindings container))))))

(defun di-resolve-or-default (container name &key default (params nil))
  "解析服务或返回默认值

参数：
  CONTAINER - DI 容器实例
  NAME      - 服务名称
  DEFAULT   - 默认值（如果服务未注册）
  PARAMS    - 构造参数（可选）

返回：
  服务实例或默认值

示例：
  (di-resolve-or-default container :cache :default nil)

优势：
  - 用于可选依赖
  - 不会因服务未注册而抛出异常"
  (declare (type (or symbol keyword) name))
  (handler-case
      (di-resolve container name :params params)
    (error (c)
      (declare (ignore c))
      default)))

;;; ============================================================
;;; 调试和监控
;;; ============================================================

(defun di-container-stats (container)
  "获取容器统计信息

参数：
  CONTAINER - DI 容器实例

返回：
  plist 包含统计信息：
    :name - 容器名称
    :bindings - 绑定数量
    :singletons - 单例数量
    :has-parent - 是否有父容器

示例：
  (di-container-stats container)
  => (:name \"CONTAINER-123\" :bindings 3 :singletons 2 :has-parent nil)"
  (list :name (di-container-name container)
        :bindings (di-container-size container)
        :singletons (di-singleton-count container)
        :has-parent (not (null (di-container-parent container)))))

(defun di-print-container (container &optional (stream t))
  "打印容器信息（用于调试）

参数：
  CONTAINER - DI 容器实例
  STREAM    - 输出流（默认 t）

返回：
  nil

输出格式：
  Container: CONTAINER-123
  Bindings: 3
  Singletons: 2
  Parent: (or nil or parent-name)
  Services:
    - :MEMORY-STORE (singleton)
    - :TOOL-REGISTRY (singleton)
    - :DATABASE (singleton)

示例：
  (di-print-container container)"
  (let ((stats (di-container-stats container))
        (parent (di-container-parent container)))
    (format stream "~&Container: ~A~%" (getf stats :name))
    (format stream "  Bindings: ~A~%" (getf stats :bindings))
    (format stream "  Singletons: ~A~%" (getf stats :singletons))
    (format stream "  Parent: ~A~%" (if parent
                                         (di-container-name parent)
                                         "none"))
    (format stream "  Services:~%")
    (maphash (lambda (name binding)
               (let ((singleton-p (getf binding :singleton))
                      (scope (getf binding :scope)))
                 (format stream "    - ~A (~A, ~A)~%"
                         name
                         (if singleton-p "singleton" "prototype")
                         scope)))
             (di-bindings container))
    (values)))

;;; ============================================================
;;; 文档和示例
;;; ============================================================

;;;
;;; 依赖注入框架使用指南
;;;

;;;=== 基础使用 ===

;;;1. 创建容器：
;;;   (defvar *app-container* (make-di-container :name \"app\"))

;;;2. 绑定服务：
;;;   (di-bind *app-container* :database
;;;     (lambda () (make-db-connection \"localhost\"))
;;;     :singleton t)

;;;3. 解析服务：
;;;   (let ((db (di-resolve *app-container* :database)))
;;;     (query db \"SELECT * FROM users\"))

;;;=== 批量绑定 ===

;;;(di-bind* *app-container*
;;;  (:database (lambda () (make-db-connection)))
;;;  (:cache (lambda () (make-cache))
;;;    :singleton nil)
;;;  (:logger (lambda () (make-logger)))

;;;=== 依赖注入 ===

;;;(di-with-dependencies *app-container*
;;;    ((db (:database))
;;;     (cache (:cache))
;;;     (logger (:logger)))
;;;  ;; 使用服务
;;;  (logger-log logger \"Starting\")
;;;  (let ((results (db-query db \"SELECT * FROM users\"))
;;;        (cache-save cache results)))
;;;    (logger-log logger \"Done\"))

;;;=== 作用域控制 ===

;;;;; 单例：整个应用共享一个实例
;;;(di-bind container :config (lambda () (load-config))
;;;          :singleton t)

;;;;; 原型：每次创建新实例
;;;(di-bind container :request (lambda () (make-request))
;;;          :singleton nil)

;;;=== 生命周期管理 ===

;;;;; 释放单个服务
;;;(di-release container :database)

;;;;; 清空容器（释放所有服务）
;;;(di-clear container)

;;;=== 可选依赖 ===

;;;(di-with-dependencies container
;;;    ((db (:database))
;;;     (cache (:cache :default nil)))
;;;  ;; cache 是可选的，如果未注册则为 nil
;;;  (when cache
;;;    (cache-save cache data)))

;;;=== 层级容器 ===

;;;;; 父容器（全局服务）
;;;(defparameter *global-container* (make-di-container :name \"global\"))
;;;(di-bind *global-container* :logger #'make-logger)

;;;;; 子容器（继承全局服务）
;;;(let ((app-container (make-di-container
;;;                          :parent *global-container*
;;;                          :name \"app\")))
;;;  ;; app-container 可以访问 logger
;;;  (di-bind app-container :service #'make-service)

;;;  (di-with-dependencies app-container
;;;      ((service (:service))
;;;       (logger (:logger)))  ;; 从父容器继承
;;;    (use-services service logger))))

;;;=== 设计优势 ===

;;;1. 松耦合：
;;;   - 服务不直接创建依赖
;;;   - 通过容器解析依赖
;;;   - 易于替换和测试

;;;2. 可测试性：
;;;   - 使用 mock 容器注入测试服务
;;;   - 不需要修改生产代码

;;;3. 可维护性：
;;;   - 集中管理服务配置
;;;   - 清晰的依赖关系

;;;4. 灵活性：
;;;   - 支持不同作用域
;;;   - 支持层级容器
;;;   - 支持可选依赖
;;;
