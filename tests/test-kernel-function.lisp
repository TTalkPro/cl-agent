;;;; test-kernel-function.lisp
;;;; CL-Agent Tests - Tool Function（Symbol Plist 方案）

(in-package :cl-agent/tests)

(def-suite kernel-function-suite :in cl-agent-suite
  :description "Tool Function（Symbol Plist）测试套件")

(in-suite kernel-function-suite)

;;; ============================================================
;;; 测试辅助
;;; ============================================================

(defun setup-test-tool ()
  "创建测试用工具函数（通过 declare-tool）"
  (defun test-get-weather (&key city unit)
    (format nil "Weather in ~A: 25~A" city (or unit "celsius")))
  (cl-agent.kernel:declare-tool 'test-get-weather
    :description "Get weather for a city"
    :parameters '((city :string "City name" :required-p t)
                  (unit :string "Temperature unit" :default "celsius"))
    :category :weather
    :sensitive nil))

;;; ============================================================
;;; 测试用例
;;; ============================================================

(test test-declare-tool
  "测试 declare-tool 注册工具元数据"
  (setup-test-tool)
  (is (eq t (cl-agent.kernel:tool-function-p 'test-get-weather)))
  (is (string= "Get weather for a city" (cl-agent.kernel:tool-description 'test-get-weather)))
  (is (eq :weather (get 'test-get-weather :category)))
  (is (null (get 'test-get-weather :sensitive)))
  (is (eq :TEST-GET-WEATHER (cl-agent.kernel:tool-name 'test-get-weather))))

(test test-tool-invoke
  "测试直接调用工具函数"
  (setup-test-tool)
  (let ((result (funcall 'test-get-weather :city "Beijing" :unit "fahrenheit")))
    (is (string= "Weather in Beijing: 25fahrenheit" result)))
  (let ((result (funcall 'test-get-weather :city "Tokyo")))
    (is (string= "Weather in Tokyo: 25celsius" result))))

(test test-validate-tool-args-required
  "测试缺少必需参数时报错"
  (setup-test-tool)
  (signals error
    (cl-agent.kernel:validate-tool-args 'test-get-weather '(:unit "celsius"))))

(test test-validate-tool-args-optional
  "测试可选参数不报错"
  (setup-test-tool)
  ;; unit 是可选的，不传不应报错
  (is (eq t (cl-agent.kernel:validate-tool-args 'test-get-weather '(:city "London")))))

(test test-params-to-json-schema
  "测试参数规格转 JSON Schema"
  (let ((schema (cl-agent.kernel:params->json-schema
                 '((city :string "City name" :required-p t)
                   (unit :string "Temperature unit")))))
    (is (string= "object" (getf schema :type)))
    ;; properties 应包含 city 和 unit
    (let ((props (getf schema :properties)))
      (is (= 2 (length props)))
      ;; 第一个是 city
      (let ((city-prop (second (first props))))
        (is (string= "string" (getf city-prop :type)))
        (is (string= "City name" (getf city-prop :description)))))
    ;; required 应只包含 city
    (let ((required (getf schema :required)))
      (is (= 1 (length required)))
      (is (string= "city" (first required))))))

(test test-tool-schema-hash-table
  "测试 tool-schema 返回 hash-table"
  (setup-test-tool)
  (let ((ht (cl-agent.kernel:tool-schema 'test-get-weather)))
    (is (hash-table-p ht))
    (is (string= "object" (gethash "type" ht)))
    (is (hash-table-p (gethash "properties" ht)))))

(test test-deftool-basic
  "测试 deftool 宏基本功能"
  (eval '(cl-agent.kernel:deftool test-add "Add two numbers"
           ((a :int "First number" :required-p t)
            (b :int "Second number" :required-p t))
           (+ a b)))

  ;; 检查函数是否可调用
  (is (= 5 (funcall 'test-add :a 2 :b 3)))

  ;; 检查 plist 元数据
  (is (eq t (cl-agent.kernel:tool-function-p 'test-add)))
  (is (string= "Add two numbers" (cl-agent.kernel:tool-description 'test-add)))
  (is (eq :TEST-ADD (cl-agent.kernel:tool-name 'test-add))))

(test test-deftool-with-options
  "测试 deftool 宏带选项"
  (eval '(cl-agent.kernel:deftool test-delete "Delete something"
           ((target :string "Target" :required-p t))
           (:sensitive t :category :destructive)
           (format nil "Deleted: ~A" target)))

  (is (get 'test-delete :sensitive))
  (is (eq :destructive (get 'test-delete :category))))

(test test-deftool-no-params
  "测试无参数的 deftool"
  (eval '(cl-agent.kernel:deftool test-noop "Do nothing"
           ()
           "done"))

  (is (string= "done" (funcall 'test-noop))))

(test test-params-to-json-schema-empty
  "测试空参数的 Schema 生成"
  (let ((schema (cl-agent.kernel:params->json-schema nil)))
    (is (string= "object" (getf schema :type)))
    (is (null (getf schema :properties)))
    (is (null (getf schema :required)))))

(test test-params-to-json-schema-types
  "测试各种类型的 Schema 映射"
  (let ((schema (cl-agent.kernel:params->json-schema
                 '((name :string "Name")
                   (age :int "Age")
                   (score :float "Score")
                   (active :bool "Active")
                   (tags :array "Tags")
                   (data :object "Data")))))
    (let ((props (getf schema :properties)))
      (is (= 6 (length props))))))
