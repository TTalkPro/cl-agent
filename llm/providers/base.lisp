;;;; base.lisp
;;;; CL-Agent - LLM 提供商基类
;;;;
;;;; 概述：
;;;;   定义 LLM 提供商的基类和通用功能
;;;;
;;;; 设计原则：
;;;;   - 所有提供商继承 base-provider 类
;;;;   - 提供统一的 CLOS 接口
;;;;   - 错误处理使用 cl-agent.core 中的条件
;;;;
;;;; 使用示例：
;;;;   ;; 定义新的提供商
;;;;   (defclass my-provider (base-provider)
;;;;     ((api-key :initarg :api-key :reader my-provider-api-key)))
;;;;
;;;;   ;; 实现 llm-chat 方法
;;;;   (defmethod llm-chat ((provider my-provider) messages &key ...)
;;;;     ...)

(in-package :cl-agent.llm)

;;; ============================================================
;;; 提供商基类
;;; ============================================================

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

;;; llm-chat 泛型函数现定义在 cl-agent.kernel 包中（core/kernel/kernel.lisp）
;;; cl-agent.llm 包通过 :import-from 导入并重导出该符号

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

(defun build-headers (provider api-key &key extra-headers)
  "构建请求头

参数：
  PROVIDER      - 提供商实例
  API-KEY       - API 密钥
  EXTRA-HEADERS - 额外的请求头（可选，alist 格式）

返回：
  请求头 alist

说明：
  这是一个基础实现，各提供商通常需要自己的请求头构建函数"
  (declare (ignore provider))
  (let ((base-headers `(("Content-Type" . "application/json")
                        ("x-api-key" . ,api-key))))
    (append base-headers extra-headers)))

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
  如果请求失败，发出 cl-agent.core:llm-error"
  (handler-case
      (let ((response (cl-agent.http:http-request url
                                                   :method :post
                                                   :body body
                                                   :headers headers
                                                   :timeout timeout
                                                   :parse-json nil)))
        (cl-agent.http:http-response-body response))
    ;; HTTP 错误
    (cl-agent.http:http-error (condition)
      (cl-agent.core:signal-error 'cl-agent.core:llm-error
                                  :message (format nil "HTTP 请求失败: ~A"
                                                   (cl-agent.http:http-error-status condition))
                                  :status-code (cl-agent.http:http-error-status condition)
                                  :request-url url
                                  :cause condition))
    ;; 其他错误
    (error (condition)
      (cl-agent.core:signal-error 'cl-agent.core:llm-error
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
  如果解析失败，发出 cl-agent.core:llm-error"
  (handler-case
      (if (stringp response)
          (cl-agent.core:json-parse response)
          response)
    (error (condition)
      (cl-agent.core:signal-error 'cl-agent.core:llm-error
                                  :message (format nil "JSON 解析失败: ~A" condition)
                                  :cause condition))))

;;; ============================================================
;;; 错误处理说明
;;; ============================================================
;;;
;;; 错误条件已在 cl-agent.core 中统一定义：
;;;
;;;   - cl-agent.core:llm-error           - LLM 相关错误
;;;   - cl-agent.core:api-error           - API 调用错误
;;;   - cl-agent.core:missing-api-key-error - 缺少 API 密钥
;;;
;;; 错误信号函数：
;;;
;;;   - cl-agent.core:signal-error        - 通用错误信号
;;;   - cl-agent.core:signal-llm-error    - LLM 错误信号
;;;
;;; 使用示例：
;;;
;;;   (cl-agent.core:signal-error 'cl-agent.core:llm-error
;;;                               :message "请求超时"
;;;                               :provider :openai
;;;                               :model "gpt-4o")
;;;
;;;   (cl-agent.core:signal-llm-error :openai "gpt-4o"
;;;                                   :message "API 调用失败"
;;;                                   :status-code 429)
