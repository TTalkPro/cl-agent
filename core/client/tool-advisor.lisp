;;;; tool-advisor.lisp
;;;; CL-Agent Client - ToolCallingAdvisor（递归 Advisor）
;;;;
;;;; 概述（对标 Spring AI 2.0 ToolCallingAdvisor）：
;;;;   工具执行循环作为 Advisor 链中的一等公民——一个"递归 Advisor"，
;;;;   反复重入下游链直到停止条件满足：
;;;;
;;;;   1. 重入下游（内侧 Advisor + ChatModel 终端）拿到响应
;;;;   2. 响应携带 tool-calls 且 prompt 配置了工具
;;;;      → ToolCallingManager 执行工具 → 用 conversation-history
;;;;        组新 prompt → 回到 1
;;;;   3. 否则返回最终响应
;;;;
;;;;   :return-direct 工具的结果直接合成最终响应，不回传模型。
;;;;
;;;; 排序（order 越小越靠外）：
;;;;   默认 order 2000，位于记忆类 Advisor（1000）内侧——对标 Spring
;;;;   的默认布局（memory HIGHEST_PRECEDENCE+200 在 tool loop
;;;;   HIGHEST_PRECEDENCE+300 之外）：记忆只记录最终问答，
;;;;   工具轮次的中间消息不进入记忆。
;;;;
;;;;   位于本 Advisor 内侧（order > 2000）的 Advisor 每轮工具循环
;;;;   都会执行——审批门、逐轮日志等场景放这里。
;;;;
;;;; 自动注册：
;;;;   ChatClient 组装链时自动追加一个默认实例（链中已有或
;;;;   客户端/请求禁用时除外）；禁用后进入 user-controlled 模式，
;;;;   调用方拿到携带 tool-calls 的响应自行驱动
;;;;   cl-agent.chat:execute-tool-calls 循环。

(in-package #:cl-agent.client)

(defparameter +tool-calling-advisor-order+ 2000
  "tool-calling-advisor 默认排序：记忆类 Advisor（1000）内侧")

(defvar *tool-calling-manager* nil
  "tool-calling-advisor 未显式传 :manager 时采用的默认 manager。

NIL 表示各 advisor 自建独立的顺序 manager（无共享状态）。
可用 let 动态绑定覆盖——例如临时切到并行 manager——无需全局
变量或改造任何调用点（含 ChatClient 自动注册的 advisor）：

  (with-concurrent-tool-calling-manager (mgr :pool-size 8)
    (let ((*tool-calling-manager* mgr))
      (chat client (:user \"...\") (:tools ...))))  ; 自动注册的 advisor 即用 mgr

显式 (make-tool-calling-advisor :manager x) 始终优先于本默认。")

(defun default-tool-calling-manager* ()
  "解析默认 manager：优先动态绑定的 *tool-calling-manager*，
否则新建一个顺序 manager"
  (or *tool-calling-manager* (make-default-tool-calling-manager)))

(defclass tool-calling-advisor (advisor)
  ((manager
    :initarg :manager
    :initform (default-tool-calling-manager*)
    :reader tool-advisor-manager
    :documentation "tool-calling-manager 实例")
   (max-iterations
    :initarg :max-iterations
    :initform 10
    :reader tool-advisor-max-iterations
    :documentation "工具循环最大轮数（超过发
max-tool-iterations-exceeded-error）"))
  (:default-initargs :order +tool-calling-advisor-order+)
  (:documentation "工具执行循环 Advisor（对标 ToolCallingAdvisor）"))

(defun make-tool-calling-advisor (&rest initargs &key manager max-iterations order)
  "创建 tool-calling-advisor。

参数：
  MANAGER        - 自定义 tool-calling-manager（可选）
  MAX-ITERATIONS - 循环上限（默认 10）
  ORDER          - 排序（默认 2000，记忆 Advisor 内侧）"
  (declare (ignore manager max-iterations order))
  (apply #'make-instance 'tool-calling-advisor initargs))

;;; ============================================================
;;; 细粒度钩子（对标 Spring AI 2.0 ToolCallingAdvisor 的
;;; doInitializeLoop / doBeforeCall / doAfterCall / doFinalizeLoop）
;;; ============================================================
;;; 子类特化即可在循环的关键节点观察或改写请求/响应，
;;; 无需重写整个 advise-call / advise-stream。
;;; call 与 stream 共用同一组钩子（循环核心本就共用）。

(defgeneric tool-advisor-initialize-loop (advisor request)
  (:documentation "循环开始前调用一次（对标 doInitializeLoop）。

返回（可改写的）client-request；默认原样返回。
适合：解析/索引工具集、初始化 request context 状态。"))

(defmethod tool-advisor-initialize-loop ((advisor tool-calling-advisor) request)
  request)

(defgeneric tool-advisor-before-call (advisor request iteration)
  (:documentation "每轮进入下游链（模型调用）之前调用（对标 doBeforeCall）。

参数：
  ITERATION - 当前轮次（从 0 起）

返回（可改写的）client-request；默认原样返回。
适合：按轮改写 prompt/工具集（如渐进式工具披露）、审批门。"))

(defmethod tool-advisor-before-call ((advisor tool-calling-advisor) request iteration)
  (declare (ignore iteration))
  request)

(defgeneric tool-advisor-after-call (advisor request response iteration)
  (:documentation "每轮拿到下游响应之后、工具执行判定之前调用
（对标 doAfterCall）。

返回（可改写的）client-response；默认原样返回。
适合：逐轮日志/指标、响应改写、旁路终止判定。"))

(defmethod tool-advisor-after-call ((advisor tool-calling-advisor) request response iteration)
  (declare (ignore request iteration))
  response)

(defgeneric tool-advisor-finalize-loop (advisor request response)
  (:documentation "循环结束（含 return-direct 短路）后调用一次
（对标 doFinalizeLoop）。

返回（可改写的）最终 client-response；默认原样返回。
适合：汇总统计、清理 request context 状态。"))

(defmethod tool-advisor-finalize-loop ((advisor tool-calling-advisor) request response)
  (declare (ignore request))
  response)

;;; ============================================================
;;; 循环核心（call 与 stream 共用）
;;; ============================================================

(defun prompt-has-tools-p (prompt)
  "prompt 的选项是否配置了工具"
  (let ((options (prompt-options prompt)))
    (or (chat-options-tool-callbacks options)
        (chat-options-tool-names options))))

(defun return-direct-response (result source-response request)
  ":return-direct 工具：工具结果直接合成最终响应"
  (make-client-response
   (make-chat-response
    (make-generation
     (assistant-message (message-text (tool-execution-last-message result)))
     :finish-reason :stop)
    :metadata (chat-response-metadata-of
               (client-response-chat-response source-response)))
   :context (client-request-context request)))

(defun run-tool-calling-loop (advisor request step)
  "递归工具循环：STEP 为 (request) → client-response
（同步与流式共用，差异只在 STEP 如何进入下游链）。

钩子调用点：
  initialize-loop → [before-call → 下游 → after-call → 工具执行]* → finalize-loop"
  (let ((max-iterations (tool-advisor-max-iterations advisor))
        (manager (tool-advisor-manager advisor)))
    (loop with current-request = (tool-advisor-initialize-loop advisor request)
          for iteration from 0
          do (when (> iteration max-iterations)
               (error 'cl-agent.chat:max-tool-iterations-exceeded-error
                      :limit max-iterations))
             (setf current-request
                   (tool-advisor-before-call advisor current-request iteration))
             (let* ((response (tool-advisor-after-call
                               advisor current-request
                               (funcall step current-request)
                               iteration))
                    (chat-response (client-response-chat-response response))
                    (prompt (client-request-prompt current-request)))
               (if (and (chat-response-has-tool-calls-p chat-response)
                        (prompt-has-tools-p prompt))
                   ;; 有工具调用：执行 → 会话历史组新 prompt → 重入下游
                   (let ((result (execute-tool-calls manager prompt chat-response)))
                     (if (tool-execution-return-direct-p result)
                         (return (tool-advisor-finalize-loop
                                  advisor current-request
                                  (return-direct-response result response
                                                          current-request)))
                         (setf current-request
                               (client-request-copy
                                current-request
                                :prompt (prompt-copy
                                         prompt
                                         :messages (tool-execution-conversation-history
                                                    result))))))
                   ;; 无工具调用（或未配置工具）：最终响应
                   (return (tool-advisor-finalize-loop
                            advisor current-request response)))))))

;;; ============================================================
;;; Advisor 协议实现
;;; ============================================================

(defmethod advise-call ((advisor tool-calling-advisor) request chain)
  (run-tool-calling-loop advisor request
                         (lambda (req) (chain-next chain req))))

(defmethod advise-stream ((advisor tool-calling-advisor) request chain on-chunk)
  "流式工具循环：每轮都走流式下游，文本增量全程透传
（含中间轮次可能伴随 tool-calls 的说明文本）"
  (run-tool-calling-loop advisor request
                         (lambda (req)
                           (chain-next-stream chain req on-chunk))))
