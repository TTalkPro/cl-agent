;;;; chat-client.lisp
;;;; CL-Agent Client - ChatClient
;;;;
;;;; 概述（对标 Spring AI ChatClient fluent API）：
;;;;
;;;;   Java:
;;;;     ChatClient client = ChatClient.builder(chatModel)
;;;;         .defaultSystem("你是一个助手")
;;;;         .defaultAdvisors(new MessageChatMemoryAdvisor(memory))
;;;;         .build();
;;;;     String answer = client.prompt().user("你好").call().content();
;;;;
;;;;   Lisp（函数管道，配合 cl-agent.core:-> 线程宏）:
;;;;     (defvar *client*
;;;;       (-> (chat-client-builder model)
;;;;           (default-system "你是一个助手")
;;;;           (default-advisors (make-message-chat-memory-advisor :memory mem))
;;;;           (build-client)))
;;;;     (-> (client-prompt *client*)
;;;;         (prompt-user "你好")
;;;;         (call-content))
;;;;
;;;;   Lisp（chat 宏 DSL，声明式）:
;;;;     (chat *client*
;;;;       (:system "你是一个天气助手")
;;;;       (:user "~A的天气怎么样？" city)
;;;;       (:tools 'get-weather)
;;;;       (:conversation "conv-1"))
;;;;     ;; 缺省返回文本，(:call :response) 返回 chat-response
;;;;
;;;; 执行流程：
;;;;   请求 spec → prompt + context → client-request
;;;;   → Advisor 洋葱链（默认 + 请求级，按 order 排序）
;;;;   → 终端调 chat-model-call（内部完成工具执行循环）
;;;;   → client-response

(in-package #:cl-agent.client)

;;; ============================================================
;;; ChatClient 与 Builder
;;; ============================================================

(defclass chat-client ()
  ((model
    :initarg :model
    :reader chat-client-model
    :documentation "chat-model 实例")
   (default-system-text
    :initarg :default-system-text
    :initform nil
    :reader client-default-system
    :documentation "默认系统提示")
   (default-options
    :initarg :default-options
    :initform nil
    :reader client-default-options
    :documentation "默认 chat-options")
   (default-advisors
    :initarg :default-advisors
    :initform nil
    :reader client-default-advisors
    :documentation "默认 Advisor 列表（legacy advisor 路径；kernel 路径用 :filters）")
   (default-tools
    :initarg :default-tools
    :initform nil
    :reader client-default-tools
    :documentation "默认工具引用列表（callback/符号/字符串）")
   (auto-tool-advisor
    :initarg :auto-tool-advisor
    :initform t
    :reader client-auto-tool-advisor-p
    :documentation "是否自动注册 tool-calling-advisor（默认 T；
NIL 进入 user-controlled 工具执行模式")
   ;; P5: kernel-backed 路径
   (kernel
    :initarg :kernel
    :initform nil
    :reader client-kernel
    :documentation "kernel 实例（非 nil 时使用 kernel+filter 执行路径；
nil 时走 legacy advisor 链"))
  (:documentation "面向应用的聊天客户端（对标 ChatClient）"))

(defclass chat-client-builder ()
  ((model :initarg :model :accessor builder-model)
   (system-text :initform nil :accessor builder-system-text)
   (options :initform nil :accessor builder-options)
   (advisors :initform nil :accessor builder-advisors)
   (tools :initform nil :accessor builder-tools))
  (:documentation "ChatClient 构建器（对标 ChatClient.Builder）"))

(defun chat-client-builder (model)
  "创建 ChatClient 构建器（对标 ChatClient.builder(chatModel)）"
  (make-instance 'chat-client-builder :model model))

(defun default-system (builder text)
  "设置默认系统提示（对标 defaultSystem）。返回 builder。"
  (setf (builder-system-text builder) text)
  builder)

(defun default-options (builder options)
  "设置默认 chat-options（对标 defaultOptions）。返回 builder。"
  (setf (builder-options builder) options)
  builder)

(defun default-advisors (builder &rest advisors)
  "追加默认 Advisor（对标 defaultAdvisors）。返回 builder。"
  (setf (builder-advisors builder)
        (append (builder-advisors builder) advisors))
  builder)

(defun default-tools (builder &rest tools)
  "追加默认工具（对标 defaultToolCallbacks/defaultToolNames）。
接受 tool-callback / deftool 符号 / 名称字符串。返回 builder。"
  (setf (builder-tools builder)
        (append (builder-tools builder) tools))
  builder)

(defun build-client (builder)
  "构建 chat-client（对标 build()）"
  (make-instance 'chat-client
                 :model (builder-model builder)
                 :default-system-text (builder-system-text builder)
                 :default-options (builder-options builder)
                 :default-advisors (builder-advisors builder)
                 :default-tools (builder-tools builder)))

(defun make-chat-client (model &key system options advisors tools
                                     (auto-tool-advisor t) kernel)
  "一步创建 chat-client（对标 ChatClient.create(chatModel) 及常用默认值）。

  KERNEL 非空时使用 kernel+filter 执行路径（推荐，P5+）：
  此时 ADVISORS 被忽略，KERNEL 应已配置好 filters/tools。

  KERNEL 为空时走 legacy advisor 链（P4 及之前的行为）。

  AUTO-TOOL-ADVISOR 为 NIL 时不自动注册 tool-calling-advisor。

示例：
  ;; Legacy advisor 路径
  (make-chat-client model :system \"...\" :advisors (list ...))

  ;; Kernel+filter 路径（推荐）
  (make-chat-client model :kernel
    (cl-agent.kernel:build-kernel
      :model model
      :filters (list (cl-agent.kernel:memory-filter mem))
      :tools '(get-weather)))"
  (make-instance 'chat-client
                 :model model
                 :default-system-text system
                 :default-options options
                 :default-advisors advisors
                 :default-tools tools
                 :auto-tool-advisor auto-tool-advisor
                 :kernel kernel))

(defun make-kernel-client (model &key filters tools settings)
  "创建 kernel-backed ChatClient（推荐的新路径）。

  等价于：
  (make-chat-client model :kernel (build-kernel :model model
                                                 :filters filters
                                                 :tools tools
                                                 :settings settings))

  使用 kernel+filter 三链架构（对标 clj-agent），不再走 advisor 链。"
  (let ((kernel (cl-agent.kernel:build-kernel
                 :model model
                 :filters filters
                 :tools tools
                 :settings settings)))
    (make-instance 'chat-client
                   :model model
                   :kernel kernel
                   :default-tools tools)))

(defmethod print-object ((client chat-client) stream)
  (print-unreadable-object (client stream :type t)
    (format stream "~A~@[ advisors=~A~]~@[ tools=~A~]"
            (type-of (chat-client-model client))
            (let ((n (length (client-default-advisors client))))
              (when (plusp n) n))
            (let ((n (length (client-default-tools client))))
              (when (plusp n) n)))))

;;; ============================================================
;;; 请求 Spec（fluent API，对标 ChatClientRequestSpec）
;;; ============================================================

(defclass chat-request-spec ()
  ((client :initarg :client :reader spec-client)
   (system-text :initform nil :accessor spec-system-text)
   (user-text :initform nil :accessor spec-user-text)
   (messages :initform nil :accessor spec-messages)
   (options :initform nil :accessor spec-options)
   (advisors :initform nil :accessor spec-advisors)
   (tools :initform nil :accessor spec-tools)
   (context :initform nil :accessor spec-context
            :documentation "context 初始键值 plist"))
  (:documentation "单次请求的可变构建载体（对标 ChatClientRequestSpec）"))

(defun client-prompt (client &optional user-text)
  "开始构建一次请求（对标 client.prompt() / client.prompt(userText)）"
  (let ((spec (make-instance 'chat-request-spec :client client)))
    (when user-text
      (setf (spec-user-text spec) user-text))
    spec))

(defun prompt-system (spec text &rest format-args)
  "设置本次请求的系统提示（覆盖客户端默认值）。
TEXT 可带 format 控制串。返回 spec。"
  (setf (spec-system-text spec)
        (if format-args (apply #'format nil text format-args) text))
  spec)

(defun prompt-user (spec text &rest format-args)
  "设置用户输入。TEXT 可带 format 控制串。返回 spec。

示例：(prompt-user spec \"~A 的天气怎么样？\" \"东京\")"
  (setf (spec-user-text spec)
        (if format-args (apply #'format nil text format-args) text))
  spec)

(defun prompt-add-messages (spec &rest messages)
  "追加任意消息（message 实例）。返回 spec。"
  (setf (spec-messages spec) (append (spec-messages spec) messages))
  spec)

(defun prompt-with-options (spec &rest options-or-kv)
  "设置本次请求的 chat-options。
接受一个 chat-options 实例，或关键字参数（自动构造）。返回 spec。

示例：
  (prompt-with-options spec :temperature 0.2 :max-tokens 512)"
  (setf (spec-options spec)
        (if (and (= (length options-or-kv) 1)
                 (typep (first options-or-kv) 'chat-options))
            (first options-or-kv)
            (apply #'make-chat-options options-or-kv)))
  spec)

(defun prompt-advisors (spec &rest advisors)
  "追加请求级 Advisor（对标 advisors(...)）。返回 spec。"
  (setf (spec-advisors spec) (append (spec-advisors spec) advisors))
  spec)

(defun prompt-tools (spec &rest tools)
  "追加请求级工具（对标 toolCallbacks/toolNames）。返回 spec。"
  (setf (spec-tools spec) (append (spec-tools spec) tools))
  spec)

(defun prompt-context (spec key value)
  "写入 Advisor 上下文初始值。返回 spec。"
  (setf (spec-context spec)
        (append (spec-context spec) (list key value)))
  spec)

(defun prompt-conversation (spec conversation-id)
  "设置会话 ID（记忆类 Advisor 的会话键）。返回 spec。"
  (prompt-context spec :conversation-id conversation-id))

;;; ============================================================
;;; Spec → 执行
;;; ============================================================

(defun spec-build-prompt (spec)
  "把 spec 物化为 prompt：默认值与请求级设置合并"
  (let* ((client (spec-client spec))
         (system-text (or (spec-system-text spec)
                          (client-default-system client)))
         (tools (append (spec-tools spec) (client-default-tools client)))
         (options (merge-chat-options (spec-options spec)
                                      (client-default-options client)))
         ;; 工具并入选项（resolve 延迟到 ChatModel 层）
         (options (if tools
                      (merge-chat-options
                       (make-chat-options
                        :tool-callbacks (resolve-tool-callbacks tools))
                       options)
                      options))
         (messages (append
                    (when system-text (list (system-message system-text)))
                    (spec-messages spec)
                    (when (spec-user-text spec)
                      (list (user-message (spec-user-text spec)))))))
    (unless (remove-if #'system-message-p messages)
      (error "请求缺少用户输入：请用 prompt-user / (:user ...) 提供"))
    (make-prompt messages :options options)))

(defun spec-build-request (spec)
  "把 spec 物化为 client-request"
  (let ((request (make-client-request (spec-build-prompt spec))))
    (loop for (key value) on (spec-context spec) by #'cddr
          do (context-set request key value))
    request))

;;; ============================================================
;;; Spec → 执行
;;; ============================================================

(defun call-client-response (spec)
  "执行请求，返回 client-response（通过 kernel+filter 路径）"
  (let* ((client (spec-client spec))
         (kernel (or (client-kernel client)
                     ;; 无 kernel 时即时创建（无 filter/tool 的裸 kernel）
                     (let ((k (cl-agent.kernel:build-kernel
                               :model (chat-client-model client)
                               :tools (append (spec-tools spec)
                                              (client-default-tools client)))))
                       (setf (slot-value client 'kernel) k)
                       k)))
         (prompt (spec-build-prompt spec))
         (messages (prompt-messages prompt))
         (ctx nil))
    ;; 从 spec context 构建 plist
    (loop for (key value) on (spec-context spec) by #'cddr
          do (setf (getf ctx key) value))
    ;; 添加 conversation-id 从 prompt options
    (let* ((options (prompt-options prompt))
           (tool-ctx (chat-options-tool-context options)))
      (when tool-ctx
        (loop for (k v) on tool-ctx by #'cddr
              do (setf (getf ctx k) v)))
      ;; 把调用方 options 存入 context，供 run-tool-loop 合并到每次调用
      (when options
        (setf (getf ctx :caller-options) options)))
    ;; 调用 invoke-turn
    (let* ((turn-req (cl-agent.kernel:make-turn-request
                      messages :context ctx))
           (result (cl-agent.kernel:invoke-turn kernel turn-req)))
      (make-client-response
       (or (cl-agent.kernel:turn-result-response result)
           (make-chat-response
            (make-generation
             (assistant-message "（无响应）") :finish-reason :stop)))
       :context (make-hash-table :test #'equal)))))

(defun call-response (spec)
  "执行请求，返回 chat-response（对标 call().chatResponse()）"
  (client-response-chat-response (call-client-response spec)))

(defun call-content (spec)
  "执行请求，返回文本内容（对标 call().content()）"
  (chat-response-text (call-response spec)))

(defun call-entity (spec &key schema (max-repeat-attempts 3))
  "执行请求并把响应内容解析为结构化对象（对标 call().entity(...)）。

  参数：
  - SCHEMA              - JSON Schema（可选，给出时仅解析不校验——
                          校验请通过 kernel 的 validation-turn-filter 实现）
  - MAX-REPEAT-ATTEMPTS - 保留参数（advisor 退役后不再用于自动校验重试）

  不传 SCHEMA 时行为与既往一致：只解析。"
  (declare (ignore max-repeat-attempts))
  (prompt-add-messages
   spec
   (system-message "请只输出 JSON，不要任何多余说明或 markdown 代码围栏。"))
  (let* ((text (call-content spec))
         (clean (strip-json-fences text)))
    (json-parse clean)))

(defun strip-json-fences (text)
  "剥离 markdown 代码围栏（```json ... ```）。安全处理短字符串。"
  (let ((trimmed (string-trim '(#\Space #\Tab #\Newline #\Return) text)))
    (cond
      ;; 匹配 ```json ... ``` 围栏
       ((and (>= (length trimmed) 7)
             (string= trimmed "```json" :end1 7))
        (let* ((rest (subseq trimmed 7))
               (rest (string-trim '(#\Space #\Tab #\Newline #\Return) rest)))
          ;; 去掉尾部 ```
          (if (and (>= (length rest) 3)
                   (string= rest "```" :start1 (- (length rest) 3)))
              (subseq rest 0 (- (length rest) 3))
              rest)))
      ;; 匹配 ``` ... ``` 围栏（无 json 前缀）
       ((and (>= (length trimmed) 3)
             (string= trimmed "```" :end1 3))
        (let* ((rest (subseq trimmed 3))
               (rest (string-trim '(#\Space #\Tab #\Newline #\Return) rest)))
          (if (and (>= (length rest) 3)
                   (string= rest "```" :start1 (- (length rest) 3)))
              (subseq rest 0 (- (length rest) 3))
              rest)))
       (t trimmed))))

(defun stream-content (spec on-chunk)
  "流式执行请求：每个文本增量回调 (on-chunk delta)。
返回最终 chat-response（对标 stream().content()）。

  注意：当前实现降级为同步调用（完整文本作为单个 chunk 回调）。
  完整流式支持需要 kernel 的 invoke-chat-stream（未来实现）。"
  (let ((response (call-response spec)))
    (funcall on-chunk (chat-response-text response))
    response))

;;; ============================================================
;;; chat 宏 —— 声明式请求 DSL
;;; ============================================================

(defmacro chat (client &body clauses)
  "声明式聊天请求 DSL（对标 client.prompt()...call().content() 链）。

语法：
  (chat client
    [(:system 文本 [format 参数...])]
    [(:user 文本 [format 参数...])]
    [(:messages 消息...)]
    [(:options :temperature 0.7 ...)]
    [(:advisors advisor...)]
    [(:tools 工具...)]
    [(:context 键 值)]
    [(:conversation 会话ID)]
    [(:call :content | :response | :client-response | :entity [schema])]
    [(:stream 回调)])

(:call :entity schema) 会自动挂载 structured-output-validation-advisor：
响应不符合 schema 时带着校验错误让模型重试（默认最多 3 次）。

简写：(chat client \"你好\") ≡ (chat client (:user \"你好\"))

缺省终结操作为 (:call :content)，返回回复文本。

示例：
  (chat *client*
    (:system \"你是一个天气助手\")
    (:user \"~A 的天气怎么样？\" city)
    (:tools 'get-weather)
    (:conversation \"conv-1\"))"
  (let ((spec-var (gensym "SPEC"))
        (terminal '(:call :content))
        (setters nil))
    (dolist (clause clauses)
      (if (stringp clause)
          (push `(prompt-user ,spec-var ,clause) setters)
          (ecase (first clause)
            (:system (push `(prompt-system ,spec-var ,@(rest clause)) setters))
            (:user (push `(prompt-user ,spec-var ,@(rest clause)) setters))
            (:messages (push `(prompt-add-messages ,spec-var ,@(rest clause)) setters))
            (:options (push `(prompt-with-options ,spec-var ,@(rest clause)) setters))
            (:advisors (warn ":advisors clause is deprecated; use kernel filters instead"))
            (:tools (push `(prompt-tools ,spec-var ,@(rest clause)) setters))
            (:context (push `(prompt-context ,spec-var ,@(rest clause)) setters))
            (:conversation (push `(prompt-conversation ,spec-var ,@(rest clause)) setters))
            ((:call :stream) (setf terminal clause)))))
    `(let ((,spec-var (client-prompt ,client)))
       ,@(nreverse setters)
       ,(ecase (first terminal)
          (:call (ecase (second terminal)
                   (:content `(call-content ,spec-var))
                   (:response `(call-response ,spec-var))
                   (:client-response `(call-client-response ,spec-var))
                   (:entity (if (cddr terminal)
                                `(call-entity ,spec-var
                                              :schema ,(third terminal)
                                              ,@(cdddr terminal))
                                `(call-entity ,spec-var)))))
          (:stream `(stream-content ,spec-var ,(second terminal)))))))
