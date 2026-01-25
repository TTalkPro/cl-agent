;;;; macros.lisp
;;;; CL-Agent Core Kernel - 工具定义宏
;;;;
;;;; 概述：
;;;;   提供 deftool 和 defplugin 宏，用于声明式定义工具函数和插件。
;;;;   deftool 展开为 defun + symbol plist 元数据。
;;;;   defplugin 展开为 symbol plist 元数据。

(in-package #:cl-agent.kernel)

;;; ============================================================
;;; deftool 宏
;;; ============================================================

(defmacro deftool (name description params &body body-and-options)
  "定义工具函数

参数:
  NAME        - 函数名称（符号）
  DESCRIPTION - 函数描述字符串
  PARAMS      - 参数规格列表
    格式: ((param-name type description &key required-p default) ...)
  BODY        - 函数体

选项（可在 body 之前以 plist 形式指定）:
  (:sensitive t)   - 标记为敏感操作
  (:category :xxx) - 设置分类

展开为:
  1. defun NAME (&key param1 param2 ...)
  2. 在符号 NAME 上设置 plist 元数据

示例:
  (deftool get-weather \"获取天气\"
    ((city :string \"城市名称\" :required-p t)
     (unit :string \"温度单位\" :default \"celsius\"))
    (format nil \"~A：晴，22°~A\" city unit))

  ;; 带选项:
  (deftool delete-file \"删除文件\"
    ((path :string \"文件路径\" :required-p t))
    (:sensitive t :category :file)
    (delete-file path))"
  (let* ((options (when (and (consp (first body-and-options))
                             (keywordp (first (first body-and-options))))
                   (first body-and-options)))
         (body (if options (rest body-and-options) body-and-options))
         (category (getf options :category :general))
         (sensitive (getf options :sensitive))
         (lambda-keys (mapcar (lambda (p)
                                (destructuring-bind (pname ptype pdesc &key required-p default) p
                                  (declare (ignore ptype pdesc required-p))
                                  (if default (list pname default) pname)))
                              params))
         (tool-name-kw (intern (symbol-name name) :keyword)))
    `(progn
       (defun ,name (&key ,@lambda-keys)
         ,@body)
       (setf (get ',name :kernel-function) t
             (get ',name :description) ,description
             (get ',name :parameters) ',params
             (get ',name :tool-name) ,tool-name-kw
             (get ',name :category) ,category
             (get ',name :sensitive) ,sensitive)
       ',name)))

;;; ============================================================
;;; defplugin 宏
;;; ============================================================

(defmacro defplugin (name description &body tool-symbols)
  "定义插件（工具分组）

参数:
  NAME         - 插件名称（符号）
  DESCRIPTION  - 插件描述
  TOOL-SYMBOLS - 工具函数符号列表

展开为:
  在符号 NAME 上设置 plist 元数据

示例:
  (defplugin weather-plugin \"天气工具集\"
    get-weather
    get-forecast)"
  `(progn
     (setf (get ',name :plugin) t
           (get ',name :description) ,description
           (get ',name :tools) '(,@tool-symbols))
     ',name))
