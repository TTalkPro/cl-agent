;;;; file.lisp
;;;; CL-Agent - 文件操作工具
;;;;
;;;; 概述：
;;;;   实现文件读写和操作功能
;;;;
;;;; 特性：
;;;;   - 文件读写
;;;;   - 目录遍历
;;;;   - 文件信息
;;;;   - 路径操作

(in-package :cl-agent.tools)

;;; ============================================================
;;; 动态配置变量（通过动态绑定传递）
;;; ============================================================

(defvar *file-allowed-paths* '()
  "允许访问的路径白名单（动态变量，通过 provider 绑定）")

(defvar *file-max-size* 10485760  ; 10MB
  "最大文件大小（动态变量，通过 provider 绑定）")

(defvar *file-enabled* t
  "是否启用文件工具（动态变量，通过 provider 绑定）")

;;; ============================================================
;;; 文件读取
;;; ============================================================

(defun file-read (filepath &key (encoding :utf-8) (limit nil))
  "读取文件内容

  参数：
    FILEPATH - 文件路径
    ENCODING - 文件编码
    LIMIT    - 读取大小限制（字节）

  返回：
    文件内容字符串

  说明：
    如果文件超过限制，只读取部分内容"
  (with-file-validation (filepath :check-size t :limit-var limit)
    (with-open-file (stream filepath
                            :direction :input
                            :element-type (flexi-streams:octet))
      (let ((contents (make-array (file-length stream)
                                  :element-type '(unsigned-byte 8))))
        (read-sequence contents stream)
        (flexi-streams:octets-to-string contents
                                         :encoding encoding)))))

(defun file-read-lines (filepath &key (encoding :utf-8))
  "读取文件为行列表

  参数：
    FILEPATH - 文件路径
    ENCODING - 文件编码

  返回：
    行列表"
  (with-file-operations
    (check-file-path filepath)
    (with-open-file (stream filepath
                            :direction :input
                            :external-format encoding)
      (loop for line = (read-line stream nil nil)
            while line
            collect line))))

(defun file-read-binary (filepath &key (limit nil))
  "读取二进制文件

  参数：
    FILEPATH - 文件路径
    LIMIT    - 读取大小限制

  返回：
    字节数组"
  (with-file-validation (filepath :check-size t :limit-var limit)
    (with-open-file (stream filepath
                            :direction :input
                            :element-type '(unsigned-byte 8))
      (let ((contents (make-array (file-length stream)
                                  :element-type '(unsigned-byte 8))))
        (read-sequence contents stream)
        contents))))

;;; ============================================================
;;; 文件写入
;;; ============================================================

(defun file-write (filepath content &key
                                  (encoding :utf-8)
                                  (if-exists :supersede)
                                  (if-does-not-exist :create))
  "写入文件

  参数：
    FILEPATH - 文件路径
    CONTENT  - 内容字符串
    ENCODING - 文件编码
    IF-EXISTS - 文件存在时的行为
    IF-DOES-NOT-EXIST - 文件不存在时的行为

  返回：
    写入的字节数"
  (with-file-operations
    (check-file-path filepath)
    (let ((bytes (flexi-streams:string-to-octets content
                                                  :encoding encoding)))
      (with-open-file (stream filepath
                              :direction :output
                              :element-type '(unsigned-byte 8)
                              :if-exists if-exists
                              :if-does-not-exist if-does-not-exist)
        (write-sequence bytes stream)
        (length bytes)))))

(defun file-append (filepath content &key (encoding :utf-8))
  "追加内容到文件

  参数：
    FILEPATH - 文件路径
    CONTENT  - 内容字符串
    ENCODING - 文件编码

  返回：
    写入的字节数"
  (file-write filepath content
              :encoding encoding
              :if-exists :append
              :if-does-not-exist :create))

(defun file-write-lines (filepath lines &key
                                       (encoding :utf-8)
                                       (if-exists :supersede))
  "写入行列表到文件

  参数：
    FILEPATH - 文件路径
    LINES    - 行列表
    ENCODING - 文件编码
    IF-EXISTS - 文件存在时的行为

  返回：
    写入的行数"
  (with-output-to-string (content)
    (dolist (line lines)
      (format t "~A~%" line)))
  (file-write filepath content
              :encoding encoding
              :if-exists if-exists)
  (length lines))

(defun file-write-binary (filepath bytes &key
                                       (if-exists :supersede)
                                       (if-does-not-exist :create))
  "写入二进制文件

  参数：
    FILEPATH - 文件路径
    BYTES    - 字节数组
    IF-EXISTS - 文件存在时的行为
    IF-DOES-NOT-EXIST - 文件不存在时的行为

  返回：
    写入的字节数"
  (with-file-operations
    (check-file-path filepath)
    (with-open-file (stream filepath
                            :direction :output
                            :element-type '(unsigned-byte 8)
                            :if-exists if-exists
                            :if-does-not-exist if-does-not-exist)
      (write-sequence bytes stream)
      (length bytes))))

;;; ============================================================
;;; 文件信息
;;; ============================================================

(defun file-exists-p (filepath)
  "检查文件是否存在

  参数：
    FILEPATH - 文件路径

  返回：
    T 或 NIL"
  (uiop:file-exists-p filepath))

(defun file-directory-p (filepath)
  "检查路径是否为目录

  参数：
    FILEPATH - 文件路径

  返回：
    T 或 NIL"
  (uiop:directory-exists-p filepath))

(defun file-size (filepath)
  "获取文件大小

  参数：
    FILEPATH - 文件路径

  返回：
    文件大小（字节）或 NIL"
  (when (file-exists-p filepath)
    (handler-case
        (with-open-file (stream filepath
                                :direction :input
                                :element-type '(unsigned-byte 8))
          (file-length stream))
      (error ()
        nil))))

(defun file-modification-time (filepath)
  "获取文件修改时间

  参数：
    FILEPATH - 文件路径

  返回：
    修改时间（universal time）或 NIL"
  (when (file-exists-p filepath)
    (handler-case
        (with-open-file (stream filepath :direction :input)
          (file-write-date stream))
      (error ()
        nil))))

(defun file-info (filepath)
  "获取文件信息

  参数：
    FILEPATH - 文件路径

  返回：
    信息 plist"
  (let ((path (uiop:parse-native-namestring filepath)))
    `(:path ,(namestring path)
      :exists ,(uiop:file-exists-p path)
      :directory ,(uiop:directory-exists-p path)
      :size ,(file-size filepath)
      :modification-time ,(file-modification-time filepath)
      :absolute ,(uiop:absolute-pathname-p path))))

;;; ============================================================
;;; 目录操作 - 可移植辅助函数
;;; ============================================================

(defun %delete-empty-directory (dir)
  "可移植的空目录删除 (内部函数)

  参数：
    DIR - 目录路径

  说明：
    支持 SBCL, CCL 以及通过 UIOP 的其他实现"
  (let ((path (if (pathnamep dir) dir (pathname dir))))
    #+sbcl (sb-posix:rmdir (namestring path))
    #+ccl (ccl:delete-directory path)
    #-(or sbcl ccl) (uiop:delete-empty-directory path)))

(defun %delete-directory-recursive (dir)
  "内部函数：递归删除目录内容

  参数：
    DIR - 目录路径

  说明：
    先删除所有文件，再递归删除子目录，最后删除空目录"
  (let ((path (if (pathnamep dir) dir (pathname dir))))
    ;; 删除目录中的所有文件
    (dolist (item (uiop:directory-files path))
      (delete-file item))
    ;; 递归删除子目录
    (dolist (subdir (uiop:subdirectories path))
      (%delete-directory-recursive subdir))
    ;; 删除空目录
    (%delete-empty-directory path)))

;;; ============================================================
;;; 目录操作
;;; ============================================================

(defun directory-list (directory &key (recursive nil))
  "列出目录内容

  参数：
    DIRECTORY - 目录路径
    RECURSIVE - 是否递归

  返回：
    路径列表"
  (with-file-operations
    (check-file-path directory)
    (if recursive
        ;; 使用 directory 递归查找
        (uiop:subdirectories directory)
        ;; 非递归，只列出直接内容
        (append (uiop:directory-files directory)
                (uiop:subdirectories directory)))))

(defun directory-create (directory &key (if-exists :error))
  "创建目录

  参数：
    DIRECTORY - 目录路径
    IF-EXISTS - 目录存在时的行为

  返回：
    目录路径"
  (with-file-operations
    (check-file-path directory)
    (ensure-directories-exist directory
                               :verbose *tool-verbose*)
    directory))

(defun directory-delete (directory &key (recursive nil))
  "删除目录

  参数：
    DIRECTORY - 目录路径
    RECURSIVE - 是否递归删除

  返回：
    T 或 NIL

  说明：
    支持 SBCL 和 CCL 双实现"
  (with-file-operations
    (check-file-path directory)
    (when (uiop:directory-exists-p directory)
      (if recursive
          (%delete-directory-recursive directory)
          ;; 非递归：检查目录是否为空
          (let ((files (uiop:directory-files directory))
                (subdirs (uiop:subdirectories directory)))
            (if (and (null files) (null subdirs))
                (%delete-empty-directory directory)
                (error "Directory not empty: ~A" directory)))))
    t))

;;; ============================================================
;;; 文件操作
;;; ============================================================

(defun file-delete (filepath)
  "删除文件

  参数：
    FILEPATH - 文件路径

  返回：
    T 或 NIL"
  (with-file-operations
    (check-file-path filepath)
    (when (file-exists-p filepath)
      (delete-file filepath)
      t)))

(defun file-copy (source destination)
  "复制文件

  参数：
    SOURCE      - 源文件路径
    DESTINATION - 目标文件路径

  返回：
    目标文件路径"
  (with-file-operations
    (check-file-path source)
    (check-file-path destination)
    ;; 使用标准 Common Lisp 方式复制文件
    (with-open-file (in source
                        :direction :input
                        :element-type '(unsigned-byte 8))
      (with-open-file (out destination
                           :direction :output
                           :element-type '(unsigned-byte 8)
                           :if-exists :supersede)
        (let ((buffer (make-array 8192 :element-type '(unsigned-byte 8))))
          (loop for bytes-read = (read-sequence buffer in)
                while (plusp bytes-read)
                do (write-sequence buffer out :end bytes-read)))))
    destination))

(defun file-move (source destination)
  "移动文件

  参数：
    SOURCE      - 源文件路径
    DESTINATION - 目标文件路径

  返回：
    目标文件路径"
  (with-file-operations
    (check-file-path source)
    (check-file-path destination)
    (rename-file source destination)
    destination))

(defun file-rename (old new)
  "重命名文件

  参数：
    OLD - 旧文件路径
    NEW - 新文件路径

  返回：
    新文件路径"
  (file-move old new))

;;; ============================================================
;;; 路径操作
;;; ============================================================

(defun path-join (&rest components)
  "连接路径组件

  参数：
    COMPONENTS - 路径组件列表

  返回：
    连接后的路径"
  (when components
    (let ((result (first components)))
      (dolist (component (rest components))
        (setf result (merge-pathnames
                      (uiop:parse-native-namestring component)
                      (uiop:parse-native-namestring result))))
      (uiop:native-namestring result))))

(defun path-normalize (path)
  "规范化路径

  参数：
    PATH - 路径字符串

  返回：
    规范化后的路径"
  (handler-case
      (uiop:native-namestring (truename path))
    (error ()
      ;; 如果文件不存在，返回路径本身
      (uiop:native-namestring (uiop:parse-native-namestring path)))))

(defun path-absolute-p (path)
  "检查是否为绝对路径

  参数：
    PATH - 路径字符串

  返回：
    T 或 NIL"
  (uiop:absolute-pathname-p path))

(defun path-directory (path)
  "获取路径的目录部分

  参数：
    PATH - 路径字符串

  返回：
    目录路径"
  (let ((pathname (uiop:parse-native-namestring path)))
    (uiop:native-namestring (make-pathname
                              :directory (pathname-directory pathname)
                              :name nil
                              :type nil))))

(defun path-basename (path)
  "路径的文件名部分

  参数：
    PATH - 路径字符串

  返回：
    文件名"
  (let ((pathname (uiop:parse-native-namestring path)))
    (pathname-name pathname)))

(defun path-extension (path)
  "获取文件扩展名

  参数：
    PATH - 路径字符串

  返回：
    扩展名（不包括点）"
  (let ((pathname (uiop:parse-native-namestring path)))
    (pathname-type pathname)))

;;; ============================================================
;;; 文件搜索
;;; ============================================================

(defun file-find (pattern directory &key (recursive t))
  "在目录中查找文件

  参数：
    PATTERN   - 文件名模式（通配符）
    DIRECTORY - 搜索目录
    RECURSIVE - 是否递归搜索

  返回：
    匹配文件列表"
  (with-file-operations
    (check-file-path directory)
    (let ((files (directory-list directory :recursive recursive)))
      (remove-if-not (lambda (filepath)
                       (cl-ppcre:scan pattern
                                       (file-namestring filepath)))
                     files))))

;;; ============================================================
;;; 权限和安全
;;; ============================================================

(defun check-file-path (filepath)
  "检查文件路径是否允许访问

  参数：
    FILEPATH - 文件路径

  错误：
    - file-access-error: 路径不允许访问"
  (when *file-allowed-paths*
    (let ((absolute-path (path-normalize filepath)))
      (unless (some (lambda (allowed-path)
                     (cl-ppcre:scan (format nil "^~A" allowed-path)
                                     absolute-path))
                   *file-allowed-paths*)
        (error "File access denied: ~A" filepath)))))

(defun set-file-whitelist (paths)
  "设置允许访问的路径白名单

  参数：
    PATHS - 路径列表

  说明：
    空列表表示允许所有路径"
  (setf *file-allowed-paths* paths)
  (when *tool-verbose*
    (format t "[File] Whitelist set to: ~A~%" paths)))

(defun allow-file-path (path)
  "添加路径到白名单

  参数：
    PATH - 路径字符串"
  (pushnew path *file-allowed-paths* :test #'string=)
  (when *tool-verbose*
    (format t "[File] Allowed path: ~A~%" path)))

;;; ============================================================
;;; 文件工具注册
;;; ============================================================

(defun register-file-tools ()
  "注册文件工具

  返回：
    注册的工具数量"
  ;; 读取文件（注意：忽略encoding参数，函数内部使用关键字）
  (register-tool
   :file-read
   "Read file contents"
   (lambda (filepath &key encoding)
     (declare (ignore encoding))
     (file-read filepath))
   :parameters '((:filepath
                  :type string
                  :description "File path"
                  :required t)
                 (:encoding
                  :type string
                  :description "File encoding"
                  :required nil
                  :default "utf-8"))
   :category :file
   :permissions '(:file-read))

  ;; 写入文件
  (register-tool
   :file-write
   "Write content to file"
   (lambda (filepath content &key encoding)
     (declare (ignore encoding))
     (file-write filepath content))
   :parameters '((:filepath
                  :type string
                  :description "File path"
                  :required t)
                 (:content
                  :type string
                  :description "Content to write"
                  :required t)
                 (:encoding
                  :type string
                  :description "File encoding"
                  :required nil
                  :default "utf-8"))
   :category :file
   :permissions '(:file-write))

  ;; 追加文件
  (register-tool
   :file-append
   "Append content to file"
   (lambda (filepath content &key encoding)
     (declare (ignore encoding))
     (file-append filepath content))
   :parameters '((:filepath
                  :type string
                  :description "File path"
                  :required t)
                 (:content
                  :type string
                  :description "Content to append"
                  :required t))
   :category :file
   :permissions '(:file-write))

  ;; 列出目录
  (register-tool
   :directory-list
   "List directory contents"
   (lambda (directory &key recursive)
     (declare (ignore recursive))
     (directory-list directory))
   :parameters '((:directory
                  :type string
                  :description "Directory path"
                  :required nil
                  :default ".")
                 (:recursive
                  :type boolean
                  :description "Recursive listing"
                  :required nil
                  :default nil))
   :category :file
   :permissions '(:file-read))

  ;; 文件信息
  (register-tool
   :file-info
   "Get file information"
   #'file-info
   :parameters '((:filepath
                  :type string
                  :description "File path"
                  :required t))
   :category :file
   :permissions '(:file-read))

  ;; 删除文件
  (register-tool
   :file-delete
   "Delete file"
   #'file-delete
   :parameters '((:filepath
                  :type string
                  :description "File path"
                  :required t))
   :category :file
   :permissions '(:file-write))

  ;; 复制文件
  (register-tool
   :file-copy
   "Copy file"
   #'file-copy
   :parameters '((:source
                  :type string
                  :description "Source file path"
                  :required t)
                 (:destination
                  :type string
                  :description "Destination file path"
                  :required t))
   :category :file
   :permissions '(:file-read :file-write))

  ;; 移动文件
  (register-tool
   :file-move
   "Move file"
   #'file-move
   :parameters '((:source
                  :type string
                  :description "Source file path"
                  :required t)
                 (:destination
                  :type string
                  :description "Destination file path"
                  :required t))
   :category :file
   :permissions '(:file-read :file-write))

  9)  ;; 返回注册的工具数量

;;; ============================================================
;;; 自动初始化
;;; ============================================================

;; 自动注册文件工具（当加载此文件时）
;; (register-file-tools)  ; Temporarily disabled to test loading

;; 导出符号
