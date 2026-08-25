;;;; chat-client.lisp
;;;; CL-Agent ChatClient - ChatClient CLOS 类 + build-chat-client 构造函数
;;;;
;;;; 概述：
;;;;   ChatClient 是 filter 链 + 模型 + 工具 + 配置的聚合载体（对标
;;;;   clj-agent ChatClient）。它是 P2 invoke-chat / invoke-tool / invoke-turn
;;;;   三个终端函数的工厂参数——本阶段只落地骨架，不实现终端逻辑。
;;;;
;;;; 设计要点：
;;;;   - chat-client 极简：只存 model / tools / filters / settings / eligibility-fn
;;;;   - chat-client 无 memory 字段：记忆是 filter（message-chat-memory-filter），
;;;;     不是 chat-client 的固有属性——与 clj-agent 行为一致
;;;;   - eligibility-fn 缺省 (constantly t)：总认为"应该续跑"；
;;;;     P2 循环逻辑用它判断是否继续工具迭代
;;;;   - settings 是 alist：(:max-tool-iterations . 10) 等任意键值

(in-package #:cl-agent/core)

;;; ============================================================
;;; ChatClient CLOS 类
;;; =========================================================;;;

(defclass chat-client ()
  ((model
    :initarg :model
    :initform nil
    :reader chat-client-model
    :documentation "chat-model 实例（LLM 服务入口）")
   (tools
    :initarg :tools
    :initform nil
    :reader chat-client-tools
    :documentation "工具符号列表或 tool-callback 列表（注册顺序 = 工具名顺序）")
   (filters
    :initarg :filters
    :initform nil
    :reader chat-client-filters
    :documentation "filter 实例列表（注册顺序 = 洋葱层级：靠前 = 最外层）")
   (eligibility-fn
    :initarg :eligibility-fn
    :initform (constantly t)
    :reader chat-client-eligibility-fn
    :documentation "续跑判据：(response context) → boolean。
判断上一轮响应是否应当继续（如：是否还有未执行的 tool-call）。
缺省 (constantly t)——P2 可替换为基于 tool-call 存在与否的判断。")
   (settings
    :initarg :settings
    :initform nil
    :reader chat-client-settings
    :documentation "配置 alist（(:max-tool-iterations . 10) 等）")
   (tool-manager
    :initarg :tool-manager
    :initform nil
    :reader chat-client-tool-manager
    :documentation "ToolCallingManager 实例（可注入执行策略）。
nil = 走 invoke-tool-batch 原路径；非 nil = 经 execute-tool-calls 协议。")
   (state-slots
    :initarg :state-slots
    :initform nil
    :reader chat-client-state-slots
    :documentation "状态槽声明：((key :init 初值 :reduce (老值 新值)→合并值) ...)。

决定工具批次 :writes 在屏障处（apply-writes）的合并语义：
声明了 :reduce 的槽用它折叠（老值缺席时用 :init）；未声明的槽
last-writer——后写覆盖，按 tool-call 原始序确定，与并行执行的
实际交错无关。同批被写 ≥2 次且无 reducer 的键会告警。")
   (default-system
    :initarg :system
    :initform nil
    :reader chat-client-default-system
    :documentation "默认系统提示文本。请求级 (:system ...) 覆盖它。")
   (default-options
    :initarg :options
    :initform nil
    :reader chat-client-default-options
    :documentation "默认 chat-options。请求级 (:options ...) 优先，
按 merge-chat-options 语义合并（工具列表取并集）。")
   (tool-gate
    :initarg :tool-gate
    :initform nil
    :reader chat-client-tool-gate
    :documentation "工具审批闸门（HITL）：(tool-call) → :proceed | :pause
| (:pause . 原因)。nil = 不审批，全部直接执行。

在**批执行之前**对本批每个 tool-call 恰好评估一次；任一判 :pause 则整轮
暂停（工具一个都不执行），run-tool-loop 返回 turn-result(:paused)，
调用方审批后用 resume-turn 续跑。")
   (loop-fn
    :initarg :loop-fn
    :initform nil
    :reader chat-client-loop-fn
    :documentation "工具循环实现：(chat-client turn-request) → turn-result。
nil（缺省）= run-tool-loop。

它是 :turn 链的 terminal——换掉它就是换掉整个循环骨架（ReAct、
plan-execute 等），而 :turn 链的 filter 完全无感、照常环绕。
契约与 run-tool-loop 同形。

自定义循环若要支持 HITL 暂停，必须**同时**提供 resume-fn：
它自己定义暂停快照长什么样，默认的 %resume-continuation 读不懂。
不提供也没关系——不产生 turn-result(:paused) 就永远走不到 resume。")
   (resume-fn
    :initarg :resume-fn
    :initform nil
    :reader chat-client-resume-fn
    :documentation "暂停延续实现：(chat-client loop-state decision payload) → turn-result。
nil（缺省）= 内建的 %resume-continuation（配套 run-tool-loop）。

与 loop-fn 成对：换了循环就连它的暂停延续一起换。resume-turn 把它装在
:turn 链的 terminal 第一次调用处，之后的 filter 递归重入走 loop-fn。"))
  (:documentation "ChatClient 聚合（model/tools/filters/settings/tool-manager +
默认 system/options + loop-fn/resume-fn）——无 memory（记忆是 memory-filter
的事）。"))

(defmethod print-object ((chat-client chat-client) stream)
  (print-unreadable-object (chat-client stream :type t)
    (format stream "~A filters=~A"
            (chat-client-model chat-client)
            (length (chat-client-filters chat-client)))))

;;; ============================================================
;;; build-chat-client
;;; =========================================================;;;

(defun build-chat-client (&key model tools filters eligibility-fn settings tool-manager
                          system options tool-gate state-slots loop-fn resume-fn)
  "构建 ChatClient 实例。

参数：
  - model          chat-model 实例（LLM 服务）
  - tools          工具符号列表或 tool-callback 列表（缺省 nil）
  - filters        filter 实例列表（注册顺序 = 执行顺序；缺省 nil）
  - eligibility-fn (response context) → boolean（缺省 (constantly t)）
  - settings       配置 alist（缺省 nil）
  - tool-manager   ToolCallingManager 实例（缺省 nil = 走原路径；
                   推荐 (make-virtual-thread-tool-calling-manager) 或
                   (make-sequential-tool-calling-manager)）
  - system         默认系统提示文本；请求级 (:system ...) 覆盖它
  - options        默认 chat-options；请求级 (:options ...) 优先合并
  - tool-gate      工具审批闸门 (tool-call) → :proceed | :pause | (:pause . 原因)；
                   nil（缺省）= 不审批。判 :pause → 整轮暂停，
                   用 resume-turn 续跑
  - state-slots    状态槽声明 ((key :init v0 :reduce fn) ...)——工具批次
                   :writes 的合并语义（未声明的槽 last-writer，按 call 序）
  - loop-fn        自定义工具循环 (chat-client turn-request) → turn-result；
                   nil（缺省）= run-tool-loop。它是 :turn 链的 terminal，
                   换掉它即换掉循环骨架，:turn filter 照常环绕
  - resume-fn      自定义暂停延续 (chat-client loop-state decision payload)
                   → turn-result；nil（缺省）= 内建实现。与 loop-fn 成对：
                   自定义循环要支持 HITL 就必须两个一起给

返回值：chat-client 实例。

示例：
  (build-chat-client :model m
                :system \"你是一个天气助手\"
                :options (make-chat-options :temperature 0.3)
                :filters (list (memory-filter mem))
                :tools '(get-weather))"
  (make-instance 'chat-client
                 :model model
                 :tools (or tools nil)
                 :filters (or filters nil)
                 :eligibility-fn (or eligibility-fn (constantly t))
                 :settings (or settings nil)
                 :tool-manager tool-manager
                 :system system
                 :options options
                 :tool-gate tool-gate
                 :state-slots state-slots
                 :loop-fn loop-fn
                 :resume-fn resume-fn))
