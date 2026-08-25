# 工具调用架构：Filter 与 Manager 的分工

[English](tool-calling.md)

本文说明 cl-agent 的工具调用为什么拆成 **kernel 的循环（`run-tool-loop`）**、
**Filter（可组合的环绕层）** 与 **Manager（执行策略）** 三个关注点，对应
Spring AI 2.0 的哪些组件，以及我们在哪些地方**有意或已知地**偏离了参照实现。

符号速查见 [API 参考](API_CN.md) 的「工具体系」一节。

## 一句话

**Kernel 拥有循环，Filter 环绕循环，Manager 执行工具。**

```
run-tool-loop:  invoke-chat → 有 tool-calls 且 eligible? → 执行一批工具 → 追加消息 → 再调模型
                ↑ :chat 链                                  ↑ 这一格是 manager / invoke-tool-batch
                                                              批内每个工具再过 :tool 链
```

循环在 `cl-agent/core:run-tool-loop`（`core/kernel/invoke.lisp`）里——它是
**`:turn` 链的 terminal，不是 filter**，也**不在 ChatModel 里**
（`chat-model-call` 是严格的单次调用语义）。

terminal 不等于写死：`build-kernel :loop-fn` 可整体替换它，换一套循环骨架
（ReAct、plan-execute）是传一个 kernel 参数的事，不用改框架。因为替换发生在
**terminal 这个唯一出口**上，环绕它的 `:turn` filter 一律不受影响，HITL 的
续跑路径也不受影响——`resume-turn` 本来就是靠替换同一个 terminal 工作的。
自定义循环要支持暂停/续跑就配套给 `:resume-fn`，见
[API 参考](API_CN.md#loop-fn--resume-fn--替换循环骨架)。

执行层做完一批就返回：它不知道 `:max-tool-iterations`、不知道自己是第几轮、
也不决定要不要继续。这些都是 `run-tool-loop` 的事。

## Spring AI 2.0 的对应关系

| Spring AI 2.0 | cl-agent | 拥有循环 |
|---|---|---|
| `ToolCallingAdvisor`（2.0） | `run-tool-loop`（`core/kernel/invoke.lisp`，`:turn` 链终端） | **是** |
| `CallAdvisor` / `AdvisorChain` | `make-filter` / `defilter` + `build-chain` 三链 | 否（环绕） |
| `ToolCallingManager` | `cl-agent/core:tool-calling-manager`（三实现） | 否 |
| `ToolExecutionResult` | `make-tool-execution-result` plist | 结果对象 |
| `ToolExecutionExceptionProcessor` | 无对应；kernel 用三故障分类（见下） | 错误处理 |

命名注意：Spring AI 2.0 的一个 breaking change 是把 1.1.x 的 `ToolCallAdvisor`
**重命名为** `ToolCallingAdvisor`。查 1.1.x 的 javadoc 会看到旧名。

> **cl-agent 的 Advisor 与 ChatClient 两层移植物均已退役。**
> `defadvisor` / `advise-call` / `chain-next` / `tool-calling-advisor` /
> `+*-advisor-order+` 等符号已整体删除；ChatClient 移植层（ChatClient /
> Builder / fluent RequestSpec）亦已删除（`cl-agent/client` 这个**包名被复用**
> 了：现在是 SimpleAgent）。我们用 kernel + filter 三链表达
> Spring 的 Advisor 语义：`:advisors (list ...)` →
> `build-kernel :filters (list ...)`；入口则是 `build-kernel` + `chat` 宏。
> 因此下文的「advisor」一律指 Spring 侧的组件，「kernel 路径」指
> `build-kernel` → `chat` → `invoke-turn` 这条唯一执行路径。

## 为什么拆开：1.x 的教训

Spring AI 1.x 里**每个 ChatModel 实现都有自己私有的工具执行循环**——官方博客
的原话是 "functional, but buried. There was no way to hook into it"（能用，但埋
起来了，没法挂钩子）。2.0 把工具循环提升为链上一等的可组合组件，这样链上其他
组件（日志 / 记忆 / 护栏）才能观察和拦截工具调用过程。

cl-agent 吸取的是同一个教训，但落点更靠外：循环被提到 **kernel** 里，而链被拆成
**三条**，于是「挂在哪一层」本身就是可表达的语义：

| 链 | 环绕什么 | 典型 filter |
|---|---|---|
| `:turn` | 一整轮（含**整个**工具循环） | 护栏、校验重入、RAG 注入 |
| `:chat` | 循环内**每一次** LLM 调用 | 记忆、日志、渐进式工具披露 |
| `:tool` | **每一次**工具执行 | 超时、审批门、工具日志 |

这正是 1.x 做不到而 2.0 想要的东西：护栏可以选择包住整个循环（`:turn`），
也可以选择每轮复查（`:chat`）；审批门可以精确卡在单个工具上（`:tool`），
不必为此理解循环。

三条链都由 `build-chain` 折叠：`filters` 列表靠前 = 靠外 = 先执行，没有 order
字段。每层闭包**只捕获下游**，所以「递归重入」是免费的——
`validation-turn-filter` 校验不过时再调一次 `(funcall chain req)` 就重跑了整条
循环，不会把自己上游的 filter 重跑一遍。

## 两种执行模式

拆分之后有两种执行模式，都走 kernel：

1. **Framework-controlled** —— `build-kernel` + `chat` 宏，循环由 kernel 自动跑，
   调用方无感
2. **Kernel-controlled** —— 给 kernel 注入 `:tool-manager` 选执行策略

```lisp
;; 1. Framework-controlled
(cl-agent/core:build-kernel
  :model model
  :filters (list (cl-agent/core:timeout-filter 5000))
  :tools '(get-weather))

;; 2. Kernel-controlled：注入执行策略
(cl-agent/core:build-kernel
  :model model
  :tools '(get-weather)
  :tool-manager (cl-agent/core:make-sequential-tool-calling-manager))
```

> **曾经还有第三种「User-controlled」模式**——自己调 `chat-model-call`，再拿
> 合并前 `cl-agent/chat` 的 ToolCallingManager 驱动循环。它已不存在：chat 层那套
> manager（`default-tool-calling-manager` / `concurrent-tool-calling-manager` /
> `(manager prompt response)` 签名的 `execute-tool-calls` /
> `tool-execution-result` 及其读取器）已整体删除。工具执行现在**只**住在
> kernel 层——`run-tool-loop`、`invoke-tool-batch`，以及三个
> ToolCallingManager。kernel 是唯一路径。
>
> 附带的好处：chat 层的 `execute-tool-calls` 消失、kernel 载体改名为
> `tool-result` 之后，两个包再无同名导出，`:shadow` 随之删除——这正是
> `cl-agent/http` / `/chat` / `/kernel` 三包得以合并为 `cl-agent/core` 的前提。

## 执行层做的事

`run-tool-loop` 每轮判定有 `tool-calls` 且通过 `eligibility-fn` 后，把这一批交给
执行层——`kernel-tool-manager` 为 nil 时走 `invoke-tool-batch`
（`core/kernel/batch.lisp`），非 nil 时走 `execute-tool-calls` 协议。它：

1. **解析** —— 按名字找 callback（`find-callback-for-call`，`core/chat/tool.lisp`）
2. **调度** —— 缺省**整批并行**（`lparallel:future`）；批内任一工具声明
   `:serial` 则整批退化为顺序执行；≤1 个工具时也退化顺序，省掉无意义的开销
3. **过 `:tool` 链** —— 每个工具经 `invoke-tool` 进入 `:tool` 洋葱
   （超时 / 审批 / 日志都在这一层生效）
4. **隔离错误** —— 工具抛条件不炸掉整个对话，而是被捕获成
   `tool-result` 的 `:error` 槽，经 `tool-result->text` 转文本回传模型让它自纠错。
   **工具名不存在**也走这条路：`resolve-callback` 捕获 `tool-not-found-error`，
   转成 `:semantic` 错误结果，渲染为「错误：找不到工具 xxx」，而不是让条件冒泡出
   `(chat ...)` 中断整轮对话
5. **汇总 return-direct** —— 批内**所有**工具都声明了 `:return-direct` 时才置 T；
   此时工具结果即最终答案，不再回传模型

结果按原 `tool-calls` 顺序返回——并行只影响时序，不影响消息顺序。

### 为什么值得做成独立抽象

如果只是「循环调 callback」，在 `run-tool-loop` 里 `mapcar` 就够了。它独立存在
是因为**执行策略**是可替换点：

- `make-virtual-thread-tool-calling-manager` —— 并行默认，尊重 `:serial`，
  适合工具体是 HTTP / DB 这类 I/O
- `make-sequential-tool-calling-manager` —— 全串行，适合调试或严格副作用顺序
- `make-thread-pool-tool-calling-manager` —— 线程池，限流场景（可配 `pool-size`）

换实现不用动循环，也不用动任何 filter。

## 三种故障分类

`core/kernel/conditions.lisp` 把工具故障分成三类，`classify-tool-error` 负责把
任意 condition 映射到其一：

| 分类 | 含义 | 预期动作 |
|---|---|---|
| `:semantic` | 模型问题：参数格式错、逻辑错、不支持的操作 | 不重试，转文本回传模型自纠错 |
| `:transient` | 瞬态故障：超时、限流（429/503）、连接重置 | 可重试 |
| `:environment` | 环境错误：权限不足、认证失败、依赖宕机 | 需人工介入 |

分类规则按优先级：`tool-failure` 子类直接取 `:class` 槽 → `tool-not-found-error`
/ `tool-execution-error` 为 `:semantic` → 否则按错误消息关键词启发式判断
（"timeout"/"超时"/"429"/"503" → `:transient`；"permission denied"/"unauthorized"/
"权限不足" → `:environment`）→ 兜底 `:semantic`（保守：不重试）。

工具作者可以直接发精确的条件，绕开启发式：

```lisp
(cl-agent/core:deftool fetch-quote (&key symbol)
  "抓取股票报价"
  (:param symbol :string "股票代码" :required t)
  (:retry t)
  (handler-case (http-get-quote symbol)
    (error (e)
      (error 'cl-agent/core:transient-tool-failure
             :message (princ-to-string e)))))
```

分类直接驱动路由：`:transient` 且工具声明了 `(:retry t)` → 框架内部指数退避重试；
其余一律贴标签放进 `tool-result` 的 `:error` 槽（供 `:tool` filter 与调用方读取），
并把文本回传模型。仍缺的那一个分支（`:environment` → 暂停等人）见下面第 3 条。

> 分类必须**看穿一层包装**：`tool-callback-call` 会把工具体 signal 的**一切**
> 包成 `tool-execution-error`，原件塞进 `:cause`。`classify-tool-error` 递归解包——
> 不解的话，工具明明 signal 了 `transient-tool-failure`，出来也只剩 `:semantic`，
> 三类故障直接退化成一类。

## 一个安全边界

`find-callback-for-call` **只查本次请求的 options，不回退全局注册表**。

这是刻意的：否则任何 `deftool` 过的工具，只要模型报出名字就能被执行——提示注入
下可直接利用的越权。而 `deftool` 是自动注册的，作者根本意识不到攻击面被扩大了。

参照实现同样没有这种回退：clj-agent 的 `find-function` 只查 kernel 的
`:tool-vars`，找不到即抛；Spring 的 `ToolCallbackResolver` 是 manager 的实例
字段，默认为空。

**「找不到」是语义故障，不是崩溃。** `find-callback-for-call` 找不到时发
`tool-not-found-error`。这个条件曾在批执行路径的 `handler-case` **之外**发出，
于是模型只要报出一个幻觉工具名（LLM 常见故障），条件就会一路冒泡出 `(chat ...)`
中断整轮对话。现在 `resolve-callback`（`core/kernel/batch.lisp`）会捕获它，产出
`:semantic` 错误的 `tool-result`，经 `tool-result->text` 渲染为
「错误：找不到工具 xxx」回传模型，让它自纠（改用别的工具、修参数）。边界本身不变：
没暴露的工具依然绝不执行，只是改用语言告诉模型。

kernel 化之后这条边界没有松动，反而更紧了一层：kernel 的 `resolve-kernel-tools`
只认 `kernel-tools`（加上本次请求 `(:tools ...)` 合并进来的 caller-options），
`run-tool-loop` 每轮重新解析。护栏与审批门则是**独立的第二道**：
`safeguard-turn-filter` 在 `:turn` 链短路（返回 `:cancelled` 的 `turn-result`，
模型根本没被调用），`approval-filter` 在 `:tool` 链逐工具卡门——两者都不依赖
工具解析是否正确。

## 已知偏差

### 1. `resolveToolDefinitions` 不在 manager 上（结构性缺口）

Spring 的 manager 接口是**双向**的：

```java
public interface ToolCallingManager {
    List<ToolDefinition> resolveToolDefinitions(ToolCallingChatOptions chatOptions);  // 出站
    ToolExecutionResult executeToolCalls(Prompt prompt, ChatResponse chatResponse);   // 入站
}
```

cl-agent 的 kernel manager 只有入站那一半（`execute-tool-calls`）。出站解析用自由
函数 `resolve-tool-callbacks`，散在三个调用点：`core/chat/model.lisp`（按名字解析
`:tool-names`）、`core/kernel/invoke.lisp`（`resolve-kernel-tools`：kernel 级
`:tools`）、`core/kernel/chat.lisp`（`kernel-chat`：请求级 `(:tools ...)`）。

**后果**：Spring 里「换个 manager 就同时改变工具暴露和执行」的能力，这里做不到
——想改工具暴露得动三个调用点。

**缺口比 1.x 时代窄了**：filter 化之后，「改变本次暴露的工具」有了正规的挂载点
——`tool-search-filter` 就是在 `:chat` 链上重写 prompt options 的
`:tool-callbacks` 来做渐进式披露的。按租户过滤可见工具这类需求，现在写一个
`:chat` filter 即可，不必把 `resolve-tool-definitions` 提为 manager 的泛型函数。
真正的缺口只剩「暴露与执行必须由同一个对象决定」这一条语义。

### 2. 没有 ToolExecutionExceptionProcessor（有意）

Spring 把错误处理做成独立的 functional interface，作为策略对象注入 manager：

```java
@FunctionalInterface
public interface ToolExecutionExceptionProcessor {
    String process(ToolExecutionException exception);
}
```

cl-agent 没有这个 seam：错误在 `tool-apply-terminal` 被捕获成 `tool-result` 的
`:error` plist（`(:class ... :message ...)`），由 `tool-result->text` 渲染给模型。
要定制就写一个 `:tool` filter 包住它——filter 拿得到 request 与 response 两侧，
比一个只接收 exception 的处理器更强。

（已删除的旧 chat 层 manager 曾有对应物：泛型函数
`(process-tool-execution-error manager condition tool-call)`，随 manager 一并消失。
它的默认语义——把故障转成文本回传模型——由 `tool-result->text` 承接，这也正是
工具名不存在时会渲染成「错误：找不到工具 xxx」而非无用占位符的原因。）

**代价**：定制错误文本没有「一行特化」的写法，得写 filter。

### 3. `:environment` 不会暂停等人（部分实现）

分级重试**已实现**：`:transient` + 工具声明 `(:retry t)` → 指数退避，
最多 `*transient-retry-attempts*` 次（缺省 3），退避基数
`*transient-retry-base-delay*`（缺省 0.1s）逐次翻倍。重试是逐工具 opt-in 的——
重试意味着重复副作用，框架不替工具作者决定。

**没实现的是矩阵的另一半**：clj-agent 里 `:environment` 故障会**暂停等人介入**
（`:env-retry` 类暂停），这里仍只转文本回传模型。

**为什么不是「加个分支」那么简单**：本仓库已实现的审批类暂停
（`:tool-gate` + `resume-turn`）切在批执行**之前**——一个工具都没跑，
快照天然一致。而环境类暂停切在**屏障处**：批已经执行完了，有的工具成功、
某个撞上了挂掉的依赖。续跑意味着只重跑失败的那些、同时保住已成功的结果——
快照形状与今天 `loop-state` 携带的不同。

**当前后果**：依赖挂了，在模型看来和普通报错没区别，它多半会道歉了事，
而不是等人把环境修好。

### 4. 默认错误语义不同（语言差异，不可避免）

Spring 的 `DefaultToolExecutionExceptionProcessor` 按异常类型分流：

| 异常类型 | 行为 |
|---|---|
| `RuntimeException` | 转文本回传模型 |
| checked exception（如 `IOException`） | 抛给调用方 |
| `Error`（如 `OutOfMemoryError`） | 抛给调用方 |

CL 没有 checked exception 的概念，精确对齐不可能。cl-agent 偏得更远：
`tool-apply-terminal` 捕获的是**全部** `error`，于是工具体里的任何错误都不会
冒泡给调用方，一律变成回传模型的文本；`resolve-callback` 把
`tool-not-found-error` 也纳入同样的处理。这比 Spring 更「宽容」，也意味着
`Error` 级别的问题会被静默吞掉当成模型能自纠的事。从 kernel 逃出来的只剩
`max-tool-iterations-exceeded-error`（循环超限，由 `run-tool-loop` 直接发）。
需要错误冒泡时，写一个 `:tool` filter 检查 `tool-result-error` 并重新 signal。

## 参考

- [Tool Calling in Spring AI 2.0: A Composable, Agentic Architecture](https://spring.io/blog/2026/06/15/spring-ai-composable-tool-calling/)
- [Tool Calling :: Spring AI Reference](https://docs.spring.io/spring-ai/reference/api/tools.html)
- [Recursive Advisors :: Spring AI Reference](https://docs.spring.io/spring-ai/reference/api/advisors-recursive.html)
- [Upgrade Notes :: Spring AI Reference](https://docs.spring.io/spring-ai/reference/upgrade-notes.html)
