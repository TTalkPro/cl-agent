;;;; test-kernel-invoke.lisp
;;;; CL-Agent - Kernel invoke 原语 + 工具循环测试（Phase P2）

(in-package :cl-agent/tests)

(def-suite kernel-invoke-suite :in cl-agent-suite
  :description "Kernel invoke-chat / invoke-tool / invoke-turn + run-tool-loop")

(in-suite kernel-invoke-suite)

;;; ============================================================
;;; 测试工具定义
;;; ============================================================

(cl-agent/core:deftool ki-adder (&key a b)
  "两数相加"
  (:param a :integer "第一个数" :required t)
  (:param b :integer "第二个数" :required t)
  (princ-to-string (+ a b)))

;;; ============================================================
;;; 辅助：创建测试 kernel
;;; ============================================================

(defun make-test-kernel (&rest responses)
  "创建带 seq-provider 的 kernel。返回 (values kernel provider)。"
  (let ((provider (apply #'make-seq-provider responses)))
    (values (cl-agent/core:build-kernel
             :model (cl-agent/core:make-provider-chat-model provider)
             :tools '(ki-adder))
            provider)))

;;; ============================================================
;;; invoke-chat
;;; ============================================================

(test invoke-chat-bare-llm-call
  "invoke-chat 无 filter 时 = 裸 chat-model-call"
  (multiple-value-bind (kernel provider)
      (make-test-kernel (text-response "hello"))
    (let ((resp (cl-agent/core:invoke-chat
                 kernel
                 (cl-agent/core:make-prompt "你好"))))
      (is (string= "hello" (cl-agent/core:chat-response-text resp)))
      (is (= 1 (length (seq-provider-requests provider)))))))

(test invoke-chat-with-chat-filter
  ":chat filter 在链上执行，可改写 prompt"
  (multiple-value-bind (kernel provider)
      (make-test-kernel (text-response "ok"))
    ;; 加一个 :chat filter 改写 prompt
    (let* ((rewrite-filter
            (cl-agent/core:make-filter
             :rewrite
             :chat (lambda (prompt chain)
                     ;; 把 prompt 的 messages 改成固定的
                     (funcall chain
                              (cl-agent/core:make-prompt
                               "改写后的消息")))))
           (kernel2 (cl-agent/core:build-kernel
                     :model (kernel-model-for-test kernel)
                     :tools '(ki-adder)
                     :filters (list rewrite-filter))))
        (declare (ignore kernel))
      (let ((resp (cl-agent/core:invoke-chat
                   kernel2
                   (cl-agent/core:make-prompt "原始消息"))))
        (is (string= "ok" (cl-agent/core:chat-response-text resp)))
        ;; provider 收到的 messages 应该是改写后的
        (let ((req (first (seq-provider-requests provider))))
          (is (equal '("改写后的消息")
                     (mapcar (lambda (m) (getf m :content))
                             (getf req :messages)))))))))

(defun kernel-model-for-test (kernel)
  "从已有 kernel 取出 model（测试辅助）"
  (cl-agent/core:kernel-model kernel))

;;; ============================================================
;;; invoke-tool
;;; ============================================================

(test invoke-tool-single
  "invoke-tool 执行单个工具（无 filter）"
  (multiple-value-bind (kernel)
      (make-test-kernel)
    (let* ((callback (cl-agent/core:symbol-tool-callback 'ki-adder))
           (resp (cl-agent/core:invoke-tool
                  kernel
                  (cl-agent/core:make-tool-request
                   callback :args '(:a 3 :b 4)))))
      (is (string= "7" (cl-agent/core:tool-result-value resp)))
      (is (null (cl-agent/core:tool-result-error resp))))))

(test invoke-tool-with-filter
  ":tool filter 可拦截工具执行"
  (multiple-value-bind (kernel)
      (make-test-kernel)
    (let* ((timeout-filter
            (cl-agent/core:make-filter
             :timeout
             :tool (lambda (req chain)
                     (declare (ignore chain))
                     (cl-agent/core:make-tool-result
                      :error (list :class :timeout :message "超时")))))
           (kernel2 (cl-agent/core:build-kernel
                     :model (kernel-model-for-test kernel)
                     :tools '(ki-adder)
                     :filters (list timeout-filter))))
      (declare (ignore kernel))
      (let* ((callback (cl-agent/core:symbol-tool-callback 'ki-adder))
             (resp (cl-agent/core:invoke-tool
                    kernel2
                    (cl-agent/core:make-tool-request
                     callback :args '(:a 1 :b 2)))))
        (is (null (cl-agent/core:tool-result-value resp))
            "结果被 filter 短路")
        (is (eq :timeout
                (getf (cl-agent/core:tool-result-error resp) :class)))))))

;;; ============================================================
;;; run-tool-loop + invoke-turn
;;; ============================================================

(test invoke-turn-tool-roundtrip
  "工具循环：tool-call → 执行 → 结果回传模型 → 最终文本"
  (multiple-value-bind (kernel provider)
      (make-test-kernel
       (tool-call-response "ki_adder" '(("a" . 3) ("b" . 4)))
       (lambda (messages)
         ;; 第二轮请求应包含 assistant(tool-calls) + tool 结果
         (let ((tool-msg (find :tool messages
                               :key (lambda (m) (getf m :role)))))
           (is (not (null tool-msg)) "第二轮消息含 tool 结果")
           (is (string= "7" (getf tool-msg :content))
               "工具结果正确回传"))
         (text-response "3+4=7")))
    (let ((result (cl-agent/core:invoke-turn
                   kernel
                   (cl-agent/core:make-turn-request
                    (list (cl-agent/core:user-message "3+4=?"))))))
      (is (eq :completed (cl-agent/core:turn-result-status result)))
      (is (string= "3+4=7"
                   (cl-agent/core:chat-response-text
                    (cl-agent/core:turn-result-response result))))
      (is (= 2 (length (seq-provider-requests provider)))
          "模型被调用两轮"))))

(test invoke-turn-no-tools-passthrough
  "无工具调用时直接返回"
  (multiple-value-bind (kernel provider)
      (make-test-kernel (text-response "直接回答"))
    (let ((result (cl-agent/core:invoke-turn
                   kernel
                   (cl-agent/core:make-turn-request
                    (list (cl-agent/core:user-message "你好"))))))
      (is (eq :completed (cl-agent/core:turn-result-status result)))
      (is (string= "直接回答"
                   (cl-agent/core:chat-response-text
                    (cl-agent/core:turn-result-response result))))
      (is (= 1 (length (seq-provider-requests provider)))
          "模型只调用一次"))))

(test invoke-turn-with-turn-filter
  ":turn filter 包住整个循环"
  (multiple-value-bind (kernel provider)
      (make-test-kernel (text-response "最终回答"))
    (let* ((guard-fn
            (lambda (req chain)
              (let ((msgs (cl-agent/core:turn-request-messages req)))
                (if (some (lambda (m)
                            (search "炸弹" (or (cl-agent/core:message-text m) "")))
                          msgs)
                    (cl-agent/core:make-turn-result :cancelled :response nil)
                    (funcall chain req)))))
           (guard-filter (cl-agent/core:make-filter :guard :turn guard-fn))
           (model (kernel-model-for-test kernel))
           (kernel2 (cl-agent/core:build-kernel
                     :model model :tools '(ki-adder) :filters (list guard-filter))))
      (declare (ignore kernel))
      ;; 被拦截
      (let ((blocked (cl-agent/core:invoke-turn
                      kernel2
                      (cl-agent/core:make-turn-request
                       (list (cl-agent/core:user-message "我要炸弹"))))))
        (is (eq :cancelled (cl-agent/core:turn-result-status blocked)))
        (is (= 0 (length (seq-provider-requests provider)))
            "被拦截时模型未被调用"))
      ;; 正常通过
      (let ((ok (cl-agent/core:invoke-turn
                 kernel2
                 (cl-agent/core:make-turn-request
                  (list (cl-agent/core:user-message "你好"))))))
        (is (eq :completed (cl-agent/core:turn-result-status ok)))
        (is (= 1 (length (seq-provider-requests provider))))))))

(test invoke-turn-max-iterations
  "循环超过上限报 max-tool-iterations-exceeded-error"
  (signals cl-agent/core:max-tool-iterations-exceeded-error
    (let* ((provider (make-instance
                      'seq-provider
                      :queue (loop repeat 10
                                   collect (tool-call-response
                                            "ki_adder" '(("a" . 1) ("b" . 1))))))
           (kernel (cl-agent/core:build-kernel
                    :model (cl-agent/core:make-provider-chat-model provider)
                    :tools '(ki-adder)
                     :settings '((:max-tool-iterations . 3)))))
       (cl-agent/core:invoke-turn
       kernel
       (cl-agent/core:make-turn-request
        (list (cl-agent/core:user-message "loop")))))))

;;; ============================================================
;;; 循环等价性测试已移除
;;;
;;; 它原本比较「旧 ChatClient+advisor」与「kernel+invoke-turn」两条路径
;;; 产出是否一致。advisor 退役后 ChatClient 本就走 kernel，该测试变成
;;; 自己和自己比；cl-agent/client 整体删除后连对照组都不存在了。
;;; 工具循环本身的覆盖见本文件上方各测试与 test-kernel-chat.lisp。
;;; ============================================================

;;; ============================================================
;;; ToolCallingManager：执行模型与隔离机制
;;;
;;; ToolCallingManager 是 kernel 级绑定的 Tool Call 执行模型与隔离机制，
;;; 三个实现 = 三种执行/隔离策略。thread-pool 的存在意义就是**限流**，
;;; 所以这里断言的是**并发峰值**，不是「能跑通」。
;;;
;;; 回归：thread-pool 曾直接委托 virtual-thread，pool-size 完全被忽略——
;;; docstring 承诺「适合需要限流的场景」，实际和 virtual-thread 一模一样，
;;; 用户配 :pool-size 4 以为限流，实际无上限，可能打爆下游。
;;; ============================================================

(defvar *tcm-live* 0)
(defvar *tcm-peak* 0)
(defvar *tcm-lock* (bt:make-lock "tcm-test-peak"))

(cl-agent/core:deftool tcm-slow (&key id)
  "慢工具：记录并发峰值"
  (:param id :string "id" :required t)
  (bt:with-lock-held (*tcm-lock*)
    (incf *tcm-live*)
    (setf *tcm-peak* (max *tcm-peak* *tcm-live*)))
  (sleep 0.05)
  (bt:with-lock-held (*tcm-lock*) (decf *tcm-live*))
  (format nil "r~A" id))

(defun tcm-response (n &optional (tool "tcm_slow"))
  "构造带 N 个 tool-call 的响应"
  (cl-agent/core:make-chat-response
   (cl-agent/core:make-generation
    (cl-agent/core:assistant-message
     ""
     :tool-calls (loop for i from 1 to n
                       collect (cl-agent/core:make-tool-call
                                :id (format nil "c~D" i) :name tool
                                :arguments (let ((h (make-hash-table :test #'equal)))
                                             (setf (gethash "id" h) (format nil "~D" i))
                                             h))))
    :finish-reason :tool-call)))

(defun tcm-run (mgr n)
  "用 MGR 执行 N 个慢工具，返回 (values 并发峰值 结果文本列表)"
  (setf *tcm-live* 0 *tcm-peak* 0)
  (let* ((k (cl-agent/core:build-kernel :model nil :tools '(tcm-slow) :tool-manager mgr))
         (res (cl-agent/core:execute-tool-calls mgr k (tcm-response n)
                                                (list :tool-context nil))))
    (values *tcm-peak*
            (mapcar #'cl-agent/core:tool-response-text (getf res :messages)))))

(test thread-pool-manager-actually-limits-concurrency
  "thread-pool manager 的并发峰值必须 **严格 ≤ pool-size**。

这是它与 virtual-thread 的唯一区别，也是它存在的理由。"
  (dolist (size '(1 2 3))
    (cl-agent/core:with-thread-pool-tool-calling-manager (mgr size)
      (let ((peak (tcm-run mgr 6)))
        (is (<= peak size)
            "pool-size=~D 时并发峰值 ~D 超限——限流没生效" size peak)))))

(test thread-pool-manager-differs-from-virtual-thread
  "对照：virtual-thread 不限流，峰值应明显高于 pool-size 1。
若两者峰值一样，说明 thread-pool 又退化成委托 virtual-thread 了。"
  (let ((vt-peak (tcm-run (cl-agent/core:make-virtual-thread-tool-calling-manager) 6))
        (tp-peak (cl-agent/core:with-thread-pool-tool-calling-manager (mgr 1)
                   (tcm-run mgr 6))))
    (is (= 1 tp-peak))
    (is (> vt-peak tp-peak)
        "virtual-thread 峰值 ~D 应 > thread-pool(1) 的 ~D" vt-peak tp-peak)))

(test thread-pool-manager-preserves-order
  "结果必须与 tool_calls **同序**——channel 的 receive-result 不保证顺序，
靠索引回填。乱序会让回传给模型的 tool 消息 id 全错位。"
  (cl-agent/core:with-thread-pool-tool-calling-manager (mgr 4)
    (multiple-value-bind (peak texts) (tcm-run mgr 5)
      (declare (ignore peak))
      (is (equal '("r1" "r2" "r3" "r4" "r5") texts)))))

(test shutdown-tool-calling-manager-is-idempotent
  "shutdown 幂等；对非 thread-pool manager 是 no-op"
  (let ((mgr (cl-agent/core:make-thread-pool-tool-calling-manager 2)))
    (tcm-run mgr 2)
    (cl-agent/core:shutdown-tool-calling-manager mgr)
    (cl-agent/core:shutdown-tool-calling-manager mgr)   ; 再关一次不该炸
    (is-true t))
  ;; 非 thread-pool 的 manager 也能安全调用
  (cl-agent/core:shutdown-tool-calling-manager
   (cl-agent/core:make-virtual-thread-tool-calling-manager))
  (is-true t))

(test thread-pool-manager-pool-is-reusable
  "同一个 manager 连续多批复用同一个池（不是每批新建）"
  (cl-agent/core:with-thread-pool-tool-calling-manager (mgr 2)
    (tcm-run mgr 4)
    (let ((pool-after-first (cl-agent/core::tcm-pool mgr)))
      (tcm-run mgr 4)
      (is (eq pool-after-first (cl-agent/core::tcm-pool mgr))))))

;;; ============================================================
;;; 多工具并行不得依赖用户预先初始化 lparallel（回归）
;;;
;;; lparallel 的 submit-task/future 都作用于 lparallel:*kernel*，而它
;;; **默认是 NIL**。本库此前既不建也不提，于是默认路径只要模型一次发
;;; 2 个 tool_call 就 NO-KERNEL-ERROR 崩掉——1 个反而没事（≤1 走顺序
;;; 路径，不碰 lparallel）。而多工具并行是 LLM 的常见行为。
;;;
;;; 全部既有测试都只用 1 个工具，恰好把它盖了个严实。这几个测试
;;; **必须用 ≥2 个工具**，否则等于没测。
;;; ============================================================

(cl-agent/core:deftool mt-echo (&key id)
  "回显"
  (:param id :string "id" :required t)
  (format nil "e~A" id))

(test multi-tool-parallel-works-without-user-lparallel-setup
  "默认路径（不给 :tool-manager）跑 2+ 个工具不得报 NO-KERNEL-ERROR"
  (let* ((k (cl-agent/core:build-kernel :model nil :tools '(mt-echo)))
         (opts (cl-agent/core:make-chat-options
                :tool-callbacks (cl-agent/core:resolve-tool-callbacks '(mt-echo))))
         (calls (cl-agent/core:chat-response-tool-calls (tcm-response 3 "mt_echo"))))
    (let ((results (cl-agent/core:invoke-tool-batch k calls opts nil)))
      (is (= 3 (length results)))
      (is (equal '("e1" "e2" "e3")
                 (mapcar #'cl-agent/core:tool-result-value results))))))

(test multi-tool-via-virtual-thread-manager-works
  "默认 manager（virtual-thread）跑 2+ 个工具同样不得崩"
  (let* ((mgr (cl-agent/core:make-virtual-thread-tool-calling-manager))
         (k (cl-agent/core:build-kernel :model nil :tools '(mt-echo)
                                        :tool-manager mgr))
         (res (cl-agent/core:execute-tool-calls mgr k (tcm-response 3 "mt_echo")
                                                (list :tool-context nil))))
    (is (equal '("e1" "e2" "e3")
               (mapcar #'cl-agent/core:tool-response-text (getf res :messages))))))

(test ensure-tool-pool-respects-caller-binding
  "调用方自己绑了 lparallel:*kernel* 时，ensure-tool-pool 用调用方的"
  (let ((mine (lparallel:make-kernel 2 :name "test-caller-pool")))
    (unwind-protect
         (let ((lparallel:*kernel* mine))
           (is (eq mine (cl-agent/core:ensure-tool-pool))))
      (let ((lparallel:*kernel* mine))
        (lparallel:end-kernel :wait t)))))

;;; ============================================================
;;; 故障分类 + 故障路由（回归）
;;;
;;; batch.lisp 的文件头注释白纸黑字写着一套策略矩阵：
;;;   :transient + :retry → 指数退避重试；其余 → 转文本回传模型。
;;; 但代码里**一行都没实现**——从不读 tool-callback-retry-p、不退避、
;;; 不重试。deftool 认真记了 (:retry t)，零消费者。
;;;
;;; 更底层的问题：分类本身就是坏的。tool-callback-call 把工具体内抛的
;;; **一切** condition 包成 tool-execution-error，而 classify-tool-error
;;; 直接把它判成 :semantic——于是三类故障在真实链路上退化成一类。
;;; 没有正确分类，按类路由无从谈起。
;;; ============================================================

(cl-agent/core:deftool fc-transient (&key x)
  "signal 瞬态故障"
  (:param x :string "x")
  (declare (ignore x))
  (error 'cl-agent/core:transient-tool-failure :message "下游 503"))

(cl-agent/core:deftool fc-env (&key x)
  "signal 环境故障"
  (:param x :string "x")
  (declare (ignore x))
  (error 'cl-agent/core:environment-tool-failure :message "权限不足"))

(cl-agent/core:deftool fc-timeout (&key x)
  "裸的超时错误（靠关键词启发式分类）"
  (:param x :string "x")
  (declare (ignore x))
  (error "connection timeout after 30s"))

(cl-agent/core:deftool fc-semantic (&key x)
  "普通错误"
  (:param x :string "x")
  (declare (ignore x))
  (error "参数不对"))

(defun fc-class (sym)
  "跑一次工具，返回结果里的故障分类"
  (let* ((k (cl-agent/core:build-kernel :model nil :tools (list sym)))
         (req (cl-agent/core:make-tool-request
               (cl-agent/core:symbol-tool-callback sym) :args '(:x "1")))
         (r (cl-agent/core:invoke-tool k req)))
    (getf (cl-agent/core:tool-result-error r) :class)))

(test tool-failure-classified-through-wrapper
  "分类必须**穿透 tool-callback-call 的包装**。
回归：包装后一律 :semantic，三类退化成一类。"
  (is (eq :transient (fc-class 'fc-transient)))
  (is (eq :environment (fc-class 'fc-env)))
  (is (eq :transient (fc-class 'fc-timeout)))   ; 启发式
  (is (eq :semantic (fc-class 'fc-semantic))))

(test classify-tool-error-unwraps-cause
  "classify-tool-error 直接喂包装过的 condition 也要能解包"
  (let ((wrapped (make-condition
                  'cl-agent/core:tool-execution-error
                  :tool-name "x"
                  :cause (make-condition 'cl-agent/core:transient-tool-failure
                                         :message "503"))))
    (is (eq :transient (cl-agent/core:classify-tool-error wrapped))))
  ;; 无 cause 时保守判 :semantic
  (is (eq :semantic
          (cl-agent/core:classify-tool-error
           (make-condition 'cl-agent/core:tool-execution-error :tool-name "x")))))

;;; --- 故障路由：重试 ---

(defvar *fc-runs* 0)

(cl-agent/core:deftool fc-flaky (&key x)
  "前两次瞬态失败，第三次成功；声明了 :retry"
  (:param x :string "x")
  (:retry t)
  (declare (ignore x))
  (incf *fc-runs*)
  (if (< *fc-runs* 3)
      (error 'cl-agent/core:transient-tool-failure :message "503")
      "ok"))

(cl-agent/core:deftool fc-always-transient (&key x)
  "一直瞬态失败；声明了 :retry"
  (:param x :string "x")
  (:retry t)
  (declare (ignore x))
  (incf *fc-runs*)
  (error 'cl-agent/core:transient-tool-failure :message "503"))

(cl-agent/core:deftool fc-transient-noretry (&key x)
  "瞬态失败但**没**声明 :retry"
  (:param x :string "x")
  (declare (ignore x))
  (incf *fc-runs*)
  (error 'cl-agent/core:transient-tool-failure :message "503"))

(cl-agent/core:deftool fc-semantic-retry (&key x)
  "语义故障但声明了 :retry（语义不该重试）"
  (:param x :string "x")
  (:retry t)
  (declare (ignore x))
  (incf *fc-runs*)
  (error "参数不对"))

(defun fc-run-batch (sym)
  "经 invoke-tool-batch 跑一次，返回 (values 执行次数 结果)"
  (setf *fc-runs* 0)
  (let* ((cb (cl-agent/core:symbol-tool-callback sym))
         (k (cl-agent/core:build-kernel :model nil :tools (list sym)))
         (calls (list (cl-agent/core:make-tool-call
                       :id "c1" :name (cl-agent/core:tool-callback-name cb)
                       :arguments (let ((h (make-hash-table :test #'equal)))
                                    (setf (gethash "x" h) "1") h))))
         (results (cl-agent/core:invoke-tool-batch
                   k calls
                   (cl-agent/core:make-chat-options
                    :tool-callbacks (cl-agent/core:resolve-tool-callbacks (list sym)))
                   nil)))
    (values *fc-runs* (first results))))

(test transient-with-retry-is-retried
  ":transient + :retry → 重试；前两次失败第三次成功"
  (multiple-value-bind (runs r) (fc-run-batch 'fc-flaky)
    (is (= 3 runs))
    (is (string= "ok" (cl-agent/core:tool-result-value r)))))

(test transient-retry-gives-up-after-max-attempts
  "一直瞬态失败 → 尝试 *transient-retry-attempts* 次后交出错误（不无限重试）"
  (multiple-value-bind (runs r) (fc-run-batch 'fc-always-transient)
    (is (= cl-agent/core:*transient-retry-attempts* runs))
    (is (eq :transient (getf (cl-agent/core:tool-result-error r) :class)))))

(test transient-without-retry-declaration-not-retried
  ":transient 但没声明 :retry → 只跑一次。
重试意味着重复副作用，必须由工具作者显式选择加入。"
  (multiple-value-bind (runs r) (fc-run-batch 'fc-transient-noretry)
    (is (= 1 runs))
    (is (eq :transient (getf (cl-agent/core:tool-result-error r) :class)))))

(test semantic-failure-never-retried-even-with-retry-flag
  ":semantic 即便声明了 :retry 也不重试——参数错了重试一万次还是错"
  (multiple-value-bind (runs r) (fc-run-batch 'fc-semantic-retry)
    (is (= 1 runs))
    (is (eq :semantic (getf (cl-agent/core:tool-result-error r) :class)))))

;;; ============================================================
;;; 真流式通路 + :token-xform 组装
;;;
;;; 此前这两个 token-xform filter 是**三重装饰品**：
;;;   1. 没有代码读 filter-token-xform 去组装流（invoke-chat-stream 不存在），
;;;      kernel-chat-stream 是同步降级；
;;;   2. 它们返回**裸 lambda 而不是 filter 实例**，压根放不进 :filters；
;;;   3. 协议照搬 transducer 的 arity 重载，0-arity 返回函数当 step。
;;; 三条互相掩护——放不进 :filters 就从没被组装，也就没人发现协议是拧的。
;;; ============================================================

(defclass stream-provider ()
  ((chunks :initarg :chunks :reader stream-provider-chunks))
  (:documentation "把预设分片逐个吐出的流式 provider"))

(defmethod cl-agent/core:provider-supports-streaming-p ((p stream-provider)) t)

(defmethod cl-agent/core:llm-chat-stream ((p stream-provider) messages on-chunk
                                          &key &allow-other-keys)
  (declare (ignore messages))
  (dolist (c (stream-provider-chunks p))
    (funcall on-chunk (list :delta c)))
  (cl-agent/core:make-llm-response
   :content (apply #'concatenate 'string (stream-provider-chunks p))
   :finish-reason :stop))

(defmethod cl-agent/core:llm-chat ((p stream-provider) messages &key &allow-other-keys)
  (declare (ignore messages))
  (cl-agent/core:make-llm-response
   :content (apply #'concatenate 'string (stream-provider-chunks p))
   :finish-reason :stop))

(defun stream-kernel (chunks &rest filters)
  (cl-agent/core:build-kernel
   :model (cl-agent/core:make-provider-chat-model
           (make-instance 'stream-provider :chunks chunks))
   :filters filters))

(test kernel-chat-stream-is-incremental
  "kernel-chat-stream 必须逐片回调，不是攒完一次性给。
回归：它曾是同步降级（整段文本一个 chunk）。"
  (let ((got nil))
    (cl-agent/core:kernel-chat-stream (stream-kernel '("你" "好" "世界"))
                                      (lambda (d) (push d got))
                                      :user "hi")
    (is (equal '("你" "好" "世界") (reverse got)))))

(test token-xform-filters-are-filter-instances
  "token-redact-filter / hold-release-filter 必须返回 **filter 实例**——
名字叫 xxx-filter 却返回裸 lambda 的话，根本放不进 :filters。"
  (is (typep (cl-agent/core:token-redact-filter '("x")) 'cl-agent/core:filter))
  (is (typep (cl-agent/core:hold-release-filter) 'cl-agent/core:filter))
  ;; 且 token-xform 槽真的有值
  (is (not (null (cl-agent/core:filter-token-xform
                  (cl-agent/core:token-redact-filter '("x")))))))

(test token-redact-filter-redacts-in-stream
  "脱敏 xform 在流式管道里生效"
  (let ((got nil))
    (cl-agent/core:kernel-chat-stream
     (stream-kernel '("我的" "password" "是x")
                    (cl-agent/core:token-redact-filter '("password")))
     (lambda (d) (push d got))
     :user "hi")
    (is (equal '("我的" "***" "是x") (reverse got)))))

(test hold-release-filter-buffers-then-releases
  "hold-release 缓冲全部 token，流结束时一次性放出"
  (let ((got nil) (seen nil))
    (cl-agent/core:kernel-chat-stream
     (stream-kernel '("你" "好" "世界")
                    (cl-agent/core:hold-release-filter
                     :approve-fn (lambda (text) (setf seen text) t)))
     (lambda (d) (push d got))
     :user "hi")
    ;; 缓冲型：下游只收到 1 片全文
    (is (equal '("你好世界") got))
    ;; 审批函数看到的是全文
    (is (string= "你好世界" seen))))

(test hold-release-filter-blocks-on-reject
  "审批否决 → 送出拒答文本，原文不外泄"
  (let ((got nil))
    (cl-agent/core:kernel-chat-stream
     (stream-kernel '("机密" "内容")
                    (cl-agent/core:hold-release-filter
                     :approve-fn (lambda (text) (declare (ignore text)) nil)))
     (lambda (d) (push d got))
     :user "hi")
    (is (= 1 (length got)))
    (is (search "未通过审核" (first got)))
    (is (not (search "机密" (first got))))))

(test chat-filters-still-apply-in-stream
  ":chat filter 在流式路径下照常生效（memory 落库）"
  (let ((mem (cl-agent/core:make-message-window-chat-memory))
        (got nil))
    (cl-agent/core:kernel-chat-stream
     (stream-kernel '("答") (cl-agent/core:memory-filter mem))
     (lambda (d) (push d got))
     :user "问" :context '(:conversation-id "st1"))
    ;; user + assistant
    (is (= 2 (length (cl-agent/core:memory-messages mem "st1"))))))

(test compose-token-xforms-order-is-onion
  "多个 xform 按洋葱序：靠前 = 靠外 = 先看到 token"
  (let ((trace nil))
    (flet ((tracer (tag)
             (cl-agent/core:make-filter
              tag
              :token-xform
              (lambda (downstream)
                (values (lambda (tok) (push tag trace) (funcall downstream tok))
                        nil)))))
      (multiple-value-bind (emit finish)
          (cl-agent/core:compose-token-xforms
           (list (tracer :outer) (tracer :inner))
           (lambda (tok) (declare (ignore tok)) (push :sink trace)))
        (funcall emit (list :token "x"))
        (when finish (funcall finish))
        (is (equal '(:outer :inner :sink) (reverse trace)))))))

(test kernel-chat-stream-refuses-tools-loudly
  "流式路径不跑工具循环 → 带工具时必须**报错**，不能静默丢掉工具执行。
静默丢掉的话，模型发了 tool_call 没人执行，用户只看到一段没头没尾的文本。"
  (signals error
    (cl-agent/core:kernel-chat-stream
     (cl-agent/core:build-kernel
      :model (cl-agent/core:make-provider-chat-model
              (make-instance 'stream-provider :chunks '("x")))
      :tools '(mt-echo))
     (lambda (d) (declare (ignore d)))
     :user "hi"))
  ;; 请求级 :tools 同样拦
  (signals error
    (cl-agent/core:kernel-chat-stream
     (stream-kernel '("x"))
     (lambda (d) (declare (ignore d)))
     :user "hi" :tools '(mt-echo)))
  ;; 无工具则正常
  (let ((got nil))
    (cl-agent/core:kernel-chat-stream (stream-kernel '("ok"))
                                      (lambda (d) (push d got)) :user "hi")
    (is (equal '("ok") got))))

;;; ============================================================
;;; :writes + :state-slots（MapReduce 契约）
;;; ============================================================

(test apply-writes-semantics
  "apply-writes 纯函数：last-writer 按序 / reducer 折叠 / 冲突检测"
  ;; 未声明槽：last-writer，后写覆盖，按序确定；同批多写 → 冲突键
  (multiple-value-bind (ctx conflicts)
      (cl-agent/core:apply-writes '(:x 0) '((:x 1) (:x 2)))
    (is (= 2 (getf ctx :x)) "last-writer：序列里靠后的胜出")
    (is (equal '(:x) conflicts) "无 reducer 的多写被标为冲突"))
  ;; 声明 reducer：按序折叠，老值缺席用 :init
  (multiple-value-bind (ctx conflicts)
      (cl-agent/core:apply-writes
       '(:other "keep")
       '((:notes ("a")) (:notes ("b")))
       (list (list :notes :init nil
                   :reduce (lambda (old new) (append old new)))))
    (is (equal '("a" "b") (getf ctx :notes)) "reducer 按 call 序折叠")
    (is (null conflicts) "有 reducer 就不算冲突")
    (is (string= "keep" (getf ctx :other)) "未被写的键原样保留"))
  ;; reducer + context 里已有老值 → 用老值而非 :init
  (let ((ctx (cl-agent/core:apply-writes
              '(:n 10)
              '((:n 5))
              (list (list :n :init 0 :reduce #'+)))))
    (is (= 15 (getf ctx :n)) "老值在 context 里就不用 :init"))
  ;; 纯函数：不改实参
  (let ((orig (list :x 1)))
    (cl-agent/core:apply-writes orig '((:x 99)))
    (is (= 1 (getf orig :x)) "实参 plist 不被修改")))

;;; 工具：用 (values 结果 writes) 声明写意图
(cl-agent/core:deftool ws-note (&key text)
  "记一条笔记"
  (:param text :string "内容" :required t)
  (values (format nil "已记：~A" text)
          (list :notes (list text))))

;;; 工具：读回累积的笔记（下一轮才看得到折叠结果）
(cl-agent/core:deftool ws-read (&key tool-context)
  "读全部笔记"
  (:param tool-context :object "宿主注入")
  (format nil "笔记：~{~A~^,~}" (getf tool-context :notes)))

;;; 工具：必失败（写意图必须作废）
(cl-agent/core:deftool ws-boom (&key)
  "总是失败"
  (error "boom"))

(defun ws-two-calls-response ()
  "一批两个 ws-note 调用（a 在前 b 在后）"
  (cl-agent/core:make-llm-response
   :content ""
   :tool-calls (list (list :id "w1" :name "ws_note"
                           :arguments (let ((h (make-hash-table :test #'equal)))
                                        (setf (gethash "text" h) "a") h))
                     (list :id "w2" :name "ws_note"
                           :arguments (let ((h (make-hash-table :test #'equal)))
                                        (setf (gethash "text" h) "b") h)))
   :finish-reason :tool-call
   :model "seq-model"))

(defun ws-state-slots ()
  (list (list :notes :init nil :reduce (lambda (old new) (append old new)))))

(test writes-fold-end-to-end
  "端到端：批内两工具的 :writes 按 call 序折叠 → 下一轮工具看到折叠后
快照 → 最终 turn-result-tool-context 交还累积状态"
  (let* ((provider (make-seq-provider
                    (ws-two-calls-response)
                    (tool-call-response "ws_read" nil :id "r1")
                    (text-response "done")))
         (kernel (cl-agent/core:build-kernel
                  :model (cl-agent/core:make-provider-chat-model provider)
                  :tools '(ws-note ws-read)
                  :state-slots (ws-state-slots)))
         (result (cl-agent/core:invoke-turn
                  kernel
                  (cl-agent/core:make-turn-request
                   (list (cl-agent/core:user-message "记笔记"))))))
    (is (eq :completed (cl-agent/core:turn-result-status result)))
    ;; 第三轮请求里 ws_read 的 tool 消息 = 折叠后（a 在前 b 在后）。
    ;; 此时有两条 tool 消息（第一轮批次的 + 第二轮 ws_read 的），取**最后**一条
    (let* ((req3 (first (seq-provider-requests provider)))
           (tool-msg (find :tool (reverse (getf req3 :messages))
                           :key (lambda (m) (getf m :role)))))
      (is (string= "笔记：a,b" (getf tool-msg :content))
          "下一轮工具读到按 call 序折叠的 context"))
    ;; 最终 turn-result 交还累积状态
    (is (equal '("a" "b")
               (getf (cl-agent/core:turn-result-tool-context result) :notes))
        "turn-result-tool-context 带出折叠后的最终 context")))

(test writes-of-failed-tool-discarded
  "失败调用的写意图不生效（事务性）"
  (let* ((ok (cl-agent/core:make-tool-result :value "ok" :writes '(:notes ("x"))))
         (bad (cl-agent/core:make-tool-result
               :writes '(:notes ("泄漏"))
               :error '(:class :semantic :message "boom")))
         (kernel (cl-agent/core:build-kernel :model nil
                                             :state-slots (ws-state-slots)))
         (ctx (cl-agent/core:fold-batch-writes kernel (list ok bad) nil)))
    (is (equal '("x") (getf ctx :notes)) "只有成功调用的写意图生效")))

(test writes-fold-via-manager-path
  "manager 路径：execute-tool-calls 的 :context 是应用 writes 后的 context
（此前协议这么承诺、实现原样透传）"
  (dolist (mgr (list (cl-agent/core:make-sequential-tool-calling-manager)
                     (cl-agent/core:make-virtual-thread-tool-calling-manager)))
    (let* ((kernel (cl-agent/core:build-kernel
                    :model nil :tools '(ws-note)
                    :tool-manager mgr
                    :state-slots (ws-state-slots)))
           (resp (cl-agent/core:make-chat-response
                  (cl-agent/core:make-generation
                   (cl-agent/core:assistant-message
                    ""
                    :tool-calls (list (cl-agent/core:make-tool-call
                                       :id "m1" :name "ws_note"
                                       :arguments '(:text "hello"))))
                   :finish-reason :tool-call)))
           (result (cl-agent/core:execute-tool-calls
                    mgr kernel resp (list :tool-context '(:seed t)))))
      (is (equal '("hello") (getf (getf result :context) :notes))
          (format nil "~A 折叠 writes 进 :context" (type-of mgr)))
      (is (eq t (getf (getf result :context) :seed))
          "既有 context 键保留"))))

(test tool-callback-call-passes-writes-through
  "tool-callback-call 返回 (values 文本 writes)——写意图穿透执行链"
  (multiple-value-bind (text writes)
      (cl-agent/core:tool-callback-call
       (cl-agent/core:symbol-tool-callback 'ws-note) '(:text "x"))
    (is (string= "已记：x" text))
    (is (equal '(:notes ("x")) writes))))

(test sequential-manager-survives-unknown-tool
  "sequential manager 对幻觉工具名产出语义错误回传，而不是 signal 冲出整轮。
此前它绕过 resolve-callback 直接调 find-callback-for-call（signal 路径），
与主路径行为分叉——CLOS 收敛（manager-run-batch）后统一走顺序批。"
  (let* ((mgr (cl-agent/core:make-sequential-tool-calling-manager))
         (k (cl-agent/core:build-kernel :model nil :tools '(ki-adder)
                                        :tool-manager mgr))
         (resp (cl-agent/core:make-chat-response
                (cl-agent/core:make-generation
                 (cl-agent/core:assistant-message
                  "" :tool-calls (list (cl-agent/core:make-tool-call
                                        :id "x1" :name "no_such_tool"
                                        :arguments nil)))
                 :finish-reason :tool-call)))
         (result (cl-agent/core:execute-tool-calls
                  mgr k resp (list :tool-context nil))))
    (is (= 1 (length (getf result :messages))))
    (is (search "no_such_tool"
                (cl-agent/core:tool-response-text (first (getf result :messages))))
        "错误文本报出工具名，模型才能自纠")
    ;; 共享骨架现在如实收集 :errors（virtual-thread 此前恒 nil）
    (is (= 1 (length (getf result :errors))))
    (is (eq :semantic (getf (first (getf result :errors)) :class)))))

;;; ============================================================
;;; P4 Code Review 回归测试
;;; ============================================================

(cl-agent/core:deftool rd-direct (&key x)
  "直接返回结果的工具（return-direct）"
  (:param x :integer "值" :required t)
  (:return-direct t)
  (format nil "结果是 ~A" x))

(test return-direct-via-manager-skeleton
  "execute-tool-calls 的共享骨架必须正确计算 :return-direct。
此前 manager 路径恒返回 done=nil，return-direct 被静默吞掉。"
  (dolist (mgr-fn (list #'cl-agent/core:make-sequential-tool-calling-manager
                        #'cl-agent/core:make-virtual-thread-tool-calling-manager))
    (let* ((mgr (funcall mgr-fn))
           (k (cl-agent/core:build-kernel :model nil :tools '(rd-direct)
                                          :tool-manager mgr))
           (resp (cl-agent/core:make-chat-response
                  (cl-agent/core:make-generation
                   (cl-agent/core:assistant-message
                    "" :tool-calls (list (cl-agent/core:make-tool-call
                                          :id "x1" :name "rd_direct"
                                          :arguments (let ((h (make-hash-table :test #'equal)))
                                                       (setf (gethash "x" h) "42") h))))
                   :finish-reason :tool-call)))
           (result (cl-agent/core:execute-tool-calls mgr k resp (list :tool-context nil))))
      (is (getf result :return-direct)
          "~A 路径应返回 :return-direct = t" (type-of mgr)))))

(test return-direct-via-manager-end-to-end
  "return-direct 工具经 manager 路径短路——不回传模型，直接交结果。
此前 manager 路径无视 return-direct，结果被当 tool 消息回传模型。"
  (let* ((mgr (cl-agent/core:make-sequential-tool-calling-manager))
         (provider (make-seq-provider
                    (tool-call-response "rd_direct" '(("x" . 42)))
                    (text-response "不应该走到第二轮")))
         (k (cl-agent/core:build-kernel
             :model (cl-agent/core:make-provider-chat-model provider)
             :tools '(rd-direct) :tool-manager mgr)))
    (let ((result (cl-agent/core:invoke-turn
                   k
                   (cl-agent/core:make-turn-request
                    (list (cl-agent/core:user-message "直接给我结果"))))))
      (is (eq :completed (cl-agent/core:turn-result-status result)))
      (is (search "结果是 42"
                  (cl-agent/core:chat-response-text
                   (cl-agent/core:turn-result-response result))))
      (is (= 1 (length (seq-provider-requests provider)))
          "return-direct 应短路——模型只被调用一次"))))

(test resume-honors-tool-manager
  "resume-turn 的续跑批必须经过 manager-run-batch（受线程池限流）。
此前 %resume-continuation 直接调 invoke-tool-batch，绕过 manager——
thread-pool(1) + HITL 暂停的组合下，续跑批并发不受限。"
  (setf *tcm-live* 0 *tcm-peak* 0)
  (let* ((mgr (cl-agent/core:make-thread-pool-tool-calling-manager 1))
         (gate (lambda (tc) (declare (ignore tc)) :pause))
         (multi-tc-response
           (lambda (messages)
             (declare (ignore messages))
             (cl-agent/core:make-llm-response
              :content ""
              :tool-calls (loop for i from 1 to 3
                                collect (list :id (format nil "c~D" i)
                                              :name "tcm_slow"
                                              :arguments (let ((h (make-hash-table :test #'equal)))
                                                           (setf (gethash "id" h) (format nil "~D" i))
                                                           h)))
              :finish-reason :tool-call
              :model "seq-model")))
         (provider (make-seq-provider
                    multi-tc-response
                    (text-response "done")))
         (k (cl-agent/core:build-kernel
             :model (cl-agent/core:make-provider-chat-model provider)
             :tools '(tcm-slow) :tool-manager mgr :tool-gate gate)))
    (unwind-protect
         (let* ((turn1 (cl-agent/core:invoke-turn
                        k
                        (cl-agent/core:make-turn-request
                         (list (cl-agent/core:user-message "跑3个工具")))))
                (loop-state (cl-agent/core:turn-result-loop-state turn1)))
           (is (eq :paused (cl-agent/core:turn-result-status turn1)))
           ;; 续跑：3 个慢工具经 thread-pool(1) → 峰值必须 ≤ 1
           (let ((turn2 (cl-agent/core:resume-turn k loop-state :approved)))
             (declare (ignore turn2)))
           (is (<= *tcm-peak* 1)
               "续跑批经 manager-run-batch，pool-size=1 → 峰值 ~D 应 ≤ 1" *tcm-peak*))
      (cl-agent/core:shutdown-tool-calling-manager mgr))))

(test tool-search-instruction-injected-once
  "tool-search-filter 的 instruction 系统消息每会话只追加一次。
此前每轮都追加，多轮循环里重复膨胀。"
  (let* ((idx (cl-agent/core:make-keyword-tool-index '(ki-adder)))
         (ts-filter (cl-agent/core:tool-search-filter idx))
         (instruction cl-agent/core:*tool-search-instruction*)
         (seen-count 0)
         (counter (cl-agent/core:make-filter
                   :counter :chat
                   (lambda (prompt chain)
                     ;; 数 instruction 在 messages 里出现的次数
                     (dolist (m (cl-agent/core:prompt-messages prompt))
                       (when (and (cl-agent/core:system-message-p m)
                                  (search instruction (or (cl-agent/core:message-text m) "")))
                         (incf seen-count)))
                     (funcall chain prompt))))
         (provider (make-seq-provider
                    (text-response "ok")
                    (text-response "ok2")))
         (k (cl-agent/core:build-kernel
             :model (cl-agent/core:make-provider-chat-model provider)
             :filters (list ts-filter counter))))
    ;; 同一会话调两轮
    (cl-agent/core:invoke-chat
     k (cl-agent/core:make-prompt
        (list (cl-agent/core:user-message "hi"))
        :options (cl-agent/core:make-chat-options
                  :tool-context (list :conversation-id "conv-once"))))
    (cl-agent/core:invoke-chat
     k (cl-agent/core:make-prompt
        (list (cl-agent/core:user-message "again"))
        :options (cl-agent/core:make-chat-options
                  :tool-context (list :conversation-id "conv-once"))))
    (is (= 1 seen-count)
        "instruction 应只追加一次，实际 ~D 次" seen-count)))

;;; ============================================================
;;; 捉虫回归（2026-07-17 探针发现的 4 个真 bug）
;;; ============================================================

(test stream-guard-catches-options-tools
  "流式守卫必须拦下 options 里的 tool-callbacks——不止 :tools 参数。
回归：守卫此前只查 (getf plist :tools) 与 kernel-tools，漏了请求级
:options 和 kernel 默认 :options 携带的工具，配 :options 的流式请求
直接穿过守卫，模型发 tool_call 却无人执行（正是守卫本该堵的洞）。"
  (let ((opts (cl-agent/core:make-chat-options
               :tool-callbacks (cl-agent/core:resolve-tool-callbacks '(mt-echo)))))
    ;; 请求级 :options 带工具
    (signals error
      (cl-agent/core:kernel-chat-stream (stream-kernel '("x"))
                                        (lambda (d) (declare (ignore d)))
                                        :user "hi" :options opts))
    ;; kernel 默认 :options 带工具
    (let ((k (cl-agent/core:build-kernel
              :model (cl-agent/core:make-provider-chat-model
                      (make-instance 'stream-provider :chunks '("x")))
              :options opts)))
      (signals error
        (cl-agent/core:kernel-chat-stream k (lambda (d) (declare (ignore d)))
                                          :user "hi")))))

(defclass always-tool-provider ()
  ((count :initform 0 :accessor atp-count))
  (:documentation "永远回 tool_call 的 provider，用来数模型被调多少次"))
(defmethod cl-agent/core:llm-chat ((p always-tool-provider) messages
                                   &key &allow-other-keys)
  (declare (ignore messages))
  (incf (atp-count p))
  (let ((h (make-hash-table :test #'equal)))
    (setf (gethash "id" h) "1")
    (cl-agent/core:make-llm-response
     :content "" :finish-reason :tool-call :model "loop"
     :tool-calls (list (list :id (format nil "c~D" (atp-count p))
                             :name "mt_echo" :arguments h)))))

(test max-tool-iterations-exact-count
  "max-tool-iterations=N 恰好执行 N 轮工具，第 N+1 次探测发现模型仍
要工具即报错。回归：此前检查在循环体外且用 >（而非 >=），上限 3
实际调了 5 次模型（多执行 1 轮 + 多探测 1 次）。"
  (let* ((provider (make-instance 'always-tool-provider))
         (k (cl-agent/core:build-kernel
             :model (cl-agent/core:make-provider-chat-model provider)
             :tools '(mt-echo)
             :settings '((:max-tool-iterations . 2)))))
    (signals cl-agent/core:max-tool-iterations-exceeded-error
      (cl-agent/core:invoke-turn
       k (cl-agent/core:make-turn-request (list (cl-agent/core:user-message "go")))))
    ;; 2 轮工具执行（iter 0,1）+ 第 3 次探测（iter 2）触发 error = 恰 3 次
    (is (= 3 (atp-count provider))
        "上限 2 → 模型恰调 3 次（2 轮执行 + 1 次探测），不是旧的 4 次")))

(cl-agent/core:deftool rdc-direct (&key q)
  "直接返回结果"
  (:param q :string "q" :required t)
  (:return-direct t)
  (format nil "直答：~A" q))

(defclass rdc-provider ()
  ((q :initarg :q :accessor rdc-q)))
(defmethod cl-agent/core:llm-chat ((p rdc-provider) messages &key &allow-other-keys)
  (declare (ignore messages))
  (let ((n (pop (rdc-q p)))) (if (functionp n) (funcall n) n)))

(test resume-respects-return-direct
  "resume 后对全批 return-direct 工具必须短路——工具结果即最终答复，
不再回模型。回归：resume 路径此前无条件进 %tool-loop，approve 一个
return-direct 工具后又多调一次模型，拿到的是不该出现的续写。"
  (let* ((extra 0)
         (h (make-hash-table :test #'equal))
         (_ (setf (gethash "q" h) "42"))
         (provider (make-instance 'rdc-provider
                     :q (list (cl-agent/core:make-llm-response
                               :content "" :finish-reason :tool-call :model "m"
                               :tool-calls (list (list :id "c1" :name "rdc_direct"
                                                       :arguments h)))
                              (lambda () (incf extra)
                                (cl-agent/core:make-llm-response
                                 :content "不该来" :finish-reason :stop :model "m")))))
         (k (cl-agent/core:build-kernel
             :model (cl-agent/core:make-provider-chat-model provider)
             :tools '(rdc-direct)
             :tool-gate (lambda (tc) (declare (ignore tc)) :pause))))
    (declare (ignore _))
    (let* ((paused (cl-agent/core:invoke-turn
                    k (cl-agent/core:make-turn-request
                       (list (cl-agent/core:user-message "q")))))
           (final (cl-agent/core:resume-turn
                   k (cl-agent/core:turn-result-loop-state paused) :approved)))
      (is (= 0 extra) "resume 后不再调模型（return-direct 短路）")
      (is (eq :completed (cl-agent/core:turn-result-status final)))
      (is (search "直答：42"
                  (cl-agent/core:chat-response-text
                   (cl-agent/core:turn-result-response final)))
          "最终答复是工具结果本身，不是模型续写"))))

(test memory-crop-keeps-tool-pairs-intact
  "memory 窗口裁剪不得切开 assistant(tool_use)/tool(tool_result) 对——
否则序列以孤儿 tool 消息开头，真实 provider 400。回归：此前纯数量
subseq，window 落在对中间就产生孤儿 tool 开头。"
  (let* ((mem (cl-agent/core:make-message-window-chat-memory))
         (conv "crop"))
    ;; 历史：user / assistant(tool_use) / tool / assistant（4 条）
    (cl-agent/core:memory-add mem conv (cl-agent/core:user-message "问题"))
    (cl-agent/core:memory-add
     mem conv (cl-agent/core:assistant-message
               "" :tool-calls (list (cl-agent/core:make-tool-call
                                     :id "t1" :name "f" :arguments nil))))
    (cl-agent/core:memory-add
     mem conv (cl-agent/core:tool-response-message
               (list (cl-agent/core:make-tool-response :id "t1" :name "f" :text "r"))))
    (cl-agent/core:memory-add mem conv (cl-agent/core:assistant-message "答"))
    (let (sent)
      (let* ((spy (cl-agent/core:make-filter
                   :spy :chat
                   (lambda (prompt chain)
                     (declare (ignore chain))
                     (setf sent (mapcar #'cl-agent/core:message-role
                                        (cl-agent/core:prompt-messages prompt)))
                     (cl-agent/core:make-chat-response
                      (cl-agent/core:make-generation
                       (cl-agent/core:assistant-message "ok") :finish-reason :stop)))))
             (k (cl-agent/core:build-kernel
                 :model nil
                 :filters (list (cl-agent/core:memory-filter mem :window 3) spy))))
        (cl-agent/core:kernel-chat k :user "新" :context (list :conversation-id conv))
        ;; window=3 的纯裁剪会切成 (tool assistant user)——孤儿 tool 开头。
        ;; 修复后起点前移到 user，首条非 tool。
        (is (not (eq :tool (first sent)))
            "裁剪后首条不是孤儿 tool 消息")
        ;; 任意 tool 消息前必有配对的 assistant(tool_use)
        (loop for (role . rest) on sent
              for i from 0
              when (eq role :tool)
                do (is (find :assistant (subseq sent 0 i))
                       "tool 消息前存在 assistant(tool_use)"))))))

;;; ============================================================
;;; :loop-fn / :resume-fn —— 可替换的循环骨架
;;; ============================================================

(test loop-fn-defaults-to-run-tool-loop
  "不给 :loop-fn 时 terminal 仍是 run-tool-loop——默认路径零改动"
  (multiple-value-bind (kernel provider)
      (make-test-kernel
       (tool-call-response "ki_adder" '(("a" . 3) ("b" . 4)))
       (text-response "3+4=7"))
    (declare (ignore provider))
    (is (null (cl-agent/core:kernel-loop-fn kernel)) "槽缺省为 nil")
    (is (null (cl-agent/core:kernel-resume-fn kernel)) "槽缺省为 nil")
    (let ((result (cl-agent/core:invoke-turn
                   kernel
                   (cl-agent/core:make-turn-request
                    (list (cl-agent/core:user-message "3+4=?"))))))
      (is (eq :completed (cl-agent/core:turn-result-status result)))
      (is (string= "3+4=7"
                   (cl-agent/core:chat-response-text
                    (cl-agent/core:turn-result-response result)))))))

(test loop-fn-replaces-terminal
  "自定义 loop-fn 整体接管循环：模型一次都不调"
  (multiple-value-bind (kernel-unused provider)
      (make-test-kernel (text-response "不该来"))
    (declare (ignore kernel-unused))
    (let* ((seen nil)
           (k (cl-agent/core:build-kernel
               :model (cl-agent/core:make-provider-chat-model provider)
               :tools '(ki-adder)
               :loop-fn (lambda (kernel req)
                          (declare (ignore kernel))
                          (setf seen (cl-agent/core:turn-request-messages req))
                          (cl-agent/core:make-turn-result
                           :completed
                           :response (cl-agent/core:make-chat-response
                                      (cl-agent/core:make-generation
                                       (cl-agent/core:assistant-message "自定义循环")
                                       :finish-reason :stop))
                           :tool-calls-made 0))))
           (result (cl-agent/core:invoke-turn
                    k (cl-agent/core:make-turn-request
                       (list (cl-agent/core:user-message "问"))))))
      (is (string= "自定义循环"
                   (cl-agent/core:chat-response-text
                    (cl-agent/core:turn-result-response result))))
      (is (= 1 (length seen)) "loop-fn 收到 turn-request 的 messages")
      (is (= 0 (length (seq-provider-requests provider)))
          "默认循环被完全绕过，模型未被调用"))))

(test loop-fn-still-wrapped-by-turn-filters
  ":turn filter 照常环绕自定义 loop-fn——换 terminal 不影响洋葱"
  (let* ((trace nil)
         (spy (cl-agent/core:make-filter
               :spy
               :turn (lambda (req chain)
                       (push :before trace)
                       (let ((r (funcall chain req)))
                         (push :after trace)
                         r))))
         (k (cl-agent/core:build-kernel
             :model nil
             :filters (list spy)
             :loop-fn (lambda (kernel req)
                        (declare (ignore kernel req))
                        (push :loop trace)
                        (cl-agent/core:make-turn-result
                         :completed
                         :response (cl-agent/core:make-chat-response
                                    (cl-agent/core:make-generation
                                     (cl-agent/core:assistant-message "x")
                                     :finish-reason :stop)))))))
    (cl-agent/core:invoke-turn
     k (cl-agent/core:make-turn-request
        (list (cl-agent/core:user-message "问"))))
    (is (equal '(:before :loop :after) (reverse trace))
        "filter 在自定义循环外层照常进出")))

(test resume-fn-replaces-continuation
  "自定义 resume-fn 接管暂停延续；filter 递归重入仍落到 loop-fn"
  (let* ((calls nil)
         (k (cl-agent/core:build-kernel
             :model nil
             :loop-fn (lambda (kernel req)
                        (declare (ignore kernel req))
                        (push :loop calls)
                        (cl-agent/core:make-turn-result :completed))
             :resume-fn (lambda (kernel loop-state decision payload)
                          (declare (ignore kernel payload))
                          (push (list :resume decision
                                      (cl-agent/core:loop-state-iteration loop-state))
                                calls)
                          (cl-agent/core:make-turn-result
                           :completed
                           :response (cl-agent/core:make-chat-response
                                      (cl-agent/core:make-generation
                                       (cl-agent/core:assistant-message "已续跑")
                                       :finish-reason :stop))))))
         (ls (cl-agent/core:make-loop-state :iteration 2 :context nil))
         (result (cl-agent/core:resume-turn k ls :approved)))
    (is (equal '((:resume :approved 2)) calls)
        "只走自定义 resume-fn，未落到 loop-fn")
    (is (string= "已续跑"
                 (cl-agent/core:chat-response-text
                  (cl-agent/core:turn-result-response result))))))

(test default-hitl-resume-unaffected-by-loop-fn-seam
  "接缝引入后默认 HITL 暂停/续跑行为不变（回归）"
  (let* ((provider (make-seq-provider
                    (tool-call-response "ki_adder" '(("a" . 1) ("b" . 2)))
                    (text-response "1+2=3")))
         (k (cl-agent/core:build-kernel
             :model (cl-agent/core:make-provider-chat-model provider)
             :tools '(ki-adder)
             :tool-gate (lambda (tc) (declare (ignore tc)) :pause)))
         (paused (cl-agent/core:invoke-turn
                  k (cl-agent/core:make-turn-request
                     (list (cl-agent/core:user-message "1+2=?"))))))
    (is (eq :paused (cl-agent/core:turn-result-status paused)))
    (is (= 1 (length (seq-provider-requests provider)))
        "暂停时工具未执行、模型只调了一轮")
    (let ((final (cl-agent/core:resume-turn
                  k (cl-agent/core:turn-result-loop-state paused) :approved)))
      (is (eq :completed (cl-agent/core:turn-result-status final)))
      (is (string= "1+2=3"
                   (cl-agent/core:chat-response-text
                    (cl-agent/core:turn-result-response final)))))))
