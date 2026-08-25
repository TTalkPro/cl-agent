;;;; test-chat-client-skeleton.lisp
;;;; CL-Agent - ChatClient 骨架测试

(in-package :cl-agent/tests)

(def-suite chat-client-suite :in cl-agent-suite
  :description "ChatClient CLOS 类 + build-chat-client + 载体")

(in-suite chat-client-suite)

;;; ============================================================
;;; ChatClient 构造
;;; ============================================================

(test build-chat-client-basic
  "build-chat-client 基本参数 → 各 reader 返回正确值"
  (let* ((dummy-model (list :fake-model))
         (f1 (cl-agent/core:make-filter :f1 :chat (lambda (req chain) (funcall chain req))))
         (k (cl-agent/core:build-chat-client
             :model dummy-model
             :tools '(get-weather save-note)
             :filters (list f1))))
    (is (eq dummy-model (cl-agent/core:chat-client-model k)))
    (is (equal '(get-weather save-note) (cl-agent/core:chat-client-tools k)))
    (is (= 1 (length (cl-agent/core:chat-client-filters k))))
    (is (eq :f1 (cl-agent/core:filter-name (first (cl-agent/core:chat-client-filters k)))))))

(test build-chat-client-defaults
  "build-chat-client 缺省值：filters 为空列表，eligibility-fn 为 constantly t，
循环上限 10"
  (let ((k (cl-agent/core:build-chat-client :model (list :fake))))
    (is (null (cl-agent/core:chat-client-tools k)))
    (is (null (cl-agent/core:chat-client-filters k)))
    (is (= 10 (cl-agent/core:chat-client-max-tool-iterations k)))
    (is (funcall (cl-agent/core:chat-client-eligibility-fn k) nil nil)
        "默认 eligibility-fn 总是返回 t")))

(test chat-client-has-four-slots
  "ChatClient 收窄到四个槽：model / filters / default-request / tool-calling。

收窄前是 12 个平级槽（含一个 settings alist）。工具循环那七项搬进
tool-calling-config（对标 ToolCallingAdvisor），system/options/tools
三项搬进 chat-client-default-request（对标 DefaultChatClientRequestSpec）。"
  (let ((slots (mapcar #'closer-mop:slot-definition-name
                       (closer-mop:class-slots
                        (find-class 'cl-agent/core:chat-client)))))
    (is (= 4 (length slots)) "槽数应为 4，实际 ~A：~A" (length slots) slots)
    (dolist (name '(model filters default-request tool-calling))
      (is (member name slots :test #'string=) "缺少槽 ~A" name))))

(test chat-client-aggregates-are-real-objects
  "default-request / tool-calling 是值对象，不是 plist/alist"
  (let ((k (cl-agent/core:build-chat-client
            :model (list :fake)
            :system "你是助手"
            :tools '(get-weather)
            :max-tool-iterations 5)))
    (is (typep (cl-agent/core:chat-client-default-request k)
               'cl-agent/core:chat-client-default-request))
    (is (typep (cl-agent/core:chat-client-tool-calling k)
               'cl-agent/core:tool-calling-config))
    ;; 便捷访问器穿过聚合读到叶子
    (is (string= "你是助手" (cl-agent/core:chat-client-default-system k)))
    (is (equal '(get-weather) (cl-agent/core:chat-client-tools k)))
    (is (= 5 (cl-agent/core:chat-client-max-tool-iterations k)))))

(test chat-client-mutate-shares-untouched-slots
  "mutate 只换指定槽，其余原样共享（对标 ChatClient#mutate）"
  (let* ((k (cl-agent/core:build-chat-client
             :model (list :fake) :system "原提示" :max-tool-iterations 7))
         (k2 (cl-agent/core:chat-client-mutate
              k :filters (list (cl-agent/core:make-filter :f)))))
    (is (= 1 (length (cl-agent/core:chat-client-filters k2))))
    ;; default-request / tool-calling 是同一个对象，不是拷贝
    (is (eq (cl-agent/core:chat-client-default-request k)
            (cl-agent/core:chat-client-default-request k2)))
    (is (= 7 (cl-agent/core:chat-client-max-tool-iterations k2)))
    ;; 原 chat-client 不受影响
    (is (null (cl-agent/core:chat-client-filters k)))))

(test tool-calling-config-mutate-preserves-rest
  "tool-calling-config-mutate 只换指定字段；config 为 NIL 时以全缺省为基底"
  (let* ((config (cl-agent/core:make-tool-calling-config
                  :max-iterations 3
                  :tool-manager :fake-manager))
         (mutated (cl-agent/core:tool-calling-config-mutate
                   config :tool-gate (lambda (tc) (declare (ignore tc)) :proceed))))
    (is (= 3 (cl-agent/core:tool-calling-max-iterations mutated)))
    (is (eq :fake-manager (cl-agent/core:tool-calling-tool-manager mutated)))
    (is (functionp (cl-agent/core:tool-calling-tool-gate mutated)))
    (is (null (cl-agent/core:tool-calling-tool-gate config)) "原 config 不受影响"))
  ;; NIL 基底
  (let ((mutated (cl-agent/core:tool-calling-config-mutate nil :max-iterations 20)))
    (is (= 20 (cl-agent/core:tool-calling-max-iterations mutated)))
    (is (funcall (cl-agent/core:tool-calling-eligibility-fn mutated) nil nil))))

(test build-chat-client-custom-eligibility
  "build-chat-client 自定义 eligibility-fn"
  (let ((k (cl-agent/core:build-chat-client
            :model (list :fake)
            :eligibility-fn (lambda (resp ctx)
                               (declare (ignore resp))
                               (getf ctx :has-budget)))))
    (is (funcall (cl-agent/core:chat-client-eligibility-fn k) nil '(:has-budget t)))
    (is (not (funcall (cl-agent/core:chat-client-eligibility-fn k) nil '(:has-budget nil))))))

(test build-chat-client-max-tool-iterations
  "循环上限是具名参数，settings alist 已移除。

旧读法是 (cdr (assoc :max-tool-iterations settings))——键名拼错就静默
回落到 10，这正是改成具名槽的理由。留一层「仍然接受」的兼容壳等于把那个
读法留在原地，所以传 :settings 直接报错并给出迁移写法。"
  (is (= 5 (cl-agent/core:chat-client-max-tool-iterations
            (cl-agent/core:build-chat-client :model (list :fake)
                                             :max-tool-iterations 5))))
  (is (= 10 (cl-agent/core:chat-client-max-tool-iterations
             (cl-agent/core:build-chat-client :model (list :fake))))
      "缺省 10")
  ;; 旧写法：报错而非静默接受
  (signals error
    (cl-agent/core:build-chat-client
     :model (list :fake)
     :settings '((:max-tool-iterations . 3) (:timeout . 30))))
  (signals error
    (cl-agent/client:make-agent :model (list :fake)
                                :settings '((:max-tool-iterations . 3)))))

;;; ============================================================
;;; ChatClient 无 memory 字段
;;; ============================================================

(test chat-client-has-no-memory-slot
  "chat-client 类无 memory 相关 slot——memory 是 filter，不是 chat-client 属性"
  (let ((slot-names (mapcar (lambda (s) (symbol-name (closer-mop:slot-definition-name s)))
                            (closer-mop:class-slots (find-class 'cl-agent/core:chat-client)))))
    (is (not (member "MEMORY" slot-names :test #'string=))
        "chat-client 无 memory slot——memory 是 filter 不是 chat-client 属性")
    ;; 收窄后的四个槽也不该悄悄长回来（槽清单的断言在
    ;; CHAT-CLIENT-HAS-FOUR-SLOTS）
    (is (not (member "TOOLS" slot-names :test #'string=))
        "tools 归 default-request，不该是 chat-client 的平级槽")
    (is (not (member "SETTINGS" slot-names :test #'string=))
        "settings alist 已退役——循环上限是 tool-calling-config 的具名槽")))

;;; ============================================================
;;; 载体类
;;; ============================================================

(test tool-request-carriers
  "tool-request / tool-result 构造与读取"
  (let ((req (cl-agent/core:make-tool-request
              'get-weather :args '(:city "北京") :context '(:user-id 1))))
    (is (eq 'get-weather (cl-agent/core:tool-request-function req)))
    (is (equal '(:city "北京") (cl-agent/core:tool-request-args req)))
    (is (equal '(:user-id 1) (cl-agent/core:tool-request-context req))))
  ;; writes 是 **plist**（:key value ...），不是 alist——apply-writes 按
  ;; (loop for (k v) on writes by #'cddr) 遍历。这里曾写 '((:counter . 1))：
  ;; 一个长度为 1 的 alist，折叠时会被误解读成键 (:counter . 1) 值 NIL。
  ;; 测试只断言「存进去等于取出来」、从不真的折叠它，所以一直没暴露；
  ;; tool-result 的不变式（长度必须为偶数）把它当场抓了出来。
  (let ((resp (cl-agent/core:make-tool-result
               :value "22°C" :writes '(:counter 1) :error nil)))
    (is (equal "22°C" (cl-agent/core:tool-result-value resp)))
    (is (equal '(:counter 1) (cl-agent/core:tool-result-writes resp)))
    (is (null (cl-agent/core:tool-result-error resp)))
    ;; 而且它真的能折叠——这才是 writes 的用途
    (is (= 1 (getf (cl-agent/core:apply-writes
                    nil (list (cl-agent/core:tool-result-writes resp)))
                   :counter)))))

(test chat-client-request-response-carriers
  "chat-client-request / chat-client-response 构造与读取"
  ;; 载体持有的是 prompt，不是裸 messages——传字符串/列表由
  ;; make-chat-client-request 自动包装（与 chat-model-call 的入参约定一致）
  (let ((req (cl-agent/core:make-chat-client-request
              (list "msg1" "msg2") :context '(:conv-id "c1") :resume-p t)))
    (is (typep (cl-agent/core:chat-client-request-prompt req)
               'cl-agent/core:prompt))
    (is (equal '("msg1" "msg2")
               (mapcar #'cl-agent/core:message-text
                       (cl-agent/core:chat-client-request-messages req))))
    (is (equal '(:conv-id "c1") (cl-agent/core:chat-client-request-context req)))
    (is (eq t (cl-agent/core:chat-client-request-resume-p req))))
  ;; 请求级 options 是 prompt 的一部分，不再走 context 暗管道
  (let* ((options (cl-agent/core:make-chat-options :temperature 0.5))
         (req (cl-agent/core:make-chat-client-request
               (cl-agent/core:make-prompt "hi" :options options))))
    (is (eq options (cl-agent/core:chat-client-request-options req))))
  (let ((result (cl-agent/core:make-chat-client-response
                 :completed
                 :chat-response (cl-agent/core:make-chat-response
                                 (cl-agent/core:make-generation
                                  (cl-agent/core:assistant-message "answer")
                                  :finish-reason :stop))
                 :tool-calls-made 3)))
    (is (eq :completed (cl-agent/core:chat-client-response-status result)))
    (is (string= "answer" (cl-agent/core:chat-client-response-text result)))
    (is (= 3 (cl-agent/core:chat-client-response-tool-calls-made result)))))

(test chat-client-request-mutate-preserves-untouched-fields
  "mutate 只换指定字段，其余原样保留——filter 改写请求的正道。

手写重建很容易漏字段：旧代码里 rag filter 重建时只传了 :context，
把 resume-p 丢成 nil（当时靠分支条件恰好绕开）。"
  (let* ((options (cl-agent/core:make-chat-options :temperature 0.7))
         (req (cl-agent/core:make-chat-client-request
               (cl-agent/core:make-prompt "原问题" :options options)
               :context '(:conv-id "c1")
               :resume-p t))
         (mutated (cl-agent/core:chat-client-request-mutate
                   req :messages (list (cl-agent/core:user-message "改写后")))))
    ;; 换了 messages
    (is (equal '("改写后")
               (mapcar #'cl-agent/core:message-text
                       (cl-agent/core:chat-client-request-messages mutated))))
    ;; options / context / resume-p 全部保留
    (is (eq options (cl-agent/core:chat-client-request-options mutated)))
    (is (equal '(:conv-id "c1") (cl-agent/core:chat-client-request-context mutated)))
    (is (eq t (cl-agent/core:chat-client-request-resume-p mutated)))
    ;; 原请求不受影响
    (is (equal '("原问题")
               (mapcar #'cl-agent/core:message-text
                       (cl-agent/core:chat-client-request-messages req))))))

;;; ============================================================
;;; 不变式（initialize-instance :after）
;;; ============================================================
;;; 这些性质此前只是构造函数的礼貌——绕过 make-* 直接 make-instance
;;; 就没有保障。挂在 initialize-instance 上之后，无论从哪条路造出来都成立。

(test filter-name-is-always-non-nil
  "没给 :name 的 filter 自动取类名 downcase——不再返回 NIL。

此前 filter-name-default 是个要调用方记得问的函数，(filter-name f)
对没给名字的实例返回 NIL，日志里就是一个空名字。"
  ;; make-filter 路径
  (is (string= "filter" (cl-agent/core:filter-name
                         (cl-agent/core:make-filter nil))))
  ;; 裸 make-instance 路径——不变式同样成立
  (is (string= "filter" (cl-agent/core:filter-name
                         (make-instance 'cl-agent/core:filter))))
  ;; 显式给名字时不被覆盖
  (is (eq :mine (cl-agent/core:filter-name
                 (cl-agent/core:make-filter :mine)))))

(test paused-response-must-carry-loop-state
  ":paused 却不带 loop-state → 构造时就报错，而不是等到 resume 才炸。

自定义 loop-fn 最容易踩：产出了 :paused 却忘了装快照，调用方拿到一个
「暂停了但无法续跑」的响应，错误现场离出错点很远。"
  (signals error
    (cl-agent/core:make-chat-client-response :paused))
  ;; 带上 loop-state 就正常
  (let ((response (cl-agent/core:make-chat-client-response
                   :paused
                   :loop-state (cl-agent/core:make-loop-state :iteration 2))))
    (is (eq :paused (cl-agent/core:chat-client-response-status response)))
    (is (= 2 (cl-agent/core:loop-state-iteration
              (cl-agent/core:chat-client-response-loop-state response)))))
  ;; 其余状态不受这条约束
  (is (eq :completed (cl-agent/core:chat-client-response-status
                      (cl-agent/core:make-chat-client-response :completed)))))

(test tool-execution-result-is-a-class-not-a-plist
  "批执行结果是类，拼错的访问器当场就断——而不是 getf 静默返回 NIL。

:return-direct 拼错时 getf 返回 NIL，而 NIL 恰好是「不短路」这个合法值：
错误不报，只表现为「approve 一个 return-direct 工具后又多调一次模型」。"
  (let ((result (cl-agent/core:make-tool-execution-result
                 :messages nil :context '(:k 1) :return-direct t)))
    (is (typep result 'cl-agent/core:tool-execution-result))
    (is (not (listp result)) "不再是 plist")
    (is (eq t (cl-agent/core:tool-execution-return-direct-p result)))
    (is (equal '(:k 1) (cl-agent/core:tool-execution-context result)))))

(test tool-error-info-rejects-unknown-class
  "故障分类必须是 :semantic / :transient / :environment 之一。

它是**故障路由的判据**——只有 :transient 且工具声明了 :retry 才重试。
错误此前是裸 plist：拼错键名静默变 NIL，编造一个分类（测试里真的有过
:timeout）也无人过问，表现出来只是「声明了 :retry 的工具没重试」。"
  (signals error (cl-agent/core:make-tool-error-info :class :timeout))
  (signals error (cl-agent/core:make-tool-error-info :class :retryable))
  (dolist (class '(:semantic :transient :environment))
    (is (eq class (cl-agent/core:tool-error-class
                   (cl-agent/core:make-tool-error-info :class class)))))
  ;; 缺省保守：不重试
  (is (eq :semantic (cl-agent/core:tool-error-class
                     (cl-agent/core:make-tool-error-info :message "x"))))
  ;; cause 保留原 condition，分类丢失细节时的兜底线索
  (let ((c (make-condition 'simple-error :format-control "boom")))
    (is (eq c (cl-agent/core:tool-error-cause
               (cl-agent/core:make-tool-error-info :class :transient :cause c))))))

(test state-slot-declares-merge-semantics
  "状态槽是类，不是 alist 套 plist。

旧写法 (key :init v0 :reduce fn) 靠 (rest (assoc key slots)) + getf 现场
解读：`:reduce` 拼成 `:reducer` 就退化成 last-writer——不报错，只是
「累加」悄悄变成了「覆盖」。"
  (let ((slot (cl-agent/core:make-state-slot :notes :init nil :reduce-fn #'append)))
    (is (eq :notes (cl-agent/core:state-slot-key slot)))
    (is (functionp (cl-agent/core:state-slot-reduce-fn slot)))
    (is (null (cl-agent/core:state-slot-init slot))))
  ;; 没有 reducer = last-writer，合法
  (is (null (cl-agent/core:state-slot-reduce-fn
             (cl-agent/core:make-state-slot :x))))
  ;; 键必须是 keyword，reducer 必须可调用
  (signals error (cl-agent/core:make-state-slot "notes"))
  (signals error (cl-agent/core:make-state-slot :notes :reduce-fn 42))
  ;; find-state-slot 按键查找
  (let ((slots (list (cl-agent/core:make-state-slot :a)
                     (cl-agent/core:make-state-slot :b :reduce-fn #'+))))
    (is (eq :b (cl-agent/core:state-slot-key
                (cl-agent/core:find-state-slot slots :b))))
    (is (null (cl-agent/core:find-state-slot slots :zzz)))))

(test resume-payload-normalizes-plist-at-entry
  "续跑载荷是类；resume-turn 仍接受 plist，入口处归一一次。

plist 是 resume-turn 最自然的调用写法，所以入口保留；内部只面对实例，
不再各处 getf。"
  (let ((payload (cl-agent/core:coerce-resume-payload '(:message "答复" :args (:a 1)))))
    (is (typep payload 'cl-agent/core:resume-payload))
    (is (string= "答复" (cl-agent/core:resume-payload-message payload)))
    (is (equal '(:a 1) (cl-agent/core:resume-payload-args payload))))
  ;; 实例原样透传
  (let ((payload (cl-agent/core:make-resume-payload :message "x")))
    (is (eq payload (cl-agent/core:coerce-resume-payload payload))))
  ;; NIL → 空载荷，不是 NIL
  (let ((payload (cl-agent/core:coerce-resume-payload nil)))
    (is (typep payload 'cl-agent/core:resume-payload))
    (is (null (cl-agent/core:resume-payload-message payload)))))

(test default-request-can-be-passed-as-an-aggregate
  "default-request / tool-calling 可以整体传入，覆盖对应的扁平参数。

用途：把一套「请求默认形状」在多个 chat-client 之间复用。"
  (let* ((request (cl-agent/core:make-chat-client-default-request
                   :system "共用提示" :tools '(get-weather)))
         (k (cl-agent/core:build-chat-client :model (list :fake)
                                             :default-request request)))
    (is (eq request (cl-agent/core:chat-client-default-request k)))
    ;; 聚合自身的访问器
    (is (string= "共用提示" (cl-agent/core:default-request-system request)))
    (is (equal '(get-weather) (cl-agent/core:default-request-tools request)))
    (is (null (cl-agent/core:default-request-options request)))
    ;; chat-client 上的便捷访问器读到同一份
    (is (string= "共用提示" (cl-agent/core:chat-client-default-system k)))
    (is (equal '(get-weather) (cl-agent/core:chat-client-tools k))))
  ;; 聚合优先于扁平参数
  (let ((k (cl-agent/core:build-chat-client
            :model (list :fake)
            :system "会被忽略"
            :default-request (cl-agent/core:make-chat-client-default-request
                              :system "胜出"))))
    (is (string= "胜出" (cl-agent/core:chat-client-default-system k))))
  ;; 同理 tool-calling
  (let ((k (cl-agent/core:build-chat-client
            :model (list :fake)
            :max-tool-iterations 99
            :tool-calling (cl-agent/core:make-tool-calling-config :max-iterations 7))))
    (is (= 7 (cl-agent/core:chat-client-max-tool-iterations k)))))
