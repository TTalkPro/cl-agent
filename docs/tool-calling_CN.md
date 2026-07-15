# 工具调用架构：Advisor 与 Manager 的分工

[English](tool-calling.md)

本文说明 cl-agent 的工具调用为什么拆成 **ToolCallingAdvisor（循环）** 与
**ToolCallingManager（执行）** 两层，对应 Spring AI 2.0 的哪些组件，以及
我们在哪些地方**有意或已知地**偏离了参照实现。

符号速查见 [API 参考](API_CN.md) 的「工具体系」一节。

## 一句话

**Advisor 拥有循环，Manager 执行工具。**

```
advisor 循环:  调模型 → 有 tool-calls? → manager 执行一轮 → 拿 history 组下一轮 prompt → 再调模型
                                        ↑ manager 的全部职责就是这一格
```

Manager 做完一轮就返回，它不知道 `max-iterations`、不知道自己是第几轮、
也不决定要不要继续。这些都在 advisor 里（`core/client/tool-advisor.lisp`）。

## Spring AI 2.0 的对应关系

| Spring AI 2.0 | cl-agent | 拥有循环 |
|---|---|---|
| `ToolCallingAdvisor` | `tool-calling-advisor`（`core/client/tool-advisor.lisp`） | **是** |
| `ToolCallingManager` | `tool-calling-manager`（`core/chat/tool.lisp`） | 否 |
| `ToolExecutionResult` | `tool-execution-result` | 结果对象 |
| `ToolExecutionExceptionProcessor` | `process-tool-execution-error` 泛型函数 | 错误处理 |

命名注意：Spring AI 2.0 的一个 breaking change 是把 1.1.x 的 `ToolCallAdvisor`
**重命名为** `ToolCallingAdvisor`。查 1.1.x 的 javadoc 会看到旧名。

## 为什么拆成两层：1.x 的教训

Spring AI 1.x 里**每个 ChatModel 实现都有自己私有的工具执行循环**——官方博客
的原话是 "functional, but buried. There was no way to hook into it"（能用，但埋
起来了，没法挂钩子）。2.0 把工具循环提升到 advisor 链里成为一等的可组合组件，
这样链上其他 advisor（日志 / 记忆 / 护栏）才能观察和拦截工具调用过程。

拆分之后有三种执行模式，cl-agent 三种都支持：

1. **Framework-controlled** —— ChatClient 自动注册 advisor，调用方无感
2. **Advisor-controlled** —— 显式构造 advisor 并注入自定义 manager
3. **User-controlled** —— 调用方自己拿 manager 写循环

```lisp
;; 3. User-controlled：manager 脱离 advisor 单独用
(let ((mgr (make-default-tool-calling-manager)))
  (loop for response = (chat-model-call model prompt)
        while (chat-response-tool-calls response)
        do (let ((result (execute-tool-calls mgr prompt response)))
             (setf prompt (prompt-copy
                           prompt
                           :messages (tool-execution-conversation-history result))))
        finally (return response)))
```

**第三种模式正是 manager 必须独立于 advisor 的理由**：manager 要能脱离 advisor
单独用。这也解释了 `chat-client` 上的 `auto-tool-advisor` 开关（对标
`AdvisorParams.toolCallingAdvisorAutoRegister(false)`）——关掉它就进入
user-controlled 模式。

## Manager 做的五件事

给它一个带 `tool-calls` 的 `chat-response`（`execute-tool-calls`），它：

1. **解析** —— 按名字找 callback（`find-callback-for-call`，`core/chat/tool.lisp`）
2. **执行** —— 调 callback，传入 args 和 `tool-context`
3. **隔离错误** —— 工具抛异常不炸掉整个对话，而是经
   `process-tool-execution-error` 转成错误文本回传模型，让模型自纠错
4. **组装会话历史** —— 拼成 `原消息 + assistant(tool-calls) + tool-response`，
   即下一轮 prompt 的消息列表
5. **汇总 return-direct** —— 任一工具声明了 `:return-direct` 就置 T

返回的 `tool-execution-result` 只有两个字段：`conversation-history` 和
`return-direct`。

### 为什么值得做成独立抽象

如果只是「循环调 callback」，在 advisor 里 `mapcar` 就够了。它独立存在是因为
有两个可替换点：

- **执行策略** —— `default-tool-calling-manager` 顺序执行；
  `concurrent-tool-calling-manager` 走 lparallel 线程池并发执行，适合工具体是
  HTTP / DB 这类 I/O。两者语义完全一致（结果按原序、return-direct 取并集、
  错误同样隔离），换实现不用动循环。并发版在 ≤1 个工具时 `call-next-method`
  退化回顺序版，省掉无意义的线程池开销。
- **错误策略** —— `process-tool-execution-error` 是泛型函数，默认转文本回传，
  也可特化成直接 re-signal 让错误冒泡给调用方。

## 一个安全边界

`find-callback-for-call` **只查本次请求的 options，不回退全局注册表**。

这是刻意的：否则任何 `deftool` 过的工具，只要模型报出名字就能被执行——提示注入
下可直接利用的越权。而 `deftool` 若自动注册，作者根本意识不到攻击面被扩大了。

参照实现同样没有这种回退：clj-agent 的 `find-function` 只查 kernel 的
`:tool-vars`，找不到即抛；Spring 的 `ToolCallbackResolver` 是 manager 的实例
字段，默认为空。

## 已知偏差

### 1. `resolveToolDefinitions` 不在 manager 上（结构性缺口）

Spring 的 manager 接口是**双向**的：

```java
public interface ToolCallingManager {
    List<ToolDefinition> resolveToolDefinitions(ToolCallingChatOptions chatOptions);  // 出站
    ToolExecutionResult executeToolCalls(Prompt prompt, ChatResponse chatResponse);   // 入站
}
```

cl-agent 的 `tool-calling-manager` 只有入站那一半（`execute-tool-calls`）。
出站解析用自由函数 `resolve-tool-callbacks`，散在三个调用点：
`core/chat/model.lisp`、`core/client/chat-client.lisp`、
`core/client/tool-search-advisor.lisp`。

**后果**：Spring 里「换个 manager 就同时改变工具暴露和执行」的能力，这里做不到
——想改工具暴露得动三个调用点。目前没有需要这么做的场景，故未补齐；若将来出现
（例如按租户过滤可见工具），应把 `resolve-tool-definitions` 提为 manager 的
泛型函数。

### 2. ToolExecutionExceptionProcessor 折叠进了 manager（有意）

Spring 是独立的 functional interface，作为策略对象注入 manager：

```java
@FunctionalInterface
public interface ToolExecutionExceptionProcessor {
    String process(ToolExecutionException exception);
}
```

cl-agent 做成 manager 上的三参泛型函数：

```lisp
(process-tool-execution-error manager condition tool-call)
```

**理由**：CLOS 里泛型分派本来就取代策略对象，不需要为「一个方法的接口」造一个
类。而且我们多传了 `tool-call`，比 Spring 只给 exception 的信息更全——特化时
可以按工具名分别处理。

### 3. 默认错误语义不同（语言差异，不可避免）

Spring 的 `DefaultToolExecutionExceptionProcessor` 按异常类型分流：

| 异常类型 | 行为 |
|---|---|
| `RuntimeException` | 转文本回传模型 |
| checked exception（如 `IOException`） | 抛给调用方 |
| `Error`（如 `OutOfMemoryError`） | 抛给调用方 |

cl-agent 捕获 `tool-execution-error` / `tool-not-found-error` 两个条件转文本，
其余条件自然冒泡。效果上接近（严重错误都会冒泡），但分类依据是「条件类型是否在
handler-case 名单里」而不是「是否 unchecked」——CL 没有 checked exception 的
概念，这个偏差不可避免。

## 参考

- [Tool Calling in Spring AI 2.0: A Composable, Agentic Architecture](https://spring.io/blog/2026/06/15/spring-ai-composable-tool-calling/)
- [Tool Calling :: Spring AI Reference](https://docs.spring.io/spring-ai/reference/api/tools.html)
- [Recursive Advisors :: Spring AI Reference](https://docs.spring.io/spring-ai/reference/api/advisors-recursive.html)
- [Upgrade Notes :: Spring AI Reference](https://docs.spring.io/spring-ai/reference/upgrade-notes.html)
