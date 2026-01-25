;;;; builtin.lisp
;;;; CL-Agent - Builtin Tool Provider
;;;;
;;;; 概述：
;;;;   提供内置工具集合（HTTP、文件、搜索、Shell）
;;;;
;;;; 特性：
;;;;   - 整合现有工具实现
;;;;   - 统一配置管理
;;;;   - 安全性控制
;;;;   - 工具自动注册

(in-package #:cl-agent.tools)

;;; ============================================================
;;; Builtin Tool Provider 类
;;; ============================================================

(defclass builtin-tool-provider (tool-provider)
  ((http-enabled
    :initarg :http-enabled
    :accessor builtin-http-enabled-p
    :initform t
    :type boolean
    :documentation "是否启用 HTTP 工具")

   (file-enabled
    :initarg :file-enabled
    :accessor builtin-file-enabled-p
    :initform t
    :type boolean
    :documentation "是否启用文件工具")

   (search-enabled
    :initarg :search-enabled
    :accessor builtin-search-enabled-p
    :initform t
    :type boolean
    :documentation "是否启用搜索工具")

   (shell-enabled
    :initarg :shell-enabled
    :accessor builtin-shell-enabled-p
    :initform nil
    :type boolean
    :documentation "是否启用 Shell 工具（默认禁用）")

   (http-config
    :initarg :http-config
    :accessor builtin-http-config
    :initform nil
    :documentation "HTTP 工具配置（plist）")

   (file-config
    :initarg :file-config
    :accessor builtin-file-config
    :initform nil
    :documentation "文件工具配置（plist）")

   (search-config
    :initarg :search-config
    :accessor builtin-search-config
    :initform nil
    :documentation "搜索工具配置（plist）")

   (shell-config
    :initarg :shell-config
    :accessor builtin-shell-config
    :initform nil
    :documentation "Shell 工具配置（plist）"))

  (:documentation "内置工具提供者，提供 HTTP、文件、搜索、Shell 等工具"))

;;; ============================================================
;;; 构造函数
;;; ============================================================

(defun make-builtin-provider (&key
                                (name "builtin")
                                (http-enabled t)
                                (file-enabled t)
                                (search-enabled t)
                                (shell-enabled nil)
                                http-config
                                file-config
                                search-config
                                shell-config)
  "创建内置工具提供者实例

  参数：
    NAME           - 提供者名称
    HTTP-ENABLED   - 是否启用 HTTP 工具（默认启用）
    FILE-ENABLED   - 是否启用文件工具（默认启用）
    SEARCH-ENABLED - 是否启用搜索工具（默认启用）
    SHELL-ENABLED  - 是否启用 Shell 工具（默认禁用，安全考虑）
    HTTP-CONFIG    - HTTP 配置（:timeout :allowed-domains :default-headers）
    FILE-CONFIG    - 文件配置（:allowed-paths :max-file-size）
    SEARCH-CONFIG  - 搜索配置（:engine :max-results）
    SHELL-CONFIG   - Shell 配置（:allowed-commands :timeout）

  返回：
    builtin-tool-provider 实例

  示例：
    (make-builtin-provider
      :http-config '(:timeout 60 :allowed-domains (\"api.example.com\"))
      :shell-enabled nil)"
  (make-instance 'builtin-tool-provider
                 :name name
                 :http-enabled http-enabled
                 :file-enabled file-enabled
                 :search-enabled search-enabled
                 :shell-enabled shell-enabled
                 :http-config http-config
                 :file-config file-config
                 :search-config search-config
                 :shell-config shell-config))

;;; ============================================================
;;; 配置辅助函数
;;; ============================================================

(defun make-config-bindings (config default-bindings)
  "从配置创建动态变量绑定列表

  参数：
    CONFIG           - 配置 plist
    DEFAULT-BINDINGS - 默认绑定列表 ((var default-value) ...)

  返回：
    绑定列表，用于 progv"
  (let ((vars '())
        (vals '()))
    (dolist (binding default-bindings)
      (destructuring-bind (var default-value &optional config-key) binding
        (push var vars)
        (push (or (and config config-key (getf config config-key))
                  default-value)
              vals)))
    (values (nreverse vars) (nreverse vals))))

;;; ============================================================
;;; HTTP 工具注册
;;; ============================================================

(defun register-http-tools (provider)
  "注册 HTTP 工具"
  (when (builtin-http-enabled-p provider)
    ;; 配置通过 execute-tool 的动态绑定应用

    ;; HTTP GET
    (register-tool provider
      (make-simple-tool
       :http-get
       "执行 HTTP GET 请求"
       (lambda (&key url params headers (timeout *http-default-timeout*))
         "执行 HTTP GET 请求并返回响应

         参数：
           URL     - 请求 URL（必需）
           PARAMS  - 查询参数（可选）
           HEADERS - 请求头（可选）
           TIMEOUT - 超时时间（可选）

         返回：
           HTTP 响应结构"
         (multiple-value-bind (status response-headers body)
             (http-get url :params params :headers headers :timeout timeout)
           (list :status status
                 :headers response-headers
                 :body body)))
       :parameters '((:url :type string :required t)
                     (:params :type list :required nil)
                     (:headers :type list :required nil)
                     (:timeout :type integer :required nil))
       :category :http
       :permissions '(:network-access)))

    ;; HTTP POST
    (register-tool provider
      (make-simple-tool
       :http-post
       "执行 HTTP POST 请求"
       (lambda (&key url data params headers content-type (timeout *http-default-timeout*))
         "执行 HTTP POST 请求并返回响应

         参数：
           URL          - 请求 URL（必需）
           DATA         - 请求体数据（必需）
           PARAMS       - 查询参数（可选）
           HEADERS      - 请求头（可选）
           CONTENT-TYPE - 内容类型（可选）
           TIMEOUT      - 超时时间（可选）

         返回：
           HTTP 响应结构"
         (multiple-value-bind (status response-headers body)
             (http-post url data
                        :params params
                        :headers headers
                        :content-type content-type
                        :timeout timeout)
           (list :status status
                 :headers response-headers
                 :body body)))
       :parameters '((:url :type string :required t)
                     (:data :type t :required t)
                     (:params :type list :required nil)
                     (:headers :type list :required nil)
                     (:content-type :type string :required nil)
                     (:timeout :type integer :required nil))
       :category :http
       :permissions '(:network-access)))

    ;; HTTP 通用请求
    (register-tool provider
      (make-simple-tool
       :http-request
       "执行通用 HTTP 请求（支持 GET、POST、PUT、DELETE 等）"
       (lambda (&key url (method :get) data params headers content-type (timeout *http-default-timeout*))
         "执行任意 HTTP 方法请求

         参数：
           URL          - 请求 URL（必需）
           METHOD       - HTTP 方法（默认 :get）
           DATA         - 请求体数据（可选）
           PARAMS       - 查询参数（可选）
           HEADERS      - 请求头（可选）
           CONTENT-TYPE - 内容类型（可选）
           TIMEOUT      - 超时时间（可选）

         返回：
           HTTP 响应结构"
         (multiple-value-bind (status response-headers body)
             (http-request url
                           :method method
                           :data data
                           :params params
                           :headers headers
                           :content-type content-type
                           :timeout timeout)
           (list :status status
                 :headers response-headers
                 :body body)))
       :parameters '((:url :type string :required t)
                     (:method :type keyword :required nil)
                     (:data :type t :required nil)
                     (:params :type list :required nil)
                     (:headers :type list :required nil)
                     (:content-type :type string :required nil)
                     (:timeout :type integer :required nil))
       :category :http
       :permissions '(:network-access)))))

;;; ============================================================
;;; 文件工具注册
;;; ============================================================

(defun register-file-tools (provider)
  "注册文件工具"
  (when (builtin-file-enabled-p provider)
    ;; 配置通过 execute-tool 的动态绑定应用

    ;; 文件读取
    (register-tool provider
      (make-simple-tool
       :file-read
       "读取文件内容"
       (lambda (&key filepath (encoding :utf-8) limit)
         "读取文件内容并返回字符串

         参数：
           FILEPATH - 文件路径（必需）
           ENCODING - 文件编码（默认 UTF-8）
           LIMIT    - 读取大小限制（可选）

         返回：
           文件内容字符串"
         (file-read filepath :encoding encoding :limit limit))
       :parameters '((:filepath :type string :required t)
                     (:encoding :type keyword :required nil)
                     (:limit :type integer :required nil))
       :category :file
       :permissions '(:file-read)))

    ;; 文件写入
    (register-tool provider
      (make-simple-tool
       :file-write
       "写入文件内容"
       (lambda (&key filepath content (encoding :utf-8) (if-exists :supersede))
         "写入内容到文件

         参数：
           FILEPATH  - 文件路径（必需）
           CONTENT   - 文件内容（必需）
           ENCODING  - 文件编码（默认 UTF-8）
           IF-EXISTS - 文件存在时的行为（默认覆盖）

         返回：
           文件路径"
         (file-write filepath content
                     :encoding encoding
                     :if-exists if-exists
                     :if-does-not-exist :create))
       :parameters '((:filepath :type string :required t)
                     (:content :type string :required t)
                     (:encoding :type keyword :required nil)
                     (:if-exists :type keyword :required nil))
       :category :file
       :permissions '(:file-write)))

    ;; 文件读取行
    (register-tool provider
      (make-simple-tool
       :file-read-lines
       "读取文件为行列表"
       (lambda (&key filepath (encoding :utf-8))
         "读取文件为行列表

         参数：
           FILEPATH - 文件路径（必需）
           ENCODING - 文件编码（默认 UTF-8）

         返回：
           行列表"
         (file-read-lines filepath :encoding encoding))
       :parameters '((:filepath :type string :required t)
                     (:encoding :type keyword :required nil))
       :category :file
       :permissions '(:file-read)))

    ;; 文件写入行
    (register-tool provider
      (make-simple-tool
       :file-write-lines
       "写入行列表到文件"
       (lambda (&key filepath lines (encoding :utf-8) (if-exists :supersede))
         "写入行列表到文件

         参数：
           FILEPATH  - 文件路径（必需）
           LINES     - 行列表（必需）
           ENCODING  - 文件编码（默认 UTF-8）
           IF-EXISTS - 文件存在时的行为（默认覆盖）

         返回：
           文件路径"
         (file-write-lines filepath lines
                           :encoding encoding
                           :if-exists if-exists
                           :if-does-not-exist :create))
       :parameters '((:filepath :type string :required t)
                     (:lines :type list :required t)
                     (:encoding :type keyword :required nil)
                     (:if-exists :type keyword :required nil))
       :category :file
       :permissions '(:file-write)))))

;;; ============================================================
;;; 搜索工具注册
;;; ============================================================

(defun register-search-tools (provider)
  "注册搜索工具"
  (when (builtin-search-enabled-p provider)
    ;; 配置通过 execute-tool 的动态绑定应用

    ;; Web 搜索
    (register-tool provider
      (make-simple-tool
       :web-search
       "执行 Web 搜索"
       (lambda (&key query (engine *default-search-engine*) (max-results *search-results-limit*))
         "执行 Web 搜索并返回结果

         参数：
           QUERY       - 搜索查询（必需）
           ENGINE      - 搜索引擎（可选，默认 DuckDuckGo）
           MAX-RESULTS - 最大结果数量（可选）

         返回：
           搜索结果列表"
         (web-search query :engine engine :max-results max-results))
       :parameters '((:query :type string :required t)
                     (:engine :type keyword :required nil)
                     (:max-results :type integer :required nil))
       :category :search
       :permissions '(:network-access)))

    ;; DuckDuckGo 搜索
    (register-tool provider
      (make-simple-tool
       :duckduckgo-search
       "使用 DuckDuckGo 搜索"
       (lambda (&key query (max-results *search-results-limit*))
         "使用 DuckDuckGo 搜索并返回结果

         参数：
           QUERY       - 搜索查询（必需）
           MAX-RESULTS - 最大结果数量（可选）

         返回：
           搜索结果列表"
         (duckduckgo-search query :max-results max-results))
       :parameters '((:query :type string :required t)
                     (:max-results :type integer :required nil))
       :category :search
       :permissions '(:network-access)))))

;;; ============================================================
;;; Shell 工具注册
;;; ============================================================

(defun register-shell-tools (provider)
  "注册 Shell 工具"
  (when (builtin-shell-enabled-p provider)
    ;; 配置通过 execute-tool 的动态绑定应用

    ;; Shell 命令执行
    (register-tool provider
      (make-simple-tool
       :shell-command
       "执行 Shell 命令"
       (lambda (&key command (timeout *shell-timeout*) directory environment)
         "执行 Shell 命令并返回结果

         参数：
           COMMAND     - 命令字符串（必需）
           TIMEOUT     - 超时时间（可选）
           DIRECTORY   - 工作目录（可选）
           ENVIRONMENT - 环境变量（可选）

         返回：
           执行结果（:exit-code :output :error）"
         (multiple-value-bind (exit-code output error-output)
             (shell-command command
                            :timeout timeout
                            :directory directory
                            :environment environment)
           (list :exit-code exit-code
                 :output output
                 :error error-output)))
       :parameters '((:command :type string :required t)
                     (:timeout :type integer :required nil)
                     (:directory :type string :required nil)
                     (:environment :type list :required nil))
       :category :shell
       :permissions '(:shell-access)))

    ;; Shell 安全执行
    (register-tool provider
      (make-simple-tool
       :shell-command-safe
       "安全执行 Shell 命令（捕获所有错误）"
       (lambda (&key command (timeout *shell-timeout*))
         "安全执行 Shell 命令并返回结果

         参数：
           COMMAND - 命令字符串（必需）
           TIMEOUT - 超时时间（可选）

         返回：
           执行结果（:success :output :error）"
         (multiple-value-bind (success-p output error)
             (shell-command-safe command :timeout timeout)
           (list :success success-p
                 :output output
                 :error error)))
       :parameters '((:command :type string :required t)
                     (:timeout :type integer :required nil))
       :category :shell
       :permissions '(:shell-access)))))

;;; ============================================================
;;; Provider 初始化
;;; ============================================================

(defmethod initialize-provider ((provider builtin-tool-provider))
  "初始化内置工具提供者，注册所有启用的工具"
  ;; 调用父类初始化
  (call-next-method)

  ;; 注册各类工具
  (register-http-tools provider)
  (register-file-tools provider)
  (register-search-tools provider)
  (register-shell-tools provider)

  ;; 返回提供者
  provider)

;;; ============================================================
;;; Provider 关闭
;;; ============================================================

(defmethod shutdown-provider ((provider builtin-tool-provider))
  "关闭内置工具提供者"
  ;; 禁用全局标志
  (when (builtin-http-enabled-p provider)
    (setf *http-enabled* nil))
  (when (builtin-file-enabled-p provider)
    (setf *file-enabled* nil))
  (when (builtin-shell-enabled-p provider)
    (setf *shell-enabled* nil))

  ;; 调用父类关闭
  (call-next-method))

;;; ============================================================
;;; 便利函数
;;; ============================================================

(defun make-default-builtin-provider (&key (shell-enabled nil))
  "创建默认配置的内置工具提供者

  参数：
    SHELL-ENABLED - 是否启用 Shell 工具（默认禁用）

  返回：
    已初始化的 builtin-tool-provider 实例

  示例：
    (defparameter *builtin* (make-default-builtin-provider))
    (defparameter *registry* (make-tool-registry))
    (add-provider *registry* *builtin*)"
  (let ((provider (make-builtin-provider :shell-enabled shell-enabled)))
    (initialize-provider provider)
    provider))

;;; ============================================================
;;; 工具执行（带动态配置绑定）
;;; ============================================================

(defmethod execute-tool ((provider builtin-tool-provider) tool-name &rest args)
  "执行工具，自动应用配置的动态绑定"
  ;; 检查提供者是否启用
  (unless (provider-enabled-p provider)
    (error "Provider ~A is disabled" (provider-name provider)))

  ;; 查找工具
  (let ((tool (find-tool provider tool-name)))
    (unless tool
      (error "Tool ~A not found in provider ~A"
             tool-name (provider-name provider)))

    ;; 准备动态变量绑定
    (let ((vars '())
          (vals '()))

      ;; HTTP 配置绑定
      (let ((http-conf (builtin-http-config provider)))
        (when (builtin-http-enabled-p provider)
          (push '*http-enabled* vars)
          (push t vals)
          (push '*http-default-timeout* vars)
          (push (or (getf http-conf :timeout) 30) vals)
          (push '*http-default-headers* vars)
          (push (getf http-conf :default-headers) vals)
          (push '*http-allowed-domains* vars)
          (push (or (getf http-conf :allowed-domains) '()) vals)))

      ;; 文件配置绑定
      (let ((file-conf (builtin-file-config provider)))
        (when (builtin-file-enabled-p provider)
          (push '*file-enabled* vars)
          (push t vals)
          (push '*file-allowed-paths* vars)
          (push (or (getf file-conf :allowed-paths) '()) vals)
          (push '*file-max-size* vars)
          (push (or (getf file-conf :max-file-size) 10485760) vals)))

      ;; 搜索配置绑定
      (let ((search-conf (builtin-search-config provider)))
        (when (builtin-search-enabled-p provider)
          (push '*default-search-engine* vars)
          (push (or (getf search-conf :engine) :duckduckgo) vals)
          (push '*search-results-limit* vars)
          (push (or (getf search-conf :max-results) 10) vals)))

      ;; Shell 配置绑定
      (let ((shell-conf (builtin-shell-config provider)))
        (when (builtin-shell-enabled-p provider)
          (push '*shell-enabled* vars)
          (push t vals)
          (push '*shell-allowed-commands* vars)
          (push (or (getf shell-conf :allowed-commands) '()) vals)
          (push '*shell-timeout* vars)
          (push (or (getf shell-conf :timeout) 30) vals)
          (push '*shell-max-output-size* vars)
          (push (or (getf shell-conf :max-output-size) 100000) vals)))

      ;; 使用动态绑定执行工具
      (progv (nreverse vars) (nreverse vals)
        (apply (tool-handler tool) args)))))

;;; ============================================================
;;; 导出符号
;;; ============================================================

;; 类和构造函数已通过 package.lisp 导出
;; 这里添加 builtin-specific 的导出

(export '(builtin-tool-provider
          make-builtin-provider
          make-default-builtin-provider
          builtin-http-enabled-p
          builtin-file-enabled-p
          builtin-search-enabled-p
          builtin-shell-enabled-p
          builtin-http-config
          builtin-file-config
          builtin-search-config
          builtin-shell-config))
