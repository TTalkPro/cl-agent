;;;; workflow-usage.lisp
;;;; CL-Agent - 工作流使用示例

;; 加载系统
(asdf:load-system :cl-agent)

;; 使用包
(in-package :cl-user)
(use-package :cl-agent)

;;; ============================================================
;;; 示例 1：简单链式工作流
;;; ============================================================

(defun example-1-simple-chain ()
  "最简单的链式工作流"
  (format t "~%=== Example 1: Simple Chain ===~%")

  ;; 创建图
  (let ((graph (make-graph :name "simple-chain")))

    ;; 添加节点
    (add-node graph :step1
               (lambda (state)
                 (format t "  Step 1: Processing~%")
                 (state-set state :step1 "done")))

    (add-node graph :step2
               (lambda (state)
                 (format t "  Step 2: Processing~%")
                 (state-set state :step2 "done")))

    (add-node graph :step3
               (lambda (state)
                 (format t "  Step 3: Processing~%")
                 (state-set state :step3 "done")))

    ;; 添加边
    (add-edge graph :step1 :step2)
    (add-edge graph :step2 :step3)

    ;; 设置入口点
    (set-entry-point graph :step1)

    ;; 运行
    (let ((result (run-workflow graph (make-state :input "data")
                                    :verbose t)))
      (format t "~%Final state:~A~%" (state-keys result)))))

;;; ============================================================
;;; 示例 2：使用 DSL 定义工作流
;;; ============================================================

(defworkflow example-workflow-2
  "使用 DSL 定义的工作流"

  (node :start
        (lambda (state)
          (format t "  Start node~%")
          (state-set state :started t))
        :description "Start node")

  (node :process
        (lambda (state)
          (format t "  Process node~%")
          (state-set state :processed t))
        :description "Process node")

  (node :__end__
        (lambda (state)
          (format t "  End node~%")
          (state-set state :__end__ed t))
        :description "End node")

  (edge :start :process)
  (edge :process :__end__)
  (entrypoint :start))

(defun example-2-dsl-workflow ()
  "运行 DSL 定义的工作流"
  (format t "~%=== Example 2: DSL Workflow ===~%")

  (let ((result (invoke *example-workflow-2* (make-state :input "data")
                                           :verbose t)))
    (format t "~%Final state:~A~%" (state-keys result))))

;;; ============================================================
;;; 示例 3：条件分支工作流
;;; ============================================================

(defun example-3-conditional-workflow ()
  "条件分支工作流"
  (format t "~%=== Example 3: Conditional Workflow ===~%")

  (let ((graph (make-graph :name "conditional")))

    ;; 节点
    (add-node graph :check
               (lambda (state)
                 (format t "  Checking condition...~%")
                 (let ((value (state-get state :value)))
                   (state-set state :positive (> value 0)))))

    (add-node graph :positive-handler
               (lambda (state)
                 (format t "  Positive case~%")
                 (state-set state :result "positive")))

    (add-node graph :negative-handler
               (lambda (state)
                 (format t "  Negative case~%")
                 (state-set state :result "negative")))

    ;; 条件边
    (add-conditional-edge graph
                        :check
                        (lambda (state)
                          (if (state-get state :positive)
                              :positive-handler
                              :negative-handler))
                        :positive-handler
                        :negative-handler)

    (set-entry-point graph :check)

    ;; 测试正数情况
    (format t "~%Test positive value:~%")
    (let ((result1 (run-workflow graph (make-state :value 10)
                                     :verbose t)))
      (format t "Result: ~A~%" (state-get result1 :result)))

    ;; 测试负数情况
    (format t "~%Test negative value:~%")
    (let ((result2 (run-workflow graph (make-state :value -5)
                                     :verbose t)))
      (format t "Result: ~A~%" (state-get result2 :result)))))

;;; ============================================================
;;; 示例 4：并行执行工作流
;;; ============================================================

(defun example-4-parallel-workflow ()
  "并行执行工作流"
  (format t "~%=== Example 4: Parallel Workflow ===~%")

  (let ((graph (make-graph :name "parallel")))

    ;; 节点
    (add-node graph :split
               (lambda (state)
                 (format t "  Splitting work...~%")
                 (state-set state :items '(1 2 3 4 5))))

    (add-node graph :task1
               (lambda (state)
                 (format t "    Task 1 processing~%")
                 (sleep 0.5)
                 (state-set state :task1-result "done")))

    (add-node graph :task2
               (lambda (state)
                 (format t "    Task 2 processing~%")
                 (sleep 0.5)
                 (state-set state :task2-result "done")))

    (add-node graph :task3
               (lambda (state)
                 (format t "    Task 3 processing~%")
                 (sleep 0.5)
                 (state-set state :task3-result "done")))

    (add-node graph :aggregate
               (lambda (state)
                 (format t "  Aggregating results~%")
                 (state-set state :aggregated t)))

    ;; 边
    (add-edge graph :split :task1)
    (add-edge graph :split :task2)
    (add-edge graph :split :task3)
    (add-edge graph :task1 :aggregate)
    (add-edge graph :task2 :aggregate)
    (add-edge graph :task3 :aggregate)

    (set-entry-point graph :split)

    ;; 并行执行
    (let ((result (run-workflow graph (make-state :input "data")
                                    :mode :parallel
                                    :verbose t)))
      (format t "~%Aggregated: ~A~%" (state-get result :aggregated))))

;;; ============================================================
;;; 示例 5：循环工作流
;;; ============================================================

(defun example-5-loop-workflow ()
  "循环工作流"
  (format t "~%=== Example 5: Loop Workflow ===~%")

  (let ((graph (make-graph :name "loop")))

    ;; 节点
    (add-node graph :init
               (lambda (state)
                 (format t "  Initializing counter~%")
                 (state-set state :count 0)))

    (add-node graph :increment
               (lambda (state)
                 (let ((count (state-get state :count)))
                   (format t "  Incrementing: ~A -> ~A~%" count (1+ count))
                   (state-set state :count (1+ count)))))

    (add-node graph :check
               (lambda (state)
                 (let ((count (state-get state :count)))
                   (format t "  Checking: ~A < 5? ~A~%" count (< count 5))
                   state)))

    ;; 条件边
    (add-conditional-edge graph
                        :check
                        (lambda (state)
                          (let ((count (state-get state :count)))
                            (if (< count 5)
                                :increment
                                +__end__+)))
                        :increment
                        +__end__+)

    (add-edge graph :init :check)
    (add-edge graph :increment :check)

    (set-entry-point graph :init)

    ;; 运行
    (let ((result (run-workflow graph (make-state)
                                    :verbose t)))
      (format t "~%Final count: ~A~%" (state-get result :count)))))

;;; ============================================================
;;; 示例 6：链式模板
;;; ============================================================

(defun example-6-chain-template ()
  "使用链式模板"
  (format t "~%=== Example 6: Chain Template ===~%")

  (let ((chain (make-chain-graph
                :chain-name "my-chain"
                :steps '((:step1 . (lambda (s)
                                     (state-set s :a 1)))
                         (:step2 . (lambda (s)
                                     (state-set s :b 2)))
                         (:step3 . (lambda (s)
                                     (state-set s :c 3))))))))
    (graph-print chain)
    (let ((result (run-workflow chain (make-state))))
      (format t "~%Result: ~A~%" (state-to-plist result)))))

;;; ============================================================
;;; 示例 7：流式工作流执行
;;; ============================================================

(defun example-7-streaming-execution ()
  "流式工作流执行"
  (format t "~%=== Example 7: Streaming Execution ===~%")

  (let ((graph (make-graph :name "streaming")))

    (add-node graph :step1
               (lambda (state)
                 (format t "  Executing step1~%")
                 (state-set state :step1-result "result1")))

    (add-node graph :step2
               (lambda (state)
                 (format t "  Executing step2~%")
                 (state-set state :step2-result "result2")))

    (add-edge graph :step1 :step2)
    (set-entry-point graph :step1)

    ;; 流式执行
    (run-workflow-stream graph
                         (lambda (node-id state)
                           (format t "~&Callback after ~A: ~A keys~%"
                                   node-id (state-count state)))
                         (make-state)
                         :verbose t)))

;;; ============================================================
;;; 示例 8：工作流验证
;;; ============================================================

(defun example-8-workflow-validation ()
  "工作流验证"
  (format t "~%=== Example 8: Workflow Validation ===~%")

  ;; 创建有效图
  (let ((valid-graph (make-graph :name "valid")))
    (add-node valid-graph :node1 (lambda (s) s))
    (add-node valid-graph :node2 (lambda (s) s))
    (add-edge valid-graph :node1 :node2)
    (set-entry-point valid-graph :node1)

    (multiple-value-bind (valid-p errors) (validate-graph valid-graph)
      (format t "Valid graph: ~A~%" valid-p)
      (when errors
        (format t "Errors: ~A~%" errors))))

  ;; 创建无效图
  (let ((invalid-graph (make-graph :name "invalid")))
    ;; 没有节点
    (multiple-value-bind (valid-p errors) (validate-graph invalid-graph)
      (format t "~%Invalid graph: ~A~%" (not valid-p))
      (format t "Errors: ~A~%" errors))))

;;; ============================================================
;;; 示例 9：图可视化
;;; ============================================================

(defun example-9-graph-visualization ()
  "图可视化（Graphviz DOT 格式）"
  (format t "~%=== Example 9: Graph Visualization ===~%")

  (let ((graph (make-graph :name "visualization")))
    (add-node graph :A (lambda (s) s))
    (add-node graph :B (lambda (s) s))
    (add-node graph :C (lambda (s) s))
    (add-edge graph :A :B)
    (add-edge graph :B :C)
    (add-conditional-edge graph :B (lambda (s) :C) :C)
    (set-entry-point graph :A)

    (format t "~%DOT format:~%")
    (format t "~A~%" (graph-visualize graph))))

;;; ============================================================
;;; 示例 10：状态操作
;;; ============================================================

(defun example-10-state-operations ()
  "状态操作示例"
  (format t "~%=== Example 10: State Operations ===~%")

  ;; 创建状态
  (let ((state (make-state :a 1 :b 2)))
    (format t "Initial state:~%")
    (state-print state)

    ;; 更新状态
    (let ((new-state (state-set state :c 3)))
      (format t "After set:~%")
      (state-print new-state))

    ;; 批量更新
    (let ((updated-state (state-update state :d 4 :e 5)))
      (format t "After update:~%")
      (state-print updated-state))

    ;; 状态合并
    (let ((state1 (make-state :a 1 :b 2))
          (state2 (make-state :b 3 :c 4)))
      (let ((merged (state-merge state1 state2)))
        (format t "Merged state:~%")
        (state-print merged)))

    ;; 状态过滤
    (let ((filter-state (state-filter state
                                          (lambda (k v)
                                            (declare (ignore k))
                                            (evenp v)))))
      (format t "Filtered (even values):~%")
      (state-print filter-state))))

;;; ============================================================
;;; 运行所有示例
;;; ============================================================

(defun run-workflow-examples ()
  "运行所有工作流示例"
  (format t "~%========================================")
  (format t "~%  CL-Agent Workflow Examples")
  (format t "~%========================================")

  (example-1-simple-chain)
  (example-2-dsl-workflow)
  (example-3-conditional-workflow)
  (example-4-parallel-workflow)
  (example-5-loop-workflow)
  (example-6-chain-template)
  (example-7-streaming-execution)
  (example-8-workflow-validation)
  (example-9-graph-visualization)
  (example-10-state-operations)

  (format t "~%========================================")
  (format t "~%  All examples completed!")
  (format t "~%========================================~%"))

;; 运行示例（取消注释）
;; (run-workflow-examples)
