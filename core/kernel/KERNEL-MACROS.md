## `defkernel` - 声明式定义工具函数

核心作用：**一次声明，同时生成可调用函数和 LLM 工具 schema**。

```lisp
(defkernel get-weather "获取天气"
  ((city :string "城市名称" :required-p t)
   (unit :string "温度单位" :default "celsius"))
  (format nil "~A 天气：晴，22°~A" city unit))
```

展开为两件事：

1. **一个普通 defun**（可以直接在 Lisp 中调用）：
   ```lisp
   (defun get-weather (&key city (unit "celsius")) ...)
   ```

2. **一个 `kernel-function` 实例**（存放 schema 元数据，供 LLM 识别）：
   ```lisp
   (defparameter *kf-get-weather*
     (make-kernel-function
       :name :get-weather
       :description "获取天气"
       :handler #'get-weather
       :parameters '((city :string "城市名称" :required-p t) ...)
       ...))
   ```

参数规格中的 `:string`、`:required-p`、`:default` 会被自动转换为 JSON Schema，发送给 LLM 作为 tool 定义。这样函数签名和 schema 永远保持同步，不会出现不一致。

---

## `defplugin` - 将多个 kernel-function 组织为插件

核心作用：**把相关工具打包到一个命名集合中**，方便注册到 kernel。

```lisp
(defplugin weather-plugin "天气工具集"
  *kf-get-weather*
  *kf-get-forecast*)
```

展开为：
```lisp
(defparameter *plugin-weather-plugin*
  (create-plugin :weather-plugin "天气工具集"
                 (list *kf-get-weather* *kf-get-forecast*)))
```

然后在创建 kernel 时按需挂载：
```lisp
(make-kernel :chat-service provider
             :plugins (list *plugin-weather-plugin*
                            *plugin-math-plugin*))
```

---

## 整体关系

```
defkernel  →  *kf-xxx*  (单个工具定义)
                ↓
defplugin  →  *plugin-xxx*  (工具集合)
                ↓
make-kernel  →  kernel 实例  (挂载插件，提供 chat-completion)
```

这个模式借鉴自 Microsoft Semantic Kernel 的设计：kernel-function 是最小执行单元，plugin 是分组容器，kernel 是运行时协调器。好处是工具定义与 LLM 调用逻辑完全解耦——同一组 plugin 可以挂到不同的 kernel（不同模型/provider）上使用。
