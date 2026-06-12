;;;; live-minimax-verify.lisp
;;;; CL-Agent - MiniMax 真实 API 三层验证
;;;;
;;;; 验证范围（使用环境变量 MINIMAX_AUTH_TOKEN）：
;;;;   A. LLM Provider 层：openai-compat 基座、llm-response 归一化、
;;;;      <think> 推理块剥离、usage 别名（含 cached_tokens）、错误分类
;;;;   B. Kernel 层：invoke-chat（:chat 洋葱链 + chat-request 改写）、
;;;;      run-tool-loop 完整工具循环（simpleagent，:tool 链 filter 触发）
;;;;   C. Agent 层：KernelAgent + ChatMemory 多轮记忆 + callback 事件流
;;;;
;;;; 运行：
;;;;   sbcl --load tests/live-minimax-verify.lisp

(in-package :cl-user)

(defvar *pass* 0)
(defvar *fail* 0)

(defmacro check (label form)
  `(handler-case
       (if ,form
           (progn (incf *pass*) (format t "  [PASS] ~A~%" ,label))
           (progn (incf *fail*) (format t "  [FAIL] ~A~%" ,label)))
     (error (e)
       (incf *fail*)
       (format t "  [FAIL] ~A — 异常: ~A~%" ,label e))))

(format t "~%============================================~%")
(format t "  MiniMax 真实 API 三层验证~%")
(format t "============================================~%")

;;; ============================================================
;;; A. Provider 层
;;; ============================================================

(format t "~%--- A. LLM Provider 层 ---~%")

(defvar *provider* (cl-agent.llm:make-provider :minimax))

(check "A1. provider 创建（env MINIMAX_AUTH_TOKEN）"
       (not (null *provider*)))
(check "A2. provider 是 openai-compat 子类"
       (typep *provider* 'cl-agent.llm.providers:openai-compat-provider))
(check "A3. provider-name = :minimax"
       (eq :minimax (cl-agent.core:provider-name *provider*)))

(format t "  ... 调用 llm-chat（真实 API）~%")
(defvar *resp*
  (cl-agent.kernel:llm-chat *provider*
                            (list (list :role :user
                                        :content "请用一句话介绍 Common Lisp。"))
                            :max-tokens 2048))

(check "A4. llm-chat 返回 llm-response 对象"
       (cl-agent.core:llm-response-p *resp*))
(check "A5. content 非空"
       (plusp (length (cl-agent.core:llm-response-content *resp*))))
(check "A6. <think> 推理块已从 content 剥离"
       (not (search "<think>" (cl-agent.core:llm-response-content *resp*))))
(check "A7. 推理内容提取到 reasoning 槽"
       (let ((r (cl-agent.core:llm-response-reasoning *resp*)))
         (and r (plusp (length r)))))
(check "A8. finish-reason 归一化为 :stop"
       (eq :stop (cl-agent.core:llm-response-finish-reason *resp*)))
(check "A9. usage 归一化（input/output tokens > 0）"
       (let ((u (cl-agent.core:llm-response-usage *resp*)))
         (and u
              (plusp (cl-agent.core:llm-usage-input-tokens u))
              (plusp (cl-agent.core:llm-usage-output-tokens u)))))
(check "A10. model 字段回填"
       (search "MiniMax" (cl-agent.core:llm-response-model *resp*)))

(format t "  响应: ~A~%"
        (let ((c (cl-agent.core:llm-response-content *resp*)))
          (subseq c 0 (min 80 (length c)))))
(format t "  usage: ~A | cache-read: ~A~%"
        (cl-agent.core:llm-response-usage *resp*)
        (cl-agent.core:llm-usage-cache-read-tokens
         (cl-agent.core:llm-response-usage *resp*)))

;; 错误分类：坏 token → 鉴权错误 → 不可重试
(format t "  ... 验证错误分类（故意使用无效 token）~%")
(check "A11. 无效 token 报 llm-error 且 error-retryable-p = NIL"
       (handler-case
           (progn (cl-agent.kernel:llm-chat
                   (cl-agent.llm:make-provider :minimax :api-key "invalid-token-xyz")
                   (list (list :role :user :content "hi"))
                   :max-tokens 16)
                  nil)   ; 不该成功
         (cl-agent.core:llm-error (e)
           (not (cl-agent.core:error-retryable-p e)))))

;;; ============================================================
;;; B. Kernel 层
;;; ============================================================

(format t "~%--- B. Kernel 层 ---~%")

;; B1: invoke-chat 经过 :chat 洋葱链，filter 改写 chat-request
(defvar *chat-filter-hits* 0)
(defvar *kernel-plain*
  (cl-agent.kernel:make-kernel
   :service *provider*
   :filters (list (cl-agent.kernel:make-filter
                   :type :chat :name "marker"
                   :before (lambda (req)
                             (incf *chat-filter-hits*)
                             ;; 改写请求：注入系统提示
                             (setf (cl-agent.kernel:chat-request-messages req)
                                   (cons (list :role :system
                                               :content "无论用户问什么，你的回答必须以「收到」两个字开头。")
                                         (cl-agent.kernel:chat-request-messages req)))
                             req)))))

(format t "  ... invoke-chat（真实 API）~%")
(defvar *chat-resp*
  (cl-agent.kernel:invoke-chat *kernel-plain*
                               (list (list :role :user :content "你好"))
                               :settings '(:max-tokens 2048)))

(check "B1. invoke-chat 返回 llm-response"
       (cl-agent.core:llm-response-p *chat-resp*))
(check "B2. :chat 链 filter 被触发"
       (plusp *chat-filter-hits*))
(check "B3. filter 改写的 system 提示生效（回答以「收到」开头）"
       (let ((c (cl-agent.core:llm-response-content *chat-resp*)))
         (search "收到" c :end2 (min 10 (length c)))))

;; B4-B7: invoke-kernel 完整工具循环
(defvar *tool-called* nil)
(defvar *tool-filter-hits* 0)

(defvar *kernel-tools*
  (let ((k (cl-agent.kernel:make-kernel
            :service *provider*
            :filters (list (cl-agent.kernel:make-filter
                            :type :tool :name "tool-counter"
                            :around (lambda (req chain)
                                      (incf *tool-filter-hits*)
                                      (funcall chain req)))))))
    (cl-agent.kernel:kernel-register-tool
     k (cl-agent.kernel:make-tool
        :name :get_weather
        :description "查询指定城市的当前天气"
        :handler (lambda (&key city)
                   (setf *tool-called* city)
                   (format nil "~A：晴，气温 23 摄氏度" city))
        :parameters '((city :type :string :required t
                            :description "城市名称"))))
    k))

(format t "  ... invoke-kernel 工具循环（真实 API，约 2 次往返）~%")
(defvar *loop-result*
  (cl-agent.simpleagent:run-tool-loop
   *kernel-tools*
   (list (list :role :user
               :content "请调用 get_weather 工具查询北京的天气，然后告诉我结果。"))
   :settings '(:max-tokens 4096)))

(check "B4. 模型发起了工具调用（handler 被执行）"
       (and *tool-called* (search "北京" *tool-called*)))
(check "B5. tool-calls-made 记录了调用"
       (= 1 (length (getf *loop-result* :tool-calls-made))))
(check "B6. :tool 链 filter 被触发"
       (plusp *tool-filter-hits*))
(check "B7. 最终回答包含工具结果信息（23 摄氏度）"
       (search "23" (getf *loop-result* :text)))

(format t "  最终回答: ~A~%"
        (let ((c (getf *loop-result* :text)))
          (subseq c 0 (min 100 (length c)))))

;;; ============================================================
;;; C. Agent 层
;;; ============================================================

(format t "~%--- C. Agent 层（KernelAgent + ChatMemory + Callbacks）---~%")

(defvar *events* nil)
(defvar *store* (cl-agent.kernel:make-in-memory-chat-store))

(defvar *agent*
  ;; 直接传 provider —— make-kernel-agent 自动包装 Kernel（创建时可指定/替换）
  (cl-agent.simpleagent:make-kernel-agent
   *provider*
   :name "minimax-agent"
   :system-prompt "你是一个简洁的助手，回答尽量简短。"
   :settings '(:max-tokens 2048)
   :memory *store*
   :conversation-id "live-conv"))

(cl-agent.simpleagent:agent-on-message
 *agent* (lambda (msg) (declare (ignore msg)) (push :message *events*)))
(cl-agent.simpleagent:agent-on-response
 *agent* (lambda (text) (declare (ignore text)) (push :response *events*)))

(format t "  ... 第一轮对话（真实 API）~%")
(defvar *turn1* (cl-agent.simpleagent:agent-chat *agent* "你好，我的名字叫小明，请记住。"))

(check "C1. 第一轮返回非空回答"
       (and (stringp *turn1*) (plusp (length *turn1*))))
(check "C2. callback 事件触发（:on-message + :on-response）"
       (and (member :message *events*) (member :response *events*)))

(format t "  ... 第二轮对话（验证 ChatMemory 跨轮记忆）~%")
(defvar *turn2* (cl-agent.simpleagent:agent-chat *agent* "我叫什么名字？"))

(check "C3. 第二轮回答包含「小明」（memory-filter 注入了历史）"
       (search "小明" *turn2*))
(check "C4. store 中按序存有完整对话（4 条消息）"
       (equal '(:user :assistant :user :assistant)
              (mapcar (lambda (m) (getf m :role))
                      (cl-agent.kernel:mem-get *store* "live-conv"))))
(check "C5. agent-get-history 读取 store 历史"
       (= 4 (length (cl-agent.simpleagent:agent-get-history *agent*))))
(check "C6. memory-filter 是 Agent 私有的（kernel filters 零污染）"
       (and (null (cl-agent.kernel:kernel-filters
                   (cl-agent.simpleagent:agent-kernel *agent*)))
            (not (null (cl-agent.simpleagent:agent-memory-filter *agent*)))))
(check "C7. provider 直接创建 Agent（ensure-kernel 自动包装）"
       (typep (cl-agent.simpleagent:agent-kernel *agent*)
              'cl-agent.kernel:kernel))

(format t "  第二轮回答: ~A~%"
        (subseq *turn2* 0 (min 80 (length *turn2*))))

;;; ============================================================
;;; 汇总
;;; ============================================================

(format t "~%============================================~%")
(format t "  结果: ~A 通过 / ~A 失败~%" *pass* *fail*)
(format t "============================================~%")
(uiop:quit (if (zerop *fail*) 0 1))
