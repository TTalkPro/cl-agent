;;;; llm-usage.lisp
;;;; CL-Agent - LLM 使用示例

;; 加载系统
(asdf:load-system :cl-agent)

;; 使用包
(in-package :cl-user)
(use-package :cl-agent)

;;; ============================================================
;;; 示例 1：基础聊天
;;; ============================================================

(defun example-1-basic-chat ()
  "最简单的聊天示例"
  (format t "~%=== Example 1: Basic Chat ===~%")

  ;; 创建客户端
  (let ((client (make-client :provider :anthropic)))

    ;; 发送消息
    (let ((response (chat-simple client "What is Common Lisp?")))
      (format t "Response: ~A~%" response))))

;;; ============================================================
;;; 示例 2：带系统提示
;;; ============================================================

(defun example-2-system-prompt ()
  "使用系统提示"
  (format t "~%=== Example 2: System Prompt ===~%")

  (let ((client (make-client :provider :anthropic)))

    (let ((response (chat-simple client
                                 "Explain recursion"
                                 :system "You are a programming tutor.
                                           Explain concepts clearly and concisely.")))
      (format t "Response: ~A~%" response))))

;;; ============================================================
;;; 示例 3：多轮对话
;;; ============================================================

(defun example-3-multi-turn ()
  "多轮对话示例"
  (format t "~%=== Example 3: Multi-turn Conversation ===~%")

  (let ((client (make-client :provider :anthropic)))

    ;; 对话历史
    (let ((conversation `((:user . "My name is Alice"))))

      ;; 第一轮
      (let ((response1 (chat-multi-turn client conversation)))
        (format t "Assistant: ~A~%" response1)

        ;; 添加到历史
        (push `(:assistant . ,response1) conversation)

        ;; 第二轮
        (push `(:user . "What's my name?") conversation)
        (let ((response2 (chat-multi-turn client (nreverse conversation))))
          (format t "Assistant: ~A~%" response2))))))

;;; ============================================================
;;; 示例 4：流式响应
;;; ============================================================

(defun example-4-streaming ()
  "流式响应示例"
  (format t "~%=== Example 4: Streaming Response ===~%")

  (let ((client (make-client :provider :anthropic)))

    (format t "Assistant: ")
    (chat-stream-simple client
                       "Tell me a short story about a robot"
                       (lambda (text)
                         (format t "~A" text)
                         (force-output)))
    (terpri)))

;;; ============================================================
;;; 示例 5：流式到字符串
;;; ============================================================

(defun example-5-stream-to-string ()
  "流式响应并收集到字符串"
  (format t "~%=== Example 5: Stream to String ===~%")

  (let ((client (make-client :provider :anthropic)))

    (let ((response (chat-stream-to-string client "Count to 10")))
      (format t "Full response: ~A~%" response))))

;;; ============================================================
;;; 示例 6：流式迭代器
;;; ============================================================

(defun example-6-stream-iterator ()
  "使用流式迭代器"
  (format t "~%=== Example 6: Stream Iterator ===~%")

  (let ((client (make-client :provider :anthropic)))

    (let ((iterator (chat-stream-iterator client
                                          '((:user . "List 5 programming languages")))))

      (format t "Response: ")
      (loop for chunk = (stream-next iterator)
            while chunk
            do (format t "~A" chunk))
      (terpri))))

;;; ============================================================
;;; 示例 7：批量处理
;;; ============================================================

(defun example-7-batch-chat ()
  "批量处理多个提示"
  (format t "~%=== Example 7: Batch Processing ===~%")

  (let ((client (make-client :provider :anthropic)))

    (let ((prompts '("What is AI?"
                    "What is ML?"
                    "What is Deep Learning?")))

      (let ((responses (batch-chat client prompts :parallel t)))
        (loop for prompt in prompts
              for response in responses
              do (format t "~%~A => ~A~%" prompt (subseq response 0 (min 50 (length response)))))))))

;;; ============================================================
;;; 示例 8：不同提供商
;;; ============================================================

(defun example-8-different-providers ()
  "使用不同提供商"
  (format t "~%=== Example 8: Different Providers ===~%")

  ;; Anthropic Claude
  (format t "~%Claude:~%")
  (let ((claude-client (make-client :provider :anthropic
                                    :model "claude-3-5-sonnet-20241022")))
    (format t "~A~%" (chat-simple claude-client "Say 'Hello from Claude!'")))

  ;; OpenAI GPT
  (format t "~%GPT:~%")
  (let ((gpt-client (make-client :provider :openai
                                 :model "gpt-4o-mini")))
    (format t "~A~%" (chat-simple gpt-client "Say 'Hello from GPT!'")))

  ;; Ollama（本地）
  ;; (format t "~%Ollama:~%")
  ;; (let ((ollama-client (make-client :provider :ollama
  ;;                                   :model "llama3.2")))
  ;;   (format t "~A~%" (chat-simple ollama-client "Say 'Hello from Ollama!'"))))

  )

;;; ============================================================
;;; 示例 9：Token 计数和成本估算
;;; ============================================================

(defun example-9-token-counting ()
  "Token 计数和成本估算"
  (format t "~%=== Example 9: Token Counting & Cost Estimation ===~%")

  (let ((client (make-client :provider :anthropic))
        (text "Common Lisp is a dialect of the Lisp programming language."))

    (let ((tokens (count-tokens-for-client client text)))
      (format t "Text: ~A~%" text)
      (format t "Estimated tokens: ~A~%" tokens)

      (let ((cost (estimate-cost client tokens 0)))
        (format t "Estimated cost: $~F~%" cost)))))

;;; ============================================================
;;; 示例 10：流式到文件
;;; ============================================================

(defun example-10-stream-to-file ()
  "流式响应并写入文件"
  (format t "~%=== Example 10: Stream to File ===~%")

  (let ((client (make-client :provider :anthropic)))

    (let ((response (chat-stream-to-file client
                                         "Write a haiku about programming"
                                         "/tmp/haiku.txt")))
      (format t "Response written to /tmp/haiku.txt~%")
      (format t "Content: ~A~%" response))))

;;; ============================================================
;;; 运行所有示例
;;; ============================================================

(defun run-llm-examples ()
  "运行所有 LLM 示例"
  (format t "~%========================================")
  (format t "~%  CL-Agent LLM Examples")
  (format t "~%========================================")

  (example-1-basic-chat)
  (example-2-system-prompt)
  (example-3-multi-turn)
  (example-4-streaming)
  (example-5-stream-to-string)
  (example-6-stream-iterator)
  (example-7-batch-chat)
  (example-8-different-providers)
  (example-9-token-counting)
  (example-10-stream-to-file)

  (format t "~%========================================")
  (format t "~%  All examples completed!")
  (format t "~%========================================~%"))

;; 运行示例（取消注释）
;; (run-llm-examples)
