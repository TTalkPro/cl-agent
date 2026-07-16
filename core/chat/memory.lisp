;;;; memory.lisp
;;;; CL-Agent Chat - ChatMemory
;;;;
;;;; 概述（对标 Spring AI ChatMemory / ChatMemoryRepository）：
;;;;
;;;;   chat-memory-repository        存储协议（find/save/delete/ids）
;;;;   ├── in-memory-chat-memory-repository  线程安全内存实现
;;;;   └── （自定义：JDBC/Redis 等后端实现同一协议即可）
;;;;
;;;;   chat-memory                   记忆协议（add/messages/clear）
;;;;   └── message-window-chat-memory  滑动窗口实现（默认 20 条）
;;;;
;;;; 窗口语义（pairing-safe）：
;;;;   - system-message 不计入窗口、始终保留
;;;;   - 裁剪后窗口头部若是孤立的 tool-response-message
;;;;     （其对应的 assistant 工具调用已被裁掉），继续丢弃直到头部合法，
;;;;     避免 provider 校验报错。

(in-package #:cl-agent.core)

(alexandria:define-constant +default-conversation-id+ "default"
  :test #'equal
  :documentation "缺省会话 ID（对标 ChatMemory.DEFAULT_CONVERSATION_ID）")

;;; ============================================================
;;; Repository 协议
;;; ============================================================

(defclass chat-memory-repository ()
  ()
  (:documentation "会话消息存储协议基类（对标 ChatMemoryRepository）"))

(defgeneric repository-find (repository conversation-id)
  (:documentation "返回该会话的消息列表（message 实例，无则 NIL）"))

(defgeneric repository-save (repository conversation-id messages)
  (:documentation "整体替换该会话的消息列表"))

(defgeneric repository-delete (repository conversation-id)
  (:documentation "删除该会话的全部消息"))

(defgeneric repository-conversation-ids (repository)
  (:documentation "列出所有会话 ID"))

;;; ============================================================
;;; 内存实现（线程安全）
;;; ============================================================

(defclass in-memory-chat-memory-repository (chat-memory-repository)
  ((table
    :initform (make-hash-table :test #'equal)
    :reader repository-table
    :documentation "conversation-id → 消息列表")
   (lock
    :initform (bt:make-lock "chat-memory-repository")
    :reader repository-lock))
  (:documentation "线程安全的内存存储
（对标 InMemoryChatMemoryRepository）"))

(defun make-in-memory-chat-memory-repository ()
  "创建内存 Repository"
  (make-instance 'in-memory-chat-memory-repository))

(defmethod repository-find ((repo in-memory-chat-memory-repository) conversation-id)
  (bt:with-lock-held ((repository-lock repo))
    (copy-list (gethash conversation-id (repository-table repo)))))

(defmethod repository-save ((repo in-memory-chat-memory-repository) conversation-id messages)
  (bt:with-lock-held ((repository-lock repo))
    (setf (gethash conversation-id (repository-table repo))
          (copy-list messages)))
  nil)

(defmethod repository-delete ((repo in-memory-chat-memory-repository) conversation-id)
  (bt:with-lock-held ((repository-lock repo))
    (remhash conversation-id (repository-table repo)))
  nil)

(defmethod repository-conversation-ids ((repo in-memory-chat-memory-repository))
  (bt:with-lock-held ((repository-lock repo))
    (loop for id being the hash-keys of (repository-table repo)
          collect id)))

;;; ============================================================
;;; ChatMemory 协议
;;; ============================================================

(defclass chat-memory ()
  ()
  (:documentation "会话记忆协议基类（对标 ChatMemory）"))

(defgeneric memory-add (memory conversation-id messages)
  (:documentation "追加消息（单条 message 或列表）到会话记忆"))

(defgeneric memory-messages (memory conversation-id)
  (:documentation "取回该会话的记忆消息列表（对标 ChatMemory#get）"))

(defgeneric memory-clear (memory conversation-id)
  (:documentation "清空该会话记忆"))

;;; ============================================================
;;; 滑动窗口实现
;;; ============================================================

(defclass message-window-chat-memory (chat-memory)
  ((repository
    :initarg :repository
    :reader memory-repository
    :documentation "chat-memory-repository 后端")
   (max-messages
    :initarg :max-messages
    :initform 20
    :reader memory-max-messages
    :documentation "窗口大小（非 system 消息条数，默认 20）"))
  (:documentation "滑动窗口记忆（对标 MessageWindowChatMemory）：
追加时按窗口裁剪后落库，system 消息不计入且始终保留。"))

(defun make-message-window-chat-memory (&key repository (max-messages 20))
  "创建滑动窗口记忆。REPOSITORY 缺省为新建的内存 Repository。"
  (make-instance 'message-window-chat-memory
                 :repository (or repository
                                 (make-in-memory-chat-memory-repository))
                 :max-messages max-messages))

(defun window-messages (messages max-messages)
  "pairing-safe 窗口裁剪：保留尾部 MAX-MESSAGES 条非 system 消息；
窗口头部的孤立 tool-response-message 连带丢弃；system 消息保留在最前。"
  (let* ((systems (remove-if-not #'system-message-p messages))
         (body (remove-if #'system-message-p messages))
         (windowed (if (and max-messages (> (length body) max-messages))
                       (nthcdr (- (length body) max-messages) body)
                       body))
         (trimmed (loop for rest on windowed
                        unless (tool-response-message-p (car rest))
                          return rest
                        finally (return nil))))
    (append systems trimmed)))

(defmethod memory-add ((memory message-window-chat-memory) conversation-id messages)
  (let* ((repo (memory-repository memory))
         (new (if (listp messages) messages (list messages)))
         (all (append (repository-find repo conversation-id) new)))
    (repository-save repo conversation-id
                     (window-messages all (memory-max-messages memory))))
  nil)

(defmethod memory-messages ((memory message-window-chat-memory) conversation-id)
  (repository-find (memory-repository memory) conversation-id))

(defmethod memory-clear ((memory message-window-chat-memory) conversation-id)
  (repository-delete (memory-repository memory) conversation-id))
