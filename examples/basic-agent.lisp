;;;; basic-agent.lisp
;;;; Lisp in Agents - 基本 Agent 示例

;; 加载系统
(asdf:load-system :lisp-in-agents)

;; 使用包
(in-package :lisp-in-agents)

;;; ============================================================
;;; 示例 1：简单的聊天 Agent
;;; ============================================================

(defun example-1-simple-chat ()
  "最简单的聊天 Agent"
  ;; 创建 LLM 客户端
  (let* ((llm (make-client :provider :anthropic
                           :model "claude-3-5-sonnet-20241022"))
         ;; 创建简单的 Agent
         (agent (make-agent :llm-client llm
                           :system-prompt "You are a helpful assistant.")))

    ;; 与 Agent 对话
    (let ((response (agent-run agent "Hello! What can you do?")))
      (format t "Agent: ~A~%" response))))

;;; ============================================================
;;; 示例 2：带工具的 Agent
;;; ============================================================

(defun example-2-agent-with-tools ()
  "带工具的 ReAct Agent"
  (let* ((llm (make-client :provider :anthropic
                           :model "claude-3-5-sonnet-20241022"))
         ;; 定义工具
         (tools '(web-search shell-command))
         ;; 创建带工具的 Agent
         (agent (make-react-agent
                :llm-client llm
                :tools tools
                :system-prompt "You are a research assistant. Use tools when needed."
                :max-iterations 10)))

    ;; Agent 可以使用工具
    (let ((response (agent-run agent "Search for recent Common Lisp developments")))
      (format t "Agent: ~A~%" response))))

;;; ============================================================
;;; 示例 3：带记忆的 Agent
;;; ============================================================

(defun example-3-agent-with-memory ()
  "带记忆的 Agent - 记住对话历史"
  (let* ((llm (make-client :provider :anthropic
                           :model "claude-3-5-sonnet-20241022"))
         ;; 创建记忆
         (memory (make-memory :system-prompt "Remember our conversation."))
         ;; 创建带记忆的 Agent
         (agent (make-agent :llm-client llm
                           :memory memory
                           :system-prompt "You are a helpful assistant with memory.")))

    ;; 多轮对话
    (agent-run agent "My name is Alice")
    (agent-run agent "What's my name?")
    ;; Agent 记住了名字！
    ))

;;; ============================================================
;;; 示例 4：流式输出
;;; ============================================================

(defun example-4-streaming-agent ()
  "流式输出的 Agent"
  (let* ((llm (make-client :provider :anthropic
                           :model "claude-3-5-sonnet-20241022"))
         (agent (make-react-agent :llm-client llm)))

    ;; 使用回调处理流式输出
    (agent-run-stream agent
                      "Tell me a short story"
                      (lambda (chunk)
                        (format t "~A" chunk)
                        (force-output)))))

;;; ============================================================
;;; 示例 5：自定义工具
;;; ============================================================

(defun example-5-custom-tool ()
  "定义并使用自定义工具"
  ;; 定义一个计算器工具
  (define-tool calculator
    :description "Perform basic arithmetic calculations"
    :parameters '((expression . :string))
    :fn (lambda (args)
          (let ((expr (getf args :expression)))
            (format nil "Result: ~A"
                    (eval (read-from-string expr))))))

  ;; 创建使用自定义工具的 Agent
  (let* ((llm (make-client :provider :anthropic
                           :model "claude-3-5-sonnet-20241022"))
         (agent (make-react-agent
                :llm-client llm
                :tools '(calculator))))

    (agent-run agent "What is 123 * 456?")))

;;; ============================================================
;;; 示例 6：带检查点的 Agent
;;; ============================================================

(defun example-6-agent-with-checkpoints ()
  "带检查点的 Agent - 可以中断和恢复"
  (let* ((llm (make-client :provider :anthropic
                           :model "claude-3-5-sonnet-20241022"))
         (agent (make-react-agent
                :llm-client llm
                :system-prompt "You are a helpful assistant."))
         (thread-id "example-thread"))

    ;; 启用检查点
    (agent-run-with-checkpoints agent
                                "Start a long task..."
                                :thread-id thread-id
                                :checkpoint-interval :every-iteration)

    ;; 可以从检查点恢复
    ;; (agent-resume-from-checkpoint agent thread-id)))

;;; ============================================================
;;; 运行所有示例
;;; ============================================================

(defun run-examples ()
  "运行所有示例"
  (format t "~%=== Example 1: Simple Chat ===~%")
  (example-1-simple-chat)

  (format t "~%=== Example 2: Agent with Tools ===~%")
  (example-2-agent-with-tools)

  (format t "~%=== Example 3: Agent with Memory ===~%")
  (example-3-agent-with-memory)

  (format t "~%=== Example 4: Streaming Agent ===~%")
  (example-4-streaming-agent)

  (format t "~%=== Example 5: Custom Tool ===~%")
  (example-5-custom-tool)

  (format t "~%=== Example 6: Agent with Checkpoints ===~%")
  (example-6-agent-with-checkpoints))

;; 运行示例（取消注释）
;; (run-examples)
