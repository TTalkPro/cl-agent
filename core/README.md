# CL-Agent Core

[English](README_EN.md)

核心模块，对标 Spring AI 2.0 的分层设计。

## 包结构

| 包 | 对标 | 内容 |
|---|---|---|
| `cl-agent.core` | — | 条件系统、工具函数、HTTP/SSE 客户端、JSON Schema 生成与校验、`llm-chat` Provider SPI、统一 `llm-response` |
| `cl-agent.chat` | `org.springframework.ai.chat.*` | CLOS 消息体系、Prompt、ChatOptions、ChatResponse、`deftool` 工具体系、ChatModel 协议、ChatMemory |
| `cl-agent.kernel` | `chat.client.*` + `chat.client.advisor.*` | Filter 三链 + `build-chain`、Kernel + `build-kernel`、`invoke-chat/tool/turn`、`run-tool-loop`、ToolCallingManager、10 个内置 filter、`chat` 宏 DSL |

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
│   └── model.lisp           ChatModel 协议 + Provider 适配器（单次调用）
└── kernel/                  Kernel + Filter 执行内核（唯一执行路径）
    ├── carriers.lisp        三链请求/响应载体
    ├── filter.lisp          filter CLOS + build-chain + defilter
    ├── kernel.lisp          kernel CLOS + build-kernel
    ├── conditions.lisp      工具故障分类（语义/瞬时/环境）
    ├── batch.lisp           批量工具执行（并行 / :serial / 故障路由）
    ├── tool-calling-manager.lisp  串行 / 虚拟线程 / 线程池 三实现
    ├── invoke.lisp          invoke-chat/tool/turn + run-tool-loop
    ├── filters/             10 个内置 filter
    │   ├── memory.lisp      记忆（:chat，循环内每轮生效）
    │   ├── logging.lisp     日志（:chat / :tool）
    │   ├── safeguard.lisp   安全护栏（:turn，短路）
    │   ├── validation.lisp  结构化输出校验（:turn，递归重入自纠）
    │   ├── re-reading.lisp  RE2 重读（:turn）
    │   ├── rag.lisp         RAG 问答注入（:turn）+ IRetriever
    │   ├── tool-search.lisp 渐进式工具披露（:chat）+ IToolIndex
    │   ├── timeout.lisp     工具超时（:tool）
    │   ├── approval.lisp    预执行审批门（:tool）
    │   └── token-xform.lisp token 改写（:token-xform transducer）
    └── chat.lisp            chat 宏 DSL + kernel-chat* 调用方入口
```

## 设计要点

- **中立 plist 边界**：CLOS 消息不跨越 Provider SPI；
  `messages->neutral` / `neutral->messages` 在 `provider-chat-model`
  适配层完成互转，Provider 只见 `(:role ... :content ...)` plist。
- **选项合并语义**：`chat-options` 用槽位未绑定表示"未设置"，
  `merge-chat-options` 实现运行时 > 客户端默认 > 模型默认的覆盖链，
  工具列表取并集。
- **工具执行不在 ChatModel 内**：对齐 Spring AI 2.0——`chat-model-call`
  只做单次调用（注入工具 schema，但不执行工具），工具循环上移到
  `cl-agent.kernel:run-tool-loop`。1.x 的 `internal-tool-execution-enabled`
  已随之移除。
- **Filter 三链**：`:chat` / `:tool` / `:turn`（外加 `:token-xform`）。
  `build-chain` 把 filter 列表折叠成嵌套闭包，闭包**只捕获下游**——
  于是「递归重入」就是再调一次同一个 `chain`，零额外机制
  （`validation-turn-filter` 的自纠重试即由此实现）。
  列表顺序即洋葱层级：靠前 = 靠外 = 先执行。
- **Spring AI 的两层移植都已退役**：`defadvisor` / `advise-call` / `order`
  排序体系，以及整个 `cl-agent.client`（ChatClient / Builder / fluent
  RequestSpec）。执行路径唯一为 kernel + filter，入口是 `build-kernel`
  的关键字参数 + `chat` 宏。
- **两个包可直接一起 `:use`**：`(:use :cl :cl-agent.chat :cl-agent.kernel)`
  无需任何 shadowing。曾经不行——两个包有三个同名导出：
  `tool-response` / `make-tool-response`（chat 是协议消息层的「工具响应」
  值对象，kernel 是执行链的响应载体）与 `execute-tool-calls`（两套不同
  签名的 manager 协议）。已从根上消除：kernel 的载体改名为
  `tool-request` / `tool-result`（与 turn 链的 `turn-request` /
  `turn-result` 对称），chat 的旧 ToolCallingManager 整体删除。
  kernel 因此不再需要任何 `:shadow`。

详见 [API 参考](../docs/API_CN.md)。
