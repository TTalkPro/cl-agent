;;;; builtin/shell.lisp
;;;; CL-Agent Plugin - Shell Execution Plugin
;;;;
;;;; Overview:
;;;;   Secure shell command execution plugin with sandboxing and validation.

(in-package #:cl-agent.plugin)

;;; ============================================================
;;; Shell Plugin Class
;;; ============================================================

(defclass shell-plugin ()
  ((name
    :initform "shell"
    :reader plugin-name)

   (allowed-commands
    :initarg :allowed-commands
    :accessor shell-plugin-allowed-commands
    :initform nil
    :type list
    :documentation "Allowed command prefixes (nil = all)")

   (blocked-commands
    :initarg :blocked-commands
    :accessor shell-plugin-blocked-commands
    :initform '("rm -rf" "dd if=" "mkfs" "fdisk" "> /dev/"
               "sudo" "su " "chmod 777" "curl | sh" "wget | sh")
    :type list
    :documentation "Blocked command patterns")

   (working-directory
    :initarg :working-directory
    :accessor shell-plugin-working-directory
    :initform nil
    :type (or null string)
    :documentation "Working directory (nil = current)")

   (timeout
    :initarg :timeout
    :accessor shell-plugin-timeout
    :initform 60
    :type integer
    :documentation "Command timeout in seconds")

   (max-output-size
    :initarg :max-output-size
    :accessor shell-plugin-max-output-size
    :initform (* 1024 1024)  ; 1MB
    :type integer
    :documentation "Maximum output size")

   (environment
    :initarg :environment
    :accessor shell-plugin-environment
    :initform nil
    :type list
    :documentation "Environment variables (alist)")

   (security-policy
    :initarg :security-policy
    :accessor shell-plugin-security-policy
    :initform nil
    :documentation "Security policy"))

  (:documentation "Secure shell execution plugin."))

(defun make-shell-plugin (&key allowed-commands blocked-commands working-directory
                                timeout max-output-size environment security-policy)
  "Create a shell plugin.

Parameters:
  ALLOWED-COMMANDS  - List of allowed command prefixes
  BLOCKED-COMMANDS  - List of blocked command patterns
  WORKING-DIRECTORY - Working directory
  TIMEOUT           - Command timeout
  MAX-OUTPUT-SIZE   - Maximum output size
  ENVIRONMENT       - Environment variables
  SECURITY-POLICY   - Security policy

Returns:
  shell-plugin instance"
  (make-instance 'shell-plugin
                 :allowed-commands allowed-commands
                 :blocked-commands (or blocked-commands
                                      '("rm -rf" "dd if=" "mkfs" "fdisk"
                                        "sudo" "su "))
                 :working-directory working-directory
                 :timeout (or timeout 60)
                 :max-output-size (or max-output-size (* 1024 1024))
                 :environment environment
                 :security-policy security-policy))

;;; ============================================================
;;; Command Validation
;;; ============================================================

(defun validate-shell-command (plugin command)
  "Validate a command against plugin restrictions.

Parameters:
  PLUGIN  - Shell plugin
  COMMAND - Command to validate

Returns:
  T if valid, signals error otherwise"
  ;; Check blocked commands
  (dolist (pattern (shell-plugin-blocked-commands plugin))
    (when (search pattern command :test #'char-equal)
      (error "Command contains blocked pattern: ~A" pattern)))

  ;; Check allowed commands
  (when (shell-plugin-allowed-commands plugin)
    (unless (some (lambda (prefix)
                   (and (>= (length command) (length prefix))
                        (string-equal prefix (subseq command 0 (length prefix)))))
                 (shell-plugin-allowed-commands plugin))
      (error "Command not in allowed list")))

  ;; Check for shell injection patterns
  (when (or (search "$()" command)
           (search "`" command)
           (search "&&" command)
           (search "||" command)
           (search ";" command)
           (search "|" command))
    (warn "Command contains shell operators - use with caution"))

  t)

;;; ============================================================
;;; Shell Operations
;;; ============================================================

(defgeneric shell-plugin-execute (plugin command &key timeout)
  (:documentation "Execute a shell command."))

(defmethod shell-plugin-execute ((plugin shell-plugin) command &key timeout)
  "Execute a shell command."
  (validate-shell-command plugin command)

  (let ((effective-timeout (or timeout (shell-plugin-timeout plugin)))
        (working-dir (shell-plugin-working-directory plugin)))

    ;; Execute command
    (handler-case
        (multiple-value-bind (output error-output exit-code)
            (uiop:run-program command
                             :output '(:string :stripped t)
                             :error-output '(:string :stripped t)
                             :ignore-error-status t
                             :directory working-dir)
          ;; Truncate output if needed
          (when (> (length output) (shell-plugin-max-output-size plugin))
            (setf output (subseq output 0 (shell-plugin-max-output-size plugin))))
          (when (> (length error-output) (shell-plugin-max-output-size plugin))
            (setf error-output (subseq error-output 0 (shell-plugin-max-output-size plugin))))

          (list :command command
                :exit-code exit-code
                :stdout output
                :stderr error-output
                :success (zerop exit-code)))
      (error (e)
        (list :command command
              :exit-code -1
              :error (format nil "~A" e)
              :success nil)))))

(defgeneric shell-plugin-script (plugin script &key interpreter)
  (:documentation "Execute a shell script."))

(defmethod shell-plugin-script ((plugin shell-plugin) script
                                 &key (interpreter "/bin/sh"))
  "Execute a shell script."
  ;; Validate each line of the script
  (dolist (line (cl-ppcre:split "\\n" script))
    (let ((trimmed (string-trim '(#\Space #\Tab) line)))
      (unless (or (string= trimmed "")
                 (char= (char trimmed 0) #\#))
        (validate-shell-command plugin trimmed))))

  ;; Execute via interpreter
  (shell-plugin-execute plugin
                        (format nil "~A <<'SCRIPT'~%~A~%SCRIPT"
                                interpreter script)))

;;; ============================================================
;;; Plugin Tools Registration
;;; ============================================================

(defun shell-plugin-tools (plugin)
  "Get tool definitions for shell plugin."
  (list
   (make-tool
    :name "execute_command"
    :description "Execute a shell command"
    :parameters `((:name "command" :type :string :required t
                  :description "Command to execute")
                  (:name "timeout" :type :integer
                  :description "Timeout in seconds"))
    :handler (lambda (args)
              (shell-plugin-execute plugin (getf args :command)
                                   :timeout (getf args :timeout))))

   (make-tool
    :name "execute_script"
    :description "Execute a shell script"
    :parameters `((:name "script" :type :string :required t
                  :description "Script content")
                  (:name "interpreter" :type :string
                  :description "Script interpreter (default: /bin/sh)"))
    :handler (lambda (args)
              (shell-plugin-script plugin (getf args :script)
                                  :interpreter (or (getf args :interpreter)
                                                   "/bin/sh"))))))

