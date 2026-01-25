;;;; agent-memory.lisp
;;;; CL-Agent Memory - Agent Memory API
;;;;
;;;; Overview:
;;;;   Agent memory interface combining Checkpointer (short-term)
;;;;   and Store (long-term) into a single API
;;;;
;;;; Design:
;;;;   - 双 Store 架构：context-store (内存) + persistent-store (持久化)
;;;;   - 无全局变量，显式传值
;;;;   - 支持降级为单一 Store
;;;;
;;;; Architecture:
;;;;   ┌─────────────────────────────────────────────────────────┐
;;;;   │                     agent-memory                        │
;;;;   │  ┌─────────────────┐      ┌─────────────────────────┐  │
;;;;   │  │  context-store  │      │   persistent-store      │  │
;;;;   │  │  (内存，快速)   │      │   (持久化，归档)        │  │
;;;;   │  │                 │      │                         │  │
;;;;   │  │ ← checkpointer  │      │ ← 长期记忆              │  │
;;;;   │  │ ← 当前对话      │ ───→ │ ← 归档历史              │  │
;;;;   │  └─────────────────┘      └─────────────────────────┘  │
;;;;   └─────────────────────────────────────────────────────────┘
;;;;
;;;; Reference:
;;;;   - Erlang agent_memory.erl
;;;;   - LangGraph Memory abstraction

(in-package #:cl-agent.memory)

;;; ============================================================
;;; Agent Memory Class
;;; ============================================================

(defclass agent-memory ()
  ((context-store
    :initarg :context-store
    :reader agent-memory-context-store
    :documentation "Context store for current session (memory backend, fast)")

   (persistent-store
    :initarg :persistent-store
    :reader agent-memory-persistent-store
    :initform nil
    :documentation "Persistent store for long-term memory (optional, can be file/db)")

   (checkpointer
    :initarg :checkpointer
    :reader agent-memory-checkpointer
    :documentation "Checkpointer using context-store")

   (default-thread-id
    :initarg :default-thread-id
    :accessor agent-memory-default-thread-id
    :initform "default"
    :type string
    :documentation "Default thread ID")

   (auto-archive
    :initarg :auto-archive
    :accessor agent-memory-auto-archive
    :initform nil
    :type boolean
    :documentation "Whether to auto-archive on session end")

   (config
    :initarg :config
    :accessor agent-memory-config
    :initform nil
    :type list
    :documentation "Configuration options"))

  (:documentation "Agent Memory - 双 Store 架构

提供短期（context-store）和长期（persistent-store）记忆的统一接口。

双 Store 模式：
  context-store:     内存存储，用于当前对话、Checkpointer
  persistent-store:  持久化存储，用于历史归档、知识库

单 Store 模式（降级）：
  当 persistent-store 为 NIL 时，所有操作使用 context-store

设计原则：
  - 无全局变量，显式传递 memory 实例
  - 支持灵活的后端配置
  - 会话结束时可归档到 persistent-store"))

(defun agent-memory-p (obj)
  "Check if OBJ is a agent-memory instance"
  (typep obj 'agent-memory))

(defun make-agent-memory (&key context-store
                                persistent-store
                                (checkpointer-namespace '("checkpoints"))
                                (default-thread-id "default")
                                (auto-archive nil)
                                config)
  "创建 agent-memory 实例

参数：
  CONTEXT-STORE          - 上下文存储（必需，用于当前会话）
  PERSISTENT-STORE       - 持久化存储（可选，用于长期记忆）
  CHECKPOINTER-NAMESPACE - Checkpointer 命名空间前缀
  DEFAULT-THREAD-ID      - 默认线程 ID
  AUTO-ARCHIVE           - 是否自动归档
  CONFIG                 - 额外配置

返回：
  agent-memory 实例

示例：
  ;; 单 Store 模式（简单）
  (make-agent-memory
   :context-store (make-memory-store-backend))

  ;; 双 Store 模式（推荐）
  (make-agent-memory
   :context-store (make-memory-store-backend)
   :persistent-store (make-memory-store-backend :max-size 100000))

  ;; 带自动归档
  (make-agent-memory
   :context-store (make-memory-store-backend)
   :persistent-store (make-memory-store-backend)
   :auto-archive t)"
  (unless context-store
    (error "context-store is required"))

  (let ((checkpointer (make-checkpoint-manager
                       :store context-store
                       :namespace-prefix checkpointer-namespace)))

    (make-instance 'agent-memory
                   :context-store context-store
                   :persistent-store persistent-store
                   :checkpointer checkpointer
                   :default-thread-id default-thread-id
                   :auto-archive auto-archive
                   :config config)))

(defmethod print-object ((memory agent-memory) stream)
  (print-unreadable-object (memory stream :type t)
    (format stream "thread: ~A, dual-store: ~A"
            (agent-memory-default-thread-id memory)
            (if (agent-memory-persistent-store memory) "yes" "no"))))

;;; ============================================================
;;; Store 选择辅助函数
;;; ============================================================

(defun effective-store (memory &key persistent)
  "获取有效的 Store

参数：
  MEMORY     - agent-memory 实例
  PERSISTENT - 是否优先使用 persistent-store

返回：
  Store 实例"
  (if (and persistent (agent-memory-persistent-store memory))
      (agent-memory-persistent-store memory)
      (agent-memory-context-store memory)))

(defun has-persistent-store-p (memory)
  "检查是否有持久化存储"
  (not (null (agent-memory-persistent-store memory))))

;;; ============================================================
;;; Agent Memory Protocol
;;; ============================================================

(defgeneric memory-save-state (memory state &key thread-id metadata)
  (:documentation "Save state as a checkpoint (to context-store)"))

(defgeneric memory-load-state (memory &key thread-id checkpoint-id)
  (:documentation "Load state from checkpoint"))

(defgeneric memory-put-item (memory namespace key value &key metadata embedding persistent)
  (:documentation "Store an item (default: persistent-store if available)"))

(defgeneric memory-get-item (memory namespace key &key persistent)
  (:documentation "Retrieve an item"))

(defgeneric memory-search-items (memory namespace-prefix &key query limit persistent)
  (:documentation "Search items"))

(defgeneric memory-clear-all (memory &key thread-id namespace persistent)
  (:documentation "Clear memory"))

;;; ============================================================
;;; Protocol Implementation
;;; ============================================================

(defmethod memory-save-state ((memory agent-memory) state
                              &key thread-id metadata)
  "Save state as a checkpoint (always to context-store)"
  (let* ((tid (or thread-id (agent-memory-default-thread-id memory)))
         (config (make-checkpoint-config :thread-id tid))
         (cp (make-checkpoint :thread-id tid
                             :metadata metadata)))

    ;; Copy state to checkpoint channels
    (when (hash-table-p state)
      (maphash (lambda (k v)
                 (checkpoint-set-channel cp k v))
               state))
    (when (listp state)
      (loop for (k v) on state by #'cddr
            do (checkpoint-set-channel cp (string-downcase (symbol-name k)) v)))

    (checkpointer-save (agent-memory-checkpointer memory) config cp)))

(defmethod memory-load-state ((memory agent-memory) &key thread-id checkpoint-id)
  "Load state from checkpoint"
  (let* ((tid (or thread-id (agent-memory-default-thread-id memory)))
         (config (make-checkpoint-config :thread-id tid
                                        :checkpoint-id checkpoint-id)))
    (checkpointer-load (agent-memory-checkpointer memory) config)))

(defmethod memory-put-item ((memory agent-memory) namespace key value
                           &key metadata embedding (persistent t))
  "Store an item

参数：
  PERSISTENT - 是否存储到 persistent-store（默认 T）
               如果 persistent-store 不存在，则使用 context-store"
  (store-put (effective-store memory :persistent persistent)
             namespace key value
             :metadata metadata
             :embedding embedding))

(defmethod memory-get-item ((memory agent-memory) namespace key
                           &key (persistent t))
  "Retrieve an item"
  (let ((item (store-get (effective-store memory :persistent persistent)
                        namespace key)))
    (when item
      (store-item-value item))))

(defmethod memory-search-items ((memory agent-memory) namespace-prefix
                               &key query limit (persistent t))
  "Search items"
  (store-search (effective-store memory :persistent persistent)
               namespace-prefix
               :query query
               :limit limit))

(defmethod memory-clear-all ((memory agent-memory) &key thread-id namespace persistent)
  "Clear memory"
  (let ((cp-count 0)
        (store-count 0))
    ;; Clear checkpoints if thread-id provided
    (when thread-id
      (let ((config (make-checkpoint-config :thread-id thread-id)))
        (setf cp-count (checkpointer-clear
                       (agent-memory-checkpointer memory)
                       config))))
    ;; Clear store if namespace provided
    (when namespace
      (setf store-count (store-clear (effective-store memory :persistent persistent)
                                    namespace)))
    ;; Clear all if neither provided
    (when (and (null thread-id) (null namespace))
      (setf cp-count (checkpointer-clear
                     (agent-memory-checkpointer memory)
                     (make-checkpoint-config
                      :thread-id (agent-memory-default-thread-id memory))))
      (setf store-count (store-clear (agent-memory-context-store memory))))
    `(:checkpoints-cleared ,cp-count
      :items-cleared ,store-count)))

;;; ============================================================
;;; Archive Functions (Context → Persistent)
;;; ============================================================

(defgeneric memory-archive-session (memory &key thread-id summarize-fn)
  (:documentation "Archive current session to persistent store"))

(defgeneric memory-load-archived (memory session-id)
  (:documentation "Load archived session from persistent store"))

(defgeneric memory-list-archived (memory &key limit)
  (:documentation "List archived sessions"))

(defmethod memory-archive-session ((memory agent-memory)
                                   &key thread-id summarize-fn)
  "将当前会话归档到 persistent-store

参数：
  MEMORY       - agent-memory 实例
  THREAD-ID    - 线程 ID（可选）
  SUMMARIZE-FN - 总结函数（可选）(lambda (messages) -> summary-string)

返回：
  归档的 session-id 或 NIL（如果没有 persistent-store）"
  (unless (has-persistent-store-p memory)
    (return-from memory-archive-session nil))

  (let* ((tid (or thread-id (agent-memory-default-thread-id memory)))
         (config (make-checkpoint-config :thread-id tid))
         (cp (checkpointer-load (agent-memory-checkpointer memory) config))
         (messages (when cp (checkpoint-get-messages cp)))
         (session-id (format nil "session-~A-~A" tid (get-universal-time))))

    (when messages
      (let ((archive-data
              `(:session-id ,session-id
                :thread-id ,tid
                :archived-at ,(get-universal-time)
                :message-count ,(length messages)
                :messages ,messages
                :summary ,(when summarize-fn
                           (funcall summarize-fn messages)))))

        ;; Store to persistent-store
        (store-put (agent-memory-persistent-store memory)
                   '("archives" "sessions")
                   session-id
                   archive-data
                   :metadata `(:type :session-archive
                              :thread-id ,tid))

        ;; Clear context-store for this thread
        (checkpointer-clear (agent-memory-checkpointer memory) config)

        session-id))))

(defmethod memory-load-archived ((memory agent-memory) session-id)
  "从 persistent-store 加载已归档的会话

参数：
  MEMORY     - agent-memory 实例
  SESSION-ID - 会话 ID

返回：
  归档数据 plist 或 NIL"
  (unless (has-persistent-store-p memory)
    (return-from memory-load-archived nil))

  (let ((item (store-get (agent-memory-persistent-store memory)
                        '("archives" "sessions")
                        session-id)))
    (when item
      (store-item-value item))))

(defmethod memory-list-archived ((memory agent-memory) &key (limit 20))
  "列出已归档的会话

参数：
  MEMORY - agent-memory 实例
  LIMIT  - 最大返回数量

返回：
  归档会话列表"
  (unless (has-persistent-store-p memory)
    (return-from memory-list-archived nil))

  (let ((items (store-search (agent-memory-persistent-store memory)
                            '("archives" "sessions")
                            :limit limit)))
    (mapcar (lambda (item)
              (let ((data (store-item-value item)))
                `(:session-id ,(getf data :session-id)
                  :thread-id ,(getf data :thread-id)
                  :archived-at ,(getf data :archived-at)
                  :message-count ,(getf data :message-count)
                  :summary ,(getf data :summary))))
            items)))

;;; ============================================================
;;; Convenience Functions (Message-Based)
;;; ============================================================

(defgeneric memory-add-message (memory role content &key thread-id metadata)
  (:documentation "Add a message to conversation history"))

(defgeneric memory-get-messages (memory &key thread-id limit full)
  (:documentation "Get messages from conversation history

Parameters:
  MEMORY    - Agent memory instance
  THREAD-ID - Thread ID (optional)
  LIMIT     - Maximum number of messages to return (optional)
  FULL      - If T, return full-messages (complete history) instead of
              working copy (which may be compressed). Default: NIL"))

(defgeneric memory-clear-messages (memory &key thread-id archive)
  (:documentation "Clear conversation history"))

(defmethod memory-add-message ((memory agent-memory) role content
                              &key thread-id metadata)
  "Add a message to conversation history

Description:
  Adds a new message to both messages (working copy) and full-messages
  (complete history). This dual-storage approach enables:
  - Compression of messages without losing the original history
  - Time-travel through complete conversation
  - Avoiding repeated compression when restoring from checkpoint

Behavior:
  - messages: Working copy, may be compressed later
  - full-messages: Complete uncompressed history, always grows"
  (let* ((tid (or thread-id (agent-memory-default-thread-id memory)))
         (config (make-checkpoint-config :thread-id tid))
         (current-cp (checkpointer-load (agent-memory-checkpointer memory) config))
         (messages (if current-cp
                      (checkpoint-get-messages current-cp)
                      '()))
         (full-messages (if current-cp
                           (checkpoint-get-full-messages current-cp)
                           '()))
         (new-message (make-memory-message :role role
                                          :content content
                                          :metadata metadata)))

    ;; Append new message to both
    (setf messages (append messages (list new-message)))
    (setf full-messages (append full-messages (list new-message)))

    ;; Create new checkpoint with updated messages
    (let ((new-cp (make-checkpoint
                  :thread-id tid
                  :metadata `(:last-message-role ,role))))
      ;; Save both messages and full-messages
      (checkpoint-set-messages new-cp messages)
      (checkpoint-set-full-messages new-cp full-messages)

      ;; Copy other channels from current checkpoint
      (when current-cp
        (maphash (lambda (k v)
                   (unless (or (string= k "messages")
                              (string= k "full-messages"))
                     (checkpoint-set-channel new-cp k v)))
                 (checkpoint-channel-values current-cp)))

      (checkpointer-save (agent-memory-checkpointer memory) config new-cp)
      new-message)))

(defmethod memory-get-messages ((memory agent-memory) &key thread-id limit full)
  "Get messages from conversation history

Parameters:
  THREAD-ID - Thread ID (optional)
  LIMIT     - Maximum number of messages (optional)
  FULL      - If T, return full-messages (complete uncompressed history)
              If NIL, return messages (working copy, may be compressed)
              Default: NIL

Returns:
  List of messages"
  (let* ((tid (or thread-id (agent-memory-default-thread-id memory)))
         (config (make-checkpoint-config :thread-id tid))
         (cp (checkpointer-load (agent-memory-checkpointer memory) config))
         (messages (when cp
                     (if full
                         (checkpoint-get-full-messages cp)
                         (checkpoint-get-messages cp)))))
    (if (and limit (> (length messages) limit))
        (subseq messages (- (length messages) limit))
        messages)))

(defmethod memory-clear-messages ((memory agent-memory) &key thread-id archive)
  "Clear conversation history

参数：
  THREAD-ID - 线程 ID（可选）
  ARCHIVE   - 是否先归档（默认 NIL）"
  (when archive
    (memory-archive-session memory :thread-id thread-id))

  (let* ((tid (or thread-id (agent-memory-default-thread-id memory)))
         (config (make-checkpoint-config :thread-id tid)))
    (checkpointer-clear (agent-memory-checkpointer memory) config)))

;;; ============================================================
;;; Message Compression
;;; ============================================================

(defgeneric memory-compress-messages (memory compress-fn &key thread-id keep-recent)
  (:documentation "Compress messages using provided compression function

Parameters:
  MEMORY      - Agent memory instance
  COMPRESS-FN - Function to compress messages: (lambda (messages) -> compressed-messages)
                Takes full-messages and returns compressed version
  THREAD-ID   - Thread ID (optional)
  KEEP-RECENT - Number of recent messages to keep uncompressed (optional)

Description:
  This function compresses the working copy (messages) while preserving
  the complete history (full-messages). This allows:
  - Reducing token usage for LLM calls
  - Avoiding repeated compression when restoring from checkpoint
  - Maintaining ability to time-travel through full history

Example:
  (memory-compress-messages memory
    (lambda (msgs)
      ;; Compress to summary + recent messages
      (let ((summary (summarize-messages (butlast msgs 5)))
            (recent (last msgs 5)))
        (cons summary recent)))
    :thread-id \"chat-123\"
    :keep-recent 5)"))

(defmethod memory-compress-messages ((memory agent-memory) compress-fn
                                    &key thread-id keep-recent)
  "Compress messages while preserving full history"
  (let* ((tid (or thread-id (agent-memory-default-thread-id memory)))
         (config (make-checkpoint-config :thread-id tid))
         (current-cp (checkpointer-load (agent-memory-checkpointer memory) config)))

    (unless current-cp
      (error "No checkpoint found for thread ~A" tid))

    (let* ((full-messages (or (checkpoint-get-full-messages current-cp)
                             (checkpoint-get-messages current-cp)))
           (messages-to-compress (if keep-recent
                                    (butlast full-messages keep-recent)
                                    full-messages))
           (compressed-messages (if messages-to-compress
                                   (funcall compress-fn messages-to-compress)
                                   '()))
           (recent-messages (if keep-recent
                               (last full-messages keep-recent)
                               '()))
           (new-messages (append compressed-messages recent-messages)))

      ;; Create new checkpoint with compressed messages
      (let ((new-cp (make-checkpoint
                    :thread-id tid
                    :metadata `(:compressed t
                               :compressed-at ,(get-universal-time)))))
        ;; Set compressed working copy
        (checkpoint-set-messages new-cp new-messages)
        ;; Preserve full history
        (checkpoint-set-full-messages new-cp full-messages)

        ;; Copy other channels
        (maphash (lambda (k v)
                   (unless (or (string= k "messages")
                              (string= k "full-messages"))
                     (checkpoint-set-channel new-cp k v)))
                 (checkpoint-channel-values current-cp))

        (checkpointer-save (agent-memory-checkpointer memory) config new-cp)
        new-messages))))

;;; ============================================================
;;; Convenience Functions (Time Travel)
;;; ============================================================

(defgeneric memory-go-back (memory &key thread-id steps)
  (:documentation "Go back in checkpoint history"))

(defgeneric memory-go-forward (memory &key thread-id steps)
  (:documentation "Go forward in checkpoint history"))

(defgeneric memory-list-history (memory &key thread-id limit)
  (:documentation "List checkpoint history"))

(defmethod memory-go-back ((memory agent-memory) &key thread-id (steps 1))
  "Go back in checkpoint history"
  (let* ((tid (or thread-id (agent-memory-default-thread-id memory)))
         (config (make-checkpoint-config :thread-id tid)))
    (checkpointer-go-back (agent-memory-checkpointer memory)
                         config :steps steps)))

(defmethod memory-go-forward ((memory agent-memory) &key thread-id (steps 1))
  "Go forward in checkpoint history"
  (let* ((tid (or thread-id (agent-memory-default-thread-id memory)))
         (config (make-checkpoint-config :thread-id tid)))
    (checkpointer-go-forward (agent-memory-checkpointer memory)
                            config :steps steps)))

(defmethod memory-list-history ((memory agent-memory) &key thread-id limit)
  "List checkpoint history"
  (let* ((tid (or thread-id (agent-memory-default-thread-id memory)))
         (config (make-checkpoint-config :thread-id tid)))
    (checkpointer-list (agent-memory-checkpointer memory)
                      config :limit limit)))

;;; ============================================================
;;; Convenience Functions (Branching)
;;; ============================================================

(defgeneric memory-create-branch (memory branch-id &key thread-id from-checkpoint)
  (:documentation "Create a new branch"))

(defgeneric memory-switch-branch (memory branch-id &key thread-id)
  (:documentation "Switch to a different branch"))

(defgeneric memory-list-branches (memory &key thread-id)
  (:documentation "List all branches"))

(defmethod memory-create-branch ((memory agent-memory) branch-id
                                &key thread-id from-checkpoint)
  "Create a new branch"
  (let* ((tid (or thread-id (agent-memory-default-thread-id memory)))
         (config (make-checkpoint-config :thread-id tid)))
    (checkpointer-branch (agent-memory-checkpointer memory)
                        config branch-id
                        :from-checkpoint-id from-checkpoint)))

(defmethod memory-switch-branch ((memory agent-memory) branch-id &key thread-id)
  "Switch to a different branch"
  (let* ((tid (or thread-id (agent-memory-default-thread-id memory)))
         (config (make-checkpoint-config :thread-id tid)))
    (checkpointer-switch-branch (agent-memory-checkpointer memory)
                               config branch-id)))

(defmethod memory-list-branches ((memory agent-memory) &key thread-id)
  "List all branches"
  (let* ((tid (or thread-id (agent-memory-default-thread-id memory)))
         (config (make-checkpoint-config :thread-id tid)))
    (checkpointer-list-branches (agent-memory-checkpointer memory) config)))

;;; ============================================================
;;; Convenience Functions (Semantic Memory)
;;; ============================================================

(defgeneric memory-remember (memory content &key type namespace metadata embedding)
  (:documentation "Remember something in long-term memory"))

(defgeneric memory-recall (memory query &key type namespace limit)
  (:documentation "Recall from long-term memory"))

(defgeneric memory-forget (memory &key type namespace key)
  (:documentation "Forget from long-term memory"))

(defmethod memory-remember ((memory agent-memory) content
                           &key (type :general) namespace metadata embedding)
  "Remember something in long-term memory (to persistent-store)"
  (let* ((ns (or namespace (list (string-downcase (symbol-name type)))))
         (key (format nil "~A-~A"
                     (string-downcase (symbol-name type))
                     (get-universal-time))))
    (store-put (effective-store memory :persistent t)
               ns key content
               :metadata (append `(:type ,type) metadata)
               :embedding embedding)))

(defmethod memory-recall ((memory agent-memory) query
                         &key (type nil) namespace limit)
  "Recall from long-term memory (from persistent-store)"
  (let ((ns (or namespace
               (when type
                 (list (string-downcase (symbol-name type))))
               '())))
    (mapcar #'store-item-value
            (store-search (effective-store memory :persistent t)
                         ns :query query :limit limit))))

(defmethod memory-forget ((memory agent-memory) &key type namespace key)
  "Forget from long-term memory"
  (let ((ns (or namespace
               (when type
                 (list (string-downcase (symbol-name type))))
               '())))
    (if key
        (store-delete (effective-store memory :persistent t) ns key)
        (store-clear (effective-store memory :persistent t) ns))))

;;; ============================================================
;;; Factory Functions
;;; ============================================================

(defun make-simple-memory (&key (max-context-size 1000)
                                (default-thread-id "default"))
  "创建简单的单 Store 内存实例

参数：
  MAX-CONTEXT-SIZE  - 上下文 Store 最大条目数
  DEFAULT-THREAD-ID - 默认线程 ID

返回：
  agent-memory 实例（单 Store 模式）"
  (make-agent-memory
   :context-store (make-memory-store-backend :max-size max-context-size)
   :default-thread-id default-thread-id))

(defun make-dual-store-memory (&key (max-context-size 1000)
                                    (max-persistent-size nil)
                                    (default-thread-id "default")
                                    (auto-archive nil))
  "创建双 Store 内存实例

参数：
  MAX-CONTEXT-SIZE    - 上下文 Store 最大条目数
  MAX-PERSISTENT-SIZE - 持久化 Store 最大条目数（nil=无限制）
  DEFAULT-THREAD-ID   - 默认线程 ID
  AUTO-ARCHIVE        - 是否自动归档

返回：
  agent-memory 实例（双 Store 模式）"
  (make-agent-memory
   :context-store (make-memory-store-backend :max-size max-context-size)
   :persistent-store (make-memory-store-backend :max-size max-persistent-size)
   :default-thread-id default-thread-id
   :auto-archive auto-archive))
