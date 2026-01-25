;;;; zhipu-anthropic-test.lisp
;;;; 测试智谱 AI Anthropic 兼容端点

(asdf:load-system :cl-agent)
(in-package :cl-user)
(use-package :cl-agent)

;; 设置环境变量
(setf (uiop:getenv "ZHIPU_API_KEY") "your-api-key-here")

;; 方式1：使用 Anthropic provider（可能有问题）
;; 智谱的 Anthropic 兼容端点可能需要不同的认证方式
(defparameter *client-v1*
  (cl-agent.llm:make-client
   :provider :anthropic
   :model "glm-4-flash"
   :api-key (cl-agent.core:get-env "ZHIPU_API_KEY")
   :base-url "https://open.bigmodel.cn/api/anthropic/v1"))

;; 方式2：使用智谱 provider（推荐）
(defparameter *client-zhipu*
  (cl-agent.llm:make-client
   :provider :zhipu
   :model "glm-4-flash"
   :api-key (cl-agent.core:get-env "ZHIPU_API_KEY"))

;; 测试函数
(defun test-zhipu-anthropic-v1 ()
  "测试智谱 Anthropic v1 兼容端点"
  (format t "~%=== Testing Zhipu Anthropic v1 ===~%")
  (handler-case
      (let ((response (cl-agent.llm:chat-simple *client-v1* "你好")))
        (format t "Response: ~A~%" response))
    (error (e)
      (format t "Error: ~A~%" e))))

(defun test-zhipu-native ()
  "测试智谱原生端点（推荐）"
  (format t "~%=== Testing Zhipu Native Endpoint ===~%")
  (handler-case
      (let ((response (cl-agent.llm:chat-simple *client-zhipu* "你好")))
        (format t "Response: ~A~%" response))
    (error (e)
      (format t "Error: ~A~%" e))))

;; 创建 Agent 的示例
(defun create-agent-with-zhipu ()
  "创建使用智谱的 Agent"
  (format t "~%=== Creating Agent with Zhipu ===~%")

  ;; 使用智谱原生端点（推荐）
  (let* ((client (cl-agent.llm:make-client
                     :provider :zhipu
                     :model "glm-4-flash"
                     :api-key (cl-agent.core:get-env "ZHIPU_API_KEY")))
         (memory (cl-agent.memory:make-agent-memory
                  :context-store (cl-agent.memory:make-memory-store-backend)
                  :persistent-store (cl-agent.memory:make-sqlite-store-backend
                                             :db-path "/tmp/agent-memory.db")
                  :auto-archive t))
         (agent (cl-agent.simpleagent:create-agent
                 :model client
                 :prompt "You are a helpful assistant."
                 :checkpointer memory
                 :name "zhipu-agent")))

    ;; 测试 Agent
    (let ((result (cl-agent.simpleagent:agent-run agent "你好，请介绍一下自己" :verbose t)))
      (format t "~%Agent response: ~A~%" result))
    agent))

;; 运行测试
(defun run-zhipu-tests ()
  "运行所有测试"
  (test-zhipu-native)  ; 先测试原生端点
  (test-zhipu-anthropic-v1)  ; 再测试兼容端点
  (create-agent-with-zhipu))
