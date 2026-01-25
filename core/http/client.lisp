;;;; client.lisp
;;;; CL-Agent HTTP - 同步 HTTP 客户端
;;;;
;;;; 概述：
;;;;   基于 Dexador 的同步 HTTP 客户端封装
;;;;
;;;; 特性：
;;;;   - 统一的请求接口
;;;;   - 自动 JSON 序列化/反序列化
;;;;   - 完整的错误处理
;;;;   - 响应结构化
;;;;
;;;; 使用示例：
;;;;   (http-get "https://api.example.com/users")
;;;;   (http-post "https://api.example.com/users"
;;;;              :body '(("name" . "Alice"))
;;;;              :content-type :json)

(in-package #:cl-agent.http)

;;; ============================================================
;;; 全局配置
;;; ============================================================

(defvar *default-timeout* 30
  "默认请求超时时间（秒）")

(defvar *http-user-agent* "CL-Agent/1.0"
  "HTTP User-Agent 请求头")

;;; ============================================================
;;; 响应结构
;;; ============================================================

(defstruct http-response
  "HTTP 响应结构

槽位说明：
  STATUS  - HTTP 状态码
  HEADERS - 响应头 alist
  BODY    - 响应体（字符串或字节数组）
  URI     - 最终请求的 URI（可能经过重定向）"
  (status 0 :type fixnum)
  (headers nil :type list)
  (body nil)
  (uri nil :type (or null string)))

;;; ============================================================
;;; 响应谓词
;;; ============================================================

(defun http-success-p (response)
  "检查响应是否成功 (2xx)

参数：
  RESPONSE - http-response 结构或状态码

返回：
  t 或 nil"
  (let ((status (if (http-response-p response)
                    (http-response-status response)
                    response)))
    (and (>= status 200) (< status 300))))

(defun http-client-error-p (response)
  "检查响应是否为客户端错误 (4xx)

参数：
  RESPONSE - http-response 结构或状态码

返回：
  t 或 nil"
  (let ((status (if (http-response-p response)
                    (http-response-status response)
                    response)))
    (and (>= status 400) (< status 500))))

(defun http-server-error-p (response)
  "检查响应是否为服务端错误 (5xx)

参数：
  RESPONSE - http-response 结构或状态码

返回：
  t 或 nil"
  (let ((status (if (http-response-p response)
                    (http-response-status response)
                    response)))
    (>= status 500)))

;;; ============================================================
;;; 工具函数
;;; ============================================================

(defun build-url (base-url &optional path query-params)
  "构建完整 URL

参数：
  BASE-URL     - 基础 URL
  PATH         - 路径（可选）
  QUERY-PARAMS - 查询参数 alist（可选）

返回：
  完整 URL 字符串

示例：
  (build-url \"https://api.example.com\" \"/users\" '((\"page\" . \"1\")))
  => \"https://api.example.com/users?page=1\""
  (let ((url (if path
                 (concatenate 'string
                              (string-right-trim "/" base-url)
                              "/"
                              (string-left-trim "/" path))
                 base-url)))
    (if query-params
        (concatenate 'string url "?" (encode-query-params query-params))
        url)))

(defun encode-query-params (params)
  "编码查询参数

参数：
  PARAMS - 参数 alist

返回：
  URL 编码的查询字符串

示例：
  (encode-query-params '((\"name\" . \"Alice\") (\"age\" . \"30\")))
  => \"name=Alice&age=30\""
  (format nil "~{~A~^&~}"
          (loop for (key . value) in params
                collect (format nil "~A=~A"
                                (quri:url-encode (princ-to-string key))
                                (quri:url-encode (princ-to-string value))))))

(defun parse-content-type (content-type)
  "解析 Content-Type 头

参数：
  CONTENT-TYPE - Content-Type 字符串

返回：
  plist (:type TYPE :charset CHARSET)

示例：
  (parse-content-type \"application/json; charset=utf-8\")
  => (:type \"application/json\" :charset \"utf-8\")"
  (when content-type
    (let* ((parts (cl-ppcre:split ";\\s*" content-type))
           (type (first parts))
           (charset (loop for part in (rest parts)
                          when (cl-ppcre:scan "^charset=" part)
                          return (subseq part 8))))
      (list :type type :charset charset))))

(defun json-body (data)
  "将数据转换为 JSON 字符串

参数：
  DATA - Lisp 数据（alist、plist 或其他）

返回：
  JSON 字符串"
  (com.inuoe.jzon:stringify data))

(defun parse-json-body (body)
  "解析 JSON 响应体

参数：
  BODY - JSON 字符串

返回：
  解析后的 Lisp 数据"
  (when (and body (> (length body) 0))
    (com.inuoe.jzon:parse body :key-fn #'alexandria:make-keyword)))

;;; ============================================================
;;; 核心请求函数
;;; ============================================================

(defun http-request (url &key
                           (method :get)
                           headers
                           body
                           (content-type nil)
                           (timeout *default-timeout*)
                           (want-stream nil)
                           (force-binary nil)
                           (keep-alive t)
                           (parse-json t))
  "发送 HTTP 请求

参数：
  URL          - 请求 URL
  METHOD       - HTTP 方法（:get, :post, :put, :delete, :patch, :head）
  HEADERS      - 请求头 alist
  BODY         - 请求体（字符串、字节数组或 alist）
  CONTENT-TYPE - 内容类型（:json, :form, 或字符串）
  TIMEOUT      - 超时时间（秒）
  WANT-STREAM  - 是否返回流而不是字符串
  FORCE-BINARY - 是否强制返回字节数组
  KEEP-ALIVE   - 是否保持连接
  PARSE-JSON   - 是否自动解析 JSON 响应

返回：
  http-response 结构

示例：
  ;; GET 请求
  (http-request \"https://api.example.com/users\")

  ;; POST JSON
  (http-request \"https://api.example.com/users\"
                :method :post
                :body '((\"name\" . \"Alice\"))
                :content-type :json)

  ;; 带自定义头的请求
  (http-request \"https://api.example.com/data\"
                :headers '((\"Authorization\" . \"Bearer token\")))"

  ;; 处理内容类型和请求体
  (let* ((final-headers (copy-list headers))
         (final-body body))

    ;; 添加 User-Agent
    (unless (assoc "User-Agent" final-headers :test #'string-equal)
      (push (cons "User-Agent" *http-user-agent*) final-headers))

    ;; 处理 content-type
    (when content-type
      (let ((ct-string (case content-type
                         (:json "application/json")
                         (:form "application/x-www-form-urlencoded")
                         (otherwise content-type))))
        (unless (assoc "Content-Type" final-headers :test #'string-equal)
          (push (cons "Content-Type" ct-string) final-headers))))

    ;; 如果 body 是 alist 且 content-type 是 :json，自动序列化
    (when (and (consp body)
               (eq content-type :json))
      (setf final-body (json-body body)))

    ;; 执行请求
    (handler-case
        (multiple-value-bind (response-body status-code response-headers uri stream)
            (dexador:request url
                             :method method
                             :headers final-headers
                             :content final-body
                             :connect-timeout timeout
                             :read-timeout timeout
                             :want-stream want-stream
                             :force-binary force-binary
                             :keep-alive keep-alive)
          (declare (ignore stream))

          ;; 构建响应
          (let* ((headers-alist (if (hash-table-p response-headers)
                                    ;; 将 hash-table 转换为 alist
                                    (let ((result nil))
                                      (maphash (lambda (k v)
                                                 (push (cons k v) result))
                                               response-headers)
                                      result)
                                    response-headers))
                 (body-str (if (and (stringp response-body)
                                    parse-json
                                    (let ((ct (if (hash-table-p response-headers)
                                                  (gethash :content-type response-headers)
                                                  (cdr (assoc :content-type response-headers)))))
                                      (and ct (search "application/json" ct))))
                               (parse-json-body response-body)
                               response-body))
                 (response (make-http-response
                            :status status-code
                            :headers headers-alist
                            :body body-str
                            :uri (when uri (quri:render-uri uri)))))

            ;; 检查错误状态
            (when (>= status-code 400)
              (signal-http-error status-code
                                 :body response-body
                                 :uri url
                                 :headers response-headers))

            response))

      ;; 处理 Dexador 特定异常
      (dexador:http-request-failed (e)
        (signal-http-error (dexador:response-status e)
                           :body (dexador:response-body e)
                           :uri url
                           :cause e))

      (usocket:timeout-error (e)
        (signal-timeout-error url :timeout timeout :cause e))

      (usocket:socket-error (e)
        (signal-connection-error (quri:uri-host (quri:uri url))
                                 :port (quri:uri-port (quri:uri url))
                                 :uri url
                                 :cause e))

      (error (e)
        (error 'http-error
               :uri url
               :cause e)))))

;;; ============================================================
;;; 便捷方法
;;; ============================================================

(defun http-get (url &key headers (timeout *default-timeout*) query-params (parse-json t))
  "发送 GET 请求

参数：
  URL          - 请求 URL
  HEADERS      - 请求头
  TIMEOUT      - 超时时间
  QUERY-PARAMS - 查询参数 alist
  PARSE-JSON   - 是否自动解析 JSON

返回：
  http-response 结构

示例：
  (http-get \"https://api.example.com/users\"
            :query-params '((\"page\" . \"1\") (\"limit\" . \"10\")))"
  (let ((final-url (if query-params
                       (build-url url nil query-params)
                       url)))
    (http-request final-url
                  :method :get
                  :headers headers
                  :timeout timeout
                  :parse-json parse-json)))

(defun http-post (url &key headers body (content-type :json) (timeout *default-timeout*) (parse-json t))
  "发送 POST 请求

参数：
  URL          - 请求 URL
  HEADERS      - 请求头
  BODY         - 请求体
  CONTENT-TYPE - 内容类型（默认 :json）
  TIMEOUT      - 超时时间
  PARSE-JSON   - 是否自动解析 JSON

返回：
  http-response 结构

示例：
  (http-post \"https://api.example.com/users\"
             :body '((\"name\" . \"Alice\") (\"email\" . \"alice@example.com\")))"
  (http-request url
                :method :post
                :headers headers
                :body body
                :content-type content-type
                :timeout timeout
                :parse-json parse-json))

(defun http-put (url &key headers body (content-type :json) (timeout *default-timeout*) (parse-json t))
  "发送 PUT 请求

参数：
  URL          - 请求 URL
  HEADERS      - 请求头
  BODY         - 请求体
  CONTENT-TYPE - 内容类型（默认 :json）
  TIMEOUT      - 超时时间
  PARSE-JSON   - 是否自动解析 JSON

返回：
  http-response 结构"
  (http-request url
                :method :put
                :headers headers
                :body body
                :content-type content-type
                :timeout timeout
                :parse-json parse-json))

(defun http-delete (url &key headers body (timeout *default-timeout*) (parse-json t))
  "发送 DELETE 请求

参数：
  URL        - 请求 URL
  HEADERS    - 请求头
  BODY       - 请求体（可选）
  TIMEOUT    - 超时时间
  PARSE-JSON - 是否自动解析 JSON

返回：
  http-response 结构"
  (http-request url
                :method :delete
                :headers headers
                :body body
                :timeout timeout
                :parse-json parse-json))

(defun http-patch (url &key headers body (content-type :json) (timeout *default-timeout*) (parse-json t))
  "发送 PATCH 请求

参数：
  URL          - 请求 URL
  HEADERS      - 请求头
  BODY         - 请求体
  CONTENT-TYPE - 内容类型（默认 :json）
  TIMEOUT      - 超时时间
  PARSE-JSON   - 是否自动解析 JSON

返回：
  http-response 结构"
  (http-request url
                :method :patch
                :headers headers
                :body body
                :content-type content-type
                :timeout timeout
                :parse-json parse-json))

(defun http-head (url &key headers (timeout *default-timeout*))
  "发送 HEAD 请求

参数：
  URL     - 请求 URL
  HEADERS - 请求头
  TIMEOUT - 超时时间

返回：
  http-response 结构（body 为 nil）"
  (http-request url
                :method :head
                :headers headers
                :timeout timeout
                :parse-json nil))
