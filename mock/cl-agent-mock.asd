;;;; cl-agent-mock.asd
;;;; CL-Agent Mock 测试系统

(asdf:defsystem #:cl-agent-mock
  :description "CL-Agent Mock 实现（用于测试和开发）"
  :author "David"
  :license "MIT"
  :version "1.0.0"

  :depends-on (#:cl-agent-core
               #:cl-agent-llm
               #:cl-agent-extra)

  :serial t
  :components ((:file "package")
               (:file "llm")
               (:file "tools"))

  :in-order-to ((asdf:test-op (asdf:test-op #:cl-agent-test))))
