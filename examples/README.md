# CL-Agent 示例

[English](README_EN.md)

## kernel-usage.lisp —— Kernel + Filter 完整用法

独立脚本，用 mock provider 演示（无需 API 密钥）：

```bash
sbcl --load examples/kernel-usage.lisp
```

加载后可逐个运行：

| 函数 | 演示内容 |
|---|---|
| `(kernel-examples::example-1)` | 最简 chat 宏调用 |
| `(kernel-examples::example-2)` | 请求级 system + options |
| `(kernel-examples::example-3)` | deftool 工具 + run-tool-loop 工具循环 |
| `(kernel-examples::example-4)` | memory-filter 多轮记忆 |
| `(kernel-examples::example-5)` | 自定义 filter + 日志/护栏 filter 洋葱链 |
| `(kernel-examples::example-6)` | 函数形态入口（kernel-chat-text） |
| `(kernel-examples::example-7)` | 结构化输出 + schema 校验自纠 |
| `(kernel-examples::example-8)` | 流式输出（:stream） |

接真实提供商时把 `*model*` 换成：

```lisp
(cl-agent/llm:create-chat-model :anthropic
  :model "claude-sonnet-4-20250514")
```

## ../scripts/live-test.lisp —— 真实 provider 端到端验证

mock 证明不了「真实模型会不会按我们的 schema 发工具调用」这类问题，
这个脚本补的就是那一段（不进测试套件，手动跑）：

```bash
MINIMAX_API_KEY=... sbcl --script scripts/live-test.lisp
```

覆盖：单次问答 / 真实工具循环（断言工具确实被执行）/ memory 多轮 /
结构化输出 schema 校验 / 真实 SSE 分片。

## llm-usage.lisp —— 底层 Provider SPI 直接调用

不经过 kernel，直接使用 `cl-agent/llm` 的客户端与 Provider。

## di-usage-examples.lisp —— DI 容器（可选设施）

`cl-agent/core` 自带的依赖注入容器示例（独立设施，库内部不使用）。
