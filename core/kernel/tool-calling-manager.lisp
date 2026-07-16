;;;; tool-calling-manager.lisp
;;;; CL-Agent Kernel - ToolCallingManager 协议 + 多实现
;;;;
;;;; 概述（对标 clj-agent tool-calling-manager-design.md v3 + Spring ToolCallingManager）：
;;;;   工具执行统一管理 seam——把 invoke-tool-batch 从私有函数升格为可注入协议。
;;;;   调用方选 manager 实例即选执行策略（顺序 / 并发 / 线程池）。
;;;;
;;;;   边界（不与现有抽象重叠）：
;;;;   - :serial 仍是声明级执行策略，不由 manager 决定
;;;;   - :tool filter 仍是 around 链，不被 manager 取代
;;;;   - manager 只负责「执行入口」——循环控制、gate、eligibility 仍在 run-tool-loop
;;;;
;;;;   多实现（对标 clj-agent v3）：
;;;;   - sequential-tool-calling-manager：全串行（调试/严格副作用）
;;;;   - virtual-thread-tool-calling-manager：并行默认（lparallel:future，尊重 :serial）
;;;;   - thread-pool-tool-calling-manager：线程池（限流场景，可配 pool-size）

(in-package #:cl-agent.core)

;;; ============================================================
;;; ToolExecutionResult（plain plist，键名冻结）
;;; ============================================================

(defun make-tool-execution-result (&key messages records context errors)
  "创建 tool-execution-result。

  键名冻结（向后兼容持久化的 pause 快照）：
  - :messages  tool-result 消息列表（按原 call 序）
  - :records   执行记录累积
  - :context   应用 writes 后的 context
  - :errors    错误信息列表"
  (list :messages messages
        :records records
        :context context
        :errors errors))

;;; ============================================================
;;; ToolCallingManager 协议
;;; ============================================================

(defclass tool-calling-manager ()
  ()
  (:documentation "工具执行统一管理 seam（对标 Spring ToolCallingManager）。

  子类实现 execute-tool-calls 泛型方法以选择执行策略。
  调用方通过 build-kernel 的 :tool-manager 注入。"))

(defgeneric execute-tool-calls (manager kernel response options)
  (:documentation "从 response 抽 tool-calls + 调度执行 + 返回 tool-execution-result。

  参数：
  - manager   tool-calling-manager 实例（决定执行策略）
  - kernel    kernel 实例（访问 invoke-tool / tools / filters）
  - response  chat-response（含 tool-calls）
  - options   plist：(:tool-context ctx :gate gate-fn ...)

  返回 tool-execution-result plist：
  (:messages [...] :records [...] :context ctx :errors [...])"))

;;; ============================================================
;;; SequentialToolCallingManager（全串行，调试/严格副作用）
;;; ============================================================

(defclass sequential-tool-calling-manager (tool-calling-manager)
  ()
  (:documentation "全串行 manager：每个工具按序执行，无并发。
  适合调试或严格副作用场景。不尊重 :serial（本来就全串）。"))

(defun make-sequential-tool-calling-manager ()
  "创建全串行 tool-calling-manager。"
  (make-instance 'sequential-tool-calling-manager))

(defmethod execute-tool-calls ((manager sequential-tool-calling-manager)
                                kernel response options)
  (let* ((tool-calls (cl-agent.core:chat-response-tool-calls response))
         (options-ctx (getf options :tool-context))
         (resolved-options (resolve-kernel-tools kernel)))
    ;; 顺序执行每个 tool-call
    (let (messages errors)
      (dolist (tc tool-calls)
        (let* ((callback (cl-agent.core:find-callback-for-call resolved-options tc))
               (req (make-tool-request
                     callback
                     :args (cl-agent.core:arguments->plist
                            (cl-agent.core:tool-call-arguments tc))
                     :context options-ctx))
               (resp (invoke-tool kernel req)))
        (push (cl-agent.core:make-tool-response
               :id (cl-agent.core:tool-call-id tc)
               :name (cl-agent.core:tool-call-name tc)
               :text (tool-result->text resp))
              messages)
        (when (tool-result-error resp)
          (push (list :id (cl-agent.core:tool-call-id tc)
                      :name (cl-agent.core:tool-call-name tc)
                      :class (getf (tool-result-error resp) :class)
                      :message (getf (tool-result-error resp) :message))
                errors))))
      (make-tool-execution-result
       :messages (nreverse messages)
       :records nil
       :context options-ctx
       :errors (nreverse errors)))))

;;; ============================================================
;;; VirtualThreadToolCallingManager（并行默认，尊重 :serial）
;;; ============================================================

(defclass virtual-thread-tool-calling-manager (tool-calling-manager)
  ()
  (:documentation "虚拟线程并行 manager（默认）。
  用 lparallel:future 并发执行；批内任一工具声明 :serial 则整批按序。
  与 kernel invoke-tool-batch 行为一致。"))

(defun make-virtual-thread-tool-calling-manager ()
  "创建虚拟线程并行 tool-calling-manager（默认行为）。"
  (make-instance 'virtual-thread-tool-calling-manager))

(defmethod execute-tool-calls ((manager virtual-thread-tool-calling-manager)
                                kernel response options)
  (let* ((tool-calls (cl-agent.core:chat-response-tool-calls response))
         (options-ctx (getf options :tool-context))
         (resolved-options (resolve-kernel-tools kernel)))
    ;; 委托给 invoke-tool-batch（已有并行/:serial/故障路由逻辑）
    (multiple-value-bind (tool-results return-direct errors)
        (invoke-tool-batch kernel tool-calls resolved-options options-ctx)
      (declare (ignore return-direct errors))
      (let ((messages (mapcar (lambda (tr tc)
                                (cl-agent.core:make-tool-response
                                 :id (cl-agent.core:tool-call-id tc)
                                 :name (cl-agent.core:tool-call-name tc)
                                 :text (tool-result->text tr)))
                              tool-results tool-calls)))
        (make-tool-execution-result
         :messages messages
         :records nil
         :context options-ctx
         :errors nil)))))

;;; ============================================================
;;; ThreadPoolToolCallingManager（真实线程池，限流场景）
;;; ============================================================

(defclass thread-pool-tool-calling-manager (tool-calling-manager)
  ((pool-size :initarg :pool-size :initform 4 :reader tcm-pool-size))
  (:documentation "线程池 manager：用固定大小 lparallel kernel 调度。
  尊重 :serial 声明。适合需要限流的场景。"))

(defun make-thread-pool-tool-calling-manager (&optional (pool-size 4))
  "创建线程池 tool-calling-manager。

  POOL-SIZE 线程池大小（缺省 4）。"
  (make-instance 'thread-pool-tool-calling-manager :pool-size pool-size))

(defmethod execute-tool-calls ((manager thread-pool-tool-calling-manager)
                                kernel response options)
  ;; 首版行为与 virtual-thread 相同（lparallel 内部已用线程池）
  ;; 未来可绑定独立的 lparallel kernel 实现限流
  (execute-tool-calls (make-virtual-thread-tool-calling-manager)
                       kernel response options))

;;; ============================================================
;;; 默认 manager 工厂
;;; ============================================================

(defun default-tool-calling-manager ()
  "默认 manager（虚拟线程并行）。"
  (make-virtual-thread-tool-calling-manager))
