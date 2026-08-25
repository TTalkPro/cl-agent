# Refactoring Plan: cl-agent 三层职责对齐 Spring AI（Provider / ChatModel / ChatClient）

> 基线：SBCL 2.6.6 **1165 checks / 0 failures**（2026-08-25）
> 完成：**1396 checks / 0 failures**（SBCL 2.6.7 + CCL）
> 真实链路：`scripts/live-test.lisp` MiniMax-M2.7 **13/13**
> 版本统一为 11.0.0
> 参照实现：`~/workspace/spring-ai`（含中文注释的 2.x 分支）

## 0. Executive summary

当前 cl-agent 的三层边界与 Spring AI 错位在**中间层**：`provider-chat-model`
是个 10 行透传壳（`core/chat/model.lisp:160`），既不重试也不观测；而重试逻辑
被困在 `llm/client.lisp:232` 的 `chat-with-retry` 里——那是 `client` 类的旧路径，
**chat-client 主干完全不经过它**。于是整条主干无重试。

同时 `chat-client` 承载了 12 个槽（loop-fn / resume-fn / tool-gate /
eligibility-fn / state-slots / tool-manager / settings …），远超 Spring AI
`ChatClient`（chatModel + advisors + defaultRequest）的范围；这些槽在 Spring AI
里全部属于 `ToolCallingAdvisor`。

目标：
```
Provider  = 底层信息 + 如何调用（HTTP / 序列化 / 鉴权 / 格式转换）
ChatModel = 单次调用的全部重活（options 解析、重试、观测、usage 累计、
            响应规范化、流式聚合）
ChatClient= filter 链 + 默认请求 + 模型引用（工具循环下放给 tool-calling-filter）
```

## 1. 决策（已确认）

- **DP1 — 旧 `client` 路径**：删除 `llm/client.lisp` 的 `client` 类、`client-chat`、
  `chat-with-retry`，重试能力上提到 ChatModel。
- **DP2 — 工具循环归属**：留在 ChatClient 层。新版 Spring AI 已把循环从
  `AnthropicChatModel` 移到 `ToolCallingAdvisor`（`spring-ai-client-chat`），
  与 cl-agent 现状一致。ChatModel 的「重」= 单次调用范围内的重活。
- **DP3 — 兼容策略**：不保兼容，一次改到位；examples / docs / 测试同步更新。

## 2. 架构映射（现状 → 目标）

| 概念 | cl-agent 现状 | 目标 | Spring AI 对应 |
|---|---|---|---|
| 模型请求抽象 | 无 | `model-request` 抽象类 | `ModelRequest<T>` |
| 模型响应抽象 | 无 | `model-response` / `model-result` | `ModelResponse` / `ModelResult` |
| chat 请求 | `prompt`（不继承任何抽象） | `prompt : model-request` | `Prompt implements ModelRequest` |
| chat 响应 | `chat-response`（同上） | `chat-response : model-response` | `ChatResponse` |
| 重试 | `llm/client.lisp` 旧路径，主干不经过 | ChatModel `:around` 方法 | ChatModel 内 RetryTemplate |
| 观测 | 无 | ChatModel `observation-fn` 槽 | `ObservationRegistry` |
| ChatClient 载体 | `turn-request` / `turn-result` | `chat-client-request` / `chat-client-response` | `ChatClientRequest` / `ChatClientResponse` |
| 工具循环 | chat-client 的固有 terminal + 7 个相关槽 | `tool-calling-filter`（`:turn` 钩子）持有全部循环配置 | `ToolCallingAdvisor` |
| 批执行结果 | plist（`getf`） | `tool-execution-result` 类 | `ToolExecutionResult` |
| 配置 | `settings` alist | 各归属组件的具名槽 | 构造器参数 |

## 3. 阶段（每阶段 additive-green）—— 全部完成

### P1 — ChatModel 承重 ✅
1. `chat-model` 基类加 `retry-policy` / `observation-fn` 槽
2. `retry-policy` 类（替代 `core/http/retry.lisp` 的 `retry-config` struct 在此层的角色）
3. `chat-model-call` / `chat-model-stream` 的 `:around` 方法实现重试 + 观测
4. 删除 `llm/client.lisp` 的 `client` / `client-chat` / `chat-with-retry` / `retryable-error-p`
   等 15 个公开函数；`llm/streaming.lisp` `llm/embeddings.lisp` 改依赖 provider
5. `llm/package.lisp` 移除 11 个 client 导出符号

### P2 — Request/Response 类体系 ✅
1. 新建 `core/model/protocol.lisp`：`model-request` / `model-response` / `model-result`
   / `model-options` 抽象类 + 泛型 `request-instructions` / `request-options` /
   `response-result` / `response-results` / `response-metadata`
2. `prompt` / `chat-response` / `generation` / `chat-options` 接入继承
3. `turn-request` → `chat-client-request`（prompt + context，不再是裸 messages）
   `turn-result` → `chat-client-response`（chat-response + context + status/HITL 字段）

### P3 — ChatClient 收窄 ✅
1. 新建 `tool-calling-filter`（`:turn` 钩子），吸收：`loop-fn` `resume-fn`
   `tool-gate` `eligibility-fn` `state-slots` `tool-manager` `max-tool-iterations`
2. `chat-client` 收窄到 4 槽：`model` / `filters` / `default-request` / `observation-fn`
3. `build-chat-client` 保持同样的关键字入参，内部自动组装 `tool-calling-filter`

### P4 — 类化 ✅
1. `tool-execution-result` plist → 类（键名冻结契约转为 reader）
2. `default-request` 类（system / options / tools 三者聚合，对标 `DefaultChatClientRequestSpec`）
3. `retry-config` struct → 类；`stream-context` 等热路径 struct 保持不变
4. `initialize-instance :after` 承接构造函数里的不变式（缺省名、断言）

## 4. 不做的事

- 不引入 MOP / `:metaclass`——本项目无需自定义元类
- 热路径 struct（`http-response` / `anthropic-stream-state` / `http-future`）保持 struct
- filter 钩子仍存槽位、不改为泛型分发（`filter.lisp` 文件头已论证）
- `context` 保持开放字典语义（Spring AI 也是 `Map<String,Object>`）

## 5. 执行记录

| 阶段 | checks | 说明 |
|---|---|---|
| 基线 | 1165 | |
| P1 | 1237 | ChatModel retry-policy / observation-fn + `:around`；删 `llm/client.lisp`（515 行）与 `llm/streaming.lisp`（连带：整个文件依赖 `client` 类，全库零调用，与主干 `llm-chat-stream` 重复）；`estimate-cost` / `*provider-pricing*` 抢救进 `llm/providers.lisp` |
| P2 | 1244 | `core/model/protocol.lisp`；`turn-request/result` → `chat-client-request/response`；`:caller-options` 暗管道消除 |
| P3 | 1263 | chat-client 12 槽 → 4 槽；`chat-client-mutate` / `tool-calling-config-mutate` |
| P4 | 1396 | 五处 plist·struct 类化（`tool-execution-result` / `tool-error-info` / `state-slot` / `resume-payload` / `retry-config`）；四条 `initialize-instance :after` 不变式；删除 `:settings` shim（彻底执行 DP3）；provider 层 `*llm-call-observer*` 横切；版本统一 11.0.0 |

### P3 的取舍：为什么循环没做成 filter

新版 Spring AI 把工具循环做成了 `ToolCallingAdvisor`——一个真正的 advisor，
用 `chain.nextCall()` 调下游，配置是它自己的实例状态。cl-agent 这边**没有**
照搬，原因是架构差异而非偷懒：

- Spring AI 的 `ToolCallingAdvisor` 持有 `ToolCallingManager`，而 manager
  自己就知道怎么执行工具，不需要回头找 ChatClient。
- cl-agent 的工具执行要穿 `:tool` filter 链，而链存在 chat-client 上
  （`invoke-tool` 的第一个参数就是 chat-client）。filter 钩子的签名是
  `(req chain)`，够不着 chat-client。

硬套会引入循环引用（filter 持有 chat-client 的反向引用）或动态变量
（`*current-chat-client*`）——两者都比现在的 terminal 形态更糟。所以循环仍是
`:turn` 链的 terminal，配置聚合成 `tool-calling-config` 由 chat-client 持有
一个槽。收窄的目标（chat-client 不背 12 个槽）达到了，`ToolCallingAdvisor`
的**配置面**也对齐了，只是形态仍是 terminal 而非 filter。

要改成 filter 形态，前置条件是把 `:tool` 链从 chat-client 上解耦出去——那是
另一次重构，不在本次范围内。

## 6. 真实链路验证的一处教训

类化 `state-slots` 时漏改了 `scripts/live-test.lisp`——它不在 ASDF 系统里，
测试套件覆盖不到。当时做过一次「符号解析检查」（加载系统后 `read` 整个脚本），
结论是「读取 OK」，但那只证明符号都存在：旧写法
`(list :notes :init nil :reduce fn)` 是完全合法的 `read`，错误要到
`state-slot-key` 分派时才暴露。

**教训**：`read` 通过 ≠ 能跑。游离于测试系统外的脚本，改动涉及它用到的 API 时
必须真跑一遍。这次是真实 API 调用逮到的（第 11 项 ERROR）。

## 7. 收尾时补的覆盖缺口

用「本次新增的公开符号是否被测试引用」扫了一遍，发现三处零覆盖：

- **Model 抽象协议整体没有测试**——P2 的核心产出只验证了「编译通过」。
  补了 `tests/test-model-protocol.lisp`，重点不是各访问器能否取值，而是
  **同一段计费代码同时吃 chat-response 与 embedding-response**：协议层的
  价值全在这里，只测 chat 的话它退化成一堆别名。
- `*llm-stream-observer*` 零覆盖（流式与非流式是两个变量，配了一个不覆盖
  另一个，这条得有测试钉住）。
- `call-with-retry` / `make-chat-client-default-request` 只被间接触及。

同时把 `test-chat-model.lisp` 里借用的 `stream-provider` 换成本文件自定义的
桩——那个类定义在 ASDF 序列更靠后的文件里，跨文件借用能跑（类在运行时才
解析），但把加载顺序变成了隐式约束。

## 8. 不变式全面铺开（P5）

`initialize-instance :after` 从四条扩到 **36/61 个类**，统一经
`core/invariants.lisp` 的 `definvariants` 宏 + 五个原语表达——用宏而不是
每处手写 `defmethod`，为的是让六十来个类的写法完全一致：同一个位置、
同一组原语、同一种错误消息格式。散落成各写各的 `defmethod` 时，读者无法
一眼判断「这个类到底有没有约束」。

未挂的 25 个**在类定义处写明了理由**，让空缺读起来是结论而不是遗漏：
协议基类无槽、provider 允许延迟提供 key、DI 槽是自建内部状态、
`chat-options` 的 unbound 就是语义（并有一条测试守卫这个决定）。

铺开当场逮到两个潜伏已久的 bug：
1. 一个测试用 `:writes '((:counter . 1))`——**alist**，而 `apply-writes` 按
   plist 的 `cddr` 遍历，折叠时会把键读成 `(:counter . 1)`、值读成 NIL。
   那个测试只断言「存进去等于取出来」、从不真的折叠，所以一直没暴露。
2. 一处遗留的 plist 形态 `:error`——上一轮 `tool-error-info` 类化时漏改的。

两个都属于「结构错了但没人读到那一步」，正是不变式最擅长抓的类型。

## 9. 铺开当天引入又修掉的一个回归

给 `llm-response` 的 `finish-reason` 挂白名单 `require-member`，把
`normalize-finish-reason` 的**容错设计**变成了硬失败：那个函数的兜底分支
刻意把未映射的厂商值原样转成 keyword（厂商随时加 `"safety"`、`"refusal"`，
上层用 `(eq reason :tool-call)` 判断、未知值走 else 分支是正确行为），
而白名单让这类响应在构造时就崩。

**测试全是已知值，所以照样全绿——只有真实流量会炸。** 是「铺开后再回头查
生产路径的取值来源」时发现的，不是测试发现的。

得到的判据（已写进 `core/invariants.lisp` 头注）：
**枚举白名单属于我方控制取值空间的槽，不属于外部系统返回的值。**
`retry-config` 的 `backoff` 是用户配置（写错该报错）、
`chat-client-response` 的 `status` 是库内部产出、
`tool-error-info` 与 `media` 的分类有落在白名单内的兜底——这三类留白名单；
`finish-reason` 这类只校验类型。

## 10. 一个跨实现的坑

修上面那个回归时顺带撞到：**`slot :type` 声明在 CL 里不是可移植的运行时
保证**。CCL 在槽赋值时就检查（抛 `BAD-SLOT-TYPE-FROM-INITARG`，早于
`initialize-instance :after`），SBCL 在默认 safety 下**根本不检查**。

表现为同一条测试断言在两个实现上结论相反：
`(make-llm-response :finish-reason "裸字符串")` 在 CCL 上报错、在 SBCL 上
悄悄成功。一度因此把 `require-type` 删掉（以为槽的 `:type` 已经够了），
结果 SBCL 上坏数据可以一路流下去。

结论：**`:type` 与 `require-type` 两者都要**——前者表达意图并供编译器优化，
后者提供跨实现一致的拒绝。代价是抛的条件类型因实现而异，所以这类校验的
测试断言写 `(signals error ...)` 而非具体条件。

也说明了「SBCL + CCL 双跑」不是形式：这个差异只有跑第二个实现才看得见。
