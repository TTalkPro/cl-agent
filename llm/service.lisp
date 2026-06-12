;;;; service.lisp
;;;; CL-Agent LLM - Service Layer
;;;;
;;;; Overview:
;;;;   Provider 层现在自身就产出统一的 llm-response 对象
;;;;   （openai-compat 基座 / anthropic / dashscope 各自归一化，
;;;;   usage 别名与 finish-reason 的单一来源在 cl-agent.core）。
;;;;
;;;;   本文件退化为薄兼容层：
;;;;   - ensure-llm-response：幂等转换（plist -> llm-response）
;;;;   - normalize-response：旧 API 兼容壳（忽略 provider-type 分发）
;;;;   - chat-with-normalization：旧高层 API（llm-chat 已归一，直通）
;;;;
;;;;   参照 clj-agent design/response-path-consolidation.md：
;;;;   响应归一化收敛为单一活路径，不再按 provider 各写一份。

(in-package :cl-agent.llm)

;;; ============================================================
;;; Response Normalization（幂等单一入口）
;;; ============================================================

(defun ensure-llm-response (response)
  "确保响应为 llm-response 对象（幂等）。

参数：
  RESPONSE - llm-response 对象或旧式响应 plist

返回：
  llm-response 对象"
  (if (cl-agent.core:llm-response-p response)
      response
      (cl-agent.core:plist-to-llm-response response)))

(defun normalize-response (raw-response &optional provider-type)
  "将响应归一化为 llm-response 对象（旧 API 兼容壳）。

PROVIDER-TYPE 参数已不再需要——provider 层自身完成归一化，
本函数只做幂等转换。保留参数仅为向后兼容。"
  (declare (ignore provider-type))
  (ensure-llm-response raw-response))

;;; ============================================================
;;; High-Level Service Functions
;;; ============================================================

(defun chat-with-normalization (provider messages &rest args
                                &key max-tokens temperature model tools system)
  "调用 LLM 并返回统一的 llm-response 对象。

说明：
  provider 的 llm-chat 现在直接返回 llm-response；
  本函数保留为高层兼容 API（含幂等归一化保护）。"
  (declare (ignore max-tokens temperature model tools system))
  (ensure-llm-response (apply #'llm-chat provider messages args)))

;;; ============================================================
;;; Utility Functions for llm-response
;;; ============================================================

(defun response-reasoning-content (response)
  "从 llm-response 中提取思维链内容（GLM/DeepSeek reasoning_content、
Anthropic thinking）。

参数：
  RESPONSE - llm-response 对象

返回：
  思维链字符串，没有则 NIL"
  (or (cl-agent.core:llm-response-reasoning response)
      ;; 旧版兼容：reasoning 曾被塞进扩展的 raw-response
      (let ((raw (cl-agent.core:llm-response-raw response)))
        (when (hash-table-p raw)
          (gethash "reasoning_content" raw)))))

(defun response-complete-p (response)
  "检查响应是否完整（非截断）

参数：
  RESPONSE - llm-response 对象

返回：
  t 如果响应完整，nil 如果被截断"
  (eq (cl-agent.core:llm-response-finish-reason response) :stop))
