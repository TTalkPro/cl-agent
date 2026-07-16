# 待完成任务

> 来源：2026-07-16 会话。advisor→kernel+filter 架构重构（P1-P5 + TCM）。
> 参照实现为 `~/workspace/clj-agent`（Clojure kernel+filter 架构）+ Spring AI 2.0。
>
> 测试基线：SBCL 2.6.6 **693 checks / 0 failures**
> （810 → 652：advisor 实现与测试一并删除；→ 699：补 filter 实际调用、
>  memory 桥接、chat 宏 DSL、kernel 默认 system/options 等回归测试；
>  → 693：旧 ToolCallingManager 测试随该层退役，安全边界测试改写保留）。
> 真实 provider 验证：`scripts/live-test.lisp` MiniMax **5/5**。
>
> 完整重构计划见 `.sisyphus/plans/kernel-filter-refactor.md`。

---

## 架构现状

```
cl-agent.kernel（唯一执行路径 + 调用方入口）
  ├── Filter CLOS 类（四钩子: :tool/:chat/:turn/:token-xform）
  ├── build-chain（洋葱折叠, 闭包仅下游, 递归重入免费）
  ├── Kernel（model/tools/filters/settings/tool-manager +
  │   默认 system/options, 无 memory）
  ├── 载体：tool-request/tool-result、turn-request/turn-result
  │   （chat 链无专门载体：请求=prompt，响应=chat-response）
  ├── invoke-chat/tool/turn + run-tool-loop（:turn terminal）
  ├── invoke-tool-batch（并行/:serial/故障路由）
  ├── ToolCallingManager 协议（Sequential/VirtualThread/ThreadPool 三实现）
  ├── 10 个内置 filter（memory/logging/safeguard/validation/
  │   re-reading/RAG/tool-search/timeout/approval/token-xform）
  └── chat 宏 DSL + kernel-chat* 函数入口（调用方唯一入口）

cl-agent.client —— 已整包删除（v9.0.0）
  Spring AI 的 ChatClient + Builder + fluent RequestSpec 移植层。
  迁移：make-kernel-client → build-kernel；(chat client ...) 原样可用，
  符号来自 cl-agent.kernel。
```

## 已完成（2026-07-16）

### P1: Filter 机制 + Kernel 骨架 ✅

- [x] filter CLOS 类（四钩子: :tool/:chat/:turn/:token-xform）
- [x] build-chain 洋葱折叠（reduce + reverse → 嵌套闭包）
- [x] defilter 宏（(self req chain) 三参数签名）
- [x] kernel CLOS 类（model/tools/filters/settings, 无 memory）
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

- [x] chat-client 加 :kernel 槽, call-client-response 双路径分派
- [x] make-kernel-client 工厂（kernel-backed ChatClient）
- [x] 对齐审计测试（10 filter 类型 + kernel-client + 故障分类）
- [x] 测试基线 781 → 810（+29）

### ToolCallingManager 协议 ✅

- [x] execute-tool-calls 泛型协议 + tool-execution-result plist
- [x] sequential-tool-calling-manager（全串行, 调试/严格副作用）
- [x] virtual-thread-tool-calling-manager（并行默认, 尊重 :serial）
- [x] thread-pool-tool-calling-manager（线程池, 可配 pool-size）
- [x] kernel 加 :tool-manager 槽, build-kernel 支持 :tool-manager
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
- [x] **README.md 重写**：架构图/对应表/快速开始全部改为 kernel+filter；
      原「快速开始」教的 `:advisors (list ...)` 现在是硬报错，
      「`(:call :entity schema)` 会自动校验并重试最多 3 次」也早已不成立
      （`call-entity` 只解析）——都已改正并实跑验证
- [x] **全量回归**：684 checks / 0 failures

### 顺带修掉的 5 个真实 bug ✅

> 共同根因：P4/P5 的 filter 测试只**构造** filter、检查钩子槽非空，
> 从不**驱动**钩子跑完整链路。钩子体内的错误、跨载体的 context 桥接
> 断裂一律照不到，810 checks 全绿也没用。已补 21 个实际驱动钩子/端到端
> 的测试（690 total），每个 bug 都验证过「改回旧代码即失败」。

- [x] **`qa-turn-filter` 从未能工作**（`kernel/filters/rag.lisp`）：
      `let` 该写 `let*`——`new-messages` 的初值引用同一个 `let` 里的
      `enhanced`，于是只要检索到任何文档就必然
      `UNBOUND-VARIABLE: ENHANCED`。编译期一直有
      `undefined variable: CL-AGENT.KERNEL::ENHANCED` 告警，无人理会。

- [x] **`structured-output-validate-fn` 判据完全反相**
      （`kernel/filters/validation.lisp`）：把
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

- [x] **`kernel:strip-json-fences` 对带围栏输入必报错**（同上）：
      `(string= body "```" :start2 ...)` 该用 `:start1`——start 索引
      属于被切片的那侧，写成 `:start2` 等于去 `"```"` 这个长度 3 的
      字面量里取第 34 位 → `bounding indices ... are bad`。
      而 LLM 最爱吐 ```json 围栏的 JSON。叠加上一条，合规输出会被
      判为「不是合法 JSON」并烧光全部重试。已修 + 支持裸 ``` 围栏。

- [x] **多轮记忆经 `(:conversation id)` 静默失效**
      （`kernel/invoke.lisp` + `filters/memory.lisp`）：`memory-filter`
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

> 注：`strip-json-fences` 在 `cl-agent.client` 与 `cl-agent.kernel`
> 各有一份实现（client 那份一直是对的，kernel 那份刚修）。两份都还在，
> 行为已对齐，但重复本身值得后续收口到 `cl-agent.core`。

### 文档全量对齐 kernel+filter ✅

- [x] **README.md / README_EN.md**：架构图/执行路径图/对应表/快速开始
      全部改写；每段 lisp 片段都实跑验证过
- [x] **core/README.md / core/README_EN.md**：包表加 `cl-agent.kernel`，
      文件树换成 kernel/ + client/carriers.lisp，删掉不存在的 advisor 文件；
      「内部工具执行」错误论断（工具循环住 ChatModel 内）已改正
- [x] **docs/API.md / API_CN.md**：删 Advisor 章，加 cl-agent.kernel 章
      （filter/build-kernel/invoke-*/run-tool-loop/三 manager/10 filter
      真实签名），ChatClient 章收敛到现存 API，补迁移表（子代理完成）
- [x] **docs/QUICKSTART / tool-calling（CN+EN）**：自定义 Advisor → filter，
      标题「Advisor 与 Manager」→「Filter 与 Manager」，工具循环归位到
      run-tool-loop，补三故障分类 + :serial 批语义（子代理完成）
- [x] **examples/README（CN+EN）**：example-5 描述改为 filter

---

### cl-agent.client 整包退役 ✅（2026-07-16 续二）

> 决策：Advisor 退役后，ChatClient 是 Spring AI 留下的第二个移植层
> （ChatClient + Builder + fluent RequestSpec）。Builder 与链式 spec 是
> Java 的表达习惯——在 Lisp 里 `build-kernel` 的关键字参数 + 声明式 `chat`
> 宏覆盖同样的场景，还少一个包、少一层间接。故整包删除，只把 `chat` 宏
> 搬进 kernel（它本就不是 Spring 写法，是 Lisp 化的 DSL）。

- [x] **`chat` 宏搬入 `cl-agent.kernel`**（新文件 `core/kernel/chat.lisp`）：
      宏 + 函数形态入口 `kernel-chat` / `kernel-chat-text` /
      `kernel-chat-entity` / `kernel-chat-stream`
- [x] **删除 `core/client/` 整个目录**（package / carriers / chat-client，594 行）
      —— 载体 `client-request` / `client-response` / `context-*` 是纯死代码
      （kernel 三链不用它们，:chat 链的请求就是 prompt、响应就是 chat-response）
- [x] **终结操作调整**：`(:call :client-response)` → `(:call :result)`
      （返回 turn-result，能看 status）；其余 `:content` / `:response` /
      `:entity` / `:stream` 语义不变
- [x] **请求级 `:tools`** 与 kernel 的 `:tools` 取并集（经 caller-options 的
      tool-callbacks，run-tool-loop 的 merge 天然并集）
- [x] **补回 kernel 级默认 system / options**（`build-kernel :system :options`）：
      这是**删 client 时我引入的功能回归**——旧 `make-chat-client` 有
      `:system` / `:options`（客户端级默认），第一版 `build-kernel` 没接，
      等于逼用户每次请求重写 system。文档子代理审计时发现并报了上来，
      核实属实（`build-kernel` 原签名只有 model/tools/filters/
      eligibility-fn/settings/tool-manager）。已加 `default-system` /
      `default-options` 两个槽 + 访问器，合并语义：
      system 请求级**覆盖**、options 请求级**优先**（未提及的默认项保留）、
      tools **取并集**。加 5 个测试守住（含「默认 options 与 :tools 共存，
      merge 不冲掉 tool-callbacks」）
- [x] **测试迁移**：`test-chat-client.lisp` → `test-kernel-chat.lisp`
      （14 → 13 个测试；Builder / fluent spec 的 6 个随该层退役，
      新增 `(:call :result)`、`:messages`、请求级工具并集、
      `(:conversation ...)` 可达 memory-filter 四项）
- [x] **删除孤儿测试**：`test-parallel-tools.lisp`（不在 asd，且引用已删符号）
- [x] **删除同义反复测试**：`kernel-loop-equivalent-to-advisor`（原本比较
      「旧 ChatClient+advisor」vs「kernel」，advisor 退役后 ChatClient 本就
      走 kernel，等于自己和自己比；client 删除后连对照组都不存在）
- [x] **examples 重写**：`chat-client-usage.lisp` → `kernel-usage.lisp`，
      8 个示例全部实跑通过
- [x] **文档全量改到 kernel API**：README / core README / examples README /
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

## 待完成

### 包设计撞名 + 旧 ToolCallingManager 退役 ✅（2026-07-16 续三）

> 两件是同一个根因，一起做掉。做完 `cl-agent.kernel` **不再需要任何
> `:shadow`**，下游可以直接 `(:use :cl-agent.chat :cl-agent.kernel)`
> 而不必自己写 shadowing-import（已编译验证）。

- [x] **kernel 载体改名**：`tool-response` → `tool-result`
      （accessors：`tool-response-result` → `tool-result-value`、
      `-writes` / `-error` 同理；构造 `make-tool-result :value`）。
      理由：与 turn 链的 `turn-request` → `turn-result` 对称，且撞名本就是
      巧合——chat 的 `tool-response` 是**协议消息层**的值对象（id/name/text，
      装进 role=:tool 的消息），kernel 的是**执行链层**的载体
      （value/writes/error），两者分属不同层。
- [x] **删除 `cl-agent.chat` 的旧 ToolCallingManager**（tool.lisp 766 → 502 行）：
      `tool-calling-manager` / `default-tool-calling-manager` /
      `execute-tool-calls` / `execute-one-tool-call` /
      `process-tool-execution-error` / `concurrent-tool-calling-manager` /
      `with-concurrent-tool-calling-manager` / `tool-execution-result` 等全删。
      工具执行唯一住在 kernel。
- [x] **保留并导出 `find-callback-for-call`**：它长在 manager 区块里但与
      manager 无关（只是「按名找工具」），且 kernel 的 batch / manager /
      tool-search filter 都依赖它。顺带从内部符号（`::` 访问）提为正式导出。
      它那段**安全边界注释**（不回退全局注册表 = 防提示注入越权）一并保留。
- [x] **移除 kernel 的 `:shadow`**：三个撞名（`tool-response` /
      `make-tool-response` / `execute-tool-calls`）已全部消除。
- [x] **测试改写而非删除**：`test-tool.lisp` 的 manager 测试随该层退役，
      但**两个安全边界测试（越权回归）改写成走完整 kernel 链路保留下来**——
      那是防提示注入的真实边界，不能因为 manager 没了就丢。另加
      `find-callback-for-call` 的解析/拒绝测试。
- [x] **清理过时源码注释**（文档子代理审计报出）：`chat/package.lisp` 头部
      仍称 `provider-chat-model` 有「内部工具执行循环」（与 2.0 单次调用设计
      矛盾）；`chat/tool.lisp` 仍指向已删除的 `process-tool-execution-error`。
- [x] **文档同步**：core README（中英）+ docs 六个文件（子代理完成），
      「必须 shadowing-import」的说法全部反转
- [x] **全量回归**：693 checks / 0 failures（冷编译）；MiniMax live 5/5

### cl-agent.core.protocols 并入 cl-agent.core ✅

> 该包统共只导出 2 个符号（`make-standard-id-generator` /
> `make-standard-timestamp-provider`），却占着 `protocols` 这个极宽泛的
> 昵称——还容易与 `protocols/` 子系统（A2A，另一回事）混淆。

- [x] 两个工厂并入 `core/utils.lisp`，从 `cl-agent.core` 导出
- [x] 删除 `core/protocols/` 目录 + asd 的 Protocol Layer 模块
- [x] **消掉一层间接**：该包排在 utils **之后**加载，逼得 utils 里的
      `init-default-id-generator` / `init-default-timestamp-provider`
      只能用 `find-package` + `find-symbol` 动态查找绕开加载顺序。
      合并后直接调用即可。
- [x] 三个昵称（`cl-agent.core.protocols` / `cla.core.protocols` /
      **`protocols`**）随包一并消失
- [x] DI 可替换性保留：`setf *default-id-generator*` 仍可注入自定义实现
      （已实测验证）
- [x] 全量回归：693 checks / 0 failures（冷编译，零告警）

### 顺带修掉的第 6 个真实 bug ✅

- [x] **模型幻觉工具名会崩掉整轮对话**（`kernel/batch.lisp`）：
      `find-callback-for-call` 找不到工具时是 **signal**，而 batch 的三个
      调用点（`batch-has-serial-p` / `execute-batch-sequential` /
      `execute-batch-parallel`）都在构造 tool-request **之前**调用它——
      落在 `invoke-tool` → `tool-apply-terminal` 的 handler-case **之外**。
      于是模型只要报出一个不存在的工具名（LLM 幻觉工具名很常见），
      `TOOL-NOT-FOUND-ERROR` 一路冒泡出 `(chat ...)`，整轮对话直接中断。
      旧 ToolCallingManager 有 `process-tool-execution-error` 兜这一层，
      kernel 路径漏了——删 manager 时改写安全测试才把它暴露出来。
      修法：新增 `resolve-callback` 捕获并转成 `:semantic` 错误 tool-result；
      新增 `tool-result->text` 把错误渲染成「错误：找不到工具 xxx」回传模型
      （此前错误结果的 value 是 nil，文本变成无信息量的「（执行失败）」，
      模型无从自纠）。安全边界不变：未暴露的工具依然绝不执行。
      2 个回归测试守住，验证过「回退即失败」。

### 待查：batch 故障路由名不副实（文档审计时发现，未改代码）

> `kernel/batch.lisp` 的文件头注释承诺一套策略矩阵，但实现没兑现。
> 已在 docs 里如实标为「已知偏差」，代码待修。

- [ ] **`:retry` / 退避从不触发**：注释说 `:transient` + `:retry` →
      指数退避 3 次、`:environment` → 暂停。`invoke-tool-batch` 从不读
      `tool-callback-retry-p`、不退避、不暂停——三类都被转成文本。
      `deftool` 记了 `(:retry t)` 但 kernel 批路径不消费。
- [ ] **`classify-tool-error` 基本被绕过**：`tool-apply-terminal` 捕获
      所有 `error` 硬编码 `:class :semantic`；`classify-tool-error` 只在
      `execute-batch-parallel` 的 future 包装里调用一次，故实际只分类
      「逃出 `:tool` filter 的错误」（如 `timeout-filter`）。工具体内
      signal 的 `transient-tool-failure` **不会**被归为 `:transient`。
      建议：让 `tool-apply-terminal` 走 `classify-tool-error`。

### 待查：其他已在文档标注的实现缺口

- [ ] **`tool-search-filter` 是半成品**：`search_tools` 内联工具没接线，
      只有 filter 侧的系统消息改写。
- [ ] **`thread-pool-tool-calling-manager` 不理 `pool-size`**：首版直接
      委托 virtual-thread manager。
- [ ] **`stream-content` 不是真流式**：降级为一次性同步 chunk；真 SSE
      只在 `chat-model-stream`。invoke-chat-stream 仍待实现（见下）。

### ToolCallingManager PR2: deftool :backend 扩展（HTTP/MCP）

> 状态：⏸️ 搁置（待真实需求触发）
> 设计文档已就绪：`~/workspace/clj-agent/docs/tool-calling-manager-design.md` §5-6

- [ ] deftool 扩展 `:backend` 元数据（`:local`/`:http`/`:mcp`）
- [ ] `invoke-backend` defmulti 分派
- [ ] HTTP transport 实现（client 模块）
- [ ] MCP backend 协议接口（IMcpClient）

### Kernel 集成深化

- [ ] **kernel-client 端到端集成测试**：用 mock provider 验证完整的
      `make-kernel-client` → `chat` 宏 → `invoke-turn` → `turn-result` 链路
      （含工具循环 + memory-filter + safeguard）
- [ ] **:writes + :state-slots MapReduce 契约**（对标 clj-agent 的
      context/apply-writes 屏障折叠）
- [ ] **HITL（暂停/resume）**：对标 clj-agent 的 gate/pause/resume 机制
- [ ] **Streaming 通路**：invoke-chat-stream + :token-xform 组装

### 既有遗留（非本轮引入）

- [ ] **A2A / MCP 子系统（`protocols/` 目录 + `cl-agent.protocols` 包）**：
      未完成且**加载即报错**——asd 列了 `mcp.lisp` / `mcp-client.lisp` /
      `mcp-server.lisp` 三个文件，但目录里根本不存在，
      `(asdf:load-system :cl-agent-protocols)` 直接
      `Failed to find the TRUENAME of .../protocols/mcp.lisp`。
      它不在主构建里，故平时不影响。不建议短期推进。
      注：与已并入 core 的 `cl-agent.core.protocols` 毫无关系——
      后者只是 ID/时间戳工厂，同名纯属巧合（也正是它该改名的理由之一）。
