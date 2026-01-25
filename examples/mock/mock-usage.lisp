;;;; mock-usage.lisp
;;;; CL-Agent - Mock 使用示例
;;;;
;;;; 概述：
;;;;   展示如何使用 Mock 功能进行测试和开发
;;;;
;;;; 特性：
;;;;   - 不需要 API 密钥
;;;;   - 快速测试功能
;;;;   - 确定性输出
;;;;
;;;; 适用场景：
;;;;   - 单元测试
;;;;   - 功能演示
;;;;   - 开发调试

(in-package :cl-user)

;;; ============================================================
;;; 基础 Mock 使用示例
;;; ============================================================

(defun example-mock-quick-chat ()
  "示例 1: Mock 快速聊天"
  (format t "~%=== 示例 1: Mock 快速聊天 ===~%")

  (let* ((mock-provider (cl-agent.mock:make-quick-mock :smart))
         (response (cl-agent.llm:quick-chat
                    mock-provider
                    "介绍一下 Common Lisp")))
    (format t "响应: ~A~%" response)))

(defun example-mock-with-client-macro ()
  "示例 2: 使用 with-llm-client 宏配合 Mock"
  (format t "~%=== 示例 2: 使用 with-llm-client 宏配合 Mock ===~%")

  (let* ((mock-provider (cl-agent.mock:make-quick-mock :smart)))
    (cl-agent.llm:with-llm-client (client mock-provider)
      (let ((response1 (cl-agent.llm:llm-chat
                        client
                        '((:role "user" :content "你好")))))
        (format t "对话1: ~A~%" (getf response1 :content)))

      (let ((response2 (cl-agent.llm:llm-chat
                        client
                        '((:role "user" :content "再见")))))
        (format t "对话2: ~A~%" (getf response2 :content))))))

;;; ============================================================
;;; Mock Agent 使用示例
;;; ============================================================

(defun example-mock-agent ()
  "示例 3: 使用 Mock 创建 Agent"
  (format t "~%=== 示例 3: 使用 Mock 创建 Agent ===~%")

  (let* ((mock-provider (cl-agent.mock:make-quick-mock :smart))
         (client (cl-agent.llm:make-llm-client :provider mock-provider))

         ;; 创建简单工具
         (calculator (cl-agent.tools:make-tool
                      :calculator
                      "执行数学计算"
                      (lambda (input &key context)
                        (declare (ignore context))
                        (let ((expr (getf input :expression)))
                          (handler-case
                              (let ((result (eval (read-from-string expr))))
                                (list :success t
                                      :result (format nil "~A = ~A" expr result)))
                            (error (e)
                              (list :success nil
                                    :error (format nil "计算错误: ~A" e))))))
                      :parameters
                      (list :type "object"
                            :properties (list (list :expression
                                                    (list :type "string"
                                                          :description "数学表达式")))
                            :required (list "expression")))))

    ;; 注册工具
    (cl-agent.tools:register-tool
     :calculator
     (cl-agent.tools:tool-description calculator)
     (cl-agent.tools:tool-execute-fn calculator))

    ;; 创建 Agent
    (let ((agent (cl-agent.agent:make-agent
                  :name "计算助手"
                  :llm-client client
                  :tools '(:calculator)
                  :system-prompt "你是一个擅长数学计算的助手。")))

      (format t "Agent 信息:~%")
      (cl-agent.agent:print-agent-info agent)

      ;; 与 Agent 对话
      (format t "~%对话示例:~%")
      (let ((response (cl-agent.agent:agent-chat
                       agent
                       "帮我计算 (10 + 20) * 3")))
        (format t "Agent 响应: ~A~%" response)))))

;;; ============================================================
;;; Mock 工作流使用示例
;;; ============================================================

(defun example-mock-workflow ()
  "示例 4: 使用 Mock 的工作流"
  (format t "~%=== 示例 4: 使用 Mock 的工作流 ===~%")

  (let* ((mock-provider (cl-agent.mock:make-quick-mock :smart))
         (client (cl-agent.llm:make-llm-client :provider mock-provider))

         ;; 创建工作流
         (workflow (cl-agent.graph:make-workflow
                    :name "分析工作流"
                    :strategy :sequential)))

    ;; 添加节点
    (cl-agent.graph:workflow-add-node
     workflow :analyze
     (lambda (state)
       (format t "  [步骤1] 分析数据...~%")
       (cl-agent.graph:state-set state :analyzed t)))

    (cl-agent.graph:workflow-add-node
     workflow :process
     (lambda (state)
       (format t "  [步骤2] 处理数据...~%")
       (cl-agent.graph:state-set state :processed t)))

    (cl-agent.graph:workflow-add-node
     workflow :report
     (lambda (state)
       (format t "  [步骤3] 生成报告...~%")
       (cl-agent.graph:state-set state :report "分析完成")))

    ;; 添加边
    (cl-agent.graph:workflow-add-edge workflow :analyze :process)
    (cl-agent.graph:workflow-add-edge workflow :process :report)

    ;; 设置入口
    (cl-agent.graph:workflow-set-entry workflow :analyze)

    ;; 运行工作流
    (format t "运行工作流:~%")
    (let ((final-state (cl-agent.graph:workflow-run
                        workflow
                        (cl-agent.graph:make-state)
                        :verbose t)))
      (format t "~%最终状态: ~A~%" final-state))))

;;; ============================================================
;;; 运行所有 Mock 示例
;;; ============================================================

(defun run-mock-examples ()
  "运行所有 Mock 示例"
  (format t "~%========================================")
  (format t "~%  CL-Agent Mock 使用示例")
  (format t "~%========================================")
  (format t "~%注意：Mock 示例不需要 API 密钥")
  (format t "~%      适合用于测试和开发")
  (format t "~%========================================")

  (example-mock-quick-chat)
  (example-mock-with-client-macro)
  (example-mock-agent)
  (example-mock-workflow)

  (format t "~%========================================")
  (format t "~%  所有 Mock 示例运行完成")
  (format t "~%========================================~%"))
