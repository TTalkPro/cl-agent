;;;; test-core.lisp
;;;; Lisp in Agents - 核心功能测试

(in-package :cl-agent/tests)

;; 核心 API 测试套件
(def-suite core-suite :in cl-agent-suite
  :description "核心功能测试")

(in-suite core-suite)

;; ============================================================
;; 工具函数测试
;; ============================================================

(test get-env
  "测试环境变量获取"
  (is (stringp (cl-agent/core:get-env "HOME")))
  (is (eq nil (cl-agent/core:get-env "NONEXISTENT_VAR_XYZ")))
  (is (string= "default"
               (cl-agent/core:get-env "NONEXISTENT_VAR" "default"))))

(test generate-uuid
  "测试 UUID 生成"
  (let ((uuid (cl-agent/core:generate-uuid)))
    (is (stringp uuid))
    (is (> (length uuid) 0))
    ;; 每次生成不同的 UUID
    (let ((uuid2 (cl-agent/core:generate-uuid)))
      (is (not (string= uuid uuid2))))))

(test timestamp
  "测试时间戳"
  (let ((ts (cl-agent/core:timestamp-now)))
    (is (integerp ts))
    (is (> ts 0))))

;; ============================================================
;; JSON 操作测试
;; ============================================================

(test json-parse
  "json-parse：JSON 文本 → jzon 表示

值表示（校验器与 provider 层都依赖它，见 core/json-schema.lisp）：
  object → hash-table(equal)   array → vector   true → T
  false → NIL   null → 符号 NULL（注意不是 CL 的 NIL）"
  (let ((h (cl-agent/core:json-parse "{\"a\":1,\"b\":\"s\"}")))
    (is (hash-table-p h))
    (is (= 1 (gethash "a" h)))
    (is (string= "s" (gethash "b" h))))
  ;; 数组 → vector（非 list）
  (let ((v (cl-agent/core:json-parse "[1,2,3]")))
    (is (vectorp v))
    (is (equalp #(1 2 3) v)))
  ;; 三个易混的标量：false 是 NIL，null 是符号 NULL，二者不同
  (is (eq t (cl-agent/core:json-parse "true")))
  (is (eq nil (cl-agent/core:json-parse "false")))
  (is (eq 'null (cl-agent/core:json-parse "null")))
  (is (not (eq (cl-agent/core:json-parse "false")
               (cl-agent/core:json-parse "null"))))
  ;; 非法 JSON 发条件（调用方据此兜底，如 validate-json-text）
  (signals error (cl-agent/core:json-parse "{不是 JSON")))

(test json-stringify
  "json-stringify：Lisp 值 → JSON 文本（往返一致）"
  (let ((h (make-hash-table :test 'equal)))
    (setf (gethash "a" h) 1)
    (is (string= "{\"a\":1}" (cl-agent/core:json-stringify h))))
  ;; 往返：不断言键序——jzon 的 hash-table 遍历顺序随实现而变
  ;; （实测 SBCL 与 CCL 不同），依赖键序的断言不可移植
  (let* ((original "{\"x\":[1,2],\"y\":\"z\"}")
         (round-trip (cl-agent/core:json-parse
                      (cl-agent/core:json-stringify
                       (cl-agent/core:json-parse original)))))
    (is (equalp #(1 2) (gethash "x" round-trip)))
    (is (string= "z" (gethash "y" round-trip)))))

;; ============================================================
;; 条件系统测试
;; ============================================================

;;; 注：此处曾有链式宏（-> / ->> / as->）的测试。宏与全库其余 20 个
;;; 零使用的工具宏已一并删除（见 macros.lisp 头注），测试随之删除。
;;; 附：as-> 曾因缺右括号使 macros.lisp 后 290 行（含日志系统）从未
;;; 生效——这段历史保留在 macros.lisp 的注释里。

(test when-let-macro
  "when-let：非 nil 绑定执行，nil 短路（全库唯一存活的绑定宏）"
  (is (= 6 (cl-agent/core:when-let (x (+ 1 2)) (* x 2))))
  (is (null (cl-agent/core:when-let (x nil) (error "不应执行")))))

(test signal-error
  "测试错误信号"
  (signals cl-agent/core:cl-agent-error
    (cl-agent/core:signal-error 'cl-agent/core:cl-agent-error
                          :message "Test error")))

(test validation-error
  "验证错误条件可携带 :field 并经 signal-error 发出
（signal-validation-error 便捷封装已随零使用清理删除）"
  (signals cl-agent/core:validation-error
    (cl-agent/core:signal-error 'cl-agent/core:validation-error
                                :message "Invalid value"
                                :field "test-field")))

;; ============================================================
;; 运行核心测试
;; ============================================================

(defun run-core-tests ()
  "运行核心测试"
  (run! 'core-suite))

;;; ============================================================
;;; DI :request 作用域
;;; ============================================================

(test di-request-scope
  "同一 with-di-request-scope 内共享实例，跨作用域隔离。

此前 :request 声明了却未实现——落到与 :prototype 相同的分支（每次 resolve
新建实例），与声明的「请求内共享」语义相反，且毫无提示。"
  (let ((n 0)
        (c (cl-agent/core:make-di-container)))
    (cl-agent/core:di-bind c :svc (lambda () (list :i (incf n))) :scope :request)
    ;; 请求内共享
    (cl-agent/core:with-di-request-scope
      (is (eq (cl-agent/core:di-resolve c :svc)
              (cl-agent/core:di-resolve c :svc))))
    ;; 跨请求隔离
    (let ((a (cl-agent/core:with-di-request-scope (cl-agent/core:di-resolve c :svc)))
          (b (cl-agent/core:with-di-request-scope (cl-agent/core:di-resolve c :svc))))
      (is (not (eq a b))))))

(test di-request-scope-errors-when-not-active
  "作用域外解析 :request 服务必须报错，而不是静默退化成 prototype
（对标 Spring 的 ScopeNotActiveException）"
  (let ((c (cl-agent/core:make-di-container)))
    (cl-agent/core:di-bind c :svc (lambda () :x) :scope :request)
    (signals cl-agent/core:di-request-scope-not-active-error
      (cl-agent/core:di-resolve c :svc))))

(test di-request-scope-is-thread-isolated
  "缓存是动态绑定 ⇒ 每个线程在自己的作用域里有自己的实例"
  (let* ((n 0)
         (c (cl-agent/core:make-di-container))
         (results nil)
         (lock (bt:make-lock)))
    (cl-agent/core:di-bind c :svc (lambda () (list :i (incf n))) :scope :request)
    (mapc #'bt:join-thread
          (loop repeat 4
                collect (bt:make-thread
                         (lambda ()
                           (cl-agent/core:with-di-request-scope
                             (let ((x (cl-agent/core:di-resolve c :svc)))
                               (bt:with-lock-held (lock) (push x results))))))))
    (is (= 4 (length (remove-duplicates results :test #'eq))))))

(test di-other-scopes-unaffected
  "singleton / prototype 语义不受 :request 实现影响"
  (let ((n 0)
        (c (cl-agent/core:make-di-container)))
    (cl-agent/core:di-bind c :single (lambda () (list :s (incf n))) :scope :singleton)
    (cl-agent/core:di-bind c :proto (lambda () (list :p (incf n))) :scope :prototype)
    (is (eq (cl-agent/core:di-resolve c :single) (cl-agent/core:di-resolve c :single)))
    (is (not (eq (cl-agent/core:di-resolve c :proto) (cl-agent/core:di-resolve c :proto))))))
