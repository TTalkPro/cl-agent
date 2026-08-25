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
;;;;   - di-usage-examples.lisp     依赖注入容器示例（asd 组件）
;;;;   - chat-client-usage.lisp          ChatClient + Filter 完整用法（独立脚本，
;;;;                                sbcl --load examples/chat-client-usage.lisp）

(asdf:defsystem #:cl-agent-examples
  :description "CL-Agent Examples - Usage Examples and Demos"
  :author "David"
  :license "MIT"
  :version "1.0.0"

  :depends-on (#:cl-agent-core)

  :serial t
  :components ((:file "di-usage-examples")))
