# Mock 模块

中文 | [English](README_EN.md)

测试用 Mock 实现模块，提供 LLM 和工具的模拟。

## 目录结构

```
mock/
├── package.lisp              # 包定义
├── llm.lisp                  # Mock LLM
└── tools.lisp                # Mock 工具
```

## Mock LLM

### 基本使用

```lisp
;; 创建 Mock LLM
(defvar *mock-llm* (make-mock-llm))

;; 设置预定义响应
(mock-llm-set-response *mock-llm*
  "你好"
  "你好！有什么可以帮助你的吗？")

;; 使用
(mock-llm-chat *mock-llm* "你好")
;; => "你好！有什么可以帮助你的吗？"
```

### 响应模式

```lisp
;; 固定响应
(make-mock-llm :mode :fixed
               :response "固定回复")

;; 回显模式
(make-mock-llm :mode :echo)
(mock-llm-chat *mock-llm* "Hello")
;; => "Echo: Hello"

;; 序列响应
(make-mock-llm :mode :sequence
               :responses '("第一次回复" "第二次回复" "第三次回复"))

;; 函数响应
(make-mock-llm :mode :function
               :handler (lambda (messages)
                          (format nil "收到 ~A 条消息" (length messages))))
```

### 工具调用模拟

```lisp
;; 设置工具调用响应
(mock-llm-set-tool-call *mock-llm*
  "天气"
  '(:tool-calls ((:id "call_1"
                  :name "get-weather"
                  :arguments (:city "北京")))))

;; 使用
(mock-llm-chat *mock-llm* "北京天气怎么样？")
;; => {:tool-calls [...]}
```

### 延迟模拟

```lisp
;; 模拟网络延迟
(make-mock-llm :delay 1000)  ; 1 秒延迟

;; 随机延迟
(make-mock-llm :delay '(500 . 2000))  ; 500-2000 ms
```

### 错误模拟

```lisp
;; 模拟错误
(mock-llm-set-error *mock-llm* "错误触发词"
  (make-condition 'llm-error :message "API 错误"))

;; 随机错误
(make-mock-llm :error-rate 0.1)  ; 10% 错误率
```

## Mock 工具

### 创建 Mock 工具

```lisp
;; 固定返回值
(defvar *mock-weather*
  (make-mock-tool "get-weather"
    :response "晴天，25°C"))

;; 函数返回值
(defvar *mock-calculator*
  (make-mock-tool "calculate"
    :handler (lambda (args)
               (eval (read-from-string (getf args :expression))))))
```

### 调用记录

```lisp
;; 获取调用历史
(mock-tool-calls *mock-weather*)
;; => ((:args (:city "北京") :time "...")
;;     (:args (:city "上海") :time "..."))

;; 清除记录
(mock-tool-clear-calls *mock-weather*)

;; 验证调用
(mock-tool-called-p *mock-weather*)  ; => T
(mock-tool-called-with *mock-weather* '(:city "北京"))  ; => T
(mock-tool-call-count *mock-weather*)  ; => 2
```

## 与测试集成

```lisp
;; 在测试中把 Mock LLM 适配为 ChatModel
(deftest test-kernel-with-mock
  (let* ((mock-llm (cl-agent.mock:make-mock-llm))
         (model (cl-agent.chat:make-provider-chat-model mock-llm))
         (k (cl-agent.kernel:build-kernel :model model)))
    (is (stringp (cl-agent.kernel:chat k "你好")))))

;; 需要精确控制响应序列时，直接特化 llm-chat（见 tests/suite.lisp
;; 的 seq-provider）：每次调用弹出预设的 llm-response，
;; 可断言工具循环轮数、发给模型的消息等。
```

## 使用示例

### 完整测试场景（工具循环）

```lisp
(deftest test-weather-tools
  ;; 第一轮返回 tool-call，第二轮返回最终文本
  (let* ((provider (make-seq-provider
                    (tool-call-response "get_weather" '(("city" . "北京")))
                    (text-response "北京今天晴，25°C")))
         (model (cl-agent.chat:make-provider-chat-model provider))
         (k (cl-agent.kernel:build-kernel :model model :tools '(get-weather))))
    (is (search "25°C"
                (cl-agent.kernel:chat k (:user "北京天气怎么样？"))))))
```

### 流式响应模拟

```lisp
(make-mock-llm :mode :stream
               :tokens '("你" "好" "！" "我" "是" "助" "手" "。"))

(mock-llm-chat-stream *mock-llm* messages
  :on-token (lambda (token)
              (format t "~A" token)))
```
