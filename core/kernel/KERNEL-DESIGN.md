# CL-Agent Kernel 设计方案

中文 | [English](KERNEL-DESIGN_EN.md)

## 设计原则

1. **直接工具注册** —— Kernel 直接持有 Tool Registry，无需中间 Plugin 层
2. **Tag 标签过滤** —— 工具通过标签分类，支持运行时过滤
3. **Builder 模式** —— 流式 API 构建 Kernel
4. **预设配置** —— 内置安全级别和功能预设

---

## 架构总览

```
┌──────────────────────────────────────────────────┐
│  用户代码                                         │
│  ┌──────────────────────────────────────────────┐ │
│  │ make-simple-tool                              │ │
│  │ (创建带标签的工具)                             │ │
│  └──────────────────┬───────────────────────────┘ │
│                     │                             │
│                     ▼                             │
│  ┌──────────────────────────────────────────────┐ │
│  │ Tool Registry                                 │ │
│  │ (管理工具 + Tag 过滤)                          │ │
│  └──────────────────┬───────────────────────────┘ │
├─────────────────────┼───────────────────────────────┤
│  Kernel 层                                         │
│                     ▼                             │
│  ┌──────────────────────────────────────────────┐ │
│  │ Kernel                                        │ │
│  │ - tool-registry (工具注册表)                   │ │
│  │ - active-tags (活跃标签过滤)                   │ │
│  │ - service (LLM 服务)                          │ │
│  │ - filters (过滤器链)                          │ │
│  └──────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────┘
```

---

## 核心组件

### Tool（工具）

```lisp
(defclass tool ()
  ((name :type keyword)
   (description :type string)
   (handler :type function)
   (parameters :type list)
   (category :type keyword)
   (tags :type list)        ; 标签列表
   (metadata :type list)))
```

### Tool Registry（工具注册表）

```lisp
;; 创建注册表
(make-tool-registry)

;; 注册工具
(register-tool registry tool)

;; Tag 过滤
(list-tools-by-tag registry :safe)
(list-tools-by-tags registry '(:file :read) :mode :any)
```

### Kernel

```lisp
(defclass kernel ()
  ((service)            ; LLM 服务
   (config)             ; 配置
   (tool-registry)      ; 工具注册表
   (active-tags)        ; 活跃标签（过滤用）
   (tag-filter-mode)    ; 过滤模式 :any 或 :all
   (filters)            ; 过滤器链
   (context)))          ; 执行上下文
```

---

## 工具创建

### 使用 make-simple-tool

```lisp
(defvar *weather-tool*
  (cl-agent.tools:make-simple-tool
    :get_weather
    "获取指定城市的天气信息"
    (lambda (&key city unit)
      (format nil "~A：晴，22°~A" city (or unit "C")))
    :parameters '((:city :type :string :description "城市名称" :required-p t)
                  (:unit :type :string :description "温度单位"))
    :category :utility
    :tags '(:utility :weather :safe)))
```

### 内置工具

```lisp
;; 文件工具
(cl-agent.tools:make-read-file-tool)   ; 标签: (:file :io :read :safe)
(cl-agent.tools:make-write-file-tool)  ; 标签: (:file :io :write)

;; HTTP 工具
(cl-agent.tools:make-http-get-tool)    ; 标签: (:http :network :read :safe)
(cl-agent.tools:make-http-post-tool)   ; 标签: (:http :network :write)

;; 实用工具
(cl-agent.tools:make-get-timestamp-tool)  ; 标签: (:utility :safe)
(cl-agent.tools:make-generate-uuid-tool)  ; 标签: (:utility :safe)
```

---

## Kernel Builder

### 基本用法

```lisp
(defvar *kernel*
  (cl-agent.kernel:build-kernel
    (cl-agent.kernel:with-tool
      (cl-agent.kernel:add-service
        (cl-agent.kernel:create-kernel-builder)
        *provider*)
      *weather-tool*)))
```

### 添加多个工具

```lisp
(defvar *kernel*
  (cl-agent.kernel:build-kernel
    (cl-agent.kernel:with-tools
      (cl-agent.kernel:add-service
        (cl-agent.kernel:create-kernel-builder)
        *provider*)
      (list *tool1* *tool2* *tool3*))))
```

### 使用预设

```lisp
(defvar *kernel*
  (cl-agent.kernel:build-kernel
    (cl-agent.kernel:with-preset
      (cl-agent.kernel:add-service
        (cl-agent.kernel:create-kernel-builder)
        *provider*)
      :safe                      ; 预设
      :security-level :standard))) ; 安全级别
```

### 设置 Tag 过滤

```lisp
(defvar *kernel*
  (cl-agent.kernel:build-kernel
    (cl-agent.kernel:with-active-tags
      (cl-agent.kernel:with-preset
        (cl-agent.kernel:add-service
          (cl-agent.kernel:create-kernel-builder)
          *provider*)
        :full)
      '(:safe :utility)    ; 只启用这些标签
      :mode :any)))        ; :any 或 :all
```

---

## Tag 过滤

### 在 Kernel 级别过滤

```lisp
;; 设置活跃标签
(kernel-set-active-tags kernel '(:safe :utility))

;; 清除标签过滤
(kernel-clear-active-tags kernel)

;; 获取过滤后的工具
(kernel-list-tools kernel)
(kernel-get-tools kernel)
```

### 在查询时过滤

```lisp
;; 指定标签查询
(kernel-list-tools kernel :tags '(:file))
(kernel-get-tools kernel :tags '(:safe :read))
```

---

## 3 层 Invoke API

### Tier 1: 工具执行

```lisp
(invoke kernel :tool-name args)
(invoke-tool kernel context :tool-name args)
```

### Tier 2: 单次 LLM 调用

```lisp
(invoke-chat kernel messages)
(invoke-chat-stream kernel messages :on-token #'handler)
```

### Tier 3: 完整工具循环

```lisp
(invoke-kernel kernel messages)
(invoke-chat-with-tools kernel messages)
```

---

## 预设配置

### 安全级别

| 级别 | 描述 |
|------|------|
| `:permissive` | 宽松模式 |
| `:standard` | 标准模式（推荐） |
| `:strict` | 严格模式 |

### 工具预设

| 预设 | 包含工具 |
|------|---------|
| `:standard` | 文件 + HTTP + 实用工具 |
| `:safe` | 只读操作 |
| `:full` | 全部（含 Shell） |
| `:file-only` | 仅文件 |
| `:http-only` | 仅 HTTP |
| `:utility-only` | 仅实用工具 |

---

## 使用示例

### 完整示例

```lisp
;; 1. 创建 Provider
(defvar *provider*
  (cl-agent.llm.providers:make-anthropic-provider
    :api-key (uiop:getenv "ANTHROPIC_API_KEY")
    :model "claude-3-5-sonnet-20241022"))

;; 2. 创建自定义工具
(defvar *calc-tool*
  (cl-agent.tools:make-simple-tool
    :calculate
    "计算数学表达式"
    (lambda (&key expression)
      (format nil "~A" (eval (read-from-string expression))))
    :parameters '((:expression :type :string
                   :description "数学表达式"
                   :required-p t))
    :tags '(:utility :math :safe)))

;; 3. 创建 Kernel
(defvar *kernel*
  (cl-agent.kernel:build-kernel
    (cl-agent.kernel:with-tool
      (cl-agent.kernel:with-preset
        (cl-agent.kernel:add-service
          (cl-agent.kernel:create-kernel-builder)
          *provider*)
        :utility-only
        :security-level :standard)
      *calc-tool*)))

;; 4. 创建 Agent
(defvar *agent*
  (cl-agent.simpleagent:make-kernel-agent *kernel*
    :system-prompt "你是一个有帮助的助手。"))

;; 5. 对话
(cl-agent.simpleagent:agent-chat *agent* "计算 15 * 7")
```

---

## 关键优势

| 特性 | 说明 |
|------|------|
| 直接工具注册 | 无需 Plugin 中间层，更简洁 |
| Tag 过滤 | 灵活的运行时工具过滤 |
| 预设配置 | 快速配置常用场景 |
| Builder 模式 | 流式 API，易于组合 |
| 安全级别 | 内置安全控制 |
