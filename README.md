# CL-Agent

[English](README_EN.md)

基于 Common Lisp 的统一 AI Agent 框架，采用语义内核架构：胖核心（基础设施 + Kernel + 原生工具注册表 + SimpleAgent）+ 外围能力模块（LLM、Extra）。

## 特性

- **多提供商 LLM 支持**：Anthropic Claude、OpenAI GPT、智谱 GLM、Ollama、DashScope
  （OpenAI 兼容基座，统一 llm-response 响应对象）
- **原生工具系统**：Kernel 内置工具注册表 + Tag 标签过滤
- **洋葱式 Filter 管道**：around/before/after，:chat 与 :tool 双链
- **ChatMemory**：按 conversation-id 自管对话历史的 Memory Filter
- **Checkpoint**：流程状态快照（谱系/分支/时间旅行，位于 extra）
- **统一错误模型**：retryable 分类 + 指数退避重试

## 架构

```
┌─────────────────────────────────────────────────────┐
│                    CL-Agent                         │
└─────────────────────────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────┐
│                  Core（胖核心）                      │
│ 基础设施 + Kernel(工具注册表/Filter/Memory) +       │
│ LLM 协议 + SimpleAgent                              │
└─────────────────────────────────────────────────────┘
    ▲                              ▲
    │实现协议                      │依赖
┌────────┐                ┌──────────────────────┐
│  LLM   │                │        Extra         │
│(提供商)│                │ Checkpoint + Process │
└────────┘                │   + ProcessAgent     │
                          └──────────────────────┘
```

## 模块说明

| 模块 | 描述 |
|------|------|
| **core** | 胖核心：基础设施、Kernel（Context/Filter/Service/原生工具注册表/MemoryFilter）、LLM 协议、SimpleAgent（KernelAgent） |
| **llm** | LLM 提供商实现（Anthropic、OpenAI、智谱、Ollama、DashScope），实现 core 的 llm-chat 协议 |
| **extra** | 可选扩展：Checkpoint（流程状态快照/时间旅行）、Process 框架、ProcessAgent |
| **protocols** | A2A 协议支持（独立系统，未纳入主构建） |

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

### 带工具的 Agent

```lisp
;; 创建工具（core 原生工具注册表）
(defvar *weather-tool*
  (cl-agent.kernel:make-tool
    :name :get_weather
    :description "获取指定城市的天气"
    :handler (lambda (&key city)
               (format nil "~A 的天气：22°C，晴" city))
    :parameters '((city :type :string :description "城市名称" :required t))
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

### Tag 过滤

```lisp
;; 创建带 Tag 过滤的 Kernel（只启用 :safe 和 :utility 标签的工具）
(defvar *kernel*
  (cl-agent.kernel:make-kernel
    :service *provider*
    :active-tags '(:safe :utility)   ; 只启用这些标签的工具
    :tag-filter-mode :any))          ; :any = 匹配任一标签, :all = 匹配所有标签
```

## 文档

- [快速开始指南](docs/QUICKSTART_CN.md)
- [API 参考](docs/API_CN.md)

## 许可证

MIT License

## 贡献

欢迎贡献！请随时提交 Pull Request。
