;;;; invoke.lisp
;;;; CL-Agent Kernel - invoke-chat / invoke-tool / invoke-turn + run-tool-loop
;;;;
;;;; 概述（Phase P2）：
;;;;   三链 invoke 原语让 kernel 活起来——连接 ChatModel 和工具执行。
;;;;   run-tool-loop 是 :turn 链的 terminal（不是 filter）。
;;;;
;;;;   三链组装点：
;;;;   - invoke-chat  → build-chain(:chat) → terminal = chat-model-call
;;;;   - invoke-tool  → build-chain(:tool) → terminal = tool-callback-call
;;;;   - invoke-turn  → build-chain(:turn) → terminal = run-tool-loop
;;;;
;;;;   循环数据流：
;;;;     invoke-turn → [turn filters] → run-tool-loop
;;;;       │
;;;;       ├── invoke-chat([chat filters] → LLM) → chat-response
;;;;       ├── if tool-calls & eligible:
;;;;       │     invoke-tool-batch → tool results
;;;;       │     append messages → repeat
;;;;       └── else: return turn-result(:completed)
;;;;
;;;;   Chat 链请求/响应 = prompt / chat-response（最简，不加包装层）。
;;;;   Tool 链请求/响应 = tool-request / tool-result（kernel 载体）。
;;;;   Turn 链请求/响应 = turn-request / turn-result（kernel 载体）。

(in-package #:cl-agent.core)

;;; ============================================================
;;; invoke-chat：:chat 链 → ChatModel
;;; ============================================================

(defun invoke-chat (kernel prompt)
  "经 :chat filter 链调用 LLM（单次，不执行工具）。

  PROMPT 可以是 string / 消息列表 / prompt 实例（ChatModel 自动包装）。
  返回 cl-agent.core:chat-response 实例。

  :chat filter 钩子签名：(prompt chain) → chat-response
  - prompt  = cl-agent.core:prompt 实例
  - chain   = 下游函数 (prompt) → chat-response
  - 返回值  = chat-response"
  (let ((chain (build-chain (kernel-filters kernel)
                            #'filter-chat-hook
                            (lambda (p)
                              (chat-model-call (kernel-model kernel) p)))))
    (funcall chain prompt)))

;;; ============================================================
;;; invoke-tool：:tool 链 → 工具执行
;;; ============================================================

(defun invoke-tool (kernel tool-request)
  "经 :tool filter 链执行单个工具。

  :tool filter 钩子签名：(tool-request chain) → tool-result
  - tool-request  = kernel:tool-request 实例
  - chain         = 下游函数
  - 返回值        = kernel:tool-result 实例"
  (let ((chain (build-chain (kernel-filters kernel)
                            #'filter-tool-hook
                            (lambda (req) (tool-apply-terminal req)))))
    (funcall chain tool-request)))

(defun tool-apply-terminal (req)
  "工具执行终端：调用 tool-callback-call，捕获异常为 :semantic 错误。

  tool-request-function 可以是 tool-callback 实例或符号（自动解析）。"
  (let* ((fn-spec (tool-request-function req))
         (callback (etypecase fn-spec
                     (cl-agent.core:tool-callback fn-spec)
                     (symbol (or (cl-agent.core:symbol-tool-callback fn-spec)
                                 (error 'cl-agent.core:tool-not-found-error
                                        :tool-name fn-spec)))))
         (args (tool-request-args req))
         (ctx (tool-request-context req)))
    (handler-case
        (make-tool-result :value (cl-agent.core:tool-callback-call
                                     callback args ctx))
      (cl-agent.core:tool-not-found-error (e)
        (declare (ignore e))
        (make-tool-result :error (list :class :semantic
                                         :message "工具未找到")))
      (error (e)
        (make-tool-result :error (list :class :semantic
                                         :message (princ-to-string e)))))))

;;; ============================================================
;;; invoke-tool-batch：批量执行工具调用（委托 batch.lisp）
;;; ============================================================
;;; P3: 并行默认 + :serial 退化 + 故障路由。
;;; batch.lisp 中的 invoke-tool-batch 是完整实现；这里不再重复定义。
;;; （invoke-tool-batch 在 batch.lisp 中定义，通过 package 导出）

;;; ============================================================
;;; resolve-kernel-tools：kernel 工具符号 → chat-options
;;; ============================================================

(defun resolve-kernel-tools (kernel)
  "把 kernel 的 :tools（符号列表）解析为 chat-options（含 tool-callbacks）。"
  (let ((tools (kernel-tools kernel)))
    (if tools
        (cl-agent.core:make-chat-options
         :tool-callbacks (cl-agent.core:resolve-tool-callbacks tools))
        nil)))

(defparameter +internal-context-keys+ '(:caller-options)
  "turn context 里的内部管道键，不外泄到 prompt 的 tool-context。")

(defun fold-context-into-tool-context (options context)
  "返回 OPTIONS 的副本，把 CONTEXT（turn context plist，剔除内部键）
折进它的 tool-context——CONTEXT 的键覆盖同名的既有 tool-context 键。

存在的理由：:chat 链的 filter 只拿得到 prompt，读的是 prompt options
的 tool-context；而 (:conversation ...) / prompt-context 写的是 turn
context。不桥接则二者各说各话（memory-filter 的 :conversation-id 读不到）。"
  (let ((extra (loop for (k v) on context by #'cddr
                     unless (member k +internal-context-keys+)
                       append (list k v))))
    (if (null extra)
        (or options (cl-agent.core:make-chat-options))
        (let* ((base (or options (cl-agent.core:make-chat-options)))
               (existing (cl-agent.core:chat-options-tool-context base))
               ;; 先放 extra，再放既有——同名键 extra 胜出（getf 取首个匹配）
               (merged-ctx (append extra existing)))
          ;; 只覆盖 tool-context 一个槽：primary 仅绑定 tool-context，
          ;; merge 把 base 其余槽（含 tool-callbacks）原样保留。
          (cl-agent.core:merge-chat-options
           (cl-agent.core:make-chat-options :tool-context merged-ctx)
           base)))))

;;; ============================================================
;;; run-tool-loop：工具调用循环（:turn 链的 terminal）
;;; ============================================================

(defun resolve-turn-options (kernel context)
  "把 kernel 工具 + caller-options + turn context 解析成本轮的 chat-options。"
  (let* ((caller-options (getf context :caller-options))
         (kernel-options (resolve-kernel-tools kernel))
         (merged (if caller-options
                     (cl-agent.core:merge-chat-options caller-options kernel-options)
                     kernel-options)))
    ;; 把 turn context 折进 options 的 tool-context——:chat 链的 filter
    ;; （memory-filter 等）只拿得到 prompt，读的是 prompt options 的
    ;; tool-context，而 (:conversation ...) / prompt-context 写的是
    ;; turn context。不桥接的话 (:conversation "id") 到不了
    ;; memory-filter，多轮记忆会静默失效。:caller-options 是内部
    ;; 管道，剔除不外泄。
    (fold-context-into-tool-context merged context)))

(defun evaluate-gate (gate tool-calls)
  "对本批每个 tool-call **恰好评估一次** gate。

返回 (values paused-call reason)：有任一判 :pause 则返回第一个及其原因；
全部 :proceed 返回 (values nil nil)。

「恰好一次」是硬要求：gate 常常挂着副作用（记审计日志、弹审批 UI、
计数）。评估两遍就会重复触发。所以这里一次性算完，不做
some+filter 那种两阶段扫描。"
  (when gate
    (loop for tc in tool-calls
          for verdict = (funcall gate tc)
          when (or (eq verdict :pause)
                   (and (consp verdict) (eq (car verdict) :pause)))
            do (return (values tc (when (consp verdict) (cdr verdict))))
          finally (return (values nil nil)))))

(defun tool-results->message (tool-results tool-calls)
  "把一批 tool-result 转成回传模型的 tool 消息。"
  (cl-agent.core:tool-response-message
   (mapcar (lambda (tr tc)
             (cl-agent.core:make-tool-response
              :id (cl-agent.core:tool-call-id tc)
              :name (cl-agent.core:tool-call-name tc)
              :text (tool-result->text tr)))
           tool-results tool-calls)))

(defun run-tool-loop (kernel turn-request)
  "工具调用循环。不是 filter——是 :turn 链的 terminal。

  每轮：
  1. 构建 prompt（messages + tools）
  2. invoke-chat → chat-response
  3. 响应携带 tool-calls 且通过 eligibility 判定：
     3a. 先过 tool-gate（HITL）——任一判 :pause → 整轮暂停，
         **工具一个都不执行**，返回 turn-result(:paused)
     3b. 否则 invoke-tool-batch 执行
  4. 把 assistant(tool-calls) 消息 + tool 结果追加到 messages
  5. 回到 1
  6. 无 tool-calls 或未通过 eligibility → 返回 turn-result(:completed)

  最大循环次数从 kernel settings 取（缺省 10）。"
  (let ((context (turn-request-context turn-request)))
    (%tool-loop kernel
                (turn-request-messages turn-request)
                (resolve-turn-options kernel context)
                context
                0)))

(defun %tool-loop (kernel messages options context iteration)
  "循环主体。从第 ITERATION 轮开始跑——resume 靠它从中点续跑。"
  (let ((max-iter (or (cdr (assoc :max-tool-iterations (kernel-settings kernel)))
                      10))
        (eligibility (kernel-eligibility-fn kernel))
        (gate (kernel-tool-gate kernel)))
    (loop for iter from iteration
          for prompt = (cl-agent.core:make-prompt messages :options options)
          for response = (invoke-chat kernel prompt)
          do (when (> iter max-iter)
               (error 'cl-agent.core:max-tool-iterations-exceeded-error
                      :limit max-iter))
             (cond
               ((and (cl-agent.core:chat-response-has-tool-calls-p response)
                     (funcall eligibility response context))
                (let ((tool-calls (cl-agent.core:chat-response-tool-calls response)))
                  ;; HITL 闸门：在**执行之前**评估。判 :pause 就整批不执行，
                  ;; 把续跑所需的一切装进 loop-state 交出去。
                  (multiple-value-bind (paused-call reason)
                      (evaluate-gate gate tool-calls)
                    (if paused-call
                        (return
                          (make-turn-result
                           :paused
                           :pause-reason (or reason
                                             (format nil "需要审批：~A"
                                                     (cl-agent.core:tool-call-name paused-call)))
                           :loop-state (make-loop-state
                                        :messages messages
                                        :response response
                                        :tool-calls tool-calls
                                        :pending-id (cl-agent.core:tool-call-id paused-call)
                                        :iteration iter
                                        :options options
                                        :context context)
                           :pending-tool (make-pending-tool
                                          :name (cl-agent.core:tool-call-name paused-call)
                                          :args (cl-agent.core:arguments->plist
                                                 (cl-agent.core:tool-call-arguments paused-call))
                                          :id (cl-agent.core:tool-call-id paused-call))
                           :tool-calls-made iter))
                        ;; 放行：执行整批
                        (multiple-value-bind (result done)
                            (%execute-and-append kernel response tool-calls
                                                 messages options context iter)
                          (if done
                              (return result)      ; return-direct 收尾
                              (setf messages result)))))))
               (t
                ;; 无工具调用：最终响应
                (return (make-turn-result :completed :response response
                                          :tool-calls-made iter)))))))

(defun %execute-and-append (kernel response tool-calls messages options context iteration)
  "执行一批工具并把结果追加进 messages。

返回 (values X done-p)：
  - done-p = nil → X 是追加后的新 messages（继续循环）
  - done-p = t   → X 是终局 turn-result（return-direct 收尾）"
  (let ((tm (kernel-tool-manager kernel)))
    (if tm
        ;; === Manager 路径 ===
        (let* ((result (execute-tool-calls tm kernel response
                                           (list :tool-context context)))
               (tool-msg (cl-agent.core:tool-response-message (getf result :messages))))
          (values (append messages
                          (list (cl-agent.core:chat-response-message response) tool-msg))
                  nil))
        ;; === 原路径（invoke-tool-batch）===
        (multiple-value-bind (tool-results return-direct)
            (invoke-tool-batch kernel tool-calls options context)
          (let ((tool-msg (tool-results->message tool-results tool-calls)))
            (if return-direct
                ;; return-direct：工具结果即最终答案，不再回传模型
                (values (make-turn-result
                         :completed
                         :response (cl-agent.core:make-chat-response
                                    (cl-agent.core:make-generation
                                     (cl-agent.core:assistant-message
                                      (format nil "~{~A~^~%~}"
                                              (mapcar #'tool-result-value tool-results)))
                                     :finish-reason :stop))
                         :tool-calls-made (1+ iteration))
                        t)
                (values (append messages
                                (list (cl-agent.core:chat-response-message response) tool-msg))
                        nil)))))))

;;; ============================================================
;;; resume-turn：从暂停点续跑（HITL）
;;; ============================================================

(defun %resume-gate (decision payload pending-id)
  "按审批决定组一个用于续跑那一批的 gate。

返回 (tool-call) → :proceed | (:reject . 理由) | (:reply . 答复)"
  (ecase decision
    ;; 批准：整批放行（pending 之外的工具本来也没被单独拒绝过）
    (:approved (constantly :proceed))
    ;; 答复即结果（ask-user 语义）：pending 工具不执行，答复直接当它的结果
    (:reply (let ((msg (getf payload :message)))
              (unless (stringp msg)
                (error ":reply 需要 payload 里的 :message（答复文本）"))
              (lambda (tc)
                (if (equal (cl-agent.core:tool-call-id tc) pending-id)
                    (cons :reply msg)
                    :proceed))))
    ;; 拒绝：只拒 pending 那个，其余照常执行
    (:rejected (let ((reason (getf payload :message)))
                 (lambda (tc)
                   (if (equal (cl-agent.core:tool-call-id tc) pending-id)
                       (cons :reject reason)
                       :proceed))))))

(defun %apply-resume-gate (gate tool-calls)
  "按 resume-gate 把本批切成「要执行的」与「已定结果的」。

返回 (values callable-calls decided-alist)：
  - callable-calls  需要真执行的 tool-call
  - decided-alist   ((tool-call . 结果文本) ...)——拒绝/答复，不执行"
  (let (callable decided)
    (dolist (tc tool-calls)
      (let ((verdict (funcall gate tc)))
        (cond
          ((and (consp verdict) (eq (car verdict) :reject))
           (push (cons tc (format nil "已拒绝执行~@[：~A~]" (cdr verdict))) decided))
          ((and (consp verdict) (eq (car verdict) :reply))
           (push (cons tc (cdr verdict)) decided))
          (t (push tc callable)))))
    (values (nreverse callable) (nreverse decided))))

(defun %resume-continuation (kernel loop-state decision payload)
  "暂停延续：按决定处理 pending 批次，然后接着跑循环。"
  (let* ((tool-calls (loop-state-tool-calls loop-state))
         (pending-id (loop-state-pending-id loop-state))
         (messages (loop-state-messages loop-state))
         (response (loop-state-response loop-state))
         (options (loop-state-options loop-state))
         (context (loop-state-context loop-state))
         (iteration (loop-state-iteration loop-state))
         ;; 编辑后批准：用新参数替换 pending 工具的参数
         (new-args (and (eq decision :approved) (getf payload :args)))
         (tool-calls (if new-args
                         (mapcar (lambda (tc)
                                   (if (equal (cl-agent.core:tool-call-id tc) pending-id)
                                       (cl-agent.core:make-tool-call
                                        :id (cl-agent.core:tool-call-id tc)
                                        :name (cl-agent.core:tool-call-name tc)
                                        :arguments new-args)
                                       tc))
                                 tool-calls)
                         tool-calls))
         (gate (%resume-gate decision payload pending-id)))
    (multiple-value-bind (callable decided) (%apply-resume-gate gate tool-calls)
      ;; 真要执行的那部分走正常批执行；被拒/被答复的直接用现成文本
      (let* ((executed (when callable
                         (multiple-value-list
                          (invoke-tool-batch kernel callable options context))))
             (results (first executed))
             ;; 按**原始顺序**拼回结果——模型看到的 tool 消息顺序必须与
             ;; 它发出的 tool_calls 一致，否则 id 对不上
             (texts (mapcar
                     (lambda (tc)
                       (let ((hit (assoc tc decided)))
                         (if hit
                             (cdr hit)
                             (let ((pos (position tc callable)))
                               (if pos
                                   (tool-result->text (nth pos results))
                                   "（未执行）")))))
                     tool-calls))
             (tool-msg (cl-agent.core:tool-response-message
                        (mapcar (lambda (tc text)
                                  (cl-agent.core:make-tool-response
                                   :id (cl-agent.core:tool-call-id tc)
                                   :name (cl-agent.core:tool-call-name tc)
                                   :text text))
                                tool-calls texts))))
        (%tool-loop kernel
                    (append messages
                            (list (cl-agent.core:chat-response-message response) tool-msg))
                    options context (1+ iteration))))))

(defun resume-turn (kernel loop-state decision &key payload)
  "从暂停点续跑工具循环。

  参数：
  - loop-state  turn-result(:paused) 上的 loop-state
  - decision    :approved | :rejected | :reply
  - payload     plist：
                :approved + (:args 新参数)   → 编辑后批准（pending 工具用新参数执行）
                :reply    + (:message 答复)  → 答复即结果（pending 工具不执行，
                                               答复直接作为它的结果回模型）
                :rejected + (:message 理由)  → 结果「已拒绝执行：<理由>」，
                                               模型直接拿到原因，省一轮干猜

  返回：同 invoke-turn（:completed，或再次 :paused——批里可能还有别的
  敏感工具，或后续轮次又触发 gate）。

  resume 同样过 :turn filter 链：validation 之类的 filter 要能作用于续跑
  后的结果。首次进入 terminal = 暂停延续，filter 递归重入 = 常规循环
  （新 delta），靠 consumed 标志一次性分派。"
  (check-type decision (member :approved :rejected :reply))
  (let* ((consumed nil)
         (context (loop-state-context loop-state))
         (terminal (lambda (req)
                     (if (not consumed)
                         (progn (setf consumed t)
                                (%resume-continuation kernel loop-state decision payload))
                         ;; turn filter 递归重入 → 走常规循环（新 delta）
                         (run-tool-loop kernel req))))
         (chain (build-chain (kernel-filters kernel) #'filter-turn-hook terminal)))
    (funcall chain (make-turn-request nil :context context :resume-p t))))

;;; ============================================================
;;; invoke-turn：:turn 链包住 run-tool-loop
;;; ============================================================

(defun invoke-turn (kernel turn-request)
  "经 :turn filter 链执行一轮对话。

  :turn 链包住 run-tool-loop（terminal）。turn filter 可：
  - 改写入口 messages（RAG 注入、re-reading）
  - 短路（safeguard 拦截）
  - 递归重入（validation 校验失败 → 再调 chain）

  :turn filter 钩子签名：(turn-request chain) → turn-result"
  (let ((chain (build-chain (kernel-filters kernel)
                            #'filter-turn-hook
                            (lambda (req) (run-tool-loop kernel req)))))
    (funcall chain turn-request)))
