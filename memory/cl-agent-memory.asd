;;;; cl-agent-memory.asd
;;;; CL-Agent Memory - Agent Memory System
;;;;
;;;; Version: 4.0.0
;;;; Author: David
;;;;
;;;; Overview:
;;;;   Agent memory management combining:
;;;;   - Store (long-term persistence)
;;;;   - Checkpointer (short-term state snapshots)
;;;;   - Conversation Summary Buffer (auto-summarize)
;;;;   - Long-term Memory (semantic, episodic, procedural)
;;;;   - Retrieval Strategies
;;;;   - Agent Memory API
;;;;
;;;; Directory Structure:
;;;;   memory/
;;;;   ├── package.lisp            - Package definition
;;;;   ├── protocol.lisp           - Consolidated protocols
;;;;   ├── utils.lisp              - Utility functions
;;;;   ├── store/                  - Long-term persistence layer
;;;;   │   ├── protocol.lisp       - Store protocol
;;;;   │   ├── memory-backend.lisp - In-memory backend
;;;;   │   ├── sqlite-backend.lisp - SQLite backend
;;;;   │   └── vector-memory.lisp  - Vector memory store
;;;;   ├── checkpoint/             - Short-term state snapshots
;;;;   │   ├── protocol.lisp       - Checkpoint protocol
;;;;   │   └── manager.lisp        - Checkpoint manager
;;;;   ├── long-term/              - Long-term memory types
;;;;   │   ├── semantic.lisp       - Semantic memory (facts)
;;;;   │   ├── episodic.lisp       - Episodic memory (events)
;;;;   │   └── procedural.lisp     - Procedural memory (skills)
;;;;   ├── retrieval/              - Retrieval strategies
;;;;   │   └── strategies.lisp     - Different retrieval strategies
;;;;   └── api/                    - Unified API
;;;;       ├── message.lisp        - Message data structure
;;;;       ├── agent-memory.lisp   - Agent memory interface
;;;;       └── summary-buffer.lisp - Conversation summary buffer
;;;;
;;;; Architecture:
;;;;   ┌──────────────────────────────────────────────┐
;;;;   │             Agent Memory API                 │
;;;;   │          (api/agent-memory.lisp)             │
;;;;   └──────────────────────────────────────────────┘
;;;;                       │
;;;;          ┌────────────┼────────────┐
;;;;          │            │            │
;;;;   ┌──────▼──────┐ ┌───▼───┐ ┌──────▼──────┐
;;;;   │ Checkpointer│ │Message│ │   Store     │
;;;;   │   (短期)    │ │ 结构  │ │   (长期)    │
;;;;   └─────────────┘ └───────┘ └─────────────┘
;;;;
;;;; Store Backends:
;;;;   - memory-store-backend: 内存存储（快速，非持久化）
;;;;   - sqlite-store-backend: SQLite 存储（持久化）
;;;;
;;;; Design philosophy:
;;;;   - CLOS-based OOP (defclass/defgeneric/defmethod)
;;;;   - Pluggable backends (memory, sqlite, etc.)
;;;;   - Thread-safe operations
;;;;   - Follows LangGraph/Erlang agent_memory patterns
;;;;
;;;; Usage:
;;;;   (asdf:load-system :cl-agent-memory)
;;;;
;;;;   ;; 使用内存后端（默认）
;;;;   (make-agent-memory
;;;;    :context-store (make-memory-store-backend))
;;;;
;;;;   ;; 使用 SQLite 后端（持久化）
;;;;   (make-agent-memory
;;;;    :context-store (make-memory-store-backend)
;;;;    :persistent-store (make-sqlite-store-backend
;;;;                        :db-path "/path/to/store.db"))

(asdf:defsystem #:cl-agent-memory
  :description "CL-Agent Memory - Agent Memory Management System (v4.0.0)"
  :author "David"
  :license "MIT"
  :version "4.0.0"

  :depends-on (#:alexandria
               #:serapeum
               #:cl-ppcre
               #:uuid
               #:bordeaux-threads
               ;; JSON serialization (for SQLite backend)
               #:com.inuoe.jzon
               ;; Database abstraction layer
               #:cl-dbi
               #:dbd-sqlite3
               ;; CL-Agent core module
               #:cl-agent-core)

  :serial t
  :components
  (;; === Package Definition ===
   (:file "package")

   ;; === Utilities (loaded first for dependencies) ===
   (:file "utils")

   ;; === Consolidated Protocols ===
   (:file "protocol")

   ;; === Store Layer (Long-term Persistence) ===
   (:module "store"
    :serial t
    :components
    ((:file "protocol")
     (:file "memory-backend")
     (:file "sqlite-backend")
     (:file "vector-memory")))

   ;; === Checkpoint Layer (Short-term State) ===
   (:module "checkpoint"
    :serial t
    :components
    ((:file "protocol")
     (:file "manager")))

   ;; === Long-term Memory Types ===
   (:module "long-term"
    :serial t
    :components
    ((:file "semantic")
     (:file "episodic")
     (:file "procedural")))

   ;; === Retrieval Strategies ===
   (:module "retrieval"
    :serial t
    :components
    ((:file "strategies")))

   ;; === Agent Memory API ===
   (:module "api"
    :serial t
    :components
    ((:file "message")
     (:file "agent-memory")
     (:file "summary-buffer")))))

;; ============================================================
;; Changelog
;; ============================================================
;;
;; v4.0.0:
;; - Major update matching clj-agent architecture
;; - Added long-term memory module:
;;   - semantic.lisp: Semantic memory for facts and knowledge
;;   - episodic.lisp: Episodic memory for events and experiences
;;   - procedural.lisp: Procedural memory for skills and procedures
;; - Added vector-memory.lisp: Vector-based similarity search
;; - Added retrieval/ module with multiple strategies:
;;   - Semantic (vector similarity)
;;   - Recency (time-based)
;;   - Frequency (access count)
;;   - Importance (priority-based)
;;   - Hybrid (combination)
;; - Added consolidated protocol.lisp at top level
;; - Updated package.lisp with new exports
;;
;; v3.0.0:
;; - 重命名 unified-memory → agent-memory
;;   - 更直观的命名，表达"Agent 的记忆系统"
;;   - unified.lisp → agent-memory.lisp
;;   - 保留向后兼容别名（unified-memory 仍可用）
;;   - 更新所有 API 前缀
;;
;; v2.6.0:
;; - 规范化文件和目录命名
;;   - package-memory.lisp → package.lisp
;;   - core/ → api/（避免与全局 core 混淆）
;;   - memory-message.lisp → message.lisp
;;   - unified-memory.lisp → unified.lisp
;;
;; v2.5.0:
;; - 删除遗留组件（short-term-memory, long-term-memory, session-memory, memory-manager）
;; - 将 memory-message.lisp 移入 core/ 目录（核心数据结构）
;; - 删除 legacy/ 目录
;; - 精简包导出，移除废弃 API
;;
;; v2.4.0:
;; - 重组目录结构
;; - 新增 core/ 目录存放核心 API (unified-memory, summary-buffer)
;; - 新增 legacy/ 目录存放遗留组件
;; - 更新 ASD 文件结构注释
;;
;; v2.3.0:
;; - 添加 cl-agent-core 依赖
;; - 移除重复的 format-timestamp 和 truncate-string 函数
;; - 标记遗留组件为 @DEPRECATED
;; - 更新包定义分类注释
;;
;; v2.2.0:
;; - 统一 Store + Checkpoint + Memory API
;; - 添加 SQLite 后端支持
