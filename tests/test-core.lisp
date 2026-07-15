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
  (is (stringp (cl-agent.core:get-env "HOME")))
  (is (eq nil (cl-agent.core:get-env "NONEXISTENT_VAR_XYZ")))
  (is (string= "default"
               (cl-agent.core:get-env "NONEXISTENT_VAR" "default"))))

(test generate-uuid
  "测试 UUID 生成"
  (let ((uuid (cl-agent.core:generate-uuid)))
    (is (stringp uuid))
    (is (> (length uuid) 0))
    ;; 每次生成不同的 UUID
    (let ((uuid2 (cl-agent.core:generate-uuid)))
      (is (not (string= uuid uuid2))))))

(test timestamp
  "测试时间戳"
  (let ((ts (cl-agent.core:timestamp-now)))
    (is (integerp ts))
    (is (> ts 0))))

;; ============================================================
;; JSON 操作测试
;; ============================================================

(test json-parse
  "测试 JSON 解析"
  (skip "JSON 解析测试需要额外配置"))

(test json-stringify
  "测试 JSON 序列化"
  (skip "JSON 序列化测试需要额外配置"))

;; ============================================================
;; 条件系统测试
;; ============================================================

;;; 链式宏
;;; 注：macros.lisp 中 as-> 曾因 defmacro 缺一个右括号而使其后约 290 行
;;; （含整个日志系统）从未生效；括号补上后 as-> 自身的逻辑缺陷才暴露出来
;;; （丢弃 initial-form、嵌套顺序颠倒 → UNBOUND-VARIABLE）。

(test thread-as-macro
  "as-> 依次以 VAR 承接上一步结果"
  (is (= 12 (cl-agent.core:as-> 5 x (+ x 1) (* x 2))))
  ;; 插入位置任意（这正是 as-> 相对 -> / ->> 的意义）
  (is (= 3 (cl-agent.core:as-> 10 x (/ x 5) (- 5 x))))
  ;; 无 form 时返回初值
  (is (= 5 (cl-agent.core:as-> 5 x)))
  ;; form 不引用 VAR 也不应报错（ignorable）
  (is (= 7 (cl-agent.core:as-> 5 x 7))))

(test thread-first-and-last-macros
  "-> 与 ->> 的插入位置分别为首参与末参"
  (is (= 12 (cl-agent.core:-> 5 (+ 1) (* 2))))
  (is (equal '(1 2 3) (cl-agent.core:->> '(3 2 1) (reverse))))
  ;; -> 插首参：(/ 10 2) = 5；->> 插末参：(/ 2 10) = 1/5
  (is (= 5 (cl-agent.core:-> 10 (/ 2))))
  (is (= 1/5 (cl-agent.core:->> 10 (/ 2)))))

(test signal-error
  "测试错误信号"
  (signals cl-agent.core:cl-agent-error
    (cl-agent.core:signal-error 'cl-agent.core:cl-agent-error
                          :message "Test error")))

(test validation-error
  "测试验证错误"
  (signals cl-agent.core:validation-error
    (cl-agent.core:signal-validation-error "test-field"
                                     :message "Invalid value")))

;; ============================================================
;; 运行核心测试
;; ============================================================

(defun run-core-tests ()
  "运行核心测试"
  (run! 'core-suite))
