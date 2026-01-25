# CL-Agent Kernel Plugin 设计方案

## 设计原则

1. **无全局变量** —— 工具实例由 plugin 对象持有，不依赖 `defparameter`
2. **CLOS 双分派** —— `tool-invoke (plugin-class × eql-tool-name)` 编译期确定调用路径
3. **协议为骨架** —— 框架只定义 `defgeneric`，用户实现 `defmethod`
4. **宏为语法糖** —— `defplugin` / `deftool` 简化声明，但非必须

---

## 架构总览

```
┌──────────────────────────────────────────────────┐
│  用户代码                                         │
│  ┌──────────────┐   ┌──────────────────────────┐ │
│  │ defplugin    │   │ deftool                  │ │
│  │ (语法糖)     │   │ (语法糖)                  │ │
│  └──────┬───────┘   └───────────┬──────────────┘ │
│         │                       │                 │
│         ▼                       ▼                 │
│  ┌──────────────┐   ┌──────────────────────────┐ │
│  │ defclass     │   │ defmethod                │ │
│  │ defmethod    │   │  tool-invoke             │ │
│  │  plugin-name │   │  tool-description        │ │
│  │  plugin-desc │   │  tool-schema             │ │
│  └──────┬───────┘   └───────────┬──────────────┘ │
├─────────┼───────────────────────┼─────────────────┤
│  框架协议层                                        │
│         ▼                       ▼                 │
│  ┌────────────────────────────────────────────┐   │
│  │ CLOS 双分派                                 │   │
│  │ (plugin-class × eql-tool-name) → 方法体    │   │
│  └────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────┘
```

---

## 第一层：CLOS 协议（核心，无宏）

### 基类

```lisp
(defclass kernel-plugin ()
  ((tools-cache :initform nil :accessor plugin-tools-cache))
  (:documentation "所有插件的基类"))
```

### 插件级协议

```lisp
(defgeneric plugin-name (plugin)
  (:documentation "返回插件名称 keyword"))

(defgeneric plugin-description (plugin)
  (:documentation "返回插件描述字符串"))

(defgeneric plugin-tools (plugin)
  (:documentation "返回此插件支持的工具名称 keyword 列表"))
```

### 工具级协议（双分派）

```lisp
(defgeneric tool-invoke (plugin tool-name args)
  (:documentation "执行工具。
  PLUGIN    - 插件实例（提供 class 分派）
  TOOL-NAME - 工具名称 keyword（提供 EQL 分派）
  ARGS      - 参数 plist"))

(defgeneric tool-description (plugin tool-name)
  (:documentation "返回工具描述字符串"))

(defgeneric tool-schema (plugin tool-name)
  (:documentation "返回工具参数的 JSON Schema（hash-table）"))
```

### 纯协议使用方式（不用任何宏）

```lisp
(defclass weather-plugin (kernel-plugin)
  ((api-key :initarg :api-key :reader plugin-api-key)))

(defmethod plugin-name ((p weather-plugin)) :weather-plugin)
(defmethod plugin-description ((p weather-plugin)) "天气工具集")
(defmethod plugin-tools ((p weather-plugin)) '(:get-weather :get-forecast))

;; --- :get-weather ---
(defmethod tool-description ((p weather-plugin) (name (eql :get-weather)))
  "获取指定城市的当前天气信息")

(defmethod tool-schema ((p weather-plugin) (name (eql :get-weather)))
  (params->json-schema
   '((city :string "城市名称" :required t)
     (unit :string "温度单位" :default "celsius"))))

(defmethod tool-invoke ((p weather-plugin) (name (eql :get-weather)) args)
  (let ((city (getf args :city))
        (unit (getf args :unit "celsius")))
    (format nil "~A：晴，22°~A" city unit)))

;; --- :get-forecast ---
(defmethod tool-description ((p weather-plugin) (name (eql :get-forecast)))
  "获取天气预报")

(defmethod tool-schema ((p weather-plugin) (name (eql :get-forecast)))
  (params->json-schema
   '((city :string "城市名称" :required t)
     (days :int "预报天数" :default 3))))

(defmethod tool-invoke ((p weather-plugin) (name (eql :get-forecast)) args)
  (format nil "~A未来~A天：晴转多云" (getf args :city) (getf args :days 3)))
```

---

## 第二层：宏语法糖

### defplugin

```lisp
(defplugin weather-plugin ()
  "天气工具集"
  ((api-key :initarg :api-key :reader plugin-api-key)
   (base-url :initarg :base-url :initform "https://api.weather.com")))
```

展开为：

```lisp
(progn
  (defclass weather-plugin (kernel-plugin)
    ((api-key :initarg :api-key :reader plugin-api-key)
     (base-url :initarg :base-url :initform "https://api.weather.com")))

  (defmethod plugin-name ((p weather-plugin))
    :weather-plugin)

  (defmethod plugin-description ((p weather-plugin))
    "天气工具集"))
```

### deftool

```lisp
(deftool (weather-plugin :get-weather)
  "获取指定城市的天气信息"
  ((city :string "城市名称" :required t)
   (unit :string "温度单位" :default "celsius"))
  (format nil "~A：晴，22°~A（via ~A）"
          city unit (plugin-api-key plugin)))
```

展开为：

```lisp
(progn
  ;; 注册工具名到类元数据
  (register-tool-name 'weather-plugin :get-weather)

  ;; 描述
  (defmethod tool-description ((plugin weather-plugin)
                               (name (eql :get-weather)))
    "获取指定城市的天气信息")

  ;; Schema
  (defmethod tool-schema ((plugin weather-plugin)
                          (name (eql :get-weather)))
    (params->json-schema
     '((city :string "城市名称" :required t)
       (unit :string "温度单位" :default "celsius"))))

  ;; 执行（body 中 plugin 变量可用）
  (defmethod tool-invoke ((plugin weather-plugin)
                          (name (eql :get-weather))
                          args)
    (let ((city (getf args :city))
          (unit (getf args :unit "celsius")))
      (format nil "~A：晴，22°~A（via ~A）"
              city unit (plugin-api-key plugin)))))
```

### 工具名注册（plugin-tools 自动实现）

```lisp
;; 编译期元数据（仅存 class-name → tool-names 映射）
(defvar *plugin-tool-registry* (make-hash-table :test #'eq))

(defun register-tool-name (class-name tool-name)
  (pushnew tool-name (gethash class-name *plugin-tool-registry*)))

;; plugin-tools 默认实现：从 registry 读取
(defmethod plugin-tools ((p kernel-plugin))
  (gethash (class-name (class-of p)) *plugin-tool-registry*))
```

注意：`*plugin-tool-registry*` 是**编译期元数据**（类似 CLOS 自身的 class registry），不是工具实例。用户手动 `defmethod plugin-tools` 可覆盖此行为。

---

## 第三层：Kernel 集成

### tool_call 阶段的分派路径

```
LLM 返回: {name: "get_weather", arguments: {"city": "北京"}}
        │
        ▼
kernel-execute-tool(kernel, :get-weather, (:city "北京"))
        │
        ├── find-plugin-for-tool  →  遍历 plugins，检查 plugin-tools
        │
        ▼
(tool-invoke <weather-plugin> :get-weather (:city "北京"))
        │
        ▼
CLOS discriminating function:
   specializer-1: (typep obj 'weather-plugin)  → class test
   specializer-2: (eq name :get-weather)       → eq test
        │
        ▼
直接跳转方法体（无 hash-table 查找）
```

### Kernel 实现

```lisp
(defun kernel-get-tools (kernel)
  "收集所有插件的工具 schema 列表（传给 LLM 的 tools 参数）"
  (loop for plugin in (kernel-plugins kernel)
        nconc (loop for tool-name in (plugin-tools plugin)
                    collect
                    (list :name (string-downcase (symbol-name tool-name))
                          :description (tool-description plugin tool-name)
                          :input-schema (tool-schema plugin tool-name)))))

(defun kernel-execute-tool (kernel fn-name args)
  "查找并执行工具"
  (let ((plugin (find-plugin-for-tool kernel fn-name)))
    (unless plugin
      (error "Tool ~A not found in any plugin" fn-name))
    (tool-invoke plugin fn-name args)))

(defun find-plugin-for-tool (kernel fn-name)
  "查找包含指定工具的插件"
  (loop for plugin in (kernel-plugins kernel)
        when (member fn-name (plugin-tools plugin))
          return plugin))
```

---

## 使用示例

### 使用宏（推荐，简洁）

```lisp
(defplugin weather-plugin ()
  "天气工具集"
  ((api-key :initarg :api-key :reader plugin-api-key)))

(deftool (weather-plugin :get-weather)
  "获取指定城市的天气信息"
  ((city :string "城市名称" :required t)
   (unit :string "温度单位" :default "celsius"))
  (format nil "~A：晴，22°~A（via ~A）"
          city unit (plugin-api-key plugin)))

(deftool (weather-plugin :get-forecast)
  "获取天气预报"
  ((city :string "城市名称" :required t)
   (days :int "预报天数" :default 3))
  (format nil "~A未来~A天：晴转多云" city days))

;; 实例化（无全局变量）
(let* ((wp (make-instance 'weather-plugin :api-key "my-key"))
       (kernel (make-kernel
                 :chat-service provider
                 :plugins (list wp))))
  (chat-completion kernel history
    :settings '(:system-prompt "你是有用的助手")))
```

### 不使用宏（纯 CLOS）

```lisp
(defclass weather-plugin (kernel-plugin)
  ((api-key :initarg :api-key :reader plugin-api-key)))

(defmethod plugin-name ((p weather-plugin)) :weather-plugin)
(defmethod plugin-description ((p weather-plugin)) "天气工具集")
(defmethod plugin-tools ((p weather-plugin)) '(:get-weather))

(defmethod tool-description ((p weather-plugin) (name (eql :get-weather)))
  "获取天气")

(defmethod tool-schema ((p weather-plugin) (name (eql :get-weather)))
  (params->json-schema '((city :string "城市名" :required t))))

(defmethod tool-invoke ((p weather-plugin) (name (eql :get-weather)) args)
  (format nil "~A：晴" (getf args :city)))

;; 使用方式完全相同
(let* ((wp (make-instance 'weather-plugin :api-key "my-key"))
       (kernel (make-kernel :chat-service provider :plugins (list wp))))
  (chat-completion kernel history :settings ...))
```

---

## 关键优势

| 特性 | 说明 |
|------|------|
| 无全局变量 | 工具生命周期由 plugin 实例管理 |
| 编译期分派 | CLOS 方法缓存，无运行时 hash-table |
| 插件可持有状态 | api-key、config 等通过 slots 访问 |
| 多实例共存 | 同一 plugin 类可创建多个不同配置的实例 |
| 可测试 | 传入 mock plugin 实例即可，无需 mock 全局状态 |
| 可扩展 | 任何包可 defmethod 添加新工具到已有 plugin |
| 两种风格共存 | 宏和纯 CLOS 可混用，宏只是语法糖 |
