;;;; test-tools.lisp
;;;; CL-Agent - 工具测试

(in-package :cl-agent/tests)

;; 工具测试套件
(def-suite tools-suite :in cl-agent-tests:lisp-in-agents-suite
  :description "工具系统测试")

(in-suite tools-suite)

;; ============================================================
;; 工具核心测试
;; ============================================================

(test register-tool
  "测试工具注册"
  ;; 注册测试工具
  (cl-agent.tools:register-tool
   :test-tool
   "Test tool"
   (lambda (x) (* 2 x))
   :parameters '((:x :type number :required t))
   :category :test)

  ;; 检查注册
  (is (cl-agent.tools:tool-registered-p :test-tool))

  ;; 获取工具
  (let ((tool (cl-agent.tools:get-tool :test-tool)))
    (is (not (null tool)))
    (is (eq (cl-agent.tools:tool-name tool) :test-tool))
    (is (string= (cl-agent.tools:tool-description tool) "Test tool"))))

(test unregister-tool
  "测试工具注销"
  ;; 注册工具
  (cl-agent.tools:register-tool
   :temp-tool
   "Temporary tool"
   (lambda () nil))

  (is (cl-agent.tools:tool-registered-p :temp-tool))

  ;; 注销工具
  (let ((removed (cl-agent.tools:unregister-tool :temp-tool)))
    (is (not (null removed)))
    (is (not (cl-agent.tools:tool-registered-p :temp-tool)))))

(test list-tools
  "测试列出工具"
  ;; 清空工具
  (cl-agent.tools:clear-tools)

  ;; 注册几个工具
  (cl-agent.tools:register-tool :tool1 "Tool 1" (lambda () nil) :category :cat1)
  (cl-agent.tools:register-tool :tool2 "Tool 2" (lambda () nil) :category :cat2)
  (cl-agent.tools:register-tool :tool3 "Tool 3" (lambda () nil) :category :cat1)

  ;; 列出所有工具
  (let ((all-tools (cl-agent.tools:list-tools)))
    (is (= (length all-tools) 3)))

  ;; 按分类列出
  (let ((cat1-tools (cl-agent.tools:list-tools :category :cat1)))
    (is (= (length cat1-tools) 2))))

(test execute-tool
  "测试工具执行"
  ;; 注册测试工具
  (cl-agent.tools:register-tool
   :double
   "Double a number"
   (lambda (x) (* 2 x))
   :parameters '((:x :type number :required t)))

  ;; 执行工具
  (let ((result (cl-agent.tools:execute-tool :double '(5))))
    (is (= result 10)))

  ;; 测试参数解析
  (let ((result (cl-agent.tools:execute-tool :double '(:x 7))))
    (is (= result 14))))

(test execute-tool-safe
  "测试安全工具执行"
  ;; 注册会失败的测试工具
  (cl-agent.tools:register-tool
   :failing-tool
   "A tool that fails"
   (lambda () (error "Intentional failure")))

  ;; 安全执行
  (multiple-value-bind (result success-p error)
      (cl-agent.tools:execute-tool-safe :failing-tool nil)
    (is (not success-p))
    (is (not (null error)))
    (is (stringp result))))

;; ============================================================
;; 参数处理测试
;; ============================================================

(test flatten-arguments
  "测试参数展平"
  ;; plist
  (is (equal (cl-agent.tools:flatten-arguments '(:a 1 :b 2))
             '(:a 1 :b 2)))

  ;; alist
  (let ((result (cl-agent.tools:flatten-arguments '((:a . 1) (:b . 2)))))
    (is (member :a result))
    (is (member 1 result)))

  ;; hash-table
  (let ((table (make-hash-table)))
    (setf (gethash :a table) 1)
    (setf (gethash :b table) 2)
    (let ((result (cl-agent.tools:flatten-arguments table)))
      (is (member :a result))
      (is (member 1 result)))))

;; ============================================================
;; 权限测试
;; ============================================================

(test permissions
  "测试权限控制"
  ;; 启用权限
  (setf cl-agent.tools:*permissions-enabled* t)

  ;; 设置权限
  (setf cl-agent.tools:*allowed-permissions* '(:test))

  ;; 检查权限
  (is (cl-agent.tools:permission-allowed-p :test))
  (is (not (cl-agent.tools:permission-allowed-p :other)))

  ;; 授予权限
  (cl-agent.tools:grant-permission :other)
  (is (cl-agent.tools:permission-allowed-p :other))

  ;; 撤销权限
  (cl-agent.tools:revoke-permission :other)
  (is (not (cl-agent.tools:permission-allowed-p :other)))

  ;; 禁用权限检查
  (setf cl-agent.tools:*permissions-enabled* nil))

;; ============================================================
;; 工具信息测试
;; ============================================================

(test tool-info
  "测试工具信息"
  (cl-agent.tools:register-tool
   :info-test
   "Test tool for info"
   (lambda () nil)
   :parameters '((:param1 :type string :required t))
   :category :info
   :permissions '(:test-perm))

  (let ((tool (cl-agent.tools:get-tool :info-test))
        (info (cl-agent.tools:tool-info (cl-agent.tools:get-tool :info-test))))
    (is (eq (getf info :name) :info-test))
    (is (string= (getf info :description) "Test tool for info"))
    (is (eq (getf info :category) :info))
    (is (member :test-perm (getf info :permissions)))))

(test tool-to-plist
  "测试工具转换为 plist"
  (cl-agent.tools:register-tool
   :plist-test
   "Test plist conversion"
   (lambda () nil)
   :category :test)

  (let ((tool (cl-agent.tools:get-tool :plist-test))
        (plist (cl-agent.tools:tool-to-plist
                (cl-agent.tools:get-tool :plist-test))))
    (is (eq (getf plist :name) :plist-test))
    (is (string= (getf plist :description) "Test plist conversion"))
    (is (eq (getf plist :category) :test))))

;; ============================================================
;; Shell 工具测试
;; ============================================================

(test shell-pwd
  "测试 pwd 命令"
  (cl-agent.tools:enable-shell)
  (let ((result (cl-agent.tools:pwd)))
    (is (stringp result))
    (is (> (length result) 0))))

(test shell-ls
  "测试 ls 命令"
  (cl-agent.tools:enable-shell)
  (let ((result (cl-agent.tools:ls ".")))
    (is (stringp result))))

(test shell-command-safe
  "测试安全命令执行"
  (cl-agent.tools:enable-shell)
  (multiple-value-bind (success-p output error)
      (cl-agent.tools:shell-command-safe "echo 'test'")
    (is success-p)
    (is (stringp output))
    (is (null error))))

;; ============================================================
;; 文件工具测试
;; ============================================================

(test file-exists-p
  "测试文件存在检查"
  (is (cl-agent.tools:file-exists-p "/tmp"))
  (is (not (cl-agent.tools:file-exists-p "/nonexistent/file.xyz"))))

(test file-info
  "测试文件信息"
  (let ((info (cl-agent.tools:file-info "/tmp")))
    (is (plist-get info :exists))
    (is (plist-get info :directory))))

(test path-operations
  "测试路径操作"
  (is (stringp (cl-agent.tools:path-join "a" "b" "c")))
  (is (stringp (cl-agent.tools:path-directory "/path/to/file.txt")))
  (is (stringp (cl-agent.tools:path-basename "/path/to/file.txt"))))

;; ============================================================
;; HTTP 工具测试
;; ============================================================

(test http-status-code-checks
  "测试 HTTP 状态码检查"
  ;; 成功状态码
  (is (cl-agent.tools:status-code-success-p 200))
  (is (cl-agent.tools:status-code-success-p 204))
  (is (not (cl-agent.tools:status-code-success-p 404)))

  ;; 客户端错误
  (is (cl-agent.tools:status-code-client-error-p 400))
  (is (cl-agent.tools:status-code-client-error-p 404))
  (is (not (cl-agent.tools:status-code-client-error-p 500)))

  ;; 服务器错误
  (is (cl-agent.tools:status-code-server-error-p 500))
  (is (cl-agent.tools:status-code-server-error-p 503))
  (is (not (cl-agent.tools:status-code-server-error-p 404))))

(test http-merge-headers
  "测试请求头合并"
  (let ((result (cl-agent.tools:merge-headers '(("Content-Type" . "application/json")))))
    (is (consp result))
    (is (assoc "Content-Type" result :test #'string=))))

;; ============================================================
;; 工具序列化测试
;; ============================================================

(test tool-from-plist
  "测试从 plist 创建工具"
  (let ((plist '(:name :test-from-plist
                 :description "Test"
                 :parameters nil
                 :category :test
                 :permissions nil))
        (tool (cl-agent.tools:tool-from-plist
               '(:name :test-from-plist
                 :description "Test"
                 :parameters nil
                 :category :test
                 :permissions nil))))
    (is (eq (cl-agent.tools:tool-name tool) :test-from-plist))
    (is (string= (cl-agent.tools:tool-description tool) "Test"))
    (is (eq (cl-agent.tools:tool-category tool) :test))))

;; ============================================================
;; 工具发现测试
;; ============================================================

(test find-tools-by-category
  "测试按分类查找工具"
  ;; 清空并注册测试工具
  (cl-agent.tools:clear-tools)
  (cl-agent.tools:register-tool :cat1-a "Tool" (lambda () nil) :category :cat1)
  (cl-agent.tools:register-tool :cat1-b "Tool" (lambda () nil) :category :cat1)
  (cl-agent.tools:register-tool :cat2-a "Tool" (lambda () nil) :category :cat2)

  (let ((cat1-tools (cl-agent.tools:find-tools-by-category :cat1)))
    (is (= (length cat1-tools) 2)))

  (let ((cat2-tools (cl-agent.tools:find-tools-by-category :cat2)))
    (is (= (length cat2-tools) 1))))

;; ============================================================
;; 运行工具测试
;; ============================================================

(defun run-tools-tests ()
  "运行所有工具测试"
  (run! 'tools-suite))
