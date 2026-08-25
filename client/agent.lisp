;;;; agent.lisp
;;;; CL-Agent Client - SimpleAgent（有状态对话 + callbacks + 错误归一化）
;;;;
;;;; 对标 clj-agent 的 im.ttalk.agent.client/create-agent + chat。
;;;;
;;;; HITL（pause/resume）：配 :on-tool-call 回调即启用——它返回
;;;; (:interrupt . 原因) 就暂停待审批，agent-resume 续跑。
;;;; 这不是另一套机制，就是回调的返回值（clj-agent 同款设计）。

(in-package #:cl-agent/client)

;;; ============================================================
;;; Agent
;;; ============================================================

(defclass agent ()
  ((id
    :initarg :id
    :reader agent-id
    :documentation "agent 实例标识（调试/日志用）")
   (chat-client
    :initarg :chat-client
    :reader agent-chat-client
    :documentation "底层 chat-client（执行内核）")
   (memory
    :initarg :memory
    :reader agent-memory
    :documentation "chat-memory store；nil = 无记忆（每轮独立）")
   (conversation-id
    :initarg :conversation-id
    :reader agent-conversation-id
    :documentation "会话 ID。agent 不自己存历史——历史由 chat-client 的
memory-filter 按这个 ID 管，agent 只持 ID。")
   (callbacks
    :initarg :callbacks
    :initform nil
    :reader agent-callbacks
    :documentation "回调 plist（:on-turn-start/:on-turn-end/:on-turn-error/
:on-tool-call/:on-tool-result/:on-interrupt/:on-resume）")
   (turn-count
    :initform 0
    :accessor agent-turn-count
    :documentation "已完成的 turn 数")
   (paused-state
    :initform nil
    :accessor agent-paused-state
    :documentation "暂停快照（loop-state）；nil = 未暂停"))
  (:documentation "有状态对话 agent。

线程安全：单个 agent 实例不可被多线程并发 agent-chat。每个 agent 绑定
单一对话线程；要并发就按会话各建一个 agent（共享同一个持久 store、
各自 :conversation-id 即可隔离）。"))

(cl-agent/core:definvariants agent (self)
  (cl-agent/core:require-slot self 'id "实例标识（调试/日志）")
  (cl-agent/core:require-slot self 'chat-client "底层执行内核")
  (cl-agent/core:require-type self 'chat-client 'cl-agent/core:chat-client)
  ;; memory 允许为 NIL（无记忆，每轮独立），但 conversation-id 不能——
  ;; 它是 memory-filter 按会话取历史的键，缺了会让多轮记忆静默失效。
  (cl-agent/core:require-slot self 'conversation-id
                              "memory-filter 按它取会话历史")
  (cl-agent/core:require-type self 'memory 'cl-agent/core:chat-memory))

(defmethod print-object ((a agent) stream)
  (print-unreadable-object (a stream :type t)
    (format stream "~A turns=~A~@[ conv=~A~]"
            (agent-id a) (agent-turn-count a) (agent-conversation-id a))))

;;; ============================================================
;;; callbacks
;;; ============================================================

(defun invoke-callback (agent key &rest args)
  "调用 AGENT 上名为 KEY 的回调（未注册则 no-op）。

回调里的异常不得掀翻整轮对话——它们多数是**观测**手段。
例外是 :on-tool-call：它的返回值是 HITL 的控制信号（见 agent-gate），
但即便它抛异常，也按「没表态」处理（放行），而不是让整轮崩掉。"
  (let ((fn (getf (agent-callbacks agent) key)))
    (when fn
      (handler-case (apply fn args)
        (error (e)
          (log-warn "[agent] 回调 ~A 抛出异常，已忽略：~A" key e)
          nil)))))

(defun result-filter (agent)
  "把 agent 的 :on-tool-result 桥接成一个 :tool filter。

工具**结果**只能在执行后拿到，所以走 :tool 链。
而 :on-tool-call 不在这里——它要能在执行**前**否决（返回 :interrupt），
那是 chat-client 的 tool-gate 的活，见 agent-gate。"
  (cl-agent/core:make-filter
   :agent-callbacks
   :tool (lambda (req chain)
           (let* ((cb (cl-agent/core:tool-request-function req))
                  (name (cl-agent/core:tool-callback-name cb))
                  (result (funcall chain req)))
             (invoke-callback agent :on-tool-result name
                              (cl-agent/core:tool-result->text result))
             result))))

(defun agent-gate (agent)
  "把 agent 的 :on-tool-call 桥接成 chat-client 的 tool-gate。

  :on-tool-call (name args) 的返回值决定这个工具的命运：
    nil / 其它    → 放行
    (:interrupt)  → 暂停待审批
    (:interrupt . 原因) 或 (:interrupt 原因) → 暂停，并带上原因

  这正是 clj-agent 的设计：**pause/resume 不是另一套机制，
  就是 on-tool-call 返回 interrupt**。配了这个回调就等于启用了 HITL。"
  (lambda (tool-call)
    (let* ((name (cl-agent/core:tool-call-name tool-call))
           (args (cl-agent/core:arguments->plist
                  (cl-agent/core:tool-call-arguments tool-call)))
           (verdict (invoke-callback agent :on-tool-call name args)))
      (cond
        ((null verdict) :proceed)
        ((eq verdict :interrupt) :pause)
        ((and (consp verdict) (eq (car verdict) :interrupt))
         (let ((reason (if (consp (cdr verdict)) (second verdict) (cdr verdict))))
           (if reason (cons :pause reason) :pause)))
        (t :proceed)))))

;;; ============================================================
;;; make-agent
;;; ============================================================

(defvar *agent-counter* 0)

(defun next-agent-id ()
  (format nil "agent-~D" (incf *agent-counter*)))

(defun make-agent (&key model system options tools
                        (memory :default) conversation-id
                        callbacks chat-client (max-tool-iterations 10)
                        (settings nil settings-p)
                        (filters nil filters-p))
  "创建有状态 agent。

  参数：
  - model           chat-model 实例（不给 :chat-client 时必填）
  - system          默认系统提示
  - options         默认 chat-options
  - tools           工具符号列表
  - memory          chat-memory store；:default（缺省）= 新建滑动窗口记忆；
                    nil = 无记忆（每轮独立）
  - conversation-id 会话 ID（缺省自动生成）
  - callbacks       回调 plist：
                    :on-turn-start  (agent)
                    :on-turn-end    (agent result)
                    :on-turn-error  (agent condition)
                    :on-tool-call   (name args) → 返回 (:interrupt . 原因) 触发
                                    暂停待审批（**配了它就等于启用 HITL**）
                    :on-tool-result (name text)
  - max-tool-iterations 工具循环上限（缺省 10）
  - settings        **已移除**。传了直接报错——见 build-chat-client。
  - chat-client          预构建 chat-client（要挂 filter 时用这个）

  **本层不接受 :filters**——agent 只暴露 :callbacks。要 filter 请自己
  build-chat-client 后经 :chat-client 传入。这条边界是刻意的：简单层一旦开始转发
  filter，就会慢慢长成第二个 chat-client。

  给 :chat-client 时，memory-filter 由调用方自己负责挂载（本函数不改动
  预构建 chat-client 的 filters）。

  示例：
    (make-agent :model m :system \"你是助手\" :tools '(get-weather))
    (make-agent :model m :memory nil)                      ; 无记忆
    (make-agent :chat-client my-chat-client :memory my-store)        ; 自带 filter"
  (declare (ignore filters settings))
  ;; 显式报错而非静默忽略：clj-agent 那边是 warn + ignore，但静默丢弃
  ;; 横切能力正是本仓库刚清理掉的那类坑（ChatClient 的横切槽位最后
  ;; 全成了 no-op，记忆/护栏无声失效）。宁可直接拦下并给出出路。
  (when settings-p
    (error "make-agent 不再接受 :settings——用 :max-tool-iterations。~@
            见 build-chat-client 的同名报错。"))
  (when filters-p
    (error "make-agent 不接受 :filters——agent 层只暴露 :callbacks。~@
            要挂 filter 请自建 chat-client 后经 :chat-client 传入：~@
              (make-agent :chat-client (cl-agent/core:build-chat-client~@
                                    :model m~@
                                    :filters (list ...))~@
                          :memory store)"))
  (let* ((store (cond ((eq memory :default)
                       (cl-agent/core:make-message-window-chat-memory))
                      (t memory)))
         (k (or chat-client
                (cl-agent/core:build-chat-client
                 :model model
                 :system system
                 :options options
                 :tools tools
                 :max-tool-iterations max-tool-iterations
                 :filters (remove nil
                                  (list (when store
                                          (cl-agent/core:memory-filter store))))))))
    (let ((a (make-instance 'agent
                            :id (next-agent-id)
                            :chat-client k
                            :memory store
                            :conversation-id (or conversation-id
                                                 (format nil "conv-~A" (next-agent-id)))
                            :callbacks callbacks)))
      ;; 工具回调要接到 chat-client 上，而 agent 实例此刻才建好（gate/filter 的
      ;; 闭包要捕获它）——所以这里重建一次 chat-client 把它们挂上去。
      ;;   :on-tool-result → :tool filter（结果只能在执行后拿到）
      ;;   :on-tool-call   → tool-gate（要能在执行前否决，这是 HITL 的入口）
      (when (or (getf callbacks :on-tool-call) (getf callbacks :on-tool-result))
        ;; mutate 而非重建：此前这里是把 chat-client 逐槽拆开再 build 一遍，
        ;; 每加一个 chat-client 槽都要记得在这儿补一行，漏了就静默丢配置。
        (setf (slot-value a 'chat-client)
              (cl-agent/core:chat-client-mutate
               k
               ;; 结果 filter 放最外层：它要看到全部工具调用
               :filters (if (getf callbacks :on-tool-result)
                            (cons (result-filter a) (cl-agent/core:chat-client-filters k))
                            (cl-agent/core:chat-client-filters k))
               :tool-calling (if (getf callbacks :on-tool-call)
                                 (cl-agent/core:tool-calling-config-mutate
                                  (cl-agent/core:chat-client-tool-calling k)
                                  :tool-gate (agent-gate a))
                                 (cl-agent/core:chat-client-tool-calling k)))))
      a)))

;;; ============================================================
;;; 结果载体（归一化：不抛异常）
;;; ============================================================
;;;
;;; core 的 chat 宏出错就抛条件。agent 层把它归一化成一个结果对象——
;;; 对标 clj-agent 的 {:status :completed|:error ...}。
;;; 理由：agent 是面向应用的入口，一次 LLM 调用失败是**预期内**的常态
;;; （网络抖动、限流、模型抽风），调用方该拿到状态而不是被条件掀翻。

(defstruct (agent-result (:constructor %make-agent-result))
  (status :completed :type keyword)
  (text nil)
  (response nil)
  (error nil)
  ;; :paused 时有值
  (pending-tool nil)
  (pause-reason nil))

;;; ============================================================
;;; 对话
;;; ============================================================

(defun %turn->agent-result (agent turn)
  "把 chat-client 的 chat-client-response 归一化成 agent-result，并同步 agent 的暂停态。"
  (let ((status (cl-agent/core:chat-client-response-status turn))
        (resp (cl-agent/core:chat-client-response-chat-response turn)))
    (if (eq status :paused)
        ;; 暂停：把 loop-state 记在 agent 上，等 agent-resume
        (let ((pending (cl-agent/core:chat-client-response-pending-tool turn)))
          (setf (agent-paused-state agent) (cl-agent/core:chat-client-response-loop-state turn))
          (let ((r (%make-agent-result
                    :status :paused
                    :pending-tool pending
                    :pause-reason (cl-agent/core:chat-client-response-pause-reason turn))))
            (invoke-callback agent :on-interrupt agent r)
            r))
        (progn
          (setf (agent-paused-state agent) nil)
          (incf (agent-turn-count agent))
          (let ((r (%make-agent-result
                    :status status
                    :response resp
                    :text (when resp (cl-agent/core:chat-response-text resp)))))
            (invoke-callback agent :on-turn-end agent r)
            r)))))

(defun agent-chat-result (agent message &key options tools)
  "对话，返回 agent-result（**不抛异常**）。

  status：
  - :completed  正常完成 → agent-result-text / -response
  - :paused     工具待审批（:on-tool-call 返回了 :interrupt）
                → agent-result-pending-tool 看在批什么，agent-resume 续跑
  - :cancelled  被 filter 短路（如 safeguard 命中敏感词）
  - :error      LLM/工具/其它异常 → agent-result-error 是条件对象

  上下文自动累积（同一 agent 的 conversation-id 不变）。"
  (invoke-callback agent :on-turn-start agent)
  (handler-case
      (let* ((ctx (when (agent-conversation-id agent)
                    (list :conversation-id (agent-conversation-id agent))))
             (turn (cl-agent/core:chat-client-call
                    (agent-chat-client agent)
                    :user message
                    :options options
                    :tools tools
                    :context ctx)))
        (%turn->agent-result agent turn))
    (error (e)
      (invoke-callback agent :on-turn-error agent e)
      (%make-agent-result :status :error :error e))))

;;; ============================================================
;;; pause / resume（HITL）
;;; ============================================================

(defun agent-paused-p (agent)
  "agent 是否停在待审批状态。"
  (and (agent-paused-state agent) t))

(defun agent-pending-tool (agent)
  "当前待审批的工具（未暂停时为 nil）。"
  (let ((ls (agent-paused-state agent)))
    (when ls
      (let ((pending-id (cl-agent/core:loop-state-pending-id ls)))
        (find-if (lambda (tc)
                   (equal (cl-agent/core:tool-call-id tc) pending-id))
                 (cl-agent/core:loop-state-tool-calls ls))))))

(defun agent-resume (agent decision &key payload)
  "审批后续跑，返回 agent-result（**不抛异常**）。

  decision：
  - :approved  批准。payload (:args 新参数) → 编辑后批准（用新参数执行）
  - :rejected  拒绝。payload (:message 理由) → 结果「已拒绝执行：<理由>」
               回给模型，省它一轮干猜
  - :reply     答复即结果（ask-user 语义）。payload (:message 答复) **必填**
               → pending 工具不执行，答复直接作为它的结果回模型

  续跑后可能再次 :paused（本批里还有别的敏感工具，或后续轮次又触发）。"
  (let ((ls (agent-paused-state agent)))
    (unless ls
      (error "agent 未处于暂停状态（agent-paused-p 为 nil）"))
    (invoke-callback agent :on-resume agent decision)
    (handler-case
        (let ((turn (cl-agent/core:resume-turn (agent-chat-client agent) ls decision
                                               :payload payload)))
          (%turn->agent-result agent turn))
      (error (e)
        (invoke-callback agent :on-turn-error agent e)
        ;; 续跑失败：清掉暂停态，否则会卡死在一个再也 resume 不动的快照上
        (setf (agent-paused-state agent) nil)
        (%make-agent-result :status :error :error e)))))

(defun agent-chat (agent message &key options tools)
  "对话，返回回复文本（最常用的形态）。

  出错时返回 (values nil result)——第二值是完整的 agent-result，
  可从中取 status / error。要完整结果请直接用 agent-chat-result。"
  (let ((r (agent-chat-result agent message :options options :tools tools)))
    (if (eq (agent-result-status r) :completed)
        (agent-result-text r)
        (values nil r))))

(defun agent-history (agent)
  "取该会话的完整消息历史（无记忆时返回 nil）。"
  (let ((store (agent-memory agent)))
    (when store
      (cl-agent/core:memory-messages store (agent-conversation-id agent)))))

(defun agent-reset (agent)
  "清空会话历史、暂停态与轮次计数。agent 本身可继续用。"
  (let ((store (agent-memory agent)))
    (when store
      (cl-agent/core:memory-clear store (agent-conversation-id agent))))
  (setf (agent-turn-count agent) 0)
  (setf (agent-paused-state agent) nil)
  agent)
