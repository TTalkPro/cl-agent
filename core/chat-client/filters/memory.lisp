;;;; memory.lisp
;;;; CL-Agent ChatClient Filters - Memory Filter (:chat, 循环内首位)
;;;;
;;;; 概述（对标 clj-agent advisor/memory.clj + Spring MessageChatMemoryAdvisor）：
;;;;   memory-filter 挂在 :chat 链首位（循环内），每轮 LLM 调用前后执行：
;;;;   - before: 存 delta 消息 → 用完整历史替换 prompt messages
;;;;   - after: 存 assistant 回复（含 tool-calls）
;;;;
;;;;   **刻意放循环内**（与 Spring 放循环外不同）：每轮落完整 transcript，
;;;;   heal-dangling、暂停恢复、timeline 全依赖完整历史。

(in-package #:cl-agent/core)

(defun crop-history-to-window (history window)
  "把 HISTORY 裁到最后 WINDOW 条，但起点**前移到最近的 user 消息**。

  为什么不能纯按数量 subseq：历史里 assistant(tool_use) 与其
  tool(tool_result) 是**成对**的，纯数量裁剪可能切在对中间——留下
  以孤儿 tool_result 开头的序列，Anthropic / MiniMax 直接 400
  （tool_result 必须紧跟 tool_use；且首条须为 user）。

  策略：从数量边界往更早退，退到最近一条 user 消息为止。宁可多带几条
  历史（略超 window），也不发非法序列。history 不含 system——filter 存
  历史时已跳过，展开时 system 单独置顶。"
  (if (<= (length history) window)
      history
      (let ((start (- (length history) window)))
        (loop while (and (> start 0)
                         (not (user-message-p (nth start history))))
              do (decf start))
        (subseq history start))))

(defun memory-filter (store &key (window 20))
  "创建 memory-filter（:chat 链首位，循环内）。

  参数：
  - store   chat-memory 实例（cl-agent/core:message-window-chat-memory 等）
  - window  滑动窗口大小（传给 memory-messages 裁剪；缺省 20）

  行为：
  - 从 prompt options 的 tool-context 取 :conversation-id
  - 无 conversation-id → 直接 passthrough（不记不读）
  - 有 conversation-id → 存 delta / 展开历史 / 存回复
  - **system 消息不进历史**：它每轮由 prompt 重新提供，存进去会随轮次
    线性累积。展开时把本轮的 system 置顶，window 只裁历史不碰 system。

  使用：应注册为 filters 列表的首位（其他 filter 看到完整历史）。"
  (make-filter
   :memory
   :chat (lambda (prompt chain)
           (let* ((options (cl-agent/core:prompt-options prompt))
                  (ctx (cl-agent/core:chat-options-tool-context options))
                  (conv-id (getf ctx :conversation-id)))
             (if conv-id
                 ;; 有会话 ID：存 delta → 展开历史 → 调下游 → 存回复
                 (let* ((msgs (cl-agent/core:prompt-messages prompt))
                        (system-msgs (remove-if-not #'cl-agent/core:system-message-p msgs)))
                   ;; before: 只存**尚未存过的非 system** 消息。
                   ;;
                   ;; 两条规则，各修一个真实 bug：
                   ;;
                   ;; 1. system 不进历史——它由每轮的 prompt 重新提供（chat-client 的
                   ;;    :system 默认值或请求级 (:system ...)）。此前存了全部
                   ;;    prompt 消息，于是每轮的 system 都被追加一份，历史里
                   ;;    system 随轮次线性累积。
                   ;;
                   ;; 2. eq 幂等——run-tool-loop 传的是**本轮累积的完整 messages**
                   ;;    （不是 delta），而本 filter 挂在 :chat 链、工具循环每轮
                   ;;    都会过一遍。不去重的话，第 2 轮会把 user/assistant 再存
                   ;;    一份：历史变成 (user assistant user assistant tool ...)，
                   ;;    发给模型的序列直接非法（Anthropic 格式要求 user/assistant
                   ;;    交替、tool_result 紧跟 tool_use）——实测 MiniMax 返回 400。
                   ;;    循环用 append 累积，同一条消息在各轮是**同一个对象**，
                   ;;    所以 eq 就能准确判断「这条存过没有」。
                   (let ((seen (cl-agent/core:memory-messages store conv-id)))
                     (dolist (msg msgs)
                       (unless (or (cl-agent/core:system-message-p msg)
                                   (member msg seen :test #'eq))
                         (cl-agent/core:memory-add store conv-id msg))))
                   ;; 用「本轮 system 置顶 + 裁剪后的历史」替换 prompt。
                   ;; window 只裁历史，不碰 system——否则长对话里 system
                   ;; 会先被裁掉，模型直接失忆人设。
                   (let* ((history (cl-agent/core:memory-messages store conv-id))
                          ;; 按 user 边界裁剪——纯数量 subseq 会切开
                          ;; tool_use/tool_result 对（见 crop-history-to-window）
                          (cropped (crop-history-to-window history window))
                          (new-prompt (cl-agent/core:prompt-copy
                                       prompt :messages (append system-msgs cropped)))
                          ;; 调下游（LLM）
                          (response (funcall chain new-prompt)))
                     ;; after: 存 assistant 回复
                     (cl-agent/core:memory-add
                      store conv-id
                      (cl-agent/core:chat-response-message response))
                     response))
                 ;; 无会话 ID：直接透传
                 (funcall chain prompt))))))
