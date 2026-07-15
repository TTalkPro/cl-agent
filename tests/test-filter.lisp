;;;; test-filter.lisp
;;;; CL-Agent - Filter 机制 + build-chain + defilter 宏测试

(in-package :cl-agent/tests)

(def-suite filter-suite :in cl-agent-suite
  :description "Filter 机制 / build-chain 洋葱折叠 / defilter 宏")

(in-suite filter-suite)

;;; ============================================================
;;; 辅助：用闭包记录执行顺序的测试 filter
;;; ============================================================

(defun make-trace-filter (tag log-cell &key chain-key)
  "构造一个记录 before/after 顺序的 filter。
LOG-CELL 是 cons cell（其 car 是日志列表，新→旧）。
CHAIN-KEY 为 :chat / :tool / :turn。"
  (let ((hook (lambda (req chain)
                (push (list :before tag) (car log-cell))
                (let ((resp (funcall chain req)))
                  (push (list :after tag) (car log-cell))
                  resp))))
    (case chain-key
      (:chat (cl-agent.kernel:make-filter tag :chat hook))
      (:tool (cl-agent.kernel:make-filter tag :tool hook))
      (:turn (cl-agent.kernel:make-filter tag :turn hook))
      (t (error "未知 chain-key ~A" chain-key)))))

;;; ============================================================
;;; build-chain 洋葱排序
;;; ============================================================

(test build-chain-onion-ordering
  "洋葱序：靠前的 filter 在最外层——before 正序，after 逆序"
  (let ((log (list nil)))
    (let ((f-outer (make-trace-filter :outer log :chain-key :chat))
          (f-mid   (make-trace-filter :mid log :chain-key :chat))
          (f-inner (make-trace-filter :inner log :chain-key :chat))
          (terminal (lambda (req)
                      (push :terminal (car log))
                      (list :response req))))
      (let ((chain (cl-agent.kernel:build-chain
                    (list f-outer f-mid f-inner)
                    #'cl-agent.kernel:filter-chat-hook
                    terminal)))
        (funcall chain "test-req"))
    ;; 日志（新→旧）：(:after :outer) (:after :mid) (:after :inner) :terminal
    ;;               (:before :inner) (:before :mid) (:before :outer)
    ;; 验证 before 正序 / after 逆序
    (let* ((entries (remove-if-not #'consp (car log)))
           (befores (mapcar #'second (remove-if-not (lambda (e) (eq (first e) :before)) entries)))
           (afters  (mapcar #'second (remove-if-not (lambda (e) (eq (first e) :after)) entries))))
      (is (equal '(:outer :mid :inner) (reverse befores))
          "before 正序：outer → mid → inner")
      (is (equal '(:inner :mid :outer) (reverse afters))
          "after 逆序：inner → mid → outer")))))

;;; ============================================================
;;; 短路（filter 不调 chain）
;;; ============================================================

(test build-chain-short-circuit
  "短路：filter 不调 chain 时下游不执行"
  (let ((terminal-called nil)
        (short-circuit-filter
          (cl-agent.kernel:make-filter
           :short
           :chat (lambda (req chain)
                   (declare (ignore chain))
                   (list :short-circuited req)))))
    (let ((chain (cl-agent.kernel:build-chain
                  (list short-circuit-filter)
                  #'cl-agent.kernel:filter-chat-hook
                  (lambda (req)
                    (setf terminal-called t)
                    (list :terminal req)))))
      (let ((result (funcall chain "req")))
        (is (equal '(:short-circuited "req") result))
        (is (null terminal-called) "terminal 未执行")))))

;;; ============================================================
;;; around 共享状态（闭包局部变量跨 before/after）
;;; ============================================================

(test filter-around-shared-state
  "around filter：before/after 共享闭包局部状态"
  (let ((timing-filter
          (cl-agent.kernel:make-filter
           :timing
           :chat (lambda (req chain)
                   (let ((start 42))
                     (let ((resp (funcall chain req)))
                       ;; after 段能访问 start
                       (is (= 42 start) "after 段可访问 before 段的局部变量")
                       resp)))))
        (terminal (lambda (req) (list :ok req))))
    (let ((chain (cl-agent.kernel:build-chain
                  (list timing-filter)
                  #'cl-agent.kernel:filter-chat-hook
                  terminal)))
      (funcall chain "test"))))

;;; ============================================================
;;; 递归重入（filter 多次调 chain）
;;; ============================================================

(test build-chain-recursive-reentry
  "递归重入：validation filter 调 chain 两次——terminal 被调用 2 次"
  (let ((call-count 0))
    (let ((validation-filter
           (cl-agent.kernel:make-filter
            :validation
            :chat (lambda (req chain)
                    (let ((resp-1 (funcall chain req)))
                      (if (eq (getf resp-1 :quality) :bad)
                          ;; 第一次不合格 → 改写 req → 重入
                          (funcall chain (list :retry req))
                          resp-1)))))
          (terminal (lambda (req)
                      (incf call-count)
                      (if (= call-count 1)
                          (list :quality :bad :req req)
                          (list :quality :good :req req)))))
      (let ((chain (cl-agent.kernel:build-chain
                    (list validation-filter)
                    #'cl-agent.kernel:filter-chat-hook
                    terminal)))
        (let ((result (funcall chain "original")))
          (is (= 2 call-count) "terminal 被调用 2 次")
          (is (eq :good (getf result :quality)) "第二次返回合格结果")
          (is (equal '(:retry "original") (getf result :req))
              "第二次请求是重入后的改写版本"))))))

;;; ============================================================
;;; 多链钩子选择
;;; ============================================================

(test multi-chain-hook-selection
  "多链：filter 同时有 :chat 和 :tool 钩子，分别构建两条链"
  (let ((chat-log nil)
        (tool-log nil))
    (let ((dual-filter
           (cl-agent.kernel:make-filter
            :dual
            :chat (lambda (req chain)
                    (push :chat-invoked chat-log)
                    (funcall chain req))
            :tool (lambda (req chain)
                    (push :tool-invoked tool-log)
                    (funcall chain req)))))
      ;; 构建 :chat 链
      (let ((chat-chain (cl-agent.kernel:build-chain
                         (list dual-filter)
                         #'cl-agent.kernel:filter-chat-hook
                         (lambda (req) (list :chat-terminal req)))))
        (funcall chat-chain "chat-req")
        (is (equal '(:chat-invoked) chat-log) ":chat 钩子被调用"))
      ;; 构建 :tool 链
      (let ((tool-chain (cl-agent.kernel:build-chain
                         (list dual-filter)
                         #'cl-agent.kernel:filter-tool-hook
                         (lambda (req) (list :tool-terminal req)))))
        (funcall tool-chain "tool-req")
        (is (equal '(:tool-invoked) tool-log) ":tool 钩子被调用")))))

;;; ============================================================
;;; 无钩子的 filter 被跳过
;;; ============================================================

(test filter-without-hook-skipped
  "filter 只有 :tool 钩子，构建 :chat 链时自动跳过"
  (let ((chat-called nil)
        (tool-only (cl-agent.kernel:make-filter
                    :tool-only
                    :tool (lambda (req chain) (funcall chain req)))))
    (let ((chain (cl-agent.kernel:build-chain
                  (list tool-only)
                  #'cl-agent.kernel:filter-chat-hook
                  (lambda (req)
                    (push :terminal chat-called)
                    req))))
      (funcall chain "test")
      (is (equal '(:terminal) chat-called) "terminal 直接执行，filter 被跳过"))))

;;; ============================================================
;;; defilter 宏基本展开
;;; ============================================================

(cl-agent.kernel:defilter test-timing-filter
    ((store :initarg :store :initform nil :reader test-filter-store))
  (:chat (self req chain)
    (let ((resp (funcall chain req)))
      (setf (slot-value self 'store) (1+ (or (slot-value self 'store) 0)))
      resp)))

(test defilter-generates-class-and-constructor
  "defilter 生成 filter 子类 + make- 构造函数"
  (let ((f (make-test-timing-filter)))
    (is (typep f 'cl-agent.kernel:filter))
    (is (not (null (cl-agent.kernel:filter-chat-hook f)))
        ":chat 钩子存在")
    (is (null (cl-agent.kernel:filter-tool-hook f))
        ":tool 钩子不存在")))

(test defilter-hook-invocable
  "defilter 生成的钩子可调用且可访问实例槽"
  (let ((f (make-test-timing-filter)))
    (let ((chain (cl-agent.kernel:build-chain
                  (list f)
                  #'cl-agent.kernel:filter-chat-hook
                  (lambda (req) (list :ok req)))))
      (funcall chain "round-1")
      (funcall chain "round-2"))
    (is (= 2 (test-filter-store f))
        "store 槽被钩子递增了两次")))
