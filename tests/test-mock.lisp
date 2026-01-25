;;;; test-mock.lisp
;;;; CL-Agent - Mock 模块测试
;;;;
;;;; 测试 Mock 模块的所有功能

(in-package :cl-agent/tests)

;; Mock 测试套件
(def-suite mock-suite
  :in cl-agent-suite
  :description "Mock 模块测试")

(in-suite mock-suite)

;;; ============================================================
;;; Mock LLM 测试
;;; ============================================================

(test make-mock-llm-basic
  "测试创建基本 Mock LLM"
  (let ((mock (cl-agent.mock:make-mock-llm)))
    (is (typep mock 'cl-agent.mock:mock-llm-provider))
    (is (eq (cl-agent.llm:llm-provider-name mock) :mock))
    (is (stringp (cl-agent.llm:llm-default-model mock)))))

(test make-mock-llm-with-delay
  "测试创建带延迟的 Mock LLM"
  (let ((mock (cl-agent.mock:make-mock-llm :response-delay 0.1)))
    (is (= (cl-agent.mock:mock-response-delay mock) 0.1))))

(test make-mock-llm-with-error-rate
  "测试创建带错误率的 Mock LLM"
  (let ((mock (cl-agent.mock:make-mock-llm :error-rate 0.5)))
    (is (= (cl-agent.mock:mock-error-rate mock) 0.5))))

(test make-mock-llm-with-responses
  "测试创建带预定义响应的 Mock LLM"
  (let ((responses (make-hash-table :test #'equal))
        (mock))
    (setf (gethash "你好" responses) "你好！")
    (setf (gethash "测试" responses) "测试响应")
    (setf mock (cl-agent.mock:make-mock-llm :responses responses))
    (is (typep mock 'cl-agent.mock:mock-llm-provider))
    (is (not (null (cl-agent.mock:mock-responses mock))))))

(test llm-available-p-mock
  "测试 Mock LLM 总是可用"
  (let ((mock (cl-agent.mock:make-mock-llm)))
    (is (cl-agent.llm:llm-available-p mock))))

(test llm-chat-mock-simple
  "测试 Mock LLM 简单聊天"
  (let ((mock (cl-agent.mock:make-mock-llm))
        (messages '((:role "user" :content "你好"))))
    (let ((response (cl-agent.llm:llm-chat mock messages)))
      (is (consp response))
      (is (getf response :content))
      (is (getf response :usage)))))

(test llm-chat-mock-with-predefined-response
  "测试 Mock LLM 预定义响应"
  (let ((responses (make-hash-table :test #'equal))
        (mock))
    (setf (gethash "测试提示" responses)
          (list :content "预定义响应" :success t))
    (setf mock (cl-agent.mock:make-mock-llm :responses responses))
    (let ((response (cl-agent.llm:llm-chat
                     mock
                     '((:role "user" :content "测试提示")))))
      (is (string= (getf response :content) "预定义响应")))))

(test llm-chat-mock-calculator-scenario
  "测试 Mock LLM 计算器场景"
  (let ((mock (cl-agent.mock:make-mock-llm))
        (messages '((:role "user" :content "帮我计算 1+1"))))
    (let ((response (cl-agent.llm:llm-chat mock messages :tools t)))
      (is (getf response :content))
      (is (getf response :tool-calls))))

(test llm-chat-mock-search-scenario
  "测试 Mock LLM 搜索场景"
  (let ((mock (cl-agent.mock:make-mock-llm))
        (messages '((:role "user" :content "搜索最新新闻"))))
    (let ((response (cl-agent.llm:llm-chat mock messages :tools t)))
      (is (getf response :content)))))

(test llm-chat-mock-code-scenario
  "测试 Mock LLM 代码生成场景"
  (let ((mock (cl-agent.mock:make-mock-llm))
        (messages '((:role "user" :content "写一个递归函数"))))
    (let ((response (cl-agent.llm:llm-chat mock messages)))
      (is (getf response :content))
      (is (cl-ppcre:scan "defun|defn|function"
                        (getf response :content)))))

(test llm-chat-mock-joke-scenario
  "测试 Mock LLM 笑话场景"
  (let ((mock (cl-agent.mock:make-mock-llm))
        (messages '((:role "user" :content "讲个笑话"))))
    (let ((response (cl-agent.llm:llm-chat mock messages)))
      (is (getf response :content))
      (is (> (length (getf response :content)) 10)))))

(test llm-chat-mock-with-delay
  "测试 Mock LLM 带延迟"
  (let ((mock (cl-agent.mock:make-mock-llm :response-delay 0.1))
        (messages '((:role "user" :content "测试"))))
    (let ((start (get-universal-time))
          (response (cl-agent.llm:llm-chat mock messages))
          (end (get-universal-time)))
      (is (getf response :content))
      ;; 延迟应该至少 0.1 秒
      (is (> (- end start) 0)))))

(test make-quick-mock-smart
  "测试快速创建智能 Mock"
  (let ((mock (cl-agent.mock:make-quick-mock :smart)))
    (is (typep mock 'cl-agent.mock:mock-llm-provider))))

(test make-quick-mock-echo
  "测试快速创建回显 Mock"
  (let ((mock (cl-agent.mock:make-quick-mock :echo))
        (messages '((:role "user" :content "测试回显"))))
    (let ((response (cl-agent.llm:llm-chat mock messages)))
      (is (getf response :content)))))

(test make-quick-mock-fixed
  "测试快速创建固定响应 Mock"
  (let ((mock (cl-agent.mock:make-quick-mock :fixed))
        (messages '((:role "user" :content "任意内容"))))
    (let ((response (cl-agent.llm:llm-chat mock messages)))
      (is (getf response :content)))))

(test create-predefined-mock
  "测试创建预定义场景 Mock"
  (let ((mock (cl-agent.mock:create-predefined-mock)))
    (is (typep mock 'cl-agent.mock:mock-llm-provider))
    (let ((response (cl-agent.llm:llm-chat
                     mock
                     '((:role "user" :content "你好")))))
      (is (getf response :content)))))

;;; ============================================================
;;; Mock 工具测试
;;; ============================================================

(test make-calculator-tool
  "测试创建 Mock 计算器工具"
  (let ((tool (cl-agent.mock:make-calculator-tool)))
    (is (typep tool 'cl-agent.mock:mock-tool))
    (is (eq (cl-agent.tools:tool-name tool) :calculator))))

(test make-search-tool
  "测试创建 Mock 搜索工具"
  (let ((tool (cl-agent.mock:make-search-tool)))
    (is (typep tool 'cl-agent.mock:mock-tool))
    (is (eq (cl-agent.tools:tool-name tool) :search))))

(test make-file-tool
  "测试创建 Mock 文件工具"
  (let ((tool (cl-agent.mock:make-file-tool)))
    (is (typep tool 'cl-agent.mock:mock-tool))
    (is (eq (cl-agent.tools:tool-name tool) :file-ops))))

(test make-database-tool
  "测试创建 Mock 数据库工具"
  (let ((tool (cl-agent.mock:make-database-tool)))
    (is (typep tool 'cl-agent.mock:mock-tool))
    (is (eq (cl-agent.tools:tool-name tool) :database))))

(test make-mock-toolkit
  "测试创建完整 Mock 工具包"
  (let ((toolkit (cl-agent.mock:make-mock-toolkit)))
    (is (listp toolkit))
    (is (= (length toolkit) 4))
    (is (every (lambda (t) (typep t 'cl-agent.mock:mock-tool))
               toolkit))))

(test mock-tool-execute-calculator
  "测试 Mock 计算器工具执行"
  (let ((tool (cl-agent.mock:make-calculator-tool)))
    (let ((result (cl-agent.tools:tool-execute
                   tool
                   '(:expression "1+1"))))
      (is (getf result :success))
      (is (getf result :result)))))

(test mock-tool-execute-search
  "测试 Mock 搜索工具执行"
  (let ((tool (cl-agent.mock:make-search-tool)))
    (let ((result (cl-agent.tools:tool-execute
                   tool
                   '(:query "测试查询"))))
      (is (getf result :success))
      (is (getf result :result)))))

(test mock-tool-execute-file-read
  "测试 Mock 文件工具执行（读取）"
  (let ((tool (cl-agent.mock:make-file-tool)))
    (let ((result (cl-agent.tools:tool-execute
                   tool
                   '(:action :read :path "/tmp/test.txt"))))
      (is (getf result :success)))))

(test mock-tool-execute-file-write
  "测试 Mock 文件工具执行（写入）"
  (let ((tool (cl-agent.mock:make-file-tool)))
    (let ((result (cl-agent.tools:tool-execute
                   tool
                   '(:action :write :path "/tmp/test.txt" :content "test"))))
      (is (getf result :success)))))

(test mock-tool-execute-file-list
  "测试 Mock 文件工具执行（列出）"
  (let ((tool (cl-agent.mock:make-file-tool)))
    (let ((result (cl-agent.tools:tool-execute
                   tool
                   '(:action :list :path "/tmp"))))
      (is (getf result :success))
      (is (listp (getf result :result)))))

(test mock-tool-execute-database
  "测试 Mock 数据库工具执行"
  (let ((tool (cl-agent.mock:make-database-tool)))
    (let ((result (cl-agent.tools:tool-execute
                   tool
                   '(:query "SELECT * FROM users"))))
      (is (getf result :success))
      (is (getf result :result)))))

(test mock-tool-with-delay
  "测试带延迟的 Mock 工具"
  (let ((tool (cl-agent.mock:make-calculator-tool :delay 0.1)))
    (let ((start (get-internal-real-time))
          (result (cl-agent.tools:tool-execute
                   tool
                   '(:expression "1+1")))
          (end (get-internal-real-time)))
      (is (getf result :success))
      (is (> (- end start) 0)))))

(test mock-tool-with-error-rate
  "测试带错误率的 Mock 工具"
  (let ((tool (cl-agent.mock:make-calculator-tool :error-rate 1.0))
        (success-count 0)
        (total-count 10))
    (dotimes (i total-count)
      (let ((result (cl-agent.tools:tool-execute
                     tool
                     '(:expression "1+1"))))
        (when (getf result :success)
          (incf success-count))))
    ;; 由于错误率是 100%，所有请求都应该失败
    (is (= success-count 0))))

(test mock-tool-schema
  "测试 Mock 工具 schema"
  (let ((tool (cl-agent.mock:make-calculator-tool)))
    (let ((schema (cl-agent.tools:tool-schema tool)))
      (is (getf schema :name))
      (is (getf schema :description))
      (is (getf schema :parameters)))))

;;; ============================================================
;;; 辅助函数测试
;;; ============================================================

(test safe-evaluate-expression
  "测试安全表达式求值"
  (is (= (cl-agent.mock:safe-evaluate-expression "1+1") 2))
  (is (= (cl-agent.mock:safe-evaluate-expression "2*3") 6))
  (is (= (cl-agent.mock:safe-evaluate-expression "10-5") 5)))

(test generate-mock-search-results
  "测试生成 Mock 搜索结果"
  (let ((result (cl-agent.mock:generate-mock-search-results "测试")))
    (is (stringp result))
    (is (cl-ppcre:scan "测试" result))))

(test generate-mock-db-results
  "测试生成 Mock 数据库结果"
  (let ((result (cl-agent.mock:generate-mock-db-results "SELECT *")))
    (is (stringp result))
    (is (cl-ppcre:scan "SELECT" result))))

;;; ============================================================
;;; 运行 Mock 测试
;;; ============================================================

(defun run-mock-tests ()
  "运行所有 Mock 测试"
  (run! 'mock-suite))
