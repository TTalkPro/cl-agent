# CL-Agent Memory

Agent 记忆管理系统，提供短期记忆（Checkpointer）和长期记忆（Store）的统一接口。

## 架构概览

```
┌─────────────────────────────────────────────────────────┐
│                     agent-memory                        │
│  ┌─────────────────┐      ┌─────────────────────────┐  │
│  │  context-store  │      │   persistent-store      │  │
│  │  (内存，快速)   │      │   (持久化，归档)        │  │
│  │                 │      │                         │  │
│  │ ← checkpointer  │      │ ← 长期记忆              │  │
│  │ ← 当前对话      │ ───→ │ ← 归档历史              │  │
│  └─────────────────┘      └─────────────────────────┘  │
└─────────────────────────────────────────────────────────┘
```

## 设计原则

1. **无全局变量** - 显式传递 memory 实例，避免隐式状态
2. **CLOS 类** - 使用 `defclass`/`defgeneric`/`defmethod` 模式
3. **可插拔后端** - Store 协议支持多种实现（内存、SQLite、PostgreSQL 等）
4. **双 Store 架构** - 支持热/冷数据分离，也可降级为单 Store

## 双 Store 架构

### 设计动机

| 存储类型 | 用途 | 特点 |
|---------|------|------|
| context-store | 当前会话、Checkpointer | 快速读写、内存存储 |
| persistent-store | 历史归档、知识库 | 持久化、大容量 |

### 数据流向

```
用户对话 → context-store → [归档] → persistent-store
              ↑                           ↓
         checkpointer                [加载历史]
         (时间旅行)
```

### 降级模式

当 `persistent-store` 为 `NIL` 时，自动降级为单 Store 模式，所有操作使用 `context-store`。

## Store 后端

### 1. Memory Backend (内存)

快速、非持久化，适用于开发测试和会话缓存。

```lisp
(make-memory-store-backend
  :max-size 1000           ; 最大条目数（nil=无限制）
  :eviction-policy :lru)   ; 淘汰策略 (:lru, :fifo, :lifo)
```

### 2. SQLite Backend (持久化)

基于 SQLite 的持久化存储，适用于单机部署。

```lisp
(make-sqlite-store-backend
  :db-path "/path/to/store.db"  ; 数据库路径（必需）
  :busy-timeout 5000            ; 忙等待超时（毫秒）
  :auto-vacuum t)               ; 自动清理
```

#### SQLite 表结构

```sql
CREATE TABLE store_items (
    full_key   TEXT PRIMARY KEY,   -- namespace + key 组合键
    namespace  TEXT NOT NULL,       -- 命名空间（如 "user/123/prefs"）
    key        TEXT NOT NULL,       -- 条目键
    value      TEXT NOT NULL,       -- JSON 序列化的值
    embedding  TEXT,                -- JSON 序列化的向量（可选）
    metadata   TEXT,                -- JSON 序列化的元数据（可选）
    created_at INTEGER NOT NULL,    -- 创建时间戳
    updated_at INTEGER NOT NULL     -- 更新时间戳
);

-- 索引
CREATE INDEX idx_store_namespace ON store_items(namespace);
CREATE INDEX idx_store_updated_at ON store_items(updated_at);
```

#### SQLite 配置

- **WAL 模式**: 提高并发读写性能
- **NORMAL 同步**: 平衡性能和安全性
- **线程安全**: 使用锁 + busy_timeout

## 使用示例

### 基本用法

```lisp
;; 加载系统
(asdf:load-system :cl-agent-memory)
(use-package :cl-agent.memory)

;; 单 Store 模式（简单）
(let ((memory (make-simple-memory)))
  (memory-add-message memory :user "Hello")
  (memory-add-message memory :assistant "Hi there!")
  (memory-get-messages memory))

;; 双 Store 模式（推荐）
(let ((memory (make-dual-store-memory)))
  ;; 使用...
  )
```

### 自定义后端

```lisp
;; 内存 + SQLite 双 Store
(let ((memory (make-agent-memory
                :context-store (make-memory-store-backend
                                 :max-size 500)
                :persistent-store (make-sqlite-store-backend
                                    :db-path "/data/agent-memory.db"))))

  ;; 添加消息（保存到 context-store）
  (memory-add-message memory :user "你好")

  ;; 长期记忆（保存到 persistent-store）
  (memory-remember memory "用户偏好深色主题" :type :preference)

  ;; 归档当前会话
  (memory-archive-session memory)

  ;; 查看已归档会话
  (memory-list-archived memory))
```

### Store 协议
                                 :max-size 500)
                :persistent-store (make-sqlite-store-backend
                                    :db-path "/data/agent-memory.db"))))

  ;; 添加消息（保存到 context-store）
  (memory-add-message memory :user "你好")

  ;; 长期记忆（保存到 persistent-store）
  (memory-remember memory "用户偏好深色主题" :type :preference)

  ;; 归档当前会话
  (memory-archive-session memory)

  ;; 查看已归档会话
  (memory-list-archived memory))
```

### Store 协议

所有 Store 后端实现统一的协议：

```lisp
;; 基本操作
(store-put store namespace key value &key metadata embedding)
(store-get store namespace key)
(store-delete store namespace key)
(store-search store namespace-prefix &key query limit filter)

;; 管理操作
(store-clear store &optional namespace)
(store-count store &optional namespace)
(store-stats store)
(store-list-namespaces store prefix &key limit)

;; 批量操作
(store-put-batch store items)
(store-get-batch store keys)
(store-delete-batch store keys)
```

### 命名空间

命名空间使用列表表示层级结构：

```lisp
;; 命名空间示例
'("user" "123" "preferences")  ; -> "user/123/preferences"
'("archives" "sessions")       ; -> "archives/sessions"
'("knowledge" "facts")         ; -> "knowledge/facts"

;; 前缀搜索
(store-search store '("user" "123"))  ; 搜索 user/123 下所有条目
```

## agent-memory 详细使用指南

### checkpoint-manager vs agent-memory

| 特性 | `checkpoint-manager` | `agent-memory` |
|------|---------------------|------------------|
| **用途** | 纯检查点管理 | Agent 内存接口（短期+长期） |
| **存储** | 单 Store | 双 Store（context + persistent） |
| **时间旅行** | ✅ | ✅ |
| **分支功能** | ✅ | ✅ |
| **知识库** | ❌ | ✅ |
| **会话归档** | ❌ | ✅ |

**建议**：对于大多数场景，直接使用 `agent-memory`，它提供了 `checkpoint-manager` 的所有功能，还有额外的记忆管理能力。

### 创建 agent-memory

```lisp
;; 单 Store 模式（简单场景）
(defparameter *memory*
  (make-agent-memory
   :context-store (make-memory-store-backend)
   :default-thread-id "main"))

;; 双 Store 模式（推荐）
(defparameter *memory*
  (make-agent-memory
   :context-store (make-memory-store-backend
                   :max-size 1000
                   :eviction-policy :lru)
   :persistent-store (make-sqlite-store-backend
                      :db-path "/data/agent-memory.db")
   :auto-archive t  ; 自动归档
   :default-thread-id "main"))

;; 使用 Agent 创建时的便捷配置
(defparameter *agent*
  (create-agent
   :model (list :provider :anthropic
               :model "glm-4.7"
               :api-key (get-env "ZHIPU_API_KEY")
               :base-url "https://open.bigmodel.cn/api/anthropic/v1")
   :checkpointer (make-agent-memory
                  :context-store (make-memory-store-backend)
                  :persistent-store (make-memory-store-backend))
   :name "time-travel-agent"))
```

### 时间旅行功能

时间旅行允许你回退到之前的状态，或前进到未来的状态。

```lisp
;; 1. 模拟对话，保存多个检查点
(memory-save-state *memory*
                    '(:message "你好" :step 1)
                    :thread-id "main")

(memory-save-state *memory*
                    '(:message "今天天气" :step 2)
                    :thread-id "main")

(memory-save-state *memory*
                    '(:message "再见" :step 3)
                    :thread-id "main")

;; 2. 回退 1 步（回到 step 2）
(memory-go-back *memory* :thread-id "main" :steps 1)

;; 3. 回退 2 步（回到 step 1）
(memory-go-back *memory* :thread-id "main" :steps 2)

;; 4. 前进 1 步（前进到 step 2）
(memory-go-forward *memory* :thread-id "main" :steps 1)

;; 5. 跳转到指定检查点
(memory-load-state *memory*
                   :thread-id "main"
                   :checkpoint-id "cp-123")

;; 6. 列出所有历史
(memory-list *memory* :thread-id "main")
;; => ((:checkpoint-id "cp-1" :timestamp ...) ...)
```

### 分支功能

分支功能允许你创建"平行宇宙"，尝试不同的对话路径。

```lisp
;; 1. 创建新分支（从当前状态）
(memory-branch *memory* "experiment-branch"
               :thread-id "main"
               :from-checkpoint-id "cp-2")

;; 2. 切换到新分支
(memory-switch-branch *memory* "experiment-branch")

;; 3. 在新分支上继续对话
(memory-save-state *memory*
                    '(:message "尝试不同的回复" :step 4)
                    :thread-id "experiment-branch")

;; 4. 切换回主分支
(memory-switch-branch *memory* "main")

;; 5. 列出所有分支
(memory-list-branches *memory*)
;; => (("main" . (...)) ("experiment-branch" . (...)))

;; 6. 删除分支
(memory-delete-branch *memory* "old-branch")
```

### 实战示例：尝试不同的对话策略

```lisp
(defun try-different-response (memory user-message)
  "创建分支尝试不同的回复策略"

  ;; 1. 保存当前状态
  (let ((current-state (memory-load-state memory)))
    (memory-save-state memory current-state))

  ;; 2. 创建"正式回复"分支
  (memory-branch memory "formal"
                 :from-checkpoint-id (get-current-cp-id memory))
  (memory-switch-branch memory "formal")
  (let ((formal-response (generate-response user-message :style :formal)))
    (memory-save-state memory formal-response))

  ;; 3. 切换回主分支，创建"随意回复"分支
  (memory-switch-branch memory "main")
  (memory-branch memory "casual"
                 :from-checkpoint-id (get-current-cp-id memory))
  (memory-switch-branch memory "casual")
  (let ((casual-response (generate-response user-message :style :casual)))
    (memory-save-state memory casual-response))

  ;; 4. 比较两个分支的结果
  (let ((formal-response (memory-load-state memory
                                          :thread-id "formal"))
        (casual-response (memory-load-state memory
                                          :thread-id "casual")))
    (list :formal formal-response
          :casual casual-response)))

;; 使用示例
(try-different-response *memory* "介绍一下你自己")
;; => (:FORMAL "您好，我是..." :CASUAL "嘿！我是...")
```

### 知识库功能

使用 `persistent-store` 存储长期知识。

```lisp
;; 1. 存储知识（默认到 persistent-store）
(memory-put-item *memory*
                 '("knowledge" "facts")
                 "fact-1"
                 "CL-Agent 是一个 Lisp AI 框架"
                 :metadata '(:source "internal" :confidence 1.0))

;; 2. 存储用户偏好
(memory-put-item *memory*
                 '("user" "123" "preferences")
                 "theme"
                 "dark"
                 :metadata '(:type "preference"))

;; 3. 搜索知识
(memory-search-items *memory*
                      '("knowledge")
                      :query "Lisp"
                      :limit 10)

;; 4. 获取用户偏好
(memory-get-item *memory*
                 '("user" "123" "preferences")
                 "theme")
;; => "dark"
```

### 会话归档

将当前会话从 `context-store` 归档到 `persistent-store`。

```lisp
;; 1. 手动归档
(memory-archive-session *memory*
                        :thread-id "session-1"
                        :summarize-fn (lambda (messages)
                                       (summarize-conversation messages)))

;; 2. 列出已归档会话
(memory-list-archived *memory* :limit 20)

;; 3. 加载已归档会话
(memory-load-archived *memory* "session-id-123")

;; 4. 自动归档（创建时设置）
(defparameter *memory*
  (make-agent-memory
   :context-store (make-memory-store-backend)
   :persistent-store (make-sqlite-store-backend
                      :db-path "/data/memory.db")
   :auto-archive t))  ; 会话结束时自动归档
```

### 直接访问 Checkpointer（高级用法）

如果你想直接使用底层的 `checkpoint-manager` API：

```lisp
;; 获取内嵌的 checkpointer
(defparameter *checkpointer*
  (agent-memory-checkpointer *memory*))

;; 使用 checkpoint-manager 的所有功能
(let ((config (make-checkpoint-config :thread-id "main")))
  (checkpointer-go-back *checkpointer* config :steps 1)
  (checkpointer-branch *checkpointer* config "new-branch")
  (checkpointer-switch-branch *checkpointer* config "new-branch")
  (checkpointer-delete-branch *checkpointer* config "old-branch"))
```

### 完整 Agent 示例

```lisp
;; 创建支持时间旅行的 Agent
(defparameter *agent*
  (create-agent
   :model (list :provider :anthropic
               :model "glm-4.7"
               :api-key (get-env "ZHIPU_API_KEY")
               :base-url "https://open.bigmodel.cn/api/anthropic/v1")
   :checkpointer (make-agent-memory
                  :context-store (make-memory-store-backend)
                  :persistent-store (make-sqlite-store-backend
                                     :db-path "/data/agent.db")
                  :auto-archive t)
   :name "time-travel-agent"))

;; 使用 Agent
(agent-run *agent* "你好")
;; => 自动保存为 checkpoint-1

(agent-run *agent* "今天天气怎么样")
;; => 自动保存为 checkpoint-2

;; 回退重试
(let ((memory (agent-get-checkpointer *agent*)))
  (memory-go-back memory :steps 1))
;; => 回到 checkpoint-1

;; 创建分支尝试不同回复
(let ((memory (agent-get-checkpointer *agent*)))
  (memory-branch memory "alternative")
  (memory-switch-branch memory "alternative"))

(agent-run *agent* "用幽默的方式回答")
;; => 在新分支上继续
```

## 与 LangGraph 对比

| 特性 | CL-Agent | LangGraph |
|------|----------|-----------|
| Saver/Store | 统一（Checkpointer 使用 Store） | 分离 |
| 后端选择 | 传入实例 | 配置参数 |
| 全局变量 | 无（显式传值） | 有 |
| 双存储 | context + persistent | 需自行实现 |

## 文件结构

```
memory/
├── README.md                 # 本文档
├── cl-agent-memory.asd       # 系统定义
├── package-memory.lisp       # 包导出
├── utils.lisp                # 工具函数
├── store/
│   ├── protocol.lisp         # Store 协议定义
│   ├── memory-backend.lisp   # 内存后端实现
│   └── sqlite-backend.lisp   # SQLite 后端实现
├── checkpoint/
│   ├── protocol.lisp         # Checkpoint 协议
│   └── manager.lisp          # Checkpoint 管理器
├── api/
│   ├── message.lisp          # 消息数据结构
│   ├── agent-memory.lisp     # Agent Memory API
│   └── summary-buffer.lisp   # 对话总结缓冲区
└── [legacy components]       # 兼容性组件
```

## 版本历史

- **3.0.0** - 重命名 unified-memory → agent-memory
- **2.2.0** - 添加 SQLite Store 后端
- **2.1.0** - 添加对话总结缓冲区 (ConversationSummaryBuffer)
- **2.0.0** - 双 Store 架构，废弃全局变量
- **1.0.0** - 初始版本，统一 Store + Checkpointer
