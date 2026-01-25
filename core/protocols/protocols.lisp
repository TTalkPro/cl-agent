;;;; protocols.lisp
;;;; CL-Agent Core - 统一协议定义
;;;;
;;;; 概述：
;;;;   定义所有核心协议接口

(defpackage #:cl-agent.core.protocols
  (:use #:common-lisp)
  (:import-from #:uuid #:make-v4-uuid)
  (:import-from #:local-time #:timestamp-to-unix #:now)
  (:nicknames #:cla.core.protocols #:protocols)
  (:export
   ;; === ID 生成器协议 ===
   #:make-standard-id-generator

   ;; === 时间戳提供者协议 ===
   #:make-standard-timestamp-provider

   ;; === 状态协议 ===
   #:state-p
   #:make-state
   #:state-get
   #:state-set
   #:state-update
   #:state-merge
   #:state-copy
   #:state-to-plist

   ;; === 执行器协议 ===
   #:run-workflow
   #:run-workflow-stream))

(in-package :cl-agent.core.protocols)

;;; ============================================================
;;; ID 生成器协议
;;; ============================================================

(declaim (ftype (function () function) make-standard-id-generator))

(defun make-standard-id-generator ()
  "创建标准 ID 生成器（使用 UUID）

  返回一个无参数的函数，调用时返回唯一 ID 字符串。

  返回：
    ID 生成器函数（无参数）-> 字符串

  示例：
    (defparameter *id-gen* (make-standard-id-generator))
    (funcall *id-gen*)  ; => \"550e8400-e29b-41d4-a716-446655440000\"

  说明：
    - 使用 UUID v4 算法
    - 保证全局唯一性
    - 适合分布式系统"
  (lambda ()
    (make-v4-uuid)))

;;; ============================================================
;;; 时间戳提供者协议
;;; ============================================================

(declaim (ftype (function () function) make-standard-timestamp-provider))

(defun make-standard-timestamp-provider ()
  "创建标准时间戳提供者（使用 Unix 时间戳）

  返回一个无参数的函数，调用时返回当前 Unix 时间戳。

  返回：
    时间戳提供者函数（无参数）-> 整数（Unix 时间戳）

  示例：
    (defparameter *ts-provider* (make-standard-timestamp-provider))
    (funcall *ts-provider*)  ; => 1704067200 (2024-01-01 00:00:00 UTC)

  说明：
    - Unix 时间戳：从 1970-01-01 00:00:00 UTC 起的秒数
    - 使用整数存储，便于序列化和比较
    - 时区无关，适合分布式系统"
  (lambda ()
    (timestamp-to-unix (now))))

;;; ============================================================
;;; 状态和执行器协议占位符
;;; ============================================================
;;; 完整实现在 graph/state.lisp 和 graph/executor.lisp 中
;;; 这里只导出符号以保持接口一致性
