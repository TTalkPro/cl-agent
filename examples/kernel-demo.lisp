;;;; kernel-demo.lisp
;;;; CL-Agent - Kernel 系统使用示例
;;;;
;;;; 概述：
;;;;   演示 Semantic Kernel 模式的使用方法，包括：
;;;;   - deftool 定义工具函数
;;;;   - defplugin 组织插件
;;;;   - make-kernel 创建 Kernel
;;;;   - invoke-kernel 自动工具调用循环
;;;;   - filter chain 过滤器链
;;;;
;;;; 使用：
;;;;   (asdf:load-system :cl-agent)
;;;;   (load "examples/kernel-demo.lisp")

(in-package :cl-user)

;;; ============================================================
;;; Step 1: 定义工具函数
;;; ============================================================

;; 定义天气查询函数
(cl-agent.kernel:deftool get-weather "Get current weather for a city"
  ((city :string "City name" :required-p t)
   (unit :string "Temperature unit (celsius/fahrenheit)" :default "celsius"))
  (format nil "Weather in ~A: 22 degrees ~A, partly cloudy" city unit))

;; 定义温度转换函数
(cl-agent.kernel:deftool convert-temperature "Convert temperature between units"
  ((value :float "Temperature value" :required-p t)
   (from-unit :string "Source unit" :required-p t)
   (to-unit :string "Target unit" :required-p t))
  (let ((celsius (if (string-equal from-unit "fahrenheit")
                     (* (- value 32) 5/9)
                     value)))
    (format nil "~,1F ~A"
            (if (string-equal to-unit "fahrenheit")
                (+ (* celsius 9/5) 32)
                celsius)
            to-unit)))

;; 定义计算器函数（标记为敏感操作用于演示审批 filter）
(cl-agent.kernel:deftool eval-expression "Evaluate a math expression"
  ((expression :string "Math expression" :required-p t))
  (:sensitive t :category :math)
  (format nil "Result: ~A" (eval (read-from-string expression))))

;;; ============================================================
;;; Step 2: 创建 Plugin
;;; ============================================================

;; 使用 defplugin 宏组织相关函数
(cl-agent.kernel:defplugin weather-plugin "Weather and temperature tools"
  get-weather
  convert-temperature)

;; 或者使用 declare-plugin 运行时注册
(cl-agent.kernel:declare-plugin 'math-plugin
  "Math tools"
  '(eval-expression))

;;; ============================================================
;;; Step 3: 创建 Kernel（使用 Mock LLM）
;;; ============================================================

(defun demo-basic-kernel ()
  "演示基本 Kernel 使用"
  (format t "~%=== Basic Kernel Demo ===~%")

  ;; 创建 kernel
  (let* ((mock-llm (cl-agent.mock:make-mock-llm))
         (kernel (cl-agent.kernel:make-kernel
                  :service mock-llm
                  :plugins '(weather-plugin math-plugin))))

    ;; 查看已注册的工具
    (format t "~%Registered tools:~%")
    (dolist (tool-schema (cl-agent.kernel:kernel-get-tools kernel))
      (format t "  - ~A: ~A~%"
              (getf tool-schema :name)
              (getf tool-schema :description)))

    ;; 直接执行工具
    (format t "~%Direct tool execution:~%")
    (format t "  get-weather: ~A~%"
            (cl-agent.kernel:kernel-execute-tool kernel :get-weather
                                                      '(:city "Tokyo")))
    (format t "  convert-temperature: ~A~%"
            (cl-agent.kernel:kernel-execute-tool kernel :convert-temperature
                                                      '(:value 100.0 :from-unit "celsius" :to-unit "fahrenheit")))))

;;; ============================================================
;;; Step 4: Filter Chain 演示
;;; ============================================================

(defun demo-filter-chain ()
  "演示 Filter Chain 使用"
  (format t "~%=== Filter Chain Demo ===~%")

  (let* ((mock-llm (cl-agent.mock:make-mock-llm))
         (kernel (cl-agent.kernel:make-kernel
                  :service mock-llm
                  :plugins '(weather-plugin math-plugin)
                  :filters (list
                            ;; 日志 filter
                            (cl-agent.kernel:make-logging-filter)
                            ;; 错误处理 filter
                            (cl-agent.kernel:make-error-handling-filter)))))

    ;; 执行工具（会经过 filter chain）
    (format t "~%Executing with filters:~%")
    (let* ((execute-fn (lambda (ctx)
                         (cl-agent.kernel:kernel-execute-tool
                          kernel (getf ctx :tool-name) (getf ctx :tool-args))))
           (chain (cl-agent.kernel:build-filter-chain
                   (cl-agent.kernel:kernel-filters kernel) execute-fn))
           (result (funcall chain '(:tool-name :get-weather
                                    :tool-args (:city "Paris")
                                    :tool-id "demo_1"
                                    :kernel nil))))
      (format t "~%Result: ~A~%" result))))

;;; ============================================================
;;; Step 5: Chat Completion 演示
;;; ============================================================

(defun demo-chat-completion ()
  "演示 Chat Completion 循环"
  (format t "~%=== Chat Completion Demo ===~%")

  ;; 使用 mock LLM（简单文本响应）
  (let* ((mock-llm (cl-agent.mock:make-mock-llm))
         (kernel (cl-agent.kernel:make-kernel
                  :service mock-llm
                  :plugins '(weather-plugin)))
         (history (cl-agent.kernel:make-chat-history)))

    ;; 添加用户消息
    (cl-agent.kernel:history-add history :user "你好，今天天气怎么样？")

    ;; 执行 invoke-kernel（mock 不会触发工具调用，直接返回文本）
    (let ((result (cl-agent.simpleagent:invoke-kernel kernel
                    (cl-agent.kernel:chat-history-messages history)
                    :settings '(:system-prompt "You are a helpful weather assistant."))))
      (format t "~%Response: ~A~%" (getf result :text))
      (format t "Tool calls made: ~A~%" (length (getf result :tool-calls-made))))))

;;; ============================================================
;;; 运行所有演示
;;; ============================================================

(defun run-kernel-demos ()
  "运行所有 Kernel 演示"
  (demo-basic-kernel)
  (demo-filter-chain)
  (demo-chat-completion)
  (format t "~%=== All demos completed ===~%"))

;; 自动运行
;; (run-kernel-demos)
