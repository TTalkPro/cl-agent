;;;; callbacks.lisp
;;;; CL-Agent SimpleAgent - Callback Registry（CLOS）
;;;;
;;;; 概述：
;;;;   Agent 的回调机制：每个事件可挂多个回调，按优先级触发，
;;;;   单个回调出错不影响其他回调（错误隔离），支持一次性回调。
;;;;
;;;; 事件约定（kernel-agent）：
;;;;   :on-message     (user-message)          用户消息进入
;;;;   :on-tool-call   (tool-name args)        工具调用前
;;;;   :on-tool-result (tool-name result)      工具调用后
;;;;   :on-response    (response-text result)  最终响应
;;;;   :on-error       (condition)             出错时（随后重新抛出）
;;;;   :on-chunk       (chunk)                 流式块（agent-chat-stream）
;;;;
;;;; 用法：
;;;;   (register-callback (agent-callbacks agent) :on-tool-call
;;;;                      (lambda (name args) (log-it name args))
;;;;                      :name :audit :priority 10)

(in-package #:cl-agent.simpleagent)

;;; ============================================================
;;; Callback Entry
;;; ============================================================

(defclass callback-entry ()
  ((name
    :initarg :name
    :reader callback-entry-name
    :documentation "回调标识（同名注册会替换）")
   (fn
    :initarg :fn
    :reader callback-entry-fn
    :documentation "回调函数")
   (priority
    :initarg :priority
    :initform 100
    :reader callback-entry-priority
    :documentation "优先级（越小越先触发）")
   (once-p
    :initarg :once
    :initform nil
    :reader callback-entry-once-p
    :documentation "一次性回调：触发后自动注销"))
  (:documentation "单个回调注册项"))

(defmethod print-object ((entry callback-entry) stream)
  (print-unreadable-object (entry stream :type t)
    (format stream "~A priority=~A~@[ once~]"
            (callback-entry-name entry)
            (callback-entry-priority entry)
            (callback-entry-once-p entry))))

;;; ============================================================
;;; Callback Registry
;;; ============================================================

(defclass callback-registry ()
  ((table
    :initform (make-hash-table :test #'eq)
    :reader callback-registry-table
    :documentation "事件 -> callback-entry 列表")
   (lock
    :initform (bt:make-lock "callback-registry-lock")
    :reader callback-registry-lock))
  (:documentation "事件回调注册表：多回调、优先级、错误隔离、once 语义"))

(defun make-callback-registry (&optional initial-plist)
  "创建回调注册表。

INITIAL-PLIST 为旧式回调 plist（如 (:on-tool-call fn ...)），
会被逐项注册（向后兼容 make-kernel-agent 的 :callbacks 参数）。"
  (let ((registry (make-instance 'callback-registry)))
    (loop for (event fn) on initial-plist by #'cddr
          when fn
            do (register-callback registry event fn))
    registry))

(defun callback-registry-p (obj)
  "检查是否为回调注册表"
  (typep obj 'callback-registry))

;;; ============================================================
;;; 注册 / 注销
;;; ============================================================

(defgeneric register-callback (registry event fn &key name priority once)
  (:documentation "注册回调。

参数：
  REGISTRY - callback-registry
  EVENT    - 事件关键字（如 :on-tool-call）
  FN       - 回调函数（参数随事件而定）
  NAME     - 回调标识（默认 :default；同名注册会替换）
  PRIORITY - 优先级（越小越先触发，默认 100）
  ONCE     - T 则触发一次后自动注销

返回：
  callback-entry 实例"))

(defmethod register-callback ((registry callback-registry) event fn
                              &key (name :default) (priority 100) once)
  (let ((entry (make-instance 'callback-entry
                              :name name :fn fn
                              :priority priority :once once)))
    (bt:with-lock-held ((callback-registry-lock registry))
      (let ((entries (gethash event (callback-registry-table registry))))
        ;; 同名替换
        (setf (gethash event (callback-registry-table registry))
              (stable-sort (cons entry
                                 (remove name entries
                                         :key #'callback-entry-name))
                           #'< :key #'callback-entry-priority))))
    entry))

(defgeneric unregister-callback (registry event name)
  (:documentation "注销指定事件下名为 NAME 的回调。返回 T 表示有移除。"))

(defmethod unregister-callback ((registry callback-registry) event name)
  (bt:with-lock-held ((callback-registry-lock registry))
    (let* ((entries (gethash event (callback-registry-table registry)))
           (remaining (remove name entries :key #'callback-entry-name)))
      (setf (gethash event (callback-registry-table registry)) remaining)
      (< (length remaining) (length entries)))))

(defgeneric clear-callbacks (registry &optional event)
  (:documentation "清空回调（EVENT 为 NIL 时清空全部）"))

(defmethod clear-callbacks ((registry callback-registry) &optional event)
  (bt:with-lock-held ((callback-registry-lock registry))
    (if event
        (remhash event (callback-registry-table registry))
        (clrhash (callback-registry-table registry))))
  nil)

(defun callback-count (registry event)
  "指定事件的回调数量"
  (bt:with-lock-held ((callback-registry-lock registry))
    (length (gethash event (callback-registry-table registry)))))

;;; ============================================================
;;; 触发
;;; ============================================================

(defgeneric fire-callbacks (registry event &rest args)
  (:documentation "按优先级触发事件回调。

单个回调出错只记日志，不影响其他回调；once 回调触发后自动注销。
返回触发的回调数量。"))

(defmethod fire-callbacks ((registry callback-registry) event &rest args)
  (let ((entries (bt:with-lock-held ((callback-registry-lock registry))
                   (copy-list (gethash event (callback-registry-table registry)))))
        (fired 0))
    (dolist (entry entries)
      (handler-case
          (progn
            (apply (callback-entry-fn entry) args)
            (incf fired))
        (error (e)
          (cl-agent.core:log-warn "Callback ~A/~A error: ~A"
                                  event (callback-entry-name entry) e)))
      (when (callback-entry-once-p entry)
        (unregister-callback registry event (callback-entry-name entry))))
    fired))

(defmethod fire-callbacks ((registry null) event &rest args)
  "无注册表时静默"
  (declare (ignore event args))
  0)
