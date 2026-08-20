;;;; test-agent.lisp
;;;; CL-Agent - SimpleAgent（cl-agent/client）测试

(in-package :cl-agent/tests)

(def-suite agent-suite :in cl-agent-suite
  :description "SimpleAgent：有状态对话、callbacks、错误归一化")

(in-suite agent-suite)

(defun make-agent-test-model (&rest responses)
  (cl-agent/core:make-provider-chat-model (apply #'make-seq-provider responses)))

;;; ============================================================
;;; 有状态对话
;;; ============================================================

(test agent-chat-returns-text
  "agent-chat 返回回复文本"
  (let ((a (cl-agent/client:make-agent
            :model (make-agent-test-model (text-response "你好！")))))
    (is (string= "你好！" (cl-agent/client:agent-chat a "hi")))))

(test agent-accumulates-context-across-turns
  "多轮自动累积上下文——调用方不用自己传 conversation-id。
这正是 SimpleAgent 相对裸 kernel 的核心价值。"
  (let ((a (cl-agent/client:make-agent
            :model (make-agent-test-model (text-response "回复1")
                                          (text-response "回复2")))))
    (cl-agent/client:agent-chat a "我叫大卫")
    (cl-agent/client:agent-chat a "我叫什么")
    ;; 2 轮 × (user + assistant) = 4
    (is (= 4 (length (cl-agent/client:agent-history a))))
    (is (= 2 (cl-agent/client:agent-turn-count a)))))

(test agent-second-turn-sees-first-turn-history
  "第二轮请求真的带上了第一轮的历史（不只是 store 里有）"
  (let* ((provider (make-seq-provider (text-response "r1") (text-response "r2")))
         (a (cl-agent/client:make-agent
             :model (cl-agent/core:make-provider-chat-model provider))))
    (cl-agent/client:agent-chat a "第一句")
    (cl-agent/client:agent-chat a "第二句")
    ;; seq-provider 的 requests 是 push 的 → first 是最后一次调用
    (let ((second-req-msgs (getf (first (seq-provider-requests provider)) :messages)))
      ;; 第二轮应含：user1 + assistant1 + user2 = 3 条
      (is (= 3 (length second-req-msgs)))
      (is (string= "第一句" (getf (first second-req-msgs) :content))))))

(test agent-separate-agents-are-isolated
  "不同 agent 的会话互不串（各自 conversation-id）"
  (let ((a1 (cl-agent/client:make-agent
             :model (make-agent-test-model (text-response "a"))))
        (a2 (cl-agent/client:make-agent
             :model (make-agent-test-model (text-response "b")))))
    (cl-agent/client:agent-chat a1 "in-a1")
    (cl-agent/client:agent-chat a2 "in-a2")
    (is (= 2 (length (cl-agent/client:agent-history a1))))
    (is (= 2 (length (cl-agent/client:agent-history a2))))
    (is (string/= (cl-agent/client:agent-conversation-id a1)
                  (cl-agent/client:agent-conversation-id a2)))))

(test agent-memory-nil-means-no-history
  ":memory nil → 无记忆，每轮独立"
  (let ((a (cl-agent/client:make-agent
            :model (make-agent-test-model (text-response "r1") (text-response "r2"))
            :memory nil)))
    (cl-agent/client:agent-chat a "第一句")
    (cl-agent/client:agent-chat a "第二句")
    (is (null (cl-agent/client:agent-history a)))))

(test agent-reset-clears-history
  "agent-reset 清空历史与轮次计数，agent 仍可用"
  (let ((a (cl-agent/client:make-agent
            :model (make-agent-test-model (text-response "r1") (text-response "r2")))))
    (cl-agent/client:agent-chat a "hi")
    (is (= 2 (length (cl-agent/client:agent-history a))))
    (cl-agent/client:agent-reset a)
    (is (null (cl-agent/client:agent-history a)))
    (is (= 0 (cl-agent/client:agent-turn-count a)))
    ;; 重置后还能继续对话
    (is (string= "r2" (cl-agent/client:agent-chat a "again")))))

(test agent-system-and-tools
  ":system 与 :tools 下发到模型"
  (let* ((provider (make-seq-provider (text-response "ok")))
         (a (cl-agent/client:make-agent
             :model (cl-agent/core:make-provider-chat-model provider)
             :system "你是一个天气助手"
             :tools '(test-adder))))
    (cl-agent/client:agent-chat a "hi")
    (let ((req (first (seq-provider-requests provider))))
      (is (string= "你是一个天气助手" (getf (first (getf req :messages)) :content)))
      (is (= 1 (length (getf req :tools)))))))

;;; ============================================================
;;; system 不进历史（回归）
;;; ============================================================

(test agent-system-not-accumulated-in-history
  "system 消息不进历史——它每轮由 prompt 重新提供。
回归：memory-filter 曾存全部 prompt 消息（含 system），于是每轮追加一份，
2 轮就有 2 条 system、10 轮 10 条，白烧 token 还混淆模型
（实测多轮后再发工具调用会失败）。"
  (let ((a (cl-agent/client:make-agent
            :model (make-agent-test-model (text-response "r1") (text-response "r2"))
            :system "你是一个助手")))
    (cl-agent/client:agent-chat a "第一句")
    (cl-agent/client:agent-chat a "第二句")
    (let ((history (cl-agent/client:agent-history a)))
      ;; 历史里一条 system 都不该有
      (is (null (remove-if-not #'cl-agent/core:system-message-p history)))
      ;; 2 轮 × (user + assistant) = 4，不多不少
      (is (= 4 (length history))))))

(test agent-system-still-sent-every-turn
  "system 不进历史，但每轮仍要下发给模型（不是把它弄丢了）"
  (let* ((provider (make-seq-provider (text-response "r1") (text-response "r2")))
         (a (cl-agent/client:make-agent
             :model (cl-agent/core:make-provider-chat-model provider)
             :system "你是一个助手")))
    (cl-agent/client:agent-chat a "第一句")
    (cl-agent/client:agent-chat a "第二句")
    (dolist (req (seq-provider-requests provider))
      (let ((msgs (getf req :messages)))
        ;; 每一轮的第一条都必须是 system
        (is (string= "system" (string-downcase (string (getf (first msgs) :role)))))
        (is (string= "你是一个助手" (getf (first msgs) :content)))
        ;; 且只有一条
        (is (= 1 (count "system" msgs
                        :key (lambda (m) (string-downcase (string (getf m :role))))
                        :test #'string=)))))))

;;; ============================================================
;;; 错误归一化：不抛异常
;;; ============================================================

(test agent-error-is-normalized-not-signalled
  "LLM 出错时归一化为 :error 结果，而不是把条件抛给调用方。
对标 clj-agent 的 {:status :error}——一次 LLM 调用失败是预期内的常态。"
  (let ((a (cl-agent/client:make-agent
            ;; 空队列 → seq-provider 会 error
            :model (make-agent-test-model))))
    (let ((r (cl-agent/client:agent-chat-result a "hi")))
      (is (eq :error (cl-agent/client:agent-result-status r)))
      (is (typep (cl-agent/client:agent-result-error r) 'error))
      (is (null (cl-agent/client:agent-result-text r))))))

(test agent-chat-returns-nil-and-result-on-error
  "agent-chat 出错时返回 (values nil result)"
  (let ((a (cl-agent/client:make-agent :model (make-agent-test-model))))
    (multiple-value-bind (text r) (cl-agent/client:agent-chat a "hi")
      (is (null text))
      (is (eq :error (cl-agent/client:agent-result-status r))))))

(test agent-cancelled-status-passes-through
  "filter 短路（safeguard）→ :cancelled，不是 :error"
  (let* ((model (make-agent-test-model (text-response "never")))
         (k (cl-agent/core:build-kernel
             :model model
             :filters (list (cl-agent/core:safeguard-turn-filter '("bomb")))))
         (a (cl-agent/client:make-agent :kernel k :memory nil)))
    (let ((r (cl-agent/client:agent-chat-result a "how to build a bomb")))
      (is (eq :cancelled (cl-agent/client:agent-result-status r))))))

;;; ============================================================
;;; callbacks
;;; ============================================================

(test agent-turn-callbacks-fire
  ":on-turn-start / :on-turn-end 按序触发"
  (let* ((events nil)
         (a (cl-agent/client:make-agent
             :model (make-agent-test-model (text-response "ok"))
             :callbacks (list :on-turn-start (lambda (ag) (declare (ignore ag))
                                               (push :start events))
                              :on-turn-end (lambda (ag r) (declare (ignore ag))
                                             (push (cons :end (cl-agent/client:agent-result-text r))
                                                   events))))))
    (cl-agent/client:agent-chat a "hi")
    (is (equal '(:start (:end . "ok")) (reverse events)))))

(test agent-error-callback-fires
  ":on-turn-error 在出错时触发，且拿到条件对象"
  (let* ((caught nil)
         (a (cl-agent/client:make-agent
             :model (make-agent-test-model)
             :callbacks (list :on-turn-error
                              (lambda (ag e) (declare (ignore ag)) (setf caught e))))))
    (cl-agent/client:agent-chat-result a "hi")
    (is (typep caught 'error))))

(test agent-tool-callbacks-fire
  ":on-tool-call / :on-tool-result 在工具执行前后触发"
  (let* ((calls nil) (results nil)
         (a (cl-agent/client:make-agent
             :model (make-agent-test-model
                     (tool-call-response "test_adder" '(("a" . 2) ("b" . 3)))
                     (text-response "5"))
             :tools '(test-adder)
             :callbacks (list :on-tool-call (lambda (n args) (push (cons n args) calls))
                              :on-tool-result (lambda (n r) (push (cons n r) results))))))
    (cl-agent/client:agent-chat a "2+3")
    (is (= 1 (length calls)))
    (is (string= "test_adder" (car (first calls))))
    (is (= 1 (length results)))
    (is (string= "5" (cdr (first results))))))

(test agent-callback-error-does-not-break-turn
  "回调里抛异常不掀翻整轮对话——回调是观测手段，不是控制流"
  (let ((a (cl-agent/client:make-agent
            :model (make-agent-test-model (text-response "ok"))
            :callbacks (list :on-turn-start
                             (lambda (ag) (declare (ignore ag))
                               (error "回调故意炸了"))))))
    (is (string= "ok" (cl-agent/client:agent-chat a "hi")))))

;;; ============================================================
;;; 分层边界
;;; ============================================================

(test agent-does-not-accept-filters
  "make-agent 不接受 :filters——agent 层只暴露 :callbacks。
要挂 filter 请自建 kernel 经 :kernel 传入。"
  (is (eq :error
          (handler-case
              (progn (cl-agent/client:make-agent
                      :model (make-agent-test-model (text-response "x"))
                      :filters (list (cl-agent/core:logging-chat-filter)))
                     :no-error)
            (error () :error)))))

(test agent-accepts-prebuilt-kernel
  "自建 kernel（含 filter）经 :kernel 传入可用"
  (let* ((mem (cl-agent/core:make-message-window-chat-memory))
         (k (cl-agent/core:build-kernel
             :model (make-agent-test-model (text-response "r1") (text-response "r2"))
             :filters (list (cl-agent/core:memory-filter mem))))
         (a (cl-agent/client:make-agent :kernel k :memory mem)))
    (cl-agent/client:agent-chat a "第一句")
    (cl-agent/client:agent-chat a "第二句")
    (is (= 4 (length (cl-agent/client:agent-history a))))))

;;; ============================================================
;;; pause / resume（HITL）
;;;
;;; 设计：配 :on-tool-call 回调即启用——返回 (:interrupt . 原因) 就暂停。
;;; 关键不变量：**暂停时工具一个都没执行**。
;;; ============================================================

(defvar *hitl-fired* nil
  "记录 hitl-danger 是否真的执行过——暂停语义的硬断言靠它。")

(cl-agent/core:deftool hitl-danger (&key target)
  "危险操作（测试审批用）"
  (:param target :string "目标" :required t)
  (setf *hitl-fired* target)
  (format nil "已删除 ~A" target))

(defun make-hitl-agent (&rest callbacks)
  (cl-agent/client:make-agent
   :model (make-agent-test-model
           (tool-call-response "hitl_danger" '(("target" . "/tmp/x")))
           (text-response "完成"))
   :tools '(hitl-danger)
   :callbacks callbacks))

(test agent-pauses-and-tool-not-executed
  "on-tool-call 返回 :interrupt → :paused，且**工具没有被执行**"
  (let* ((*hitl-fired* nil)
         (a (make-hitl-agent :on-tool-call
                             (lambda (n args) (declare (ignore args))
                               (when (string= n "hitl_danger")
                                 (cons :interrupt "需要审批"))))))
    (let ((r (cl-agent/client:agent-chat-result a "删除 /tmp/x")))
      (is (eq :paused (cl-agent/client:agent-result-status r)))
      ;; 硬断言：暂停 ≠ 执行后再问
      (is (null *hitl-fired*) "暂停时工具不得被执行")
      (is (cl-agent/client:agent-paused-p a))
      (is (string= "需要审批" (cl-agent/client:agent-result-pause-reason r)))
      (let ((p (cl-agent/client:agent-result-pending-tool r)))
        (is (string= "hitl_danger" (cl-agent/core:pending-tool-name p)))
        (is (equal "/tmp/x" (getf (cl-agent/core:pending-tool-args p) :target)))))))

(test agent-resume-approved-executes-tool
  ":approved → 工具执行，循环继续到完成"
  (let* ((*hitl-fired* nil)
         (a (make-hitl-agent :on-tool-call
                             (lambda (n args) (declare (ignore args))
                               (when (string= n "hitl_danger") (cons :interrupt "审批"))))))
    (cl-agent/client:agent-chat-result a "删除 /tmp/x")
    (is (null *hitl-fired*))
    (let ((r (cl-agent/client:agent-resume a :approved)))
      (is (eq :completed (cl-agent/client:agent-result-status r)))
      (is (string= "完成" (cl-agent/client:agent-result-text r)))
      ;; 批准后工具真的执行了
      (is (string= "/tmp/x" *hitl-fired*))
      (is (not (cl-agent/client:agent-paused-p a))))))

(test agent-resume-approved-with-edited-args
  ":approved + (:args 新参数) → 编辑后批准，工具用**新**参数执行"
  (let* ((*hitl-fired* nil)
         (a (make-hitl-agent :on-tool-call
                             (lambda (n args) (declare (ignore args))
                               (when (string= n "hitl_danger") :interrupt)))))
    (cl-agent/client:agent-chat-result a "删除 /tmp/x")
    (cl-agent/client:agent-resume a :approved :payload '(:args (:target "/tmp/safe")))
    (is (string= "/tmp/safe" *hitl-fired*) "应以编辑后的参数执行")))

(test agent-resume-rejected-does-not-execute
  ":rejected → 工具不执行，理由作为结果回传模型"
  (let* ((*hitl-fired* nil)
         (provider (make-seq-provider
                    (tool-call-response "hitl_danger" '(("target" . "/tmp/x")))
                    (lambda (messages)
                      ;; 第二轮：模型应看到拒绝理由
                      (let ((tool-msg (find :tool messages
                                            :key (lambda (m) (getf m :role)))))
                        (is (not (null tool-msg)))
                        (is (search "已拒绝执行" (getf tool-msg :content)))
                        (is (search "太危险了" (getf tool-msg :content))))
                      (text-response "好的，我不删了"))))
         (a (cl-agent/client:make-agent
             :model (cl-agent/core:make-provider-chat-model provider)
             :tools '(hitl-danger)
             :callbacks (list :on-tool-call
                              (lambda (n args) (declare (ignore args))
                                (when (string= n "hitl_danger") :interrupt))))))
    (cl-agent/client:agent-chat-result a "删除 /tmp/x")
    (let ((r (cl-agent/client:agent-resume a :rejected :payload '(:message "太危险了"))))
      (is (eq :completed (cl-agent/client:agent-result-status r)))
      (is (null *hitl-fired*) "拒绝后工具不得被执行"))))

(test agent-resume-reply-uses-answer-as-result
  ":reply → 工具不执行，答复直接作为它的结果回模型（ask-user 语义）"
  (let* ((*hitl-fired* nil)
         (provider (make-seq-provider
                    (tool-call-response "hitl_danger" '(("target" . "/tmp/x")))
                    (lambda (messages)
                      (let ((tool-msg (find :tool messages
                                            :key (lambda (m) (getf m :role)))))
                        (is (string= "用户说：改天再删" (getf tool-msg :content))))
                      (text-response "收到"))))
         (a (cl-agent/client:make-agent
             :model (cl-agent/core:make-provider-chat-model provider)
             :tools '(hitl-danger)
             :callbacks (list :on-tool-call
                              (lambda (n args) (declare (ignore args))
                                (when (string= n "hitl_danger") :interrupt))))))
    (cl-agent/client:agent-chat-result a "删除 /tmp/x")
    (let ((r (cl-agent/client:agent-resume a :reply
                                           :payload '(:message "用户说：改天再删"))))
      (is (eq :completed (cl-agent/client:agent-result-status r)))
      (is (null *hitl-fired*) ":reply 时工具不得被执行"))))

(test agent-reply-requires-message
  ":reply 缺 :message → 报错（而不是把 nil 当答复喂给模型）"
  (let ((a (make-hitl-agent :on-tool-call
                            (lambda (n args) (declare (ignore args))
                              (when (string= n "hitl_danger") :interrupt)))))
    (cl-agent/client:agent-chat-result a "删除 /tmp/x")
    (let ((r (cl-agent/client:agent-resume a :reply)))
      ;; 归一化为 :error，不抛给调用方
      (is (eq :error (cl-agent/client:agent-result-status r))))))

(test agent-resume-without-pause-errors
  "未暂停时 agent-resume 报错"
  (let ((a (cl-agent/client:make-agent
            :model (make-agent-test-model (text-response "ok")))))
    (signals error (cl-agent/client:agent-resume a :approved))))

(test agent-no-gate-means-no-pause
  "不配 :on-tool-call → 无 HITL，工具照常执行"
  (let* ((*hitl-fired* nil)
         (a (cl-agent/client:make-agent
             :model (make-agent-test-model
                     (tool-call-response "hitl_danger" '(("target" . "/tmp/x")))
                     (text-response "完成"))
             :tools '(hitl-danger))))
    (is (string= "完成" (cl-agent/client:agent-chat a "删除")))
    (is (string= "/tmp/x" *hitl-fired*))))

(test agent-gate-evaluated-exactly-once-per-tool
  "gate 对每个 tool-call **恰好评估一次**——gate 常带副作用（审计/弹窗/计数），
评估两遍就是重复触发。"
  (let* ((calls 0)
         (a (make-hitl-agent :on-tool-call
                             (lambda (n args) (declare (ignore n args))
                               (incf calls)
                               nil))))   ; 不拦，只数
    (cl-agent/client:agent-chat-result a "删除 /tmp/x")
    (is (= 1 calls))))

(test agent-interrupt-callback-fires
  ":on-interrupt 在进入暂停时触发"
  (let* ((fired nil)
         (a (make-hitl-agent
             :on-tool-call (lambda (n args) (declare (ignore args))
                             (when (string= n "hitl_danger") :interrupt))
             :on-interrupt (lambda (ag r) (declare (ignore ag))
                             (setf fired (cl-agent/client:agent-result-status r))))))
    (cl-agent/client:agent-chat-result a "删除 /tmp/x")
    (is (eq :paused fired))))

;;; ============================================================
;;; 消息不重复（回归）
;;;
;;; run-tool-loop 传的是本轮**累积的完整 messages**（不是 delta），
;;; 而 memory-filter 挂在 :chat 链、工具循环每轮都过一遍。不去重的话，
;;; 第 2 轮会把 user/assistant 再存一份，历史变成
;;;   (user assistant user assistant tool ...)
;;; 发给模型的序列直接非法（Anthropic 格式要求 user/assistant 交替、
;;; tool_result 紧跟 tool_use）——实测 MiniMax 返回 400。
;;; mock 不校验序列，所以这个 bug 只有真实 provider 才暴露。
;;; ============================================================

(defun roles-of (messages)
  (mapcar #'cl-agent/core:message-role messages))

(test tool-loop-does-not-duplicate-history
  "普通工具循环：历史不得出现重复的 user/assistant"
  (let* ((mem (cl-agent/core:make-message-window-chat-memory))
         (a (cl-agent/client:make-agent
             :model (make-agent-test-model
                     (tool-call-response "test_adder" '(("a" . 2) ("b" . 3)))
                     (text-response "5"))
             :tools '(test-adder)
             :memory mem
             :system "你是助手")))
    (cl-agent/client:agent-chat a "2+3")
    ;; user → assistant(tool_call) → tool → assistant(final)
    (is (equal '(:user :assistant :tool :assistant)
               (roles-of (cl-agent/client:agent-history a))))))

(test tool-loop-sends-legal-message-sequence
  "发给模型的序列必须合法：system 一条、user/assistant 交替、tool 紧跟 assistant"
  (let* ((provider (make-seq-provider
                    (tool-call-response "test_adder" '(("a" . 2) ("b" . 3)))
                    (text-response "5")))
         (a (cl-agent/client:make-agent
             :model (cl-agent/core:make-provider-chat-model provider)
             :tools '(test-adder)
             :system "你是助手")))
    (cl-agent/client:agent-chat a "2+3")
    ;; requests 是 push 的 → first 是第二轮
    (let ((second-round (mapcar (lambda (m) (getf m :role))
                                (getf (first (seq-provider-requests provider)) :messages))))
      (is (equal '(:system :user :assistant :tool) second-round)))))

(test hitl-resume-does-not-duplicate-history
  "HITL 续跑后历史同样不得重复"
  (let* ((*hitl-fired* nil)
         (mem (cl-agent/core:make-message-window-chat-memory))
         (a (cl-agent/client:make-agent
             :model (make-agent-test-model
                     (tool-call-response "hitl_danger" '(("target" . "/tmp/x")))
                     (text-response "完成"))
             :tools '(hitl-danger)
             :memory mem
             :callbacks (list :on-tool-call
                              (lambda (n args) (declare (ignore args))
                                (when (string= n "hitl_danger") :interrupt))))))
    (cl-agent/client:agent-chat-result a "删除")
    ;; 暂停时：user + assistant(tool_call) 已落库，工具未执行
    (is (equal '(:user :assistant) (roles-of (cl-agent/client:agent-history a))))
    (cl-agent/client:agent-resume a :approved)
    (is (equal '(:user :assistant :tool :assistant)
               (roles-of (cl-agent/client:agent-history a))))))
