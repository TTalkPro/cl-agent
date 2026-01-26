;;;; service.lisp
;;;; CL-Agent LLM - Service Layer
;;;;
;;;; Overview:
;;;;   Service layer that normalizes provider responses to unified llm-response format.
;;;;   This separates the concern of API communication (Provider layer) from
;;;;   response normalization (Service layer).
;;;;
;;;; Architecture:
;;;;   Provider Layer (返回原始 API 响应)
;;;;   ├── anthropic.lisp  ──┐
;;;;   ├── bailian.lisp      │
;;;;   ├── zhipu.lisp        ├──→ llm-chat 返回原始格式 plist
;;;;   ├── openai.lisp       │
;;;;   └── ...             ──┘
;;;;            │
;;;;            ▼
;;;;   Service Layer (service.lisp)
;;;;   └── normalize-response ──→ llm-response 对象
;;;;
;;;; Usage:
;;;;   ;; Provider returns raw plist
;;;;   (let ((raw-response (llm-chat provider messages)))
;;;;     ;; Service normalizes to llm-response
;;;;     (normalize-response raw-response (provider-name provider)))

(in-package :cl-agent.llm)

;;; ============================================================
;;; Response Normalization
;;; ============================================================

(defun normalize-response (raw-response provider-type)
  "将各 provider 的原始响应转换为统一的 llm-response 对象

参数：
  RAW-RESPONSE  - Provider 返回的原始响应 plist
  PROVIDER-TYPE - Provider 类型 (:anthropic, :openai, :zhipu, :ollama, :dashscope)

返回：
  llm-response 对象

说明：
  这是 Service 层的核心函数，负责将各种 Provider 返回的不同格式
  统一转换为 llm-response 对象，供上层（Kernel、Agent）使用。"
  (ecase provider-type
    (:anthropic (normalize-anthropic-response raw-response))
    (:openai    (normalize-openai-response raw-response))
    (:zhipu     (normalize-zhipu-response raw-response))
    (:ollama    (normalize-ollama-response raw-response))
    (:dashscope (normalize-dashscope-response raw-response))))

;;; ============================================================
;;; Provider-Specific Normalizers
;;; ============================================================

(defun normalize-anthropic-response (raw)
  "将 Anthropic 响应转换为 llm-response

Anthropic 响应格式：
  (:content \"...\"
   :tool-calls (...)
   :model \"claude-...\"
   :usage (:input-tokens N :output-tokens M)
   :stop-reason \"end_turn\"
   :id \"msg_...\"
   :raw-response <hash-table>)"
  (let ((content (getf raw :content))
        (tool-calls (getf raw :tool-calls))
        (model (getf raw :model))
        (usage (getf raw :usage))
        (stop-reason (getf raw :stop-reason))
        (message-id (getf raw :id))
        (raw-response (getf raw :raw-response)))
    (cl-agent.core:make-llm-response
     :content (or content "")
     :tool-calls tool-calls
     :usage (normalize-usage usage :anthropic)
     :model model
     :finish-reason (cl-agent.core:normalize-finish-reason stop-reason)
     :message-id message-id
     :raw-response raw-response)))

(defun normalize-openai-response (raw)
  "将 OpenAI 响应转换为 llm-response

OpenAI 响应格式：
  (:content \"...\"
   :tool-calls (...)
   :model \"gpt-...\"
   :usage (:prompt-tokens N :completion-tokens M)
   :finish-reason \"stop\"
   :id \"chatcmpl-...\"
   :raw-response <hash-table>)"
  (let ((content (getf raw :content))
        (tool-calls (getf raw :tool-calls))
        (model (getf raw :model))
        (usage (getf raw :usage))
        (finish-reason (getf raw :finish-reason))
        (message-id (getf raw :id))
        (raw-response (getf raw :raw-response)))
    (cl-agent.core:make-llm-response
     :content (or content "")
     :tool-calls tool-calls
     :usage (normalize-usage usage :openai)
     :model model
     :finish-reason (cl-agent.core:normalize-finish-reason finish-reason)
     :message-id message-id
     :raw-response raw-response)))

(defun normalize-zhipu-response (raw)
  "将智谱 AI 响应转换为 llm-response

智谱响应格式：
  (:content \"...\"
   :reasoning-content \"...\"  ; 思维链（特有）
   :tool-calls (...)
   :model \"glm-...\"
   :usage (:prompt-tokens N :completion-tokens M :total-tokens T)
   :finish-reason \"stop\"
   :id \"...\"
   :raw-response <hash-table>)

注意：
  reasoning-content 保存在 raw-response 中以便后续提取"
  (let ((content (getf raw :content))
        (reasoning-content (getf raw :reasoning-content))
        (tool-calls (getf raw :tool-calls))
        (model (getf raw :model))
        (usage (getf raw :usage))
        (finish-reason (getf raw :finish-reason))
        (message-id (getf raw :id))
        (raw-response (getf raw :raw-response)))
    ;; 将 reasoning-content 存入扩展的 raw-response
    (let ((extended-raw (if reasoning-content
                            (let ((h (make-hash-table :test 'equal)))
                              (setf (gethash "parsed" h) raw-response)
                              (setf (gethash "reasoning_content" h) reasoning-content)
                              h)
                            raw-response)))
      (cl-agent.core:make-llm-response
       :content (or content "")
       :tool-calls tool-calls
       :usage (normalize-usage usage :zhipu)
       :model model
       :finish-reason (cl-agent.core:normalize-finish-reason finish-reason)
       :message-id message-id
       :raw-response extended-raw))))

(defun normalize-ollama-response (raw)
  "将 Ollama 响应转换为 llm-response

Ollama 响应格式：
  (:content \"...\"
   :model \"llama2\"
   :done t)"
  (let ((content (getf raw :content))
        (model (getf raw :model))
        (done (getf raw :done)))
    (cl-agent.core:make-llm-response
     :content (or content "")
     :tool-calls nil
     :usage (cl-agent.core:make-llm-usage
             :input-tokens 0
             :output-tokens 0)
     :model model
     :finish-reason (if done :stop :unknown)
     :message-id nil
     :raw-response raw)))

(defun normalize-dashscope-response (raw)
  "将 DashScope/百炼 响应转换为 llm-response

DashScope 响应格式：
  (:content \"...\"
   :tool-calls (...)
   :model \"qwen-...\"
   :usage (:prompt-tokens N :completion-tokens M :total-tokens T)
   :raw-response <hash-table>)"
  (let ((content (getf raw :content))
        (tool-calls (getf raw :tool-calls))
        (model (getf raw :model))
        (usage (getf raw :usage))
        (raw-response (getf raw :raw-response)))
    (cl-agent.core:make-llm-response
     :content (or content "")
     :tool-calls tool-calls
     :usage (normalize-usage usage :dashscope)
     :model model
     :finish-reason :stop  ; DashScope 默认 stop
     :message-id nil
     :raw-response raw-response)))

;;; ============================================================
;;; Usage Normalization
;;; ============================================================

(defun normalize-usage (usage provider-type)
  "将各 provider 的 usage 信息转换为 llm-usage 对象

参数：
  USAGE         - Provider 返回的 usage 信息（plist 或 hash-table）
  PROVIDER-TYPE - Provider 类型

返回：
  llm-usage 对象"
  (when (null usage)
    (return-from normalize-usage
      (cl-agent.core:make-llm-usage :input-tokens 0 :output-tokens 0)))

  (let ((input-tokens 0)
        (output-tokens 0)
        (cache-read-tokens nil)
        (cache-creation-tokens nil))

    (cond
      ;; Hash-table format (from raw API response)
      ((hash-table-p usage)
       (ecase provider-type
         ((:anthropic)
          (setf input-tokens (or (gethash "input_tokens" usage) 0))
          (setf output-tokens (or (gethash "output_tokens" usage) 0))
          (setf cache-read-tokens (gethash "cache_read_input_tokens" usage))
          (setf cache-creation-tokens (gethash "cache_creation_input_tokens" usage)))
         ((:openai)
          (setf input-tokens (or (gethash "prompt_tokens" usage) 0))
          (setf output-tokens (or (gethash "completion_tokens" usage) 0)))
         ((:zhipu :dashscope)
          (setf input-tokens (or (gethash "prompt_tokens" usage)
                                 (gethash "input_tokens" usage) 0))
          (setf output-tokens (or (gethash "completion_tokens" usage)
                                  (gethash "output_tokens" usage) 0)))
         ((:ollama)
          (setf input-tokens 0)
          (setf output-tokens 0))))

      ;; Plist format
      ((listp usage)
       (ecase provider-type
         ((:anthropic)
          (setf input-tokens (or (getf usage :input-tokens) 0))
          (setf output-tokens (or (getf usage :output-tokens) 0))
          (setf cache-read-tokens (getf usage :cache-read-input-tokens))
          (setf cache-creation-tokens (getf usage :cache-creation-input-tokens)))
         ((:openai)
          (setf input-tokens (or (getf usage :prompt-tokens) 0))
          (setf output-tokens (or (getf usage :completion-tokens) 0)))
         ((:zhipu :dashscope)
          (setf input-tokens (or (getf usage :prompt-tokens)
                                 (getf usage :input-tokens) 0))
          (setf output-tokens (or (getf usage :completion-tokens)
                                  (getf usage :output-tokens) 0)))
         ((:ollama)
          (setf input-tokens 0)
          (setf output-tokens 0)))))

    (cl-agent.core:make-llm-usage
     :input-tokens input-tokens
     :output-tokens output-tokens
     :cache-read-tokens cache-read-tokens
     :cache-creation-tokens cache-creation-tokens)))

;;; ============================================================
;;; High-Level Service Functions
;;; ============================================================

(defun chat-with-normalization (provider messages &rest args
                                &key max-tokens temperature model tools system)
  "调用 LLM 并返回统一的 llm-response 对象

参数：
  PROVIDER    - Provider 实例
  MESSAGES    - 消息列表
  MAX-TOKENS  - 最大 token 数
  TEMPERATURE - 温度参数
  MODEL       - 模型名称
  TOOLS       - 工具列表
  SYSTEM      - 系统提示

返回：
  llm-response 对象

说明：
  这是推荐的高层 API，内部调用 provider 的 llm-chat，
  然后通过 normalize-response 转换为统一格式。"
  (declare (ignore max-tokens temperature model tools system))
  (let ((raw-response (apply #'llm-chat provider messages args))
        (provider-type (provider-name provider)))
    (normalize-response raw-response provider-type)))

;;; ============================================================
;;; Utility Functions for llm-response
;;; ============================================================

(defun response-reasoning-content (response)
  "从 llm-response 中提取思维链内容（智谱特有）

参数：
  RESPONSE - llm-response 对象

返回：
  思维链字符串，如果没有则返回 nil"
  (let ((raw (cl-agent.core:llm-response-raw response)))
    (when (hash-table-p raw)
      (gethash "reasoning_content" raw))))

(defun response-complete-p (response)
  "检查响应是否完整（非截断）

参数：
  RESPONSE - llm-response 对象

返回：
  t 如果响应完整，nil 如果被截断"
  (eq (cl-agent.core:llm-response-finish-reason response) :stop))
