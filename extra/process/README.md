# Process Framework

中文 | [English](README_EN.md)

事件驱动的流程执行框架，支持外部事件注入、Human-in-the-loop 和状态机控制。

## 目录结构

```
core/process/
├── package.lisp          # 包定义
├── event.lisp            # 事件系统
├── step.lisp             # 步骤抽象
├── state-machine.lisp    # 状态机
├── human-loop.lisp       # Human-in-the-loop
├── process.lisp          # 流程定义
└── runtime.lisp          # 运行时
```

## 核心概念

### 事件系统 (Event)

```lisp
;; 事件类型
+event-type-input+      ; 外部输入
+event-type-output+     ; 步骤输出
+event-type-external+   ; 外部系统事件
+event-type-approval+   ; 人工审批
+event-type-timeout+    ; 超时
+event-type-error+      ; 错误
+event-type-cancel+     ; 取消

;; 创建事件
(make-event :type :external
            :name "data-ready"
            :data '(:file "data.csv")
            :source "external-system")

;; 事件总线
(defvar *bus* (make-event-bus))

;; 订阅事件
(event-bus-subscribe *bus* :approval
  (lambda (event)
    (format t "收到审批: ~A~%" (event-data event))))

;; 发布事件
(event-bus-publish *bus*
  (make-event :type :approval :data t))
```

### 步骤 (Step)

```lisp
;; 定义步骤
(defstep process-data (:input data :context ctx)
  :description "处理数据"
  :timeout 60
  :retry (:max-attempts 3 :backoff :exponential)
  :wait-for (:data-ready)
  :handler
  (let ((result (analyze data)))
    (step-completed :output result)))

;; 或手动创建
(make-step "validate"
  :description "验证输入"
  :handler (lambda (ctx input)
             (if (valid-p input)
                 (step-completed :output input)
                 (step-failed "Invalid input")))
  :timeout 30)

;; 步骤结果
(step-completed :output result)           ; 成功
(step-failed error)                       ; 失败
(step-waiting :events '(:approval))       ; 等待事件
(step-skipped :reason "Condition not met") ; 跳过
```

### 状态机 (State Machine)

```lisp
;; 创建状态机
(defvar *sm*
  (-> (state-machine-builder)
      (with-state :idle :initial t)
      (with-state :running)
      (with-state :paused)
      (with-state :completed)
      (with-state :failed)
      (with-transition-rule :idle :running :on :start)
      (with-transition-rule :running :paused :on :pause)
      (with-transition-rule :running :completed :on :complete)
      (with-transition-rule :paused :running :on :resume)))

;; 触发转换
(state-machine-trigger *sm* :start context)
(state-machine-current-state *sm*)  ; => :running

;; 检查是否可触发
(state-machine-can-trigger-p *sm* :pause context)
```

### Human-in-the-Loop

```lisp
;; 创建管理器
(defvar *hlm*
  (make-human-loop-manager
    :on-request (lambda (req)
                  (format t "需要输入: ~A~%" (input-request-prompt req)))
    :on-response (lambda (resp)
                   (format t "收到响应: ~A~%" (input-response-value resp)))))

;; 请求输入（阻塞）
(let ((response (wait-for-text *hlm* "请输入您的姓名："
                               :timeout 60)))
  (format t "您好，~A！~%" (input-response-value response)))

;; 请求审批
(if (wait-for-approval *hlm* "是否批准此操作？"
                       :description "这将修改数据库"
                       :timeout 300)
    (execute-operation)
    (cancel-operation))

;; 请求选择
(let ((choice (wait-for-choice *hlm* "选择处理方式："
                               '("快速处理" "标准处理" "详细处理"))))
  (process-with-mode choice))

;; 异步请求
(human-loop-request-input-async *hlm* request
  (lambda (response)
    (handle-response response)))

;; 提交响应（从外部）
(human-loop-submit-response *hlm*
  (make-input-response request-id
    :value "用户输入"
    :approved-p t))
```

### 流程定义 (Process)

```lisp
;; 使用宏定义流程
(defprocess document-approval
  :description "文档审批流程"
  :version "1.0.0"

  :steps
  ((submit
    :description "提交文档"
    :handler (lambda (ctx input)
               (context-set-variable ctx :document input)
               (step-completed :output input)))

   (review
    :description "审核文档"
    :wait-for (:approval)
    :timeout 86400  ; 24小时
    :handler (lambda (ctx input)
               (let ((approved (context-get-variable ctx :approval-result)))
                 (if approved
                     (step-completed :output input
                                     :next-step "publish")
                     (step-completed :output input
                                     :next-step "revise")))))

   (revise
    :description "修改文档"
    :wait-for (:revision)
    :handler (lambda (ctx input)
               (step-completed :output (context-get-variable ctx :revised-doc)
                               :next-step "review")))

   (publish
    :description "发布文档"
    :handler (lambda (ctx input)
               (publish-document input)
               (step-completed :output input))))

  :on-event
  ((:approval . (lambda (ctx event)
                  (context-set-variable ctx :approval-result
                    (event-data event))))
   (:revision . (lambda (ctx event)
                  (context-set-variable ctx :revised-doc
                    (event-data event)))))

  :on-complete (lambda (ctx result)
                 (log-info "文档已发布")))
```

### 运行时 (Runtime)

```lisp
;; 创建运行时
(defvar *runtime*
  (make-process-runtime document-approval
    :on-step-start (lambda (ctx step)
                     (format t "开始步骤: ~A~%" (step-name step)))
    :on-step-complete (lambda (ctx step result)
                        (format t "完成步骤: ~A -> ~A~%"
                                (step-name step)
                                (step-result-status result)))
    :human-handler (lambda (request)
                     ;; 发送到 UI
                     (send-to-ui request))))

;; 启动流程
(runtime-start *runtime* :input document :async t)

;; 注入外部事件
(runtime-inject-event *runtime*
  (make-event :type :approval
              :data t
              :source "manager"))

;; 暂停/恢复
(runtime-pause *runtime*)
(runtime-resume *runtime*)

;; 获取状态
(runtime-get-state *runtime*)
;; => (:state :waiting
;;     :current-step "review"
;;     :pending-inputs 1
;;     :history-count 5)

;; 获取待处理的人工输入
(runtime-get-pending-inputs *runtime*)

;; 提交人工输入响应
(runtime-submit-input *runtime*
  (make-input-response request-id :value "approved" :approved-p t))

;; 停止流程
(runtime-stop *runtime*)
```

## 完整示例

### 数据处理流程（带审批）

```lisp
(defprocess data-pipeline
  :description "数据处理管道"
  :timeout 3600  ; 1小时总超时

  :steps
  ((validate
    :description "验证输入数据"
    :handler (lambda (ctx input)
               (if (validate-data input)
                   (step-completed :output input)
                   (step-failed "数据验证失败"))))

   (transform
    :description "转换数据"
    :handler (lambda (ctx input)
               (step-completed :output (transform-data input))))

   (review
    :description "人工审核"
    :wait-for (:review-complete)
    :timeout 1800  ; 30分钟
    :handler (lambda (ctx input)
               (let ((approved (context-get-variable ctx :review-approved)))
                 (if approved
                     (step-completed :output input)
                     (step-failed "审核未通过")))))

   (load
    :description "加载到数据库"
    :handler (lambda (ctx input)
               (load-to-database input)
               (step-completed :output {:status "loaded"}))))

  :on-event
  ((:review-complete . (lambda (ctx event)
                         (context-set-variable ctx :review-approved
                           (getf (event-data event) :approved))))))

;; 使用
(let ((runtime (make-process-runtime data-pipeline
                 :human-handler #'send-review-request)))

  ;; 启动
  (runtime-start runtime :input raw-data :async t)

  ;; 等待审核步骤...
  ;; 用户在 UI 上审核后提交

  ;; 注入审核结果
  (runtime-inject-event runtime
    (make-event :type :review-complete
                :data '(:approved t :comment "数据正确"))))
```

### 与 SimpleAgent 集成

ProcessAgent 已原生集成 core/process 框架：

```lisp
;; 创建带事件和人工介入支持的 ProcessAgent
(defvar *agent*
  (cl-agent.simpleagent:make-process-agent *kernel*
    :name "event-driven-agent"
    :event-handlers
    (list (cons :approval
                (lambda (event)
                  (format t "审批事件: ~A~%" (event-data event)))))
    :human-handler
    (lambda (request)
      (format t "需要输入: ~A~%" (input-request-prompt request)))))

;; 启动 Agent
(cl-agent.simpleagent:agent-start *agent*)

;; 注入外部事件 (类似 C# Process Framework)
(cl-agent.simpleagent:agent-inject-event *agent*
  (make-event :type :external
              :name "data-ready"
              :data '(:file "data.csv")))

;; 请求人工审批
(let ((request (make-input-request
                 :type :approval
                 :prompt "是否继续？")))
  (cl-agent.simpleagent:agent-request-input *agent* request))

;; 提交人工响应
(cl-agent.simpleagent:agent-submit-input *agent*
  (make-input-response request-id :approved-p t))
```

使用步骤流程：

```lisp
;; 定义流程
(defprocess my-workflow
  :description "我的工作流"
  :steps
  ((step-1 :handler (lambda (ctx input) (step-completed :output input)))
   (step-2 :wait-for (:approval) :handler ...)))

;; 创建带流程的 Agent
(defvar *workflow-agent*
  (cl-agent.simpleagent:make-process-agent *kernel*
    :process my-workflow))

(cl-agent.simpleagent:agent-start *workflow-agent*)
(cl-agent.simpleagent:agent-start-process *workflow-agent* :input data)
```

## API 摘要

### Event
- `make-event` - 创建事件
- `event-bus-subscribe` - 订阅事件
- `event-bus-publish` - 发布事件

### Step
- `make-step` / `defstep` - 创建步骤
- `step-completed` - 成功结果
- `step-failed` - 失败结果
- `step-waiting` - 等待结果

### State Machine
- `make-state-machine` - 创建状态机
- `state-machine-trigger` - 触发转换
- `with-state` / `with-transition-rule` - 构建器

### Human Loop
- `make-human-loop-manager` - 创建管理器
- `wait-for-text/confirmation/choice/approval` - 便捷函数
- `human-loop-submit-response` - 提交响应

### Process
- `make-process` / `defprocess` - 定义流程
- `process-add-step` - 添加步骤
- `process-add-event-handler` - 添加事件处理器

### Runtime
- `make-process-runtime` - 创建运行时
- `runtime-start/stop/pause/resume` - 生命周期控制
- `runtime-inject-event` - 注入事件
- `runtime-submit-input` - 提交人工输入
- `runtime-get-state` - 获取状态
