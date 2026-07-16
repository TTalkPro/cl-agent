;;;; stream/openai.lisp
;;;; CL-Agent LLM - OpenAI 兼容 SSE 流式处理
;;;;
;;;; 概述（参照 clj-agent provider/stream/openai.clj）：
;;;;   处理 OpenAI 风格的 SSE 流式响应，构建与非流式调用兼容的
;;;;   llm-response。适用于 openai-compat-provider 全部子类
;;;;   （OpenAI / 智谱 / DeepSeek / Gemini / Mistral / Ollama ...）。
;;;;
;;;;   OpenAI 流式格式：
;;;;   - 每行 data: {...}，choices[0].delta 携带增量：
;;;;     content（文本）/ reasoning_content（DeepSeek/GLM 思维链）/
;;;;     tool_calls（按 index 分片：id/function.name 首片，
;;;;     function.arguments 逐片拼接 JSON 字符串）
;;;;   - choices[0].finish_reason 在末片给出
;;;;   - usage 在最后一个 chunk 顶层（DeepSeek 原生带；
;;;;     OpenAI 需 stream_options.include_usage，经 :extra-params 开启）
;;;;   - data: [DONE] 结束
;;;;
;;;; 回调协议（chunk plist）：
;;;;   :delta / :reasoning-delta / :done（与 Anthropic 流式一致）

(in-package :cl-agent.llm.providers)

;;; ============================================================
;;; 累积状态
;;; ============================================================

(defstruct (openai-stream-state (:conc-name ostream-))
  "OpenAI 兼容流式累积状态"
  (id nil)
  (model nil)
  (text (make-string-output-stream))
  (reasoning (make-string-output-stream))
  (tool-calls (make-hash-table))         ; index → (:id :name :args-stream)
  (finish-reason nil)
  (usage nil))

;;; ============================================================
;;; 事件处理
;;; ============================================================

(defun process-openai-chunk (state data callback)
  "处理单个 OpenAI 流式 chunk（已解析的 JSON hash-table）。

参数：
  STATE    - openai-stream-state
  DATA     - chunk JSON（hash-table）
  CALLBACK - chunk 回调（可为 NIL）"
  (flet ((emit (chunk)
           (when callback (funcall callback chunk))))
    ;; 元数据（首个携带者生效）
    (unless (ostream-id state)
      (setf (ostream-id state) (gethash "id" data)))
    (unless (ostream-model state)
      (setf (ostream-model state) (gethash "model" data)))
    ;; 末块 usage
    (let ((usage (gethash "usage" data)))
      (when (hash-table-p usage)
        (setf (ostream-usage state) usage)))
    ;; choices[0]
    (let* ((choices (gethash "choices" data))
           (choice (when (and choices (plusp (length choices)))
                     (elt choices 0))))
      (when choice
        ;; finish_reason（末片）
        (let ((finish (gethash "finish_reason" choice)))
          (when (and finish (not (eq finish 'null)))
            (setf (ostream-finish-reason state) finish)))
        ;; delta 增量
        (let ((delta (gethash "delta" choice)))
          (when (hash-table-p delta)
            ;; 文本
            (let ((content (gethash "content" delta)))
              (when (and (stringp content) (string/= content ""))
                (write-string content (ostream-text state))
                (emit (list :delta content))))
            ;; 思维链（DeepSeek reasoning_content / GLM 同名字段）
            (let ((reasoning (gethash "reasoning_content" delta)))
              (when (and (stringp reasoning) (string/= reasoning ""))
                (write-string reasoning (ostream-reasoning state))
                (emit (list :reasoning-delta reasoning))))
            ;; 工具调用分片：按 index 累积
            (let ((tool-calls (gethash "tool_calls" delta)))
              (when tool-calls
                (loop for tc across (if (vectorp tool-calls)
                                        tool-calls
                                        (coerce tool-calls 'vector))
                      do (let* ((index (or (gethash "index" tc) 0))
                                (entry (or (gethash index (ostream-tool-calls state))
                                           (setf (gethash index (ostream-tool-calls state))
                                                 (list :id nil :name nil
                                                       :args-stream (make-string-output-stream)))))
                                (fn (gethash "function" tc)))
                           ;; id / name 出现在首片
                           (let ((id (gethash "id" tc)))
                             (when id (setf (getf entry :id) id)))
                           (when fn
                             (let ((name (gethash "name" fn)))
                               (when name (setf (getf entry :name) name)))
                             (let ((args (gethash "arguments" fn)))
                               (when (stringp args)
                                 (write-string args (getf entry :args-stream)))))
                           (setf (gethash index (ostream-tool-calls state))
                                 entry)))))))))))

;;; ============================================================
;;; 响应构建
;;; ============================================================

(defun build-openai-stream-response (state)
  "从最终累积状态构建统一 llm-response（与非流式调用兼容）"
  (let ((tool-calls
          (loop for index in (sort (loop for k being the hash-keys
                                           of (ostream-tool-calls state)
                                         collect k)
                                   #'<)
                for entry = (gethash index (ostream-tool-calls state))
                collect (list :id (getf entry :id)
                              :name (let ((name (getf entry :name)))
                                      (when name
                                        (intern (string-upcase name) :keyword)))
                              :arguments
                              (let ((json-str (get-output-stream-string
                                               (getf entry :args-stream))))
                                (handler-case
                                    (if (string= json-str "")
                                        (make-hash-table :test 'equal)
                                        (cl-agent.core:json-parse json-str))
                                  (error () (make-hash-table :test 'equal)))))))
        (reasoning (get-output-stream-string (ostream-reasoning state))))
    (cl-agent.core:make-llm-response
     :content (get-output-stream-string (ostream-text state))
     :tool-calls tool-calls
     :usage (cl-agent.core:normalize-usage (ostream-usage state))
     :model (ostream-model state)
     :finish-reason (cl-agent.core:normalize-finish-reason
                     (or (ostream-finish-reason state)
                         (when tool-calls "tool_calls")))
     :reasoning (when (string/= reasoning "") reasoning)
     :message-id (ostream-id state))))

;;; ============================================================
;;; llm-chat-stream 实现（openai-compat-provider 全部子类）
;;; ============================================================

(defmethod cl-agent.core:provider-supports-streaming-p ((provider openai-compat-provider))
  t)

(defmethod cl-agent.core:llm-chat-stream ((provider openai-compat-provider) messages callback
                                          &key max-tokens
                                               ;; NIL 时不下发（SPI「存在才发送」契约）
                                               temperature
                                               model
                                               tools
                                               system
                                               top-p
                                               stop
                                               frequency-penalty
                                               presence-penalty
                                               tool-choice
                                               extra-params
                                          &allow-other-keys)
  "OpenAI 兼容的真 SSE 流式实现（openai/zhipu/deepseek/gemini/mistral/ollama）。

CALLBACK 收到 chunk plist：
  (:delta 文本增量) / (:reasoning-delta 思维链增量) / (:done t)

返回：
  最终 llm-response（与非流式调用兼容，含 tool-calls / 末块 usage）"
  (let* ((effective-messages (if system
                                 (cons (list :role :system :content system)
                                       messages)
                                 messages))
         (request-body (provider-finalize-request
                        provider
                        (build-openai-compatible-request
                         provider effective-messages
                         :max-tokens max-tokens
                         :temperature temperature
                         :model model
                         :tools tools
                         :top-p top-p
                         :stop stop
                         :frequency-penalty frequency-penalty
                         :presence-penalty presence-penalty
                         :tool-choice tool-choice
                         :extra-params extra-params
                         :stream t)))
         (url (cl-agent.llm:build-api-url
               provider
               (cl-agent.llm:provider-chat-endpoint provider)))
         (state (make-openai-stream-state)))
    (cl-agent.core:http-stream-sse
     url
     :headers (provider-auth-headers provider)
     :body (cl-agent.core:json-stringify request-body)
     :content-type "application/json"
     :timeout (max 300 (cl-agent.llm:provider-timeout provider))
     :on-event (lambda (event)
                 (let ((data-str (getf event :data)))
                   (when (and data-str
                              (string/= data-str "")
                              (not (string= data-str "[DONE]")))
                     (let ((data (handler-case
                                     (cl-agent.core:json-parse data-str)
                                   (error () nil))))
                       (when (hash-table-p data)
                         (process-openai-chunk state data callback)))))))
    (when callback
      (funcall callback (list :done t)))
    (build-openai-stream-response state)))
