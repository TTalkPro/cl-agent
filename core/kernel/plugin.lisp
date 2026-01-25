;;;; plugin.lisp
;;;; CL-Agent Core Kernel - Plugin（Symbol Plist 方案）
;;;;
;;;; 概述：
;;;;   Plugin 的元数据附加在符号属性表上。
;;;;   Plugin 是一组工具符号的逻辑分组。
;;;;
;;;; Symbol Plist 约定：
;;;;   :plugin      → T               ;; 标记为插件
;;;;   :description → "插件描述"       ;; 插件描述
;;;;   :tools       → (sym1 sym2 ...) ;; 工具符号列表

(in-package #:cl-agent.kernel)

;;; ============================================================
;;; 运行时注册 API
;;; ============================================================

(defun declare-plugin (name description tool-symbols)
  "运行时声明插件（无宏替代）

参数:
  NAME         - 插件符号
  DESCRIPTION  - 插件描述
  TOOL-SYMBOLS - 工具符号列表

返回:
  NAME 符号"
  (setf (get name :plugin) t
        (get name :description) description
        (get name :tools) tool-symbols)
  name)

;;; ============================================================
;;; 查询 API
;;; ============================================================

(defun plugin-p (symbol)
  "检查符号是否标注为 plugin"
  (get symbol :plugin))

(defun plugin-tool-symbols (plugin-sym)
  "获取插件的工具符号列表"
  (get plugin-sym :tools))

(defmethod cl-agent.core:plugin-description ((plugin-sym symbol))
  "获取插件描述 (for symbol-plist plugins)"
  (get plugin-sym :description))

(defun plugin-get-schemas (plugin-sym)
  "获取插件中所有工具的 Schema 列表

参数:
  PLUGIN-SYM - 插件符号

返回:
  Schema 列表，每个元素为:
  (:name \"tool-name\" :description \"...\" :input-schema hash-table)"
  (loop for tool-sym in (plugin-tool-symbols plugin-sym)
        when (tool-function-p tool-sym)
        collect (list :name (string-downcase
                             (symbol-name
                              (get tool-sym :tool-name)))
                      :description (tool-description tool-sym)
                      :input-schema (tool-schema tool-sym))))

