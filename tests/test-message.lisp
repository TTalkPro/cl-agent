;;;; test-message.lisp
;;;; CL-Agent - 消息体系测试（cl-agent.chat）

(in-package :cl-agent/tests)

(def-suite message-suite :in cl-agent-suite
  :description "CLOS 消息体系与中立 plist 互转")

(in-suite message-suite)

;;; ============================================================
;;; 消息类型与角色
;;; ============================================================

(test message-roles
  "四种消息的角色关键字"
  (is (eq :system (cl-agent.chat:message-role (cl-agent.chat:system-message "s"))))
  (is (eq :user (cl-agent.chat:message-role (cl-agent.chat:user-message "u"))))
  (is (eq :assistant (cl-agent.chat:message-role (cl-agent.chat:assistant-message "a"))))
  (is (eq :tool (cl-agent.chat:message-role
                 (cl-agent.chat:tool-response-message
                  (cl-agent.chat:make-tool-response :id "1" :name "t" :text "r"))))))

(test message-text
  "消息文本访问"
  (is (string= "你好" (cl-agent.chat:message-text (cl-agent.chat:user-message "你好"))))
  (is (string= "" (cl-agent.chat:message-text (cl-agent.chat:assistant-message nil)))))

(test message-predicates
  "消息谓词"
  (is-true (cl-agent.chat:user-message-p (cl-agent.chat:user-message "u")))
  (is-false (cl-agent.chat:user-message-p (cl-agent.chat:system-message "s")))
  (is-true (cl-agent.chat:messagep (cl-agent.chat:system-message "s")))
  (is-false (cl-agent.chat:messagep "字符串不是消息")))

(test assistant-tool-calls
  "assistant 消息携带 tool-calls"
  (let* ((tc (cl-agent.chat:make-tool-call :name "get-weather"
                                           :arguments '(:city "东京")))
         (msg (cl-agent.chat:assistant-message "" :tool-calls (list tc))))
    (is (= 1 (length (cl-agent.chat:assistant-tool-calls msg))))
    ;; 名称统一为小写字符串
    (is (string= "get-weather" (cl-agent.chat:tool-call-name tc)))
    ;; ID 自动生成
    (is (stringp (cl-agent.chat:tool-call-id tc)))))

;;; ============================================================
;;; 中立 plist 互转（provider SPI 边界）
;;; ============================================================

(test neutral-simple
  "简单消息 → 中立 plist"
  (let ((neutral (cl-agent.chat:message->neutral (cl-agent.chat:user-message "你好"))))
    (is (= 1 (length neutral)))
    (is (eq :user (getf (first neutral) :role)))
    (is (string= "你好" (getf (first neutral) :content)))))

(test neutral-assistant-with-tool-calls
  "assistant + tool-calls → 中立 plist"
  (let* ((msg (cl-agent.chat:assistant-message
               "我来查"
               :tool-calls (list (cl-agent.chat:make-tool-call
                                  :id "c1" :name "f" :arguments '(:x 1)))))
         (plist (first (cl-agent.chat:message->neutral msg))))
    (is (eq :assistant (getf plist :role)))
    (is (= 1 (length (getf plist :tool-calls))))
    (is (string= "c1" (getf (first (getf plist :tool-calls)) :id)))))

(test neutral-tool-response-expansion
  "含 N 条结果的 tool-response-message 展开为 N 条 :tool 消息"
  (let* ((msg (cl-agent.chat:tool-response-message
               (list (cl-agent.chat:make-tool-response :id "1" :name "a" :text "r1")
                     (cl-agent.chat:make-tool-response :id "2" :name "b" :text "r2"))))
         (neutral (cl-agent.chat:message->neutral msg)))
    (is (= 2 (length neutral)))
    (is (every (lambda (m) (eq :tool (getf m :role))) neutral))
    (is (string= "1" (getf (first neutral) :tool-call-id)))))

(test neutral-roundtrip
  "中立 plist 往返转换保持语义"
  (let* ((messages (list (cl-agent.chat:system-message "系统")
                         (cl-agent.chat:user-message "用户")
                         (cl-agent.chat:assistant-message "助手")))
         (roundtrip (cl-agent.chat:neutral->messages
                     (cl-agent.chat:messages->neutral messages))))
    (is (= 3 (length roundtrip)))
    (is (equal '(:system :user :assistant)
               (mapcar #'cl-agent.chat:message-role roundtrip)))
    (is (equal '("系统" "用户" "助手")
               (mapcar #'cl-agent.chat:message-text roundtrip)))))

;;; ============================================================
;;; Prompt
;;; ============================================================

(test prompt-from-string
  "字符串自动包装为 user-message"
  (let ((prompt (cl-agent.chat:make-prompt "你好")))
    (is (= 1 (length (cl-agent.chat:prompt-messages prompt))))
    (is (cl-agent.chat:user-message-p
         (first (cl-agent.chat:prompt-messages prompt))))))

(test prompt-with-system
  ":system 插入为首条系统消息"
  (let ((prompt (cl-agent.chat:make-prompt "你好" :system "你是助手")))
    (is (= 2 (length (cl-agent.chat:prompt-messages prompt))))
    (is (cl-agent.chat:system-message-p
         (first (cl-agent.chat:prompt-messages prompt))))))

(test prompt-copy-immutable
  "prompt-copy 不修改原 prompt"
  (let* ((original (cl-agent.chat:make-prompt "你好"))
         (copy (cl-agent.chat:prompt-append-messages
                original (list (cl-agent.chat:user-message "再见")))))
    (is (= 1 (length (cl-agent.chat:prompt-messages original))))
    (is (= 2 (length (cl-agent.chat:prompt-messages copy))))))

(test prompt-last-user-text
  "取最后一条用户消息文本"
  (let ((prompt (cl-agent.chat:make-prompt
                 (list (cl-agent.chat:user-message "第一")
                       (cl-agent.chat:assistant-message "回复")
                       (cl-agent.chat:user-message "第二")))))
    (is (string= "第二" (cl-agent.chat:prompt-last-user-text prompt)))))

;;; ============================================================
;;; ChatResponse
;;; ============================================================

(test chat-response-accessors
  "chat-response 便捷访问器"
  (let ((response (cl-agent.chat:make-chat-response
                   (cl-agent.chat:make-generation
                    (cl-agent.chat:assistant-message "回答")
                    :finish-reason :stop)
                   :metadata (cl-agent.chat:make-chat-response-metadata
                              :model "test-model"))))
    (is (string= "回答" (cl-agent.chat:chat-response-text response)))
    (is (eq :stop (cl-agent.chat:chat-response-finish-reason response)))
    (is-false (cl-agent.chat:chat-response-has-tool-calls-p response))
    (is (string= "test-model"
                 (cl-agent.chat:response-metadata-model
                  (cl-agent.chat:chat-response-metadata-of response))))))

(test llm-response-conversion
  "llm-response → chat-response 转换"
  (let* ((llm-response (tool-call-response "get_weather" '(("city" . "东京"))))
         (response (cl-agent.chat:llm-response->chat-response llm-response)))
    (is-true (cl-agent.chat:chat-response-has-tool-calls-p response))
    (is (eq :tool-call (cl-agent.chat:chat-response-finish-reason response)))
    (let ((tc (first (cl-agent.chat:chat-response-tool-calls response))))
      (is (string= "get_weather" (cl-agent.chat:tool-call-name tc)))
      (is (string= "call-1" (cl-agent.chat:tool-call-id tc))))))
