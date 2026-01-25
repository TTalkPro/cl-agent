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

可暂停、恢复、停止的 Agent，适合长时间运行的任务。集成 core/process 框架支持事件驱动和人工介入。

### 基本用法

```lisp
;; 创建
(defvar *process-agent*
  (make-process-agent *kernel*
    :name "background-worker"))

;; 启动（非阻塞）
(agent-start *process-agent*)
(agent-send *process-agent* "分析这份大型数据集...")

;; 检查状态
(agent-state *process-agent*)  ; => :running / :paused / :stopped

;; 暂停
(agent-pause *process-agent*)

;; 恢复
(agent-resume *process-agent*)

;; 停止
(agent-stop *process-agent*)
```

### 事件注入 (类似 C# Process Framework)

```lisp
;; 创建带事件处理的 Agent
(defvar *process-agent*
  (make-process-agent *kernel*
    :name "event-driven-agent"
    :event-handlers
    (list
      (cons :external
            (lambda (event)
              (format t "收到外部事件: ~A~%"
                      (cl-agent.process:event-data event)))))))

(agent-start *process-agent*)

;; 订阅事件
(agent-subscribe-event *process-agent* :approval
  (lambda (event)
    (format t "收到审批: ~A~%" (cl-agent.process:event-data event))))

;; 注入外部事件（类似 C# 的 InputEvent）
(agent-inject-event *process-agent*
  (cl-agent.process:make-event
    :type :external
    :name "data-ready"
    :data '(:file "data.csv" :rows 1000)))

;; 注入审批事件
(agent-inject-event *process-agent*
  (cl-agent.process:make-event
    :type :approval
    :data t
    :source "manager"))
```

### 人工介入 (Human-in-the-Loop)

```lisp
;; 创建带人工输入处理的 Agent
(defvar *process-agent*
  (make-process-agent *kernel*
    :name "hitl-agent"
    :human-handler
    (lambda (request)
      ;; 转发到 UI 或其他处理
      (format t "需要人工输入: ~A~%"
              (cl-agent.process:input-request-prompt request)))))

(agent-start *process-agent*)

;; 请求人工审批
(let ((request (cl-agent.process:make-input-request
                 :type :approval
                 :prompt "是否批准删除这些文件？"
                 :description "将删除 100 个临时文件"
                 :timeout 300)))
  (agent-request-input *process-agent* request))

;; 查看待处理的人工输入
(agent-get-pending-inputs *process-agent*)

;; 提交人工响应
(agent-submit-input *process-agent*
  (cl-agent.process:make-input-response request-id
    :value "approved"
    :approved-p t
    :responder "admin"))

;; 便捷函数：等待审批
(when (agent-wait-for-approval *process-agent*
                                "继续执行？"
                                :timeout 60)
  (execute-dangerous-operation))

;; 便捷函数：等待确认
(when (agent-wait-for-confirmation *process-agent*
                                    "是否保存更改？"
                                    :default t)
  (save-changes))
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
(agent-send *process-agent* "新的指令...")

;; 获取 Agent 输出
(agent-receive *process-agent*)  ; 阻塞
(agent-receive *process-agent* :timeout 5)  ; 5 秒超时
```

### 步骤流程 (Step-based Workflow)

```lisp
;; 定义流程
(cl-agent.process:defprocess document-approval
  :description "文档审批流程"

  :steps
  ((submit
    :description "提交文档"
    :handler (lambda (ctx input)
               (cl-agent.process:step-completed :output input)))

   (review
    :description "审核文档"
    :wait-for (:approval)
    :timeout 3600
    :handler (lambda (ctx input)
               (if (cl-agent.process:context-get-variable ctx :approved)
                   (cl-agent.process:step-completed :output input)
                   (cl-agent.process:step-failed "被拒绝")))))

  :on-event
  ((:approval . (lambda (ctx event)
                  (cl-agent.process:context-set-variable ctx :approved
                    (cl-agent.process:event-data event))))))

;; 创建带流程的 Agent
(defvar *workflow-agent*
  (make-process-agent *kernel*
    :name "workflow-agent"
    :process document-approval))

(agent-start *workflow-agent*)

;; 启动流程
(agent-start-process *workflow-agent* :input document-data)

;; 注入审批事件
(agent-inject-event *workflow-agent*
  (cl-agent.process:make-event :type :approval :data t))

;; 获取流程状态
(agent-get-process-state *workflow-agent*)
;; => (:state :running :current-step "review" ...)
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
