;;;; package-http.lisp
;;;; CL-Agent - HTTP 客户端包定义
;;;;
;;;; 概述：
;;;;   提供统一的 HTTP 客户端抽象层，支持同步和异步请求
;;;;
;;;; 设计目标：
;;;;   - 封装底层 HTTP 库（Dexador）
;;;;   - 提供简洁的同步 API
;;;;   - 支持基于 lparallel 的异步请求
;;;;   - 内置重试策略
;;;;   - SSE（Server-Sent Events）流式支持
;;;;
;;;; 依赖：
;;;;   - dexador: HTTP 客户端
;;;;   - lparallel: 并行计算（异步支持）
;;;;   - flexi-streams: 流处理

(defpackage #:cl-agent.http
  (:use #:common-lisp)
  (:nicknames #:cla.http #:http)
  (:export
   ;; ==================== 同步 API ====================
   ;; 核心请求函数
   #:http-request
   #:http-get
   #:http-post
   #:http-put
   #:http-delete
   #:http-patch
   #:http-head

   ;; ==================== 异步 API ====================
   ;; 异步请求
   #:http-request-async
   #:http-get-async
   #:http-post-async

   ;; 并行请求
   #:http-parallel
   #:http-parallel-map

   ;; Future 操作
   #:http-future
   #:http-future-p
   #:http-future-done-p
   #:http-future-value
   #:http-future-wait
   #:http-future-cancel

   ;; ==================== 流式 API ====================
   ;; SSE 流式请求
   #:http-stream
   #:http-stream-sse

   ;; 流式上下文
   #:stream-context
   #:make-stream-context
   #:stream-context-buffer
   #:stream-context-callback
   #:stream-context-stop-p

   ;; ==================== 重试策略 ====================
   ;; 重试配置
   #:retry-config
   #:make-retry-config
   #:retry-config-max-retries
   #:retry-config-delay
   #:retry-config-backoff
   #:retry-config-retry-on

   ;; 重试执行
   #:with-retry
   #:http-request-with-retry

   ;; ==================== 响应处理 ====================
   ;; 响应结构
   #:http-response
   #:make-http-response
   #:http-response-status
   #:http-response-headers
   #:http-response-body
   #:http-response-uri

   ;; 响应谓词
   #:http-success-p
   #:http-client-error-p
   #:http-server-error-p

   ;; ==================== 条件系统 ====================
   ;; HTTP 错误
   #:http-error
   #:http-error-status
   #:http-error-body
   #:http-error-uri

   #:http-client-error
   #:http-server-error
   #:http-timeout-error
   #:http-connection-error

   ;; ==================== 配置 ====================
   ;; 全局配置
   #:*default-timeout*
   #:*default-retry-config*
   #:*http-user-agent*

   ;; 线程池
   #:*http-thread-pool*
   #:initialize-http-thread-pool
   #:shutdown-http-thread-pool

   ;; ==================== 工具函数 ====================
   #:build-url
   #:encode-query-params
   #:parse-content-type
   #:json-body))
