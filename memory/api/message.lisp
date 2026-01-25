;;;; memory-message.lisp
;;;; CL-Agent Memory - Memory Message 类
;;;;
;;;; 概述：
;;;;   对话消息的 CLOS 实现

(in-package :cl-agent.memory)

;;; ============================================================
;;; Memory Message 类
;;; ============================================================

(defclass memory-message ()
  ((role
    :initarg :role
    :accessor memory-message-role
    :type keyword
    :documentation "消息角色：:user/:assistant/:system/:tool")
   (content
    :initarg :content
    :accessor memory-message-content
    :type string
    :documentation "消息内容")
   (timestamp
    :initarg :timestamp
    :accessor memory-message-timestamp
    :initform nil
    :type (or null integer)
    :documentation "时间戳")
   (metadata
    :initarg :metadata
    :accessor memory-message-metadata
    :initform nil
    :type (or null hash-table)
    :documentation "元数据"))
  (:documentation "Memory Message 类

表示对话历史中的一条消息

槽位说明：
  ROLE      - 消息角色（:user, :assistant, :system, :tool）
  CONTENT   - 消息内容
  TIMESTAMP - 时间戳
  METADATA  - 元数据"))

(defun memory-message-p (obj)
  "检查对象是否是 memory-message 实例"
  (typep obj 'memory-message))

(defun make-memory-message (&key role content timestamp metadata)
  "创建 memory-message 实例

参数：
  ROLE      - 消息角色（:user/:assistant/:system/:tool）
  CONTENT   - 消息内容
  TIMESTAMP - 时间戳（可选，默认当前时间）
  METADATA  - 元数据（可选）

返回：
  memory-message 实例"
  (make-instance 'memory-message
                 :role role
                 :content content
                 :timestamp (or timestamp (cl-agent.core:timestamp-now))
                 :metadata metadata))

(defmethod print-object ((msg memory-message) stream)
  (print-unreadable-object (msg stream :type t)
    (format stream "~A ~S"
            (memory-message-role msg)
            (let ((content (memory-message-content msg)))
              (if (> (length content) 30)
                  (concatenate 'string (subseq content 0 30) "...")
                  content)))))

;;; ============================================================
;;; 消息创建便捷函数
;;; ============================================================

(defun make-user-message (content &key metadata)
  "创建用户消息"
  (make-memory-message :role :user :content content :metadata metadata))

(defun make-assistant-message (content &key metadata)
  "创建助手消息"
  (make-memory-message :role :assistant :content content :metadata metadata))

(defun make-system-message (content &key metadata)
  "创建系统消息"
  (make-memory-message :role :system :content content :metadata metadata))

(defun make-tool-message (content &key tool-name tool-result)
  "创建工具消息"
  (let ((metadata (when tool-name
                    (let ((ht (make-hash-table :test #'equal)))
                      (setf (gethash :tool-name ht) tool-name)
                      (when tool-result
                        (setf (gethash :tool-result ht) tool-result))
                      ht))))
    (make-memory-message :role :tool :content content :metadata metadata)))

;;; ============================================================
;;; Memory Message 协议方法
;;; ============================================================

(defgeneric message-to-alist (message)
  (:documentation "将消息转换为 alist"))

(defgeneric message-token-count (message)
  (:documentation "估算消息的 token 数量"))

(defmethod message-to-alist ((msg memory-message))
  "将消息转换为 alist 表示"
  `((:role . ,(memory-message-role msg))
    (:content . ,(memory-message-content msg))
    (:timestamp . ,(memory-message-timestamp msg))
    (:metadata . ,(memory-message-metadata msg))))

(defmethod message-token-count ((msg memory-message))
  "估算消息的 token 数量"
  (estimate-tokens (memory-message-content msg)))
