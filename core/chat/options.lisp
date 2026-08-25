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

(in-package #:cl-agent/core)

(defparameter +chat-options-slots+
  '(model temperature max-tokens top-p top-k stop-sequences
    frequency-penalty presence-penalty thinking extra-params
    tool-callbacks tool-names tool-context)
  "chat-options 全部槽位（合并/拷贝时枚举用）")

;;; ============================================================
;;; 刻意没有 definvariants
;;; ============================================================
;;; 本类十几个槽全部**没有** :initform——槽 unbound 就是「未设置」的语义，
;;; merge-chat-options 靠 slot-boundp 实现「运行时 > chat-client 默认 >
;;; 模型默认」的覆盖链，options->spi-args 靠它实现「存在才下发」
;;; （凭空补一个 temperature 会让 Opus 4.7+ 直接 400）。
;;;
;;; 给它加必填校验会直接毁掉这个设计。全库其余值对象都挂了 definvariants，
;;; 这里的空缺是**结论**而不是遗漏——不是每个 unbound 槽都是漏洞。
;;; 判据见 core/invariants.lisp 头注的三分类。

(defclass chat-options (model-options)
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
   (thinking
    :initarg :thinking
    :documentation "扩展思考配置（对标 Spring AI 的 ThinkingConfigParam）。

取值（中立规格，由各 provider 翻译为自家 wire 格式）：
  :disabled                                    关闭思考
  :adaptive                                    由模型自行决定思考量
  (:adaptive :display :omitted)
  (:enabled :budget-tokens 2048)               指定思考预算
  (:enabled :budget-tokens 2048 :display :omitted)
  hash-table                                   原样下发（逃生通道）

:display 为 :summarized（默认）或 :omitted——:omitted 时思考内容
被隐去但仍返回 signature，多轮工具调用的延续性不受影响。

目前由 Anthropic 系 provider（anthropic / minimax）实现；
其它 provider 忽略该槽位。")
   (extra-params
    :initarg :extra-params
    :documentation "厂商专有参数逃生通道（plist，直接并入请求体，
对标 Spring AI 各厂商 Options 的扩展字段 / clj-agent :extra-body）")
   (tool-callbacks
    :initarg :tool-callbacks
    :documentation "tool-callback 实例列表（运行时工具）")
   (tool-names
    :initarg :tool-names
    :documentation "按名引用全局注册表工具的名称列表（字符串/符号）")
   (tool-context
    :initarg :tool-context
    :documentation "透传给工具执行的上下文 plist"))
  (:documentation "可移植的 Chat 调用选项
（对标 Spring AI 2.0 ChatOptions + ToolCallingChatOptions；
工具执行循环本身不在这里配置——它由 cl-agent/core:run-tool-loop
承担，循环相关旋钮见 build-chat-client 的 :max-tool-iterations/:tool-manager）"))

(defun make-chat-options (&rest initargs
                          &key model temperature max-tokens top-p top-k
                               stop-sequences frequency-penalty presence-penalty
                               thinking extra-params
                               tool-callbacks tool-names tool-context)
  "创建 chat-options。只有显式传入的选项才算\"已设置\"。

示例：
  (make-chat-options :temperature 0.3 :max-tokens 1024)
  (make-chat-options :extra-params '(:seed 42 :response-format ...))"
  (declare (ignore model temperature max-tokens top-p top-k
                   stop-sequences frequency-penalty presence-penalty
                   extra-params
                   tool-callbacks tool-names tool-context))
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

(defun chat-options-thinking (options)
  "扩展思考配置（未设置返回 NIL）"
  (options-slot options 'thinking))

(defun chat-options-extra-params (options)
  "厂商专有参数 plist（未设置返回 NIL）"
  (options-slot options 'extra-params))

(defun chat-options-tool-callbacks (options)
  (options-slot options 'tool-callbacks))

(defun chat-options-tool-names (options)
  (options-slot options 'tool-names))

(defun chat-options-tool-context (options)
  (options-slot options 'tool-context))

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

(defun chat-options-with-tools (options &key tool-callbacks tool-names)
  "返回把工具槽**替换**为给定值的选项副本（其余槽位保留）。

与 merge-chat-options 的并集语义不同：这里是整体替换，
供需要收窄工具集的场景使用（如渐进式工具披露）。"
  (let ((new (copy-chat-options options)))
    (setf (slot-value new 'tool-callbacks) tool-callbacks
          (slot-value new 'tool-names) tool-names)
    new))

(defmethod print-object ((options chat-options) stream)
  (print-unreadable-object (options stream :type t)
    (format stream "~{~{~A=~S~}~^ ~}"
            (loop for slot in +chat-options-slots+
                  when (slot-boundp options slot)
                    collect (list slot (slot-value options slot))))))
