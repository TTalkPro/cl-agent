;;;; streaming.lisp
;;;; CL-Agent HTTP - 流式请求支持
;;;;
;;;; 概述：
;;;;   提供 SSE（Server-Sent Events）流式请求支持
;;;;
;;;; 特性：
;;;;   - SSE 事件解析
;;;;   - 增量数据处理
;;;;   - 回调驱动的流处理
;;;;
;;;; 使用示例：
;;;;   (http-stream-sse "https://api.example.com/events"
;;;;     :on-event (lambda (event)
;;;;                 (format t "收到事件: ~A~%" event)))

(in-package #:cl-agent.http)

;;; ============================================================
;;; 流式上下文
;;; ============================================================

(defstruct stream-context
  "流式请求上下文

槽位说明：
  BUFFER       - 数据缓冲区（处理不完整的数据）
  CALLBACK     - 事件回调函数
  STOP-P       - 停止标志
  ACCUMULATOR  - 内容累加器
  EVENT-TYPE   - 当前事件类型
  EVENT-DATA   - 当前事件数据"
  (buffer "" :type string)
  (callback nil :type (or null function))
  (stop-p nil :type boolean)
  (accumulator "" :type string)
  (event-type nil)
  (event-data nil))

;;; ============================================================
;;; SSE 解析
;;; ============================================================

(defun parse-sse-line (line)
  "解析 SSE 单行

参数：
  LINE - SSE 文本行

返回：
  (values FIELD VALUE) 或 nil

SSE 格式：
  field: value

常见字段：
  - data: 事件数据
  - event: 事件类型
  - id: 事件 ID
  - retry: 重连间隔"
  (when (and line (> (length line) 0))
    (let ((colon-pos (position #\: line)))
      (if colon-pos
          (let* ((field (subseq line 0 colon-pos))
                 (value (if (> (length line) (1+ colon-pos))
                            (let ((start (1+ colon-pos)))
                              ;; 跳过可选的空格
                              (when (and (< start (length line))
                                         (char= (char line start) #\Space))
                                (incf start))
                              (subseq line start))
                            "")))
            (values field value))
          ;; 无冒号的行（注释或其他）
          (when (char= (char line 0) #\:)
            (values :comment (subseq line 1)))))))

(defun parse-sse-chunk (chunk context)
  "解析 SSE 数据块

参数：
  CHUNK   - 数据块字符串
  CONTEXT - stream-context 对象

返回：
  解析出的事件列表"
  (let* ((combined (concatenate 'string (stream-context-buffer context) chunk))
         (lines (cl-ppcre:split "\\r?\\n" combined))
         (events '())
         (current-data '())
         (current-event nil))

    ;; 检查最后是否有不完整的行
    (let ((ends-with-newline (and (> (length combined) 0)
                                   (member (char combined (1- (length combined)))
                                           '(#\Newline #\Return)))))
      (unless ends-with-newline
        ;; 保存最后不完整的行到缓冲区
        (setf (stream-context-buffer context) (car (last lines)))
        (setf lines (butlast lines)))

      (when ends-with-newline
        (setf (stream-context-buffer context) "")))

    ;; 解析每一行
    (dolist (line lines)
      (if (string= line "")
          ;; 空行表示事件结束
          (when current-data
            (push (list :event (or current-event "message")
                        :data (format nil "~{~A~^~%~}" (nreverse current-data)))
                  events)
            (setf current-data '())
            (setf current-event nil))
          ;; 解析字段
          (multiple-value-bind (field value) (parse-sse-line line)
            (when field
              (cond
                ((string= field "data")
                 (push value current-data))
                ((string= field "event")
                 (setf current-event value))
                ((string= field "id")
                 ;; 可以存储 last-event-id
                 nil)
                ((string= field "retry")
                 ;; 可以更新重连间隔
                 nil))))))

    (nreverse events)))

;;; ============================================================
;;; 流式请求
;;; ============================================================

(defun http-stream (url callback &key
                                   (method :get)
                                   headers
                                   body
                                   (content-type nil)
                                   (timeout 0))
  "发送流式 HTTP 请求

参数：
  URL      - 请求 URL
  CALLBACK - 数据回调函数，接收 (chunk context)
  METHOD   - HTTP 方法
  HEADERS  - 请求头
  BODY     - 请求体
  CONTENT-TYPE - 内容类型
  TIMEOUT  - 超时时间（0 表示无限）

返回：
  stream-context 对象

说明：
  回调函数签名：(lambda (chunk context) ...)
  - CHUNK: 接收到的数据块（字节数组）
  - CONTEXT: stream-context 对象

  在回调中设置 (setf (stream-context-stop-p context) t) 可停止流

示例：
  (http-stream \"https://api.example.com/stream\"
    (lambda (chunk context)
      (format t \"收到: ~A~%\" chunk)))"

  (let* ((context (make-stream-context :callback callback))
         (final-headers (copy-list headers)))

    ;; 添加必要的头
    (unless (assoc "Accept" final-headers :test #'string-equal)
      (push '("Accept" . "text/event-stream") final-headers))

    ;; 处理内容类型
    (when content-type
      (let ((ct-string (case content-type
                         (:json "application/json")
                         (otherwise content-type))))
        (unless (assoc "Content-Type" final-headers :test #'string-equal)
          (push (cons "Content-Type" ct-string) final-headers))))

    ;; 序列化 body
    (let ((final-body body))
      (when (and (consp body) (eq content-type :json))
        (setf final-body (json-body body)))

      ;; 执行流式请求
      (handler-case
          (dexador:request url
                           :method method
                           :headers final-headers
                           :content final-body
                           :connect-timeout (if (zerop timeout) nil timeout)
                           :read-timeout (if (zerop timeout) nil timeout)
                           :want-stream t
                           :keep-alive nil)
        (error (e)
          (error 'http-error :uri url :cause e)))

      context)))

(defun http-stream-sse (url &key
                              (method :post)
                              headers
                              body
                              (content-type :json)
                              (timeout 0)
                              (on-event nil)
                              (on-error nil)
                              (on-complete nil))
  "发送 SSE 流式请求

参数：
  URL         - 请求 URL
  METHOD      - HTTP 方法（默认 :post）
  HEADERS     - 请求头
  BODY        - 请求体
  CONTENT-TYPE - 内容类型
  TIMEOUT     - 超时时间
  ON-EVENT    - 事件回调 (lambda (event-type data))
  ON-ERROR    - 错误回调 (lambda (error))
  ON-COMPLETE - 完成回调 (lambda (context))

返回：
  累积的响应内容字符串

说明：
  ON-EVENT 接收的 event 为 plist:
  (:event EVENT-TYPE :data DATA-STRING)

示例：
  (http-stream-sse \"https://api.example.com/chat\"
    :body '((\"messages\" . ((\"content\" . \"Hello\"))))
    :on-event (lambda (event)
                (format t \"~A: ~A~%\"
                        (getf event :event)
                        (getf event :data))))"

  (let* ((context (make-stream-context))
         (final-headers (copy-list headers))
         (accumulator ""))

    ;; 添加必要的头
    (unless (assoc "Accept" final-headers :test #'string-equal)
      (push '("Accept" . "text/event-stream") final-headers))

    (when content-type
      (let ((ct-string (case content-type
                         (:json "application/json")
                         (otherwise content-type))))
        (unless (assoc "Content-Type" final-headers :test #'string-equal)
          (push (cons "Content-Type" ct-string) final-headers))))

    (let ((final-body body))
      (when (and (consp body) (eq content-type :json))
        (setf final-body (json-body body)))

      (handler-case
          (multiple-value-bind (body-stream status response-headers)
              (dexador:request url
                               :method method
                               :headers final-headers
                               :content final-body
                               :connect-timeout (if (zerop timeout) nil timeout)
                               :read-timeout (if (zerop timeout) nil timeout)
                               :want-stream t
                               :keep-alive nil)
            (declare (ignore status response-headers))

            ;; 处理流
            (unwind-protect
                 (let ((buffer (make-array 4096 :element-type '(unsigned-byte 8))))
                   (loop for bytes-read = (read-sequence buffer body-stream)
                         while (and (plusp bytes-read)
                                    (not (stream-context-stop-p context)))
                         do
                         ;; 转换为字符串
                         (let ((chunk (flexi-streams:octets-to-string
                                       buffer
                                       :external-format :utf-8
                                       :end bytes-read)))
                           ;; 解析 SSE 事件
                           (dolist (event (parse-sse-chunk chunk context))
                             (let ((data (getf event :data)))
                               ;; 累积数据
                               (when data
                                 (setf accumulator
                                       (concatenate 'string accumulator data)))
                               ;; 调用回调
                               (when on-event
                                 (funcall on-event event)))))))
              ;; 关闭流
              (close body-stream))

            ;; 调用完成回调
            (when on-complete
              (funcall on-complete context)))

        (error (e)
          (if on-error
              (funcall on-error e)
              (error 'http-error :uri url :cause e)))))

    accumulator))
