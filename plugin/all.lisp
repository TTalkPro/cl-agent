;;;; all.lisp
;;;; CL-Agent Plugin - Plugin Aggregation
;;;;
;;;; Overview:
;;;;   Utilities for managing collections of plugins and registering
;;;;   all builtin plugins at once.

(in-package #:cl-agent.plugin)

;;; ============================================================
;;; Plugin Collection Class
;;; ============================================================

(defclass plugin-collection ()
  ((plugins
    :initform (make-hash-table :test 'equal)
    :reader collection-plugins
    :documentation "Hash table of name -> plugin")

   (load-order
    :initform nil
    :accessor collection-load-order
    :documentation "List of plugin names in load order"))

  (:documentation "A collection of plugins."))

(defun make-plugin-collection ()
  "Create an empty plugin collection."
  (make-instance 'plugin-collection))

(defgeneric collection-add (collection name plugin)
  (:documentation "Add a plugin to the collection."))

(defmethod collection-add ((collection plugin-collection) name plugin)
  "Add a plugin to the collection."
  (setf (gethash name (collection-plugins collection)) plugin)
  (pushnew name (collection-load-order collection) :test #'equal)
  plugin)

(defgeneric collection-remove (collection name)
  (:documentation "Remove a plugin from the collection."))

(defmethod collection-remove ((collection plugin-collection) name)
  "Remove a plugin from the collection."
  (remhash name (collection-plugins collection))
  (setf (collection-load-order collection)
        (remove name (collection-load-order collection) :test #'equal)))

(defgeneric collection-get (collection name)
  (:documentation "Get a plugin by name."))

(defmethod collection-get ((collection plugin-collection) name)
  "Get a plugin by name."
  (gethash name (collection-plugins collection)))

(defgeneric collection-list (collection)
  (:documentation "List all plugins in the collection."))

(defmethod collection-list ((collection plugin-collection))
  "List all plugins in the collection."
  (mapcar (lambda (name)
            (list :name name
                  :plugin (gethash name (collection-plugins collection))))
          (reverse (collection-load-order collection))))

;;; ============================================================
;;; Builtin Plugins Factory
;;; ============================================================

(defun all-builtin-plugins (&key file-config http-config shell-config utility-config)
  "Create all builtin plugins with optional configurations.

Parameters:
  FILE-CONFIG    - Plist for file plugin configuration
  HTTP-CONFIG    - Plist for HTTP plugin configuration
  SHELL-CONFIG   - Plist for shell plugin configuration
  UTILITY-CONFIG - Plist for utility plugin configuration

Returns:
  Plugin collection with all builtin plugins"
  (let ((collection (make-plugin-collection)))

    ;; File plugin
    (collection-add collection "file"
                    (apply #'make-file-plugin
                           (or file-config '())))

    ;; HTTP plugin
    (collection-add collection "http"
                    (apply #'make-http-plugin
                           (or http-config '())))

    ;; Shell plugin
    (collection-add collection "shell"
                    (apply #'make-shell-plugin
                           (or shell-config '())))

    ;; Utility plugin
    (collection-add collection "utility"
                    (apply #'make-utility-plugin
                           (or utility-config '())))

    collection))

(defun create-default-plugins (&key (security-level :standard))
  "Create default plugins with security level.

Parameters:
  SECURITY-LEVEL - Security level (:permissive, :standard, :strict)

Returns:
  Plugin collection"
  (let ((policy (case security-level
                  (:permissive (make-permissive-policy))
                  (:standard (make-standard-policy))
                  (:strict (make-strict-policy))
                  (otherwise (make-standard-policy)))))

    (all-builtin-plugins
     :file-config (list :security-policy policy
                       :max-file-size (case security-level
                                       (:strict (* 1024 1024))     ; 1MB
                                       (:standard (* 10 1024 1024)) ; 10MB
                                       (otherwise (* 100 1024 1024)))) ; 100MB
     :http-config (list :security-policy policy
                       :rate-limit (case security-level
                                    (:strict 10)
                                    (:standard 60)
                                    (otherwise nil))
                       :blocked-domains '("localhost" "127.0.0.1" "0.0.0.0"))
     :shell-config (list :security-policy policy
                        :timeout (case security-level
                                  (:strict 10)
                                  (:standard 60)
                                  (otherwise 300)))
     :utility-config '())))

;;; ============================================================
;;; Tool Registry Integration
;;; ============================================================

(defun register-all-plugins (registry collection)
  "Register all plugins in collection to a tool registry.

Parameters:
  REGISTRY   - Tool registry
  COLLECTION - Plugin collection

Returns:
  Number of tools registered"
  (let ((count 0))
    (dolist (entry (collection-list collection))
      (let* ((name (getf entry :name))
             (plugin (getf entry :plugin))
             (tools (get-plugin-tools name plugin)))
        (dolist (tool tools)
          (register-tool registry tool)
          (incf count))))
    count))

(defun get-plugin-tools (name plugin)
  "Get tools from a plugin based on its type."
  (cond
    ((typep plugin 'file-plugin)
     (file-plugin-tools plugin))
    ((typep plugin 'http-plugin)
     (http-plugin-tools plugin))
    ((typep plugin 'shell-plugin)
     (shell-plugin-tools plugin))
    ((typep plugin 'utility-plugin)
     (utility-plugin-tools plugin))
    (t
     ;; Generic: try to call plugin-tools
     (when (find-method #'plugin-tools nil (list (class-of plugin)) nil)
       (plugin-tools plugin)))))

(defgeneric plugin-tools (plugin)
  (:documentation "Get tools provided by a plugin.")
  (:method ((plugin t))
    "Default: no tools"
    nil))

;;; ============================================================
;;; Convenience Functions
;;; ============================================================

(defun quick-setup-registry (&key (security-level :standard))
  "Quick setup: create a registry with all builtin plugins.

Parameters:
  SECURITY-LEVEL - Security level

Returns:
  Configured tool registry"
  (let ((registry (make-tool-registry))
        (plugins (create-default-plugins :security-level security-level)))
    (register-all-plugins registry plugins)
    registry))

(defun list-all-builtin-tools ()
  "List all available builtin tools."
  (let ((collection (all-builtin-plugins)))
    (mapcan (lambda (entry)
              (let* ((name (getf entry :name))
                     (plugin (getf entry :plugin))
                     (tools (get-plugin-tools name plugin)))
                (mapcar (lambda (tool)
                          (list :plugin name
                                :tool (tool-name tool)
                                :description (tool-description tool)))
                        tools)))
            (collection-list collection))))

