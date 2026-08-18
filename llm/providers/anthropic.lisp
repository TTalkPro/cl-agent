;;;; anthropic.lisp
;;;; CL-Agent - Anthropic Claude 提供商实现
;;;;
;;;; 概述：
;;;;   实现 Anthropic Claude 系列的 LLM 提供商接口
;;;;
;;;; 支持的模型：
;;;;   - claude-sonnet-4-20250514 (Claude Sonnet 4)
;;;;   - claude-3-5-sonnet-20241022 (Claude 3.5 Sonnet)
;;;;   - claude-3-5-haiku-20241022 (Claude 3.5 Haiku)
;;;;   - claude-3-opus-20240229 (Claude 3 Opus)
;;;;
;;;; API 特点：
;;;;   - 使用 x-api-key 请求头认证
;;;;   - 需要 anthropic-version 请求头
;;;;   - max_tokens 是必需参数
;;;;   - system 消息单独传递，不在 messages 数组中

(in-package :cl-agent.llm.providers)

;;; ============================================================
;;; Anthropic 提供商类
;;; ============================================================

(defclass anthropic-provider (cl-agent.llm:base-provider)
  ((api-key :initarg :api-key
            :reader anthropic-provider-api-key
            ;; 同时实现 cl-agent.core:provider-api-key 协议——调用方（如
            ;; make-client）据此统一向 provider 取 key，无需再维护一张
            ;; 「provider → 环境变量名」的手写表。openai-compat 系早已用
            ;; :accessor provider-api-key 实现了它，此前只有 Anthropic 系
            ;; （含 minimax）缺席，于是它们在 make-client 里取不到 key。
            :reader cl-agent.core:provider-api-key
            :documentation "Anthropic API 密钥")
   (anthropic-version :initarg :anthropic-version
                      :initform "2023-06-01"
                      :reader anthropic-provider-version
                      :documentation "Anthropic API 版本"))
  (:documentation "Anthropic Claude 提供商

支持 Claude 系列模型，包括 Claude Sonnet 4、Claude 3.5 和 Claude 3"))

;;; ============================================================
;;; 工厂函数
;;; ============================================================

(defun make-anthropic-provider (&key
                                  (api-url "https://api.anthropic.com")
                                  (model "claude-sonnet-4-20250514")
                                  api-key
                                  (anthropic-version "2023-06-01")
                                  (timeout 120))
  "创建 Anthropic 提供商

参数：
  API-URL           - API 基础 URL（可选，默认官方 API）
  MODEL             - 默认模型（可选，默认 claude-sonnet-4-20250514）
  API-KEY           - API 密钥（可选，从环境变量读取）
  ANTHROPIC-VERSION - API 版本（可选，默认 2023-06-01）
  TIMEOUT           - 请求超时时间（可选，默认 120 秒）

返回：
  Anthropic 提供商实例

示例：
  ;; 使用默认配置
  (make-anthropic-provider)

  ;; 指定模型和 API 密钥
  (make-anthropic-provider :model \"claude-3-5-sonnet-20241022\"
                           :api-key \"sk-ant-...\")

  ;; 使用较新的 API 版本
  (make-anthropic-provider :anthropic-version \"2024-01-01\")"

  ;; 获取 API 密钥
  (let ((key (or api-key
                 (uiop:getenv "ANTHROPIC_API_KEY"))))
    (when (null key)
      (cl-agent.core:signal-error 'cl-agent.core:missing-api-key-error
                                  :message "Anthropic API 密钥未设置，请设置 ANTHROPIC_API_KEY 环境变量"
                                  :config-key "ANTHROPIC_API_KEY"))

    (make-instance 'anthropic-provider
                   :name :anthropic
                   :api-url api-url
                   :default-model model
                   :chat-endpoint "/v1/messages"
                   :stream-endpoint "/v1/messages"
                   :api-key key
                   :anthropic-version anthropic-version
                   :timeout timeout)))

;;; ============================================================
;;; 协议实现
;;; ============================================================

(defmethod cl-agent.llm:llm-chat ((provider anthropic-provider) messages
                                   &key
                                   (max-tokens 4096)
                                   temperature
                                   model
                                   tools
                                   system
                                   top-p
                                   top-k
                                   stop
                                   thinking
                                   extra-params
                                   &allow-other-keys)
  "发送聊天请求到 Anthropic

参数：
  PROVIDER    - Anthropic 提供商实例
  MESSAGES    - 消息列表
  MAX-TOKENS  - 最大 token 数（Anthropic 强制要求该字段，故默认 4096）
  TEMPERATURE - 温度参数（可选；NIL 时不下发，用服务端默认）
  MODEL       - 模型名称（可选）
  TOOLS       - 工具列表（可选）
  SYSTEM      - 系统提示（可选）

返回：
  响应 plist

注：除 MAX-TOKENS 外的可选参数遵循 SPI 的「存在才发送」契约——
NIL 表示不下发该字段。TEMPERATURE 此前默认 0.7，违反该契约：
调用方即使不设置温度也会被发出 temperature=0.7。这不只是语义问题，
按 Anthropic 官方文档会直接坏在两处：

  1. temperature / top_p / top_k 在 Claude Opus 4.7 及以后（含 4.8）
     不受支持，设为非默认值返回 400。文档原文要求「omit them from
     request payloads」——自动注入 0.7 等于让这些模型完全不可用。
  2. Claude 4.1 Opus / 4.5 Sonnet 起，temperature 与 top_p 不能同时
     指定，否则 400「temperature and top_p cannot both be specified」。
     调用方只要传 :top-p，就会被这个默认值连坐。

参见 https://platform.claude.com/docs/en/build-with-claude/working-with-messages"

  ;; 1. 构建请求体
  (let* ((request-body (build-anthropic-request-body
                        provider
                        messages
                        :max-tokens max-tokens
                        :temperature temperature
                        :model model
                        :tools tools
                        :system system
                        :top-p top-p
                        :top-k top-k
                        :stop stop
                        :thinking thinking
                        :extra-params extra-params))

         ;; 2. 构建 URL
         (url (cl-agent.llm:build-api-url
              provider
              (cl-agent.llm:base-provider-chat-endpoint provider)))

         ;; 3. 构建请求头
         (headers (build-anthropic-headers provider))

         ;; 4. 发送请求
         (response (cl-agent.llm:make-http-request
                    url
                    headers
                    (cl-agent.core:json-stringify request-body)
                    :timeout (cl-agent.llm:base-provider-timeout provider))))

    ;; 5. 解析响应
    (parse-anthropic-response response)))

(defmethod cl-agent.llm:llm-available-p ((provider anthropic-provider))
  "检查 Anthropic 提供商是否可用"
  (and (slot-boundp provider 'api-key)
       (anthropic-provider-api-key provider)
       (not (string= (anthropic-provider-api-key provider) ""))))

;;; ============================================================
;;; 请求构建
;;; ============================================================

(define-condition invalid-thinking-config-error (error)
  ((detail :initarg :detail :reader invalid-thinking-config-detail))
  (:report (lambda (condition stream)
             (format stream "扩展思考配置非法：~A" (invalid-thinking-config-detail condition))))
  (:documentation "thinking 配置不符合 Anthropic 规格。

宁可在构建请求时报出可定位的错误，也不要把非法配置发出去换一个
裸 400（Anthropic 对 budget_tokens 的约束不会告诉你是哪一条违反了）。"))

(defun thinking->anthropic (spec max-tokens)
  "把中立的 thinking 规格翻译为 Anthropic wire 格式的 hash-table。

规格（对标 ThinkingConfigParam 的三个变体）：
  :disabled                                   → {\"type\":\"disabled\"}
  :adaptive                                   → {\"type\":\"adaptive\"}
  (:adaptive :display :omitted)               → + \"display\"
  (:enabled :budget-tokens N)                 → {\"type\":\"enabled\",\"budget_tokens\":N}
  (:enabled :budget-tokens N :display :omitted)
  hash-table                                  → 原样返回（逃生通道）

约束（来自官方文档，此处提前校验）：
  budget_tokens 必须 ≥1024 且 < max_tokens——思考计入 max_tokens。"
  (flet ((fail (fmt &rest args)
           (error 'invalid-thinking-config-error
                  :detail (apply #'format nil fmt args)))
         (display->wire (display)
           (when display
             (unless (member display '(:summarized :omitted))
               (error 'invalid-thinking-config-error
                      :detail (format nil ":display 只能是 :summarized 或 :omitted，实际为 ~S"
                                      display)))
             (string-downcase (symbol-name display)))))
    (let ((body (make-hash-table :test 'equal)))
      (etypecase spec
        ;; 逃生通道：调用方自己按 wire 格式给全，原样下发
        (hash-table spec)
        (keyword
         (ecase spec
           (:disabled (setf (gethash "type" body) "disabled"))
           (:adaptive (setf (gethash "type" body) "adaptive"))
           (:enabled (fail ":enabled 必须给出预算，写成 (:enabled :budget-tokens N)")))
         body)
        (cons
         (destructuring-bind (kind &key budget-tokens display) spec
           (ecase kind
             (:disabled (setf (gethash "type" body) "disabled"))
             (:adaptive
              (setf (gethash "type" body) "adaptive")
              (let ((d (display->wire display)))
                (when d (setf (gethash "display" body) d))))
             (:enabled
              (unless (integerp budget-tokens)
                (fail ":enabled 需要 :budget-tokens（整数），实际为 ~S" budget-tokens))
              (when (< budget-tokens 1024)
                (fail "budget-tokens 须 ≥1024，实际为 ~A" budget-tokens))
              (when (and (integerp max-tokens) (>= budget-tokens max-tokens))
                (fail "budget-tokens (~A) 须小于 max-tokens (~A)——思考计入 max-tokens"
                      budget-tokens max-tokens))
              (setf (gethash "type" body) "enabled")
              (setf (gethash "budget_tokens" body) budget-tokens)
              (let ((d (display->wire display)))
                (when d (setf (gethash "display" body) d)))))
           body))))))

(defun build-anthropic-request-body (provider messages &key
                                               max-tokens
                                               temperature
                                               model
                                               tools
                                               system
                                               top-p
                                               top-k
                                               stop
                                               thinking
                                               extra-params)
  "构建 Anthropic API 请求体

参数：
  PROVIDER    - 提供商实例
  MESSAGES    - 消息列表
  MAX-TOKENS  - 最大 token 数（必需）
  TEMPERATURE - 温度
  MODEL       - 模型名称
  TOOLS       - 工具列表
  SYSTEM      - 系统提示
  TOP-P       - 核采样（存在才发送）
  TOP-K       - Top-K 采样（存在才发送）
  STOP        - 停止序列（wire 字段 stop_sequences，存在才发送）
  EXTRA-PARAMS - 厂商专有参数 plist（直接并入请求体顶层）

返回：
  请求体 hash-table（JSON 格式）"

  (let* ((model-name (or model (cl-agent.llm:base-provider-default-model provider)))
         ;; 分离系统消息和其他消息
         (parsed-messages (parse-messages-for-anthropic messages))
         (system-prompt (or system (getf parsed-messages :system)))
         (converted-messages (getf parsed-messages :messages))
         (body (make-hash-table :test 'equal)))

    ;; 构建基础请求体
    (setf (gethash "model" body) model-name)
    (setf (gethash "max_tokens" body) max-tokens)
    (setf (gethash "messages" body) (coerce converted-messages 'vector))

    ;; 添加 temperature
    (when temperature
      (setf (gethash "temperature" body) temperature))

    ;; 添加系统提示（Anthropic 使用单独的 system 参数）
    (when system-prompt
      (setf (gethash "system" body) system-prompt))

    ;; 添加工具
    (when tools
      (setf (gethash "tools" body) (coerce (convert-tools-to-anthropic tools) 'vector)))

    ;; 采样与停止序列（存在才发送）
    (when top-p
      (setf (gethash "top_p" body) top-p))
    (when top-k
      (setf (gethash "top_k" body) top-k))
    (when stop
      (setf (gethash "stop_sequences" body)
            (if (listp stop) (coerce stop 'vector) stop)))

    ;; 扩展思考（存在才发送）
    (when thinking
      (setf (gethash "thinking" body) (thinking->anthropic thinking max-tokens)))

    ;; 厂商专有参数逃生通道：最后并入，可覆盖任何字段
    (when extra-params
      (loop for (key value) on extra-params by #'cddr
            do (setf (gethash (if (stringp key)
                                  key
                                  (substitute #\_ #\-
                                              (string-downcase (string key))))
                              body)
                     value)))

    body))

(defun media-block-for-anthropic (media)
  "把一段中立 media plist 翻译为 Anthropic 的 content 块（hash-table）。

Anthropic 的块形态：
  图片  {\"type\":\"image\",   \"source\":{...}}
  文档  {\"type\":\"document\",\"source\":{...}}
  source 有两种：
    {\"type\":\"base64\",\"media_type\":\"image/png\",\"data\":\"<base64>\"}
    {\"type\":\"url\",\"url\":\"https://...\"}

Anthropic 的 Messages API 不接受音频/视频输入，这两类返回 NIL 跳过——
把它们塞进请求只会换来一个 400。"
  (let ((kind (or (getf media :kind) :image))
        (url (getf media :url))
        (block-hash (make-hash-table :test 'equal))
        (source (make-hash-table :test 'equal)))
    (when (member kind '(:image :document))
      (cond
        ;; 远程 URL 直接交给 Anthropic 去取
        ((and url (not (eql 0 (search "data:" url))))
         (setf (gethash "type" source) "url")
         (setf (gethash "url" source) url))
        (t
         (let ((b64 (cl-agent.core:media-neutral-base64 media)))
           ;; 调用方给的 data: URI：剥掉前缀，取出裸 base64
           (when (and (null b64) url)
             (let ((comma (position #\, url)))
               (when comma (setf b64 (subseq url (1+ comma))))))
           (when b64
             (setf (gethash "type" source) "base64")
             (setf (gethash "media_type" source)
                   (or (getf media :media-type)
                       (if (eq kind :image) "image/png" "application/pdf")))
             (setf (gethash "data" source) b64)))))
      (when (plusp (hash-table-count source))
        (setf (gethash "type" block-hash)
              (if (eq kind :image) "image" "document"))
        (setf (gethash "source" block-hash) source)
        block-hash))))

(defun build-anthropic-content-blocks (text media)
  "把「文本 + 附件」构造成 Anthropic 的 content 块数组（vector）。

顺序与 OpenAI 侧一致：文本在前、附件在后；文本为空时不发文本块。"
  (let ((blocks nil))
    (when (and text (stringp text) (string/= text ""))
      (let ((text-block (make-hash-table :test 'equal)))
        (setf (gethash "type" text-block) "text")
        (setf (gethash "text" text-block) text)
        (push text-block blocks)))
    (dolist (m media)
      (let ((block-hash (media-block-for-anthropic m)))
        (when block-hash (push block-hash blocks))))
    (coerce (nreverse blocks) 'vector)))

(defun parse-messages-for-anthropic (messages)
  "解析消息，分离系统消息，处理工具调用消息

参数：
  MESSAGES - 消息列表

返回：
  plist 包含 :system 和 :messages

说明：
  处理以下消息格式：
  1. 普通消息：(:role :user :content \"...\")
  2. assistant 工具调用：(:role :assistant :content \"...\" :tool-calls (...))
  3. 工具结果：(:role :tool :tool-call-id \"...\" :content \"...\")

  Anthropic API 要求：
  - assistant 工具调用消息的 content 为 tool_use 块数组
  - 工具结果作为 user 消息的 tool_result 块发送"
  (let ((system-prompt nil)
        (other-messages '())
        ;; 收集连续的 tool result 消息，合并为一个 user 消息
        (pending-tool-results nil))

    (labels ((flush-tool-results ()
               "将累积的 tool results 合并为一个 user 消息"
               (when pending-tool-results
                 (let ((msg-hash (make-hash-table :test 'equal))
                       (content-blocks
                         (mapcar (lambda (tr)
                                   (let ((block (make-hash-table :test 'equal)))
                                     (setf (gethash "type" block) "tool_result")
                                     (setf (gethash "tool_use_id" block) (getf tr :tool-call-id))
                                     (setf (gethash "content" block) (or (getf tr :content) ""))
                                     block))
                                 (nreverse pending-tool-results))))
                   (setf (gethash "role" msg-hash) "user")
                   (setf (gethash "content" msg-hash)
                         (coerce content-blocks 'vector))
                   (push msg-hash other-messages))
                 (setf pending-tool-results nil)))

             (build-tool-use-content (tool-calls text-content reasoning-blocks)
               "构建包含 tool_use 块的 content 数组"
               (let ((blocks nil))
                 ;; thinking 块必须排在最前：Anthropic 要求扩展思考的
                 ;; assistant 轮以 thinking 块开头，且在工具调用对话中连同
                 ;; signature 原样回传，否则请求被拒。块由 provider 原样
                 ;; 保留（见 extract-thinking-blocks / rebuild-thinking-block），
                 ;; 此处不重建、不改写。
                 (dolist (block reasoning-blocks)
                   (push block blocks))
                 ;; 添加文本块（如果有）
                 (when (and text-content (not (string= text-content "")))
                   (let ((text-block (make-hash-table :test 'equal)))
                     (setf (gethash "type" text-block) "text")
                     (setf (gethash "text" text-block) text-content)
                     (push text-block blocks)))
                 ;; 添加 tool_use 块
                 (dolist (tc tool-calls)
                   (let ((tc-block (make-hash-table :test 'equal))
                         (tc-name (getf tc :name))
                         (tc-id (getf tc :id))
                         (tc-args (getf tc :arguments)))
                     (setf (gethash "type" tc-block) "tool_use")
                     (setf (gethash "id" tc-block) (or tc-id (cl-agent.core:generate-uuid)))
                     (setf (gethash "name" tc-block)
                           (if (keywordp tc-name)
                               (string-downcase (symbol-name tc-name))
                               (string-downcase (string tc-name))))
                     (setf (gethash "input" tc-block)
                           (cond
                             ((hash-table-p tc-args) tc-args)
                             ((and (listp tc-args) (keywordp (first tc-args)))
                              ;; plist → hash-table
                              (let ((ht (make-hash-table :test 'equal)))
                                (loop for (k v) on tc-args by #'cddr
                                      do (setf (gethash (string-downcase (symbol-name k)) ht) v))
                                ht))
                             (t (make-hash-table :test 'equal))))
                     (push tc-block blocks)))
                 (coerce (nreverse blocks) 'vector))))

      (dolist (msg messages)
        (let ((role (if (and (consp msg) (not (consp (cdr msg))))
                        (car msg)
                        (getf msg :role)))
              (content (if (and (consp msg) (not (consp (cdr msg))))
                           (cdr msg)
                           (getf msg :content)))
              (tool-calls (when (consp (cdr msg)) (getf msg :tool-calls)))
              (tool-call-id (when (consp (cdr msg)) (getf msg :tool-call-id)))
              ;; 多模态附件（中立 media plist 列表）
              (media (when (consp (cdr msg)) (getf msg :media)))
              ;; provider 原生推理块（含 signature），由 message->neutral 带过来
              (reasoning-blocks (when (consp (cdr msg))
                                  (getf msg :reasoning-blocks))))
          (cond
            ;; 系统消息
            ((member role '(:system "system" system) :test #'equalp)
             (flush-tool-results)
             (if system-prompt
                 (setf system-prompt (concatenate 'string system-prompt "\n"
                                                  (if (stringp content) content "")))
                 (setf system-prompt (if (stringp content) content ""))))

            ;; 工具结果消息 → 累积后合并发送
            ((member role '(:tool "tool" tool) :test #'equalp)
             (push (list :tool-call-id (or tool-call-id "unknown")
                         :content (if (stringp content) content
                                      (format nil "~S" content)))
                   pending-tool-results))

            ;; assistant 带 tool-calls
            ((and (member role '(:assistant "assistant" assistant) :test #'equalp)
                  tool-calls)
             (flush-tool-results)
             (let ((msg-hash (make-hash-table :test 'equal)))
               (setf (gethash "role" msg-hash) "assistant")
               (setf (gethash "content" msg-hash)
                     (build-tool-use-content tool-calls
                                             (if (stringp content) content "")
                                             reasoning-blocks))
               (push msg-hash other-messages)))

            ;; 普通消息
            (t
             (flush-tool-results)
             (let ((msg-hash (make-hash-table :test 'equal)))
               (setf (gethash "role" msg-hash) (convert-role-to-anthropic role))
               (setf (gethash "content" msg-hash)
                     (cond
                       ;; 带附件：content 升为块数组（文本块 + 媒体块）
                       (media
                        (build-anthropic-content-blocks
                         (if (stringp content) content "") media))
                       ((stringp content) content)
                       (t (format nil "~S" content))))
               (push msg-hash other-messages))))))

      ;; 刷新剩余的 tool results
      (flush-tool-results))

    (list :system system-prompt
          :messages (nreverse other-messages))))

(defun convert-role-to-anthropic (role)
  "转换角色为 Anthropic 格式

参数：
  ROLE - 角色标识（关键字或字符串）

返回：
  Anthropic 格式的角色字符串"
  (let ((role-str (string-downcase (string role))))
    (cond
      ((string= role-str "user") "user")
      ((string= role-str "assistant") "assistant")
      ((string= role-str "human") "user")
      ((string= role-str "ai") "assistant")
      (t "user"))))

(defun convert-tools-to-anthropic (tools)
  "转换工具为 Anthropic 格式

参数：
  TOOLS - 工具列表（每个工具为 plist: (:name ... :description ... :input-schema ...)）

返回：
  Anthropic 格式的工具列表（hash-table list）

说明：
  Anthropic 工具格式：
  {
    \"name\": \"tool_name\",
    \"description\": \"Tool description\",
    \"input_schema\": {
      \"type\": \"object\",
      \"properties\": {...},
      \"required\": [...]
    }
  }"
  (loop for tool in tools
        collect (let ((tool-hash (make-hash-table :test 'equal))
                      (schema-raw (or (getf tool :input-schema)
                                      (getf tool :parameters))))
                  (setf (gethash "name" tool-hash) (getf tool :name))
                  (setf (gethash "description" tool-hash) (getf tool :description))
                  (setf (gethash "input_schema" tool-hash)
                        (cond
                          ;; 已经是 hash-table（可直接序列化）
                          ((hash-table-p schema-raw) schema-raw)
                          ;; plist schema（来自 params->json-schema）→ 转换为 hash-table
                          ((and (consp schema-raw) (keywordp (first schema-raw)))
                           (cl-agent.core:schema-to-hash-table schema-raw))
                          ;; 默认空 schema
                          (t (let ((default-schema (make-hash-table :test 'equal)))
                               (setf (gethash "type" default-schema) "object")
                               (setf (gethash "properties" default-schema) (make-hash-table :test 'equal))
                               (setf (gethash "required" default-schema) #())
                               default-schema))))
                  tool-hash)))

(defgeneric build-anthropic-headers (provider)
  (:documentation "构建 Anthropic 格式端点的请求头（alist）。

CLOS 扩展点：Anthropic 兼容厂商（如 MiniMax）通过特化本泛型函数
切换鉴权方案（Bearer 等），复用其余全部请求/响应实现。"))

(defmethod build-anthropic-headers ((provider anthropic-provider))
  "标准 Anthropic：x-api-key + anthropic-version 请求头"
  (let ((api-key (anthropic-provider-api-key provider))
        (version (anthropic-provider-version provider)))
    `(("Content-Type" . "application/json")
      ("x-api-key" . ,api-key)
      ("anthropic-version" . ,version))))
;;; ============================================================
;;; 响应解析
;;; ============================================================

(defun parse-anthropic-response (response)
  "解析 Anthropic API 响应

参数：
  RESPONSE - HTTP 响应

返回：
  llm-response 对象

说明：
  Anthropic 响应格式：
  {
    \"id\": \"msg_...\",
    \"type\": \"message\",
    \"role\": \"assistant\",
    \"content\": [{\"type\": \"text\", \"text\": \"...\"}],
    \"model\": \"claude-...\",
    \"stop_reason\": \"end_turn\",
    \"usage\": {
      \"input_tokens\": N,
      \"output_tokens\": N
    }
  }"

  (let* ((parsed (cl-agent.llm:parse-json-response response))
         ;; 从 hash-table 中提取值（使用字符串键）
         (content-blocks (if (hash-table-p parsed)
                             (gethash "content" parsed)
                             (getf parsed :content)))
         (content (extract-text-content content-blocks))
         (tool-use (extract-tool-use content-blocks))
         (reasoning (extract-thinking-content content-blocks))
         (reasoning-blocks (extract-thinking-blocks content-blocks))
         (usage (if (hash-table-p parsed)
                    (gethash "usage" parsed)
                    (getf parsed :usage)))
         (stop-reason (if (hash-table-p parsed)
                          (gethash "stop_reason" parsed)
                          (getf parsed :stop_reason)))
         (model-name (if (hash-table-p parsed)
                         (gethash "model" parsed)
                         (getf parsed :model)))
         (message-id (if (hash-table-p parsed)
                         (gethash "id" parsed)
                         (getf parsed :id))))

    ;; 构建 llm-response 对象
    ;; usage 走 cl-agent.core:normalize-usage（含 cache_read/cache_creation 字段）
    (cl-agent.core:make-llm-response
     :content content
     :tool-calls (when tool-use
                   (parse-anthropic-tool-use tool-use))
     :usage (cl-agent.core:normalize-usage usage)
     :model model-name
     :finish-reason (cl-agent.core:normalize-finish-reason stop-reason)
     :reasoning reasoning
     :reasoning-blocks reasoning-blocks
     :message-id message-id
     :raw-response parsed)))

(defun content-blocks->list (content-blocks)
  "把 Anthropic 内容块归一化为 list（可能是 vector 或 list）"
  (cond
    ((vectorp content-blocks) (coerce content-blocks 'list))
    ((listp content-blocks) content-blocks)
    (t nil)))

(defun extract-thinking-content (content-blocks)
  "提取 Anthropic thinking blocks（扩展思考）为 reasoning 字符串。

参数：
  CONTENT-BLOCKS - Anthropic 内容块（vector 或 list）

返回：
  拼接的 thinking 文本，没有则 NIL"
  (let ((thinking nil))
    (dolist (block (content-blocks->list content-blocks))
      (when (and (hash-table-p block)
                 (equal (gethash "type" block) "thinking"))
        (push (gethash "thinking" block) thinking)))
    (when thinking
      (format nil "~{~A~^~%~}" (nreverse thinking)))))

(defun extract-thinking-blocks (content-blocks)
  "原样保留 thinking / redacted_thinking 块，供后续轮次回传。

与 extract-thinking-content 的区别：那个函数只取思考*文本*，
丢掉了 signature。而 Anthropic 要求工具调用对话的 assistant 轮
必须把 thinking 块连同 signature 一起原样回传，仅凭文本无法重建。

redacted_thinking 块（内容被加密）同样必须回传，故一并保留。

返回：
  hash-table 块的列表（保持原顺序），没有则 NIL"
  (remove-if-not
   (lambda (block)
     (and (hash-table-p block)
          (member (gethash "type" block) '("thinking" "redacted_thinking")
                  :test #'equal)))
   (content-blocks->list content-blocks)))

(defun extract-text-content (content-blocks)
  "从内容块中提取文本

参数：
  CONTENT-BLOCKS - Anthropic 内容块列表（vector、list、hash-table 或 string）

返回：
  文本字符串"
  ;; 处理各种可能的格式
  (cond
    ;; nil
    ((null content-blocks) "")

    ;; 直接是字符串
    ((stringp content-blocks) content-blocks)

    ;; 单个 hash-table（单个内容块）
    ((hash-table-p content-blocks)
     (let ((type (gethash "type" content-blocks))
           (text (gethash "text" content-blocks)))
       (if (string= type "text")
           (or text "")
           "")))

    ;; vector 或 list
    (t
     (let ((texts '())
           (blocks (if (vectorp content-blocks)
                       (coerce content-blocks 'list)
                       content-blocks)))
       (dolist (block blocks)
         (let ((type (if (hash-table-p block)
                         (gethash "type" block)
                         (getf block :type)))
               (text (if (hash-table-p block)
                         (gethash "text" block)
                         (getf block :text))))
           (when (and type (string= type "text"))
             (push text texts))))
       (if (= (length texts) 1)
           (first texts)
           (format nil "~{~A~^~%~}" (nreverse texts)))))))

(defun extract-tool-use (content-blocks)
  "从内容块中提取工具使用

参数：
  CONTENT-BLOCKS - Anthropic 内容块列表（vector、list、hash-table 或 string）

返回：
  工具使用块列表"
  ;; 处理各种可能的格式
  (cond
    ;; nil 或字符串 - 无工具使用
    ((or (null content-blocks) (stringp content-blocks))
     nil)

    ;; 单个 hash-table（单个内容块）
    ((hash-table-p content-blocks)
     (let ((type (gethash "type" content-blocks)))
       (if (and type (string= type "tool_use"))
           (list content-blocks)
           nil)))

    ;; vector 或 list
    (t
     (let ((blocks (if (vectorp content-blocks)
                       (coerce content-blocks 'list)
                       content-blocks)))
       (loop for block in blocks
             for type = (if (hash-table-p block)
                            (gethash "type" block)
                            (getf block :type))
             when (and type (string= type "tool_use"))
             collect block)))))

(defun parse-anthropic-tool-use (tool-blocks)
  "解析 Anthropic 工具使用

参数：
  TOOL-BLOCKS - 工具使用块列表

返回：
  标准化的工具调用列表"
  (loop for block in tool-blocks
        collect (list :id (if (hash-table-p block)
                              (gethash "id" block)
                              (getf block :id))
                      :name (let ((name (if (hash-table-p block)
                                            (gethash "name" block)
                                            (getf block :name))))
                             (intern (string-upcase name) :keyword))
                      :arguments (if (hash-table-p block)
                                     (gethash "input" block)
                                     (getf block :input))
                      :raw block)))

;;; ============================================================
;;; 辅助函数
;;; ============================================================

(defun anthropic-model-context-window (model)
  "获取模型的上下文窗口大小

参数：
  MODEL - 模型名称

返回：
  上下文窗口 token 数"
  (cond
    ((search "claude-3-opus" model) 200000)
    ((search "claude-3-5-sonnet" model) 200000)
    ((search "claude-3-5-haiku" model) 200000)
    ((search "claude-sonnet-4" model) 200000)
    ((search "claude-3-sonnet" model) 200000)
    ((search "claude-3-haiku" model) 200000)
    (t 100000)))  ; 默认值

(defun anthropic-model-max-output (model)
  "获取模型的最大输出 token 数

参数：
  MODEL - 模型名称

返回：
  最大输出 token 数"
  (cond
    ((search "claude-sonnet-4" model) 16384)
    ((search "claude-3-5" model) 8192)
    ((search "claude-3-opus" model) 4096)
    (t 4096)))  ; 默认值
