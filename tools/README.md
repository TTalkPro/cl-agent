# Tools 模块

中文 | [English](README_EN.md)

工具系统：Tool Registry + Tag 标签过滤 + 预设配置。

## 目录结构

```
tools/
├── package.lisp              # 包定义
├── protocol.lisp             # 工具类和协议
├── registry.lisp             # 工具注册表（支持 Tag 过滤）
├── core.lisp                 # 核心工具函数
├── builtin.lisp              # 带标签的内置工具
├── presets.lisp              # 工具预设配置
├── tool-factories.lisp       # 工具工厂
└── providers/                # Provider 实现
    ├── builtin.lisp
    └── custom.lisp
```

## 核心概念

### Tool（工具）

每个工具包含以下属性：

- `name` - 工具名称（关键字）
- `description` - 工具描述
- `handler` - 执行函数
- `parameters` - 参数定义
- `category` - 分类
- `tags` - 标签列表（用于过滤）
- `metadata` - 元数据

### 创建工具

```lisp
;; 使用 make-simple-tool
(defvar *my-tool*
  (cl-agent.tools:make-simple-tool
    :greet
    "问候用户"
    (lambda (&key name)
      (format nil "你好，~A！" name))
    :parameters '((:name :type :string :description "用户名" :required-p t))
    :category :utility
    :tags '(:utility :safe)))
```

### Tag 标签

标签用于工具分类和过滤：

```lisp
;; 检查工具标签
(cl-agent.tools:tool-has-tag-p tool :safe)        ; 是否有指定标签
(cl-agent.tools:tool-has-any-tag-p tool '(:safe :utility)) ; 是否有任一标签
(cl-agent.tools:tool-has-all-tags-p tool '(:file :read))   ; 是否有所有标签

;; 修改标签
(cl-agent.tools:tool-add-tag tool :new-tag)
(cl-agent.tools:tool-remove-tag tool :old-tag)
(cl-agent.tools:tool-set-tags tool '(:tag1 :tag2))
```

## Tool Registry（工具注册表）

### 创建和管理

```lisp
;; 创建注册表
(defvar *registry* (cl-agent.tools:make-tool-registry))

;; 注册工具
(cl-agent.tools:register-tool *registry* *my-tool*)

;; 查找工具
(cl-agent.tools:find-tool *registry* :greet)

;; 列出所有工具
(cl-agent.tools:list-tools *registry*)

;; 工具数量
(cl-agent.tools:registry-tool-count *registry*)
```

### Tag 过滤

```lisp
;; 按单个标签过滤
(cl-agent.tools:list-tools-by-tag *registry* :safe)

;; 按多个标签过滤
(cl-agent.tools:list-tools-by-tags *registry* '(:file :read) :mode :any)  ; 任一匹配
(cl-agent.tools:list-tools-by-tags *registry* '(:file :safe) :mode :all)  ; 全部匹配

;; 获取过滤后的工具 Schema
(cl-agent.tools:get-tools-schema-by-tags *registry* '(:safe) :mode :any)

;; 列出所有标签
(cl-agent.tools:list-all-tags *registry*)

;; 统计标签工具数
(cl-agent.tools:count-tools-by-tag *registry* :safe)
```

## 预设配置

### 安全级别

| 级别 | 描述 |
|------|------|
| `:permissive` | 宽松模式，最少限制 |
| `:standard` | 标准模式，平衡安全和功能 |
| `:strict` | 严格模式，最大限制 |

### 工具预设

| 预设 | 描述 |
|------|------|
| `:standard` | 标准工具集（文件、HTTP、实用工具） |
| `:safe` | 安全工具集（只读操作） |
| `:full` | 完整工具集（包含 Shell） |
| `:file-only` | 仅文件操作 |
| `:http-only` | 仅 HTTP 操作 |
| `:utility-only` | 仅实用工具 |

### 使用预设

```lisp
;; 快速获取预设工具
(defvar *tools* (cl-agent.tools:quick-setup-tools
                  :preset :safe
                  :security-level :standard))

;; 列出可用预设
(cl-agent.tools:list-all-presets)
;; => (STANDARD SAFE FULL FILE-ONLY HTTP-ONLY UTILITY-ONLY)

;; 查看预设描述
(cl-agent.tools:describe-preset :safe)
```

## 内置工具

### 文件工具

```lisp
(cl-agent.tools:make-read-file-tool)      ; 标签: (:file :io :read :safe)
(cl-agent.tools:make-write-file-tool)     ; 标签: (:file :io :write)
(cl-agent.tools:make-delete-file-tool)    ; 标签: (:file :io :write :dangerous)
(cl-agent.tools:make-list-directory-tool) ; 标签: (:file :io :read :safe)

;; 或批量创建
(cl-agent.tools:create-file-tools)
```

### HTTP 工具

```lisp
(cl-agent.tools:make-http-get-tool)   ; 标签: (:http :network :read :safe)
(cl-agent.tools:make-http-post-tool)  ; 标签: (:http :network :write)

;; 或批量创建
(cl-agent.tools:create-http-tools)
```

### Shell 工具

```lisp
(cl-agent.tools:make-execute-command-tool) ; 标签: (:shell :system :dangerous)

;; 或批量创建
(cl-agent.tools:create-shell-tools)
```

### 实用工具

```lisp
(cl-agent.tools:make-get-timestamp-tool)   ; 标签: (:utility :safe)
(cl-agent.tools:make-generate-uuid-tool)   ; 标签: (:utility :safe)
(cl-agent.tools:make-json-parse-tool)      ; 标签: (:utility :safe)
(cl-agent.tools:make-json-stringify-tool)  ; 标签: (:utility :safe)
(cl-agent.tools:make-string-replace-tool)  ; 标签: (:utility :safe)
(cl-agent.tools:make-math-eval-tool)       ; 标签: (:utility :safe)

;; 或批量创建
(cl-agent.tools:create-utility-tools)
```

## 与 Kernel 集成

```lisp
;; 方式 1：使用 Builder 添加单个工具
(defvar *kernel*
  (cl-agent.kernel:build-kernel
    (cl-agent.kernel:with-tool
      (cl-agent.kernel:add-service
        (cl-agent.kernel:create-kernel-builder)
        *provider*)
      *my-tool*)))

;; 方式 2：使用 Builder 添加多个工具
(defvar *kernel*
  (cl-agent.kernel:build-kernel
    (cl-agent.kernel:with-tools
      (cl-agent.kernel:add-service
        (cl-agent.kernel:create-kernel-builder)
        *provider*)
      (list *tool1* *tool2* *tool3*))))

;; 方式 3：使用预设
(defvar *kernel*
  (cl-agent.kernel:build-kernel
    (cl-agent.kernel:with-preset
      (cl-agent.kernel:add-service
        (cl-agent.kernel:create-kernel-builder)
        *provider*)
      :safe
      :security-level :standard)))

;; 方式 4：带 Tag 过滤
(defvar *kernel*
  (cl-agent.kernel:build-kernel
    (cl-agent.kernel:with-active-tags
      (cl-agent.kernel:with-preset
        (cl-agent.kernel:add-service
          (cl-agent.kernel:create-kernel-builder)
          *provider*)
        :full)
      '(:safe :utility)
      :mode :any)))
```

## 工具 Schema 生成

```lisp
;; 生成 JSON Schema
(cl-agent.tools:tool-to-json-schema tool)
;; => ((:name . "greet")
;;     (:description . "问候用户")
;;     (:input_schema . ...))

;; 参数到 JSON Schema
(cl-agent.tools:parameter-to-json-schema param-spec)
```

## 标签列表

| 标签 | 描述 |
|------|------|
| `:file` | 文件操作 |
| `:http` | HTTP 请求 |
| `:shell` | Shell 命令 |
| `:utility` | 通用工具 |
| `:io` | 输入/输出操作 |
| `:network` | 网络操作 |
| `:system` | 系统操作 |
| `:safe` | 安全操作（只读） |
| `:read` | 读取操作 |
| `:write` | 写入操作 |
| `:dangerous` | 危险操作 |
