# CL-Agent

[English](README_EN.md)

基于 Common Lisp 的统一 AI Agent 框架，采用语义内核架构和 7 层模块化设计。

## 特性

- **多提供商 LLM 支持**：Anthropic Claude、OpenAI GPT、智谱 GLM、Ollama
- **灵活的工具系统**：直接工具注册 + Tag 标签过滤
- **工具预设**：内置安全级别和功能预设，快速配置
- **全面的记忆管理**：短期检查点 + 长期持久化存储
- **RAG 管道**：文本分割、嵌入、向量存储、检索
- **协议支持**：MCP（模型上下文协议）+ A2A（Agent 间通信）
- **安全与弹性**：速率限制、输入验证、重试、超时、熔断

## 架构

```
┌─────────────────────────────────────────────────────┐
│                    CL-Agent                         │
└─────────────────────────────────────────────────────┘
                         │
    ┌────────────────────┼────────────────────┐
    │                    │                    │
    ▼                    ▼                    ▼
┌────────┐        ┌────────────┐        ┌──────────┐
│  Core  │        │    LLM     │        │SimpleAgent│
│(内核)  │        │(LLM提供商) │        │ (Agent)  │
└────────┘        └────────────┘        └──────────┘
    │                    │                    │
    ├────────────────────┼────────────────────┤
    │                    │                    │
    ▼                    ▼                    ▼
┌────────┐        ┌────────────┐        ┌──────────┐
│ Memory │        │   Tools    │        │   RAG    │
│(记忆)  │        │ (工具+标签)│        │(检索增强)│
└────────┘        └────────────┘        └──────────┘
                         │
                         ▼
                  ┌────────────┐
                  │    MCP     │
                  │  (协议)    │
                  └────────────┘
```

## 模块说明

| 模块 | 描述 |
|------|------|
| **core** | 核心基础设施：Kernel、Context、Filter、Service 抽象 |
| **llm** | LLM 提供商实现（Anthropic、OpenAI、智谱、Ollama） |
| **tools** | 工具系统：Tool Registry + Tag 过滤 + 预设配置 |
| **simpleagent** | 简单 Agent 实现（KernelAgent、ProcessAgent） |
| **memory** | 统一记忆管理（检查点、存储、长期记忆） |
| **rag** | 检索增强生成管道 |
| **mcp** | 模型上下文协议实现 |
| **protocols** | 协议支持（MCP、A2A） |

## 安装

### 前置条件

- SBCL 或其他 Common Lisp 实现
- Quicklisp

### 设置

```bash
# 克隆仓库
git clone https://github.com/example/cl-agent.git
cd cl-agent

# 使用 ASDF 加载
(asdf:load-system :cl-agent)
```

## 快速开始

### 基本聊天

```lisp
(ql:quickload :cl-agent)

;; 创建 LLM 客户端
(defvar *client*
  (cl-agent.llm:make-client
    :provider :anthropic
    :model "claude-3-5-sonnet-20241022"
    :api-key (uiop:getenv "ANTHROPIC_API_KEY")))

;; 简单聊天
(cl-agent.llm:chat *client* "你好，最近怎么样？")
```

### 带工具的 Agent（新 API）

```lisp
;; 创建工具
(defvar *weather-tool*
  (cl-agent.tools:make-simple-tool
    :get_weather
    "获取指定城市的天气"
    (lambda (&key city)
      (format nil "~A 的天气：22°C，晴" city))
    :parameters '((:city :type :string :description "城市名称" :required-p t))
    :tags '(:utility :weather :safe)))

;; 使用 Builder 模式创建 Kernel
(defvar *kernel*
  (cl-agent.kernel:build-kernel
    (cl-agent.kernel:with-tool
      (cl-agent.kernel:add-service
        (cl-agent.kernel:create-kernel-builder)
        *provider*)
      *weather-tool*)))

;; 创建 Agent
(defvar *agent*
  (cl-agent.simpleagent:make-kernel-agent *kernel*
    :system-prompt "你是一个有帮助的助手。"))

;; 与 Agent 对话
(cl-agent.simpleagent:agent-chat *agent* "东京的天气怎么样？")
```

### 使用预设快速配置

```lisp
;; 使用预设创建带工具的 Kernel
(defvar *kernel*
  (cl-agent.kernel:build-kernel
    (cl-agent.kernel:with-preset
      (cl-agent.kernel:add-service
        (cl-agent.kernel:create-kernel-builder)
        *provider*)
      :safe                    ; 预设：:standard :safe :full :file-only :http-only :utility-only
      :security-level :standard))) ; 安全级别：:permissive :standard :strict
```

### Tag 过滤

```lisp
;; 创建带 Tag 过滤的 Kernel（只启用 :safe 和 :utility 标签的工具）
(defvar *kernel*
  (cl-agent.kernel:build-kernel
    (cl-agent.kernel:with-active-tags
      (cl-agent.kernel:with-preset
        (cl-agent.kernel:add-service
          (cl-agent.kernel:create-kernel-builder)
          *provider*)
        :full)
      '(:safe :utility)     ; 只启用这些标签的工具
      :mode :any)))         ; :any = 匹配任一标签, :all = 匹配所有标签
```

## 工具标签

内置工具使用以下标签：

| 标签 | 描述 |
|------|------|
| `:file` | 文件操作工具 |
| `:http` | HTTP 请求工具 |
| `:shell` | Shell 命令工具 |
| `:utility` | 通用工具 |
| `:safe` | 安全的只读操作 |
| `:read` | 读取操作 |
| `:write` | 写入操作 |
| `:dangerous` | 危险操作（需谨慎） |

## 文档

- [快速开始指南](docs/QUICKSTART_CN.md)
- [API 参考](docs/API_CN.md)

## 许可证

MIT License

## 贡献

欢迎贡献！请随时提交 Pull Request。
