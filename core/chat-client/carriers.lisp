;;;; carriers.lisp
;;;; CL-Agent ChatClient - 三链请求/响应载体
;;;;
;;;; 概述：
;;;;   ChatClient 架构里 chat / tool / turn 三条链各自携带不同的请求/响应
;;;;   结构。Chat 链不用专门的载体——请求就是 cl-agent/core:prompt，
;;;;   响应就是 chat-response，够用且少一层包装。本文件定义 tool 链与
;;;;   turn 链的载体类。
;;;;
;;;;   （历史：早期 chat 链复用过 cl-agent/client 的 client-request /
;;;;   client-response；该包已随 Spring AI 移植层一并删除。）
;;;;
;;;;   Tool 链：
;;;;     tool-request  = function + args + context
;;;;     tool-result   = value + writes + error
;;;;
;;;;   Turn 链（ChatClient 层，对标 Spring AI ChatClientRequest/Response）：
;;;;     chat-client-request  = prompt + context + resume-p
;;;;     chat-client-response = status + chat-response + context + HITL 字段
;;;;
;;;;   命名对照：这两个类曾叫 turn-request / turn-result，槽也不同——
;;;;   request 存裸 messages（请求级 options 走 context 的 :caller-options
;;;;   暗管道），result 的 chat-response 槽叫 response、context 槽叫
;;;;   tool-context。改名同时把这两处语义摆正。
;;;;
;;;;   所有载体均为普通 CLOS 值对象，零行为、不含协议方法——filter 钩子
;;;;   直接对它们做 (req chain) → resp 的函数调用。

(in-package #:cl-agent/core)

;;; ============================================================
;;; Tool 链载体
;;; ============================================================

(defclass tool-request ()
  ((function
    :initarg :function
    :reader tool-request-function
    :documentation "tool-callback 或工具元数据（符号/ToolCallback/function）")
   (args
    :initarg :args
    :initform nil
    :reader tool-request-args
    :documentation "工具参数 plist")
   (context
    :initarg :context
    :initform nil
    :reader tool-request-context
    :documentation "工具上下文 plist（filter 间共享）"))
  (:documentation "Tool 链请求载体（chat-client 工具调用请求）"))

(definvariants tool-request (self)
  (require-slot self 'function "要执行哪个工具——没有它这个请求无从分派"))

(defun make-tool-request (function &key args context)
  "创建 tool-request。ARGS 缺省 nil，CONTEXT 缺省 nil。"
  (make-instance 'tool-request
                 :function function
                 :args args
                 :context context))

(defclass state-slot ()
  ((key
    :initarg :key
    :reader state-slot-key
    :documentation "context 里的键（keyword）")
   (init
    :initarg :init
    :initform nil
    :reader state-slot-init
    :documentation "初值：reducer 首次折叠、而 context 里还没有该键时用它")
   (reduce-fn
    :initarg :reduce-fn
    :initform nil
    :reader state-slot-reduce-fn
    :documentation "(老值 新值) → 合并值。NIL = last-writer（后写覆盖）。

按 tool-call 原始序折叠，与并行执行的实际交错无关——这是合并确定性的来源。"))
  (:documentation "一个状态槽的合并语义声明。

  决定工具批次 :writes 在屏障处（apply-writes）怎么合并：声明了 reducer
  的槽用它折叠，没声明的 last-writer。同批被写 ≥2 次且无 reducer 的键
  会被报为冲突（last-writer 会静默丢掉先写的值）。

  曾是 (key :init v0 :reduce fn) 这样的 alist 套 plist：条目结构靠
  (rest (assoc key slots)) + getf 现场解读，:reduce 拼成 :reducer 就退化成
  last-writer——不报错，只是累加变成了覆盖。"))

(defun make-state-slot (key &key init reduce-fn)
  "创建状态槽声明。

  (make-state-slot :notes :init nil :reduce-fn #'append)
    → :notes 累加而非覆盖"
  (make-instance 'state-slot :key key :init init :reduce-fn reduce-fn))

(definvariants state-slot (self)
  (require-slot self 'key "context 里的键，折叠时按它查找")
  (require-type self 'key 'keyword)
  (require-callable self 'reduce-fn "NIL 表示 last-writer；给了就得能调用"))

(defmethod print-object ((slot state-slot) stream)
  (print-unreadable-object (slot stream :type t)
    (format stream "~S~:[ last-writer~; reduced~]"
            (state-slot-key slot) (state-slot-reduce-fn slot))))

(defun find-state-slot (slots key)
  "在声明列表里找 KEY 的 state-slot，没有则 NIL。"
  (find key slots :key #'state-slot-key))

(defclass resume-payload ()
  ((message
    :initarg :message
    :initform nil
    :reader resume-payload-message
    :documentation ":rejected 时是拒绝理由，:reply 时是答复文本（后者必填）")
   (args
    :initarg :args
    :initform nil
    :reader resume-payload-args
    :documentation ":approved 时的新参数 plist——编辑后批准，pending 工具
用这份参数执行。NIL = 按原参数执行。"))
  (:documentation "HITL 续跑决定的随行数据（对应 resume-turn 的 :payload）。

  哪个决定该带哪个字段是有约束的（:reply 必须有 message），此前是裸
  plist，约束只能等到 %resume-gate 里才发现。"))

(defun make-resume-payload (&key message args)
  "创建续跑载荷。"
  (make-instance 'resume-payload :message message :args args))

(definvariants resume-payload (self)
  ;; args 是编辑后批准时替换给工具的参数 plist
  (require-that self (evenp (length (resume-payload-args self)))
                "args 是参数 plist，长度必须为偶数"))

(defun coerce-resume-payload (payload)
  "把 PAYLOAD 归一成 resume-payload 实例。

  接受 resume-payload 实例、plist (:message ... :args ...)、或 NIL。
  plist 形式仍然接受——它是 resume-turn 最自然的调用写法
  （(resume-turn k s :reply :payload '(:message \"...\"))），
  归一在入口处一次完成，内部只面对实例。"
  (etypecase payload
    (null (make-resume-payload))
    (resume-payload payload)
    (list (make-resume-payload :message (getf payload :message)
                               :args (getf payload :args)))))

(defmethod print-object ((payload resume-payload) stream)
  (print-unreadable-object (payload stream :type t)
    (format stream "~@[msg ~S~]~@[ args ~S~]"
            (resume-payload-message payload)
            (resume-payload-args payload))))

(defclass tool-error-info ()
  ((class
    :initarg :class
    :initform :semantic
    :reader tool-error-class
    :documentation "故障分类：:semantic | :transient | :environment。

**故障路由按它分派**——只有 :transient 且工具声明了 :retry 才重试
（见 batch.lisp 的 execute-with-retry）。这正是它必须是具名槽的理由：
此前它是 plist 里的一个键，拼错就静默变 NIL，而 NIL 不等于 :transient，
表现出来只是「声明了 :retry 的工具没有重试」——不报错，只是没生效。")
   (message
    :initarg :message
    :initform nil
    :reader tool-error-message
    :documentation "错误文本（回传给模型的那句）")
   (cause
    :initarg :cause
    :initform nil
    :reader tool-error-cause
    :documentation "原始 condition（可为 NIL）。分类丢失了细节时的兜底线索。"))
  (:documentation "工具执行失败的结构化描述。

  曾是 (list :class ... :message ...) 裸 plist，在 batch.lisp /
  timeout.lisp / invoke.lisp 三处手工构造——三份写法各自漂移的空间，
  而它承载的是故障路由的判据。"))

(defun make-tool-error-info (&key (class :semantic) message cause)
  "创建工具错误信息。CLASS 缺省 :semantic（保守：不重试）。"
  (make-instance 'tool-error-info :class class :message message :cause cause))

(definvariants tool-error-info (self)
  ;; 故障路由按 class 分派（只有 :transient 会重试），未知值会静默退化成
  ;; 「不重试」——不报错、不告警，只表现为「声明了 :retry 的工具没重试」。
  (require-member self 'class '(:semantic :transient :environment)
                  "故障路由按它分派"))

(defmethod print-object ((info tool-error-info) stream)
  (print-unreadable-object (info stream :type t)
    (format stream "~A~@[ ~S~]" (tool-error-class info) (tool-error-message info))))

(defclass tool-result ()
  ((value
    :initarg :value
    :initform nil
    :reader tool-result-value
    :documentation "工具返回结果（任意值；遵循 deftool 函数返回值）")
   (writes
    :initarg :writes
    :initform nil
    :reader tool-result-writes
    :documentation "状态写意图 plist（:key value ...）。

来源：工具函数返回 (values 结果 writes-plist)，或 :tool filter 自己
构造带 :writes 的 tool-result。工具在并行中拿到的 context 是**只读
快照**，写经此声明——批次屏障（fold-batch-writes → apply-writes）
按 tool-call 原始序折叠进 context，合并语义由 chat-client 的 :state-slots
声明（未声明的槽 last-writer）。失败调用（error 非 nil）的写意图
不生效。")
   (error
    :initarg :error
    :initform nil
    :reader tool-result-error
    :documentation "tool-error-info 实例，或 NIL（成功）"))
  (:documentation "Tool 链响应载体（chat-client 工具执行结果）。

命名：与 turn 链的 turn-request → turn-result 对称。
曾叫 tool-response——与 cl-agent/core:tool-response（协议消息层的
「工具响应」值对象：id/name/text）撞名，逼得 chat-client 必须 shadow，
下游想同时 :use 两个包还得自己写 shadowing-import。两者本就是不同
层的东西：chat 的是发回模型的消息，chat-client 的是执行链的结果载体。
改名后撞名消失，shadow 也随之删除。"))

(definvariants tool-result (self)
  ;; writes 是 plist（:key value ...），屏障折叠时按 cddr 遍历——传错结构
  ;; 会在 apply-writes 里崩，而那已经离工具返回很远了。
  (require-that self (evenp (length (tool-result-writes self)))
                "writes 是 plist，长度必须为偶数")
  (require-type self 'error 'tool-error-info))

(defun make-tool-result (&key value writes error)
  "创建 tool-result。"
  (make-instance 'tool-result
                 :value value
                 :writes writes
                 :error error))

;;; ============================================================
;;; Turn 链载体
;;; ============================================================

(defclass chat-client-request ()
  ((prompt
    :initarg :prompt
    :initform nil
    :reader chat-client-request-prompt
    :documentation "本轮的完整输入：prompt 实例（messages + options）。

持有 prompt 而非裸 messages，是与 Spring AI 的 ChatClientRequest 对齐，
也消除了一条暗管道：此前请求级 options 是塞进 context 的 :caller-options
键偷传给 run-tool-loop 的，循环里再把它取出来合并、并在折进
tool-context 时特意剔除「不外泄」。options 是请求的一等成分，
就该和 messages 装在同一个 prompt 里。")
   (context
    :initarg :context
    :initform nil
    :reader chat-client-request-context
    :documentation "上下文 plist（filter 间共享的开放字典）。

对标 ChatClientRequest 的 Map<String,Object> context——刻意保持开放
字典语义：filter 之间传什么由它们自己约定，框架不预设键名。")
   (resume-p
    :initarg :resume-p
    :initform nil
    :reader chat-client-request-resume-p
    :documentation "是否从暂停恢复（HITL 续跑用）"))
  (:documentation "ChatClient 链请求载体（对标 Spring AI ChatClientRequest）。

  一轮对话的输入：prompt + context。:turn 链的 filter 拿到的就是它。"))

(defun make-chat-client-request (prompt &key context resume-p)
  "创建 chat-client-request。

  PROMPT 可以是 prompt 实例、消息列表或字符串——后两者自动包装
  （与 chat-model-call 的入参约定一致，调用方不必为了造载体而先建 prompt）。"
  (make-instance 'chat-client-request
                 :prompt (etypecase prompt
                           (prompt prompt)
                           (null nil)
                           (string (make-prompt prompt))
                           (list (make-prompt prompt)))
                 :context context
                 :resume-p resume-p))

(definvariants chat-client-request (self)
  (require-type self 'prompt 'prompt))

(defun chat-client-request-messages (request)
  "便捷读取：请求 prompt 的消息列表。

  :turn filter 绝大多数只关心 messages（RAG 注入、re-reading 改写、
  safeguard 扫描），不必每次都穿两层。"
  (let ((prompt (chat-client-request-prompt request)))
    (when prompt (prompt-messages prompt))))

(defun chat-client-request-options (request)
  "便捷读取：请求 prompt 的 chat-options（可为 NIL）。"
  (let ((prompt (chat-client-request-prompt request)))
    (when prompt (prompt-options prompt))))

(defun chat-client-request-mutate (request &key (messages nil messages-p)
                                                (options nil options-p)
                                                (context nil context-p)
                                                (resume-p nil resume-p-p))
  "复制 REQUEST 并替换指定字段，未指定的原样保留（对标 ChatClientRequest#mutate）。

  这是 :turn filter 改写请求的正道。手写 make-chat-client-request 重建
  很容易漏字段——旧代码里就有 filter 只传了 :context、把 resume-p 丢成
  nil 的写法（当时靠分支条件恰好绕开，属于运气而非设计）。mutate 从结构上
  消除这类遗漏。"
  (make-instance
   'chat-client-request
   :prompt (if (or messages-p options-p)
               (make-prompt (if messages-p
                                messages
                                (chat-client-request-messages request))
                            :options (if options-p
                                         options
                                         (chat-client-request-options request)))
               (chat-client-request-prompt request))
   :context (if context-p context (chat-client-request-context request))
   :resume-p (if resume-p-p resume-p (chat-client-request-resume-p request))))

(defmethod print-object ((request chat-client-request) stream)
  (print-unreadable-object (request stream :type t)
    (format stream "~A msgs~:[~; resume~]"
            (length (chat-client-request-messages request))
            (chat-client-request-resume-p request))))

;;; ============================================================
;;; 暂停载体（HITL）
;;; ============================================================

(defclass loop-state ()
  ((messages
    :initarg :messages
    :initform nil
    :reader loop-state-messages
    :documentation "暂停时刻的消息列表（尚未含本轮 assistant/工具结果）")
   (response
    :initarg :response
    :initform nil
    :reader loop-state-response
    :documentation "触发暂停的那条 assistant 响应（携带 tool-calls）")
   (tool-calls
    :initarg :tool-calls
    :initform nil
    :reader loop-state-tool-calls
    :documentation "本批全部 tool-call——**都还没执行**")
   (pending-id
    :initarg :pending-id
    :initform nil
    :reader loop-state-pending-id
    :documentation "被 gate 判为 :pause 的那个 tool-call 的 id（resume 定位用）")
   (iteration
    :initarg :iteration
    :initform 0
    :reader loop-state-iteration
    :documentation "暂停发生在第几轮（resume 后接着数，仍受 max-tool-iterations 约束）")
   (options
    :initarg :options
    :initform nil
    :reader loop-state-options
    :documentation "本轮已解析的 chat-options（含 tool-callbacks）")
   (context
    :initarg :context
    :initform nil
    :reader loop-state-context
    :documentation "暂停时刻的 turn context"))
  (:documentation "工具循环的暂停快照——resume 靠它从中点续跑。

刻意不含 chat-client/gate/callbacks：那些是代码侧的东西，resume 时重新提供。
本类只装「续跑所需的数据」。"))

(definvariants loop-state (self)
  ;; 快照的用途只有一个：喂给 resume-turn 从中点续跑。iteration 是续跑的
  ;; 起点，负数会让循环上限的计数从错误的地方开始。
  (require-type self 'iteration '(integer 0))
  (require-that self (>= (loop-state-iteration self) 0)
                "iteration 是续跑的起点轮次，不能为负"))

(defun make-loop-state (&key messages response tool-calls pending-id
                             (iteration 0) options context)
  "创建 loop-state。"
  (make-instance 'loop-state
                 :messages messages :response response
                 :tool-calls tool-calls :pending-id pending-id
                 :iteration iteration :options options :context context))

(defclass pending-tool ()
  ((name
    :initarg :name
    :reader pending-tool-name
    :documentation "待审批的工具名")
   (args
    :initarg :args
    :initform nil
    :reader pending-tool-args
    :documentation "待审批的工具参数 plist")
   (id
    :initarg :id
    :initform nil
    :reader pending-tool-id
    :documentation "对应的 tool-call id"))
  (:documentation "待审批工具的描述（给审批方看的，不含执行逻辑）"))

(definvariants pending-tool (self)
  ;; 审批方看的就是这个对象：没有名字的待审批工具让人无从判断该不该批
  (require-slot self 'name "审批方靠它判断在批什么"))

(defun make-pending-tool (&key name args id)
  (make-instance 'pending-tool :name name :args args :id id))

(defmethod print-object ((p pending-tool) stream)
  (print-unreadable-object (p stream :type t)
    (format stream "~A ~S" (pending-tool-name p) (pending-tool-args p))))

(defclass chat-client-response ()
  ((status
    :initarg :status
    :reader chat-client-response-status
    :documentation ":completed | :paused | :cancelled | :error")
   (chat-response
    :initarg :chat-response
    :initform nil
    :reader chat-client-response-chat-response
    :documentation "最终 chat-response，或 NIL（出错/被拦时为 NIL）。

对标 ChatClientResponse 的 chatResponse 字段：ChatClient 层的响应
包着 ChatModel 层的响应，而不是取代它。")
   (context
    :initarg :context
    :initform nil
    :reader chat-client-response-context
    :documentation "折叠完全部工具批次 :writes 后的最终 context plist——
工具经写意图累积的状态由此交还调用方。无工具/无写意图时是轮初
context 原样。

对标 ChatClientResponse 的 context 字段：请求带进来的开放字典，
经过整轮之后带出去。（此前叫 tool-context，名字暗示「只有工具用」，
实际是整条 :turn 链共享的那一份。）")
   (tool-calls-made
    :initarg :tool-calls-made
    :initform nil
    :reader chat-client-response-tool-calls-made
    :documentation "本轮已执行的工具调用轮数（循环上限判断用）")
   (loop-state
    :initarg :loop-state
    :initform nil
    :reader chat-client-response-loop-state
    :documentation ":paused 时的续跑快照（喂给 resume-turn）；其余状态为 NIL")
   (pending-tool
    :initarg :pending-tool
    :initform nil
    :reader chat-client-response-pending-tool
    :documentation ":paused 时待审批的工具（name/args/id）；其余状态为 NIL")
   (pause-reason
    :initarg :pause-reason
    :initform nil
    :reader chat-client-response-pause-reason
    :documentation ":paused 的原因（gate 给的说明文本）"))
  (:documentation "ChatClient 链响应载体（对标 Spring AI ChatClientResponse）。

  比 Spring AI 的多出 status / loop-state / pending-tool / pause-reason
  四项：Spring AI 的 ChatClient 是同步到底的，没有 HITL 暂停这一档。
  cl-agent 的工具循环可以在批执行前停下来等审批，续跑所需的一切装在
  loop-state 里交还调用方。"))

(defun make-chat-client-response (status &key chat-response context tool-calls-made
                                              loop-state pending-tool pause-reason)
  "创建 chat-client-response。STATUS 必填，其余缺省 NIL。

STATUS = :paused 时应同时给 loop-state / pending-tool / pause-reason——
resume-turn 靠 loop-state 续跑，审批方靠 pending-tool 知道在批什么。"
  (make-instance 'chat-client-response
                 :status status
                 :chat-response chat-response
                 :context context
                 :tool-calls-made tool-calls-made
                 :loop-state loop-state
                 :pending-tool pending-tool
                 :pause-reason pause-reason))

(defun chat-client-response-text (response)
  "便捷读取：最终回复文本。无 chat-response（被拦/出错）时返回 NIL。"
  (let ((chat-response (chat-client-response-chat-response response)))
    (when chat-response (chat-response-text chat-response))))

(defmethod print-object ((response chat-client-response) stream)
  (print-unreadable-object (response stream :type t)
    (format stream "~A~@[ ~A tool-rounds~]"
            (chat-client-response-status response)
            (chat-client-response-tool-calls-made response))))

(definvariants chat-client-response (self)
  (require-member self 'status '(:completed :paused :cancelled :error)
                  "调用方按它分派")
  ;; :paused 却不带快照 = 一个「暂停了但无法续跑」的响应，而这只会在调用方
  ;; 真的去 resume 时才炸，离出错点很远。自定义 loop-fn 最容易踩。
  (require-that self
                (or (not (eq (chat-client-response-status self) :paused))
                    (chat-client-response-loop-state self))
                ":paused 必须携带 loop-state——没有它 resume-turn 无从续跑。~
自定义 loop-fn 产出 :paused 时，要么装上自己的快照、要么连 resume-fn 一起提供"))
