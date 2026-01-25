;;;; builtin/http.lisp
;;;; CL-Agent Plugin - HTTP Requests Plugin
;;;;
;;;; Overview:
;;;;   Secure HTTP client plugin with rate limiting and domain filtering.

(in-package #:cl-agent.plugin)

;;; ============================================================
;;; HTTP Plugin Class
;;; ============================================================

(defclass http-plugin ()
  ((name
    :initform "http"
    :reader plugin-name)

   (allowed-domains
    :initarg :allowed-domains
    :accessor http-plugin-allowed-domains
    :initform nil
    :type list
    :documentation "Allowed domains (nil = all)")

   (blocked-domains
    :initarg :blocked-domains
    :accessor http-plugin-blocked-domains
    :initform '("localhost" "127.0.0.1" "0.0.0.0" "internal")
    :type list
    :documentation "Blocked domains")

   (timeout
    :initarg :timeout
    :accessor http-plugin-timeout
    :initform 30
    :type integer
    :documentation "Request timeout in seconds")

   (max-response-size
    :initarg :max-response-size
    :accessor http-plugin-max-response-size
    :initform (* 5 1024 1024)  ; 5MB
    :type integer
    :documentation "Maximum response size")

   (rate-limiter
    :initarg :rate-limiter
    :accessor http-plugin-rate-limiter
    :initform nil
    :documentation "Rate limiter")

   (user-agent
    :initarg :user-agent
    :accessor http-plugin-user-agent
    :initform "CL-Agent/1.0"
    :type string
    :documentation "User agent string")

   (security-policy
    :initarg :security-policy
    :accessor http-plugin-security-policy
    :initform nil
    :documentation "Security policy"))

  (:documentation "Secure HTTP client plugin."))

(defun make-http-plugin (&key allowed-domains blocked-domains timeout
                               max-response-size rate-limit user-agent
                               security-policy)
  "Create an HTTP plugin.

Parameters:
  ALLOWED-DOMAINS   - List of allowed domains
  BLOCKED-DOMAINS   - List of blocked domains
  TIMEOUT           - Request timeout
  MAX-RESPONSE-SIZE - Maximum response size
  RATE-LIMIT        - Rate limit (requests/minute)
  USER-AGENT        - User agent string
  SECURITY-POLICY   - Security policy

Returns:
  http-plugin instance"
  (make-instance 'http-plugin
                 :allowed-domains allowed-domains
                 :blocked-domains (or blocked-domains
                                     '("localhost" "127.0.0.1" "0.0.0.0"))
                 :timeout (or timeout 30)
                 :max-response-size (or max-response-size (* 5 1024 1024))
                 :rate-limiter (when rate-limit
                                (make-rate-limiter rate-limit))
                 :user-agent (or user-agent "CL-Agent/1.0")
                 :security-policy security-policy))

;;; ============================================================
;;; URL Validation
;;; ============================================================

(defun validate-http-url (plugin url)
  "Validate a URL against plugin restrictions.

Parameters:
  PLUGIN - HTTP plugin
  URL    - URL to validate

Returns:
  T if valid, signals error otherwise"
  (let ((domain (extract-domain url)))
    (unless domain
      (error "Invalid URL: ~A" url))

    ;; Check blocked domains
    (when (member domain (http-plugin-blocked-domains plugin)
                  :test #'string-equal)
      (error "Domain is blocked: ~A" domain))

    ;; Check allowed domains
    (when (http-plugin-allowed-domains plugin)
      (unless (member domain (http-plugin-allowed-domains plugin)
                      :test #'string-equal)
        (error "Domain not in allowed list: ~A" domain))))

  ;; Check rate limit
  (when (http-plugin-rate-limiter plugin)
    (unless (rate-limiter-check (http-plugin-rate-limiter plugin))
      (error "Rate limit exceeded")))

  t)

;;; ============================================================
;;; HTTP Operations
;;; ============================================================

(defgeneric http-plugin-get (plugin url &key headers)
  (:documentation "Perform HTTP GET request."))

(defmethod http-plugin-get ((plugin http-plugin) url &key headers)
  "Perform HTTP GET request."
  (validate-http-url plugin url)
  (http-plugin-request plugin url :method :get :headers headers))

(defgeneric http-plugin-post (plugin url &key body headers content-type)
  (:documentation "Perform HTTP POST request."))

(defmethod http-plugin-post ((plugin http-plugin) url
                              &key body headers (content-type "application/json"))
  "Perform HTTP POST request."
  (validate-http-url plugin url)
  (http-plugin-request plugin url
                        :method :post
                        :body body
                        :headers headers
                        :content-type content-type))

(defgeneric http-plugin-request (plugin url &key method body headers content-type)
  (:documentation "Perform HTTP request."))

(defmethod http-plugin-request ((plugin http-plugin) url
                                 &key (method :get) body headers content-type)
  "Perform HTTP request."
  (validate-http-url plugin url)

  (let ((all-headers (append
                      headers
                      `(("User-Agent" . ,(http-plugin-user-agent plugin))))))
    (when content-type
      (push (cons "Content-Type" content-type) all-headers))

    ;; Use cl-agent.core http client or dexador
    (handler-case
        (multiple-value-bind (body status response-headers)
            (dex:request url
                        :method method
                        :content body
                        :headers all-headers
                        :read-timeout (http-plugin-timeout plugin)
                        :connect-timeout (http-plugin-timeout plugin))
          (list :status status
                :headers response-headers
                :body body
                :success (and (>= status 200) (< status 300))))
      (error (e)
        (list :status nil
              :error (format nil "~A" e)
              :success nil)))))

;;; ============================================================
;;; Plugin Tools Registration
;;; ============================================================

(defun http-plugin-tools (plugin)
  "Get tool definitions for HTTP plugin."
  (list
   (make-tool
    :name "http_get"
    :description "Perform HTTP GET request"
    :parameters `((:name "url" :type :string :required t :description "URL to fetch")
                  (:name "headers" :type :object :description "Request headers"))
    :handler (lambda (args)
              (http-plugin-get plugin (getf args :url)
                              :headers (getf args :headers))))

   (make-tool
    :name "http_post"
    :description "Perform HTTP POST request"
    :parameters `((:name "url" :type :string :required t :description "URL to post to")
                  (:name "body" :type :string :description "Request body")
                  (:name "headers" :type :object :description "Request headers"))
    :handler (lambda (args)
              (http-plugin-post plugin (getf args :url)
                               :body (getf args :body)
                               :headers (getf args :headers))))))

