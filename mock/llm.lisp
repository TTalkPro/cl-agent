;;;; llm.lisp
;;;; CL-Agent - Mock LLM 实现
;;;;
;;;; 概述：
;;;;   提供模拟的 LLM 实现，用于测试和演示
;;;;
;;;; 特性：
;;;;   - 无需 API 密钥
;;;;   - 即时响应，无网络延迟
;;;;   - 可预测的输出
;;;;   - 支持工具调用模拟

(in-package :cl-agent.mock)

;;; ============================================================
;;; Mock LLM 提供商
;;; ============================================================

(defclass mock-llm-provider ()
  ((response-delay :initarg :response-delay
                   :initform 0
                   :accessor mock-response-delay
                   :documentation "模拟响应延迟（秒）")
   (error-rate :initarg :error-rate
               :initform 0
               :accessor mock-error-rate
               :documentation "模拟错误率（0.0-1.0）")
   (responses :initarg :responses
              :initform (make-hash-table :test #'equal)
              :accessor mock-responses
              :documentation "预定义的响应映射"))
  (:documentation "Mock LLM 提供商

用于测试和演示，无需真实的 API 调用"))

;;; ============================================================
;;; 工厂函数
;;; ============================================================

(defun make-mock-llm (&key (response-delay 0) (error-rate 0) (responses (make-hash-table :test #'equal)))
  "创建 Mock LLM 提供商

参数：
  RESPONSE-DELAY - 响应延迟（秒），默认 0
  ERROR-RATE     - 错误率（0.0-1.0），默认 0
  RESPONSES      - 预定义响应（hash-table），键为提示词，值为响应

返回：
  Mock LLM 提供商实例

示例：
  (make-mock-llm :response-delay 0.5
                 :responses '((\"你好\" . \"你好！有什么可以帮助你的吗？\")))

  ;; 快速创建
  (make-mock-llm)"
  (make-instance 'mock-llm-provider
                 :response-delay response-delay
                 :error-rate error-rate
                 :responses responses))

;;; ============================================================
;;; LLM 协议实现
;;; ============================================================

(defmethod llm-chat ((provider mock-llm-provider) messages &key max-tokens temperature (model nil) (tools nil) system)
  "发送聊天请求到 Mock LLM"
  (declare (ignore max-tokens temperature model tools system))

  ;; 模拟延迟
  (let ((delay (mock-response-delay provider)))
    (when (> delay 0)
      (sleep delay)))

  ;; 模拟错误
  (when (> (mock-error-rate provider) 0)
    (when (< (random 1.0) (mock-error-rate provider))
      (return-from llm-chat
        (list :success nil
              :error "Mock LLM API error"))))

  ;; 获取最后一条用户消息
  (let* ((last-user-msg (loop for msg in (reverse messages)
                              when (eq (getf msg :role) :user)
                              return msg))
         (prompt (getf last-user-msg :content))
         (responses (mock-responses provider))
         (response (gethash prompt responses)))

    (if response
        ;; 返回预定义的响应
        (if (consp response)
            response
            (list :content response
                  :usage (list :prompt-tokens (length prompt)
                              :completion-tokens (length response)
                              :total-tokens (+ (length prompt)
                                               (length response)))))
        ;; 生成智能默认响应
        (generate-mock-response prompt messages tools))))

(defmethod llm-available-p ((provider mock-llm-provider))
  "Mock LLM 总是可用"
  (declare (ignore provider))
  t)

(defmethod llm-provider-name ((provider mock-llm-provider))
  "获取提供商名称"
  (declare (ignore provider))
  :mock)

(defmethod llm-default-model ((provider mock-llm-provider))
  "获取默认模型"
  (declare (ignore provider))
  "mock-model-v1")

;;; ============================================================
;;; 智能响应生成
;;; ============================================================

(defun generate-mock-response (prompt messages tools)
  "生成智能的 mock 响应

参数：
  PROMPT   - 用户提示词
  MESSAGES - 完整消息历史
  TOOLS    - 可用工具列表

返回：
  响应 plist"

  (let ((lower-prompt (string-downcase prompt)))

    (cond
      ;; 工具调用场景
      ((and tools
            (or (cl-ppcre:scan "计算|calculate|compute|\\d+\\s*[+\\-*/]\\s*\\d+" lower-prompt)
                (cl-ppcre:scan "搜索|search|查找|find" lower-prompt)
                (cl-ppcre:scan "文件|file|读取|read" lower-prompt)))
       (generate-tool-call-response prompt tools))

      ;; 问答场景
      ((cl-ppcre:scan "你是|what are you|介绍|introduce" lower-prompt)
       (list :content "我是 Mock LLM，用于测试和演示。我不会调用真实的 API，但可以模拟各种交互场景。"
             :usage (list :prompt-tokens 10 :completion-tokens 30 :total-tokens 40)))

      ;; 代码生成场景
      ((cl-ppcre:scan "代码|code|函数|function|实现|implement" lower-prompt)
       (list :content (format nil "~%// Mock 代码实现~%(defun mock-function ()~%  \"这是一个 mock 函数\"~%  (return \"mock result\"))~%"
                               (generate-mock-code-snippet prompt))
             :usage (list :prompt-tokens 20 :completion-tokens 50 :total-tokens 70)))

      ;; 笑话场景
      ((cl-ppcre:scan "笑话|joke|幽默|humor" lower-prompt)
       (list :content (generate-joke-response)
             :usage (list :prompt-tokens 10 :completion-tokens 40 :total-tokens 50)))

      ;; 总结场景
      ((cl-ppcre:scan "总结|summary|摘要|abstract" lower-prompt)
       (list :content (format nil "总结：~%~A~%~%这是一个基于输入内容生成的 mock 总结。"
                               (truncate-string prompt 50))
             :usage (list :prompt-tokens 15 :completion-tokens 30 :total-tokens 45)))

      ;; 默认响应
      (t
       (list :content (format nil "Mock LLM 响应：~%~A~%~%(这是模拟的响应，用于测试和演示)"
                               (truncate-string prompt 100))
             :usage (list :prompt-tokens (length prompt)
                          :completion-tokens 20
                          :total-tokens (+ (length prompt) 20)))))))

(defun generate-tool-call-response (prompt tools)
  "生成模拟的工具调用响应

参数：
  PROMPT - 用户提示词
  TOOLS  - 可用工具列表

返回：
  响应 plist，包含工具调用"

  ;; 尝试匹配工具
  (let* ((lower-prompt (string-downcase prompt))
         (tool-name (cond
                     ((cl-ppcre:scan "计算|calculate|math" lower-prompt) :calculator)
                     ((cl-ppcre:scan "搜索|search|find|lookup" lower-prompt) :search)
                     ((cl-ppcre:scan "文件|file|read|write" lower-prompt) :file-ops)
                     ((and tools (listp tools))
                      (getf (first tools) :name))
                     (t :generic-tool))))

    (list :content (format nil "我将调用 ~A 工具来处理你的请求。"
                          tool-name)
          :tool-calls (list
                       (list :id (format nil "call_~A" (generate-random-id))
                             :name tool-name
                             :arguments "{\"input\": \"test\"}"))
          :usage (list :prompt-tokens 20
                      :completion-tokens 10
                      :total-tokens 30))))

(defun generate-tool-arguments (tool-name prompt)
  "根据工具名称生成模拟参数

参数：
  TOOL-NAME - 工具名称
  PROMPT    - 用户提示词

返回：
  参数 alist"

  (case tool-name
    (:calculator
     ;; 尝试从提示词中提取数学表达式
     (let ((expr (extract-math-expression prompt)))
       (list :expression (or expr "1 + 1"))))
    (:search
     (list :query (or (extract-search-query prompt) "test query")))
    (:file-ops
     (list :path (or (extract-file-path prompt) "/tmp/file.txt")))
    (t
     (list :input prompt))))

;;; ============================================================
;;; 辅助函数
;;; ============================================================

(defun generate-mock-code-snippet (prompt)
  "生成 mock 代码片段"

  (cond
    ((cl-ppcre:scan "clojure|lisp" (string-downcase prompt))
     "(defn hello [name] (str \"Hello, \" name \"!\"))")
    ((cl-ppcre:scan "python" (string-downcase prompt))
     "def hello(name): return f\"Hello, {name}!\"")
    ((cl-ppcre:scan "javascript|js" (string-downcase prompt))
     "function hello(name) { return `Hello, ${name}!`; }")
    (t
     "// Generic code example\nfunction mock() { return true; }")))

(defun generate-joke-response ()
  "生成 mock 笑话"

  (let ((jokes
          '("为什么程序员总是混淆圣诞节和万圣节？因为 Oct 31 = Dec 25！"
            "一个 SQL 语句走进一家酒吧，走到两张桌子中间说：'我可以 join 你们吗？'"
            "程序员的三大谎言：1. 这只是个小修改 2. 马上就好 3. 兼容所有浏览器"
            "为什么 Java 程序员要戴眼镜？因为他们看不清 C#"
            "真正的程序员认为硬件是会硬化的软件")))

    (nth (random (length jokes)) jokes)))

(defun generate-random-id ()
  "生成随机 ID"
  (format nil "~36R" (get-universal-time)))

(defun truncate-string (str max-len)
  "截断字符串到指定长度"
  (if (> (length str) max-len)
      (subseq str 0 max-len)
      str))

(defun extract-math-expression (prompt)
  "尝试从提示词中提取数学表达式"
  (let ((match (cl-ppcre:scan-to-strings "\\d+\\s*[+\\-*/]\\s*\\d+" prompt)))
    (when match
      (aref match 0))))

(defun extract-search-query (prompt)
  "尝试从提示词中提取搜索查询"
  (let ((match (cl-ppcre:scan-to-strings "(?:搜索|search|查找|find)\\s*[：:：]?\\s*(.+)" prompt)))
    (when match
      (aref match 0))))

(defun extract-file-path (prompt)
  "尝试从提示词中提取文件路径"
  (let ((match (cl-ppcre:scan-to-strings "[/\\][\\w\\./-]+" prompt)))
    (when match
      (aref match 0))))

;;; ============================================================
;;; 预定义场景响应
;;; ============================================================

(defun create-predefined-mock ()
  "创建带有预定义响应的 Mock LLM

返回：
  Mock LLM 实例，包含常见的测试场景响应"

  (let* ((responses (make-hash-table :test #'equal))
         (provider (make-mock-llm :responses responses)))

    ;; 添加预定义响应
    (setf (gethash "你好" responses)
          (list :content "你好！有什么可以帮助你的吗？"))

    (setf (gethash "1+1等于几" responses)
          (list :content "1+1=2"
                :tool-calls (list (list :id "call_calc"
                                        :name :calculator
                                        :arguments "{\\\"expression\\\": \\\"1+1\\\"}"))))

    (setf (gethash "写一个递归函数" responses)
          (list :content "这是一个简单的递归函数示例：

```clojure
(defn factorial [n]
  (if (<= n 1)
    1
    (* n (factorial (dec n)))))
```

这个函数计算 n 的阶乘。"))

    provider))

;;; ============================================================
;;; 导出便捷函数
;;; ============================================================

(defun make-quick-mock (&optional (response-style :smart))
  "快速创建 Mock LLM

参数：
  RESPONSE-STYLE - 响应风格
                   :smart  - 智能响应（根据提示词内容）
                   :echo   - 回显提示词
                   :fixed  - 固定响应

返回：
  Mock LLM 实例

示例：
  (make-quick-mock :smart)
  (make-quick-mock :echo)"

  (ecase response-style
    (:smart (make-mock-llm))
    (:echo (make-mock-llm
            :responses (make-hash-table :test #'equal)))
    (:fixed (let ((responses (make-hash-table :test #'equal)))
              (setf (gethash "" responses)
                    (list :content "Fixed response"))
              (make-mock-llm :responses responses)))))
