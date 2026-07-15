;;;; test-tool-advisor.lisp
;;;; CL-Agent - ToolCallingAdvisor 测试（Spring AI 2.0 架构）
;;;;
;;;; 覆盖：
;;;;   - 递归工具循环（重入下游链直到无 tool-calls）
;;;;   - return-direct 短路 / max-iterations 上限
;;;;   - ChatClient 自动注册与禁用（user-controlled 模式）
;;;;   - 记忆 Advisor 在循环外（默认布局）只记录最终问答
;;;;   - 循环内侧 Advisor 每轮执行
;;;;   - 流式工具循环

(in-package :cl-agent/tests)

(def-suite tool-advisor-suite :in cl-agent-suite
  :description "tool-calling-advisor：递归工具循环（2.0 编排层）")

(in-suite tool-advisor-suite)

(defun make-tool-loop-client (&rest responses)
  "顺序响应客户端（自动注册 tool-calling-advisor），
返回 (values client provider)"
  (let ((provider (apply #'make-seq-provider responses)))
    (values (cl-agent.client:make-chat-client
             (cl-agent.chat:make-provider-chat-model provider))
            provider)))

;;; ============================================================
;;; 递归循环
;;; ============================================================

(test advisor-tool-loop-roundtrip
  "tool-call → 执行 → 结果回传模型 → 最终文本"
  (multiple-value-bind (client provider)
      (make-tool-loop-client
       (tool-call-response "test_adder" '(("a" . 3) ("b" . 4)))
       (lambda (messages)
         ;; 第二轮请求应包含 assistant(tool-calls) + tool 结果
         (let ((tool-msg (find :tool messages
                               :key (lambda (m) (getf m :role)))))
           (assert tool-msg)
           (assert (string= "7" (getf tool-msg :content))))
         (text-response "3+4=7")))
    (is (string= "3+4=7"
                 (cl-agent.client:chat client
                   (:user "3+4=?")
                   (:tools 'test-adder))))
    ;; provider 被调用两轮，两轮都带工具 schema
    (is (= 2 (length (seq-provider-requests provider))))
    (is (every (lambda (req) (= 1 (length (getf req :tools))))
               (seq-provider-requests provider)))))

(test advisor-return-direct
  "return-direct 工具结果直接作为最终答案，不再回传模型"
  (multiple-value-bind (client provider)
      (make-tool-loop-client
       (tool-call-response "test_direct_tool" '(("text" . "急停"))))
    (is (string= "直接结果：急停"
                 (cl-agent.client:chat client
                   (:user "go")
                   (:tools 'test-direct-tool))))
    (is (= 1 (length (seq-provider-requests provider))))))

(test advisor-max-iterations
  "循环超过上限报 max-tool-iterations-exceeded-error"
  (let* ((provider (make-instance
                    'seq-provider
                    :queue (loop repeat 10
                                 collect (tool-call-response
                                          "test_adder" '(("a" . 1) ("b" . 1))))))
         (client (cl-agent.client:make-chat-client
                  (cl-agent.chat:make-provider-chat-model provider)
                  ;; 显式提供小上限的 advisor（覆盖自动注册）
                  :advisors (list (cl-agent.client:make-tool-calling-advisor
                                   :max-iterations 3)))))
    (signals cl-agent.chat:max-tool-iterations-exceeded-error
      (cl-agent.client:chat client
        (:user "loop")
        (:tools 'test-adder)))))

(test advisor-no-tools-passthrough
  "未配置工具时循环立即返回（不误入死循环）"
  (multiple-value-bind (client provider)
      (make-tool-loop-client (text-response "普通回答"))
    (is (string= "普通回答" (cl-agent.client:chat client "你好")))
    (is (= 1 (length (seq-provider-requests provider))))))

;;; ============================================================
;;; 自动注册 / user-controlled
;;; ============================================================

(test advisor-auto-registration
  "ChatClient 自动追加 tool-calling-advisor；链中已有则不重复"
  (let ((client (cl-agent.client:make-chat-client
                 (cl-agent.chat:make-provider-chat-model
                  (make-seq-provider (text-response "ok"))))))
    (let ((advisors (cl-agent.client::spec-effective-advisors
                     (cl-agent.client:client-prompt client))))
      (is (= 1 (count-if (lambda (a)
                           (typep a 'cl-agent.client:tool-calling-advisor))
                         advisors)))))
  ;; 显式提供时不重复注册
  (let ((client (cl-agent.client:make-chat-client
                 (cl-agent.chat:make-provider-chat-model
                  (make-seq-provider (text-response "ok")))
                 :advisors (list (cl-agent.client:make-tool-calling-advisor
                                  :max-iterations 5)))))
    (let ((advisors (cl-agent.client::spec-effective-advisors
                     (cl-agent.client:client-prompt client))))
      (is (= 1 (count-if (lambda (a)
                           (typep a 'cl-agent.client:tool-calling-advisor))
                         advisors))))))

(test advisor-user-controlled-mode
  "禁用自动注册：tool-calls 响应原样返回，调用方手动驱动循环"
  (let* ((provider (make-seq-provider
                    (tool-call-response "test_adder" '(("a" . 2) ("b" . 5)))
                    (text-response "2+5=7")))
         (model (cl-agent.chat:make-provider-chat-model provider))
         (client (cl-agent.client:make-chat-client
                  model :auto-tool-advisor nil))
         (response (cl-agent.client:chat client
                     (:user "2+5=?")
                     (:tools 'test-adder)
                     (:call :response))))
    ;; 第一步：原样拿到 tool-calls（框架未代执行）
    (is-true (cl-agent.chat:chat-response-has-tool-calls-p response))
    (is (= 1 (length (seq-provider-requests provider))))
    ;; 第二步：手动执行工具并续跑（对标 user-controlled execution）
    (let* ((manager (cl-agent.chat:make-default-tool-calling-manager))
           (prompt (cl-agent.chat:make-prompt
                    (list (cl-agent.chat:user-message "2+5=?"))
                    :options (cl-agent.chat:make-chat-options
                              :tool-callbacks
                              (cl-agent.chat:resolve-tool-callbacks
                               '(test-adder)))))
           (result (cl-agent.chat:execute-tool-calls manager prompt response))
           (final (cl-agent.chat:chat-model-call
                   model
                   (cl-agent.chat:make-prompt
                    (cl-agent.chat:tool-execution-conversation-history result)))))
      (is (string= "2+5=7" (cl-agent.chat:chat-response-text final))))))

;;; ============================================================
;;; 与其他 Advisor 的组合语义
;;; ============================================================

(test advisor-memory-outside-loop
  "记忆 Advisor（order 1000）在循环外：只记最终问答，
工具轮次的中间消息不入记忆（对标 Spring 默认布局）"
  (let* ((provider (make-seq-provider
                    (tool-call-response "test_adder" '(("a" . 1) ("b" . 2)))
                    (text-response "1+2=3")))
         (memory (cl-agent.chat:make-message-window-chat-memory))
         (client (cl-agent.client:make-chat-client
                  (cl-agent.chat:make-provider-chat-model provider)
                  :advisors (list (cl-agent.client:make-message-chat-memory-advisor
                                   :memory memory)))))
    (is (string= "1+2=3"
                 (cl-agent.client:chat client
                   (:user "1+2=?")
                   (:tools 'test-adder)
                   (:conversation "tc-mem"))))
    ;; 记忆只有 user + 最终 assistant，两条；工具轮次不入库
    (let ((messages (cl-agent.chat:memory-messages memory "tc-mem")))
      (is (= 2 (length messages)))
      (is (equal '(:user :assistant)
                 (mapcar #'cl-agent.chat:message-role messages))))))

(test advisor-inner-advisor-runs-each-iteration
  "循环内侧（order > 2000）的 Advisor 每轮工具循环都执行"
  (let* ((provider (make-seq-provider
                    (tool-call-response "test_adder" '(("a" . 1) ("b" . 1)))
                    (text-response "2")))
         (log (list nil))
         (inner (make-trace-advisor :tag :inner :log log :order 3000))
         (client (cl-agent.client:make-chat-client
                  (cl-agent.chat:make-provider-chat-model provider)
                  :advisors (list inner))))
    (cl-agent.client:chat client (:user "1+1=?") (:tools 'test-adder))
    ;; 两轮模型调用 → inner 执行两次（before/after 各两条）
    (is (= 2 (count '(:before :inner) (car log) :test #'equal)))
    (is (= 2 (count '(:after :inner) (car log) :test #'equal)))))

;;; ============================================================
;;; conversation-history-enabled（对标 2.0 的同名开关）
;;; ============================================================

(test advisor-conversation-history-enabled-by-default
  "默认在循环内部维护完整会话历史：第二轮带上 assistant(tool-calls) + tool 结果"
  (multiple-value-bind (client provider)
      (make-tool-loop-client
       (tool-call-response "test_adder" '(("a" . 3) ("b" . 4)))
       (text-response "7"))
    (cl-agent.client:chat client (:user "3+4=?") (:tools 'test-adder))
    (let ((second-round (first (seq-provider-requests provider))))
      ;; 完整历史：user + assistant(tool-calls) + tool 结果
      (is (member :tool (getf second-round :messages)
                  :key (lambda (m) (getf m :role))))
      (is (member :assistant (getf second-round :messages)
                  :key (lambda (m) (getf m :role)))))))

(test advisor-conversation-history-disabled-trims-to-last
  "关闭内部会话历史：下一轮只带 system + 最后一条消息"
  (let* ((provider (make-seq-provider
                    (tool-call-response "test_adder" '(("a" . 3) ("b" . 4)))
                    (text-response "7")))
         (client (cl-agent.client:make-chat-client
                  (cl-agent.chat:make-provider-chat-model provider)
                  :system "你是助手"
                  :advisors (list (cl-agent.client:make-tool-calling-advisor
                                   :conversation-history-enabled nil)))))
    (cl-agent.client:chat client (:user "3+4=?") (:tools 'test-adder))
    (let* ((second-round (first (seq-provider-requests provider)))
           (roles (mapcar (lambda (m) (getf m :role))
                          (getf second-round :messages))))
      ;; 只剩 system + 最后一条（工具结果），中间的 user/assistant 被裁掉
      (is (equal '(:system :tool) roles)))))

(test advisor-history-disabled-with-inner-memory-rebuilds-history
  "关闭内部历史 + 记忆 Advisor 在循环内侧：每轮迭代重建出合法的完整历史。

这是 conversation-history-enabled NIL 的正确用法。记忆 Advisor 若放在
默认 order（循环外）只会执行一次，下一轮 prompt 退化成 [system, 工具结果]，
工具结果缺少对应的 assistant 工具调用消息，真实提供商会返回 HTTP 400。"
  (let* ((provider (make-seq-provider
                    (tool-call-response "test_adder" '(("a" . 3) ("b" . 4)))
                    (text-response "7")))
         (memory (cl-agent.chat:make-message-window-chat-memory))
         (client (cl-agent.client:make-chat-client
                  (cl-agent.chat:make-provider-chat-model provider)
                  :system "你是助手"
                  :advisors (list (cl-agent.client:make-message-chat-memory-advisor
                                   :memory memory
                                   :order (1+ cl-agent.client:+tool-calling-advisor-order+))
                                  (cl-agent.client:make-tool-calling-advisor
                                   :conversation-history-enabled nil)))))
    (cl-agent.client:chat client (:user "3+4=?") (:tools 'test-adder))
    (let* ((second-round (first (seq-provider-requests provider)))
           (roles (mapcar (lambda (m) (getf m :role))
                          (getf second-round :messages))))
      ;; 记忆把 user 与 assistant(tool-calls) 补了回来，工具结果前有对应的工具调用
      (is (equal '(:system :user :assistant :tool) roles)))))

(test advisor-memory-advisor-marker
  "memory-advisor-p 标记（对标 MemoryAdvisor 标记接口）：
tool-calling-advisor 用它检查关闭内部历史时链上是否具备重建历史的能力"
  (is (cl-agent.client:memory-advisor-p
       (cl-agent.client:make-message-chat-memory-advisor
        :memory (cl-agent.chat:make-message-window-chat-memory))))
  (is (not (cl-agent.client:memory-advisor-p
            (cl-agent.client:make-tool-calling-advisor))))
  (is (not (cl-agent.client:memory-advisor-p
            (cl-agent.client:make-simple-logger-advisor)))))

;;; ============================================================
;;; eligibility（对标 ToolExecutionEligibilityChecker）
;;; ============================================================

(test advisor-eligibility-can-suppress-tool-execution
  "自定义 eligibility 返回 NIL 时不执行工具，带 tool-calls 的响应直接返回"
  (let* ((provider (make-seq-provider
                    (tool-call-response "test_adder" '(("a" . 1) ("b" . 1)))))
         (client (cl-agent.client:make-chat-client
                  (cl-agent.chat:make-provider-chat-model provider)
                  :advisors (list (cl-agent.client:make-tool-calling-advisor
                                   :eligibility (lambda (chat-response)
                                                  (declare (ignore chat-response))
                                                  nil)))))
         (response (cl-agent.client:chat client
                     (:user "1+1=?")
                     (:tools 'test-adder)
                     (:call :response))))
    ;; 只调一次模型；工具未执行，tool-calls 原样返回给调用方
    (is (= 1 (length (seq-provider-requests provider))))
    (is (cl-agent.chat:chat-response-has-tool-calls-p response))))

(test advisor-default-eligibility-predicate
  "默认判定：响应为 NIL 或无 tool-calls 时不执行工具"
  (is (not (cl-agent.client:default-tool-execution-eligible-p nil)))
  (is (not (cl-agent.client:default-tool-execution-eligible-p
            (cl-agent.chat:make-chat-response
             (cl-agent.chat:make-generation
              (cl-agent.chat:assistant-message "纯文本")))))))

;;; ============================================================
;;; next-instructions 钩子（对标 doGetNextInstructionsForToolCall）
;;; ============================================================

(defclass drop-tool-messages-advisor (cl-agent.client:tool-calling-advisor)
  ()
  (:documentation "测试用：把下一轮消息裁成只剩最后一条"))

(defmethod cl-agent.client:tool-advisor-next-instructions
    ((advisor drop-tool-messages-advisor) request response result)
  (declare (ignore request response))
  (last (cl-agent.chat:tool-execution-conversation-history result)))

(test advisor-next-instructions-hook-rewrites-next-round
  "特化 next-instructions 钩子即可改写下一轮的消息列表"
  (let* ((provider (make-seq-provider
                    (tool-call-response "test_adder" '(("a" . 3) ("b" . 4)))
                    (text-response "7")))
         (client (cl-agent.client:make-chat-client
                  (cl-agent.chat:make-provider-chat-model provider)
                  :advisors (list (make-instance 'drop-tool-messages-advisor)))))
    (cl-agent.client:chat client (:user "3+4=?") (:tools 'test-adder))
    (let ((second-round (first (seq-provider-requests provider))))
      (is (= 1 (length (getf second-round :messages))))
      (is (eq :tool (getf (first (getf second-round :messages)) :role))))))

;;; ============================================================
;;; 流式工具循环
;;; ============================================================

(test advisor-streaming-tool-loop
  "流式请求的工具循环：每轮走流式下游，文本增量全程透传"
  (multiple-value-bind (client provider)
      (make-tool-loop-client
       (tool-call-response "test_adder" '(("a" . 4) ("b" . 4)))
       (text-response "4+4=8"))
    (let ((chunks nil))
      (cl-agent.client:chat client
        (:user "4+4=?")
        (:tools 'test-adder)
        (:stream (lambda (delta) (push delta chunks))))
      ;; 两轮模型调用；最终文本经流式回调到达
      (is (= 2 (length (seq-provider-requests provider))))
      (is (member "4+4=8" chunks :test #'string=)))))
