;;;; test-checkpoint.lisp
;;;; CL-Agent Tests - Checkpoint（cl-agent-extra）
;;;;
;;;; 测试 Store 协议 + 内存后端 + Checkpoint 管理（谱系/时间旅行）

(in-package :cl-agent/tests)

(def-suite checkpoint-suite
  :description "Checkpoint module test suite"
  :in cl-agent-suite)

(in-suite checkpoint-suite)

;;; ============================================================
;;; Store Backend 测试
;;; ============================================================

(test store-memory-backend-basic
  "测试内存存储后端基本操作"
  (let ((store (cl-agent.checkpoint:make-memory-store-backend)))
    ;; 存储
    (cl-agent.checkpoint:store-put store '("test") "key1" "value1")
    (cl-agent.checkpoint:store-put store '("test") "key2" "value2")

    ;; 读取 - store-get 返回 store-item，需要提取 value
    (let ((item1 (cl-agent.checkpoint:store-get store '("test") "key1"))
          (item2 (cl-agent.checkpoint:store-get store '("test") "key2"))
          (item3 (cl-agent.checkpoint:store-get store '("test") "key3")))
      (is (string= (cl-agent.checkpoint:store-item-value item1) "value1"))
      (is (string= (cl-agent.checkpoint:store-item-value item2) "value2"))
      (is (null item3)))

    ;; 计数
    (is (= (cl-agent.checkpoint:store-count store '("test")) 2))

    ;; 删除
    (cl-agent.checkpoint:store-delete store '("test") "key1")
    (is (null (cl-agent.checkpoint:store-get store '("test") "key1")))
    (is (= (cl-agent.checkpoint:store-count store '("test")) 1))))

(test store-namespaces
  "测试命名空间操作"
  (let ((store (cl-agent.checkpoint:make-memory-store-backend)))
    (cl-agent.checkpoint:store-put store '("ns1") "key" "value1")
    (cl-agent.checkpoint:store-put store '("ns2") "key" "value2")
    (cl-agent.checkpoint:store-put store '("ns1" "sub") "key" "value3")

    ;; 列出命名空间
    (let ((namespaces (cl-agent.checkpoint:store-list-namespaces store nil)))
      (is (>= (length namespaces) 2)))

    ;; 清除特定命名空间
    (cl-agent.checkpoint:store-clear store '("ns1"))
    (is (null (cl-agent.checkpoint:store-get store '("ns1") "key")))
    (let ((item2 (cl-agent.checkpoint:store-get store '("ns2") "key")))
      (is (string= (cl-agent.checkpoint:store-item-value item2) "value2")))))

(test store-batch-operations
  "测试批量操作 - 使用单个 put 替代 batch"
  (let ((store (cl-agent.checkpoint:make-memory-store-backend)))
    ;; 使用多个 store-put 代替 batch
    (cl-agent.checkpoint:store-put store '("batch") "k1" "v1")
    (cl-agent.checkpoint:store-put store '("batch") "k2" "v2")
    (cl-agent.checkpoint:store-put store '("batch") "k3" "v3")
    (is (= (cl-agent.checkpoint:store-count store '("batch")) 3))
    ;; 删除
    (cl-agent.checkpoint:store-delete store '("batch") "k1")
    (cl-agent.checkpoint:store-delete store '("batch") "k2")
    (is (= (cl-agent.checkpoint:store-count store '("batch")) 1))))

;; ============================================================
;; Checkpoint 测试
;; ============================================================

(test checkpoint-manager-basic
  "测试检查点管理器基本操作"
  (let* ((store (cl-agent.checkpoint:make-memory-store-backend))
         (manager (cl-agent.checkpoint:make-checkpoint-manager :store store)))
    ;; 创建检查点
    (let ((cp (cl-agent.checkpoint:make-checkpoint
               :thread-id "thread-1"
               :channel-values (make-hash-table :test #'equal))))
      (setf (gethash "messages" (cl-agent.checkpoint:checkpoint-channel-values cp))
            '((:role :user :content "Hello")))

      ;; 保存检查点
      (let ((config (cl-agent.checkpoint:make-checkpoint-config :thread-id "thread-1")))
        (cl-agent.checkpoint:checkpointer-save manager config cp)

        ;; 加载检查点
        (let ((loaded (cl-agent.checkpoint:checkpointer-load manager config)))
          (is (not (null loaded)))
          (is (string= (cl-agent.checkpoint:checkpoint-thread-id loaded) "thread-1")))))))

(test checkpoint-lineage
  "测试检查点历史链"
  (let* ((store (cl-agent.checkpoint:make-memory-store-backend))
         (manager (cl-agent.checkpoint:make-checkpoint-manager :store store))
         (config (cl-agent.checkpoint:make-checkpoint-config :thread-id "thread-1")))

    ;; 创建多个检查点
    (dotimes (i 3)
      (let ((cp (cl-agent.checkpoint:make-checkpoint
                 :thread-id "thread-1"
                 :channel-values (make-hash-table :test #'equal))))
        (setf (gethash "step" (cl-agent.checkpoint:checkpoint-channel-values cp)) i)
        (cl-agent.checkpoint:checkpointer-save manager config cp)))

    ;; 获取历史链
    (let ((lineage (cl-agent.checkpoint:checkpointer-get-lineage manager config)))
      (is (>= (length lineage) 2)))))

;; ============================================================
;; Agent Memory 测试
;; ============================================================
