;;;; package.lisp
;;;; CL-Agent Mock - 包定义

(defpackage :cl-agent/mock
  (:use :common-lisp)
  (:import-from #:cl-agent/core #:llm-chat)
  (:documentation "Mock LLM provider（测试/离线开发用）。

实现 cl-agent/core 的 llm-chat SPI，返回真 llm-response——
经 provider-chat-model 适配后与任何真实 provider 等价可换。

历史：曾有 tools.lisp（mock-tool 类 + define-mock-tool 宏 + 4 个
工具工厂）。那套体系早于 deftool 架构——mock-tool 不是
tool-callback，进不了 (:tools ...)，全库唯一消费者是一个从未列进
asd、括号都不平衡的化石测试文件。已整体删除；mock 工具直接用
deftool 定义即可。还曾导出 *default-mock-responses*——它没有定义，
纯装饰性导出。")
  (:export
   ;; Mock LLM
   #:make-mock-llm
   #:make-quick-mock
   #:create-predefined-mock
   #:mock-llm-provider
   #:mock-response-delay
   #:mock-error-rate
   #:mock-responses))
