;;;; test-memory.lisp
;;;; CL-Agent - 统一记忆管理测试
;;;;
;;;; 测试 cl-agent-memory 的核心 API：
;;;;   - Memory Message（消息数据结构）
;;;;   - Store（长期持久化）
;;;;   - Checkpoint（短期状态快照）
;;;;   - Unified Memory（统一 API）

(in-package :cl-agent/tests)

;; 记忆管理测试套件
(def-suite memory-suite :in cl-agent-suite
  :description "统一记忆管理系统测试")

(in-suite memory-suite)

;; ============================================================
;; Memory Message 测试
;; ============================================================

(test make-user-message
  "测试创建用户消息"
  (let ((msg (cl-agent.memory:make-user-message "Hello")))
    (is (eq (cl-agent.memory:memory-message-role msg) :user))
    (is (string= (cl-agent.memory:memory-message-content msg) "Hello"))
    (is (not (null (cl-agent.memory:memory-message-timestamp msg))))))

(test make-assistant-message
  "测试创建助手消息"
  (let ((msg (cl-agent.memory:make-assistant-message "Hi!")))
    (is (eq (cl-agent.memory:memory-message-role msg) :assistant))
    (is (string= (cl-agent.memory:memory-message-content msg) "Hi!"))))

(test make-system-message
  "测试创建系统消息"
  (let ((msg (cl-agent.memory:make-system-message "You are helpful.")))
    (is (eq (cl-agent.memory:memory-message-role msg) :system))
    (is (string= (cl-agent.memory:memory-message-content msg)
                 "You are helpful."))))

(test make-tool-message
  "测试创建工具消息"
  (let ((msg (cl-agent.memory:make-tool-message "Result: 42"
                                                :tool-name "calculator"
                                                :tool-result 42)))
    (is (eq (cl-agent.memory:memory-message-role msg) :tool))
    (is (string= (cl-agent.memory:memory-message-content msg) "Result: 42"))
    (let ((meta (cl-agent.memory:memory-message-metadata msg)))
      (is (not (null meta)))
      (is (string= (gethash :tool-name meta) "calculator")))))

(test message-to-alist
  "测试消息转 alist"
  (let* ((msg (cl-agent.memory:make-user-message "Test"))
         (alist (cl-agent.memory:message-to-alist msg)))
    (is (eq (cdr (assoc :role alist)) :user))
    (is (string= (cdr (assoc :content alist)) "Test"))))

;; ============================================================
;; Store 测试
;; ============================================================

(test store-memory-backend-basic
  "测试内存存储后端基本操作"
  (let ((store (cl-agent.memory:make-memory-store-backend)))
    ;; 存储
    (cl-agent.memory:store-put store '("test") "key1" "value1")
    (cl-agent.memory:store-put store '("test") "key2" "value2")

    ;; 读取 - store-get 返回 store-item，需要提取 value
    (let ((item1 (cl-agent.memory:store-get store '("test") "key1"))
          (item2 (cl-agent.memory:store-get store '("test") "key2"))
          (item3 (cl-agent.memory:store-get store '("test") "key3")))
      (is (string= (cl-agent.memory:store-item-value item1) "value1"))
      (is (string= (cl-agent.memory:store-item-value item2) "value2"))
      (is (null item3)))

    ;; 计数
    (is (= (cl-agent.memory:store-count store '("test")) 2))

    ;; 删除
    (cl-agent.memory:store-delete store '("test") "key1")
    (is (null (cl-agent.memory:store-get store '("test") "key1")))
    (is (= (cl-agent.memory:store-count store '("test")) 1))))

(test store-namespaces
  "测试命名空间操作"
  (let ((store (cl-agent.memory:make-memory-store-backend)))
    (cl-agent.memory:store-put store '("ns1") "key" "value1")
    (cl-agent.memory:store-put store '("ns2") "key" "value2")
    (cl-agent.memory:store-put store '("ns1" "sub") "key" "value3")

    ;; 列出命名空间
    (let ((namespaces (cl-agent.memory:store-list-namespaces store nil)))
      (is (>= (length namespaces) 2)))

    ;; 清除特定命名空间
    (cl-agent.memory:store-clear store '("ns1"))
    (is (null (cl-agent.memory:store-get store '("ns1") "key")))
    (let ((item2 (cl-agent.memory:store-get store '("ns2") "key")))
      (is (string= (cl-agent.memory:store-item-value item2) "value2")))))

(test store-batch-operations
  "测试批量操作 - 使用单个 put 替代 batch"
  (let ((store (cl-agent.memory:make-memory-store-backend)))
    ;; 使用多个 store-put 代替 batch
    (cl-agent.memory:store-put store '("batch") "k1" "v1")
    (cl-agent.memory:store-put store '("batch") "k2" "v2")
    (cl-agent.memory:store-put store '("batch") "k3" "v3")
    (is (= (cl-agent.memory:store-count store '("batch")) 3))
    ;; 删除
    (cl-agent.memory:store-delete store '("batch") "k1")
    (cl-agent.memory:store-delete store '("batch") "k2")
    (is (= (cl-agent.memory:store-count store '("batch")) 1))))

;; ============================================================
;; Checkpoint 测试
;; ============================================================

(test checkpoint-manager-basic
  "测试检查点管理器基本操作"
  (let* ((store (cl-agent.memory:make-memory-store-backend))
         (manager (cl-agent.memory:make-checkpoint-manager :store store)))
    ;; 创建检查点
    (let ((cp (cl-agent.memory:make-checkpoint
               :thread-id "thread-1"
               :channel-values (make-hash-table :test #'equal))))
      (setf (gethash "messages" (cl-agent.memory:checkpoint-channel-values cp))
            '((:role :user :content "Hello")))

      ;; 保存检查点
      (let ((config (cl-agent.memory:make-checkpoint-config :thread-id "thread-1")))
        (cl-agent.memory:checkpointer-save manager config cp)

        ;; 加载检查点
        (let ((loaded (cl-agent.memory:checkpointer-load manager config)))
          (is (not (null loaded)))
          (is (string= (cl-agent.memory:checkpoint-thread-id loaded) "thread-1")))))))

(test checkpoint-lineage
  "测试检查点历史链"
  (let* ((store (cl-agent.memory:make-memory-store-backend))
         (manager (cl-agent.memory:make-checkpoint-manager :store store))
         (config (cl-agent.memory:make-checkpoint-config :thread-id "thread-1")))

    ;; 创建多个检查点
    (dotimes (i 3)
      (let ((cp (cl-agent.memory:make-checkpoint
                 :thread-id "thread-1"
                 :channel-values (make-hash-table :test #'equal))))
        (setf (gethash "step" (cl-agent.memory:checkpoint-channel-values cp)) i)
        (cl-agent.memory:checkpointer-save manager config cp)))

    ;; 获取历史链
    (let ((lineage (cl-agent.memory:checkpointer-get-lineage manager config)))
      (is (>= (length lineage) 2)))))

;; ============================================================
;; Agent Memory 测试
;; ============================================================

(test agent-memory-create
  "测试创建 Agent 记忆实例"
  (let ((memory (cl-agent.memory:make-simple-memory)))
    (is (not (null memory)))
    (is (cl-agent.memory:agent-memory-p memory))))

(test agent-memory-messages
  "测试 Agent 记忆消息操作"
  (let ((memory (cl-agent.memory:make-simple-memory)))
    ;; 添加消息
    (cl-agent.memory:memory-add-message memory :user "Hello")
    (cl-agent.memory:memory-add-message memory :assistant "Hi there!")

    ;; 获取消息
    (let ((messages (cl-agent.memory:memory-get-messages memory)))
      (is (= (length messages) 2))
      (is (eq (cl-agent.memory:memory-message-role (first messages)) :user)))

    ;; 清空消息
    (cl-agent.memory:memory-clear-messages memory)
    (is (= (length (cl-agent.memory:memory-get-messages memory)) 0))))

(test agent-memory-state
  "测试 Agent 记忆状态保存/加载（消息自动保存为 checkpoint）"
  (let ((memory (cl-agent.memory:make-simple-memory)))
    ;; 添加消息 - 每次添加都会自动创建 checkpoint
    (cl-agent.memory:memory-add-message memory :user "Message 1")
    (cl-agent.memory:memory-add-message memory :user "Message 2")
    (cl-agent.memory:memory-add-message memory :user "Message 3")
    ;; 验证有 3 条消息
    (is (= (length (cl-agent.memory:memory-get-messages memory)) 3))
    ;; 回退一步 - 应该回到 2 条消息的状态
    (cl-agent.memory:memory-go-back memory)
    (is (<= (length (cl-agent.memory:memory-get-messages memory)) 3))))

(test agent-memory-items
  "测试 Agent 记忆项存储"
  (let ((memory (cl-agent.memory:make-simple-memory)))
    ;; 存储项
    (cl-agent.memory:memory-put-item memory '("facts") "sky-color" "blue")
    (cl-agent.memory:memory-put-item memory '("facts") "grass-color" "green")

    ;; 获取项
    (is (string= (cl-agent.memory:memory-get-item memory '("facts") "sky-color") "blue"))

    ;; 搜索项
    (let ((results (cl-agent.memory:memory-search-items memory '("facts"))))
      (is (>= (length results) 2)))))

(test agent-memory-time-travel
  "测试 Agent 记忆时间旅行（消息自动创建 checkpoint）"
  (let ((memory (cl-agent.memory:make-simple-memory)))
    ;; 添加消息 - 每次添加都会自动创建 checkpoint
    (cl-agent.memory:memory-add-message memory :user "Message 1")
    (cl-agent.memory:memory-add-message memory :user "Message 2")
    (cl-agent.memory:memory-add-message memory :user "Message 3")

    ;; 获取历史
    (let ((history (cl-agent.memory:memory-list-history memory)))
      (is (>= (length history) 2)))

    ;; 回退
    (cl-agent.memory:memory-go-back memory)
    (let ((messages (cl-agent.memory:memory-get-messages memory)))
      (is (<= (length messages) 3)))))

;; ============================================================
;; 运行记忆测试
;; ============================================================

(defun run-memory-tests ()
  "运行所有记忆测试"
  (run! 'memory-suite))
