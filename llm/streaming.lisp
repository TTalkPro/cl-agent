;;;; streaming.lisp
;;;; CL-Agent - 流式响应支持
;;;;
;;;; 概述：
;;;;   实现 LLM 流式响应功能
;;;;
;;;; 特性：
;;;;   - SSE（Server-Sent Events）流式解析
;;;;   - 增量响应处理
;;;;   - 回调函数支持
;;;;   - 多提供商支持
;;;;
;;;; 使用示例：
;;;;   (chat-stream client '((:user . "Tell me a story"))
;;;;                (lambda (event)
;;;;                  (format t "~A" (getf event :text))))

(in-package :cl-agent.llm)

;;; ============================================================
;;; 流式上下文结构
;;; ============================================================

(defstruct stream-context
  "流式响应上下文

槽位说明：
  CLIENT        - LLM 客户端
  CALLBACK      - 回调函数，接收事件 plist
  ACCUMULATOR   - 内容累加器
  CHUNK-BUFFER  - 块缓冲区（处理不完整的 SSE 数据）
  FIRST-CHUNK-P - 是否第一个块"
  client
  callback
  (accumulator "")
  (chunk-buffer "")
  (first-chunk-p t))

;;; ============================================================
;;; SSE 解析器
;;; ============================================================

(defun parse-sse-line (line)
  "解析 SSE 行

参数：
  LINE - SSE 文本行

返回：
  解析后的数据（JSON 字符串或 nil）

SSE 格式：
  data: {\"type\": \"content\", \"text\": \"Hello\"}

示例：
  (parse-sse-line \"data: {\\\"type\\\": \\\"content\\\"}\")
  => \"{\\\"type\\\": \\\"content\\\"}\""
  (when (and line (> (length line) 0))
    (let ((trimmed (string-trim '(#\Space #\Tab #\Newline #\Return) line)))
      (when (and (> (length trimmed) 5)
                 (string= (subseq trimmed 0 5) "data:"))
        (let ((data (subseq trimmed 5)))
          (string-trim '(#\Space) data))))))

(defun parse-sse-chunk (chunk)
  "解析 SSE 数据块

参数：
  CHUNK - SSE 数据块（可能包含多行）

返回：
  解析后的数据列表"
  (let ((lines (cl-ppcre:split "\\r?\\n" chunk)))
    (remove nil (mapcar #'parse-sse-line lines))))

;;; ============================================================
;;; 提供商特定的流式解析
;;; ============================================================

(defun parse-stream-event (json-data provider-type)
  "解析流式事件（通用入口）

参数：
  JSON-DATA     - JSON 字符串
  PROVIDER-TYPE - 提供商类型

返回：
  解析后的事件 plist"
  (handler-case
      (ecase provider-type
        (:anthropic (parse-anthropic-stream-event json-data))
        (:openai (parse-openai-stream-event json-data))
        (:ollama (parse-ollama-stream-event json-data))
        (:zhipu (parse-zhipu-stream-event json-data)))
    (error ()
      ;; 解析失败时返回 nil
      nil)))

(defun parse-anthropic-stream-event (json-data)
  "解析 Anthropic 流式事件

参数：
  JSON-DATA - JSON 字符串

返回：
  解析后的事件 plist

事件类型：
  - message_start: 消息开始
  - content_block_delta: 内容增量
  - message_stop: 消息停止"
  (let ((data (cl-agent.core:json-parse json-data)))
    (let ((type (alist-get data "type")))
      (cond
        ((string= type "message_start")
         `(:type :start :message ,(alist-get data "message")))
        ((string= type "content_block_delta")
         (let ((delta (alist-get data "delta")))
           `(:type :content :text ,(alist-get delta "text"))))
        ((string= type "content_block_stop")
         `(:type :content-stop))
        ((string= type "message_delta")
         `(:type :delta :usage ,(alist-get data "usage")))
        ((string= type "message_stop")
         `(:type :stop))
        (t nil)))))

(defun parse-openai-stream-event (json-data)
  "解析 OpenAI 流式事件

参数：
  JSON-DATA - JSON 字符串

返回：
  解析后的事件 plist"
  ;; 检查 [DONE] 标记
  (when (string= (string-trim '(#\Space) json-data) "[DONE]")
    (return-from parse-openai-stream-event `(:type :stop)))

  (let ((data (cl-agent.core:json-parse json-data)))
    (let ((choices (alist-get data "choices")))
      (when choices
        (let* ((choice (first choices))
               (finish-reason (alist-get choice "finish_reason")))
          (if finish-reason
              `(:type :stop :reason ,finish-reason)
              (let ((delta (alist-get choice "delta")))
                `(:type :content :text ,(alist-get delta "content")))))))))

(defun parse-ollama-stream-event (json-data)
  "解析 Ollama 流式事件

参数：
  JSON-DATA - JSON 字符串

返回：
  解析后的事件 plist"
  (let ((data (cl-agent.core:json-parse json-data)))
    (if (alist-get data "done")
        `(:type :stop)
        (let ((message (alist-get data "message")))
          `(:type :content
            :text ,(alist-get message "content"))))))

(defun parse-zhipu-stream-event (json-data)
  "解析智谱 AI 流式事件

参数：
  JSON-DATA - JSON 字符串

返回：
  解析后的事件 plist

说明：
  智谱 AI 的流式格式与 OpenAI 兼容"
  ;; 检查 [DONE] 标记
  (when (string= (string-trim '(#\Space) json-data) "[DONE]")
    (return-from parse-zhipu-stream-event `(:type :stop)))

  (let ((data (cl-agent.core:json-parse json-data)))
    (let ((choices (alist-get data "choices")))
      (when choices
        (let* ((choice (first choices))
               (finish-reason (alist-get choice "finish_reason")))
          (if finish-reason
              `(:type :stop :reason ,finish-reason)
              (let ((delta (alist-get choice "delta")))
                `(:type :content
                  :text ,(alist-get delta "content")))))))))

;;; ============================================================
;;; 流式请求执行
;;; ============================================================

(defun chat-stream (client messages callback &key
                                               (system nil)
                                               (tools nil)
                                               (temperature nil)
                                               (max-tokens nil))
  "流式聊天接口

参数：
  CLIENT      - 客户端实例
  MESSAGES    - 消息列表
  CALLBACK    - 回调函数，接收事件 plist
  SYSTEM      - 系统提示（可选）
  TOOLS       - 工具列表（可选）
  TEMPERATURE - 温度（可选）
  MAX-TOKENS  - 最大 token 数（可选）

返回：
  完整的响应内容字符串

回调格式：
  回调函数接收事件 plist，包含：
  - :type   事件类型（:start, :content, :stop）
  - :text   内容文本（:content 类型时）

示例：
  (chat-stream *client*
              '((:user . \"Tell me a story\"))
              (lambda (event)
                (when (eq (getf event :type) :content)
                  (format t \"~A\" (getf event :text))
                  (force-output))))"

  (let* ((provider (client-provider client))
         (provider-type (provider-name provider))
         (temp (or temperature (client-temperature client)))
         (tokens (or max-tokens (client-max-tokens client)))

         ;; 构建请求
         (request-body (build-chat-request-body
                        provider
                        messages
                        :system system
                        :tools (when tools (convert-tools-to-provider tools provider))
                        :temperature temp
                        :max-tokens tokens
                        :stream t))

         (request-url (concatenate 'string
                                   (client-base-url client)
                                   (provider-stream-endpoint provider)))

         (request-headers (provider-headers provider (client-api-key client)))

         ;; 创建流式上下文
         (context (make-stream-context
                   :client client
                   :callback callback)))

    ;; 执行流式请求
    ;; 注：使用 dexador 的 :want-stream 选项获取响应流
    ;; dexador 通过 cl-agent-core 的依赖传递可用
    (handler-case
        (multiple-value-bind (body-stream status headers)
            (dexador:request
             request-url
             :method :post
             :content (cl-agent.core:json-stringify request-body)
             :headers request-headers
             :want-stream t
             :keep-alive nil)
          (declare (ignore status headers))
          ;; 处理流式响应
          (unwind-protect
               (progn
                 (process-stream-response body-stream context provider-type)
                 ;; 返回累积的内容
                 (stream-context-accumulator context))
            ;; 确保关闭流
            (when body-stream
              (close body-stream))))

      ;; HTTP 错误处理
      (cl-agent.http:http-error (condition)
        (cl-agent.core:signal-error 'cl-agent.core:llm-error
                                    :message (format nil "HTTP 流式请求失败: ~A"
                                                     (cl-agent.http:http-error-status condition))
                                    :provider provider-type
                                    :status-code (cl-agent.http:http-error-status condition)
                                    :url request-url
                                    :cause condition))

      (dexador:http-request-failed (condition)
        (cl-agent.core:signal-error 'cl-agent.core:llm-error
                                    :message (format nil "HTTP 流式请求失败: ~A"
                                                     (dexador:response-status condition))
                                    :provider provider-type
                                    :status-code (dexador:response-status condition)
                                    :url request-url
                                    :cause condition))

      (error (condition)
        (cl-agent.core:signal-error 'cl-agent.core:llm-error
                                    :message (format nil "流式处理错误: ~A" condition)
                                    :provider provider-type
                                    :url request-url
                                    :cause condition)))))

(defun process-stream-response (body-stream context provider-type)
  "处理流式响应

参数：
  BODY-STREAM   - 响应体流
  CONTEXT       - 流式上下文
  PROVIDER-TYPE - 提供商类型"
  (let ((buffer (make-array 1024 :element-type '(unsigned-byte 8)))
        (callback (stream-context-callback context)))

    ;; 读取流
    (loop for bytes-read = (read-sequence buffer body-stream)
          while (plusp bytes-read)
          do
          ;; 转换为字符串
          (let ((chunk (flexi-streams:octets-to-string
                        buffer
                        :external-format :utf-8
                        :end bytes-read)))

            ;; 累积到缓冲区
            (setf (stream-context-chunk-buffer context)
                  (concatenate 'string
                               (stream-context-chunk-buffer context)
                               chunk))

            ;; 解析完整的 SSE 事件
            (dolist (event-data (parse-sse-chunk (stream-context-chunk-buffer context)))
              ;; 解析事件
              (let ((parsed (parse-stream-event event-data provider-type)))
                (when parsed
                  ;; 处理不同类型的事件
                  (case (getf parsed :type)
                    (:content
                     (let ((text (getf parsed :text)))
                       (when text
                         ;; 累积内容
                         (setf (stream-context-accumulator context)
                               (concatenate 'string
                                            (stream-context-accumulator context)
                                            text))
                         ;; 调用回调
                         (funcall callback parsed))))

                    (:stop
                     ;; 消息结束
                     (return-from process-stream-response))

                    (otherwise
                     ;; 其他事件类型，可选择调用回调
                     nil)))))

            ;; 清空已处理的缓冲区
            (setf (stream-context-chunk-buffer context) "")))))

;;; ============================================================
;;; 便捷流式 API
;;; ============================================================

(defun chat-stream-simple (client prompt callback &key (system nil))
  "简化的流式聊天接口

参数：
  CLIENT   - 客户端实例
  PROMPT   - 用户提示
  CALLBACK - 回调函数，接收每个文本块
  SYSTEM   - 系统提示（可选）

返回：
  完整响应字符串

示例：
  (chat-stream-simple *client* \"Count to 10\"
                     (lambda (event)
                       (format t \"~A\" (getf event :text))
                       (force-output)))"
  (chat-stream client `((:user . ,prompt)) callback :system system))

(defun chat-stream-to-string (client prompt &key (system nil))
  "流式聊天但收集到字符串

参数：
  CLIENT - 客户端实例
  PROMPT - 用户提示
  SYSTEM - 系统提示（可选）

返回：
  完整响应字符串

示例：
  (let ((response (chat-stream-to-string *client* \"Hello\")))
    (format t \"Full response: ~A\" response))"
  (chat-stream client
               `((:user . ,prompt))
               (lambda (event)
                 (declare (ignore event)))
               :system system))

(defun chat-stream-to-file (client prompt filepath &key (system nil))
  "流式聊天并写入文件

参数：
  CLIENT   - 客户端实例
  PROMPT   - 用户提示
  FILEPATH - 输出文件路径
  SYSTEM   - 系统提示（可选）

返回：
  完整响应字符串

示例：
  (chat-stream-to-file *client*
                      \"Write a long essay\"
                      \"essay.txt\")"
  (with-open-file (stream filepath
                          :direction :output
                          :if-exists :supersede
                          :if-does-not-exist :create
                          :external-format :utf-8)
    (chat-stream client
                 `((:user . ,prompt))
                 (lambda (event)
                   (when-let (text (getf event :text))
                     ;; 写入文件
                     (write-string text stream)
                     (force-output stream)))
                 :system system)))

;;; ============================================================
;;; 流式迭代器
;;; ============================================================

(defstruct stream-iterator
  "流式响应迭代器

槽位说明：
  CONTENT-LIST  - 内容块列表
  CURRENT-INDEX - 当前索引"
  content-list
  (current-index 0))

(defun chat-stream-iterator (client messages &key (system nil))
  "创建流式响应迭代器

参数：
  CLIENT   - 客户端实例
  MESSAGES - 消息列表
  SYSTEM   - 系统提示（可选）

返回：
  迭代器对象

示例：
  (let ((iter (chat-stream-iterator *client* '((:user . \"Hello\")))))
    (loop for chunk = (stream-next iter)
          while chunk
          do (format t \"~A\" chunk)))"
  (let ((chunks '()))
    ;; 收集所有块
    (chat-stream client messages
                 (lambda (event)
                   (when-let (text (getf event :text))
                     (push text chunks)))
                 :system system)
    ;; 反转列表
    (make-stream-iterator
     :content-list (nreverse chunks)
     :current-index 0)))

(defun stream-next (iterator)
  "获取下一个内容块

参数：
  ITERATOR - 流迭代器

返回：
  下一个内容块或 nil（如果已结束）

示例：
  (let ((iter (chat-stream-iterator *client* ...)))
    (loop for chunk = (stream-next iter)
          while chunk
          do (process-chunk chunk)))"
  (when (< (stream-iterator-current-index iterator)
           (length (stream-iterator-content-list iterator)))
    (let ((chunk (elt (stream-iterator-content-list iterator)
                      (stream-iterator-current-index iterator))))
      (incf (stream-iterator-current-index iterator))
      chunk)))

(defun stream-has-more-p (iterator)
  "检查是否还有更多内容

参数：
  ITERATOR - 流迭代器

返回：
  t 或 nil"
  (< (stream-iterator-current-index iterator)
     (length (stream-iterator-content-list iterator))))
