# CL-Agent 示例

[English](README_EN.md)

## chat-client-usage.lisp —— ChatClient 完整用法

独立脚本，用 mock provider 演示（无需 API 密钥）：

```bash
sbcl --load examples/chat-client-usage.lisp
```

加载后可逐个运行：

| 函数 | 演示内容 |
|---|---|
| `(chat-client-examples::example-1)` | 最简 chat 宏调用 |
| `(chat-client-examples::example-2)` | Builder 链式构建 |
| `(chat-client-examples::example-3)` | deftool 工具 + 内部工具执行循环 |
| `(chat-client-examples::example-4)` | ChatMemory 多轮记忆 |
| `(chat-client-examples::example-5)` | defadvisor 自定义 Advisor + 日志/护栏 |
| `(chat-client-examples::example-6)` | fluent 管道风格（-> 线程宏） |
| `(chat-client-examples::example-7)` | 结构化输出（:call :entity） |
| `(chat-client-examples::example-8)` | 流式输出（:stream） |

接真实提供商时把 `*model*` 换成：

```lisp
(cl-agent.llm:create-chat-model :anthropic
  :model "claude-sonnet-4-20250514")
```

## llm-usage.lisp —— 底层 Provider SPI 直接调用

不经过 ChatClient，直接使用 `cl-agent.llm` 的客户端与 Provider。

## di-usage-examples.lisp —— DI 容器（可选设施）

`cl-agent.core` 自带的依赖注入容器示例（protocols 子系统使用）。
