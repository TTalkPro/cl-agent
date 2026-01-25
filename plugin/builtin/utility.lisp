;;;; builtin/utility.lisp
;;;; CL-Agent Plugin - Utility Tools Plugin
;;;;
;;;; Overview:
;;;;   General utility tools for common operations.

(in-package #:cl-agent.plugin)

;;; ============================================================
;;; Utility Plugin Class
;;; ============================================================

(defclass utility-plugin ()
  ((name
    :initform "utility"
    :reader plugin-name)

   (json-max-depth
    :initarg :json-max-depth
    :accessor utility-plugin-json-max-depth
    :initform 100
    :type integer
    :documentation "Maximum JSON parsing depth")

   (json-max-string-length
    :initarg :json-max-string-length
    :accessor utility-plugin-json-max-string-length
    :initform (* 10 1024 1024)  ; 10MB
    :type integer
    :documentation "Maximum JSON string length"))

  (:documentation "Utility tools plugin."))

(defun make-utility-plugin (&key json-max-depth json-max-string-length)
  "Create a utility plugin."
  (make-instance 'utility-plugin
                 :json-max-depth (or json-max-depth 100)
                 :json-max-string-length (or json-max-string-length
                                             (* 10 1024 1024))))

;;; ============================================================
;;; Timestamp Operations
;;; ============================================================

(defgeneric utility-timestamp (plugin &key format timezone)
  (:documentation "Get current timestamp."))

(defmethod utility-timestamp ((plugin utility-plugin) &key format timezone)
  "Get current timestamp."
  (declare (ignore plugin timezone))
  (let ((now (get-universal-time)))
    (case format
      (:unix (- now (encode-universal-time 0 0 0 1 1 1970 0)))
      (:iso (cl-agent.core:format-timestamp now))
      (otherwise (cl-agent.core:format-timestamp now)))))

;;; ============================================================
;;; UUID Operations
;;; ============================================================

(defgeneric utility-uuid (plugin &key version)
  (:documentation "Generate a UUID."))

(defmethod utility-uuid ((plugin utility-plugin) &key version)
  "Generate a UUID."
  (declare (ignore plugin version))
  (cl-agent.core:generate-uuid))

;;; ============================================================
;;; JSON Operations
;;; ============================================================

(defgeneric utility-json-parse (plugin json-string)
  (:documentation "Parse JSON string."))

(defmethod utility-json-parse ((plugin utility-plugin) json-string)
  "Parse JSON string."
  (when (> (length json-string) (utility-plugin-json-max-string-length plugin))
    (error "JSON string exceeds maximum length"))
  (com.inuoe.jzon:parse json-string))

(defgeneric utility-json-stringify (plugin object &key pretty)
  (:documentation "Convert object to JSON string."))

(defmethod utility-json-stringify ((plugin utility-plugin) object &key pretty)
  "Convert object to JSON string."
  (declare (ignore pretty))
  (com.inuoe.jzon:stringify object))

;;; ============================================================
;;; String Operations
;;; ============================================================

(defgeneric utility-string-split (plugin string separator)
  (:documentation "Split string by separator."))

(defmethod utility-string-split ((plugin utility-plugin) string separator)
  "Split string by separator."
  (declare (ignore plugin))
  (cl-ppcre:split separator string))

(defgeneric utility-string-join (plugin strings separator)
  (:documentation "Join strings with separator."))

(defmethod utility-string-join ((plugin utility-plugin) strings separator)
  "Join strings with separator."
  (declare (ignore plugin))
  (format nil (format nil "~~{~~A~~^~A~~}" separator) strings))

(defgeneric utility-string-replace (plugin string pattern replacement)
  (:documentation "Replace pattern in string."))

(defmethod utility-string-replace ((plugin utility-plugin) string pattern replacement)
  "Replace pattern in string."
  (declare (ignore plugin))
  (cl-ppcre:regex-replace-all pattern string replacement))

;;; ============================================================
;;; Hash/Encoding Operations
;;; ============================================================

(defgeneric utility-base64-encode (plugin string)
  (:documentation "Base64 encode a string."))

(defmethod utility-base64-encode ((plugin utility-plugin) string)
  "Base64 encode a string."
  (declare (ignore plugin))
  (cl-base64:string-to-base64-string string))

(defgeneric utility-base64-decode (plugin string)
  (:documentation "Base64 decode a string."))

(defmethod utility-base64-decode ((plugin utility-plugin) string)
  "Base64 decode a string."
  (declare (ignore plugin))
  (cl-base64:base64-string-to-string string))

;;; ============================================================
;;; Math Operations
;;; ============================================================

(defgeneric utility-math-eval (plugin expression)
  (:documentation "Evaluate a math expression (safe subset)."))

(defmethod utility-math-eval ((plugin utility-plugin) expression)
  "Evaluate a simple math expression.
   Supports: +, -, *, /, parentheses, numbers"
  (declare (ignore plugin))
  ;; Simple and safe: only allow numbers and basic operations
  (let ((sanitized (cl-ppcre:regex-replace-all "[^0-9+\\-*/().\\s]" expression "")))
    (when (string/= sanitized expression)
      (error "Invalid characters in expression"))
    ;; Use reader in a safe way
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

;;; ============================================================
;;; Plugin Tools Registration
;;; ============================================================

(defun utility-plugin-tools (plugin)
  "Get tool definitions for utility plugin."
  (list
   (make-tool
    :name "get_timestamp"
    :description "Get current timestamp"
    :parameters `((:name "format" :type :string
                  :description "Format: unix or iso (default: iso)"))
    :handler (lambda (args)
              (let ((fmt (getf args :format)))
                (utility-timestamp plugin
                                  :format (if (string-equal fmt "unix")
                                             :unix :iso)))))

   (make-tool
    :name "generate_uuid"
    :description "Generate a UUID"
    :parameters `()
    :handler (lambda (args)
              (declare (ignore args))
              (utility-uuid plugin)))

   (make-tool
    :name "json_parse"
    :description "Parse JSON string"
    :parameters `((:name "json" :type :string :required t
                  :description "JSON string to parse"))
    :handler (lambda (args)
              (utility-json-parse plugin (getf args :json))))

   (make-tool
    :name "json_stringify"
    :description "Convert object to JSON string"
    :parameters `((:name "object" :type :object :required t
                  :description "Object to stringify"))
    :handler (lambda (args)
              (utility-json-stringify plugin (getf args :object))))

   (make-tool
    :name "string_replace"
    :description "Replace pattern in string"
    :parameters `((:name "string" :type :string :required t :description "Input string")
                  (:name "pattern" :type :string :required t :description "Pattern to find")
                  (:name "replacement" :type :string :required t :description "Replacement"))
    :handler (lambda (args)
              (utility-string-replace plugin
                                     (getf args :string)
                                     (getf args :pattern)
                                     (getf args :replacement))))

   (make-tool
    :name "math_eval"
    :description "Evaluate a math expression"
    :parameters `((:name "expression" :type :string :required t
                  :description "Math expression (e.g., 2 + 3 * 4)"))
    :handler (lambda (args)
              (utility-math-eval plugin (getf args :expression))))))

