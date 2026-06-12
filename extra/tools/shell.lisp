;;;; shell.lisp
;;;; CL-Agent - Shell 命令工具
;;;;
;;;; 概述：
;;;;   执行 Shell 命令的工具
;;;;
;;;; 特性：
;;;;   - 命令执行
;;;;   - 输出捕获
;;;;   - 超时控制
;;;;   - 安全限制

(in-package :cl-agent.tools)

;;; ============================================================
;;; 动态配置变量（通过动态绑定传递）
;;; ============================================================

(defvar *shell-allowed-commands* '()
  "允许执行的命令白名单（动态变量，通过 provider 绑定）")

(defvar *shell-timeout* 30
  "默认命令执行超时（动态变量，通过 provider 绑定）")

(defvar *shell-max-output-size* 100000
  "最大输出大小（动态变量，通过 provider 绑定）")

(defvar *shell-enabled* t
  "是否启用 Shell 工具（动态变量，通过 provider 绑定）")

;;; ============================================================
;;; 命令执行
;;; ============================================================

(defun shell-command (command &key
                             (timeout *shell-timeout*)
                             (directory nil)
                             (environment nil))
  "执行 Shell 命令

  参数：
    COMMAND    - 命令字符串
    TIMEOUT    - 超时时间（秒）
    DIRECTORY  - 工作目录（可选）
    ENVIRONMENT - 环境变量（可选）

  返回：
    (values exit-code output error-output)

  示例：
    (shell-command \\"ls -la\\" :timeout 10)"
  (unless *shell-enabled*
    (error "Shell commands are disabled"))

  ;; 检查命令白名单
  (when *shell-allowed-commands*
    (let ((cmd-name (first (cl-ppcre:split "\\s+" command))))
      (unless (member cmd-name *shell-allowed-commands* :test #'string=)
        (error "Command not allowed: ~A" cmd-name))))

  (handler-case
      (uiop:run-program
       command
       :output :strings
       :error-output :strings
       :input nil
       :timeout timeout
       :directory (when directory (uiop:parse-native-namestring directory))
       :environment (when environment environment))

    (uiop:subprocess-error (e)
      (values (uiop:subprocess-error-code e)
              ""
              ""))

    (error (e)
      (error "Command execution failed: ~A" e))))

(defun shell-command-safe (command &key (timeout *shell-timeout*))
  "安全执行 Shell 命令（捕获所有错误）

  参数：
    COMMAND - 命令字符串
    TIMEOUT - 超时时间

  返回：
    (values success-p output error)"
  (handler-case
      (multiple-value-bind (exit-code output error-output)
          (shell-command command :timeout timeout)
        (declare (ignore error-output))
        (values (zerop exit-code) output nil))
    (error (e)
      (values nil (format nil "Error: ~A" e) e))))

;;; ============================================================
;;; 命令管道
;;; ============================================================

(defun shell-pipe (commands &key (timeout *shell-timeout*))
  "执行命令管道

  参数：
    COMMANDS - 命令列表 ((cmd1 args...) (cmd2 args...) ...)
    TIMEOUT  - 超时时间

  返回：
    (values exit-code output error-output)

  示例：
    (shell-pipe '((\\"cat\\" \\"file.txt\\")
                  (\\"grep\\" \\"pattern\\")
                  (\\"wc\\" \\"-l\\")))"
  (unless *shell-enabled*
    (error "Shell commands are disabled"))

  (let* ((pipe-command (format nil "~{~A~^ | ~}"
                               (mapcar (lambda (cmd)
                                        (if (consp cmd)
                                            (format nil "~{~A~^ ~}" cmd)
                                            cmd))
                                      commands))))
    (shell-command pipe-command :timeout timeout)))

;;; ============================================================
;;; 常用命令包装
;;; ============================================================

(defun ls (&optional (directory ".") &key (long nil) (all nil))
  "列出目录内容

  参数：
    DIRECTORY - 目录路径
    LONG      - 详细格式
    ALL       - 包含隐藏文件

  返回：
    输出字符串"
  (let ((args (list directory)))
    (when long (push "-l" args))
    (when all (push "-a" args))
    (multiple-value-bind (exit-code output error-output)
        (shell-command (format nil "ls ~{~A ~}" (nreverse args)))
      (declare (ignore error-output))
      (if (zerop exit-code)
          output
          (error "ls failed: ~A" output)))))

(defun cat (filepath)
  "显示文件内容

  参数：
    FILEPATH - 文件路径

  返回：
    文件内容字符串"
  (multiple-value-bind (exit-code output error-output)
      (shell-command (format nil "cat ~A" filepath))
    (declare (ignore error-output))
    (if (zerop exit-code)
        output
        (error "cat failed: ~A" output))))

(defun grep (pattern filepath &key (case-insensitive nil)
                                   (count nil)
                                   (line-number nil))
  "在文件中搜索模式

  参数：
    PATTERN         - 搜索模式
    FILEPATH        - 文件路径
    CASE-INSENSITIVE - 忽略大小写
    COUNT           - 只显示匹配数
    LINE-NUMBER     - 显示行号

  返回：
    匹配行字符串"
  (let ((args '()))
    (when case-insensitive (push "-i" args))
    (when count (push "-c" args))
    (when line-number (push "-n" args))
    (push pattern args)
    (push filepath args)
    (multiple-value-bind (exit-code output error-output)
        (shell-command (format nil "grep ~{~A ~}" (nreverse args)))
      (declare (ignore error-output))
      (if (zerop exit-code)
          output
          ""))))  ;; grep 没有匹配时返回非 0，但不是错误

(defun wc (filepath &key (lines nil) (words nil) (bytes nil))
  "统计文件行数、字数、字节数

  参数：
    FILEPATH - 文件路径
    LINES    - 统计行数
    WORDS    - 统计字数
    BYTES    - 统计字节数

  返回：
    统计信息字符串"
  (let ((args '()))
    (when lines (push "-l" args))
    (when words (push "-w" args))
    (when bytes (push "-c" args))
    (when (null args) (push "-lwc" args))  ; 默认全部
    (push filepath args)
    (multiple-value-bind (exit-code output error-output)
        (shell-command (format nil "wc ~{~A ~}" (nreverse args)))
      (declare (ignore error-output))
      (if (zerop exit-code)
          output
          (error "wc failed: ~A" output)))))

(defun pwd ()
  "获取当前工作目录

  返回：
    目录路径字符串"
  (multiple-value-bind (exit-code output error-output)
      (shell-command "pwd")
    (declare (ignore error-output))
    (if (zerop exit-code)
        (string-trim '(#\Newline #\Return) output)
        (error "pwd failed: ~A" output))))

(defun cd (directory)
  "切换工作目录（仅在进程内有效）

  参数：
    DIRECTORY - 目标目录

  返回：
    新工作目录路径

  说明：
    注意：这只影响当前 Lisp 进程的工作目录"
  (uiop:chdir (uiop:parse-native-namestring directory))
  (pwd))

;;; ============================================================
;;; Shell 工具注册
;;; ============================================================

(defun register-shell-tools ()
  "注册 Shell 工具

  返回：
    注册的工具数量"
  ;; 通用命令执行
  (register-tool
   :shell
   "Execute shell commands"
   #'shell-command
   :parameters '((:command
                  :type string
                  :description "Shell command to execute"
                  :required t)
                 (:timeout
                  :type integer
                  :description "Timeout in seconds"
                  :required nil
                  :default 30))
   :category :shell
   :permissions '(:shell-access))

  ;; 快速命令执行（安全版本）
  (register-tool
   :shell-safe
   "Execute shell commands safely (catches all errors)"
   #'shell-command-safe
   :parameters '((:command
                  :type string
                  :description "Shell command to execute"
                  :required t)
                 (:timeout
                  :type integer
                  :description "Timeout in seconds"
                  :required nil
                  :default 30))
   :category :shell
   :permissions '(:shell-access))

  ;; 列出目录
  (register-tool
   :ls
   "List directory contents"
   (lambda (directory &key (long nil) (all nil))
     (declare (ignore long all))
     (ls directory))
   :parameters '((:directory
                  :type string
                  :description "Directory path"
                  :required nil
                  :default ".")
                 (:long
                  :type boolean
                  :description "Long format"
                  :required nil
                  :default nil)
                 (:all
                  :type boolean
                  :description "Include hidden files"
                  :required nil
                  :default nil))
   :category :shell
   :permissions '(:shell-access))

  ;; 读取文件
  (register-tool
   :cat
   "Read file contents"
   #'cat
   :parameters '((:filepath
                  :type string
                  :description "File path"
                  :required t))
   :category :shell
   :permissions '(:shell-access :file-read))

  ;; 搜索文件内容
  (register-tool
   :grep
   "Search for pattern in file"
   (lambda (pattern filepath &key (case-insensitive nil)
                                   (count nil)
                                   (line-number nil))
     (declare (ignore case-insensitive count line-number))
     (grep pattern filepath))
   :parameters '((:pattern
                  :type string
                  :description "Search pattern"
                  :required t)
                 (:filepath
                  :type string
                  :description "File path"
                  :required t))
   :category :shell
   :permissions '(:shell-access :file-read))

  ;; 统计文件
  (register-tool
   :wc
   "Count lines, words, bytes in file"
   (lambda (filepath &key (lines nil) (words nil) (bytes nil))
     (declare (ignore lines words bytes))
     (wc filepath))
   :parameters '((:filepath
                  :type string
                  :description "File path"
                  :required t)
                 (:lines
                  :type boolean
                  :description "Count lines"
                  :required nil
                  :default nil)
                 (:words
                  :type boolean
                  :description "Count words"
                  :required nil
                  :default nil)
                 (:bytes
                  :type boolean
                  :description "Count bytes"
                  :required nil
                  :default nil))
   :category :shell
   :permissions '(:shell-access :file-read))

  ;; 获取当前目录
  (register-tool
   :pwd
   "Get current working directory"
   #'pwd
   :parameters '()
   :category :shell
   :permissions '(:shell-access))

  7)  ;; 返回注册的工具数量

;;; ============================================================
;;; 安全控制
;;; ============================================================

(defun enable-shell ()
  "启用 Shell 工具"
  (setf *shell-enabled* t)
  (when *tool-verbose*
    (format t "[Shell] Shell tools enabled~%")))

(defun disable-shell ()
  "禁用 Shell 工具"
  (setf *shell-enabled* nil)
  (when *tool-verbose*
    (format t "[Shell] Shell tools disabled~%")))

(defun set-shell-whitelist (commands)
  "设置允许的命令白名单

  参数：
    COMMANDS - 命令名称列表

  说明：
    空列表表示允许所有命令"
  (setf *shell-allowed-commands* commands)
  (when *tool-verbose*
    (format t "[Shell] Whitelist set to: ~A~%" commands)))

(defun allow-shell-command (command)
  "添加命令到白名单

  参数：
    COMMAND - 命令名称"
  (pushnew command *shell-allowed-commands* :test #'string=)
  (when *tool-verbose*
    (format t "[Shell] Allowed command: ~A~%" command)))

;;; ============================================================
;;; 辅助函数
;;; ============================================================

(defun parse-command-output (output &key (trim t))
  "解析命令输出

  参数：
    OUTPUT - 命令输出字符串
    TRIM   - 是否修剪空白

  返回：
    行列表"
  (let ((lines (cl-ppcre:split "\\r?\\n" output)))
    (if trim
        (mapcar #'string-trim '(#\Space #\Tab #\Newline #\Return) lines)
        lines)))

(defun get-exit-code-meaning (code)
  "获取退出代码的含义

  参数：
    CODE - 退出代码

  返回：
    描述字符串"
  (case code
    (0 "Success")
    (1 "General error")
    (2 "Misuse of shell command")
    (126 "Command invoked cannot execute")
    (127 "Command not found")
    (128 "Invalid exit argument")
    (130 "Control-C")
    (255 "Exit status out of range")
    (otherwise "Unknown error")))

;;; ============================================================
;;; 自动初始化
;;; ============================================================

;; 自动注册 Shell 工具（当加载此文件时）
;; (register-shell-tools)  ; Temporarily disabled to test loading

;; 导出符号
