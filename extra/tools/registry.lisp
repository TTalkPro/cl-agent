;;;; registry.lisp
;;;; CL-Agent Tools - 工具注册表
;;;;
;;;; 概述：
;;;;   管理多个 Tool Provider，提供统一的工具访问接口
;;;;
;;;; 功能：
;;;;   - 管理多个 Provider
;;;;   - 工具缓存和查找
;;;;   - 冲突解决
;;;;   - 统一执行接口

(in-package #:cl-agent.tools)

;;; ============================================================
;;; 工具注册表类
;;; ============================================================

(defclass tool-registry (tool-provider)
  ((providers
    :accessor registry-providers
    :initform nil
    :type list
    :documentation "提供者列表（按优先级排序）")

   (tool-cache
    :accessor registry-tool-cache
    :initform (make-hash-table :test #'eq)
    :documentation "工具缓存：name -> (provider . tool)")

   (conflict-resolution
    :initarg :conflict-resolution
    :accessor registry-conflict-resolution
    :initform :first-wins
    :type (member :first-wins :last-wins :error)
    :documentation "工具名称冲突解决策略
- :first-wins  - 使用第一个提供者的工具（默认）
- :last-wins   - 使用最后一个提供者的工具
- :error       - 遇到冲突抛出错误")

   (cache-valid
    :accessor registry-cache-valid-p
    :initform nil
    :type boolean
    :documentation "缓存是否有效")

   ;; 权限配置
   (permissions-enabled
    :initarg :permissions-enabled
    :accessor registry-permissions-enabled-p
    :initform nil
    :type boolean
    :documentation "是否启用权限检查")

   (allowed-permissions
    :initarg :allowed-permissions
    :accessor registry-allowed-permissions
    :initform '(:all)
    :type list
    :documentation "允许的权限列表")

   ;; 详细日志配置
   (verbose
    :initarg :verbose
    :accessor registry-verbose-p
    :initform nil
    :type boolean
    :documentation "是否启用详细日志输出"))

  (:documentation "工具注册表，继承自 tool-provider。
支持：
1. 直接注册工具（使用继承的 tools 槽）
2. 管理多个子 provider
3. 工具缓存和冲突解决
直接注册的工具优先级最高。"))

;;; ============================================================
;;; 构造函数
;;; ============================================================

(defun make-tool-registry (&rest providers)
  "创建工具注册表（继承自 tool-provider）

参数:
  PROVIDERS - 提供者实例列表（可选）

关键字参数:
  :conflict-resolution - 冲突解决策略（可选，默认 :first-wins）

返回:
  tool-registry 实例

示例:
  (make-tool-registry provider1 provider2)
  (make-tool-registry provider1 provider2 :conflict-resolution :error)"
  (let ((registry (make-instance 'tool-registry
                                 :name "registry"
                                 :enabled t))
        (conflict-resolution :first-wins))

    ;; 提取关键字参数
    (when (and providers (keywordp (first (last providers 2))))
      (setf conflict-resolution (first (last providers)))
      (setf providers (butlast providers 2)))

    (setf (registry-conflict-resolution registry) conflict-resolution)

    ;; 添加提供者
    (dolist (provider providers)
      (add-provider registry provider))

    registry))

;;; ============================================================
;;; Provider 管理
;;; ============================================================

(defun add-provider (registry provider)
  "添加提供者到注册表

参数:
  REGISTRY - 注册表实例
  PROVIDER - 提供者实例

返回:
  provider

说明:
  - 自动初始化提供者（如果未初始化）
  - 使缓存失效
  - 不允许嵌套 registry（防止循环依赖）"
  ;; Prevent circular dependency - no registry nesting
  (when (typep provider 'tool-registry)
    (error "Cannot add tool-registry as a provider (nesting not supported)"))

  ;; 初始化提供者（如果需要）
  (unless (provider-enabled-p provider)
    (enable-provider provider))
  (initialize-provider provider)

  ;; 添加到列表末尾
  (setf (registry-providers registry)
        (append (registry-providers registry) (list provider)))

  ;; 使缓存失效
  (invalidate-cache registry)

  provider)

(defun remove-provider (registry provider-name)
  "从注册表移除提供者

参数:
  REGISTRY      - 注册表实例
  PROVIDER-NAME - 提供者名称（字符串）

返回:
  被移除的 provider，如果未找到返回 nil"
  (let ((provider (find-provider registry provider-name)))
    (when provider
      ;; 从列表中移除
      (setf (registry-providers registry)
            (remove provider (registry-providers registry)))

      ;; 关闭提供者
      (shutdown-provider provider)

      ;; 使缓存失效
      (invalidate-cache registry))

    provider))

(defun find-provider (registry provider-name)
  "在注册表中查找提供者

参数:
  REGISTRY      - 注册表实例
  PROVIDER-NAME - 提供者名称（字符串）

返回:
  provider 实例，如果未找到返回 nil"
  (find provider-name (registry-providers registry)
        :key #'provider-name
        :test #'string=))

(defun list-providers (registry)
  "列出注册表中的所有提供者

参数:
  REGISTRY - 注册表实例

返回:
  提供者列表"
  (copy-list (registry-providers registry)))

;;; ============================================================
;;; 缓存管理
;;; ============================================================

(defun invalidate-cache (registry)
  "使工具缓存失效

参数:
  REGISTRY - 注册表实例

返回:
  registry"
  (setf (registry-cache-valid-p registry) nil)
  registry)

(defun rebuild-tool-cache (registry)
  "重建工具缓存

参数:
  REGISTRY - 注册表实例

返回:
  registry

说明:
  根据冲突解决策略构建缓存"
  ;; 清空缓存
  (clrhash (registry-tool-cache registry))

  (let ((conflict-resolution (registry-conflict-resolution registry))
        (providers (registry-providers registry)))

    ;; 根据策略决定遍历顺序
    (let ((ordered-providers (case conflict-resolution
                              (:first-wins providers)
                              (:last-wins (reverse providers))
                              (:error providers))))

      ;; 遍历提供者
      (dolist (provider ordered-providers)
        (when (provider-enabled-p provider)
          ;; 遍历工具
          (maphash (lambda (tool-name tool)
                    (let ((existing (gethash tool-name (registry-tool-cache registry))))
                      ;; 处理冲突
                      (cond
                        ;; 没有冲突，直接添加
                        ((null existing)
                         (setf (gethash tool-name (registry-tool-cache registry))
                               (cons provider tool)))

                        ;; :error 策略，抛出错误
                        ((eq conflict-resolution :error)
                         (error "Tool name conflict: ~A exists in both ~A and ~A"
                                tool-name
                                (provider-name (car existing))
                                (provider-name provider)))

                        ;; :first-wins，跳过（已有工具）
                        ((eq conflict-resolution :first-wins)
                         nil)  ; 不覆盖

                        ;; :last-wins，覆盖
                        ((eq conflict-resolution :last-wins)
                         (setf (gethash tool-name (registry-tool-cache registry))
                               (cons provider tool))))))
                  (provider-tools provider))))))

  ;; 标记缓存有效
  (setf (registry-cache-valid-p registry) t)

  registry)

(defun ensure-cache-valid (registry)
  "确保缓存有效，如果无效则重建

参数:
  REGISTRY - 注册表实例

返回:
  registry"
  (unless (registry-cache-valid-p registry)
    (rebuild-tool-cache registry))
  registry)

;;; ============================================================
;;; 泛型方法重写（tool-provider 协议）
;;; ============================================================

(defmethod find-tool ((registry tool-registry) tool-name)
  "查找工具：优先直接注册的工具，然后查找子 provider

参数:
  REGISTRY  - 注册表实例
  TOOL-NAME - 工具名称（关键字）

返回:
  tool 实例，如果未找到返回 nil

优先级:
  1. 直接注册的工具（继承的 tools 槽）
  2. Provider 工具（从 tool-cache）"
  ;; Priority 1: Direct tools (inherited from tool-provider)
  (or (call-next-method)  ; Calls tool-provider's find-tool
      ;; Priority 2: Provider tools (from cache)
      (progn
        (ensure-cache-valid registry)
        (let ((cached (gethash tool-name (registry-tool-cache registry))))
          (when cached (cdr cached))))))

(defmethod register-tool ((registry tool-registry) (tool tool))
  "注册直接工具到 registry (继承的 tools 槽)

参数:
  REGISTRY - 注册表实例
  TOOL     - 工具实例

返回:
  tool

说明:
  - 添加到直接工具表（优先级最高）
  - 使缓存失效"
  ;; Call parent to add to tools hash-table
  (call-next-method)
  ;; Invalidate cache since we added a direct tool
  (invalidate-cache registry)
  tool)

(defmethod list-tools ((registry tool-registry) &key category)
  "列出所有工具：直接工具 + provider 工具

参数:
  REGISTRY - 注册表实例
  CATEGORY - 可选，按分类过滤

返回:
  工具列表

说明:
  合并直接工具和所有 provider 的工具"
  (ensure-cache-valid registry)
  (let ((tools nil)
        (seen-names (make-hash-table :test #'eq)))

    ;; Add direct tools (inherited)
    (maphash (lambda (name tool)
               (when (or (null category)
                        (eq (tool-category tool) category))
                 (push tool tools)
                 (setf (gethash name seen-names) t)))
             (provider-tools registry))

    ;; Add provider tools from cache (avoid duplicates)
    (maphash (lambda (name cached)
               (let ((tool (cdr cached)))
                 (when (and (or (null category)
                               (eq (tool-category tool) category))
                           (not (gethash name seen-names)))
                   (push tool tools))))
             (registry-tool-cache registry))

    (nreverse tools)))

(defmethod execute-tool ((registry tool-registry) tool-name &rest args)
  "执行工具：先查找（直接优先），然后委托给对应 provider

参数:
  REGISTRY  - 注册表实例
  TOOL-NAME - 工具名称（关键字）
  ARGS      - 工具参数（关键字参数）

返回:
  工具执行结果

错误:
  - 如果注册表被禁用，抛出错误
  - 如果工具未找到，抛出错误"
  (unless (provider-enabled-p registry)
    (error "Registry is disabled"))

  ;; Find tool (direct first, then cache)
  (let ((tool (find-tool registry tool-name)))
    (unless tool
      (error "Tool ~A not found" tool-name))

    ;; Check if it's a direct tool
    (if (gethash tool-name (provider-tools registry))
        ;; Direct tool: execute directly
        (apply (tool-handler tool) args)
        ;; Provider tool: delegate to provider
        (let* ((cached (gethash tool-name (registry-tool-cache registry)))
               (provider (car cached)))
          (apply #'execute-tool provider tool-name args)))))

(defun list-all-tools (registry &key category provider)
  "列出注册表中的所有工具

参数:
  REGISTRY - 注册表实例

关键字参数:
  CATEGORY - 按分类过滤（可选）
  PROVIDER - 按提供者名称过滤（可选）

返回:
  工具列表"
  (ensure-cache-valid registry)

  (let ((tools nil))
    (maphash (lambda (tool-name cached)
               (declare (ignore tool-name))
               (let ((tool (cdr cached))
                     (prov (car cached)))
                 (when (and (or (null category)
                               (eq (tool-category tool) category))
                           (or (null provider)
                               (string= (provider-name prov) provider)))
                   (push tool tools))))
             (registry-tool-cache registry))
    (nreverse tools)))

(defun tool-exists-p (registry tool-name)
  "检查工具是否存在于注册表中

参数:
  REGISTRY  - 注册表实例
  TOOL-NAME - 工具名称

返回:
  t 或 nil"
  (ensure-cache-valid registry)
  (not (null (gethash tool-name (registry-tool-cache registry)))))

;;; ============================================================
;;; 统计和信息
;;; ============================================================

(defun registry-tool-count (registry)
  "获取注册表中的工具总数（直接注册的工具 + provider 工具）

参数:
  REGISTRY - 注册表实例

返回:
  工具数量（整数）"
  (ensure-cache-valid registry)
  (let ((cache (registry-tool-cache registry))
        (direct (provider-tools registry))
        (count 0))
    ;; 直接注册的工具优先
    (incf count (hash-table-count direct))
    ;; provider 工具中未被直接工具遮蔽的部分
    (maphash (lambda (name entry)
               (declare (ignore entry))
               (unless (gethash name direct)
                 (incf count)))
             cache)
    count))

(defun registry-provider-count (registry)
  "获取注册表中的提供者数量

参数:
  REGISTRY - 注册表实例

返回:
  提供者数量（整数）"
  (length (registry-providers registry)))

(defun print-registry-info (registry &optional (stream *standard-output*))
  "打印注册表信息

参数:
  REGISTRY - 注册表实例
  STREAM   - 输出流（可选，默认 *standard-output*）

返回:
  registry"
  (ensure-cache-valid registry)

  (format stream "~%Tool Registry Information:~%")
  (format stream "  Providers: ~A~%" (registry-provider-count registry))
  (format stream "  Tools: ~A~%" (registry-tool-count registry))
  (format stream "  Conflict Resolution: ~A~%" (registry-conflict-resolution registry))

  (format stream "~%Providers:~%")
  (dolist (provider (registry-providers registry))
    (format stream "  - ~A (~A tools, ~:[disabled~;enabled~])~%"
            (provider-name provider)
            (provider-tool-count provider)
            (provider-enabled-p provider)))

  registry)

;;; ============================================================
;;; Tag 过滤功能
;;; ============================================================

(defun list-tools-by-tag (registry tag)
  "按单个标签过滤工具

参数:
  REGISTRY - 注册表实例
  TAG      - 标签（关键字）

返回:
  匹配的工具列表"
  (list-tools-by-tags registry (list tag) :mode :any))

(defun list-tools-by-tags (registry tags &key (mode :any))
  "按标签列表过滤工具

参数:
  REGISTRY - 注册表实例
  TAGS     - 标签列表
  MODE     - 匹配模式
           - :any  - 工具具有任一标签即匹配（默认）
           - :all  - 工具必须具有所有标签才匹配

返回:
  匹配的工具列表"
  (when (null tags)
    (return-from list-tools-by-tags (list-tools registry)))

  (let ((all-tools (list-tools registry))
        (matcher (case mode
                   (:all #'tool-has-all-tags-p)
                   (otherwise #'tool-has-any-tag-p))))
    (remove-if-not (lambda (tool)
                    (funcall matcher tool tags))
                  all-tools)))

(defun get-tools-schema-by-tags (registry tags &key (mode :any))
  "获取按标签过滤后的工具 Schema 列表

参数:
  REGISTRY - 注册表实例
  TAGS     - 标签列表（nil 表示不过滤）
  MODE     - 匹配模式 (:any 或 :all)

返回:
  Schema 列表，每个元素为:
  (:name \"tool-name\" :description \"...\" :input-schema hash-table)"
  (let ((tools (if tags
                   (list-tools-by-tags registry tags :mode mode)
                   (list-tools registry))))
    (mapcar #'tool-to-json-schema tools)))

(defun list-all-tags (registry)
  "列出注册表中所有工具的标签

参数:
  REGISTRY - 注册表实例

返回:
  标签列表（去重）"
  (let ((tags nil))
    (dolist (tool (list-tools registry))
      (dolist (tag (tool-tags tool))
        (pushnew tag tags :test #'eq)))
    (nreverse tags)))

(defun count-tools-by-tag (registry)
  "统计每个标签下的工具数量

参数:
  REGISTRY - 注册表实例

返回:
  alist ((tag . count) ...)"
  (let ((tag-counts (make-hash-table :test #'eq)))
    (dolist (tool (list-tools registry))
      (dolist (tag (tool-tags tool))
        (incf (gethash tag tag-counts 0))))
    (let ((result nil))
      (maphash (lambda (tag count)
                 (push (cons tag count) result))
               tag-counts)
      (sort result #'> :key #'cdr))))
