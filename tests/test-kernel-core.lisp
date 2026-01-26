;;;; test-kernel-core.lisp
;;;; CL-Agent Tests - Kernel Core

(in-package :cl-agent/tests)

(def-suite kernel-core-suite :in cl-agent-suite
  :description "Kernel Core 测试套件")

(in-suite kernel-core-suite)

;;; ============================================================
;;; 测试辅助
;;; ============================================================

(defun setup-test-weather-tools ()
  "注册测试用天气工具和插件"
  (defun test-core-get-weather (&key city)
    (format nil "Sunny in ~A" city))
  (cl-agent.kernel:declare-tool 'test-core-get-weather
    :description "Get weather"
    :parameters '((city :string "City" :required-p t))
    :category :weather)
  (cl-agent.kernel:declare-plugin 'test-core-weather-plugin
    "Weather tools"
    '(test-core-get-weather)))

(defun setup-test-math-tools ()
  "注册测试用数学工具和插件"
  (defun test-core-calculate (&key a b)
    (+ a b))
  (cl-agent.kernel:declare-tool 'test-core-calculate
    :description "Calculate"
    :parameters '((a :int "First" :required-p t)
                  (b :int "Second" :required-p t))
    :category :math)
  (cl-agent.kernel:declare-plugin 'test-core-math-plugin
    "Math tools"
    '(test-core-calculate)))

;;; ============================================================
;;; 测试用例
;;; ============================================================

(test test-make-kernel-minimal
  "测试最小化创建 kernel（仅 service）"
  (let ((kernel (cl-agent.kernel:make-kernel
                 :service (cl-agent.mock:make-mock-llm))))
    (is (typep kernel 'cl-agent.kernel:kernel))
    (is (not (null (cl-agent.kernel:kernel-service kernel))))
    (is (null (cl-agent.kernel:kernel-plugins kernel)))
    (is (null (cl-agent.kernel:kernel-filters kernel)))))

(test test-make-kernel-with-plugins
  "测试创建带多个 plugin 的 kernel"
  (setup-test-weather-tools)
  (setup-test-math-tools)
  (let ((kernel (cl-agent.kernel:make-kernel
                 :service (cl-agent.mock:make-mock-llm)
                 :plugins '(test-core-weather-plugin test-core-math-plugin))))
    (is (= 2 (length (cl-agent.kernel:kernel-plugins kernel))))))

(test test-kernel-find-tool-symbol
  "测试在 kernel 中跨 plugin 查找工具符号"
  (setup-test-weather-tools)
  (setup-test-math-tools)
  (let ((kernel (cl-agent.kernel:make-kernel
                 :service (cl-agent.mock:make-mock-llm)
                 :plugins '(test-core-weather-plugin test-core-math-plugin))))
    ;; 查找 weather plugin 中的函数
    (let ((sym (cl-agent.kernel:kernel-find-tool-symbol kernel :test-core-get-weather)))
      (is (not (null sym)))
      (is (eq 'test-core-get-weather sym)))
    ;; 查找 math plugin 中的函数
    (let ((sym (cl-agent.kernel:kernel-find-tool-symbol kernel :test-core-calculate)))
      (is (not (null sym)))
      (is (eq 'test-core-calculate sym)))))

(test test-kernel-find-tool-symbol-not-found
  "测试查找不存在的函数返回 nil"
  (setup-test-weather-tools)
  (let ((kernel (cl-agent.kernel:make-kernel
                 :service (cl-agent.mock:make-mock-llm)
                 :plugins '(test-core-weather-plugin))))
    (is (null (cl-agent.kernel:kernel-find-tool-symbol kernel :nonexistent)))))

(test test-kernel-execute-tool
  "测试通过 kernel 执行工具"
  (setup-test-weather-tools)
  (setup-test-math-tools)
  (let ((kernel (cl-agent.kernel:make-kernel
                 :service (cl-agent.mock:make-mock-llm)
                 :plugins '(test-core-weather-plugin test-core-math-plugin))))
    (is (string= "Sunny in Tokyo"
                 (cl-agent.kernel:kernel-execute-tool kernel :test-core-get-weather '(:city "Tokyo"))))
    (is (= 7
           (cl-agent.kernel:kernel-execute-tool kernel :test-core-calculate '(:a 3 :b 4))))))

(test test-kernel-execute-tool-not-found
  "测试执行不存在的工具报错"
  (setup-test-weather-tools)
  (let ((kernel (cl-agent.kernel:make-kernel
                 :service (cl-agent.mock:make-mock-llm)
                 :plugins '(test-core-weather-plugin))))
    (signals error
      (cl-agent.kernel:kernel-execute-tool kernel :nonexistent '()))))

(test test-kernel-get-tools
  "测试获取所有工具 schema"
  (setup-test-weather-tools)
  (setup-test-math-tools)
  (let ((kernel (cl-agent.kernel:make-kernel
                 :service (cl-agent.mock:make-mock-llm)
                 :plugins '(test-core-weather-plugin test-core-math-plugin))))
    (let ((tools (cl-agent.kernel:kernel-get-tools kernel)))
      (is (= 2 (length tools)))
      (dolist (tool tools)
        (is (stringp (getf tool :name)))))))

(test test-kernel-get-tools-cached
  "测试工具 schema 缓存"
  (setup-test-weather-tools)
  (let ((kernel (cl-agent.kernel:make-kernel
                 :service (cl-agent.mock:make-mock-llm)
                 :plugins '(test-core-weather-plugin))))
    ;; 第一次调用
    (let ((tools1 (cl-agent.kernel:kernel-get-tools kernel)))
      ;; 第二次调用应返回相同对象（缓存）
      (let ((tools2 (cl-agent.kernel:kernel-get-tools kernel)))
        (is (eq tools1 tools2))))))

;;; ============================================================
;;; Invoke 测试
;;; ============================================================

(test test-invoke-basic
  "测试基本 invoke 调用"
  (setup-test-weather-tools)
  (setup-test-math-tools)
  (let ((kernel (cl-agent.kernel:make-kernel
                 :service (cl-agent.mock:make-mock-llm)
                 :plugins '(test-core-weather-plugin test-core-math-plugin))))
    (is (string= "Sunny in Tokyo"
                 (cl-agent.kernel:invoke kernel :test-core-get-weather '(:city "Tokyo"))))
    (is (= 7
           (cl-agent.kernel:invoke kernel :test-core-calculate '(:a 3 :b 4))))))

(test test-invoke-with-filter
  "测试 invoke 经过 filter chain"
  (setup-test-weather-tools)
  (let* ((filter-called nil)
         (filter (lambda (context next-fn)
                   (setf filter-called t)
                   (funcall next-fn context)))
         (kernel (cl-agent.kernel:make-kernel
                  :service (cl-agent.mock:make-mock-llm)
                  :plugins '(test-core-weather-plugin)
                  :filters (list filter))))
    (cl-agent.kernel:invoke kernel :test-core-get-weather '(:city "Test"))
    (is (eq t filter-called))))

(test test-invoke-not-found
  "测试 invoke 函数不存在时报错"
  (setup-test-weather-tools)
  (let ((kernel (cl-agent.kernel:make-kernel
                 :service (cl-agent.mock:make-mock-llm)
                 :plugins '(test-core-weather-plugin))))
    (signals error
      (cl-agent.kernel:invoke kernel :nonexistent '()))))
