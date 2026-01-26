;;;; package.lisp
;;;; CL-Agent - 统一包定义
;;;;
;;;; 概述：
;;;;   定义 CL-Agent 框架的所有包结构。
;;;;   采用分层架构，每层负责特定功能。
;;;;
;;;; 架构：
;;;;   Kernel 层：kernel, kernel-function, kernel-plugin, filter, invoke-kernel
;;;;   LLM 层：provider 基类和具体实现
;;;;   Core 层：条件系统、工具函数、HTTP 客户端
;;;;   Memory 层：Store + Checkpointer

;;; ============================================================
;;; 核心基础设施包
;;; ============================================================

(defpackage :cl-agent.core
  (:use :cl)
  (:nicknames :cla.core :core)
  (:export
   ;; 条件系统
   #:cl-agent-error
   #:api-error
   #:llm-error
   #:tool-error
   #:config-error
   #:validation-error
   #:signal-error

   ;; 工具函数
   #:get-env
   #:generate-uuid
   #:timestamp-now
   #:alist-get
   #:plist-get
   #:json-parse
   #:json-stringify

   ;; 实用宏
   #:when-let
   #:if-let
   #:with-timing
   #:with-retry
   #:->
   #:->>))

;;; ============================================================
;;; LLM 服务包
;;; ============================================================

(defpackage :cl-agent.llm
  (:use :cl)
  (:nicknames :cla.llm :llm)
  (:export
   ;; 客户端
   #:client
   #:make-client
   #:client-provider
   #:client-model
   #:client-api-key

   ;; 提供商
   #:provider
   #:make-anthropic-provider
   #:make-openai-provider
   #:make-ollama-provider
   #:make-zhipu-provider
   #:provider-name
   #:provider-model

   ;; API
   #:chat
   #:chat-stream
   #:count-tokens
   #:embed
   #:llm-chat

   ;; 配置
   #:*default-anthropic-model*
   #:*default-openai-model*
   #:*anthropic-api-url*
   #:*openai-api-url*))

;;; ============================================================
;;; 工具包
;;; ============================================================

(defpackage :cl-agent.tools
  (:use :cl)
  (:nicknames :cla.tools :tools)
  (:export
   ;; 工具定义
   #:tool
   #:make-tool
   #:tool-name
   #:tool-description
   #:tool-parameters
   #:tool-fn

   ;; 工具注册
   #:define-tool
   #:register-tool
   #:get-tool
   #:list-tools

   ;; 工具执行
   #:execute-tool
   #:execute-tool-calls

   ;; 工具格式
   #:tool-to-llm-format
   #:tools-to-llm-format

   ;; 内置工具
   #:web-search
   #:shell-command
   #:file-read
   #:file-write
   #:http-request

   ;; 搜索配置
   #:*search-provider*
   #:*tavily-api-key*
   #:*serpapi-api-key*

   ;; Shell 配置
   #:*shell-enabled*
   #:*shell-timeout*
   #:*safe-shell-mode*))

;;; ============================================================
;;; 记忆包
;;; ============================================================

(defpackage :cl-agent.memory
  (:use :cl)
  (:nicknames :cla.memory :memory)
  (:export
   ;; 记忆
   #:memory
   #:make-memory
   #:memory-id
   #:memory-messages
   #:memory-context

   ;; 消息操作
   #:add-message
   #:add-user-message
   #:add-assistant-message
   #:add-tool-message
   #:get-messages
   #:get-last-n-messages
   #:clear-messages

   ;; 上下文操作
   #:get-context
   #:set-context
   #:update-context

   ;; 系统提示
   #:set-system-prompt
   #:get-system-prompt

   ;; 持久化
   #:save-to-file
   #:load-from-file

   ;; 增强记忆
   #:enhanced-memory
   #:make-enhanced-memory
   #:em-add-message
   #:em-recall
   #:em-archive

   ;; 会话管理
   #:session-manager
   #:make-session-manager
   #:sm-create-session
   #:sm-get-session
   #:sm-list-sessions
   #:sm-delete-session))

;;; ============================================================
;;; 检查点包
;;; ============================================================

(defpackage :cl-agent.checkpoint
  (:use :cl)
  (:nicknames :cla.checkpoint :checkpoint)
  (:export
   ;; 检查点
   #:checkpoint
   #:make-checkpoint
   #:checkpoint-id
   #:checkpoint-thread-id
   #:checkpoint-state
   #:checkpoint-metadata
   #:checkpoint-timestamp

   ;; 检查点存储
   #:checkpoint-store
   #:make-memory-store
   #:make-filesystem-store

   ;; 存储 API
   #:save-checkpoint
   #:load-checkpoint
   #:delete-checkpoint
   #:list-checkpoints
   #:get-latest-checkpoint

   ;; 时间旅行
   #:create-branch
   #:load-branch
   #:compare-states
   #:with-time-travel

   ;; 全局配置
   #:*checkpoint-store*))

;;; ============================================================
;;; RAG 包
;;; ============================================================

(defpackage :cl-agent.rag
  (:use :cl)
  (:nicknames :cla.rag :rag)
  (:export
   ;; 嵌入
   #:embedding-client
   #:make-embedding-client
   #:embed-text
   #:embed-texts

   ;; 向量操作
   #:cosine-similarity
   #:euclidean-distance
   #:vector-normalize

   ;; 文本分块
   #:chunk-text
   #:chunk-by-sentences
   #:chunk-by-paragraphs

   ;; 向量存储
   #:vector-store
   #:make-vector-store
   #:vector-store-add-document
   #:vector-store-search
   #:vector-store-get-document
   #:vector-store-count
   #:vector-store-clear
   #:add-document
   #:search-documents

   ;; 文档
   #:document
   #:make-document
   #:document-id
   #:document-content
   #:document-metadata
   #:document-embedding

   ;; RAG 管道
   #:rag-pipeline
   #:make-rag-pipeline
   #:rag-retrieve
   #:rag-query
   #:rag-chat

   ;; 便捷函数
   #:setup-rag
   #:quick-rag
   #:index-file
   #:index-directory))

;;; ============================================================
;;; 协议包
;;; ============================================================

(defpackage :cl-agent.protocols
  (:use :cl :cl-agent.core)
  (:nicknames :cla.protocols :protocols)
  (:export
   ;; MCP
   #:mcp-message
   #:make-mcp-message
   #:mcp-client
   #:make-mcp-client
   #:mcp-client-connect
   #:mcp-client-call-tool
   #:mcp-server
   #:make-mcp-server
   #:mcp-server-start
   #:mcp-server-stop
   #:mcp-register-tool
   #:mcp-register-resource
   #:mcp-connect
   #:mcp-call-tool

   ;; A2A
   #:a2a-message
   #:make-a2a-message-bus
   #:a2a-send-message
   #:a2a-publish-event
   #:a2a-listen
   #:a2a-register-service
   #:a2a-discover-services))

;;; ============================================================
;;; 主包
;;; ============================================================

(defpackage :cl-agent
  (:use :cl
        :cl-agent.core
        :cl-agent.llm
        :cl-agent.tools
        :cl-agent.memory
        :cl-agent.checkpoint
        :cl-agent.rag
        :cl-agent.protocols)
  (:nicknames :cla)
  (:export
   ;; ==================== 核心工具 ====================
   #:get-env
   #:generate-uuid
   #:timestamp-now
   #:json-parse
   #:json-stringify
   #:when-let
   #:if-let
   #:with-timing
   #:->
   #:->>

   ;; ==================== LLM ====================
   #:make-client
   #:chat
   #:chat-stream
   #:count-tokens
   #:embed

   ;; ==================== 工具 ====================
   #:define-tool
   #:execute-tool
   #:web-search
   #:shell-command
   #:file-read
   #:file-write
   #:http-request

   ;; ==================== 记忆 ====================
   #:make-memory
   #:add-message
   #:get-messages
   #:make-enhanced-memory
   #:em-recall
   #:make-session-manager

   ;; ==================== 检查点 ====================
   #:make-checkpoint
   #:save-checkpoint
   #:load-checkpoint
   #:create-branch
   #:with-time-travel

   ;; ==================== RAG ====================
   #:make-embedding-client
   #:embed-text
   #:make-rag-pipeline
   #:rag-query
   #:setup-rag
   #:index-file

   ;; ==================== 协议 ====================
   #:make-mcp-server
   #:mcp-server-start
   #:make-mcp-client
   #:mcp-client-connect
   #:mcp-call-tool
   #:mcp-register-tool
   #:make-a2a-message-bus
   #:a2a-send-message
   #:a2a-publish-event
   #:a2a-listen
   #:a2a-register-service
   #:a2a-discover-services))
