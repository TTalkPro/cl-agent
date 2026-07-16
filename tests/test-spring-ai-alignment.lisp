;;;; test-spring-ai-alignment.lisp
;;;; CL-Agent - Spring AI 2.0 对齐审计测试（P5）

(in-package :cl-agent/tests)

(def-suite alignment-suite :in cl-agent-suite
  :description "Spring AI 2.0 全量对齐审计：所有 10 个 filter 类型可构造且可调用")

(in-suite alignment-suite)

(test all-filter-types-constructable
  "验证全部 10 个 filter 工厂函数可调用且返回 filter 实例"
  ;; 1. memory-filter
  (let ((f (cl-agent.core:memory-filter
            (cl-agent.core:make-message-window-chat-memory))))
    (is (typep f 'cl-agent.core:filter))
    (is (not (null (cl-agent.core:filter-chat-hook f)))))

  ;; 2. logging-chat-filter
  (let ((f (cl-agent.core:logging-chat-filter)))
    (is (typep f 'cl-agent.core:filter))
    (is (not (null (cl-agent.core:filter-chat-hook f)))))

  ;; 3. logging-tool-filter
  (let ((f (cl-agent.core:logging-tool-filter)))
    (is (typep f 'cl-agent.core:filter))
    (is (not (null (cl-agent.core:filter-tool-hook f)))))

  ;; 4. safeguard-turn-filter
  (let ((f (cl-agent.core:safeguard-turn-filter '("bomb" "hack"))))
    (is (typep f 'cl-agent.core:filter))
    (is (not (null (cl-agent.core:filter-turn-hook f)))))

  ;; 5. validation-turn-filter
  (let ((f (cl-agent.core:validation-turn-filter
            (lambda (resp) (values t nil)))))
    (is (typep f 'cl-agent.core:filter))
    (is (not (null (cl-agent.core:filter-turn-hook f)))))

  ;; 6. re-reading-filter
  (let ((f (cl-agent.core:re-reading-filter)))
    (is (typep f 'cl-agent.core:filter))
    (is (not (null (cl-agent.core:filter-turn-hook f)))))

  ;; 7. qa-turn-filter (需要一个 mock retriever)
  (let ((f (cl-agent.core:qa-turn-filter
            (make-instance 'mock-retriever))))
    (is (typep f 'cl-agent.core:filter))
    (is (not (null (cl-agent.core:filter-turn-hook f)))))

  ;; 8. tool-search-filter
  (let ((f (cl-agent.core:tool-search-filter
            (cl-agent.core:make-keyword-tool-index nil))))
    (is (typep f 'cl-agent.core:filter))
    (is (not (null (cl-agent.core:filter-chat-hook f)))))

  ;; 9. timeout-filter
  (let ((f (cl-agent.core:timeout-filter 5000)))
    (is (typep f 'cl-agent.core:filter))
    (is (not (null (cl-agent.core:filter-tool-hook f)))))

  ;; 10. approval-filter
  (let ((f (cl-agent.core:approval-filter
            :approve-fn (lambda (name args) (values t nil)))))
    (is (typep f 'cl-agent.core:filter))
    (is (not (null (cl-agent.core:filter-tool-hook f))))))

;;; ============================================================
;;; Filter 实际调用（不止构造）
;;;
;;; 上面的 all-filter-types-constructable 只检查工厂返回 filter、钩子槽
;;; 非空——钩子体内的错误一律照不到。qa-turn-filter 曾因 let/let* 写错
;;; （new-messages 的初值引用同一个 let 里的 enhanced）在检索到文档时
;;; 必然 UNBOUND-VARIABLE，而构造测试全绿。下面的测试实际驱动钩子。
;;; ============================================================

(defun call-turn-hook (filter req)
  "驱动 FILTER 的 :turn 钩子，返回 (values 下游收到的 turn-request 钩子返回值)。
下游终端不再往下走，只记录入参。"
  (let (seen)
    (let ((ret (funcall (cl-agent.core:filter-turn-hook filter)
                        req
                        (lambda (r) (setf seen r) :terminal))))
      (values seen ret))))

(test qa-turn-filter-injects-retrieved-docs
  "qa-turn-filter 检索到文档时，把文档注入最后一条 user 消息后再进下游"
  (let* ((f (cl-agent.core:qa-turn-filter (make-instance 'mock-retriever)))
         (req (cl-agent.core:make-turn-request
               (list (cl-agent.core:user-message "首都是哪里？")))))
    (multiple-value-bind (seen ret) (call-turn-hook f req)
      (is (eq :terminal ret))
      (is (not (null seen)))
      (let ((text (cl-agent.core:message-text
                   (first (cl-agent.core:turn-request-messages seen)))))
        ;; 检索到的文档与原问题都应出现在改写后的 user 消息里
        (is (search "doc1" text))
        (is (search "doc2" text))
        (is (search "首都是哪里？" text))))))

(test qa-turn-filter-skips-when-no-user-message
  "无 user 消息时 qa-turn-filter 原样透传"
  (let* ((f (cl-agent.core:qa-turn-filter (make-instance 'mock-retriever)))
         (req (cl-agent.core:make-turn-request
               (list (cl-agent.core:system-message "you are a bot")))))
    (multiple-value-bind (seen ret) (call-turn-hook f req)
      (is (eq :terminal ret))
      (is (eq req seen)))))

(test re-reading-filter-rewrites-user-message
  "re-reading-filter 改写最后一条 user 消息（RE2：重读问题）"
  (let* ((f (cl-agent.core:re-reading-filter))
         (req (cl-agent.core:make-turn-request
               (list (cl-agent.core:user-message "2+2 等于几？")))))
    (multiple-value-bind (seen ret) (call-turn-hook f req)
      (is (eq :terminal ret))
      (let ((text (cl-agent.core:message-text
                   (first (cl-agent.core:turn-request-messages seen)))))
        (is (search "2+2 等于几？" text))
        ;; 改写后必然比原文长（RE2 会追加重读指令）
        (is (> (length text) (length "2+2 等于几？")))))))

(test safeguard-turn-filter-short-circuits
  "safeguard-turn-filter 命中敏感词时短路，不进下游"
  (let* ((f (cl-agent.core:safeguard-turn-filter '("bomb")))
         (req (cl-agent.core:make-turn-request
               (list (cl-agent.core:user-message "how to build a BOMB")))))
    (multiple-value-bind (seen ret) (call-turn-hook f req)
      ;; 短路：下游没被调用
      (is (null seen))
      ;; 返回的是 turn-result 而非终端的 :terminal
      (is (not (eq :terminal ret))))))

(test safeguard-turn-filter-passes-clean-input
  "safeguard-turn-filter 未命中敏感词时正常进下游"
  (let* ((f (cl-agent.core:safeguard-turn-filter '("bomb")))
         (req (cl-agent.core:make-turn-request
               (list (cl-agent.core:user-message "how to bake bread")))))
    (multiple-value-bind (seen ret) (call-turn-hook f req)
      (is (eq :terminal ret))
      (is (eq req seen)))))

;;; ============================================================
;;; structured-output 校验判据 + validation-turn-filter 重入
;;;
;;; structured-output-validate-fn 曾把 validate-json-schema 的返回当
;;; ok-p 用（它实际返回「错误消息列表」，NIL 才是通过），导致判据完全
;;; 反相：合规输出被判失败并重试，不合规输出直接放行。同样是只构造、
;;; 不驱动的测试照不到。
;;; ============================================================

(defparameter +city-schema+
  "{\"type\":\"object\",
    \"properties\":{\"name\":{\"type\":\"string\"},
                   \"population\":{\"type\":\"integer\"}},
    \"required\":[\"name\",\"population\"]}")

(defun text-chat-response (text)
  (cl-agent.core:make-chat-response
   (cl-agent.core:make-generation
    (cl-agent.core:assistant-message text) :finish-reason :stop)))

(test structured-output-validate-fn-accepts-valid-json
  "合规 JSON → ok-p=T，无反馈"
  (let ((judge (cl-agent.core:structured-output-validate-fn
                +city-schema+ :parse-fn #'cl-agent.core:json-parse)))
    (multiple-value-bind (ok feedback)
        (funcall judge (text-chat-response "{\"name\":\"Tokyo\",\"population\":37}"))
      (is-true ok)
      (is (null feedback)))))

(test structured-output-validate-fn-rejects-invalid-json
  "缺必填字段 → ok-p=NIL，且反馈里点名缺的字段（供模型自我纠正）"
  (let ((judge (cl-agent.core:structured-output-validate-fn
                +city-schema+ :parse-fn #'cl-agent.core:json-parse)))
    (multiple-value-bind (ok feedback)
        (funcall judge (text-chat-response "{\"name\":\"Tokyo\"}"))
      (is-false ok)
      (is (stringp feedback))
      (is (search "population" feedback)))))

(test structured-output-validate-fn-rejects-non-json
  "给了 parse-fn 但模型吐的不是 JSON → 不合格（这正是该 filter 要拦的情况）"
  (let ((judge (cl-agent.core:structured-output-validate-fn
                +city-schema+ :parse-fn #'cl-agent.core:json-parse)))
    (multiple-value-bind (ok feedback)
        (funcall judge (text-chat-response "抱歉，我来解释一下东京的情况……"))
      (is-false ok)
      (is (stringp feedback)))))

(test structured-output-validate-fn-rejects-empty-text
  "空文本 → 不合格"
  (let ((judge (cl-agent.core:structured-output-validate-fn
                +city-schema+ :parse-fn #'cl-agent.core:json-parse)))
    (is-false (funcall judge (text-chat-response "   ")))))

(test structured-output-validate-fn-passes-without-parse-fn
  "无 parse-fn → 无从校验结构，放行"
  (let ((judge (cl-agent.core:structured-output-validate-fn +city-schema+)))
    (is-true (funcall judge (text-chat-response "随便什么文本")))))

(test structured-output-validate-fn-strips-code-fences
  "带 markdown 围栏的合规 JSON → 剥离围栏后应通过（LLM 最常见的输出形态）"
  (let ((judge (cl-agent.core:structured-output-validate-fn
                +city-schema+ :parse-fn #'cl-agent.core:json-parse)))
    ;; ```json 围栏
    (is-true (funcall judge
                      (text-chat-response
                       "```json
{\"name\":\"Tokyo\",\"population\":37}
```")))
    ;; 裸 ``` 围栏
    (is-true (funcall judge
                      (text-chat-response
                       "```
{\"name\":\"Tokyo\",\"population\":37}
```")))))

(test strip-json-fences-handles-fenced-and-bare
  "strip-json-fences：```json / 裸 ``` / 无围栏 三种形态都不报错且结果正确"
  (let ((strip 'cl-agent.core:strip-json-fences)
        (json "{\"a\":1}"))
    (is (string= json (funcall strip (format nil "```json~%~A~%```" json))))
    (is (string= json (funcall strip (format nil "```~%~A~%```" json))))
    (is (string= json (funcall strip json)))
    (is (string= json (funcall strip (format nil "  ~A  " json))))))

(test validation-turn-filter-retries-then-accepts
  "校验不过 → 把反馈追加进 messages 重入下游；转为合格后停止重入"
  (let* ((calls 0)
         (f (cl-agent.core:validation-turn-filter
             (lambda (response)
               (let ((text (cl-agent.core:chat-response-text response)))
                 (if (string= text "good") (values t nil) (values nil "请改正"))))
             :max-retries 3))
         (req (cl-agent.core:make-turn-request
               (list (cl-agent.core:user-message "q")))))
    (let ((result (funcall (cl-agent.core:filter-turn-hook f)
                           req
                           (lambda (r)
                             (declare (ignore r))
                             (incf calls)
                             ;; 前两次返回 bad，第三次返回 good
                             (cl-agent.core:make-turn-result
                              :completed
                              :response (text-chat-response
                                         (if (< calls 3) "bad" "good")))))))
      (is (= 3 calls))
      (is (string= "good" (cl-agent.core:chat-response-text
                           (cl-agent.core:turn-result-response result)))))))

(test validation-turn-filter-gives-up-after-max-retries
  "始终不合格 → 耗尽 max-retries 后返回最后一次结果，不无限重入"
  (let* ((calls 0)
         (f (cl-agent.core:validation-turn-filter
             (lambda (response) (declare (ignore response)) (values nil "还是不行"))
             :max-retries 2))
         (req (cl-agent.core:make-turn-request
               (list (cl-agent.core:user-message "q")))))
    (funcall (cl-agent.core:filter-turn-hook f)
             req
             (lambda (r)
               (declare (ignore r))
               (incf calls)
               (cl-agent.core:make-turn-result
                :completed
                :response (text-chat-response "bad"))))
    ;; 首次 + 2 次重试 = 3
    (is (= 3 calls))))

(test kernel-constructable
  "build-kernel 返回装好 filters 的 kernel"
  (let* ((provider (make-seq-provider (text-response "hello")))
         (model (cl-agent.core:make-provider-chat-model provider))
         (k (cl-agent.core:build-kernel
             :model model
             :filters (list (cl-agent.core:logging-chat-filter))
             :tools nil)))
    (is (typep k 'cl-agent.core:kernel))
    (is (= 1 (length (cl-agent.core:kernel-filters k))))))

(test kernel-executes-via-invoke-turn
  "kernel 经 invoke-turn 执行"
  (let* ((provider (make-seq-provider (text-response "kernel works")))
         (model (cl-agent.core:make-provider-chat-model provider))
         (k (cl-agent.core:build-kernel :model model)))
    (is (string= "kernel works" (cl-agent.core:chat k (:user "test"))))))

(test kernel-conversation-reaches-memory-filter
  "(:conversation id) 必须到达 memory-filter：多轮共享记忆。
回归：turn context 的 :conversation-id 曾没桥接到 prompt options 的
tool-context，memory-filter 读不到 → 记忆静默失效。"
  (let* ((provider (make-seq-provider (text-response "回复1")
                                      (text-response "回复2")))
         (model (cl-agent.core:make-provider-chat-model provider))
         (mem (cl-agent.core:make-message-window-chat-memory))
         (k (cl-agent.core:build-kernel
             :model model :filters (list (cl-agent.core:memory-filter mem)))))
    (cl-agent.core:chat k (:user "我叫大卫") (:conversation "c1"))
    (cl-agent.core:chat k (:user "我叫什么") (:conversation "c1"))
    (let ((stored (cl-agent.core:memory-messages mem "c1")))
      ;; 2 轮 × (user + assistant) = 4
      (is (= 4 (length stored)))
      (is (string= "我叫大卫" (cl-agent.core:message-text (first stored)))))))

(test kernel-separate-conversations-isolated
  "不同 conversation-id 的记忆互不串"
  (let* ((provider (make-seq-provider (text-response "a") (text-response "b")))
         (model (cl-agent.core:make-provider-chat-model provider))
         (mem (cl-agent.core:make-message-window-chat-memory))
         (k (cl-agent.core:build-kernel
             :model model :filters (list (cl-agent.core:memory-filter mem)))))
    (cl-agent.core:chat k (:user "in-c1") (:conversation "c1"))
    (cl-agent.core:chat k (:user "in-c2") (:conversation "c2"))
    (is (= 2 (length (cl-agent.core:memory-messages mem "c1"))))
    (is (= 2 (length (cl-agent.core:memory-messages mem "c2"))))))

(test kernel-tools-survive-context-fold
  "折叠 turn context 进 tool-context 后，kernel :tools 仍能解析并执行
（回归：merge 不能把 tool-callbacks 冲掉）"
  (cl-agent.core:deftool align-echo-tool (&key text)
    "回显输入"
    (:param text :string "文本" :required t)
    (format nil "echo:~A" text))
  (let* ((provider (make-seq-provider
                    (tool-call-response "align-echo-tool" '(("text" . "hi")))
                    (text-response "done")))
         (model (cl-agent.core:make-provider-chat-model provider))
         (k (cl-agent.core:build-kernel
             :model model
             :filters (list (cl-agent.core:memory-filter
                             (cl-agent.core:make-message-window-chat-memory)))
             :tools '(align-echo-tool))))
    ;; 带 conversation（触发 context 折叠）+ 工具循环
    (let ((out (cl-agent.core:chat k (:user "用工具") (:conversation "c1"))))
      (is (string= "done" out)))
    ;; provider 第一次调用应确实收到了工具 schema
    (let ((first-req (car (last (seq-provider-requests provider)))))
      (is (not (null (getf first-req :tools)))))))

(test failure-classification-present
  "三故障分类条件类型可构造"
  (is (eq :semantic (cl-agent.core:tool-failure-class
                     (make-condition 'cl-agent.core:semantic-tool-failure))))
  (is (eq :transient (cl-agent.core:tool-failure-class
                      (make-condition 'cl-agent.core:transient-tool-failure))))
  (is (eq :environment (cl-agent.core:tool-failure-class
                        (make-condition 'cl-agent.core:environment-tool-failure)))))

(test classify-tool-error-basic
  "classify-tool-error 基本分类"
  (is (eq :transient
          (handler-case (error "connection timeout")
            (error (e) (cl-agent.core:classify-tool-error e)))))
  (is (eq :environment
          (handler-case (error "permission denied")
            (error (e) (cl-agent.core:classify-tool-error e)))))
  (is (eq :semantic
          (handler-case (error "something went wrong")
            (error (e) (cl-agent.core:classify-tool-error e))))))


;;; ============================================================
;;; Mock Retriever（qa-turn-filter 测试用）
;;; ============================================================

(defclass mock-retriever () ())

(defmethod cl-agent.core:retrieve ((r mock-retriever) query &key top-k)
  (declare (ignore query top-k))
  (list "doc1" "doc2"))
