;;;; kernel.lisp
;;;; CL-Agent Kernel - Kernel Core Class + Builder API
;;;;
;;;; Overview:
;;;;   Kernel is the central coordinator of the Semantic Kernel architecture.
;;;;   It holds:
;;;;   - Service: Abstraction over LLM provider (chat-fn + build-result-msgs)
;;;;   - Tool Registry: Direct tool management with tag-based filtering
;;;;   - Filters: Filter functions for tool execution pipeline
;;;;   - Config: Configuration plist
;;;;
;;;; Design:
;;;;   - Builder pattern for fluent construction
;;;;   - Service abstraction decouples from LLM specifics
;;;;   - Query API for tool/schema access
;;;;   - Thread-safe operations
;;;;   - Tag-based tool filtering
;;;;
;;;; Note:
;;;;   This file uses the cl-agent.tools package if available.
;;;;   Functions are resolved at runtime to avoid circular dependencies.

(in-package #:cl-agent.kernel)

;;; ============================================================
;;; Runtime Package Resolution (avoid circular dependencies)
;;; ============================================================

(defun tools-package-available-p ()
  "Check if cl-agent.tools package is available."
  (find-package :cl-agent.tools))

(defun call-tools-function (name &rest args)
  "Call a function from cl-agent.tools package by name.
   Returns NIL if package not available."
  (when (tools-package-available-p)
    (let ((fn (find-symbol (string name) :cl-agent.tools)))
      (when (and fn (fboundp fn))
        (apply (symbol-function fn) args)))))

(defun make-default-tool-registry ()
  "Create a default tool registry if cl-agent.tools is available."
  (call-tools-function "MAKE-TOOL-REGISTRY"))

;;; ============================================================
;;; Tools Package Function Wrappers
;;; ============================================================
;;; These functions wrap calls to cl-agent.tools package to avoid
;;; compile-time dependencies while maintaining clean code.

(defun %tools-register-tool (registry tool)
  "Register a tool to registry."
  (call-tools-function "REGISTER-TOOL" registry tool))

(defun %tools-unregister-tool (registry tool-name)
  "Unregister a tool from registry."
  (call-tools-function "UNREGISTER-TOOL" registry tool-name))

(defun %tools-find-tool (registry tool-name)
  "Find a tool in registry."
  (call-tools-function "FIND-TOOL" registry tool-name))

(defun %tools-list-tools (registry)
  "List all tools in registry."
  (call-tools-function "LIST-TOOLS" registry))

(defun %tools-list-tools-by-tags (registry tags &key (mode :any))
  "List tools by tags."
  (call-tools-function "LIST-TOOLS-BY-TAGS" registry tags :mode mode))

(defun %tools-registry-tool-count (registry)
  "Get tool count from registry."
  (or (call-tools-function "REGISTRY-TOOL-COUNT" registry) 0))

(defun %tools-invalidate-cache (registry)
  "Invalidate registry cache."
  (call-tools-function "INVALIDATE-CACHE" registry))

(defun %tools-get-tools-schema-by-tags (registry tags &key (mode :any))
  "Get tools schema by tags."
  (call-tools-function "GET-TOOLS-SCHEMA-BY-TAGS" registry tags :mode mode))

(defun %tools-tool-to-json-schema (tool)
  "Convert tool to JSON schema."
  (call-tools-function "TOOL-TO-JSON-SCHEMA" tool))

(defun %tools-validate-arguments (tool args)
  "Validate tool arguments."
  (call-tools-function "VALIDATE-ARGUMENTS" tool args))

(defun %tools-tool-handler (tool)
  "Get tool handler."
  (call-tools-function "TOOL-HANDLER" tool))

(defun %tools-tool-name (tool)
  "Get tool name."
  (call-tools-function "TOOL-NAME" tool))

(defun %tools-tool-description (tool)
  "Get tool description."
  (call-tools-function "TOOL-DESCRIPTION" tool))

(defun %tools-tool-tags (tool)
  "Get tool tags."
  (call-tools-function "TOOL-TAGS" tool))

(defun %tools-tool-category (tool)
  "Get tool category."
  (call-tools-function "TOOL-CATEGORY" tool))

(defun %tools-tool-add-tag (tool tag)
  "Add tag to tool."
  (call-tools-function "TOOL-ADD-TAG" tool tag))

(defun %tools-list-all-tags (registry)
  "List all tags in registry."
  (call-tools-function "LIST-ALL-TAGS" registry))

(defun %tools-quick-setup-tools (&key preset security-level)
  "Quick setup tools with preset."
  (call-tools-function "QUICK-SETUP-TOOLS" :preset preset :security-level security-level))

(defun %tools-make-tool (&rest initargs)
  "Create a cl-agent.tools:tool instance (reflectively).
   Returns NIL if the tools package is not available."
  (when (tools-package-available-p)
    (let ((tool-class (find-symbol "TOOL" :cl-agent.tools)))
      (when tool-class
        (apply #'make-instance tool-class initargs)))))

;;; ============================================================
;;; Kernel Class
;;; ============================================================

(defclass kernel ()
  ((service
    :initarg :service
    :accessor kernel-service
    :initform nil
    :documentation "Service plist (:chat-fn :build-result-msgs :provider :config)")

   (config
    :initarg :config
    :accessor kernel-config
    :initform nil
    :documentation "Configuration plist (:max-tokens, :temperature, etc.)")

   ;; NEW: Tool Registry - direct tool management
   (tool-registry
    :initarg :tool-registry
    :accessor kernel-tool-registry
    :initform nil
    :documentation "Tool registry for direct tool management")

   ;; NEW: Active tags for filtering
   (active-tags
    :initarg :active-tags
    :accessor kernel-active-tags
    :initform nil
    :documentation "Active tags for tool filtering (nil = no filter)")

   ;; Tag filter mode
   (tag-filter-mode
    :initarg :tag-filter-mode
    :accessor kernel-tag-filter-mode
    :initform :any
    :documentation "Tag filter mode: :any (match any tag) or :all (match all tags)")

   (filters
    :initarg :filters
    :accessor kernel-filters
    :initform nil
    :documentation "Filter functions list")

   (tools-cache
    :accessor kernel-tools-cache
    :initform nil
    :documentation "Cached tool schemas (auto-invalidated)")

   (context
    :initarg :context
    :accessor kernel-context
    :initform nil
    :documentation "Default execution context")

   (lock
    :initform (bt:make-lock "kernel-lock")
    :reader kernel-lock
    :documentation "Thread-safe lock for kernel modifications"))

  (:documentation "Kernel - Central coordinator for Semantic Kernel architecture.
Holds service, tool-registry, filters, and configuration.
Supports tag-based tool filtering."))

;;; ============================================================
;;; Constructor
;;; ============================================================

(defun make-kernel (&key service config tool-registry plugins active-tags
                         tag-filter-mode filters context)
  "Create a Kernel instance.

Parameters:
  SERVICE         - Service plist or LLM provider
  CONFIG          - Configuration plist
  TOOL-REGISTRY   - Tool registry for direct tool management
  PLUGINS         - List of plugin symbols (declare-plugin/defplugin);
                    their tools are registered into the tool registry
  ACTIVE-TAGS     - Active tags for filtering (nil = no filter)
  TAG-FILTER-MODE - :any or :all (default :any)
  FILTERS         - Filter function list
  CONTEXT         - Default execution context

Returns:
  Kernel instance"
  (let* ((effective-service (if (service-p service)
                                service
                                (when service
                                  (service-from-provider service :config config))))
         (kernel (make-instance 'kernel
                               :service effective-service
                               :config config
                               :tool-registry tool-registry
                               :active-tags active-tags
                               :tag-filter-mode (or tag-filter-mode :any)
                               :filters filters
                               :context context)))
    ;; Create default tool-registry if not provided and tools package is available
    (unless (kernel-tool-registry kernel)
      (setf (kernel-tool-registry kernel)
            (make-default-tool-registry)))
    ;; Register plugin tools into the registry
    (dolist (plugin plugins)
      (kernel-add-plugin kernel plugin))
    kernel))

;;; ============================================================
;;; Kernel Builder
;;; ============================================================

(defclass kernel-builder ()
  ((service
    :initform nil
    :accessor builder-service)
   (config
    :initform nil
    :accessor builder-config)
   (tool-registry
    :initform nil
    :accessor builder-tool-registry)
   (tools
    :initform nil
    :accessor builder-tools)
   (active-tags
    :initform nil
    :accessor builder-active-tags)
   (tag-filter-mode
    :initform :any
    :accessor builder-tag-filter-mode)
   (filters
    :initform nil
    :accessor builder-filters)
   (context
    :initform nil
    :accessor builder-context))
  (:documentation "Builder for constructing Kernel instances fluently."))

(defun create-kernel-builder ()
  "Create a new KernelBuilder instance.

Returns:
  New kernel-builder instance

Usage:
  (-> (create-kernel-builder)
      (with-tool my-tool)
      (with-tools (list tool1 tool2))
      (with-active-tags '(:file :safe))
      (add-service my-service)
      (add-filter my-filter)
      (build-kernel))"
  (make-instance 'kernel-builder))

;;; --- Tool Management (NEW) ---

(defgeneric with-tool (builder tool &key tags)
  (:documentation "Add a tool to the builder.

Parameters:
  BUILDER - Kernel builder
  TOOL    - Tool instance
  TAGS    - Optional tags to add to the tool

Returns:
  The builder (for chaining)"))

(defmethod with-tool ((builder kernel-builder) tool &key tags)
  "Add a tool to the builder."
  ;; Add tags if provided
  (when tags
    (dolist (tag tags)
      (%tools-tool-add-tag tool tag)))
  (push tool (builder-tools builder))
  builder)

(defgeneric with-tools (builder tools)
  (:documentation "Add multiple tools to the builder.

Parameters:
  BUILDER - Kernel builder
  TOOLS   - List of tool instances

Returns:
  The builder (for chaining)"))

(defmethod with-tools ((builder kernel-builder) tools)
  "Add multiple tools to the builder."
  (setf (builder-tools builder)
        (append (builder-tools builder) tools))
  builder)

(defgeneric with-tool-registry (builder registry)
  (:documentation "Set the tool registry for the builder.

Parameters:
  BUILDER  - Kernel builder
  REGISTRY - Tool registry instance

Returns:
  The builder (for chaining)"))

(defmethod with-tool-registry ((builder kernel-builder) registry)
  "Set the tool registry for the builder."
  (setf (builder-tool-registry builder) registry)
  builder)

(defgeneric with-active-tags (builder tags &key mode)
  (:documentation "Set active tags for tool filtering.

Parameters:
  BUILDER - Kernel builder
  TAGS    - Tag list for filtering
  MODE    - :any or :all (default :any)

Returns:
  The builder (for chaining)"))

(defmethod with-active-tags ((builder kernel-builder) tags &key (mode :any))
  "Set active tags for tool filtering."
  (setf (builder-active-tags builder) tags)
  (setf (builder-tag-filter-mode builder) mode)
  builder)

(defgeneric with-preset (builder preset &key security-level)
  (:documentation "Add tools from a preset.

Parameters:
  BUILDER        - Kernel builder
  PRESET         - Preset name: :standard :safe :full :file-only :http-only :utility-only
  SECURITY-LEVEL - Security level: :permissive :standard :strict

Returns:
  The builder (for chaining)"))

(defmethod with-preset ((builder kernel-builder) preset &key (security-level :standard))
  "Add tools from a preset."
  (let ((tools (%tools-quick-setup-tools :preset preset
                                                  :security-level security-level)))
    (with-tools builder tools)))

;;; --- Service and Filter Management ---

(defgeneric add-service (builder service)
  (:documentation "Set the service for the builder.

Parameters:
  BUILDER - Kernel builder
  SERVICE - Service plist or LLM provider

Returns:
  The builder (for chaining)"))

(defmethod add-service ((builder kernel-builder) service)
  "Set the service for the builder.
   Accepts either a service plist or an LLM provider."
  (setf (builder-service builder) service)
  builder)

(defgeneric add-filter (builder filter)
  (:documentation "Add a filter to the builder.

Parameters:
  BUILDER - Kernel builder
  FILTER  - Filter function

Returns:
  The builder (for chaining)"))

(defmethod add-filter ((builder kernel-builder) filter)
  "Add filter(s) to the builder."
  (if (listp filter)
      (setf (builder-filters builder)
            (append (builder-filters builder) filter))
      (push filter (builder-filters builder)))
  builder)

(defgeneric with-config (builder config)
  (:documentation "Set configuration for the builder.

Parameters:
  BUILDER - Kernel builder
  CONFIG  - Configuration plist

Returns:
  The builder (for chaining)"))

(defmethod with-config ((builder kernel-builder) config)
  "Set configuration for the builder."
  (setf (builder-config builder) config)
  builder)

(defgeneric builder-with-context (builder context)
  (:documentation "Set default context for the builder.

Parameters:
  BUILDER - Kernel builder
  CONTEXT - Context instance

Returns:
  The builder (for chaining)"))

(defmethod builder-with-context ((builder kernel-builder) context)
  "Set default context for the builder."
  (setf (builder-context builder) context)
  builder)

;;; --- Build ---

(defgeneric build-kernel (builder)
  (:documentation "Build the Kernel from the builder state.

Parameters:
  BUILDER - Kernel builder

Returns:
  New Kernel instance"))

(defmethod build-kernel ((builder kernel-builder))
  "Build Kernel from builder."
  (let* ((registry (or (builder-tool-registry builder)
                       (make-default-tool-registry)))
         (kernel (make-kernel
                  :service (builder-service builder)
                  :config (builder-config builder)
                  :tool-registry registry
                  :active-tags (builder-active-tags builder)
                  :tag-filter-mode (builder-tag-filter-mode builder)
                  :filters (nreverse (builder-filters builder))
                  :context (builder-context builder))))
    ;; Register tools to registry
    (dolist (tool (nreverse (builder-tools builder)))
      (%tools-register-tool registry tool))
    kernel))

;;; ============================================================
;;; Tool Lookup (NEW - Registry-based)
;;; ============================================================

(defun kernel-find-tool (kernel tool-name)
  "Find a tool in the kernel's tool registry.

Parameters:
  KERNEL    - Kernel instance
  TOOL-NAME - Tool name (keyword)

Returns:
  Tool instance, or NIL if not found"
  (%tools-find-tool (kernel-tool-registry kernel) tool-name))

(defun kernel-find-tool-by-name (kernel name-string)
  "Find a tool by name string.

Parameters:
  KERNEL      - Kernel instance
  NAME-STRING - Tool name as string

Returns:
  Tool instance, or NIL if not found"
  (let ((tool-name (intern (string-upcase name-string) :keyword)))
    (kernel-find-tool kernel tool-name)))

;;; ============================================================
;;; Tool Execution
;;; ============================================================

(defgeneric kernel-execute-tool (kernel tool-name args)
  (:documentation "Execute a tool directly (bypasses filter chain).

Parameters:
  KERNEL    - Kernel instance
  TOOL-NAME - Tool name (keyword)
  ARGS      - Arguments plist

Returns:
  Execution result

Signals:
  Error if tool not found"))

(defmethod kernel-execute-tool ((kernel kernel) tool-name args)
  "Execute a tool by name."
  (let ((tool (kernel-find-tool kernel tool-name)))
    (unless tool
      (error "Tool ~A not found in kernel" tool-name))
    (multiple-value-bind (validated-args errors)
        (%tools-validate-arguments tool args)
      (when errors
        (error "Validation errors: ~{~A~^, ~}" errors))
      (apply (%tools-tool-handler tool) validated-args))))

;;; ============================================================
;;; Query API
;;; ============================================================

(defgeneric kernel-get-tools (kernel &key tags)
  (:documentation "Get tool schemas, optionally filtered by tags.

Parameters:
  KERNEL - Kernel instance
  TAGS   - Optional tag list for filtering (uses kernel's active-tags if nil)

Returns:
  List of tool schemas (Anthropic format)"))

(defmethod kernel-get-tools ((kernel kernel) &key tags)
  "Get tool schemas with optional tag filtering."
  (let* ((filter-tags (or tags (kernel-active-tags kernel)))
         (filter-mode (kernel-tag-filter-mode kernel))
         (registry (kernel-tool-registry kernel)))
    (when registry
      (if filter-tags
          (%tools-get-tools-schema-by-tags registry filter-tags :mode filter-mode)
          (mapcar #'%tools-tool-to-json-schema
                  (%tools-list-tools registry))))))

(defun kernel-invalidate-tools-cache (kernel)
  "Invalidate the tools cache.

Parameters:
  KERNEL - Kernel instance

Returns:
  NIL"
  (bt:with-lock-held ((kernel-lock kernel))
    (setf (kernel-tools-cache kernel) nil)
    ;; Also invalidate registry cache
    (when (kernel-tool-registry kernel)
      (%tools-invalidate-cache (kernel-tool-registry kernel)))))

(defgeneric kernel-list-tools (kernel &key tags)
  (:documentation "List all registered tools.

Parameters:
  KERNEL - Kernel instance
  TAGS   - Optional tag filter

Returns:
  List of tool info plists"))

(defmethod kernel-list-tools ((kernel kernel) &key tags)
  "List all tools with optional tag filtering."
  (let* ((filter-tags (or tags (kernel-active-tags kernel)))
         (filter-mode (kernel-tag-filter-mode kernel))
         (registry (kernel-tool-registry kernel)))
    (when registry
      (let ((tools (if filter-tags
                       (%tools-list-tools-by-tags registry filter-tags :mode filter-mode)
                       (%tools-list-tools registry))))
        (mapcar (lambda (tool)
                  (list :name (%tools-tool-name tool)
                        :description (%tools-tool-description tool)
                        :tags (%tools-tool-tags tool)
                        :category (%tools-tool-category tool)))
                tools)))))

;;; ============================================================
;;; Invoke - Tool Execution through Filter Chain
;;; ============================================================

(defgeneric invoke (kernel tool-name args &key context)
  (:documentation "Execute a registered tool through filter chain.

Parameters:
  KERNEL    - Kernel instance
  TOOL-NAME - Tool name (keyword)
  ARGS      - Arguments plist
  CONTEXT   - Additional context plist (optional)

Returns:
  Execution result

Signals:
  Error if tool not found"))

(defmethod invoke ((kernel kernel) tool-name args &key context)
  "Execute tool through filter chain."
  ;; Verify tool exists
  (unless (kernel-find-tool kernel tool-name)
    (error "Tool ~A not found in kernel" tool-name))

  (let* ((filters (kernel-filters kernel))
         (execute-fn (lambda (ctx)
                       (kernel-execute-tool kernel
                                            (getf ctx :tool-name)
                                            (getf ctx :tool-args))))
         (chain (build-filter-chain filters execute-fn))
         (ctx (list* :tool-name tool-name
                     :tool-args args
                     :kernel kernel
                     context)))
    (funcall chain ctx)))

;;; ============================================================
;;; Kernel Modification API
;;; ============================================================

(defun kernel-register-tool (kernel tool)
  "Register a tool to the kernel.

Parameters:
  KERNEL - Kernel instance
  TOOL   - Tool instance

Returns:
  The kernel (for chaining)"
  (bt:with-lock-held ((kernel-lock kernel))
    (%tools-register-tool (kernel-tool-registry kernel) tool)
    (setf (kernel-tools-cache kernel) nil))
  kernel)

(defun kernel-register-tools (kernel tools)
  "Register multiple tools to the kernel.

Parameters:
  KERNEL - Kernel instance
  TOOLS  - List of tool instances

Returns:
  The kernel (for chaining)"
  (bt:with-lock-held ((kernel-lock kernel))
    (dolist (tool tools)
      (%tools-register-tool (kernel-tool-registry kernel) tool))
    (setf (kernel-tools-cache kernel) nil))
  kernel)

(defun %plugin-param-type (type)
  "Normalize symbol-plist param type keywords to tools type keywords."
  (case type
    (:int :integer)
    (:float :number)
    (:bool :boolean)
    (otherwise type)))

(defun %plugin-params-to-tool-parameters (parameters)
  "Convert symbol-plist param specs to tools parameter format.

  Input:  ((name type description &key required-p default) ...)
  Output: ((name :type TYPE :description DESC :required BOOL [:default V]) ...)"
  (loop for spec in parameters
        collect (destructuring-bind (pname ptype pdesc &key required-p default) spec
                  (append (list pname
                                :type (%plugin-param-type ptype)
                                :description pdesc
                                :required required-p)
                          (when default (list :default default))))))

(defun kernel-add-plugin (kernel plugin-sym)
  "Register all tools of a symbol-plist plugin into the kernel's tool registry.

Parameters:
  KERNEL     - Kernel instance
  PLUGIN-SYM - Plugin symbol (declared via declare-plugin/defplugin)

Returns:
  The kernel (for chaining)"
  (unless (plugin-p plugin-sym)
    (error "~A is not a plugin" plugin-sym))
  (dolist (tool-sym (plugin-tool-symbols plugin-sym))
    (when (tool-function-p tool-sym)
      (let ((tool (%tools-make-tool
                   :name (tool-name tool-sym)
                   :description (or (tool-description tool-sym) "")
                   :handler (let ((sym tool-sym))
                              (lambda (&rest args) (apply sym args)))
                   :parameters (%plugin-params-to-tool-parameters
                                (tool-parameters tool-sym))
                   :category (or (get tool-sym :category) :custom)
                   ;; :sensitive 元数据转换为 :sensitive 标签（approval filter 依赖）
                   :tags (append (get tool-sym :tags)
                                 (when (get tool-sym :sensitive) '(:sensitive))))))
        (when tool
          (kernel-register-tool kernel tool)))))
  kernel)

(defun kernel-unregister-tool (kernel tool-name)
  "Unregister a tool from the kernel.

Parameters:
  KERNEL    - Kernel instance
  TOOL-NAME - Tool name (keyword)

Returns:
  The kernel (for chaining)"
  (bt:with-lock-held ((kernel-lock kernel))
    (%tools-unregister-tool (kernel-tool-registry kernel) tool-name)
    (setf (kernel-tools-cache kernel) nil))
  kernel)

(defun kernel-set-active-tags (kernel tags &key (mode :any))
  "Set active tags for tool filtering.

Parameters:
  KERNEL - Kernel instance
  TAGS   - Tag list (nil = no filter)
  MODE   - :any or :all

Returns:
  The kernel (for chaining)"
  (bt:with-lock-held ((kernel-lock kernel))
    (setf (kernel-active-tags kernel) tags)
    (setf (kernel-tag-filter-mode kernel) mode)
    (setf (kernel-tools-cache kernel) nil))
  kernel)

(defun kernel-clear-active-tags (kernel)
  "Clear active tags (disable filtering).

Parameters:
  KERNEL - Kernel instance

Returns:
  The kernel (for chaining)"
  (kernel-set-active-tags kernel nil))

(defun kernel-add-filter (kernel filter)
  "Add a filter to the kernel.

Parameters:
  KERNEL - Kernel instance
  FILTER - Filter function

Returns:
  The kernel (for chaining)"
  (bt:with-lock-held ((kernel-lock kernel))
    (push filter (kernel-filters kernel)))
  kernel)

(defun kernel-clear-filters (kernel)
  "Clear all filters from the kernel.

Parameters:
  KERNEL - Kernel instance

Returns:
  The kernel (for chaining)"
  (bt:with-lock-held ((kernel-lock kernel))
    (setf (kernel-filters kernel) nil))
  kernel)

;;; ============================================================
;;; Service Access
;;; ============================================================

(defun kernel-get-service (kernel)
  "Get the service from kernel.

Parameters:
  KERNEL - Kernel instance

Returns:
  Service plist"
  (kernel-service kernel))

(defun kernel-set-service (kernel service)
  "Set the service for kernel.

Parameters:
  KERNEL  - Kernel instance
  SERVICE - Service plist or provider

Returns:
  The kernel (for chaining)"
  (bt:with-lock-held ((kernel-lock kernel))
    (if (service-p service)
        (setf (kernel-service kernel) service)
        (setf (kernel-service kernel)
              (service-from-provider service :config (kernel-config kernel)))))
  kernel)

;;; ============================================================
;;; Convenience Functions
;;; ============================================================

(defun kernel-tool-count (kernel)
  "Get the total number of tools registered.

Parameters:
  KERNEL - Kernel instance

Returns:
  Tool count"
  (let ((registry (kernel-tool-registry kernel)))
    (if registry
        (%tools-registry-tool-count registry)
        0)))

(defun kernel-has-tool-p (kernel tool-name)
  "Check if kernel has a specific tool.

Parameters:
  KERNEL    - Kernel instance
  TOOL-NAME - Tool name (keyword)

Returns:
  T if tool exists, NIL otherwise"
  (not (null (kernel-find-tool kernel tool-name))))

(defun kernel-list-tags (kernel)
  "List all tags from tools in the kernel.

Parameters:
  KERNEL - Kernel instance

Returns:
  Tag list"
  (let ((registry (kernel-tool-registry kernel)))
    (when registry
      (%tools-list-all-tags registry))))

(defmethod print-object ((kernel kernel) stream)
  "Print kernel in a readable format."
  (print-unreadable-object (kernel stream :type t :identity t)
    (let ((tool-count (kernel-tool-count kernel))
          (active-tags (kernel-active-tags kernel)))
      (format stream "~A tools, ~A filters~@[, active-tags: ~A~]"
              tool-count
              (length (kernel-filters kernel))
              active-tags))))
