;;;; mock-usage.lisp
;;;; CL-Agent - Mock 模块使用示例
;;;;
;;;; 展示如何使用 Mock 模块进行测试和演示
;;;;
;;;; 使用：
;;;;   sbcl --load examples/mock-usage.lisp
;;;;   ccl --load examples/mock-usage.lisp

(require :asdf)

;; Set up paths to load from current project directory first
(let ((root (make-pathname :directory (butlast (pathname-directory *load-truename*)))))
  (dolist (d '("" "core/" "llm/" "extra/" "mock/"))
    (pushnew (merge-pathnames d root) asdf:*central-registry* :test #'equal)))

(ql:quickload :cl-agent-mock :silent t)

(in-package :cl-user)

;;; ============================================================
;;; Mock LLM 使用示例
;;; ============================================================

(defun example-mock-llm-basic ()
  "示例 1: 基本的 Mock LLM 使用"
  (format t "~%=== 示例 1: 基本 Mock LLM ===~%")

  ;; 创建 Mock LLM
  (let ((mock (cl-agent.mock:make-mock-llm)))

    ;; 发送消息
    (let ((response (cl-agent.llm:llm-chat
                     mock
                     '((:role "user" :content "你好！")))))
      (format t "响应: ~A~%" (cl-agent.core:llm-response-content response))
      (format t "Token 使用: 输入=~A 输出=~A~%"
              (cl-agent.core:llm-response-input-tokens response)
              (cl-agent.core:llm-response-output-tokens response)))))

(defun example-mock-llm-smart-responses ()
  "示例 2: 智能 Mock 响应"
  (format t "~%=== 示例 2: 智能 Mock 响应 ===~%")

  (let ((mock (cl-agent.mock:make-quick-mock :smart)))

    ;; 计算场景
    (format t "计算场景:~%")
    (let ((response (cl-agent.llm:llm-chat
                     mock
                     '((:role "user" :content "帮我计算 1+1"))
                     :tools t)))
      (format t "  响应: ~A~%" (cl-agent.core:llm-response-content response))
      (when (cl-agent.core:llm-response-has-tool-calls-p response)
        (format t "  工具调用: ~A~%" (cl-agent.core:llm-response-tool-calls response))))

    ;; 代码生成场景
    (format t "~%代码生成场景:~%")
    (let ((response (cl-agent.llm:llm-chat
                     mock
                     '((:role "user" :content "写一个递归函数")))))
      (format t "  响应: ~A~%" (cl-agent.core:llm-response-content response)))

    ;; 笑话场景
    (format t "~%笑话场景:~%")
    (let ((response (cl-agent.llm:llm-chat
                     mock
                     '((:role "user" :content "讲个笑话")))))
      (format t "  响应: ~A~%" (cl-agent.core:llm-response-content response)))))

(defun example-mock-llm-predefined-responses ()
  "示例 3: 预定义响应"
  (format t "~%=== 示例 3: 预定义响应 ===~%")

  (let ((responses (make-hash-table :test #'equal))
        (mock))

    ;; 设置预定义响应
    (setf (gethash "你好" responses)
          (list :content "你好！有什么可以帮助你的吗？"))

    (setf (gethash "1+1等于几" responses)
          (list :content "1+1=2"
                :tool-calls (list (list :id "call_calc"
                                       :name :calculator
                                       :arguments "{\"expression\": \"1+1\"}"))))

    (setf mock (cl-agent.mock:make-mock-llm :responses responses))

    ;; 测试预定义响应
    (let ((response1 (cl-agent.llm:llm-chat
                      mock
                      '((:role "user" :content "你好")))))
      (format t "响应1: ~A~%" (cl-agent.core:llm-response-content response1)))

    (let ((response2 (cl-agent.llm:llm-chat
                      mock
                      '((:role "user" :content "1+1等于几")))))
      (format t "响应2: ~A~%" (cl-agent.core:llm-response-content response2))
      (format t "工具调用: ~A~%" (cl-agent.core:llm-response-tool-calls response2)))))

(defun example-mock-llm-with-delay-and-errors ()
  "示例 4: 带延迟和错误的 Mock"
  (format t "~%=== 示例 4: 带延迟和错误的 Mock ===~%")

  ;; 带延迟的 Mock
  (format t "带延迟的 Mock (0.1秒):~%")
  (let ((mock (cl-agent.mock:make-mock-llm :response-delay 0.1))
        (start (get-universal-time)))
    (let ((response (cl-agent.llm:llm-chat
                     mock
                     '((:role "user" :content "测试")))))
      (let ((end (get-universal-time)))
        (format t "  响应: ~A~%" (cl-agent.core:llm-response-content response))
        (format t "  耗时: ~A 秒~%" (- end start)))))

  ;; 带错误率的 Mock
  (format t "~%带错误率的 Mock (100%):~%")
  (let ((mock (cl-agent.mock:make-mock-llm :error-rate 1.0)))
    (dotimes (i 3)
      (let ((response (cl-agent.llm:llm-chat
                       mock
                       '((:role "user" :content "测试")))))
        (if (eq (cl-agent.core:llm-response-finish-reason response) :error)
            (format t "  请求 ~A: 错误~%" (1+ i))
            (format t "  请求 ~A: 成功 - ~A~%" (1+ i)
                    (cl-agent.core:llm-response-content response)))))))

;;; ============================================================
;;; Mock 工具使用示例
;;; ============================================================

(defun example-mock-tools-calculator ()
  "示例 5: Mock 计算器工具"
  (format t "~%=== 示例 5: Mock 计算器工具 ===~%")

  (let ((calc (cl-agent.mock:make-calculator-tool)))

    ;; 执行计算
    (let ((result (cl-agent.tools:tool-execute
                   calc
                   '(:expression "1+1"))))
    (format t "1+1 = ~A~%" (getf result :result)))

    (let ((result (cl-agent.tools:tool-execute
                   calc
                   '(:expression "2*3+4"))))
    (format t "2*3+4 = ~A~%" (getf result :result)))))

(defun example-mock-tools-search ()
  "示例 6: Mock 搜索工具"
  (format t "~%=== 示例 6: Mock 搜索工具 ===~%")

  (let ((search (cl-agent.mock:make-search-tool)))

    ;; 执行搜索
    (let ((result (cl-agent.tools:tool-execute
                   search
                   '(:query "Common Lisp 编程"))))
      (format t "搜索结果:~%")
      (format t "~A~%" (getf result :result)))))

(defun example-mock-tools-file ()
  "示例 7: Mock 文件工具"
  (format t "~%=== 示例 7: Mock 文件工具 ===~%")

  (let ((file (cl-agent.mock:make-file-tool)))

    ;; 读取文件
    (let ((result (cl-agent.tools:tool-execute
                   file
                   '(:action :read :path "/tmp/test.txt"))))
      (format t "读取文件: ~A~%" (getf result :result)))

    ;; 写入文件
    (let ((result (cl-agent.tools:tool-execute
                   file
                   '(:action :write :path "/tmp/test.txt" :content "测试内容"))))
      (format t "写入文件: ~A~%" (getf result :metadata)))

    ;; 列出目录
    (let ((result (cl-agent.tools:tool-execute
                   file
                   '(:action :list :path "/tmp"))))
      (format t "目录内容: ~A~%" (getf result :result)))))

(defun example-mock-toolkit ()
  "示例 8: 完整的 Mock 工具包"
  (format t "~%=== 示例 8: 完整的 Mock 工具包 ===~%")

  ;; 创建工具包
  (let ((toolkit (cl-agent.mock:make-mock-toolkit)))

    (format t "工具包包含 ~D 个工具:~%" (length toolkit))
    (dolist (tool toolkit)
      (format t "  - ~A: ~A~%"
              (cl-agent.tools:tool-name tool)
              (cl-agent.tools:tool-description tool)))))

;;; ============================================================
;;; 集成示例：Mock LLM + Mock 工具
;;; ============================================================

(defun example-mock-agent ()
  "示例 9: 使用 Mock 创建简单 Agent"
  (format t "~%=== 示例 9: 使用 Mock 创建 Agent ===~%")

  ;; 创建 Mock LLM
  (let ((mock-llm (cl-agent.mock:make-quick-mock :smart)))

    ;; 创建 Mock 工具包
    (let ((toolkit (cl-agent.mock:make-mock-toolkit)))

      ;; 注册工具
      (dolist (tool toolkit)
        (cl-agent.tools:register-tool
         (cl-agent.tools:tool-name tool)
         (cl-agent.tools:tool-description tool)
         (lambda (input &key context)
           (cl-agent.tools:tool-execute tool input :context context))))

      ;; 模拟对话
      (format t "用户: 帮我计算 123 * 456~%")
      (let ((response (cl-agent.llm:llm-chat
                       mock-llm
                       '((:role "user" :content "帮我计算 123 * 456"))
                       :tools toolkit)))
        (format t "Agent: ~A~%" (cl-agent.core:llm-response-content response))

        (when (cl-agent.core:llm-response-has-tool-calls-p response)
          (format t "工具调用:~%")
          (dolist (call (cl-agent.core:llm-response-tool-calls response))
            (format t "  - 工具: ~A~%" (getf call :name))
            (format t "    参数: ~A~%" (getf call :arguments))))))))

;;; ============================================================
;;; 运行所有示例
;;; ============================================================

(defun run-mock-examples ()
  "运行所有 Mock 示例"
  (format t "~%========================================")
  (format t "~%  CL-Agent Mock 模块使用示例")
  (format t "~%========================================")

  (example-mock-llm-basic)
  (example-mock-llm-smart-responses)
  (example-mock-llm-predefined-responses)
  (example-mock-llm-with-delay-and-errors)
  (example-mock-tools-calculator)
  (example-mock-tools-search)
  (example-mock-tools-file)
  (example-mock-toolkit)
  (example-mock-agent)

  (format t "~%========================================")
  (format t "~%  所有示例运行完成")
  (format t "~%========================================~%"))

;;; ============================================================
;;; 运行示例
;;; ============================================================

(run-mock-examples)

#+sbcl (sb-ext:exit :code 0)
#+ccl (ccl:quit 0)
