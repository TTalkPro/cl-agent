;;;; test-chat-client.lisp
;;;; CL-Agent - ChatClient 测试（Builder / fluent spec / chat 宏 / 集成）

(in-package :cl-agent/tests)

(def-suite chat-client-suite :in cl-agent-suite
  :description "ChatClient Builder、fluent API、chat 宏与端到端集成")

(in-suite chat-client-suite)

(defun make-test-client (&rest responses)
  "顺序响应的测试客户端，返回 (values client provider)"
  (let* ((provider (apply #'make-seq-provider responses))
         (model (cl-agent.chat:make-provider-chat-model provider)))
    (values (cl-agent.client:make-chat-client model) provider)))

;;; ============================================================
;;; Builder
;;; ============================================================

(test builder-fluent-construction
  "Builder 链式构建（配合 -> 线程宏语义：每步返回 builder）"
  (let* ((provider (make-seq-provider (text-response "ok")))
         (model (cl-agent.chat:make-provider-chat-model provider))
         (builder (cl-agent.client:chat-client-builder model))
         (client (cl-agent.client:build-client
                  (cl-agent.client:default-system builder "默认系统"))))
    (is (typep client 'cl-agent.client:chat-client))
    ;; 默认 system 生效
    (cl-agent.client:call-content
     (cl-agent.client:prompt-user (cl-agent.client:client-prompt client) "hi"))
    (let ((messages (getf (first (seq-provider-requests provider)) :messages)))
      (is (string= "默认系统" (getf (first messages) :content))))))

(test builder-default-options
  "Builder 默认 options 下发"
  (let* ((provider (make-seq-provider (text-response "ok")))
         (model (cl-agent.chat:make-provider-chat-model provider))
         (client (cl-agent.client:build-client
                  (cl-agent.client:default-options
                   (cl-agent.client:chat-client-builder model)
                   (cl-agent.chat:make-chat-options :max-tokens 77)))))
    (cl-agent.client:chat client "hi")
    (is (= 77 (getf (first (seq-provider-requests provider)) :max-tokens)))))

;;; ============================================================
;;; fluent 请求 spec
;;; ============================================================

(test fluent-call-content
  "prompt-user → call-content"
  (let ((client (make-test-client (text-response "你好！"))))
    (is (string= "你好！"
                 (cl-agent.client:call-content
                  (cl-agent.client:prompt-user
                   (cl-agent.client:client-prompt client) "你好"))))))

(test fluent-format-args
  "prompt-user 的 format 控制串"
  (multiple-value-bind (client provider) (make-test-client (text-response "ok"))
    (cl-agent.client:call-content
     (cl-agent.client:prompt-user
      (cl-agent.client:client-prompt client) "~A 的天气" "东京"))
    (let ((messages (getf (first (seq-provider-requests provider)) :messages)))
      (is (string= "东京 的天气" (getf (first messages) :content))))))

(test fluent-call-response
  "call-response 返回 chat-response"
  (let ((client (make-test-client (text-response "内容"))))
    (let ((response (cl-agent.client:call-response
                     (cl-agent.client:prompt-user
                      (cl-agent.client:client-prompt client) "hi"))))
      (is (typep response 'cl-agent.chat:chat-response))
      (is (eq :stop (cl-agent.chat:chat-response-finish-reason response))))))

(test fluent-requires-user-input
  "缺少用户输入时报错"
  (let ((client (make-test-client (text-response "ok"))))
    (signals error
      (cl-agent.client:call-content (cl-agent.client:client-prompt client)))))

(test client-prompt-with-initial-text
  "client-prompt 可直接携带用户文本（对标 prompt(userText)）"
  (let ((client (make-test-client (text-response "ok"))))
    (is (string= "ok" (cl-agent.client:call-content
                       (cl-agent.client:client-prompt client "你好"))))))

;;; ============================================================
;;; chat 宏
;;; ============================================================

(test chat-macro-shorthand
  "(chat client \"文本\") 简写"
  (let ((client (make-test-client (text-response "简写响应"))))
    (is (string= "简写响应" (cl-agent.client:chat client "你好")))))

(test chat-macro-clauses
  ":system/:user/:options 子句"
  (multiple-value-bind (client provider)
      (make-test-client (text-response "ok"))
    (cl-agent.client:chat client
      (:system "你是~A" "翻译")
      (:user "翻译：~A" "hello")
      (:options :temperature 0.1))
    (let* ((request (first (seq-provider-requests provider)))
           (messages (getf request :messages)))
      (is (string= "你是翻译" (getf (first messages) :content)))
      (is (string= "翻译：hello" (getf (second messages) :content)))
      (is (= 0.1 (getf request :temperature))))))

(test chat-macro-call-response
  "(:call :response) 返回 chat-response"
  (let ((client (make-test-client (text-response "ok"))))
    (is (typep (cl-agent.client:chat client
                 (:user "hi")
                 (:call :response))
               'cl-agent.chat:chat-response))))

(test chat-macro-entity
  "(:call :entity) 解析 JSON（容忍代码围栏）"
  (let ((client (make-test-client
                 (text-response "```json
{\"city\": \"东京\", \"temp\": 22}
```"))))
    (let ((entity (cl-agent.client:chat client
                    (:user "东京天气，用 JSON 回答")
                    (:call :entity))))
      (is (string= "东京" (gethash "city" entity)))
      (is (= 22 (gethash "temp" entity))))))

(test chat-macro-stream
  "(:stream fn) 流式回调"
  (let ((client (make-test-client (text-response "流式文本")))
        (chunks nil))
    (cl-agent.client:chat client
      (:user "hi")
      (:stream (lambda (delta) (push delta chunks))))
    (is (equal '("流式文本") (reverse chunks)))))

;;; ============================================================
;;; 端到端集成
;;; ============================================================

(test integration-tools-via-client
  "ChatClient + deftool 工具端到端"
  (multiple-value-bind (client provider)
      (make-test-client
       (tool-call-response "test_adder" '(("a" . 10) ("b" . 20)))
       (text-response "10+20=30"))
    (is (string= "10+20=30"
                 (cl-agent.client:chat client
                   (:user "10+20=?")
                   (:tools 'test-adder))))
    (is (= 2 (length (seq-provider-requests provider))))))

;;; ============================================================
;;; Advisor 集成测试已移除（advisor 系统退役）
;;; memory/safeguard/logger 的等价功能由 kernel filter 提供：
;;; - cl-agent.kernel:memory-filter
;;; - cl-agent.kernel:safeguard-turn-filter
;;; - cl-agent.kernel:logging-chat-filter
;;; ============================================================
