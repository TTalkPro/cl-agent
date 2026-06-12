;;;; builtin.lisp
;;;; CL-Agent Tools - Builtin Tools with Tags
;;;;
;;;; Overview:
;;;;   Provides built-in tools with tag-based categorization.
;;;;   These tools can be used directly with Kernel's tool-registry.
;;;;
;;;; Tags:
;;;;   :file    - File operations
;;;;   :http    - HTTP/network operations
;;;;   :shell   - Shell command execution
;;;;   :utility - General utility functions
;;;;   :read    - Read-only operations
;;;;   :write   - Write operations
;;;;   :dangerous - Potentially dangerous operations
;;;;   :safe    - Safe operations
;;;;   :io      - Input/output operations
;;;;   :network - Network operations

(in-package #:cl-agent.tools)

;;; ============================================================
;;; Helper Functions
;;; ============================================================

(defun extract-domain-from-url (url)
  "Extract domain from URL string."
  (handler-case
      (let ((uri (quri:uri url)))
        (quri:uri-host uri))
    (error () nil)))

;;; ============================================================
;;; File Tools
;;; ============================================================

(defun make-read-file-tool (&key allowed-paths max-file-size)
  "Create a read_file tool.

Parameters:
  ALLOWED-PATHS - List of allowed path prefixes (nil = all)
  MAX-FILE-SIZE - Maximum file size in bytes (default 10MB)

Returns:
  Tool instance with tags: (:file :read :io :safe)"
  (let ((max-size (or max-file-size (* 10 1024 1024))))
    (make-simple-tool
     :read_file
     "Read contents of a file"
     (lambda (&key path encoding)
       (declare (ignore encoding))
       ;; Validate path
       (when allowed-paths
         (unless (some (lambda (prefix)
                        (and (>= (length path) (length prefix))
                             (string= prefix (subseq path 0 (length prefix)))))
                      allowed-paths)
           (error "Path not in allowed paths: ~A" path)))
       (when (search ".." path)
         (error "Path traversal not allowed: ~A" path))
       ;; Check file exists
       (unless (probe-file path)
         (error "File not found: ~A" path))
       ;; Check size
       (let ((size (with-open-file (s path) (file-length s))))
         (when (> size max-size)
           (error "File too large: ~A bytes (max: ~A)" size max-size)))
       ;; Read file
       (with-open-file (stream path :direction :input)
         (let ((content (make-string (file-length stream))))
           (read-sequence content stream)
           content)))
     :parameters '((:path :type :string :description "File path to read" :required-p t)
                   (:encoding :type :string :description "File encoding (default: utf-8)"))
     :category :file
     :tags '(:file :read :io :safe))))

(defun make-write-file-tool (&key allowed-paths blocked-extensions max-file-size)
  "Create a write_file tool.

Parameters:
  ALLOWED-PATHS      - List of allowed path prefixes (nil = all)
  BLOCKED-EXTENSIONS - List of blocked file extensions
  MAX-FILE-SIZE      - Maximum content size in bytes (default 10MB)

Returns:
  Tool instance with tags: (:file :write :io)"
  (let ((max-size (or max-file-size (* 10 1024 1024)))
        (blocked (or blocked-extensions '(".exe" ".dll" ".so" ".dylib" ".bin"))))
    (make-simple-tool
     :write_file
     "Write content to a file"
     (lambda (&key path content)
       ;; Validate path
       (when allowed-paths
         (unless (some (lambda (prefix)
                        (and (>= (length path) (length prefix))
                             (string= prefix (subseq path 0 (length prefix)))))
                      allowed-paths)
           (error "Path not in allowed paths: ~A" path)))
       (when (search ".." path)
         (error "Path traversal not allowed: ~A" path))
       ;; Check extension
       (let ((ext (pathname-type (pathname path))))
         (when (and ext (member (concatenate 'string "." ext) blocked :test #'string-equal))
           (error "Blocked file extension: ~A" ext)))
       ;; Check content size
       (when (> (length content) max-size)
         (error "Content too large: ~A bytes (max: ~A)" (length content) max-size))
       ;; Write file
       (ensure-directories-exist path)
       (with-open-file (stream path
                               :direction :output
                               :if-exists :supersede
                               :if-does-not-exist :create)
         (write-sequence content stream))
       (list :path path :size (length content) :success t))
     :parameters '((:path :type :string :description "File path to write" :required-p t)
                   (:content :type :string :description "Content to write" :required-p t))
     :category :file
     :tags '(:file :write :io))))

(defun make-delete-file-tool (&key allowed-paths)
  "Create a delete_file tool.

Parameters:
  ALLOWED-PATHS - List of allowed path prefixes (nil = all)

Returns:
  Tool instance with tags: (:file :write :io :dangerous)"
  (make-simple-tool
   :delete_file
   "Delete a file"
   (lambda (&key path)
     ;; Validate path
     (when allowed-paths
       (unless (some (lambda (prefix)
                      (and (>= (length path) (length prefix))
                           (string= prefix (subseq path 0 (length prefix)))))
                    allowed-paths)
         (error "Path not in allowed paths: ~A" path)))
     (when (search ".." path)
       (error "Path traversal not allowed: ~A" path))
     (unless (probe-file path)
       (error "File not found: ~A" path))
     (delete-file path)
     (list :path path :deleted t))
   :parameters '((:path :type :string :description "File path to delete" :required-p t))
   :category :file
   :tags '(:file :write :io :dangerous)))

(defun make-list-directory-tool (&key allowed-paths)
  "Create a list_directory tool.

Parameters:
  ALLOWED-PATHS - List of allowed path prefixes (nil = all)

Returns:
  Tool instance with tags: (:file :read :io :safe)"
  (make-simple-tool
   :list_directory
   "List contents of a directory"
   (lambda (&key path recursive)
     ;; Validate path
     (when allowed-paths
       (unless (some (lambda (prefix)
                      (and (>= (length path) (length prefix))
                           (string= prefix (subseq path 0 (length prefix)))))
                    allowed-paths)
         (error "Path not in allowed paths: ~A" path)))
     ;; List directory
     (let ((entries nil))
       (if recursive
           (dolist (entry (directory (merge-pathnames "**/*.*" path)))
             (push (list :name (enough-namestring entry path)
                        :path (namestring entry))
                   entries))
           (dolist (entry (directory (merge-pathnames "*.*" path)))
             (push (list :name (enough-namestring entry path)
                        :path (namestring entry))
                   entries)))
       (nreverse entries)))
   :parameters '((:path :type :string :description "Directory path" :required-p t)
                 (:recursive :type :boolean :description "List recursively"))
   :category :file
   :tags '(:file :read :io :safe)))

;;; ============================================================
;;; HTTP Tools
;;; ============================================================

(defun make-http-get-tool (&key blocked-domains timeout user-agent)
  "Create an http_get tool.

Parameters:
  BLOCKED-DOMAINS - List of blocked domains
  TIMEOUT         - Request timeout in seconds (default 30)
  USER-AGENT      - User agent string

Returns:
  Tool instance with tags: (:http :network :read :safe)"
  (let ((blocked (or blocked-domains '("localhost" "127.0.0.1" "0.0.0.0")))
        (req-timeout (or timeout 30))
        (ua (or user-agent "CL-Agent/1.0")))
    (make-simple-tool
     :http_get
     "Perform HTTP GET request"
     (lambda (&key url headers)
       ;; Validate domain
       (let ((domain (extract-domain-from-url url)))
         (when (member domain blocked :test #'string-equal)
           (error "Domain is blocked: ~A" domain)))
       ;; Make request
       (handler-case
           (multiple-value-bind (body status response-headers)
               (dex:get url
                       :headers (append headers `(("User-Agent" . ,ua)))
                       :read-timeout req-timeout
                       :connect-timeout req-timeout)
             (list :status status
                   :headers response-headers
                   :body body
                   :success (and (>= status 200) (< status 300))))
         (error (e)
           (list :status nil :error (format nil "~A" e) :success nil))))
     :parameters '((:url :type :string :description "URL to fetch" :required-p t)
                   (:headers :type :object :description "Request headers"))
     :category :http
     :tags '(:http :network :read :safe))))

(defun make-http-post-tool (&key blocked-domains timeout user-agent)
  "Create an http_post tool.

Parameters:
  BLOCKED-DOMAINS - List of blocked domains
  TIMEOUT         - Request timeout in seconds (default 30)
  USER-AGENT      - User agent string

Returns:
  Tool instance with tags: (:http :network :write)"
  (let ((blocked (or blocked-domains '("localhost" "127.0.0.1" "0.0.0.0")))
        (req-timeout (or timeout 30))
        (ua (or user-agent "CL-Agent/1.0")))
    (make-simple-tool
     :http_post
     "Perform HTTP POST request"
     (lambda (&key url body headers content-type)
       ;; Validate domain
       (let ((domain (extract-domain-from-url url)))
         (when (member domain blocked :test #'string-equal)
           (error "Domain is blocked: ~A" domain)))
       ;; Make request
       (let ((all-headers (append headers
                                  `(("User-Agent" . ,ua)
                                    ("Content-Type" . ,(or content-type "application/json"))))))
         (handler-case
             (multiple-value-bind (response-body status response-headers)
                 (dex:post url
                          :content body
                          :headers all-headers
                          :read-timeout req-timeout
                          :connect-timeout req-timeout)
               (list :status status
                     :headers response-headers
                     :body response-body
                     :success (and (>= status 200) (< status 300))))
           (error (e)
             (list :status nil :error (format nil "~A" e) :success nil)))))
     :parameters '((:url :type :string :description "URL to post to" :required-p t)
                   (:body :type :string :description "Request body")
                   (:headers :type :object :description "Request headers")
                   (:content-type :type :string :description "Content type"))
     :category :http
     :tags '(:http :network :write))))

;;; ============================================================
;;; Shell Tools
;;; ============================================================

(defun make-execute-command-tool (&key blocked-commands timeout working-directory)
  "Create an execute_command tool.

Parameters:
  BLOCKED-COMMANDS  - List of blocked command patterns
  TIMEOUT           - Command timeout in seconds (default 60)
  WORKING-DIRECTORY - Working directory for commands

Returns:
  Tool instance with tags: (:shell :dangerous)"
  (let ((blocked (or blocked-commands
                     '("rm -rf" "dd if=" "mkfs" "fdisk" "sudo" "su ")))
        (cmd-timeout (or timeout 60)))
    (make-simple-tool
     :execute_command
     "Execute a shell command"
     (lambda (&key command timeout)
       ;; Validate command
       (dolist (pattern blocked)
         (when (search pattern command :test #'char-equal)
           (error "Command contains blocked pattern: ~A" pattern)))
       ;; Execute
       (handler-case
           (multiple-value-bind (output error-output exit-code)
               (uiop:run-program command
                                :output '(:string :stripped t)
                                :error-output '(:string :stripped t)
                                :ignore-error-status t
                                :directory working-directory)
             (list :command command
                   :exit-code exit-code
                   :stdout output
                   :stderr error-output
                   :success (zerop exit-code)))
         (error (e)
           (list :command command
                 :exit-code -1
                 :error (format nil "~A" e)
                 :success nil))))
     :parameters '((:command :type :string :description "Command to execute" :required-p t)
                   (:timeout :type :integer :description "Timeout in seconds"))
     :category :shell
     :tags '(:shell :dangerous))))

;;; ============================================================
;;; Utility Tools
;;; ============================================================

(defun make-get-timestamp-tool ()
  "Create a get_timestamp tool.

Returns:
  Tool instance with tags: (:utility :safe)"
  (make-simple-tool
   :get_timestamp
   "Get current timestamp"
   (lambda (&key format)
     (let ((now (get-universal-time)))
       (if (string-equal format "unix")
           (- now (encode-universal-time 0 0 0 1 1 1970 0))
           (cl-agent.core:format-timestamp now))))
   :parameters '((:format :type :string :description "Format: unix or iso (default: iso)"))
   :category :utility
   :tags '(:utility :safe)))

(defun make-generate-uuid-tool ()
  "Create a generate_uuid tool.

Returns:
  Tool instance with tags: (:utility :safe)"
  (make-simple-tool
   :generate_uuid
   "Generate a UUID"
   (lambda (&key)
     (cl-agent.core:generate-uuid))
   :parameters '()
   :category :utility
   :tags '(:utility :safe)))

(defun make-json-parse-tool (&key max-string-length)
  "Create a json_parse tool.

Parameters:
  MAX-STRING-LENGTH - Maximum JSON string length (default 10MB)

Returns:
  Tool instance with tags: (:utility :safe)"
  (let ((max-len (or max-string-length (* 10 1024 1024))))
    (make-simple-tool
     :json_parse
     "Parse JSON string"
     (lambda (&key json)
       (when (> (length json) max-len)
         (error "JSON string exceeds maximum length"))
       (com.inuoe.jzon:parse json))
     :parameters '((:json :type :string :description "JSON string to parse" :required-p t))
     :category :utility
     :tags '(:utility :safe))))

(defun make-json-stringify-tool ()
  "Create a json_stringify tool.

Returns:
  Tool instance with tags: (:utility :safe)"
  (make-simple-tool
   :json_stringify
   "Convert object to JSON string"
   (lambda (&key object)
     (com.inuoe.jzon:stringify object))
   :parameters '((:object :type :object :description "Object to stringify" :required-p t))
   :category :utility
   :tags '(:utility :safe)))

(defun make-string-replace-tool ()
  "Create a string_replace tool.

Returns:
  Tool instance with tags: (:utility :safe)"
  (make-simple-tool
   :string_replace
   "Replace pattern in string"
   (lambda (&key string pattern replacement)
     (cl-ppcre:regex-replace-all pattern string replacement))
   :parameters '((:string :type :string :description "Input string" :required-p t)
                 (:pattern :type :string :description "Pattern to find" :required-p t)
                 (:replacement :type :string :description "Replacement" :required-p t))
   :category :utility
   :tags '(:utility :safe)))

(defun make-math-eval-tool ()
  "Create a math_eval tool.

Returns:
  Tool instance with tags: (:utility :safe)"
  (make-simple-tool
   :math_eval
   "Evaluate a math expression"
   (lambda (&key expression)
     ;; Only allow numbers and basic operations
     (let ((sanitized (cl-ppcre:regex-replace-all "[^0-9+\\-*/().\\s]" expression "")))
       (when (string/= sanitized expression)
         (error "Invalid characters in expression"))
       (handler-case
           (let ((form (read-from-string (format nil "(~A)" sanitized))))
             (if (and (listp form)
                     (every (lambda (x)
                             (or (numberp x)
                                (member x '(+ - * /))))
                           (alexandria:flatten form)))
                 (eval form)
                 (error "Invalid expression")))
         (error (e)
           (error "Failed to evaluate expression: ~A" e)))))
   :parameters '((:expression :type :string :description "Math expression (e.g., 2 + 3 * 4)" :required-p t))
   :category :utility
   :tags '(:utility :safe)))

;;; ============================================================
;;; Tool Collections (Convenience Functions)
;;; ============================================================

(defun create-file-tools (&key allowed-paths blocked-extensions max-file-size)
  "Create all file operation tools.

Parameters:
  ALLOWED-PATHS      - List of allowed path prefixes
  BLOCKED-EXTENSIONS - List of blocked file extensions
  MAX-FILE-SIZE      - Maximum file size

Returns:
  List of tool instances"
  (list
   (make-read-file-tool :allowed-paths allowed-paths :max-file-size max-file-size)
   (make-write-file-tool :allowed-paths allowed-paths
                         :blocked-extensions blocked-extensions
                         :max-file-size max-file-size)
   (make-delete-file-tool :allowed-paths allowed-paths)
   (make-list-directory-tool :allowed-paths allowed-paths)))

(defun create-http-tools (&key blocked-domains timeout user-agent)
  "Create all HTTP operation tools.

Parameters:
  BLOCKED-DOMAINS - List of blocked domains
  TIMEOUT         - Request timeout
  USER-AGENT      - User agent string

Returns:
  List of tool instances"
  (list
   (make-http-get-tool :blocked-domains blocked-domains
                       :timeout timeout
                       :user-agent user-agent)
   (make-http-post-tool :blocked-domains blocked-domains
                        :timeout timeout
                        :user-agent user-agent)))

(defun create-shell-tools (&key blocked-commands timeout working-directory)
  "Create all shell operation tools.

Parameters:
  BLOCKED-COMMANDS  - List of blocked command patterns
  TIMEOUT           - Command timeout
  WORKING-DIRECTORY - Working directory

Returns:
  List of tool instances"
  (list
   (make-execute-command-tool :blocked-commands blocked-commands
                              :timeout timeout
                              :working-directory working-directory)))

(defun create-utility-tools (&key json-max-length)
  "Create all utility tools.

Parameters:
  JSON-MAX-LENGTH - Maximum JSON string length

Returns:
  List of tool instances"
  (list
   (make-get-timestamp-tool)
   (make-generate-uuid-tool)
   (make-json-parse-tool :max-string-length json-max-length)
   (make-json-stringify-tool)
   (make-string-replace-tool)
   (make-math-eval-tool)))

(defun create-all-builtin-tools (&key file-config http-config shell-config utility-config)
  "Create all builtin tools with optional configurations.

Parameters:
  FILE-CONFIG    - Plist for file tools (:allowed-paths :blocked-extensions :max-file-size)
  HTTP-CONFIG    - Plist for HTTP tools (:blocked-domains :timeout :user-agent)
  SHELL-CONFIG   - Plist for shell tools (:blocked-commands :timeout :working-directory)
  UTILITY-CONFIG - Plist for utility tools (:json-max-length)

Returns:
  List of all builtin tool instances"
  (append
   (apply #'create-file-tools (or file-config '()))
   (apply #'create-http-tools (or http-config '()))
   (apply #'create-shell-tools (or shell-config '()))
   (apply #'create-utility-tools (or utility-config '()))))

(defun create-safe-tools (&key file-config http-config utility-config)
  "Create only safe (read-only, non-dangerous) tools.

Returns:
  List of safe tool instances"
  (list
   (apply #'make-read-file-tool (or file-config '()))
   (apply #'make-list-directory-tool (or file-config '()))
   (apply #'make-http-get-tool (or http-config '()))
   (make-get-timestamp-tool)
   (make-generate-uuid-tool)
   (apply #'make-json-parse-tool (or utility-config '()))
   (make-json-stringify-tool)
   (make-string-replace-tool)
   (make-math-eval-tool)))

(defun register-builtin-tools (registry &key file-config http-config shell-config utility-config)
  "Register all builtin tools to a registry.

Parameters:
  REGISTRY       - Tool registry
  FILE-CONFIG    - File tools configuration
  HTTP-CONFIG    - HTTP tools configuration
  SHELL-CONFIG   - Shell tools configuration
  UTILITY-CONFIG - Utility tools configuration

Returns:
  Number of tools registered"
  (let ((tools (create-all-builtin-tools :file-config file-config
                                         :http-config http-config
                                         :shell-config shell-config
                                         :utility-config utility-config))
        (count 0))
    (dolist (tool tools)
      (register-tool registry tool)
      (incf count))
    count))
