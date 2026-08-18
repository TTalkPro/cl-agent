;;;; registry.lisp
;;;; CL-Agent LLM - Provider Registry
;;;;
;;;; Overview:
;;;;   Central registry for LLM providers.
;;;;   Allows registration and lookup of provider factories.

(in-package #:cl-agent.llm)

;;; ============================================================
;;; Provider Registry
;;; ============================================================

(defvar *provider-registry* (make-hash-table :test 'eq)
  "Registry mapping provider keywords to factory functions.")

(defun register-provider (name factory-fn)
  "Register a provider factory.

Parameters:
  NAME       - Provider name keyword (e.g., :anthropic, :openai)
  FACTORY-FN - Factory function (lambda (&key ...) -> provider)

Returns:
  NAME"
  (setf (gethash name *provider-registry*) factory-fn)
  name)

(defun get-provider-factory (name)
  "Get a provider factory by name.

Parameters:
  NAME - Provider name keyword

Returns:
  Factory function, or NIL if not found"
  (gethash name *provider-registry*))

(defun unregister-provider (name)
  "Unregister a provider factory（对标 clj-agent registry/unregister-provider!）.

Parameters:
  NAME - Provider name keyword

Returns:
  T if a registration was removed, NIL otherwise"
  (remhash name *provider-registry*))

(defun list-providers ()
  "List all registered provider names.

Returns:
  List of provider name keywords"
  (loop for name being the hash-keys of *provider-registry*
        collect name))

(defun provider-registered-p (name)
  "Check if a provider is registered.

Parameters:
  NAME - Provider name keyword

Returns:
  T if registered, NIL otherwise"
  (not (null (gethash name *provider-registry*))))

;;; ============================================================
;;; Built-in Provider Registration
;;; ============================================================
;;;
;;; 一张表，不是十几段复制粘贴的 register-provider——同一个事实
;;; （provider 关键字 ↔ 工厂函数）只写一遍。新增内置 provider 只需
;;; 在表里加一行；忘记加时 make-provider / create-chat-model 一并失效，
;;; 不会出现「注册了但工厂名写错」这种半可用状态。
;;;
;;; 注：表里存的是工厂函数的**符号**而非 #'函数对象。apply 接受函数
;;; 名符号，于是调用时才解析——provider 文件单独重新编译后，注册表
;;; 自动指向新定义，不必重新加载 registry。

(defparameter +builtin-provider-factories+
  '(;; —— Anthropic 格式 ——
    (:anthropic   . cl-agent.llm.providers:make-anthropic-provider)
    (:minimax     . cl-agent.llm.providers:make-minimax-provider)

    ;; —— OpenAI 兼容 ——
    (:openai      . cl-agent.llm.providers:make-openai-provider)
    (:zhipu       . cl-agent.llm.providers:make-zhipu-provider)
    (:deepseek    . cl-agent.llm.providers:make-deepseek-provider)
    (:gemini      . cl-agent.llm.providers:make-gemini-provider)
    (:mistral     . cl-agent.llm.providers:make-mistral-provider)
    (:xai         . cl-agent.llm.providers:make-xai-provider)
    (:moonshot    . cl-agent.llm.providers:make-moonshot-provider)
    (:siliconflow . cl-agent.llm.providers:make-siliconflow-provider)
    (:openrouter  . cl-agent.llm.providers:make-openrouter-provider)
    (:ollama      . cl-agent.llm.providers:make-ollama-provider)

    ;; —— 厂商原生格式 ——
    (:dashscope   . cl-agent.llm.providers:make-dashscope-provider))
  "内置 provider 关键字 → 工厂函数名。")

(dolist (entry +builtin-provider-factories+)
  (register-provider (car entry)
                     (let ((factory (cdr entry)))
                       (lambda (&rest args) (apply factory args)))))

;;; ============================================================
;;; Provider Creation
;;; ============================================================

(defun create-provider (name &rest args)
  "Create a provider by name or alias.

Parameters:
  NAME - Provider name keyword, or a registered alias (\"claude\", \"gpt\", ...)
  ARGS - Arguments to pass to factory

Returns:
  Provider instance

Signals:
  Error if provider not registered

Note:
  别名在此解析（resolve-provider-name 对非别名是恒等的）。此前这里直接查
  factory 表、不解析别名，于是 register-provider-alias 注册的别名只在
  builder 路径可用，主路径 (create-provider \"claude\") 会报 Unknown provider——
  同一个别名机制在两条路径上行为不一致。"
  (let* ((resolved (resolve-provider-name name))
         (factory (get-provider-factory resolved)))
    (unless factory
      (error "Unknown provider: ~A. Registered providers: ~A"
             name (list-providers)))
    (apply factory args)))

;;; ============================================================
;;; Provider Aliases
;;; ============================================================

(defvar *provider-aliases* (make-hash-table :test 'equal)
  "Aliases for provider names.")

(defun register-provider-alias (alias name)
  "Register an alias for a provider.

Parameters:
  ALIAS - Alias string or keyword
  NAME  - Actual provider name keyword"
  (setf (gethash (if (keywordp alias)
                     (string-downcase (symbol-name alias))
                     (string-downcase alias))
                 *provider-aliases*)
        name))

(defun resolve-provider-name (name-or-alias)
  "Resolve a provider name or alias to the canonical name.

Parameters:
  NAME-OR-ALIAS - Name or alias

Returns:
  Canonical provider name keyword"
  (if (keywordp name-or-alias)
      (or (gethash (string-downcase (symbol-name name-or-alias))
                   *provider-aliases*)
          name-or-alias)
      (or (gethash (string-downcase name-or-alias)
                   *provider-aliases*)
          (intern (string-upcase name-or-alias) :keyword))))

;; Register common aliases
(register-provider-alias "claude" :anthropic)
(register-provider-alias "gpt" :openai)
(register-provider-alias "glm" :zhipu)
(register-provider-alias "chatglm" :zhipu)
(register-provider-alias "google" :gemini)
(register-provider-alias "qwen" :dashscope)
(register-provider-alias "bailian" :dashscope)
(register-provider-alias "grok" :xai)
(register-provider-alias "x-ai" :xai)
(register-provider-alias "kimi" :moonshot)
(register-provider-alias "moonshotai" :moonshot)
(register-provider-alias "silicon" :siliconflow)
(register-provider-alias "guiji" :siliconflow)

;;; ============================================================
;;; ChatModel 桥接（cl-agent-llm ↔ cl-agent.core 的 ChatModel 协议）
;;; ============================================================
;;; 历史：本函数原在 factory/builder.lisp——那里还有一个 provider-builder
;;; 类 + 8 个 fluent 泛型（with-api-key / with-model / ...）。Builder 与
;;; fluent 链是 Java 的表达习惯，与已退役的 ChatClient Builder 同一模式；
;;; 全库唯一消费 builder 的 create-chat-model-from-builder 自己也零调用。
;;; 本函数的关键字参数覆盖全部场景，builder.lisp 整体删除。

(defun create-chat-model (provider-name &rest args
                          &key model api-key api-url options &allow-other-keys)
  "从提供商规格创建 ChatModel（cl-agent-llm 与 cl-agent.chat 的桥梁）。

参数：
  PROVIDER-NAME - 提供商关键字（:anthropic、:openai 等）或别名
  MODEL         - 模型名（可选）
  API-KEY       - API 密钥（可选，默认取环境变量）
  API-URL       - API 地址（可选，默认取提供商默认值）
  OPTIONS       - 默认 chat-options（可选）
  其余关键字参数透传给提供商工厂。

返回：
  cl-agent.core:provider-chat-model 实例

用法：
  (create-chat-model :anthropic :model \"claude-sonnet-4-20250514\")
  (create-chat-model :openai :model \"gpt-4o\"
                     :options (cl-agent.core:make-chat-options :temperature 0.3))"
  (declare (ignore model api-key api-url))
  (let* ((resolved-name (resolve-provider-name provider-name))
         (provider (apply #'create-provider resolved-name
                          (alexandria:remove-from-plist args :options))))
    (cl-agent.core:make-provider-chat-model provider :default-options options)))
