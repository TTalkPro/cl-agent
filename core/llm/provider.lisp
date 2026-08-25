;;;; provider.lisp
;;;; CL-Agent Core LLM - ILLMProvider Protocol
;;;;
;;;; Overview:
;;;;   Defines the generic functions protocol for LLM providers.
;;;;   This is the interface that all LLM provider implementations
;;;;   must satisfy.
;;;;
;;;; Location:
;;;;   core/llm/provider.lisp - Protocol definitions in core to avoid
;;;;   circular dependencies between modules.
;;;;
;;;; Design:
;;;;   Following Common Lisp idioms, we use defgeneric to define
;;;;   the protocol. Provider implementations in cl-agent-llm
;;;;   will specialize these methods.

(in-package #:cl-agent/core)

;;; ============================================================
;;; Core LLM Protocol
;;; ============================================================

(defgeneric llm-chat (provider messages &key max-tokens temperature model tools system
                                             top-p top-k stop
                                             frequency-penalty presence-penalty
                                             tool-choice thinking extra-params)
  (:documentation "Send a chat request to an LLM.

所有可选参数遵循\"存在才发送\"（参照 clj-agent build-params）：
NIL 表示不下发该字段，避免误触发厂商默认值或 400。

Parameters:
  PROVIDER    - Provider instance (implements this generic function)
  MESSAGES    - List of message plists
  MAX-TOKENS  - Maximum tokens in response (optional)
  TEMPERATURE - Temperature parameter (optional)
  MODEL       - Model name (optional, uses provider default)
  TOOLS       - List of tool schemas (optional)
  SYSTEM      - System prompt (optional)
  TOP-P       - 核采样参数 (optional)
  TOP-K       - Top-K 采样（Anthropic 等支持的厂商）(optional)
  STOP        - 停止序列列表 (optional)
  FREQUENCY-PENALTY - 频率惩罚 (optional)
  PRESENCE-PENALTY  - 存在惩罚 (optional)
  TOOL-CHOICE - :auto / :required / :none 或厂商原生形态 (optional)
  THINKING    - 扩展思考配置（optional，对标 Spring AI ThinkingConfigParam）：
                :disabled / :adaptive / (:enabled :budget-tokens N)
                / (:adaptive :display :omitted) / hash-table（原样下发）。
                由 Anthropic 系 provider 实现，其它 provider 忽略。
                详见 chat-options 的 thinking 槽。
  EXTRA-PARAMS - 厂商专有参数逃生通道（plist，直接并入请求体，
                 对标 clj-agent 的 :extra-body）(optional)

Returns:
  Response plist:
    :content     - Text content
    :tool-calls  - Tool call list (if any)
    :usage       - Token usage plist (if available)
    :finish-reason - Reason for completion

Note:
  This generic function is defined in cl-agent/chat-client but
  specialized by LLM provider modules (cl-agent-llm).
  ChatClient uses this protocol to communicate with LLMs without
  knowing specific provider implementations."))

(defgeneric llm-chat-stream (provider messages callback
                             &key max-tokens temperature model tools system
                                  top-p top-k stop
                                  frequency-penalty presence-penalty
                                  tool-choice thinking extra-params)
  (:documentation "Send a streaming chat request to an LLM.

Parameters:
  PROVIDER    - Provider instance
  MESSAGES    - List of message plists
  CALLBACK    - Function (chunk) called for each chunk
  MAX-TOKENS  - Maximum tokens in response (optional)
  TEMPERATURE - Temperature parameter (optional)
  MODEL       - Model name (optional)
  TOOLS       - List of tool schemas (optional)
  SYSTEM      - System prompt (optional)

Returns:
  Final response plist (same as llm-chat)

Note:
  CALLBACK is called with each streaming chunk as a plist:
    :delta    - Content delta
    :done     - T when stream is complete"))

;;; ============================================================
;;; Provider Configuration Protocol
;;; ============================================================

(defgeneric provider-name (provider)
  (:documentation "Get the name of the provider.

Parameters:
  PROVIDER - Provider instance

Returns:
  Provider name string (e.g., \"anthropic\", \"openai\")"))

(defgeneric provider-model (provider)
  (:documentation "Get the default model of the provider.

Parameters:
  PROVIDER - Provider instance

Returns:
  Default model name string"))

(defgeneric provider-api-key (provider)
  (:documentation "Get the API key of the provider.

Parameters:
  PROVIDER - Provider instance

Returns:
  API key string"))

(defgeneric provider-base-url (provider)
  (:documentation "Get the base URL of the provider.

Parameters:
  PROVIDER - Provider instance

Returns:
  Base URL string"))

(defgeneric provider-supports-tools-p (provider)
  (:documentation "Check if the provider supports tool/function calling.

Parameters:
  PROVIDER - Provider instance

Returns:
  T if tools are supported, NIL otherwise"))

(defgeneric provider-supports-streaming-p (provider)
  (:documentation "Check if the provider supports streaming.

Parameters:
  PROVIDER - Provider instance

Returns:
  T if streaming is supported, NIL otherwise"))

;;; ============================================================
;;; Tool Schema Protocol
;;; ============================================================

(defgeneric provider-format-tools (provider tools)
  (:documentation "Format tool schemas for the provider's API.

Parameters:
  PROVIDER - Provider instance
  TOOLS    - List of tool schemas in generic format

Returns:
  Tool schemas formatted for the specific provider API.
  Different providers (OpenAI, Anthropic) have different formats."))

(defgeneric provider-parse-tool-calls (provider response)
  (:documentation "Parse tool calls from provider response.

Parameters:
  PROVIDER - Provider instance
  RESPONSE - Raw API response

Returns:
  List of normalized tool call plists:
    :id        - Tool call ID
    :name      - Function name
    :arguments - Arguments plist"))

;;; ============================================================
;;; Default Method Implementations
;;; ============================================================

(defmethod provider-supports-tools-p ((provider t))
  "Default: assume tools are not supported."
  nil)

(defmethod provider-supports-streaming-p ((provider t))
  "Default: assume streaming is not supported."
  nil)

(defmethod llm-chat-stream ((provider t) messages callback
                            &rest args
                            &key max-tokens temperature model tools system
                                 top-p top-k stop
                                 frequency-penalty presence-penalty
                                 tool-choice thinking extra-params)
  "Default streaming implementation: fall back to non-streaming."
  (declare (ignore callback max-tokens temperature model tools system
                   top-p top-k stop frequency-penalty presence-penalty
                   tool-choice thinking extra-params))
  (apply #'llm-chat provider messages args))

;;; ============================================================
;;; Provider Capability Checking
;;; ============================================================

(defun check-provider-tools-support (provider)
  "Check if provider supports tools, signal error if not.

Parameters:
  PROVIDER - Provider instance

Signals:
  Error if tools not supported"
  (unless (provider-supports-tools-p provider)
    (error "Provider ~A does not support tool calling"
           (provider-name provider))))

(defun check-provider-streaming-support (provider)
  "Check if provider supports streaming, signal error if not.

Parameters:
  PROVIDER - Provider instance

Signals:
  Error if streaming not supported"
  (unless (provider-supports-streaming-p provider)
    (error "Provider ~A does not support streaming"
           (provider-name provider))))

;;; ============================================================
;;; Provider Base Class
;;; ============================================================

(defclass base-llm-provider ()
  ((name
    :initarg :name
    :reader provider-name
    :documentation "Provider name")

   (api-key
    :initarg :api-key
    :accessor provider-api-key
    :documentation "API key for authentication")

   (base-url
    :initarg :base-url
    :accessor provider-base-url
    :documentation "Base URL for API requests")

   (model
    :initarg :model
    :accessor provider-model
    :documentation "Default model to use")

   (supports-tools
    :initarg :supports-tools
    :initform t
    :accessor provider-supports-tools-p
    :documentation "Whether provider supports tool calling")

   (supports-streaming
    :initarg :supports-streaming
    :initform t
    :accessor provider-supports-streaming-p
    :documentation "Whether provider supports streaming")

   (default-max-tokens
    :initarg :default-max-tokens
    :initform 4096
    :accessor provider-default-max-tokens
    :documentation "Default max tokens")

   (default-temperature
    :initarg :default-temperature
    :initform 0.7
    :accessor provider-default-temperature
    :documentation "Default temperature"))

  (:documentation "Base class for LLM providers.
Provides common slots and default method implementations."))

(defmethod print-object ((provider base-llm-provider) stream)
  "Print provider in a readable format."
  (print-unreadable-object (provider stream :type t :identity t)
    (format stream "~A ~A" (provider-name provider) (provider-model provider))))

;;; ============================================================
;;; Provider 层横切：调用观测
;;; ============================================================
;;; 计时、用量记账、请求日志这些东西每个 provider 都需要，但**不属于**
;;; provider——provider 只负责「底层信息 + 如何调用」。写在每个实现里的
;;; 结果是十几份副本各自漂移，且新增 provider 时必然有人忘记。
;;;
;;; 挂在 (t) 上的 :around 覆盖每一个 provider（含 mock 与测试用的桩），
;;; 无论它继承自哪个基类——llm 层的真实 provider 继承的是
;;; cl-agent/llm:base-provider 而非本文件的 base-llm-provider，
;;; 挂在后者上够不着它们。
;;;
;;; 与 ChatModel 层 observation-fn 的分工：
;;;   ChatModel 的钩子包住**一次逻辑调用**（含重试，记一条）；
;;;   这里的钩子包住**每一次真实 wire 调用**（重试三次就触发三次）。
;;;   要算钱看这里，要算延迟看那边。

(defvar *llm-call-observer* nil
  "Provider 调用观测钩子：(provider messages args thunk) → llm-response。

  - provider  provider 实例
  - messages  中立消息列表
  - args      本次调用的 SPI 关键字参数 plist（:model / :tools / …）
  - thunk     执行真实调用，返回 llm-response

  NIL（缺省）= 不观测，零开销。用 let 绑定即对**所有** provider 生效：

    (let ((*llm-call-observer*
            (lambda (provider messages args thunk)
              (declare (ignore messages args))
              (let ((start (get-internal-real-time)))
                (prog1 (funcall thunk)
                  (log-info \"~A 耗时 ~Dms\" (provider-name provider)
                            (round (- (get-internal-real-time) start)
                                   (/ internal-time-units-per-second 1000))))))))
      ...)

  它是动态变量而非 provider 的槽，因为观测通常是**调用点**的关注
  （这一段业务要记账），而不是 provider 实例的固有属性。")

(defvar *llm-stream-observer* nil
  "流式调用的观测钩子，签名同 *llm-call-observer*，包住 llm-chat-stream。")

(defmethod llm-chat :around ((provider t) messages
                             &rest args &key &allow-other-keys)
  "施加 *llm-call-observer*。无钩子时直接下沉（一次 NIL 检查）。"
  (if *llm-call-observer*
      (funcall *llm-call-observer* provider messages args
               (lambda () (call-next-method)))
      (call-next-method)))

(defmethod llm-chat-stream :around ((provider t) messages callback
                                    &rest args &key &allow-other-keys)
  "施加 *llm-stream-observer*。"
  (declare (ignore callback))
  (if *llm-stream-observer*
      (funcall *llm-stream-observer* provider messages args
               (lambda () (call-next-method)))
      (call-next-method)))

;;; ------------------------------------------------------------
;;; 开箱即用：用量累计
;;; ------------------------------------------------------------

(defclass llm-usage-tally ()
  ((calls
    :initform 0
    :accessor usage-tally-calls
    :documentation "真实 wire 调用次数（重试三次算三次）")
   (input-tokens
    :initform 0
    :accessor usage-tally-input-tokens)
   (output-tokens
    :initform 0
    :accessor usage-tally-output-tokens)
   (lock
    :initform (bt:make-lock "llm-usage-tally")
    :reader usage-tally-lock
    :documentation "并行批执行时多个线程会同时记账"))
  (:documentation "跨调用的 token 用量累计。"))

(defun make-llm-usage-tally ()
  (make-instance 'llm-usage-tally))

(definvariants llm-usage-tally (self)
  ;; 三个计数槽都有 :initform 0，这里只钉住「不能被造成负数起点」——
  ;; 累计器从负数开始，最后报出来的账单就是错的，且没有任何报错。
  (require-that self (and (>= (usage-tally-calls self) 0)
                          (>= (usage-tally-input-tokens self) 0)
                          (>= (usage-tally-output-tokens self) 0))
                "计数起点不能为负"))

(defmethod print-object ((tally llm-usage-tally) stream)
  (print-unreadable-object (tally stream :type t)
    (format stream "~A calls, ~A in / ~A out"
            (usage-tally-calls tally)
            (usage-tally-input-tokens tally)
            (usage-tally-output-tokens tally))))

(defun usage-tally-observer (tally)
  "构造一个把用量记进 TALLY 的 *llm-call-observer*。

    (let* ((tally (make-llm-usage-tally))
           (*llm-call-observer* (usage-tally-observer tally)))
      (chat-model-call model \"...\")
      (usage-tally-output-tokens tally))"
  (lambda (provider messages args thunk)
    (declare (ignore provider messages args))
    (let ((response (funcall thunk)))
      (bt:with-lock-held ((usage-tally-lock tally))
        (incf (usage-tally-calls tally))
        (let ((usage (and (llm-response-p response)
                          (llm-response-usage response))))
          (when usage
            (incf (usage-tally-input-tokens tally)
                  (or (llm-usage-input-tokens usage) 0))
            (incf (usage-tally-output-tokens tally)
                  (or (llm-usage-output-tokens usage) 0)))))
      response)))
