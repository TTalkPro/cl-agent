# CL-Agent 示例

中文 | [English](README_EN.md)

本目录包含 CL-Agent 框架的各种使用示例。

---

## 目录结构

### `mock/` - Mock 示例

**用途**：使用 Mock 进行测试和开发

**特点**：
- 不需要 API 密钥
- 快速测试功能
- 确定性输出

**适用场景**：
- 单元测试
- 功能演示
- 开发调试

**运行方式**：
```lisp
;; 加载 Mock 示例
(load "src/cl-agent/examples/mock/mock-usage.lisp")

;; 运行所有 Mock 示例
(run-mock-examples)

;; 运行单个示例
(example-mock-quick-chat)
(example-mock-agent)
(example-mock-workflow)
```

**文件列表**：
- `mock-usage.lisp` - 基础 Mock 使用示例

---

### `real/` - 真实 API 示例

**用途**：展示如何使用真实的 LLM 提供商

**特点**：
- 连接真实 API（ZhipuAI、OpenAI 等）
- 实际生产环境使用

**前置要求**：
- 设置 `ZHIPU_API_KEY` 环境变量（智谱AI）
- 设置 `OPENAI_API_KEY` 环境变量（OpenAI）

**运行方式**：
```lisp
;; 加载真实 API 示例
(load "src/cl-agent/examples/real-usage.lisp")

;; 运行所有示例
(run-real-examples)

;; 运行单个示例
(example-zhipu-basic)
(example-openai-basic)
(example-agent-with-zhipu)
```

**文件列表**：
- `real-usage.lisp` - ZhipuAI、OpenAI、Agent、工作流示例

---

### `basic/` - 基础示例

**用途**：框架基础功能演示

**包含**：
- 基本概念介绍
- 简单使用场景
- API 入门

---

### `advanced/` - 高级示例

**用途**：展示高级功能和最佳实践

**包含**：
- 检查点和状态恢复
- 时间旅行调试
- 复杂工作流
- RAG 管道

---

## 运行建议

### 1. 首次使用

从 Mock 示例开始，无需 API 密钥即可快速了解框架：

```lisp
(load "src/cl-agent/examples/mock/mock-usage.lisp")
(run-mock-examples)
```

### 2. 真实 API 测试

设置环境变量后，运行真实 API 示例：

```bash
# 设置环境变量
export ZHIPU_API_KEY="your-zhipu-api-key"
export OPENAI_API_KEY="your-openai-api-key"

# 在 Lisp 中运行
(load "src/cl-agent/examples/real-usage.lisp")
(run-real-examples)
```

### 3. 开发和测试

使用 Mock 示例进行开发，确保逻辑正确后再切换到真实 API。

---

## 重要说明

### Mock vs 真实 API

| 特性 | Mock | 真实 API |
|------|------|----------|
| 需要 API 密钥 | ❌ | ✅ |
| 响应速度 | 快 | 依赖网络 |
| 输出质量 | 固定模式 | 智能生成 |
| 适用场景 | 测试/演示 | 生产环境 |

### 无 Fallback 策略

本框架**不会**因真实 API 失败而自动降级到 Mock：

- ✅ 明确区分测试环境和生产环境
- ✅ 避免意外的 API 调用
- ✅ 更清晰的错误诊断

**错误处理**：

```lisp
(handler-case
    (let ((client (make-llm-client :provider real-provider)))
      ;; 真实 API 调用
      ...)
  (missing-api-key-error (c)
    (format t "错误: 缺少 API 密钥~%")
    ;; 明确处理错误，不降级到 Mock
    ))
```

---

## 贡献指南

添加新示例时：

1. **选择合适的目录**：
   - Mock 测试 → `mock/`
   - 真实 API 调用 → `real/`
   - 基础教程 → `basic/`
   - 高级用法 → `advanced/`

2. **遵循命名规范**：
   - 文件名：`xxx-usage.lisp` 或 `xxx-example.lisp`
   - 函数名：`example-xxx` 或 `demo-xxx`

3. **添加注释**：
   - 文件头部说明用途
   - 函数文档字符串
   - 关键代码行注释

4. **更新本文档**：
   - 在对应章节添加新示例说明
   - 包含运行方式
