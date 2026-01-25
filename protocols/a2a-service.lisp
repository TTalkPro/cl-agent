;;;; a2a-service.lisp
;;;; CL-Agent - A2A 服务发现
;;;;
;;;; 概述：
;;;;   实现 A2A 服务注册和发现功能
;;;;
;;;; 内容：
;;;;   - 服务注册表
;;;;   - 服务注册和注销
;;;;   - 服务发现

(in-package :cl-agent.protocols)

;;; ============================================================
;;; 服务发现
;;; ============================================================

(defstruct a2a-service-registry
  "A2A 服务注册表

  槽位说明：
    SERVICES  - 服务列表
    ENDPOINTS - 端点映射"
  (services (make-hash-table :test #'equal))
  (endpoints (make-hash-table :test #'equal)))

(defparameter *a2a-service-registry* (make-a2a-service-registry)
  "全局 A2A 服务注册表")

(defun a2a-register-service (agent-info endpoint)
  "注册服务

  参数：
    AGENT-INFO - Agent 信息
    ENDPOINT   - 端点

  返回：
    是否成功"
  (let ((id (a2a-agent-info-id agent-info)))
    (setf (gethash id (a2a-service-registry-services *a2a-service-registry*))
          agent-info)
    (setf (gethash id (a2a-service-registry-endpoints *a2a-service-registry*))
          endpoint)
    (when *mcp-verbose*
      (mcp-log :info "Registered service: ~A" id))
    t))

(defun a2a-unregister-service (agent-id)
  "注销服务

  参数：
    AGENT-ID - Agent ID

  返回：
    是否成功"
  (remhash agent-id (a2a-service-registry-services *a2a-service-registry*))
  (remhash agent-id (a2a-service-registry-endpoints *a2a-service-registry*))
  (when *mcp-verbose*
    (mcp-log :info "Unregistered service: ~A" agent-id))
  t)

(defun a2a-discover-services (&key (type nil))
  "发现服务

  参数：
    TYPE - Agent 类型（可选）

  返回：
    服务列表"
  (let ((services '()))
    (maphash (lambda (id info)
               (unless (and type
                            (not (string= (a2a-agent-info-type info)
                                         type)))
                 (push info services)))
             (a2a-service-registry-services *a2a-service-registry*))
    services))

(defun a2a-get-service-endpoint (agent-id)
  "获取服务端点

  参数：
    AGENT-ID - Agent ID

  返回：
    端点或 NIL"
  (gethash agent-id
           (a2a-service-registry-endpoints *a2a-service-registry*)))
