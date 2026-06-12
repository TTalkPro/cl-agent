# CL-Agent Extra

[English](README_EN.md)

`cl-agent-extra` 是 CL-Agent 的可选扩展系统，构建在 `cl-agent-core` 之上，包含三部分：

| 子模块 | 目录 | 描述 |
|--------|------|------|
| **Process 框架** | `process/` | 事件系统、Step 抽象、状态机、Human-in-the-Loop、Process 运行时（包 `cl-agent.process`） |
| **工具系统** | `tools/` | Tool Registry + Tag 过滤 + 内置工具（HTTP/文件/搜索/Shell）+ 安全与弹性（包 `cl-agent.tools`） |
| **ProcessAgent** | `agent/` | 可暂停/恢复的后台线程 Agent，集成 Process 框架（包 `cl-agent.extra.agent`） |

## 加载

```lisp
(asdf:load-system :cl-agent-extra)
```

## 与 core 的关系

- core 的 Kernel 通过运行时反射（`find-symbol`）软依赖 `cl-agent.tools`：
  未加载 extra 时 Kernel 没有工具注册表（优雅降级）；加载后自动可用。
- `ProcessAgent`（`cl-agent.extra.agent:process-agent`）继承 core 的
  `cl-agent.simpleagent:kernel-agent`，并依赖 `cl-agent.process` 的事件总线、
  事件队列与 human-loop 管理器。

详细文档见各子目录的 README。
