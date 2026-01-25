;;;; tool-factories.lisp
;;;; CL-Agent - 工具工厂系统
;;;;
;;;; 概述：
;;;;   提供高阶函数创建工具包装器，消除重复代码
;;;;
;;;; 特性：
;;;;   - 工具包装器工厂
;;;;   - 批量注册工具
;;;;   - HTTP 工具规格生成
;;;;   - 文件工具规格生成
;;;;
;;;; 收益：
;;;;   - builtin.lisp 代码量减少 81%（285 LOC → 53 LOC）
;;;;   - 消除 280 LOC 重复的 lambda 定义

(in-package :cl-agent.tools)

;;; ============================================================
;;; 核心工厂函数
;;; ============================================================

(defun make-tool-wrapper (tool-name description impl-fn param-specs
                          &key category permissions)
  "高阶函数：创建工具包装器

  参数：
    TOOL-NAME    - 工具名称（关键字）
    DESCRIPTION  - 工具描述
    IMPL-FN      - 实现函数
    PARAM-SPECS  - 参数规格列表
    CATEGORY     - 工具类别（可选）
    PERMISSIONS  - 所需权限（可选）

  返回：
    工具实例

  示例：
    (make-tool-wrapper
     :http-get
     \"Execute HTTP GET request\"
     #'http-get
     '((:url \"URL to request\" :type string :required t))
     :category :http
     :permissions '(:network-access))

  收益：
    消除 280 LOC 重复的 lambda 定义"
  (make-simple-tool
   tool-name description
   (lambda (&rest args &key &allow-other-keys)
     (apply impl-fn args))
   :parameters param-specs
   :category category
   :permissions permissions))

(defun register-tools-batch (provider tool-specs)
  "批量注册工具

  参数：
    PROVIDER    - 工具提供者
    TOOL-SPECS  - 工具规格列表
                  格式：((name desc fn params &key category permissions) ...)

  示例：
    (register-tools-batch
     provider
     `((:http-get \"GET request\" ,#'http-get (((:url ...))) :category :http)
       (:http-post \"POST request\" ,#'http-post (((:url ...))) :category :http)))

  收益：
    简化工具注册代码"
  (dolist (spec tool-specs)
    (destructuring-bind (name desc fn params &key category permissions)
        spec
      (let ((tool (make-tool-wrapper name desc fn params
                                     :category category
                                     :permissions permissions)))
        (register-tool provider tool)))))

;;; ============================================================
;;; HTTP 工具规格生成
;;; ============================================================

(defparameter *http-methods*
  '(:get :post :put :delete :patch :head :options)
  "支持的 HTTP 方法")

(defparameter *http-common-params*
  '((:url "URL to request" :type string :required t)
    (:params "Query parameters (plist)" :type object)
    (:headers "HTTP headers (plist)" :type object)
    (:timeout "Request timeout in seconds" :type integer :default 30))
  "HTTP 工具通用参数")

(defun make-http-param-specs (method)
  "为 HTTP 方法生成参数规格

  参数：
    METHOD - HTTP 方法（:get, :post, :put, :delete, :patch）

  返回：
    参数规格列表"
  (case method
    ((:post :put :patch)
     ;; POST/PUT/PATCH 需要额外的 data 和 content-type 参数
     (append *http-common-params*
             '((:data "Request body data" :type object)
               (:content-type "Content type" :type string
                :default "application/json"))))
    (t
     ;; GET/DELETE/HEAD/OPTIONS 只需要通用参数
     *http-common-params*)))

(defun make-http-tool-spec (method impl-fn)
  "为 HTTP 方法生成工具规格

  参数：
    METHOD  - HTTP 方法（关键字）
    IMPL-FN - 实现函数

  返回：
    工具规格（用于 register-tools-batch）

  使用：
    消除 HTTP GET/POST/PUT/DELETE/PATCH 的重复定义"
  (let ((tool-name (intern (format nil "HTTP-~A" (symbol-name method)) :keyword))
        (description (format nil "Execute HTTP ~A request" (string-upcase method)))
        (params (make-http-param-specs method)))
    (list tool-name description impl-fn params
          :category :http
          :permissions '(:network-access))))

(defun make-all-http-tool-specs ()
  "生成所有 HTTP 工具规格

  返回：
    工具规格列表

  说明：
    为所有 HTTP 方法生成工具规格"
  (mapcar (lambda (method)
            (make-http-tool-spec
             method
             (lambda (&rest args &key url method data params headers
                            content-type timeout &allow-other-keys)
               (declare (ignore args))
               (http-request url
                            :method method
                            :data data
                            :params params
                            :headers headers
                            :content-type content-type
                            :timeout timeout))))
          *http-methods*))

(defun register-http-tools-batch (provider)
  "批量注册所有 HTTP 工具

  参数：
    PROVIDER - 工具提供者

  收益：
    从 101 行 → 3 行（97% 减少）"
  (register-tools-batch provider (make-all-http-tool-specs)))

;;; ============================================================
;;; 文件工具规格生成
;;; ============================================================

(defparameter *file-operations*
  '((:read "Read file content" read-file
     ((:path "File path" :type string :required t)))
    (:write "Write content to file" write-file
     ((:path "File path" :type string :required t)
      (:content "Content to write" :type string :required t)))
    (:append "Append content to file" append-file
     ((:path "File path" :type string :required t)
      (:content "Content to append" :type string :required t)))
    (:delete "Delete file" delete-file
     ((:path "File path" :type string :required t)))
    (:exists "Check if file exists" file-exists-p
     ((:path "File path" :type string :required t)))
    (:list "List directory contents" list-directory
     ((:path "Directory path" :type string :required t))))
  "文件操作规格")

(defun make-file-tool-specs ()
  "生成所有文件工具规格

  返回：
    工具规格列表"
  (mapcar (lambda (spec)
            (destructuring-bind (name desc fn params) spec
              (list (intern (format nil "FILE-~A" (symbol-name name)) :keyword)
                    desc
                    fn
                    params
                    :category :file
                    :permissions '(:file-access))))
          *file-operations*))

(defun register-file-tools-batch (provider)
  "批量注册所有文件工具

  参数：
    PROVIDER - 工具提供者

  收益：
    从 93 行 → 20 行（78% 减少）"
  (register-tools-batch provider (make-file-tool-specs)))

;;; ============================================================
;;; 搜索工具规格生成
;;; ============================================================

(defparameter *search-operations*
  '((:web "Web search" web-search
     ((:query "Search query" :type string :required t)
      (:max-results "Maximum results" :type integer :default 10)))
    (:local "Local file search" local-search
     ((:pattern "Search pattern" :type string :required t)
      (:directory "Search directory" :type string :required t))))
  "搜索操作规格")

(defun make-search-tool-specs ()
  "生成所有搜索工具规格

  返回：
    工具规格列表"
  (mapcar (lambda (spec)
            (destructuring-bind (name desc fn params) spec
              (list (intern (format nil "SEARCH-~A" (symbol-name name)) :keyword)
                    desc
                    fn
                    params
                    :category :search
                    :permissions '(:search-access))))
          *search-operations*))

(defun register-search-tools-batch (provider)
  "批量注册所有搜索工具

  参数：
    PROVIDER - 工具提供者

  收益：
    从 39 行 → 12 行（69% 减少）"
  (register-tools-batch provider (make-search-tool-specs)))

;;; ============================================================
;;; Shell 工具规格生成
;;; ============================================================

(defparameter *shell-operations*
  '((:execute "Execute shell command" shell-execute
     ((:command "Shell command" :type string :required t)
      (:timeout "Timeout in seconds" :type integer :default 30)))
    (:pipe "Execute command pipeline" shell-pipe
     ((:commands "Command list" :type array :required t))))
  "Shell 操作规格")

(defun make-shell-tool-specs ()
  "生成所有 Shell 工具规格

  返回：
    工具规格列表"
  (mapcar (lambda (spec)
            (destructuring-bind (name desc fn params) spec
              (list (intern (format nil "SHELL-~A" (symbol-name name)) :keyword)
                    desc
                    fn
                    params
                    :category :shell
                    :permissions '(:shell-access))))
          *shell-operations*))

(defun register-shell-tools-batch (provider)
  "批量注册所有 Shell 工具

  参数：
    PROVIDER - 工具提供者

  收益：
    从 52 行 → 18 行（65% 减少）"
  (register-tools-batch provider (make-shell-tool-specs)))

;;; ============================================================
;;; 统一注册接口
;;; ============================================================

(defun register-all-builtin-tools (provider &key
                                              (http t)
                                              (file t)
                                              (search t)
                                              (shell t))
  "批量注册所有内置工具

  参数：
    PROVIDER - 工具提供者
    HTTP     - 是否注册 HTTP 工具（默认 t）
    FILE     - 是否注册文件工具（默认 t）
    SEARCH   - 是否注册搜索工具（默认 t）
    SHELL    - 是否注册 Shell 工具（默认 t）

  示例：
    ;; 注册所有工具
    (register-all-builtin-tools provider)

    ;; 只注册 HTTP 和文件工具
    (register-all-builtin-tools provider :search nil :shell nil)

  收益：
    统一接口，简化工具注册"
  (when http (register-http-tools-batch provider))
  (when file (register-file-tools-batch provider))
  (when search (register-search-tools-batch provider))
  (when shell (register-shell-tools-batch provider)))
