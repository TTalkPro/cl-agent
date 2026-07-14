;;;; test-memory.lisp
;;;; CL-Agent - ChatMemory 测试（Repository 协议 + 滑动窗口）

(in-package :cl-agent/tests)

(def-suite memory-suite :in cl-agent-suite
  :description "ChatMemory / ChatMemoryRepository")

(in-suite memory-suite)

;;; ============================================================
;;; Repository 协议
;;; ============================================================

(test repository-crud
  "内存 Repository 的存取删"
  (let ((repo (cl-agent.chat:make-in-memory-chat-memory-repository))
        (messages (list (cl-agent.chat:user-message "你好"))))
    (is (null (cl-agent.chat:repository-find repo "c1")))
    (cl-agent.chat:repository-save repo "c1" messages)
    (is (= 1 (length (cl-agent.chat:repository-find repo "c1"))))
    (is (equal '("c1") (cl-agent.chat:repository-conversation-ids repo)))
    (cl-agent.chat:repository-delete repo "c1")
    (is (null (cl-agent.chat:repository-find repo "c1")))))

(test repository-isolation
  "会话之间互不影响"
  (let ((repo (cl-agent.chat:make-in-memory-chat-memory-repository)))
    (cl-agent.chat:repository-save repo "a" (list (cl-agent.chat:user-message "A")))
    (cl-agent.chat:repository-save repo "b" (list (cl-agent.chat:user-message "B")))
    (is (string= "A" (cl-agent.chat:message-text
                      (first (cl-agent.chat:repository-find repo "a")))))
    (cl-agent.chat:repository-delete repo "a")
    (is (= 1 (length (cl-agent.chat:repository-find repo "b"))))))

;;; ============================================================
;;; MessageWindowChatMemory
;;; ============================================================

(test memory-add-and-get
  "追加与取回"
  (let ((memory (cl-agent.chat:make-message-window-chat-memory)))
    (cl-agent.chat:memory-add memory "c1" (cl-agent.chat:user-message "单条"))
    (cl-agent.chat:memory-add memory "c1" (list (cl-agent.chat:assistant-message "回复")))
    (is (= 2 (length (cl-agent.chat:memory-messages memory "c1"))))
    (cl-agent.chat:memory-clear memory "c1")
    (is (null (cl-agent.chat:memory-messages memory "c1")))))

(test memory-window-truncation
  "超过窗口时裁掉最旧的非 system 消息"
  (let ((memory (cl-agent.chat:make-message-window-chat-memory :max-messages 3)))
    (cl-agent.chat:memory-add
     memory "c1" (list (cl-agent.chat:user-message "1")
                       (cl-agent.chat:assistant-message "2")
                       (cl-agent.chat:user-message "3")
                       (cl-agent.chat:assistant-message "4")))
    (is (equal '("2" "3" "4")
               (mapcar #'cl-agent.chat:message-text
                       (cl-agent.chat:memory-messages memory "c1"))))))

(test memory-window-keeps-system
  "system 消息不计入窗口且始终保留"
  (let ((memory (cl-agent.chat:make-message-window-chat-memory :max-messages 2)))
    (cl-agent.chat:memory-add
     memory "c1" (list (cl-agent.chat:system-message "系统指令")
                       (cl-agent.chat:user-message "1")
                       (cl-agent.chat:assistant-message "2")
                       (cl-agent.chat:user-message "3")))
    (let ((messages (cl-agent.chat:memory-messages memory "c1")))
      (is (= 3 (length messages)))
      (is (cl-agent.chat:system-message-p (first messages)))
      (is (equal '("2" "3")
                 (mapcar #'cl-agent.chat:message-text (rest messages)))))))

(test memory-window-pairing-safe
  "窗口头部的孤立 tool-response 消息被连带丢弃"
  (let ((memory (cl-agent.chat:make-message-window-chat-memory :max-messages 3)))
    (cl-agent.chat:memory-add
     memory "c1"
     (list (cl-agent.chat:user-message "问")
           (cl-agent.chat:assistant-message
            "" :tool-calls (list (cl-agent.chat:make-tool-call
                                  :id "t1" :name "f")))
           ;; 窗口若从这条开始，其 assistant 已被裁掉 → 应丢弃
           (cl-agent.chat:tool-response-message
            (list (cl-agent.chat:make-tool-response :id "t1" :name "f" :text "r")))
           (cl-agent.chat:assistant-message "答")
           (cl-agent.chat:user-message "追问")))
    (let ((messages (cl-agent.chat:memory-messages memory "c1")))
      ;; max 3 → 窗口为 (tool-response 答 追问)，孤立 tool 头被丢弃
      (is (= 2 (length messages)))
      (is (equal '("答" "追问")
                 (mapcar #'cl-agent.chat:message-text messages))))))

(test memory-custom-repository
  "可注入自定义 Repository 后端"
  (let* ((repo (cl-agent.chat:make-in-memory-chat-memory-repository))
         (memory (cl-agent.chat:make-message-window-chat-memory
                  :repository repo)))
    (cl-agent.chat:memory-add memory "c1" (cl-agent.chat:user-message "hi"))
    ;; 直接从底层 repo 可见
    (is (= 1 (length (cl-agent.chat:repository-find repo "c1"))))))
