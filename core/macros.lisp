;;;; macros.lisp
;;;; CL-Agent - 实用宏定义

(in-package :cl-agent.core)

;;; ============================================================
;;; 绑定宏
;;; ============================================================

(defmacro when-let ((var value) &body body)
  "当值非空时绑定的 when 版本"
  `(let ((,var ,value))
     (when ,var
       ,@body)))

(defmacro when-let* (bindings &body body)
  "链式 when-let"
  (if (null bindings)
      `(progn ,@body)
      `(when-let ,(car bindings)
         (when-let* ,(cdr bindings)
           ,@body))))

(defmacro if-let ((var value) then-form &optional else-form)
  "当值非空时绑定的 if 版本"
  `(let ((,var ,value))
     (if ,var
         ,then-form
         ,else-form)))

(defmacro unless-let ((var value) &body body)
  "当值为空时绑定"
  `(let ((,var ,value))
     (unless ,var
       ,@body)))

;;; anaphoric variants
(defmacro awhen (test-form &body body)
  "带 it 绑定的 when"
  `(let ((it ,test-form))
     (when it
       (symbol-macrolet ((it it))
         ,@body))))

(defmacro aif (test-form then-form &optional else-form)
  "带 it 绑定的 if"
  `(let ((it ,test-form))
     (if it
         (symbol-macrolet ((it it))
           ,then-form)
         ,else-form)))

;;; ============================================================
;;; 控制流宏
;;; ============================================================

(defmacro -> (initial-form &rest forms)
  "线程首个（thread-first）"
  (loop for form in forms
        with result = initial-form
        do (setf result
                 (if (listp form)
                     (cons (car form) (cons result (cdr form)))
                     (list form result)))
        finally (return result)))

(defmacro ->> (initial-form &rest forms)
  "线程最后（thread-last）"
  (loop for form in forms
        with result = initial-form
        do (setf result
                 (if (listp form)
                     (append form (list result))
                     (list form result)))
        finally (return result)))

(defmacro as-> (initial-form var &rest forms)
  "线程 AS（显式命名）"
  (loop for form in forms
        with result = var
        initially `(let ((,var ,initial-form))
                    (declare (ignorable ,var)))
        do (setf result
                 `(let ((,var ,form))
                    (declare (ignorable ,var))
                    ,result))
        finally (return result))

;;; ============================================================
;;; 资源管理宏
;;; ============================================================

(defmacro with-timing ((&optional (label "Timing")) &body body)
  "测量执行时间的宏"
  `(let ((start-time (get-internal-real-time))
         (start-unix (timestamp-now)))
     (multiple-value-prog1
         (progn ,@body)
       (let ((end-time (get-internal-real-time))
             (end-unix (timestamp-now)))
         (log:info "~A: ~F seconds (~F ms)"
                   ,label
                   (/ (- end-time start-time) internal-time-units-per-second)
                   (- end-unix start-unix))))))

(defmacro with-retry ((&key (max-retries 3)
                           (backoff-base 2)
                           (condition 'error)) &body body)
  "带退避的重试宏"
  (let ((retries (gensym "RETRIES"))
        (result (gensym "RESULT")))
    `(let ((,retries 0))
       (loop
         (handler-case
             (let ((,result (progn ,@body)))
               (when (> ,retries 0)
                 (log:info "Retry succeeded after ~A attempts" ,retries))
               (return ,result))
           (,condition (condition)
             (if (< ,retries ,max-retries)
                 (progn
                   (incf ,retries)
                   (let ((wait-time (* (expt ,backoff-base ,retries) 0.1)))
                     (log:warn "Attempt ~A/~A failed: ~A~%~
                               Retrying after ~F seconds..."
                              ,retries ,max-retries condition wait-time)
                     (sleep wait-time)))
                 (error condition))))))))

(defmacro with-temp-file ((var &key (prefix "lia") (suffix "tmp")) &body body)
  "创建临时文件的上下文管理器"
  `(let ((,var (merge-pathnames
                (make-pathname :name (concatenate 'string ,prefix "-" (generate-uuid))
                              :type ,suffix)
                (uiop:temporary-directory))))
     (unwind-protect
         (progn ,@body)
       (when (probe-file ,var)
         (delete-file ,var)))))

;;; ============================================================
;;; 验证宏
;;; ============================================================

(defmacro check-type-or-nil (place type &optional (place-name "" place-name-p))
  "检查类型或允许 nil"
  `(or (null ,place)
       (typep ,place ',type)
       (error 'validation-error
              :message (format nil "~:@(~A~) should be ~A or NIL, got ~S"
                              ,(if place-name-p place-name place)
                              ',type ,place)
              :field ,(if place-name-p place-name place))))

(defmacro with-validated-args (validations &body body)
  "参数验证块"
  `(progn
     ,@(loop for (var type) in validations
             collect `(check-type-or-nil ,var ,type))
     ,@body))

(defmacro assert-not-nil (value &optional (message "Value cannot be nil"))
  "断言值非空"
  `(unless ,value
     (error 'validation-error
            :message ,message)))

;;; ============================================================
;;; 迭代宏
;;; ============================================================

(defmacro do-alist ((key value alist) &body body)
  "遍历关联表"
  `(dolist (entry ,alist)
     (let ((,key (car entry))
           (,value (cdr entry)))
       ,@body)))

(defmacro do-plist ((key value plist) &body body)
  "遍历属性列表"
  (let ((iter (gensym "ITER")))
    `(do ((,iter ,plist (cddr ,iter)))
         ((null ,iter))
       (let ((,key (car ,iter))
             (,value (cadr ,iter)))
         (declare (ignorable ,key ,value))
         ,@body))))

(defmacro collect-if (predicate list)
  "收集满足条件的元素"
  `(remove-if-not ,predicate ,list))

;;; ============================================================
;;; 结果处理宏
;;; ============================================================

(defmacro result-let ((var result-form) &body body)
  "绑定结果并处理（成功/失败）"
  `(let ((,var ,result-form))
     (if (and (consp ,var) (eq (car ,var) :ok))
         (let ((value (cdr ,var)))
           (declare (ignorable value))
           ,@body)
         (let ((error (cdr ,var)))
           (declare (ignorable error))
           (error 'validation-error
                  :message (format nil "Operation failed: ~A" error))))))

(defmacro ok-or (value)
  "返回 (ok . value) 或 (error . message)"
  `(if ,value
       (cons :ok ,value)
       (cons :error nil)))

;;; ============================================================
;;; 配置宏
;;; ============================================================

(defmacro defconfig (var-name default &key (required nil) (documentation ""))
  "定义配置变量"
  (let ((env-var (symbol-name var-name))
        (reader-name (intern (format nil "~A-CONFIG" var-name))))
    `(progn
       (defparameter ,var-name ,default
         ,@(when documentation (list documentation)))
       (defun ,reader-name ()
         ,(if required
              `(or ,var-name (get-env-required ,env-var))
              `(or ,var-name (get-env ,env-var ,default))))
       (export ',var-name)
       (export ',reader-name))))

;;; ============================================================
;;; 缓存宏
;;; ============================================================

(defmacro define-cached-function (name args &body body)
  "定义带缓存函数"
  (let ((cache-var (intern (format nil "*~A-CACHE*" name))))
    `(progn
       (defparameter ,cache-var (make-hash-table :test 'equal))
       (defun ,name ,args
         (let ((key (list ,@args)))
           (multiple-value-bind (value found-p)
               (gethash key ,cache-var)
             (if found-p
                 value
                 (let ((result (progn ,@body)))
                   (setf (gethash key ,cache-var) result)
                   result))))))))

;;; ============================================================
;;; 日志系统
;;; ============================================================

(defvar *log-level* :info
  "当前日志级别（:debug, :info, :warn, :error, :off）")

(defvar *log-stream* *standard-output*
  "日志输出流")

(defvar *log-timestamp-format* t
  "是否在日志中包含时间戳")

(defvar *log-context* nil
  "当前日志上下文（动态变量）")

(defparameter *log-level-priority*
  '((:debug . 0)
    (:info . 1)
    (:warn . 2)
    (:error . 3)
    (:off . 100))
  "日志级别优先级")

(defun log-level-priority (level)
  "获取日志级别的优先级"
  (or (cdr (assoc level *log-level-priority*))
      1))  ; 默认 info 级别

(defun log-enabled-p (level)
  "检查指定级别的日志是否启用"
  (>= (log-level-priority level)
      (log-level-priority *log-level*)))

(defun format-log-timestamp ()
  "格式化日志时间戳"
  (multiple-value-bind (sec min hour day month year)
      (get-decoded-time)
    (format nil "~4,'0D-~2,'0D-~2,'0D ~2,'0D:~2,'0D:~2,'0D"
            year month day hour min sec)))

(defun log-message (level format-string &rest args)
  "记录日志消息

  参数：
    LEVEL         - 日志级别（:debug, :info, :warn, :error）
    FORMAT-STRING - 格式化字符串
    ARGS          - 格式化参数"
  (when (log-enabled-p level)
    (let ((level-str (case level
                       (:debug "DEBUG")
                       (:info "INFO")
                       (:warn "WARN")
                       (:error "ERROR")
                       (otherwise "LOG"))))
      (format *log-stream* "~&~@[~A ~][~A]~@[ [~A]~] ~?~%"
              (when *log-timestamp-format* (format-log-timestamp))
              level-str
              *log-context*
              format-string
              args)
      (force-output *log-stream*))))

(defun log-debug (format-string &rest args)
  "记录 DEBUG 级别日志"
  (apply #'log-message :debug format-string args))

(defun log-info (format-string &rest args)
  "记录 INFO 级别日志"
  (apply #'log-message :info format-string args))

(defun log-warn (format-string &rest args)
  "记录 WARN 级别日志"
  (apply #'log-message :warn format-string args))

(defun log-error (format-string &rest args)
  "记录 ERROR 级别日志"
  (apply #'log-message :error format-string args))

(defmacro with-log-context ((&rest context) &body body)
  "在上下文中执行代码

  参数：
    CONTEXT - 上下文标识符列表

  示例：
    (with-log-context (:agent \"my-agent\")
      (log-info \"Processing...\"))"
  `(let ((*log-context* (format nil "~{~A~^/~}" (list ,@context))))
     ,@body))

(defmacro log-and-return (level format-string &rest args)
  "记录日志并返回最后一个参数的值

  参数：
    LEVEL         - 日志级别
    FORMAT-STRING - 格式化字符串
    ARGS          - 参数（最后一个作为返回值）"
  (let ((result-var (gensym "RESULT")))
    `(let ((,result-var (progn ,@(butlast args))))
       (log-message ,level ,format-string ,@(last args))
       ,result-var)))

(defmacro with-logging ((&key (level :info) (on-entry nil) (on-exit nil)) &body body)
  "带日志的代码块

  参数：
    LEVEL    - 日志级别
    ON-ENTRY - 进入时的日志消息
    ON-EXIT  - 退出时的日志消息"
  (let ((result-var (gensym "RESULT")))
    `(progn
       ,(when on-entry
          `(log-message ,level ,on-entry))
       (let ((,result-var (progn ,@body)))
         ,(when on-exit
            `(log-message ,level ,on-exit))
         ,result-var))))

(defun set-log-level (level)
  "设置日志级别

  参数：
    LEVEL - 日志级别（:debug, :info, :warn, :error, :off）"
  (setf *log-level* level))

(defun get-log-level ()
  "获取当前日志级别"
  *log-level*)
)
