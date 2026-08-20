;;;; suite.lisp
;;;; CL-Agent - 测试套件定义（v8.0.0，Spring AI 对标架构）

(in-package :cl-user)

(defpackage :cl-agent/tests
  (:use :cl :fiveam)
  (:export #:cl-agent-suite
           #:run-cl-agent-tests)
  ;; 测试内部共享的 mock 设施
  (:export #:seq-provider
           #:make-seq-provider
           #:seq-provider-requests
           #:text-response
           #:tool-call-response))

(in-package :cl-agent/tests)

;; 主测试套件
(def-suite cl-agent-suite
  :description "CL-Agent Complete Test Suite")

(in-suite cl-agent-suite)

(defun run-cl-agent-tests ()
  "运行全部测试"
  (run! 'cl-agent-suite))

;;; ============================================================
;;; 共享 Mock：顺序响应 Provider（实现 llm-chat SPI）
;;; ============================================================
;;; 每次 llm-chat 调用弹出队列头：
;;;   - llm-response 对象：直接返回
;;;   - 函数：以 (messages &rest spi-args) 调用，返回 llm-response
;;; 同时记录每次调用的入参，供测试断言。

(defclass seq-provider ()
  ((queue
    :initarg :queue
    :initform nil
    :accessor seq-provider-queue
    :documentation "待返回的响应队列")
   (requests
    :initform nil
    :accessor seq-provider-requests
    :documentation "已收到的请求记录（新→旧）：
每项为 plist (:messages ... :tools ... :model ... :max-tokens ... :temperature ...)")))

(defun make-seq-provider (&rest responses)
  "创建顺序响应 provider"
  (make-instance 'seq-provider :queue responses))

(defmethod cl-agent/core:llm-chat ((provider seq-provider) messages
                                   &key max-tokens temperature model tools system
                                        top-p top-k stop
                                        frequency-penalty presence-penalty
                                        tool-choice extra-params
                                   &allow-other-keys)
  (declare (ignore system))
  (push (list :messages messages :tools tools :model model
              :max-tokens max-tokens :temperature temperature
              :top-p top-p :top-k top-k :stop stop
              :frequency-penalty frequency-penalty
              :presence-penalty presence-penalty
              :tool-choice tool-choice :extra-params extra-params)
        (seq-provider-requests provider))
  (let ((next (pop (seq-provider-queue provider))))
    (unless next
      (error "seq-provider 响应队列已空"))
    (etypecase next
      (function (funcall next messages))
      (cl-agent/core:llm-response next))))

(defun text-response (text &key (finish-reason :stop))
  "构造纯文本 llm-response"
  (cl-agent/core:make-llm-response
   :content text
   :finish-reason finish-reason
   :model "seq-model"
   :usage (cl-agent/core:make-llm-usage :input-tokens 10 :output-tokens 5)))

(defun tool-call-response (name arguments &key (id "call-1") (content ""))
  "构造携带单个工具调用的 llm-response。
ARGUMENTS 为 alist（(\"city\" . \"东京\")...），自动转 hash-table。"
  (let ((args-ht (make-hash-table :test #'equal)))
    (loop for (k . v) in arguments
          do (setf (gethash k args-ht) v))
    (cl-agent/core:make-llm-response
     :content content
     :tool-calls (list (list :id id :name name :arguments args-ht))
     :finish-reason :tool-call
     :model "seq-model")))
