;;;; chat.lisp
;;;; CL-Agent Kernel - Invoke 原语（遵循 clj-agent 模式）
;;;;
;;;; 概述：
;;;;   Kernel 的不可约内核 = 两个原语 + Filter 机制：
;;;;   - invoke-tool: 执行单个工具（:tool 洋葱链）
;;;;   - invoke-chat: 单次 LLM 调用（:chat 洋葱链）
;;;;
;;;;   工具调用循环（run-tool-loop）是 Agent 运行时的策略，
;;;;   位于 cl-agent.simpleagent —— Kernel 不负责全流程。
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

(defun run-chat-chain (kernel request &key extra-filters)
  "把 chat-request 送入 :chat 洋葱链，最内层 terminal 真正调 LLM。

chat filter 可以改写 request 的 messages / tools / tool-choice /
system-prompt / settings（参见 chat-request）。

参数：
  KERNEL        - Kernel 实例
  REQUEST       - chat-request 实例
  EXTRA-FILTERS - 请求级 filter 列表（调用方私有，置于 kernel filters
                  之外层；Agent 的 memory-filter 走这里，kernel 零污染）

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
         (chain (build-phase-chain (append extra-filters (kernel-filters kernel))
                                   :chat terminal)))
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
;;; 上下文辅助
;;; ============================================================
;;; 工具调用循环（run-tool-loop）已下沉到 cl-agent.simpleagent
;;; （core/simpleagent/loop.lisp）—— Kernel 只负责单次 chat 与单次 tool。

(defun context-conversation-id (context)
  "从执行上下文中读取 conversation-id（memory filter 的会话键）。

CONTEXT 可以是 context 实例、plist 或 NIL。"
  (typecase context
    (context (context-get context :conversation-id))
    (list (getf context :conversation-id))
    (t nil)))

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
