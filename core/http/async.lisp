;;;; async.lisp
;;;; CL-Agent HTTP - 异步 HTTP 支持
;;;;
;;;; 概述：
;;;;   基于 lparallel 的异步 HTTP 请求支持
;;;;
;;;; 特性：
;;;;   - Future 模式的异步请求
;;;;   - 批量并行请求
;;;;   - 线程池管理
;;;;
;;;; 使用示例：
;;;;   ;; 单个异步请求
;;;;   (let ((future (http-get-async "https://api.example.com/data")))
;;;;     ;; 做其他事情...
;;;;     (http-future-value future))  ; 获取结果
;;;;
;;;;   ;; 并行多个请求
;;;;   (http-parallel
;;;;     (list (make-request :url "https://api1.example.com")
;;;;           (make-request :url "https://api2.example.com")))

(in-package #:cl-agent.http)

;;; ============================================================
;;; 线程池管理
;;; ============================================================

(defvar *http-thread-pool* nil
  "HTTP 异步请求使用的线程池

使用 initialize-http-thread-pool 初始化")

(defvar *http-thread-pool-size* 4
  "默认线程池大小")

(defun initialize-http-thread-pool (&key (size *http-thread-pool-size*))
  "初始化 HTTP 线程池

参数：
  SIZE - 线程池大小（默认 4）

返回：
  线程池对象

说明：
  调用此函数前，异步 HTTP 函数将使用 lparallel 的默认内核。
  建议在应用启动时调用一次。

示例：
  (initialize-http-thread-pool :size 8)"
  (when *http-thread-pool*
    (shutdown-http-thread-pool))
  (setf *http-thread-pool*
        (lparallel:make-kernel size :name "http-pool"))
  *http-thread-pool*)

(defun shutdown-http-thread-pool ()
  "关闭 HTTP 线程池

说明：
  应在应用退出前调用以清理资源"
  (when *http-thread-pool*
    (setf *http-thread-pool* nil)
    (lparallel:end-kernel :wait t)))

(defmacro with-http-kernel (&body body)
  "在 HTTP 线程池上下文中执行代码

如果 *http-thread-pool* 存在，使用它；
否则使用 lparallel:*kernel*（需要已初始化）"
  `(let ((lparallel:*kernel* (or *http-thread-pool* lparallel:*kernel*)))
     (unless lparallel:*kernel*
       (error "HTTP 线程池未初始化。请调用 (initialize-http-thread-pool) 或 (setf lparallel:*kernel* (lparallel:make-kernel N))"))
     ,@body))

;;; ============================================================
;;; HTTP Future
;;; ============================================================

(defstruct (http-future (:constructor %make-http-future))
  "HTTP 异步请求的 Future

槽位说明：
  LPARALLEL-FUTURE - 底层 lparallel future
  URL              - 请求 URL（用于调试）
  METHOD           - 请求方法"
  (lparallel-future nil)
  (url nil :type (or null string))
  (method :get :type keyword))

;; 注：http-future-p 由 defstruct 自动生成

(defun http-future-done-p (future)
  "检查 future 是否已完成

参数：
  FUTURE - http-future 对象

返回：
  t 或 nil"
  (lparallel:fulfilledp (http-future-lparallel-future future)))

(defun http-future-value (future &key (timeout nil) (default nil))
  "获取 future 的值

参数：
  FUTURE  - http-future 对象
  TIMEOUT - 超时时间（秒，nil 表示无限等待）
  DEFAULT - 超时时返回的默认值

返回：
  http-response 或 DEFAULT（超时时）

说明：
  如果 future 执行过程中发生错误，此函数会重新抛出该错误

示例：
  (let ((future (http-get-async url)))
    (http-future-value future :timeout 10))"
  (let ((lp-future (http-future-lparallel-future future)))
    (if timeout
        (handler-case
            (bt:with-timeout (timeout)
              (lparallel:force lp-future))
          (bt:timeout ()
            default))
        (lparallel:force lp-future))))

(defun http-future-wait (future &key (timeout nil))
  "等待 future 完成但不获取值

参数：
  FUTURE  - http-future 对象
  TIMEOUT - 超时时间（秒）

返回：
  t（完成）或 nil（超时）"
  (let ((lp-future (http-future-lparallel-future future)))
    (if timeout
        (handler-case
            (progn
              (bt:with-timeout (timeout)
                (lparallel:force lp-future))
              t)
          (bt:timeout ()
            nil))
        (progn
          (lparallel:force lp-future)
          t))))

(defun http-future-cancel (future)
  "取消 future（尽力而为）

参数：
  FUTURE - http-future 对象

返回：
  t

说明：
  由于 HTTP 请求的性质，取消可能不会立即生效。
  已发送的请求无法真正取消，但可以忽略其结果。"
  ;; lparallel 的 future 不支持真正的取消
  ;; 这里只是标记（未来可以扩展）
  (declare (ignore future))
  t)

;;; ============================================================
;;; 异步请求函数
;;; ============================================================

(defun http-request-async (url &key
                                 (method :get)
                                 headers
                                 body
                                 (content-type nil)
                                 (timeout *default-timeout*)
                                 (parse-json t))
  "异步发送 HTTP 请求

参数：
  URL          - 请求 URL
  METHOD       - HTTP 方法
  HEADERS      - 请求头
  BODY         - 请求体
  CONTENT-TYPE - 内容类型
  TIMEOUT      - 超时时间
  PARSE-JSON   - 是否自动解析 JSON

返回：
  http-future 对象

示例：
  (let ((future (http-request-async \"https://api.example.com/data\"
                                    :method :post
                                    :body '{\"key\": \"value\"}
                                    :content-type :json)))
    ;; 做其他事情...
    (http-future-value future))"
  (with-http-kernel
    (%make-http-future
     :lparallel-future (lparallel:future
                         (http-request url
                                       :method method
                                       :headers headers
                                       :body body
                                       :content-type content-type
                                       :timeout timeout
                                       :parse-json parse-json))
     :url url
     :method method)))

(defun http-get-async (url &key headers (timeout *default-timeout*) query-params (parse-json t))
  "异步发送 GET 请求

参数：
  URL          - 请求 URL
  HEADERS      - 请求头
  TIMEOUT      - 超时时间
  QUERY-PARAMS - 查询参数
  PARSE-JSON   - 是否自动解析 JSON

返回：
  http-future 对象

示例：
  (http-get-async \"https://api.example.com/users\")"
  (let ((final-url (if query-params
                       (build-url url nil query-params)
                       url)))
    (http-request-async final-url
                        :method :get
                        :headers headers
                        :timeout timeout
                        :parse-json parse-json)))

(defun http-post-async (url &key headers body (content-type :json) (timeout *default-timeout*) (parse-json t))
  "异步发送 POST 请求

参数：
  URL          - 请求 URL
  HEADERS      - 请求头
  BODY         - 请求体
  CONTENT-TYPE - 内容类型
  TIMEOUT      - 超时时间
  PARSE-JSON   - 是否自动解析 JSON

返回：
  http-future 对象

示例：
  (http-post-async \"https://api.example.com/users\"
                   :body '((\"name\" . \"Alice\")))"
  (http-request-async url
                      :method :post
                      :headers headers
                      :body body
                      :content-type content-type
                      :timeout timeout
                      :parse-json parse-json))

;;; ============================================================
;;; 并行请求
;;; ============================================================

(defstruct http-request-spec
  "HTTP 请求规格

槽位说明：
  URL          - 请求 URL
  METHOD       - HTTP 方法
  HEADERS      - 请求头
  BODY         - 请求体
  CONTENT-TYPE - 内容类型
  TIMEOUT      - 超时时间
  TAG          - 用户标签（用于识别结果）"
  (url nil :type string)
  (method :get :type keyword)
  (headers nil :type list)
  (body nil)
  (content-type nil)
  (timeout *default-timeout* :type number)
  (tag nil))

(defun http-parallel (requests &key (fail-fast nil))
  "并行执行多个 HTTP 请求

参数：
  REQUESTS  - http-request-spec 列表或 URL 字符串列表
  FAIL-FAST - 是否在首个错误时停止

返回：
  结果列表，每个元素为：
  - 成功：(:ok RESPONSE :tag TAG)
  - 失败：(:error CONDITION :tag TAG)

示例：
  (http-parallel
    (list (make-http-request-spec :url \"https://api1.example.com\" :tag :api1)
          (make-http-request-spec :url \"https://api2.example.com\" :tag :api2)))

  ;; 简化形式（仅 URL）
  (http-parallel '(\"https://api1.example.com\"
                   \"https://api2.example.com\"))"
  (with-http-kernel
    (let* ((specs (mapcar (lambda (req)
                            (if (stringp req)
                                (make-http-request-spec :url req)
                                req))
                          requests))
           (futures (mapcar (lambda (spec)
                              (cons spec
                                    (lparallel:future
                                      (handler-case
                                          (list :ok
                                                (http-request
                                                 (http-request-spec-url spec)
                                                 :method (http-request-spec-method spec)
                                                 :headers (http-request-spec-headers spec)
                                                 :body (http-request-spec-body spec)
                                                 :content-type (http-request-spec-content-type spec)
                                                 :timeout (http-request-spec-timeout spec)))
                                        (error (e)
                                          (list :error e))))))
                            specs)))
      ;; 收集结果
      (loop for (spec . future) in futures
            for result = (lparallel:force future)
            when (and fail-fast (eq (first result) :error))
            do (return (list (append result (list :tag (http-request-spec-tag spec)))))
            collect (append result (list :tag (http-request-spec-tag spec)))))))

(defun http-parallel-map (urls fn &key headers (timeout *default-timeout*))
  "并行请求多个 URL 并对结果应用函数

参数：
  URLS    - URL 列表
  FN      - 应用于每个响应的函数
  HEADERS - 公共请求头
  TIMEOUT - 超时时间

返回：
  FN 的返回值列表

示例：
  (http-parallel-map
    '(\"https://api.example.com/user/1\"
      \"https://api.example.com/user/2\")
    (lambda (response)
      (getf (http-response-body response) :name)))"
  (let ((results (http-parallel
                  (mapcar (lambda (url)
                            (make-http-request-spec
                             :url url
                             :headers headers
                             :timeout timeout))
                          urls))))
    (mapcar (lambda (result)
              (if (eq (first result) :ok)
                  (funcall fn (second result))
                  (second result)))  ; 返回错误条件
            results)))
