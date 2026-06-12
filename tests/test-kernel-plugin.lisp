;;;; test-kernel-plugin.lisp
;;;; CL-Agent Tests - Plugin（Symbol Plist 方案）

(in-package :cl-agent/tests)

(def-suite kernel-plugin-suite :in cl-agent-suite
  :description "Plugin（Symbol Plist）测试套件")

(in-suite kernel-plugin-suite)

;;; ============================================================
;;; 测试辅助
;;; ============================================================

(defun setup-test-tools-and-plugin ()
  "创建测试用工具和插件"
  ;; 定义工具函数
  (defun test-plug-weather (&key city)
    (format nil "Sunny in ~A" city))
  (cl-agent.kernel:declare-tool 'test-plug-weather
    :description "Get weather"
    :parameters '((city :string "City" :required-p t))
    :category :weather)

  (defun test-plug-forecast (&key city days)
    (format nil "~A-day forecast for ~A" (or days 5) city))
  (cl-agent.kernel:declare-tool 'test-plug-forecast
    :description "Get forecast"
    :parameters '((city :string "City" :required-p t)
                  (days :int "Days"))
    :category :weather)

  (defun test-plug-math (&key expression)
    (format nil "Result: ~A" expression))
  (cl-agent.kernel:declare-tool 'test-plug-math
    :description "Calculate expression"
    :parameters '((expression :string "Expression" :required-p t))
    :category :math)

  ;; 定义插件
  (cl-agent.kernel:declare-plugin 'test-weather-plugin
    "Weather related tools"
    '(test-plug-weather test-plug-forecast)))

;;; ============================================================
;;; 测试用例
;;; ============================================================

(test test-declare-plugin
  "测试 declare-plugin 注册插件元数据"
  (setup-test-tools-and-plugin)
  (is (eq t (cl-agent.kernel:plugin-p 'test-weather-plugin)))
  (is (string= "Weather related tools"
                (cl-agent.core:plugin-description 'test-weather-plugin))))

(test test-plugin-tool-symbols
  "测试获取插件的工具符号列表"
  (setup-test-tools-and-plugin)
  (let ((tools (cl-agent.kernel:plugin-tool-symbols 'test-weather-plugin)))
    (is (= 2 (length tools)))
    (is (member 'test-plug-weather tools))
    (is (member 'test-plug-forecast tools))))

(test test-plugin-get-schemas
  "测试获取插件所有工具的 Schema"
  (setup-test-tools-and-plugin)
  (let ((schemas (cl-agent.kernel:plugin-get-schemas 'test-weather-plugin)))
    (is (= 2 (length schemas)))
    ;; 每个 schema 都有 :name 字段
    (dolist (schema schemas)
      (is (stringp (getf schema :name)))
      (is (stringp (getf schema :description)))
      (is (hash-table-p (getf schema :input-schema))))))

(test test-defplugin-macro
  "测试 defplugin 宏"
  ;; 先定义工具
  (eval '(progn
           (cl-agent.kernel:deftool test-plug-fn1 "Function 1"
             ((x :int "X" :required-p t))
             (* x 2))
           (cl-agent.kernel:deftool test-plug-fn2 "Function 2"
             ((y :string "Y" :required-p t))
             (concatenate 'string y "!"))
           (cl-agent.kernel:defplugin test-demo-plugin "Demo plugin"
             test-plug-fn1
             test-plug-fn2)))

  ;; 检查 plugin 元数据
  (is (eq t (cl-agent.kernel:plugin-p 'test-demo-plugin)))
  (is (string= "Demo plugin" (cl-agent.core:plugin-description 'test-demo-plugin)))
  ;; 包含两个工具
  (let ((tools (cl-agent.kernel:plugin-tool-symbols 'test-demo-plugin)))
    (is (= 2 (length tools)))
    (is (member 'test-plug-fn1 tools))
    (is (member 'test-plug-fn2 tools))))

(test test-plugin-tool-execution
  "测试通过 plugin 工具符号调用函数"
  (setup-test-tools-and-plugin)
  (let ((tool-sym (first (cl-agent.kernel:plugin-tool-symbols 'test-weather-plugin))))
    ;; 直接 funcall symbol-function
    (let ((result (funcall (symbol-function tool-sym) :city "Beijing")))
      (is (stringp result)))))

(test test-plugin-not-exist
  "测试不存在的 plugin 符号"
  (is (null (cl-agent.kernel:plugin-p 'nonexistent-plugin-xyz))))
