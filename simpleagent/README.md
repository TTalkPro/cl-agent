# SimpleAgent 模块

简单 Agent 实现模块，提供开箱即用的 Agent 类。

## 目录结构

```
simpleagent/
├── package.lisp        # 包定义
├── common.lisp         # 基础 Agent 类和协议
├── kernel-agent.lisp   # KernelAgent 实现
└── process-agent.lisp  # ProcessAgent 实现
```

## Agent 类型

| 类型 | 描述 | 使用场景 |
|------|------|----------|
| KernelAgent | 简单聊天循环 Agent | 基本对话、工具调用 |
| ProcessAgent | 可暂停/恢复的 Agent | 长时间任务、后台运行 |

## KernelAgent

### 基本用法

```lisp
;; 创建 Agent
(defvar *agent*
  (make-kernel-agent *kernel*
    :name "my-assistant"
    :system-prompt "你是一个有帮助的助手。"))

;; 聊天
(agent-chat *agent* "你好！")
;; => "你好！有什么可以帮助你的吗？"

;; 多轮对话（自动保持上下文）
(agent-chat *agent* "我叫小明")
(agent-chat *agent* "我叫什么？")
;; => "你叫小明。"
```

### 完整配置

```lisp
(defvar *agent*
  (make-kernel-agent *kernel*
    :name "advanced-agent"
    :system-prompt "你是一个专业的数据分析师。"

    ;; 设置
    :settings '(:max-iterations 10      ; 最大工具调用轮数
                :temperature 0.7        ; 采样温度
                :max-tokens 2048        ; 最大输出 token
                :stop-sequences ("END") ; 停止序列
                :verbose nil)           ; 是否输出调试信息

    ;; 回调
    :callbacks (list
                 :on-message (lambda (msg) (format t "消息: ~A~%" msg))
                 :on-tool-call (lambda (call) (format t "工具: ~A~%" call))
                 :on-error (lambda (err) (format t "错误: ~A~%" err)))))
```

### 带记忆的 Agent

```lisp
(defvar *memory* (make-agent-memory))

(defvar *agent*
  (make-kernel-agent *kernel*
    :name "memory-agent"
    :memory *memory*
    :system-prompt "记住用户的偏好。"))

;; 对话会自动保存到记忆
(agent-chat *agent* "我喜欢蓝色")
(agent-chat *agent* "我喜欢什么颜色？")
;; => "你喜欢蓝色。"
```

### 获取 Agent 信息

```lisp
(agent-id *agent*)          ; => "550e8400-..."
(agent-name *agent*)        ; => "my-assistant"
(agent-created-at *agent*)  ; => "2024-01-15T10:30:00Z"
(agent-history *agent*)     ; => 对话历史列表
(agent-context *agent*)     ; => 当前上下文
```

### 重置对话

```lisp
;; 清空历史，保留配置
(agent-reset *agent*)

;; 完全重新初始化
(agent-reinitialize *agent*)
```

## ProcessAgent

可暂停、恢复、停止的 Agent，适合长时间运行的任务。

### 基本用法

```lisp
;; 创建
(defvar *process-agent*
  (make-process-agent *kernel*
    :name "background-worker"))

;; 启动（非阻塞）
(agent-start *process-agent* "分析这份大型数据集...")

;; 检查状态
(agent-state *process-agent*)  ; => :running / :paused / :stopped

;; 暂停
(agent-pause *process-agent*)

;; 恢复
(agent-resume *process-agent*)

;; 停止
(agent-stop *process-agent*)
```

### 等待完成

```lisp
;; 阻塞等待
(agent-wait *process-agent*)

;; 带超时等待
(agent-wait *process-agent* :timeout 60)  ; 60 秒超时

;; 获取结果
(agent-result *process-agent*)
```

### 状态回调

```lisp
(defvar *process-agent*
  (make-process-agent *kernel*
    :on-start (lambda (agent)
                (format t "Agent 已启动~%"))
    :on-pause (lambda (agent)
                (format t "Agent 已暂停~%"))
    :on-resume (lambda (agent)
                 (format t "Agent 已恢复~%"))
    :on-stop (lambda (agent result)
               (format t "Agent 已停止，结果: ~A~%" result))
    :on-error (lambda (agent error)
                (format t "Agent 错误: ~A~%" error))))
```

### 消息队列

```lisp
;; 向运行中的 Agent 发送消息
(agent-send-message *process-agent* "新的指令...")

;; 获取 Agent 输出
(agent-receive-message *process-agent*)  ; 阻塞
(agent-receive-message *process-agent* :timeout 5)  ; 5 秒超时
```

## 自定义 Agent

继承 `base-agent` 创建自定义 Agent：

```lisp
(defclass my-custom-agent (base-agent)
  ((custom-slot :accessor agent-custom-slot
                :initarg :custom-slot)))

(defmethod agent-chat ((agent my-custom-agent) message &key &allow-other-keys)
  ;; 自定义聊天逻辑
  ...)

(defmethod agent-reset ((agent my-custom-agent))
  ;; 自定义重置逻辑
  (call-next-method)  ; 调用父类方法
  ...)
```

## Agent 协议

所有 Agent 实现以下协议：

```lisp
;; 基本属性
(defgeneric agent-id (agent))
(defgeneric agent-name (agent))
(defgeneric agent-created-at (agent))
(defgeneric agent-metadata (agent))

;; 核心操作
(defgeneric agent-chat (agent message &key &allow-other-keys))
(defgeneric agent-reset (agent))

;; 可选操作（ProcessAgent）
(defgeneric agent-start (agent message))
(defgeneric agent-pause (agent))
(defgeneric agent-resume (agent))
(defgeneric agent-stop (agent))
(defgeneric agent-state (agent))
```

## 使用示例

### 客服机器人

```lisp
(defvar *customer-service*
  (make-kernel-agent *kernel*
    :name "customer-service"
    :system-prompt "你是一个专业的客服代表。
- 始终保持礼貌和耐心
- 尽量解决客户问题
- 必要时转接人工客服"))

(agent-chat *customer-service* "我的订单还没收到")
```

### 代码助手

```lisp
(defvar *code-assistant*
  (make-kernel-agent *kernel*
    :name "code-assistant"
    :system-prompt "你是一个编程助手。
- 提供清晰的代码示例
- 解释代码的工作原理
- 建议最佳实践"
    :settings '(:temperature 0.3)))  ; 低温度更确定性

(agent-chat *code-assistant* "如何在 Common Lisp 中读取文件？")
```

### 后台数据处理

```lisp
(defvar *data-processor*
  (make-process-agent *kernel*
    :name "data-processor"))

;; 启动后台任务
(agent-start *data-processor*
  "分析 sales.csv 文件，生成月度报告")

;; 做其他事情...

;; 检查进度
(when (eq (agent-state *data-processor*) :running)
  (format t "仍在处理中...~%"))

;; 等待完成并获取结果
(let ((result (agent-wait *data-processor*)))
  (format t "分析完成: ~A~%" result))
```
