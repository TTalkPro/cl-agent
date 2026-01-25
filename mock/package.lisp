;;;; package.lisp
;;;; CL-Agent - Mock 模块包定义

(defpackage :cl-agent.mock
  (:use :common-lisp)
  (:import-from #:cl-agent.kernel #:llm-chat)
  (:nicknames :mock)
  (:export
   ;; Mock LLM
   #:make-mock-llm
   #:make-quick-mock
   #:create-predefined-mock
   #:mock-llm-provider

   ;; Mock Tools
   #:make-calculator-tool
   #:make-search-tool
   #:make-file-tool
   #:make-database-tool
   #:make-mock-toolkit
   #:mock-tool

   ;; 辅助函数
   #:generate-mock-response
   #:safe-evaluate-expression

   ;; 预定义场景
   #:*default-mock-responses*))
