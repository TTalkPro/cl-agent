;;;; test-kernel-chat.lisp
;;;; CL-Agent Tests - Kernel Chat Completion

(in-package :cl-agent/tests)

(def-suite kernel-chat-suite :in cl-agent-suite
  :description "Kernel Chat Completion 测试套件")

(in-suite kernel-chat-suite)

;;; ============================================================
;;; Mock LLM 增强：支持多轮工具调用
;;; ============================================================

(defclass sequenced-mock-llm (cl-agent.mock:mock-llm-provider)
  ((response-sequence :initarg :responses
                      :accessor mock-response-sequence
                      :initform nil
                      :documentation "按顺序返回的响应列表")
   (call-count :initform 0
               :accessor mock-call-count))
  (:documentation "按顺序返回预定义响应的 Mock LLM"))

(defmethod cl-agent.llm:llm-chat ((provider sequenced-mock-llm) messages &key max-tokens temperature model tools system)
  (declare (ignore max-tokens temperature model tools system))
  (let* ((idx (mock-call-count provider))
         (responses (mock-response-sequence provider))
         (response (if (< idx (length responses))
                       (nth idx responses)
                       (list :content "Default response"))))
    (incf (mock-call-count provider))
    response))

(defun make-sequenced-mock (&rest responses)
  "创建按顺序响应的 Mock LLM"
  (make-instance 'sequenced-mock-llm :responses responses))

;;; ============================================================
;;; 测试辅助
;;; ============================================================

(defun setup-chat-test-tools ()
  "注册 chat 测试用工具和插件"
  (defun test-chat-get-weather (&key city)
    (format nil "Sunny in ~A" city))
  (cl-agent.kernel:declare-tool 'test-chat-get-weather
    :description "Get weather"
    :parameters '((city :string "City" :required-p t)))

  (defun test-chat-calculate (&key expression)
    (format nil "Result: ~A" expression))
  (cl-agent.kernel:declare-tool 'test-chat-calculate
    :description "Calculate"
    :parameters '((expression :string "Expr" :required-p t)))

  (cl-agent.kernel:declare-plugin 'test-chat-tools-plugin
    "Test tools"
    '(test-chat-get-weather test-chat-calculate)))

(defun make-chat-test-kernel (mock-llm &key filters)
  "创建测试用 kernel"
  (setup-chat-test-tools)
  (cl-agent.kernel:make-kernel
   :chat-service mock-llm
   :plugins '(test-chat-tools-plugin)
   :filters filters))

;;; ============================================================
;;; 测试用例
;;; ============================================================

(test test-chat-simple-text
  "测试简单文本响应（无工具调用）"
  (let* ((mock (make-sequenced-mock
                (list :content "Hello, how can I help?")))
         (kernel (make-chat-test-kernel mock))
         (history (cl-agent.kernel:make-chat-history)))
    (cl-agent.kernel:history-add history :user "Hello")
    (let ((result (cl-agent.kernel:chat-completion kernel history)))
      (is (string= "Hello, how can I help?" (getf result :text)))
      (is (null (getf result :tool-calls-made))))))

(test test-chat-auto-one-call
  "测试单次工具调用后获得文本响应"
  (let* ((mock (make-sequenced-mock
                ;; 第一次：返回工具调用
                (list :content ""
                      :tool-calls (list (list :id "call_1"
                                              :name "test-chat-get-weather"
                                              :arguments '(:city "Beijing"))))
                ;; 第二次：返回文本
                (list :content "The weather in Beijing is sunny.")))
         (kernel (make-chat-test-kernel mock))
         (history (cl-agent.kernel:make-chat-history)))
    (cl-agent.kernel:history-add history :user "What's the weather in Beijing?")
    (let ((result (cl-agent.kernel:chat-completion kernel history)))
      (is (string= "The weather in Beijing is sunny." (getf result :text)))
      (is (= 1 (length (getf result :tool-calls-made)))))))

(test test-chat-auto-multi-calls
  "测试单次响应中多个工具调用"
  (let* ((mock (make-sequenced-mock
                ;; 第一次：返回两个工具调用
                (list :content ""
                      :tool-calls (list (list :id "call_1"
                                              :name "test-chat-get-weather"
                                              :arguments '(:city "Beijing"))
                                        (list :id "call_2"
                                              :name "test-chat-get-weather"
                                              :arguments '(:city "Tokyo"))))
                ;; 第二次：返回文本
                (list :content "Beijing is sunny, Tokyo is rainy.")))
         (kernel (make-chat-test-kernel mock))
         (history (cl-agent.kernel:make-chat-history)))
    (cl-agent.kernel:history-add history :user "Weather in Beijing and Tokyo?")
    (let ((result (cl-agent.kernel:chat-completion kernel history)))
      (is (string= "Beijing is sunny, Tokyo is rainy." (getf result :text)))
      (is (= 2 (length (getf result :tool-calls-made)))))))

(test test-chat-auto-loop
  "测试多轮工具调用循环"
  (let* ((mock (make-sequenced-mock
                ;; 第一轮：工具调用
                (list :content ""
                      :tool-calls (list (list :id "call_1"
                                              :name "test-chat-get-weather"
                                              :arguments '(:city "Beijing"))))
                ;; 第二轮：又一个工具调用
                (list :content ""
                      :tool-calls (list (list :id "call_2"
                                              :name "test-chat-calculate"
                                              :arguments '(:expression "1+1"))))
                ;; 第三轮：文本响应
                (list :content "Done with all tools.")))
         (kernel (make-chat-test-kernel mock))
         (history (cl-agent.kernel:make-chat-history)))
    (cl-agent.kernel:history-add history :user "Do stuff")
    (let ((result (cl-agent.kernel:chat-completion kernel history)))
      (is (string= "Done with all tools." (getf result :text)))
      (is (= 2 (length (getf result :tool-calls-made)))))))

(test test-chat-none
  "测试 :none 禁用工具调用"
  (let* ((mock (make-sequenced-mock
                (list :content "I cannot use tools.")))
         (kernel (make-chat-test-kernel mock))
         (history (cl-agent.kernel:make-chat-history)))
    (cl-agent.kernel:history-add history :user "Use a tool")
    (let ((result (cl-agent.kernel:chat-completion kernel history
                    :settings '(:function-choice :none))))
      (is (string= "I cannot use tools." (getf result :text)))
      (is (null (getf result :tool-calls-made))))))

(test test-chat-max-attempts
  "测试超过最大迭代次数报错"
  (let* ((mock (make-sequenced-mock
                ;; 无限返回工具调用
                (list :content ""
                      :tool-calls (list (list :id "call_1"
                                              :name "test-chat-get-weather"
                                              :arguments '(:city "A"))))
                (list :content ""
                      :tool-calls (list (list :id "call_2"
                                              :name "test-chat-get-weather"
                                              :arguments '(:city "B"))))
                (list :content ""
                      :tool-calls (list (list :id "call_3"
                                              :name "test-chat-get-weather"
                                              :arguments '(:city "C"))))))
         (kernel (make-chat-test-kernel mock))
         (history (cl-agent.kernel:make-chat-history)))
    (cl-agent.kernel:history-add history :user "Loop forever")
    (signals error
      (cl-agent.kernel:chat-completion kernel history
        :settings '(:max-attempts 2)))))

(test test-chat-with-filters
  "测试 filter 在工具执行时被调用"
  (let* ((filter-called nil)
         (filter (lambda (context next-fn)
                   (setf filter-called t)
                   (funcall next-fn context)))
         (mock (make-sequenced-mock
                (list :content ""
                      :tool-calls (list (list :id "call_1"
                                              :name "test-chat-get-weather"
                                              :arguments '(:city "Test"))))
                (list :content "Filtered result.")))
         (kernel (make-chat-test-kernel mock :filters (list filter)))
         (history (cl-agent.kernel:make-chat-history)))
    (cl-agent.kernel:history-add history :user "Test")
    (cl-agent.kernel:chat-completion kernel history)
    (is (eq t filter-called))))

(test test-chat-history-updated
  "测试 chat-history 在完成后包含工具消息"
  (let* ((mock (make-sequenced-mock
                (list :content ""
                      :tool-calls (list (list :id "call_1"
                                              :name "test-chat-get-weather"
                                              :arguments '(:city "Beijing"))))
                (list :content "Done.")))
         (kernel (make-chat-test-kernel mock))
         (history (cl-agent.kernel:make-chat-history)))
    (cl-agent.kernel:history-add history :user "Weather?")
    (cl-agent.kernel:chat-completion kernel history)
    ;; 历史应包含: user, assistant(tool-call), tool(result), assistant(text)
    (let ((msgs (cl-agent.kernel:chat-history-messages history)))
      (is (>= (length msgs) 3)))))

(test test-chat-callbacks
  "测试 on-tool-call 和 on-tool-result 回调"
  (let* ((call-log nil)
         (result-log nil)
         (mock (make-sequenced-mock
                (list :content ""
                      :tool-calls (list (list :id "call_1"
                                              :name "test-chat-get-weather"
                                              :arguments '(:city "Test"))))
                (list :content "Done.")))
         (kernel (make-chat-test-kernel mock))
         (history (cl-agent.kernel:make-chat-history)))
    (cl-agent.kernel:history-add history :user "Test")
    (cl-agent.kernel:chat-completion kernel history
      :settings (list :on-tool-call (lambda (name args)
                                      (push (list name args) call-log))
                      :on-tool-result (lambda (name result)
                                        (push (list name result) result-log))))
    (is (= 1 (length call-log)))
    (is (= 1 (length result-log)))
    (is (eq :test-chat-get-weather (first (first call-log))))))

(test test-chat-history-struct
  "测试 chat-history 结构操作"
  (let ((history (cl-agent.kernel:make-chat-history)))
    ;; 初始为空
    (is (null (cl-agent.kernel:chat-history-messages history)))
    ;; 添加消息
    (cl-agent.kernel:history-add history :user "Hello")
    (is (= 1 (length (cl-agent.kernel:chat-history-messages history))))
    ;; 添加系统消息
    (cl-agent.kernel:history-add-system history "You are helpful.")
    (let ((msgs (cl-agent.kernel:chat-history-messages history)))
      (is (eq :system (getf (first msgs) :role))))))

;;; ============================================================
;;; Invoke-Chat 测试
;;; ============================================================

(test test-invoke-chat-simple
  "测试 invoke-chat 单次 LLM 调用（不处理 tool-calls）"
  (let* ((mock (make-sequenced-mock
                ;; 返回带 tool-calls 的响应——invoke-chat 不应处理它
                (list :content "I want to call a tool"
                      :tool-calls (list (list :id "call_1"
                                              :name "test-chat-get-weather"
                                              :arguments '(:city "Beijing"))))))
         (kernel (make-chat-test-kernel mock))
         (messages (list (list :role :user :content "What's the weather?"))))
    (let ((response (cl-agent.kernel:invoke-chat kernel messages)))
      ;; invoke-chat 直接返回 LLM 响应，不处理 tool-calls
      (is (string= "I want to call a tool" (getf response :content)))
      (is (not (null (getf response :tool-calls)))))))

(test test-invoke-chat-with-system-prompt
  "测试 invoke-chat 使用 system-prompt"
  (let* ((received-messages nil)
         (mock (make-instance 'sequenced-mock-llm
                 :responses (list (list :content "Response with system")))))
    ;; 重定义 llm-chat 来捕获 messages
    (defmethod cl-agent.llm:llm-chat ((provider (eql mock)) messages &key max-tokens temperature model tools system)
      (declare (ignore max-tokens temperature model tools system))
      (setf received-messages messages)
      (list :content "Response with system"))
    (let* ((kernel (make-chat-test-kernel mock))
           (messages (list (list :role :user :content "Hello"))))
      (cl-agent.kernel:invoke-chat kernel messages
        :settings '(:system-prompt "You are a test bot"))
      ;; 验证 system prompt 被添加
      (is (eq :system (getf (first received-messages) :role))))))

;;; ============================================================
;;; Invoke-Chat-With-Tools 测试
;;; ============================================================

(test test-invoke-chat-with-tools-basic
  "测试 invoke-chat-with-tools 基本工具调用循环"
  (let* ((mock (make-sequenced-mock
                ;; 第一次：返回工具调用
                (list :content ""
                      :tool-calls (list (list :id "call_1"
                                              :name "test-chat-get-weather"
                                              :arguments '(:city "Beijing"))))
                ;; 第二次：返回文本
                (list :content "The weather in Beijing is sunny.")))
         (kernel (make-chat-test-kernel mock))
         (messages (list (list :role :user :content "What's the weather in Beijing?"))))
    (let ((result (cl-agent.kernel:invoke-chat-with-tools kernel messages)))
      (is (string= "The weather in Beijing is sunny." (getf result :text)))
      (is (= 1 (length (getf result :tool-calls-made)))))))

(test test-invoke-chat-with-tools-uses-invoke
  "测试 invoke-chat-with-tools 的工具执行经过 filter chain（通过 invoke）"
  (let* ((filter-log nil)
         (filter (lambda (context next-fn)
                   (push (getf context :tool-name) filter-log)
                   (funcall next-fn context)))
         (mock (make-sequenced-mock
                ;; 两个工具调用
                (list :content ""
                      :tool-calls (list (list :id "call_1"
                                              :name "test-chat-get-weather"
                                              :arguments '(:city "A"))
                                        (list :id "call_2"
                                              :name "test-chat-get-weather"
                                              :arguments '(:city "B"))))
                ;; 文本响应
                (list :content "Done.")))
         (kernel (make-chat-test-kernel mock :filters (list filter)))
         (messages (list (list :role :user :content "Test"))))
    (cl-agent.kernel:invoke-chat-with-tools kernel messages)
    ;; 验证 filter 被调用了两次（每个工具一次）
    (is (= 2 (length filter-log)))
    (is (eq :test-chat-get-weather (first filter-log)))
    (is (eq :test-chat-get-weather (second filter-log)))))
