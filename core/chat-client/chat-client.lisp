;;;; chat-client.lisp
;;;; CL-Agent ChatClient - ChatClient CLOS 类 + build-chat-client 构造函数
;;;;
;;;; 概述：
;;;;   ChatClient 是 filter 链 + 模型 + 配置的聚合载体，是 invoke-chat /
;;;;   invoke-tool / invoke-turn 三个终端函数的工厂参数。
;;;;
;;;; 四个槽（对标 Spring AI 的 ChatClient），各管一件事：
;;;;   model            往哪调                          ChatModel
;;;;   filters          链上有谁                        advisors
;;;;   default-request  请求默认长什么样                 DefaultChatClientRequestSpec
;;;;                    （system / options / tools）
;;;;   tool-calling     工具循环怎么跑                   ToolCallingAdvisor
;;;;                    （上限/闸门/执行策略/循环骨架）
;;;;
;;;; 设计要点：
;;;;   - 刻意**无 memory 槽**：记忆是 filter（message-chat-memory-filter），
;;;;     不是 chat-client 的固有属性——与 clj-agent 及 Spring AI 一致
;;;;   - 四个槽都是不可变值对象，chat-client-mutate 共享它们派生新实例
;;;;   - 便捷访问器（chat-client-tools / -max-tool-iterations / …）穿过聚合
;;;;     直接读叶子，抹平多出来的那层间接
;;;;
;;;; 收窄前是 12 个平级槽（model/tools/filters/eligibility-fn/settings/
;;;; tool-manager/state-slots/default-system/default-options/tool-gate/
;;;; loop-fn/resume-fn），其中 settings 还是个 alist——唯一的键
;;;; :max-tool-iterations 用 (cdr (assoc ...)) 读，拼错就静默回落到 10。

(in-package #:cl-agent/core)

;;; ============================================================
;;; ChatClient CLOS 类
;;; =========================================================;;;

(defclass chat-client-default-request ()
  ((system
    :initarg :system
    :initform nil
    :reader default-request-system
    :documentation "默认系统提示文本。请求级 (:system ...) 覆盖它。")
   (options
    :initarg :options
    :initform nil
    :reader default-request-options
    :documentation "默认 chat-options。请求级 (:options ...) 优先，
按 merge-chat-options 语义合并（工具列表取并集）。")
   (tools
    :initarg :tools
    :initform nil
    :reader default-request-tools
    :documentation "默认工具引用：符号列表或 tool-callback 列表
（注册顺序 = 工具名顺序）。请求级 (:tools ...) 与它取并集。"))
  (:documentation "ChatClient 的默认请求（对标 Spring AI 的
DefaultChatClientRequestSpec）。

  「每次请求都长这样，除非本次另有指定」的那一份。把 system / options /
  tools 三者聚在一起，而不是散成 chat-client 的三个平级槽——它们在语义上
  是一个东西：请求的默认形状。"))

(definvariants chat-client-default-request (self)
  (require-type self 'system 'string "默认系统提示是文本")
  (require-type self 'options 'chat-options)
  (require-that self (listp (default-request-tools self))
                "tools 是符号或 tool-callback 的列表"))

(defun make-chat-client-default-request (&key system options tools)
  "创建 chat-client 的默认请求。"
  (make-instance 'chat-client-default-request
                 :system system :options options :tools tools))

(defclass tool-calling-config ()
  ((max-iterations
    :initarg :max-iterations
    :initform 10
    :type fixnum
    :reader tool-calling-max-iterations
    :documentation "工具循环上限：最多执行多少轮工具。

超限抛 max-tool-iterations-exceeded-error。注意「轮」指真的执行了工具的
那些轮——不带工具调用的最终答复轮不计入，也不受限。

此前这个值藏在 chat-client 的 settings alist 里（:max-tool-iterations），
读法是 (cdr (assoc :max-tool-iterations ...))，键名拼错就静默回落到 10。")
   (eligibility-fn
    :initarg :eligibility-fn
    :initform (constantly t)
    :reader tool-calling-eligibility-fn
    :documentation "续跑判据：(chat-response context) → boolean。
判断携带 tool-calls 的响应是否应当真的进入工具执行。缺省 (constantly t)。")
   (tool-gate
    :initarg :tool-gate
    :initform nil
    :reader tool-calling-tool-gate
    :documentation "工具审批闸门（HITL）：(tool-call) → :proceed | :pause
| (:pause . 原因)。nil = 不审批，全部直接执行。

在**批执行之前**对本批每个 tool-call 恰好评估一次；任一判 :pause 则整轮
暂停（工具一个都不执行），循环返回 chat-client-response(:paused)，
调用方审批后用 resume-turn 续跑。")
   (state-slots
    :initarg :state-slots
    :initform nil
    :reader tool-calling-state-slots
    :documentation "state-slot 实例列表。

决定工具批次 :writes 在屏障处（apply-writes）的合并语义：
声明了 reducer 的槽用它折叠（老值缺席时用 init）；未声明的槽
last-writer——后写覆盖，按 tool-call 原始序确定，与并行执行的
实际交错无关。同批被写 ≥2 次且无 reducer 的键会告警。

  (list (make-state-slot :notes :reduce-fn #'append))")
   (tool-manager
    :initarg :tool-manager
    :initform nil
    :reader tool-calling-tool-manager
    :documentation "ToolCallingManager 实例（可注入执行策略）。
nil = 走 invoke-tool-batch 原路径；非 nil = 经 execute-tool-calls 协议。")
   (loop-fn
    :initarg :loop-fn
    :initform nil
    :reader tool-calling-loop-fn
    :documentation "工具循环实现：(chat-client request) → chat-client-response。
nil（缺省）= run-tool-loop。

它是 :turn 链的 terminal——换掉它就是换掉整个循环骨架（ReAct、
plan-execute 等），而 :turn 链的 filter 完全无感、照常环绕。
契约与 run-tool-loop 同形。

自定义循环若要支持 HITL 暂停，必须**同时**提供 resume-fn：
它自己定义暂停快照长什么样，默认的实现读不懂。
不提供也没关系——不产生 chat-client-response(:paused) 就永远走不到 resume。")
   (resume-fn
    :initarg :resume-fn
    :initform nil
    :reader tool-calling-resume-fn
    :documentation "暂停延续实现：(chat-client loop-state decision payload)
→ chat-client-response。nil（缺省）= 内建的 %resume-continuation。

与 loop-fn 成对：换了循环就连它的暂停延续一起换。resume-turn 把它装在
:turn 链的 terminal 第一次调用处，之后的 filter 递归重入走 loop-fn。"))
  (:documentation "工具循环的全部配置（对标 Spring AI 的 ToolCallingAdvisor）。

  Spring AI 把这些做成一个 Advisor 的实例状态；cl-agent 的循环是 :turn 链的
  terminal 而非 filter（filter 钩子只拿到 (req chain)，够不着执行工具所需的
  chat-client），所以配置聚在这个值对象里、由 chat-client 持有一个槽。
  收敛前它们是 chat-client 上七个平级槽外加一个 settings alist。"))

(defun make-tool-calling-config (&key (max-iterations 10) eligibility-fn tool-gate
                                      state-slots tool-manager loop-fn resume-fn)
  "创建工具循环配置。"
  (make-instance 'tool-calling-config
                 :max-iterations max-iterations
                 :eligibility-fn (or eligibility-fn (constantly t))
                 :tool-gate tool-gate
                 :state-slots state-slots
                 :tool-manager tool-manager
                 :loop-fn loop-fn
                 :resume-fn resume-fn))

(definvariants tool-calling-config (self)
  (require-that self (>= (tool-calling-max-iterations self) 1)
                "max-iterations 至少为 1——0 表示一轮工具都不许执行，~
那应该通过不给工具来表达")
  (require-callable self 'eligibility-fn "(response context) → boolean")
  (require-callable self 'tool-gate "(tool-call) → :proceed | :pause | (:pause . 原因)")
  (require-callable self 'loop-fn "(chat-client request) → chat-client-response")
  (require-callable self 'resume-fn
                    "(chat-client loop-state decision payload) → chat-client-response")
  ;; state-slots 是 state-slot 实例列表——传旧的 alist 写法在这里当场断，
  ;; 而不是等到某个工具真的声明了 :writes、走到屏障折叠时才崩。
  (require-that self (every (lambda (x) (typep x 'state-slot))
                            (tool-calling-state-slots self))
                "state-slots 必须是 state-slot 实例列表（旧写法是 ~
((key :init v :reduce fn) ...) 的 alist，用 make-state-slot 改写）"))

(defclass chat-client ()
  ((model
    :initarg :model
    :initform nil
    :reader chat-client-model
    :documentation "chat-model 实例（LLM 服务入口）")
   (filters
    :initarg :filters
    :initform nil
    :reader chat-client-filters
    :documentation "filter 实例列表（注册顺序 = 洋葱层级：靠前 = 最外层）")
   (default-request
    :initarg :default-request
    :initform nil
    :reader chat-client-default-request
    :documentation "chat-client-default-request 实例：默认 system / options / tools")
   (tool-calling
    :initarg :tool-calling
    :initform nil
    :reader chat-client-tool-calling
    :documentation "tool-calling-config 实例：工具循环的全部配置"))
  (:documentation "ChatClient 聚合（对标 Spring AI ChatClient）。

  四个槽，各管一件事：
    model           往哪调
    filters         链上有谁
    default-request 请求默认长什么样（system / options / tools）
    tool-calling    工具循环怎么跑（上限 / 闸门 / 执行策略 / 循环骨架）

  刻意**没有** memory 槽：记忆是 filter（message-chat-memory-filter），
  不是 chat-client 的固有属性——与 clj-agent 及 Spring AI 一致。

  收窄前是 12 个平级槽（model/tools/filters/eligibility-fn/settings/
  tool-manager/state-slots/default-system/default-options/tool-gate/
  loop-fn/resume-fn），其中 settings 还是个 alist。"))

;;; ============================================================
;;; 便捷访问器：穿过聚合读到叶子
;;; ============================================================
;;; 收窄的代价是多一层间接。这几个访问器把它抹平——调用点写
;;; (chat-client-tools k) 而不是 (default-request-tools (chat-client-default-request k))，
;;; 且默认聚合缺席时（build-chat-client 之外手工 make-instance）不炸。

(defun chat-client-tools (chat-client)
  "默认工具引用列表。"
  (let ((request (chat-client-default-request chat-client)))
    (when request (default-request-tools request))))

(defun chat-client-default-system (chat-client)
  "默认系统提示文本。"
  (let ((request (chat-client-default-request chat-client)))
    (when request (default-request-system request))))

(defun chat-client-default-options (chat-client)
  "默认 chat-options。"
  (let ((request (chat-client-default-request chat-client)))
    (when request (default-request-options request))))

(defun chat-client-tool-calling-config (chat-client)
  "工具循环配置；未配时给一份全缺省的，让循环代码不必到处判空。"
  (or (chat-client-tool-calling chat-client)
      (make-tool-calling-config)))

(defun chat-client-max-tool-iterations (chat-client)
  (tool-calling-max-iterations (chat-client-tool-calling-config chat-client)))

(defun chat-client-eligibility-fn (chat-client)
  (tool-calling-eligibility-fn (chat-client-tool-calling-config chat-client)))

(defun chat-client-tool-gate (chat-client)
  (tool-calling-tool-gate (chat-client-tool-calling-config chat-client)))

(defun chat-client-state-slots (chat-client)
  (tool-calling-state-slots (chat-client-tool-calling-config chat-client)))

(defun chat-client-tool-manager (chat-client)
  (tool-calling-tool-manager (chat-client-tool-calling-config chat-client)))

(definvariants chat-client (self)
  ;; 四个槽都允许缺席（便捷访问器会兜底），但类型不能错——给错了要到第一次
  ;; 对话时才炸，那时错误现场离装配点已经很远。
  (require-type self 'default-request 'chat-client-default-request)
  (require-type self 'tool-calling 'tool-calling-config)
  (require-that self (every (lambda (f) (typep f 'filter))
                            (chat-client-filters self))
                "filters 必须是 filter 实例列表"))

(defmethod print-object ((chat-client chat-client) stream)
  (print-unreadable-object (chat-client stream :type t)
    (format stream "~A filters=~A"
            (chat-client-model chat-client)
            (length (chat-client-filters chat-client)))))

;;; ============================================================
;;; build-chat-client
;;; =========================================================;;;

(defun build-chat-client (&key model tools filters eligibility-fn tool-manager
                          system options tool-gate state-slots loop-fn resume-fn
                          (max-tool-iterations 10) default-request tool-calling
                          (settings nil settings-p))
  "构建 ChatClient 实例。

参数（扁平形式，构造函数负责聚合成 default-request / tool-calling）：
  - model               chat-model 实例（LLM 服务）
  - filters             filter 实例列表（注册顺序 = 执行顺序；缺省 nil）

  默认请求：
  - system              默认系统提示文本；请求级 (:system ...) 覆盖它
  - options             默认 chat-options；请求级 (:options ...) 优先合并
  - tools               默认工具引用（符号/tool-callback 列表；缺省 nil）

  工具循环：
  - max-tool-iterations 循环上限（缺省 10）
  - eligibility-fn      (response context) → boolean（缺省 (constantly t)）
  - tool-gate           工具审批闸门 (tool-call) → :proceed | :pause | (:pause . 原因)；
                        nil（缺省）= 不审批。判 :pause → 整轮暂停，
                        用 resume-turn 续跑
  - state-slots         状态槽声明 ((key :init v0 :reduce fn) ...)——工具批次
                        :writes 的合并语义（未声明的槽 last-writer，按 call 序）
  - tool-manager        ToolCallingManager 实例（缺省 nil = 走原路径；
                        推荐 (make-virtual-thread-tool-calling-manager) 或
                        (make-sequential-tool-calling-manager)）
  - loop-fn             自定义工具循环 (chat-client request) → chat-client-response；
                        nil（缺省）= run-tool-loop。它是 :turn 链的 terminal，
                        换掉它即换掉循环骨架，:turn filter 照常环绕
  - resume-fn           自定义暂停延续 (chat-client loop-state decision payload)
                        → chat-client-response；nil（缺省）= 内建实现。与 loop-fn
                        成对：自定义循环要支持 HITL 就必须两个一起给

  直接给聚合对象（与上面的扁平参数二选一，给了就整体覆盖）：
  - default-request     chat-client-default-request 实例
  - tool-calling        tool-calling-config 实例

  - settings            **已移除**。传了直接报错并给出迁移指引——唯一的键
                        :max-tool-iterations 现在是具名参数。

返回值：chat-client 实例。

示例：
  (build-chat-client :model m
                :system \"你是一个天气助手\"
                :options (make-chat-options :temperature 0.3)
                :filters (list (memory-filter mem))
                :tools '(get-weather)
                :max-tool-iterations 5)"
  ;; 显式报错而非静默接受：settings 的读法是 (cdr (assoc :max-tool-iterations ...))，
  ;; 键名拼错就静默回落到 10——正是把它改成具名槽的理由。留一层「仍然接受」
  ;; 的兼容壳等于把那个读法留在原地，只是换了个入口。
  (when settings-p
    (error "build-chat-client 不再接受 :settings——唯一的键 :max-tool-iterations~@
            现在是具名参数：~@
              (build-chat-client :model m :max-tool-iterations ~A)~@
            旧写法 :settings '((:max-tool-iterations . N)) 的读法是~@
            (cdr (assoc ...))，键名拼错会静默回落到 10。"
           (or (cdr (assoc :max-tool-iterations settings)) 10)))
  (make-instance
   'chat-client
   :model model
   :filters (or filters nil)
   :default-request (or default-request
                        (make-chat-client-default-request
                         :system system :options options :tools tools))
   :tool-calling (or tool-calling
                     (make-tool-calling-config
                      :max-iterations max-tool-iterations
                      :eligibility-fn eligibility-fn
                      :tool-gate tool-gate
                      :state-slots state-slots
                      :tool-manager tool-manager
                      :loop-fn loop-fn
                      :resume-fn resume-fn))))

;;; ============================================================
;;; chat-client-mutate：派生一个改了若干处的 ChatClient
;;; ============================================================

(defun chat-client-mutate (chat-client &key
                                         (model nil model-p)
                                         (filters nil filters-p)
                                         (default-request nil default-request-p)
                                         (tool-calling nil tool-calling-p))
  "复制 CHAT-CLIENT 并替换指定的槽，未指定的原样共享（对标 ChatClient#mutate）。

  派生一个「除了这一处以外都一样」的 ChatClient：加一个 filter、换一个
  gate、临时提高循环上限。四个槽都是不可变值对象，共享安全。

  要改聚合里的某一项（如只换 tool-gate），先用 tool-calling-config-mutate
  造新配置再传进来。"
  (make-instance 'chat-client
                 :model (if model-p model (chat-client-model chat-client))
                 :filters (if filters-p filters (chat-client-filters chat-client))
                 :default-request (if default-request-p
                                      default-request
                                      (chat-client-default-request chat-client))
                 :tool-calling (if tool-calling-p
                                   tool-calling
                                   (chat-client-tool-calling chat-client))))

(defun tool-calling-config-mutate (config &key
                                            (max-iterations nil max-iterations-p)
                                            (eligibility-fn nil eligibility-fn-p)
                                            (tool-gate nil tool-gate-p)
                                            (state-slots nil state-slots-p)
                                            (tool-manager nil tool-manager-p)
                                            (loop-fn nil loop-fn-p)
                                            (resume-fn nil resume-fn-p))
  "复制 CONFIG 并替换指定字段，未指定的原样保留。

  CONFIG 为 NIL 时以全缺省配置为基底——chat-client 的 tool-calling 槽
  允许缺席，调用方不必先判空。"
  (let ((config (or config (make-tool-calling-config))))
    (make-instance 'tool-calling-config
                   :max-iterations (if max-iterations-p
                                       max-iterations
                                       (tool-calling-max-iterations config))
                   :eligibility-fn (if eligibility-fn-p
                                       (or eligibility-fn (constantly t))
                                       (tool-calling-eligibility-fn config))
                   :tool-gate (if tool-gate-p tool-gate (tool-calling-tool-gate config))
                   :state-slots (if state-slots-p
                                    state-slots
                                    (tool-calling-state-slots config))
                   :tool-manager (if tool-manager-p
                                     tool-manager
                                     (tool-calling-tool-manager config))
                   :loop-fn (if loop-fn-p loop-fn (tool-calling-loop-fn config))
                   :resume-fn (if resume-fn-p resume-fn (tool-calling-resume-fn config)))))

(defmethod print-object ((request chat-client-default-request) stream)
  (print-unreadable-object (request stream :type t)
    (format stream "~:[~;system ~]~A tools"
            (default-request-system request)
            (length (default-request-tools request)))))

(defmethod print-object ((config tool-calling-config) stream)
  (print-unreadable-object (config stream :type t)
    (format stream "max=~A~:[~; gated~]"
            (tool-calling-max-iterations config)
            (tool-calling-tool-gate config))))
