# Tools 模块

基础工具定义和工具注册系统。

## 目录结构

```
tools/
├── package-tools.lisp        # 包定义
├── registry.lisp             # 工具注册表
├── executor.lisp             # 工具执行器
├── schema.lisp               # Schema 生成
└── builtin/                  # 内置工具定义
    └── ...
```

## 工具注册

### 注册工具

```lisp
;; 使用 register-tool
(register-tool :get-time
  :description "获取当前时间"
  :parameters '()
  :handler (lambda ()
             (format nil "~A" (get-universal-time))))

;; 带参数的工具
(register-tool :greet
  :description "问候用户"
  :parameters '((:name :type :string :description "用户名" :required t))
  :handler (lambda (name)
             (format nil "你好，~A！" name)))
```

### 查询工具

```lisp
;; 获取工具信息
(get-tool :get-time)
;; => (:name :get-time :description "获取当前时间" ...)

;; 列出所有工具
(list-tools)
;; => (:get-time :greet ...)

;; 检查工具是否存在
(tool-exists-p :get-time)
;; => T
```

### 执行工具

```lisp
;; 执行工具
(execute-tool :greet '("小明"))
;; => "你好，小明！"

;; 带关键字参数
(execute-tool :greet '(:name "小明"))
;; => "你好，小明！"
```

## Schema 生成

```lisp
;; 生成 JSON Schema
(tool-to-json-schema :greet)
;; => {"name": "greet",
;;     "description": "问候用户",
;;     "parameters": {
;;       "type": "object",
;;       "properties": {
;;         "name": {"type": "string", "description": "用户名"}
;;       },
;;       "required": ["name"]
;;     }}

;; 批量生成
(tools-to-json-schemas '(:get-time :greet))
```

## 与 Kernel 集成

```lisp
;; 工具会自动被 Kernel 的插件系统使用
;; 参见 core/kernel/function.lisp 和 plugin/ 模块
```

## 参数类型

支持的参数类型：

| 类型 | 关键字 | JSON Schema 类型 |
|------|--------|------------------|
| 字符串 | `:string` | `string` |
| 整数 | `:int` / `:integer` | `integer` |
| 数字 | `:number` / `:float` | `number` |
| 布尔 | `:bool` / `:boolean` | `boolean` |
| 数组 | `:array` / `:list` | `array` |
| 对象 | `:object` / `:hash` | `object` |
