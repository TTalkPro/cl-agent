# 待完成任务

> 来源：2026-07-16 会话。advisor→kernel+filter 架构重构（P1-P5 + TCM）。
> 参照实现为 `~/workspace/clj-agent`（Clojure kernel+filter 架构）+ Spring AI 2.0。
>
> 测试基线：SBCL 2.6.6 **810 checks / 0 failures**（原基线 715 → +95）。
>
> 完整重构计划见 `.sisyphus/plans/kernel-filter-refactor.md`。

---

## 架构现状

```
cl-agent.kernel（新, 推荐）
  ├── Filter CLOS 类（四钩子: :tool/:chat/:turn/:token-xform）
  ├── build-chain（洋葱折叠, 闭包仅下游, 递归重入免费）
  ├── Kernel（model/tools/filters/settings/tool-manager, 无 memory）
  ├── invoke-chat/tool/turn + run-tool-loop（:turn terminal）
  ├── invoke-tool-batch（并行/:serial/故障路由）
  ├── ToolCallingManager 协议（Sequential/VirtualThread/ThreadPool 三实现）
  ├── 10 个内置 filter（memory/logging/safeguard/validation/
  │   re-reading/RAG/tool-search/timeout/approval/token-xform）
  └── ChatClient 桥接（make-kernel-client, kernel-backed 执行路径）

cl-agent.client（旧, legacy）
  └── Advisor 链（仍可用, kernel=nil 时走此路径）
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

## 待完成

### P5-续: Advisor API 完全退役

> 当前状态：advisor 与 kernel+filter 双路径共存。旧 advisor 测试全绿。
> 退役目标：删除 advisor 文件 + 从 asd 移除 + 删除/适配旧测试。

- [ ] **删除 advisor 文件**：`advisor.lisp`, `tool-advisor.lisp`,
      `tool-search-advisor.lisp`, `structured-output-advisor.lisp`
- [ ] **从 tool.lisp 移除 ToolCallingManager（旧）**：`default-tool-calling-manager`,
      `concurrent-tool-calling-manager`, `execute-tool-calls`（旧的）
- [ ] **chat-client.lisp 移除 advisor 路径**：`spec-advisor-chain`,
      `spec-effective-advisors`, legacy `call-client-response` 分支
- [ ] **删除/适配旧 advisor 测试**：`test-advisor.lisp`, `test-tool-advisor.lisp`,
      `test-tool-search.lisp`, `test-structured-output.lisp`, `test-parallel-tools.lisp`
- [ ] **更新 asd + package 导出**：移除 advisor 模块, 清理导出
- [ ] **全量回归**：确认 chat 宏行为等价

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

- [ ] **A2A / MCP 子系统**：整个子系统未完成且无法加载（3 个文件不存在,
      传输层是 stub）。不建议短期推进。
