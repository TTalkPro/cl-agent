;;;; message.lisp
;;;; CL-Agent Chat - CLOS 消息体系
;;;;
;;;; 概述（对标 Spring AI org.springframework.ai.chat.messages.*）：
;;;;
;;;;   message（抽象基类）
;;;;   ├── system-message         系统指令
;;;;   ├── user-message           用户输入
;;;;   ├── assistant-message      模型回复（可携带 tool-calls）
;;;;   └── tool-response-message  工具执行结果（可携带多条 tool-response）
;;;;
;;;;   与 Java 版一一对应：
;;;;     Message / SystemMessage / UserMessage / AssistantMessage /
;;;;     ToolResponseMessage / AssistantMessage.ToolCall /
;;;;     ToolResponseMessage.ToolResponse
;;;;
;;;;   类名与同名构造函数共存（CL 的函数/类命名空间分离），
;;;;   构造风格贴近 new UserMessage("...")：
;;;;     (user-message "你好")
;;;;     (assistant-message "好的" :tool-calls (list (make-tool-call ...)))
;;;;
;;;; 中立 plist：
;;;;   Provider SPI（cl-agent.core:llm-chat）接收 (:role ... :content ...)
;;;;   风格的中立消息。message->neutral / neutral->message 负责边界互转，
;;;;   CLOS 消息不跨越 SPI 边界。

(in-package #:cl-agent.core)

;;; ============================================================
;;; 抽象基类
;;; ============================================================

(defclass message ()
  ((metadata
    :initarg :metadata
    :initform nil
    :accessor message-metadata
    :documentation "附加元数据（plist）"))
  (:documentation "所有聊天消息的抽象基类"))

(defgeneric message-role (message)
  (:documentation "消息角色关键字：:system / :user / :assistant / :tool"))

(defgeneric message-text (message)
  (:documentation "消息的文本内容（字符串，可能为空串）"))

(defgeneric message-media (message)
  (:documentation "消息携带的多模态附件（media 实例列表）。

只有 user-message 会有；其余消息类型恒为 NIL，
调用方无需先判类型。")
  (:method ((message message)) nil))

(defun messagep (obj)
  "是否为 message 实例"
  (typep obj 'message))

;;; ============================================================
;;; tool-call / tool-response 值对象
;;; ============================================================

(defclass tool-call ()
  ((id
    :initarg :id
    :reader tool-call-id
    :documentation "工具调用 ID（provider 分配或自动生成）")
   (name
    :initarg :name
    :reader tool-call-name
    :documentation "工具名称（字符串）")
   (arguments
    :initarg :arguments
    :initform nil
    :reader tool-call-arguments
    :documentation "调用参数（hash-table / plist / JSON 字符串）"))
  (:documentation "assistant 消息中携带的工具调用请求
（对标 AssistantMessage.ToolCall）"))

(defun make-tool-call (&key id name arguments)
  "创建 tool-call。ID 为空时自动生成；NAME 统一为小写字符串。"
  (make-instance 'tool-call
                 :id (or id (generate-uuid))
                 :name (etypecase name
                         (string name)
                         (symbol (string-downcase (symbol-name name))))
                 :arguments arguments))

(defmethod print-object ((tc tool-call) stream)
  (print-unreadable-object (tc stream :type t)
    (format stream "~A id=~A" (tool-call-name tc) (tool-call-id tc))))

(defclass tool-response ()
  ((id
    :initarg :id
    :reader tool-response-id
    :documentation "对应的工具调用 ID")
   (name
    :initarg :name
    :reader tool-response-name
    :documentation "工具名称（字符串）")
   (text
    :initarg :text
    :initform ""
    :reader tool-response-text
    :documentation "工具执行结果文本"))
  (:documentation "单个工具执行结果
（对标 ToolResponseMessage.ToolResponse）"))

(defun make-tool-response (&key id name (text ""))
  "创建 tool-response"
  (make-instance 'tool-response
                 :id id
                 :name (etypecase name
                         (string name)
                         (symbol (string-downcase (symbol-name name))))
                 :text text))

(defmethod print-object ((tr tool-response) stream)
  (print-unreadable-object (tr stream :type t)
    (format stream "~A id=~A" (tool-response-name tr) (tool-response-id tr))))

;;; ============================================================
;;; 具体消息类
;;; ============================================================

(defclass system-message (message)
  ((text
    :initarg :text
    :initform ""
    :reader message-text
    :documentation "系统指令文本"))
  (:documentation "系统指令消息（对标 SystemMessage）"))

(defmethod message-role ((msg system-message)) :system)

(defclass user-message (message)
  ((text
    :initarg :text
    :initform ""
    :reader message-text
    :documentation "用户输入文本")
   (media
    :initarg :media
    :initform nil
    :reader message-media
    :documentation "多模态附件：media 实例列表（图片/音频/文档，可为空）"))
  (:documentation "用户消息（对标 UserMessage）。

文本之外可携带 media 附件——同一条消息里文本与附件一起送给模型，
wire 形态由各 provider 翻译（OpenAI 的 content 分片数组 /
Anthropic 的 content 块数组）。"))

(defmethod message-role ((msg user-message)) :user)

(defclass assistant-message (message)
  ((text
    :initarg :text
    :initform ""
    :reader message-text
    :documentation "模型回复文本")
   (tool-calls
    :initarg :tool-calls
    :initform nil
    :reader assistant-tool-calls
    :documentation "tool-call 实例列表（可为空）"))
  (:documentation "模型回复消息（对标 AssistantMessage）"))

(defmethod message-role ((msg assistant-message)) :assistant)

(defclass tool-response-message (message)
  ((responses
    :initarg :responses
    :initform nil
    :reader tool-responses
    :documentation "tool-response 实例列表"))
  (:documentation "工具执行结果消息（对标 ToolResponseMessage）"))

(defmethod message-role ((msg tool-response-message)) :tool)

(defmethod message-text ((msg tool-response-message))
  "多条工具结果拼接为文本（便于日志/调试）"
  (format nil "~{~A~^~%~}"
          (mapcar #'tool-response-text (tool-responses msg))))

;;; ============================================================
;;; 构造函数（与类同名，风格贴近 new XxxMessage(...)）
;;; ============================================================

(defun system-message (text &key metadata)
  "创建系统消息"
  (make-instance 'system-message :text (or text "") :metadata metadata))

(defun user-message (text &key media metadata)
  "创建用户消息。

参数：
  TEXT     - 文本内容
  MEDIA    - 多模态附件：media 实例或其列表（可选）
  METADATA - 附加元数据 plist（可选）

示例：
  (user-message \"这张图里有什么？\"
                :media (image-media :url \"https://example.com/cat.png\"))"
  (make-instance 'user-message
                 :text (or text "")
                 :media (cond ((null media) nil)
                              ((listp media) media)
                              (t (list media)))
                 :metadata metadata))

(defun assistant-message (text &key tool-calls metadata)
  "创建模型回复消息。TOOL-CALLS 为 tool-call 实例列表。"
  (make-instance 'assistant-message
                 :text (or text "")
                 :tool-calls tool-calls
                 :metadata metadata))

(defun tool-response-message (responses &key metadata)
  "创建工具结果消息。RESPONSES 为 tool-response 实例（或其列表）。"
  (make-instance 'tool-response-message
                 :responses (if (listp responses) responses (list responses))
                 :metadata metadata))

;;; ============================================================
;;; 谓词
;;; ============================================================

(defun system-message-p (obj) (typep obj 'system-message))
(defun user-message-p (obj) (typep obj 'user-message))
(defun assistant-message-p (obj) (typep obj 'assistant-message))
(defun tool-response-message-p (obj) (typep obj 'tool-response-message))

;;; ============================================================
;;; 打印
;;; ============================================================

(defmethod print-object ((msg message) stream)
  (print-unreadable-object (msg stream :type t)
    (let ((text (message-text msg)))
      (format stream "~S~@[ tool-calls=~A~]"
              (if (> (length text) 40)
                  (concatenate 'string (subseq text 0 40) "...")
                  text)
              (when (and (assistant-message-p msg)
                         (assistant-tool-calls msg))
                (length (assistant-tool-calls msg)))))))

;;; ============================================================
;;; 中立 plist 互转（provider SPI 边界）
;;; ============================================================

(defgeneric message->neutral (message)
  (:documentation "把 CLOS 消息转换为中立消息 plist 列表。

大多数消息对应单条 plist；tool-response-message 每个结果一条
（provider 侧要求 :role :tool 消息一一对应 tool-call-id）。"))

(defmethod message->neutral ((msg system-message))
  (list (list :role :system :content (message-text msg))))

(defmethod message->neutral ((msg user-message))
  (let ((media (message-media msg)))
    (list (append (list :role :user :content (message-text msg))
                  ;; 附件降为中立 plist——CLOS media 不跨 SPI 边界，
                  ;; 与 tool-call 同一纪律
                  (when media
                    (list :media (media-list->neutral media)))))))

(defmethod message->neutral ((msg assistant-message))
  (let ((calls (assistant-tool-calls msg))
        ;; provider 原生推理块（含签名）。Anthropic 要求工具调用对话的
        ;; assistant 轮把 thinking 块原样回传，故必须穿过中立层。
        ;; 对不产生此类块的 provider 恒为 NIL，不影响它们。
        (reasoning-blocks (getf (message-metadata msg) :reasoning-blocks)))
    (list
     (append
      (list :role :assistant :content (message-text msg))
      (when calls
        (list :tool-calls (mapcar (lambda (tc)
                                    (list :id (tool-call-id tc)
                                          :name (tool-call-name tc)
                                          :arguments (tool-call-arguments tc)))
                                  calls)))
      (when reasoning-blocks
        (list :reasoning-blocks reasoning-blocks))))))

(defmethod message->neutral ((msg tool-response-message))
  (mapcar (lambda (tr)
            (list :role :tool
                  :tool-call-id (tool-response-id tr)
                  :name (tool-response-name tr)
                  :content (tool-response-text tr)))
          (tool-responses msg)))

(defun messages->neutral (messages)
  "把 CLOS 消息列表展开为中立消息 plist 列表"
  (mapcan #'message->neutral messages))

(defun neutral->message (plist)
  "把单条中立消息 plist 转换回 CLOS 消息。

:role :tool 的消息转换为含单条 tool-response 的 tool-response-message。"
  (let ((role (getf plist :role))
        (content (or (getf plist :content) "")))
    (ecase role
      (:system (system-message content))
      (:user (user-message content
                           :media (mapcar #'neutral->media
                                          (getf plist :media))))
      (:assistant
       (assistant-message
        content
        :tool-calls (mapcar (lambda (tc)
                              (make-tool-call :id (getf tc :id)
                                              :name (getf tc :name)
                                              :arguments (getf tc :arguments)))
                            (getf plist :tool-calls))
        ;; 与 message->neutral 对称，保证 CLOS ↔ 中立往返不丢推理块
        :metadata (let ((blocks (getf plist :reasoning-blocks)))
                    (when blocks (list :reasoning-blocks blocks)))))
      (:tool
       (tool-response-message
        (list (make-tool-response :id (getf plist :tool-call-id)
                                  :name (or (getf plist :name) "tool")
                                  :text content)))))))

(defun neutral->messages (plists)
  "把中立消息 plist 列表转换回 CLOS 消息列表"
  (mapcar #'neutral->message plists))
