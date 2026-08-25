;;;; model.lisp
;;;; CL-Agent Chat - ChatModel 协议 + Provider 适配器
;;;;
;;;; 概述（对标 Spring AI 2.0 ChatModel / StreamingChatModel）：
;;;;
;;;;   chat-model-call (model prompt) → chat-response      —— ChatModel#call
;;;;   chat-model-stream (model prompt on-chunk) → 最终响应 —— StreamingChatModel#stream
;;;;
;;;;   provider-chat-model 把实现了 cl-agent/core:llm-chat SPI 的任意
;;;;   provider（Anthropic/OpenAI/智谱/MiniMax/Mock...）适配为 ChatModel。
;;;;
;;;; 2.0 架构变更（对齐 Spring AI 2.0 GA）：
;;;;   ChatModel 只负责单次模型调用——解析工具引用并向模型注入工具
;;;;   schema，但**不执行工具**。工具执行循环上移到
;;;;   cl-agent/core:run-tool-loop（由 invoke-turn 驱动，ChatClient
;;;;   经 chat-client 自动走到）。1.x 的 internal-tool-execution-enabled
;;;;   选项已随之移除。
;;;;
;;;;   直接使用 chat-model-call 且响应携带 tool-calls 时，调用方自行
;;;;   决定处理方式（对标 user-controlled tool execution）：
;;;;     (execute-tool-calls manager prompt response)
;;;;     → tool-execution-result → 用 conversation-history 组新 prompt 再调。

(in-package #:cl-agent/core)

;;; ============================================================
;;; 条件
;;; ============================================================

(define-condition max-tool-iterations-exceeded-error (error)
  ((limit :initarg :limit :reader max-tool-iterations-limit))
  (:report (lambda (condition stream)
             (format stream "工具执行循环超过最大轮数 ~A"
                     (max-tool-iterations-limit condition)))))

;;; ============================================================
;;; ChatModel 协议
;;; ============================================================

;;; ============================================================
;;; 重试策略（ChatModel 层能力）
;;; ============================================================
;;; 重试属于 ChatModel、不属于 provider：provider 只管「底层信息 +
;;; 如何调用」（端点、鉴权、请求体格式、响应解析），一次调用失败要不要
;;; 再来一次是模型层的编排决策——同一个 provider 在不同 ChatModel 实例
;;; 下可以配不同重试预算。对标 Spring AI 把 RetryTemplate 交给
;;; XxxChatModel 而非 XxxApi。
;;;
;;; 此前重试活在 llm/client.lisp 的 chat-with-retry 里，而那是 client 类
;;; 的路径——chat-client 主干走 chat-model-call，完全不经过它，于是整条
;;; 主干无重试。client 类已随本次重构退役。

(defclass retry-policy ()
  ((max-attempts
    :initarg :max-attempts
    :initform 3
    :type fixnum
    :reader retry-policy-max-attempts
    :documentation "总尝试次数（含首次）。1 = 不重试。")
   (initial-delay
    :initarg :initial-delay
    :initform 1.0
    :type number
    :reader retry-policy-initial-delay
    :documentation "首次重试前的延迟（秒）")
   (backoff
    :initarg :backoff
    :initform 2.0
    :type number
    :reader retry-policy-backoff
    :documentation "退避倍数：第 N 次重试延迟 = initial-delay * backoff^(N-1)")
   (max-delay
    :initarg :max-delay
    :initform 60.0
    :type number
    :reader retry-policy-max-delay
    :documentation "单次延迟上限（秒）")
   (jitter
    :initarg :jitter
    :initform 0.1
    :type number
    :reader retry-policy-jitter
    :documentation "抖动比例（0 = 关闭）。实际延迟在 ±jitter 内随机浮动，
避免多个并发调用在同一时刻重试打爆上游。")
   (retryable-p
    :initarg :retryable-p
    :initform #'error-retryable-p
    :reader retry-policy-retryable-p
    :documentation "(condition) → boolean。缺省 error-retryable-p——
分类的单一来源在 core/conditions.lisp，不要在这里另立一套。")
   (on-retry
    :initarg :on-retry
    :initform nil
    :reader retry-policy-on-retry
    :documentation "(condition attempt delay) → nil。每次决定重试前调用（日志/指标）。"))
  (:documentation "ChatModel 的重试策略。nil 策略 = 不重试。"))

(defun make-retry-policy (&key (max-attempts 3) (initial-delay 1.0) (backoff 2.0)
                               (max-delay 60.0) (jitter 0.1)
                               (retryable-p #'error-retryable-p) on-retry)
  "创建重试策略。

  (make-retry-policy :max-attempts 4 :initial-delay 0.5)
    → 最多 4 次尝试，延迟 0.5 / 1.0 / 2.0 秒（各带 ±10% 抖动）"
  (make-instance 'retry-policy
                 :max-attempts max-attempts :initial-delay initial-delay
                 :backoff backoff :max-delay max-delay :jitter jitter
                 :retryable-p retryable-p :on-retry on-retry))

(definvariants retry-policy (self)
  ;; 这些数值直接决定退避行为，写反了不会报错、只会表现为「重试太密」或
  ;; 「一次都不重试」。max-attempts 是**总**尝试次数（含首次），所以 0 无意义。
  (require-that self (>= (retry-policy-max-attempts self) 1)
                "max-attempts 是总尝试次数（含首次），至少为 1；1 = 不重试")
  (require-that self (>= (retry-policy-initial-delay self) 0)
                "initial-delay 不能为负")
  (require-that self (>= (retry-policy-backoff self) 1)
                "backoff 是退避倍数，小于 1 会让延迟越retry越短")
  (require-that self (>= (retry-policy-max-delay self)
                         (retry-policy-initial-delay self))
                "max-delay 不能小于 initial-delay，否则首次重试就被封顶")
  (require-that self (<= 0 (retry-policy-jitter self) 1)
                "jitter 是比例，取值 [0, 1]")
  (require-callable self 'retryable-p "(condition) → boolean")
  (require-callable self 'on-retry "(condition attempt delay) → nil"))

(defmethod print-object ((policy retry-policy) stream)
  (print-unreadable-object (policy stream :type t)
    (format stream "~Ax ~,2Fs^~,1F"
            (retry-policy-max-attempts policy)
            (retry-policy-initial-delay policy)
            (retry-policy-backoff policy))))

(defun retry-policy-delay-for (policy attempt)
  "第 ATTEMPT 次重试（从 1 起）前应等待的秒数。"
  (let* ((base (* (retry-policy-initial-delay policy)
                  (expt (retry-policy-backoff policy) (1- attempt))))
         (capped (min base (retry-policy-max-delay policy)))
         (jitter (retry-policy-jitter policy)))
    (if (plusp jitter)
        ;; ±jitter：random 给 [0, 2j)，减去 j 得 [-j, +j)
        (max 0 (+ capped (* capped (- (random (* 2.0 jitter)) jitter))))
        capped)))

(defun call-with-retry (policy thunk)
  "按 POLICY 反复调用 THUNK 直到成功或判定不可重试。

  POLICY 为 nil 时直接调用一次（零开销路径）。"
  (if (null policy)
      (funcall thunk)
      (let ((max-attempts (retry-policy-max-attempts policy))
            (retryable (retry-policy-retryable-p policy))
            (on-retry (retry-policy-on-retry policy)))
        (loop for attempt from 1
              do (handler-case
                     (return (funcall thunk))
                   (error (c)
                     ;; 最后一次尝试、或分类判定不可重试 → 原样抛出。
                     ;; 不包装成新条件：调用方按 error-retryable-p 的
                     ;; 同一套分类做决策，换了类型就断了。
                     (when (or (>= attempt max-attempts)
                               (not (funcall retryable c)))
                       (error c))
                     (let ((delay (retry-policy-delay-for policy attempt)))
                       (when on-retry
                         (funcall on-retry c attempt delay))
                       (sleep delay))))))))

;;; ============================================================
;;; ChatModel 协议
;;; ============================================================

(defclass chat-model ()
  ((retry-policy
    :initarg :retry-policy
    :initform nil
    :reader chat-model-retry-policy
    :documentation "retry-policy 实例，nil = 不重试。
由 chat-model-call / chat-model-stream 的 :around 方法统一施加，
所有子类自动继承，不需要各自实现。")
   (observation-fn
    :initarg :observation-fn
    :initform nil
    :reader chat-model-observation-fn
    :documentation "观测钩子：(model prompt thunk) → response。
包住**含重试的整次调用**（不是每次尝试），所以记到的是一次逻辑调用的
总耗时与最终结果。nil = 不观测（零开销）。"))
  (:documentation "ChatModel 协议基类（对标 Spring AI ChatModel）。

  职责边界：单次模型调用范围内的全部重活——options 解析合并、重试、
  观测、响应规范化、流式聚合。**不含**工具循环：那在 ChatClient 层
  （run-tool-loop，对标 Spring AI 的 ToolCallingAdvisor）。

  provider 只负责底层信息与如何调用，不参与以上任何一项。"))

(defgeneric chat-model-call (model prompt)
  (:documentation "同步调用模型（单次，不执行工具）。

参数：
  MODEL  - chat-model 实例
  PROMPT - prompt 实例（或字符串/消息列表，自动包装）

返回：
  chat-response 实例（可能携带 tool-calls，由上层
  cl-agent/core:run-tool-loop 或调用方处理）"))

(defgeneric chat-model-stream (model prompt on-chunk)
  (:documentation "流式调用模型（单次，不执行工具）。

参数：
  MODEL    - chat-model 实例
  PROMPT   - prompt 实例
  ON-CHUNK - 回调 (delta-text)，每个文本增量调用一次

返回：
  最终 chat-response 实例

默认实现降级为一次性调用（完整文本作为单个 chunk 回调）。"))

(defgeneric chat-model-default-options (model)
  (:documentation "模型的默认 chat-options（可为 NIL）"))

(defmethod chat-model-default-options ((model chat-model))
  nil)

;;; 便捷：接受字符串 / 消息列表
(defmethod chat-model-call ((model chat-model) (prompt string))
  (chat-model-call model (make-prompt prompt)))

(defmethod chat-model-call ((model chat-model) (prompt list))
  (chat-model-call model (make-prompt prompt)))

(defmethod chat-model-stream ((model chat-model) (prompt string) on-chunk)
  (chat-model-stream model (make-prompt prompt) on-chunk))

(defmethod chat-model-stream ((model chat-model) (prompt list) on-chunk)
  (chat-model-stream model (make-prompt prompt) on-chunk))

;;; 默认流式实现：降级为一次性调用
(defmethod chat-model-stream ((model chat-model) (prompt prompt) on-chunk)
  (let ((response (chat-model-call model prompt)))
    (funcall on-chunk (chat-response-text response))
    response))

;;; ============================================================
;;; 横切：重试 + 观测（:around，全部子类自动继承）
;;; ============================================================
;;; 用方法组合而非在每个实现里手写：新增一个 ChatModel 子类不需要
;;; 记得调重试封装，也不可能漏。
;;;
;;; 只特化 (chat-model prompt)——string / list 的便捷方法会重新分派到
;;; prompt 版本，:around 在那一次触发，不会叠加两层重试。

(defun %observe-model-call (model prompt thunk)
  "把 THUNK 交给 MODEL 的观测钩子；无钩子则直接调用。"
  (let ((observe (chat-model-observation-fn model)))
    (if observe
        (funcall observe model prompt thunk)
        (funcall thunk))))

(defmethod chat-model-call :around ((model chat-model) (prompt prompt))
  "施加观测（外）+ 重试（内）。

顺序是刻意的：观测包住含重试的整次调用，记到的是一次逻辑调用的总耗时
与最终结果，而不是每次尝试各记一条。要按尝试观测就用 retry-policy 的
:on-retry。"
  (%observe-model-call
   model prompt
   (lambda ()
     (call-with-retry (chat-model-retry-policy model)
                      (lambda () (call-next-method))))))

(defmethod chat-model-stream :around ((model chat-model) (prompt prompt) on-chunk)
  "流式调用的重试 + 观测。

  注意重试语义的边界：**已经吐给 on-chunk 的 token 不会被撤回**。
  重试只对「连接建立/首字节之前就失败」的情形有意义；流跑到一半断掉再重
  试，调用方会看到前半段 token 出现两次。所以流式路径通常应把
  retry-policy 配成 nil 或 max-attempts=1，除非调用方自己能处理重复前缀。"
  (%observe-model-call
   model prompt
   (lambda ()
     (call-with-retry (chat-model-retry-policy model)
                      (lambda () (call-next-method))))))

;;; ============================================================
;;; Provider 适配器
;;; ============================================================

(defclass provider-chat-model (chat-model)
  ((provider
    :initarg :provider
    :reader chat-model-provider
    :documentation "实现 cl-agent/core:llm-chat 的 provider 实例")
   (default-options
    :initarg :default-options
    :initform nil
    :reader %model-default-options
    :documentation "模型级默认 chat-options"))
  (:documentation "把 llm-chat SPI provider 适配为 ChatModel（单次调用）"))

(defun make-provider-chat-model (provider &key default-options
                                               retry-policy observation-fn)
  "创建 provider 适配的 ChatModel。

参数：
  PROVIDER        - 实现 llm-chat 泛型函数的 provider 实例
  DEFAULT-OPTIONS - 模型级默认 chat-options（可选）
  RETRY-POLICY    - retry-policy 实例（可选）。nil = 不重试。
  OBSERVATION-FN  - 观测钩子 (model prompt thunk) → response（可选）

示例：
  (make-provider-chat-model
    (cl-agent/llm:make-anthropic-provider)
    :default-options (make-chat-options :temperature 0.3)
    :retry-policy (make-retry-policy :max-attempts 4))"
  (make-instance 'provider-chat-model
                 :provider provider
                 :default-options default-options
                 :retry-policy retry-policy
                 :observation-fn observation-fn))

(definvariants provider-chat-model (self)
  (require-slot self 'provider "适配的目标——没有它这个 ChatModel 无处可调"))

(definvariants chat-model (self)
  ;; 基类不变式：所有子类继承。观测钩子给错类型时，直到第一次调用才炸。
  (require-type self 'retry-policy 'retry-policy)
  (require-callable self 'observation-fn "(model prompt thunk) → response"))

(defmethod chat-model-default-options ((model provider-chat-model))
  (%model-default-options model))

(defmethod print-object ((model provider-chat-model) stream)
  (print-unreadable-object (model stream :type t)
    (format stream "~A" (type-of (chat-model-provider model)))))

;;; ============================================================
;;; 调用实现（单次，无工具循环）
;;; ============================================================

(defun resolved-options-tools (options)
  "从合并后的选项解析出全部 tool-callback"
  (append (chat-options-tool-callbacks options)
          (resolve-tool-callbacks (chat-options-tool-names options))))

(defun options->spi-args (options)
  "把 chat-options 展开为 llm-chat SPI 的关键字参数 plist
（存在才下发，与 SPI 的\"存在才发送\"约定一致）"
  (let ((args nil))
    (flet ((add (key value)
             (when value
               (push value args)
               (push key args))))
      (add :model (chat-options-model options))
      (add :max-tokens (chat-options-max-tokens options))
      (add :temperature (chat-options-temperature options))
      (add :top-p (chat-options-top-p options))
      (add :top-k (chat-options-top-k options))
      (add :stop (chat-options-stop-sequences options))
      (add :frequency-penalty (chat-options-frequency-penalty options))
      (add :presence-penalty (chat-options-presence-penalty options))
      (add :thinking (chat-options-thinking options))
      (add :extra-params (chat-options-extra-params options)))
    args))

(defmethod chat-model-call ((model provider-chat-model) (prompt prompt))
  "单次模型调用：注入工具 schema，不执行工具。"
  (let* ((options (merge-chat-options (prompt-options prompt)
                                      (chat-model-default-options model)))
         (schemas (mapcar #'tool-callback->schema
                          (resolved-options-tools options)))
         (llm-response (apply #'llm-chat (chat-model-provider model)
                              (messages->neutral (prompt-messages prompt))
                              :tools schemas
                              (options->spi-args options))))
    (llm-response->chat-response llm-response)))

;;; ============================================================
;;; 流式实现（单次；流处理器支持 tool_calls 分片累积）
;;; ============================================================

(defmethod chat-model-stream ((model provider-chat-model) (prompt prompt) on-chunk)
  (let* ((options (merge-chat-options (prompt-options prompt)
                                      (chat-model-default-options model)))
         (schemas (mapcar #'tool-callback->schema
                          (resolved-options-tools options)))
         (provider (chat-model-provider model)))
    (if (not (provider-supports-streaming-p provider))
        ;; provider 不支持流式：降级为一次性调用
        (let ((response (chat-model-call model prompt)))
          (funcall on-chunk (chat-response-text response))
          response)
        ;; 真流式（含工具 schema：tool-calls 由流处理器分片累积）
        (let ((llm-response
                (apply #'llm-chat-stream provider
                       (messages->neutral (prompt-messages prompt))
                       (lambda (chunk)
                         (let ((delta (getf chunk :delta)))
                           (when (and delta (string/= delta ""))
                             (funcall on-chunk delta))))
                       :tools schemas
                       (options->spi-args options))))
          (llm-response->chat-response llm-response)))))
