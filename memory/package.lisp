;;;; package-memory.lisp
;;;; CL-Agent Memory - 包定义
;;;;
;;;; Overview:
;;;;   定义统一记忆管理系统的包
;;;;
;;;; Design:
;;;;   - 使用 CLOS 实现所有数据结构
;;;;   - 使用 defgeneric/defmethod 实现所有方法
;;;;   - 统一 Store + Checkpoint + Memory API
;;;;
;;;; Architecture:
;;;;   Store (长期记忆) + Checkpointer (短期记忆) = Unified Memory

(defpackage #:cl-agent.memory
  (:use #:common-lisp)
  (:local-nicknames (:bt :bordeaux-threads))
  (:nicknames #:cla.memory #:memory)
  (:export
   ;; ==================== Store Protocol ====================
   ;; Store Item
   #:store-item
   #:store-item-p
   #:make-store-item
   #:store-item-namespace
   #:store-item-key
   #:store-item-value
   #:store-item-embedding
   #:store-item-created-at
   #:store-item-updated-at
   #:store-item-metadata

   ;; Store Protocol Methods
   #:store-put
   #:store-get
   #:store-delete
   #:store-search
   #:store-list-namespaces
   #:store-clear
   #:store-count
   #:store-stats

   ;; Store Batch Operations
   #:store-put-batch
   #:store-get-batch
   #:store-delete-batch

   ;; Namespace Utilities
   #:namespace-to-string
   #:string-to-namespace
   #:namespace-prefix-p
   #:full-key
   #:parse-full-key

   ;; Memory Store Backend
   #:memory-store-backend
   #:make-memory-store-backend
   #:memory-store-data
   #:memory-store-namespace-index
   #:memory-store-max-size
   #:memory-store-eviction-policy

   ;; SQLite Store Backend
   #:sqlite-store-backend
   #:make-sqlite-store-backend
   #:sqlite-store-db-path
   #:sqlite-store-connection
   #:sqlite-store-auto-vacuum
   #:sqlite-store-busy-timeout
   #:sqlite-close

   ;; ==================== Checkpoint Protocol ====================
   ;; Checkpoint Class
   #:checkpoint
   #:checkpoint-p
   #:make-checkpoint
   #:checkpoint-id
   #:checkpoint-thread-id
   #:checkpoint-parent-id
   #:checkpoint-channel-values
   #:checkpoint-channel-versions
   #:checkpoint-timestamp
   #:checkpoint-metadata

   ;; Checkpoint Config
   #:checkpoint-config
   #:checkpoint-config-p
   #:make-checkpoint-config
   #:config-thread-id
   #:config-checkpoint-id
   #:config-namespace

   ;; Checkpointer Protocol Methods (统一命名 - 推荐)
   #:checkpoint-save
   #:checkpoint-load
   #:checkpoint-list-all
   #:checkpoint-delete
   #:checkpoint-clear
   #:checkpoint-get-latest
   #:checkpoint-get-lineage
   #:checkpoint-branch
   #:checkpoint-list-branches

   ;; Checkpointer Protocol Methods (向后兼容别名)
   #:checkpointer-save
   #:checkpointer-load
   #:checkpointer-list
   #:checkpointer-delete
   #:checkpointer-clear
   #:checkpointer-get-latest
   #:checkpointer-get-lineage
   #:checkpointer-branch
   #:checkpointer-list-branches

   ;; Time Travel Methods (统一命名 - 推荐)
   #:checkpoint-go-back
   #:checkpoint-go-forward
   #:checkpoint-goto
   #:checkpoint-switch-branch
   #:checkpoint-delete-branch

   ;; Extended Checkpointer Methods (向后兼容别名)
   #:checkpointer-go-back
   #:checkpointer-go-forward
   #:checkpointer-goto
   #:checkpointer-switch-branch
   #:checkpointer-delete-branch

   ;; Checkpoint Utilities
   #:generate-checkpoint-id
   #:checkpoint-get-channel
   #:checkpoint-set-channel
   #:checkpoint-get-messages
   #:checkpoint-set-messages
   #:checkpoint-get-full-messages
   #:checkpoint-set-full-messages
   #:checkpoint-to-plist
   #:plist-to-checkpoint

   ;; Checkpoint Manager
   #:checkpoint-manager
   #:make-checkpoint-manager
   #:checkpoint-manager-store
   #:checkpoint-manager-current-branch
   #:checkpoint-manager-branches
   #:checkpoint-manager-namespace-prefix

   ;; Branch Info
   #:branch-info
   #:make-branch-info
   #:branch-info-id
   #:branch-info-head-checkpoint-id
   #:branch-info-checkpoint-count
   #:branch-info-created-at

   ;; ==================== Agent Memory ====================
   ;; Agent Memory Class
   #:agent-memory
   #:agent-memory-p
   #:make-agent-memory
   #:agent-memory-checkpointer
   #:agent-memory-context-store
   #:agent-memory-persistent-store
   #:agent-memory-default-thread-id
   #:agent-memory-auto-archive
   #:agent-memory-config

   ;; Store 选择辅助
   #:effective-store
   #:has-persistent-store-p

   ;; Unified Memory Protocol
   #:memory-save-state
   #:memory-load-state
   #:memory-put-item
   #:memory-get-item
   #:memory-search-items
   #:memory-clear-all

   ;; Message Operations
   #:memory-add-message
   #:memory-get-messages
   #:memory-clear-messages
   #:memory-compress-messages

   ;; Archive Operations (Context → Persistent)
   #:memory-archive-session
   #:memory-load-archived
   #:memory-list-archived

   ;; Time Travel Operations
   #:memory-go-back
   #:memory-go-forward
   #:memory-list-history

   ;; Branch Operations
   #:memory-create-branch
   #:memory-switch-branch
   #:memory-list-branches

   ;; Semantic Memory Operations
   #:memory-remember
   #:memory-recall
   #:memory-forget

   ;; Factory Functions
   #:make-simple-memory
   #:make-dual-store-memory

   ;; Global Convenience Functions
   #:save-state
   #:load-state
   #:add-message
   #:get-messages
   #:put-item
   #:get-item
   #:search-items

   ;; ==================== Memory Message 类 ====================
   #:memory-message
   #:memory-message-p
   #:make-memory-message
   #:memory-message-role
   #:memory-message-content
   #:memory-message-timestamp
   #:memory-message-metadata
   ;; 便捷构造函数
   #:make-user-message
   #:make-assistant-message
   #:make-system-message
   #:make-tool-message
   ;; 消息协议
   #:message-to-alist
   #:message-token-count

   ;; ==================== Conversation Summary Buffer ====================
   #:conversation-summary-buffer
   #:conversation-summary-buffer-p
   #:make-conversation-summary-buffer
   ;; 访问器
   #:summary-buffer-summary
   #:summary-buffer-buffer
   #:summary-buffer-max-buffer-tokens
   #:summary-buffer-max-summary-tokens
   #:summary-buffer-summarizer-fn
   #:summary-buffer-system-prompt
   #:summary-buffer-auto-summarize
   #:summary-buffer-human-prefix
   #:summary-buffer-ai-prefix
   #:summary-buffer-verbose
   ;; CLOS 方法
   #:csb-add-message
   #:csb-get-messages
   #:csb-summarize
   #:csb-clear
   #:csb-buffer-tokens
   #:csb-needs-summarize-p
   #:csb-get-context
   ;; 辅助函数
   #:format-messages-for-summary
   #:make-summary-prompt
   #:make-llm-summary-buffer
   ;; 模板
   #:*default-summary-prompt-template*

   ;; ==================== 辅助函数 ====================
   #:estimate-tokens
   #:extract-keywords
   #:cosine-similarity

   ;; ==================== Vector Memory ====================
   #:vector-memory
   #:make-vector-memory
   #:vector-entry
   #:make-vector-entry
   #:vector-memory-add
   #:vector-memory-search
   #:vector-memory-remove
   #:vector-memory-update
   #:vector-memory-get
   #:vector-memory-count
   #:vector-memory-clear
   #:vector-memory-ids
   #:vector-memory-add-batch
   #:vector-memory-search-batch
   #:vector-memory-stats

   ;; ==================== Long-term Memory Protocol ====================
   #:memory-type
   #:memory-store-entry
   #:memory-retrieve
   #:memory-consolidate
   #:memory-decay

   ;; ==================== Semantic Memory ====================
   #:semantic-memory
   #:make-semantic-memory
   #:semantic-entry
   #:make-semantic-entry
   #:semantic-entry-id
   #:semantic-entry-content
   #:semantic-entry-category
   #:semantic-entry-embedding
   #:semantic-entry-confidence
   #:semantic-add-fact
   #:semantic-find-by-category
   #:semantic-link-concepts

   ;; ==================== Episodic Memory ====================
   #:episodic-memory
   #:make-episodic-memory
   #:episode-entry
   #:make-episode-entry
   #:episode-entry-id
   #:episode-entry-event
   #:episode-entry-event-type
   #:episode-entry-occurred-at
   #:episode-entry-importance
   #:episodic-add-event
   #:episodic-retrieve-by-time
   #:episodic-retrieve-by-type
   #:episodic-recent

   ;; ==================== Procedural Memory ====================
   #:procedural-memory
   #:make-procedural-memory
   #:procedure-entry
   #:make-procedure-entry
   #:procedure-entry-id
   #:procedure-entry-name
   #:procedure-entry-steps
   #:procedure-entry-proficiency
   #:procedural-add-skill
   #:procedural-get-by-name
   #:procedural-retrieve-by-trigger
   #:procedural-record-execution
   #:procedural-most-used

   ;; ==================== Retrieval Strategies ====================
   #:retrieval-strategy
   #:retrieval-strategy-name
   #:retrieval-execute
   #:retrieval-rank
   ;; Specific strategies
   #:semantic-retrieval-strategy
   #:make-semantic-retrieval-strategy
   #:recency-retrieval-strategy
   #:make-recency-retrieval-strategy
   #:frequency-retrieval-strategy
   #:make-frequency-retrieval-strategy
   #:importance-retrieval-strategy
   #:make-importance-retrieval-strategy
   #:hybrid-retrieval-strategy
   #:make-hybrid-retrieval-strategy
   ;; Convenience
   #:create-default-retrieval-strategy
   #:create-rag-retrieval-strategy

   ;; ==================== Embedding Protocol ====================
   #:embed-text
   #:embed-batch
   #:embedder-dimensions))
