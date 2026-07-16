;;;; test-tool.lisp
;;;; CL-Agent - 工具体系测试（deftool / ToolCallback / 工具解析与暴露边界）

(in-package :cl-agent/tests)

(def-suite tool-suite :in cl-agent-suite
  :description "deftool 宏、ToolCallback、按名解析与工具暴露边界")

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

(test deftool-has-no-global-side-effect
  "deftool 不写全局注册表——工具的身份是它的符号。

自动全局注册会让每个 deftool 悄悄扩大攻击面（模型报出名字即可执行
从未暴露的工具），也让测试相互污染。对齐 clj-agent：deftool 生成
defn + var 元数据，工具由 (build-kernel {:tools [#'foo]}) 显式传入。"
  (let ((callback (cl-agent.chat:symbol-tool-callback 'test-adder)))
    (is-true callback)
    (is (string= "test_adder" (cl-agent.chat:tool-callback-name callback)))
    ;; 未显式注册 → 全局表里查不到
    (is (null (cl-agent.chat:find-tool-callback "test_adder")))))

(test register-tool-callback-is-opt-in
  "显式 register-tool-callback 后，字符串名才可解析（配置驱动场景）"
  (let ((cb (cl-agent.chat:symbol-tool-callback 'test-adder)))
    (is (null (cl-agent.chat:find-tool-callback "test_adder")))
    (unwind-protect
         (progn
           (cl-agent.chat:register-tool-callback cb)
           (is (eq cb (cl-agent.chat:find-tool-callback "test_adder")))
           (is (equal (list cb) (cl-agent.chat:resolve-tool-callbacks
                                 '("test_adder")))))
      (cl-agent.chat:unregister-tool-callback "test_adder"))
    (is (null (cl-agent.chat:find-tool-callback "test_adder")))))

(test deftool-description-and-params
  "docstring 与 :param 子句进入 tool-definition"
  (let* ((callback (cl-agent.chat:symbol-tool-callback 'test-adder))
         (def (cl-agent.chat:tool-callback-definition callback)))
    (is (string= "把两个数相加" (cl-agent.chat:tool-definition-description def)))
    (is (= 2 (length (cl-agent.chat:tool-definition-parameters def))))))

(test deftool-schema
  "自动派生 provider schema"
  (let ((schema (cl-agent.chat:tool-callback->schema
                 (cl-agent.chat:symbol-tool-callback 'test-adder))))
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
  "解析工具引用：实例 / 符号（deftool 的默认路径）"
  (let* ((inline-cb (cl-agent.chat:make-tool-callback
                     (lambda (&key) "x") :name "inline"))
         (resolved (cl-agent.chat:resolve-tool-callbacks
                    (list inline-cb 'test-adder))))
    (is (= 2 (length resolved)))
    (is (eq inline-cb (first resolved)))
    (is (string= "test_adder" (cl-agent.chat:tool-callback-name (second resolved)))))
  (signals cl-agent.chat:tool-not-found-error
    (cl-agent.chat:resolve-tool-callbacks '("no_such_tool")))
  ;; 字符串引用需先显式注册——deftool 不再自动进全局表
  (signals cl-agent.chat:tool-not-found-error
    (cl-agent.chat:resolve-tool-callbacks '("test_adder"))))

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
;;; 工具解析：find-callback-for-call
;;; ============================================================
;;;
;;; ToolCallingManager 的测试已随该层删除——工具执行循环现在唯一住在
;;; cl-agent.kernel（覆盖见 test-kernel-invoke / test-kernel-chat）。
;;; 本层只剩「工具是什么」：定义、注册、schema、按名解析。

(defun opts-exposing (&rest tool-syms)
  "构造只暴露指定工具的 chat-options"
  (cl-agent.chat:make-chat-options
   :tool-callbacks (cl-agent.chat:resolve-tool-callbacks tool-syms)))

(test find-callback-for-call-resolves-exposed
  "本次请求暴露了的工具，按名解析得到"
  (let* ((options (opts-exposing 'test-adder))
         (tc (cl-agent.chat:make-tool-call :id "1" :name "test_adder"
                                           :arguments '(:a 1 :b 2)))
         (cb (cl-agent.chat:find-callback-for-call options tc)))
    (is (string= "test_adder" (cl-agent.chat:tool-callback-name cb)))))

(test find-callback-for-call-rejects-unexposed
  "未暴露的工具名 → tool-not-found-error（不回退全局注册表）"
  (let ((options (opts-exposing 'test-adder))
        (tc (cl-agent.chat:make-tool-call :id "1" :name "test_context_tool"
                                          :arguments '(:city "x"))))
    (signals cl-agent.chat:tool-not-found-error
      (cl-agent.chat:find-callback-for-call options tc))))

;;; ============================================================
;;; 工具暴露边界（越权回归）
;;; ============================================================

(defvar *secret-tool-fired* nil)

(cl-agent.chat:deftool secret-tool (&key target)
  "危险操作——本测试中从不暴露给模型"
  (:param target :string "目标" :required t)
  (setf *secret-tool-fired* target)
  "已执行")

(test unexposed-tool-is-never-executed
  "模型报出一个未暴露的工具名时不得被执行——即便它已被显式注册到全局表。

工具执行只认本次请求 options 里的工具。此前 find-callback-for-call 会
回退查全局注册表，而 deftool 自动注册，于是任何 deftool 过的工具，
模型只要报出名字就会被执行（提示注入下可直接利用的越权）。

参照实现同样没有回退：clj-agent 的 find-function 只查 kernel 的
:tool-vars 并抛异常；Spring 的 ToolCallbackResolver 默认为空。

本测试走完整 kernel 链路（旧版经已删除的 ToolCallingManager）：
模型第一轮报出 secret_tool，第二轮给最终文本。"
  (let ((cb (cl-agent.chat:symbol-tool-callback 'secret-tool)))
    (unwind-protect
         (progn
           ;; 最坏情况：即使它进了全局表，也不该被执行
           (cl-agent.chat:register-tool-callback cb)
           (setf *secret-tool-fired* nil)
           (let* ((provider (make-seq-provider
                             (tool-call-response "secret_tool" '(("target" . "alice")))
                             (text-response "done")))
                  (model (cl-agent.chat:make-provider-chat-model provider))
                  ;; kernel 只暴露 test-adder
                  (k (cl-agent.kernel:build-kernel :model model
                                                   :tools '(test-adder))))
             (cl-agent.kernel:chat k (:user "hi"))
             (is (null *secret-tool-fired*)
                 "未暴露的工具被执行了：越权回归")))
      (cl-agent.chat:unregister-tool-callback "secret_tool")
      (setf *secret-tool-fired* nil))))

(test unexposed-tool-error-goes-back-to-model
  "未暴露工具的错误转成文本回传模型，对话不中断（而非抛给调用方）"
  (let ((cb (cl-agent.chat:symbol-tool-callback 'secret-tool)))
    (unwind-protect
         (progn
           (cl-agent.chat:register-tool-callback cb)
           (let* ((second-round-messages nil)
                  (provider (make-seq-provider
                             (tool-call-response "secret_tool" '(("target" . "alice")))
                             (lambda (messages)
                               (setf second-round-messages messages)
                               (text-response "done"))))
                  (model (cl-agent.chat:make-provider-chat-model provider))
                  (k (cl-agent.kernel:build-kernel :model model
                                                   :tools '(test-adder))))
             ;; 不报错，正常拿到最终文本
             (is (string= "done" (cl-agent.kernel:chat k (:user "hi"))))
             ;; 第二轮里有一条 tool 消息，内容是错误说明
             (let ((tool-msg (find :tool second-round-messages
                                   :key (lambda (m) (getf m :role)))))
               (is (not (null tool-msg)) "错误应作为 tool 结果回传模型")
               (is (search "工具" (getf tool-msg :content))))))
      (cl-agent.chat:unregister-tool-callback "secret_tool")
      (setf *secret-tool-fired* nil))))

(test exposed-tool-still-executes
  "对照：暴露了的工具正常执行（确认上面的隔离不是把功能整个关掉了）"
  (let* ((provider (make-seq-provider
                    (tool-call-response "test_adder" '(("a" . 2) ("b" . 3)))
                    (text-response "5")))
         (model (cl-agent.chat:make-provider-chat-model provider))
         (k (cl-agent.kernel:build-kernel :model model :tools '(test-adder))))
    (is (string= "5" (cl-agent.kernel:chat k (:user "2+3"))))
    ;; 两轮：一轮要工具，一轮拿结果 → 工具确实执行了
    (is (= 2 (length (seq-provider-requests provider))))))

;;; ============================================================
;;; 跨包引用（符号身份带包作用域）
;;; ============================================================

(defpackage #:cl-agent/tests.tool-pkg
  (:use #:cl)
  (:export #:pkg-weather))

(in-package #:cl-agent/tests.tool-pkg)
(cl-agent.chat:deftool pkg-weather (&key city)
  "另一个包里定义的工具"
  (:param city :string "城市" :required t)
  (format nil "~A：晴" city))
(in-package :cl-agent/tests)

(test cross-package-tool-reference
  "工具的身份是符号，带包作用域——跨包必须用包限定或 :use。

别的包里 'pkg-weather 读出来是本包的符号，与定义处并非同一对象。
这与 clj-agent 同构（跨 ns 需 #'other-ns/foo 或 :require :refer）。"
  ;; 包限定 → 同一符号 → 可解析
  (is (string= "pkg_weather"
               (cl-agent.chat:tool-callback-name
                (first (cl-agent.chat:resolve-tool-callbacks
                        '(cl-agent/tests.tool-pkg:pkg-weather))))))
  ;; 本包同名符号是另一个对象 → 解析失败
  (is (not (eq 'pkg-weather 'cl-agent/tests.tool-pkg:pkg-weather)))
  (signals cl-agent.chat:tool-not-found-error
    (cl-agent.chat:resolve-tool-callbacks '(pkg-weather))))

(test tool-not-found-error-reveals-package
  "报错必须显式带包名——跨包引用是本设计最常见的绊脚点，
而 ~A 会抹掉包前缀、~S 在报错现场恰好是该包时也不显示前缀，
两者都会报出误导性的「找不到工具：PKG-WEATHER」。"
  (let ((message (handler-case
                     (progn (cl-agent.chat:resolve-tool-callbacks '(pkg-weather)) nil)
                   (cl-agent.chat:tool-not-found-error (e) (princ-to-string e)))))
    (is (search "CL-AGENT/TESTS::PKG-WEATHER" message)
        "报错未显示包名，无法定位：~A" message)
    (is (search "包限定" message))))
