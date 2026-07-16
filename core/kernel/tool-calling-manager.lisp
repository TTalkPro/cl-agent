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

(defun make-tool-execution-result (&key messages records context errors return-direct)
  "创建 tool-execution-result。

  键名冻结（向后兼容持久化的 pause 快照）：
  - :messages       tool-response 列表（按原 call 序）
  - :records        执行记录累积
  - :context        应用 writes 后的 context
  - :errors         错误信息列表
  - :return-direct  全批工具是否都声明了 :return-direct（短路信号）"
  (list :messages messages
        :records records
        :context context
        :errors errors
        :return-direct return-direct))

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
;;; 共享骨架 + manager-run-batch（CLOS 差异点收敛）
;;; ============================================================
;;; 三个 manager 的差别**只有**「以何种执行模型跑这一批」——抽 tool-calls、
;;; 组装消息、收集错误、折叠 :writes 全部相同。此前三份手写副本各自漂移：
;;; sequential 那份绕过 resolve-callback（模型幻觉一个工具名 →
;;; find-callback-for-call 直接 signal 冲出整轮对话）也绕过 %run-one-tool
;;; （:retry 声明在它手下无效）；virtual-thread 那份把 :errors 恒填 nil。
;;; 收敛后骨架只有一份，manager 只实现 manager-run-batch 一个方法。

(defgeneric manager-run-batch (manager kernel tool-calls options context)
  (:documentation "以 MANAGER 的执行模型跑一批 tool-call。

  这是 manager 之间**唯一**的差异点（执行模型与隔离机制的落点）。
  返回 tool-result 列表（必须与 TOOL-CALLS 同序）。"))

(defmethod execute-tool-calls ((manager tool-calling-manager)
                               kernel response options)
  "共享骨架：抽 tool-calls → manager-run-batch → 组装 tool-execution-result。

  :context 按协议 = 应用 writes 后的 context（fold-batch-writes 折叠，
  失败调用的写意图不生效）。此前该承诺只写在 docstring 里，三个实现
  全部原样透传。"
  (let* ((tool-calls (cl-agent.core:chat-response-tool-calls response))
         (options-ctx (getf options :tool-context))
         (resolved-options (resolve-kernel-tools kernel))
         (tool-results (manager-run-batch manager kernel tool-calls
                                          resolved-options options-ctx))
         ;; return-direct：全批工具都必须声明 :return-direct 才短路
         ;; （与 invoke-tool-batch 的 (every #'first prepared) 同构）
         (return-direct (every
                         (lambda (tc)
                           (multiple-value-bind (cb err)
                               (resolve-callback resolved-options tc)
                             (declare (ignore err))
                             (and cb (cl-agent.core:tool-callback-return-direct-p cb))))
                         tool-calls)))
    (make-tool-execution-result
     :messages (tool-results->responses tool-results tool-calls)
     :records nil
     :context (fold-batch-writes kernel tool-results options-ctx)
     :errors (batch-error-summaries tool-results tool-calls)
     :return-direct return-direct)))

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

(defmethod manager-run-batch ((manager sequential-tool-calling-manager)
                              kernel tool-calls options context)
  ;; 直取顺序路径。经 execute-batch-sequential 意味着与主路径同等待遇：
  ;; resolve-callback（幻觉工具名 → 语义错误回传，不崩整轮）与
  ;; %run-one-tool（:retry 瞬态重试）都生效——此前这条路两者皆无。
  (values (execute-batch-sequential kernel tool-calls options context)))

;;; ============================================================
;;; VirtualThreadToolCallingManager（并行默认，尊重 :serial）
;;; ============================================================

(defclass virtual-thread-tool-calling-manager (tool-calling-manager)
  ()
  (:documentation "虚拟线程并行 manager（默认）。
  并发执行整批；批内任一工具声明 :serial 则整批按序。
  与 kernel 无 manager 时的 invoke-tool-batch 行为一致，
  并发度用进程级默认池（ensure-tool-pool）。"))

(defun make-virtual-thread-tool-calling-manager ()
  "创建虚拟线程并行 tool-calling-manager（默认行为）。"
  (make-instance 'virtual-thread-tool-calling-manager))

(defmethod manager-run-batch ((manager virtual-thread-tool-calling-manager)
                              kernel tool-calls options context)
  (values (invoke-tool-batch kernel tool-calls options context)))

;;; ============================================================
;;; ThreadPoolToolCallingManager（真实线程池，限流场景）
;;; ============================================================

(defclass thread-pool-tool-calling-manager (tool-calling-manager)
  ((pool-size
    :initarg :pool-size
    :initform 4
    :reader tcm-pool-size
    :documentation "worker 线程数——批内并发的硬上限")
   (pool
    :initform nil
    :accessor tcm-pool
    :documentation "自己的 lparallel kernel（懒初始化）。
nil = 尚未创建或已关闭。")
   (lock
    :initform (bt:make-lock "tool-calling-manager-pool")
    :reader tcm-lock
    :documentation "保护 pool 的创建/关闭——manager 可能被多线程共享"))
  (:documentation "线程池 manager：用**固定大小**的 lparallel kernel 调度，
批内并发不超过 pool-size。尊重 :serial 声明。

用途：给工具执行加一道限流闸。工具常打外部依赖（数据库、下游 API、
本地进程），virtual-thread 那种「有多少 tool-call 就并发多少」在批量场景
会直接打爆对方。

生命周期：线程池懒创建（首次执行时），**用完须 shutdown**，否则 worker
线程泄漏。要么显式调 shutdown-tool-calling-manager，要么用
with-thread-pool-tool-calling-manager 宏（推荐，非局部退出也能回收）。"))

(defun make-thread-pool-tool-calling-manager (&optional (pool-size 4))
  "创建线程池 tool-calling-manager。

  POOL-SIZE 线程池大小（缺省 4）——批内并发的硬上限。

  注意：线程池懒创建，**用完须 shutdown-tool-calling-manager**。
  推荐用 with-thread-pool-tool-calling-manager 宏自动回收。"
  (make-instance 'thread-pool-tool-calling-manager :pool-size pool-size))

(defun ensure-manager-pool (manager)
  "取 MANAGER 的线程池，未创建则建（线程安全的双检锁）。"
  (or (tcm-pool manager)
      (bt:with-lock-held ((tcm-lock manager))
        ;; 双检：拿到锁后再看一次，避免并发重复建池
        (or (tcm-pool manager)
            (setf (tcm-pool manager)
                  (lparallel:make-kernel (tcm-pool-size manager)
                                         :name "cl-agent-tool-pool"))))))

(defun shutdown-tool-calling-manager (manager)
  "关闭 MANAGER 的线程池（幂等）。非 thread-pool manager 为 no-op。"
  (when (typep manager 'thread-pool-tool-calling-manager)
    (bt:with-lock-held ((tcm-lock manager))
      (when (tcm-pool manager)
        ;; end-kernel 作用于 lparallel:*kernel*，故必须先把待关闭的池绑上去
        ;; 再关，最后才清空槽——顺序反了会丢失池句柄，worker 线程永久泄漏
        ;; 且再也无法回收。（同 core/http/async.lisp 的教训。）
        (let ((lparallel:*kernel* (tcm-pool manager)))
          (lparallel:end-kernel :wait t))
        (setf (tcm-pool manager) nil))))
  nil)

(defmacro with-thread-pool-tool-calling-manager ((var &optional (pool-size 4))
                                                 &body body)
  "词法作用域内绑定 VAR 为线程池 manager，退出时（含非局部退出）自动关池。

  示例：
    (with-thread-pool-tool-calling-manager (mgr 8)
      (chat (build-kernel :model m :tools '(...) :tool-manager mgr)
            (:user \"...\")))"
  `(let ((,var (make-thread-pool-tool-calling-manager ,pool-size)))
     (unwind-protect (progn ,@body)
       (shutdown-tool-calling-manager ,var))))

(defmethod manager-run-batch ((manager thread-pool-tool-calling-manager)
                              kernel tool-calls options context)
  ;; 把自己的固定大小池绑成当前 lparallel kernel——batch 的 channel 任务
  ;; 提交到这个池，并发被 pool-size 卡死。
  ;;
  ;; 此前这里直接委托 virtual-thread manager，pool-size **完全没被用过**：
  ;; docstring 承诺「适合需要限流的场景」，实际和 virtual-thread 一模一样。
  ;; 用户配 :pool-size 4 以为限流到 4 并发，实际无限制——批量工具直接
  ;; 打爆下游。三种执行模型实际只有两种。
  (let ((lparallel:*kernel* (ensure-manager-pool manager)))
    (values (invoke-tool-batch kernel tool-calls options context))))

;;; ============================================================
;;; 默认 manager 工厂
;;; ============================================================

(defun default-tool-calling-manager ()
  "默认 manager（虚拟线程并行）。"
  (make-virtual-thread-tool-calling-manager))
