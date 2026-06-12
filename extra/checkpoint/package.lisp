;;;; package.lisp
;;;; CL-Agent Extra - Checkpoint 包定义
;;;;
;;;; Overview:
;;;;   流程状态快照系统（LangGraph CheckpointSaver 风格）：
;;;;   - Store 协议 + 内存后端（checkpoint 的存储层）
;;;;   - Checkpoint：按 thread-id 的状态快照、谱系、分支、时间旅行
;;;;
;;;;   服务于 process 框架（pause/resume 的状态持久化），
;;;;   原属 cl-agent-memory，做减法后并入 cl-agent-extra。

(defpackage #:cl-agent.checkpoint
  (:use #:common-lisp)
  (:local-nicknames (:bt :bordeaux-threads))
  (:nicknames #:cla.checkpoint #:checkpoint)
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

   ;; Batch Operations
   #:store-put-batch
   #:store-get-batch
   #:store-delete-batch

   ;; Memory Backend
   #:memory-store-backend
   #:make-memory-store-backend

   ;; ==================== Checkpoint ====================
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
   #:branch-info-created-at))
