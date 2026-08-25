;;;; invoke.lisp
;;;; CL-Agent ChatClient - invoke-chat / invoke-tool / invoke-turn + run-tool-loop
;;;;
;;;; 概述（Phase P2）：
;;;;   三链 invoke 原语让 chat-client 活起来——连接 ChatModel 和工具执行。
;;;;   run-tool-loop 是 :turn 链的 terminal（不是 filter），可经
;;;;   build-chat-client 的 :loop-fn 整体替换。
;;;;
;;;;   三链组装点：
;;;;   - invoke-chat  → build-chain(:chat) → terminal = chat-model-call
;;;;   - invoke-tool  → build-chain(:tool) → terminal = tool-callback-call
;;;;   - invoke-turn  → build-chain(:turn) → terminal = loop-fn
;;;;                    （缺省 run-tool-loop）
;;;;
;;;;   循环数据流：
;;;;     invoke-turn → [turn filters] → run-tool-loop
;;;;       │
;;;;       ├── invoke-chat([chat filters] → LLM) → chat-response
;;;;       ├── if tool-calls & eligible:
;;;;       │     invoke-tool-batch → tool results
;;;;       │     append messages → repeat
;;;;       └── else: return chat-client-response(:completed)
;;;;
;;;;   Chat 链请求/响应 = prompt / chat-response（最简，不加包装层）。
;;;;   Tool 链请求/响应 = tool-request / tool-result（chat-client 载体）。
;;;;   Turn 链请求/响应 = chat-client-request / chat-client-response
;;;;   （对标 Spring AI ChatClientRequest / ChatClientResponse）。

(in-package #:cl-agent/core)

;;; ============================================================
;;; invoke-chat：:chat 链 → ChatModel
;;; ============================================================

(defun invoke-chat (chat-client prompt)
  "经 :chat filter 链调用 LLM（单次，不执行工具）。

  PROMPT 可以是 string / 消息列表 / prompt 实例（ChatModel 自动包装）。

  返回 (values chat-response effective-prompt)：
  - chat-response    模型响应
  - effective-prompt **filter 改写后、真正发给模型的** prompt

  为什么要把 effective-prompt 传出来：:chat filter 可以改写工具集
  （tool-search-filter 的渐进式披露就是这么做的）。工具执行阶段必须用
  这一份，否则「模型看到的工具集」与「可执行的工具集」会不一致——
  filter 注入的工具模型看得见却执行不了（find-callback-for-call 只认
  传给它的那份 options，直接报「找不到工具」）。

  :chat filter 钩子签名：(prompt chain) → chat-response
  - prompt  = cl-agent/core:prompt 实例
  - chain   = 下游函数 (prompt) → chat-response
  - 返回值  = chat-response"
  (let* ((effective nil)
         (chain (build-chain (chat-client-filters chat-client)
                             #'filter-chat-hook
                             (lambda (p)
                               ;; terminal 拿到的就是穿过整条链后的最终 prompt
                               (setf effective p)
                               (chat-model-call (chat-client-model chat-client) p)))))
    (let ((response (funcall chain prompt)))
      (values response (or effective prompt)))))

;;; ============================================================
;;; invoke-chat-stream：:chat 链 + :token-xform 组装
;;; ============================================================

(defun compose-token-xforms (filters sink)
  "把 FILTERS 的 :token-xform 折叠成出站 token 管道，最内层是 SINK。

  返回 (values emit finish)：
  - emit   (token-plist) → nil   处理一个 token
  - finish () → nil              流结束，让有缓冲的 xform 吐出来

  token-xform 协议：(downstream-emit) → (values emit finish)
  - downstream-emit  往更内层送 token 的函数
  - emit             本层处理一个 token（可改写、丢弃、缓冲）
  - finish           流结束时调用（无缓冲的 xform 给 no-op 即可）

  为什么不用经典 transducer 的 arity 重载（(rf) / (rf acc) / (rf acc x)）：
  出站 token 流没有累积器，硬套 reducing function 只会让每个 xform 都要写
  一堆无意义的 arity 分支。此前的实现就是这么拧的——0-arity 竟然返回一个
  函数当 step 用，两个 filter 都没人调过所以没人发现。

  filters 靠前 = 靠外 = 先看到 token（与 build-chain 的洋葱方向一致）。"
  (let ((emit sink)
        (finishers nil))
    ;; 从内往外套：最后一个 filter 最靠内
    (dolist (f (reverse filters))
      (let ((xf (filter-token-xform f)))
        (when xf
          (multiple-value-bind (new-emit finish) (funcall xf emit)
            (setf emit new-emit)
            ;; finish 按「从外往内」的顺序收集：外层 flush 时内层还活着
            (push finish finishers)))))
    (values emit
            (lambda ()
              (dolist (fin finishers)
                (when fin (funcall fin)))))))

(defun invoke-chat-stream (chat-client prompt on-token)
  "经 :chat filter 链 + :token-xform 管道的**流式**调用。

  ON-TOKEN 收到 plist：(:token \"增量文本\")。

  返回 (values chat-response effective-prompt)——与 invoke-chat 同形。

  :chat filter 照常生效（记忆/日志/工具披露都能改写 prompt）；
  :token-xform 则组装在流式 terminal 内侧，作用于出站 token
  （脱敏、先审后放…）。

  注意 provider 不支持流式时 chat-model-stream 会降级为一次性调用，
  此时整段文本作为单个 token 送出——token-xform 仍然生效。"
  (let* ((effective nil)
         (chain (build-chain
                 (chat-client-filters chat-client)
                 #'filter-chat-hook
                 (lambda (p)
                   (setf effective p)
                   (multiple-value-bind (emit finish)
                       (compose-token-xforms (chat-client-filters chat-client)
                                             (lambda (tok) (funcall on-token tok)))
                     (let ((response
                             (cl-agent/core:chat-model-stream
                              (chat-client-model chat-client) p
                              ;; chat-model-stream 给的是裸字符串增量，
                              ;; 这里包成 plist 交给 xform 管道
                              (lambda (delta) (funcall emit (list :token delta))))))
                       ;; flush 缓冲型 xform（如 hold-release）
                       (funcall finish)
                       response))))))
    (let ((response (funcall chain prompt)))
      (values response (or effective prompt)))))

;;; ============================================================
;;; invoke-tool：:tool 链 → 工具执行
;;; ============================================================

(defun invoke-tool (chat-client tool-request)
  "经 :tool filter 链执行单个工具。

  :tool filter 钩子签名：(tool-request chain) → tool-result
  - tool-request  = chat-client:tool-request 实例
  - chain         = 下游函数
  - 返回值        = chat-client:tool-result 实例"
  (let ((chain (build-chain (chat-client-filters chat-client)
                            #'filter-tool-hook
                            (lambda (req) (tool-apply-terminal req)))))
    (funcall chain tool-request)))

(defun tool-apply-terminal (req)
  "工具执行终端：调用 tool-callback-call，异常经 classify-tool-error 分类。

  tool-request-function 可以是 tool-callback 实例或符号（自动解析）。

  此前这里把所有异常硬编码成 :class :semantic——而这是**工具执行的
  唯一终端**，于是三故障分类在实际链路上从不生效：工具 signal 的
  transient-tool-failure / environment-tool-failure 全被压成 :semantic。
  classify-tool-error 当时只在 execute-batch-parallel 的 future 包装里
  被调用一次，那层只能兜住「逃出 :tool filter 的错误」（如 timeout-filter），
  兜不住工具体本身。"
  (let* ((fn-spec (tool-request-function req))
         (callback (etypecase fn-spec
                     (cl-agent/core:tool-callback fn-spec)
                     (symbol (or (cl-agent/core:symbol-tool-callback fn-spec)
                                 (error 'cl-agent/core:tool-not-found-error
                                        :tool-name fn-spec)))))
         (args (tool-request-args req))
         (ctx (tool-request-context req)))
    (handler-case
        (multiple-value-bind (value writes)
            (cl-agent/core:tool-callback-call callback args ctx)
          ;; writes = 工具用 (values 结果 writes-plist) 声明的写意图，
          ;; 这里只装车不生效——批次屏障（fold-batch-writes）统一折叠
          (make-tool-result :value value :writes writes))
      (cl-agent/core:tool-not-found-error (e)
        (make-tool-result :error (make-tool-error-info
                                  :class :semantic
                                  :message "工具未找到"
                                  :cause e)))
      (error (e)
        (make-tool-result :error (make-tool-error-info
                                  :class (classify-tool-error e)
                                  :message (princ-to-string e)
                                  :cause e))))))

;;; ============================================================
;;; invoke-tool-batch：批量执行工具调用（委托 batch.lisp）
;;; ============================================================
;;; P3: 并行默认 + :serial 退化 + 故障路由。
;;; batch.lisp 中的 invoke-tool-batch 是完整实现；这里不再重复定义。
;;; （invoke-tool-batch 在 batch.lisp 中定义，通过 package 导出）

;;; ============================================================
;;; resolve-chat-client-tools：chat-client 工具符号 → chat-options
;;; ============================================================

(defun resolve-chat-client-tools (chat-client)
  "把 chat-client 的 :tools（符号列表）解析为 chat-options（含 tool-callbacks）。"
  (let ((tools (chat-client-tools chat-client)))
    (if tools
        (cl-agent/core:make-chat-options
         :tool-callbacks (cl-agent/core:resolve-tool-callbacks tools))
        nil)))

(defun fold-context-into-tool-context (options context)
  "返回 OPTIONS 的副本，把 CONTEXT（turn context plist）折进它的
tool-context——CONTEXT 的键覆盖同名的既有 tool-context 键。

存在的理由：:chat 链的 filter 只拿得到 prompt，读的是 prompt options
的 tool-context；而 (:conversation ...) / prompt-context 写的是 turn
context。不桥接则二者各说各话（memory-filter 的 :conversation-id 读不到）。

注：此处曾有一张 +internal-context-keys+ 剔除表，唯一的成员是
:caller-options——请求级 options 当年是塞进 context 偷传给循环的，
于是折叠时又得把它捞出来扔掉。options 现在是 chat-client-request 的
prompt 的一部分，暗管道消失，剔除表也随之删除。"
  (let ((extra (copy-list context)))
    (if (null extra)
        (or options (cl-agent/core:make-chat-options))
        (let* ((base (or options (cl-agent/core:make-chat-options)))
               (existing (cl-agent/core:chat-options-tool-context base))
               ;; 先放 extra，再放既有——同名键 extra 胜出（getf 取首个匹配）
               (merged-ctx (append extra existing)))
          ;; 只覆盖 tool-context 一个槽：primary 仅绑定 tool-context，
          ;; merge 把 base 其余槽（含 tool-callbacks）原样保留。
          (cl-agent/core:merge-chat-options
           (cl-agent/core:make-chat-options :tool-context merged-ctx)
           base)))))

;;; ============================================================
;;; run-tool-loop：工具调用循环（:turn 链的 terminal）
;;; ============================================================

(defun resolve-turn-options (chat-client request-options context)
  "把 chat-client 工具 + 请求级 options + turn context 解析成本轮的 chat-options。

REQUEST-OPTIONS 来自 chat-client-request 的 prompt（请求级优先），
chat-client 的工具作为兜底并入。"
  (let* ((chat-client-options (resolve-chat-client-tools chat-client))
         (merged (if request-options
                     (cl-agent/core:merge-chat-options request-options
                                                       chat-client-options)
                     chat-client-options)))
    ;; 把 turn context 折进 options 的 tool-context——:chat 链的 filter
    ;; （memory-filter 等）只拿得到 prompt，读的是 prompt options 的
    ;; tool-context，而 (:conversation ...) / prompt-context 写的是
    ;; turn context。不桥接的话 (:conversation "id") 到不了
    ;; memory-filter，多轮记忆会静默失效。
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
  (cl-agent/core:tool-response-message
   (tool-results->responses tool-results tool-calls)))

(defun run-tool-loop (chat-client request)
  "工具调用循环。不是 filter——是 :turn 链的**缺省** terminal
（经 build-chat-client 的 :loop-fn 可整体替换）。

  每轮：
  1. 构建 prompt（messages + tools）
  2. invoke-chat → chat-response
  3. 响应携带 tool-calls 且通过 eligibility 判定：
     3a. 先过 tool-gate（HITL）——任一判 :pause → 整轮暂停，
         **工具一个都不执行**，返回 chat-client-response(:paused)
     3b. 否则 invoke-tool-batch 执行
  4. 把 assistant(tool-calls) 消息 + tool 结果追加到 messages
  5. 回到 1
  6. 无 tool-calls 或未通过 eligibility → 返回 chat-client-response(:completed)

  最大循环次数取自 chat-client 的 tool-calling-config（缺省 10）。"
  (let ((context (chat-client-request-context request)))
    (%tool-loop chat-client
                (chat-client-request-messages request)
                (resolve-turn-options chat-client
                                      (chat-client-request-options request)
                                      context)
                context
                0)))

(defun %tool-loop (chat-client messages options context iteration)
  "循环主体。从第 ITERATION 轮开始跑——resume 靠它从中点续跑。"
  (let* ((config (chat-client-tool-calling-config chat-client))
         (max-iter (tool-calling-max-iterations config))
         (eligibility (tool-calling-eligibility-fn config))
         (gate (tool-calling-tool-gate config)))
    (loop for iter from iteration
          for prompt = (cl-agent/core:make-prompt messages :options options)
          ;; exec-options = :chat 链改写后**真正发给模型**的那份。
          ;; 工具执行必须用它，否则模型看到的工具集与可执行的不一致
          ;; （tool-search-filter 注入的 search_tools 就会「找不到工具」）。
          for exec-options = nil
          for response = (multiple-value-bind (r eff) (invoke-chat chat-client prompt)
                           (setf exec-options (cl-agent/core:prompt-options eff))
                           r)
          do (cond
               ((and (cl-agent/core:chat-response-has-tool-calls-p response)
                     (funcall eligibility response context))
                ;; 上限检查放在**要执行工具**这个分支里，而不是循环顶部：
                ;;   1. 无工具的最终答复轮不受限——否则一个正好在边界给出
                ;;      答复的对话会被误判成「超限」而非正常返回。
                ;;   2. 用 >= 而非 >：max-iter=N 就是「最多执行 N 轮工具」。
                ;; 此前两处都错：检查在 cond 外（无工具轮也计入并多调一次
                ;; 模型），且用 >（又松一层）——上限 3 实际调了 5 次模型。
                (when (>= iter max-iter)
                  (error 'cl-agent/core:max-tool-iterations-exceeded-error
                         :limit max-iter))
                (let ((tool-calls (cl-agent/core:chat-response-tool-calls response)))
                  ;; HITL 闸门：在**执行之前**评估。判 :pause 就整批不执行，
                  ;; 把续跑所需的一切装进 loop-state 交出去。
                  (multiple-value-bind (paused-call reason)
                      (evaluate-gate gate tool-calls)
                    (if paused-call
                        (return
                          (make-chat-client-response
                           :paused
                           :pause-reason (or reason
                                             (format nil "需要审批：~A"
                                                     (cl-agent/core:tool-call-name paused-call)))
                           :loop-state (make-loop-state
                                        :messages messages
                                        :response response
                                        :tool-calls tool-calls
                                        :pending-id (cl-agent/core:tool-call-id paused-call)
                                        :iteration iter
                                        :options exec-options
                                        :context context)
                           :pending-tool (make-pending-tool
                                          :name (cl-agent/core:tool-call-name paused-call)
                                          :args (cl-agent/core:arguments->plist
                                                 (cl-agent/core:tool-call-arguments paused-call))
                                          :id (cl-agent/core:tool-call-id paused-call))
                           :tool-calls-made iter))
                        ;; 放行：执行整批
                        (multiple-value-bind (result done new-context)
                            (%execute-and-append chat-client response tool-calls
                                                 messages exec-options context iter)
                          (if done
                              (return result)      ; return-direct 收尾
                              (progn
                                (setf messages result)
                                ;; 屏障折叠改了 context → 线程给下一轮：
                                ;; 工具直接拿 context（tool-request :context），
                                ;; :chat filter 读 options 的 tool-context，
                                ;; 两条路都要更新，否则 filter 看到的是旧快照
                                (unless (eq new-context context)
                                  (setf context new-context
                                        options (fold-context-into-tool-context
                                                 options new-context))))))))))
               (t
                ;; 无工具调用：最终响应。tool-context 带出**折叠后**的
                ;; 最终 context——工具经 :writes 累积的状态由此交还调用方
                (return (make-chat-client-response :completed
                                           :chat-response response
                                           :context context
                                           :tool-calls-made iter)))))))

(defun %execute-and-append (chat-client response tool-calls messages options context iteration)
  "执行一批工具并把结果追加进 messages。

返回 (values X done-p new-context)：
  - done-p = nil → X 是追加后的新 messages（继续循环）
  - done-p = t   → X 是终局 chat-client-response（return-direct 收尾）
  - new-context  = 屏障处折叠本批 :writes 后的 context（无写意图时
                   与 CONTEXT 同一对象）——循环用它跑下一轮，
                   下轮工具看到的就是折叠后的快照"
  (let ((tm (chat-client-tool-manager chat-client)))
    (if tm
        ;; === Manager 路径 ===
        ;; execute-tool-calls 的 :context 按协议就是「应用 writes 后的
        ;; context」——此前协议这么写、三个实现全都原样透传。
        ;; :return-direct 也由共享骨架计算（全批声明才短路）。
        (let* ((result (execute-tool-calls tm chat-client response
                                           (list :tool-context context)))
               (return-direct (tool-execution-return-direct-p result))
               (new-context (or (tool-execution-context result) context))
               (tool-msg (cl-agent/core:tool-response-message
                          (tool-execution-messages result))))
          (if return-direct
              ;; return-direct：工具结果即最终答案，不再回传模型。
              ;; 写意图照常折叠（与非 manager 路径一致）
              (values (make-chat-client-response
                       :completed
                       :chat-response (cl-agent/core:make-chat-response
                                  (cl-agent/core:make-generation
                                   (cl-agent/core:assistant-message
                                    (format nil "~{~A~^~%~}"
                                            (mapcar #'cl-agent/core:tool-response-text
                                                    (tool-execution-messages result))))
                                   :finish-reason :stop))
                       :context new-context
                       :tool-calls-made (1+ iteration))
                      t
                      new-context)
              (values (append messages
                              (list (cl-agent/core:chat-response-message response) tool-msg))
                      nil
                      new-context)))
        ;; === 原路径（invoke-tool-batch）===
        (multiple-value-bind (tool-results return-direct)
            (invoke-tool-batch chat-client tool-calls options context)
          (let ((tool-msg (tool-results->message tool-results tool-calls))
                (new-context (fold-batch-writes chat-client tool-results context)))
            (if return-direct
                ;; return-direct：工具结果即最终答案，不再回传模型。
                ;; 写意图照常折叠——工具确实执行了，状态不能丢
                (values (make-chat-client-response
                         :completed
                         :chat-response (cl-agent/core:make-chat-response
                                    (cl-agent/core:make-generation
                                     (cl-agent/core:assistant-message
                                      (format nil "~{~A~^~%~}"
                                              (mapcar #'tool-result-value tool-results)))
                                     :finish-reason :stop))
                         :context new-context
                         :tool-calls-made (1+ iteration))
                        t
                        new-context)
                (values (append messages
                                (list (cl-agent/core:chat-response-message response) tool-msg))
                        nil
                        new-context)))))))

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
    (:reply (let ((msg (resume-payload-message payload)))
              (unless (stringp msg)
                (error ":reply 需要 payload 的 :message（答复文本），收到 ~S。" msg))
              (lambda (tc)
                (if (equal (cl-agent/core:tool-call-id tc) pending-id)
                    (cons :reply msg)
                    :proceed))))
    ;; 拒绝：只拒 pending 那个，其余照常执行
    (:rejected (let ((reason (resume-payload-message payload)))
                 (lambda (tc)
                   (if (equal (cl-agent/core:tool-call-id tc) pending-id)
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

(defun %resume-continuation (chat-client loop-state decision payload)
  "暂停延续：按决定处理 pending 批次，然后接着跑循环。"
  (let* ((tool-calls (loop-state-tool-calls loop-state))
         (pending-id (loop-state-pending-id loop-state))
         (messages (loop-state-messages loop-state))
         (response (loop-state-response loop-state))
         (options (loop-state-options loop-state))
         (context (loop-state-context loop-state))
         (iteration (loop-state-iteration loop-state))
         ;; 编辑后批准：用新参数替换 pending 工具的参数
         (new-args (and (eq decision :approved) (resume-payload-args payload)))
         (tool-calls (if new-args
                         (mapcar (lambda (tc)
                                   (if (equal (cl-agent/core:tool-call-id tc) pending-id)
                                       (cl-agent/core:make-tool-call
                                        :id (cl-agent/core:tool-call-id tc)
                                        :name (cl-agent/core:tool-call-name tc)
                                        :arguments new-args)
                                       tc))
                                 tool-calls)
                         tool-calls))
         (gate (%resume-gate decision payload pending-id)))
    (multiple-value-bind (callable decided) (%apply-resume-gate gate tool-calls)
      ;; 真要执行的那部分走正常批执行；被拒/被答复的直接用现成文本
      ;; 经 manager-run-batch 路由：若配了 thread-pool manager，续跑批也受限流
      ;; （此前直接调 invoke-tool-batch，manager 被绕过）
      (let* ((tm (chat-client-tool-manager chat-client))
             (executed (when callable
                         (multiple-value-list
                          (if tm
                              (manager-run-batch tm chat-client callable options context)
                              (invoke-tool-batch chat-client callable options context)))))
             (results (first executed))
             ;; 屏障折叠：真执行了的那部分照常提交写意图（callable 保持
             ;; 原始相对序）；被拒/被答复的没执行，自然没有写
             (context (if results
                          (fold-batch-writes chat-client results context)
                          context))
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
             (tool-msg (cl-agent/core:tool-response-message
                        (mapcar (lambda (tc text)
                                  (cl-agent/core:make-tool-response
                                   :id (cl-agent/core:tool-call-id tc)
                                   :name (cl-agent/core:tool-call-name tc)
                                   :text text))
                                tool-calls texts))))
        ;; return-direct 短路——正常路径（%execute-and-append）对全批
        ;; return-direct 会把工具结果直接当最终答复、不回模型；resume
        ;; 此前漏了这一步，approve 一个 return-direct 工具后又多调一次
        ;; 模型（拿到的还是「不该来」的续写）。
        ;; 只在**全部真执行且全 return-direct**时短路：有被拒/被答复的
        ;; （decided 非空）说明要把结果回给模型，不短路。
        (if (and callable (null decided)
                 (batch-all-return-direct-p callable options))
            (make-chat-client-response
             :completed
             :chat-response (cl-agent/core:make-chat-response
                        (cl-agent/core:make-generation
                         (cl-agent/core:assistant-message
                          (format nil "~{~A~^~%~}" texts))
                         :finish-reason :stop))
             :context context
             :tool-calls-made (1+ iteration))
            (%tool-loop chat-client
                        (append messages
                                (list (cl-agent/core:chat-response-message response) tool-msg))
                        ;; context 若被写意图更新，options 的 tool-context 也要跟上
                        (fold-context-into-tool-context options context)
                        context (1+ iteration)))))))

;;; ============================================================
;;; 循环实现的解析：loop-fn / resume-fn
;;; ============================================================
;;;
;;; 缺省值不能写进 chat-client 的 initform——chat-client.lisp 先于本文件加载，
;;; 那时 run-tool-loop / %resume-continuation 还不存在。故在调用点兜底。

(defun chat-client-loop-function (chat-client)
  "本 chat-client 的工具循环实现：(chat-client request) → chat-client-response。
缺省 run-tool-loop。"
  (or (tool-calling-loop-fn (chat-client-tool-calling-config chat-client))
      #'run-tool-loop))

(defun chat-client-resume-function (chat-client)
  "本 chat-client 的暂停延续实现：(chat-client loop-state decision payload) → chat-client-response。
缺省 %resume-continuation（配套 run-tool-loop）。"
  (or (tool-calling-resume-fn (chat-client-tool-calling-config chat-client))
      #'%resume-continuation))

(defun resume-turn (chat-client loop-state decision &key payload)
  "从暂停点续跑工具循环。

  参数：
  - loop-state  chat-client-response(:paused) 上的 loop-state
  - decision    :approved | :rejected | :reply
  - payload     resume-payload 实例，或等价的 plist（入口处归一）：
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
  (let* ((payload (coerce-resume-payload payload))
         (consumed nil)
         (context (loop-state-context loop-state))
         (terminal (lambda (req)
                     (if (not consumed)
                         (progn (setf consumed t)
                                (funcall (chat-client-resume-function chat-client)
                                         chat-client loop-state decision payload))
                         ;; turn filter 递归重入 → 走常规循环（新 delta）
                         (funcall (chat-client-loop-function chat-client) chat-client req))))
         (chain (build-chain (chat-client-filters chat-client) #'filter-turn-hook terminal)))
    (funcall chain (make-chat-client-request nil :context context :resume-p t))))

;;; ============================================================
;;; invoke-turn：:turn 链包住 run-tool-loop
;;; ============================================================

(defun invoke-turn (chat-client request)
  "经 :turn filter 链执行一轮对话。

  :turn 链包住 terminal（缺省 run-tool-loop，可由 chat-client 的 :loop-fn
  替换）。turn filter 可：
  - 改写入口请求（RAG 注入、re-reading）——用 chat-client-request-mutate
  - 短路（safeguard 拦截）
  - 递归重入（validation 校验失败 → 再调 chain）

  :turn filter 钩子签名：(chat-client-request chain) → chat-client-response"
  (let ((chain (build-chain (chat-client-filters chat-client)
                            #'filter-turn-hook
                            (lambda (req)
                              (funcall (chat-client-loop-function chat-client) chat-client req)))))
    (funcall chain request)))
