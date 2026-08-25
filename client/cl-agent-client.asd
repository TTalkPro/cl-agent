;;;; cl-agent-client.asd
;;;; CL-Agent Client - SimpleAgent（面向应用的易用层）
;;;;
;;;; Version: 11.0.0
;;;;
;;;; 三模块分层（对标 clj-agent 的 core / provider / client）：
;;;;   cl-agent-core    框架本体：基础设施 + HTTP + Chat API + ChatClient/Filter
;;;;   cl-agent-llm     提供商适配器（独立可插拔）
;;;;   cl-agent-client  Agent 运行时 ← 本模块
;;;;
;;;; 本模块只依赖 core（不依赖 llm）——provider 由调用方注入。

(asdf:defsystem #:cl-agent-client
  :description "CL-Agent Client - SimpleAgent（有状态对话 + callbacks + 错误归一化）"
  :author "David"
  :license "MIT"
  :version "11.0.0"

  :depends-on (#:cl-agent-core)

  :serial t
  :components ((:file "package")
               (:file "agent")))
