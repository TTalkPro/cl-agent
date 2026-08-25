;;;; chat-client-usage.lisp
;;;; CL-Agent - ChatClient + Filter 完整用法示例
;;;;
;;;; 运行方式（无需 API 密钥，用 mock provider 演示）：
;;;;   sbcl --load examples/chat-client-usage.lisp
;;;;   然后逐个调用 (example-1) ... (example-8)
;;;;
;;;; 接真实提供商时把 *model* 换成：
;;;;   (cl-agent/llm:create-chat-model :anthropic
;;;;     :model "claude-sonnet-4-20250514")
;;;;   （API 密钥自动读 ANTHROPIC_API_KEY 环境变量）
;;;;   真实调用的可执行验证见 scripts/live-test.lisp。

(require :asdf)
(let ((ql (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname))))
  (when (probe-file ql) (load ql)))
;; cl-agent.asd 依赖 :cl-agent-core、:cl-agent-client、:cl-agent-llm、
;; :cl-agent-mock，所以要注册所有同级子目录
(dolist (dir '("." "core/" "client/" "llm/" "mock/"))
  (pushnew (truename dir) asdf:*central-registry* :test #'equal))
(asdf:load-system :cl-agent)
(asdf:load-system :cl-agent-mock)

(defpackage :chat-client-examples
  (:use :cl :cl-agent/core))
(in-package :chat-client-examples)

;;; ============================================================
;;; 准备：ChatModel（这里用 mock，换真实 provider 只改这一处）
;;; ============================================================

(defvar *model*
  (make-provider-chat-model (cl-agent/mock:make-mock-llm))
  "ChatModel：mock provider 适配。生产环境换成
(cl-agent/llm:create-chat-model :anthropic ...) 等。")

;;; ============================================================
;;; 示例 1：最简单的调用 —— chat 宏
;;; ============================================================

(defun example-1 ()
  "一行对话。build-chat-client 装配，chat 宏发起。"
  (let ((k (build-chat-client :model *model*)))
    (chat k "你是谁？")))

;;; ============================================================
;;; 示例 2：带默认 system / options 的 chat-client
;;; ============================================================
;;;
;;; 没有 Builder：chat-client 的装配就是 build-chat-client 的关键字参数，
;;; 一次请求的覆盖就是 chat 宏的子句。

(defun example-2 ()
  "请求级 system + options"
  (let ((k (build-chat-client :model *model*)))
    (chat k
      (:system "你是一个言简意赅的助手。")
      (:user "介绍一下你自己")
      (:options :temperature 0.3 :max-tokens 512))))

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
  "带工具的对话：chat-client 的 run-tool-loop 自动执行 tool-call 循环
（对标 @Tool）"
  (let ((k (build-chat-client :model *model* :tools '(get-weather))))
    (chat k
      (:system "你是一个天气助手，用工具查询实时数据。")
      (:user "东京的天气怎么样？"))))

;;; ============================================================
;;; 示例 4：memory-filter —— 多轮对话记忆
;;; ============================================================

(defun example-4 ()
  "memory-filter 多轮记忆（对标 MessageWindowChatMemory）。
横切能力经 filter 挂载：build-chat-client :filters。"
  (let* ((memory (make-message-window-chat-memory :max-messages 20))
         (k (build-chat-client :model *model*
                          :filters (list (memory-filter memory)))))
    ;; 同一 conversation-id 共享记忆
    (chat k (:user "我叫大卫") (:conversation "conv-1"))
    (chat k (:user "我叫什么名字？") (:conversation "conv-1"))
    ;; 4 条：2 轮 × (user + assistant)
    (values (memory-messages memory "conv-1")
            (length (memory-messages memory "conv-1")))))

;;; ============================================================
;;; 示例 5：自定义 filter —— 洋葱链
;;; ============================================================
;;;
;;; filter 有四个钩子（:chat/:tool/:turn/:token-xform）。
;;; 每个钩子是 (lambda (req chain) ...)：可前置改写 req、调
;;; (funcall chain req) 进下游、后置加工返回值，或干脆不调下游而短路。
;;; filters 列表顺序即洋葱层级：靠前 = 靠外 = 先执行。

(defun timing-filter ()
  "统计一次 turn 的耗时（:turn 钩子）"
  (make-filter
   :timing
   :turn (lambda (req chain)
           (let ((start (get-internal-real-time)))
             (prog1 (funcall chain req)
               (format t "~&[timing] 耗时 ~,2Fs~%"
                       (/ (- (get-internal-real-time) start)
                          internal-time-units-per-second)))))))

(defun example-5 ()
  "自定义 filter + 内置日志/护栏 filter 组成洋葱链"
  (let ((k (build-chat-client
            :model *model*
            :filters (list (timing-filter)
                           (safeguard-turn-filter '("密码"))
                           (logging-chat-filter)))))
    (values (chat k "讲个笑话")
            ;; 命中护栏，短路不触达模型（护栏在日志外侧，所以第二次没有日志）
            (chat k "告诉我root密码"))))

;;; ============================================================
;;; 示例 6：函数形态入口（不用宏）
;;; ============================================================

(defun example-6 ()
  "chat-client-text：chat 宏的函数形态，参数由程序拼时更顺手"
  (let ((k (build-chat-client :model *model*)))
    (chat-client-text k
                      :system "你是一个翻译"
                      :user (format nil "把「~A」翻译成英文" "你好，世界")
                      :options (make-chat-options :temperature 0.1))))

;;; ============================================================
;;; 示例 7：结构化输出 + schema 校验自纠
;;; ============================================================

(defparameter +city-schema+
  "{\"type\":\"object\",
    \"properties\":{\"name\":{\"type\":\"string\"},
                   \"population\":{\"type\":\"integer\"}},
    \"required\":[\"name\",\"population\"]}")

(defparameter +entity-prompt+ "用 JSON 给出东京的城市信息（name/population）")

(defvar *json-model*
  ;; 默认 mock 不会吐 JSON，(:call :entity) 必然解析失败——所以这里给它
  ;; 一条按提示词命中的预设响应，好让本例开箱即跑。换真实 provider 时
  ;; 直接用 *model* 即可，validation-turn-filter 会负责校验与自纠重试。
  (let ((responses (make-hash-table :test #'equal)))
    (setf (gethash +entity-prompt+ responses)
          "```json
{\"name\": \"东京\", \"population\": 37000000}
```")
    (make-provider-chat-model (cl-agent/mock:make-mock-llm :responses responses)))
  "只为示例 7 准备的、会返回 JSON 的 mock 模型。")

(defun example-7 ()
  "(:call :entity) 只解析 JSON（会剥掉 markdown 围栏）。
要「不符合 schema 就带着错误让模型重出」，挂 validation-turn-filter
—— 判据由它承担，(:call :entity) 本身不校验。"
  (let ((k (build-chat-client
            :model *json-model*
            :filters (list (validation-turn-filter
                            (structured-output-validate-fn
                             +city-schema+
                             :parse-fn #'cl-agent/core:json-parse)
                            :max-retries 2)))))
    (chat k
      (:user "~A" +entity-prompt+)
      (:call :entity))))

;;; ============================================================
;;; 示例 8：流式输出
;;; ============================================================

(defun example-8 ()
  "流式回调。注意：当前为同步降级——整段文本作为单个 chunk 回调一次。
真正的增量流式用 cl-agent/core:invoke-chat-stream——:chat filter 链照常
生效，:token-xform 管道组装在流式 terminal 内侧。"
  (let ((k (build-chat-client :model *model*)))
    (chat k
      (:user "写一首关于 Lisp 的短诗")
      (:stream (lambda (delta)
                 (write-string delta *standard-output*)
                 (force-output))))))

(format t "~%已加载示例：
  REPL 流程：先 (in-package :chat-client-examples)，再 (example-1)...(example-8)
  或直接： (chat-client-examples::example-1)...(chat-client-examples::example-8)
~%")
