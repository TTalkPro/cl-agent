;;;; kernel.lisp
;;;; CL-Agent Kernel - Kernel CLOS 类 + build-kernel 构造函数
;;;;
;;;; 概述：
;;;;   Kernel 是 filter 链 + 模型 + 工具 + 配置的聚合载体（对标
;;;;   clj-agent Kernel）。它是 P2 invoke-chat / invoke-tool / invoke-turn
;;;;   三个终端函数的工厂参数——本阶段只落地骨架，不实现终端逻辑。
;;;;
;;;; 设计要点：
;;;;   - kernel 极简：只存 model / tools / filters / settings / eligibility-fn
;;;;   - kernel 无 memory 字段：记忆是 filter（message-chat-memory-filter），
;;;;     不是 kernel 的固有属性——与 clj-agent 行为一致
;;;;   - eligibility-fn 缺省 (constantly t)：总认为"应该续跑"；
;;;;     P2 循环逻辑用它判断是否继续工具迭代
;;;;   - settings 是 alist：(:max-tool-iterations . 10) 等任意键值

(in-package #:cl-agent.kernel)

;;; ============================================================
;;; Kernel CLOS 类
;;; =========================================================;;;

(defclass kernel ()
  ((model
    :initarg :model
    :initform nil
    :reader kernel-model
    :documentation "chat-model 实例（LLM 服务入口）")
   (tools
    :initarg :tools
    :initform nil
    :reader kernel-tools
    :documentation "工具符号列表或 tool-callback 列表（注册顺序 = 工具名顺序）")
   (filters
    :initarg :filters
    :initform nil
    :reader kernel-filters
    :documentation "filter 实例列表（注册顺序 = 洋葱层级：靠前 = 最外层）")
   (eligibility-fn
    :initarg :eligibility-fn
    :initform (constantly t)
    :reader kernel-eligibility-fn
    :documentation "续跑判据：(response context) → boolean。
判断上一轮响应是否应当继续（如：是否还有未执行的 tool-call）。
缺省 (constantly t)——P2 可替换为基于 tool-call 存在与否的判断。")
   (settings
    :initarg :settings
    :initform nil
    :reader kernel-settings
    :documentation "配置 alist（(:max-tool-iterations . 10) 等）"))
  (:documentation "Kernel 聚合（model/tools/filters/settings）——无 memory。"))

(defmethod print-object ((kernel kernel) stream)
  (print-unreadable-object (kernel stream :type t)
    (format stream "~A filters=~A"
            (kernel-model kernel)
            (length (kernel-filters kernel)))))

;;; ============================================================
;;; build-kernel
;;; =========================================================;;;

(defun build-kernel (&key model tools filters eligibility-fn settings)
  "构建 Kernel 实例。

参数：
  - model          chat-model 实例（LLM 服务）
  - tools          工具符号列表或 tool-callback 列表（缺省 nil）
  - filters        filter 实例列表（注册顺序 = 执行顺序；缺省 nil）
  - eligibility-fn (response context) → boolean（缺省 (constantly t)）
  - settings       配置 alist（缺省 nil）

返回值：kernel 实例。"
  (make-instance 'kernel
                 :model model
                 :tools (or tools nil)
                 :filters (or filters nil)
                 :eligibility-fn (or eligibility-fn (constantly t))
                 :settings (or settings nil)))
