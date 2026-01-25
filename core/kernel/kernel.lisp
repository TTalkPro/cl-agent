;;;; kernel.lisp
;;;; CL-Agent Kernel - Kernel Core Class + Builder API
;;;;
;;;; Overview:
;;;;   Kernel is the central coordinator of the Semantic Kernel architecture.
;;;;   It holds:
;;;;   - Service: Abstraction over LLM provider (chat-fn + build-result-msgs)
;;;;   - Plugins: List of plugin symbols (each has :tools in plist)
;;;;   - Filters: Filter functions for tool execution pipeline
;;;;   - Config: Configuration plist
;;;;
;;;; Design:
;;;;   - Builder pattern for fluent construction
;;;;   - Service abstraction decouples from LLM specifics
;;;;   - Query API for tool/schema access
;;;;   - Thread-safe operations

(in-package #:cl-agent.kernel)

;;; ============================================================
;;; Kernel Class
;;; ============================================================

(defclass kernel ()
  ((service
    :initarg :service
    :accessor kernel-service
    :initform nil
    :documentation "Service plist (:chat-fn :build-result-msgs :provider :config)")

   ;; Keep chat-service for backward compatibility
   (chat-service
    :initarg :chat-service
    :accessor kernel-chat-service
    :initform nil
    :documentation "LLM chat service provider (deprecated, use service)")

   (config
    :initarg :config
    :accessor kernel-config
    :initform nil
    :documentation "Configuration plist (:max-tokens, :temperature, etc.)")

   (plugins
    :initarg :plugins
    :accessor kernel-plugins
    :initform nil
    :documentation "Plugin symbol list (each symbol's plist contains :tools)")

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
Holds service, plugins, filters, and configuration."))

;;; ============================================================
;;; Constructor
;;; ============================================================

(defun make-kernel (&key service chat-service config plugins filters context)
  "Create a Kernel instance.

Parameters:
  SERVICE      - Service plist (preferred)
  CHAT-SERVICE - LLM provider (backward compatibility, use service instead)
  CONFIG       - Configuration plist
  PLUGINS      - Plugin symbol list
  FILTERS      - Filter function list
  CONTEXT      - Default execution context

Returns:
  Kernel instance"
  (let ((kernel (make-instance 'kernel
                               :service service
                               :chat-service chat-service
                               :config config
                               :plugins plugins
                               :filters filters
                               :context context)))
    ;; If service not provided but chat-service is, create service from provider
    (when (and (null service) chat-service)
      (setf (kernel-service kernel)
            (service-from-provider chat-service :config config)))
    kernel))

;;; ============================================================
;;; Kernel Builder
;;; ============================================================

(defclass kernel-builder ()
  ((service
    :initform nil
    :accessor builder-service)
   (chat-service
    :initform nil
    :accessor builder-chat-service)
   (config
    :initform nil
    :accessor builder-config)
   (plugins
    :initform nil
    :accessor builder-plugins)
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
      (add-plugin my-plugin)
      (add-service my-service)
      (add-filter my-filter)
      (build-kernel))"
  (make-instance 'kernel-builder))

(defgeneric add-plugin (builder plugin)
  (:documentation "Add a plugin to the builder.

Parameters:
  BUILDER - Kernel builder
  PLUGIN  - Plugin symbol or list of symbols

Returns:
  The builder (for chaining)"))

(defmethod add-plugin ((builder kernel-builder) plugin)
  "Add plugin(s) to the builder."
  (if (listp plugin)
      (setf (builder-plugins builder)
            (append (builder-plugins builder) plugin))
      (push plugin (builder-plugins builder)))
  builder)

(defgeneric add-service (builder service)
  (:documentation "Set the service for the builder.

Parameters:
  BUILDER - Kernel builder
  SERVICE - Service plist or LLM provider

Returns:
  The builder (for chaining)"))

(defmethod add-service ((builder kernel-builder) service)
  "Set the service for the builder."
  (if (service-p service)
      (setf (builder-service builder) service)
      ;; Assume it's a provider, create service from it
      (setf (builder-chat-service builder) service))
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

(defgeneric build-kernel (builder)
  (:documentation "Build the Kernel from the builder state.

Parameters:
  BUILDER - Kernel builder

Returns:
  New Kernel instance"))

(defmethod build-kernel ((builder kernel-builder))
  "Build Kernel from builder."
  (make-kernel :service (builder-service builder)
               :chat-service (builder-chat-service builder)
               :config (builder-config builder)
               :plugins (nreverse (builder-plugins builder))
               :filters (nreverse (builder-filters builder))
               :context (builder-context builder)))

;;; ============================================================
;;; Tool Lookup
;;; ============================================================

(defun kernel-find-tool-symbol (kernel fn-name)
  "Find a tool symbol in the kernel's plugins.

Parameters:
  KERNEL  - Kernel instance
  FN-NAME - Function name (keyword)

Returns:
  Tool symbol, or NIL if not found"
  (loop for plugin-sym in (kernel-plugins kernel)
        thereis (find fn-name (plugin-tool-symbols plugin-sym)
                      :key (lambda (s) (get s :tool-name)))))

(defun kernel-find-tool-by-name (kernel name-string)
  "Find a tool symbol by name string.

Parameters:
  KERNEL      - Kernel instance
  NAME-STRING - Function name as string

Returns:
  Tool symbol, or NIL if not found"
  (let ((fn-name (intern (string-upcase name-string) :keyword)))
    (kernel-find-tool-symbol kernel fn-name)))

;;; ============================================================
;;; Tool Execution
;;; ============================================================

(defgeneric kernel-execute-tool (kernel fn-name args)
  (:documentation "Execute a tool directly (bypasses filter chain).

Parameters:
  KERNEL  - Kernel instance
  FN-NAME - Function name (keyword)
  ARGS    - Arguments plist

Returns:
  Execution result

Signals:
  Error if function not found"))

(defmethod kernel-execute-tool ((kernel kernel) fn-name args)
  "Execute a tool by name."
  (let ((tool-sym (kernel-find-tool-symbol kernel fn-name)))
    (unless tool-sym
      (error "Function ~A not found in kernel" fn-name))
    (validate-tool-args tool-sym args)
    (apply (symbol-function tool-sym) args)))

;;; ============================================================
;;; Query API
;;; ============================================================

(defgeneric kernel-get-tools (kernel)
  (:documentation "Get all registered tool schemas.

Parameters:
  KERNEL - Kernel instance

Returns:
  List of tool schemas (Anthropic format)"))

(defmethod kernel-get-tools ((kernel kernel))
  "Get all tool schemas (uses cache)."
  (or (kernel-tools-cache kernel)
      (setf (kernel-tools-cache kernel)
            (loop for plugin-sym in (kernel-plugins kernel)
                  nconc (plugin-get-schemas plugin-sym)))))

(defun kernel-invalidate-tools-cache (kernel)
  "Invalidate the tools cache.

Parameters:
  KERNEL - Kernel instance

Returns:
  NIL"
  (bt:with-lock-held ((kernel-lock kernel))
    (setf (kernel-tools-cache kernel) nil)))

(defgeneric kernel-list-plugins (kernel)
  (:documentation "List all registered plugins.

Parameters:
  KERNEL - Kernel instance

Returns:
  List of plugin info plists"))

(defmethod kernel-list-plugins ((kernel kernel))
  "List all plugins with their info."
  (loop for plugin-sym in (kernel-plugins kernel)
        collect (list :name plugin-sym
                      :description (plugin-description plugin-sym)
                      :tools (plugin-tool-symbols plugin-sym))))

(defgeneric kernel-list-tools (kernel)
  (:documentation "List all registered tools.

Parameters:
  KERNEL - Kernel instance

Returns:
  List of tool info plists"))

(defmethod kernel-list-tools ((kernel kernel))
  "List all tools with their info."
  (loop for plugin-sym in (kernel-plugins kernel)
        nconc (loop for tool-sym in (plugin-tool-symbols plugin-sym)
                    collect (list :name (tool-name tool-sym)
                                  :description (tool-description tool-sym)
                                  :plugin plugin-sym))))

;;; ============================================================
;;; Invoke - Tool Execution through Filter Chain
;;; ============================================================

(defgeneric invoke (kernel fn-name args &key context)
  (:documentation "Execute a registered function through filter chain.

Parameters:
  KERNEL  - Kernel instance
  FN-NAME - Function name (keyword)
  ARGS    - Arguments plist
  CONTEXT - Additional context plist (optional)

Returns:
  Execution result

Signals:
  Error if function not found"))

(defmethod invoke ((kernel kernel) fn-name args &key context)
  "Execute function through filter chain."
  (let ((tool-sym (kernel-find-tool-symbol kernel fn-name)))
    (unless tool-sym
      (error "Function ~A not found in kernel" fn-name))
    (let* ((filters (kernel-filters kernel))
           (execute-fn (lambda (ctx)
                         (kernel-execute-tool kernel
                                              (getf ctx :tool-name)
                                              (getf ctx :tool-args))))
           (chain (build-filter-chain filters execute-fn))
           (ctx (list* :tool-name fn-name
                       :tool-args args
                       :kernel kernel
                       context)))
      (funcall chain ctx))))

;;; ============================================================
;;; Kernel Modification API
;;; ============================================================

(defun kernel-add-plugin (kernel plugin-sym)
  "Add a plugin to the kernel.

Parameters:
  KERNEL     - Kernel instance
  PLUGIN-SYM - Plugin symbol

Returns:
  The kernel (for chaining)"
  (bt:with-lock-held ((kernel-lock kernel))
    (pushnew plugin-sym (kernel-plugins kernel))
    (setf (kernel-tools-cache kernel) nil))
  kernel)

(defun kernel-remove-plugin (kernel plugin-sym)
  "Remove a plugin from the kernel.

Parameters:
  KERNEL     - Kernel instance
  PLUGIN-SYM - Plugin symbol

Returns:
  The kernel (for chaining)"
  (bt:with-lock-held ((kernel-lock kernel))
    (setf (kernel-plugins kernel)
          (remove plugin-sym (kernel-plugins kernel)))
    (setf (kernel-tools-cache kernel) nil))
  kernel)

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
  Service plist, or creates one from chat-service if needed"
  (or (kernel-service kernel)
      (when (kernel-chat-service kernel)
        (setf (kernel-service kernel)
              (service-from-provider (kernel-chat-service kernel)
                                     :config (kernel-config kernel))))))

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
  (reduce #'+ (kernel-plugins kernel)
          :key (lambda (p) (length (plugin-tool-symbols p)))
          :initial-value 0))

(defun kernel-has-tool-p (kernel fn-name)
  "Check if kernel has a specific tool.

Parameters:
  KERNEL  - Kernel instance
  FN-NAME - Function name (keyword)

Returns:
  T if tool exists, NIL otherwise"
  (not (null (kernel-find-tool-symbol kernel fn-name))))

(defmethod print-object ((kernel kernel) stream)
  "Print kernel in a readable format."
  (print-unreadable-object (kernel stream :type t :identity t)
    (format stream "~A plugins, ~A tools, ~A filters"
            (length (kernel-plugins kernel))
            (kernel-tool-count kernel)
            (length (kernel-filters kernel)))))
