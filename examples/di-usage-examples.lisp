;;;; di-usage-examples.lisp
;;;; CL-Agent - 依赖注入框架使用示例
;;;;
;;;; 概述：
;;;;   演示如何在 CL-Agent 中使用依赖注入框架
;;;;
;;;; 特性：
;;;;   - 服务绑定和解析
;;;;   - 单例和原型作用域
;;;;   - 层级容器
;;;;   - 生命周期管理

(in-package :cl-user)

;;; ============================================================
;;; 示例 1: 基础使用 - 简单的服务容器
;;; ============================================================

(defun example-1-basic-container ()
  "示例 1: 创建基本的 DI 容器

演示：
  - 创建容器
  - 绑定简单服务
  - 解析服务"

  ;; 1. 创建容器
  (defparameter *simple-container*
    (cl-agent.core:make-di-container :name "simple"))

  ;; 2. 绑定服务（工厂函数）
  (cl-agent.core:di-bind *simple-container* :greeting
    (lambda ()
      "Hello from DI Container!")
    :singleton t)

  ;; 3. 解析服务
  (let ((greeting (cl-agent.core:di-resolve *simple-container* :greeting)))
    (format t "~&Greeting: ~A~%" greeting))
  ;; => Greeting: Hello from DI Container!

  ;; 4. 验证单例：两次解析返回相同实例
  (let ((g1 (cl-agent.core:di-resolve *simple-container* :greeting))
        (g2 (cl-agent.core:di-resolve *simple-container* :greeting)))
    (format t "Same instance? ~A~%" (eq g1 g2)))
  ;; => Same instance? T

  :success)

;;; ============================================================
;;; 示例 2: 服务作用域
;;; ============================================================

(defun example-2-service-scopes ()
  "示例 2: 单例和原型作用域

演示：
  - 单例模式（同一实例）
  - 原型模式（不同实例）"

  (defparameter *scope-container*
    (cl-agent.core:make-di-container :name "scope"))

  ;; 1. 绑定单例服务
  (cl-agent.core:di-bind *scope-container* :singleton-service
    (lambda ()
      (cons :singleton (random 100)))
    :singleton t)

  ;; 2. 绑定原型服务
  (cl-agent.core:di-bind *scope-container* :prototype-service
    (lambda ()
      (cons :prototype (random 100)))
    :singleton nil)

  ;; 3. 测试单例：两次解析返回相同实例
  (let ((s1 (cl-agent.core:di-resolve *scope-container* :singleton-service))
        (s2 (cl-agent.core:di-resolve *scope-container* :singleton-service)))
    (format t "~&Singleton service:~%")
    (format t "  First:  ~A~%" s1)
    (format t "  Second: ~A~%" s2)
    (format t "  Same? ~A~%" (eq s1 s2)))
  ;; => Same? T

  ;; 4. 测试原型：两次解析返回不同实例
  (let ((p1 (cl-agent.core:di-resolve *scope-container* :prototype-service))
        (p2 (cl-agent.core:di-resolve *scope-container* :prototype-service)))
    (format t "~&Prototype service:~%")
    (format t "  First:  ~A~%" p1)
    (format t "  Second: ~A~%" p2)
    (format t "  Same? ~A~%" (eq p1 p2)))
  ;; => Same? NIL

  :success)

;;; ============================================================
;;; 示例 3: 批量绑定服务
;;; ============================================================

(defun example-3-batch-binding ()
  "示例 3: 使用 di-bind* 批量绑定服务

演示：
  - 批量绑定多个服务
  - 混合单例和原型作用域"

  (defparameter *batch-container*
    (cl-agent.core:make-di-container :name "batch"))

  ;; 批量绑定服务
  (cl-agent.core:di-bind* *batch-container*
    (:config
     (lambda () (list :debug t :verbose t))
     :singleton t)

    (:database
     (lambda () (list :connection "db-connection"))
     :singleton t)

    (:cache
     (lambda () (list :backend "memory"))
     :singleton nil)  ; 每次创建新实例

    (:logger
     (lambda () (list :level :info))
     :singleton t))

  ;; 验证绑定
  (format t "~&Services bound: ~A~%"
          (cl-agent.core:di-list-services *batch-container*))
  ;; => (:CONFIG :DATABASE :CACHE :LOGGER)

  ;; 测试原型作用域
  (let ((cache1 (cl-agent.core:di-resolve *batch-container* :cache))
        (cache2 (cl-agent.core:di-resolve *batch-container* :cache)))
    (format t "Cache is prototype? ~A~%" (not (eq cache1 cache2))))
  ;; => Cache is prototype? T

  :success)

;;; ============================================================
;;; 示例 4: 层级容器
;;; ============================================================

(defun example-4-hierarchical-containers ()
  "示例 4: 使用层级容器组织服务

演示：
  - 父容器（全局服务）
  - 子容器（应用特定服务）
  - 服务继承"

  ;; 1. 创建全局容器（父容器）
  (defparameter *global-container*
    (cl-agent.core:make-di-container :name "global"))

  ;; 绑定全局服务
  (cl-agent.core:di-bind *global-container* :logger
    (lambda () (list :level :info :name "global-logger"))
    :singleton t)

  (cl-agent.core:di-bind *global-container* :config
    (lambda () (list :version "2.0.0"))
    :singleton t)

  ;; 2. 创建应用容器（子容器）
  (defparameter *app-container*
    (cl-agent.core:make-di-container
     :parent *global-container*
     :name "app"))

  ;; 绑定应用特定服务
  (cl-agent.core:di-bind *app-container* :database
    (lambda () (list :connection "app-db"))
    :singleton t)

  ;; 3. 子容器可以访问父容器的服务
  (cl-agent.core:di-with-dependencies *app-container*
      ((logger (:logger))
       (config (:config))
       (database (:database)))
    (format t "~&Logger (from parent): ~A~%" logger)
    (format t "Config (from parent): ~A~%" config)
    (format t "Database (from child): ~A~%" database))

  ;; 4. 验证层级关系
  (format t "~&App container parent: ~A~%"
          (cl-agent.core:di-container-parent *app-container*))

  :success)

;;; ============================================================
;;; 示例 5: 可选依赖和默认值
;;; ============================================================

(defun example-5-optional-dependencies ()
  "示例 5: 处理可选依赖

演示：
  - 使用 di-resolve-or-default
  - 在 di-with-dependencies 中使用 :default"

  (defparameter *optional-container*
    (cl-agent.core:make-di-container :name "optional"))

  ;; 只绑定部分服务
  (cl-agent.core:di-bind *optional-container* :required-service
    (lambda () "Required service is available")
    :singleton t)

  ;; 1. 使用 di-resolve-or-default
  (let ((required (cl-agent.core:di-resolve-or-default
                   *optional-container* :required-service
                   :default "Not found"))
        (optional (cl-agent.core:di-resolve-or-default
                   *optional-container* :optional-service
                   :default "Default optional service")))

    (format t "~&Required: ~A~%" required)
    ;; => Required: Required service is available

    (format t "Optional: ~A~%" optional))
  ;; => Optional: Default optional service

  ;; 2. 在 di-with-dependencies 中使用默认值
  (cl-agent.core:di-with-dependencies *optional-container*
      ((required (:required-service))
       (optional (:optional-service :default "Default value")))
    (format t "~&In macro - Required: ~A~%" required)
    (format t "In macro - Optional: ~A~%" optional))

  :success)

;;; ============================================================
;;; 示例 6: 生命周期管理
;;; ============================================================

(defun example-6-lifecycle-management ()
  "示例 6: 管理服务生命周期

演示：
  - 释放单个服务
  - 清空容器
  - 检查绑定状态"

  (defparameter *lifecycle-container*
    (cl-agent.core:make-di-container :name "lifecycle"))

  ;; 绑定服务
  (cl-agent.core:di-bind *lifecycle-container* :service1
    (lambda () "Service 1")
    :singleton t)

  (cl-agent.core:di-bind *lifecycle-container* :service2
    (lambda () "Service 2")
    :singleton t)

  ;; 1. 检查绑定状态
  (format t "~&Service1 bound? ~A~%"
          (cl-agent.core:di-boundp *lifecycle-container* :service1))
  ;; => Service1 bound? T

  ;; 2. 获取容器统计
  (let ((stats (cl-agent.core:di-container-stats *lifecycle-container*)))
    (format t "~&Container stats:~%")
    (format t "  Name: ~A~%" (getf stats :name))
    (format t "  Bindings: ~A~%" (getf stats :bindings))
    (format t "  Singletons: ~A~%" (getf stats :singletons)))
  ;; => Container stats:
  ;;    Name: LIFECYCLE-123
  ;;    Bindings: 2
  ;;    Singletons: 0 (before resolution)

  ;; 3. 解析服务（创建单例）
  (cl-agent.core:di-resolve *lifecycle-container* :service1)
  (cl-agent.core:di-resolve *lifecycle-container* :service2)

  (let ((stats (cl-agent.core:di-container-stats *lifecycle-container*)))
    (format t "~&After resolution:~%")
    (format t "  Singletons: ~A~%" (getf stats :singletons)))
  ;; => Singletons: 2

  ;; 4. 释放单个服务
  (cl-agent.core:di-release *lifecycle-container* :service1)

  (let ((stats (cl-agent.core:di-container-stats *lifecycle-container*)))
    (format t "~&After releasing service1:~%")
    (format t "  Singletons: ~A~%" (getf stats :singletons)))
  ;; => Singletons: 1

  ;; 5. 清空容器
  (cl-agent.core:di-clear *lifecycle-container*)

  (let ((stats (cl-agent.core:di-container-stats *lifecycle-container*)))
    (format t "~&After clear:~%")
    (format t "  Singletons: ~A~%" (getf stats :singletons)))
  ;; => Singletons: 0

  :success)

;;; ============================================================
;;; 示例 7: 完整的层级应用结构
;;; ============================================================

(defun example-7-complete-hierarchical-app ()
  "示例 7: 完整的层级应用结构

演示：
  - 构建三层架构
  - 服务依赖关系
  - 层级继承"

  ;; 1. 全局服务层
  (defparameter *global-services*
    (cl-agent.core:make-di-container :name "global"))

  (cl-agent.core:di-bind* *global-services*
    (:logger
     (lambda () (list :level :debug))
     :singleton t)

    (:metrics
     (lambda () (list :enabled t))
     :singleton t))

  ;; 2. 核心服务层
  (defparameter *core-services*
    (cl-agent.core:make-di-container
     :parent *global-services*
     :name "core"))

  (cl-agent.core:di-bind* *core-services*
    (:memory
     (lambda () (list :type "in-memory"))
     :singleton t)

    (:tools
     (lambda () (list :count 10))
     :singleton t))

  ;; 3. 应用层
  (defparameter *app-services*
    (cl-agent.core:make-di-container
     :parent *core-services*
     :name "app"))

  (cl-agent.core:di-bind* *app-services*
    (:config
     (lambda ()
       (list :max-iterations 10
             :timeout 300))
     :singleton t))

  ;; 4. 使用服务
  (cl-agent.core:di-with-dependencies *app-services*
      ((memory (:memory))
       (tools (:tools))
       (config (:config))
       (logger (:logger))  ; 从全局层继承
       (metrics (:metrics))) ; 从全局层继承

    ;; 创建服务列表
    (format t "~&Creating App with:~%")
    (format t "  Memory: ~A~%" memory)
    (format t "  Tools: ~A~%" tools)
    (format t "  Config: ~A~%" config)
    (format t "  Logger: ~A~%" logger)
    (format t "  Metrics: ~A~%" metrics)

    ;; 返回服务列表
    (list :memory memory
          :tools tools
          :config config
          :logger logger
          :metrics metrics))

  ;; 5. 打印容器层级结构
  (format t "~%~%Container Hierarchy:~%")
  (format t "==================~%")
  (cl-agent.core:di-print-container *app-services*)

  :success)

;;; ============================================================
;;; 示例 8: 懒加载依赖
;;; ============================================================

(defun example-8-lazy-dependencies ()
  "示例 8: 使用懒加载优化性能

演示：
  - di-lazy-dependency: 延迟解析
  - di-lazy-service: 延迟绑定"

  (defparameter *lazy-container*
    (cl-agent.core:make-di-container :name "lazy"))

  ;; 绑定昂贵的服务
  (cl-agent.core:di-bind *lazy-container* :expensive-service
    (lambda ()
      (format t "~&[Creating expensive service...]~%")
      (list :data "expensive-data"))
    :singleton t)

  ;; 1. 使用懒加载依赖
  (cl-agent.core:di-with-dependencies *lazy-container*
      ((cheap-service (cl-agent.core:di-lazy-dependency
                       :expensive-service)))
    (format t "~&Dependency created (not resolved yet)~%")

    ;; 首次使用时才会解析
    (format t "~&Using service: ~A~%" cheap-service))

  ;; 2. 使用懒加载服务（直接解析，不使用宏）
  (format t "~&Testing lazy dependency resolution~%")

  :success)

;;; ============================================================
;;; 运行所有示例
;;; ============================================================

(defun run-all-di-examples ()
  "运行所有依赖注入示例

返回：
  成功/失败结果列表"

  (format t "~%~%")
  (format t "========================================~%")
  (format t "CL-Agent 依赖注入示例~%")
  (format t "========================================~%")

  (let ((results
          (list
            ;; 示例 1: 基础使用
            (format t "~%~%示例 1: 基础容器~%")
            (format t "-------------------~%")
            (example-1-basic-container)

            ;; 示例 2: 服务作用域
            (format t "~%~%示例 2: 服务作用域~%")
            (format t "---------------~%")
            (example-2-service-scopes)

            ;; 示例 3: 批量绑定
            (format t "~%~%示例 3: 批量绑定~%")
            (format t "---------------~%")
            (example-3-batch-binding)

            ;; 示例 4: 层级容器
            (format t "~%~%示例 4: 层级容器~%")
            (format t "---------------~%")
            (example-4-hierarchical-containers)

            ;; 示例 5: 可选依赖
            (format t "~%~%示例 5: 可选依赖~%")
            (format t "---------------~%")
            (example-5-optional-dependencies)

            ;; 示例 6: 生命周期管理
            (format t "~%~%示例 6: 生命周期管理~%")
            (format t "--------------------~%")
            (example-6-lifecycle-management)

            ;; 示例 7: 完整应用
            (format t "~%~%示例 7: 完整层级应用~%")
            (format t "--------------------~%")
            (example-7-complete-hierarchical-app)

            ;; 示例 8: 懒加载
            (format t "~%~%示例 8: 懒加载依赖~%")
            (format t "----------------~%")
            (example-8-lazy-dependencies))))

    (format t "~%~%")
    (format t "========================================~%")
    (format t "所有示例运行完成！~%")
    (format t "========================================~%")

    results))

;;; ============================================================
;;; 导出函数
;;; ============================================================

(export '(run-all-di-examples
          example-1-basic-container
          example-2-service-scopes
          example-3-batch-binding
          example-4-hierarchical-containers
          example-5-optional-dependencies
          example-6-lifecycle-management
          example-7-complete-hierarchical-app
          example-8-lazy-dependencies))
