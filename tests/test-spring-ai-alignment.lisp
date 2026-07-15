;;;; test-spring-ai-alignment.lisp
;;;; CL-Agent - Spring AI 2.0 对齐审计测试（P5）

(in-package :cl-agent/tests)

(def-suite alignment-suite :in cl-agent-suite
  :description "Spring AI 2.0 全量对齐审计：所有 10 个 filter 类型可构造且可调用")

(in-suite alignment-suite)

(test all-filter-types-constructable
  "验证全部 10 个 filter 工厂函数可调用且返回 filter 实例"
  ;; 1. memory-filter
  (let ((f (cl-agent.kernel:memory-filter
            (cl-agent.chat:make-message-window-chat-memory))))
    (is (typep f 'cl-agent.kernel:filter))
    (is (not (null (cl-agent.kernel:filter-chat-hook f)))))

  ;; 2. logging-chat-filter
  (let ((f (cl-agent.kernel:logging-chat-filter)))
    (is (typep f 'cl-agent.kernel:filter))
    (is (not (null (cl-agent.kernel:filter-chat-hook f)))))

  ;; 3. logging-tool-filter
  (let ((f (cl-agent.kernel:logging-tool-filter)))
    (is (typep f 'cl-agent.kernel:filter))
    (is (not (null (cl-agent.kernel:filter-tool-hook f)))))

  ;; 4. safeguard-turn-filter
  (let ((f (cl-agent.kernel:safeguard-turn-filter '("bomb" "hack"))))
    (is (typep f 'cl-agent.kernel:filter))
    (is (not (null (cl-agent.kernel:filter-turn-hook f)))))

  ;; 5. validation-turn-filter
  (let ((f (cl-agent.kernel:validation-turn-filter
            (lambda (resp) (values t nil)))))
    (is (typep f 'cl-agent.kernel:filter))
    (is (not (null (cl-agent.kernel:filter-turn-hook f)))))

  ;; 6. re-reading-filter
  (let ((f (cl-agent.kernel:re-reading-filter)))
    (is (typep f 'cl-agent.kernel:filter))
    (is (not (null (cl-agent.kernel:filter-turn-hook f)))))

  ;; 7. qa-turn-filter (需要一个 mock retriever)
  (let ((f (cl-agent.kernel:qa-turn-filter
            (make-instance 'mock-retriever))))
    (is (typep f 'cl-agent.kernel:filter))
    (is (not (null (cl-agent.kernel:filter-turn-hook f)))))

  ;; 8. tool-search-filter
  (let ((f (cl-agent.kernel:tool-search-filter
            (cl-agent.kernel:make-keyword-tool-index nil))))
    (is (typep f 'cl-agent.kernel:filter))
    (is (not (null (cl-agent.kernel:filter-chat-hook f)))))

  ;; 9. timeout-filter
  (let ((f (cl-agent.kernel:timeout-filter 5000)))
    (is (typep f 'cl-agent.kernel:filter))
    (is (not (null (cl-agent.kernel:filter-tool-hook f)))))

  ;; 10. approval-filter
  (let ((f (cl-agent.kernel:approval-filter
            :approve-fn (lambda (name args) (values t nil)))))
    (is (typep f 'cl-agent.kernel:filter))
    (is (not (null (cl-agent.kernel:filter-tool-hook f))))))

(test kernel-client-constructable
  "make-kernel-client 创建的 ChatClient 带 kernel 槽"
  (let* ((provider (make-seq-provider (text-response "hello")))
         (model (cl-agent.chat:make-provider-chat-model provider))
         (client (cl-agent.client:make-kernel-client
                  model
                  :filters (list (cl-agent.kernel:logging-chat-filter))
                  :tools nil)))
    (is (not (null (cl-agent.client:client-kernel client))))
    (is (typep (cl-agent.client:client-kernel client) 'cl-agent.kernel:kernel))))

(test kernel-client-executes-via-invoke-turn
  "kernel-backed ChatClient 通过 invoke-turn 执行（不走 advisor 链）"
  (let* ((provider (make-seq-provider (text-response "kernel works")))
         (model (cl-agent.chat:make-provider-chat-model provider))
         (client (cl-agent.client:make-kernel-client model)))
    (let ((result (cl-agent.client:chat client (:user "test"))))
      (is (string= "kernel works" result)))))

(test failure-classification-present
  "三故障分类条件类型可构造"
  (is (eq :semantic (cl-agent.kernel:tool-failure-class
                     (make-condition 'cl-agent.kernel:semantic-tool-failure))))
  (is (eq :transient (cl-agent.kernel:tool-failure-class
                      (make-condition 'cl-agent.kernel:transient-tool-failure))))
  (is (eq :environment (cl-agent.kernel:tool-failure-class
                        (make-condition 'cl-agent.kernel:environment-tool-failure)))))

(test classify-tool-error-basic
  "classify-tool-error 基本分类"
  (is (eq :transient
          (handler-case (error "connection timeout")
            (error (e) (cl-agent.kernel:classify-tool-error e)))))
  (is (eq :environment
          (handler-case (error "permission denied")
            (error (e) (cl-agent.kernel:classify-tool-error e)))))
  (is (eq :semantic
          (handler-case (error "something went wrong")
            (error (e) (cl-agent.kernel:classify-tool-error e))))))


;;; ============================================================
;;; Mock Retriever（qa-turn-filter 测试用）
;;; ============================================================

(defclass mock-retriever () ())

(defmethod cl-agent.kernel:retrieve ((r mock-retriever) query &key top-k)
  (declare (ignore query top-k))
  (list "doc1" "doc2"))
