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
;;;;   Tool 链请求/响应 = tool-request / tool-response（kernel 载体）。
;;;;   Turn 链请求/响应 = turn-request / turn-result（kernel 载体）。

(in-package #:cl-agent.kernel)

;;; ============================================================
;;; invoke-chat：:chat 链 → ChatModel
;;; ============================================================

(defun invoke-chat (kernel prompt)
  "经 :chat filter 链调用 LLM（单次，不执行工具）。

  PROMPT 可以是 string / 消息列表 / prompt 实例（ChatModel 自动包装）。
  返回 cl-agent.chat:chat-response 实例。

  :chat filter 钩子签名：(prompt chain) → chat-response
  - prompt  = cl-agent.chat:prompt 实例
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

  :tool filter 钩子签名：(tool-request chain) → tool-response
  - tool-request  = kernel:tool-request 实例
  - chain         = 下游函数
  - 返回值        = kernel:tool-response 实例"
  (let ((chain (build-chain (kernel-filters kernel)
                            #'filter-tool-hook
                            (lambda (req) (tool-apply-terminal req)))))
    (funcall chain tool-request)))

(defun tool-apply-terminal (req)
  "工具执行终端：调用 tool-callback-call，捕获异常为 :semantic 错误。

  tool-request-function 可以是 tool-callback 实例或符号（自动解析）。"
  (let* ((fn-spec (tool-request-function req))
         (callback (etypecase fn-spec
                     (cl-agent.chat:tool-callback fn-spec)
                     (symbol (or (cl-agent.chat:symbol-tool-callback fn-spec)
                                 (error 'cl-agent.chat:tool-not-found-error
                                        :tool-name fn-spec)))))
         (args (tool-request-args req))
         (ctx (tool-request-context req)))
    (handler-case
        (make-tool-response :result (cl-agent.chat:tool-callback-call
                                     callback args ctx))
      (cl-agent.chat:tool-not-found-error (e)
        (declare (ignore e))
        (make-tool-response :error (list :class :semantic
                                         :message "工具未找到")))
      (error (e)
        (make-tool-response :error (list :class :semantic
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
        (cl-agent.chat:make-chat-options
         :tool-callbacks (cl-agent.chat:resolve-tool-callbacks tools))
        nil)))

;;; ============================================================
;;; run-tool-loop：工具调用循环（:turn 链的 terminal）
;;; ============================================================

(defun run-tool-loop (kernel turn-request)
  "工具调用循环。不是 filter——是 :turn 链的 terminal。

  每轮：
  1. 构建 prompt（messages + tools）
  2. invoke-chat → chat-response
  3. 如果响应携带 tool-calls 且通过 eligibility 判定 → invoke-tool-batch
  4. 把 assistant(tool-calls) 消息 + tool 结果追加到 messages
  5. 回到 1
  6. 否则（无 tool-calls 或未通过 eligibility）→ 返回 turn-result(:completed)

  最大循环次数从 kernel settings 取（缺省 10）。"
  (let* ((max-iter (or (cdr (assoc :max-tool-iterations (kernel-settings kernel)))
                       10))
         (options (resolve-kernel-tools kernel))
         (eligibility (kernel-eligibility-fn kernel))
         (context (turn-request-context turn-request)))
    (loop for iteration from 0
          with messages = (turn-request-messages turn-request)
          for prompt = (cl-agent.chat:make-prompt messages :options options)
          for response = (invoke-chat kernel prompt)
          do (when (> iteration max-iter)
               (error 'cl-agent.chat:max-tool-iterations-exceeded-error
                      :limit max-iter))
             (cond
               ((and (cl-agent.chat:chat-response-has-tool-calls-p response)
                     (funcall eligibility response context))
                ;; 有工具调用：执行 → 追加消息 → 继续
                (let* ((tool-calls (cl-agent.chat:chat-response-tool-calls response)))
                  (multiple-value-bind (tool-results return-direct)
                      (invoke-tool-batch kernel tool-calls options context)
                    (let ((tool-msg (cl-agent.chat:tool-response-message
                                     (mapcar (lambda (tr tc)
                                               (cl-agent.chat:make-tool-response
                                                :id (cl-agent.chat:tool-call-id tc)
                                                :name (cl-agent.chat:tool-call-name tc)
                                                :text (or (tool-response-result tr)
                                                          "（执行失败）")))
                                             tool-results tool-calls))))
                      (if return-direct
                          ;; return-direct：工具结果即最终答案，不再回传模型
                          (let ((final-text
                                  (format nil "~{~A~^~%~}"
                                          (mapcar #'tool-response-result tool-results))))
                            (return (make-turn-result
                                     :completed
                                     :response (cl-agent.chat:make-chat-response
                                                (cl-agent.chat:make-generation
                                                 (cl-agent.chat:assistant-message final-text)
                                                 :finish-reason :stop))
                                     :tool-calls-made (1+ iteration))))
                          ;; 正常路径：追加消息 → 继续循环
                          (setf messages
                                (append messages
                                        (list (cl-agent.chat:chat-response-message response)
                                              tool-msg))))))))
               (t
                ;; 无工具调用：最终响应
                (return (make-turn-result :completed :response response
                                          :tool-calls-made iteration)))))))

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
