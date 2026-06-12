# CL-Agent Extra

[English](README_EN.md)

`cl-agent-extra` 是 CL-Agent 的可选扩展系统，构建在 `cl-agent-core` 之上，包含三部分：

| 子模块 | 目录 | 描述 |
|--------|------|------|
| **Checkpoint** | `checkpoint/` | 流程状态快照：Store 协议 + 内存后端 + 谱系/分支/时间旅行（包 `cl-agent.checkpoint`，原 cl-agent-memory 的 process 相关部分） |
| **Process 框架** | `process/` | 事件系统、Step 抽象、状态机、Human-in-the-Loop、Process 运行时（包 `cl-agent.process`） |
| **ProcessAgent** | `agent/` | 可暂停/恢复的后台线程 Agent，集成 Process 框架（包 `cl-agent.extra.agent`） |

## 加载

```lisp
(asdf:load-system :cl-agent-extra)
```

## 与 core 的关系

- 工具注册表现在是 core 的原生能力（`cl-agent.kernel` 的 tool 类 +
  tool-registry），extra 不再承载工具系统。
- `ProcessAgent`（`cl-agent.extra.agent:process-agent`）继承 core 的
  `cl-agent.simpleagent:kernel-agent`，并依赖 `cl-agent.process` 的事件总线、
  事件队列与 human-loop 管理器。

详细文档见各子目录的 README。
