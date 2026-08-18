;;;; dashscope.lisp
;;;; CL-Agent - 阿里云 DashScope 提供商实现
;;;;
;;;; 概述（命名与 clj-agent provider/dashscope.clj 一致）：
;;;;   实现阿里云百炼平台 DashScope 原生 API 的 LLM 提供商接口
;;;;
;;;; 支持的模型：
;;;;   - qwen-max / qwen-max-latest
;;;;   - qwen-plus / qwen-plus-latest
;;;;   - qwen-turbo / qwen-turbo-latest
;;;;   - qwen-long
;;;;   - qwen3-max / qwen3-max-preview
;;;;   - qwen3-plus / qwen3-plus-preview
;;;;   - qwen3-coder-plus / qwen3-coder-flash
;;;;
;;;; API 端点：
;;;;   - https://dashscope.aliyuncs.com/api/v1/services/aigc/text-generation/generation

(in-package :cl-agent.llm.providers)

;;; ============================================================
;;; DashScope 提供商类
;;; ============================================================

(defclass dashscope-provider (cl-agent.llm:base-provider)
  ((api-key :initarg :api-key
            :reader provider-api-key
            :documentation "DashScope API 密钥"))
  (:documentation "阿里云百炼 DashScope 提供商

支持通义千问 Qwen 系列模型，使用 DashScope 原生 API"))

;;; ============================================================
;;; 端点
;;; ============================================================

(defparameter +dashscope-text-endpoint+
  "/api/v1/services/aigc/text-generation/generation"
  "DashScope 原生文本生成端点")

(defparameter +dashscope-multimodal-endpoint+
  "/api/v1/services/aigc/multimodal-generation/generation"
  "DashScope 原生多模态生成端点（qwen-vl / qwen-audio 等）。

多模态与纯文本是**两个不同的端点**，且 content 形态也不同
（数组 vs 字符串）。把带附件的请求发去文本端点只会得到 400，
所以 llm-chat 按消息里有没有 :media 自动择路。")

(defparameter +dashscope-embedding-endpoint+
  "/api/v1/services/embeddings/text-embedding/text-embedding"
  "DashScope 原生嵌入端点")

;;; ============================================================
;;; 工厂函数
;;; ============================================================

(defun make-dashscope-provider (&key
                                 (api-url "https://dashscope.aliyuncs.com")
                                 (model "qwen-plus")
                                 api-key
                                 (timeout 120))
  "创建阿里云百炼 DashScope 提供商

参数：
  API-URL  - API 基础 URL（可选，默认阿里云）
  MODEL    - 默认模型（默认 qwen-plus）
  API-KEY  - API 密钥（可从 DASHSCOPE_API_KEY 或 BAILIAN_API_KEY 环境变量读取）
  TIMEOUT  - 请求超时时间（秒，默认 120）

返回：
  DashScope 提供商实例

示例：
  ;; 使用默认配置
  (make-dashscope-provider)

  ;; 指定模型
  (make-dashscope-provider :model \"qwen-max\")

  ;; 使用 qwen3 系列
  (make-dashscope-provider :model \"qwen3-max\")"
  (let ((key (or api-key
                 (uiop:getenv "DASHSCOPE_API_KEY")
                 (uiop:getenv "BAILIAN_API_KEY"))))
    (unless key
      (cl-agent.core:signal-error 'cl-agent.core:missing-api-key-error
                                  :message "DashScope API 密钥未设置，请设置 DASHSCOPE_API_KEY 或 BAILIAN_API_KEY 环境变量"
                                  :config-key "DASHSCOPE_API_KEY"))

    (make-instance 'dashscope-provider
                   :name :dashscope
                   :api-url api-url
                   :default-model model
                   :chat-endpoint +dashscope-text-endpoint+
                   :stream-endpoint +dashscope-text-endpoint+
                   :api-key key
                   :timeout timeout)))

;;; ============================================================
;;; 请求构建
;;; ============================================================

(defun messages-have-media-p (messages)
  "消息列表里是否含多模态附件"
  (some (lambda (msg) (and (listp msg) (getf msg :media))) messages))

(defun media-part-for-dashscope (media)
  "把一段中立 media plist 翻译为 DashScope 的 content 分片。

DashScope 的分片是单键对象，键即模态：
  {\"image\": \"https://... 或 data:image/png;base64,...\"}
  {\"audio\": \"...\"}
  {\"video\": \"...\"}
DashScope 接受 data: URI，所以图片/音频/视频统一走 media-neutral-data-uri。

纯文档（PDF）在 DashScope 属于另一套文件上传 API，不在多模态
generation 端点里，这里返回 NIL 跳过而不是发一个必然 400 的请求。"
  (let ((kind (or (getf media :kind) :image))
        (uri (cl-agent.core:media-neutral-data-uri media)))
    (when uri
      (let ((part (make-hash-table :test 'equal))
            (key (case kind
                   (:image "image")
                   (:audio "audio")
                   (:video "video")
                   (t nil))))
        (when key
          (setf (gethash key part) uri)
          part)))))

(defun build-dashscope-content-parts (content media)
  "把「文本 + 附件」构造成 DashScope 的 content 数组。

DashScope 的官方样例把附件排在文本之前，这里照此顺序。"
  (let ((parts nil))
    (dolist (m media)
      (let ((part (media-part-for-dashscope m)))
        (when part (push part parts))))
    (when (and content (stringp content) (string/= content ""))
      (let ((text-part (make-hash-table :test 'equal)))
        (setf (gethash "text" text-part) content)
        (push text-part parts)))
    (coerce (nreverse parts) 'vector)))

(defun build-dashscope-request (provider messages &key
                                                   max-tokens
                                                   temperature
                                                   model
                                                   tools)
  "构建 DashScope 原生 API 请求体

请求格式：
  {
    \"model\": \"qwen-plus\",
    \"input\": {
      \"messages\": [...]
    },
    \"parameters\": {
      \"result_format\": \"message\",
      \"temperature\": 0.7,
      \"max_tokens\": 2000
    }
  }"
  (let ((model-name (or model (cl-agent.llm:provider-default-model provider)))
        (body (make-hash-table :test 'equal))
        (input (make-hash-table :test 'equal))
        (parameters (make-hash-table :test 'equal)))
    ;; model
    (setf (gethash "model" body) model-name)

    ;; input.messages
    (setf (gethash "messages" input)
          (convert-messages-for-dashscope messages))
    (setf (gethash "input" body) input)

    ;; parameters
    ;; 多模态端点的响应恒为 message 形态，且不接受 result_format 参数
    (unless (messages-have-media-p messages)
      (setf (gethash "result_format" parameters) "message"))
    (when temperature
      (setf (gethash "temperature" parameters) temperature))
    (when max-tokens
      (setf (gethash "max_tokens" parameters) max-tokens))

    ;; tools (如果有)
    (when tools
      (setf (gethash "tools" parameters)
            (coerce (mapcar #'format-tool-for-dashscope tools) 'vector)))

    (setf (gethash "parameters" body) parameters)

    body))

(defun convert-messages-for-dashscope (messages)
  "转换消息为 DashScope 格式"
  (coerce
   (loop for msg in messages
         for role = (getf msg :role)
         for content = (getf msg :content)
         for media = (getf msg :media)
         for tool-calls = (getf msg :tool-calls)
         for tool-call-id = (getf msg :tool-call-id)
         for msg-hash = (make-hash-table :test 'equal)
         do (progn
              (setf (gethash "role" msg-hash)
                    (if (keywordp role)
                        (string-downcase (symbol-name role))
                        role))
              ;; 带附件的消息：content 升为分片数组；否则保持字符串
              (cond
                (media
                 (setf (gethash "content" msg-hash)
                       (build-dashscope-content-parts content media)))
                (content
                 (setf (gethash "content" msg-hash) content)))
              (when tool-calls
                (setf (gethash "tool_calls" msg-hash)
                      (convert-tool-calls-for-dashscope tool-calls)))
              (when tool-call-id
                (setf (gethash "tool_call_id" msg-hash) tool-call-id)))
         collect msg-hash)
   'vector))

(defun convert-tool-calls-for-dashscope (tool-calls)
  "转换工具调用为 DashScope 格式"
  (coerce
   (loop for tc in tool-calls
         for tc-hash = (make-hash-table :test 'equal)
         for fn-hash = (make-hash-table :test 'equal)
         do (progn
              (setf (gethash "id" tc-hash) (getf tc :id))
              (setf (gethash "type" tc-hash) "function")
              (setf (gethash "name" fn-hash)
                    (let ((name (getf tc :name)))
                      (if (keywordp name)
                          (string-downcase (symbol-name name))
                          name)))
              (setf (gethash "arguments" fn-hash) (getf tc :arguments))
              (setf (gethash "function" tc-hash) fn-hash))
         collect tc-hash)
   'vector))

(defun format-tool-for-dashscope (tool)
  "将工具格式化为 DashScope 格式"
  (let ((tool-hash (make-hash-table :test 'equal))
        (fn-hash (make-hash-table :test 'equal)))
    (setf (gethash "type" tool-hash) "function")
    (setf (gethash "name" fn-hash) (getf tool :name))
    (setf (gethash "description" fn-hash) (getf tool :description))
    (setf (gethash "parameters" fn-hash) (getf tool :parameters))
    (setf (gethash "function" tool-hash) fn-hash)
    tool-hash))

;;; ============================================================
;;; 响应解析
;;; ============================================================

(defun dashscope-content->text (content)
  "把 DashScope 的 message.content 归一为文本。

文本端点返回字符串；多模态端点返回分片数组
  [{\"text\": \"...\"}]
不归一的话，多模态回复的 content 会是一个 hash-table 向量，
一路漂到 llm-response-content，调用方拿到的不是字符串。"
  (cond
    ((null content) "")
    ((stringp content) content)
    ((vectorp content)
     (with-output-to-string (out)
       (loop for part across content
             do (let ((text (cond ((stringp part) part)
                                  ((hash-table-p part) (gethash "text" part))
                                  (t nil))))
                  (when (stringp text) (write-string text out))))))
    ((listp content)
     (dashscope-content->text (coerce content 'vector)))
    (t (format nil "~A" content))))

(defun parse-dashscope-response (response)
  "解析 DashScope 响应

响应格式：
  {
    \"output\": {
      \"choices\": [{
        \"message\": {
          \"content\": \"...\",
          \"role\": \"assistant\"
        },
        \"finish_reason\": \"stop\"
      }]
    },
    \"usage\": {
      \"total_tokens\": 21,
      \"output_tokens\": 11,
      \"input_tokens\": 10
    },
    \"request_id\": \"...\"
  }

返回统一的 llm-response 对象"
  (let* ((parsed (cl-agent.llm:parse-json-response response))
         (output (gethash "output" parsed))
         (choices (when output (gethash "choices" output)))
         (first-choice (when (and choices (plusp (length choices)))
                         (elt choices 0)))
         (message (when first-choice (gethash "message" first-choice)))
         (content (dashscope-content->text
                   (when message (gethash "content" message))))
         (tool-calls (when message (gethash "tool_calls" message)))
         (finish-reason (when first-choice (gethash "finish_reason" first-choice))))

    (cl-agent.core:make-llm-response
     :content (or content "")
     :tool-calls (when tool-calls
                   (parse-dashscope-tool-calls tool-calls))
     :usage (cl-agent.core:normalize-usage (gethash "usage" parsed))
     :model (gethash "model" parsed)
     :finish-reason (cl-agent.core:normalize-finish-reason finish-reason)
     :message-id (gethash "request_id" parsed)
     :raw-response parsed)))

(defun parse-dashscope-tool-calls (tool-calls)
  "解析 DashScope 工具调用"
  (loop for call in (if (vectorp tool-calls)
                        (coerce tool-calls 'list)
                        tool-calls)
        for id = (gethash "id" call)
        for function = (gethash "function" call)
        for name = (when function (gethash "name" function))
        for arguments = (when function (gethash "arguments" function))
        collect (list :id id
                      :name (when name (make-keyword (string-downcase name)))
                      :arguments arguments
                      :raw call)))

;;; ============================================================
;;; 协议实现
;;; ============================================================

(defmethod cl-agent.llm:llm-chat ((provider dashscope-provider) messages
                                   &key
                                   max-tokens
                                   ;; NIL 时不下发（SPI「存在才发送」契约）
                                   temperature
                                   model
                                   tools
                                   system
                                   &allow-other-keys)
  "发送聊天请求到 DashScope

参数：
  PROVIDER      - DashScope 提供商实例
  MESSAGES      - 消息列表
  MAX-TOKENS    - 最大 token 数（可选）
  TEMPERATURE   - 温度参数（可选，默认 0.7）
  MODEL         - 模型名称（可选）
  TOOLS         - 工具列表（可选）
  SYSTEM        - 系统提示（可选）

返回：
  响应 plist"
  (declare (ignore system))
  (let* (;; 构建请求体
         (request-body (build-dashscope-request
                        provider
                        messages
                        :max-tokens max-tokens
                        :temperature temperature
                        :model model
                        :tools tools))
         ;; 构建 URL：带附件的请求走多模态端点（两个端点不通用）
         (url (cl-agent.llm:build-api-url
               provider
               (if (messages-have-media-p messages)
                   +dashscope-multimodal-endpoint+
                   (cl-agent.llm:provider-chat-endpoint provider))))
         ;; 使用 Bearer Token 认证
         (headers (build-bearer-auth-headers provider))
         ;; 发送请求
         (response (cl-agent.llm:make-http-request
                    url
                    headers
                    (cl-agent.core:json-stringify request-body)
                    :timeout (cl-agent.llm:provider-timeout provider))))
    ;; 解析响应
    (parse-dashscope-response response)))

(defmethod cl-agent.llm:llm-available-p ((provider dashscope-provider))
  "检查 DashScope 提供商是否可用"
  (and (slot-boundp provider 'api-key)
       (provider-api-key provider)
       (not (string= (provider-api-key provider) ""))))

;;; ============================================================
;;; 辅助函数
;;; ============================================================

(defun dashscope-list-models ()
  "列出 DashScope 支持的主要模型"
  '(;; Qwen Max 系列
    "qwen-max" "qwen-max-latest"
    "qwen3-max" "qwen3-max-preview"
    ;; Qwen Plus 系列
    "qwen-plus" "qwen-plus-latest"
    "qwen3-plus" "qwen3-plus-preview"
    ;; Qwen Turbo 系列
    "qwen-turbo" "qwen-turbo-latest"
    ;; Qwen Long（长文本）
    "qwen-long"
    ;; Qwen Coder 系列
    "qwen3-coder-plus" "qwen3-coder-flash"
    ;; 视觉模型
    "qwen-vl-max" "qwen-vl-plus"))
