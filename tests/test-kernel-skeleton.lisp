;;;; test-kernel-skeleton.lisp
;;;; CL-Agent - Kernel 骨架测试

(in-package :cl-agent/tests)

(def-suite kernel-suite :in cl-agent-suite
  :description "Kernel CLOS 类 + build-kernel + 载体")

(in-suite kernel-suite)

;;; ============================================================
;;; Kernel 构造
;;; ============================================================

(test build-kernel-basic
  "build-kernel 基本参数 → 各 reader 返回正确值"
  (let* ((dummy-model (list :fake-model))
         (f1 (cl-agent.kernel:make-filter :f1 :chat (lambda (req chain) (funcall chain req))))
         (k (cl-agent.kernel:build-kernel
             :model dummy-model
             :tools '(get-weather save-note)
             :filters (list f1))))
    (is (eq dummy-model (cl-agent.kernel:kernel-model k)))
    (is (equal '(get-weather save-note) (cl-agent.kernel:kernel-tools k)))
    (is (= 1 (length (cl-agent.kernel:kernel-filters k))))
    (is (eq :f1 (cl-agent.kernel:filter-name (first (cl-agent.kernel:kernel-filters k)))))))

(test build-kernel-defaults
  "build-kernel 缺省值：filters 为空列表，eligibility-fn 为 constantly t"
  (let ((k (cl-agent.kernel:build-kernel :model (list :fake))))
    (is (null (cl-agent.kernel:kernel-tools k)))
    (is (null (cl-agent.kernel:kernel-filters k)))
    (is (null (cl-agent.kernel:kernel-settings k)))
    (is (funcall (cl-agent.kernel:kernel-eligibility-fn k) nil nil)
        "默认 eligibility-fn 总是返回 t")))

(test build-kernel-custom-eligibility
  "build-kernel 自定义 eligibility-fn"
  (let ((k (cl-agent.kernel:build-kernel
            :model (list :fake)
            :eligibility-fn (lambda (resp ctx)
                               (declare (ignore resp))
                               (getf ctx :has-budget)))))
    (is (funcall (cl-agent.kernel:kernel-eligibility-fn k) nil '(:has-budget t)))
    (is (not (funcall (cl-agent.kernel:kernel-eligibility-fn k) nil '(:has-budget nil))))))

(test build-kernel-settings-alist
  "build-kernel settings 传递"
  (let ((k (cl-agent.kernel:build-kernel
            :model (list :fake)
            :settings '((:max-tool-iterations . 10)
                        (:timeout . 30)))))
    (is (equal '((:max-tool-iterations . 10) (:timeout . 30))
               (cl-agent.kernel:kernel-settings k)))))

;;; ============================================================
;;; Kernel 无 memory 字段
;;; ============================================================

(test kernel-has-no-memory-slot
  "kernel 类无 memory 相关 slot"
  (let ((slot-names (mapcar (lambda (s) (symbol-name (closer-mop:slot-definition-name s)))
                            (closer-mop:class-slots (find-class 'cl-agent.kernel:kernel)))))
    ;; 期望的 slot 列表（按符号名比较，避免跨包符号不一致）
    (is (member "MODEL" slot-names :test #'string=))
    (is (member "TOOLS" slot-names :test #'string=))
    (is (member "FILTERS" slot-names :test #'string=))
    (is (member "ELIGIBILITY-FN" slot-names :test #'string=))
    (is (member "SETTINGS" slot-names :test #'string=))
    ;; 确认没有 memory
    (is (not (member "MEMORY" slot-names :test #'string=))
        "kernel 无 memory slot——memory 是 filter 不是 kernel 属性")))

;;; ============================================================
;;; 载体类
;;; ============================================================

(test tool-request-carriers
  "tool-request / tool-response 构造与读取"
  (let ((req (cl-agent.kernel:make-tool-request
              'get-weather :args '(:city "北京") :context '(:user-id 1))))
    (is (eq 'get-weather (cl-agent.kernel:tool-request-function req)))
    (is (equal '(:city "北京") (cl-agent.kernel:tool-request-args req)))
    (is (equal '(:user-id 1) (cl-agent.kernel:tool-request-context req))))
  (let ((resp (cl-agent.kernel:make-tool-response
               :result "22°C" :writes '((:counter . 1)) :error nil)))
    (is (equal "22°C" (cl-agent.kernel:tool-response-result resp)))
    (is (equal '((:counter . 1)) (cl-agent.kernel:tool-response-writes resp)))
    (is (null (cl-agent.kernel:tool-response-error resp)))))

(test turn-request-result-carriers
  "turn-request / turn-result 构造与读取"
  (let ((req (cl-agent.kernel:make-turn-request
              (list "msg1" "msg2") :context '(:conv-id "c1") :resume-p t)))
    (is (equal '("msg1" "msg2") (cl-agent.kernel:turn-request-messages req)))
    (is (equal '(:conv-id "c1") (cl-agent.kernel:turn-request-context req)))
    (is (eq t (cl-agent.kernel:turn-request-resume-p req))))
  (let ((result (cl-agent.kernel:make-turn-result
                 :completed :response "answer" :tool-calls-made 3)))
    (is (eq :completed (cl-agent.kernel:turn-result-status result)))
    (is (equal "answer" (cl-agent.kernel:turn-result-response result)))
    (is (= 3 (cl-agent.kernel:turn-result-tool-calls-made result)))))
