;;;; test-tool-search.lisp
;;;; CL-Agent - 循环钩子 + ToolSearchToolCallingAdvisor 测试
;;;;
;;;; 覆盖：
;;;;   - 细粒度钩子的调用次序与次数（initialize/before/after/finalize）
;;;;   - before-call 钩子的请求改写能力
;;;;   - ToolSearch：首轮只披露 tool_search、检索后注入命中工具、
;;;;     发现集合请求级隔离、匹配策略

(in-package :cl-agent/tests)

(def-suite tool-search-suite :in cl-agent-suite
  :description "工具循环钩子 + 渐进式工具披露")

(in-suite tool-search-suite)

;;; ============================================================
;;; 细粒度钩子
;;; ============================================================

(defclass hook-recording-advisor (cl-agent.client:tool-calling-advisor)
  ((log :initarg :log :reader hook-log))
  (:documentation "记录钩子调用的测试 advisor"))

(defmethod cl-agent.client:tool-advisor-initialize-loop
    ((advisor hook-recording-advisor) request)
  (push :initialize (car (hook-log advisor)))
  (call-next-method))

(defmethod cl-agent.client:tool-advisor-before-call
    ((advisor hook-recording-advisor) request iteration)
  (push (list :before iteration) (car (hook-log advisor)))
  (call-next-method))

(defmethod cl-agent.client:tool-advisor-after-call
    ((advisor hook-recording-advisor) request response iteration)
  (push (list :after iteration) (car (hook-log advisor)))
  (call-next-method))

(defmethod cl-agent.client:tool-advisor-finalize-loop
    ((advisor hook-recording-advisor) request response)
  (push :finalize (car (hook-log advisor)))
  (call-next-method))

(test hooks-invocation-order
  "两轮工具循环：initialize×1 → (before→after)×2 → finalize×1"
  (let* ((provider (make-seq-provider
                    (tool-call-response "test_adder" '(("a" . 1) ("b" . 2)))
                    (text-response "3")))
         (log (list nil))
         (client (cl-agent.client:make-chat-client
                  (cl-agent.chat:make-provider-chat-model provider)
                  :advisors (list (make-instance 'hook-recording-advisor
                                                 :log log)))))
    (is (string= "3" (cl-agent.client:chat client
                       (:user "1+2=?")
                       (:tools 'test-adder))))
    (is (equal '(:initialize (:before 0) (:after 0) (:before 1) (:after 1) :finalize)
               (reverse (car log))))))

(test hooks-run-for-streaming
  "流式路径共用同一组钩子"
  (let* ((provider (make-seq-provider (text-response "ok")))
         (log (list nil))
         (client (cl-agent.client:make-chat-client
                  (cl-agent.chat:make-provider-chat-model provider)
                  :advisors (list (make-instance 'hook-recording-advisor
                                                 :log log)))))
    (cl-agent.client:chat client
      (:user "hi")
      (:stream (lambda (delta) (declare (ignore delta)))))
    (is (equal '(:initialize (:before 0) (:after 0) :finalize)
               (reverse (car log))))))

(defclass rewrite-hook-advisor (cl-agent.client:tool-calling-advisor)
  ()
  (:documentation "before-call 改写请求的测试 advisor"))

(defmethod cl-agent.client:tool-advisor-before-call
    ((advisor rewrite-hook-advisor) request iteration)
  (declare (ignore iteration))
  ;; 每轮给 prompt 追加一条 system 提醒
  (cl-agent.client:client-request-copy
   request
   :prompt (cl-agent.chat:prompt-append-messages
            (cl-agent.client:client-request-prompt request)
            (list (cl-agent.chat:system-message "钩子注入的提醒")))))

(test hooks-can-rewrite-request
  "before-call 钩子可改写 request（provider 能看到注入的消息）"
  (let* ((provider (make-seq-provider (text-response "ok")))
         (client (cl-agent.client:make-chat-client
                  (cl-agent.chat:make-provider-chat-model provider)
                  :advisors (list (make-instance 'rewrite-hook-advisor)))))
    (cl-agent.client:chat client "hi")
    (let ((messages (getf (first (seq-provider-requests provider)) :messages)))
      (is (find "钩子注入的提醒" messages
                :key (lambda (m) (getf m :content))
                :test #'string=)))))

;;; ============================================================
;;; ToolSearch：渐进式工具披露
;;; ============================================================

(cl-agent.chat:deftool ts-get-weather (&key city)
  "查询指定城市的天气预报信息"
  (:param city :string "城市名称" :required t)
  (format nil "~A：晴，22°C" city))

(cl-agent.chat:deftool ts-send-email (&key to subject)
  "发送电子邮件给指定收件人"
  (:param to :string "收件人地址" :required t)
  (:param subject :string "邮件主题")
  (format nil "已发送给 ~A：~A" to subject))

(cl-agent.chat:deftool ts-query-db (&key sql)
  "执行数据库查询语句"
  (:param sql :string "SQL 语句" :required t)
  (format nil "查询结果：~A 行" (length sql)))

(defun schema-names (request-plist)
  "提取 provider 收到的工具 schema 名称列表"
  (mapcar (lambda (schema) (getf schema :name))
          (getf request-plist :tools)))

(defun make-search-client (provider)
  (cl-agent.client:make-chat-client
   (cl-agent.chat:make-provider-chat-model provider)
   :advisors (list (cl-agent.client:make-tool-search-tool-calling-advisor))))

(test tool-search-progressive-disclosure
  "首轮只披露 tool_search；检索命中后注入该工具；全程不发全量"
  (let* ((provider
           (make-seq-provider
            ;; 轮 1：模型检索天气能力
            (tool-call-response "tool_search" '(("query" . "天气")))
            ;; 轮 2：模型调用被发现的工具
            (tool-call-response "ts_get_weather" '(("city" . "东京")) :id "call-2")
            ;; 轮 3：最终答案
            (text-response "东京晴，22°C")))
         (client (make-search-client provider)))
    (is (string= "东京晴，22°C"
                 (cl-agent.client:chat client
                   (:user "东京天气如何？")
                   (:tools 'ts-get-weather 'ts-send-email 'ts-query-db))))
    (let ((requests (reverse (seq-provider-requests provider))))
      (is (= 3 (length requests)))
      ;; 轮 1：只有检索工具（3 个业务工具都未披露）
      (is (equal '("tool_search") (schema-names (first requests))))
      ;; 轮 2：检索工具 + 被发现的天气工具
      (is (equal '("tool_search" "ts_get_weather")
                 (schema-names (second requests))))
      ;; 轮 3 同轮 2；未被检索的工具始终未披露
      (is (not (member "ts_send_email" (schema-names (third requests))
                       :test #'string=))))))

(test tool-search-result-text
  "检索结果文本包含命中工具的名称与描述，供模型决策"
  (let* ((provider
           (make-seq-provider
            (tool-call-response "tool_search" '(("query" . "邮件")))
            (lambda (messages)
              ;; 工具结果消息应包含命中工具信息
              (let ((tool-msg (find :tool messages
                                    :key (lambda (m) (getf m :role)))))
                (assert (search "ts_send_email" (getf tool-msg :content)))
                (assert (search "电子邮件" (getf tool-msg :content))))
              (text-response "好的"))))
         (client (make-search-client provider)))
    (is (string= "好的"
                 (cl-agent.client:chat client
                   (:user "帮我发邮件")
                   (:tools 'ts-get-weather 'ts-send-email))))))

(test tool-search-no-match
  "无命中时返回提示文本，模型可换词重试"
  (let* ((provider
           (make-seq-provider
            (tool-call-response "tool_search" '(("query" . "量子计算")))
            (lambda (messages)
              (let ((tool-msg (find :tool messages
                                    :key (lambda (m) (getf m :role)))))
                (assert (search "未找到" (getf tool-msg :content))))
              (text-response "抱歉没有这个能力"))))
         (client (make-search-client provider)))
    (is (string= "抱歉没有这个能力"
                 (cl-agent.client:chat client
                   (:user "算个量子态")
                   (:tools 'ts-get-weather))))))

(test tool-search-discovery-isolated-per-request
  "发现集合是请求级状态：新请求重新从零披露"
  (let* ((advisor (cl-agent.client:make-tool-search-tool-calling-advisor))
         (run (lambda (provider)
                (cl-agent.client:chat
                    (cl-agent.client:make-chat-client
                     (cl-agent.chat:make-provider-chat-model provider)
                     :advisors (list advisor))
                  (:user "东京天气？")
                  (:tools 'ts-get-weather))))
         (p1 (make-seq-provider
              (tool-call-response "tool_search" '(("query" . "天气")))
              (tool-call-response "ts_get_weather" '(("city" . "东京")) :id "c2")
              (text-response "晴")))
         (p2 (make-seq-provider (text-response "第二次"))))
    ;; 第一个请求：完整检索流程
    (is (string= "晴" (funcall run p1)))
    ;; 第二个请求（同一 advisor 实例）：首轮仍只披露 tool_search
    (funcall run p2)
    (is (equal '("tool_search")
               (schema-names (first (seq-provider-requests p2)))))))

(test tool-search-regex-mode
  ":regex 匹配策略"
  (let* ((provider
           (make-seq-provider
            (tool-call-response "tool_search" '(("query" . "send.*email|邮件")))
            (lambda (messages)
              (let ((tool-msg (find :tool messages
                                    :key (lambda (m) (getf m :role)))))
                (assert (search "ts_send_email" (getf tool-msg :content))))
              (text-response "ok"))))
         (client (cl-agent.client:make-chat-client
                  (cl-agent.chat:make-provider-chat-model provider)
                  :advisors (list (cl-agent.client:make-tool-search-tool-calling-advisor
                                   :match-mode :regex)))))
    (is (string= "ok" (cl-agent.client:chat client
                        (:user "发邮件")
                        (:tools 'ts-get-weather 'ts-send-email))))))

(test tool-search-no-tools-passthrough
  "未配置工具时退化为普通行为（不注入检索工具）"
  (let* ((provider (make-seq-provider (text-response "普通回答")))
         (client (make-search-client provider)))
    (is (string= "普通回答" (cl-agent.client:chat client "你好")))
    (is (null (getf (first (seq-provider-requests provider)) :tools)))))
