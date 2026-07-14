;;;; test-tool.lisp
;;;; CL-Agent - 工具体系测试（deftool / ToolCallback / ToolCallingManager）

(in-package :cl-agent/tests)

(def-suite tool-suite :in cl-agent-suite
  :description "deftool 宏、ToolCallback 与 ToolCallingManager")

(in-suite tool-suite)

;;; ============================================================
;;; 测试工具定义（deftool 宏展开发生在编译期）
;;; ============================================================

(cl-agent.chat:deftool test-adder (&key a b)
  "把两个数相加"
  (:param a :number "第一个数" :required t)
  (:param b :number "第二个数" :required t)
  (+ a b))

(cl-agent.chat:deftool test-direct-tool (&key text)
  "直接返回结果的工具"
  (:param text :string "文本")
  (:return-direct t)
  (format nil "直接结果：~A" text))

(cl-agent.chat:deftool test-context-tool (&key city tool-context)
  "使用宿主注入上下文的工具"
  (:param city :string "城市" :required t)
  (:param tool-context :object "宿主注入")
  (format nil "~A/~A" city (getf tool-context :tenant)))

;;; ============================================================
;;; deftool 宏
;;; ============================================================

(test deftool-defines-function
  "deftool 同时定义普通函数"
  (is (= 5 (test-adder :a 2 :b 3))))

(test deftool-registers-callback
  "deftool 注册到全局注册表（名称转下划线风格）"
  (let ((callback (cl-agent.chat:find-tool-callback "test_adder")))
    (is-true callback)
    (is (string= "test_adder" (cl-agent.chat:tool-callback-name callback)))
    ;; 符号属性也可取回
    (is (eq callback (get 'test-adder 'cl-agent.chat::tool-callback)))))

(test deftool-description-and-params
  "docstring 与 :param 子句进入 tool-definition"
  (let* ((callback (cl-agent.chat:find-tool-callback 'test-adder))
         (def (cl-agent.chat:tool-callback-definition callback)))
    (is (string= "把两个数相加" (cl-agent.chat:tool-definition-description def)))
    (is (= 2 (length (cl-agent.chat:tool-definition-parameters def))))))

(test deftool-schema
  "自动派生 provider schema"
  (let ((schema (cl-agent.chat:tool-callback->schema
                 (cl-agent.chat:find-tool-callback 'test-adder))))
    (is (string= "test_adder" (getf schema :name)))
    (let ((params (getf schema :parameters)))
      (is (equal '("a" "b") (getf params :required))))))

(test deftool-rejects-positional-args
  "非 &key 的 lambda-list 在宏展开期报错"
  (signals error
    (macroexpand-1 '(cl-agent.chat:deftool bad-tool (x y)
                     "位置参数不允许"
                     (+ x y)))))

;;; ============================================================
;;; ToolCallback
;;; ============================================================

(test make-tool-callback-runtime
  "运行时构造 tool-callback（对标 FunctionToolCallback）"
  (let ((callback (cl-agent.chat:make-tool-callback
                   (lambda (&key name) (format nil "你好，~A" name))
                   :name "greet"
                   :description "打招呼"
                   :parameters '((name :string "姓名" :required-p t)))))
    (is (string= "你好，大卫"
                 (cl-agent.chat:tool-callback-call callback '(:name "大卫"))))))

(test tool-callback-non-string-result
  "非字符串结果自动 format"
  (let ((callback (cl-agent.chat:make-tool-callback
                   (lambda (&key) 42) :name "answer")))
    (is (string= "42" (cl-agent.chat:tool-callback-call callback nil)))))

(test tool-callback-error-wrapped
  "工具内部错误包装为 tool-execution-error"
  (let ((callback (cl-agent.chat:make-tool-callback
                   (lambda (&key) (error "内部炸了")) :name "bomb")))
    (signals cl-agent.chat:tool-execution-error
      (cl-agent.chat:tool-callback-call callback nil))))

(test resolve-tool-callbacks
  "解析工具引用：实例 / 符号 / 字符串"
  (let* ((inline-cb (cl-agent.chat:make-tool-callback
                     (lambda (&key) "x") :name "inline"))
         (resolved (cl-agent.chat:resolve-tool-callbacks
                    (list inline-cb 'test-adder "test_adder"))))
    (is (= 3 (length resolved)))
    (is (eq inline-cb (first resolved))))
  (signals cl-agent.chat:tool-not-found-error
    (cl-agent.chat:resolve-tool-callbacks '("no_such_tool"))))

;;; ============================================================
;;; 参数归一化
;;; ============================================================

(test arguments-normalization
  "hash-table / JSON 字符串 / plist 统一归一化为关键字 plist"
  (let ((ht (make-hash-table :test #'equal)))
    (setf (gethash "user_name" ht) "david")
    (is (equal '(:user-name "david") (cl-agent.chat:arguments->plist ht))))
  (is (equal '(:city "东京")
             (cl-agent.chat:arguments->plist "{\"city\": \"东京\"}")))
  (is (equal '(:a 1) (cl-agent.chat:arguments->plist '(:a 1))))
  (is (null (cl-agent.chat:arguments->plist nil)))
  (is (null (cl-agent.chat:arguments->plist "不是 JSON"))))

;;; ============================================================
;;; ToolCallingManager
;;; ============================================================

(defclass rethrow-tool-manager (cl-agent.chat:default-tool-calling-manager)
  ()
  (:documentation "测试用：工具错误直接冒泡而非转文本"))

(defmethod cl-agent.chat:process-tool-execution-error
    ((manager rethrow-tool-manager) condition tool-call)
  (declare (ignore tool-call))
  (error condition))

(defun response-with-calls (&rest name-args-pairs)
  "构造携带多个 tool-call 的 chat-response"
  (cl-agent.chat:make-chat-response
   (cl-agent.chat:make-generation
    (cl-agent.chat:assistant-message
     ""
     :tool-calls (loop for (name args id) in name-args-pairs
                       collect (cl-agent.chat:make-tool-call
                                :id id :name name :arguments args)))
    :finish-reason :tool-call)))

(defun result-first-tool-text (result)
  "取 tool-execution-result 末尾工具消息的首条结果文本"
  (cl-agent.chat:tool-response-text
   (first (cl-agent.chat:tool-responses
           (cl-agent.chat:tool-execution-last-message result)))))

(test manager-executes-calls
  "Manager 执行工具并返回 tool-execution-result（含完整会话历史）"
  (let* ((manager (cl-agent.chat:make-default-tool-calling-manager))
         (prompt (cl-agent.chat:make-prompt "算一下"
                                            :options (cl-agent.chat:make-chat-options)))
         (response (response-with-calls
                    (list "test_adder" '(:a 1 :b 2) "id-1")))
         (result (cl-agent.chat:execute-tool-calls manager prompt response)))
    (is (typep result 'cl-agent.chat:tool-execution-result))
    (is-false (cl-agent.chat:tool-execution-return-direct-p result))
    (is (string= "3" (result-first-tool-text result)))
    ;; 会话历史 = 原 prompt 消息 + assistant(tool-calls) + tool 消息
    (let ((history (cl-agent.chat:tool-execution-conversation-history result)))
      (is (= 3 (length history)))
      (is (equal '(:user :assistant :tool)
                 (mapcar #'cl-agent.chat:message-role history))))))

(test manager-return-direct
  ":return-direct 工具触发直接返回标记"
  (let* ((manager (cl-agent.chat:make-default-tool-calling-manager))
         (prompt (cl-agent.chat:make-prompt "test"))
         (response (response-with-calls
                    (list "test_direct_tool" '(:text "hi") "id-1")))
         (result (cl-agent.chat:execute-tool-calls manager prompt response)))
    (is-true (cl-agent.chat:tool-execution-return-direct-p result))
    (is (string= "直接结果：hi" (result-first-tool-text result)))))

(test manager-tool-context-injection
  "tool-context 只注入给声明了它的工具"
  (let* ((manager (cl-agent.chat:make-default-tool-calling-manager))
         (prompt (cl-agent.chat:make-prompt
                  "test"
                  :options (cl-agent.chat:make-chat-options
                            :tool-context '(:tenant "acme"))))
         (response (response-with-calls
                    (list "test_context_tool" '(:city "东京") "id-1")))
         (result (cl-agent.chat:execute-tool-calls manager prompt response)))
    (is (string= "东京/acme" (result-first-tool-text result)))))

(test manager-unknown-tool-error-as-result
  "未知工具不抛错，错误文本作为结果回传（模型可自纠错）"
  (let* ((manager (cl-agent.chat:make-default-tool-calling-manager))
         (prompt (cl-agent.chat:make-prompt "test"))
         (response (response-with-calls
                    (list "ghost_tool" nil "id-1")))
         (result (cl-agent.chat:execute-tool-calls manager prompt response)))
    (is (search "错误" (result-first-tool-text result)))))

(test manager-tool-error-as-result
  "工具执行报错时错误文本作为结果回传"
  (let* ((manager (cl-agent.chat:make-default-tool-calling-manager))
         (bomb (cl-agent.chat:make-tool-callback
                (lambda (&key) (error "爆炸")) :name "bomb_tool"))
         (prompt (cl-agent.chat:make-prompt
                  "test"
                  :options (cl-agent.chat:make-chat-options
                            :tool-callbacks (list bomb))))
         (response (response-with-calls (list "bomb_tool" nil "id-1")))
         (result (cl-agent.chat:execute-tool-calls manager prompt response)))
    (is (search "错误" (result-first-tool-text result)))))

(test manager-custom-error-processor
  "process-tool-execution-error 可定制（对标 ToolExecutionExceptionProcessor）"
  (let* ((manager (make-instance 'rethrow-tool-manager))
         (prompt (cl-agent.chat:make-prompt "test"))
         (response (response-with-calls (list "ghost_tool" nil "id-1"))))
    (signals cl-agent.chat:tool-not-found-error
      (cl-agent.chat:execute-tool-calls manager prompt response))))
