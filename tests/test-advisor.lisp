;;;; test-advisor.lisp
;;;; CL-Agent - Advisor 协议、洋葱链与 defadvisor 宏测试

(in-package :cl-agent/tests)

(def-suite advisor-suite :in cl-agent-suite
  :description "Advisor 协议 / 有序洋葱链 / defadvisor / 内置 Advisor")

(in-suite advisor-suite)

;;; ============================================================
;;; 测试 Advisor（defadvisor 宏展开发生在编译期）
;;; ============================================================

(cl-agent.client:defadvisor trace-advisor
    (:order 0 :documentation "记录执行顺序")
  (:slots ((tag :initarg :tag :reader trace-tag)
           (log :initarg :log :reader trace-log
                :documentation "共享记录器（cons cell 装列表）")))
  (:call (advisor request chain)
    (push (list :before (trace-tag advisor)) (car (trace-log advisor)))
    (let ((response (cl-agent.client:chain-next chain request)))
      (push (list :after (trace-tag advisor)) (car (trace-log advisor)))
      response)))

(cl-agent.client:defadvisor rewrite-advisor
    (:order 0 :documentation "把用户输入改写为固定文本")
  (:slots ((replacement :initarg :replacement :reader rewrite-replacement)))
  (:call (advisor request chain)
    (cl-agent.client:chain-next
     chain
     (cl-agent.client:client-request-copy
      request
      :prompt (cl-agent.chat:make-prompt
               (rewrite-replacement advisor)
               :options (cl-agent.chat:prompt-options
                         (cl-agent.client:client-request-prompt request)))))))

(cl-agent.client:defadvisor short-circuit-advisor
    (:order -999 :documentation "不调下游直接返回")
  (:call (advisor request chain)
    (declare (ignore advisor chain))
    (cl-agent.client:make-client-response
     (cl-agent.chat:make-chat-response
      (cl-agent.chat:make-generation
       (cl-agent.chat:assistant-message "被短路了") :finish-reason :stop))
     :context (cl-agent.client:client-request-context request))))

;;; ============================================================
;;; defadvisor 宏产物
;;; ============================================================

(test defadvisor-generates-class-and-constructor
  "defadvisor 生成类、方法与 make- 构造函数"
  (let ((advisor (make-trace-advisor :tag :x :log (list nil))))
    (is (typep advisor 'cl-agent.client:advisor))
    (is (= 0 (cl-agent.client:advisor-order advisor)))
    (is (string= "trace-advisor" (cl-agent.client:advisor-name advisor)))))

(test defadvisor-order-initarg
  ":order 可在实例化时覆盖"
  (is (= 42 (cl-agent.client:advisor-order (make-trace-advisor :tag :x :log (list nil)
                                                               :order 42)))))

;;; ============================================================
;;; 洋葱链
;;; ============================================================

(defun run-chain (advisors &key (result "终端结果"))
  "用同步终端跑一条链，返回 client-response"
  (cl-agent.client:chain-next
   (cl-agent.client:make-advisor-chain
    advisors
    (lambda (request)
      (cl-agent.client:make-client-response
       (cl-agent.chat:make-chat-response
        (cl-agent.chat:make-generation
         (cl-agent.chat:assistant-message result) :finish-reason :stop))
       :context (cl-agent.client:client-request-context request))))
   (cl-agent.client:make-client-request (cl-agent.chat:make-prompt "hi"))))

(test chain-onion-order
  "链按 order 升序排列，洋葱式前后包裹"
  (let* ((log (list nil))
         (outer (make-trace-advisor :tag :outer :log log :order -10))
         (inner (make-trace-advisor :tag :inner :log log :order 10)))
    ;; 传入顺序故意颠倒，验证排序
    (run-chain (list inner outer))
    (is (equal '((:before :outer) (:before :inner)
                 (:after :inner) (:after :outer))
               (reverse (car log))))))

(test chain-stable-order
  "同 order 保持注册顺序（稳定排序）"
  (let* ((log (list nil))
         (a (make-trace-advisor :tag :a :log log))
         (b (make-trace-advisor :tag :b :log log)))
    (run-chain (list a b))
    (is (equal '((:before :a) (:before :b) (:after :b) (:after :a))
               (reverse (car log))))))

(test chain-request-rewrite
  "Advisor 可改写 request 后传递下游"
  (let* ((seen nil)
         (response (cl-agent.client:chain-next
                    (cl-agent.client:make-advisor-chain
                     (list (make-rewrite-advisor :replacement "改写后"))
                     (lambda (request)
                       (setf seen (cl-agent.chat:prompt-last-user-text
                                   (cl-agent.client:client-request-prompt request)))
                       (cl-agent.client:make-client-response
                        (cl-agent.chat:make-chat-response
                         (cl-agent.chat:make-generation
                          (cl-agent.chat:assistant-message "ok")))
                        :context (cl-agent.client:client-request-context request))))
                    (cl-agent.client:make-client-request
                     (cl-agent.chat:make-prompt "原始输入")))))
    (declare (ignore response))
    (is (string= "改写后" seen))))

(test chain-short-circuit
  "Advisor 短路时终端不被调用"
  (let* ((terminal-called nil)
         (response (cl-agent.client:chain-next
                    (cl-agent.client:make-advisor-chain
                     (list (make-short-circuit-advisor))
                     (lambda (request)
                       (declare (ignore request))
                       (setf terminal-called t)
                       (error "不应到达终端")))
                    (cl-agent.client:make-client-request
                     (cl-agent.chat:make-prompt "hi")))))
    (is-false terminal-called)
    (is (string= "被短路了"
                 (cl-agent.chat:chat-response-text
                  (cl-agent.client:client-response-chat-response response))))))

(test chain-context-sharing
  "request/response context 贯通共享"
  (let ((response
          (cl-agent.client:chain-next
           (cl-agent.client:make-advisor-chain
            nil
            (lambda (request)
              (cl-agent.client:context-set request "from-terminal" 99)
              (cl-agent.client:make-client-response
               (cl-agent.chat:make-chat-response
                (cl-agent.chat:make-generation
                 (cl-agent.chat:assistant-message "ok")))
               :context (cl-agent.client:client-request-context request))))
           (let ((request (cl-agent.client:make-client-request
                           (cl-agent.chat:make-prompt "hi"))))
             (cl-agent.client:context-set request "from-caller" 1)
             request))))
    (is (= 1 (cl-agent.client:context-get response "from-caller")))
    (is (= 99 (cl-agent.client:context-get response "from-terminal")))
    (is (eq :missing (cl-agent.client:context-get response "nope" :missing)))))

;;; ============================================================
;;; 内置 Advisor：记忆
;;; ============================================================

(test message-memory-advisor-augments-and-saves
  "消息记忆：注入历史 + 保存新消息与回复"
  (let* ((memory (cl-agent.chat:make-message-window-chat-memory))
         (advisor (cl-agent.client:make-message-chat-memory-advisor :memory memory))
         (seen-counts nil)
         (terminal (lambda (request)
                     (push (length (cl-agent.chat:prompt-messages
                                    (cl-agent.client:client-request-prompt request)))
                           seen-counts)
                     (cl-agent.client:make-client-response
                      (cl-agent.chat:make-chat-response
                       (cl-agent.chat:make-generation
                        (cl-agent.chat:assistant-message "回复")))
                      :context (cl-agent.client:client-request-context request))))
         (run (lambda (text)
                (cl-agent.client:chain-next
                 (cl-agent.client:make-advisor-chain (list advisor) terminal)
                 (cl-agent.client:make-client-request
                  (cl-agent.chat:make-prompt text))))))
    (funcall run "第一轮")
    (funcall run "第二轮")
    ;; 第一轮 1 条消息，第二轮 = 历史(user+assistant) + 新 user = 3 条
    (is (equal '(1 3) (reverse seen-counts)))
    ;; 记忆中：user assistant user assistant
    (is (equal '(:user :assistant :user :assistant)
               (mapcar #'cl-agent.chat:message-role
                       (cl-agent.chat:memory-messages
                        memory cl-agent.chat:+default-conversation-id+))))))

(test message-memory-advisor-conversation-isolation
  "不同 conversation-id 的记忆相互隔离"
  (let* ((memory (cl-agent.chat:make-message-window-chat-memory))
         (advisor (cl-agent.client:make-message-chat-memory-advisor :memory memory))
         (terminal (lambda (request)
                     (cl-agent.client:make-client-response
                      (cl-agent.chat:make-chat-response
                       (cl-agent.chat:make-generation
                        (cl-agent.chat:assistant-message "ok")))
                      :context (cl-agent.client:client-request-context request))))
         (run (lambda (text cid)
                (let ((request (cl-agent.client:make-client-request
                                (cl-agent.chat:make-prompt text))))
                  (cl-agent.client:context-set
                   request cl-agent.client:+conversation-id-key+ cid)
                  (cl-agent.client:chain-next
                   (cl-agent.client:make-advisor-chain (list advisor) terminal)
                   request)))))
    (funcall run "甲的话" "conv-a")
    (funcall run "乙的话" "conv-b")
    (is (= 2 (length (cl-agent.chat:memory-messages memory "conv-a"))))
    (is (= 2 (length (cl-agent.chat:memory-messages memory "conv-b"))))
    (is (string= "甲的话"
                 (cl-agent.chat:message-text
                  (first (cl-agent.chat:memory-messages memory "conv-a")))))))

(test prompt-memory-advisor-injects-text
  "提示词记忆：历史渲染进 system 消息"
  (let* ((memory (cl-agent.chat:make-message-window-chat-memory))
         (advisor (cl-agent.client:make-prompt-chat-memory-advisor :memory memory))
         (last-system nil)
         (terminal (lambda (request)
                     (let ((systems (cl-agent.chat:prompt-system-messages
                                     (cl-agent.client:client-request-prompt request))))
                       (setf last-system (when systems
                                           (cl-agent.chat:message-text (first systems)))))
                     (cl-agent.client:make-client-response
                      (cl-agent.chat:make-chat-response
                       (cl-agent.chat:make-generation
                        (cl-agent.chat:assistant-message "回复")))
                      :context (cl-agent.client:client-request-context request))))
         (run (lambda (text)
                (cl-agent.client:chain-next
                 (cl-agent.client:make-advisor-chain (list advisor) terminal)
                 (cl-agent.client:make-client-request
                  (cl-agent.chat:make-prompt text :system "你是助手"))))))
    (funcall run "我叫大卫")
    (funcall run "我叫什么")
    (is (search "USER: 我叫大卫" last-system))
    (is (search "ASSISTANT: 回复" last-system))
    (is (search "你是助手" last-system))))

;;; ============================================================
;;; 内置 Advisor：护栏与日志
;;; ============================================================

(test safe-guard-blocks
  "命中敏感词短路，未命中放行"
  (let* ((advisor (cl-agent.client:make-safe-guard-advisor
                   :sensitive-words '("违禁品")
                   :failure-response "无法协助"))
         (terminal-hits 0)
         (terminal (lambda (request)
                     (incf terminal-hits)
                     (cl-agent.client:make-client-response
                      (cl-agent.chat:make-chat-response
                       (cl-agent.chat:make-generation
                        (cl-agent.chat:assistant-message "正常回复")))
                      :context (cl-agent.client:client-request-context request))))
         (run (lambda (text)
                (cl-agent.chat:chat-response-text
                 (cl-agent.client:client-response-chat-response
                  (cl-agent.client:chain-next
                   (cl-agent.client:make-advisor-chain (list advisor) terminal)
                   (cl-agent.client:make-client-request
                    (cl-agent.chat:make-prompt text))))))))
    (is (string= "无法协助" (funcall run "哪里买违禁品")))
    (is (= 0 terminal-hits))
    (is (string= "正常回复" (funcall run "今天天气如何")))
    (is (= 1 terminal-hits))))

(test logger-advisor-writes-stream
  "日志 Advisor 输出请求与响应摘要"
  (let* ((out (make-string-output-stream))
         (advisor (cl-agent.client:make-simple-logger-advisor :stream out)))
    (run-chain (list advisor))
    (let ((logged (get-output-stream-string out)))
      (is (search "request:" logged))
      (is (search "response:" logged))
      (is (search "终端结果" logged)))))
