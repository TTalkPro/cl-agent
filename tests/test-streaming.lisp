;;;; test-streaming.lisp
;;;; CL-Agent - SSE 流式处理器测试（离线，喂事件序列）
;;;;
;;;; 覆盖：
;;;;   - Anthropic 流处理器：文本/thinking/工具输入分片累积、
;;;;     usage 合并、finish-reason、错误事件
;;;;   - OpenAI 兼容流处理器：delta.content / reasoning_content /
;;;;     tool_calls 分片拼接、末块 usage、[DONE]

(in-package :cl-agent/tests)

(def-suite streaming-suite :in cl-agent-suite
  :description "SSE 流式处理器（Anthropic + OpenAI 兼容）")

(in-suite streaming-suite)

(defun json-ht (json-string)
  "解析 JSON 字符串为 hash-table（测试辅助）"
  (cl-agent/core:json-parse json-string))

;;; ============================================================
;;; Anthropic 流处理器
;;; ============================================================

(defun run-anthropic-events (events &optional callback)
  "喂事件序列（JSON 字符串列表），返回最终 llm-response"
  (let ((state (cl-agent/llm/providers::make-anthropic-stream-state)))
    (dolist (json events)
      (let ((data (json-ht json)))
        (cl-agent/llm/providers::process-anthropic-event
         state (gethash "type" data) data callback)))
    (cl-agent/llm/providers::build-anthropic-stream-response state)))

(defparameter +anthropic-text-events+
  (list "{\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"model\":\"MiniMax-M2.7\",\"usage\":{\"input_tokens\":10}}}"
        "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}"
        "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"你好\"}}"
        "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"，世界\"}}"
        "{\"type\":\"content_block_stop\",\"index\":0}"
        "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":5}}"
        "{\"type\":\"message_stop\"}"))

(test anthropic-stream-text-accumulation
  "文本增量累积 + 元数据 + usage 合并"
  (let ((response (run-anthropic-events +anthropic-text-events+)))
    (is (string= "你好，世界" (cl-agent/core:llm-response-content response)))
    (is (eq :stop (cl-agent/core:llm-response-finish-reason response)))
    (is (string= "msg_1" (cl-agent/core:llm-response-message-id response)))
    (is (string= "MiniMax-M2.7" (cl-agent/core:llm-response-model response)))
    ;; message_start 的 input + message_delta 的 output 合并
    (is (= 10 (cl-agent/core:llm-response-input-tokens response)))
    (is (= 5 (cl-agent/core:llm-response-output-tokens response)))))

(test anthropic-stream-callback-chunks
  "回调按序收到文本增量"
  (let ((chunks nil))
    (run-anthropic-events +anthropic-text-events+
                          (lambda (chunk) (push chunk chunks)))
    (is (equal '("你好" "，世界")
               (mapcar (lambda (c) (getf c :delta)) (reverse chunks))))))

(test anthropic-stream-tool-use
  "tool_use 块：input_json_delta 分片拼接并解析"
  (let ((response (run-anthropic-events
                   (list "{\"type\":\"message_start\",\"message\":{\"id\":\"msg_2\",\"model\":\"m\",\"usage\":{\"input_tokens\":1}}}"
                         "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_1\",\"name\":\"get_weather\",\"input\":{}}}"
                         "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"city\\\": \"}}"
                         "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"\\\"东京\\\"}\"}}"
                         "{\"type\":\"content_block_stop\",\"index\":0}"
                         "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":2}}"))))
    (is (eq :tool-call (cl-agent/core:llm-response-finish-reason response)))
    (let ((tc (first (cl-agent/core:llm-response-tool-calls response))))
      (is (string= "toolu_1" (cl-agent/core:llm-tool-call-id tc)))
      ;; make-llm-response 把 name 归一化为关键字
      (is (eq :get_weather (cl-agent/core:llm-tool-call-name tc)))
      ;; 分片 JSON 拼接后正确解析（start 自带的空 {} 占位不污染）
      (is (string= "东京"
                   (gethash "city" (cl-agent/core:llm-tool-call-arguments tc)))))))

(test anthropic-stream-thinking
  "thinking_delta：累积到 reasoning，经 :reasoning-delta 单独下发"
  (let* ((chunks nil)
         (response (run-anthropic-events
                    (list "{\"type\":\"message_start\",\"message\":{\"id\":\"m\",\"model\":\"m\",\"usage\":{\"input_tokens\":1}}}"
                          "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"thinking\"}}"
                          "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"先想想\"}}"
                          "{\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}"
                          "{\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"text_delta\",\"text\":\"答案\"}}"
                          "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}")
                    (lambda (chunk) (push chunk chunks)))))
    ;; 思考不污染答案流
    (is (string= "答案" (cl-agent/core:llm-response-content response)))
    (is (string= "先想想" (cl-agent/core:llm-response-reasoning response)))
    (let ((reasoning-chunks (remove-if-not (lambda (c) (getf c :reasoning-delta))
                                           chunks)))
      (is (= 1 (length reasoning-chunks))))))

(test anthropic-stream-error-event
  "error 事件在构建响应时抛 llm-error"
  (signals cl-agent/core:llm-error
    (run-anthropic-events
     (list "{\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"Overloaded\"}}"))))

;;; ============================================================
;;; OpenAI 兼容流处理器
;;; ============================================================

(defun run-openai-chunks (chunks-json &optional callback)
  "喂 chunk 序列（JSON 字符串列表），返回最终 llm-response"
  (let ((state (cl-agent/llm/providers::make-openai-stream-state)))
    (dolist (json chunks-json)
      (cl-agent/llm/providers::process-openai-chunk
       state (json-ht json) callback))
    (cl-agent/llm/providers::build-openai-stream-response state)))

(test openai-stream-text-accumulation
  "delta.content 累积 + 元数据 + 末块 usage"
  (let* ((chunks nil)
         (response (run-openai-chunks
                    (list "{\"id\":\"cc-1\",\"model\":\"deepseek-chat\",\"choices\":[{\"delta\":{\"role\":\"assistant\",\"content\":\"\"}}]}"
                          "{\"id\":\"cc-1\",\"choices\":[{\"delta\":{\"content\":\"你好\"}}]}"
                          "{\"id\":\"cc-1\",\"choices\":[{\"delta\":{\"content\":\"！\"}}]}"
                          "{\"id\":\"cc-1\",\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":8,\"completion_tokens\":3}}")
                    (lambda (chunk) (push chunk chunks)))))
    (is (string= "你好！" (cl-agent/core:llm-response-content response)))
    (is (eq :stop (cl-agent/core:llm-response-finish-reason response)))
    (is (string= "cc-1" (cl-agent/core:llm-response-message-id response)))
    (is (string= "deepseek-chat" (cl-agent/core:llm-response-model response)))
    (is (= 8 (cl-agent/core:llm-response-input-tokens response)))
    (is (= 3 (cl-agent/core:llm-response-output-tokens response)))
    (is (equal '("你好" "！")
               (mapcar (lambda (c) (getf c :delta)) (reverse chunks))))))

(test openai-stream-tool-call-fragments
  "tool_calls 分片：首片带 id/name，arguments 逐片拼接"
  (let ((response (run-openai-chunks
                   (list "{\"id\":\"cc-2\",\"model\":\"m\",\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_1\",\"function\":{\"name\":\"get_weather\",\"arguments\":\"\"}}]}}]}"
                         "{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"{\\\"city\\\":\"}}]}}]}"
                         "{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"\\\"东京\\\"}\"}}]}}]}"
                         "{\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}]}"))))
    (is (eq :tool-call (cl-agent/core:llm-response-finish-reason response)))
    (let ((tc (first (cl-agent/core:llm-response-tool-calls response))))
      (is (string= "call_1" (cl-agent/core:llm-tool-call-id tc)))
      (is (eq :get_weather (cl-agent/core:llm-tool-call-name tc)))
      (is (string= "东京"
                   (gethash "city" (cl-agent/core:llm-tool-call-arguments tc)))))))

(test openai-stream-reasoning-content
  "reasoning_content 增量单独下发且不污染答案"
  (let* ((chunks nil)
         (response (run-openai-chunks
                    (list "{\"id\":\"cc-3\",\"model\":\"deepseek-reasoner\",\"choices\":[{\"delta\":{\"reasoning_content\":\"思考中\"}}]}"
                          "{\"choices\":[{\"delta\":{\"content\":\"答案\"}}]}"
                          "{\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}")
                    (lambda (chunk) (push chunk chunks)))))
    (is (string= "答案" (cl-agent/core:llm-response-content response)))
    (is (string= "思考中" (cl-agent/core:llm-response-reasoning response)))
    (is (= 1 (count-if (lambda (c) (getf c :reasoning-delta)) chunks)))
    (is (= 1 (count-if (lambda (c) (getf c :delta)) chunks)))))

(test openai-stream-null-finish-reason-ignored
  "中间 chunk 的 finish_reason:null 不覆盖状态"
  (let ((response (run-openai-chunks
                   (list "{\"id\":\"cc-4\",\"model\":\"m\",\"choices\":[{\"delta\":{\"content\":\"x\"},\"finish_reason\":null}]}"
                         "{\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}"))))
    (is (eq :stop (cl-agent/core:llm-response-finish-reason response)))))

;;; ============================================================
;;; 能力声明
;;; ============================================================

(test streaming-capability-declared
  "anthropic 系与 openai-compat 系都声明支持流式"
  (is-true (cl-agent/core:provider-supports-streaming-p
            (cl-agent/llm/providers:make-minimax-provider :api-key "k")))
  (is-true (cl-agent/core:provider-supports-streaming-p
            (cl-agent/llm/providers:make-anthropic-provider :api-key "k")))
  (is-true (cl-agent/core:provider-supports-streaming-p
            (cl-agent/llm/providers:make-mistral-provider :api-key "k"))))
