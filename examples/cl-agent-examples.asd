;;;; cl-agent-examples.asd
;;;; CL-Agent Examples - 使用示例和演示
;;;;
;;;; Version: 1.0.0
;;;; Author: David
;;;;
;;;; Overview:
;;;;   CL-Agent 的使用示例和演示代码
;;;;
;;;; Contains:
;;;;   - 依赖注入框架示例
;;;;   - 记忆管理示例（TODO）
;;;;   - 工具使用示例（TODO）
;;;;   - 完整 Agent 应用示例（TODO）

(asdf:defsystem #:cl-agent-examples
  :description "CL-Agent Examples - Usage Examples and Demos"
  :author "David"
  :license "MIT"
  :version "1.0.0"

  :depends-on (#:cl-agent-core)

  :serial t
  :components ((:file "di-usage-examples")))
