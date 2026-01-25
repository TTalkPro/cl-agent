;;;; memory-usage.lisp
;;;; CL-Agent - 统一记忆管理使用示例
;;;;
;;;; 展示 cl-agent-memory 的核心功能：
;;;;   - 消息管理（Memory Message）
;;;;   - 长期存储（Store）
;;;;   - 状态快照（Checkpoint）
;;;;   - 统一记忆 API（Unified Memory）

;; 加载系统
(asdf:load-system :cl-agent-memory)

;; 使用包
(in-package :cl-user)
(use-package :cl-agent.memory)

;;; ============================================================
;;; 示例 1：Memory Message 基本使用
;;; ============================================================

(defun example-1-memory-message ()
  "Memory Message 基本使用"
  (format t "~%=== Example 1: Memory Message ===~%")

  ;; 创建不同类型的消息
  (let ((user-msg (make-user-message "Hello, AI!"))
        (assistant-msg (make-assistant-message "Hi! How can I help?"))
        (system-msg (make-system-message "You are a helpful assistant."))
        (tool-msg (make-tool-message "Result: 42"
                                     :tool-name "calculator"
                                     :tool-result 42)))

    ;; 显示消息
    (format t "~%Messages created:~%")
    (dolist (msg (list user-msg assistant-msg system-msg tool-msg))
      (format t "  [~A] ~A~%"
              (memory-message-role msg)
              (memory-message-content msg)))

    ;; 消息转 alist
    (format t "~%User message as alist: ~A~%"
            (message-to-alist user-msg))))

;;; ============================================================
;;; 示例 2：Store 存储操作
;;; ============================================================

(defun example-2-store-operations ()
  "Store 存储操作"
  (format t "~%=== Example 2: Store Operations ===~%")

  ;; 创建内存存储后端
  (let ((store (make-memory-store-backend)))
    ;; 存储数据
    (store-put store '("facts") "sky-color" "blue")
    (store-put store '("facts") "grass-color" "green")
    (store-put store '("user" "preferences") "theme" "dark")

    (format t "~%Stored 3 items~%")

    ;; 读取数据
    (format t "Sky color: ~A~%" (store-get store '("facts") "sky-color"))
    (format t "Theme: ~A~%" (store-get store '("user" "preferences") "theme"))

    ;; 批量操作
    (store-put-batch store '("numbers")
                     '(("one" . "1") ("two" . "2") ("three" . "3")))

    (format t "~%Batch stored numbers~%")
    (format t "Count in 'numbers' namespace: ~A~%"
            (store-count store '("numbers")))

    ;; 列出命名空间
    (format t "~%Namespaces: ~A~%"
            (store-list-namespaces store))))

;;; ============================================================
;;; 示例 3：Checkpoint 状态快照
;;; ============================================================

(defun example-3-checkpoint ()
  "Checkpoint 状态快照"
  (format t "~%=== Example 3: Checkpoint ===~%")

  ;; 创建检查点管理器
  (let* ((store (make-memory-store-backend))
         (manager (make-checkpoint-manager :store store))
         (config (make-checkpoint-config :thread-id "demo-thread")))

    ;; 创建并保存检查点
    (dotimes (step 3)
      (let ((cp (make-checkpoint
                 :thread-id "demo-thread"
                 :channel-values (let ((ht (make-hash-table :test #'equal)))
                                  (setf (gethash "step" ht) step)
                                  (setf (gethash "data" ht)
                                        (format nil "Data at step ~A" step))
                                  ht))))
        (checkpointer-save manager config cp)
        (format t "Saved checkpoint at step ~A~%" step)))

    ;; 获取最新检查点
    (let ((latest (checkpointer-get-latest manager config)))
      (format t "~%Latest checkpoint:~%")
      (format t "  Thread ID: ~A~%" (checkpoint-thread-id latest))
      (format t "  Step: ~A~%"
              (gethash "step" (checkpoint-channel-values latest))))

    ;; 获取历史链
    (let ((lineage (checkpointer-get-lineage manager config)))
      (format t "~%Checkpoint history: ~A checkpoints~%" (length lineage)))))

;;; ============================================================
;;; 示例 4：Agent Memory 基本使用
;;; ============================================================

(defun example-4-agent-memory ()
  "Agent Memory 基本使用"
  (format t "~%=== Example 4: Agent Memory ===~%")

  ;; 创建简单记忆实例
  (let ((memory (make-simple-memory)))
    ;; 添加对话消息
    (memory-add-message memory :user "What is Common Lisp?")
    (memory-add-message memory :assistant
                        "Common Lisp is a powerful, multi-paradigm programming language.")
    (memory-add-message memory :user "What are its key features?")

    ;; 获取消息
    (format t "~%Conversation:~%")
    (dolist (msg (memory-get-messages memory))
      (format t "  [~A] ~A~%"
              (memory-message-role msg)
              (let ((content (memory-message-content msg)))
                (if (> (length content) 50)
                    (concatenate 'string (subseq content 0 50) "...")
                    content))))

    (format t "~%Total messages: ~A~%"
            (length (memory-get-messages memory)))))

;;; ============================================================
;;; 示例 5：Unified Memory 状态管理
;;; ============================================================

(defun example-5-state-management ()
  "Unified Memory 状态管理"
  (format t "~%=== Example 5: State Management ===~%")

  (let ((memory (make-simple-memory)))
    ;; 添加消息并保存状态
    (memory-add-message memory :user "First message")
    (memory-save-state memory)
    (format t "Saved state with 1 message~%")

    (memory-add-message memory :assistant "First response")
    (memory-save-state memory)
    (format t "Saved state with 2 messages~%")

    (memory-add-message memory :user "Second message")
    (memory-save-state memory)
    (format t "Saved state with 3 messages~%")

    ;; 获取历史
    (format t "~%History entries: ~A~%"
            (length (memory-list-history memory)))

    ;; 回退
    (format t "~%Going back...~%")
    (memory-go-back memory)
    (format t "Messages after go-back: ~A~%"
            (length (memory-get-messages memory)))))

;;; ============================================================
;;; 示例 6：Unified Memory 项存储
;;; ============================================================

(defun example-6-item-storage ()
  "Unified Memory 项存储"
  (format t "~%=== Example 6: Item Storage ===~%")

  (let ((memory (make-simple-memory)))
    ;; 存储知识项
    (memory-put-item memory '("knowledge" "science") "gravity"
                     "Force that attracts objects with mass")
    (memory-put-item memory '("knowledge" "science") "photosynthesis"
                     "Process by which plants convert light to energy")
    (memory-put-item memory '("knowledge" "history") "lisp-origin"
                     "Created by John McCarthy in 1958")

    ;; 获取项
    (format t "~%Gravity: ~A~%"
            (memory-get-item memory '("knowledge" "science") "gravity"))

    ;; 搜索项
    (format t "~%Science knowledge items:~%")
    (dolist (item (memory-search-items memory '("knowledge" "science")))
      (format t "  - ~A~%" item))))

;;; ============================================================
;;; 示例 7：Dual Store Memory（持久化）
;;; ============================================================

(defun example-7-dual-store ()
  "Dual Store Memory（内存 + 持久化）"
  (format t "~%=== Example 7: Dual Store Memory ===~%")

  ;; 注意：实际使用时可以指定 SQLite 路径
  ;; (make-dual-store-memory :db-path "/path/to/memory.db")

  ;; 这里使用纯内存版本演示
  (let ((memory (make-simple-memory)))
    ;; 存储会话数据（短期）
    (memory-add-message memory :user "Hello!")
    (memory-add-message memory :assistant "Hi there!")

    ;; 存储知识项（可持久化）
    (memory-put-item memory '("learned") "user-name" "Alice")

    (format t "Memory configured~%")
    (format t "Messages: ~A~%" (length (memory-get-messages memory)))
    (format t "User name: ~A~%"
            (memory-get-item memory '("learned") "user-name"))))

;;; ============================================================
;;; 示例 8：Summary Buffer（对话摘要）
;;; ============================================================

(defun example-8-summary-buffer ()
  "Conversation Summary Buffer"
  (format t "~%=== Example 8: Summary Buffer ===~%")

  ;; 创建对话摘要缓冲
  (let ((csb (make-conversation-summary-buffer
              :max-buffer-tokens 1000
              :human-prefix "Human"
              :ai-prefix "AI")))

    ;; 添加消息
    (csb-add-message csb (make-user-message "Hello!"))
    (csb-add-message csb (make-assistant-message "Hi! How can I help you?"))
    (csb-add-message csb (make-user-message "Tell me about Lisp."))
    (csb-add-message csb (make-assistant-message
                          "Lisp is a family of programming languages..."))

    ;; 获取消息
    (format t "~%Messages in buffer: ~A~%"
            (length (csb-get-messages csb)))

    ;; 检查 token 数
    (format t "Estimated buffer tokens: ~A~%"
            (csb-buffer-tokens csb))

    ;; 获取上下文
    (format t "~%Context for LLM:~%~A~%"
            (csb-get-context csb))))

;;; ============================================================
;;; 运行所有示例
;;; ============================================================

(defun run-memory-examples ()
  "运行所有记忆管理示例"
  (format t "~%========================================")
  (format t "~%  CL-Agent Memory Examples (v2.5.0)")
  (format t "~%========================================")

  (example-1-memory-message)
  (example-2-store-operations)
  (example-3-checkpoint)
  (example-4-agent-memory)
  (example-5-state-management)
  (example-6-item-storage)
  (example-7-dual-store)
  (example-8-summary-buffer)

  (format t "~%========================================")
  (format t "~%  All memory examples completed!")
  (format t "~%========================================~%"))

;; 运行示例（取消注释）
;; (run-memory-examples)
