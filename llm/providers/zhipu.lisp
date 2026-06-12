;;;; zhipu.lisp
;;;; CL-Agent - 智谱 AI (ZhipuAI) 提供商实现
;;;;
;;;; 概述：
;;;;   智谱 AI GLM 系列提供商——声明式定义 + 两处特化：
;;;;   - 认证头：API 密钥含 \".\" 时按 id.secret 完整格式直传
;;;;   - 思维链：reasoning_content 由 openai-compat 基座统一提取到
;;;;     llm-response 的 :reasoning 槽
;;;;
;;;; 支持的模型：
;;;;   - GLM-4.7（最新）/ glm-4.6（带思维链）
;;;;   - glm-4-plus / glm-4-air / glm-4-flash
;;;;
;;;; API 文档：https://open.bigmodel.cn/dev/api

(in-package :cl-agent.llm.providers)

(define-openai-compat-provider zhipu
  :base-url "https://open.bigmodel.cn/api/paas/v4"
  :env-key "ZHIPU_API_KEY"
  :default-model "GLM-4.7"
  :documentation "智谱 AI GLM 提供商

支持 GLM-4 系列模型，包括最新的 GLM-4.7。
glm-4.6 会输出思维链（llm-response-reasoning）。")

;;; ============================================================
;;; 智谱特化：认证头
;;; ============================================================

(defmethod provider-auth-headers ((provider zhipu-provider))
  "智谱 AI 认证头。

API 密钥格式为 id.secret 时直传完整格式，否则按 Bearer Token。"
  (let* ((api-key (provider-api-key provider))
         (auth-header (if (search "." api-key)
                          api-key
                          (format nil "Bearer ~A" api-key))))
    `(("Content-Type" . "application/json")
      ("Authorization" . ,auth-header))))

;;; ============================================================
;;; 智谱 AI 辅助函数
;;; ============================================================

(defun extract-reasoning-content (response)
  "提取思维链内容。

参数：
  RESPONSE - llm-response 对象（或旧式响应 plist）

返回：
  思维链字符串，没有则 NIL"
  (typecase response
    (cl-agent.core:llm-response (cl-agent.core:llm-response-reasoning response))
    (list (getf response :reasoning-content))
    (t nil)))

(defun response-complete-p (response)
  "检查响应是否完整（未被截断）。

参数：
  RESPONSE - llm-response 对象（或旧式响应 plist）

返回：
  T 表示正常完成（:stop），NIL 表示被截断或其他原因结束"
  (typecase response
    (cl-agent.core:llm-response
     (eq (cl-agent.core:llm-response-finish-reason response) :stop))
    (list
     (let ((reason (getf response :finish-reason)))
       (and reason (string-equal (string reason) "stop"))))
    (t nil)))

(defun get-suggested-max-tokens (provider)
  "获取建议的 max-tokens 值。

说明：
  - GLM-4.7 / glm-4.6: 建议 4096（含思维链）
  - 其他模型: 建议 2048"
  (let ((model (cl-agent.llm:provider-default-model provider)))
    (cond
      ((search "GLM-4.7" model) 4096)
      ((search "glm-4.6" model) 4096)
      (t 2048))))
