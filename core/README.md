# Core 模块

中文 | [English](README_EN.md)

核心基础设施模块，提供 Kernel 框架、HTTP 客户端、条件系统和工具函数。

## 目录结构

```
core/
├── package-core.lisp          # 包定义
├── conditions.lisp            # 条件系统
├── types.lisp                 # 核心数据类型
├── utils.lisp                 # 工具函数
├── macros.lisp                # 实用宏
├── validation.lisp            # 数据验证
├── dependency-injection.lisp  # 依赖注入容器
├── data-convert.lisp          # 数据转换
├── http/                      # HTTP 客户端模块
│   ├── client.lisp
│   ├── async.lisp
│   ├── retry.lisp
│   └── streaming.lisp
└── kernel/                    # Kernel 框架
    ├── function.lisp          # Tool 元数据
    ├── plugin.lisp            # Plugin 元数据
    ├── macros.lisp            # deftool/defplugin 宏
    ├── context.lisp           # Context 类
    ├── service.lisp           # Service 抽象
    ├── filter.lisp            # Filter 管道
    ├── kernel.lisp            # Kernel 类
    └── chat.lisp              # Invoke API
```

## 核心概念

### 1. 条件系统

```lisp
;; 定义的条件类型
cl-agent-error        ; 基础错误
├── api-error         ; API 相关错误
├── llm-error         ; LLM 调用错误
├── tool-error        ; 工具执行错误
├── validation-error  ; 验证错误
└── config-error      ; 配置错误
```

### 2. 核心数据类型

```lisp
;; Message 构造
(make-message :role :user :content "Hello")
(make-message :role :assistant :content "Hi" :tool-calls [...])
(make-message :role :tool :content "Result" :tool-call-id "123")

;; ToolCall 构造
(make-tool-call :id "call_123" :name "get-weather" :arguments '(:city "Tokyo"))

;; Response 构造（工具结果）
(make-response :content "..." :tool-calls [...] :metadata {...})
```

### 2.1 统一 LLM 响应类型

所有 LLM Provider 返回统一的 `llm-response` CLOS 对象：

```lisp
;; LLM 响应对象
(make-llm-response
  :content "Hello!"
  :tool-calls nil
  :usage (make-llm-usage :input-tokens 10 :output-tokens 5)
  :model "glm-4.7"
  :finish-reason :stop
  :message-id "msg_123"
  :raw-response parsed-hash-table)

;; 访问响应内容
(llm-response-content response)      ; => "Hello!"
(llm-response-tool-calls response)   ; => nil 或工具调用列表
(llm-response-model response)        ; => "glm-4.7"
(llm-response-finish-reason response) ; => :stop, :tool-call, :length, :error

;; 便捷访问器
(llm-response-has-tool-calls-p response) ; => T/NIL
(llm-response-has-content-p response)    ; => T/NIL
(llm-response-input-tokens response)     ; => 10
(llm-response-output-tokens response)    ; => 5
(llm-response-total-tokens response)     ; => 15
(llm-response-first-tool-call response)  ; => 第一个工具调用或 nil

;; 工具调用结构
;; (:id "call_123" :name :GET_WEATHER :arguments #<hash-table>)
```

**finish-reason 统一值**：
- `:stop` - 正常结束
- `:tool-call` - 需要工具调用
- `:length` - 达到最大长度
- `:error` - 错误
- `:content-filter` - 内容过滤

### 3. 工具函数

```lisp
;; 环境变量
(get-env "API_KEY")
(get-env "PORT" "8080")  ; 带默认值

;; UUID 生成
(generate-uuid)  ; => "550e8400-e29b-41d4-a716-446655440000"

;; 时间戳
(timestamp-now)  ; => "2024-01-15T10:30:00Z"

;; JSON 操作
(json-encode object)
(json-decode string)
```

### 4. 实用宏

```lisp
;; 条件绑定
(when-let ((value (get-value)))
  (process value))

(if-let ((value (get-value)))
  (process value)
  (handle-nil))

;; 计时
(with-timing ("operation")
  (do-something))

;; 线程宏（类似 Clojure）
(-> value
    (transform-1)
    (transform-2 extra-arg)
    (transform-3))
```

## Kernel 框架

### Tool Function

使用 Symbol Plist 存储工具元数据：

```lisp
;; 声明式定义
(deftool get-weather "获取天气信息"
  ((city :string "城市名称" :required-p t)
   (unit :string "温度单位" :default "celsius"))
  (format nil "~A: 22°C" city))

;; 运行时注册
(declare-tool 'my-tool
  :description "工具描述"
  :parameters '((param1 :string "参数1" :required-p t)))

;; 查询元数据
(tool-function-p 'get-weather)    ; => T
(tool-description 'get-weather)   ; => "获取天气信息"
(tool-parameters 'get-weather)    ; => (...)
(tool-schema 'get-weather)        ; => JSON Schema
```

### Plugin

工具的逻辑分组：

```lisp
;; 声明式定义
(defplugin weather-plugin "天气相关工具"
  get-weather
  get-forecast)

;; 运行时注册
(declare-plugin 'my-plugin "插件描述" '(tool1 tool2))

;; 查询
(plugin-p 'weather-plugin)           ; => T
(plugin-tool-symbols 'weather-plugin) ; => (GET-WEATHER GET-FORECAST)
(plugin-get-schemas 'weather-plugin)  ; => 所有工具的 schemas
```

### Context

执行上下文：

```lisp
(let ((ctx (make-context :messages messages)))
  ;; 变量管理
  (context-set-variable ctx "key" "value")
  (context-get-variable ctx "key")

  ;; 消息管理
  (context-add-message ctx message)
  (context-messages ctx)

  ;; 历史和追踪
  (context-history ctx)
  (context-trace ctx))
```

### Service

LLM 服务抽象：

```lisp
(make-service
  :chat-fn (lambda (messages tools settings)
             ;; 调用 LLM
             ...)
  :build-result-msgs-fn (lambda (response)
                          ;; 构建结果消息
                          ...)
  :provider provider-instance)
```

### Filter

4 种类型的过滤器：

```lisp
;; 过滤器类型
:pre-invocation   ; 工具执行前
:post-invocation  ; 工具执行后
:pre-chat         ; LLM 调用前
:post-chat        ; LLM 调用后

;; 创建过滤器
(make-filter
  :type :pre-chat
  :name "rag-injection"
  :fn (lambda (ctx next)
        ;; 前置处理
        (inject-rag-context ctx)
        ;; 调用下一个
        (let ((result (funcall next ctx)))
          ;; 后置处理
          result))
  :priority 10)
```

### Kernel

中央协调器：

```lisp
;; 创建 Kernel
(defvar *kernel*
  (make-kernel
    :service *service*
    :plugins '(plugin1 plugin2)
    :filters (list filter1 filter2)
    :config '(:max-iterations 10)))

;; Builder 模式
(defvar *kernel*
  (-> (make-kernel)
      (with-service service)
      (with-plugins '(plugin1))
      (with-filter filter)
      (with-config '(:debug t))
      (build)))

;; 获取工具信息
(kernel-get-tools *kernel*)
(kernel-get-schema *kernel* "tool-name")
```

### 3-Tier Invoke API

```lisp
;; Tier 1: 执行单个工具
(invoke-tool kernel context "get-weather" '(:city "Tokyo"))

;; Tier 2: 单次 LLM 调用
(invoke-chat kernel context messages settings)

;; Tier 3: 完整工具调用循环
(invoke-kernel kernel context messages)
```

## HTTP 客户端

```lisp
;; 基本请求
(http-get url :headers headers)
(http-post url :body body :headers headers)

;; 异步请求
(http-async url :method :post
            :on-success (lambda (response) ...)
            :on-error (lambda (error) ...))

;; 流式请求 (SSE)
(http-stream url
  :on-event (lambda (event) ...)
  :on-error (lambda (error) ...))

;; 带重试
(with-retry (:attempts 3 :backoff :exponential)
  (http-get url))
```

## 依赖注入

```lisp
;; 创建容器
(defvar *container* (make-di-container))

;; 注册服务
(di-register *container* :llm-client
  (lambda () (make-client :provider :anthropic)))

;; 解析服务
(di-resolve *container* :llm-client)

;; 作用域
(di-scoped *container* :request
  (lambda ()
    ;; 请求作用域的服务
    ...))
```
