# CL-Agent Core

[English](README_EN.md)

核心模块（v8.0.0），对标 Spring AI 2.0 的分层设计。

## 包结构

| 包 | 对标 | 内容 |
|---|---|---|
| `cl-agent.core` | — | 条件系统、工具函数、HTTP/SSE 客户端、JSON Schema 生成、`llm-chat` Provider SPI、统一 `llm-response` |
| `cl-agent.chat` | `org.springframework.ai.chat.*` | CLOS 消息体系、Prompt、ChatOptions、ChatResponse、`deftool` 工具体系、ChatModel 协议、ChatMemory |
| `cl-agent.client` | `org.springframework.ai.chat.client.*` | Advisor 协议与洋葱链、`defadvisor` 宏、内置 Advisor、ChatClient + Builder + `chat` 宏 |

## 文件布局

```
core/
├── package-core.lisp        cl-agent.core 包定义
├── conditions.lisp          条件系统
├── macros.lisp              实用宏（-> ->> when-let ...）
├── utils.lisp / types.lisp / validation.lisp / data-convert.lisp
├── json-schema.lisp         params->json-schema / schema-to-hash-table
├── llm/
│   ├── response.lisp        统一 llm-response / llm-usage / llm-tool-call
│   └── provider.lisp        llm-chat / llm-chat-stream SPI
├── http/                    HTTP 客户端 + SSE 流式 + 重试
├── chat/                    Chat Model API
│   ├── message.lisp         消息体系 + 中立 plist 互转
│   ├── options.lisp         ChatOptions（未设置语义 + 合并）
│   ├── prompt.lisp          Prompt（不可变增强）
│   ├── response.lisp        ChatResponse / Generation / 元数据
│   ├── tool.lisp            deftool / ToolCallback / ToolCallingManager
│   ├── memory.lisp          ChatMemory / Repository 协议
│   └── model.lisp           ChatModel 协议 + Provider 适配器（工具循环）
└── client/                  ChatClient + Advisor
    ├── advisor.lisp         协议 / 洋葱链 / defadvisor / 排序常量
    ├── advisors.lisp        日志 / 消息记忆 / 护栏
    ├── tool-advisor.lisp    ToolCallingAdvisor（递归工具循环 + 钩子）
    ├── tool-search-advisor.lisp      ToolSearch（渐进式工具披露）
    ├── structured-output-advisor.lisp StructuredOutputValidation（校验 + 自纠）
    └── chat-client.lisp     ChatClient / Builder / 请求 spec / chat 宏
```

## 设计要点

- **中立 plist 边界**：CLOS 消息不跨越 Provider SPI；
  `messages->neutral` / `neutral->messages` 在 `provider-chat-model`
  适配层完成互转，Provider 只见 `(:role ... :content ...)` plist。
- **选项合并语义**：`chat-options` 用槽位未绑定表示"未设置"，
  `merge-chat-options` 实现运行时 > 客户端默认 > 模型默认的覆盖链，
  工具列表取并集。
- **内部工具执行**：与 Spring AI 相同，工具循环住在 ChatModel 内部
  （`internal-tool-execution-enabled` 默认开启），ChatClient/Advisor
  只看到最终响应。
- **Advisor 洋葱链**：`order` 越小越靠外；`advise-stream` 默认委托
  `advise-call`，非流式 Advisor 无需感知流式路径。

详见 [API 参考](../docs/API_CN.md)。
