;;;; kernel-agent.lisp
;;;; CL-Agent SimpleAgent - Kernel Agent
;;;;
;;;; Overview:
;;;;   Simple chat agent built on top of Kernel.
;;;;   Provides a stateful chat interface with history management,
;;;;   a CLOS callback registry and optional ChatMemory integration.
;;;;
;;;; Usage:
;;;;   ;; 普通用法（本地历史）
;;;;   (let ((agent (make-kernel-agent kernel :system-prompt "You are helpful.")))
;;;;     (agent-chat agent "Hello!"))
;;;;
;;;;   ;; ChatMemory：历史由 memory-filter 按 conversation-id 自管
;;;;   (let ((agent (make-kernel-agent kernel
;;;;                  :memory (cl-agent.kernel:make-in-memory-chat-store))))
;;;;     (agent-chat agent "Hello!"))
;;;;
;;;;   ;; 回调：多回调、优先级、错误隔离
;;;;   (register-callback (agent-callbacks agent) :on-tool-call
;;;;                      (lambda (name args) ...) :name :audit)

(in-package #:cl-agent.simpleagent)

;;; ============================================================
;;; Kernel Agent Class
;;; ============================================================

(defclass kernel-agent (base-agent)
  ((kernel
    :initarg :kernel
    :reader agent-kernel
    :documentation "The Kernel instance for tool execution")

   (context
    :initarg :context
    :accessor agent-context
    :documentation "Execution context")

   (history
    :initform nil
    :accessor agent-history
    :documentation "Conversation history (local delta log, newest first)")

   (system-prompt
    :initarg :system-prompt
    :initform nil
    :accessor agent-system-prompt
    :documentation "System prompt for the agent")

   (settings
    :initarg :settings
    :initform nil
    :accessor agent-settings
    :documentation "Agent settings plist")

   (callbacks
    :initarg :callbacks
    :initform nil
    :accessor agent-callbacks
    :documentation "callback-registry 实例（构造时可传旧式 plist，自动转换）")

   (memory
    :initarg :memory
    :initform nil
    :reader agent-memory
    :documentation "ChatMemory store（可选；设置后历史由 memory-filter 自管）")

   (conversation-id
    :initarg :conversation-id
    :initform nil
    :accessor agent-conversation-id
    :documentation "会话 ID（memory 模式下的存取键，默认为 agent-id）"))

  (:documentation "Simple chat agent using Kernel for tool execution."))

(defmethod initialize-instance :after ((agent kernel-agent) &key)
  ;; 旧式回调 plist → callback-registry（向后兼容）
  (let ((callbacks (agent-callbacks agent)))
    (unless (callback-registry-p callbacks)
      (setf (agent-callbacks agent)
            (make-callback-registry callbacks))))
  ;; memory 模式：默认 conversation-id = agent-id
  (when (and (agent-memory agent)
             (null (agent-conversation-id agent)))
    (setf (agent-conversation-id agent) (agent-id agent))))

;;; ============================================================
;;; Constructor
;;; ============================================================

(defun make-kernel-agent (kernel &key name system-prompt settings callbacks
                                      memory conversation-id)
  "Create a Kernel Agent.

Parameters:
  KERNEL          - Kernel instance
  NAME            - Agent name (optional)
  SYSTEM-PROMPT   - System prompt (optional)
  SETTINGS        - Settings plist (optional)
  CALLBACKS       - 回调 plist 或 callback-registry (optional)
  MEMORY          - ChatMemory store (optional)；设置后会向 kernel
                    注册 memory-filter，对话历史由 store 自管
  CONVERSATION-ID - 会话 ID（可选，默认 agent-id）

Returns:
  New kernel-agent instance"
  (let ((agent (make-instance 'kernel-agent
                              :kernel kernel
                              :name (or name "kernel-agent")
                              :system-prompt system-prompt
                              :settings (merge-settings (default-agent-settings) settings)
                              :callbacks callbacks
                              :memory memory
                              :conversation-id conversation-id
                              :context (make-context))))
    ;; memory 模式：挂载 memory-filter，conversation-id 写入 context
    (when memory
      (kernel-add-filter kernel (cl-agent.kernel:make-memory-filter memory))
      (context-set (agent-context agent) :conversation-id
                   (agent-conversation-id agent)))
    ;; Add system message to history if provided
    (when system-prompt
      (push (list :role :system :content system-prompt)
            (agent-history agent)))
    agent))

;;; ============================================================
;;; Callback 触发辅助
;;; ============================================================

(defun agent-fire (agent event &rest args)
  "触发 agent 的事件回调（错误隔离由 registry 保证）"
  (apply #'fire-callbacks (agent-callbacks agent) event args))

;;; ============================================================
;;; Chat API
;;; ============================================================

(defun agent-chat (agent user-message &key settings)
  "Send a message and get a response.

事件流：:on-message → (:on-tool-call/:on-tool-result)* → :on-response；
出错时触发 :on-error 后重新抛出。

Parameters:
  AGENT        - Kernel agent
  USER-MESSAGE - User message string
  SETTINGS     - Override settings (optional)

Returns:
  Response text string"
  (let* ((kernel (agent-kernel agent))
         (merged-settings (merge-settings (agent-settings agent) settings))
         (memory-p (and (agent-memory agent) t)))
    ;; 事件：用户消息
    (agent-fire agent :on-message user-message)

    ;; Add user message to local history
    (push (list :role :user :content user-message)
          (agent-history agent))
    (context-add-message (agent-context agent)
                         (list :role :user :content user-message))

    (handler-bind
        ((error (lambda (condition)
                  (agent-fire agent :on-error condition))))
      ;; memory 模式只传 delta（历史由 memory-filter 从 store 展开）；
      ;; 否则传完整本地历史
      (let* ((messages (if memory-p
                           (list (list :role :user :content user-message))
                           (reverse (agent-history agent))))
             (result (invoke-kernel
                      kernel messages
                      :settings (list* :system-prompt (agent-system-prompt agent)
                                       :on-tool-call (lambda (name args)
                                                       (agent-fire agent :on-tool-call name args))
                                       :on-tool-result (lambda (name result)
                                                         (agent-fire agent :on-tool-result name result))
                                       merged-settings)
                      :context (agent-context agent))))
        ;; Update local history with assistant response
        (let ((response-text (getf result :text)))
          (push (list :role :assistant :content response-text)
                (agent-history agent))
          (context-add-message (agent-context agent)
                               (list :role :assistant :content response-text))

          ;; 事件：最终响应
          (agent-fire agent :on-response response-text)

          ;; 全局事件总线（保留）
          (fire-agent-event
           (make-agent-event-of-type :response agent
                                     :text response-text
                                     :tool-calls (getf result :tool-calls-made)))

          response-text)))))

(defun agent-chat-stream (agent user-message callback &key settings)
  "Send a message and stream the response.

每个流式块同时触发 CALLBACK 与 :on-chunk 事件。

Parameters:
  AGENT        - Kernel agent
  USER-MESSAGE - User message string
  CALLBACK     - Function (chunk) called for each chunk
  SETTINGS     - Override settings (optional)

Returns:
  Final response text"
  (let* ((kernel (agent-kernel agent))
         (merged-settings (merge-settings (agent-settings agent) settings))
         (memory (agent-memory agent))
         (cid (agent-conversation-id agent)))
    (agent-fire agent :on-message user-message)

    ;; Add user message to local history
    (push (list :role :user :content user-message)
          (agent-history agent))
    ;; memory 模式：流式不经过 chat 链，手动落库 + 取完整历史
    (when memory
      (cl-agent.kernel:mem-add memory cid
                               (list (list :role :user :content user-message))))

    (handler-bind
        ((error (lambda (condition)
                  (agent-fire agent :on-error condition))))
      (let* ((messages (if memory
                           (cl-agent.kernel:mem-get memory cid)
                           (reverse (agent-history agent))))
             (wrapped-callback (lambda (chunk)
                                 (agent-fire agent :on-chunk chunk)
                                 (funcall callback chunk)))
             (response (invoke-chat-stream kernel messages wrapped-callback
                                           :settings (list* :system-prompt (agent-system-prompt agent)
                                                            merged-settings)
                                           :context (agent-context agent))))
        ;; Update history
        (let ((response-text (cl-agent.core:llm-response-content response)))
          (push (list :role :assistant :content response-text)
                (agent-history agent))
          (when memory
            (cl-agent.kernel:mem-add memory cid
                                     (list (list :role :assistant :content response-text))))
          (agent-fire agent :on-response response-text)
          response-text)))))

;;; ============================================================
;;; History Management
;;; ============================================================

(defun agent-reset (agent &key keep-system-prompt)
  "Reset agent state（memory 模式下同时清空 store 中的会话）.

Parameters:
  AGENT             - Kernel agent
  KEEP-SYSTEM-PROMPT - Keep system prompt in history

Returns:
  The agent"
  (if (and keep-system-prompt (agent-system-prompt agent))
      (setf (agent-history agent)
            (list (list :role :system :content (agent-system-prompt agent))))
      (setf (agent-history agent) nil))
  ;; 清空 ChatMemory 中的会话
  (when (agent-memory agent)
    (cl-agent.kernel:mem-clear (agent-memory agent)
                               (agent-conversation-id agent)))
  (setf (agent-context agent) (make-context))
  (when (agent-memory agent)
    (context-set (agent-context agent) :conversation-id
                 (agent-conversation-id agent)))
  agent)

(defun agent-get-history (agent &key (include-system nil))
  "Get conversation history.

memory 模式下返回 store 中的完整历史（含工具消息）；
否则返回本地历史。

Parameters:
  AGENT          - Kernel agent
  INCLUDE-SYSTEM - Include system messages

Returns:
  History list (oldest first)"
  (let ((history (if (agent-memory agent)
                     (cl-agent.kernel:mem-get (agent-memory agent)
                                              (agent-conversation-id agent))
                     (reverse (agent-history agent)))))
    (if include-system
        history
        (remove-if (lambda (msg) (eq (getf msg :role) :system))
                   history))))

(defun agent-set-system-prompt (agent prompt)
  "Set or update system prompt.

Parameters:
  AGENT  - Kernel agent
  PROMPT - New system prompt

Returns:
  The agent"
  (setf (agent-system-prompt agent) prompt)
  ;; Update history
  (let ((history (agent-history agent)))
    (if (and history (eq (getf (car (last history)) :role) :system))
        (setf (getf (car (last history)) :content) prompt)
        (setf (agent-history agent)
              (append history (list (list :role :system :content prompt))))))
  agent)

;;; ============================================================
;;; Callback Helpers（同名替换语义，向后兼容旧 setter 风格）
;;; ============================================================

(defun agent-on-message (agent callback)
  "Set callback for user messages.

Parameters:
  AGENT    - Kernel agent
  CALLBACK - Function (message)"
  (register-callback (agent-callbacks agent) :on-message callback))

(defun agent-on-tool-call (agent callback)
  "Set callback for tool calls.

Parameters:
  AGENT    - Kernel agent
  CALLBACK - Function (name args)"
  (register-callback (agent-callbacks agent) :on-tool-call callback))

(defun agent-on-tool-result (agent callback)
  "Set callback for tool results.

Parameters:
  AGENT    - Kernel agent
  CALLBACK - Function (name result)"
  (register-callback (agent-callbacks agent) :on-tool-result callback))

(defun agent-on-response (agent callback)
  "Set callback for responses.

Parameters:
  AGENT    - Kernel agent
  CALLBACK - Function (response-text)"
  (register-callback (agent-callbacks agent) :on-response callback))

(defun agent-on-error (agent callback)
  "Set callback for errors.

Parameters:
  AGENT    - Kernel agent
  CALLBACK - Function (condition)"
  (register-callback (agent-callbacks agent) :on-error callback))

(defun agent-on-chunk (agent callback)
  "Set callback for streaming chunks.

Parameters:
  AGENT    - Kernel agent
  CALLBACK - Function (chunk)"
  (register-callback (agent-callbacks agent) :on-chunk callback))

(defun agent-remove-callback (agent event &optional (name :default))
  "移除指定事件的回调。

Parameters:
  AGENT - Kernel agent
  EVENT - 事件关键字
  NAME  - 回调标识（默认 :default）"
  (unregister-callback (agent-callbacks agent) event name))

;;; ============================================================
;;; Convenience Methods
;;; ============================================================

(defmethod agent-p ((agent kernel-agent))
  "Kernel agents are agents."
  t)

(defun agent-add-plugin (agent plugin-sym)
  "Add a plugin to the agent's kernel.

Parameters:
  AGENT      - Kernel agent
  PLUGIN-SYM - Plugin symbol"
  (kernel-add-plugin (agent-kernel agent) plugin-sym))

(defun agent-add-filter (agent filter)
  "Add a filter to the agent's kernel.

Parameters:
  AGENT  - Kernel agent
  FILTER - Filter instance, function or plist"
  (kernel-add-filter (agent-kernel agent) filter))
