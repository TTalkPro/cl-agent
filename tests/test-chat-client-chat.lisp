;;;; test-chat-client-chat.lisp
;;;; CL-Agent - chat-client 的 chat 宏 DSL 测试
;;;;
;;;; 前身是 test-chat-client.lisp。Builder / fluent RequestSpec
;;;; （client-prompt → prompt-user → call-content）随 cl-agent/client
;;;; 一并退役——那是 Spring AI 的 Java 表达习惯；在 Lisp 里 build-chat-client
;;;; 的关键字参数 + 声明式 chat 宏覆盖同样的场景。此处只测搬到 chat-client
;;;; 的 chat 宏与端到端链路。

(in-package :cl-agent/tests)

(def-suite chat-client-chat-suite :in cl-agent-suite
  :description "chat-client chat 宏 DSL、终结操作与端到端集成")

(in-suite chat-client-chat-suite)

(defun make-chat-test-chat-client (&rest responses)
  "顺序响应的测试 chat-client，返回 (values chat-client provider)。

  名字带 chat- 前缀是刻意的：test-chat-client-invoke.lisp 里已有一个同包的
  make-test-chat-client（带 :tools '(ki-adder)），两个文件都 in-package
  :cl-agent/tests，重名会让后加载的那个静默顶掉前一个。"
  (let* ((provider (apply #'make-seq-provider responses))
         (model (cl-agent/core:make-provider-chat-model provider)))
    (values (cl-agent/core:build-chat-client :model model) provider)))

;;; ============================================================
;;; chat 宏：基本子句
;;; ============================================================

(test chat-client-chat-shorthand
  "(chat chat-client \"文本\") 简写"
  (let ((k (make-chat-test-chat-client (text-response "简写响应"))))
    (is (string= "简写响应" (cl-agent/core:chat k "你好")))))

(test chat-client-chat-clauses
  ":system/:user/:options 子句（含 format 控制串）"
  (multiple-value-bind (k provider) (make-chat-test-chat-client (text-response "ok"))
    (cl-agent/core:chat k
      (:system "你是~A" "翻译")
      (:user "翻译：~A" "hello")
      (:options :temperature 0.1))
    (let* ((request (first (seq-provider-requests provider)))
           (messages (getf request :messages)))
      (is (string= "你是翻译" (getf (first messages) :content)))
      (is (string= "翻译：hello" (getf (second messages) :content)))
      (is (= 0.1 (getf request :temperature))))))

(test chat-client-chat-options-instance
  ":options 也接受现成的 chat-options 实例"
  (multiple-value-bind (k provider) (make-chat-test-chat-client (text-response "ok"))
    (cl-agent/core:chat k
      (:user "hi")
      (:options (cl-agent/core:make-chat-options :max-tokens 77)))
    (is (= 77 (getf (first (seq-provider-requests provider)) :max-tokens)))))

(test chat-client-chat-messages-clause
  ":messages 子句插入任意消息"
  (multiple-value-bind (k provider) (make-chat-test-chat-client (text-response "ok"))
    (cl-agent/core:chat k
      (:messages (cl-agent/core:user-message "第一条"))
      (:user "第二条"))
    (let ((messages (getf (first (seq-provider-requests provider)) :messages)))
      (is (= 2 (length messages)))
      (is (string= "第一条" (getf (first messages) :content)))
      (is (string= "第二条" (getf (second messages) :content))))))

(test chat-client-chat-requires-user-input
  "只有 system、没有用户输入时报错（早失败好过 provider 报难懂的 400）"
  (let ((k (make-chat-test-chat-client (text-response "ok"))))
    (signals error
      (cl-agent/core:chat k (:system "你是助手")))))

;;; ============================================================
;;; chat-client 级默认 system / options
;;;
;;; 旧的 make-chat-client 有 :system / :options（客户端级默认）。
;;; cl-agent/client 退役时若不把这份能力接到 build-chat-client 上，就等于
;;; 逼用户每次请求重写 system——是功能回归。以下测试守住它。
;;; ============================================================

(test chat-client-default-system-applies
  "build-chat-client 的 :system 作为默认系统提示下发"
  (let* ((provider (make-seq-provider (text-response "ok")))
         (model (cl-agent/core:make-provider-chat-model provider))
         (k (cl-agent/core:build-chat-client :model model :system "你是一个天气助手")))
    (cl-agent/core:chat k (:user "hi"))
    (let ((messages (getf (first (seq-provider-requests provider)) :messages)))
      (is (string= "你是一个天气助手" (getf (first messages) :content))))))

(test chat-client-request-system-overrides-default
  "请求级 (:system ...) 覆盖 chat-client 的默认 system"
  (let* ((provider (make-seq-provider (text-response "ok")))
         (model (cl-agent/core:make-provider-chat-model provider))
         (k (cl-agent/core:build-chat-client :model model :system "默认")))
    (cl-agent/core:chat k (:system "请求级") (:user "hi"))
    (let ((messages (getf (first (seq-provider-requests provider)) :messages)))
      (is (string= "请求级" (getf (first messages) :content)))
      ;; 只有一条 system，不是两条叠加
      (is (= 2 (length messages))))))

(test chat-client-default-options-apply
  "build-chat-client 的 :options 作为默认选项下发"
  (let* ((provider (make-seq-provider (text-response "ok")))
         (model (cl-agent/core:make-provider-chat-model provider))
         (k (cl-agent/core:build-chat-client
             :model model
             :options (cl-agent/core:make-chat-options :max-tokens 512
                                                       :temperature 0.3))))
    (cl-agent/core:chat k (:user "hi"))
    (let ((request (first (seq-provider-requests provider))))
      (is (= 512 (getf request :max-tokens)))
      (is (= 0.3 (getf request :temperature))))))

(test chat-client-request-options-override-defaults
  "请求级 :options 覆盖同名默认；未覆盖的默认项保留"
  (let* ((provider (make-seq-provider (text-response "ok")))
         (model (cl-agent/core:make-provider-chat-model provider))
         (k (cl-agent/core:build-chat-client
             :model model
             :options (cl-agent/core:make-chat-options :max-tokens 512
                                                       :temperature 0.3))))
    (cl-agent/core:chat k (:user "hi") (:options :temperature 0.9))
    (let ((request (first (seq-provider-requests provider))))
      ;; 请求级赢
      (is (= 0.9 (getf request :temperature)))
      ;; 没被请求级提到的默认项仍在
      (is (= 512 (getf request :max-tokens))))))

(test chat-client-default-options-coexist-with-tools
  "chat-client 默认 options 与 chat-client :tools 共存（merge 不能把 tool-callbacks 冲掉）"
  (let* ((provider (make-seq-provider (text-response "ok")))
         (model (cl-agent/core:make-provider-chat-model provider))
         (k (cl-agent/core:build-chat-client
             :model model
             :options (cl-agent/core:make-chat-options :max-tokens 256)
             :tools '(test-adder))))
    (cl-agent/core:chat k (:user "hi"))
    (let ((request (first (seq-provider-requests provider))))
      (is (= 256 (getf request :max-tokens)))
      (is (= 1 (length (getf request :tools)))))))

;;; ============================================================
;;; chat 宏：终结操作
;;; ============================================================

(test chat-client-chat-call-response
  "(:call :response) 返回 chat-response"
  (let ((k (make-chat-test-chat-client (text-response "ok"))))
    (is (typep (cl-agent/core:chat k (:user "hi") (:call :response))
               'cl-agent/core:chat-response))))

(test chat-client-chat-call-result
  "(:call :result) 返回 chat-client-response（能看到 status）"
  (let ((k (make-chat-test-chat-client (text-response "ok"))))
    (let ((r (cl-agent/core:chat k (:user "hi") (:call :result))))
      (is (eq :completed (cl-agent/core:chat-client-response-status r)))
      (is (string= "ok" (cl-agent/core:chat-response-text
                         (cl-agent/core:chat-client-response-chat-response r)))))))

(test chat-client-entity
  "(:call :entity) 解析 JSON（容忍代码围栏）"
  (let ((k (make-chat-test-chat-client
            (text-response "```json
{\"city\": \"东京\", \"temp\": 22}
```"))))
    (let ((entity (cl-agent/core:chat k
                    (:user "东京天气，用 JSON 回答")
                    (:call :entity))))
      (is (string= "东京" (gethash "city" entity)))
      (is (= 22 (gethash "temp" entity))))))

(test chat-client-stream
  "(:stream fn) 回调（当前为同步降级：整段文本一个 chunk）"
  (let ((k (make-chat-test-chat-client (text-response "流式文本")))
        (chunks nil))
    (cl-agent/core:chat k
      (:user "hi")
      (:stream (lambda (delta) (push delta chunks))))
    (is (equal '("流式文本") (reverse chunks)))))

(test chat-client-chat-advisors-clause-errors
  "(:advisors ...) 显式报错，不静默忽略"
  (is (eq :error
          (handler-case
              (macroexpand-1 '(cl-agent/core:chat k (:advisors 'foo)))
            (error () :error)))))

;;; ============================================================
;;; 端到端集成
;;; ============================================================

(test chat-client-chat-tools-end-to-end
  "chat 宏 + deftool 工具循环端到端"
  (multiple-value-bind (k provider)
      (make-chat-test-chat-client
       (tool-call-response "test_adder" '(("a" . 10) ("b" . 20)))
       (text-response "10+20=30"))
    (is (string= "10+20=30"
                 (cl-agent/core:chat k
                   (:user "10+20=?")
                   (:tools 'test-adder))))
    ;; 两次调用：一次要工具，一次拿结果
    (is (= 2 (length (seq-provider-requests provider))))))

(test chat-client-chat-request-tools-union-with-chat-client-tools
  "请求级 :tools 与 build-chat-client 的 :tools 取并集"
  (let* ((provider (make-seq-provider (text-response "ok")))
         (model (cl-agent/core:make-provider-chat-model provider))
         (k (cl-agent/core:build-chat-client :model model :tools '(test-adder))))
    (cl-agent/core:chat k (:user "hi") (:tools 'test-context-tool))
    (let ((tools (getf (first (seq-provider-requests provider)) :tools)))
      ;; 两个工具都下发给了模型
      (is (= 2 (length tools))))))

(test chat-client-chat-conversation-shorthand
  "(:conversation id) 是 (:context :conversation-id id) 的简写，memory-filter 读得到"
  (let* ((provider (make-seq-provider (text-response "回复1")
                                      (text-response "回复2")))
         (model (cl-agent/core:make-provider-chat-model provider))
         (mem (cl-agent/core:make-message-window-chat-memory))
         (k (cl-agent/core:build-chat-client
             :model model
             :filters (list (cl-agent/core:memory-filter mem)))))
    (cl-agent/core:chat k (:user "我叫大卫") (:conversation "c1"))
    (cl-agent/core:chat k (:user "我叫什么") (:conversation "c1"))
    (is (= 4 (length (cl-agent/core:memory-messages mem "c1"))))))
