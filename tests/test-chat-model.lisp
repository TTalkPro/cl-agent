;;;; test-chat-model.lisp
;;;; CL-Agent - ChatModel 协议与内部工具执行循环测试

(in-package :cl-agent/tests)

(def-suite chat-model-suite :in cl-agent-suite
  :description "ChatModel 协议、Provider 适配器与工具执行循环")

(in-suite chat-model-suite)

;;; ============================================================
;;; 基本调用
;;; ============================================================

(test model-simple-call
  "简单调用返回 chat-response"
  (let* ((provider (make-seq-provider (text-response "你好！")))
         (model (cl-agent/core:make-provider-chat-model provider))
         (response (cl-agent/core:chat-model-call model "你好")))
    (is (typep response 'cl-agent/core:chat-response))
    (is (string= "你好！" (cl-agent/core:chat-response-text response)))
    (is (eq :stop (cl-agent/core:chat-response-finish-reason response)))))

(test model-accepts-prompt-string-list
  "chat-model-call 接受字符串 / 消息列表 / prompt"
  (let ((make-model (lambda ()
                      (cl-agent/core:make-provider-chat-model
                       (make-seq-provider (text-response "ok"))))))
    (is (string= "ok" (cl-agent/core:chat-response-text
                       (cl-agent/core:chat-model-call (funcall make-model) "hi"))))
    (is (string= "ok" (cl-agent/core:chat-response-text
                       (cl-agent/core:chat-model-call
                        (funcall make-model)
                        (list (cl-agent/core:user-message "hi"))))))
    (is (string= "ok" (cl-agent/core:chat-response-text
                       (cl-agent/core:chat-model-call
                        (funcall make-model)
                        (cl-agent/core:make-prompt "hi")))))))

(test model-metadata-passthrough
  "usage / model 元数据透传"
  (let* ((provider (make-seq-provider (text-response "ok")))
         (model (cl-agent/core:make-provider-chat-model provider))
         (response (cl-agent/core:chat-model-call model "hi"))
         (usage (cl-agent/core:chat-response-usage response)))
    (is (= 10 (cl-agent/core:llm-usage-input-tokens usage)))
    (is (string= "seq-model"
                 (cl-agent/core:response-metadata-model
                  (cl-agent/core:chat-response-metadata-of response))))))

;;; ============================================================
;;; 选项合并与下发
;;; ============================================================

(test model-options-merged-to-provider
  "默认选项与运行时选项合并后下发 provider"
  (let* ((provider (make-seq-provider (text-response "ok")))
         (model (cl-agent/core:make-provider-chat-model
                 provider
                 :default-options (cl-agent/core:make-chat-options
                                   :max-tokens 100 :temperature 0.9))))
    (cl-agent/core:chat-model-call
     model (cl-agent/core:make-prompt
            "hi" :options (cl-agent/core:make-chat-options :temperature 0.2)))
    (let ((request (first (seq-provider-requests provider))))
      ;; 运行时覆盖默认
      (is (= 0.2 (getf request :temperature)))
      ;; 未覆盖沿用默认
      (is (= 100 (getf request :max-tokens))))))

(test model-system-message-folded
  "system-message 折叠进中立消息列表"
  (let* ((provider (make-seq-provider (text-response "ok")))
         (model (cl-agent/core:make-provider-chat-model provider)))
    (cl-agent/core:chat-model-call
     model (cl-agent/core:make-prompt "hi" :system "你是助手"))
    (let ((messages (getf (first (seq-provider-requests provider)) :messages)))
      (is (eq :system (getf (first messages) :role)))
      (is (string= "你是助手" (getf (first messages) :content))))))

;;; ============================================================
;;; 单次调用语义（2.0：ChatModel 不执行工具）
;;; ============================================================

(test model-injects-tool-schema
  "工具引用解析为 schema 下发 provider（但不执行）"
  (let* ((provider (make-seq-provider (text-response "ok")))
         (model (cl-agent/core:make-provider-chat-model provider)))
    (cl-agent/core:chat-model-call
     model (cl-agent/core:make-prompt
            "hi" :options (cl-agent/core:make-chat-options
                           :tool-names '(test-adder))))
    (let ((tools (getf (first (seq-provider-requests provider)) :tools)))
      (is (= 1 (length tools)))
      (is (string= "test_adder" (getf (first tools) :name))))))

(test model-returns-tool-calls-as-is
  "携带 tool-calls 的响应原样返回（工具循环属于 run-tool-loop）"
  (let* ((provider (make-seq-provider
                    (tool-call-response "test_adder" '(("a" . 1) ("b" . 1)))))
         (model (cl-agent/core:make-provider-chat-model provider))
         (response (cl-agent/core:chat-model-call
                    model (cl-agent/core:make-prompt
                           "1+1=?"
                           :options (cl-agent/core:make-chat-options
                                     :tool-names '(test-adder))))))
    (is-true (cl-agent/core:chat-response-has-tool-calls-p response))
    ;; 只调用一轮：ChatModel 不执行工具
    (is (= 1 (length (seq-provider-requests provider))))))

;;; ============================================================
;;; 流式
;;; ============================================================

(test model-stream-fallback
  "不支持流式的 provider 降级为一次性回调"
  (let* ((provider (make-seq-provider (text-response "完整内容")))
         (model (cl-agent/core:make-provider-chat-model provider))
         (chunks nil)
         (response (cl-agent/core:chat-model-stream
                    model "hi" (lambda (delta) (push delta chunks)))))
    (is (equal '("完整内容") (reverse chunks)))
    (is (string= "完整内容" (cl-agent/core:chat-response-text response)))))

;;; ============================================================
;;; 重试策略（ChatModel 层能力）
;;; ============================================================
;;; 重试是 ChatModel 的职责、不是 provider 的：provider 只管「底层信息 +
;;; 如何调用」。此前重试活在 llm/client.lisp 的 chat-with-retry 里，而
;;; chat-client 主干走 chat-model-call，完全不经过它——整条主干无重试。
;;; 下面这组测试钉的就是「主干确实重试」。

(defclass counting-chat-model (cl-agent/core:chat-model)
  ((fail-times :initarg :fail-times :initform 0 :accessor counting-model-fail-times
               :documentation "还要失败几次")
   (calls :initform 0 :accessor counting-model-calls
          :documentation "被真正调到的次数（:around 之内）"))
  (:documentation "直接继承 chat-model 的测试用子类——不经 provider 适配，
用来验证重试/观测的 :around 对任意子类都自动生效。"))

(defmethod cl-agent/core:chat-model-call ((model counting-chat-model)
                                          (prompt cl-agent/core:prompt))
  (incf (counting-model-calls model))
  (if (plusp (counting-model-fail-times model))
      (progn (decf (counting-model-fail-times model))
             (error 'cl-agent/core:llm-error :message "boom" :status-code 503))
      (cl-agent/core:make-chat-response
       (cl-agent/core:make-generation
        (cl-agent/core:assistant-message "子类响应")
        :finish-reason :stop))))

(defun %failing-then (n-failures response &key (status 503))
  "构造 seq-provider 队列：前 N 次抛可重试错误，第 N+1 次返回 RESPONSE。"
  (append (loop repeat n-failures
                collect (lambda (messages)
                          (declare (ignore messages))
                          (error 'cl-agent/core:llm-error
                                 :message "boom" :status-code status)))
          (list response)))

(defun %fast-policy (&rest args)
  "延迟极小的重试策略——测试不该为退避真的睡半秒。"
  (apply #'cl-agent/core:make-retry-policy
         :initial-delay 0.001 :backoff 1.0 :jitter 0 args))

(test retry-policy-nil-means-no-retry
  "不配 retry-policy = 一次也不重试（缺省行为，零开销路径）"
  (let* ((provider (apply #'make-seq-provider
                          (%failing-then 1 (text-response "never reached"))))
         (model (cl-agent/core:make-provider-chat-model provider)))
    (signals cl-agent/core:llm-error
      (cl-agent/core:chat-model-call model "hi"))
    ;; provider 只被调用一次——没有第二次尝试
    (is (= 1 (length (seq-provider-requests provider))))))

(test retry-recovers-from-transient-error
  "瞬态错误（503）重试后成功，返回的是成功那次的响应"
  (let* ((provider (apply #'make-seq-provider
                          (%failing-then 2 (text-response "终于成功"))))
         (model (cl-agent/core:make-provider-chat-model
                 provider :retry-policy (%fast-policy :max-attempts 3)))
         (response (cl-agent/core:chat-model-call model "hi")))
    (is (string= "终于成功" (cl-agent/core:chat-response-text response)))
    ;; 2 次失败 + 1 次成功 = 3 次真实调用
    (is (= 3 (length (seq-provider-requests provider))))))

(test retry-gives-up-after-max-attempts
  "耗尽 max-attempts 后抛出——次数是「总尝试」而非「额外重试」"
  (let* ((provider (apply #'make-seq-provider
                          (%failing-then 5 (text-response "unreachable"))))
         (model (cl-agent/core:make-provider-chat-model
                 provider :retry-policy (%fast-policy :max-attempts 3))))
    (signals cl-agent/core:llm-error
      (cl-agent/core:chat-model-call model "hi"))
    (is (= 3 (length (seq-provider-requests provider))))))

(test retry-skips-non-retryable-error
  "400 参数错不重试：分类由 error-retryable-p 单一裁定，重试层不另立规则"
  (let* ((provider (apply #'make-seq-provider
                          (%failing-then 3 (text-response "unreachable")
                                         :status 400)))
         (model (cl-agent/core:make-provider-chat-model
                 provider :retry-policy (%fast-policy :max-attempts 5))))
    (signals cl-agent/core:llm-error
      (cl-agent/core:chat-model-call model "hi"))
    (is (= 1 (length (seq-provider-requests provider))))))

(test retry-preserves-original-condition-type
  "重试耗尽后抛出的仍是原始条件，不被包装。

包装成新类型会断掉调用方的分类——上层（如 batch 的故障路由）用的是
同一套 error-retryable-p / typecase。"
  (let* ((provider (apply #'make-seq-provider
                          (%failing-then 3 (text-response "x"))))
         (model (cl-agent/core:make-provider-chat-model
                 provider :retry-policy (%fast-policy :max-attempts 2))))
    (handler-case (progn (cl-agent/core:chat-model-call model "hi") (fail "应当抛出"))
      (cl-agent/core:llm-error (c)
        (is (= 503 (cl-agent/core:api-status-code c)))))))

(test retry-on-retry-callback-fires-per-attempt
  ":on-retry 每次决定重试前触发一次，attempt 从 1 递增"
  (let* ((calls nil)
         (provider (apply #'make-seq-provider
                          (%failing-then 2 (text-response "ok"))))
         (model (cl-agent/core:make-provider-chat-model
                 provider
                 :retry-policy (%fast-policy
                                :max-attempts 3
                                :on-retry (lambda (c attempt delay)
                                            (declare (ignore c delay))
                                            (push attempt calls))))))
    (cl-agent/core:chat-model-call model "hi")
    ;; 两次失败 → 两次重试决定；最后一次成功不触发
    (is (equal '(1 2) (nreverse calls)))))

(test retry-delay-is-exponential-and-capped
  "退避延迟 = initial * backoff^(n-1)，受 max-delay 封顶"
  (let ((policy (cl-agent/core:make-retry-policy
                 :initial-delay 1.0 :backoff 2.0 :max-delay 5.0 :jitter 0)))
    (is (= 1.0 (cl-agent/core:retry-policy-delay-for policy 1)))
    (is (= 2.0 (cl-agent/core:retry-policy-delay-for policy 2)))
    (is (= 4.0 (cl-agent/core:retry-policy-delay-for policy 3)))
    ;; 第 4 次本应 8.0，被 max-delay 压到 5.0
    (is (= 5.0 (cl-agent/core:retry-policy-delay-for policy 4)))))

(test retry-jitter-stays-within-band
  "抖动在 ±jitter 比例内，且不为负"
  (let ((policy (cl-agent/core:make-retry-policy
                 :initial-delay 1.0 :backoff 1.0 :max-delay 60.0 :jitter 0.1)))
    (dotimes (i 50)
      (let ((d (cl-agent/core:retry-policy-delay-for policy 1)))
        (is (<= 0.9 d 1.1))))))

(test retry-around-is-inherited-by-subclasses
  "重试挂在 chat-model 基类的 :around 上——新写一个 ChatModel 子类
不需要记得调重试封装，也不可能漏。用方法组合而非在每个实现里手写，
换来的就是这条性质。"
  (let ((model (make-instance 'counting-chat-model
                              :fail-times 2
                              :retry-policy (%fast-policy :max-attempts 3))))
    (let ((response (cl-agent/core:chat-model-call model "hi")))
      (is (string= "子类响应" (cl-agent/core:chat-response-text response)))
      (is (= 3 (counting-model-calls model))))))

(test observation-fn-wraps-whole-call-including-retries
  "观测钩子包住的是「含重试的整次调用」，不是每次尝试——
一次逻辑调用记一条，按尝试观测请用 :on-retry。"
  (let* ((observed 0)
         (provider (apply #'make-seq-provider
                          (%failing-then 2 (text-response "ok"))))
         (model (cl-agent/core:make-provider-chat-model
                 provider
                 :retry-policy (%fast-policy :max-attempts 3)
                 :observation-fn (lambda (m prompt thunk)
                                   (declare (ignore m prompt))
                                   (incf observed)
                                   (funcall thunk)))))
    (cl-agent/core:chat-model-call model "hi")
    (is (= 1 observed))
    ;; 底下确实重试了 3 次
    (is (= 3 (length (seq-provider-requests provider))))))

;;; ============================================================
;;; Provider 层横切观测（:around on (t)）
;;; ============================================================

(test llm-call-observer-sees-every-provider
  "观测钩子挂在 (t) 上——覆盖每一个 provider，无论它继承自哪个基类。

llm 层的真实 provider 继承 cl-agent/llm:base-provider 而非 core 的
base-llm-provider，挂在后者上够不着它们。"
  (let* ((seen nil)
         (provider (make-seq-provider (text-response "ok")))
         (model (cl-agent/core:make-provider-chat-model provider))
         (cl-agent/core:*llm-call-observer*
           (lambda (p messages args thunk)
             (declare (ignore messages args))
             (push (type-of p) seen)
             (funcall thunk))))
    (is (string= "ok" (cl-agent/core:chat-response-text
                       (cl-agent/core:chat-model-call model "hi"))))
    (is (equal '(seq-provider) seen))))

(test llm-call-observer-counts-every-wire-call-including-retries
  "provider 钩子记的是**每次真实 wire 调用**；ChatModel 的 observation-fn
记的是**每次逻辑调用**（含重试算一条）。要算钱看前者，算延迟看后者。"
  (let* ((wire-calls 0)
         (logical-calls 0)
         (provider (apply #'make-seq-provider
                          (%failing-then 2 (text-response "ok"))))
         (model (cl-agent/core:make-provider-chat-model
                 provider
                 :retry-policy (%fast-policy :max-attempts 3)
                 :observation-fn (lambda (m prompt thunk)
                                   (declare (ignore m prompt))
                                   (incf logical-calls)
                                   (funcall thunk))))
         (cl-agent/core:*llm-call-observer*
           (lambda (p messages args thunk)
             (declare (ignore p messages args))
             (incf wire-calls)
             (funcall thunk))))
    (cl-agent/core:chat-model-call model "hi")
    (is (= 3 wire-calls) "两次失败 + 一次成功 = 3 次 wire 调用")
    (is (= 1 logical-calls) "一次逻辑调用")))

(test llm-call-observer-nil-is-zero-overhead
  "不配钩子时直接下沉——缺省路径只多一次 NIL 检查"
  (let ((provider (make-seq-provider (text-response "ok"))))
    (is (null cl-agent/core:*llm-call-observer*) "缺省为 NIL")
    (is (string= "ok" (cl-agent/core:chat-response-text
                       (cl-agent/core:chat-model-call
                        (cl-agent/core:make-provider-chat-model provider)
                        "hi"))))))

(test usage-tally-accumulates-across-calls
  "开箱即用的用量累计器：一个 let 绑定就给所有 provider 记上账"
  (let* ((tally (cl-agent/core:make-llm-usage-tally))
         (provider (make-seq-provider
                    (cl-agent/core:make-llm-response
                     :content "a" :finish-reason :stop
                     :usage (cl-agent/core:make-llm-usage
                             :input-tokens 10 :output-tokens 5))
                    (cl-agent/core:make-llm-response
                     :content "b" :finish-reason :stop
                     :usage (cl-agent/core:make-llm-usage
                             :input-tokens 7 :output-tokens 3))))
         (model (cl-agent/core:make-provider-chat-model provider))
         (cl-agent/core:*llm-call-observer*
           (cl-agent/core:usage-tally-observer tally)))
    (cl-agent/core:chat-model-call model "one")
    (cl-agent/core:chat-model-call model "two")
    (is (= 2 (cl-agent/core:usage-tally-calls tally)))
    (is (= 17 (cl-agent/core:usage-tally-input-tokens tally)))
    (is (= 8 (cl-agent/core:usage-tally-output-tokens tally)))))

(defclass tiny-stream-provider ()
  ((chunks :initarg :chunks :initform '("你" "好") :reader tiny-stream-chunks))
  (:documentation "本文件自用的流式桩。

刻意不借用 test-chat-client-invoke.lisp 里的 stream-provider：那个文件在
ASDF 序列里排在本文件之后，跨文件借用会让本文件的编译依赖倒过来——
能跑（类在运行时才解析），但把加载顺序变成了隐式约束。"))

(defmethod cl-agent/core:provider-supports-streaming-p ((p tiny-stream-provider)) t)

(defmethod cl-agent/core:llm-chat-stream ((p tiny-stream-provider) messages on-chunk
                                          &key &allow-other-keys)
  (declare (ignore messages))
  (dolist (c (tiny-stream-chunks p))
    (funcall on-chunk (list :delta c)))
  (cl-agent/core:make-llm-response
   :content (apply #'concatenate 'string (tiny-stream-chunks p))
   :finish-reason :stop))

(test llm-stream-observer-wraps-streaming-calls
  "流式也有观测钩子——与非流式是两个变量，别指望配了一个就都覆盖到。"
  (let* ((seen 0)
         (deltas nil)
         (provider (make-instance 'tiny-stream-provider))
         (model (cl-agent/core:make-provider-chat-model provider))
         (cl-agent/core:*llm-stream-observer*
           (lambda (p messages args thunk)
             (declare (ignore p messages args))
             (incf seen)
             (funcall thunk))))
    (cl-agent/core:chat-model-stream model "hi" (lambda (d) (push d deltas)))
    (is (= 1 seen) "流式钩子触发一次")
    (is (plusp (length deltas)) "增量照常送达")
    ;; 非流式钩子不该被流式调用触发
    (let ((call-seen 0))
      (let ((cl-agent/core:*llm-call-observer*
              (lambda (p m a thunk) (declare (ignore p m a)) (incf call-seen)
                (funcall thunk))))
        (cl-agent/core:chat-model-stream model "hi" (lambda (d) (declare (ignore d)))))
      (is (= 0 call-seen) "*llm-call-observer* 不管流式"))))

(test call-with-retry-is-usable-standalone
  "call-with-retry 是公开的：不走 ChatModel 也能给任意 thunk 加重试。

（ChatModel 的 :around 只是它最常见的一个使用者。）"
  (let ((attempts 0))
    ;; NIL 策略 = 直接调用一次，不吞异常
    (is (= 42 (cl-agent/core:call-with-retry nil (lambda () 42))))
    (signals cl-agent/core:llm-error
      (cl-agent/core:call-with-retry nil
        (lambda () (error 'cl-agent/core:llm-error :message "x" :status-code 503))))
    ;; 有策略：可重试错误反复尝试直到成功
    (setf attempts 0)
    (is (string= "ok"
                 (cl-agent/core:call-with-retry
                  (%fast-policy :max-attempts 3)
                  (lambda ()
                    (incf attempts)
                    (if (< attempts 3)
                        (error 'cl-agent/core:llm-error :message "boom" :status-code 503)
                        "ok")))))
    (is (= 3 attempts))))
