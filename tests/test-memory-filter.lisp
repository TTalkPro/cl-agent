;;;; test-memory-filter.lisp
;;;; CL-Agent Tests - ChatMemory + Memory Filter
;;;;
;;;; 依赖 test-kernel-chat.lisp 中定义的 make-sequenced-mock（:serial 加载）

(in-package :cl-agent/tests)

(def-suite memory-filter-suite :in cl-agent-suite
  :description "ChatMemory 协议 + Memory Filter 测试套件")

(in-suite memory-filter-suite)

;;; ============================================================
;;; ChatMemory store 测试
;;; ============================================================

(test chat-store-add-get
  "测试内存 store 的追加与读取"
  (let ((store (cl-agent.kernel:make-in-memory-chat-store)))
    (is (null (cl-agent.kernel:mem-get store "c1")))
    (cl-agent.kernel:mem-add store "c1" '((:role :user :content "hi")))
    (cl-agent.kernel:mem-add store "c1" '((:role :assistant :content "hello")))
    (let ((msgs (cl-agent.kernel:mem-get store "c1")))
      (is (= 2 (length msgs)))
      (is (eq :user (getf (first msgs) :role)))
      (is (eq :assistant (getf (second msgs) :role))))
    ;; 会话隔离
    (is (null (cl-agent.kernel:mem-get store "c2")))))

(test chat-store-clear
  "测试清空会话"
  (let ((store (cl-agent.kernel:make-in-memory-chat-store)))
    (cl-agent.kernel:mem-add store "c1" '((:role :user :content "hi")))
    (cl-agent.kernel:mem-clear store "c1")
    (is (null (cl-agent.kernel:mem-get store "c1")))))

(test windowed-store-basic
  "测试窗口裁剪：只保留尾部 N 条"
  (let* ((inner (cl-agent.kernel:make-in-memory-chat-store))
         (store (cl-agent.kernel:make-windowed-chat-store inner :max-messages 2)))
    (cl-agent.kernel:mem-add store "c1"
                             '((:role :user :content "1")
                               (:role :assistant :content "2")
                               (:role :user :content "3")
                               (:role :assistant :content "4")))
    (let ((msgs (cl-agent.kernel:mem-get store "c1")))
      (is (= 2 (length msgs)))
      (is (string= "3" (getf (first msgs) :content))))
    ;; 底层仍保留完整历史
    (is (= 4 (length (cl-agent.kernel:mem-get inner "c1"))))))

(test windowed-store-pairing-safe
  "测试窗口裁剪 pairing-safe：丢弃头部孤立 tool 消息"
  (let* ((inner (cl-agent.kernel:make-in-memory-chat-store))
         (store (cl-agent.kernel:make-windowed-chat-store inner :max-messages 2)))
    (cl-agent.kernel:mem-add store "c1"
                             '((:role :user :content "q")
                               (:role :assistant :content "" :tool-calls ((:id "1")))
                               (:role :tool :tool-call-id "1" :content "result")
                               (:role :assistant :content "answer")))
    ;; 窗口 [tool, assistant] → 头部孤立 tool 被丢弃
    (let ((msgs (cl-agent.kernel:mem-get store "c1")))
      (is (= 1 (length msgs)))
      (is (eq :assistant (getf (first msgs) :role))))))

(test windowed-store-keeps-system
  "测试窗口裁剪：system 消息不计入窗口、始终保留在最前"
  (let* ((inner (cl-agent.kernel:make-in-memory-chat-store))
         (store (cl-agent.kernel:make-windowed-chat-store inner :max-messages 1)))
    (cl-agent.kernel:mem-add store "c1"
                             '((:role :system :content "sys")
                               (:role :user :content "1")
                               (:role :assistant :content "2")))
    (let ((msgs (cl-agent.kernel:mem-get store "c1")))
      (is (= 2 (length msgs)))
      (is (eq :system (getf (first msgs) :role)))
      (is (string= "2" (getf (second msgs) :content))))))

;;; ============================================================
;;; Memory Filter 单元测试
;;; ============================================================

(defun make-mf-test-chain (store terminal)
  "构造只挂 memory-filter 的 chat 链"
  (cl-agent.kernel:build-phase-chain
   (list (cl-agent.kernel:make-memory-filter store))
   :chat terminal))

(test memory-filter-no-conversation-id
  "测试无 conversation-id 时 memory filter 整体 no-op"
  (let* ((store (cl-agent.kernel:make-in-memory-chat-store))
         (terminal (lambda (req)
                     (declare (ignore req))
                     (cl-agent.core:make-llm-response :content "resp")))
         (chain (make-mf-test-chain store terminal))
         (request (cl-agent.kernel:make-chat-request
                   :messages '((:role :user :content "hi")))))
    (funcall chain request)
    ;; 什么都没存
    (is (zerop (hash-table-count
                (cl-agent.kernel::chat-store-table store))))))

(test memory-filter-roundtrip
  "测试 memory filter：存 delta → 展开历史 → 存回复"
  (let* ((store (cl-agent.kernel:make-in-memory-chat-store))
         (seen-messages nil)
         (terminal (lambda (req)
                     (setf seen-messages (cl-agent.kernel:chat-request-messages req))
                     (cl-agent.core:make-llm-response :content "first-reply")))
         (chain (make-mf-test-chain store terminal)))
    ;; 第一轮
    (funcall chain (cl-agent.kernel:make-chat-request
                    :messages '((:role :user :content "round-1"))
                    :context '(:conversation-id "conv")))
    (is (= 1 (length seen-messages)))   ; 第一轮历史只有本条
    (let ((stored (cl-agent.kernel:mem-get store "conv")))
      (is (= 2 (length stored)))        ; user + assistant
      (is (string= "first-reply" (getf (second stored) :content))))
    ;; 第二轮只传 delta，LLM 看到完整历史
    (funcall chain (cl-agent.kernel:make-chat-request
                    :messages '((:role :user :content "round-2"))
                    :context '(:conversation-id "conv")))
    (is (= 3 (length seen-messages)))   ; user1 + assistant1 + user2
    (is (= 4 (length (cl-agent.kernel:mem-get store "conv"))))))

(test memory-filter-skips-system-messages
  "测试 memory filter 不把 system 消息入库"
  (let* ((store (cl-agent.kernel:make-in-memory-chat-store))
         (terminal (lambda (req)
                     (declare (ignore req))
                     (cl-agent.core:make-llm-response :content "ok")))
         (chain (make-mf-test-chain store terminal)))
    (funcall chain (cl-agent.kernel:make-chat-request
                    :messages '((:role :system :content "sys")
                                (:role :user :content "hi"))
                    :context '(:conversation-id "conv")))
    (let ((stored (cl-agent.kernel:mem-get store "conv")))
      (is (= 2 (length stored)))
      (is (notany (lambda (m) (eq (getf m :role) :system)) stored)))))

(test memory-filter-stores-tool-calls
  "测试 assistant 带 tool-calls 的回复被完整入库"
  (let* ((store (cl-agent.kernel:make-in-memory-chat-store))
         (terminal (lambda (req)
                     (declare (ignore req))
                     (cl-agent.core:make-llm-response
                      :content ""
                      :tool-calls (list (cl-agent.core:make-llm-tool-call
                                         :id "call_1" :name "get-weather"
                                         :arguments '(:city "Tokyo"))))))
         (chain (make-mf-test-chain store terminal)))
    (funcall chain (cl-agent.kernel:make-chat-request
                    :messages '((:role :user :content "weather?"))
                    :context '(:conversation-id "conv")))
    (let* ((stored (cl-agent.kernel:mem-get store "conv"))
           (assistant (second stored))
           (tc (first (getf assistant :tool-calls))))
      (is (= 2 (length stored)))
      (is (string= "call_1" (getf tc :id)))
      (is (equal '(:city "Tokyo") (getf tc :arguments))))))

;;; ============================================================
;;; invoke-kernel + Memory Filter 集成测试（delta 模式）
;;; ============================================================

(test invoke-kernel-with-memory-tool-loop
  "测试完整工具循环下 store 的内容顺序：
   [user, assistant(tool-calls), tool, assistant]"
  (setup-chat-test-tools)
  (let* ((store (cl-agent.kernel:make-in-memory-chat-store))
         (mock (make-sequenced-mock
                (list :content ""
                      :tool-calls (list (list :id "call_1"
                                              :name "test-chat-get-weather"
                                              :arguments '(:city "Beijing"))))
                (list :content "It is sunny.")))
         (kernel (cl-agent.kernel:make-kernel
                  :service mock
                  :plugins '(test-chat-tools-plugin)
                  :filters (list (cl-agent.kernel:make-memory-filter store)))))
    (let ((result (cl-agent.simpleagent:run-tool-loop
                   kernel
                   (list (list :role :user :content "Weather in Beijing?"))
                   :context (list :conversation-id "conv-loop"))))
      (is (string= "It is sunny." (getf result :text)))
      ;; store 是唯一事实来源，顺序完整
      (let ((stored (cl-agent.kernel:mem-get store "conv-loop")))
        (is (= 4 (length stored)))
        (is (equal '(:user :assistant :tool :assistant)
                   (mapcar (lambda (m) (getf m :role)) stored)))
        ;; assistant 第一条带 tool-calls
        (is (not (null (getf (second stored) :tool-calls))))
        ;; tool 消息关联正确
        (is (string= "call_1" (getf (third stored) :tool-call-id)))))))

(test invoke-kernel-memory-multi-turn
  "测试跨轮对话：第二轮只传 delta，LLM 仍看到完整历史"
  (setup-chat-test-tools)
  (let* ((store (cl-agent.kernel:make-in-memory-chat-store))
         (mock (make-sequenced-mock
                (list :content "round-1-reply")
                (list :content "round-2-reply")))
         (kernel (cl-agent.kernel:make-kernel
                  :service mock
                  :filters (list (cl-agent.kernel:make-memory-filter store))))
         (context (list :conversation-id "conv-multi")))
    (cl-agent.simpleagent:run-tool-loop
     kernel (list (list :role :user :content "turn-1")) :context context)
    (cl-agent.simpleagent:run-tool-loop
     kernel (list (list :role :user :content "turn-2")) :context context)
    (let ((stored (cl-agent.kernel:mem-get store "conv-multi")))
      (is (= 4 (length stored)))
      (is (equal '("turn-1" "round-1-reply" "turn-2" "round-2-reply")
                 (mapcar (lambda (m) (getf m :content)) stored))))))

;;; ============================================================
;;; KernelAgent + Memory 集成测试
;;; ============================================================

(test kernel-agent-with-memory
  "测试 KernelAgent 的 :memory 集成（历史由 store 自管）"
  (let* ((store (cl-agent.kernel:make-in-memory-chat-store))
         (mock (make-sequenced-mock
                (list :content "reply-1")
                (list :content "reply-2")))
         (kernel (cl-agent.kernel:make-kernel :service mock))
         (agent (cl-agent.simpleagent:make-kernel-agent
                 kernel
                 :name "memory-agent"
                 :memory store
                 :conversation-id "agent-conv")))
    (is (string= "reply-1" (cl-agent.simpleagent:agent-chat agent "hello")))
    (is (string= "reply-2" (cl-agent.simpleagent:agent-chat agent "again")))
    ;; agent-get-history 走 store
    (let ((history (cl-agent.simpleagent:agent-get-history agent)))
      (is (= 4 (length history)))
      (is (equal '("hello" "reply-1" "again" "reply-2")
                 (mapcar (lambda (m) (getf m :content)) history))))
    ;; reset 清空 store 会话
    (cl-agent.simpleagent:agent-reset agent)
    (is (null (cl-agent.kernel:mem-get store "agent-conv")))))
