;;;; cl-agent-tools.asd
;;;; CL-Agent 工具系统

(asdf:defsystem #:cl-agent-tools
  :description "CL-Agent 工具系统"
  :author "David"
  :license "MIT"
  :version "1.0.0"

  :depends-on (#:cl-agent-core      ; 包含 cl-agent.http, dexador, quri
               #:quri)              ; 保留用于域名检查

  :serial t
  :components (;; 包定义
               (:file "package")

               ;; Provider 系统核心 (Phase 1)
               (:file "protocol")
               (:file "registry")

               ;; 工具核心
               (:file "core")
               ;; 工具宏（重构基础设施）
               (:file "macros")
               ;; 工具工厂（新增）
               (:file "tool-factories")
               ;; 工具实现
               (:file "search")
               (:file "shell")
               (:file "file")
               (:file "http")

               ;; Provider 实现
               (:file "providers/builtin")      ; Phase 2 ✅ 已实现
               ;; (:file "providers/mcp")      ; Phase 3 - 跳过（应在独立项目中）
               (:file "providers/custom")       ; Phase 4 ✅ 已实现
               )

  :in-order-to ((asdf:test-op (asdf:test-op #:cl-agent-test))))
