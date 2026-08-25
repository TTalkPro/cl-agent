# 待完成任务

> 来源：2026-07-16 会话。advisor→chat-client+filter 架构重构（P1-P5 + TCM）。
> 参照实现为 `~/workspace/clj-agent`（Clojure chat-client+filter 架构）+ Spring AI 2.0。
>
> 测试基线：SBCL 2.6.6 **839 checks / 0 failures**
> （810 → 652：advisor 实现与测试一并删除；→ 693：旧 ToolCallingManager
>  测试随该层退役，安全边界测试改写保留；→ 761：新增 SimpleAgent、
>  HITL pause/resume、消息去重、线程池限流、故障分类与重试等测试）。
> 真实 provider 验证：`scripts/live-test.lisp` MiniMax **8/8**
> （单次问答 / 工具循环 / 多轮记忆 / schema 校验 / HITL 暂停·批准·拒绝 / SSE）。
>
> 完整重构计划见 `.sisyphus/plans/chat-client-filter-refactor.md`。

---

## 架构现状

三模块分层（对标 clj-agent 的 core / provider / client）：

```
cl-agent/core（框架本体，单包 477 导出）
  ├── Filter CLOS 类（四钩子: :tool/:chat/:turn/:token-xform）
  ├── build-chain（洋葱折叠, 闭包仅下游, 递归重入免费）
  ├── ChatClient（model/tools/filters/settings/tool-manager +
  │   默认 system/options, 无 memory）
  ├── 载体：tool-request/tool-result、turn-request/turn-result
  │   （chat 链无专门载体：请求=prompt，响应=chat-response）
  ├── invoke-chat/tool/turn + run-tool-loop（:turn terminal）
  ├── invoke-tool-batch（并行/:serial/故障路由）
  ├── ToolCallingManager 协议（Sequential/VirtualThread/ThreadPool 三实现）
  ├── 10 个内置 filter（memory/logging/safeguard/validation/
  │   re-reading/RAG/tool-search/timeout/approval/token-xform）
  ├── chat 宏 DSL + chat-client-call* 函数入口
  ├── HITL：tool-gate + loop-state + resume-turn
  └── 基础设施 + HTTP/SSE + Chat API（原 core/http/chat/chat-client 四包合并）

cl-agent/llm（提供商，独立可插拔）
  └── 9 个 provider + create-chat-model

cl-agent/client（面向应用的易用层，v10 新增）
  └── SimpleAgent：有状态对话 + callbacks + 错误归一化 + HITL
```

## 已完成（2026-07-16）

### P1: Filter 机制 + ChatClient 骨架 ✅

- [x] filter CLOS 类（四钩子: :tool/:chat/:turn/:token-xform）
- [x] build-chain 洋葱折叠（reduce + reverse → 嵌套闭包）
- [x] defilter 宏（(self req chain) 三参数签名）
- [x] chat-client CLOS 类（model/tools/filters/settings, 无 memory）
- [x] 载体类（tool-request/response, turn-request/result）
- [x] 测试基线 715 → 756（+41）

### P2: 三链 invoke 原语 + 工具循环 ✅

- [x] invoke-chat（:chat 链 → chat-model-call）
- [x] invoke-tool（:tool 链 → tool-callback-call）
- [x] invoke-turn（:turn 链包住 run-tool-loop）
- [x] run-tool-loop（工具调用循环, :turn terminal）
- [x] 循环等价性测试（invoke-turn vs 旧 ChatClient+advisor）
- [x] 测试基线 756 → 781（+25）

### P3: 批执行 + 故障路由 + return-direct ✅

- [x] deftool 扩展 :serial/:retry 声明
- [x] invoke-tool-batch 并行默认（lparallel:future）+ :serial 退化按序
- [x] return-direct（工具结果=最终答案, 不回灌 LLM）
- [x] eligibility-fn 可插拔续跑判据
- [x] 三故障分类（:semantic/:transient/:environment）+ classify-tool-error
- [x] 测试基线 781（0 回归）

### P4: 10 个内置 filter ✅

- [x] memory-filter（:chat 首位, 循环内, 每轮落完整 transcript）
- [x] logging-chat-filter + logging-tool-filter
- [x] safeguard-turn-filter（:turn, 大小写不敏感短路）
- [x] validation-turn-filter（:turn, 递归重入 + structured-output 判据）
- [x] re-reading-filter（:turn, RE2 技巧, :resume-p 跳过）
- [x] qa-turn-filter（:turn, RAG 注入, IRetriever 协议）
- [x] tool-search-filter（:chat, 渐进式披露, IToolIndex + keyword-tool-index）
- [x] timeout-filter（:tool, bordeaux-threads 超时）
- [x] approval-filter（:tool, 预执行审批门）
- [x] token-redact-filter + hold-release-filter（:token-xform transducer）
- [x] 测试基线 781（0 回归）

### P5: ChatClient 桥接 + 对齐审计 ✅

- [x] chat-client 加 :chat-client 槽, call-client-response 双路径分派
- [x] ChatClient 移植层的桥接工厂（由 chat-client 内核驱动）
- [x] 对齐审计测试（10 filter 类型 + ChatClient 桥接 + 故障分类）
- [x] 测试基线 781 → 810（+29）

### ToolCallingManager 协议 ✅

- [x] execute-tool-calls 泛型协议 + tool-execution-result plist
- [x] sequential-tool-calling-manager（全串行, 调试/严格副作用）
- [x] virtual-thread-tool-calling-manager（并行默认, 尊重 :serial）
- [x] thread-pool-tool-calling-manager（线程池, 可配 pool-size）
- [x] chat-client 加 :tool-manager 槽, build-chat-client 支持 :tool-manager
- [x] run-tool-loop nil-check 接入（有 manager → 协议路径; nil → 原路径）
- [x] 测试基线 810（0 回归）

---

## 已完成（2026-07-16 续）

### P5-续: Advisor API 完全退役 ✅

> 测试基线 810 → 652（advisor 测试随实现一并删除）→ 666（+14 filter 调用测试）。

- [x] **删除 advisor 实现文件**：`advisors.lisp`, `tool-advisor.lisp`,
      `tool-search-advisor.lisp`, `structured-output-advisor.lisp`
- [x] **`advisor.lisp` → `carriers.lisp`**：只保留 client-request/response +
      context 读写（ChatClient 公开载体）；协议/洋葱链/defadvisor/order 常量全删
- [x] **chat-client.lisp 清除 advisor 残留**：删掉从不被读的 `default-advisors` /
      `auto-tool-advisor` 槽、`builder-advisors`、`spec-advisors`、`prompt-advisors`
      （它们已是静默 no-op——比不存在更危险）；`(chat ... (:advisors ...))`
      改为显式报错并给迁移指引，不再静默丢弃
- [x] **删除旧 advisor 测试**：`test-advisor.lisp`, `test-tool-advisor.lisp`,
      `test-tool-search.lisp`, `test-structured-output.lisp`
- [x] **更新 asd + package 导出**：client 模块换 carriers，导出表清干净
- [x] **examples/chat-client-usage.lisp 迁移到 filter**：example-4 用
      `memory-filter`，example-5 用自定义 `make-filter` + safeguard/logging；
      8 个示例全部实跑通过
- [x] **README.md 重写**：架构图/对应表/快速开始全部改为 chat-client+filter；
      原「快速开始」教的 `:advisors (list ...)` 现在是硬报错，
      「`(:call :entity schema)` 会自动校验并重试最多 3 次」也早已不成立
      （`call-entity` 只解析）——都已改正并实跑验证
- [x] **全量回归**：684 checks / 0 failures

### 顺带修掉的 5 个真实 bug ✅

> 共同根因：P4/P5 的 filter 测试只**构造** filter、检查钩子槽非空，
> 从不**驱动**钩子跑完整链路。钩子体内的错误、跨载体的 context 桥接
> 断裂一律照不到，810 checks 全绿也没用。已补 21 个实际驱动钩子/端到端
> 的测试（690 total），每个 bug 都验证过「改回旧代码即失败」。

- [x] **`qa-turn-filter` 从未能工作**（`chat-client/filters/rag.lisp`）：
      `let` 该写 `let*`——`new-messages` 的初值引用同一个 `let` 里的
      `enhanced`，于是只要检索到任何文档就必然
      `UNBOUND-VARIABLE: ENHANCED`。编译期一直有
      `undefined variable: CL-AGENT/CHAT-CLIENT::ENHANCED` 告警，无人理会。

- [x] **`structured-output-validate-fn` 判据完全反相**
      （`chat-client/filters/validation.lisp`）：把
      `validate-json-schema` 的返回当 `ok-p` 用，但它返回的是
      **错误消息列表**（NIL 才是通过）。实测后果：合规 JSON →
      `ok-p=NIL` + 反馈「输出不符合 Schema 要求（NIL）」→ 触发重试；
      不合规 JSON → `ok-p=T` → 直接放行。即**恰好做反**。
      顺带：反馈里的 `path` 永远是 NIL（该函数没有第二返回值），
      现改为逐条回喂真实错误（`$.name：期望类型 string，实际为 integer`），
      模型才有得改。

- [x] **解析失败被当成通过**（同上）：`(if parsed ...)` 把「没给
      parse-fn」和「给了 parse-fn 但模型吐的不是 JSON」挤在一个分支，
      后者直接放行——而这恰恰是该 filter 头号要拦的情况。
      改为四路判定：空文本→不合格；无 parse-fn→放行；解析失败→不合格；
      解析成功→按 schema 校验。

- [x] **`chat-client:strip-json-fences` 对带围栏输入必报错**（同上）：
      `(string= body "```" :start2 ...)` 该用 `:start1`——start 索引
      属于被切片的那侧，写成 `:start2` 等于去 `"```"` 这个长度 3 的
      字面量里取第 34 位 → `bounding indices ... are bad`。
      而 LLM 最爱吐 ```json 围栏的 JSON。叠加上一条，合规输出会被
      判为「不是合法 JSON」并烧光全部重试。已修 + 支持裸 ``` 围栏。

- [x] **多轮记忆经 `(:conversation id)` 静默失效**
      （`chat-client/invoke.lisp` + `filters/memory.lisp`）：`memory-filter`
      从 **prompt options 的 tool-context** 读 `:conversation-id`，而
      `(:conversation "id")` / `prompt-context` 写的是 **turn context**。
      `run-tool-loop` 只把 caller-options 铺进 prompt options，从不把
      turn context 桥过去——于是 README 和 example-4 的头号写法
      `(:conversation "conv-1")` 根本到不了 memory-filter，`memory-messages`
      恒为空，多轮记忆完全不生效。实测：折叠前 0 条，折叠后 4 条。
      修法：`run-tool-loop` 用新的 `fold-context-into-tool-context` 把
      turn context（剔除内部键 `:caller-options`）折进 options 的
      tool-context，同名键 context 胜出；只覆盖 tool-context 一个槽，
      `tool-callbacks` 等原样保留（加了「带工具 + conversation」的回归
      测试确认工具没被冲掉）。加 3 个回归测试（可达/隔离/工具共存），
      每个都验证过「去掉折叠即失败」。

> 注：`strip-json-fences` 在 `cl-agent/client` 与 `cl-agent/chat-client`
> 各有一份实现（client 那份一直是对的，chat-client 那份刚修）。两份都还在，
> 行为已对齐，但重复本身值得后续收口到 `cl-agent/core`。

### 文档全量对齐 chat-client+filter ✅

- [x] **README.md / README_EN.md**：架构图/执行路径图/对应表/快速开始
      全部改写；每段 lisp 片段都实跑验证过
- [x] **core/README.md / core/README_EN.md**：包表加 `cl-agent/chat-client`，
      文件树换成 chat-client/ + client/carriers.lisp，删掉不存在的 advisor 文件；
      「内部工具执行」错误论断（工具循环住 ChatModel 内）已改正
- [x] **docs/API.md / API_CN.md**：删 Advisor 章，加 cl-agent/chat-client 章
      （filter/build-chat-client/invoke-*/run-tool-loop/三 manager/10 filter
      真实签名），ChatClient 章收敛到现存 API，补迁移表（子代理完成）
- [x] **docs/QUICKSTART / tool-calling（CN+EN）**：自定义 Advisor → filter，
      标题「Advisor 与 Manager」→「Filter 与 Manager」，工具循环归位到
      run-tool-loop，补三故障分类 + :serial 批语义（子代理完成）
- [x] **examples/README（CN+EN）**：example-5 描述改为 filter

---

### cl-agent/client 整包退役 ✅（2026-07-16 续二）

> 决策：Advisor 退役后，ChatClient 是 Spring AI 留下的第二个移植层
> （ChatClient + Builder + fluent RequestSpec）。Builder 与链式 spec 是
> Java 的表达习惯——在 Lisp 里 `build-chat-client` 的关键字参数 + 声明式 `chat`
> 宏覆盖同样的场景，还少一个包、少一层间接。故整包删除，只把 `chat` 宏
> 搬进 chat-client（它本就不是 Spring 写法，是 Lisp 化的 DSL）。

- [x] **`chat` 宏搬入 `cl-agent/chat-client`**（新文件 `core/chat-client/chat.lisp`）：
      宏 + 函数形态入口 `chat-client-call` / `chat-client-text` /
      `chat-client-entity` / `chat-client-stream`
- [x] **删除 `core/client/` 整个目录**（package / carriers / chat-client，594 行）
      —— 载体 `client-request` / `client-response` / `context-*` 是纯死代码
      （chat-client 三链不用它们，:chat 链的请求就是 prompt、响应就是 chat-response）
- [x] **终结操作调整**：`(:call :client-response)` → `(:call :result)`
      （返回 turn-result，能看 status）；其余 `:content` / `:response` /
      `:entity` / `:stream` 语义不变
- [x] **请求级 `:tools`** 与 chat-client 的 `:tools` 取并集（经 caller-options 的
      tool-callbacks，run-tool-loop 的 merge 天然并集）
- [x] **补回 chat-client 级默认 system / options**（`build-chat-client :system :options`）：
      这是**删 client 时我引入的功能回归**——旧 `make-chat-client` 有
      `:system` / `:options`（客户端级默认），第一版 `build-chat-client` 没接，
      等于逼用户每次请求重写 system。文档子代理审计时发现并报了上来，
      核实属实（`build-chat-client` 原签名只有 model/tools/filters/
      eligibility-fn/settings/tool-manager）。已加 `default-system` /
      `default-options` 两个槽 + 访问器，合并语义：
      system 请求级**覆盖**、options 请求级**优先**（未提及的默认项保留）、
      tools **取并集**。加 5 个测试守住（含「默认 options 与 :tools 共存，
      merge 不冲掉 tool-callbacks」）
- [x] **测试迁移**：`test-chat-client.lisp` → `test-chat-client-chat.lisp`
      （14 → 13 个测试；Builder / fluent spec 的 6 个随该层退役，
      新增 `(:call :result)`、`:messages`、请求级工具并集、
      `(:conversation ...)` 可达 memory-filter 四项）
- [x] **删除孤儿测试**：`test-parallel-tools.lisp`（不在 asd，且引用已删符号）
- [x] **删除同义反复测试**：`chat-client-loop-equivalent-to-advisor`（原本比较
      「旧 ChatClient+advisor」vs「chat-client」，advisor 退役后 ChatClient 本就
      走 chat-client，等于自己和自己比；client 删除后连对照组都不存在）
- [x] **examples 重写**：`chat-client-usage.lisp` → `chat-client-usage.lisp`，
      8 个示例全部实跑通过
- [x] **文档全量改到 chat-client API**：README / core README / examples README /
      llm README / mock README（各中英两版）+ docs/ 六个文件。
      `llm/README` 与 `mock/README` 此前都在教 `make-chat-client`——
      即已删除的 API，属于会直接撞墙的示例，已改并实跑验证
- [x] **版本号** 8.0.0 → 9.0.0（两个 asd）
- [x] **全量回归**：699 checks / 0 failures（冷编译，零告警）

### 真实 provider 验证 ✅

- [x] **`scripts/live-test.lisp`**（独立脚本，不进套件——套件保持全 mock、
      离线可跑、零 API 花费）。MiniMax 实测 **5/5 全过**：
      单次问答（巴黎）/ 真实工具循环（断言工具确实被执行 1 次，而非模型编造）/
      memory 多轮（模型答出上一轮的 42）/ 结构化输出 schema 校验
      （name=Tokyo population=13960000 整数）/ 真实 SSE（23 个分片）
- [x] 顺带证实 **README 宣称的「真 SSE 流式」属实**：底层 76 个原始分片
      （含 MiniMax 的 reasoning-delta），文本 7 分片。此前 live 脚本
      第一版误判失败，是因为「数到 5」太短模型一口吐完——测试断言的问题，
      非实现问题，已改用足够长的提示。

---

### 包设计撞名 + 旧 ToolCallingManager 退役 ✅（2026-07-16 续三）

> 两件是同一个根因，一起做掉。做完 `cl-agent/chat-client` **不再需要任何
> `:shadow`**，下游可以直接 `(:use :cl-agent/chat :cl-agent/chat-client)`
> 而不必自己写 shadowing-import（已编译验证）。

- [x] **chat-client 载体改名**：`tool-response` → `tool-result`
      （accessors：`tool-response-result` → `tool-result-value`、
      `-writes` / `-error` 同理；构造 `make-tool-result :value`）。
      理由：与 turn 链的 `turn-request` → `turn-result` 对称，且撞名本就是
      巧合——chat 的 `tool-response` 是**协议消息层**的值对象（id/name/text，
      装进 role=:tool 的消息），chat-client 的是**执行链层**的载体
      （value/writes/error），两者分属不同层。
- [x] **删除 `cl-agent/chat` 的旧 ToolCallingManager**（tool.lisp 766 → 502 行）：
      `tool-calling-manager` / `default-tool-calling-manager` /
      `execute-tool-calls` / `execute-one-tool-call` /
      `process-tool-execution-error` / `concurrent-tool-calling-manager` /
      `with-concurrent-tool-calling-manager` / `tool-execution-result` 等全删。
      工具执行唯一住在 chat-client。
- [x] **保留并导出 `find-callback-for-call`**：它长在 manager 区块里但与
      manager 无关（只是「按名找工具」），且 chat-client 的 batch / manager /
      tool-search filter 都依赖它。顺带从内部符号（`::` 访问）提为正式导出。
      它那段**安全边界注释**（不回退全局注册表 = 防提示注入越权）一并保留。
- [x] **移除 chat-client 的 `:shadow`**：三个撞名（`tool-response` /
      `make-tool-response` / `execute-tool-calls`）已全部消除。
- [x] **测试改写而非删除**：`test-tool.lisp` 的 manager 测试随该层退役，
      但**两个安全边界测试（越权回归）改写成走完整 chat-client 链路保留下来**——
      那是防提示注入的真实边界，不能因为 manager 没了就丢。另加
      `find-callback-for-call` 的解析/拒绝测试。
- [x] **清理过时源码注释**（文档子代理审计报出）：`chat/package.lisp` 头部
      仍称 `provider-chat-model` 有「内部工具执行循环」（与 2.0 单次调用设计
      矛盾）；`chat/tool.lisp` 仍指向已删除的 `process-tool-execution-error`。
- [x] **文档同步**：core README（中英）+ docs 六个文件（子代理完成），
      「必须 shadowing-import」的说法全部反转
- [x] **全量回归**：693 checks / 0 failures（冷编译）；MiniMax live 5/5

### cl-agent/core/protocols 并入 cl-agent/core ✅

> 该包统共只导出 2 个符号（`make-standard-id-generator` /
> `make-standard-timestamp-provider`），却占着 `protocols` 这个极宽泛的
> 昵称——还容易与 `protocols/` 子系统（A2A，另一回事）混淆。

- [x] 两个工厂并入 `core/utils.lisp`，从 `cl-agent/core` 导出
- [x] 删除 `core/protocols/` 目录 + asd 的 Protocol Layer 模块
- [x] **消掉一层间接**：该包排在 utils **之后**加载，逼得 utils 里的
      `init-default-id-generator` / `init-default-timestamp-provider`
      只能用 `find-package` + `find-symbol` 动态查找绕开加载顺序。
      合并后直接调用即可。
- [x] 三个昵称（`cl-agent/core/protocols` / `cla/core/protocols` /
      **`protocols`**）随包一并消失
- [x] DI 可替换性保留：`setf *default-id-generator*` 仍可注入自定义实现
      （已实测验证）
- [x] 全量回归：693 checks / 0 failures（冷编译，零告警）

### 顺带修掉的第 6 个真实 bug ✅

- [x] **模型幻觉工具名会崩掉整轮对话**（`chat-client/batch.lisp`）：
      `find-callback-for-call` 找不到工具时是 **signal**，而 batch 的三个
      调用点（`batch-has-serial-p` / `execute-batch-sequential` /
      `execute-batch-parallel`）都在构造 tool-request **之前**调用它——
      落在 `invoke-tool` → `tool-apply-terminal` 的 handler-case **之外**。
      于是模型只要报出一个不存在的工具名（LLM 幻觉工具名很常见），
      `TOOL-NOT-FOUND-ERROR` 一路冒泡出 `(chat ...)`，整轮对话直接中断。
      旧 ToolCallingManager 有 `process-tool-execution-error` 兜这一层，
      chat-client 路径漏了——删 manager 时改写安全测试才把它暴露出来。
      修法：新增 `resolve-callback` 捕获并转成 `:semantic` 错误 tool-result；
      新增 `tool-result->text` 把错误渲染成「错误：找不到工具 xxx」回传模型
      （此前错误结果的 value 是 nil，文本变成无信息量的「（执行失败）」，
      模型无从自纠）。安全边界不变：未暴露的工具依然绝不执行。
      2 个回归测试守住，验证过「回退即失败」。

---

## 已完成（2026-07-16 续四）

### 包合并：三模块分层 ✅

- [x] **http / chat / chat-client → cl-agent/core**（477 导出），对齐 clj-agent 的
      core / provider / client 三模块
- [x] **llm 保持独立**（provider 可插拔）；`chat` 与 core 的宏撞名 → llm `:shadow` 之
- [x] **合并前先清死代码**（否则正面撞名 15 处，SBCL 调用图坐实全是死的）：
      - `core/types.lisp` **整个文件**（319 行、34 符号）——唯一「调用」是内部
        自闭环（`make-message` 被 4 个构造器调用，那 4 个本身零调用），
        与 chat 的 CLOS 消息体系撞 11 个名
      - core 的 `build-url`（零调用）/ `with-retry`（零使用）——各自与 http 里
        **活着**的同名实现撞车，同 `alist-get` 的老套路
- [x] **stream-context 不导出**：core/http 的是传输层内部实现，llm 另有一个
      同名但语义不同的（客户端层累积器）。`:use` 只继承 external 符号——
      不导出即互不干扰

### cl-agent/client：SimpleAgent ✅

- [x] **有状态对话**：`make-agent` / `agent-chat` / `agent-chat-result` /
      `agent-history` / `agent-reset`。内部持 conversation-id + memory-filter，
      调用方不用再手写 `(:conversation "c1")`
- [x] **chat-client 级默认**：`:model :system :options :tools :memory :settings`
- [x] **callbacks**：`:on-turn-start/-end/-error`、`:on-tool-call/-result`、
      `:on-interrupt/:on-resume`。回调抛异常不掀翻整轮（观测手段非控制流）
- [x] **错误归一化**：`:completed` / `:paused` / `:cancelled` / `:error`，
      **不抛条件**（对标 clj-agent 的 `{:status :error}`）
- [x] **分层边界**：`make-agent` **不接受 `:filters`**，只暴露 `:callbacks`。
      要 filter 就自建 chat-client 传 `:chat-client`。比 clj-agent 更硬——它是
      warn+ignore，我们直接报错并给迁移指引（静默丢横切能力正是刚清掉的
      ChatClient 老坑）

### HITL：pause / resume ✅

> `:paused` 从此不再是死类型。

- [x] **chat-client 层**：`tool-gate` 槽（`(tool-call) → :proceed | :pause | (:pause . 原因)`）、
      `loop-state` / `pending-tool` 载体、`resume-turn`
- [x] **gate 在批执行之前评估，且每个 tool-call 恰好一次**——gate 常带副作用
      （审计/弹窗/计数），评估两遍就是重复触发
- [x] **核心不变量：暂停时工具一个都不执行**（单测 + live 都硬断言）
- [x] **resume 三种 decision**：
      - `:approved`（`payload (:args ...)` → 编辑后批准，用新参数执行）
      - `:rejected`（`payload (:message ...)` → 「已拒绝执行：理由」回模型，
        省它一轮干猜）
      - `:reply`（`payload (:message ...)` → 答复即工具结果，ask-user 语义）
- [x] **resume 同样过 :turn filter 链**：validation 之类要能作用于续跑结果。
      首次进 terminal = 暂停延续，filter 递归重入 = 常规循环，靠 consumed 一次性分派
- [x] **client 层**：`:on-tool-call` 返回 `(:interrupt . 原因)` 即启用 HITL——
      不是另一套机制，就是回调返回值（clj-agent 同款设计）。
      `agent-paused-p` / `agent-pending-tool` / `agent-resume`
- [x] live-test 加 3 项 HITL（暂停/批准/拒绝），MiniMax **8/8**

### 顺带修掉的第 7、8 个真实 bug ✅

- [x] **system 消息在历史里线性累积**（`filters/memory.lisp`）：memory-filter
      存了全部 prompt 消息**含 system**，而 chat-client-call 每轮都注入 system →
      2 轮 2 条、10 轮 10 条。实测 `history: 6 条`（应为 4），**多轮后再发
      工具调用直接失败**。修：system 不进历史（每轮由 prompt 提供），
      展开时置顶；window 只裁历史不碰 system（否则长对话里 system 先被裁掉，
      模型直接失忆人设）。

- [x] **工具循环把历史整份重复**（同上）：`run-tool-loop` 传的是**本轮累积的
      完整 messages**（非 delta），而 memory-filter 挂 :chat 链、每轮都过。
      第 2 轮把 user/assistant 又存一份 →
      `(user assistant user assistant tool ...)`，发给模型的序列**非法**
      （Anthropic 要求 user/assistant 交替、tool_result 紧跟 tool_use）——
      实测 MiniMax **400**。
      **与 HITL 无关，普通工具循环一样中招**；mock 不校验序列，只有真实
      provider 才暴露。
      修：memory-filter 存之前用 `eq` 判重（循环用 append 累积，同一条消息
      各轮是同一对象，eq 足够准）。
      修复后模型理解也变正确了——之前 `:approved` 后模型说「文件已在之前被
      删除，无需重复操作」（被重复消息搞糊涂），修复后是「已成功删除文件」。
      > 注：clj-agent 无此问题——它的 run-tool-loop 参数就叫 `delta`，历史
      > 完全交给 memory filter。我们的循环自己累积（好处：无 memory 也能跑），
      > 故改用 eq 幂等而非照搬。

---

## 待完成

> 排序原则：**先修「说了但没做」的**——它们比缺功能更有害：
> 用户照着注释/文档用，然后撞墙或静默受损。本轮已踩到过一串同类
> （documentation.lisp、alist-get、internal-tool-execution-enabled、
> qa-turn-filter、structured-output-validate-fn…），代价都一样。

---

### P0：文档全线过时 ✅（已修）

> 包合并 + 新增 cl-agent/client 后没同步文档，206 处引用已删除的包——
> 照 README 抄一行就撞 `Package CL-AGENT/CHAT-CLIENT does not exist`。
> **这是本轮改动造成的回归，已全部修复。**

- [x] **13 个文档全量更新**：README（我改写并逐段实跑）、README_EN、
      core README ×2、docs/API ×2、docs/QUICKSTART ×2、docs/tool-calling ×2、
      llm README ×2、mock README ×2。已删除包的引用只剩在迁移表的「旧」列。
- [x] **SimpleAgent 上文档**：README 与 QUICKSTART 都改为 SimpleAgent 打头
      （对标 clj-agent 的「方式一：推荐入门」），chat-client 降为「完全控制」。
      API 加 `cl-agent/client` 章。
- [x] **HITL 上文档**：pause/resume、tool-gate、三种 decision、
      「暂停时工具一个都不执行」的不变量。
- [x] **迁移表**：Advisor→Filter、ChatClient→ChatClient/SimpleAgent、包合并
      三张表；并写明 `cl-agent/client` 这个名字被**复用**了。
- [x] **过时的 shadowing 建议全部反转**：合并后 `(:use :cl-agent/core
      :cl-agent/client)` 无需任何 shadowing。
- [x] 所有片段实跑验证（README 一遍、docs 一遍）

顺带修掉：

- [x] **`agent-result` 类型没导出**（子代理审计发现）：只导出了访问器，
      用户无法 `(typep r 'cl-agent/client:agent-result)`。已补导出
      `agent-result` + `agent-result-p`。
- [x] **QUICKSTART 的 ASDF registry 漏了 `client/`**：照抄会导致
      `(asdf:load-system :cl-agent)` 失败（cl-agent.asd 依赖 cl-agent-client）。
- [x] **core/README 文件树列了已删的 `types.lisp`**、漏了
      `dependency-injection.lisp`。

### P1：注释在撒谎 —— 承诺了但代码没做

#### 1.1 `thread-pool-tool-calling-manager` 的限流是假的 ✅（已修）

> ToolCallingManager 的定位是 **chat-client 级绑定的 Tool Call 执行模型与
> 隔离机制**，三个实现 = 三种执行/隔离策略。thread-pool 的存在意义
> 就是**限流隔离**。

- [x] **pool-size 曾完全被忽略**：docstring 写着「用固定大小 lparallel
      chat-client 调度…适合需要限流的场景」，有 `pool-size` 槽 + 读取器，
      但 `execute-tool-calls` 直接委托 virtual-thread manager。
      用户配 `:pool-size 4` 以为限流到 4 并发，实际无限制——可能打爆
      下游。三种执行模型实际只有两种。
      修法：manager 持有自己的 lparallel kernel（懒建 + 双检锁），
      execute 时绑定 `lparallel:*kernel*`，于是 batch 的任务提交到这个池。
      新增 `shutdown-tool-calling-manager`（幂等）与
      `with-thread-pool-tool-calling-manager` 宏（非局部退出也回收）。

- [x] **顺带发现并修：`future + force` 根本限不住流**。
      lparallel 的 `force` 是 speculative 的——任务没被 worker 取走时
      **调用线程自己执行**（work-stealing，避免死锁）。实测并发上限是
      worker+1：pool-size=1 峰值 2、pool-size=3 峰值 4。对「就是要限流」
      的执行模型，超一个就是超。
      改用 channel（`submit-task` + `receive-result`，无 steal 语义）：
      实测 pool-size 1/2/3/4 → 峰值 **严格** 1/2/3/4。
      代价：`receive-result` 不保证顺序，故任务带索引回填——工具结果
      必须与 tool_calls 同序，否则回传给模型的 tool 消息 id 全错位
      （已加保序测试：故意让完成顺序反转，结果仍同序）。

- [x] 5 个回归测试（断言**并发峰值**而非「能跑通」），验证过「回退即失败」。

#### 1.1b 【新发现】多工具并行直接崩 —— 默认路径的致命 bug ✅（已修）

> 修 1.1 时写「6 个工具」的测试才炸出来的。**这是本轮最严重的一个。**

- [x] **模型一次发 2 个 tool_call 就 `NO-KERNEL-ERROR`**：
      lparallel 的 `submit-task`/`future` 都作用于 `lparallel:*kernel*`，
      而它**默认是 NIL**——lparallel 要求使用者自己 `make-kernel`。
      本库既不建也不在文档里提。于是：
      - 1 个 tool_call → OK（≤1 走顺序路径，不碰 lparallel）
      - **2 个 tool_call → 直接崩**（默认路径 + 默认 manager 都崩）
      而多工具并行是 LLM 的常见行为（Anthropic/OpenAI 都会一次返回多个）。
      **全部既有测试与 live 脚本都只用 1 个工具**，把它盖了个严实。
      修法：`ensure-tool-pool` 懒建进程级默认池（`*tool-pool-size*` 可配，
      缺省 4），优先尊重调用方已绑定的 `lparallel:*kernel*`；
      配套 `shutdown-tool-pool`。
- [x] 3 个回归测试，**强制用 ≥2 个工具**（否则等于没测），验证过回退即失败。

#### 1.2 `batch.lisp` 的故障路由策略矩阵名不副实 ✅（已修）

- [x] **那张表曾是纯谎言**：文件头注释白纸黑字写着 `:transient` + `:retry`
      → 指数退避 3 次。实际 `invoke-tool-batch` **从不读**
      `tool-callback-retry-p`、不退避、不重试——三类故障一视同仁转文本。
      `deftool` 认真记的 `(:retry t)` **零消费者**。
      修法：重试落在 `%run-one-tool`——它是并行与顺序两条路径的**共同
      执行点**（顺序路径原本直接调 invoke-tool，一并改掉：`:serial` 的
      工具往往正是那些打外部依赖、最需要重试的）。
      新增可配旋钮 `*transient-retry-attempts*`（缺省 3，含首次）与
      `*transient-retry-base-delay*`（缺省 0.1s，逐次翻倍）。
- [x] **重试是逐工具 opt-in**：只有声明 `(:retry t)` 的才重试。重试 =
      重复副作用，框架不替工具作者决定。
- [x] 实测四种组合全对：
      前2次失败第3次成功 → 跑 3 次拿到结果；一直失败 → 尝试 3 次后放弃；
      瞬态但没声明 :retry → 只跑 1 次；语义故障 + :retry → 只跑 1 次
      （参数错了重试一万次还是错）。退避实测 0.30s = 0.1+0.2。
- [x] 4 个回归测试，验证过「回退即失败」。
- [x] **注释与文档同步改真**（含 CN/EN 四份 docs）——它们之前反向撒谎
      （说「未实现」）。

> 仍存的偏差（已如实标注，非谎言）：`:environment` → 暂停等人未做。
> 它与已实现的审批类暂停切入点不同：审批切在批执行**之前**（一个工具都没跑，
> 快照天然一致），环境类切在**屏障处**（批已执行完，有的成功有的撞上挂掉的
> 依赖，续跑要只重跑失败的、保住成功的）——快照形状与今天的 `loop-state` 不同。

#### 1.3 `classify-tool-error` 基本被绕过 ✅（已修）

> 1.2 的前置：没有正确分类，按类路由无从谈起。

- [x] **根因比预想的深一层**：不只是 `tool-apply-terminal` 硬编码
      `:semantic`——`tool-callback-call` 会把工具体 signal 的**一切**包成
      `tool-execution-error`（原件塞进 `:cause`），而 `classify-tool-error`
      的规则里直接写着 `tool-execution-error → :semantic`。
      **所以只修 tool-apply-terminal 根本没用**，分类在更早就丢了。
      实测修复前：`transient-tool-failure` / `environment-tool-failure` /
      `connection timeout` 走完真实路径**全部** `:SEMANTIC`——
      三故障分类在实际链路上 100% 失效。
      修法两处：`classify-tool-error` 递归解包 `cause`；
      `tool-apply-terminal` 改用 `classify-tool-error`。
      顺带导出 `tool-execution-error-cause` / `-tool-name`（诊断包装错误时要用）。
- [x] 2 个回归测试；回退时连 1.2 的重试测试一起失败，印证了依赖关系。

### P2：半成品 ✅

- [x] **`tool-search-filter`**：三处都是废的，且互相掩护——
      `search_tools` 只存在于注释里；`:discovered-tools` 只读不写，
      filter 永远走 no-op；`subseq` 用**过滤前**的长度算上界，
      命中数 < min(limit, 工具总数) 就越界（几乎必崩）；
      注释承诺的中文二元组切分没写，中文查询恒 0 命中。
      因为从没被真正驱动过，三处谁都没暴露。
      重写：CJK bigram 分词、按 ranked 长度取上界、filter 内部自建
      `search_tools` 并与发现集合共享闭包（按 conversation-id 隔离）。
- [x] **`:chat` filter 改写的工具 ≠ 执行时认的工具**：修上一条时冒出来的——
      filter 注入的 `search_tools` 被模型调用后报「找不到工具」。
      `find-callback-for-call` 只认**请求 options** 里的工具（安全边界），
      而工具循环拿的是改写**前**那份。修法：`invoke-chat` 返回
      `(values response effective-prompt)`，工具执行按模型实际看到的那份来。
- [x] **真流式通路**：`invoke-chat-stream` + `compose-token-xforms` 落地，
      `chat-client-stream` 接真路径（此前是同步降级，整段一个 chunk）。
- [x] **两个 token-xform filter 是三重装饰品**：没有任何代码读
      `filter-token-xform` 去组装流；它们**返回裸 lambda 而不是 filter 实例**，
      压根放不进 `:filters`（名字叫 xxx-filter 却不是 filter）；协议照搬
      transducer 的 arity 重载。三条互相掩护：放不进 `:filters` → 从没被组装
      → 没人发现协议是拧的。统一为 `(downstream) → (values emit finish)`。
- [x] **流式带工具会静默丢掉工具执行**（我在本轮引入的）：真流式是单次调用，
      不跑工具循环，而此前的同步降级版本跑完整 turn。模型发了 tool_call 却
      无人执行，用户只看到一段没头没尾的文本——正是本轮一直在修的那类静默
      失效。改为**直接报错并指路** `chat-client-call`，与 `make-agent :filters`、
      `(chat ... (:advisors ...))` 的处理一致。
- [x] 文档纠正：4 处「流式尚未落地」的说明已过时；`:token-xform` 协议描述
      仍写着 transducer `(rf) → rf'`；`invoke-chat` 的第二返回值与
      `invoke-chat-stream` 未列入 Invoke 原语清单。
- [x] 测试基线 810 → 822；真实 MiniMax 验证：增量分片、脱敏、先审后放、
      与 memory-filter 共存（10/10）。

---

### P3：未做的设计 ✅

- [x] **`:writes` + `:state-slots` MapReduce 契约**（对标 clj-agent 的
      context/apply-writes 屏障折叠）。动工前 `writes` 槽是装饰品：
      有槽、有导出、有 docstring，全库**零生产者、零消费者**。顺带发现
      `make-tool-execution-result` 的协议文档写着「:context 应用 writes 后
      的 context」而三个 manager 全部原样透传，`turn-result-tool-context`
      槽也从无人赋值——同一类「注释承诺、代码没做」。
      实现（全对标 clj-agent）：
      - 工具经 `(values 结果 writes-plist)` 声明写意图；
        `tool-callback-call` → `tool-apply-terminal` 穿透装车
      - `apply-writes`（纯函数）：按 tool-call **原始序**折叠，并行交错
        不影响结果；`:reduce` 槽用 reducer（无老值用 `:init`），未声明
        last-writer；同批多写且无 reducer → 冲突告警
      - `fold-batch-writes`：屏障折叠入口，**失败调用的写意图不生效**
        （事务性）
      - 接线四处：`%tool-loop`（逐轮线程化 context + 刷新 options 的
        tool-context）、return-direct 收尾、`%resume-continuation`
        （HITL 续跑：真执行的提交、被拒/被答复的没有写）、三个
        ToolCallingManager 的 `:context`（把协议承诺做实）
      - `build-chat-client :state-slots` + `chat-client-state-slots`；
        `turn-result-tool-context` 交还折叠后的最终 context
- [x] 6 个回归测试（纯函数语义/端到端/失败作废/manager 路径/多值穿透），
      突变验证：去掉屏障折叠 → 2 项失败。测试基线 822 → 839
- [x] 真实 MiniMax 验证（live-test 11/11）：真模型一批发两个 tool_call，
      折叠序正确，turn-result 交还累积状态

---

### 大扫除（2026-07-16：删死代码 / 消冗余 / 命名合规）✅

**删除（全部经使用统计确认零消费者，且多数从未编译过）**：
- `protocols/` 全子系统（11 文件）+ `tests/test-protocols.lisp`（引用不存在的
  包 `cl-agent-tests`）+ `examples/protocols-usage.lisp`
- `examples/llm-usage.lisp`——`(use-package :cl-agent)` 引用不存在的包，加载即坏
- `tests/test-provider-name.lisp`——非 fiveam 的独立脚本，从未进 asd
- `mock/tools.lisp`——mock-tool 体系早于 deftool 架构（不是 tool-callback，
  进不了 :tools），唯一消费者是一个括号不平衡、从未编译的化石测试
- `llm/factory/builder.lisp`——provider-builder + 8 个 fluent 泛型，Java 式
  Builder（与已退役的 ChatClient Builder 同一模式），零真实消费者；
  create-chat-model 并入 registry.lisp
- `core/validation.lisp`——13 个 validate-*/ensure-* 宏全部零调用
- macros.lisp 杂物抽屉：20+ 工具宏只有 when-let（3 处）在用，其余全删
  （含引用不存在的 log:info 包的 with-timing、load 时 export 的 defconfig）
- conditions.lisp：9 个错误处理宏 + 4 个 signal-* 便捷封装 + ensure-api-key
- utils.lisp：take/drop/group-by/plist-get/make-tool（plist 时代工具规格）/
  truncate-string/clean-whitespace/string-empty-p/ensure-string/
  format-timestamp/generate-short-id/compose（展开本身是坏的）/pipe
- mock 包曾导出**没有定义**的 `*default-mock-responses*`

**修复/接回**：
- `tests/test-mock.lisp` 从未列进 asd → 一次都没跑过；按现行 API 重写并接回
- sequential manager 绕过 resolve-callback（幻觉工具名 signal 冲出整轮）也
  绕过 %run-one-tool（:retry 无效）——CLOS 收敛后统一走顺序批，加回归测试

**冗余收敛（CLOS + 助手函数）**：
- ToolCallingManager：`manager-run-batch` 泛型成为唯一差异点，
  `execute-tool-calls` 共享骨架（抽 calls→执行→组装→折叠 :writes→收集错误）
  只有一份；三份手写副本各自漂移的问题（virtual-thread 的 :errors 恒 nil）
  一并消失
- batch.lisp 新增 `tool-call->request` / `tool-results->responses` /
  `batch-error-summaries`，三处调用点共用
- chat.lisp 抽 `%assemble-messages` / `%merge-request-options`，
  chat-client-call 与 chat-client-stream 不再重复组装

**命名/Style 合规**：
- 全库 **shadow 清零**：cl-agent/llm 的 `chat` 函数改名 `client-chat`，
  唯一的 `(:shadow #:chat)` 随之删除；导出符号与 CL/SBCL 内置零冲突
  （脚本比对过 COMMON-LISP 包全部外部符号）
- 删泛昵称 `:core` / `:llm` / `:mock`（霸占全局包名，零使用），保留 `cla/*`
- 4 处 load 时 `(export ...)` 收口进 defpackage（conditions/validation/DI）
- 测试系统更名 `cl-agent-test` → `cl-agent/test`（ASDF 次级系统约定，
  每次加载的告警消失）
- 全量强制重编译**零警告**

> 测试 847 checks / 0 failures；live-test 11/11（真实 MiniMax）。

### 既有遗留 ✅（2026-07-16 大扫除中处理）

- [x] **A2A / MCP 子系统（`protocols/` 目录 + `cl-agent/protocols` 包）**：
      已整体删除（11 文件）。未完成且加载即报错——asd 列的
      `mcp.lisp` / `mcp-client.lisp` / `mcp-server.lisp` 根本不存在，
      不在主构建里，`tests/test-protocols.lisp` 还引用着不存在的包
      `cl-agent-tests`。一并删除：`examples/protocols-usage.lisp`。

---

### P4：Code Review 发现（2026-07-16，5-agent review）

> 5 个并行 review agent（Goal/QA/CodeQuality/Security/ContextMining）。
> ContextMining 因配额失败，其余 4 个完成。QA（847/0 离线 + 11/11 live）
> 与 Goal（P1-P3 全部达成）PASS，但 CodeQuality 发现 3 个 MAJOR。
> 全部修复于 commit **26ee239**（fix(chat-client)），含 4 个回归测试：
> - test-chat-client-invoke 返回 return-direct-via-manager-skeleton / -end-to-end
> - test-chat-client-invoke 返回 resume-honors-tool-manager
> - test-chat-client-invoke 返回 tool-search-instruction-injected-once
> 全套测试 **855/0 通过**（基线 847 → +8）。

#### 4.1 `:return-direct` 在 ToolCallingManager 路径上静默失效 ❌→✅

- [x] **manager 分支恒返回 `done=nil`**：`%execute-and-append` 的 manager
      分支无视 return-direct，`make-tool-execution-result` 也不携带它。
      后果：配了 `:tool-manager`（README 推荐路径）的用户，`:return-direct t`
      的工具结果被当成普通 tool 消息回传模型，而非直接返回调用方。
      修法：共享骨架 `execute-tool-calls` 计算 return-direct
      （`every resolve-callback → tool-callback-return-direct-p`），
      传入 `make-tool-execution-result`；`%execute-and-append` manager
      分支按它短路，与非 manager 分支同构。

#### 4.2 `resume-turn` 绕过已配置的 ToolCallingManager ❌→✅

- [x] **续跑批直接调 `invoke-tool-batch`**：`%resume-continuation` 第 473 行
      不检查 `(chat-client-tool-manager chat-client)`。后果：配了 thread-pool manager
      限流 **又**配了 tool-gate HITL——第一批被限流，**被暂停的那批**
      （往往是敏感工具）续跑时不限流。return-direct 在续跑上同样失效。
      修法：续跑的 callable 批经 `manager-run-batch` 走
      （thread-pool 绑池 = 限流生效），与非 manager 路径分支。

#### 4.3 tool-search sessions 哈希表无界增长 ❌→✅

- [x] **`(make-hash-table :test #'equal)` 按 conversation-id 累积，无淘汰**：
      长驻服务多会话 = 内存只增不减。每条目很小（工具名字符串列表），
      是慢泄漏而非瞬间爆，但永不回收。
      修法：加 LRU 上限（缺省 256），超出时淘汰最旧会话。

#### 4.4 非阻塞（修顺手）

- [x] `filter.lisp` 的 `token-xform` 槽 docstring 仍写旧 transducer 协议
      （应为 `(downstream) → (values emit finish)`）
- [x] tool-search 的 instruction 系统消息每轮追加 → 多轮循环里重复膨胀
      （只追加一次）
