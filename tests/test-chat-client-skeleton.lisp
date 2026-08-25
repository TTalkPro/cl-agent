;;;; test-chat-client-skeleton.lisp
;;;; CL-Agent - ChatClient 骨架测试

(in-package :cl-agent/tests)

(def-suite chat-client-suite :in cl-agent-suite
  :description "ChatClient CLOS 类 + build-chat-client + 载体")

(in-suite chat-client-suite)

;;; ============================================================
;;; ChatClient 构造
;;; ============================================================

(test build-chat-client-basic
  "build-chat-client 基本参数 → 各 reader 返回正确值"
  (let* ((dummy-model (list :fake-model))
         (f1 (cl-agent/core:make-filter :f1 :chat (lambda (req chain) (funcall chain req))))
         (k (cl-agent/core:build-chat-client
             :model dummy-model
             :tools '(get-weather save-note)
             :filters (list f1))))
    (is (eq dummy-model (cl-agent/core:chat-client-model k)))
    (is (equal '(get-weather save-note) (cl-agent/core:chat-client-tools k)))
    (is (= 1 (length (cl-agent/core:chat-client-filters k))))
    (is (eq :f1 (cl-agent/core:filter-name (first (cl-agent/core:chat-client-filters k)))))))

(test build-chat-client-defaults
  "build-chat-client 缺省值：filters 为空列表，eligibility-fn 为 constantly t"
  (let ((k (cl-agent/core:build-chat-client :model (list :fake))))
    (is (null (cl-agent/core:chat-client-tools k)))
    (is (null (cl-agent/core:chat-client-filters k)))
    (is (null (cl-agent/core:chat-client-settings k)))
    (is (funcall (cl-agent/core:chat-client-eligibility-fn k) nil nil)
        "默认 eligibility-fn 总是返回 t")))

(test build-chat-client-custom-eligibility
  "build-chat-client 自定义 eligibility-fn"
  (let ((k (cl-agent/core:build-chat-client
            :model (list :fake)
            :eligibility-fn (lambda (resp ctx)
                               (declare (ignore resp))
                               (getf ctx :has-budget)))))
    (is (funcall (cl-agent/core:chat-client-eligibility-fn k) nil '(:has-budget t)))
    (is (not (funcall (cl-agent/core:chat-client-eligibility-fn k) nil '(:has-budget nil))))))

(test build-chat-client-settings-alist
  "build-chat-client settings 传递"
  (let ((k (cl-agent/core:build-chat-client
            :model (list :fake)
            :settings '((:max-tool-iterations . 10)
                        (:timeout . 30)))))
    (is (equal '((:max-tool-iterations . 10) (:timeout . 30))
               (cl-agent/core:chat-client-settings k)))))

;;; ============================================================
;;; ChatClient 无 memory 字段
;;; ============================================================

(test chat-client-has-no-memory-slot
  "chat-client 类无 memory 相关 slot"
  (let ((slot-names (mapcar (lambda (s) (symbol-name (closer-mop:slot-definition-name s)))
                            (closer-mop:class-slots (find-class 'cl-agent/core:chat-client)))))
    ;; 期望的 slot 列表（按符号名比较，避免跨包符号不一致）
    (is (member "MODEL" slot-names :test #'string=))
    (is (member "TOOLS" slot-names :test #'string=))
    (is (member "FILTERS" slot-names :test #'string=))
    (is (member "ELIGIBILITY-FN" slot-names :test #'string=))
    (is (member "SETTINGS" slot-names :test #'string=))
    ;; 确认没有 memory
    (is (not (member "MEMORY" slot-names :test #'string=))
        "chat-client 无 memory slot——memory 是 filter 不是 chat-client 属性")))

;;; ============================================================
;;; 载体类
;;; ============================================================

(test tool-request-carriers
  "tool-request / tool-result 构造与读取"
  (let ((req (cl-agent/core:make-tool-request
              'get-weather :args '(:city "北京") :context '(:user-id 1))))
    (is (eq 'get-weather (cl-agent/core:tool-request-function req)))
    (is (equal '(:city "北京") (cl-agent/core:tool-request-args req)))
    (is (equal '(:user-id 1) (cl-agent/core:tool-request-context req))))
  (let ((resp (cl-agent/core:make-tool-result
               :value "22°C" :writes '((:counter . 1)) :error nil)))
    (is (equal "22°C" (cl-agent/core:tool-result-value resp)))
    (is (equal '((:counter . 1)) (cl-agent/core:tool-result-writes resp)))
    (is (null (cl-agent/core:tool-result-error resp)))))

(test turn-request-result-carriers
  "turn-request / turn-result 构造与读取"
  (let ((req (cl-agent/core:make-turn-request
              (list "msg1" "msg2") :context '(:conv-id "c1") :resume-p t)))
    (is (equal '("msg1" "msg2") (cl-agent/core:turn-request-messages req)))
    (is (equal '(:conv-id "c1") (cl-agent/core:turn-request-context req)))
    (is (eq t (cl-agent/core:turn-request-resume-p req))))
  (let ((result (cl-agent/core:make-turn-result
                 :completed :response "answer" :tool-calls-made 3)))
    (is (eq :completed (cl-agent/core:turn-result-status result)))
    (is (equal "answer" (cl-agent/core:turn-result-response result)))
    (is (= 3 (cl-agent/core:turn-result-tool-calls-made result)))))
