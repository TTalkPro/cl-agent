;;;; memory.lisp
;;;; CL-Agent Kernel Filters - Memory Filter (:chat, 循环内首位)
;;;;
;;;; 概述（对标 clj-agent advisor/memory.clj + Spring MessageChatMemoryAdvisor）：
;;;;   memory-filter 挂在 :chat 链首位（循环内），每轮 LLM 调用前后执行：
;;;;   - before: 存 delta 消息 → 用完整历史替换 prompt messages
;;;;   - after: 存 assistant 回复（含 tool-calls）
;;;;
;;;;   **刻意放循环内**（与 Spring 放循环外不同）：每轮落完整 transcript，
;;;;   heal-dangling、暂停恢复、timeline 全依赖完整历史。

(in-package #:cl-agent.kernel)

(defun memory-filter (store &key (window 20))
  "创建 memory-filter（:chat 链首位，循环内）。

  参数：
  - store   chat-memory 实例（cl-agent.chat:message-window-chat-memory 等）
  - window  滑动窗口大小（传给 memory-messages 裁剪；缺省 20）

  行为：
  - 从 prompt options 的 tool-context 取 :conversation-id
  - 无 conversation-id → 直接 passthrough（不记不读）
  - 有 conversation-id → 存 delta / 展开历史 / 存回复

  使用：应注册为 filters 列表的首位（其他 filter 看到完整历史）。"
  (make-filter
   :memory
   :chat (lambda (prompt chain)
           (let* ((options (cl-agent.chat:prompt-options prompt))
                  (ctx (cl-agent.chat:chat-options-tool-context options))
                  (conv-id (getf ctx :conversation-id)))
             (if conv-id
                 ;; 有会话 ID：存 delta → 展开历史 → 调下游 → 存回复
                 (progn
                   ;; before: 存本轮新消息（delta）
                   (dolist (msg (cl-agent.chat:prompt-messages prompt))
                     (cl-agent.chat:memory-add store conv-id msg))
                   ;; 用完整历史替换 prompt
                   (let* ((history (cl-agent.chat:memory-messages store conv-id))
                          (cropped (if (> (length history) window)
                                       (subseq history (- (length history) window))
                                       history))
                          (new-prompt (cl-agent.chat:prompt-copy prompt :messages cropped))
                          ;; 调下游（LLM）
                          (response (funcall chain new-prompt)))
                     ;; after: 存 assistant 回复
                     (cl-agent.chat:memory-add
                      store conv-id
                      (cl-agent.chat:chat-response-message response))
                     response))
                 ;; 无会话 ID：直接透传
                 (funcall chain prompt))))))
