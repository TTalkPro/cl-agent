# API 参考

[English](API.md)

## 目录

- [Core](#core)
  - [Kernel](#kernel)
  - [Context](#context)
  - [Tool & Plugin](#tool--plugin)
  - [Filter](#filter)
  - [Service](#service)
- [LLM](#llm)
  - [Client](#client)
  - [Providers](#providers)
- [SimpleAgent](#simpleagent)
  - [KernelAgent](#kernelagent)
  - [ProcessAgent](#processagent)
- [Memory](#memory)
  - [Store](#store)
  - [Checkpoint](#checkpoint)
  - [Agent Memory](#agent-memory)
- [RAG](#rag)
  - [Pipeline](#pipeline)
  - [Vector Store](#vector-store)
- [MCP](#mcp)

---

## Core

### Kernel

Kernel 是中央协调器，持有 Service、Plugins、Filters 和 Config。

#### `make-kernel`

```lisp
(make-kernel &key service plugins filters config) => kernel
```

创建新的 Kernel 实例。

**参数：**
- `service` - LLM 服务抽象
- `plugins` - 插件符号列表
- `filters` - 过滤器对象列表
- `config` - 配置属性列表

**示例：**
```lisp
(make-kernel
  :service my-service
  :plugins '(weather-plugin math-plugin)
  :filters (list logging-filter))
```

#### `kernel-get-tools`

```lisp
(kernel-get-tools kernel) => list
```

获取所有已注册插件的工具 schema。

#### `kernel-get-schema`

```lisp
(kernel-get-schema kernel tool-name) => hash-table
```

获取特定工具的 schema。

#### `invoke-tool`

```lisp
(invoke-tool kernel context tool-name args) => result
```

执行单个工具。

#### `invoke-chat`

```lisp
(invoke-chat kernel context messages settings) => response
```

执行单次 LLM 调用。

#### `invoke-kernel`

```lisp
(invoke-kernel kernel context messages) => response
```

执行完整的工具调用循环，直到没有更多工具调用。

---

### Context

执行上下文，追踪变量、消息、历史和执行轨迹。

#### `make-context`

```lisp
(make-context &key messages metadata) => context
```

创建新的 Context 实例。

#### `context-get-variable`

```lisp
(context-get-variable context key) => value
```

从上下文获取变量。

#### `context-set-variable`

```lisp
(context-set-variable context key value) => value
```

在上下文中设置变量。

#### `context-add-message`

```lisp
(context-add-message context message) => context
```

向上下文添加消息。

---

### Tool & Plugin

#### `deftool`

```lisp
(deftool name description parameters &body body)
```

定义带元数据的工具函数。

**参数：**
- `name` - 工具函数名称
- `description` - 供 LLM 使用的工具描述
- `parameters` - 参数规格 `((name type desc &key required-p default) ...)`
- `body` - 函数体

**示例：**
```lisp
(deftool calculate "执行计算"
  ((expression :string "数学表达式" :required-p t))
  (eval (read-from-string expression)))
```

#### `defplugin`

```lisp
(defplugin name description &rest tools)
```

定义包含多个工具的插件。

**示例：**
```lisp
(defplugin math-plugin "数学运算"
  calculate
  convert-units)
```

#### `declare-tool`

```lisp
(declare-tool symbol &key description parameters category)
```

在现有函数上声明工具元数据。

#### `declare-plugin`

```lisp
(declare-plugin symbol description tools)
```

声明插件元数据。

#### `tool-function-p`

```lisp
(tool-function-p symbol) => boolean
```

检查符号是否为工具函数。

#### `tool-schema`

```lisp
(tool-schema symbol) => hash-table
```

获取工具的 JSON Schema。

---

### Filter

过滤器在 4 个点拦截执行：pre-invocation、post-invocation、pre-chat、post-chat。

#### `make-filter`

```lisp
(make-filter &key type name fn priority) => filter
```

创建过滤器。

**参数：**
- `type` - `:pre-invocation`、`:post-invocation`、`:pre-chat`、`:post-chat` 之一
- `name` - 过滤器名称字符串
- `fn` - 过滤器函数 `(context next-fn) => result`
- `priority` - 整数优先级（越高越早执行）

**示例：**
```lisp
(make-filter
  :type :pre-invocation
  :name "logging"
  :fn (lambda (ctx next)
        (format t "执行工具...~%")
        (funcall next ctx))
  :priority 10)
```

---

### Service

LLM 抽象，将 Kernel 与具体实现解耦。

#### `make-service`

```lisp
(make-service &key chat-fn build-result-msgs-fn provider) => service
```

创建 Service 实例。

**参数：**
- `chat-fn` - LLM 聊天函数
- `build-result-msgs-fn` - 构建结果消息的函数
- `provider` - LLM 提供商实例

---

## LLM

### Client

#### `make-client`

```lisp
(make-client &key provider model api-key base-url max-tokens temperature) => client
```

创建 LLM 客户端。

**参数：**
- `provider` - 提供商关键字（`:anthropic`、`:openai`、`:zhipu`、`:ollama`）
- `model` - 模型名称字符串
- `api-key` - API 密钥字符串
- `base-url` - 可选的自定义 API 基础 URL
- `max-tokens` - 最大响应 token 数
- `temperature` - 采样温度

**示例：**
```lisp
(make-client
  :provider :anthropic
  :model "claude-3-5-sonnet-20241022"
  :api-key "sk-...")
```

#### `chat`

```lisp
(chat client messages &key tools temperature max-tokens) => response
```

向 LLM 发送聊天请求。

**参数：**
- `client` - LLM 客户端
- `messages` - 字符串或消息属性列表的列表
- `tools` - 可选的工具 schema
- `temperature` - 可选的温度覆盖
- `max-tokens` - 可选的最大 token 覆盖

**示例：**
```lisp
;; 简单字符串
(chat client "你好！")

;; 多轮对话
(chat client
  '((:role :user :content "嗨")
    (:role :assistant :content "你好！")
    (:role :user :content "你好吗？")))
```

#### `chat-stream`

```lisp
(chat-stream client messages &key on-token on-complete) => nil
```

流式输出聊天响应。

**参数：**
- `on-token` - 每个 token 的回调 `(token) => nil`
- `on-complete` - 完成时的回调 `(full-response) => nil`

---

### Providers

支持的提供商：

| 提供商 | 关键字 | 默认模型 |
|--------|--------|----------|
| Anthropic | `:anthropic` | claude-3-5-sonnet-20241022 |
| OpenAI | `:openai` | gpt-4o |
| 智谱 AI | `:zhipu` | glm-4-turbo |
| Ollama | `:ollama` | llama2 |

---

## SimpleAgent

### KernelAgent

包装 Kernel 的简单聊天 Agent。

#### `make-kernel-agent`

```lisp
(make-kernel-agent kernel &key name system-prompt settings callbacks) => agent
```

创建 KernelAgent。

**参数：**
- `kernel` - Kernel 实例
- `name` - Agent 名称
- `system-prompt` - 系统提示字符串
- `settings` - 设置属性列表（`:max-iterations` 等）
- `callbacks` - 回调函数

#### `agent-chat`

```lisp
(agent-chat agent message &key verbose) => response
```

与 Agent 对话。

---

### ProcessAgent

支持暂停/恢复的 Agent。

#### `make-process-agent`

```lisp
(make-process-agent kernel) => agent
```

#### `agent-start`

```lisp
(agent-start agent message) => nil
```

使用初始消息启动 Agent。

#### `agent-pause`

```lisp
(agent-pause agent) => nil
```

暂停 Agent 执行。

#### `agent-resume`

```lisp
(agent-resume agent) => nil
```

恢复暂停的 Agent。

#### `agent-stop`

```lisp
(agent-stop agent) => nil
```

停止 Agent。

---

## Memory

### Store

长期持久化存储协议。

#### `make-memory-store-backend`

```lisp
(make-memory-store-backend) => store
```

创建内存存储后端。

#### `make-sqlite-store-backend`

```lisp
(make-sqlite-store-backend &key db-path) => store
```

创建 SQLite 存储后端。

#### `store-put`

```lisp
(store-put store namespace key value) => value
```

存储值。

#### `store-get`

```lisp
(store-get store namespace key) => value
```

获取值。

#### `store-delete`

```lisp
(store-delete store namespace key) => boolean
```

删除值。

#### `store-list-keys`

```lisp
(store-list-keys store namespace) => list
```

列出命名空间中的所有键。

---

### Checkpoint

短期状态快照。

#### `save-checkpoint`

```lisp
(save-checkpoint checkpointer thread-id state) => checkpoint
```

保存检查点。

#### `load-checkpoint`

```lisp
(load-checkpoint checkpointer thread-id) => checkpoint
```

加载线程的最新检查点。

---

### Agent Memory

统一的记忆接口。

#### `make-agent-memory`

```lisp
(make-agent-memory &key context-store persistent-store default-thread-id) => memory
```

创建 Agent Memory。

#### `am-add-message`

```lisp
(am-add-message memory thread-id role content) => message
```

向线程添加消息。

#### `am-get-messages`

```lisp
(am-get-messages memory thread-id) => list
```

获取线程中的所有消息。

#### `am-save-checkpoint`

```lisp
(am-save-checkpoint memory thread-id state) => checkpoint
```

保存检查点。

#### `am-load-checkpoint`

```lisp
(am-load-checkpoint memory checkpoint-id) => checkpoint
```

加载检查点。

---

## RAG

### Pipeline

#### `make-rag-pipeline`

```lisp
(make-rag-pipeline &key embeddings-model vector-store splitter) => pipeline
```

创建 RAG 管道。

#### `rag-retrieve`

```lisp
(rag-retrieve pipeline query &key top-k) => list
```

检索相关文档。

#### `rag-query`

```lisp
(rag-query pipeline question &key top-k) => response
```

使用 RAG 上下文查询。

---

### Vector Store

#### `make-vector-store`

```lisp
(make-vector-store) => store
```

创建向量存储。

#### `vector-store-add-document`

```lisp
(vector-store-add-document store content embedding &key metadata) => document
```

向存储添加文档。

#### `vector-store-search`

```lisp
(vector-store-search store query-embedding &key top-k) => list
```

搜索相似文档。

---

## MCP

### Client

#### `make-mcp-client`

```lisp
(make-mcp-client &key transport) => client
```

创建 MCP 客户端。

#### `mcp-client-connect`

```lisp
(mcp-client-connect client) => nil
```

连接到 MCP 服务器。

#### `mcp-client-call-tool`

```lisp
(mcp-client-call-tool client tool-name args) => result
```

通过 MCP 调用工具。

### Server

#### `make-mcp-server`

```lisp
(make-mcp-server &key transport) => server
```

创建 MCP 服务器。

#### `mcp-server-start`

```lisp
(mcp-server-start server) => nil
```

启动 MCP 服务器。

#### `mcp-register-tool`

```lisp
(mcp-register-tool server tool-name fn) => nil
```

向服务器注册工具。
