;;;; builtin/file.lisp
;;;; CL-Agent Plugin - File Operations Plugin
;;;;
;;;; Overview:
;;;;   Secure file operations plugin with validation and sandboxing.

(in-package #:cl-agent.plugin)

;;; ============================================================
;;; File Plugin Class
;;; ============================================================

(defclass file-plugin ()
  ((name
    :initform "file"
    :reader plugin-name)

   (allowed-paths
    :initarg :allowed-paths
    :accessor file-plugin-allowed-paths
    :initform nil
    :type list
    :documentation "Allowed path prefixes (nil = all)")

   (blocked-extensions
    :initarg :blocked-extensions
    :accessor file-plugin-blocked-extensions
    :initform '(".exe" ".dll" ".so" ".dylib" ".bin")
    :type list
    :documentation "Blocked file extensions")

   (max-file-size
    :initarg :max-file-size
    :accessor file-plugin-max-file-size
    :initform (* 10 1024 1024)  ; 10MB
    :type integer
    :documentation "Maximum file size for read operations")

   (security-policy
    :initarg :security-policy
    :accessor file-plugin-security-policy
    :initform nil
    :documentation "Security policy"))

  (:documentation "Secure file operations plugin."))

(defun make-file-plugin (&key allowed-paths blocked-extensions max-file-size
                               security-policy)
  "Create a file plugin.

Parameters:
  ALLOWED-PATHS      - List of allowed path prefixes
  BLOCKED-EXTENSIONS - List of blocked file extensions
  MAX-FILE-SIZE      - Maximum file size for read operations
  SECURITY-POLICY    - Security policy

Returns:
  file-plugin instance"
  (make-instance 'file-plugin
                 :allowed-paths allowed-paths
                 :blocked-extensions (or blocked-extensions
                                        '(".exe" ".dll" ".so" ".dylib" ".bin"))
                 :max-file-size (or max-file-size (* 10 1024 1024))
                 :security-policy security-policy))

;;; ============================================================
;;; Path Validation
;;; ============================================================

(defun validate-file-path (plugin path operation)
  "Validate a file path against plugin restrictions.

Parameters:
  PLUGIN    - File plugin
  PATH      - File path to validate
  OPERATION - Operation type (:read, :write, :delete)

Returns:
  T if valid, signals error otherwise"
  ;; Check allowed paths
  (when (file-plugin-allowed-paths plugin)
    (unless (some (lambda (prefix)
                   (or (string= prefix path)
                       (and (> (length path) (length prefix))
                            (string= prefix (subseq path 0 (length prefix))))))
                 (file-plugin-allowed-paths plugin))
      (error "Path not in allowed paths: ~A" path)))

  ;; Check blocked extensions for write operations
  (when (member operation '(:write :delete))
    (let ((ext (pathname-type (pathname path))))
      (when (and ext (member (concatenate 'string "." ext)
                            (file-plugin-blocked-extensions plugin)
                            :test #'string-equal))
        (error "Blocked file extension: ~A" ext))))

  ;; Check for path traversal
  (when (search ".." path)
    (error "Path traversal not allowed: ~A" path))

  t)

;;; ============================================================
;;; File Operations
;;; ============================================================

(defgeneric file-plugin-read (plugin path &key encoding)
  (:documentation "Read file contents."))

(defmethod file-plugin-read ((plugin file-plugin) path &key (encoding :utf-8))
  "Read file contents."
  (validate-file-path plugin path :read)

  ;; Check file exists
  (unless (probe-file path)
    (error "File not found: ~A" path))

  ;; Check file size
  (let ((size (with-open-file (s path) (file-length s))))
    (when (> size (file-plugin-max-file-size plugin))
      (error "File too large: ~A bytes (max: ~A)"
             size (file-plugin-max-file-size plugin))))

  ;; Read file
  (with-open-file (stream path
                          :direction :input
                          :external-format encoding)
    (let ((content (make-string (file-length stream))))
      (read-sequence content stream)
      content)))

(defgeneric file-plugin-write (plugin path content &key encoding if-exists)
  (:documentation "Write content to file."))

(defmethod file-plugin-write ((plugin file-plugin) path content
                               &key (encoding :utf-8) (if-exists :supersede))
  "Write content to file."
  (validate-file-path plugin path :write)

  ;; Check content size
  (when (> (length content) (file-plugin-max-file-size plugin))
    (error "Content too large: ~A bytes (max: ~A)"
           (length content) (file-plugin-max-file-size plugin)))

  ;; Ensure directory exists
  (ensure-directories-exist path)

  ;; Write file
  (with-open-file (stream path
                          :direction :output
                          :external-format encoding
                          :if-exists if-exists
                          :if-does-not-exist :create)
    (write-sequence content stream))

  (list :path path
        :size (length content)
        :success t))

(defgeneric file-plugin-delete (plugin path)
  (:documentation "Delete a file."))

(defmethod file-plugin-delete ((plugin file-plugin) path)
  "Delete a file."
  (validate-file-path plugin path :delete)

  (unless (probe-file path)
    (error "File not found: ~A" path))

  (delete-file path)
  (list :path path :deleted t))

(defgeneric file-plugin-list (plugin path &key recursive)
  (:documentation "List directory contents."))

(defmethod file-plugin-list ((plugin file-plugin) path &key recursive)
  "List directory contents."
  (validate-file-path plugin path :read)

  (let ((entries '()))
    (flet ((process-entry (entry)
             (let* ((name (enough-namestring entry path))
                    (is-dir (and (null (pathname-name entry))
                                (null (pathname-type entry)))))
               (push (list :name name
                          :type (if is-dir :directory :file)
                          :path (namestring entry))
                     entries))))

      (if recursive
          ;; Recursive listing
          (dolist (entry (directory (merge-pathnames "**/*.*" path)))
            (process-entry entry))
          ;; Non-recursive listing
          (dolist (entry (directory (merge-pathnames "*.*" path)))
            (process-entry entry))))

    (nreverse entries)))

;;; ============================================================
;;; Plugin Tools Registration
;;; ============================================================

(defun file-plugin-tools (plugin)
  "Get tool definitions for file plugin.

Returns:
  List of tool specifications for the registry"
  (list
   (make-tool
    :name "read_file"
    :description "Read contents of a file"
    :parameters `((:name "path" :type :string :required t :description "File path"))
    :handler (lambda (args)
              (file-plugin-read plugin (getf args :path))))

   (make-tool
    :name "write_file"
    :description "Write content to a file"
    :parameters `((:name "path" :type :string :required t :description "File path")
                  (:name "content" :type :string :required t :description "Content to write"))
    :handler (lambda (args)
              (file-plugin-write plugin (getf args :path) (getf args :content))))

   (make-tool
    :name "delete_file"
    :description "Delete a file"
    :parameters `((:name "path" :type :string :required t :description "File path"))
    :handler (lambda (args)
              (file-plugin-delete plugin (getf args :path))))

   (make-tool
    :name "list_directory"
    :description "List directory contents"
    :parameters `((:name "path" :type :string :required t :description "Directory path")
                  (:name "recursive" :type :boolean :description "List recursively"))
    :handler (lambda (args)
              (file-plugin-list plugin (getf args :path)
                               :recursive (getf args :recursive))))))

