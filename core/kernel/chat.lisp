;;;; chat.lisp
;;;; CL-Agent Kernel - 3-Tier Invoke API
;;;;
;;;; 概述：
;;;;   实现 3 层 Chat API（遵循 clj-agent 模式）：
;;;;   - invoke-tool: 执行单个工具（通过过滤器链）
;;;;   - invoke-chat: 单次 LLM 调用（无工具循环）
;;;;   - invoke-kernel: 完整工具调用循环（主入口）
;;;;
;;;; 设计：
;;;;   - 使用 Service 抽象进行 LLM 调用
;;;;   - 使用 Context 进行状态管理
;;;;   - 在适当的点应用类型化过滤器
;;;;   - 函数嵌套不超过 3 层

(in-package #:cl-agent.kernel)

;;; ============================================================
;;; 消息处理辅助函数
;;; ============================================================

(defun normalize-messages (messages)
  "规范化消息列表

参数：
  MESSAGES - 消息列表或 chat-history

返回：
  消息列表（副本）"
  (cond
    ((chat-history-p messages)
     (copy-list (chat-history-messages messages)))
    ((listp messages)
     (copy-list messages))
    (t (list messages))))

(defun prepare-messages-with-system (messages system-prompt)
  "准备带系统提示的消息列表

参数：
  MESSAGES      - 消息列表
  SYSTEM-PROMPT - 系统提示（可选）

返回：
  处理后的消息列表"
  (unless system-prompt
    (return-from prepare-messages-with-system messages))
  (let ((msgs (copy-list messages)))
    (if (and msgs (eq (getf (first msgs) :role) :system))
        ;; 更新现有系统消息
        (setf (getf (first msgs) :content) system-prompt)
        ;; 插入新系统消息
        (push (list :role :system :content system-prompt) msgs))
    msgs))

(defun parse-tool-arguments (args-raw)
  "解析工具调用参数

参数：
  ARGS-RAW - 原始参数（hash-table、JSON 字符串或 plist）

返回：
  关键字 plist 格式的参数"
  (cond
    ;; 已经是 plist
    ((and (listp args-raw)
          (or (null args-raw)
              (keywordp (first args-raw))))
     args-raw)
    ;; Hash-table（来自 JSON 解析）
    ((hash-table-p args-raw)
     (hash-to-plist args-raw))
    ;; JSON 字符串
    ((stringp args-raw)
     (handler-case
         (let ((parsed (cl-agent.core:json-parse args-raw)))
           (if (hash-table-p parsed)
               (hash-to-plist parsed)
               parsed))
       (error () nil)))
    (t nil)))

(defun hash-to-plist (ht)
  "将 hash-table 转换为关键字 plist

参数：
  HT - Hash-table

返回：
  关键字 plist"
  (let ((result nil))
    (maphash (lambda (k v)
               (let ((key (if (keywordp k)
                              k
                              (intern (string-upcase
                                       (if (stringp k) k (string k)))
                                      :keyword))))
                 (push v result)
                 (push key result)))
             ht)
    result))

;;; ============================================================
;;; 工具执行辅助函数
;;; ============================================================

(defun execute-tool-call (kernel tool-call context on-tool-call on-tool-result)
  "执行单个工具调用

参数：
  KERNEL         - Kernel 实例
  TOOL-CALL      - 工具调用 plist
  CONTEXT        - 执行上下文
  ON-TOOL-CALL   - 调用前回调
  ON-TOOL-RESULT - 调用后回调

返回：
  工具结果消息 plist"
  (let* ((tc-id (getf tool-call :id))
         (tc-name-str (getf tool-call :name))
         (tc-name (if (keywordp tc-name-str)
                      tc-name-str
                      (intern (string-upcase tc-name-str) :keyword)))
         (tc-args (parse-tool-arguments (getf tool-call :arguments))))
    ;; 调用前回调
    (when on-tool-call
      (funcall on-tool-call tc-name tc-args))
    ;; 执行工具
    (let* ((result (invoke-tool kernel tc-name tc-args
                                :context (list :tool-id tc-id
                                               :context-object context)))
           (result-str (if (stringp result)
                           result
                           (format nil "~S" result))))
      ;; 调用后回调
      (when on-tool-result
        (funcall on-tool-result tc-name result))
      ;; 返回结果
      (list :tool-call (list :name tc-name :args tc-args :result result)
            :message (list :role :tool
                           :tool-call-id tc-id
                           :content result-str)))))

(defun execute-tool-calls (kernel tool-calls context on-tool-call on-tool-result)
  "执行一批工具调用

参数：
  KERNEL         - Kernel 实例
  TOOL-CALLS     - 工具调用列表
  CONTEXT        - 执行上下文
  ON-TOOL-CALL   - 调用前回调
  ON-TOOL-RESULT - 调用后回调

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
;;; Chat History（向后兼容）
;;; ============================================================

(defstruct (chat-history (:constructor make-chat-history))
  "可变消息列表（向后兼容）"
  (messages nil :type list))

(defun history-add (history role content)
  "添加消息到历史

参数：
  HISTORY - chat-history 实例
  ROLE    - 消息角色（:user, :assistant, :tool）
  CONTENT - 消息内容"
  (setf (chat-history-messages history)
        (append (chat-history-messages history)
                (list (list :role role :content content))))
  history)

(defun history-add-system (history content)
  "添加或替换系统消息

参数：
  HISTORY - chat-history 实例
  CONTENT - 系统提示内容"
  (let ((msgs (chat-history-messages history)))
    (if (and msgs (eq (getf (first msgs) :role) :system))
        (setf (first (chat-history-messages history))
              (list :role :system :content content))
        (setf (chat-history-messages history)
              (cons (list :role :system :content content) msgs))))
  history)

;;; ============================================================
;;; Tier 1: invoke-tool - 单个工具执行
;;; ============================================================

(defgeneric invoke-tool (kernel fn-name args &key context)
  (:documentation "通过过滤器管道执行单个工具

这是 Invoke API 的第一层 - 直接工具执行

参数：
  KERNEL  - Kernel 实例
  FN-NAME - 函数名称（关键字）
  ARGS    - 参数 plist
  CONTEXT - 执行上下文（可选）

返回：
  工具执行结果

错误：
  如果函数未找到则发出错误"))

(defmethod invoke-tool ((kernel kernel) fn-name args &key context)
  "通过 :tool 洋葱链执行单个工具"
  (let ((tool (kernel-find-tool kernel fn-name)))
    (unless tool
      (error "Tool ~A not found in kernel" fn-name))
    (let* ((terminal (lambda (request)
                       (kernel-execute-tool kernel
                                            (tool-request-name request)
                                            (tool-request-args request))))
           (chain (build-phase-chain (kernel-filters kernel) :tool terminal))
           (request (make-tool-request :tool-name fn-name
                                       :args args
                                       :tool tool
                                       :context context
                                       :kernel kernel)))
      (funcall chain request))))

;;; ============================================================
;;; Tier 2: invoke-chat - 单次 LLM 调用
;;; ============================================================

(defgeneric invoke-chat (kernel messages &key settings context)
  (:documentation "单次 Chat Completion（无工具调用循环）

这是 Invoke API 的第二层 - 单次 LLM 调用

参数：
  KERNEL   - Kernel 实例
  MESSAGES - 消息列表或 chat-history
  SETTINGS - 设置 plist：
    :system-prompt - 系统提示
    :max-tokens    - 最大 token 数
    :temperature   - 温度
  CONTEXT  - 执行上下文（可选）

返回：
  LLM 响应 plist (:content ... :tool-calls ... :usage ...)"))

(defun run-chat-chain (kernel request)
  "把 chat-request 送入 :chat 洋葱链，最内层 terminal 真正调 LLM。

chat filter 可以改写 request 的 messages / tools / tool-choice /
system-prompt / settings（参见 chat-request）。

参数：
  KERNEL  - Kernel 实例
  REQUEST - chat-request 实例

返回：
  llm-response 对象"
  (let* ((service (kernel-get-service kernel))
         (terminal (lambda (req)
                     (service-chat service
                                   (chat-request-messages req)
                                   (unless (eq (chat-request-tool-choice req) :none)
                                     (chat-request-tools req))
                                   (let ((settings (chat-request-settings req)))
                                     (if (chat-request-system-prompt req)
                                         (list* :system-prompt (chat-request-system-prompt req)
                                                settings)
                                         settings)))))
         (chain (build-phase-chain (kernel-filters kernel) :chat terminal)))
    (funcall chain request)))

(defmethod invoke-chat ((kernel kernel) messages &key settings context)
  "单次 LLM 调用（无工具循环），经过 :chat 洋葱链"
  (let* ((system-prompt (getf settings :system-prompt))
         (msgs (normalize-messages messages))
         (msgs-with-system (prepare-messages-with-system msgs system-prompt))
         (request (make-chat-request
                   :messages msgs-with-system
                   :tools (kernel-get-tools kernel)
                   :tool-choice (or (getf settings :tool-choice) :auto)
                   ;; system 已折叠进 messages，避免经 settings 重复下发
                   :settings (alexandria:remove-from-plist settings :system-prompt)
                   :context context
                   :kernel kernel)))
    (run-chat-chain kernel request)))

;;; ============================================================
;;; Tier 3: invoke-kernel - 完整工具调用循环
;;; ============================================================

(defgeneric invoke-kernel (kernel messages &key settings context)
  (:documentation "完整 Chat + 工具调用循环

这是 Invoke API 的第三层 - 主入口

参数：
  KERNEL   - Kernel 实例
  MESSAGES - 消息列表或 chat-history
  SETTINGS - 设置 plist：
    :tool-choice      - :auto | :required | :none（默认 :auto）
    :max-attempts     - 最大迭代次数（默认 10）
    :system-prompt    - 系统提示
    :on-tool-call     - 回调 (lambda (name args))
    :on-tool-result   - 回调 (lambda (name result))
    :max-tokens       - 最大 token 数
    :temperature      - 温度
  CONTEXT  - 执行上下文（可选）

返回：
  结果 plist (:text ... :tool-calls-made ... :history ... :context ...)"))

(defun context-conversation-id (context)
  "从执行上下文中读取 conversation-id（memory filter 的会话键）。

CONTEXT 可以是 context 实例、plist 或 NIL。"
  (typecase context
    (context (context-get context :conversation-id))
    (list (getf context :conversation-id))
    (t nil)))

(defmethod invoke-kernel ((kernel kernel) messages &key settings context)
  "带自动工具执行的完整工具调用循环。

每一轮 LLM 调用都经过 :chat 洋葱链（memory / logging 等 chat filter
在循环内生效）；工具执行经过 :tool 链。

当 CONTEXT 中携带 :conversation-id 时进入 delta 模式：每轮只把
增量消息（首轮为入参消息，后续为工具结果）交给 chat 链，由
memory filter 负责展开完整历史——store 是对话的唯一事实来源。"
  (let* ((tool-choice (or (getf settings :tool-choice) :auto))
         (max-attempts (getf settings :max-attempts 10))
         (system-prompt (getf settings :system-prompt))
         (on-tool-call (getf settings :on-tool-call))
         (on-tool-result (getf settings :on-tool-result))
         (conversation-id (context-conversation-id context))
         (delta-mode (and conversation-id t))
         (incoming (normalize-messages messages))
         ;; 全量模式：system 折叠进消息；delta 模式：system 经 request 槽位下发
         (msgs (if delta-mode
                   incoming
                   (prepare-messages-with-system incoming system-prompt)))
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
        (error "invoke-kernel exceeded max-attempts (~A)" max-attempts))
      (let* ((request (make-chat-request
                       :messages (if delta-mode delta msgs)
                       :tools tools
                       :tool-choice tool-choice
                       :system-prompt (when delta-mode system-prompt)
                       :settings chain-settings
                       :context ctx
                       :kernel kernel))
             (response (run-chat-chain kernel request))
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
                (when (typep ctx 'context)
                  (context-add-message ctx assistant-msg)))
              ;; 执行工具调用（经 :tool 链）
              (multiple-value-bind (results tool-messages)
                  (execute-tool-calls kernel tool-calls-plist ctx
                                      on-tool-call on-tool-result)
                (setf tool-calls-made (append tool-calls-made results))
                (setf msgs (append msgs tool-messages))
                (setf delta tool-messages)   ; 下一轮只发工具结果
                (when (typep ctx 'context)
                  (dolist (msg tool-messages)
                    (context-add-message ctx msg)))))
            ;; 无工具调用 - 返回最终响应
            (let ((text (or (cl-agent.core:llm-response-content response) "")))
              ;; 更新 chat-history（如果使用）
              (when (chat-history-p messages)
                (setf (chat-history-messages messages) msgs)
                (history-add messages :assistant text))
              (return (list :text text
                            :tool-calls-made tool-calls-made
                            :history msgs
                            :context ctx
                            :response response))))))))

;;; ============================================================
;;; 流式支持
;;; ============================================================

(defgeneric invoke-chat-stream (kernel messages callback &key settings context)
  (:documentation "invoke-chat 的流式版本

参数：
  KERNEL   - Kernel 实例
  MESSAGES - 消息列表
  CALLBACK - 每个块调用的函数 (chunk)
  SETTINGS - 设置 plist
  CONTEXT  - 执行上下文

返回：
  最终响应 plist"))

(defmethod invoke-chat-stream ((kernel kernel) messages callback &key settings context)
  "流式单次 LLM 调用"
  (let* ((msgs (normalize-messages messages))
         (tools (kernel-get-tools kernel))
         (service (kernel-get-service kernel))
         (provider (service-provider service)))
    (if (and provider (provider-supports-streaming-p provider))
        (llm-chat-stream provider msgs callback
                         :tools tools
                         :max-tokens (getf settings :max-tokens)
                         :temperature (getf settings :temperature)
                         :system (getf settings :system-prompt))
        ;; 回退到非流式
        (let ((response (invoke-chat kernel messages
                                     :settings settings
                                     :context context)))
          (funcall callback (list :delta (cl-agent.core:llm-response-content response) :done t))
          response))))

;;; ============================================================
;;; 便捷函数
;;; ============================================================

(defun quick-chat (kernel user-message &key system-prompt)
  "快速单轮对话

参数：
  KERNEL       - Kernel 实例
  USER-MESSAGE - 用户消息字符串
  SYSTEM-PROMPT - 可选系统提示

返回：
  响应文本字符串"
  (let* ((msgs (if system-prompt
                   (list (list :role :system :content system-prompt)
                         (list :role :user :content user-message))
                   (list (list :role :user :content user-message))))
         (result (invoke-kernel kernel msgs)))
    (getf result :text)))

(defun chat-with-tools (kernel user-message tools-plugin &key system-prompt)
  "使用特定工具进行对话

参数：
  KERNEL       - Kernel 实例（可能没有插件）
  USER-MESSAGE - 用户消息
  TOOLS-PLUGIN - 要使用的插件符号
  SYSTEM-PROMPT - 可选系统提示

返回：
  结果 plist"
  (let ((temp-kernel (make-kernel :service (kernel-get-service kernel)
                                  :plugins (list tools-plugin)
                                  :filters (kernel-filters kernel))))
    (invoke-kernel temp-kernel
                   (list (list :role :user :content user-message))
                   :settings (list :system-prompt system-prompt))))
