;;;; package.lisp
;;;; CL-Agent - 工具系统包定义
;;;;
;;;; 概述：
;;;;   定义工具系统相关的包
;;;;
;;;; 包结构：
;;;;   - cl-agent.tools: 工具核心
;;;;   - cl-agent.tools.search: 搜索工具
;;;;   - cl-agent.tools.shell: Shell 工具
;;;;   - cl-agent.tools.file: 文件工具
;;;;   - cl-agent.tools.http: HTTP 工具
;;;;
;;;; 使用说明：
;;;;   推荐使用泛型函数接口（适用于所有 provider）：
;;;;     (find-tool provider tool-name)
;;;;     (register-tool provider tool)
;;;;     (execute-tool provider tool-name &rest args)
;;;;     (list-tools provider &key category)
;;;;
;;;;   tool-registry 继承自 tool-provider，支持：
;;;;     1. 直接注册工具（最高优先级）
;;;;     2. 管理多个子 provider
;;;;     3. 工具缓存和冲突解决
;;;;

;;; ============================================================
;;; 工具核心包
;;; ============================================================

(defpackage #:cl-agent.tools
  (:use #:common-lisp
        #:cl-agent.core)
  (:nicknames #:cla.tools #:tools)
  (:export
   ;; ==================== 工具结构 ====================
   #:tool
   #:make-tool
   #:tool-name
   #:tool-description
   #:tool-handler
   #:tool-parameters
   #:tool-category
   #:tool-permissions
   #:tool-metadata

   ;; ==================== 工具注册 ====================
   ;; 注意：不再导出全局变量
   ;; 每个 agent 实例应创建自己的 tool-registry

   ;; ==================== 工具验证 ====================
   #:normalize-parameters
   #:validate-arguments
   #:flatten-arguments
   #:arguments-to-plist
   #:validate-argument-type
   #:find-parameter-spec

   ;; ==================== 工具查询 ====================
   ;; 使用泛型函数接口:
   ;;   - (find-tool registry tool-name)
   ;;   - (list-tools registry)

   ;; ==================== 工具信息 ====================
   #:tool-info
   #:print-tool-info
   #:describe-tools

   ;; ==================== 权限控制 ====================
   ;; Registry 权限访问器
   #:registry-permissions-enabled-p
   #:registry-allowed-permissions
   #:registry-verbose-p
   ;; 权限函数（现在接受 registry 参数）
   #:check-permissions
   #:permission-allowed-p
   #:grant-permission
   #:revoke-permission

   ;; ==================== 工具序列化 ====================
   #:tool-to-plist
   #:tool-from-plist
   #:tool-to-json-schema
   #:parameter-to-json-schema

   ;; ==================== 工具宏（重构基础设施）====================
   #:with-file-operations
   #:with-file-validation
   #:define-file-tool
   #:define-file-tools
   #:fn-pipeline

   ;; ==================== Provider System (New) ====================
   ;; Provider 类和协议
   #:tool-provider
   #:provider-name
   #:provider-enabled-p
   #:provider-tools
   #:provider-metadata
   #:provider-tool-count
   #:provider-tool-names

   ;; Provider 生命周期
   #:initialize-provider
   #:shutdown-provider
   #:enable-provider
   #:disable-provider

   ;; Provider 协议泛型函数（推荐使用）
   ;; 这些函数同时适用于 tool-provider 和 tool-registry
   #:find-tool         ; 查找工具
   #:register-tool     ; 注册工具
   #:unregister-tool   ; 注销工具
   #:list-tools        ; 列出所有工具
   #:execute-tool      ; 执行工具
   #:validate-tool-call ; 验证工具调用

   ;; Tool Registry 类
   #:tool-registry
   #:registry-providers
   #:registry-tool-cache
   #:registry-conflict-resolution
   #:registry-cache-valid-p

   ;; Registry 构造和管理
   #:make-tool-registry
   #:add-provider
   #:remove-provider
   #:find-provider
   #:list-providers

   ;; Registry 缓存管理
   #:invalidate-cache
   #:rebuild-tool-cache
   #:ensure-cache-valid

   ;; Registry 工具查找
   #:list-all-tools
   #:tool-exists-p

   ;; Registry 统计信息
   #:registry-tool-count
   #:registry-provider-count
   #:print-registry-info

   ;; 辅助函数
   #:make-simple-tool

   ;; ==================== 工具工厂系统（新增）====================
   #:make-tool-wrapper
   #:register-tools-batch
   #:make-http-param-specs
   #:make-http-tool-spec
   #:make-all-http-tool-specs
   #:register-http-tools-batch
   #:make-file-tool-specs
   #:register-file-tools-batch
   #:make-search-tool-specs
   #:register-search-tools-batch
   #:make-shell-tool-specs
   #:register-shell-tools-batch
   #:register-all-builtin-tools))

;;; ============================================================
;;; 搜索工具包
;;; ============================================================

(defpackage #:cl-agent.tools.search
  (:use #:common-lisp
        #:cl-agent.core
        #:cl-agent.tools)
  (:nicknames #:cla.tools.search)
  (:export
   ;; 注意：web-search 等函数已在 cl-agent.tools 包中定义
   ;; 这里只导出专用的搜索结果结构
   #:search-result
   #:search-result-title
   #:search-result-url
   #:search-result-snippet))

;;; ============================================================
;;; Shell 工具包
;;; ============================================================

(defpackage #:cl-agent.tools.shell
  (:use #:common-lisp
        #:cl-agent.core
        #:cl-agent.tools)
  (:nicknames #:cla.tools.shell)
  (:export
   #:make-shell-tool
   #:execute-shell-command
   #:shell-result
   #:shell-result-exit-code
   #:shell-result-stdout
   #:shell-result-stderr
   #:shell-result-success-p))

;;; ============================================================
;;; 文件工具包
;;; ============================================================

(defpackage #:cl-agent.tools.file
  (:use #:common-lisp
        #:cl-agent.core
        #:cl-agent.tools)
  (:nicknames #:cla.tools.file)
  (:export
   #:make-file-tool
   #:read-file
   #:write-file
   #:file-exists-p
   #:list-directory
   #:file-info
   #:file-info-path
   #:file-info-size
   #:file-info-modified-time))

;;; ============================================================
;;; HTTP 工具包
;;; ============================================================

(defpackage #:cl-agent.tools.http
  (:use #:common-lisp
        #:cl-agent.core
        #:cl-agent.tools)
  (:nicknames #:cla.tools.http)
  (:export
   #:make-http-tool
   #:http-get
   #:http-post
   #:http-put
   #:http-delete
   #:http-request
   #:http-response
   #:http-response-status
   #:http-response-headers
   #:http-response-body
   #:http-response-success-p))
