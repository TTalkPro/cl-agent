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
;; 在测试中使用
(deftest test-agent-with-mock
  (let* ((mock-llm (make-mock-llm :mode :sequence
                                  :responses '("让我查一下"
                                               "北京今天晴天")))
         (kernel (make-kernel :service (make-service :provider mock-llm)))
         (agent (make-kernel-agent kernel)))

    ;; 测试 Agent 行为
    (let ((response (agent-chat agent "北京天气")))
      (is (search "晴天" response)))))

;; 验证工具调用
(deftest test-tool-calls
  (let* ((mock-tool (make-mock-tool "search" :response "结果"))
         (kernel (make-kernel ...)))

    (agent-chat agent "搜索 Lisp")

    ;; 验证工具被调用
    (is (mock-tool-called-with mock-tool '(:query "Lisp")))))
```

## 使用示例

### 完整测试场景

```lisp
(deftest test-weather-agent
  ;; 设置 Mock
  (let* ((mock-llm (make-mock-llm))
         (mock-weather (make-mock-tool "get-weather"
                         :response "北京：晴，25°C")))

    ;; 配置 LLM 响应序列
    (mock-llm-set-responses *mock-llm*
      '(;; 第一次调用：决定使用工具
        (:tool-calls ((:id "1" :name "get-weather" :arguments (:city "北京"))))
        ;; 第二次调用：生成最终回复
        "根据查询，北京今天天气晴朗，温度 25°C。"))

    ;; 创建 Agent
    (let ((agent (make-kernel-agent
                   (make-kernel
                     :service (make-service :provider mock-llm)
                     :plugins (list mock-weather)))))

      ;; 执行测试
      (let ((response (agent-chat agent "北京天气怎么样？")))
        ;; 验证响应
        (is (search "25°C" response))
        ;; 验证工具调用
        (is (mock-tool-called-with mock-weather '(:city "北京")))))))
```

### 流式响应模拟

```lisp
(make-mock-llm :mode :stream
               :tokens '("你" "好" "！" "我" "是" "助" "手" "。"))

(mock-llm-chat-stream *mock-llm* messages
  :on-token (lambda (token)
              (format t "~A" token)))
```
