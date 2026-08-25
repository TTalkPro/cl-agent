;;;; base.lisp
;;;; CL-Agent - LLM 提供商基类
;;;;
;;;; 概述：
;;;;   定义 LLM 提供商的基类和通用功能
;;;;
;;;; 设计原则：
;;;;   - 所有提供商继承 base-provider 类
;;;;   - 提供统一的 CLOS 接口
;;;;   - 错误处理使用 cl-agent/core 中的条件
;;;;
;;;; 使用示例：
;;;;   ;; 定义新的提供商
;;;;   (defclass my-provider (base-provider)
;;;;     ((api-key :initarg :api-key :reader my-provider-api-key)))
;;;;
;;;;   ;; 实现 llm-chat 方法
;;;;   (defmethod llm-chat ((provider my-provider) messages &key ...)
;;;;     ...)

(in-package :cl-agent/llm)

;;; ============================================================
;;; 提供商基类
;;; ============================================================

;;; 刻意没有 definvariants：本类**不带槽**（各 provider 子类自带
;;; api-key / api-url / model 等），而子类的这些槽也不适合挂必填——
;;; API key 允许延迟提供（make-*-provider 从环境变量读，读不到时报的是
;;; missing-api-key-error，那个错误信息本身就足够清楚），强制必填会挡掉
;;; 「先建 provider、稍后设 key」的合法用法。
;;; 判据见 core/invariants.lisp 头注的三分类。

(defclass base-provider ()
  ((name :initarg :name
         :reader base-provider-name
         :documentation "提供商名称（关键字，如 :openai）")
   (api-url :initarg :api-url
            :reader base-provider-api-url
            :documentation "API 基础 URL")
   (default-model :initarg :default-model
                  :reader base-provider-default-model
                  :documentation "默认模型名称")
   (chat-endpoint :initarg :chat-endpoint
                  :reader base-provider-chat-endpoint
                  :documentation "聊天 API 端点路径")
   (stream-endpoint :initarg :stream-endpoint
                    :reader base-provider-stream-endpoint
                    :documentation "流式 API 端点路径")
   (timeout :initarg :timeout
            :initform 120
            :reader base-provider-timeout
            :documentation "请求超时时间（秒）"))
  (:documentation "LLM 提供商基类

所有具体提供商都应该继承此类并实现 llm-chat 方法。

槽位说明：
  NAME           - 提供商标识符（:anthropic, :openai, :ollama, :zhipu）
  API-URL        - API 服务器基础 URL
  DEFAULT-MODEL  - 默认使用的模型
  CHAT-ENDPOINT  - 聊天 API 的路径
  STREAM-ENDPOINT - 流式 API 的路径
  TIMEOUT        - HTTP 请求超时时间"))

;;; ============================================================
;;; 泛型函数定义
;;; ============================================================

;;; llm-chat 泛型函数现定义在 cl-agent/chat-client 包中（core/chat-client/chat-client.lisp）
;;; cl-agent/llm 包通过 :import-from 导入并重导出该符号

(defgeneric llm-available-p (provider)
  (:documentation "检查提供商是否可用

参数：
  PROVIDER - 提供商实例

返回：
  t 或 nil"))

(defgeneric llm-provider-name (provider)
  (:documentation "获取提供商名称

参数：
  PROVIDER - 提供商实例

返回：
  提供商名称关键字"))

(defgeneric llm-default-model (provider)
  (:documentation "获取默认模型名称

参数：
  PROVIDER - 提供商实例

返回：
  模型名称字符串"))

;;; ============================================================
;;; 默认方法实现
;;; ============================================================

(defmethod llm-available-p ((provider base-provider))
  "检查提供商是否可用

默认实现：总是返回 t
子类可以重写此方法实现更复杂的检查（如 API 连通性测试）"
  (declare (ignore provider))
  t)

;; Implement provider-name generic function from cl-agent/core
(defmethod cl-agent/core:provider-name ((provider base-provider))
  "获取提供商名称"
  (base-provider-name provider))

(defmethod llm-provider-name ((provider base-provider))
  "获取提供商名称"
  (base-provider-name provider))

(defmethod llm-default-model ((provider base-provider))
  "获取默认模型"
  (base-provider-default-model provider))

;;; ============================================================
;;; 通用 HTTP 工具函数
;;; ============================================================

(defun build-api-url (provider endpoint)
  "构建完整的 API URL

参数：
  PROVIDER - 提供商实例
  ENDPOINT - 端点路径（如 \"/v1/messages\"）

返回：
  完整的 API URL 字符串

示例：
  (build-api-url provider \"/chat/completions\")
  => \"https://api.openai.com/v1/chat/completions\""
  (concatenate 'string
               (base-provider-api-url provider)
               endpoint))

;; 注：这里曾有 build-headers（硬编码 x-api-key 的"基础实现"），但无人
;; 调用——各 provider 都有自己的请求头构建（build-anthropic-headers /
;; provider-auth-headers），因为鉴权头各家不同。已删除。

(defun %error-node-message (node)
  "从一个已解析的错误对象里取出人类可读信息。

NODE 可能是 hash-table（{\"message\": ...}）或直接就是字符串
（Ollama 的 {\"error\": \"model not found\"}）。"
  (cond
    ((stringp node) node)
    ((hash-table-p node)
     (let ((message (or (gethash "message" node)
                        (gethash "msg" node)
                        (gethash "detail" node)))
           (code (or (gethash "code" node)
                     (gethash "type" node)
                     (gethash "status" node))))
       (cond
         ((and message code) (format nil "~A (~A)" message code))
         (message message)
         (code (format nil "~A" code))
         (t nil))))
    (t nil)))

(defun %ensure-error-body-string (body)
  "把响应体规范成字符串；无法规范时返回 NIL。

dexador 在 force-binary 或 http-request-failed 路径上可能给出
字节向量，直接 stringp 判断会让错误信息静默丢失。"
  (cond
    ((null body) nil)
    ((stringp body) body)
    ((and (vectorp body) (not (stringp body)))
     (handler-case (flexi-streams:octets-to-string
                    (coerce body '(vector (unsigned-byte 8)))
                    :external-format :utf-8)
       (error () nil)))
    (t nil)))

(defun extract-api-error-message (body)
  "从厂商错误响应体中提取可读信息；提取不出时返回 NIL。

各家错误体形状不同，但都收敛到「error 节点 / 顶层 message」两种：
  OpenAI 系   {\"error\": {\"message\": ..., \"type\": ...}}
  Anthropic   {\"type\": \"error\", \"error\": {\"type\": ..., \"message\": ...}}
  Google      {\"error\": {\"message\": ..., \"status\": ...}}
  DashScope   {\"code\": ..., \"message\": ...}
  Ollama      {\"error\": \"model not found\"}

对标 ai-sdk 各 provider 的 failedResponseHandler：把厂商说的话带出来。
此前这里只报「HTTP 请求失败: 400」，真正的原因（模型名拼错、
上下文超限、余额不足、参数不被该模型支持）全被丢在响应体里。"
  (let ((body (%ensure-error-body-string body)))
    (when (and body (string/= body ""))
      (let ((parsed (handler-case (cl-agent/core:json-parse body)
                      (error () nil))))
        (if (hash-table-p parsed)
            (or (%error-node-message (gethash "error" parsed))
                (%error-node-message parsed))
            ;; 非 JSON（网关返回的 HTML/纯文本）：截断后原样带出
            (let ((trimmed (string-trim '(#\Space #\Newline #\Tab #\Return) body)))
              (when (string/= trimmed "")
                (if (> (length trimmed) 300)
                    (concatenate 'string (subseq trimmed 0 300) "...")
                    trimmed))))))))

(defun make-http-request (url headers body &key (timeout 120))
  "发送 HTTP POST 请求

参数：
  URL     - 请求 URL
  HEADERS - 请求头（alist）
  BODY    - 请求体（JSON 字符串）
  TIMEOUT - 读取超时时间（秒，默认 120）

返回：
  响应体字符串

错误：
  如果请求失败，发出 cl-agent/core:llm-error——其 message 带上厂商
  错误体里的原因，response-body 保留原始响应体供上层排查。"
  (handler-case
      (let ((response (cl-agent/core:http-request url
                                                   :method :post
                                                   :body body
                                                   :headers headers
                                                   :timeout timeout
                                                   :parse-json nil)))
        (cl-agent/core:http-response-body response))
    ;; HTTP 错误
    (cl-agent/core:http-error (condition)
      (let* ((raw-body (cl-agent/core:http-error-body condition))
             (response-body (or (%ensure-error-body-string raw-body) raw-body))
             (detail (extract-api-error-message raw-body)))
        (cl-agent/core:signal-error
         'cl-agent/core:llm-error
         :message (format nil "HTTP 请求失败: ~A~@[ - ~A~]"
                          (cl-agent/core:http-error-status condition)
                          detail)
         :status-code (cl-agent/core:http-error-status condition)
         :response-body response-body
         :request-url url
         :cause condition)))
    ;; 其他错误
    (error (condition)
      (cl-agent/core:signal-error 'cl-agent/core:llm-error
                                  :message (format nil "请求错误: ~A" condition)
                                  :request-url url
                                  :cause condition))))

(defun parse-json-response (response)
  "解析 JSON 响应

参数：
  RESPONSE - 响应内容（字符串或已解析的对象）

返回：
  解析后的 Lisp 对象（plist 或 hash-table）

错误：
  如果解析失败，发出 cl-agent/core:llm-error"
  (handler-case
      (if (stringp response)
          (cl-agent/core:json-parse response)
          response)
    (error (condition)
      (cl-agent/core:signal-error 'cl-agent/core:llm-error
                                  :message (format nil "JSON 解析失败: ~A" condition)
                                  :cause condition))))

;;; ============================================================
;;; 错误处理说明
;;; ============================================================
;;;
;;; 错误条件已在 cl-agent/core 中统一定义：
;;;
;;;   - cl-agent/core:llm-error           - LLM 相关错误
;;;   - cl-agent/core:api-error           - API 调用错误
;;;   - cl-agent/core:missing-api-key-error - 缺少 API 密钥
;;;
;;; 错误信号函数：
;;;
;;;   - cl-agent/core:signal-error        - 通用错误信号
;;;
;;; 使用示例：
;;;
;;;   (cl-agent/core:signal-error 'cl-agent/core:llm-error
;;;                               :message "请求超时"
;;;                               :provider :openai
;;;                               :model "gpt-4o")
