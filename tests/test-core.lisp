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
;; 状态管理测试
;; ============================================================

(test make-state
  "测试状态创建"
  (let ((state (cl-agent.workflow:make-state :a 1 :b 2)))
    (is (= 1 (cl-agent.workflow:state-get state :a)))
    (is (= 2 (cl-agent.workflow:state-get state :b)))))

(test state-set
  "测试状态设置"
  (let* ((state (cl-agent.workflow:make-state))
         (new-state (cl-agent.workflow:state-set state :key "value")))
    ;; 不可变性
    (is (eq nil (cl-agent.workflow:state-get state :key)))
    (is (string= "value" (cl-agent.workflow:state-get new-state :key)))))

(test state-update
  "测试状态更新"
  (let* ((state (cl-agent.workflow:make-state :a 1))
         (new-state (cl-agent.workflow:state-update state :b 2 :c 3)))
    (is (= 1 (cl-agent.workflow:state-get new-state :a)))
    (is (= 2 (cl-agent.workflow:state-get new-state :b)))
    (is (= 3 (cl-agent.workflow:state-get new-state :c)))))

;; ============================================================
;; 条件系统测试
;; ============================================================

(test signal-error
  "测试错误信号"
  (signals cl-agent.core:cl-agent-error
    (cl-agent.core:signal-error 'cl-agent.core:cl-agent-error
                          :message "Test error")))

(test validation-error
  "测试验证错误"
  (signals cl-agent.core:validation-error
    (cl-agent.core:signal-validation-error "test-field"
                                     :message "Invalid value"))))

;; ============================================================
;; 运行核心测试
;; ============================================================

(defun run-core-tests ()
  "运行核心测试"
  (run! 'core-suite))
