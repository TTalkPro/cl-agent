;;;; tools-usage.lisp
;;;; CL-Agent - 工具使用示例

;; 加载系统
(asdf:load-system :cl-agent)

;; 使用包
(in-package :cl-user)
(use-package :cl-agent)
(use-package :cl-agent.tools)

;;; ============================================================
;;; 示例 1：基本工具使用
;;; ============================================================

(defun example-1-basic-usage ()
  "基本工具注册和使用"
  (format t "~%=== Example 1: Basic Tool Usage ===~%")

  ;; 注册自定义工具
  (register-tool
   :greet
   "Greet someone"
   (lambda (name)
     (format nil "Hello, ~A!" name))
   :parameters '((:name
                  :type string
                  :description "Name to greet"
                  :required t))
   :category :demo)

  ;; 检查工具是否注册
  (format t "Tool registered: ~A~%"
          (tool-registered-p :greet))

  ;; 获取工具
  (let ((tool (get-tool :greet)))
    (format t "Tool info:~%")
    (print-tool-info tool))

  ;; 执行工具
  (let ((result (execute-tool :greet '("Alice"))))
    (format t "Result: ~A~%" result))

  ;; 列出所有工具
  (format t "~%All tools: ~A~%" (list-tools)))

;;; ============================================================
;;; 示例 2：搜索工具
;;; ============================================================

(defun example-2-search-tools ()
  "搜索工具使用"
  (format t "~%=== Example 2: Search Tools ===~%")

  ;; 使用 DuckDuckGo 搜索
  (format t "~%Searching for 'Common Lisp'...~%")
  (multiple-value-bind (success-p result error)
      (execute-tool-safe :search '("Common Lisp programming"))
    (if success-p
        (progn
          (format t "~%Search results:~%")
          (format t "~A~%" (format-search-results result)))
        (format t "Search failed: ~A~%" error)))

  ;; 快速搜索
  (format t "~%~%Quick search...~%")
  (let ((result (execute-tool :quick-search '("Lisp macros"))))
    (format t "~A~%" (format-search-results result))))

;;; ============================================================
;;; 示例 3：Shell 工具
;;; ============================================================

(defun example-3-shell-tools ()
  "Shell 工具使用"
  (format t "~%=== Example 3: Shell Tools ===~%")

  ;; 启用 Shell 工具
  (enable-shell)

  ;; 列出当前目录
  (format t "~%Current directory:~%")
  (let ((result (execute-tool :ls '(nil :directory "."))))
    (format t "~A~%" result))

  ;; 获取当前工作目录
  (format t "~%Working directory:~%")
  (let ((result (execute-tool :pwd nil)))
    (format t "~A~%" result))

  ;; 执行自定义命令
  (format t "~%Custom command:~%")
  (multiple-value-bind (success-p result error)
      (execute-tool-safe :shell '("echo 'Hello from Shell!'"))
    (if success-p
        (format t "~A~%" result)
        (format t "Command failed: ~A~%" error)))

  ;; 禁用 Shell 工具（安全）
  ;; (disable-shell))

;;; ============================================================
;;; 示例 4：文件工具
;;; ============================================================

(defun example-4-file-tools ()
  "文件工具使用"
  (format t "~%=== Example 4: File Tools ===~%")

  ;; 创建临时目录
  (let ((temp-dir "/tmp/cl-agent-test"))
    (ensure-directories-exist temp-dir)

    ;; 写入文件
    (format t "~%Writing file...~%")
    (execute-tool :file-write
                  `(,(format nil "~A/test.txt" temp-dir)
                    ,"Hello from CL-Agent!\\nThis is a test file."))

    ;; 读取文件
    (format t "~%Reading file...~%")
    (let ((content (execute-tool :file-read
                                 `(,(format nil "~A/test.txt" temp-dir)))))
      (format t "~A~%" content))

    ;; 追加内容
    (format t "~%Appending content...~%")
    (execute-tool :file-append
                  `(,(format nil "~A/test.txt" temp-dir)
                    ,"\\nAppended line."))

    ;; 再次读取
    (format t "~%File after append:~%")
    (let ((content (execute-tool :file-read
                                 `(,(format nil "~A/test.txt" temp-dir)))))
      (format t "~A~%" content))

    ;; 获取文件信息
    (format t "~%File info:~%")
    (let ((info (execute-tool :file-info
                              `(,(format nil "~A/test.txt" temp-dir)))))
      (format t "Size: ~A bytes~%" (getf info :size)))

    ;; 列出目录
    (format t "~%Directory listing:~%")
    (let ((files (execute-tool :directory-list `(,temp-dir))))
      (format t "~{~A~%~}~%" files))))

;;; ============================================================
;;; 示例 5：HTTP 工具
;;; ============================================================

(defun example-5-http-tools ()
  "HTTP 工具使用"
  (format t "~%=== Example 5: HTTP Tools ===~%")

  ;; HTTP GET 请求
  (format t "~%HTTP GET request...~%")
  (multiple-value-bind (success-p result error)
      (execute-tool-safe :http-get
                         '("https://httpbin.org/get"
                           :params '(("foo" . "bar"))
                           :timeout 10))
    (if success-p
        (let ((status (getf result :status))
              (body (getf result :body)))
          (format t "Status: ~A~%" status)
          (format t "Body: ~A~%" (subseq body 0 (min 200 (length body)))))
        (format t "Request failed: ~A~%" error)))

  ;; HTTP GET JSON
  (format t "~%~%HTTP GET JSON...~%")
  (multiple-value-bind (success-p result error)
      (execute-tool-safe :http-get-json
                         '("https://jsonplaceholder.typicode.com/posts/1"
                           :timeout 10))
    (if success-p
        (format t "Result: ~A~%" result)
        (format t "Request failed: ~A~%" error)))

  ;; HTTP POST JSON
  (format t "~%~%HTTP POST JSON...~%")
  (multiple-value-bind (success-p result error)
      (execute-tool-safe :http-post-json
                         '("https://jsonplaceholder.typicode.com/posts"
                           (("title" . "Test")
                            ("body" . "Test body")
                            ("userId" . 1))
                           :timeout 10))
    (if success-p
        (format t "Result: ~A~%" result)
        (format t "Request failed: ~A~%" error)))

  ;; 下载文件
  (format t "~%~%Downloading file...~%")
  (let ((download-path "/tmp/cl-agent-download.json"))
    (multiple-value-bind (success-p result error)
        (execute-tool-safe :http-download
                           `("https://jsonplaceholder.typicode.com/posts/1"
                             :filepath ,download-path
                             :timeout 30))
      (if success-p
          (format t "Downloaded to: ~A~%" download-path)
          (format t "Download failed: ~A~%" error)))))

;;; ============================================================
;;; 示例 6：工具权限控制
;;; ============================================================

(defun example-6-permissions ()
  "工具权限控制"
  (format t "~%=== Example 6: Tool Permissions ===~%")

  ;; 启用权限检查
  (setf *permissions-enabled* t)

  ;; 设置初始权限
  (setf *allowed-permissions* '(:all))

  ;; 检查权限
  (format t "Network access allowed: ~A~%"
          (permission-allowed-p :network-access))
  (format t "Shell access allowed: ~A~%"
          (permission-allowed-p :shell-access))

  ;; 撤销 Shell 权限
  (revoke-permission :shell-access)
  (format t "~%After revoking shell access:~%")
  (format t "Shell access allowed: ~A~%"
          (permission-allowed-p :shell-access))

  ;; 恢复权限
  (grant-permission :shell-access)
  (format t "~%After granting shell access:~%")
  (format t "Shell access allowed: ~A~%"
          (permission-allowed-p :shell-access))

  ;; 禁用权限检查
  (setf *permissions-enabled* nil))

;;; ============================================================
;;; 示例 7：工具分类
;;; ============================================================

(defun example-7-categories ()
  "按分类查看工具"
  (format t "~%=== Example 7: Tool Categories ===~%")

  ;; 列出所有分类
  (format t "~%Available categories:~%")
  (let ((categories (remove-duplicates
                     (remove nil
                             (mapcar (lambda (name)
                                      (let ((tool (get-tool name)))
                                        (when tool
                                          (tool-category tool))))
                                    (list-tools))))))
    (dolist (cat categories)
      (format t "  - ~A~%" cat))))

;;; ============================================================
;;; 示例 8：工具序列化
;;; ============================================================

(defun example-8-serialization ()
  "工具序列化"
  (format t "~%=== Example 8: Tool Serialization ===~%")

  ;; 获取工具
  (let ((tool (get-tool :search)))
    (when tool
      ;; 转换为 plist
      (let ((plist (tool-to-plist tool)))
        (format t "~%Tool plist:~%")
        (format t "  Name: ~A~%" (getf plist :name))
        (format t "  Description: ~A~%" (getf plist :description))
        (format t "  Category: ~A~%" (getf plist :category)))

      ;; 转换为 JSON Schema
      (let ((json-schema (tool-to-json-schema tool)))
        (format t "~%~%JSON Schema:~%")
        (format t "  Type: ~A~%" (getf json-schema :type))
        (format t "  Name: ~A~%" (getf json-schema :name))
        (format t "  Description: ~A~%" (getf json-schema :description))))))

;;; ============================================================
;;; 示例 9：批量工具执行
;;; ============================================================

(defun example-9-batch-execution ()
  "批量执行工具"
  (format t "~%=== Example 9: Batch Execution ===~%")

  ;; 批量执行多个工具
  (format t "~%Executing multiple tools:~%")

  (let ((results
         (list
          ;; 执行 1: pwd
          (cons :pwd (execute-tool :pwd nil))

          ;; 执行 2: ls
          (cons :ls (execute-tool :ls '(nil :directory ".")))

          ;; 执行 3: echo
          (cons :echo (execute-tool :shell-safe '("echo 'Batch test'"))))))

    (dolist (result results)
      (format t "~%~A: ~A~%" (car result) (cdr result)))))

;;; ============================================================
;;; 示例 10：自定义工具定义
;;; ============================================================

(defun example-10-custom-tools ()
  "使用 define-tool 宏定义工具"
  (format t "~%=== Example 10: Custom Tool Definition ===~%")

  ;; 使用宏定义工具
  (define-tool :calculate
    "Perform simple arithmetic calculations"
    (expression)
    (let ((result (eval (read-from-string expression))))
      (format nil "~A = ~A" expression result)))

  ;; 使用自定义工具
  (format t "~%Calculating:~%")
  (let ((result (execute-tool :calculate '("(+ 1 2 3)"))))
    (format t "~A~%" result))

  (format t "~%~%Calculating:~%")
  (let ((result (execute-tool :calculate '("(* 10 20)"))))
    (format t "~A~%" result)))

  ;; 定义更复杂的工具
  (define-tool :format-date
    "Format current date"
    (&key (format-string "%Y-%m-%d %H:%M:%S"))
    (local-time:format-timestring nil
                                   (local-time:now)
                                   :format format-string))

  (format t "~%~%Current date:~%")
  (let ((result (execute-tool :format-date nil)))
    (format t "~A~%" result)))

;;; ============================================================
;;; 运行所有示例
;;; ============================================================

(defun run-tools-examples ()
  "运行所有工具示例"
  (format t "~%========================================")
  (format t "~%  CL-Agent Tools Examples")
  (format t "~%========================================")

  (example-1-basic-usage)
  ;; (example-2-search-tools)  ; 需要网络
  (example-3-shell-tools)
  (example-4-file-tools)
  ;; (example-5-http-tools)    ; 需要网络
  (example-6-permissions)
  (example-7-categories)
  (example-8-serialization)
  (example-9-batch-execution)
  (example-10-custom-tools)

  (format t "~%========================================")
  (format t "~%  All tools examples completed!")
  (format t "~%========================================~%"))

;; 运行示例（取消注释）
;; (run-tools-examples)
