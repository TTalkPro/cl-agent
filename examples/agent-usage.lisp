;;;; agent-usage.lisp
;;;; CL-Agent - Agent 使用示例

;; 加载系统
(asdf:load-system :cl-agent)

;; 使用包
(in-package :cl-user)
(use-package :cl-agent)

;;; ============================================================
;;; 示例 1：基本 Agent 使用
;;; ============================================================

(defun example-1-basic-agent ()
  "最简单的 Agent 使用"
  (format t "~%=== Example 1: Basic Agent ===~%")

  ;; 创建 LLM 客户端
  (let ((llm-client (cl-agent.llm:make-client
                     :provider :anthropic
                     :api-key (cl-agent.core:get-env "ANTHROPIC_API_KEY"))))

    ;; 创建 Agent
    (let ((agent (make-agent
                   :name "basic-agent"
                   :llm-client llm-client
                   :system-prompt "You are a helpful assistant.")))

      ;; 打印 Agent 信息
      (print-agent-info agent)

      ;; 与 Agent 对话
      (let ((response (agent-chat agent "Hello! How are you?"
                                    :verbose t)))
        (format t "~%Response: ~A~%" response)))))

;;; ============================================================
;;; 示例 2：ReAct Agent
;;; ============================================================

(defun example-2-react-agent ()
  "ReAct Agent 使用"
  (format t "~%=== Example 2: ReAct Agent ===~%")

  ;; 创建 LLM 客户端
  (let ((llm-client (cl-agent.llm:make-client
                     :provider :anthropic
                     :api-key (cl-agent.core:get-env "ANTHROPIC_API_KEY"))))

    ;; 创建工具（示例）
    ;; (cl-agent.tools:register-tool :search ...)
    ;; (cl-agent.tools:register-tool :calculator ...)

    ;; 创建 ReAct Agent
    (let ((agent (make-react-agent
                   :name "research-agent"
                   :llm-client llm-client
                   :tools '(:search :calculator)
                   :max-iterations 5)))

      (format t "Created ReAct agent: ~A~%" (agent-name agent))

      ;; 运行 Agent
      (let ((result (agent-run agent
                                "What is 15 * 23?"
                                :verbose t)))
        (format t "~%Result: ~A~%" result)))))

;;; ============================================================
;;; 示例 3：图 Agent
;;; ============================================================

(defun example-3-graph-agent ()
  "图 Agent 使用"
  (format t "~%=== Example 3: Graph Agent ===~%")

  ;; 创建工作流图
  (let ((graph (make-graph :name "simple-workflow")))

    ;; 添加节点
    (add-node graph :analyze
               (lambda (state)
                 (format t "  [Analyze] Processing input...~%")
                 (state-set state :analyzed t)))

    (add-node graph :process
               (lambda (state)
                 (format t "  [Process] Processing data...~%")
                 (state-set state :processed t)))

    (add-node graph :finalize
               (lambda (state)
                 (format t "  [Finalize] Finalizing result...~%")
                 (state-set state :finalized t)))

    ;; 添加边
    (add-edge graph :analyze :process)
    (add-edge graph :process :finalize)
    (set-entry-point graph :analyze)

    ;; 创建 LLM 客户端
    (let ((llm-client (cl-agent.llm:make-client
                       :provider :anthropic
                       :api-key (cl-agent.core:get-env "ANTHROPIC_API_KEY"))))

      ;; 创建图 Agent
      (let ((agent (make-graph-agent
                     :name "workflow-agent"
                     :llm-client llm-client
                     :graph graph)))

        ;; 运行图 Agent
        (multiple-value-bind (result metadata)
            (graph-agent-run agent "Sample input"
                              :verbose t
                              :save-execution-p t)
          (format t "~%Execution ID: ~A~%" (getf metadata :execution-id))
          (format t "Duration: ~A ms~%" (getf metadata :duration))

          ;; 打印执行统计
          (print-execution-statistics agent)))))

;;; ============================================================
;;; 示例 4：链式工作流 Agent
;;; ============================================================

(defun example-4-chain-agent ()
  "链式工作流 Agent 使用"
  (format t "~%=== Example 4: Chain Workflow Agent ===~%")

  ;; 创建 LLM 客户端
  (let ((llm-client (cl-agent.llm:make-client
                     :provider :anthropic
                     :api-key (cl-agent.core:get-env "ANTHROPIC_API_KEY"))))

    ;; 创建链式工作流 Agent
    (let ((agent (make-chain-graph-agent
                   :name "chain-agent"
                   :llm-client llm-client
                   :steps '((:step1 .
                             (lambda (s)
                               (format t "  [Step 1] Initialize~%")
                               (state-set s :step1 "done")))
                            (:step2 .
                             (lambda (s)
                               (format t "  [Step 2] Process~%")
                               (state-set s :step2 "done")))
                            (:step3 .
                             (lambda (s)
                               (format t "  [Step 3] Finalize~%")
                               (state-set s :step3 "done")))))))

      ;; 运行 Agent
      (let ((result (agent-run agent "data" :verbose t)))
        (format t "~%Final state keys: ~A~%"
                (state-keys result))))))

;;; ============================================================
;;; 示例 5：Agent 执行追踪
;;; ============================================================

(defun example-5-execution-tracking ()
  "Agent 执行追踪"
  (format t "~%=== Example 5: Execution Tracking ===~%")

  ;; 创建工作流图
  (let ((graph (make-graph :name "tracked-workflow")))

    ;; 添加节点
    (add-node graph :task1
               (lambda (state)
                 (format t "  [Task 1] Executing...~%")
                 (sleep 0.1)
                 (state-set state :task1-complete t)))

    (add-node graph :task2
               (lambda (state)
                 (format t "  [Task 2] Executing...~%")
                 (sleep 0.1)
                 (state-set state :task2-complete t)))

    (add-edge graph :task1 :task2)
    (set-entry-point graph :task1)

    ;; 创建 LLM 客户端
    (let ((llm-client (cl-agent.llm:make-client
                       :provider :anthropic
                       :api-key (cl-agent.core:get-env "ANTHROPIC_API_KEY"))))

      ;; 创建图 Agent
      (let ((agent (make-graph-agent
                     :name "tracked-agent"
                     :llm-client llm-client
                     :graph graph)))

        ;; 执行多次
        (dotimes (i 3)
          (format t "~%--- Execution ~A ---~%" (1+ i))
          (graph-agent-run agent (format nil "Input ~A" (1+ i))
                            :verbose nil
                            :save-execution-p t))

        ;; 查看执行历史
        (format t "~%~%Execution History:~%")
        (let ((history (get-execution-history agent :limit 5)))
          (dolist (record history)
            (format t "~A~%" (format-execution-record record))))

        ;; 打印统计信息
        (format t "~%")
        (print-execution-statistics agent)))))

;;; ============================================================
;;; 示例 6：流式执行
;;; ============================================================

(defun example-6-streaming-execution ()
  "Agent 流式执行"
  (format t "~%=== Example 6: Streaming Execution ===~%")

  ;; 创建工作流图
  (let ((graph (make-graph :name "streaming-workflow")))

    ;; 添加节点
    (add-node graph :step1
               (lambda (state)
                 (format t "  [Step 1] Processing...~%")
                 (state-set state :count 1)))

    (add-node graph :step2
               (lambda (state)
                 (format t "  [Step 2] Processing...~%")
                 (let ((count (state-get state :count)))
                   (state-set state :count (1+ count)))))

    (add-node graph :step3
               (lambda (state)
                 (format t "  [Step 3] Processing...~%")
                 (let ((count (state-get state :count)))
                   (state-set state :count (1+ count)))))

    (add-edge graph :step1 :step2)
    (add-edge graph :step2 :step3)
    (set-entry-point graph :step1)

    ;; 创建 LLM 客户端
    (let ((llm-client (cl-agent.llm:make-client
                       :provider :anthropic
                       :api-key (cl-agent.core:get-env "ANTHROPIC_API_KEY"))))

      ;; 创建图 Agent
      (let ((agent (make-graph-agent
                     :name "streaming-agent"
                     :llm-client llm-client
                     :graph graph)))

        ;; 流式执行
        (format t "~%Streaming execution:~%")
        (graph-agent-run-stream
         agent
         "input"
         (lambda (node-id state)
           (format t "  [Callback] After ~A: count = ~A~%"
                   node-id
                   (state-get state :count 0)))
         :verbose t)))))

;;; ============================================================
;;; 示例 7：Agent 批量处理
;;; ============================================================

(defun example-7-batch-processing ()
  "Agent 批量处理"
  (format t "~%=== Example 7: Batch Processing ===~%")

  ;; 创建 LLM 客户端
  (let ((llm-client (cl-agent.llm:make-client
                     :provider :anthropic
                     :api-key (cl-agent.core:get-env "ANTHROPIC_API_KEY"))))

    ;; 创建简单 Agent
    (let ((agent (quick-agent
                   :llm-client llm-client
                   :system-prompt "You are a helpful assistant.")))

      ;; 批量对话
      (let ((messages '("Hello"
                        "How are you?"
                        "What can you do?"
                        "Thank you")))

        (format t "~%Batch processing ~A messages:~%" (length messages))
        (let ((responses (agent-batch-chat agent messages
                                            :verbose nil)))
          (loop for msg in messages
                for resp in responses
                do (format t "  Q: ~A~%  A: ~A~%~%" msg (subseq resp 0 (min 50 (length resp))))))))))

;;; ============================================================
;;; 示例 8：Agent 序列化
;;; ============================================================

(defun example-8-agent-serialization ()
  "Agent 序列化"
  (format t "~%=== Example 8: Agent Serialization ===~%")

  ;; 创建 Agent
  (let ((agent (make-agent
                 :name "serializable-agent"
                 :system-prompt "You are a helpful assistant."
                 :max-iterations 10
                 :tools '(:search :calculator))))

    ;; 转换为 plist
    (let ((plist (agent-to-plist agent)))
      (format t "~%Agent plist:~%")
      (format t "  Name: ~A~%" (getf plist :name))
      (format t "  Max Iterations: ~A~%" (getf plist :max-iterations))
      (format t "  Tools: ~A~%" (getf plist :tools)))

    ;; 转换为 JSON
    (let ((json (agent-to-json agent)))
      (format t "~%Agent JSON:~%~A~%" json))))

;;; ============================================================
;;; 示例 9：Agent 验证
;;; ============================================================

(defun example-9-agent-validation ()
  "Agent 验证"
  (format t "~%=== Example 9: Agent Validation ===~%")

  ;; 创建有效 Agent
  (let ((llm-client (cl-agent.llm:make-client
                     :provider :anthropic
                     :api-key (cl-agent.core:get-env "ANTHROPIC_API_KEY"))))

    (let ((valid-agent (make-agent
                         :name "valid-agent"
                         :llm-client llm-client
                         :tools '(:search)))

          (invalid-agent (make-agent
                           :name "invalid-agent"
                           :llm-client nil)))

      ;; 验证有效 Agent
      (format t "~%Valid Agent:~%")
      (multiple-value-bind (valid-p errors)
          (validate-agent valid-agent)
        (format t "  Valid: ~A~%" valid-p)
        (when errors
          (format t "  Errors: ~A~%" errors)))

      ;; 验证无效 Agent
      (format t "~%Invalid Agent:~%")
      (multiple-value-bind (valid-p errors)
          (validate-agent invalid-agent)
        (format t "  Valid: ~A~%" valid-p)
        (when errors
          (format t "  Errors: ~A~%" errors))))))

;;; ============================================================
;;; 示例 10：Agent 状态管理
;;; ============================================================

(defun example-10-agent-state-management ()
  "Agent 状态管理"
  (format t "~%=== Example 10: Agent State Management ===~%")

  ;; 创建 Agent
  (let ((llm-client (cl-agent.llm:make-client
                     :provider :anthropic
                     :api-key (cl-agent.core:get-env "ANTHROPIC_API_KEY"))))

    (let ((agent (make-agent
                   :name "state-agent"
                   :llm-client llm-client)))

      ;; 设置状态
      (format t "~%Setting agent state:~%")
      (agent-set-state agent :session-id "12345")
      (agent-set-state agent :user-name "Alice")

      ;; 批量更新状态
      (agent-update-state agent
                          :email "alice@example.com"
                          :preferences '(:theme :dark))

      ;; 读取状态
      (format t "~%Reading agent state:~%")
      (format t "  Session ID: ~A~%" (agent-get-state agent :session-id))
      (format t "  User Name: ~A~%" (agent-get-state agent :user-name))
      (format t "  Email: ~A~%" (agent-get-state agent :email))
      (format t "  Preferences: ~A~%" (agent-get-state agent :preferences))

      ;; 打印状态信息
      (format t "~%Agent state info:~%")
      (state-print (agent-state agent)))))

;;; ============================================================
;;; 运行所有示例
;;; ============================================================

(defun run-agent-examples ()
  "运行所有 Agent 示例"
  (format t "~%========================================")
  (format t "~%  CL-Agent Agent Examples")
  (format t "~%========================================")

  (example-1-basic-agent)
  ;; (example-2-react-agent)  ; 需要工具系统
  (example-3-graph-agent)
  (example-4-chain-agent)
  (example-5-execution-tracking)
  (example-6-streaming-execution)
  (example-7-batch-processing)
  (example-8-agent-serialization)
  (example-9-agent-validation)
  (example-10-agent-state-management)

  (format t "~%========================================")
  (format t "~%  All agent examples completed!")
  (format t "~%========================================~%"))

;; 运行示例（取消注释）
;; (run-agent-examples)
