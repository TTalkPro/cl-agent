;;;; loop.lisp
;;;; CL-Agent SimpleAgent - 工具调用循环（Agent 运行时策略）
;;;;
;;;; 概述（参照 clj-agent react.clj / onion-filter.md §6）：
;;;;   工具调用循环是 Agent 运行时的"策略"而非 Kernel 的"原语"——
;;;;   Kernel 只负责 invoke-chat（单次 LLM）与 invoke-tool（单次工具），
;;;;   循环、回调触发、请求级 filter（如 Agent 私有的 memory-filter）
;;;;   全部住在这里。
;;;;
;;;;   run-tool-loop 的回调（on-tool-call / on-tool-result）是
;;;;   Agent 层概念，Kernel 对回调零感知。

(in-package #:cl-agent.simpleagent)

;;; ============================================================
;;; 工具执行
;;; ============================================================

(defun execute-tool-call (kernel tool-call context on-tool-call on-tool-result)
  "执行单个工具调用（经 :tool 洋葱链），触发回调。

参数：
  KERNEL         - Kernel 实例
  TOOL-CALL      - 工具调用 plist (:id :name :arguments)
  CONTEXT        - 执行上下文
  ON-TOOL-CALL   - 调用前回调 (name args)，可为 NIL
  ON-TOOL-RESULT - 调用后回调 (name result)，可为 NIL

返回：
  plist (:tool-call (:name :args :result) :message <中立 tool 消息>)"
  (let* ((tc-id (getf tool-call :id))
         (tc-name-str (getf tool-call :name))
         (tc-name (if (keywordp tc-name-str)
                      tc-name-str
                      (intern (string-upcase tc-name-str) :keyword)))
         (tc-args (cl-agent.kernel:parse-tool-arguments
                   (getf tool-call :arguments))))
    (when on-tool-call
      (funcall on-tool-call tc-name tc-args))
    (let* ((result (invoke-tool kernel tc-name tc-args
                                :context (list :tool-id tc-id
                                               :context-object context)))
           (result-str (if (stringp result)
                           result
                           (format nil "~S" result))))
      (when on-tool-result
        (funcall on-tool-result tc-name result))
      (list :tool-call (list :name tc-name :args tc-args :result result)
            :message (list :role :tool
                           :tool-call-id tc-id
                           :content result-str)))))

(defun execute-tool-calls (kernel tool-calls context on-tool-call on-tool-result)
  "执行一批工具调用。

返回：
  (values tool-results tool-messages)"
  (let ((tool-results nil)
        (tool-messages nil))
    (dolist (tc tool-calls)
      (let ((result (execute-tool-call kernel tc context
                                       on-tool-call on-tool-result)))
        (push (getf result :tool-call) tool-results)
        (push (getf result :message) tool-messages)))
    (values (nreverse tool-results)
            (nreverse tool-messages))))

;;; ============================================================
;;; run-tool-loop —— 工具调用循环主入口
;;; ============================================================

(defun run-tool-loop (kernel messages &key settings context filters
                                           on-tool-call on-tool-result)
  "完整 Chat + 工具调用循环（Agent 运行时主入口）。

每一轮 LLM 调用都经过 :chat 洋葱链（FILTERS 在 kernel filters 外层），
工具执行经过 :tool 链。

当 CONTEXT 携带 :conversation-id 且 FILTERS 含 memory-filter 时进入
delta 模式：每轮只把增量消息（首轮为入参，后续为工具结果）交给链，
由 memory-filter 展开完整历史——store 是对话的唯一事实来源。

参数：
  KERNEL         - Kernel 实例
  MESSAGES       - 消息列表或 chat-history
  SETTINGS       - 设置 plist：
    :tool-choice   - :auto | :required | :none（默认 :auto）
    :max-attempts  - 最大迭代次数（默认 10）
    :system-prompt - 系统提示
    :max-tokens / :temperature 等透传 LLM
  CONTEXT        - 执行上下文（可选）
  FILTERS        - 请求级 filter 列表（调用方私有，如 Agent 的
                   memory-filter；不污染 kernel）
  ON-TOOL-CALL   - 回调 (name args)
  ON-TOOL-RESULT - 回调 (name result)

返回：
  结果 plist (:text :tool-calls-made :history :context :response)"
  (let* ((tool-choice (or (getf settings :tool-choice) :auto))
         (max-attempts (getf settings :max-attempts 10))
         (system-prompt (getf settings :system-prompt))
         (on-tool-call (or on-tool-call (getf settings :on-tool-call)))
         (on-tool-result (or on-tool-result (getf settings :on-tool-result)))
         (conversation-id (cl-agent.kernel:context-conversation-id context))
         (delta-mode (and conversation-id t))
         (incoming (cl-agent.kernel:normalize-messages messages))
         ;; 全量模式：system 折叠进消息；delta 模式：system 经 request 槽位下发
         (msgs (if delta-mode
                   incoming
                   (cl-agent.kernel:prepare-messages-with-system incoming system-prompt)))
         (chain-settings (alexandria:remove-from-plist
                          settings
                          :system-prompt :tool-choice :max-attempts
                          :on-tool-call :on-tool-result))
         (tools (unless (eq tool-choice :none)
                  (kernel-get-tools kernel)))
         (ctx (or context (make-context :messages msgs)))
         (delta msgs)              ; 本轮要发送的增量
         (tool-calls-made nil)
         (attempts 0))
    ;; 主循环：每轮经过 chat 洋葱链
    (loop
      (when (>= attempts max-attempts)
        (error "run-tool-loop exceeded max-attempts (~A)" max-attempts))
      (let* ((request (cl-agent.kernel:make-chat-request
                       :messages (if delta-mode delta msgs)
                       :tools tools
                       :tool-choice tool-choice
                       :system-prompt (when delta-mode system-prompt)
                       :settings chain-settings
                       :context ctx
                       :kernel kernel))
             (response (cl-agent.kernel:run-chat-chain kernel request
                                                       :extra-filters filters))
             (response-tool-calls (cl-agent.core:llm-response-tool-calls response)))
        (if (and response-tool-calls (not (eq tool-choice :none)))
            ;; 有工具调用
            (let ((tool-calls-plist
                    (mapcar (lambda (tc)
                              (list :id (cl-agent.core:llm-tool-call-id tc)
                                    :name (cl-agent.core:llm-tool-call-name tc)
                                    :arguments (cl-agent.core:llm-tool-call-arguments tc)))
                            response-tool-calls)))
              (incf attempts)
              ;; 记录 assistant 响应（delta 模式下由 memory filter 落库，
              ;; 本地 msgs 仅用于返回 :history）
              (let ((assistant-msg (list :role :assistant
                                         :content (or (cl-agent.core:llm-response-content response) "")
                                         :tool-calls tool-calls-plist)))
                (setf msgs (append msgs (list assistant-msg)))
                (when (typep ctx 'cl-agent.kernel:context)
                  (context-add-message ctx assistant-msg)))
              ;; 执行工具调用（经 :tool 链）
              (multiple-value-bind (results tool-messages)
                  (execute-tool-calls kernel tool-calls-plist ctx
                                      on-tool-call on-tool-result)
                (setf tool-calls-made (append tool-calls-made results))
                (setf msgs (append msgs tool-messages))
                (setf delta tool-messages)   ; 下一轮只发工具结果
                (when (typep ctx 'cl-agent.kernel:context)
                  (dolist (msg tool-messages)
                    (context-add-message ctx msg)))))
            ;; 无工具调用 - 返回最终响应
            (let ((text (or (cl-agent.core:llm-response-content response) "")))
              ;; 更新 chat-history（如果使用）
              (when (cl-agent.kernel:chat-history-p messages)
                (setf (cl-agent.kernel:chat-history-messages messages) msgs)
                (cl-agent.kernel:history-add messages :assistant text))
              (return (list :text text
                            :tool-calls-made tool-calls-made
                            :history msgs
                            :context ctx
                            :response response))))))))

;;; ============================================================
;;; 向后兼容别名
;;; ============================================================

(defun invoke-kernel (kernel messages &rest args &key settings context
                                                      filters on-tool-call on-tool-result)
  "run-tool-loop 的向后兼容别名（原 cl-agent.kernel:invoke-kernel）。"
  (declare (ignore settings context filters on-tool-call on-tool-result))
  (apply #'run-tool-loop kernel messages args))

;;; ============================================================
;;; 便捷函数
;;; ============================================================

(defun quick-chat (kernel user-message &key system-prompt)
  "快速单轮对话（带工具循环）。

返回：
  响应文本字符串"
  (let* ((msgs (if system-prompt
                   (list (list :role :system :content system-prompt)
                         (list :role :user :content user-message))
                   (list (list :role :user :content user-message))))
         (result (run-tool-loop kernel msgs)))
    (getf result :text)))

(defun chat-with-tools (kernel user-message tools-plugin &key system-prompt)
  "使用特定插件的工具进行对话。

返回：
  结果 plist"
  (let ((temp-kernel (make-kernel :service (kernel-get-service kernel)
                                  :plugins (list tools-plugin)
                                  :filters (kernel-filters kernel))))
    (run-tool-loop temp-kernel
                   (list (list :role :user :content user-message))
                   :settings (list :system-prompt system-prompt))))
