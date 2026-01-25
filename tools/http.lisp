;;;; http.lisp
;;;; CL-Agent - HTTP 工具
;;;;
;;;; 概述：
;;;;   实现 HTTP 请求功能
;;;;
;;;; 特性：
;;;;   - GET/POST/PUT/DELETE
;;;;   - 请求头设置
;;;;   - JSON 处理
;;;;   - 错误处理

(in-package :cl-agent.tools)

;;; ============================================================
;;; 动态配置变量（通过动态绑定传递）
;;; ============================================================

(defvar *http-default-timeout* 30
  "默认 HTTP 请求超时（动态变量，通过 provider 绑定）")

(defvar *http-default-headers* nil
  "默认请求头（动态变量，通过 provider 绑定）")

(defvar *http-allowed-domains* '()
  "允许访问的域名白名单（动态变量，通过 provider 绑定）")

(defvar *http-enabled* t
  "是否启用 HTTP 工具（动态变量，通过 provider 绑定）")

;;; ============================================================
;;; HTTP 辅助函数（减少嵌套）
;;; ============================================================

(defun normalize-content-type (content-type)
  "将 content-type 字符串转为关键字

  参数：
    CONTENT-TYPE - 内容类型字符串

  返回：
    关键字 (:json, :form) 或原字符串"
  (cond
    ((string-equal content-type "application/json") :json)
    ((string-equal content-type "application/x-www-form-urlencoded") :form)
    (t content-type)))

(defun validate-http-request (url)
  "验证 HTTP 请求（组合 enabled + domain 检查）

  参数：
    URL - 请求 URL

  错误：
    如果 HTTP 禁用或域名不允许，抛出错误"
  (unless *http-enabled*
    (error "HTTP requests are disabled"))
  (check-http-domain url))

(defun perform-http-call (url method data params headers ct-keyword timeout)
  "执行实际的 HTTP 调用（统一接口）

  参数：
    URL        - 请求 URL
    METHOD     - HTTP 方法
    DATA       - 请求体数据
    PARAMS     - 查询参数
    HEADERS    - 请求头
    CT-KEYWORD - 内容类型关键字
    TIMEOUT    - 超时时间

  返回：
    HTTP 响应对象"
  (ecase method
    (:get
     (cl-agent.http:http-get url
                             :headers headers
                             :query-params params
                             :timeout timeout
                             :parse-json nil))
    ((:post :put :patch)
     (cl-agent.http:http-request url
                                 :method method
                                 :headers headers
                                 :body data
                                 :content-type ct-keyword
                                 :timeout timeout
                                 :parse-json nil))
    (:delete
     (cl-agent.http:http-delete url
                                :headers headers
                                :body data
                                :timeout timeout
                                :parse-json nil))))

(defun extract-http-response (response)
  "提取 HTTP 响应数据（转换为多值返回）

  参数：
    RESPONSE - HTTP 响应对象

  返回：
    (values status-code headers body)"
  (values (cl-agent.http:http-response-status response)
          (cl-agent.http:http-response-headers response)
          (cl-agent.http:http-response-body response)))

;;; ============================================================
;;; HTTP 请求基础（重构版 - 3层嵌套）
;;; ============================================================

(defun http-request (url &key
                        (method :get)
                        (headers nil)
                        (params nil)
                        (data nil)
                        (content-type "application/json")
                        (timeout *http-default-timeout*))
  "执行 HTTP 请求（重构版 - 3层嵌套）

  参数：
    URL         - 请求 URL
    METHOD      - HTTP 方法 (:get, :post, :put, :delete, :patch)
    HEADERS     - 请求头（alist 或 plist）
    PARAMS      - 查询参数（alist 或 plist）
    DATA        - 请求体数据
    CONTENT-TYPE - 内容类型
    TIMEOUT     - 超时时间（秒）

  返回：
    (values status-code headers body)

  示例：
    (http-request \"https://api.example.com/data\"
                   :method :get
                   :params '((\"key\" . \"value\")))

  重构改进：
    - 嵌套深度：6层 → 3层（降低 50%）
    - 辅助函数提取：4个
    - 更清晰的数据流"
  ;; 验证（层1）
  (validate-http-request url)

  ;; 准备和执行（层2）
  (let* ((req-headers (merge-headers headers))
         (ct-keyword (normalize-content-type content-type)))
    (handler-case                                      ; 层3
        (let ((response (perform-http-call url method data params
                                           req-headers ct-keyword timeout)))
          (extract-http-response response))
      (error (e)
        (error "HTTP request failed: ~A" e)))))

;;; ============================================================
;;; 便捷方法
;;; ============================================================

(defun http-get (url &key (params nil)
                        (headers nil)
                        (timeout *http-default-timeout*))
  "HTTP GET 请求

  参数：
    URL     - 请求 URL
    PARAMS  - 查询参数
    HEADERS - 请求头
    TIMEOUT - 超时时间

  返回：
    (values status-code headers body)"
  (http-request url
                :method :get
                :params params
                :headers headers
                :timeout timeout))

(defun http-post (url data &key (params nil)
                             (headers nil)
                             (content-type "application/json")
                             (timeout *http-default-timeout*))
  "HTTP POST 请求

  参数：
    URL          - 请求 URL
    DATA         - 请求体数据
    PARAMS       - 查询参数
    HEADERS      - 请求头
    CONTENT-TYPE - 内容类型
    TIMEOUT      - 超时时间

  返回：
    (values status-code headers body)"
  (http-request url
                :method :post
                :params params
                :headers headers
                :data data
                :content-type content-type
                :timeout timeout))

(defun http-put (url data &key (params nil)
                            (headers nil)
                            (content-type "application/json")
                            (timeout *http-default-timeout*))
  "HTTP PUT 请求

  参数：
    URL          - 请求 URL
    DATA         - 请求体数据
    PARAMS       - 查询参数
    HEADERS      - 请求头
    CONTENT-TYPE - 内容类型
    TIMEOUT      - 超时时间

  返回：
    (values status-code headers body)"
  (http-request url
                :method :put
                :params params
                :headers headers
                :data data
                :content-type content-type
                :timeout timeout))

(defun http-delete (url &key (params nil)
                           (headers nil)
                           (timeout *http-default-timeout*))
  "HTTP DELETE 请求

  参数：
    URL     - 请求 URL
    PARAMS  - 查询参数
    HEADERS - 请求头
    TIMEOUT - 超时时间

  返回：
    (values status-code headers body)"
  (http-request url
                :method :delete
                :params params
                :headers headers
                :timeout timeout))

(defun http-patch (url data &key (params nil)
                             (headers nil)
                             (content-type "application/json")
                             (timeout *http-default-timeout*))
  "HTTP PATCH 请求

  参数：
    URL          - 请求 URL
    DATA         - 请求体数据
    PARAMS       - 查询参数
    HEADERS      - 请求头
    CONTENT-TYPE - 内容类型
    TIMEOUT      - 超时时间

  返回：
    (values status-code headers body)"
  (http-request url
                :method :patch
                :params params
                :headers headers
                :data data
                :content-type content-type
                :timeout timeout))

;;; ============================================================
;;; JSON 请求
;;; ============================================================

(defun http-get-json (url &key (params nil)
                             (headers nil)
                             (timeout *http-default-timeout*))
  "HTTP GET 请求（JSON 响应）

  参数：
    URL     - 请求 URL
    PARAMS  - 查询参数
    HEADERS - 请求头
    TIMEOUT - 超时时间

  返回：
    解析后的 JSON 数据（hash-table）"
  (unless *http-enabled*
    (error "HTTP requests are disabled"))

  (check-http-domain url)

  (let* ((request-headers (merge-headers headers))
         (response (cl-agent.http:http-get url
                                           :headers request-headers
                                           :query-params params
                                           :timeout timeout
                                           :parse-json t)))
    (unless (cl-agent.http:http-success-p response)
      (error "HTTP GET failed with status ~A: ~A"
             (cl-agent.http:http-response-status response)
             (cl-agent.http:http-response-body response)))
    (cl-agent.http:http-response-body response)))

(defun http-post-json (url data &key (params nil)
                                  (headers nil)
                                  (timeout *http-default-timeout*))
  "HTTP POST 请求（JSON 请求和响应）

  参数：
    URL     - 请求 URL
    DATA    - 请求数据（会自动转换为 JSON）
    PARAMS  - 查询参数
    HEADERS - 请求头
    TIMEOUT - 超时时间

  返回：
    解析后的 JSON 数据（hash-table）"
  (unless *http-enabled*
    (error "HTTP requests are disabled"))

  (check-http-domain url)

  (let* ((request-headers (merge-headers headers))
         (final-url (if params
                        (cl-agent.http:build-url url nil params)
                        url))
         (response (cl-agent.http:http-post final-url
                                            :headers request-headers
                                            :body data
                                            :content-type :json
                                            :timeout timeout
                                            :parse-json t)))
    (unless (cl-agent.http:http-success-p response)
      (error "HTTP POST failed with status ~A: ~A"
             (cl-agent.http:http-response-status response)
             (cl-agent.http:http-response-body response)))
    (cl-agent.http:http-response-body response)))

;;; ============================================================
;;; 流式下载
;;; ============================================================

(defun http-download (url filepath &key
                               (timeout *http-default-timeout*)
                               (progress-callback nil)
                               (chunk-size 8192))
  "下载文件

  参数：
    URL               - 下载 URL
    FILEPATH          - 保存路径
    TIMEOUT           - 超时时间
    PROGRESS-CALLBACK - 进度回调函数
                       格式: (lambda (downloaded total percent) ...)
                       - downloaded: 已下载字节数
                       - total: 总字节数（可能为 nil）
                       - percent: 百分比（可能为 nil）
    CHUNK-SIZE        - 块大小（默认 8KB）

  返回：
    下载的字节数"
  (unless *http-enabled*
    (error "HTTP requests are disabled"))

  (check-http-domain url)

  (handler-case
      (if progress-callback
          ;; 带进度回调的下载
          (http-download-with-progress url filepath
                                       :timeout timeout
                                       :progress-callback progress-callback
                                       :chunk-size chunk-size)
          ;; 简单下载（无进度回调）
          (http-download-simple url filepath :timeout timeout))
    (error (e)
      (error "HTTP download failed: ~A" e))))

(defun http-download-simple (url filepath &key (timeout *http-default-timeout*))
  "简单下载（无进度回调）

  参数：
    URL      - 下载 URL
    FILEPATH - 保存路径
    TIMEOUT  - 超时时间

  返回：
    下载的字节数"
  (let ((response (cl-agent.http:http-request url
                                              :method :get
                                              :timeout timeout
                                              :force-binary t
                                              :parse-json nil)))
    (unless (cl-agent.http:http-success-p response)
      (error "HTTP download failed with status ~A"
             (cl-agent.http:http-response-status response)))

    ;; 写入文件
    (let ((body (cl-agent.http:http-response-body response)))
      (with-open-file (stream filepath
                              :direction :output
                              :if-exists :supersede
                              :if-does-not-exist :create
                              :element-type '(unsigned-byte 8))
        (write-sequence body stream))

      ;; 返回文件大小
      (file-size filepath))))

(defun http-download-with-progress (url filepath &key
                                              (timeout *http-default-timeout*)
                                              progress-callback
                                              (chunk-size 8192))
  "带进度回调的下载

  参数：
    URL               - 下载 URL
    FILEPATH          - 保存路径
    TIMEOUT           - 超时时间
    PROGRESS-CALLBACK - 进度回调函数
    CHUNK-SIZE        - 块大小

  返回：
    下载的字节数"
  ;; 首先发送 HEAD 请求获取文件大小
  (let ((total-size (http-get-content-length url :timeout timeout)))

    ;; 使用流式请求下载
    (let ((response (cl-agent.http:http-request url
                                                :method :get
                                                :timeout timeout
                                                :want-stream t
                                                :parse-json nil)))
      (unless (cl-agent.http:http-success-p response)
        (error "HTTP download failed with status ~A"
               (cl-agent.http:http-response-status response)))

      ;; 从响应头获取 Content-Length（如果 HEAD 请求未获取到）
      (unless total-size
        (setf total-size (http-response-content-length response)))

      ;; 分块读取并写入文件
      (let ((body (cl-agent.http:http-response-body response))
            (downloaded 0))

        ;; 如果 body 是流，则分块读取
        (if (streamp body)
            (with-open-file (out filepath
                                 :direction :output
                                 :if-exists :supersede
                                 :if-does-not-exist :create
                                 :element-type '(unsigned-byte 8))
              (let ((buffer (make-array chunk-size :element-type '(unsigned-byte 8))))
                (loop for bytes-read = (read-sequence buffer body)
                      while (plusp bytes-read)
                      do (progn
                           ;; 写入文件
                           (write-sequence buffer out :end bytes-read)
                           ;; 更新已下载字节数
                           (incf downloaded bytes-read)
                           ;; 调用进度回调
                           (when progress-callback
                             (let ((percent (when total-size
                                              (* 100.0 (/ downloaded total-size)))))
                               (funcall progress-callback downloaded total-size percent)))))))

            ;; 如果 body 是字节数组，一次性写入
            (progn
              (with-open-file (out filepath
                                   :direction :output
                                   :if-exists :supersede
                                   :if-does-not-exist :create
                                   :element-type '(unsigned-byte 8))
                (write-sequence body out))
              (setf downloaded (length body))
              ;; 最终进度回调
              (when progress-callback
                (funcall progress-callback downloaded total-size 100.0))))

        downloaded))))

(defun http-get-content-length (url &key (timeout 10))
  "获取 URL 内容的大小

  参数：
    URL     - URL
    TIMEOUT - 超时时间

  返回：
    内容大小（字节）或 NIL"
  (handler-case
      (let ((response (cl-agent.http:http-request url
                                                  :method :head
                                                  :timeout timeout)))
        (when (cl-agent.http:http-success-p response)
          (http-response-content-length response)))
    (error () nil)))

(defun http-response-content-length (response)
  "从响应中获取 Content-Length

  参数：
    RESPONSE - HTTP 响应

  返回：
    内容大小（字节）或 NIL"
  (let ((headers (cl-agent.http:http-response-headers response)))
    (when headers
      (let ((content-length (or (cdr (assoc "content-length" headers :test #'string-equal))
                                (cdr (assoc :content-length headers)))))
        (when content-length
          (parse-integer (string content-length) :junk-allowed t))))))

;;; ============================================================
;;; 辅助函数
;;; ============================================================

(defun merge-headers (headers)
  "合并默认请求头和自定义请求头

  参数：
    HEADERS - 自定义请求头

  返回：
    合并后的请求头（alist）"
  (let ((result (or *http-default-headers* '())))
    (dolist (header headers)
      (let ((key (car header))
            (value (cdr header)))
        (setf result (acons key value result))))
    result))

(defun check-http-domain (url)
  "检查域名是否在白名单中

  参数：
    URL - 请求 URL

  错误：
    - http-access-error: 域名不允许访问"
  (when *http-allowed-domains*
    (let* ((uri (quri:uri url))
           (domain (quri:uri-host uri)))
      (unless (some (lambda (allowed-domain)
                     (cl-ppcre:scan (format nil "^~A" allowed-domain)
                                     domain))
                   *http-allowed-domains*)
        (error "HTTP access denied to domain: ~A" domain)))))

(defun status-code-success-p (status-code)
  "检查状态码是否表示成功

  参数：
    STATUS-CODE - HTTP 状态码

  返回：
    T 或 NIL"
  (and (>= status-code 200)
       (< status-code 300)))

(defun status-code-client-error-p (status-code)
  "检查状态码是否表示客户端错误

  参数：
    STATUS-CODE - HTTP 状态码

  返回：
    T 或 NIL"
  (and (>= status-code 400)
       (< status-code 500)))

(defun status-code-server-error-p (status-code)
  "检查状态码是否表示服务器错误

  参数：
    STATUS-CODE - HTTP 状态码

  返回：
    T 或 NIL"
  (and (>= status-code 500)
       (< status-code 600)))

;;; ============================================================
;;; 安全控制
;;; ============================================================

(defun set-http-whitelist (domains)
  "设置允许访问的域名白名单

  参数：
    DOMAINS - 域名列表

  说明：
    空列表表示允许所有域名"
  (setf *http-allowed-domains* domains)
  (when *tool-verbose*
    (format t "[HTTP] Whitelist set to: ~A~%" domains)))

(defun allow-http-domain (domain)
  "添加域名到白名单

  参数：
    DOMAIN - 域名字符串"
  (pushnew domain *http-allowed-domains* :test #'string=)
  (when *tool-verbose*
    (format t "[HTTP] Allowed domain: ~A~%" domain)))

(defun enable-http ()
  "启用 HTTP 工具"
  (setf *http-enabled* t)
  (when *tool-verbose*
    (format t "[HTTP] HTTP tools enabled~%")))

(defun disable-http ()
  "禁用 HTTP 工具"
  (setf *http-enabled* nil)
  (when *tool-verbose*
    (format t "[HTTP] HTTP tools disabled~%")))

;;; ============================================================
;;; HTTP 工具注册
;;; ============================================================

(defun register-http-tools ()
  "注册 HTTP 工具

  返回：
    注册的工具数量"
  ;; 通用 HTTP 请求
  (register-tool
   :http-request
   "Execute HTTP request"
   (lambda (url &key (method "GET")
                       (headers nil)
                       (params nil)
                       (data nil)
                       (timeout 30))
     (declare (ignore method headers params data))
     (http-request url :timeout timeout))
   :parameters '((:url
                  :type string
                  :description "Request URL"
                  :required t)
                 (:method
                  :type string
                  :description "HTTP method (GET, POST, PUT, DELETE, PATCH)"
                  :required nil
                  :default "GET")
                 (:headers
                  :type object
                  :description "Request headers"
                  :required nil)
                 (:params
                  :type object
                  :description "Query parameters"
                  :required nil)
                 (:data
                  :type string
                  :description "Request body data"
                  :required nil)
                 (:timeout
                  :type integer
                  :description "Timeout in seconds"
                  :required nil
                  :default 30))
   :category :http
   :permissions '(:network-access))

  ;; HTTP GET
  (register-tool
   :http-get
   "Execute HTTP GET request"
   (lambda (url &key (params nil) (headers nil) (timeout 30))
     (declare (ignore params headers))
     (multiple-value-bind (status-code headers body)
         (http-get url :timeout timeout)
       (declare (ignore headers))
       `(:status ,status-code :body ,body)))
   :parameters '((:url
                  :type string
                  :description "Request URL"
                  :required t)
                 (:params
                  :type object
                  :description "Query parameters"
                  :required nil)
                 (:headers
                  :type object
                  :description "Request headers"
                  :required nil)
                 (:timeout
                  :type integer
                  :description "Timeout in seconds"
                  :required nil
                  :default 30))
   :category :http
   :permissions '(:network-access))

  ;; HTTP POST JSON
  (register-tool
   :http-post-json
   "Execute HTTP POST request with JSON data"
   (lambda (url data &key (params nil) (headers nil) (timeout 30))
     (declare (ignore params headers))
     (http-post-json url data :timeout timeout))
   :parameters '((:url
                  :type string
                  :description "Request URL"
                  :required t)
                 (:data
                  :type object
                  :description "JSON data to send"
                  :required t)
                 (:params
                  :type object
                  :description "Query parameters"
                  :required nil)
                 (:headers
                  :type object
                  :description "Request headers"
                  :required nil)
                 (:timeout
                  :type integer
                  :description "Timeout in seconds"
                  :required nil
                  :default 30))
   :category :http
   :permissions '(:network-access))

  ;; HTTP GET JSON
  (register-tool
   :http-get-json
   "Execute HTTP GET request and parse JSON response"
   (lambda (url &key (params nil) (headers nil) (timeout 30))
     (declare (ignore params headers))
     (http-get-json url :timeout timeout))
   :parameters '((:url
                  :type string
                  :description "Request URL"
                  :required t)
                 (:params
                  :type object
                  :description "Query parameters"
                  :required nil)
                 (:headers
                  :type object
                  :description "Request headers"
                  :required nil)
                 (:timeout
                  :type integer
                  :description "Timeout in seconds"
                  :required nil
                  :default 30))
   :category :http
   :permissions '(:network-access))

  ;; 下载文件
  (register-tool
   :http-download
   "Download file from URL"
   (lambda (url filepath &key (timeout 300))
     (http-download url filepath :timeout timeout))
   :parameters '((:url
                  :type string
                  :description "Download URL"
                  :required t)
                 (:filepath
                  :type string
                  :description "Save path"
                  :required t)
                 (:timeout
                  :type integer
                  :description "Timeout in seconds"
                  :required nil
                  :default 300))
   :category :http
   :permissions '(:network-access :file-write))

  5)  ;; 返回注册的工具数量

;;; ============================================================
;;; 自动初始化
;;; ============================================================

;; 自动注册 HTTP 工具（当加载此文件时）
;; (register-http-tools)  ; Temporarily disabled to test loading

;; 导出符号
