;;;; batch.lisp
;;;; CL-Agent ChatClient - 批量工具执行（并行默认 + :serial 退化 + 故障路由）
;;;;
;;;; 概述（对标 clj-agent 的 react/execute-batch）：
;;;;   批次内工具默认并行执行（lparallel）；任一工具声明 :serial
;;;;   则整批退化按序。故障按 :semantic/:transient/:environment 分类路由。
;;;;
;;;;   策略矩阵（**已实现**，见 %run-one-tool）：
;;;;   | 分类          | 工具声明 :retry | 动作                          |
;;;;   |---------------|----------------|-------------------------------|
;;;;   | :semantic     | 任意           | 转文本回传模型（不中断循环）   |
;;;;   | :transient    | t              | 指数退避重试，最多 3 次        |
;;;;   | :transient    | nil            | 转文本回传模型                 |
;;;;   | :environment  | 任意           | 转文本回传模型（见下方偏差）   |
;;;;
;;;;   与参照实现的已知偏差：
;;;;   - `:environment` 在 clj-agent 里会**暂停等人**（:env-retry 类暂停），
;;;;     这里仍只转文本。HITL 的审批类暂停已实现（tool-gate + resume-turn），
;;;;     环境类暂停未做——它需要在屏障处（整批执行完）而非工具解析处切入。
;;;;
;;;;   这张表曾经是**纯谎言**：代码从不读 tool-callback-retry-p、不退避、
;;;;   不重试，三类故障全部一视同仁转文本，deftool 认真记的 (:retry t)
;;;;   零消费者。更底层的是分类本身就坏——tool-callback-call 把工具体内
;;;;   抛的一切包成 tool-execution-error，而 classify-tool-error 直接把它
;;;;   判成 :semantic，于是三类在真实链路上退化成一类。两处都已修，
;;;;   并有「回退即失败」的回归测试守着。

(in-package #:cl-agent/core)

;;; ============================================================
;;; 工具解析（找不到 ≠ 崩掉整轮对话）
;;; ============================================================

(defun resolve-callback (options tool-call)
  "为一次 tool-call 解析 callback。

返回 (values callback error-result)：
  - 找到   → (values callback nil)
  - 找不到 → (values nil tool-result(:error :semantic))

find-callback-for-call 找不到工具时是 signal 而非返回 nil。它的调用点
在构造 tool-request **之前**，落在 invoke-tool → tool-apply-terminal
的 handler-case 之外——于是模型只要报出一个不存在的工具名（LLM 幻觉
工具名很常见），条件就会一路冒泡出 (chat ...)，整轮对话直接中断。

正确语义是把「找不到工具」当作一次**语义故障**：转成文本回传模型，
让它自纠（旧 ToolCallingManager 的 process-tool-execution-error 就是
这么做的，Spring 的默认语义亦然）。安全边界不受影响——找不到就是
找不到，绝不回退全局注册表去执行未暴露的工具。"
  (handler-case (values (cl-agent/core:find-callback-for-call options tool-call)
                        nil)
    (cl-agent/core:tool-not-found-error (e)
      (values nil (make-tool-result
                   :error (list :class :semantic
                                :message (princ-to-string e)))))))

(defun tool-result->text (tool-result)
  "把 tool-result 转成回传模型的文本。

错误结果要把原因说清楚：模型看到「找不到工具 xxx」才可能自纠
（改用别的工具、修参数）；只说「（执行失败）」等于让它盲猜。
这也是旧 ToolCallingManager 的 process-tool-execution-error 默认语义。"
  (or (tool-result-value tool-result)
      (let ((err (tool-result-error tool-result)))
        (if err
            (format nil "错误：~A" (or (getf err :message) "工具执行失败"))
            "（执行失败）"))))

;;; 下面两个助手是三处调用点（顺序批 / 并行批 / manager 骨架）的
;;; 公共分母——此前各处手写同一段构造，改一处漏两处。

(defun tool-call->request (callback tool-call context)
  "由一次 tool-call 构造 tool-request（参数归一化为 plist）。"
  (make-tool-request
   callback
   :args (cl-agent/core:arguments->plist
          (cl-agent/core:tool-call-arguments tool-call))
   :context context))

(defun tool-results->responses (tool-results tool-calls)
  "把一批 tool-result 转成协议层 tool-response 列表（与 tool-calls 同序、
id/name 一一对应——顺序错位 = 回传模型的消息 id 全错）。"
  (mapcar (lambda (tr tc)
            (cl-agent/core:make-tool-response
             :id (cl-agent/core:tool-call-id tc)
             :name (cl-agent/core:tool-call-name tc)
             :text (tool-result->text tr)))
          tool-results tool-calls))

(defun batch-error-summaries (tool-results tool-calls)
  "收集批内失败调用的错误摘要 plist 列表（:id :name :class :message）。"
  (loop for tr in tool-results
        for tc in tool-calls
        for err = (tool-result-error tr)
        when err
          collect (list :id (cl-agent/core:tool-call-id tc)
                        :name (cl-agent/core:tool-call-name tc)
                        :class (getf err :class)
                        :message (getf err :message))))

;;; ============================================================
;;; 并行/串行执行
;;; ============================================================

(defun batch-all-return-direct-p (tool-calls options)
  "批内是否**每个** tool-call 都解析到声明了 :return-direct 的工具。
空批返回 nil。解析不到的工具算不满足——它执行不了，谈不上直接返回。

与 Spring AI 一致取全体语义（allMatch）：混批（部分声明）继续正常
回灌 LLM——「一半直接返回、一半交给模型」没有自洽解释。"
  (and tool-calls
       (every (lambda (tc)
                (let ((cb (resolve-callback options tc)))
                  (and cb (cl-agent/core:tool-callback-return-direct-p cb))))
              tool-calls)))

(defun batch-has-serial-p (tool-calls options)
  "检查批次中是否有任一工具声明了 :serial。
解析不到的工具当作非 serial——它根本不会被执行。"
  (some (lambda (tc)
          (let ((cb (resolve-callback options tc)))
            (and cb (cl-agent/core:tool-callback-serial-p cb))))
        tool-calls))

(defun execute-batch-sequential (chat-client tool-calls options context)
  "顺序执行整批工具调用。
返回 (values tool-results return-direct-p errors)"
  (let ((return-direct t)
        (results nil)
        (errors nil))
    (dolist (tc tool-calls)
      (multiple-value-bind (callback resolve-error) (resolve-callback options tc)
        (let* ((direct-p (and callback (cl-agent/core:tool-callback-return-direct-p callback)))
               ;; 解析不到就不进 :tool 链——没有工具可执行，
               ;; 直接产出语义错误结果回传模型。
               ;; 走 %run-one-tool 而非直接 invoke-tool：故障路由（瞬态重试）
               ;; 在它里面，顺序路径同样要享有——:serial 的工具往往正是
               ;; 那些打外部依赖、最需要重试的。
               (resp (or resolve-error
                         (%run-one-tool
                          chat-client (tool-call->request callback tc context)))))
          (unless direct-p (setf return-direct nil))
          (push resp results)
          (when (tool-result-error resp)
            (push (cons tc (tool-result-error resp)) errors)))))
    (values (nreverse results) return-direct errors)))

;;; ============================================================
;;; 工具执行线程池（进程级，懒初始化）
;;; ============================================================

(defparameter *tool-pool-size* 4
  "默认工具执行线程池的 worker 数。

只在**进程级默认池尚未创建**时生效——改它得在第一次并行执行工具之前。
要精确控制某个 chat-client 的并发，用 thread-pool-tool-calling-manager
（它有自己的池，且严格限流）。")

(defvar *tool-pool* nil
  "进程级默认 lparallel kernel（懒初始化）。")

(defvar *tool-pool-lock* (bt:make-lock "cl-agent-tool-pool")
  "保护 *tool-pool* 的创建/关闭。")

(defun ensure-tool-pool ()
  "取并行执行工具用的 lparallel kernel。

优先级：调用方已绑定的 lparallel:*kernel* > 进程级默认池（懒建）。

为什么需要它：lparallel 的 submit-task/future 都作用于 lparallel:*kernel*，
而那个变量**默认是 NIL**——lparallel 要求使用者自己 make-kernel。本库此前
既不建也不提，于是默认路径（build-chat-client 不给 :tool-manager）只要模型一次
发 2 个 tool_call 就直接 NO-KERNEL-ERROR 崩掉；1 个 tool_call 反而没事
（≤1 走顺序路径，不碰 lparallel）。而多工具并行是 LLM 的常见行为。
这里懒建一个进程级池兜底，用户仍可自己绑 lparallel:*kernel* 覆盖。"
  (or lparallel:*kernel*
      *tool-pool*
      (bt:with-lock-held (*tool-pool-lock*)
        ;; 双检：拿到锁后再看一次，避免并发重复建池
        (or *tool-pool*
            (setf *tool-pool*
                  (lparallel:make-kernel *tool-pool-size*
                                         :name "cl-agent-tool-pool"))))))

(defun shutdown-tool-pool ()
  "关闭进程级默认工具池（幂等）。通常只在进程退出前需要。"
  (bt:with-lock-held (*tool-pool-lock*)
    (when *tool-pool*
      ;; end-kernel 作用于 lparallel:*kernel*，须先绑上再关，最后清槽——
      ;; 顺序反了会丢句柄，worker 线程永久泄漏。
      (let ((lparallel:*kernel* *tool-pool*))
        (lparallel:end-kernel :wait t))
      (setf *tool-pool* nil)))
  nil)

;;; ============================================================
;;; 故障路由：按分类决定重试
;;; ============================================================

(defparameter *transient-retry-attempts* 3
  "瞬态故障的最大尝试次数（含首次）。只对声明了 :retry 的工具生效。")

(defparameter *transient-retry-base-delay* 0.1
  "指数退避的基数秒数：第 n 次重试前睡 base * 2^(n-1)。")

(defun retryable-p (req)
  "本次工具请求是否声明了 :retry。

只有 deftool 里写了 (:retry t) 的工具才会被重试——重试意味着**重复执行
副作用**，必须由工具作者显式选择加入，框架不能替他决定。"
  (let ((fn (tool-request-function req)))
    (and (typep fn 'cl-agent/core:tool-callback)
         (cl-agent/core:tool-callback-retry-p fn))))

(defun %run-one-tool (chat-client req)
  "执行单个工具，任何逃逸的条件都归一化成带分类的错误结果。

  故障路由（这里是唯一实现点——并行与顺序两条路径都经过它）：
  - :transient + 工具声明 :retry → 指数退避重试，最多
    *transient-retry-attempts* 次；仍失败则把最后一次的错误交出去
  - 其余（:semantic / :environment / 未声明 :retry 的 :transient）
    → 直接把错误结果交出去，由上层转文本回传模型

  此前 batch.lisp 的文件头注释白纸黑字写着这套矩阵，但代码里
  **一行都没实现**：从不读 tool-callback-retry-p、不退避、不重试，
  三类故障全部一视同仁转文本。deftool 认真记了 (:retry t)，没有任何
  消费者。"
  (let ((attempts (if (retryable-p req) *transient-retry-attempts* 1)))
    (loop for attempt from 1 to attempts
          for result = (handler-case (invoke-tool chat-client req)
                         (error (e)
                           (make-tool-result
                            :error (list :class (classify-tool-error e)
                                         :message (princ-to-string e)))))
          do (let ((err (tool-result-error result)))
               (cond
                 ;; 成功，或不是瞬态故障 → 立即返回
                 ((or (null err) (not (eq (getf err :class) :transient)))
                  (return result))
                 ;; 瞬态但已是最后一次 → 交出最后的错误
                 ((>= attempt attempts)
                  (return result))
                 ;; 瞬态且还有机会 → 指数退避后重试
                 (t
                  (let ((delay (* *transient-retry-base-delay*
                                  (expt 2 (1- attempt)))))
                    (log-debug "[batch] 瞬态故障，~,3Fs 后第 ~D/~D 次重试：~A"
                               delay (1+ attempt) attempts (getf err :message))
                    (sleep delay))))))))

(defun %submit-and-collect (chat-client prepared)
  "把 PREPARED 里需要执行的提交到当前 lparallel kernel，按**原序**收回结果。

为什么用 channel（submit-task + receive-result）而不是 future + force：
force 是 speculative 的——任务还没被 worker 取走时，**调用线程会自己执行**
（work-stealing，为避免死锁）。后果是并发上限变成 worker 数 + 1：
实测 pool-size=1 峰值 2、pool-size=3 峰值 4。对 thread-pool manager 这种
「就是要限流」的执行模型，超一个就是超——用户说下游只扛得住 4 并发，
配 4 结果跑 5。channel 没有 steal 语义，实测严格 ≤ pool-size。

receive-result 不保证顺序，故任务里带上索引，回填到定位数组——
工具结果必须与 tool_calls 同序，否则回传给模型的 tool 消息 id 全错位。"
  (let* ((n (length prepared))
         (slots (make-array n :initial-element nil))
         ;; 绑定到可用的池：调用方绑的（如 thread-pool manager 的限流池）
         ;; 优先，否则用进程级默认池
         (lparallel:*kernel* (ensure-tool-pool))
         (channel (lparallel:make-channel))
         (submitted 0))
    (loop for prep in prepared
          for i from 0
          do (destructuring-bind (direct-p resolve-error req) prep
               (declare (ignore direct-p))
               (if resolve-error
                   ;; 解析失败的不占 worker，直接填结果
                   (setf (aref slots i) resolve-error)
                   (let ((idx i) (r req))
                     (incf submitted)
                     (lparallel:submit-task
                      channel
                      (lambda () (cons idx (%run-one-tool chat-client r))))))))
    (loop repeat submitted
          do (let ((pair (lparallel:receive-result channel)))
               (setf (aref slots (car pair)) (cdr pair))))
    (coerce slots 'list)))

(defun execute-batch-parallel (chat-client tool-calls options context)
  "并行执行整批工具调用。
≤1 个工具时退化顺序执行。
并发度由当前 lparallel:*kernel* 的 worker 数决定——thread-pool manager
绑自己的固定大小池即得限流，virtual-thread manager 用进程默认池。
返回 (values tool-results return-direct-p errors)"
  (if (<= (length tool-calls) 1)
      (execute-batch-sequential chat-client tool-calls options context)
      ;; 预处理：解析 callback + 构建 req + 记录 direct-p
      ;; 解析在**提交并行任务之前**完成：解析失败直接产出错误结果，
      ;; 不占用 worker，也不会把条件抛出这个 mapcar（那会中断整轮对话）。
      (let* ((prepared
              (mapcar (lambda (tc)
                        (multiple-value-bind (callback resolve-error)
                            (resolve-callback options tc)
                          (let ((direct-p (and callback
                                               (cl-agent/core:tool-callback-return-direct-p callback))))
                            (list direct-p
                                  resolve-error
                                  (when callback
                                    (tool-call->request callback tc context))))))
                      tool-calls))
             (results (%submit-and-collect chat-client prepared))
             ;; prepared 的元素是 (direct-p resolve-error req)
             (return-direct (every #'first prepared))
             (errors (remove-if-not #'tool-result-error results)))
        (values results return-direct errors))))

;;; ============================================================
;;; 写意图折叠（MapReduce 的 reduce 半步，屏障处调用）
;;; ============================================================
;;; 对标 clj-agent context/apply-writes。工具在并行中**只读** context 快照，
;;; 写意图经返回值 (values 结果 writes-plist) 声明；整批收齐后（屏障）在
;;; 这里按 tool-call 原始序折叠——并行的实际交错不影响合并结果。
;;; tool-result 的 writes 槽此前是装饰品：有槽、有导出、有 docstring，
;;; 但全库零生产者、零消费者。

(defun %plist-put (plist key value)
  "返回把 KEY 置为 VALUE 的新 plist（不改原 plist，键唯一）。"
  (let ((acc nil) (found nil))
    (loop for (k v) on plist by #'cddr
          do (push k acc)
             (push (if (eq k key) (progn (setf found t) value) v) acc))
    (let ((res (nreverse acc)))
      (if found res (list* key value res)))))

(defun %slot-spec (slots key)
  "在状态槽声明里找 KEY 的条目，返回 (:init v0 :reduce fn) 部分或 nil。"
  (rest (assoc key slots)))

(defun apply-writes (context writes-seq &optional slots)
  "把一批工具的写意图按序折叠进 CONTEXT（纯函数，不修改实参）。

  参数：
  - context     轮初 context plist（工具执行时拿到的同一份快照）
  - writes-seq  writes-plist 列表；**顺序必须是 tool-call 原始序**——
                这是合并确定性的来源，与并行执行的实际交错无关
  - slots       状态槽声明 ((key :init v0 :reduce (老值 新值)→合并值) ...)；
                未声明的槽 last-writer（后写覆盖，按序确定）

  返回 (values 新context 冲突键列表)。
  冲突 = 同批被写 ≥2 次且未声明 reducer 的键——last-writer 会静默丢掉
  先写的值，调用方决定是否告警。"
  (let ((missing '#:missing)
        (counts (make-hash-table :test #'eq))
        (ctx context)
        (conflicts nil))
    (dolist (writes writes-seq)
      (loop for (k nil) on writes by #'cddr
            do (incf (gethash k counts 0))))
    (maphash (lambda (k n)
               (when (and (> n 1) (null (getf (%slot-spec slots k) :reduce)))
                 (push k conflicts)))
             counts)
    (dolist (writes writes-seq)
      (loop for (k v) on writes by #'cddr
            do (let* ((spec (%slot-spec slots k))
                      (rf (getf spec :reduce)))
                 (setf ctx
                       (%plist-put ctx k
                                   (if rf
                                       (let ((old (getf ctx k missing)))
                                         (funcall rf
                                                  (if (eq old missing)
                                                      (getf spec :init)
                                                      old)
                                                  v))
                                       v))))))
    (values ctx conflicts)))

(defun fold-batch-writes (chat-client tool-results context)
  "屏障折叠：把本批 tool-result 的写意图折进 CONTEXT，返回新 context。

失败调用（error 非 nil）的写意图**不生效**——工具失败即整个调用作废
（事务性），不能留下半截状态。tool-results 须与 tool-calls 同序
（invoke-tool-batch 保证），故折叠序 = call 原始序。"
  (let ((writes-seq (loop for tr in tool-results
                          when (and (null (tool-result-error tr))
                                    (tool-result-writes tr))
                            collect (tool-result-writes tr))))
    (if (null writes-seq)
        context
        (multiple-value-bind (new-ctx conflicts)
            (apply-writes context writes-seq (chat-client-state-slots chat-client))
          (when conflicts
            (log-warn "[batch] 同批多个工具写入未声明 reducer 的槽（last-writer 按调用序生效）：~S"
                      conflicts))
          new-ctx))))

(defun invoke-tool-batch (chat-client tool-calls options context)
  "批量执行 tool-call 列表。

  策略：
  - 默认并行（lparallel）
  - 批内任一工具声明 :serial → 整批顺序执行
  - 工具异常被捕获并分类为 :semantic/:transient/:environment
  - :transient + 工具声明 :retry → 指数退避重试（最多 3 次）
  - 其他故障 → 转文本回传模型（error 放进 tool-result）

  返回 (values tool-results return-direct-p)：
  - tool-results = chat-client:tool-result 列表（与 tool-calls 同序）
  - return-direct-p = 批内所有工具都声明了 return-direct 时为 t"
  (if (batch-has-serial-p tool-calls options)
      ;; 有 :serial → 顺序执行
      (execute-batch-sequential chat-client tool-calls options context)
      ;; 默认并行
      (execute-batch-parallel chat-client tool-calls options context)))
