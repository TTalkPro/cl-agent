;;;; test-invariants.lisp
;;;; CL-Agent - 类不变式（definvariants + 校验原语）
;;;;
;;;; 这组测试钉的是「无论从哪条路造出来都成立」——所以一律用裸
;;;; make-instance，绕开 make-* 构造函数。走构造函数的路径本来就被
;;;; 各自模块的测试覆盖了；不变式的全部意义在于**后门也堵上**。

(in-package :cl-agent/tests)

(def-suite invariants-suite :in cl-agent-suite
  :description "类不变式：make-instance 后门同样受约束")

(in-suite invariants-suite)

;;; ============================================================
;;; 原语
;;; ============================================================

(defclass %inv-probe ()
  ((required :initarg :required :initform nil :reader probe-required)
   (enum :initarg :enum :initform :a :reader probe-enum)
   (typed :initarg :typed :initform nil :reader probe-typed)
   (fn :initarg :fn :initform nil :reader probe-fn)))

(test require-slot-rejects-nil-and-unbound
  "require-slot：未绑定或 NIL 都算缺失"
  (let ((obj (make-instance '%inv-probe)))
    (signals cl-agent/core:invariant-violation
      (cl-agent/core:require-slot obj 'required "测试用"))
    ;; 有值就通过
    (is (cl-agent/core:require-slot
         (make-instance '%inv-probe :required 1) 'required "测试用"))))

(test require-member-rejects-values-outside-the-set
  "require-member：枚举槽写错 keyword 不会静默走 else 分支"
  (let ((obj (make-instance '%inv-probe :enum :zzz)))
    (signals cl-agent/core:invariant-violation
      (cl-agent/core:require-member obj 'enum '(:a :b))))
  (is (cl-agent/core:require-member
       (make-instance '%inv-probe :enum :b) 'enum '(:a :b))))

(test require-type-allows-nil-but-not-wrong-type
  "require-type：「可选，但给了就得是这个类型」"
  ;; NIL 放行——这是最常见的形态
  (is (cl-agent/core:require-type (make-instance '%inv-probe) 'typed 'string))
  (is (cl-agent/core:require-type
       (make-instance '%inv-probe :typed "x") 'typed 'string))
  (signals cl-agent/core:invariant-violation
    (cl-agent/core:require-type (make-instance '%inv-probe :typed 42) 'typed 'string)))

(test require-callable-accepts-functions-and-function-names
  "require-callable：函数对象与函数名都算可调用"
  (is (cl-agent/core:require-callable (make-instance '%inv-probe :fn #'identity) 'fn))
  (is (cl-agent/core:require-callable (make-instance '%inv-probe :fn 'identity) 'fn))
  (is (cl-agent/core:require-callable (make-instance '%inv-probe) 'fn) "NIL 放行")
  (signals cl-agent/core:invariant-violation
    (cl-agent/core:require-callable (make-instance '%inv-probe :fn 42) 'fn)))

(test invariant-violation-is-not-retryable
  "不变式违反继承 validation-error → error-retryable-p 为 NIL。

重试一个构造错误不会有不同结果；如果它被判成可重试，ChatModel 的
retry-policy 会白白重试三次再抛同一个错。"
  (let ((condition (make-condition 'cl-agent/core:invariant-violation
                                   :message "x")))
    (is (typep condition 'cl-agent/core:validation-error))
    (is (not (cl-agent/core:error-retryable-p condition)))))

(test invariant-error-message-names-the-class-and-slot
  "错误消息带上类名与槽名——读到报错的人不必回头翻源码猜是谁违反了什么"
  (handler-case
      (cl-agent/core:require-slot (make-instance '%inv-probe) 'required "某个理由")
    (cl-agent/core:invariant-violation (e)
      (let ((text (cl-agent/core:error-message e)))
        (is (search "PROBE" (string-upcase text)) "带类名")
        (is (search "REQUIRED" (string-upcase text)) "带槽名")
        (is (search "某个理由" text) "带「为什么必填」"))
      (is (eq 'required (cl-agent/core:invariant-slot-name e))))))

;;; ============================================================
;;; 后门也堵上：一律裸 make-instance
;;; ============================================================

(test make-instance-backdoor-is-covered-for-core-carriers
  "绕过 make-* 直接 make-instance，不变式照样生效。

这是整个机制的理由：(defun make-foo ...) 只是约定俗成的入口，
CL 里没人拦得住调用方直接 make-instance。"
  ;; tool-call 缺 id/name
  (signals cl-agent/core:invariant-violation
    (make-instance 'cl-agent/core:tool-call :name "x"))
  (signals cl-agent/core:invariant-violation
    (make-instance 'cl-agent/core:tool-call :id "1"))
  ;; generation 缺 message
  (signals cl-agent/core:invariant-violation
    (make-instance 'cl-agent/core:generation :finish-reason :stop))
  ;; tool-callback 缺 definition/function——此前这条校验只在
  ;; make-tool-callback 里，make-instance 能造出一个无名工具
  (signals cl-agent/core:invariant-violation
    (make-instance 'cl-agent/core:tool-callback :function #'identity))
  ;; tool-request 缺 function
  (signals cl-agent/core:invariant-violation
    (make-instance 'cl-agent/core:tool-request))
  ;; pending-tool 缺 name
  (signals cl-agent/core:invariant-violation
    (make-instance 'cl-agent/core:pending-tool :id "1")))

(test enum-slots-reject-invented-values
  "枚举槽拒绝编造的值——这类错误最隐蔽：不报错，只是静默走错分支"
  ;; 故障分类：写错就让「声明了 :retry 的工具没重试」
  (signals cl-agent/core:invariant-violation
    (make-instance 'cl-agent/core:tool-error-info :class :timeout))
  ;; 响应状态：调用方按它分派
  (signals cl-agent/core:invariant-violation
    (make-instance 'cl-agent/core:chat-client-response :status :finished))
  ;; 注：finish-reason 曾在这里被断言拒绝 :done——那条白名单已移除。
  ;; 它是**厂商返回**的值，未知取值必须放行，见
  ;; UNKNOWN-FINISH-REASON-FROM-PROVIDER-DOES-NOT-CRASH。
  ;; HTTP 重试的退避策略：calculate-delay 按它分派
  (signals cl-agent/core:invariant-violation
    (make-instance 'cl-agent/core:retry-config :backoff :fibonacci)))

(test numeric-invariants-catch-reversed-or-negative-values
  "数值约束：写反了不会报错，只会表现为「重试太密」或「一次都不重试」"
  ;; max-attempts 是总尝试次数（含首次），0 无意义
  (signals cl-agent/core:invariant-violation
    (cl-agent/core:make-retry-policy :max-attempts 0))
  ;; backoff < 1 会让延迟越重试越短
  (signals cl-agent/core:invariant-violation
    (cl-agent/core:make-retry-policy :backoff 0.5))
  ;; max-delay < initial-delay：首次重试就被封顶
  (signals cl-agent/core:invariant-violation
    (cl-agent/core:make-retry-policy :initial-delay 10.0 :max-delay 1.0))
  ;; jitter 是比例
  (signals cl-agent/core:invariant-violation
    (cl-agent/core:make-retry-policy :jitter 2.0))
  ;; 负 token 数会一路流进计费
  (signals cl-agent/core:invariant-violation
    (cl-agent/core:make-llm-usage :input-tokens -1))
  ;; 循环上限
  (signals cl-agent/core:invariant-violation
    (cl-agent/core:make-tool-calling-config :max-iterations 0)))

(test structural-invariants-catch-wrong-shapes
  "结构约束：plist / 实例列表传错形状，当场断而不是在下游崩"
  ;; writes 是 plist，奇数长度说明传的可能是 alist
  (signals cl-agent/core:invariant-violation
    (cl-agent/core:make-tool-result :writes '((:counter . 1))))
  ;; prompt 的 messages 槽里只能是 message 实例（字符串归一由 make-prompt 负责）
  (signals cl-agent/core:invariant-violation
    (make-instance 'cl-agent/core:prompt :messages (list "裸字符串")))
  ;; state-slots 传旧的 alist 写法：当场断，而不是等到屏障折叠
  (signals cl-agent/core:invariant-violation
    (cl-agent/core:make-tool-calling-config
     :state-slots (list (list :notes :init nil :reduce #'append))))
  ;; media 两个内容槽都空
  (signals cl-agent/core:invariant-violation
    (make-instance 'cl-agent/core:media :kind :image)))

(test chat-options-deliberately-has-no-invariants
  "chat-options 刻意没有必填校验——槽 unbound **就是**「未设置」的语义。

merge-chat-options 靠 slot-boundp 实现覆盖链，options->spi-args 靠它
实现「存在才下发」。给它加必填校验会直接毁掉这个设计。
这条测试是那个决定的守卫：不是每个 unbound 槽都是漏洞。"
  (let ((options (make-instance 'cl-agent/core:chat-options)))
    (is (typep options 'cl-agent/core:chat-options))
    ;; 十几个槽全部未绑定，且这是合法状态
    (is (null (cl-agent/core:chat-options-temperature options)))
    (is (null (cl-agent/core:chat-options-model options)))))

;;; ============================================================
;;; 枚举校验的边界：外部返回值不设白名单
;;; ============================================================

(test unknown-finish-reason-from-provider-does-not-crash
  "厂商返回未映射的 finish_reason 时不能崩——这是容错设计，不是漏洞。

normalize-finish-reason 的兜底分支刻意把未知值原样转成 keyword：厂商随时
会加新值（\"safety\"、\"refusal\"…），上层用 (eq reason :tool-call) 判断，
未知值走 else 分支是正确行为。这里一度挂过白名单校验，把容错变成硬失败——
测试全是已知值所以照样绿，只有真实响应会炸。"
  (let ((normalized (cl-agent/core:normalize-finish-reason "safety")))
    (is (eq :safety normalized) "未映射的值原样转 keyword")
    ;; 构造不崩
    (let ((response (cl-agent/core:make-llm-response
                     :content "hi" :finish-reason normalized)))
      (is (eq :safety (cl-agent/core:llm-response-finish-reason response))))
    ;; 真实路径（provider 解析 → plist-to-llm-response）同样不崩
    (let ((response (cl-agent/core:plist-to-llm-response
                     (list :content "hi" :finish-reason "safety"))))
      (is (eq :safety (cl-agent/core:llm-response-finish-reason response)))))
  ;; 类型仍然要对，但**由槽的 :type 保证、不由不变式重复**——
  ;; 两种实现强制 :type 的时机不同（CCL 在槽赋值时就抛自己的
  ;; BAD-SLOT-TYPE-FROM-INITARG，早于 initialize-instance :after；
  ;; SBCL 默认不强制），所以这里断言的是「会报错」而非某个具体条件类型。
  (signals error
    (cl-agent/core:make-llm-response :finish-reason "裸字符串")))

(test enum-whitelists-only-guard-values-we-control
  "白名单只用在我方控制取值空间的槽上。

对照组：backoff 是**用户配置**（写错该报错），finish-reason 是**厂商返回**
（未知值该放行）。"
  ;; 用户配置：白名单收紧
  (signals cl-agent/core:invariant-violation
    (cl-agent/core:make-retry-config :backoff :fibonacci))
  ;; 厂商返回：只校验类型
  (is (cl-agent/core:make-llm-response :finish-reason :whatever-the-vendor-said))
  ;; 有兜底收口的分类，兜底值必须在白名单内
  (is (member (cl-agent/core:classify-tool-error
               (make-condition 'simple-error :format-control "无从判断的错误"))
              '(:semantic :transient :environment))))

(test provider-shaped-failures-name-the-real-cause
  "厂商响应缺字段时，错误消息要指向厂商/解析器，而不是让人从自己代码里找"
  (handler-case
      (cl-agent/core:plist-to-llm-response
       (list :content "hi" :tool-calls (list (list :name "foo"))))  ; 缺 id
    (cl-agent/core:invariant-violation (e)
      (is (search "厂商响应" (cl-agent/core:error-message e))
          "消息里点明这通常是厂商响应缺字段"))))
