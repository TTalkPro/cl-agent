;;;; options.lisp
;;;; CL-Agent Chat - ChatOptions（可移植模型调用选项）
;;;;
;;;; 概述（对标 Spring AI ChatOptions / ToolCallingChatOptions）：
;;;;   封装一次模型调用的可移植选项。分两组：
;;;;
;;;;   模型选项：model / temperature / max-tokens / top-p / top-k /
;;;;             stop-sequences / frequency-penalty / presence-penalty
;;;;   工具选项：tool-callbacks / tool-names / tool-context /
;;;;             internal-tool-execution-enabled / max-tool-iterations
;;;;
;;;; 合并语义：
;;;;   槽位"未设置"用 slot 未绑定表示（区别于显式设为 NIL），
;;;;   merge-chat-options 逐槽取优先值——运行时选项覆盖默认选项，
;;;;   与 Spring AI 的 runtime options > default options 一致。
;;;;   tool-callbacks / tool-names 例外：合并时取并集（Spring AI 同语义）。

(in-package #:cl-agent.chat)

(defparameter +chat-options-slots+
  '(model temperature max-tokens top-p top-k stop-sequences
    frequency-penalty presence-penalty
    tool-callbacks tool-names tool-context
    internal-tool-execution-enabled max-tool-iterations)
  "chat-options 全部槽位（合并/拷贝时枚举用）")

(defclass chat-options ()
  ((model
    :initarg :model
    :documentation "模型名称（字符串）")
   (temperature
    :initarg :temperature
    :documentation "采样温度")
   (max-tokens
    :initarg :max-tokens
    :documentation "最大输出 token 数")
   (top-p
    :initarg :top-p
    :documentation "核采样参数")
   (top-k
    :initarg :top-k
    :documentation "Top-K 采样参数")
   (stop-sequences
    :initarg :stop-sequences
    :documentation "停止序列列表")
   (frequency-penalty
    :initarg :frequency-penalty
    :documentation "频率惩罚")
   (presence-penalty
    :initarg :presence-penalty
    :documentation "存在惩罚")
   (tool-callbacks
    :initarg :tool-callbacks
    :documentation "tool-callback 实例列表（运行时工具）")
   (tool-names
    :initarg :tool-names
    :documentation "按名引用全局注册表工具的名称列表（字符串/符号）")
   (tool-context
    :initarg :tool-context
    :documentation "透传给工具执行的上下文 plist")
   (internal-tool-execution-enabled
    :initarg :internal-tool-execution-enabled
    :documentation "是否在 ChatModel 内部自动执行工具调用（默认 T）")
   (max-tool-iterations
    :initarg :max-tool-iterations
    :documentation "内部工具执行循环的最大轮数（默认 10）"))
  (:documentation "可移植的 Chat 调用选项
（对标 Spring AI ChatOptions + ToolCallingChatOptions）"))

(defun make-chat-options (&rest initargs
                          &key model temperature max-tokens top-p top-k
                               stop-sequences frequency-penalty presence-penalty
                               tool-callbacks tool-names tool-context
                               internal-tool-execution-enabled max-tool-iterations)
  "创建 chat-options。只有显式传入的选项才算\"已设置\"。

示例：
  (make-chat-options :temperature 0.3 :max-tokens 1024)"
  (declare (ignore model temperature max-tokens top-p top-k
                   stop-sequences frequency-penalty presence-penalty
                   tool-callbacks tool-names tool-context
                   internal-tool-execution-enabled max-tool-iterations))
  (apply #'make-instance 'chat-options initargs))

;;; ============================================================
;;; 读取器（未设置返回默认值）
;;; ============================================================

(defun options-slot (options slot &optional default)
  "读取选项槽位；OPTIONS 为 NIL 或槽位未设置时返回 DEFAULT"
  (if (and options (slot-boundp options slot))
      (slot-value options slot)
      default))

(defun chat-options-model (options)
  (options-slot options 'model))

(defun chat-options-temperature (options)
  (options-slot options 'temperature))

(defun chat-options-max-tokens (options)
  (options-slot options 'max-tokens))

(defun chat-options-top-p (options)
  (options-slot options 'top-p))

(defun chat-options-top-k (options)
  (options-slot options 'top-k))

(defun chat-options-stop-sequences (options)
  (options-slot options 'stop-sequences))

(defun chat-options-frequency-penalty (options)
  (options-slot options 'frequency-penalty))

(defun chat-options-presence-penalty (options)
  (options-slot options 'presence-penalty))

(defun chat-options-tool-callbacks (options)
  (options-slot options 'tool-callbacks))

(defun chat-options-tool-names (options)
  (options-slot options 'tool-names))

(defun chat-options-tool-context (options)
  (options-slot options 'tool-context))

(defun chat-options-internal-tool-execution-enabled (options)
  "内部工具执行开关，未设置时默认 T（Spring AI 同默认）"
  (options-slot options 'internal-tool-execution-enabled t))

(defun chat-options-max-tool-iterations (options)
  "工具循环最大轮数，未设置时默认 10"
  (options-slot options 'max-tool-iterations 10))

;;; ============================================================
;;; 拷贝与合并
;;; ============================================================

(defun copy-chat-options (options)
  "浅拷贝 chat-options（保留未设置状态）。OPTIONS 为 NIL 返回新空实例。"
  (let ((new (make-instance 'chat-options)))
    (when options
      (dolist (slot +chat-options-slots+)
        (when (slot-boundp options slot)
          (setf (slot-value new slot) (slot-value options slot)))))
    new))

(defun merge-chat-options (primary fallback)
  "合并两组选项：PRIMARY（运行时）优先于 FALLBACK（默认）。

- 普通槽位：PRIMARY 已设置则取 PRIMARY，否则取 FALLBACK
- tool-callbacks / tool-names：取并集（运行时工具追加默认工具之前）

返回新 chat-options 实例，入参不被修改。"
  (let ((merged (copy-chat-options fallback)))
    (when primary
      (dolist (slot +chat-options-slots+)
        (when (slot-boundp primary slot)
          (setf (slot-value merged slot)
                (case slot
                  ((tool-callbacks tool-names)
                   (append (slot-value primary slot)
                           (options-slot fallback slot)))
                  (otherwise (slot-value primary slot)))))))
    merged))

(defmethod print-object ((options chat-options) stream)
  (print-unreadable-object (options stream :type t)
    (format stream "~{~{~A=~S~}~^ ~}"
            (loop for slot in +chat-options-slots+
                  when (slot-boundp options slot)
                    collect (list slot (slot-value options slot))))))
