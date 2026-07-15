# 待完成任务

> 来源：2026-07-15 会话。三条主线——Spring AI 2.0 Advisor 对齐 → CCL 可移植性 →
> 工具身份重构。所有关键结论均经实测复现（离线断言 / MiniMax 实景 API / 双实现对照），
> 参照实现为 `spring-ai` v2.0.0 源码与 `~/workspace/clj-agent`。
>
> 测试基线：SBCL 2.6.6 与 CCL 1.13 各 **`715 checks / 715 pass / 0 skip / 0 fail`**；
> MiniMax 实景 `25/25`。（本轮 671 → 715，且 skip 归零。）

## P0 — 真实功能缺口 / 误导性状态 ✅ 全部完成（2026-07-15）

> 测试：671 → 704 checks，2 skip → 0。

- [x] **`make-provider` / `make-client` 覆盖不全**：症状是 minimax / deepseek /
      gemini / mistral / dashscope 无法从环境变量取 key。实测追下去发现是**三个**
      彼此独立的手写清单在漂移：
      1. `llm/client.lisp` 的 `get-api-key-for-provider` 用手写 ECASE 重推导密钥，
         只列 anthropic/openai/zhipu——**而 provider 构造时早已读过自家环境变量**，
         这层推导整个是多余的。改为 `(or provided-key (provider-api-key provider))`。
      2. `cl-agent.core:provider-api-key` 是**零实现的泛函**：openai-compat 系用
         `:accessor provider-api-key` 恰好实现了它，**Anthropic 系（含 minimax）
         缺席** → `NO-APPLICABLE-METHOD`。给 anthropic 的 api-key 槽补上该 reader。
      3. `llm/providers.lisp` 的 `make-provider` 又是一张手写 ECASE，只列 6 个，
         **deepseek / gemini / mistral 直接 ECASE 落空**——尽管
         `factory/registry.lisp` 里 9 个 provider 一直都注册着。改为委托
         `create-provider`，注册表成为单一事实来源。
      结果：`make-client` 对 **9/9 provider** 全部可用（此前仅 3 个）。
      回归测试 `make-provider-covers-every-registered-provider`（遍历
      `list-providers`，新增 provider 自动纳入）/ `every-provider-implements-provider-api-key`。

- [x] **别名机制只在一条路径生效**：`register-provider-alias` 注册了 7 个别名
      （claude/gpt/glm/chatglm/google/qwen/bailian），`builder.lisp` 会调
      `resolve-provider-name` 解析，但 **`create-provider` 不解析**——
      `(make-provider "claude")` 报 Unknown provider。同一机制两条路径行为不一致。
      `create-provider` 补上解析（对非别名恒等）。
      回归测试 `make-provider-accepts-aliases`。

- [x] **两个假跳过的测试**：`tests/test-core.lisp` 的 `json-parse` / `json-stringify`
      测试体只有 `(skip "JSON 解析测试需要额外配置")`。**该理由是假的**——实测零配置
      可用。它们是从没写过的占位测试，基线里那 2 个 skip 就是它们。
      假测试比没测试更坏：它让人以为有覆盖。已写实，覆盖 jzon 值表示的三个易混标量
      （`true`→`T`、`false`→`NIL`、`null`→符号 `NULL`）与往返一致性。
      往返测试**刻意不断言键序**——jzon 的 hash-table 遍历顺序随实现而变
      （实测 SBCL 与 CCL 不同），依赖键序的断言不可移植。

## P1 — 未结论 / 工程债 ✅ 全部完成（2026-07-15）

- [x] **MiniMax 流式工具循环偶发空正文 —— 结案：与本项目代码无关，是服务端行为**
      （2026-07-15）。
      **交错 A/B 实验**（关键方法学修正：此前两组各自连续跑，而 MiniMax 跨时间窗
      波动极大——见过 3/3 全空与 4/4 全好——组间差异会被时间因素污染；本次
      A/B/A/B 交错以控制时间变量）：

      | 组 | 条件 | 空正文 |
      |---|---|---|
      | A | 回传 thinking 块（当前实现） | **0/14** |
      | B | 不回传（`no-passback-advisor` 精确复现修复前行为） | **0/15** |

      对照组有效性已单独验证：A 组第 2 轮请求体**含** thinking，B 组**不含**。
      结论：**「thinking 回传修复消除了空响应」的假设被证伪**——复现旧行为的 B 组
      同样 0%。此前观察到的 ~20% 与随后的 0/24 都是服务端在不同时间窗的表现，
      与本项目代码无关。
      （若当初只重跑当前实现拿到 0/14 就会「确认」假设——B 组正是为此存在。）

      本条累计确证的三个否定结论：**不是 max-tokens**（空响应
      `stop_reason=end_turn`、`output_tokens=27`，上限 4096；对照组 `max_tokens=40`
      才会 `stop_reason=max_tokens`）、**不是 temperature**（0.7 vs 1.0：20% vs 23%，
      N=25）、**不是 thinking 回传**（本次）。
      已知机制：空响应时模型把 `<minimax:tool_call>` XML 泄漏进 thinking 通道而未
      转成 `tool_use` block（原始 SSE 直接观察到），属 MiniMax 兼容层缺陷。
      **应用层若依赖流式工具循环，需自行兜底重试。**

- [x] **删除 `llm/schema/response.lisp` 与整个 `schema/` 模块**（2026-07-15）：
      58 行里只有 1 行代码（`in-package`），自称 "exists for documentation purposes"。
      注释**双向漂移**——列了并不存在的 `llm-response-to-plist`（全库无此函数），
      又漏了真有的 `llm-response-reasoning` / `reasoning-blocks`。净价值为负：
      它承诺的 API 有的不存在，存在的没列。`schema/` 至此清空（`openai.lisp` /
      `anthropic.lisp` 此前已删）。统一响应 schema 以 `core/llm/response.lisp`
      的 docstring 为准；provider 侧 wire 转换写在 `providers/` 下。

- [x] **CI 扩到 macOS**（2026-07-15）：矩阵改为
      `ubuntu-latest × {sbcl, ccl}` + `macos-latest × {sbcl}`，fasl 缓存按
      **实现 × 平台** 分开。
      **CCL 无法加入 macOS**：v1.13 发布包只有 `linuxx86` 与 `darwinx86`
      （`darwinaarch64` 404），而 `macos-latest` 已是 Apple Silicon；
      `macos-13` Intel runner 正被 GitHub 淘汰，不值得绑定。
      已给「安装 CCL」加 `runner.os == 'Linux'` 守卫——将来若往矩阵加 macOS+CCL，
      会当场失败而不是悄悄装错包。
      跨平台风险已核查：无 `run-program` / shell 依赖；`/tmp/...` 仅出现在 mock
      数据的字符串里，非真实文件操作；测试不触网（集成测试由
      `RUN_INTEGRATION_TESTS` 门控）。
      > 注意：**workflow 本身未经真实运行验证**——GitHub Actions 无法本地执行。
      > 已做的是 YAML 解析校验、CCL/SBCL 安装源可达性验证（curl 实测 200）、
      > 以及退出码语义实测。首次 push 后需盯一次实际运行。

## P2 — 既有 TODO（非本轮引入）

- [x] **`batch-chat` 的 `:parallel` 被静默忽略**（2026-07-15）：实现是
      `(declare (ignore parallel))`——调用方传 `:parallel t` 拿到的仍是串行，
      而 `examples/llm-usage.lisp:131` 正是这么调的。docstring 虽注明「目前不支持」，
      但静默接受一个不起作用的参数仍是错的：要么实现，要么报错。
      已用 lparallel 实现（该依赖早已在用于并行工具执行）：`pmapcar` 保序、
      线程池按需创建并在 `unwind-protect` 中释放、单提示退化为串行。
      **实测（MiniMax 真实批量，4 个提示）：串行 1 线程 12.4s → 并行 4 线程 4.3s**，
      结果顺序一致。回归测试见 `tests/test-core.lisp`（DI）与实景脚本。

- [x] **DI `:request` 作用域未实现**（2026-07-15）：此前 `:request` 分支落到与
      `:prototype` 相同的实现（每次 resolve 新建实例）——**声明的语义是「请求内
      共享」，实际行为相反，且毫无提示**（实测确认：两次 resolve 返回不同实例）。
      又一个「声明了但没实现」的陷阱。
      已实现：`with-di-request-scope` 宏 + 动态绑定的 `*di-request-cache*`。
      **不在作用域内时发 `di-request-scope-not-active-error` 而非静默退化**
      （对标 Spring 的 ScopeNotActiveException）。缓存是动态绑定 ⇒ 天然线程隔离。
      五条语义均实测：请求内共享 / 跨请求隔离 / 作用域外报错 / 4 线程各自独立 /
      singleton 与 prototype 不受影响。回归测试 4 个。
      顺带修正 asd 里的假注释——原写「DI container（独立设施，**protocols 系统使用**）」，
      实测 protocols 根本不用它；DI 的 798 行仅被 `examples/di-usage-examples.lisp` 使用。

- [ ] **A2A / MCP 子系统：不是「两个 TODO」，是整个子系统未完成且无法加载**。
      重新核查后的实情（原条目严重低估）：
      - **`cl-agent-protocols` 系统加载即失败**：asd 声明 12 个组件，其中
        `mcp` / `mcp-client` / `mcp-server` **三个文件根本不存在**
        （`Failed to find the TRUENAME of protocols/mcp.lisp`）。
      - **不在主构建**：`cl-agent` 只依赖 `cl-agent-core` + `cl-agent-llm`。
      - **不在测试套件**：`tests/test-protocols.lisp`（411 行）从未被运行。
      - **传输层是谎报成功的 stub**：`a2a-send` 不发送任何东西、直接返回 `t`
        （`a2a-messaging.lisp:38`），而 `a2a-handlers.lisp` / `a2a.lisp` 都在调它。
        `a2a-send-request` 的「等待响应」同样未实现（:68）。
      **不建议在此处「收 TODO」**：真正实现需要网络传输层 + 补齐三个 MCP 文件，
      那是独立项目而非清理工作。可选处置：
      (a) 作为独立分支/项目推进；
      (b) 若短期不做，把 `protocols/` 移出仓库或明确标注为 WIP 存档——
          当前状态（声明了却加载不了、测试从不运行）比不存在更容易误导人。

---

## 已完成（2026-07-15）

### 安全

- [x] **工具越权（confused deputy）**：`find-callback-for-call` 曾在 options 找不到
      工具时**回退全局注册表**，而 `deftool` 自动全局注册——于是模型报出任何
      deftool 过的工具名即可令其执行，哪怕从未暴露给它，提示注入下可直接利用。
      实测复现：client 只暴露 `leak_weather`，模型请求 `leak_delete_account`
      → **被执行，参数 user="alice"**。
      修复：执行只认本次请求 `options` 暴露的工具，找不到发 `tool-not-found-error`
      （由 `process-tool-execution-error` 转文本回传模型，对话不中断）。
      参照实现均无此回退：clj-agent `find-function` 只查 kernel `:tool-vars` 并抛；
      Spring `ToolCallbackResolver` 是 manager 实例字段、默认为空。
      回归测试 `unexposed-tool-is-never-executed` + `exposed-tool-still-executes`
      （已自检：恢复回退 → 测试立即失败）。

### 工具身份（对齐 clj-agent）

- [x] **`deftool` 无全局副作用**：只生成 `defun` + 符号属性，不再 `register-tool-callback`。
      工具的身份就是它的符号。对应 clj-agent 的 `defn` + var 元数据——Clojure 的 var
      带元数据，CL 里对应载体是符号属性列表；`#'get-weather` 是裸函数对象、取不到
      schema，**不能**用作工具引用。全局表污染 **15 → 0**（此前光加载测试套件就注入 15 个）。
- [x] **注册表降级为 opt-in**：默认空，仅服务「按*字符串*名解析」（配置驱动场景），
      需显式 `(register-tool-callback (symbol-tool-callback 'foo))`。
      回归测试 `deftool-has-no-global-side-effect` / `register-tool-callback-is-opt-in`。
- [x] **补 `symbol-tool-callback`**：符号属性名是 `cl-agent.chat` 内部符号，
      此前调用方只能写 `(get 'foo 'cl-agent.chat::tool-callback)`。
- [x] **并行测试一直在验证越权路径**：它们传的是不带 options 的 `(make-prompt "go")`，
      能跑通完全依赖全局回退。改为显式暴露工具（`pt-prompt` 辅助函数），与真实用法一致。

### CCL 可移植性

- [x] **`get-env` 在 CCL 上直接崩**：`core/utils.lisp` docstring 用了**未转义的双引号**，
      函数体混入裸符号 `OPENAI_API_KEY` / `PORT`。SBCL 静默优化掉未绑定变量引用
      （只留 style-warning，测试全绿），**CCL 运行时 UNBOUND-VARIABLE**——而这是读
      所有 API key 的函数。写了带转义处理的扫描器全库复查，并做自检
      （回退修复 → 抓到 1 处；恢复 → 0 处），确认全库仅此一例。
- [x] **`make-keyword` 未定义**：`core/dependency-injection.lisp` 的 `di-bind` /
      `di-boundp` / `di-release` / `di-resolve` 名称归一化分支调用
      `cl-agent.core::make-keyword`，而该包只 `(:use :cl)`。实测
      `(di-bind c 'sym ...)` → `UNDEFINED-FUNCTION`（传关键字碰巧走另一分支，
      所以测试从未碰到）。改用 `alexandria:make-keyword`。
- [x] **`run-tests.lisp` 成功时不退出**：失败时 `(uiop:quit 1)`、成功时直接跑完。
      SBCL 的 `--non-interactive` 隐含跑完即退所以没暴露；CCL 的 `--batch` 跑完会读
      stdin，**挂到超时**（实测 exit 124）。会做出「失败时正常报错、成功时挂死」的
      假 CI。修在源头（成功也显式 `(uiop:quit 0)`），而非让每个调用方加
      `</dev/null`。四个格子实测：SBCL 0/1、CCL 0/1。
- [x] **CI**：`.github/workflows/tests.yml`，SBCL + CCL 矩阵、`fail-fast: false`、
      按实现分开缓存 fasl（两者不兼容）、依赖从 `.asd` 派生而非手写清单。
- [x] **`rank-tools` 用不稳定 `sort`**：按分数降序而同分极常见，`subseq max-results`
      决定披露哪些工具。标准不保证 `sort` 稳定（SBCL 对向量即用非稳定算法）。
      实测两实现目前一致（列表均用归并排序、恰好稳定）——是运气不是契约。
      改 `stable-sort`，与 `make-advisor-chain` 一致。

> **不加 `#+sbcl` / `#+ccl`**：代码库零条件编译而双实现全过。可移植性来自使用
> 可移植抽象（`bordeaux-threads` / `uiop` / `lparallel`），不是来自条件编译。
> 上述三个 CCL 问题没有一个是实现差异——两个是纯 bug（SBCL 恰好宽容），
> 一个是 CLI 差异且已用可移植方式收口。加条件编译只会引入投机复杂度，
> 并把 bug 伪装成「实现差异」。真需要 `sb-ext:` 特有能力时再加。

### Spring AI 2.0 Advisor 对齐

- [x] **`structured-output-validation-advisor`**（含从零实现的 JSON Schema 校验器）：
      校验响应 JSON，失败则把错误追加到 user 消息重试。位于工具循环内侧，
      带 tool-calls 的响应放行；每次从**原始**请求增强而非累积；重试用尽返回
      最后响应而非发条件；流式明确报错。`call-entity` / `(:call :entity schema)` 可自动挂载。
      校验器踩到 jzon 表示的两个坑（`false` 与「键缺失」在 `gethash` 下都是 `NIL`；
      CL 中字符串也是 vector），均有测试锁住。
- [x] **`tool-calling-advisor` 补齐三处**：`conversation-history-enabled` 开关、
      `tool-advisor-next-instructions` 钩子（对标 `doGetNextInstructionsForToolCall`）、
      可插拔 `eligibility`（对标 `ToolExecutionEligibilityChecker`）。
      并记录：`conversation-history-enabled nil` 时记忆 Advisor **必须在工具循环内侧**
      （order > `+tool-calling-advisor-order+`），否则下一轮退化成
      `[system, 工具结果]` 被 Anthropic 以裸 400 拒绝——已加运行时告警 +
      `memory-advisor-p` 标记（对标 `MemoryAdvisor`）+ 正反回归测试。
- [x] **`tool-search-tool-calling-advisor`**：会话级索引（指纹判定 + LRU 淘汰）+
      `system-message-suffix`（无此说明模型不知道还能检索工具）。
- [x] **`message-chat-memory-advisor`** 对齐 Spring 语义：记忆前插 + 幂等检查 +
      system 置顶 + 只存最后一条 user/tool 消息。
- [x] **移除 `prompt-chat-memory-advisor`**：Spring AI 2.0 唯一被移除的 Advisor。
- [x] **排序改具名常量**，并在 `advisor.lisp` 记录与 Spring 默认布局的差异及理由
      （本实现把护栏放在记忆外侧，优先保证敏感输入不进记忆；Spring 放在工具循环内侧）。

### Anthropic 扩展思考

- [x] **thinking signature 丢失**：`extract-thinking-content` 只取思考文本、丢弃
      signature；**流式路径连 `signature_delta` 分支都没有**（只有注释提到它）。
      而 Anthropic 官方文档明写：工具调用对话的 assistant 轮**必须**原样回传
      thinking 块，400 的最常见成因正是「filters content blocks by type... or
      rebuilds the assistant message instead of echoing it」。
      新增 `llm-response-reasoning-blocks` 槽承载 provider 原生块（含 signature），
      打通 provider → assistant metadata → `message->neutral` → 请求体全链路。
      `redacted_thinking` 一并保留。
- [x] **`thinking` 一等参数**（对标 `ThinkingConfigParam`）：`:disabled` / `:adaptive` /
      `(:enabled :budget-tokens N)` / `:display`，官方约束（`budget_tokens` ≥1024 且
      < `max_tokens`）在构建期校验并发 `invalid-thinking-config-error`，
      而不是发出去换一个裸 400。五个变体经真实 API 验证。
- [x] **temperature 违反 SPI 契约**：SPI 文档明写「NIL 表示不下发该字段，避免误触发
      厂商默认值或 400」，但 `anthropic` / `dashscope` / `openai-compat` /
      `stream/openai` 四处硬编码 `(temperature 0.7)`，`make-client` 亦默认 0.7
      （取值链 `(or 调用点 (client-temperature client))` 令其永远非 NIL）。
      按官方文档这会直接坏在两处：Claude Opus 4.7+（含 4.8）**不支持**
      temperature/top_p/top_k，设非默认值返回 400，文档要求「omit them from
      request payloads」；且 Claude 4.1 Opus / 4.5 Sonnet 起 temperature 与 top_p
      不能同时指定。全部改为「存在才发送」。

> **发现 Spring AI 2.0 有同样的 thinking 回传缺陷**：其 anthropic 模块
> `ThinkingBlock`（读）出现 7 次、`RedactedThinkingBlock`（读）4 次，但写方向的
> `ThinkingBlockParam` / `RedactedThinkingBlockParam` **出现 0 次**——
> `createRequest()` 在 assistant 带工具调用时只构造 `toolUseBlocks`（连 text 块也丢）。
> 读得进来、发不回去。非本项目问题，仅记录。

### 死代码清理

- [x] **`llm/schema/anthropic.lisp`**（197 行）与 **`llm/schema/openai.lisp`**（166 行）：
      整体删除。它们是 `providers/` 下活实现的**重名死副本**，与活代码**只差一个介词**
      （`convert-messages-**to**-openai` vs `convert-messages-**for**-openai`；
      `convert-messages-**to**-anthropic` vs `parse-messages-**for**-anthropic`）。
      我的 thinking 修复第一版就打在了死的那份上——单元测试全绿而线上纹丝不动，
      是靠在同一次真实调用里同时打印 CLOS 层、中立层、实际请求体才抓出来的。
- [x] **`llm/factory/config.lisp`**（171 行）：自封闭死岛，6 个函数无一被
      registry/builder/providers 调用，表里的 temperature/model 默认值流不进任何请求。
- [x] **`core/documentation.lisp`**（337 行）：11 个宏/函数全部零使用、无文档生成器消费，
      且其中两个从提交起就没工作过——`defsection` 缺 `&body body` 却在展开体用 `,@body`
      （`macroexpand` 即报 unbound BODY）；`defstruct-documented` 的字符串形态漏了守卫。
      无人调用 → 无人执行 → 无人发现。
- [x] **13 个真死符号**：`build-headers`、`build-provider-url`、4 个 `*-api-url*`、
      4 个 `*default-*-model*`（且已过时——写着 `claude-3-5-sonnet-20241022`，
      而 provider 实际默认 `claude-sonnet-4-20250514`）、`stream-has-more-p` 等。
      **保留 `response-reasoning-content`**：虽零内部调用，但它是 README 承诺的公开 API
      （与 builder DSL 同类——公开 API 本就该由用户调用）。

### 包 / API 一致性

- [x] **门面层重名导出**：`cl-agent.llm` 与 `cl-agent.llm.providers` 各自导出 6 个
      **独立同名符号**（`eq` 验证），后果有三：用户包 `(:use ...)` 两者即撞 6 个
      name conflict（而这两个包本是「门面 + 实现」）；
      **`cl-agent.llm:make-dashscope-provider` 导出了却没有定义**（`fboundp=NIL`，
      调用即 UNDEFINED-FUNCTION——门面层手写委托时漏了它）；
      `response-complete-p` 两处实现语义分叉（主包那份不接受旧式 plist）。
      改为 `:import-from` 重导出**同一符号**（需将 providers 包定义前置），
      三个问题一次消失，且新增 provider 无需再手工同步。
      回归测试 `facade-reexports-same-symbols` / `facade-exports-are-all-fbound` /
      `response-complete-p-accepts-legacy-plist`。
- [x] **`llm-response-reasoning` 从未从 `cl-agent.llm` 导出**（core 导出了、chat 导入了，
      唯独 llm 的再导出列表漏了）；`reasoning-blocks` 我新增时漏了同一处。
- [x] **README finish-reason 表是错的**：写 `:length`，而那是**提供商侧原始值**，
      归一后是 `:max-tokens`，照着写取不到。已改为完整四值表 + 原始值对照。
- [x] **`llm/README` 的两个函数从「智谱特有」挪出**：`response-reasoning-content` /
      `response-complete-p` 均为通用（覆盖 GLM/DeepSeek/Anthropic，认归一后的 finish-reason）。
- [x] 新增 `llm-readme-accessors-are-exported` / `llm-readme-finish-reason-table`
      两个测试把 README 的承诺钉进套件——**文档承诺的 API 没人验证就会静静烂掉**，
      `llm-response-reasoning` 没导出、`make-dashscope-provider` 没定义都是这么来的，
      而当时 616 个测试一个都没抓到。
