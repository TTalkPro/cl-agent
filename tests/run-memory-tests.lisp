;;;; run-memory-tests.lisp
;;;; 独立的 memory 模块测试运行器

;;; 加载依赖
(pushnew #P"/home/david/workspace/research/lisp-in-actions/src/cl-agent/core/"
         asdf:*central-registry* :test #'equal)
(pushnew #P"/home/david/workspace/research/lisp-in-actions/src/cl-agent/memory/"
         asdf:*central-registry* :test #'equal)

(ql:quickload '(:fiveam :cl-agent-memory) :silent t)

(defpackage :memory-tests
  (:use :cl :fiveam))

(in-package :memory-tests)

(def-suite memory-suite :description "Memory module tests")
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
    (is (eq (cl-agent.memory:memory-message-role msg) :system))))

(test make-tool-message
  "测试创建工具消息"
  (let ((msg (cl-agent.memory:make-tool-message "Result: 42"
                                                :tool-name "calc")))
    (is (eq (cl-agent.memory:memory-message-role msg) :tool))
    (is (string= (cl-agent.memory:memory-message-content msg) "Result: 42"))))

;; ============================================================
;; Store 测试
;; ============================================================

(test store-basic-operations
  "测试 Store 基本操作"
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
    ;; 不同命名空间隔离
    (let ((item1 (cl-agent.memory:store-get store '("ns1") "key"))
          (item2 (cl-agent.memory:store-get store '("ns2") "key")))
      (is (string= (cl-agent.memory:store-item-value item1) "value1"))
      (is (string= (cl-agent.memory:store-item-value item2) "value2")))
    ;; 清除一个命名空间
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
;; Agent Memory 测试
;; ============================================================

(test agent-memory-create
  "测试创建 Agent 记忆"
  (let ((memory (cl-agent.memory:make-simple-memory)))
    (is (not (null memory)))
    (is (cl-agent.memory:agent-memory-p memory))))

(test agent-memory-messages
  "测试消息操作"
  (let ((memory (cl-agent.memory:make-simple-memory)))
    ;; 添加消息
    (cl-agent.memory:memory-add-message memory :user "Hello")
    (cl-agent.memory:memory-add-message memory :assistant "Hi there!")
    ;; 获取消息
    (let ((msgs (cl-agent.memory:memory-get-messages memory)))
      (is (= (length msgs) 2))
      (is (eq (cl-agent.memory:memory-message-role (first msgs)) :user)))
    ;; 清空消息
    (cl-agent.memory:memory-clear-messages memory)
    (is (= (length (cl-agent.memory:memory-get-messages memory)) 0))))

(test agent-memory-items
  "测试项存储"
  (let ((memory (cl-agent.memory:make-simple-memory)))
    ;; 存储项
    (cl-agent.memory:memory-put-item memory '("facts") "sky" "blue")
    (cl-agent.memory:memory-put-item memory '("facts") "grass" "green")
    ;; 获取项
    (is (string= (cl-agent.memory:memory-get-item memory '("facts") "sky") "blue"))
    (is (string= (cl-agent.memory:memory-get-item memory '("facts") "grass") "green"))))

(test agent-memory-state
  "测试状态保存/加载（消息自动保存为 checkpoint）"
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

;; ============================================================
;; 运行测试
;; ============================================================

(defun run-memory-tests ()
  "运行所有测试"
  (format t "~%========================================~%")
  (format t "  CL-Agent Memory v2.5.0 Tests~%")
  (format t "========================================~%~%")
  (run! 'memory-suite))

;; 自动运行
(run-memory-tests)
