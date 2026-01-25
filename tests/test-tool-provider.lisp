;;;; test-tool-provider.lisp
;;;; CL-Agent - Tool Provider System 测试

(in-package :cl-agent/tests)

;; Tool Provider 测试套件
(def-suite tool-provider-suite :in cl-agent-tests:lisp-in-agents-suite
  :description "Tool Provider 系统测试")

(in-suite tool-provider-suite)

;; ============================================================
;; Tool 类测试
;; ============================================================

(test create-simple-tool
  "测试创建简单工具"
  (let ((tool (cl-agent.tools:make-simple-tool
               :test-tool
               "A test tool"
               (lambda (&key x) (* 2 x))
               :parameters '((:x :type number :required t))
               :category :test
               :permissions '(:test-perm))))
    (is (not (null tool)))
    (is (eq (cl-agent.tools:tool-name tool) :test-tool))
    (is (string= (cl-agent.tools:tool-description tool) "A test tool"))
    (is (eq (cl-agent.tools:tool-category tool) :test))
    (is (functionp (cl-agent.tools:tool-handler tool)))
    (is (equal (cl-agent.tools:tool-permissions tool) '(:test-perm)))))

(test tool-handler-execution
  "测试工具处理函数执行"
  (let ((tool (cl-agent.tools:make-simple-tool
               :double
               "Double a number"
               (lambda (&key x) (* 2 x)))))
    (let ((result (funcall (cl-agent.tools:tool-handler tool) :x 5)))
      (is (= result 10)))))

;; ============================================================
;; Tool Provider 类测试
;; ============================================================

(test create-tool-provider
  "测试创建 tool provider"
  (let ((provider (make-instance 'cl-agent.tools:tool-provider
                                 :name "test-provider"
                                 :enabled t)))
    (is (not (null provider)))
    (is (string= (cl-agent.tools:provider-name provider) "test-provider"))
    (is (cl-agent.tools:provider-enabled-p provider))
    (is (= (cl-agent.tools:provider-tool-count provider) 0))))

(test initialize-provider
  "测试 provider 初始化"
  (let ((provider (make-instance 'cl-agent.tools:tool-provider
                                 :name "init-test")))
    (let ((result (cl-agent.tools:initialize-provider provider)))
      (is (eq result provider)))))

(test shutdown-provider
  "测试 provider 关闭"
  (let ((provider (make-instance 'cl-agent.tools:tool-provider
                                 :name "shutdown-test")))
    ;; 注册工具
    (cl-agent.tools:register-tool
     provider
     (cl-agent.tools:make-simple-tool :tool1 "Tool 1" (lambda () nil)))

    (is (= (cl-agent.tools:provider-tool-count provider) 1))

    ;; 关闭
    (cl-agent.tools:shutdown-provider provider)

    (is (= (cl-agent.tools:provider-tool-count provider) 0))))

;; ============================================================
;; Provider 工具管理测试
;; ============================================================

(test register-tool-to-provider
  "测试注册工具到 provider"
  (let ((provider (make-instance 'cl-agent.tools:tool-provider
                                 :name "register-test"))
        (tool (cl-agent.tools:make-simple-tool
               :test-tool
               "Test tool"
               (lambda () "result"))))

    (cl-agent.tools:register-tool provider tool)

    (is (= (cl-agent.tools:provider-tool-count provider) 1))
    (is (not (null (cl-agent.tools:find-tool provider :test-tool))))))

(test unregister-tool-from-provider
  "测试从 provider 注销工具"
  (let ((provider (make-instance 'cl-agent.tools:tool-provider
                                 :name "unregister-test"))
        (tool (cl-agent.tools:make-simple-tool
               :temp-tool
               "Temporary tool"
               (lambda () nil))))

    (cl-agent.tools:register-tool provider tool)
    (is (not (null (cl-agent.tools:find-tool provider :temp-tool))))

    (cl-agent.tools:unregister-tool provider :temp-tool)
    (is (null (cl-agent.tools:find-tool provider :temp-tool)))))

(test list-tools-from-provider
  "测试列出 provider 中的工具"
  (let ((provider (make-instance 'cl-agent.tools:tool-provider
                                 :name "list-test")))

    ;; 注册多个工具
    (cl-agent.tools:register-tool
     provider
     (cl-agent.tools:make-simple-tool :tool1 "Tool 1" (lambda () nil)
                                      :category :cat1))
    (cl-agent.tools:register-tool
     provider
     (cl-agent.tools:make-simple-tool :tool2 "Tool 2" (lambda () nil)
                                      :category :cat2))
    (cl-agent.tools:register-tool
     provider
     (cl-agent.tools:make-simple-tool :tool3 "Tool 3" (lambda () nil)
                                      :category :cat1))

    ;; 列出所有工具
    (let ((all-tools (cl-agent.tools:list-tools provider)))
      (is (= (length all-tools) 3)))

    ;; 按分类列出
    (let ((cat1-tools (cl-agent.tools:list-tools provider :category :cat1)))
      (is (= (length cat1-tools) 2)))))

;; ============================================================
;; Provider 工具执行测试
;; ============================================================

(test execute-tool-from-provider
  "测试从 provider 执行工具"
  (let ((provider (make-instance 'cl-agent.tools:tool-provider
                                 :name "execute-test"))
        (tool (cl-agent.tools:make-simple-tool
               :calculator
               "Calculate"
               (lambda (&key a b) (+ a b)))))

    (cl-agent.tools:register-tool provider tool)

    (let ((result (cl-agent.tools:execute-tool provider :calculator :a 3 :b 5)))
      (is (= result 8)))))

(test execute-tool-disabled-provider
  "测试从禁用的 provider 执行工具应该失败"
  (let ((provider (make-instance 'cl-agent.tools:tool-provider
                                 :name "disabled-test"))
        (tool (cl-agent.tools:make-simple-tool
               :test
               "Test"
               (lambda () "result"))))

    (cl-agent.tools:register-tool provider tool)
    (cl-agent.tools:disable-provider provider)

    (signals error
      (cl-agent.tools:execute-tool provider :test))))

(test execute-nonexistent-tool
  "测试执行不存在的工具应该失败"
  (let ((provider (make-instance 'cl-agent.tools:tool-provider
                                 :name "nonexistent-test")))
    (signals error
      (cl-agent.tools:execute-tool provider :nonexistent))))

;; ============================================================
;; Provider 启用/禁用测试
;; ============================================================

(test enable-disable-provider
  "测试启用/禁用 provider"
  (let ((provider (make-instance 'cl-agent.tools:tool-provider
                                 :name "toggle-test"
                                 :enabled t)))

    (is (cl-agent.tools:provider-enabled-p provider))

    (cl-agent.tools:disable-provider provider)
    (is (not (cl-agent.tools:provider-enabled-p provider)))

    (cl-agent.tools:enable-provider provider)
    (is (cl-agent.tools:provider-enabled-p provider))))

;; ============================================================
;; Tool Registry 测试
;; ============================================================

(test create-tool-registry
  "测试创建 tool registry"
  (let ((registry (cl-agent.tools:make-tool-registry)))
    (is (not (null registry)))
    (is (= (cl-agent.tools:registry-provider-count registry) 0))
    (is (= (cl-agent.tools:registry-tool-count registry) 0))))

(test create-registry-with-providers
  "测试创建带有 providers 的 registry"
  (let ((provider1 (make-instance 'cl-agent.tools:tool-provider
                                  :name "provider1"))
        (provider2 (make-instance 'cl-agent.tools:tool-provider
                                  :name "provider2")))

    (let ((registry (cl-agent.tools:make-tool-registry provider1 provider2)))
      (is (= (cl-agent.tools:registry-provider-count registry) 2)))))

;; ============================================================
;; Registry Provider 管理测试
;; ============================================================

(test add-provider-to-registry
  "测试添加 provider 到 registry"
  (let ((registry (cl-agent.tools:make-tool-registry))
        (provider (make-instance 'cl-agent.tools:tool-provider
                                 :name "new-provider")))

    (cl-agent.tools:add-provider registry provider)

    (is (= (cl-agent.tools:registry-provider-count registry) 1))
    (is (not (null (cl-agent.tools:find-provider registry "new-provider"))))))

(test remove-provider-from-registry
  "测试从 registry 移除 provider"
  (let ((provider (make-instance 'cl-agent.tools:tool-provider
                                 :name "removable"))
        (registry (cl-agent.tools:make-tool-registry)))

    (cl-agent.tools:add-provider registry provider)
    (is (= (cl-agent.tools:registry-provider-count registry) 1))

    (cl-agent.tools:remove-provider registry "removable")
    (is (= (cl-agent.tools:registry-provider-count registry) 0))))

(test find-provider-in-registry
  "测试在 registry 中查找 provider"
  (let ((provider (make-instance 'cl-agent.tools:tool-provider
                                 :name "findable"))
        (registry (cl-agent.tools:make-tool-registry)))

    (cl-agent.tools:add-provider registry provider)

    (let ((found (cl-agent.tools:find-provider registry "findable")))
      (is (not (null found)))
      (is (string= (cl-agent.tools:provider-name found) "findable")))))

;; ============================================================
;; Registry 工具查找测试
;; ============================================================

(test find-tool-in-registry
  "测试在 registry 中查找工具"
  (let ((provider (make-instance 'cl-agent.tools:tool-provider
                                 :name "provider"))
        (tool (cl-agent.tools:make-simple-tool
               :finder
               "Find me"
               (lambda () "found")))
        (registry (cl-agent.tools:make-tool-registry)))

    (cl-agent.tools:register-tool provider tool)
    (cl-agent.tools:add-provider registry provider)

    ;; 使用新的泛型函数 find-tool
    (let ((found-tool (cl-agent.tools:find-tool registry :finder)))
      (is (not (null found-tool)))
      (is (eq (cl-agent.tools:tool-name found-tool) :finder)))))

(test tool-exists-in-registry
  "测试检查工具是否存在于 registry"
  (let ((provider (make-instance 'cl-agent.tools:tool-provider
                                 :name "provider"))
        (tool (cl-agent.tools:make-simple-tool
               :exists
               "I exist"
               (lambda () t)))
        (registry (cl-agent.tools:make-tool-registry)))

    (cl-agent.tools:register-tool provider tool)
    (cl-agent.tools:add-provider registry provider)

    (is (cl-agent.tools:tool-exists-p registry :exists))
    (is (not (cl-agent.tools:tool-exists-p registry :nonexistent)))))

(test list-all-tools-in-registry
  "测试列出 registry 中的所有工具"
  (let ((provider1 (make-instance 'cl-agent.tools:tool-provider
                                  :name "provider1"))
        (provider2 (make-instance 'cl-agent.tools:tool-provider
                                  :name "provider2"))
        (registry (cl-agent.tools:make-tool-registry)))

    ;; Provider 1 的工具
    (cl-agent.tools:register-tool
     provider1
     (cl-agent.tools:make-simple-tool :tool1 "Tool 1" (lambda () nil)
                                      :category :cat1))
    (cl-agent.tools:register-tool
     provider1
     (cl-agent.tools:make-simple-tool :tool2 "Tool 2" (lambda () nil)
                                      :category :cat2))

    ;; Provider 2 的工具
    (cl-agent.tools:register-tool
     provider2
     (cl-agent.tools:make-simple-tool :tool3 "Tool 3" (lambda () nil)
                                      :category :cat1))

    (cl-agent.tools:add-provider registry provider1)
    (cl-agent.tools:add-provider registry provider2)

    ;; 列出所有工具
    (let ((all-tools (cl-agent.tools:list-all-tools registry)))
      (is (= (length all-tools) 3)))

    ;; 按分类列出
    (let ((cat1-tools (cl-agent.tools:list-all-tools registry :category :cat1)))
      (is (= (length cat1-tools) 2)))

    ;; 按 provider 列出
    (let ((provider1-tools (cl-agent.tools:list-all-tools registry
                                                          :provider "provider1")))
      (is (= (length provider1-tools) 2)))))

;; ============================================================
;; Registry 冲突解决测试
;; ============================================================

(test registry-conflict-first-wins
  "测试 :first-wins 冲突解决策略"
  (let ((provider1 (make-instance 'cl-agent.tools:tool-provider
                                  :name "first"))
        (provider2 (make-instance 'cl-agent.tools:tool-provider
                                  :name "second"))
        (registry (cl-agent.tools:make-tool-registry
                   :conflict-resolution :first-wins)))

    ;; 两个 provider 都有同名工具
    (cl-agent.tools:register-tool
     provider1
     (cl-agent.tools:make-simple-tool :shared "First version"
                                      (lambda () "first")))
    (cl-agent.tools:register-tool
     provider2
     (cl-agent.tools:make-simple-tool :shared "Second version"
                                      (lambda () "second")))

    (cl-agent.tools:add-provider registry provider1)
    (cl-agent.tools:add-provider registry provider2)

    ;; 应该使用第一个 provider 的工具
    (let ((tool (cl-agent.tools:find-tool registry :shared)))
      (is (not (null tool)))
      (is (string= (cl-agent.tools:tool-description tool) "First version")))))

(test registry-conflict-last-wins
  "测试 :last-wins 冲突解决策略"
  (let ((provider1 (make-instance 'cl-agent.tools:tool-provider
                                  :name "first"))
        (provider2 (make-instance 'cl-agent.tools:tool-provider
                                  :name "second"))
        (registry (cl-agent.tools:make-tool-registry
                   :conflict-resolution :last-wins)))

    ;; 两个 provider 都有同名工具
    (cl-agent.tools:register-tool
     provider1
     (cl-agent.tools:make-simple-tool :shared "First version"
                                      (lambda () "first")))
    (cl-agent.tools:register-tool
     provider2
     (cl-agent.tools:make-simple-tool :shared "Second version"
                                      (lambda () "second")))

    (cl-agent.tools:add-provider registry provider1)
    (cl-agent.tools:add-provider registry provider2)

    ;; 应该使用最后一个 provider 的工具
    (let ((tool (cl-agent.tools:find-tool registry :shared)))
      (is (not (null tool)))
      (is (string= (cl-agent.tools:tool-description tool) "Second version")))))

(test registry-conflict-error
  "测试 :error 冲突解决策略"
  (let ((provider1 (make-instance 'cl-agent.tools:tool-provider
                                  :name "first"))
        (provider2 (make-instance 'cl-agent.tools:tool-provider
                                  :name "second"))
        (registry (cl-agent.tools:make-tool-registry
                   :conflict-resolution :error)))

    ;; 两个 provider 都有同名工具
    (cl-agent.tools:register-tool
     provider1
     (cl-agent.tools:make-simple-tool :shared "First version"
                                      (lambda () "first")))
    (cl-agent.tools:register-tool
     provider2
     (cl-agent.tools:make-simple-tool :shared "Second version"
                                      (lambda () "second")))

    (cl-agent.tools:add-provider registry provider1)
    (cl-agent.tools:add-provider registry provider2)

    ;; 应该在重建缓存时报错
    (signals error
      (cl-agent.tools:ensure-cache-valid registry))))

;; ============================================================
;; Registry 工具执行测试
;; ============================================================

(test execute-tool-in-registry
  "测试在 registry 中执行工具"
  (let ((provider (make-instance 'cl-agent.tools:tool-provider
                                 :name "exec-provider"))
        (tool (cl-agent.tools:make-simple-tool
               :multiply
               "Multiply two numbers"
               (lambda (&key x y) (* x y))))
        (registry (cl-agent.tools:make-tool-registry)))

    (cl-agent.tools:register-tool provider tool)
    (cl-agent.tools:add-provider registry provider)

    ;; 使用新的泛型函数 execute-tool
    (let ((result (cl-agent.tools:execute-tool
                   registry :multiply :x 6 :y 7)))
      (is (= result 42)))))

(test execute-nonexistent-tool-in-registry
  "测试在 registry 中执行不存在的工具应该失败"
  (let ((registry (cl-agent.tools:make-tool-registry)))
    (signals error
      (cl-agent.tools:execute-tool registry :nonexistent))))

;; ============================================================
;; Registry 缓存测试
;; ============================================================

(test registry-cache-invalidation
  "测试 registry 缓存失效"
  (let ((provider (make-instance 'cl-agent.tools:tool-provider
                                 :name "cache-test"))
        (registry (cl-agent.tools:make-tool-registry)))

    (cl-agent.tools:add-provider registry provider)

    ;; 触发缓存构建
    (cl-agent.tools:ensure-cache-valid registry)
    (is (cl-agent.tools:registry-cache-valid-p registry))

    ;; 添加新工具应该使缓存失效
    (cl-agent.tools:register-tool
     provider
     (cl-agent.tools:make-simple-tool :new-tool "New" (lambda () nil)))

    ;; 注意：添加工具到 provider 不会自动使 registry 缓存失效
    ;; 需要手动调用 invalidate-cache
    (cl-agent.tools:invalidate-cache registry)
    (is (not (cl-agent.tools:registry-cache-valid-p registry)))))

;; ============================================================
;; 运行 Provider 测试
;; ============================================================

(defun run-tool-provider-tests ()
  "运行所有 Tool Provider 测试"
  (run! 'tool-provider-suite))
