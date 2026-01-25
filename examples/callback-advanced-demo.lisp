;;;; callback-advanced-demo.lisp
;;;;
;;;; 演示 LangChain 风格的 Callback 高级功能
;;;;
;;;; 包含：
;;;; 1. Run ID 追踪 (with-callback-context)
;;;; 2. 自动上下文注入 (callback-emit-with-context)
;;;; 3. 成本追踪 (cost-tracking-handler)
;;;; 4. 多处理器组合
;;;; 5. 嵌套执行追踪

(in-package :cl-agent)

;;; ============================================================================
;;; 示例 1: 基本 Run ID 追踪
;;; ============================================================================

(defun demo-basic-run-tracking ()
  "演示基本的 Run ID 追踪功能"
  (format t "~%=== Demo 1: Basic Run Tracking ===~%")

  (let ((handler (make-logging-handler :name "tracker")))
    ;; 创建一个 callback context
    (with-callback-context (:run-type :agent
                            :run-name "my-agent"
                            :tags '("demo" "test"))

      ;; 使用 callback-emit-with-context 自动注入 run-id
      (callback-emit-with-context handler :on-agent-action
                                  :action "thinking"
                                  :input "What is 2+2?")

      (callback-emit-with-context handler :on-llm-start
                                  :model "gpt-4"
                                  :prompt "Calculate 2+2")

      (callback-emit-with-context handler :on-llm-end
                                  :response "4"
                                  :tokens 10)

      (callback-emit-with-context handler :on-agent-finish
                                  :result "The answer is 4"))))

;;; ============================================================================
;;; 示例 2: 嵌套执行追踪
;;; ============================================================================

(defun demo-nested-run-tracking ()
  "演示嵌套执行的 parent-run-id 追踪"
  (format t "~%=== Demo 2: Nested Run Tracking ===~%")

  (let ((handler (make-logging-handler :name "nested-tracker")))
    ;; 外层：Agent 执行
    (with-callback-context (:run-type :agent
                            :run-name "main-agent")

      (callback-emit-with-context handler :on-agent-action
                                  :action "start")

      ;; 内层：Chain 执行
      (with-callback-context (:run-type :chain
                              :run-name "reasoning-chain")

        (callback-emit-with-context handler :on-chain-start
                                    :input "reasoning task")

        ;; 更内层：LLM 调用
        (with-callback-context (:run-type :llm
                                :run-name "gpt-4-call")

          (callback-emit-with-context handler :on-llm-start
                                      :model "gpt-4"
                                      :prompt "Think step by step")

          (callback-emit-with-context handler :on-llm-end
                                      :response "Step 1..."
                                      :tokens 50))

        (callback-emit-with-context handler :on-chain-end
                                    :output "reasoning complete"))

      (callback-emit-with-context handler :on-agent-finish
                                  :result "done"))))

;;; ============================================================================
;;; 示例 3: 成本追踪处理器
;;; ============================================================================

(defun demo-cost-tracking ()
  "演示成本追踪功能"
  (format t "~%=== Demo 3: Cost Tracking ===~%")

  (let ((cost-handler (make-cost-tracking-handler :name "cost-tracker")))

    ;; 模拟多次 LLM 调用
    (with-callback-context (:run-type :agent :run-name "multi-llm-agent")

      ;; GPT-4 调用
      (callback-emit-with-context cost-handler :on-llm-start
                                  :model "gpt-4"
                                  :prompt "Hello")
      (callback-emit-with-context cost-handler :on-llm-end
                                  :model "gpt-4"
                                  :input-tokens 10
                                  :output-tokens 20)

      ;; Claude 调用
      (callback-emit-with-context cost-handler :on-llm-start
                                  :model "claude-sonnet-4"
                                  :prompt "世界")
      (callback-emit-with-context cost-handler :on-llm-end
                                  :model "claude-sonnet-4"
                                  :input-tokens 15
                                  :output-tokens 25)

      ;; GLM-4.7 调用
      (callback-emit-with-context cost-handler :on-llm-start
                                  :model "glm-4.7"
                                  :prompt "你好")
      (callback-emit-with-context cost-handler :on-llm-end
                                  :model "glm-4.7"
                                  :input-tokens 5
                                  :output-tokens 10))

    ;; 打印成本报告
    (format t "~%--- Cost Report ---~%")
    (print-costs cost-handler)

    ;; 获取成本数据
    (let ((costs (handler-get-costs cost-handler)))
      (format t "~%Total cost: $~,4f~%"
              (reduce #'+ (mapcar #'cdr costs))))))

;;; ============================================================================
;;; 示例 4: 多处理器组合
;;; ============================================================================

(defun demo-multiple-handlers ()
  "演示组合多个处理器"
  (format t "~%=== Demo 4: Multiple Handlers ===~%")

  (let ((logging-handler (make-logging-handler :name "logger"))
        (metrics-handler (make-metrics-handler :name "metrics"))
        (cost-handler (make-cost-tracking-handler :name "cost")))

    ;; 定义一个函数来广播事件到所有处理器
    (flet ((broadcast (event-type &rest data)
             (apply #'callback-emit-with-context logging-handler event-type data)
             (apply #'callback-emit-with-context metrics-handler event-type data)
             (apply #'callback-emit-with-context cost-handler event-type data)))

      (with-callback-context (:run-type :agent
                              :run-name "multi-handler-demo")

        (broadcast :on-agent-action :action "start")

        (broadcast :on-llm-start
                   :model "gpt-4"
                   :prompt "Hello world")

        (broadcast :on-llm-end
                   :model "gpt-4"
                   :response "Hi there!"
                   :input-tokens 10
                   :output-tokens 5)

        (broadcast :on-agent-finish :result "complete")))

    ;; 打印各处理器的统计
    (format t "~%--- Logging Handler ---~%")
    (print-handler-stats logging-handler)

    (format t "~%--- Metrics Handler ---~%")
    (print-handler-stats metrics-handler)

    (format t "~%--- Cost Handler ---~%")
    (print-costs cost-handler)))

;;; ============================================================================
;;; 示例 5: 流式 Token 追踪
;;; ============================================================================

(defun demo-stream-tracking ()
  "演示流式 token 追踪"
  (format t "~%=== Demo 5: Stream Tracking ===~%")

  (let ((handler (make-logging-handler :name "stream-tracker")))

    (with-callback-context (:run-type :llm
                            :run-name "streaming-llm")

      (callback-emit-with-context handler :on-llm-start
                                  :model "gpt-4"
                                  :prompt "Write a poem"
                                  :stream t)

      ;; 模拟流式 token 生成
      (let ((tokens '("Once" " upon" " a" " time" "..." "\n"
                      "In" " a" " land" " far" " away")))
        (loop for token in tokens
              for index from 0
              do (callback-emit-with-context handler :on-llm-stream
                                            :token token
                                            :index index
                                            :accumulated (format nil "~{~A~}"
                                                               (subseq tokens 0 (1+ index))))))

      (callback-emit-with-context handler :on-llm-end
                                  :response "Once upon a time...\nIn a land far away"
                                  :input-tokens 10
                                  :output-tokens 15))))

;;; ============================================================================
;;; 示例 6: 检索器追踪
;;; ============================================================================

(defun demo-retriever-tracking ()
  "演示检索器追踪"
  (format t "~%=== Demo 6: Retriever Tracking ===~%")

  (let ((handler (make-logging-handler :name "retriever-tracker")))

    (with-callback-context (:run-type :retriever
                            :run-name "semantic-search")

      (callback-emit-with-context handler :on-retriever-start
                                  :query "machine learning"
                                  :top-k 5)

      ;; 模拟检索结果
      (let ((results '((:doc "ML is..." :score 0.95)
                       (:doc "Deep learning..." :score 0.89)
                       (:doc "Neural networks..." :score 0.85))))
        (callback-emit-with-context handler :on-retriever-end
                                    :results results
                                    :count (length results)))

      ;; 在检索后进行 LLM 调用
      (with-callback-context (:run-type :llm
                              :run-name "answer-generation")

        (callback-emit-with-context handler :on-llm-start
                                    :model "gpt-4"
                                    :prompt "Based on context, answer...")

        (callback-emit-with-context handler :on-llm-end
                                    :response "Machine learning is..."
                                    :input-tokens 100
                                    :output-tokens 50)))))

;;; ============================================================================
;;; 示例 7: 错误追踪
;;; ============================================================================

(defun demo-error-tracking ()
  "演示错误追踪"
  (format t "~%=== Demo 7: Error Tracking ===~%")

  (let ((handler (make-logging-handler :name "error-tracker")))

    (with-callback-context (:run-type :agent
                            :run-name "error-prone-agent")

      (callback-emit-with-context handler :on-agent-action
                                  :action "risky-operation")

      ;; 模拟工具调用失败
      (with-callback-context (:run-type :tool
                              :run-name "api-call")

        (callback-emit-with-context handler :on-tool-start
                                    :tool-name "external-api"
                                    :input {:query "test"})

        (callback-emit-with-context handler :on-tool-error
                                    :tool-name "external-api"
                                    :error "Connection timeout"
                                    :error-type :timeout))

      ;; Agent 尝试恢复
      (callback-emit-with-context handler :on-agent-action
                                  :action "retry-with-fallback")

      ;; 最终成功
      (callback-emit-with-context handler :on-agent-finish
                                  :result "completed with fallback"
                                  :status :partial-success))))

;;; ============================================================================
;;; 示例 8: 自定义处理器与 Run ID
;;; ============================================================================

(defun make-custom-handler-with-run-tracking ()
  "创建一个自定义处理器，利用 Run ID 进行追踪"
  (let ((run-logs (make-hash-table :test 'equal)))  ; run-id -> logs

    (make-callback-handler
     :name "custom-run-tracker"

     :on-agent-action
     (lambda (handler &key run-id action &allow-other-keys)
       (push (format nil "[~A] Action: ~A" run-id action)
             (gethash run-id run-logs)))

     :on-llm-start
     (lambda (handler &key run-id model prompt &allow-other-keys)
       (push (format nil "[~A] LLM Start: ~A - ~A" run-id model prompt)
             (gethash run-id run-logs)))

     :on-llm-end
     (lambda (handler &key run-id response &allow-other-keys)
       (push (format nil "[~A] LLM End: ~A" run-id response)
             (gethash run-id run-logs)))

     :on-agent-finish
     (lambda (handler &key run-id result &allow-other-keys)
       (push (format nil "[~A] Finish: ~A" run-id result)
             (gethash run-id run-logs))

       ;; 打印该 run 的所有日志
       (format t "~%--- Run Log for ~A ---~%" run-id)
       (dolist (log (reverse (gethash run-id run-logs)))
         (format t "~A~%" log))))))

(defun demo-custom-handler ()
  "演示自定义处理器"
  (format t "~%=== Demo 8: Custom Handler with Run Tracking ===~%")

  (let ((handler (make-custom-handler-with-run-tracking)))

    (with-callback-context (:run-type :agent
                            :run-name "custom-demo")

      (callback-emit-with-context handler :on-agent-action
                                  :action "start")

      (callback-emit-with-context handler :on-llm-start
                                  :model "gpt-4"
                                  :prompt "Hello")

      (callback-emit-with-context handler :on-llm-end
                                  :response "Hi!")

      (callback-emit-with-context handler :on-agent-finish
                                  :result "done"))))

;;; ============================================================================
;;; 运行所有示例
;;; ============================================================================

(defun run-all-demos ()
  "运行所有 callback 示例"
  (format t "~%╔════════════════════════════════════════╗~%")
  (format t "║  Advanced Callback System Demos       ║~%")
  (format t "╚════════════════════════════════════════╝~%")

  (demo-basic-run-tracking)
  (demo-nested-run-tracking)
  (demo-cost-tracking)
  (demo-multiple-handlers)
  (demo-stream-tracking)
  (demo-retriever-tracking)
  (demo-error-tracking)
  (demo-custom-handler)

  (format t "~%~%All demos completed!~%"))

;;; ============================================================================
;;; 使用说明
;;; ============================================================================

#|

快速开始：

1. 加载文件
   (load "callback-advanced-demo.lisp")

2. 运行所有示例
   (run-all-demos)

3. 运行单个示例
   (demo-basic-run-tracking)
   (demo-cost-tracking)
   (demo-nested-run-tracking)
   ...

核心概念：

1. Run ID 追踪
   - 每个 callback context 自动生成唯一的 run-id
   - 嵌套 context 时，子 context 记录 parent-run-id
   - 用于关联整个执行链路的所有事件

2. callback-emit-with-context
   - 自动注入 run-id, parent-run-id, timestamp
   - 无需手动管理这些元数据

3. with-callback-context 宏
   - 创建作用域内的执行上下文
   - 支持嵌套，自动维护父子关系
   - 可携带 metadata 和 tags

4. 成本追踪处理器
   - 自动计算不同模型的 API 成本
   - 支持 12+ 主流模型
   - 可自定义模型成本

5. 多处理器组合
   - 可同时使用多个处理器
   - 每个处理器独立工作
   - 适合分离关注点（日志/指标/成本）

实际应用场景：

1. 调试复杂的 Agent 执行流程
2. 监控生产环境的 LLM 调用成本
3. 性能分析和瓶颈定位
4. 审计和合规追踪
5. 用户行为分析

|#
