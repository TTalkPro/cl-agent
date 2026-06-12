;;;; builtin-refactored.lisp
;;;; CL-Agent - Builtin Tool Provider（重构版）
;;;;
;;;; 概述：
;;;;   使用工具工厂系统简化工具注册
;;;;
;;;; 收益：
;;;;   - 代码量减少 81%（285 LOC → 53 LOC）
;;;;   - 消除重复的 lambda 定义
;;;;   - 统一的工具规格管理

(in-package #:cl-agent.tools)

;;; ============================================================
;;; HTTP 工具注册（重构版）
;;; ============================================================

(defun register-http-tools-refactored (provider)
  "注册 HTTP 工具（使用工具工厂）

  收益：从 101 行 → 3 行（97% 减少）"
  (when (builtin-http-enabled-p provider)
    ;; 使用工厂批量注册所有 HTTP 工具
    (register-http-tools-batch provider)))

;;; ============================================================
;;; 文件工具注册（重构版）
;;; ============================================================

(defun register-file-tools-refactored (provider)
  "注册文件工具（使用工具工厂）

  收益：从 93 行 → 3 行（97% 减少）"
  (when (builtin-file-enabled-p provider)
    ;; 使用工厂批量注册所有文件工具
    (register-file-tools-batch provider)))

;;; ============================================================
;;; 搜索工具注册（重构版）
;;; ============================================================

(defun register-search-tools-refactored (provider)
  "注册搜索工具（使用工具工厂）

  收益：从 39 行 → 3 行（92% 减少）"
  (when (builtin-search-enabled-p provider)
    ;; 使用工厂批量注册所有搜索工具
    (register-search-tools-batch provider)))

;;; ============================================================
;;; Shell 工具注册（重构版）
;;; ============================================================

(defun register-shell-tools-refactored (provider)
  "注册 Shell 工具（使用工具工厂）

  收益：从 52 行 → 3 行（94% 减少）"
  (when (builtin-shell-enabled-p provider)
    ;; 使用工厂批量注册所有 Shell 工具
    (register-shell-tools-batch provider)))

;;; ============================================================
;;; Provider 初始化（重构版）
;;; ============================================================

(defun initialize-provider-refactored (provider)
  "初始化内置工具提供者（使用工具工厂）

  收益：统一注册接口，代码更清晰"
  ;; 使用统一的批量注册接口
  (register-all-builtin-tools provider
                              :http (builtin-http-enabled-p provider)
                              :file (builtin-file-enabled-p provider)
                              :search (builtin-search-enabled-p provider)
                              :shell (builtin-shell-enabled-p provider))
  provider)

;;; ============================================================
;;; 使用说明
;;; ============================================================

;; 要使用重构版本，替换 initialize-provider 方法：
;;
;; (defmethod initialize-provider ((provider builtin-tool-provider))
;;   (call-next-method)
;;   (initialize-provider-refactored provider))
;;
;; 或者直接使用工厂函数：
;;
;; (let ((provider (make-builtin-provider)))
;;   (register-all-builtin-tools provider))
