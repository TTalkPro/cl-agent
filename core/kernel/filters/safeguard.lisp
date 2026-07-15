;;;; safeguard.lisp
;;;; CL-Agent Kernel Filters - 安全护栏 (:turn, 最外层)
;;;;
;;;; 概述（对标 clj-agent safeguard-turn-filter + Spring SafeGuardAdvisor）：
;;;;   入口消息命中敏感词 → 不进循环，直接返回拒答。
;;;;   大小写不敏感（比 Spring 原版更严格）。
;;;;   被拦的输入与拒答都不落库（短路在 :turn 层，:chat memory 不执行）。

(in-package #:cl-agent.kernel)

(defun safeguard-turn-filter (keywords &key (failure-response "抱歉，无法处理该请求。"))
  "创建 safeguard-turn-filter（:turn 链，最外层守卫）。

  参数：
  - keywords         敏感词字符串列表
  - failure-response 命中时的拒答文本

  行为：
  - 检查入口 messages 中所有文本内容
  - 大小写不敏感匹配
  - 命中 → 返回 turn-result(:cancelled)，不调 chain
  - 未命中 → 正常调 chain

  边界：只查入口消息，不查工具结果或模型输出（输出侧用 token-xform）。"
  (let ((lower-keywords (mapcar (lambda (kw)
                                  (string-downcase (string kw)))
                                keywords)))
    (make-filter
     :safeguard
     :turn (lambda (req chain)
             (let ((texts (mapcar (lambda (m)
                                    (string-downcase
                                     (or (cl-agent.chat:message-text m) "")))
                                  (turn-request-messages req))))
               ;; 检查任一消息是否包含任一敏感词
               (if (some (lambda (kw)
                           (some (lambda (text) (search kw text)) texts))
                         lower-keywords)
                   ;; 命中：短路
                   (make-turn-result
                    :cancelled
                    :response (cl-agent.chat:make-chat-response
                               (cl-agent.chat:make-generation
                                (cl-agent.chat:assistant-message failure-response)
                                :finish-reason :stop)))
                   ;; 未命中：正常进入循环
                   (funcall chain req)))))))
