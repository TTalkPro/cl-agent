;;;; test-http-async.lisp
;;;; CL-Agent - 异步 HTTP 测试（http/async.lisp）
;;;;
;;;; 覆盖：
;;;;   - 动态绑定继承：future 逃逸出调用方 let 后仍看到提交时刻的绑定
;;;;   - http-parallel 的绑定继承
;;;;   - 线程池生命周期（shutdown 真正回收线程、幂等）
;;;;
;;;; 说明：
;;;;   这些测试不发真实网络请求——把 cl-agent/core:http-request 临时
;;;;   换成探针，回报「执行时看到了什么」。探针是全进程可见的，因此
;;;;   worker 线程里的调用同样会命中。

(in-package :cl-agent/tests)

(def-suite http-async-suite :in cl-agent-suite
  :description "异步 HTTP（http-request-async / http-parallel）")

(in-suite http-async-suite)

(defvar *ha-request-id* nil
  "测试用：模拟调用方 let 绑定的环境上下文")

(defun call-with-http-probe (fn)
  "把 http-request 临时替换为探针后调用 FN，结束时恢复。

探针不发网络请求，返回一个 plist 记录调用时的 URL、所在线程与
*ha-request-id* 的可见值。"
  (let ((original (fdefinition 'cl-agent/core:http-request)))
    (unwind-protect
         (progn
           (setf (fdefinition 'cl-agent/core:http-request)
                 (lambda (url &rest args)
                   (declare (ignore args))
                   (list :url url
                         :thread (bt:thread-name (bt:current-thread))
                         :req-id *ha-request-id*)))
           (funcall fn))
      (setf (fdefinition 'cl-agent/core:http-request) original))))

(defmacro with-http-probe (&body body)
  `(call-with-http-probe (lambda () ,@body)))

(defmacro with-http-pool ((&key (size 2)) &body body)
  "起一个 HTTP 线程池并保证退出时回收"
  `(progn
     (cl-agent/core:initialize-http-thread-pool :size ,size)
     (unwind-protect (progn ,@body)
       (cl-agent/core:shutdown-http-thread-pool))))

;;; ============================================================
;;; 动态绑定继承
;;; ============================================================
;;; 注：与并行工具执行同理，不存在「默认不继承」的确定性测试——
;;; 未列入名单时的可见性本就不确定（force 可能把任务窃取到调用
;;; force 的线程就地执行）。故只断言有保证的方向。

(test http-async-inherits-after-let-exits
  "future 逃逸出调用方的 let 之后再 force，请求体仍看到提交时刻的绑定。
这是异步场景与并行工具执行的关键差异：提交与执行不在同一动态范围内。"
  (with-http-probe
    (with-http-pool ()
      (let ((f nil))
        (cl-agent/core:with-inherited-specials (*ha-request-id*)
          (let ((*ha-request-id* "req-42"))
            (setf f (cl-agent/core:http-get-async "http://probe.invalid/x"))))
        ;; 此处 let 已退出，*ha-request-id* 已恢复为 NIL
        (is (null *ha-request-id*))
        ;; 但请求体看到的仍是提交时刻的值
        (is (equal "req-42"
                   (getf (cl-agent/core:http-future-value f) :req-id)))))))

(test http-async-inherits-via-dynamic-list
  "直接绑定 *inherited-special-variables* 亦可（等价于 with-inherited-specials）"
  (with-http-probe
    (with-http-pool ()
      (let ((f (let ((cl-agent/core:*inherited-special-variables* '(*ha-request-id*))
                     (*ha-request-id* "req-7"))
                 (cl-agent/core:http-get-async "http://probe.invalid/y"))))
        (is (equal "req-7" (getf (cl-agent/core:http-future-value f) :req-id)))))))

(test http-parallel-inherits
  "http-parallel 的每个请求体都继承提交时刻的绑定"
  (with-http-probe
    (with-http-pool (:size 3)
      (let ((results (cl-agent/core:with-inherited-specials (*ha-request-id*)
                       (let ((*ha-request-id* "req-9"))
                         (cl-agent/core:http-parallel
                          '("http://probe.invalid/a"
                            "http://probe.invalid/b"
                            "http://probe.invalid/c"))))))
        (is (= 3 (length results)))
        ;; 每个结果形如 (:ok <探针 plist> :tag nil)
        (is (every (lambda (r) (eq :ok (first r))) results))
        (is (equal '("req-9" "req-9" "req-9")
                   (mapcar (lambda (r) (getf (second r) :req-id)) results)))
        ;; 原序保持
        (is (equal '("http://probe.invalid/a"
                     "http://probe.invalid/b"
                     "http://probe.invalid/c")
                   (mapcar (lambda (r) (getf (second r) :url)) results)))))))

(test http-async-no-inherit-list-still-works
  "未配置继承名单时功能正常（仅绑定可见性不确定，不做断言）"
  (with-http-probe
    (with-http-pool ()
      (let ((f (cl-agent/core:http-get-async "http://probe.invalid/z")))
        (is (equal "http://probe.invalid/z"
                   (getf (cl-agent/core:http-future-value f) :url)))))))

;;; ============================================================
;;; 线程池生命周期
;;; ============================================================

(defun ha-pool-thread-count ()
  (count-if (lambda (th) (search "http-pool" (or (bt:thread-name th) "")))
            (bt:all-threads)))

(test http-pool-shutdown-reclaims-threads
  "shutdown 真正回收 worker 线程（曾因先清空 *http-thread-pool* 再
end-kernel 而导致线程永久泄漏）"
  (let ((before (ha-pool-thread-count)))
    (cl-agent/core:initialize-http-thread-pool :size 3)
    (is (= (+ before 3) (ha-pool-thread-count)))
    (cl-agent/core:shutdown-http-thread-pool)
    ;; end-kernel :wait t 返回后线程应已退出（留一点调度余量）
    (loop repeat 40
          until (= before (ha-pool-thread-count))
          do (sleep 0.05))
    (is (= before (ha-pool-thread-count)))
    (is (null cl-agent/core:*http-thread-pool*))))

(test http-pool-shutdown-idempotent
  "重复 shutdown 不报错"
  (cl-agent/core:initialize-http-thread-pool :size 2)
  (cl-agent/core:shutdown-http-thread-pool)
  (finishes (cl-agent/core:shutdown-http-thread-pool))
  (finishes (cl-agent/core:shutdown-http-thread-pool)))
