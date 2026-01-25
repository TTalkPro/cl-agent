# Memory 模块

统一记忆管理模块，提供短期检查点和长期持久化存储。

## 目录结构

```
memory/
├── package.lisp              # 包定义
├── protocol.lisp             # 统一协议
├── utils.lisp                # 工具函数
├── store/                    # 长期存储
│   ├── protocol.lisp         # Store 协议
│   ├── memory-backend.lisp   # 内存后端
│   ├── sqlite-backend.lisp   # SQLite 后端
│   └── vector-memory.lisp    # 向量存储
├── checkpoint/               # 检查点
│   ├── protocol.lisp         # Checkpoint 协议
│   └── manager.lisp          # Checkpoint 管理器
├── long-term/                # 长期记忆类型
│   ├── semantic.lisp         # 语义记忆
│   ├── episodic.lisp         # 情节记忆
│   └── procedural.lisp       # 程序性记忆
├── retrieval/                # 检索策略
│   └── strategies.lisp
└── api/                      # 统一 API
    ├── message.lisp          # 消息结构
    ├── agent-memory.lisp     # Agent Memory 类
    └── summary-buffer.lisp   # 摘要缓冲
```

## 架构概览

```
┌─────────────────────────────────────────┐
│           Agent Memory API              │
└─────────────────────────────────────────┘
              │           │
    ┌─────────┴───┐   ┌───┴─────────┐
    │             │   │             │
    ▼             ▼   ▼             ▼
┌─────────┐  ┌─────────┐  ┌─────────────┐
│Checkpoint│  │ Message │  │   Store     │
│ (短期)   │  │  结构   │  │  (长期)     │
└─────────┘  └─────────┘  └─────────────┘
                              │
              ┌───────────────┼───────────────┐
              │               │               │
              ▼               ▼               ▼
         ┌────────┐     ┌────────┐     ┌────────┐
         │ Memory │     │ SQLite │     │ Vector │
         │Backend │     │Backend │     │Backend │
         └────────┘     └────────┘     └────────┘
```

## 消息结构

```lisp
;; 创建消息
(make-memory-message :role :user :content "Hello")

;; 快捷方式
(make-user-message "Hello")
(make-assistant-message "Hi there!")
(make-system-message "You are helpful.")
(make-tool-message "Result" :tool-call-id "call_123")

;; 访问属性
(memory-message-role msg)       ; => :USER
(memory-message-content msg)    ; => "Hello"
(memory-message-timestamp msg)  ; => "2024-01-15T10:30:00Z"
(memory-message-metadata msg)   ; => (:key "value")
```

## Store 后端

### 内存后端

快速、会话级存储：

```lisp
(defvar *store* (make-memory-store-backend))

;; 基本操作
(store-put *store* '("namespace") "key" "value")
(store-get *store* '("namespace") "key")  ; => "value"
(store-delete *store* '("namespace") "key")

;; 列表和计数
(store-list-keys *store* '("namespace"))  ; => ("key1" "key2")
(store-count *store* '("namespace"))      ; => 2

;; 清空
(store-clear *store* '("namespace"))
```

### SQLite 后端

持久化文件存储：

```lisp
(defvar *store*
  (make-sqlite-store-backend
    :db-path "~/.cl-agent/memory.db"))

;; API 与内存后端相同
(store-put *store* '("facts") "lisp-creator" "John McCarthy")
(store-get *store* '("facts") "lisp-creator")

;; 数据在应用重启后保留
```

### 向量存储后端

支持语义搜索：

```lisp
(defvar *vector-store*
  (make-vector-memory-backend
    :embedding-fn #'my-embedding-function))

;; 存储带嵌入的数据
(store-put *vector-store* '("docs") "doc1"
  '(:content "Common Lisp is..."
    :embedding #(0.1 0.2 0.3 ...)))

;; 语义搜索
(vector-search *vector-store* '("docs")
  :query-embedding #(0.15 0.25 0.35 ...)
  :top-k 5)
```

## Checkpoint 系统

保存和恢复 Agent 状态：

```lisp
(defvar *checkpointer* (make-checkpoint-manager *store*))

;; 保存检查点
(let ((cp (save-checkpoint *checkpointer* "thread-1"
            '(:summary "用户讨论了旅行计划"
              :facts ((:destination "日本")
                      (:date "四月"))
              :preferences (:style "文化")))))
  (format t "检查点 ID: ~A~%" (checkpoint-id cp)))

;; 加载最新检查点
(let ((cp (load-checkpoint *checkpointer* "thread-1")))
  (when cp
    (format t "状态: ~A~%" (checkpoint-state cp))))

;; 列出所有检查点
(list-checkpoints *checkpointer* :thread-id "thread-1")

;; 删除检查点
(delete-checkpoint *checkpointer* checkpoint-id)

;; 创建分支
(create-branch *checkpointer* "thread-1" "experiment-branch")
```

## Agent Memory

统一的记忆接口：

```lisp
;; 创建 Agent Memory
(defvar *memory*
  (make-agent-memory
    :context-store (make-memory-store-backend)      ; 快速上下文
    :persistent-store (make-sqlite-store-backend    ; 持久化
                        :db-path "memory.db")
    :default-thread-id "default"
    :auto-archive t))                               ; 自动归档

;; 消息操作
(am-add-message *memory* "thread-1" :user "Hello")
(am-add-message *memory* "thread-1" :assistant "Hi!")
(am-get-messages *memory* "thread-1")
(am-get-last-n-messages *memory* "thread-1" 5)
(am-clear-messages *memory* "thread-1")

;; 检查点
(am-save-checkpoint *memory* "thread-1" '(:state ...))
(am-load-checkpoint *memory* checkpoint-id)

;; 事实存储
(am-store-fact *memory* "user-name" "小明")
(am-recall-facts *memory* "user-*")

;; 归档（移动到持久化存储）
(am-archive-messages *memory* "thread-1")
```

## 长期记忆类型

### 语义记忆（Semantic）

存储事实和知识：

```lisp
(defvar *semantic* (make-semantic-memory *store*))

;; 存储事实
(semantic-store *semantic* "lisp"
  '(:type :programming-language
    :created 1958
    :creator "John McCarthy"))

;; 检索
(semantic-recall *semantic* "lisp")

;; 关联搜索
(semantic-search *semantic* :type :programming-language)
```

### 情节记忆（Episodic）

存储事件和经历：

```lisp
(defvar *episodic* (make-episodic-memory *store*))

;; 记录事件
(episodic-record *episodic*
  '(:event "用户询问天气"
    :context (:location "北京" :mood "curious")
    :outcome "提供了天气信息"))

;; 按时间检索
(episodic-recall *episodic*
  :from "2024-01-01"
  :to "2024-01-31")

;; 按上下文检索
(episodic-search *episodic* :location "北京")
```

### 程序性记忆（Procedural）

存储技能和过程：

```lisp
(defvar *procedural* (make-procedural-memory *store*))

;; 存储过程
(procedural-store *procedural* "book-flight"
  '(:steps ("1. 确认目的地"
            "2. 选择日期"
            "3. 搜索航班"
            "4. 完成预订")
    :preconditions (:has-destination t :has-dates t)
    :tools ("flight-search" "booking-api")))

;; 检索过程
(procedural-recall *procedural* "book-flight")

;; 按工具检索
(procedural-search *procedural* :uses-tool "flight-search")
```

## 检索策略

```lisp
;; 语义检索（向量相似度）
(make-retrieval-strategy :semantic
  :embedding-fn #'embed
  :top-k 5)

;; 时间检索（最近优先）
(make-retrieval-strategy :recency
  :decay-factor 0.9)

;; 频率检索（访问频率）
(make-retrieval-strategy :frequency)

;; 重要性检索（优先级排序）
(make-retrieval-strategy :importance
  :importance-fn #'calculate-importance)

;; 混合检索
(make-retrieval-strategy :hybrid
  :strategies '((:semantic :weight 0.5)
                (:recency :weight 0.3)
                (:importance :weight 0.2)))
```

## 摘要缓冲

自动摘要长对话：

```lisp
(defvar *buffer*
  (make-summary-buffer
    :max-messages 20
    :summarize-fn #'summarize-with-llm))

;; 添加消息（自动摘要）
(buffer-add *buffer* message)

;; 获取上下文（包含摘要）
(buffer-get-context *buffer*)
;; => ((:role :system :content "之前的对话摘要: ...")
;;     (:role :user :content "最近的消息1")
;;     (:role :assistant :content "最近的消息2")
;;     ...)
```

## 使用示例

### 带持久化的聊天机器人

```lisp
(defvar *memory*
  (make-agent-memory
    :persistent-store (make-sqlite-store-backend :db-path "chat.db")))

(defvar *agent*
  (make-kernel-agent *kernel*
    :memory *memory*
    :system-prompt "记住用户的偏好和历史对话。"))

;; 第一次会话
(agent-chat *agent* "我叫小明，我喜欢编程")
(am-save-checkpoint *memory* "user-xiaoming"
  '(:name "小明" :interests ("编程")))

;; 重启后...
(let ((cp (am-load-checkpoint *memory* "user-xiaoming")))
  (format t "欢迎回来，~A！~%" (getf (checkpoint-state cp) :name)))
```

### 多用户支持

```lisp
;; 使用不同的 thread-id 区分用户
(am-add-message *memory* "user-alice" :user "Hello")
(am-add-message *memory* "user-bob" :user "Hi")

;; 各自独立的对话历史
(am-get-messages *memory* "user-alice")
(am-get-messages *memory* "user-bob")
```

### 知识库集成

```lisp
(defvar *knowledge* (make-semantic-memory *store*))

;; 导入知识
(semantic-store *knowledge* "product-a"
  '(:name "产品A"
    :price 99.99
    :features ("功能1" "功能2")))

;; Agent 可以检索知识回答问题
(let ((product (semantic-recall *knowledge* "product-a")))
  (format nil "~A 的价格是 ~A 元"
          (getf product :name)
          (getf product :price)))
```
