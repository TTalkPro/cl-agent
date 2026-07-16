;;;; chat.lisp
;;;; CL-Agent Kernel - chat 宏（声明式请求 DSL）
;;;;
;;;; 概述：
;;;;   kernel 的面向调用方入口。build-kernel 装配好 model/filters/tools 之后，
;;;;   chat 宏负责把一次请求的 system/user/messages/options/tools/context
;;;;   物化成 turn-request，交给 invoke-turn，再按终结操作取出结果。
;;;;
;;;;   (chat *kernel*
;;;;     (:system "你是一个天气助手")
;;;;     (:user "~A 的天气怎么样？" city)
;;;;     (:tools 'get-weather)
;;;;     (:conversation "conv-1"))
;;;;   ;; => 回复文本
;;;;
;;;; 历史：本 DSL 原属已删除的 cl-agent.client（那一层是 Spring AI 的
;;;; ChatClient + Builder + fluent RequestSpec 移植）。Builder 与 fluent
;;;; 链是 Java 的表达习惯，在 Lisp 里由 build-kernel 的关键字参数和这个
;;;; 声明式宏覆盖得更直接，故整层退役，只把宏搬到 kernel。

(in-package #:cl-agent.kernel)

;;; ============================================================
;;; kernel-chat：函数形态入口（chat 宏展开到它）
;;; ============================================================

(defun kernel-chat (kernel &key system user messages options tools context)
  "执行一次完整对话轮次，返回 turn-result。

  参数（均为请求级，覆盖/合并 kernel 上的同名默认值）：
  - system    系统提示文本；不给则用 kernel 的 :system
  - user      用户输入文本（可选）
  - messages  额外消息列表（message 实例），插在 system 之后、user 之前
  - options   本次请求的 chat-options；与 kernel 的 :options 合并，请求级优先
  - tools     请求级工具引用（符号/名称/callback）；与 kernel 的 :tools 取并集
  - context   turn context plist（:conversation-id 等；filter 可读）

  system/user/messages 至少要凑出一条非 system 消息，否则报错——
  只有 system 的请求对模型没有意义，早失败好过让 provider 报一个
  难懂的 400。"
  (let* ((system (or system (kernel-default-system kernel)))
         (msgs (append
                (when system (list (cl-agent.chat:system-message system)))
                messages
                (when user (list (cl-agent.chat:user-message user)))))
         ;; 请求级 options 盖 kernel 默认 options（merge 的 primary 优先）
         (options (let ((defaults (kernel-default-options kernel)))
                    (if defaults
                        (cl-agent.chat:merge-chat-options options defaults)
                        options)))
         ;; 请求级工具并进 options 的 tool-callbacks；
         ;; run-tool-loop 里 merge-chat-options 对 tool-callbacks 取并集，
         ;; 于是请求级工具与 kernel :tools 自然叠加。
         (options (if tools
                      (cl-agent.chat:merge-chat-options
                       (cl-agent.chat:make-chat-options
                        :tool-callbacks (cl-agent.chat:resolve-tool-callbacks tools))
                       options)
                      options))
         (ctx context))
    (unless (remove-if #'cl-agent.chat:system-message-p msgs)
      (error "请求缺少用户输入：请用 (:user ...) 或 (:messages ...) 提供"))
    ;; caller-options 经 context 传给 run-tool-loop，由它合并到每轮调用
    (when options
      (setf (getf ctx :caller-options) options))
    (invoke-turn kernel (make-turn-request msgs :context ctx))))

(defun kernel-chat-text (kernel &rest args)
  "kernel-chat 的取文本快捷式：返回最终回复文本。"
  (let ((result (apply #'kernel-chat kernel args)))
    (cl-agent.chat:chat-response-text (turn-result-response result))))

(defun kernel-chat-entity (kernel &rest args)
  "kernel-chat 的结构化输出快捷式：把回复解析为 JSON 值。

  只解析、不校验——要「不符合 schema 就带着错误让模型重出」，
  给 kernel 挂 validation-turn-filter（配 structured-output-validate-fn）。"
  (let* ((args (%append-json-instruction args))
         (text (apply #'kernel-chat-text kernel args)))
    (cl-agent.core:json-parse (strip-json-fences text))))

(defun %append-json-instruction (args)
  "给 kernel-chat 参数追加一条「只输出 JSON」的系统指令。"
  (let ((messages (getf args :messages)))
    (append (list :messages
                  (append messages
                          (list (cl-agent.chat:system-message
                                 "请只输出 JSON，不要任何多余说明或 markdown 代码围栏。"))))
            (loop for (k v) on args by #'cddr
                  unless (eq k :messages) append (list k v)))))

(defun kernel-chat-stream (kernel on-chunk &rest args)
  "流式执行：每个文本增量回调 (on-chunk delta)，返回最终 chat-response。

  注意：当前降级为同步调用——完整文本作为单个 chunk 回调一次。
  真正的增量流式需要 kernel 的 invoke-chat-stream（:token-xform 组装），
  尚未实现；真 SSE 目前只存在于 chat-model-stream 这一层。"
  (let* ((result (apply #'kernel-chat kernel args))
         (response (turn-result-response result)))
    (funcall on-chunk (cl-agent.chat:chat-response-text response))
    response))

;;; ============================================================
;;; chat 宏 —— 声明式请求 DSL
;;; ============================================================

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defun %chat-text-form (args)
    "(\"text\") → \"text\"；(\"~A\" x) → (format nil \"~A\" x)"
    (if (rest args)
        `(format nil ,@args)
        (first args))))

(defmacro chat (kernel &body clauses)
  "声明式对话请求 DSL。

语法：
  (chat kernel
    [(:system 文本 [format 参数...])]
    [(:user 文本 [format 参数...])]
    [(:messages 消息...)]
    [(:options :temperature 0.7 ...)]
    [(:tools 工具...)]
    [(:context 键 值)]
    [(:conversation 会话ID)]
    [(:call :content | :response | :result | :entity)]
    [(:stream 回调)])

简写：(chat kernel \"你好\") ≡ (chat kernel (:user \"你好\"))

终结操作（缺省 (:call :content)）：
  :content   回复文本（字符串）
  :response  chat-response 实例
  :result    turn-result 实例（要看 status / tool-calls-made 时用）
  :entity    把回复解析为 JSON 值（只解析不校验，校验挂
             validation-turn-filter）

:tools 是请求级工具，与 build-kernel 的 :tools 取并集。
:conversation 是 (:context :conversation-id ...) 的简写，memory-filter 读它。

示例：
  (chat *kernel*
    (:system \"你是一个天气助手\")
    (:user \"~A 的天气怎么样？\" city)
    (:tools 'get-weather)
    (:conversation \"conv-1\"))"
  (let ((system nil) (user nil)
        (messages nil) (options nil) (tools nil) (context nil)
        (terminal '(:call :content)))
    (dolist (clause clauses)
      (if (stringp clause)
          (setf user clause)
          (ecase (first clause)
            (:system (setf system (%chat-text-form (rest clause))))
            (:user (setf user (%chat-text-form (rest clause))))
            (:messages (setf messages (append messages (rest clause))))
            (:options
             (setf options
                   (if (and (= (length (rest clause)) 1)
                            (not (keywordp (second clause))))
                       ;; 单个非关键字实参 = 现成的 chat-options
                       (second clause)
                       `(cl-agent.chat:make-chat-options ,@(rest clause)))))
            (:tools (setf tools (append tools (rest clause))))
            (:context (setf context (append context (list (second clause)
                                                          (third clause)))))
            (:conversation (setf context (append context
                                                 (list :conversation-id
                                                       (second clause)))))
            ;; Advisor 体系已退役。显式报错而非静默忽略——旧代码里的
            ;; (:advisors ...) 若被悄悄丢掉，记忆/护栏会无声失效。
            (:advisors
             (error "(chat ...) 的 :advisors 子句已移除（Advisor 体系退役）。~@
                     请改用 kernel filter：~@
                     (build-kernel :model m :filters (list (memory-filter mem) ...))"))
            ((:call :stream) (setf terminal clause)))))
    (let ((args `(,@(when system `(:system ,system))
                  ,@(when user `(:user ,user))
                  ,@(when messages `(:messages (list ,@messages)))
                  ,@(when options `(:options ,options))
                  ,@(when tools `(:tools (list ,@tools)))
                  ,@(when context `(:context (list ,@context))))))
      (ecase (first terminal)
        (:call (ecase (second terminal)
                 (:content `(kernel-chat-text ,kernel ,@args))
                 (:response `(turn-result-response (kernel-chat ,kernel ,@args)))
                 (:result `(kernel-chat ,kernel ,@args))
                 (:entity `(kernel-chat-entity ,kernel ,@args))))
        (:stream `(kernel-chat-stream ,kernel ,(second terminal) ,@args))))))
