;;;; test-kernel-core.lisp
;;;; CL-Agent Tests - Kernel Core (registry-based tool management)

(in-package :cl-agent/tests)

(def-suite kernel-core-suite :in cl-agent-suite
  :description "Kernel Core 测试套件")

(in-suite kernel-core-suite)

;;; ============================================================
;;; 测试辅助
;;; ============================================================

(defun make-test-core-weather-tool ()
  "创建测试用天气工具"
  (make-instance 'cl-agent.kernel:tool
                 :name :test-core-get-weather
                 :description "Get weather"
                 :handler (lambda (&key city) (format nil "Sunny in ~A" city))
                 :parameters '((city :type :string :required t
                                     :description "City"))
                 :category :custom
                 :tags '(:weather)))

(defun make-test-core-math-tool ()
  "创建测试用数学工具"
  (make-instance 'cl-agent.kernel:tool
                 :name :test-core-calculate
                 :description "Calculate"
                 :handler (lambda (&key a b) (+ a b))
                 :parameters '((a :type :integer :required t :description "First")
                               (b :type :integer :required t :description "Second"))
                 :category :custom
                 :tags '(:math)))

(defun make-test-core-kernel (&key filters)
  "创建带两个测试工具的 kernel"
  (let ((kernel (cl-agent.kernel:make-kernel
                 :service (cl-agent.mock:make-mock-llm)
                 :filters filters)))
    (cl-agent.kernel:kernel-register-tool kernel (make-test-core-weather-tool))
    (cl-agent.kernel:kernel-register-tool kernel (make-test-core-math-tool))
    kernel))

;;; ============================================================
;;; 测试用例
;;; ============================================================

(test test-make-kernel-minimal
  "测试最小化创建 kernel（仅 service）"
  (let ((kernel (cl-agent.kernel:make-kernel
                 :service (cl-agent.mock:make-mock-llm))))
    (is (typep kernel 'cl-agent.kernel:kernel))
    (is (not (null (cl-agent.kernel:kernel-get-service kernel))))
    (is (null (cl-agent.kernel:kernel-filters kernel)))
    (is (zerop (cl-agent.kernel:kernel-tool-count kernel)))))

(test test-kernel-register-tools
  "测试向 kernel 注册多个工具"
  (let ((kernel (make-test-core-kernel)))
    (is (= 2 (cl-agent.kernel:kernel-tool-count kernel)))
    (is (cl-agent.kernel:kernel-has-tool-p kernel :test-core-get-weather))
    (is (cl-agent.kernel:kernel-has-tool-p kernel :test-core-calculate))))

(test test-kernel-find-tool
  "测试在 kernel 中查找工具"
  (let ((kernel (make-test-core-kernel)))
    ;; 查找天气工具
    (let ((tool (cl-agent.kernel:kernel-find-tool kernel :test-core-get-weather)))
      (is (not (null tool)))
      (is (eq :test-core-get-weather (cl-agent.kernel:tool-name tool))))
    ;; 查找数学工具
    (let ((tool (cl-agent.kernel:kernel-find-tool kernel :test-core-calculate)))
      (is (not (null tool)))
      (is (eq :test-core-calculate (cl-agent.kernel:tool-name tool))))))

(test test-kernel-find-tool-not-found
  "测试查找不存在的工具返回 nil"
  (let ((kernel (make-test-core-kernel)))
    (is (null (cl-agent.kernel:kernel-find-tool kernel :nonexistent)))))

(test test-kernel-execute-tool
  "测试通过 kernel 执行工具"
  (let ((kernel (make-test-core-kernel)))
    (is (string= "Sunny in Tokyo"
                 (cl-agent.kernel:kernel-execute-tool
                  kernel :test-core-get-weather '(:city "Tokyo"))))
    (is (= 7
           (cl-agent.kernel:kernel-execute-tool
            kernel :test-core-calculate '(:a 3 :b 4))))))

(test test-kernel-execute-tool-not-found
  "测试执行不存在的工具报错"
  (let ((kernel (make-test-core-kernel)))
    (signals error
      (cl-agent.kernel:kernel-execute-tool kernel :nonexistent '()))))

(test test-kernel-get-tools
  "测试获取所有工具 schema"
  (let ((kernel (make-test-core-kernel)))
    (let ((tools (cl-agent.kernel:kernel-get-tools kernel)))
      (is (= 2 (length tools)))
      (dolist (tool tools)
        (is (stringp (getf tool :name)))))))

(test test-kernel-get-tools-by-tags
  "测试按标签过滤工具 schema"
  (let ((kernel (make-test-core-kernel)))
    (let ((tools (cl-agent.kernel:kernel-get-tools kernel :tags '(:weather))))
      (is (= 1 (length tools)))
      (is (string= "test-core-get-weather"
                   (string-downcase (getf (first tools) :name)))))))

;;; ============================================================
;;; Invoke 测试（Tier 1: invoke-tool）
;;; ============================================================

(test test-invoke-tool-basic
  "测试基本 invoke-tool 调用"
  (let ((kernel (make-test-core-kernel)))
    (is (string= "Sunny in Tokyo"
                 (cl-agent.kernel:invoke-tool
                  kernel :test-core-get-weather '(:city "Tokyo"))))
    (is (= 7
           (cl-agent.kernel:invoke-tool
            kernel :test-core-calculate '(:a 3 :b 4))))))

(test test-invoke-tool-with-filter
  "测试 invoke-tool 经过 filter chain"
  (let* ((filter-called nil)
         (filter (cl-agent.kernel:make-filter
                  :type :pre-invocation
                  :name "test-filter"
                  :fn (lambda (context next-fn)
                        (setf filter-called t)
                        (funcall next-fn context))))
         (kernel (make-test-core-kernel :filters (list filter))))
    (cl-agent.kernel:invoke-tool kernel :test-core-get-weather '(:city "Test"))
    (is (eq t filter-called))))

(test test-invoke-tool-not-found
  "测试 invoke-tool 工具不存在时报错"
  (let ((kernel (make-test-core-kernel)))
    (signals error
      (cl-agent.kernel:invoke-tool kernel :nonexistent '()))))
