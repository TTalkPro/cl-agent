;;;; memory-filter.lisp
;;;; CL-Agent Kernel - ChatMemory 协议 + Memory Filter
;;;;
;;;; 概述（参照 clj-agent design/memory-filter-refactor.md）：
;;;;   按 conversation-id 自管对话历史的 :chat 洋葱 filter：
;;;;
;;;;   - before 段：把本次入参（delta）存入 store，
;;;;     再用完整历史替换发给 LLM 的 messages
;;;;   - after  段：把 LLM 的 assistant 回复（可能含 tool-calls）存入 store
;;;;
;;;;   conversation-id 从 chat-request 的 context 读取；为空时整体 no-op
;;;;   （保留一次性/无记忆调用）。store 是 filter 的私有状态，
;;;;   kernel 对"记忆"零感知。
;;;;
;;;; 用法：
;;;;   (let* ((store (make-in-memory-chat-store))
;;;;          (kernel (make-kernel :service svc
;;;;                               :filters (list (make-memory-filter store)))))
;;;;     ;; context 携带 conversation-id，invoke-kernel 自动进入 delta 模式
;;;;     (invoke-kernel kernel (list (user-message "你好"))
;;;;                    :context (list :conversation-id "conv-1")))

(in-package #:cl-agent.kernel)

;;; ============================================================
;;; ChatMemory 协议
;;; ============================================================

(defgeneric mem-get (store conversation-id)
  (:documentation "返回该会话的中立消息列表（无则 NIL）"))

(defgeneric mem-add (store conversation-id messages)
  (:documentation "追加中立消息列表"))

(defgeneric mem-clear (store conversation-id)
  (:documentation "清空该会话"))

;;; ============================================================
;;; In-Memory 实现
;;; ============================================================

(defclass in-memory-chat-store ()
  ((table
    :initform (make-hash-table :test #'equal)
    :reader chat-store-table
    :documentation "conversation-id -> 消息列表")
   (lock
    :initform (bt:make-lock "chat-store-lock")
    :reader chat-store-lock))
  (:documentation "线程安全的内存 ChatMemory 后端"))

(defun make-in-memory-chat-store ()
  "创建内存 ChatMemory"
  (make-instance 'in-memory-chat-store))

(defmethod mem-get ((store in-memory-chat-store) conversation-id)
  (bt:with-lock-held ((chat-store-lock store))
    (copy-list (gethash conversation-id (chat-store-table store)))))

(defmethod mem-add ((store in-memory-chat-store) conversation-id messages)
  (bt:with-lock-held ((chat-store-lock store))
    (setf (gethash conversation-id (chat-store-table store))
          (append (gethash conversation-id (chat-store-table store))
                  (copy-list messages))))
  nil)

(defmethod mem-clear ((store in-memory-chat-store) conversation-id)
  (bt:with-lock-held ((chat-store-lock store))
    (remhash conversation-id (chat-store-table store)))
  nil)

;;; ============================================================
;;; 窗口裁剪（pairing-safe）
;;; ============================================================

(defclass windowed-chat-store ()
  ((inner
    :initarg :inner
    :reader windowed-store-inner
    :documentation "被包装的 ChatMemory")
   (max-messages
    :initarg :max-messages
    :initform nil
    :reader windowed-store-max-messages
    :documentation "窗口大小（非 system 消息条数）"))
  (:documentation "包装一个 store，使 mem-get 只返回尾部 max-messages 条
（pairing-safe）。底层仍保留完整历史。"))

(defun make-windowed-chat-store (inner &key max-messages)
  "包装 INNER store，mem-get 时按窗口裁剪。

参数：
  INNER        - 被包装的 ChatMemory
  MAX-MESSAGES - 保留的尾部消息条数（system 消息不计入、始终保留）"
  (make-instance 'windowed-chat-store
                 :inner inner
                 :max-messages max-messages))

(defun safe-window (messages max-messages)
  "保留尾部 MAX-MESSAGES 条非 system 消息；若窗口头部是孤立的 :tool
（其 assistant 工具调用被裁掉了），继续丢弃直到头部合法，避免 provider
报错。system 消息不计入窗口、始终保留在最前。"
  (if (null max-messages)
      messages
      (let* ((systems (remove-if-not (lambda (m) (eq (getf m :role) :system))
                                     messages))
             (body (remove-if (lambda (m) (eq (getf m :role) :system))
                              messages))
             (windowed (if (> (length body) max-messages)
                           (nthcdr (- (length body) max-messages) body)
                           body))
             ;; 丢弃头部孤立 tool 消息
             (trimmed (loop for rest on windowed
                            unless (eq (getf (car rest) :role) :tool)
                              return rest
                            finally (return nil))))
        (append systems trimmed))))

(defmethod mem-get ((store windowed-chat-store) conversation-id)
  (safe-window (mem-get (windowed-store-inner store) conversation-id)
               (windowed-store-max-messages store)))

(defmethod mem-add ((store windowed-chat-store) conversation-id messages)
  (mem-add (windowed-store-inner store) conversation-id messages))

(defmethod mem-clear ((store windowed-chat-store) conversation-id)
  (mem-clear (windowed-store-inner store) conversation-id))

;;; ============================================================
;;; 中立 assistant 消息
;;; ============================================================

(defun llm-response->neutral-message (response)
  "把统一响应（llm-response）转成中立 assistant 消息 plist。

含 tool-calls 时形如：
  (:role :assistant :content \"...\"
   :tool-calls ((:id ... :name ... :arguments ...) ...))"
  (let ((text (cl-agent.core:llm-response-content response))
        (calls (cl-agent.core:llm-response-tool-calls response)))
    (if calls
        (list :role :assistant
              :content (or text "")
              :tool-calls (mapcar (lambda (tc)
                                    (list :id (cl-agent.core:llm-tool-call-id tc)
                                          :name (cl-agent.core:llm-tool-call-name tc)
                                          :arguments (cl-agent.core:llm-tool-call-arguments tc)))
                                  calls))
        (list :role :assistant :content (or text "")))))

;;; ============================================================
;;; Memory Filter（CLOS：特化 filter-around）
;;; ============================================================

(defclass memory-filter (filter)
  ((store
    :initarg :store
    :reader memory-filter-store
    :documentation "ChatMemory 后端（filter 私有，kernel 无感知）"))
  (:documentation "按 conversation-id 读写历史的 :chat 洋葱 filter。

应注册为最外层 chat filter（priority 默认 50），
确保其他 chat filter 看到完整对话历史。"))

(defun make-memory-filter (store &key (priority 50) (name "memory"))
  "构造 Memory Filter，闭包绑定 STORE。

参数：
  STORE    - ChatMemory 实例（in-memory / windowed / 自定义）
  PRIORITY - 优先级（默认 50，最外层）
  NAME     - 名称

返回：
  memory-filter 实例"
  (make-instance 'memory-filter
                 :store store
                 :type :chat
                 :name name
                 :priority priority))

(defmethod filter-around ((filter memory-filter))
  "Memory Filter 的 around 实现：
  - 有 conversation-id：存 delta → 历史替换 messages → 下游 → 存回复
  - 无 conversation-id：整体 no-op（透传）"
  (let ((store (memory-filter-store filter)))
    (lambda (request chain)
      (let ((cid (context-conversation-id (chat-request-context request))))
        (if cid
            (progn
              ;; before 段：存 delta（system 消息不入库，由请求每轮自带）
              (mem-add store cid
                       (remove-if (lambda (m) (eq (getf m :role) :system))
                                  (chat-request-messages request)))
              ;; 用完整历史替换发给下游的 messages
              (setf (chat-request-messages request) (mem-get store cid))
              ;; 下游（后续 filter + LLM terminal）
              (let ((response (funcall chain request)))
                ;; after 段：存 assistant 回复（可能含 tool-calls）
                (mem-add store cid
                         (list (llm-response->neutral-message response)))
                response))
            (funcall chain request))))))
