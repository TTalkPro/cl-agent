# CL-Agent Core

[English](README_EN.md)

核心模块，框架本体。能力对标 Spring AI 2.0，架构参照 clj-agent。

## 包结构

**一个包**：`cl-agent/core`（昵称 `cla/core`）。曾经的 `cl-agent/http` /
`cl-agent/chat` / `cl-agent/chat-client` 已全部合并进来——`core/` 下的
`http/` `chat/` `chat-client/` 现在只是 asd 的模块（文件分组），不再是包，
所有文件一律 `(in-package #:cl-agent/core)`。

| 分层 | 对标 | 内容 |
|---|---|---|
| 基础设施 | — | 条件系统、工具函数、DI 容器、JSON Schema 生成与校验、HTTP/SSE 客户端、`llm-chat` Provider SPI、统一 `llm-response` |
| Chat API | `org.springframework.ai.chat.*` | CLOS 消息体系、Prompt、ChatOptions、ChatResponse、`deftool` 工具体系、ChatModel 协议、ChatMemory |
| ChatClient | `chat.client.*` + `chat.client.advisor.*` | Filter 三链 + `build-chain`、ChatClient + `build-chat-client`、`invoke-chat/tool/turn`、`run-tool-loop`、`resume-turn`、ToolCallingManager、10 个内置 filter、`chat` 宏 DSL |

合并后 `cl-agent/core` 与 `cl-agent/client`（SimpleAgent）可以直接一起
`:use`，无需任何 shadowing：

```lisp
(defpackage :my-app
  (:use :cl :cl-agent/core :cl-agent/client))
```

## 文件布局

```
core/
├── package-core.lisp        cl-agent/core 包定义（单包）
├── conditions.lisp          条件系统
├── macros.lisp              when-let + 日志系统（log-debug/info/warn/error）
├── utils.lisp               工具函数 + ID 生成器 / 时间戳提供者
├── dependency-injection.lisp  DI 容器（独立设施，库内部不使用）
├── data-convert.lisp        plist <-> hash-table 互转
├── json-schema.lisp         params->json-schema / 校验器
├── llm/
│   ├── response.lisp        统一 llm-response / llm-usage / llm-tool-call
│   └── provider.lisp        llm-chat / llm-chat-stream SPI
├── http/                    HTTP 客户端 + 异步 + 重试 + SSE 流式
├── chat/                    Chat Model API
│   ├── message.lisp         消息体系 + 中立 plist 互转
│   ├── options.lisp         ChatOptions（未设置语义 + 合并）
│   ├── prompt.lisp          Prompt（不可变增强）
│   ├── response.lisp        ChatResponse / Generation / 元数据
│   ├── tool.lisp            deftool / ToolCallback
│   ├── memory.lisp          ChatMemory / Repository 协议
│   └── model.lisp           ChatModel 协议 + Provider 适配器（单次调用）
└── chat-client/                  ChatClient + Filter 执行内核（唯一执行路径）
    ├── carriers.lisp        三链载体 + 暂停载体（loop-state / pending-tool）
    ├── filter.lisp          filter CLOS + build-chain + defilter
    ├── chat-client.lisp          chat-client CLOS + build-chat-client（含 :tool-gate）
    ├── conditions.lisp      工具故障分类（语义/瞬时/环境）
    ├── batch.lisp           批量工具执行（并行 / :serial / 故障路由）
    ├── tool-calling-manager.lisp  串行 / 虚拟线程 / 线程池 三实现
    ├── invoke.lisp          invoke-chat/tool/turn + run-tool-loop + resume-turn
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
    │   └── token-xform.lisp token 改写（:token-xform，(downstream) → (values emit finish)）
    └── chat.lisp            chat 宏 DSL + chat-client-call* 调用方入口
```

## 设计要点

- **中立 plist 边界**：CLOS 消息不跨越 Provider SPI；
  `messages->neutral` / `neutral->messages` 在 `provider-chat-model`
  适配层完成互转，Provider 只见 `(:role ... :content ...)` plist。
- **选项合并语义**：`chat-options` 用槽位未绑定表示"未设置"，
  `merge-chat-options` 实现运行时 > chat-client 默认 > 模型默认的覆盖链，
  工具列表取并集。
- **三层职责**：Provider 只管「底层信息 + 如何调用」（端点/鉴权/请求体
  格式/响应解析）；**ChatModel 承担单次调用范围内的全部重活**——options
  解析合并、重试（`retry-policy`）、观测（`observation-fn`）、响应规范化、
  流式聚合；ChatClient 管链、记忆、工具循环、HITL。
- **工具执行不在 ChatModel 内**：`chat-model-call` 只做单次调用（注入工具
  schema，但不执行工具），工具循环上移到 `run-tool-loop`。新版 Spring AI
  也已把循环从 `XxxChatModel` 移到 ChatClient 层的 `ToolCallingAdvisor`。
- **重试挂在基类的 `:around` 上**：新写一个 ChatModel 子类不需要记得调重试
  封装，也不可能漏。缺省不重试；是否重试由 `error-retryable-p` 单一裁定，
  耗尽后原样抛出原条件不做包装。
- **两层观测各司其职**：ChatModel 的 `observation-fn` 包住一次**逻辑**调用
  （含重试记一条，算延迟用）；`*llm-call-observer*` 包住每一次**真实 wire
  调用**（重试三次触发三次，算钱用）。后者是挂在 `(t)` 上的 `:around`，
  一个 `let` 绑定覆盖所有 provider。
- **ChatClient 四个槽**：`model` / `filters` / `default-request`（system /
  options / tools）/ `tool-calling`（上限/闸门/执行策略/循环骨架）。
  对标 Spring AI 的 `ChatClient` + `DefaultChatClientRequestSpec` +
  `ToolCallingAdvisor`。四者都是不可变值对象，`chat-client-mutate` 共享它们
  派生新实例。刻意无 memory 槽——记忆是 filter。
- **Filter 三链**：`:chat` / `:tool` / `:turn`（外加 `:token-xform`）。
  `build-chain` 把 filter 列表折叠成嵌套闭包，闭包**只捕获下游**——
  于是「递归重入」就是再调一次同一个 `chain`，零额外机制
  （`validation-turn-filter` 的自纠重试即由此实现）。
  列表顺序即洋葱层级：靠前 = 靠外 = 先执行。
- **HITL 是 chat-client 的原语**：`build-chat-client :tool-gate` 接一个
  `(tool-call) → :proceed | :pause | (:pause . 原因)` 的函数，在**批执行
  之前**对每个 tool-call 恰好评估一次（gate 常带副作用——审计日志、
  审批 UI、计数器，所以「恰好一次」是契约的一部分）。判 :pause 则整轮
  暂停，**工具一个都不执行**，`run-tool-loop` 返回
  `chat-client-response(:paused)`，携带 `loop-state` 快照；审批后
  `resume-turn` 从中点续跑。
- **ChatClient 移植层已退役**：旧的 ChatClient / Builder / fluent
  RequestSpec 全部移除。执行路径唯一为 chat-client + filter，入口是
  `build-chat-client` 的关键字参数 + `chat` 宏。
  （`cl-agent/client` 这个名字已被**复用**：现在是 SimpleAgent。）
- **包合并消除了所有 shadowing**：曾经 `cl-agent/chat` 与
  `cl-agent/chat-client` 有三个同名导出：`tool-response` / `make-tool-response`
  （chat 是协议消息层的「工具响应」值对象 id/name/text，chat-client 是执行链的
  响应载体）与 `execute-tool-calls`（两套不同签名的 manager 协议）。已从
  根上消除：chat-client 的载体改名为 `tool-request` / `tool-result`（与 turn 链
  的 `chat-client-request` / `chat-client-response` 对称），chat 的旧 ToolCallingManager
  整体删除。三包随后合并为 `cl-agent/core`，`:shadow` 全部消失。

详见 [API 参考](../docs/API_CN.md)。
