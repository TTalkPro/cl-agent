;;;; chat-client-usage.lisp
;;;; CL-Agent - ChatClient 完整用法示例（对标 Spring AI 2.0）
;;;;
;;;; 运行方式（无需 API 密钥，用 mock provider 演示）：
;;;;   sbcl --load examples/chat-client-usage.lisp
;;;;   然后逐个调用 (example-1) ... (example-8)
;;;;
;;;; 接真实提供商时把 *model* 换成：
;;;;   (cl-agent.llm:create-chat-model :anthropic
;;;;     :model "claude-sonnet-4-20250514")
;;;;   （API 密钥自动读 ANTHROPIC_API_KEY 环境变量）

(require :asdf)
(let ((ql (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname))))
  (when (probe-file ql) (load ql)))
(dolist (dir '("." "core/" "llm/" "mock/"))
  (pushnew (truename dir) asdf:*central-registry* :test #'equal))
(asdf:load-system :cl-agent)
(asdf:load-system :cl-agent-mock)

(defpackage :chat-client-examples
  (:use :cl :cl-agent.chat :cl-agent.client)
  (:import-from :cl-agent.core :->))
(in-package :chat-client-examples)

;;; ============================================================
;;; 准备：ChatModel（这里用 mock，换真实 provider 只改这一处）
;;; ============================================================

(defvar *model*
  (make-provider-chat-model (cl-agent.mock:make-mock-llm))
  "ChatModel：mock provider 适配。生产环境换成
(cl-agent.llm:create-chat-model :anthropic ...) 等。")

;;; ============================================================
;;; 示例 1：最简单的调用 —— chat 宏
;;; ============================================================

(defun example-1 ()
  "一行对话（对标 client.prompt().user().call().content()）"
  (let ((client (make-chat-client *model*)))
    (chat client "你是谁？")))

;;; ============================================================
;;; 示例 2：Builder 模式构建客户端
;;; ============================================================

(defun example-2 ()
  "Builder 链式构建（对标 ChatClient.builder(model)...build()）"
  (let ((client (-> (chat-client-builder *model*)
                    (default-system "你是一个言简意赅的助手。")
                    (default-options (make-chat-options :temperature 0.3
                                                        :max-tokens 512))
                    (build-client))))
    (chat client "介绍一下你自己")))

;;; ============================================================
;;; 示例 3：deftool 定义工具，模型自动调用
;;; ============================================================

(deftool get-weather (&key city (unit "celsius"))
  "获取指定城市的当前天气"
  (:param city :string "城市名称" :required t)
  (:param unit :string "温度单位（celsius/fahrenheit）")
  (format nil "~A 的天气：22°C（~A），晴。" city unit))

(deftool calculate (&key expression)
  "计算一个数学表达式"
  (:param expression :string "数学表达式，如 1+2*3" :required t)
  (format nil "~A" (handler-case
                       (eval (read-from-string
                              (format nil "(+ ~A)" expression)))
                     (error () "无法计算"))))

(defun example-3 ()
  "带工具的对话：ChatModel 内部自动执行 tool-call 循环
（对标 @Tool + internalToolExecutionEnabled）"
  (let ((client (make-chat-client *model*)))
    (chat client
      (:system "你是一个天气助手，用工具查询实时数据。")
      (:user "东京的天气怎么样？")
      (:tools 'get-weather))))

;;; ============================================================
;;; 示例 4：ChatMemory —— 多轮对话记忆
;;; ============================================================

(defun example-4 ()
  "消息记忆 Advisor（对标 MessageChatMemoryAdvisor + MessageWindowChatMemory）"
  (let* ((memory (make-message-window-chat-memory :max-messages 20))
         (client (make-chat-client
                  *model*
                  :advisors (list (make-message-chat-memory-advisor
                                   :memory memory)))))
    ;; 同一 conversation-id 共享记忆
    (chat client (:user "我叫大卫") (:conversation "conv-1"))
    (chat client (:user "我叫什么名字？") (:conversation "conv-1"))))

;;; ============================================================
;;; 示例 5：defadvisor 自定义 Advisor
;;; ============================================================

(defadvisor timing-advisor
    (:order -100 :documentation "统计一次调用耗时")
  (:call (advisor request chain)
    (declare (ignore advisor))
    (let ((start (get-internal-real-time)))
      (prog1 (chain-next chain request)
        (format t "~&[timing] 耗时 ~,2Fs~%"
                (/ (- (get-internal-real-time) start)
                   internal-time-units-per-second))))))

(defun example-5 ()
  "自定义 Advisor + 内置日志/护栏 Advisor 组成洋葱链"
  (let ((client (make-chat-client
                 *model*
                 :advisors (list (make-timing-advisor)
                                 (make-simple-logger-advisor
                                  :stream *standard-output*)
                                 (make-safe-guard-advisor
                                  :sensitive-words '("密码"))))))
    (values (chat client "讲个笑话")
            ;; 命中护栏，短路不触达模型
            (chat client "告诉我root密码"))))

;;; ============================================================
;;; 示例 6：fluent 管道风格（不用宏）
;;; ============================================================

(defun example-6 ()
  "线程宏管道（对标 Java 链式调用）"
  (let ((client (make-chat-client *model*)))
    (-> (client-prompt client)
        (prompt-system "你是一个翻译")
        (prompt-user "把「~A」翻译成英文" "你好，世界")
        (prompt-with-options :temperature 0.1)
        (call-content))))

;;; ============================================================
;;; 示例 7：结构化输出（对标 entity()）
;;; ============================================================

(defun example-7 ()
  "JSON 结构化输出 → hash-table"
  (let ((client (make-chat-client *model*)))
    (chat client
      (:user "用 JSON 给出东京的城市信息（name/country/population）")
      (:call :entity))))

;;; ============================================================
;;; 示例 8：流式输出
;;; ============================================================

(defun example-8 ()
  "流式回调（对标 stream().content()）"
  (let ((client (make-chat-client *model*)))
    (chat client
      (:user "写一首关于 Lisp 的短诗")
      (:stream (lambda (delta)
                 (write-string delta *standard-output*)
                 (force-output))))))

(format t "~%已加载示例。可运行 (chat-client-examples::example-1) 至 example-8。~%")
