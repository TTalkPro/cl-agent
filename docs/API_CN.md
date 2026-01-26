# API 参考

[English](API.md)

## 目录

- [Core](#core)
  - [Kernel](#kernel)
  - [Context](#context)
  - [Filter](#filter)
  - [Service](#service)
- [Tools](#tools)
  - [Tool 类](#tool-类)
  - [Tool Registry](#tool-registry)
  - [Tag 过滤](#tag-过滤)
  - [预设配置](#预设配置)
  - [内置工具](#内置工具)
- [LLM](#llm)
  - [Client](#client)
  - [Providers](#providers)
- [SimpleAgent](#simpleagent)
  - [KernelAgent](#kernelagent)
  - [ProcessAgent](#processagent)
- [Memory](#memory)
- [RAG](#rag)
- [MCP](#mcp)

---

## Core

### Kernel

Kernel 是中央协调器，持有 Service、Tool Registry、Filters 和 Config。

#### `make-kernel`

```lisp
(make-kernel &key service tool-registry active-tags tag-filter-mode filters config context) => kernel
```

创建新的 Kernel 实例。

**参数：**
- `service` - LLM 服务抽象
- `tool-registry` - 工具注册表
- `active-tags` - 活跃标签（用于过滤）
- `tag-filter-mode` - 过滤模式（`:any` 或 `:all`）
- `filters` - 过滤器对象列表
- `config` - 配置属性列表
- `context` - 执行上下文

**示例：**
```lisp
(make-kernel
  :service my-service
  :tool-registry registry
  :active-tags '(:safe :utility)
  :filters (list logging-filter))
```

#### `create-kernel-builder`

```lisp
(create-kernel-builder) => kernel-builder
```

创建 Kernel Builder。

#### `build-kernel`

```lisp
(build-kernel builder) => kernel
```

从 Builder 构建 Kernel。

#### Builder 方法

```lisp
;; 添加服务
(add-service builder provider) => builder

;; 添加单个工具
(with-tool builder tool) => builder

;; 添加多个工具
(with-tools builder tool-list) => builder

;; 使用预设
(with-preset builder preset &key security-level) => builder

;; 设置活跃标签
(with-active-tags builder tags &key mode) => builder

;; 添加过滤器
(add-filter builder filter) => builder
```

**示例：**
```lisp
(build-kernel
  (with-active-tags
    (with-preset
      (add-service
        (create-kernel-builder)
        *provider*)
      :safe
      :security-level :standard)
    '(:safe :utility)
    :mode :any))
```

#### Kernel 查询 API

```lisp
;; 查找工具
(kernel-find-tool kernel tool-name) => tool

;; 执行工具
(kernel-execute-tool kernel tool-name args) => result

;; 获取工具 Schema（支持 Tag 过滤）
(kernel-get-tools kernel &key tags) => list

;; 列出工具信息（支持 Tag 过滤）
(kernel-list-tools kernel &key tags) => list

;; 工具数量
(kernel-tool-count kernel) => integer

;; 是否有工具
(kernel-has-tool-p kernel tool-name) => boolean
```

#### Kernel 工具管理 API

```lisp
;; 注册工具
(kernel-register-tool kernel tool) => kernel

;; 批量注册
(kernel-register-tools kernel tools) => kernel

;; 注销工具
(kernel-unregister-tool kernel tool-name) => kernel

;; 设置活跃标签
(kernel-set-active-tags kernel tags) => kernel

;; 清除活跃标签
(kernel-clear-active-tags kernel) => kernel
```

#### 3 层 Invoke API

```lisp
;; Tier 1: 工具执行
(invoke kernel tool-name args &key context) => result
(invoke-tool kernel context tool-name args) => result

;; Tier 2: 单次 LLM 调用
(invoke-chat kernel messages &key settings) => response
(invoke-chat-stream kernel messages &key on-token) => nil

;; Tier 3: 完整工具循环
(invoke-kernel kernel messages &key settings) => response
(invoke-chat-with-tools kernel messages &key settings) => response
```

---

### Context

执行上下文，追踪变量、消息、历史和执行轨迹。

```lisp
(make-context &key messages metadata) => context
(context-get context key) => value
(context-set context key value) => value
(context-add-message context message) => context
(context-get-messages context) => list
```

---

### Filter

过滤器在 4 个点拦截执行。

```lisp
(make-filter &key type name fn priority) => filter
```

**类型：**
- `:pre-invocation` - 工具执行前
- `:post-invocation` - 工具执行后
- `:pre-chat` - LLM 调用前
- `:post-chat` - LLM 调用后

---

### Service

LLM 抽象。

```lisp
(make-service &key chat-fn build-result-msgs-fn provider) => service
(service-from-provider provider) => service
```

---

## Tools

### Tool 类

```lisp
(defclass tool ()
  ((name :type keyword)
   (description :type string)
   (handler :type function)
   (parameters :type list)
   (category :type keyword)
   (tags :type list)
   (permissions :type list)
   (metadata)))
```

#### `make-simple-tool`

```lisp
(make-simple-tool name description handler &key parameters category tags permissions metadata) => tool
```

创建工具实例。

**参数：**
- `name` - 工具名称（关键字）
- `description` - 工具描述
- `handler` - 执行函数 `(lambda (&key ...) ...)`
- `parameters` - 参数定义列表
- `category` - 分类（默认 `:custom`）
- `tags` - 标签列表
- `permissions` - 权限列表
- `metadata` - 元数据

**示例：**
```lisp
(make-simple-tool
  :greet
  "问候用户"
  (lambda (&key name)
    (format nil "你好，~A！" name))
  :parameters '((:name :type :string :description "用户名" :required-p t))
  :tags '(:utility :safe))
```

#### Tag 辅助函数

```lisp
(tool-has-tag-p tool tag) => boolean
(tool-has-any-tag-p tool tags) => boolean
(tool-has-all-tags-p tool tags) => boolean
(tool-add-tag tool tag) => tool
(tool-remove-tag tool tag) => tool
(tool-set-tags tool tags) => tool
```

---

### Tool Registry

```lisp
(make-tool-registry) => registry
(register-tool registry tool) => tool
(unregister-tool registry tool-name) => boolean
(find-tool registry tool-name) => tool
(list-tools registry &key category) => list
(registry-tool-count registry) => integer
```

---

### Tag 过滤

```lisp
;; 按单个标签
(list-tools-by-tag registry tag) => list

;; 按多个标签
(list-tools-by-tags registry tags &key mode) => list
;; mode: :any (默认) 或 :all

;; 获取过滤后的 Schema
(get-tools-schema-by-tags registry tags &key mode) => list

;; 列出所有标签
(list-all-tags registry) => list

;; 统计
(count-tools-by-tag registry tag) => integer
```

---

### 预设配置

#### 安全级别

| 级别 | 关键字 | 描述 |
|------|--------|------|
| 宽松 | `:permissive` | 最少限制 |
| 标准 | `:standard` | 平衡模式 |
| 严格 | `:strict` | 最大限制 |

#### 工具预设

| 预设 | 关键字 | 描述 |
|------|--------|------|
| 标准 | `:standard` | 文件 + HTTP + 实用工具 |
| 安全 | `:safe` | 只读操作 |
| 完整 | `:full` | 全部工具（含 Shell） |
| 仅文件 | `:file-only` | 仅文件操作 |
| 仅 HTTP | `:http-only` | 仅 HTTP 操作 |
| 仅实用工具 | `:utility-only` | 仅实用工具 |

```lisp
;; 快速获取预设工具
(quick-setup-tools &key preset security-level) => list

;; 列出可用预设
(list-all-presets) => list

;; 查看预设描述
(describe-preset preset) => string
```

---

### 内置工具

#### 文件工具

```lisp
(make-read-file-tool) => tool      ; 标签: (:file :io :read :safe)
(make-write-file-tool) => tool     ; 标签: (:file :io :write)
(make-delete-file-tool) => tool    ; 标签: (:file :io :write :dangerous)
(make-list-directory-tool) => tool ; 标签: (:file :io :read :safe)
(create-file-tools) => list
```

#### HTTP 工具

```lisp
(make-http-get-tool) => tool   ; 标签: (:http :network :read :safe)
(make-http-post-tool) => tool  ; 标签: (:http :network :write)
(create-http-tools) => list
```

#### Shell 工具

```lisp
(make-execute-command-tool) => tool  ; 标签: (:shell :system :dangerous)
(create-shell-tools) => list
```

#### 实用工具

```lisp
(make-get-timestamp-tool) => tool    ; 标签: (:utility :safe)
(make-generate-uuid-tool) => tool    ; 标签: (:utility :safe)
(make-json-parse-tool) => tool       ; 标签: (:utility :safe)
(make-json-stringify-tool) => tool   ; 标签: (:utility :safe)
(make-string-replace-tool) => tool   ; 标签: (:utility :safe)
(make-math-eval-tool) => tool        ; 标签: (:utility :safe)
(create-utility-tools) => list
```

---

## LLM

### Client

```lisp
(make-client &key provider model api-key base-url max-tokens temperature) => client
(chat client messages &key tools temperature max-tokens) => response
(chat-stream client messages &key on-token on-complete) => nil
```

### Providers

| 提供商 | 关键字 | 默认模型 |
|--------|--------|----------|
| Anthropic | `:anthropic` | claude-3-5-sonnet-20241022 |
| OpenAI | `:openai` | gpt-4o |
| 智谱 AI | `:zhipu` | glm-4-turbo |
| Ollama | `:ollama` | llama2 |

---

## SimpleAgent

### KernelAgent

```lisp
(make-kernel-agent kernel &key name system-prompt settings callbacks) => agent
(agent-chat agent message &key verbose) => response
```

### ProcessAgent

```lisp
(make-process-agent kernel) => agent
(agent-start agent message) => nil
(agent-pause agent) => nil
(agent-resume agent) => nil
(agent-stop agent) => nil
```

---

## Memory

### Store

```lisp
(make-memory-store-backend) => store
(make-sqlite-store-backend &key db-path) => store
(store-put store namespace key value) => value
(store-get store namespace key) => value
(store-delete store namespace key) => boolean
(store-list-keys store namespace) => list
```

### Checkpoint

```lisp
(save-checkpoint checkpointer thread-id state) => checkpoint
(load-checkpoint checkpointer thread-id) => checkpoint
```

### Agent Memory

```lisp
(make-agent-memory &key context-store persistent-store default-thread-id) => memory
(am-add-message memory thread-id role content) => message
(am-get-messages memory thread-id) => list
(am-save-checkpoint memory thread-id state) => checkpoint
(am-load-checkpoint memory checkpoint-id) => checkpoint
```

---

## RAG

### Pipeline

```lisp
(make-rag-pipeline &key embeddings-model vector-store splitter) => pipeline
(rag-retrieve pipeline query &key top-k) => list
(rag-query pipeline question &key top-k) => response
```

### Vector Store

```lisp
(make-vector-store) => store
(vector-store-add-document store content embedding &key metadata) => document
(vector-store-search store query-embedding &key top-k) => list
```

---

## MCP

### Client

```lisp
(make-mcp-client &key transport) => client
(mcp-client-connect client) => nil
(mcp-client-call-tool client tool-name args) => result
```

### Server

```lisp
(make-mcp-server &key transport) => server
(mcp-server-start server) => nil
(mcp-register-tool server tool-name fn) => nil
```
