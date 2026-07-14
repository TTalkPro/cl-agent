;;;; stream/anthropic.lisp
;;;; CL-Agent LLM - Anthropic SSE 流式处理
;;;;
;;;; 概述（参照 clj-agent provider/stream/anthropic.clj）：
;;;;   处理 Anthropic 格式的 SSE 流式响应，构建与非流式调用
;;;;   兼容的 llm-response。适用于 anthropic-provider 及其子类
;;;;   （如 MiniMax 的 Anthropic 兼容端点）。
;;;;
;;;;   Anthropic 流式事件类型：
;;;;   - message_start:       消息元数据（id/model/usage.input_tokens）
;;;;   - content_block_start: 内容块开始（text / tool_use / thinking）
;;;;   - content_block_delta: 增量（text_delta / input_json_delta /
;;;;                          thinking_delta / signature_delta）
;;;;   - content_block_stop:  内容块结束（tool_use 在此解析累积的 JSON）
;;;;   - message_delta:       stop_reason；usage.output_tokens 在事件顶层
;;;;   - message_stop:        消息结束
;;;;   - error:               流式错误（overloaded_error 等）
;;;;
;;;; 回调协议（chunk plist）：
;;;;   :delta           文本增量
;;;;   :reasoning-delta 思考/推理增量（extended thinking，与答案流分离）
;;;;   :done            流结束标志（最后一次回调）

(in-package :cl-agent.llm.providers)

;;; ============================================================
;;; 累积状态
;;; ============================================================

(defstruct (anthropic-stream-state (:conc-name astream-))
  "Anthropic 流式累积状态"
  (message nil)                          ; message_start 的 message（hash-table）
  (stop-reason nil)                      ; message_delta 的 stop_reason
  (delta-usage nil)                      ; message_delta 顶层 usage（hash-table）
  (blocks (make-hash-table))             ; index → block plist
  (text (make-string-output-stream))     ; 全局文本累积
  (reasoning (make-string-output-stream)) ; 全局思考累积
  (error nil))                           ; error 事件负载

(defun astream-block (state index)
  "取指定索引的内容块（plist），不存在返回 NIL"
  (gethash index (astream-blocks state)))

(defun (setf astream-block) (block state index)
  (setf (gethash index (astream-blocks state)) block))

;;; ============================================================
;;; 事件处理
;;; ============================================================

(defun process-anthropic-event (state event-type data callback)
  "处理单个 Anthropic SSE 事件。

参数：
  STATE      - anthropic-stream-state
  EVENT-TYPE - 事件类型字符串
  DATA       - 事件 JSON（hash-table）
  CALLBACK   - chunk 回调（可为 NIL）"
  (flet ((emit (chunk)
           (when callback (funcall callback chunk))))
    (cond
      ;; 消息开始：保存元数据
      ((string= event-type "message_start")
       (setf (astream-message state) (gethash "message" data)))

      ;; 内容块开始：登记块类型与元数据
      ((string= event-type "content_block_start")
       (let* ((index (gethash "index" data))
              (block (gethash "content_block" data)))
         (setf (astream-block state index)
               (list :type (gethash "type" block)
                     :id (gethash "id" block)
                     :name (gethash "name" block)
                     ;; tool_use 的 input 增量以 JSON 片段累积
                     ;; （start 自带的空 {} 占位丢弃，参照 clj 实现的坑）
                     :input-json (make-string-output-stream)
                     :text (make-string-output-stream)))))

      ;; 内容块增量
      ((string= event-type "content_block_delta")
       (let* ((index (gethash "index" data))
              (delta (gethash "delta" data))
              (delta-type (gethash "type" delta))
              (block (astream-block state index)))
         (cond
           ;; 文本增量：块内 + 全局累积，回调下发
           ((string= delta-type "text_delta")
            (let ((text (gethash "text" delta)))
              (when text
                (when block
                  (write-string text (getf block :text)))
                (write-string text (astream-text state))
                (emit (list :delta text)))))
           ;; 工具输入增量（JSON 片段）
           ((string= delta-type "input_json_delta")
            (let ((partial (gethash "partial_json" delta)))
              (when (and partial block)
                (write-string partial (getf block :input-json)))))
           ;; 思考增量：单独通道下发，不污染答案流
           ((string= delta-type "thinking_delta")
            (let ((thinking (gethash "thinking" delta)))
              (when thinking
                (write-string thinking (astream-reasoning state))
                (emit (list :reasoning-delta thinking))))))))

      ;; 内容块结束：tool_use 块解析累积的 JSON
      ((string= event-type "content_block_stop")
       (let* ((index (gethash "index" data))
              (block (astream-block state index)))
         (when (and block (equal (getf block :type) "tool_use"))
           (let ((json-str (get-output-stream-string (getf block :input-json))))
             (setf (getf block :input)
                   (handler-case
                       (if (string= json-str "")
                           (make-hash-table :test 'equal)
                           (cl-agent.core:json-parse json-str))
                     (error () (make-hash-table :test 'equal))))
             (setf (astream-block state index) block)))))

      ;; 消息增量：stop_reason + 顶层 usage
      ((string= event-type "message_delta")
       (let ((delta (gethash "delta" data)))
         (when delta
           (let ((stop-reason (gethash "stop_reason" delta)))
             (when stop-reason
               (setf (astream-stop-reason state) stop-reason)))))
       (let ((usage (gethash "usage" data)))
         (when usage
           (setf (astream-delta-usage state) usage))))

      ;; 流式错误：记录，build 时抛出
      ((string= event-type "error")
       (setf (astream-error state) (gethash "error" data))))))

;;; ============================================================
;;; 响应构建
;;; ============================================================

(defun merged-anthropic-usage (state)
  "合并 message_start 的 usage（input_tokens）与
message_delta 顶层 usage（output_tokens）"
  (let ((merged (make-hash-table :test 'equal))
        (start-usage (when (astream-message state)
                       (gethash "usage" (astream-message state))))
        (delta-usage (astream-delta-usage state)))
    (dolist (usage (list start-usage delta-usage))
      (when (hash-table-p usage)
        (loop for key being the hash-keys of usage using (hash-value value)
              when value
                do (setf (gethash key merged) value))))
    (when (plusp (hash-table-count merged))
      merged)))

(defun build-anthropic-stream-response (state)
  "从最终累积状态构建统一 llm-response（与非流式调用兼容）"
  (when (astream-error state)
    (cl-agent.core:signal-error
     'cl-agent.core:llm-error
     :message (format nil "Anthropic 流式错误：~A"
                      (or (and (hash-table-p (astream-error state))
                               (gethash "message" (astream-error state)))
                          (astream-error state)))))
  (let* ((message (astream-message state))
         (text (get-output-stream-string (astream-text state)))
         (reasoning (get-output-stream-string (astream-reasoning state)))
         (tool-calls
           (loop for index in (sort (loop for k being the hash-keys
                                            of (astream-blocks state)
                                          collect k)
                                    #'<)
                 for block = (astream-block state index)
                 when (equal (getf block :type) "tool_use")
                   collect (list :id (getf block :id)
                                 :name (getf block :name)
                                 :arguments (getf block :input)))))
    (cl-agent.core:make-llm-response
     :content text
     :tool-calls tool-calls
     :usage (cl-agent.core:normalize-usage (merged-anthropic-usage state))
     :model (when message (gethash "model" message))
     :finish-reason (cl-agent.core:normalize-finish-reason
                     (astream-stop-reason state))
     :reasoning (when (string/= reasoning "") reasoning)
     :message-id (when message (gethash "id" message))
     :raw-response message)))

;;; ============================================================
;;; llm-chat-stream 实现（anthropic-provider 及子类）
;;; ============================================================

(defmethod cl-agent.core:provider-supports-streaming-p ((provider anthropic-provider))
  t)

(defmethod cl-agent.core:llm-chat-stream ((provider anthropic-provider) messages callback
                                          &key
                                          (max-tokens 4096)
                                          (temperature 0.7)
                                          model
                                          tools
                                          system
                                          top-p
                                          top-k
                                          stop
                                          extra-params
                                          &allow-other-keys)
  "Anthropic 格式的真 SSE 流式实现（MiniMax 等子类继承）。

CALLBACK 收到 chunk plist：
  (:delta 文本增量) / (:reasoning-delta 思考增量) / (:done t)

返回：
  最终 llm-response（与非流式调用兼容，含 tool-calls / usage）"
  (let* ((request-body (build-anthropic-request-body
                        provider messages
                        :max-tokens max-tokens
                        :temperature temperature
                        :model model
                        :tools tools
                        :system system
                        :top-p top-p
                        :top-k top-k
                        :stop stop
                        :extra-params extra-params))
         (url (cl-agent.llm:build-api-url
               provider
               (cl-agent.llm:base-provider-stream-endpoint provider)))
         (state (make-anthropic-stream-state)))
    ;; 启用流式
    (setf (gethash "stream" request-body) t)
    (cl-agent.http:http-stream-sse
     url
     :headers (build-anthropic-headers provider)
     :body (cl-agent.core:json-stringify request-body)
     :content-type "application/json"
     ;; 长生成给足超时（对齐 clj 流式 300s）
     :timeout (max 300 (cl-agent.llm:base-provider-timeout provider))
     :on-event (lambda (event)
                 (let ((data-str (getf event :data)))
                   (when (and data-str (string/= data-str ""))
                     (let ((data (handler-case
                                     (cl-agent.core:json-parse data-str)
                                   (error () nil))))
                       (when (hash-table-p data)
                         (process-anthropic-event
                          state
                          ;; 事件类型以 JSON 的 type 字段为准
                          ;; （SSE event: 行与其一致，但 data 更可靠）
                          (or (gethash "type" data) (getf event :event))
                          data
                          callback)))))))
    (when callback
      (funcall callback (list :done t)))
    (build-anthropic-stream-response state)))
