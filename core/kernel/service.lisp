;;;; service.lisp
;;;; CL-Agent Kernel - Service CLOS 类
;;;;
;;;; 概述：
;;;;   Service 抽象将 Kernel 与 LLM 具体实现解耦
;;;;   提供统一的 chat 和 result 构建接口
;;;;
;;;; 设计：
;;;;   使用 CLOS 类替代 plist，提供：
;;;;   - 类型安全
;;;;   - 方法分派
;;;;   - 更好的封装

(in-package #:cl-agent.kernel)

;;; ============================================================
;;; Service CLOS 类
;;; ============================================================

(defclass service ()
  ((chat-fn
    :initarg :chat-fn
    :accessor service-chat-fn
    :type function
    :documentation "Chat 函数: (messages tools settings) -> response")
   (build-result-msgs-fn
    :initarg :build-result-msgs-fn
    :accessor service-build-result-msgs-fn
    :initform #'default-build-result-msgs
    :type function
    :documentation "结果消息构建函数: (tool-call result) -> messages")
   (provider
    :initarg :provider
    :accessor service-provider
    :initform nil
    :documentation "LLM Provider 实例")
   (config
    :initarg :config
    :accessor service-config
    :initform nil
    :documentation "配置 plist"))
  (:documentation "LLM Service 抽象类

将 Kernel 与具体 LLM 实现解耦。
一个 Service 提供:
  - chat-fn: 调用 LLM 的函数
  - build-result-msgs-fn: 构建工具结果消息的函数
  - provider: 可选的 Provider 实例引用
  - config: 可选的配置"))

;;; ============================================================
;;; 构造函数
;;; ============================================================

(defun make-service (&key chat-fn build-result-msgs provider config)
  "创建 Service 实例

参数：
  CHAT-FN          - Chat 函数 (messages tools settings) -> response
  BUILD-RESULT-MSGS - 结果消息构建函数 (tool-call result) -> messages
  PROVIDER         - Provider 实例
  CONFIG           - 配置 plist

返回：
  Service 实例

示例：
  (make-service
    :chat-fn (lambda (msgs tools settings)
               (llm-chat provider msgs :tools tools))
    :provider provider)"
  (unless chat-fn
    (error "Service requires :chat-fn"))
  (make-instance 'service
                 :chat-fn chat-fn
                 :build-result-msgs-fn (or build-result-msgs
                                           #'default-build-result-msgs)
                 :provider provider
                 :config config))

;;; ============================================================
;;; 泛型函数
;;; ============================================================

(defgeneric service-chat (service messages tools &optional settings)
  (:documentation "调用 LLM Chat

参数：
  SERVICE  - Service 实例
  MESSAGES - 消息列表
  TOOLS    - 工具 schema 列表
  SETTINGS - 可选设置 plist

返回：
  LLM 响应 plist"))

(defgeneric service-build-result (service tool-call result)
  (:documentation "构建工具结果消息

参数：
  SERVICE   - Service 实例
  TOOL-CALL - 工具调用 plist (:id :name :arguments)
  RESULT    - 工具执行结果

返回：
  结果消息列表"))

;;; ============================================================
;;; 方法实现
;;; ============================================================

(defmethod service-chat ((service service) messages tools &optional settings)
  "调用 Service 的 chat 函数"
  (funcall (service-chat-fn service) messages tools settings))

(defmethod service-build-result ((service service) tool-call result)
  "调用 Service 的结果消息构建函数"
  (funcall (service-build-result-msgs-fn service) tool-call result))

;;; ============================================================
;;; 谓词
;;; ============================================================

(defun service-p (obj)
  "检查是否为 Service 实例

参数：
  OBJ - 对象

返回：
  t 如果是 Service，nil 否则"
  (typep obj 'service))

;;; ============================================================
;;; 默认实现
;;; ============================================================

(defun default-build-result-msgs (tool-call result)
  "默认的结果消息构建函数

参数：
  TOOL-CALL - 工具调用 plist (:id :name :arguments)
  RESULT    - 工具执行结果

返回：
  包含单个 tool 消息的列表"
  (let* ((tc-id (getf tool-call :id))
         (result-str (if (stringp result)
                         result
                         (format nil "~S" result))))
    (list (list :role :tool
                :tool-call-id tc-id
                :content result-str))))

;;; ============================================================
;;; Service 工厂（从 Provider 创建）
;;; ============================================================

(defun service-from-provider (provider &key config)
  "从 LLM Provider 创建 Service

这是 LLM 模块和 Kernel 之间的桥梁。
Provider 必须实现 llm-chat 泛型函数。

参数：
  PROVIDER - LLM provider 实例
  CONFIG   - 可选配置 plist

返回：
  Service 实例

示例：
  (service-from-provider
    (make-openai-provider :model \"gpt-4o\"))"
  (make-service
   :provider provider
   :config config
   :chat-fn (lambda (messages tools settings)
              (llm-chat provider messages
                        :tools tools
                        :max-tokens (getf settings :max-tokens)
                        :temperature (getf settings :temperature)
                        :model (getf settings :model)
                        :system (getf settings :system-prompt)))))

;;; ============================================================
;;; Service 装饰器（中间件模式）
;;; ============================================================

(defgeneric wrap-service (service wrapper-type &rest args)
  (:documentation "用装饰器包装 Service

参数：
  SERVICE      - 原 Service
  WRAPPER-TYPE - 装饰器类型关键字
  ARGS         - 装饰器参数

返回：
  新的 Service 实例"))

(defmethod wrap-service ((service service) (type (eql :logging)) &rest args)
  "添加日志装饰器"
  (let ((stream (or (getf args :stream) *standard-output*))
        (level (or (getf args :level) :info))
        (original-chat-fn (service-chat-fn service)))
    (make-service
     :provider (service-provider service)
     :config (service-config service)
     :build-result-msgs (service-build-result-msgs-fn service)
     :chat-fn (lambda (messages tools settings)
                (format stream "[~A] Service call: ~A messages, ~A tools~%"
                        level (length messages) (length tools))
                (let* ((start-time (get-internal-real-time))
                       (response (funcall original-chat-fn messages tools settings))
                       (elapsed (/ (- (get-internal-real-time) start-time)
                                   internal-time-units-per-second)))
                  (format stream "[~A] Service response in ~,2Fs~%"
                          level elapsed)
                  response)))))

(defmethod wrap-service ((service service) (type (eql :retry)) &rest args)
  "添加重试装饰器"
  (let ((max-retries (or (getf args :max-retries) 3))
        (backoff-base (or (getf args :backoff-base) 2))
        (original-chat-fn (service-chat-fn service)))
    (make-service
     :provider (service-provider service)
     :config (service-config service)
     :build-result-msgs (service-build-result-msgs-fn service)
     :chat-fn (lambda (messages tools settings)
                (let ((retries 0))
                  (loop
                    (handler-case
                        (return (funcall original-chat-fn messages tools settings))
                      (error (e)
                        (if (< retries max-retries)
                            (progn
                              (incf retries)
                              (sleep (* (expt backoff-base retries) 0.1)))
                            (error e))))))))))

(defmethod wrap-service ((service service) (type (eql :timeout)) &rest args)
  "添加超时检查装饰器"
  (let ((timeout-seconds (or (getf args :seconds) 60))
        (original-chat-fn (service-chat-fn service)))
    (make-service
     :provider (service-provider service)
     :config (service-config service)
     :build-result-msgs (service-build-result-msgs-fn service)
     :chat-fn (lambda (messages tools settings)
                (let* ((start-time (get-internal-real-time))
                       (response (funcall original-chat-fn messages tools settings))
                       (elapsed (/ (- (get-internal-real-time) start-time)
                                   internal-time-units-per-second)))
                  (when (> elapsed timeout-seconds)
                    (warn "Service call exceeded timeout: ~,2Fs > ~As"
                          elapsed timeout-seconds))
                  response)))))

;;; ============================================================
;;; 便捷函数（保持向后兼容）
;;; ============================================================

(defun wrap-service-logging (service &key (stream *standard-output*) (level :info))
  "用日志包装 Service（便捷函数）"
  (wrap-service service :logging :stream stream :level level))

(defun wrap-service-retry (service &key (max-retries 3) (backoff-base 2))
  "用重试逻辑包装 Service（便捷函数）"
  (wrap-service service :retry :max-retries max-retries :backoff-base backoff-base))

(defun wrap-service-timeout (service timeout-seconds)
  "用超时检查包装 Service（便捷函数）"
  (wrap-service service :timeout :seconds timeout-seconds))

;;; ============================================================
;;; 打印方法
;;; ============================================================

(defmethod print-object ((service service) stream)
  "打印 Service 对象"
  (print-unreadable-object (service stream :type t :identity t)
    (format stream "~@[provider=~A~]"
            (when (service-provider service)
              (type-of (service-provider service))))))
