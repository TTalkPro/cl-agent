;;;; test-glm47-live.lisp
;;;; CL-Agent - GLM-4.7 (Anthropic-compatible) 三层 Invoke API 实时测试
;;;;
;;;; 测试内容：
;;;;   1. invoke — 直接函数执行（通过 filter chain）
;;;;   2. invoke-chat 单轮 — 单次 LLM 调用（无工具循环）
;;;;   3. invoke-chat 多轮 — 多次 LLM 调用
;;;;   4. invoke-chat-with-tools 单轮 — 工具调用循环
;;;;   5. invoke-chat-with-tools 多轮 — 多轮工具调用
;;;;   6. chat-completion 向后兼容
;;;;
;;;; 使用：
;;;;   sbcl --load examples/test-glm47-live.lisp
;;;;   ccl --load examples/test-glm47-live.lisp

;;; ============================================================
;;; 加载系统
;;; ============================================================

(require :asdf)
(asdf:initialize-source-registry)

(format t "~%========================================~%")
(format t "Loading cl-agent-llm...~%")
(ql:quickload :cl-agent-llm :silent t)
(format t "cl-agent-llm loaded successfully!~%")
(format t "========================================~%")

;;; ============================================================
;;; 创建 GLM-4.7 Provider（Anthropic 兼容）
;;; ============================================================

(defparameter *glm-provider*
  (cl-agent.llm.providers:make-anthropic-provider
   :api-url "https://open.bigmodel.cn/api/anthropic"
   :model "glm-4.7"
   :api-key (uiop:getenv "ZHIPU_API_KEY")
   :anthropic-version "2023-06-01"))

(format t "~%Provider created: ~A~%"
        (cl-agent.llm:base-provider-default-model *glm-provider*))

;;; ============================================================
;;; 工具定义
;;; ============================================================

(cl-agent.kernel:deftool get-current-weather "获取指定城市的当前天气信息"
  ((city :string "城市名称" :required-p t)
   (unit :string "温度单位，celsius 或 fahrenheit" :default "celsius"))
  (format nil "~A 当前天气：晴，气温 22°~A，湿度 45%"
          city (if (string-equal unit "fahrenheit") "F" "C")))

(cl-agent.kernel:deftool calculate "计算数学表达式的结果"
  ((expression :string "数学表达式" :required-p t))
  (format nil "计算结果: ~A = ~A"
          expression
          (handler-case (eval (read-from-string expression))
            (error () "计算错误"))))

(cl-agent.kernel:defplugin tools-plugin "测试工具集合"
  get-current-weather
  calculate)

;;; ============================================================
;;; Kernel 实例
;;; ============================================================

(defparameter *kernel*
  (cl-agent.kernel:make-kernel
   :chat-service *glm-provider*
   :plugins '(tools-plugin)))

(defparameter *kernel-with-filter*
  (let ((log nil))
    (cl-agent.kernel:make-kernel
     :chat-service *glm-provider*
     :plugins '(tools-plugin)
     :filters (list (lambda (context next-fn)
                      (push (getf context :tool-name) log)
                      (format t "    [Filter] Executing: ~A~%" (getf context :tool-name))
                      (let ((result (funcall next-fn context)))
                        (format t "    [Filter] Result: ~A~%" result)
                        result))))))

;;; ============================================================
;;; 测试 1: invoke — 直接函数执行（通过 filter chain）
;;; ============================================================

(defun test-invoke ()
  "测试 invoke 直接执行已注册函数"
  (format t "~%========================================~%")
  (format t "TEST 1: invoke (Direct Function Execution)~%")
  (format t "========================================~%")

  ;; 1.1 基本调用
  (format t "~%  1.1 Basic invoke:~%")
  (let ((result (cl-agent.kernel:invoke *kernel* :get-current-weather
                                         '(:city "Beijing"))))
    (format t "    invoke(:get-current-weather, city=Beijing)~%")
    (format t "    Result: ~A~%" result)
    (assert (search "Beijing" result) () "invoke basic failed"))

  ;; 1.2 带 filter 调用
  (format t "~%  1.2 Invoke with filter:~%")
  (let ((result (cl-agent.kernel:invoke *kernel-with-filter* :calculate
                                         '(:expression "(+ 1 2 3)"))))
    (format t "    invoke(:calculate, expression=(+ 1 2 3))~%")
    (format t "    Result: ~A~%" result)
    (assert (search "6" result) () "invoke with filter failed"))

  ;; 1.3 不存在的函数
  (format t "~%  1.3 Invoke not-found:~%")
  (handler-case
      (cl-agent.kernel:invoke *kernel* :nonexistent '())
    (error (e)
      (format t "    Correctly raised error: ~A~%" e)))

  (format t "~%[TEST 1 PASSED]~%"))

;;; ============================================================
;;; 测试 2: invoke-chat 单轮对话
;;; ============================================================

(defun test-invoke-chat-single ()
  "测试 invoke-chat 单轮对话（无工具循环）"
  (format t "~%========================================~%")
  (format t "TEST 2: invoke-chat (Single-turn, No Tool Loop)~%")
  (format t "========================================~%")

  (let* ((messages (list (list :role :user
                               :content "请用一句话解释什么是 Common Lisp。")))
         (response (cl-agent.kernel:invoke-chat *kernel* messages
                     :settings '(:max-tokens 256 :temperature 0.7))))
    (format t "~%  User: 请用一句话解释什么是 Common Lisp。~%")
    (format t "  Response content: ~A~%" (getf response :content))
    (format t "  Tool-calls: ~A~%" (getf response :tool-calls))
    (assert (> (length (getf response :content)) 0)
            () "invoke-chat single turn returned empty content")
    (format t "~%[TEST 2 PASSED]~%")
    response))

;;; ============================================================
;;; 测试 3: invoke-chat 多轮对话
;;; ============================================================

(defun test-invoke-chat-multi ()
  "测试 invoke-chat 多轮对话"
  (format t "~%========================================~%")
  (format t "TEST 3: invoke-chat (Multi-turn)~%")
  (format t "========================================~%")

  ;; 第一轮
  (let* ((messages (list (list :role :user
                               :content "你好，我叫 David。请记住我的名字。")))
         (response1 (cl-agent.kernel:invoke-chat *kernel* messages
                      :settings '(:max-tokens 128 :temperature 0.3)))
         (reply1 (getf response1 :content)))
    (format t "~%  Round 1:~%")
    (format t "    User: 你好，我叫 David。请记住我的名字。~%")
    (format t "    Assistant: ~A~%" reply1)

    ;; 第二轮
    (let* ((messages2 (list (list :role :user
                                  :content "你好，我叫 David。请记住我的名字。")
                            (list :role :assistant :content reply1)
                            (list :role :user :content "我叫什么名字？")))
           (response2 (cl-agent.kernel:invoke-chat *kernel* messages2
                        :settings '(:max-tokens 128 :temperature 0.3)))
           (reply2 (getf response2 :content)))
      (format t "~%  Round 2:~%")
      (format t "    User: 我叫什么名字？~%")
      (format t "    Assistant: ~A~%" reply2)
      (assert (> (length reply2) 0)
              () "invoke-chat multi-turn returned empty response")
      (format t "~%[TEST 3 PASSED]~%")
      response2)))

;;; ============================================================
;;; 测试 4: invoke-chat-with-tools 单轮工具调用
;;; ============================================================

(defun test-invoke-chat-with-tools-single ()
  "测试 invoke-chat-with-tools 单轮工具调用"
  (format t "~%========================================~%")
  (format t "TEST 4: invoke-chat-with-tools (Single-turn + Tools)~%")
  (format t "========================================~%")

  (let* ((messages (list (list :role :user
                               :content "北京今天天气怎么样？")))
         (result (cl-agent.kernel:invoke-chat-with-tools *kernel-with-filter* messages
                   :settings (list :system-prompt "你是天气助手。查询天气时必须使用 get-current-weather 工具。"
                                   :max-attempts 5
                                   :on-tool-call (lambda (name args)
                                                   (format t "    [Tool Call] ~A ~S~%" name args))
                                   :on-tool-result (lambda (name result)
                                                     (format t "    [Tool Result] ~A -> ~A~%" name result))))))
    (format t "~%  User: 北京今天天气怎么样？~%")
    (format t "  Final text: ~A~%" (getf result :text))
    (format t "  Tool calls made: ~A~%" (length (getf result :tool-calls-made)))
    (when (getf result :tool-calls-made)
      (dolist (tc (getf result :tool-calls-made))
        (format t "    - ~A(~S) -> ~A~%"
                (getf tc :name) (getf tc :args) (getf tc :result))))
    (assert (> (length (getf result :text)) 0)
            () "invoke-chat-with-tools returned empty text")
    (format t "~%[TEST 4 PASSED]~%")
    result))

;;; ============================================================
;;; 测试 5: invoke-chat-with-tools 多轮工具调用
;;; ============================================================

(defun test-invoke-chat-with-tools-multi ()
  "测试 invoke-chat-with-tools 多轮对话（含工具调用）"
  (format t "~%========================================~%")
  (format t "TEST 5: invoke-chat-with-tools (Multi-turn + Tools)~%")
  (format t "========================================~%")

  ;; 第一轮：查天气
  (let* ((messages1 (list (list :role :user
                                :content "北京今天天气怎么样？")))
         (result1 (cl-agent.kernel:invoke-chat-with-tools *kernel* messages1
                    :settings (list :system-prompt "你是助手。查询天气用 get-current-weather，计算用 calculate。"
                                    :max-attempts 5
                                    :on-tool-call (lambda (name args)
                                                    (format t "    [R1 Tool Call] ~A ~S~%" name args))))))
    (format t "~%  Round 1:~%")
    (format t "    User: 北京今天天气怎么样？~%")
    (format t "    Assistant: ~A~%" (getf result1 :text))
    (format t "    Tool calls: ~A~%" (length (getf result1 :tool-calls-made)))

    ;; 第二轮：在上一轮历史基础上追加新问题
    (let* ((history (getf result1 :history))
           (messages2 (append history
                              (list (list :role :assistant :content (getf result1 :text))
                                    (list :role :user :content "帮我计算 (+ 10 20 30)"))))
           (result2 (cl-agent.kernel:invoke-chat-with-tools *kernel* messages2
                      :settings (list :system-prompt "你是助手。查询天气用 get-current-weather，计算用 calculate。"
                                      :max-attempts 5
                                      :on-tool-call (lambda (name args)
                                                      (format t "    [R2 Tool Call] ~A ~S~%" name args))))))
      (format t "~%  Round 2:~%")
      (format t "    User: 帮我计算 (+ 10 20 30)~%")
      (format t "    Assistant: ~A~%" (getf result2 :text))
      (format t "    Tool calls: ~A~%" (length (getf result2 :tool-calls-made)))
      (assert (> (length (getf result2 :text)) 0)
              () "Multi-turn invoke-chat-with-tools returned empty text")
      (format t "~%[TEST 5 PASSED]~%")
      result2)))

;;; ============================================================
;;; 测试 6: chat-completion 向后兼容
;;; ============================================================

(defun test-chat-completion-compat ()
  "测试 chat-completion 向后兼容"
  (format t "~%========================================~%")
  (format t "TEST 6: chat-completion (Backward Compatibility)~%")
  (format t "========================================~%")

  (let* ((history (cl-agent.kernel:make-chat-history)))
    (cl-agent.kernel:history-add history :user "北京今天天气怎么样？")

    (format t "~%  User: 北京今天天气怎么样？~%")
    (format t "  Calling chat-completion (legacy API)...~%")

    (let ((result (cl-agent.kernel:chat-completion *kernel* history
                    :settings (list :system-prompt "你是天气助手。查询天气时使用 get-current-weather 工具。"
                                    :max-attempts 5
                                    :on-tool-call (lambda (name args)
                                                    (format t "    [Tool Call] ~A ~S~%" name args))
                                    :on-tool-result (lambda (name result)
                                                      (format t "    [Tool Result] ~A -> ~A~%" name result))))))
      (format t "~%  Final text: ~A~%" (getf result :text))
      (format t "  Tool calls made: ~A~%" (length (getf result :tool-calls-made)))
      (assert (> (length (getf result :text)) 0)
              () "chat-completion backward compat failed")
      (format t "~%[TEST 6 PASSED]~%")
      result)))

;;; ============================================================
;;; 运行所有测试
;;; ============================================================

(defun run-all-tests ()
  "运行所有测试"
  (format t "~%~%")
  (format t "+==============================================+~%")
  (format t "|  CL-Agent Three-Level Invoke API Live Test   |~%")
  (format t "|  Provider: GLM-4.7 (Anthropic-compatible)    |~%")
  (format t "|  URL: open.bigmodel.cn/api/anthropic         |~%")
  (format t "+==============================================+~%")
  (format t "~%Implementation: ~A ~A~%"
          (lisp-implementation-type)
          (lisp-implementation-version))

  (let ((test-names '(:invoke
                      :invoke-chat-single
                      :invoke-chat-multi
                      :invoke-chat-with-tools-single
                      :invoke-chat-with-tools-multi
                      :chat-completion-compat))
        (test-fns (list #'test-invoke
                        #'test-invoke-chat-single
                        #'test-invoke-chat-multi
                        #'test-invoke-chat-with-tools-single
                        #'test-invoke-chat-with-tools-multi
                        #'test-chat-completion-compat))
        (results nil)
        (errors nil)
        (total 6))

    (loop for name in test-names
          for fn in test-fns
          for i from 1
          do (handler-case
                 (progn (funcall fn)
                        (push name results))
               (error (e)
                 (format t "~%[TEST ~A FAILED] ~A~%" i e)
                 (push (cons name e) errors))))

    ;; Summary
    (format t "~%~%========================================~%")
    (format t "TEST SUMMARY~%")
    (format t "========================================~%")
    (format t "Passed: ~A/~A~%" (length results) total)
    (when errors
      (format t "Failed: ~A/~A~%" (length errors) total)
      (dolist (err errors)
        (format t "  FAIL: ~A - ~A~%" (car err) (cdr err))))
    (format t "========================================~%~%")

    (if errors
        (progn (format t "SOME TESTS FAILED~%")
               (values nil errors))
        (progn (format t "ALL TESTS PASSED!~%")
               (values t results)))))

;; 运行测试
(run-all-tests)

;; 退出
#+sbcl (sb-ext:exit :code 0)
#+ccl (ccl:quit 0)
