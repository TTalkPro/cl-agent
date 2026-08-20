;;;; macros.lisp
;;;; CL-Agent - 实用宏 + 日志系统
;;;;
;;;; 历史：本文件曾是 20+ 个工具宏的杂物抽屉——when-let* / if-let /
;;;; unless-let / awhen / aif / -> / ->> / as-> / with-timing /
;;;; with-temp-file / do-alist / do-plist / collect-if / result-let /
;;;; ok-or / check-type-or-nil / with-validated-args / assert-not-nil /
;;;; with-log-context / log-and-return / with-logging / defconfig /
;;;; define-cached-function。全库统计：除 when-let（3 处）外**全部零使用**，
;;;; 且藏着三个坏例——anaphoric 宏（awhen/aif）隐藏 it 绑定，Google CL
;;;; Style 明确不建议；defconfig 生成**无耳罩**的特殊变量还在 load 时调
;;;; export（导出应只发生在 defpackage）；with-timing 引用不存在的
;;;; log:info 包（从没编译展开过所以没暴露）。已全部删除——需要 Clojure
;;;; 式线程宏或更多绑定宏时用 alexandria / arrows 这类专门库，框架不自造。

(in-package :cl-agent/core)

;;; ============================================================
;;; 绑定宏
;;; ============================================================

(defmacro when-let ((var value) &body body)
  "VALUE 非 nil 时把它绑定到 VAR 并执行 BODY（等价 alexandria:when-let）。"
  `(let ((,var ,value))
     (when ,var
       ,@body)))

;;; ============================================================
;;; 日志系统（零依赖的最小实现）
;;; ============================================================

(defvar *log-level* :info
  "当前日志级别（:debug :info :warn :error :off）。")

(defvar *log-stream* *standard-output*
  "日志输出流。")

(defvar *log-timestamp-format* t
  "是否在日志行首包含时间戳。")

(defparameter *log-level-priority*
  '((:debug . 0)
    (:info . 1)
    (:warn . 2)
    (:error . 3)
    (:off . 100))
  "日志级别 → 优先级。")

(defun log-level-priority (level)
  "取 LEVEL 的优先级，未知级别按 :info。"
  (or (cdr (assoc level *log-level-priority*))
      1))

(defun log-enabled-p (level)
  "LEVEL 级别的日志当前是否输出。"
  (>= (log-level-priority level)
      (log-level-priority *log-level*)))

(defun format-log-timestamp ()
  "格式化当前时间为 YYYY-MM-DD HH:MM:SS。"
  (multiple-value-bind (sec min hour day month year)
      (get-decoded-time)
    (format nil "~4,'0D-~2,'0D-~2,'0D ~2,'0D:~2,'0D:~2,'0D"
            year month day hour min sec)))

(defun log-message (level format-string &rest args)
  "按 LEVEL 记录一条日志（受 *log-level* 过滤）。"
  (when (log-enabled-p level)
    (let ((level-str (case level
                       (:debug "DEBUG")
                       (:info "INFO")
                       (:warn "WARN")
                       (:error "ERROR")
                       (otherwise "LOG"))))
      (format *log-stream* "~&~@[~A ~][~A] ~?~%"
              (when *log-timestamp-format* (format-log-timestamp))
              level-str
              format-string
              args)
      (force-output *log-stream*))))

(defun log-debug (format-string &rest args)
  "记录 DEBUG 级别日志。"
  (apply #'log-message :debug format-string args))

(defun log-info (format-string &rest args)
  "记录 INFO 级别日志。"
  (apply #'log-message :info format-string args))

(defun log-warn (format-string &rest args)
  "记录 WARN 级别日志。"
  (apply #'log-message :warn format-string args))

(defun log-error (format-string &rest args)
  "记录 ERROR 级别日志。"
  (apply #'log-message :error format-string args))

(defun set-log-level (level)
  "设置日志级别（:debug :info :warn :error :off）。"
  (setf *log-level* level))

(defun get-log-level ()
  "当前日志级别。"
  *log-level*)
