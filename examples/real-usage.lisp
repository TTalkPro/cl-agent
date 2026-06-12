;;;; real-usage.lisp
;;;; CL-Agent - 真实 LLM 使用示例
;;;;
;;;; 展示如何使用真实的 LLM 提供商（ZhipuAI、OpenAI 等）
;;;;
;;;; 注意：运行这些示例需要设置相应的 API 密钥环境变量

(in-package :cl-user)

;;; ============================================================
;;; ZhipuAI 使用示例
;;; ============================================================

(defun example-zhipu-basic ()
  "示例 1: ZhipuAI 基本使用"
  (format t "~%=== 示例 1: ZhipuAI 基本使用 ===~%")

  (handler-case
      ;; 创建 ZhipuAI 客户端
      (let* ((provider (cl-agent.llm.providers:make-zhipu-provider
                        :model "glm-4.6"))
             (client (cl-agent.llm:make-llm-client :provider provider)))

        ;; 发送消息
        (let ((response (cl-agent.llm:llm-chat
                         client
                         '((:role "user" :content "你好，请介绍一下你自己")))))
          (format t "响应: ~A~%" (cl-agent.core:llm-response-content response))

          ;; 显示 token 使用
          (format t "Token 使用: 输入=~A 输出=~A~%"
                  (cl-agent.core:llm-response-input-tokens response)
                  (cl-agent.core:llm-response-output-tokens response))))

    (cl-agent.llm:missing-api-key-error (condition)
      (format t "错误: ~A~%" (cl-agent.llm:llm-error-message condition))
      (format t "请设置 ZHIPU_API_KEY 环境变量~%"))))

(defun example-zhipu-with-tools ()
  "示例 2: ZhipuAI 带工具调用"
  (format t "~%=== 示例 2: ZhipuAI 带工具调用 ===~%")

  (handler-case
      (let* ((provider (cl-agent.llm.providers:make-zhipu-provider))
             (client (cl-agent.llm:make-llm-client :provider provider))
             (tools (list
                    (list :name "calculator"
                          :description "执行数学计算"
                          :parameters
                          (list :type "object"
                                :properties
                                (list (list :expression
                                            (list :type "string"
                                                  :description "数学表达式")))
                                :required (list "expression"))))))

        (let ((response (cl-agent.llm:llm-chat
                         client
                         '((:role "user" :content "帮我计算 123 * 456"))
                         :tools tools)))
          (format t "响应: ~A~%" (cl-agent.core:llm-response-content response))

          (when (cl-agent.core:llm-response-has-tool-calls-p response)
            (format t "~%工具调用:~%")
            (dolist (call (cl-agent.core:llm-response-tool-calls response))
              (format t "  - ID: ~A~%" (getf call :id))
              (format t "    工具: ~A~%" (getf call :name))
              (format t "    参数: ~A~%" (getf call :arguments))))))

    (cl-agent.llm:missing-api-key-error (condition)
      (format t "错误: ~A~%" (cl-agent.llm:llm-error-message condition)))))

(defun example-zhipu-reasoning-content ()
  "示例 3: ZhipuAI 思维链提取"
  (format t "~%=== 示例 3: ZhipuAI 思维链提取 ===~%")

  (handler-case
      (let* ((provider (cl-agent.llm.providers:make-zhipu-provider
                        :model "glm-4.6"))
             (client (cl-agent.llm:make-llm-client
                     :provider provider
                     :max-tokens 4096))  ; glm-4.6 需要更大的 max-tokens

            (response (cl-agent.llm:llm-chat
                       client
                       '((:role "user" :content "详细分析一下为什么 1+1=2")))))

        ;; 提取思维链
        (let ((reasoning (cl-agent.llm.providers:extract-reasoning-content response)))
          (when reasoning
            (format t "思维链内容:~%~A~%" reasoning)))

        ;; 检查响应是否完整
        (let ((complete (cl-agent.llm.providers:response-complete-p response)))
          (format t "响应完整: ~A~%" complete))

        ;; 最终答案
        (format t "~%最终答案: ~A~%" (cl-agent.core:llm-response-content response)))

    (cl-agent.llm:missing-api-key-error (condition)
      (format t "错误: ~A~%" (cl-agent.llm:llm-error-message condition)))))

;;; ============================================================
;;; OpenAI 使用示例
;;; ============================================================

(defun example-openai-basic ()
  "示例 4: OpenAI 基本使用"
  (format t "~%=== 示例 4: OpenAI 基本使用 ===~%")

  (handler-case
      (let* ((provider (cl-agent.llm.providers:make-openai-provider
                        :model "gpt-4o"))
             (client (cl-agent.llm:make-llm-client :provider provider)))

        (let ((response (cl-agent.llm:llm-chat
                         client
                         '((:role "user" :content "What is AI?")))))
          (format t "响应: ~A~%" (cl-agent.core:llm-response-content response))

          (format t "Token 使用: 输入=~A 输出=~A~%"
                  (cl-agent.core:llm-response-input-tokens response)
                  (cl-agent.core:llm-response-output-tokens response))))

    (cl-agent.llm:missing-api-key-error (condition)
      (format t "错误: ~A~%" (cl-agent.llm:llm-error-message condition))
      (format t "请设置 OPENAI_API_KEY 环境变量~%"))))

;;; ============================================================
;;; Agent 使用示例
;;; ============================================================

(defun example-agent-with-zhipu ()
  "示例 5: 使用 ZhipuAI 创建 Agent"
  (format t "~%=== 示例 5: 使用 ZhipuAI 创建 Agent ===~%")

  (handler-case
      ;; 创建 LLM 客户端
      (let* ((provider (cl-agent.llm.providers:make-zhipu-provider))
             (client (cl-agent.llm:make-llm-client :provider provider))

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
            (format t "Agent 响应: ~A~%" response))))

    (cl-agent.llm:missing-api-key-error (condition)
      (format t "错误: ~A~%" (cl-agent.llm:llm-error-message condition)))))

;;; ============================================================
;;; 运行所有示例
;;; ============================================================

(defun run-real-examples ()
  "运行所有真实 LLM 示例"
  (format t "~%========================================")
  (format t "~%  CL-Agent 真实 LLM 使用示例")
  (format t "~%========================================")
  (format t "~%注意：这些示例需要设置 API 密钥环境变量")
  (format t "~%  - ZHIPU_API_KEY (智谱AI)")
  (format t "~%  - OPENAI_API_KEY (OpenAI)")
  (format t "~%========================================")

  (example-zhipu-basic)
  (example-zhipu-with-tools)
  (example-zhipu-reasoning-content)
  (example-openai-basic)
  (example-agent-with-zhipu)

  (format t "~%========================================")
  (format t "~%  所有示例运行完成")
  (format t "~%========================================~%"))
