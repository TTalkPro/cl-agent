;;;; test-options.lisp
;;;; CL-Agent - ChatOptions 合并语义测试

(in-package :cl-agent/tests)

(def-suite options-suite :in cl-agent-suite
  :description "ChatOptions 未设置语义与合并规则")

(in-suite options-suite)

(test options-unset-defaults
  "未设置的选项返回默认值"
  (let ((options (cl-agent.chat:make-chat-options)))
    (is (null (cl-agent.chat:chat-options-temperature options)))
    (is (null (cl-agent.chat:chat-options-model options)))
    ;; 内部工具执行默认开启（Spring AI 同默认）
    (is-true (cl-agent.chat:chat-options-internal-tool-execution-enabled options))
    (is (= 10 (cl-agent.chat:chat-options-max-tool-iterations options)))))

(test options-nil-safe
  "NIL options 也能安全读取"
  (is (null (cl-agent.chat:chat-options-temperature nil)))
  (is-true (cl-agent.chat:chat-options-internal-tool-execution-enabled nil)))

(test options-explicit-nil-vs-unset
  "显式设 NIL 与未设置可区分（显式关闭内部工具执行）"
  (let ((options (cl-agent.chat:make-chat-options
                  :internal-tool-execution-enabled nil)))
    (is-false (cl-agent.chat:chat-options-internal-tool-execution-enabled options))))

(test options-merge-priority
  "合并：运行时选项覆盖默认选项，未设置的沿用默认"
  (let* ((runtime (cl-agent.chat:make-chat-options :temperature 0.2))
         (defaults (cl-agent.chat:make-chat-options :temperature 0.9
                                                    :max-tokens 100
                                                    :model "default-model"))
         (merged (cl-agent.chat:merge-chat-options runtime defaults)))
    (is (= 0.2 (cl-agent.chat:chat-options-temperature merged)))
    (is (= 100 (cl-agent.chat:chat-options-max-tokens merged)))
    (is (string= "default-model" (cl-agent.chat:chat-options-model merged)))))

(test options-merge-nil-fallback
  "任一侧为 NIL 时合并仍成立"
  (let ((merged (cl-agent.chat:merge-chat-options
                 nil (cl-agent.chat:make-chat-options :max-tokens 42))))
    (is (= 42 (cl-agent.chat:chat-options-max-tokens merged))))
  (let ((merged (cl-agent.chat:merge-chat-options
                 (cl-agent.chat:make-chat-options :max-tokens 7) nil)))
    (is (= 7 (cl-agent.chat:chat-options-max-tokens merged)))))

(test options-merge-tools-union
  "tool-callbacks / tool-names 合并取并集"
  (let* ((cb1 (cl-agent.chat:make-tool-callback
               (lambda (&key) "1") :name "tool_one"))
         (cb2 (cl-agent.chat:make-tool-callback
               (lambda (&key) "2") :name "tool_two"))
         (merged (cl-agent.chat:merge-chat-options
                  (cl-agent.chat:make-chat-options :tool-callbacks (list cb1))
                  (cl-agent.chat:make-chat-options :tool-callbacks (list cb2)))))
    (is (= 2 (length (cl-agent.chat:chat-options-tool-callbacks merged))))))

(test options-merge-immutable
  "合并不修改入参"
  (let* ((a (cl-agent.chat:make-chat-options :temperature 0.1))
         (b (cl-agent.chat:make-chat-options :temperature 0.5)))
    (cl-agent.chat:merge-chat-options a b)
    (is (= 0.1 (cl-agent.chat:chat-options-temperature a)))
    (is (= 0.5 (cl-agent.chat:chat-options-temperature b)))))

(test options-copy
  "copy-chat-options 保留未设置状态"
  (let* ((original (cl-agent.chat:make-chat-options :temperature 0.3))
         (copy (cl-agent.chat:copy-chat-options original)))
    (is (= 0.3 (cl-agent.chat:chat-options-temperature copy)))
    (is (null (cl-agent.chat:chat-options-max-tokens copy)))
    ;; 拷贝独立
    (setf (slot-value copy 'cl-agent.chat::temperature) 0.8)
    (is (= 0.3 (cl-agent.chat:chat-options-temperature original)))))
