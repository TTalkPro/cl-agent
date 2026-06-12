;;;; presets.lisp
;;;; CL-Agent Tools - Tool Presets
;;;;
;;;; Overview:
;;;;   Provides pre-configured tool sets for common use cases.
;;;;   Makes it easy to create a kernel with appropriate tools.
;;;;
;;;; Presets:
;;;;   - Standard: All safe tools + file write
;;;;   - Safe: Read-only operations only
;;;;   - Full: All tools including dangerous ones
;;;;   - File-only: Only file operations
;;;;   - HTTP-only: Only HTTP operations
;;;;   - Custom: Build your own

(in-package #:cl-agent.tools)

;;; ============================================================
;;; Tag Presets (for filtering)
;;; ============================================================

(defparameter *preset-safe-tags* '(:safe :read)
  "Tags that select safe, read-only operations.")

(defparameter *preset-file-tags* '(:file)
  "Tags that select file operations.")

(defparameter *preset-http-tags* '(:http)
  "Tags that select HTTP operations.")

(defparameter *preset-utility-tags* '(:utility)
  "Tags that select utility operations.")

(defparameter *preset-dangerous-tags* '(:dangerous :shell)
  "Tags that select dangerous operations (use with caution).")

;;; ============================================================
;;; Security Levels
;;; ============================================================

(defstruct tool-security-config
  "Security configuration for tool creation."
  (level :standard :type keyword)              ; :permissive :standard :strict
  (allowed-paths nil :type list)               ; File paths
  (blocked-extensions nil :type list)          ; File extensions
  (blocked-domains nil :type list)             ; HTTP domains
  (blocked-commands nil :type list)            ; Shell commands
  (max-file-size nil :type (or null integer))  ; Max file size
  (http-timeout nil :type (or null integer))   ; HTTP timeout
  (shell-timeout nil :type (or null integer))) ; Shell timeout

(defun make-permissive-security-config ()
  "Create a permissive security configuration.
   Use with caution - minimal restrictions."
  (make-tool-security-config
   :level :permissive
   :allowed-paths nil
   :blocked-extensions nil
   :blocked-domains nil
   :blocked-commands nil
   :max-file-size (* 100 1024 1024)  ; 100MB
   :http-timeout 120
   :shell-timeout 300))

(defun make-standard-security-config ()
  "Create a standard security configuration.
   Good balance between usability and security."
  (make-tool-security-config
   :level :standard
   :allowed-paths nil
   :blocked-extensions '(".exe" ".dll" ".so" ".dylib" ".bin")
   :blocked-domains '("localhost" "127.0.0.1" "0.0.0.0")
   :blocked-commands '("rm -rf" "dd if=" "mkfs" "fdisk" "sudo" "su ")
   :max-file-size (* 10 1024 1024)  ; 10MB
   :http-timeout 30
   :shell-timeout 60))

(defun make-strict-security-config ()
  "Create a strict security configuration.
   Maximum restrictions for sensitive environments."
  (make-tool-security-config
   :level :strict
   :allowed-paths nil  ; Must be explicitly set
   :blocked-extensions '(".exe" ".dll" ".so" ".dylib" ".bin" ".sh" ".bat" ".cmd")
   :blocked-domains '("localhost" "127.0.0.1" "0.0.0.0" "internal")
   :blocked-commands '("rm" "dd" "mkfs" "fdisk" "sudo" "su" "chmod" "chown"
                      "wget" "curl" "nc" "netcat")
   :max-file-size (* 1024 1024)  ; 1MB
   :http-timeout 10
   :shell-timeout 10))

;;; ============================================================
;;; Tool Set Presets
;;; ============================================================

(defun create-preset-tools (preset &key security-config)
  "Create tools based on a preset.

Parameters:
  PRESET          - Preset name: :standard :safe :full :file-only :http-only :utility-only
  SECURITY-CONFIG - Optional security configuration

Returns:
  List of tool instances"
  (let ((config (or security-config (make-standard-security-config))))
    (case preset
      (:standard (create-standard-tools config))
      (:safe (create-safe-preset-tools config))
      (:full (create-full-tools config))
      (:file-only (create-file-only-tools config))
      (:http-only (create-http-only-tools config))
      (:utility-only (create-utility-only-tools config))
      (otherwise (error "Unknown preset: ~A" preset)))))

(defun create-standard-tools (config)
  "Create standard tool set: safe tools + file write (no shell).

Parameters:
  CONFIG - Security configuration

Returns:
  List of tool instances"
  (append
   ;; File tools (read + write, no delete)
   (list (make-read-file-tool
          :allowed-paths (tool-security-config-allowed-paths config)
          :max-file-size (tool-security-config-max-file-size config))
         (make-write-file-tool
          :allowed-paths (tool-security-config-allowed-paths config)
          :blocked-extensions (tool-security-config-blocked-extensions config)
          :max-file-size (tool-security-config-max-file-size config))
         (make-list-directory-tool
          :allowed-paths (tool-security-config-allowed-paths config)))
   ;; HTTP tools (GET only for standard)
   (list (make-http-get-tool
          :blocked-domains (tool-security-config-blocked-domains config)
          :timeout (tool-security-config-http-timeout config)))
   ;; Utility tools (all)
   (create-utility-tools)))

(defun create-safe-preset-tools (config)
  "Create safe tool set: read-only operations only.

Parameters:
  CONFIG - Security configuration

Returns:
  List of tool instances"
  (append
   ;; Read-only file tools
   (list (make-read-file-tool
          :allowed-paths (tool-security-config-allowed-paths config)
          :max-file-size (tool-security-config-max-file-size config))
         (make-list-directory-tool
          :allowed-paths (tool-security-config-allowed-paths config)))
   ;; HTTP GET only
   (list (make-http-get-tool
          :blocked-domains (tool-security-config-blocked-domains config)
          :timeout (tool-security-config-http-timeout config)))
   ;; Utility tools (all are safe)
   (create-utility-tools)))

(defun create-full-tools (config)
  "Create full tool set: all tools including dangerous ones.

Parameters:
  CONFIG - Security configuration

Returns:
  List of tool instances"
  (create-all-builtin-tools
   :file-config (list :allowed-paths (tool-security-config-allowed-paths config)
                      :blocked-extensions (tool-security-config-blocked-extensions config)
                      :max-file-size (tool-security-config-max-file-size config))
   :http-config (list :blocked-domains (tool-security-config-blocked-domains config)
                      :timeout (tool-security-config-http-timeout config))
   :shell-config (list :blocked-commands (tool-security-config-blocked-commands config)
                       :timeout (tool-security-config-shell-timeout config))))

(defun create-file-only-tools (config)
  "Create file-only tool set.

Parameters:
  CONFIG - Security configuration

Returns:
  List of tool instances"
  (create-file-tools
   :allowed-paths (tool-security-config-allowed-paths config)
   :blocked-extensions (tool-security-config-blocked-extensions config)
   :max-file-size (tool-security-config-max-file-size config)))

(defun create-http-only-tools (config)
  "Create HTTP-only tool set.

Parameters:
  CONFIG - Security configuration

Returns:
  List of tool instances"
  (create-http-tools
   :blocked-domains (tool-security-config-blocked-domains config)
   :timeout (tool-security-config-http-timeout config)))

(defun create-utility-only-tools (config)
  "Create utility-only tool set.

Parameters:
  CONFIG - Security configuration (mostly unused for utility tools)

Returns:
  List of tool instances"
  (declare (ignore config))
  (create-utility-tools))

;;; ============================================================
;;; Quick Setup Functions
;;; ============================================================

(defun quick-setup-tools (&key (preset :standard) (security-level :standard))
  "Quick setup: create tools with preset and security level.

Parameters:
  PRESET         - Tool preset: :standard :safe :full :file-only :http-only :utility-only
  SECURITY-LEVEL - Security level: :permissive :standard :strict

Returns:
  List of tool instances

Example:
  (quick-setup-tools :preset :safe :security-level :strict)"
  (let ((config (case security-level
                  (:permissive (make-permissive-security-config))
                  (:standard (make-standard-security-config))
                  (:strict (make-strict-security-config))
                  (otherwise (make-standard-security-config)))))
    (create-preset-tools preset :security-config config)))

(defun quick-setup-kernel-with-tools (service &key (preset :standard)
                                                    (security-level :standard)
                                                    active-tags
                                                    filters)
  "Quick setup: create a kernel with tools.

Parameters:
  SERVICE        - Service or LLM provider
  PRESET         - Tool preset (default :standard)
  SECURITY-LEVEL - Security level (default :standard)
  ACTIVE-TAGS    - Tags to filter active tools
  FILTERS        - Filter functions

Returns:
  Kernel instance

Example:
  (quick-setup-kernel-with-tools my-provider
                                  :preset :safe
                                  :security-level :strict
                                  :active-tags '(:file :read))"
  (let ((tools (quick-setup-tools :preset preset :security-level security-level))
        (builder (cl-agent.kernel:create-kernel-builder)))
    ;; Add service
    (cl-agent.kernel:add-service builder service)
    ;; Add tools
    (cl-agent.kernel:with-tools builder tools)
    ;; Set active tags if provided
    (when active-tags
      (cl-agent.kernel:with-active-tags builder active-tags))
    ;; Add filters
    (dolist (filter filters)
      (cl-agent.kernel:add-filter builder filter))
    ;; Build and return
    (cl-agent.kernel:build-kernel builder)))

;;; ============================================================
;;; Tool Set Descriptions (for documentation)
;;; ============================================================

(defun describe-preset (preset &optional (stream t))
  "Describe a tool preset.

Parameters:
  PRESET - Preset name
  STREAM - Output stream"
  (format stream "~&Preset: ~A~%" preset)
  (format stream "~&Tools:~%")
  (dolist (tool (create-preset-tools preset))
    (format stream "  - ~A: ~A~%"
            (tool-name tool)
            (tool-description tool))
    (format stream "    Tags: ~{~A~^, ~}~%"
            (tool-tags tool))))

(defun list-all-presets ()
  "List all available presets.

Returns:
  List of preset keywords"
  '(:standard :safe :full :file-only :http-only :utility-only))
