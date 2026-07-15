;;;; test-structured-output.lisp
;;;; CL-Agent - StructuredOutputValidationAdvisor 测试
;;;;
;;;; 覆盖：
;;;;   - 合法输出不重试；非法输出带着校验错误重试
;;;;   - 每次重试从*原始*请求增强，不累积错误提示
;;;;   - 重试用尽返回最后一次响应（不发条件）
;;;;   - max-repeat-attempts=0 只调一次
;;;;   - markdown 围栏容忍
;;;;   - 流式明确报错
;;;;   - 与工具循环的配合：带 tool-calls 的响应直接放行

(in-package :cl-agent/tests)

(def-suite structured-output-suite :in cl-agent-suite
  :description "结构化输出校验 Advisor")

(in-suite structured-output-suite)

(defparameter +city-schema+
  "{\"type\":\"object\",\"properties\":{\"city\":{\"type\":\"string\"}},
    \"required\":[\"city\"]}")

(defun run-structured (advisor replies &key (user-text "给出城市"))
  "用 REPLIES（文本列表）依次应答，返回 (values 最终文本 调用次数 每次的user文本)"
  (let ((calls 0)
        (seen '()))
    (let* ((terminal
             (lambda (request)
               (incf calls)
               (push (cl-agent.chat:prompt-last-user-text
                      (cl-agent.client:client-request-prompt request))
                     seen)
               (cl-agent.client:make-client-response
                (cl-agent.chat:make-chat-response
                 (cl-agent.chat:make-generation
                  (cl-agent.chat:assistant-message (or (pop replies) "{}"))))
                :context (cl-agent.client:client-request-context request))))
           (response (cl-agent.client:chain-next
                      (cl-agent.client:make-advisor-chain (list advisor) terminal)
                      (cl-agent.client:make-client-request
                       (cl-agent.chat:make-prompt user-text)))))
      (values (cl-agent.chat:chat-response-text
               (cl-agent.client:client-response-chat-response response))
              calls
              (nreverse seen)))))

;;; ============================================================
;;; 校验与自我纠正
;;; ============================================================

(test structured-output-valid-does-not-retry
  "合法输出：一次调用通过"
  (multiple-value-bind (text calls)
      (run-structured (cl-agent.client:make-structured-output-validation-advisor
                       :json-schema +city-schema+)
                      (list "{\"city\":\"东京\"}"))
    (is (string= "{\"city\":\"东京\"}" text))
    (is (= 1 calls))))

(test structured-output-retries-with-validation-error
  "校验失败：把错误追加到 user 消息后重试，成功即返回"
  (multiple-value-bind (text calls seen)
      (run-structured (cl-agent.client:make-structured-output-validation-advisor
                       :json-schema +city-schema+)
                      (list "{\"wrong\":1}" "{\"city\":\"大阪\"}"))
    (is (string= "{\"city\":\"大阪\"}" text))
    (is (= 2 calls))
    ;; 首次调用的 user 文本是干净的
    (is (string= "给出城市" (first seen)))
    ;; 重试时带上了校验错误
    (is (search "给出城市" (second seen)))
    (is (search "未通过校验" (second seen)))
    (is (search "city" (second seen)))))

(test structured-output-does-not-accumulate-errors
  "多轮重试每次都从原始请求增强，不累积出一长串错误提示"
  (multiple-value-bind (text calls seen)
      (run-structured (cl-agent.client:make-structured-output-validation-advisor
                       :json-schema +city-schema+ :max-repeat-attempts 3)
                      (list "{\"a\":1}" "{\"b\":2}" "{\"city\":\"京都\"}"))
    (declare (ignore text calls))
    ;; 第 2、3 次调用的 user 文本里「未通过校验」都只出现一次
    (flet ((count-occurrences (needle haystack)
             (loop with start = 0
                   for pos = (search needle haystack :start2 start)
                   while pos
                   count 1
                   do (setf start (+ pos (length needle))))))
      (is (= 1 (count-occurrences "未通过校验" (second seen))))
      (is (= 1 (count-occurrences "未通过校验" (third seen)))))))

(test structured-output-exhausted-returns-last-response
  "重试用尽：返回最后一次响应而非发条件——校验是尽力而为的增强"
  (multiple-value-bind (text calls)
      (run-structured (cl-agent.client:make-structured-output-validation-advisor
                       :json-schema +city-schema+ :max-repeat-attempts 2)
                      (list "{\"a\":1}" "{\"b\":2}" "{\"c\":3}" "{\"d\":4}"))
    ;; 1 次初始 + 2 次重试 = 3 次调用，返回第 3 次的响应
    (is (string= "{\"c\":3}" text))
    (is (= 3 calls))))

(test structured-output-zero-attempts-calls-once
  "max-repeat-attempts=0：模型只调用一次，不重试"
  (multiple-value-bind (text calls)
      (run-structured (cl-agent.client:make-structured-output-validation-advisor
                       :json-schema +city-schema+ :max-repeat-attempts 0)
                      (list "{\"a\":1}" "{\"city\":\"x\"}"))
    (is (string= "{\"a\":1}" text))
    (is (= 1 calls))))

(test structured-output-tolerates-markdown-fences
  "模型裹上 ```json 围栏时不应误判为校验失败"
  (multiple-value-bind (text calls)
      (run-structured (cl-agent.client:make-structured-output-validation-advisor
                       :json-schema +city-schema+)
                      (list (format nil "```json~%{\"city\":\"京都\"}~%```")))
    (declare (ignore text))
    (is (= 1 calls))))

(test structured-output-empty-text-is-a-failure
  "空响应文本按校验失败处理"
  (multiple-value-bind (text calls)
      (run-structured (cl-agent.client:make-structured-output-validation-advisor
                       :json-schema +city-schema+ :max-repeat-attempts 1)
                      (list "   " "{\"city\":\"奈良\"}"))
    (is (string= "{\"city\":\"奈良\"}" text))
    (is (= 2 calls))))

;;; ============================================================
;;; 构造期校验
;;; ============================================================

(test structured-output-requires-schema
  "缺 :json-schema 立即报错"
  (signals error (cl-agent.client:make-structured-output-validation-advisor)))

(test structured-output-rejects-negative-attempts
  "max-repeat-attempts 须为非负整数"
  (signals error
    (cl-agent.client:make-structured-output-validation-advisor
     :json-schema +city-schema+ :max-repeat-attempts -1)))

(test structured-output-rejects-bad-schema-at-construction
  "schema 写错时构造期就暴露，而不是等到第一次调用"
  (signals error
    (cl-agent.client:make-structured-output-validation-advisor
     :json-schema "{不是合法 JSON")))

;;; ============================================================
;;; 排序与流式
;;; ============================================================

(test structured-output-default-order-is-innermost
  "默认 order 位于工具循环内侧——因此能看到每一轮的模型响应"
  (is (> (cl-agent.client:advisor-order
          (cl-agent.client:make-structured-output-validation-advisor
           :json-schema +city-schema+))
         cl-agent.client:+tool-calling-advisor-order+)))

(test structured-output-streaming-unsupported
  "流式明确报错而非静默降级：校验需要完整 JSON 文本"
  (signals cl-agent.client:structured-output-streaming-unsupported-error
    (cl-agent.client:advise-stream
     (cl-agent.client:make-structured-output-validation-advisor
      :json-schema +city-schema+)
     (cl-agent.client:make-client-request (cl-agent.chat:make-prompt "x"))
     (cl-agent.client:make-advisor-chain
      nil (lambda (request) (declare (ignore request)) nil))
     (lambda (delta) (declare (ignore delta))))))

;;; ============================================================
;;; 与工具循环的配合
;;; ============================================================

(cl-agent.chat:deftool so-get-city ()
  "返回一个城市名"
  "东京")

(test structured-output-passes-tool-calls-through
  "位于工具循环内侧时，带 tool-calls 的响应直接放行给工具循环，不做校验"
  (let* ((calls 0)
         (tool-advisor (cl-agent.client:make-tool-calling-advisor))
         (validation (cl-agent.client:make-structured-output-validation-advisor
                      :json-schema +city-schema+))
         ;; 第一轮返回工具调用（不是合法 JSON，但不应触发重试），
         ;; 工具执行后第二轮返回合法 JSON
         (terminal
           (lambda (request)
             (incf calls)
             (cl-agent.client:make-client-response
              (if (= calls 1)
                  (cl-agent.chat:make-chat-response
                   (cl-agent.chat:make-generation
                    (cl-agent.chat:assistant-message
                     "我查一下"
                     :tool-calls (list (cl-agent.chat:make-tool-call
                                        :id "c1" :name "so-get-city"
                                        :arguments (make-hash-table :test #'equal))))
                    :finish-reason :tool-call))
                  (cl-agent.chat:make-chat-response
                   (cl-agent.chat:make-generation
                    (cl-agent.chat:assistant-message "{\"city\":\"东京\"}"))))
              :context (cl-agent.client:client-request-context request))))
         (response
           (cl-agent.client:chain-next
            (cl-agent.client:make-advisor-chain (list tool-advisor validation)
                                                terminal)
            (cl-agent.client:make-client-request
             (cl-agent.chat:make-prompt
              "给出城市"
              :options (cl-agent.chat:make-chat-options
                        :tool-callbacks (cl-agent.chat:resolve-tool-callbacks
                                         '(so-get-city))))))))
    ;; 恰好两次：工具轮 + 最终轮。若校验器错误地对工具轮重试，次数会更多
    (is (= 2 calls))
    (is (string= "{\"city\":\"东京\"}"
                 (cl-agent.chat:chat-response-text
                  (cl-agent.client:client-response-chat-response response))))))
