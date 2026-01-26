# 快速开始指南

[English](QUICKSTART.md)

本指南将帮助你快速上手 CL-Agent。

## 目录

- [安装](#安装)
- [基本用法](#基本用法)
- [Agent 示例](#agent-示例)
  - [简单聊天 Agent](#简单聊天-agent)
  - [带工具的 Agent](#带工具的-agent)
  - [使用预设](#使用预设)
  - [标签过滤](#标签过滤)
  - [ReAct Agent](#react-agent)
  - [带记忆持久化的 Agent](#带记忆持久化的-agent)
  - [RAG 增强 Agent](#rag-增强-agent)
  - [多轮对话 Agent](#多轮对话-agent)
- [记忆持久化](#记忆持久化)
  - [内存存储](#内存存储)
  - [SQLite 持久化](#sqlite-持久化)
  - [检查点](#检查点)

---

## 安装

### 前置条件

- SBCL（Steel Bank Common Lisp）或其他 CL 实现
- Quicklisp 包管理器

### 设置

```bash
# 克隆仓库
git clone https://github.com/example/cl-agent.git

# 添加到 local-projects
ln -s /path/to/cl-agent ~/quicklisp/local-projects/cl-agent
```

在 REPL 中加载：

```lisp
;; 加载系统
(ql:quickload :cl-agent)

;; 或加载特定模块
(ql:quickload :cl-agent-core)
(ql:quickload :cl-agent-llm)
(ql:quickload :cl-agent-tools)
(ql:quickload :cl-agent-simpleagent)
(ql:quickload :cl-agent-memory)
```

### 环境设置

设置 API 密钥：

```bash
export ANTHROPIC_API_KEY="your-api-key"
export OPENAI_API_KEY="your-api-key"
export ZHIPU_API_KEY="your-api-key"
```

---

## 基本用法

### 创建 LLM 客户端

```lisp
(defpackage :my-agent
  (:use :cl)
  (:import-from :cl-agent.llm
                :make-client
                :chat)
  (:import-from :cl-agent.core
                :get-env))

(in-package :my-agent)

;; 创建 Anthropic Claude 客户端
(defvar *client*
  (make-client
    :provider :anthropic
    :model "claude-3-5-sonnet-20241022"
    :api-key (get-env "ANTHROPIC_API_KEY")))

;; 简单聊天
(chat *client* "什么是 Common Lisp？")
```

### 切换提供商

```lisp
;; OpenAI
(defvar *openai-client*
  (make-client
    :provider :openai
    :model "gpt-4o"
    :api-key (get-env "OPENAI_API_KEY")))

;; 智谱 AI (GLM)
(defvar *zhipu-client*
  (make-client
    :provider :zhipu
    :model "glm-4-turbo"
    :api-key (get-env "ZHIPU_API_KEY")))

;; Ollama（本地）
(defvar *ollama-client*
  (make-client
    :provider :ollama
    :model "llama2"
    :base-url "http://localhost:11434"))
```

---

## Agent 示例

### 简单聊天 Agent

不带工具的基础 Agent：

```lisp
(defpackage :example-simple
  (:use :cl)
  (:import-from :cl-agent.llm :make-client)
  (:import-from :cl-agent.kernel
                :make-kernel :make-service
                :create-kernel-builder :build-kernel :add-service)
  (:import-from :cl-agent.simpleagent :make-kernel-agent :agent-chat))

(in-package :example-simple)

;; 1. 创建 LLM 客户端
(defvar *client*
  (make-client
    :provider :anthropic
    :model "claude-3-5-sonnet-20241022"
    :api-key (uiop:getenv "ANTHROPIC_API_KEY")))

;; 2. 使用 Builder 模式创建 Kernel
(defvar *kernel*
  (build-kernel
    (add-service
      (create-kernel-builder)
      *client*)))

;; 3. 创建 Agent
(defvar *agent*
  (make-kernel-agent *kernel*
    :name "simple-bot"
    :system-prompt "你是一个友好的助手。简洁且有帮助。"))

;; 4. 开始聊天！
(agent-chat *agent* "你好！你能做什么？")
;; => "你好！我可以回答问题、提供信息..."

(agent-chat *agent* "讲个笑话")
;; => "为什么程序员喜欢暗色主题？..."
```

### 带工具的 Agent

可以使用工具的 Agent（新的 tools + tags API）：

```lisp
(defpackage :example-tools
  (:use :cl)
  (:import-from :cl-agent.tools
                :make-simple-tool)
  (:import-from :cl-agent.kernel
                :create-kernel-builder :build-kernel
                :add-service :with-tools)
  (:import-from :cl-agent.simpleagent
                :make-kernel-agent :agent-chat))

(in-package :example-tools)

;; 使用 make-simple-tool 定义工具
(defvar *weather-tool*
  (make-simple-tool
    :get_weather
    "获取指定位置的当前天气"
    (lambda (&key location unit)
      ;; 实际应用中，这里调用天气 API
      (format nil "~A 的天气：22°~A，多云，湿度 65%"
              location (if (string= (or unit "celsius") "celsius") "C" "F")))
    :parameters '((:location :type :string :description "城市或位置名称" :required-p t)
                  (:unit :type :string :description "温度单位（celsius/fahrenheit）"))
    :tags '(:utility :weather :safe)))

(defvar *time-tool*
  (make-simple-tool
    :get_time
    "获取指定时区的当前时间"
    (lambda (&key timezone)
      (format nil "~A 的当前时间：~A"
              (or timezone "UTC")
              (multiple-value-bind (sec min hour)
                  (get-decoded-time)
                (format nil "~2,'0D:~2,'0D:~2,'0D" hour min sec))))
    :parameters '((:timezone :type :string :description "时区名称"))
    :tags '(:utility :time :safe)))

(defvar *calc-tool*
  (make-simple-tool
    :calculate
    "执行数学计算"
    (lambda (&key expression)
      (handler-case
          (format nil "结果：~A" (eval (read-from-string expression)))
        (error (e) (format nil "错误：~A" e))))
    :parameters '((:expression :type :string :description "数学表达式" :required-p t))
    :tags '(:utility :math :safe)))

;; 创建带工具的 Kernel
(defvar *kernel*
  (build-kernel
    (with-tools
      (add-service
        (create-kernel-builder)
        *client*)
      (list *weather-tool* *time-tool* *calc-tool*))))

;; 创建 Agent
(defvar *agent*
  (make-kernel-agent *kernel*
    :name "utility-bot"
    :system-prompt "你是一个有帮助的助手，可以使用天气、时间和计算工具。"))

;; 使用 Agent
(agent-chat *agent* "东京的天气怎么样？")
;; Agent 会调用 get_weather 工具并回复

(agent-chat *agent* "15 * 23 + 7 等于多少？")
;; Agent 会调用 calculate 工具并回复

(agent-chat *agent* "纽约现在几点？")
;; Agent 会调用 get_time 工具并回复
```

### 使用预设

使用内置工具预设快速配置：

```lisp
(defpackage :example-presets
  (:use :cl)
  (:import-from :cl-agent.kernel
                :create-kernel-builder :build-kernel
                :add-service :with-preset)
  (:import-from :cl-agent.simpleagent
                :make-kernel-agent :agent-chat))

(in-package :example-presets)

;; 创建带预设工具的 Kernel
(defvar *kernel*
  (build-kernel
    (with-preset
      (add-service
        (create-kernel-builder)
        *client*)
      :safe                      ; 预设: :standard :safe :full :file-only :http-only :utility-only
      :security-level :standard))) ; 安全级别: :permissive :standard :strict

;; 创建带预设工具的 Agent
(defvar *agent*
  (make-kernel-agent *kernel*
    :name "safe-bot"
    :system-prompt "你是一个有帮助的助手，配备安全的只读工具。"))

;; Agent 可以使用安全工具如 read-file、http-get、get-timestamp
(agent-chat *agent* "读取 /etc/hostname 的内容")
```

### 标签过滤

使用标签在运行时过滤工具：

```lisp
(defpackage :example-tags
  (:use :cl)
  (:import-from :cl-agent.kernel
                :create-kernel-builder :build-kernel
                :add-service :with-preset :with-active-tags
                :kernel-set-active-tags :kernel-clear-active-tags
                :kernel-list-tools)
  (:import-from :cl-agent.simpleagent
                :make-kernel-agent :agent-chat))

(in-package :example-tags)

;; 创建完整预设的 Kernel，但过滤为仅安全工具
(defvar *kernel*
  (build-kernel
    (with-active-tags
      (with-preset
        (add-service
          (create-kernel-builder)
          *client*)
        :full)                   ; 加载所有工具
      '(:safe :utility)          ; 但只启用安全实用工具
      :mode :any)))              ; 匹配任一标签 (:any 或 :all)

;; 列出活跃工具
(kernel-list-tools *kernel*)

;; 运行时更改活跃标签
(kernel-set-active-tags *kernel* '(:file :read))  ; 切换到文件读取工具
(kernel-clear-active-tags *kernel*)               ; 启用所有工具
```

### ReAct Agent

逐步思考的 Agent：

```lisp
(defpackage :example-react
  (:use :cl)
  (:import-from :cl-agent.tools
                :make-simple-tool)
  (:import-from :cl-agent.kernel
                :create-kernel-builder :build-kernel
                :add-service :with-tools)
  (:import-from :cl-agent.simpleagent
                :make-kernel-agent :agent-chat))

(in-package :example-react)

;; 定义研究工具
(defvar *search-tool*
  (make-simple-tool
    :web_search
    "在网上搜索信息"
    (lambda (&key query)
      ;; 模拟搜索结果
      (format nil "'~A' 的搜索结果：~%1. 维基百科文章...~%2. 新闻文章..."
              query))
    :parameters '((:query :type :string :description "搜索查询" :required-p t))
    :tags '(:research :safe)))

(defvar *read-url-tool*
  (make-simple-tool
    :read_url
    "读取 URL 内容"
    (lambda (&key url)
      (format nil "来自 ~A 的内容：[文章内容...]" url))
    :parameters '((:url :type :string :description "要读取的 URL" :required-p t))
    :tags '(:research :network :safe)))

;; 创建带研究工具的 Kernel
(defvar *kernel*
  (build-kernel
    (with-tools
      (add-service
        (create-kernel-builder)
        *client*)
      (list *search-tool* *read-url-tool*))))

;; ReAct 系统提示
(defvar *react-prompt*
  "你是一个逐步思考的研究助手。

对于每个问题，遵循以下模式：
1. 思考：想想你需要找什么
2. 行动：使用工具收集信息
3. 观察：分析工具结果
4. 如需要则重复
5. 最终答案：提供你的结论

始终解释你的推理过程。")

;; 创建 ReAct Agent
(defvar *react-agent*
  (make-kernel-agent *kernel*
    :name "react-researcher"
    :system-prompt *react-prompt*
    :settings '(:max-iterations 10)))

;; 用于研究任务
(agent-chat *react-agent*
  "法国的首都是什么，人口是多少？")
;; Agent 会：
;; 1. 思考要搜索什么
;; 2. 搜索"法国首都"
;; 3. 搜索"巴黎人口"
;; 4. 综合结果并回答
```

### 带记忆持久化的 Agent

记住对话的 Agent：

```lisp
(defpackage :example-memory
  (:use :cl)
  (:import-from :cl-agent.memory
                :make-agent-memory
                :make-memory-store-backend
                :make-sqlite-store-backend
                :am-add-message
                :am-get-messages
                :am-save-checkpoint
                :am-load-checkpoint)
  (:import-from :cl-agent.kernel
                :create-kernel-builder :build-kernel :add-service)
  (:import-from :cl-agent.simpleagent
                :make-kernel-agent :agent-chat))

(in-package :example-memory)

;; ============================================
;; 示例 1：内存存储（基于会话）
;; ============================================

(defvar *memory*
  (make-agent-memory
    :context-store (make-memory-store-backend)
    :default-thread-id "session-1"))

;; 创建 Kernel
(defvar *kernel*
  (build-kernel
    (add-service
      (create-kernel-builder)
      *client*)))

;; 创建带记忆的 Agent
(defvar *agent*
  (make-kernel-agent *kernel*
    :name "memory-bot"
    :memory *memory*
    :system-prompt "你是一个有帮助的助手。记住用户偏好。"))

;; 带记忆的对话
(agent-chat *agent* "我叫小明，我喜欢用中文交流。")
(agent-chat *agent* "我叫什么名字？")
;; => "你叫小明。"

(agent-chat *agent* "我喜欢用什么语言？")
;; => "你喜欢用中文交流。"

;; ============================================
;; 示例 2：SQLite 持久化（长期存储）
;; ============================================

(defvar *persistent-memory*
  (make-agent-memory
    :context-store (make-memory-store-backend)
    :persistent-store (make-sqlite-store-backend
                        :db-path "/path/to/agent-memory.db")
    :default-thread-id "user-123"
    :auto-archive t))

(defvar *persistent-agent*
  (make-kernel-agent *kernel*
    :name "persistent-bot"
    :memory *persistent-memory*
    :system-prompt "你记得与这位用户的所有过去对话。"))

;; 第一次会话
(agent-chat *persistent-agent* "我正在学习 Common Lisp")
(agent-chat *persistent-agent* "我最喜欢的编辑器是 Emacs")

;; 关闭前保存状态
(am-save-checkpoint *persistent-memory* "user-123"
  '(:last-topic "Common Lisp"
    :preferences (:editor "Emacs")))

;; ... 应用重启 ...

;; 稍后的会话 - 从检查点恢复
(let ((checkpoint (am-load-checkpoint *persistent-memory* "user-123")))
  (format t "上次话题：~A~%"
          (getf (checkpoint-state checkpoint) :last-topic)))

;; 继续对话
(agent-chat *persistent-agent* "我在学什么来着？")
;; => "你在学习 Common Lisp！"

;; ============================================
;; 示例 3：多线程记忆
;; ============================================

;; 不同线程用于不同上下文
(am-add-message *memory* "work-thread" :user "讨论项目截止日期")
(am-add-message *memory* "personal-thread" :user "计划周末活动")

;; 在线程之间切换
(agent-chat *agent* "继续我们的工作讨论"
  :thread-id "work-thread")

(agent-chat *agent* "我的周末计划呢？"
  :thread-id "personal-thread")

;; ============================================
;; 示例 4：检查点和恢复
;; ============================================

;; 保存带完整状态的检查点
(defvar *checkpoint-id*
  (am-save-checkpoint *memory* "session-1"
    '(:conversation-summary "用户是小明，喜欢中文"
      :user-facts ((:name "小明")
                   (:preference "中文"))
      :last-interaction-time "2024-01-15T10:30:00Z")))

;; 列出线程中的所有消息
(let ((messages (am-get-messages *memory* "session-1")))
  (dolist (msg messages)
    (format t "~A: ~A~%"
            (memory-message-role msg)
            (memory-message-content msg))))

;; 从检查点恢复
(let ((checkpoint (am-load-checkpoint *memory* *checkpoint-id*)))
  (format t "恢复的状态：~A~%" (checkpoint-state checkpoint)))
```

### RAG 增强 Agent

带文档检索的 Agent：

```lisp
(defpackage :example-rag
  (:use :cl)
  (:import-from :cl-agent.rag
                :make-rag-pipeline
                :make-text-splitter
                :make-vector-store
                :make-local-embeddings
                :vector-store-add-document
                :rag-query)
  (:import-from :cl-agent.kernel
                :create-kernel-builder :build-kernel
                :add-service :add-filter :make-filter)
  (:import-from :cl-agent.simpleagent
                :make-kernel-agent :agent-chat))

(in-package :example-rag)

;; 1. 设置 RAG 组件
(defvar *embeddings* (make-local-embeddings))
(defvar *vector-store* (make-vector-store))
(defvar *splitter* (make-text-splitter :chunk-size 500 :chunk-overlap 50))

;; 2. 创建 RAG 管道
(defvar *rag*
  (make-rag-pipeline
    :embeddings-model *embeddings*
    :vector-store *vector-store*
    :splitter *splitter*))

;; 3. 索引一些文档
(defun index-document (content metadata)
  (let ((embedding (embed *embeddings* content)))
    (vector-store-add-document *vector-store*
      content embedding :metadata metadata)))

;; 索引示例文档
(index-document
  "Common Lisp 是 Lisp 编程语言的一种方言。
   它于 1994 年被 ANSI 标准化。Common Lisp 以其
   强大的宏系统和动态类型而闻名。"
  '(:source "lisp-intro.txt" :topic "编程"))

(index-document
  "SBCL（Steel Bank Common Lisp）是一个高性能的
   Common Lisp 编译器。它是自由软件，可在
   Linux、macOS 和 Windows 等多个平台上运行。"
  '(:source "sbcl-docs.txt" :topic "实现"))

;; 4. 为 Kernel 创建 RAG 过滤器
(defvar *rag-filter*
  (make-filter
    :type :pre-chat
    :name "rag-context"
    :fn (lambda (ctx next)
          ;; 在 LLM 调用前检索相关上下文
          (let* ((query (context-get-variable ctx "user-message"))
                 (results (rag-retrieve *rag* query :top-k 3)))
            (context-set-variable ctx "rag-context" results))
          (funcall next ctx))))

;; 5. 创建带 RAG 过滤器的 Kernel
(defvar *kernel*
  (build-kernel
    (add-filter
      (add-service
        (create-kernel-builder)
        *client*)
      *rag-filter*)))

;; 6. 创建 RAG 增强的 Agent
(defvar *rag-agent*
  (make-kernel-agent *kernel*
    :name "rag-assistant"
    :system-prompt "你是一个有帮助的助手。使用提供的上下文准确回答问题。如果上下文中没有相关信息，请说明。"))

;; 7. 使用 RAG 查询
(agent-chat *rag-agent* "什么是 Common Lisp？")
;; Agent 会检索相关块并基于它们回答

(agent-chat *rag-agent* "SBCL 是什么？")
;; Agent 会找到 SBCL 文档并回复
```

### 多轮对话 Agent

复杂多轮对话的 Agent：

```lisp
(defpackage :example-multiturn
  (:use :cl)
  (:import-from :cl-agent.memory
                :make-agent-memory
                :make-memory-store-backend
                :am-add-message
                :am-get-last-n-messages)
  (:import-from :cl-agent.kernel
                :create-kernel-builder :build-kernel :add-service)
  (:import-from :cl-agent.simpleagent
                :make-kernel-agent :agent-chat))

(in-package :example-multiturn)

;; 创建 Kernel
(defvar *kernel*
  (build-kernel
    (add-service
      (create-kernel-builder)
      *client*)))

;; 创建带摘要缓冲区的记忆（用于长对话）
(defvar *memory*
  (make-agent-memory
    :context-store (make-memory-store-backend)
    :default-thread-id "conversation-1"
    :config '(:max-messages 50
              :summarize-after 20)))

;; 创建对话 Agent
(defvar *conv-agent*
  (make-kernel-agent *kernel*
    :name "conversation-agent"
    :memory *memory*
    :system-prompt "你正在进行自然对话。记住之前的上下文并保持连贯的对话。"))

;; 多轮对话
(agent-chat *conv-agent* "我想计划一次日本之旅")
;; => "听起来很棒！你打算什么时候去？"

(agent-chat *conv-agent* "可能四月去看樱花")
;; => "四月是看樱花的最佳时节！你决定去哪些城市了吗？"

(agent-chat *conv-agent* "我想去东京和京都")
;; => "很好的选择！东京体验现代日本，京都感受传统文化..."

(agent-chat *conv-agent* "第一个城市我应该看什么？")
;; => "在东京，我推荐..."（Agent 记得"第一个城市" = 东京）

;; 获取对话历史
(let ((recent (am-get-last-n-messages *memory* "conversation-1" 5)))
  (dolist (msg recent)
    (format t "~A: ~A~%~%"
            (memory-message-role msg)
            (memory-message-content msg))))
```

---

## 记忆持久化

### 内存存储

快速的基于会话的存储：

```lisp
(defvar *memory-store* (make-memory-store-backend))

;; 存储数据
(store-put *memory-store* '("users") "alice" '(:name "Alice" :age 30))
(store-put *memory-store* '("users") "bob" '(:name "Bob" :age 25))

;; 检索
(store-get *memory-store* '("users") "alice")
;; => (:NAME "Alice" :AGE 30)

;; 列出键
(store-list-keys *memory-store* '("users"))
;; => ("alice" "bob")

;; 删除
(store-delete *memory-store* '("users") "bob")
```

### SQLite 持久化

持久的基于文件的存储：

```lisp
(defvar *sqlite-store*
  (make-sqlite-store-backend :db-path "~/.cl-agent/memory.db"))

;; 与内存存储相同的 API
(store-put *sqlite-store* '("facts") "lisp-creator" "John McCarthy")
(store-get *sqlite-store* '("facts") "lisp-creator")
;; => "John McCarthy"

;; 数据跨会话持久化！
```

### 检查点

保存和恢复 Agent 状态：

```lisp
;; 保存检查点
(let ((cp (save-checkpoint *checkpointer* "thread-1"
            '(:messages-count 50
              :summary "用户讨论了日本旅行计划"
              :preferences (:travel-style "文化"
                           :budget "中等")))))
  (format t "已保存检查点：~A~%" (checkpoint-id cp)))

;; 加载检查点
(let ((cp (load-checkpoint *checkpointer* "thread-1")))
  (when cp
    (format t "状态：~A~%" (checkpoint-state cp))
    (format t "时间戳：~A~%" (checkpoint-timestamp cp))))

;; 列出线程的所有检查点
(let ((checkpoints (list-checkpoints *checkpointer* :thread-id "thread-1")))
  (dolist (cp checkpoints)
    (format t "~A 于 ~A~%"
            (checkpoint-id cp)
            (checkpoint-timestamp cp))))

;; 从检查点创建分支
(let ((branch-id (create-branch *checkpointer* "thread-1" "experiment-1")))
  (format t "已创建分支：~A~%" branch-id))
```

---

## 下一步

- 阅读 [API 参考](API_CN.md) 获取详细文档
- 探索 `examples/` 目录获取更多代码示例
- 查看 `tests/` 了解使用模式
