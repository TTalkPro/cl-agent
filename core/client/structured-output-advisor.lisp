;;;; structured-output-advisor.lisp
;;;; CL-Agent Client - StructuredOutputValidationAdvisor
;;;;
;;;; 概述（对标 Spring AI 2.0 StructuredOutputValidationAdvisor）：
;;;;   即使开启了原生结构化输出，模型仍可能返回不符合 schema 的 JSON。
;;;;   本 Advisor 校验响应文本，失败时把校验错误追加到 user 消息末尾
;;;;   重新调用模型，让模型自我纠正——最多重试 max-repeat-attempts 次。
;;;;
;;;; 排序：
;;;;   默认 order 为 +structured-output-validation-advisor-order+（最内侧，
;;;;   紧贴 ChatModel），因此位于工具循环*内部*，会看到每一轮的模型响应。
;;;;   携带 tool-calls 的响应不是最终输出，直接放行给外侧的
;;;;   tool-calling-advisor 去执行工具，只有最终响应才校验。
;;;;
;;;; 流式：
;;;;   不支持——校验需要完整 JSON 文本，而流式的意义在于增量产出。
;;;;   与 Spring 一致，流式路径直接发条件而非静默降级。
;;;;
;;;; 用法：
;;;;   ;; 显式挂载
;;;;   (make-chat-client model
;;;;     :advisors (list (make-structured-output-validation-advisor
;;;;                      :json-schema "{\"type\":\"object\",
;;;;                                     \"required\":[\"city\",\"temp\"]}")))
;;;;
;;;;   ;; 或经 call-entity / (:call :entity) 自动挂载（传 :schema 时）
;;;;   (chat client (:user "给出东京天气") (:call :entity schema))

(in-package #:cl-agent.client)

(define-condition structured-output-streaming-unsupported-error (error)
  ()
  (:report (lambda (condition stream)
             (declare (ignore condition))
             (format stream "structured-output-validation-advisor 不支持流式调用：~@
校验需要完整的 JSON 文本。请改用同步路径（call-entity / (:call :entity)），~@
或从流式链中移除本 Advisor。")))
  (:documentation "结构化输出校验 Advisor 被用于流式链
（对标 Spring 的 UnsupportedOperationException）"))

(defun strip-json-fences (text)
  "剥掉 markdown 代码围栏，取出 JSON 文本。

模型即使被要求「只输出 JSON」也常常裹上 ```json 围栏，
校验与解析前统一剥离。"
  (let* ((trimmed (string-trim '(#\Space #\Newline #\Return #\Tab) text))
         (fence-start (search "```" trimmed)))
    (if (and fence-start (zerop fence-start))
        (let* ((first-newline (position #\Newline trimmed))
               (fence-end (search "```" trimmed :from-end t)))
          (if (and first-newline fence-end (> fence-end first-newline))
              (string-trim '(#\Space #\Newline #\Return #\Tab)
                           (subseq trimmed (1+ first-newline) fence-end))
              trimmed))
        trimmed)))

;;; ============================================================
;;; Advisor
;;; ============================================================

(defclass structured-output-validation-advisor (advisor)
  ((json-schema
    :initarg :json-schema
    :reader structured-output-schema
    :documentation "归一化后的 hash-table 形式 JSON Schema")
   (max-repeat-attempts
    :initarg :max-repeat-attempts
    :initform 3
    :reader structured-output-max-repeat-attempts
    :documentation "校验失败后的最大重试次数。
0 表示不重试——模型只调用一次（对标 Spring 的 maxRepeatAttempts）"))
  (:default-initargs :order +structured-output-validation-advisor-order+)
  (:documentation "结构化输出 JSON Schema 校验 + 自我纠正 Advisor
（对标 StructuredOutputValidationAdvisor）"))

(defmethod initialize-instance :after
    ((advisor structured-output-validation-advisor) &key)
  (unless (slot-boundp advisor 'json-schema)
    (error "structured-output-validation-advisor 需要 :json-schema"))
  (let ((attempts (structured-output-max-repeat-attempts advisor)))
    (unless (and (integerp attempts) (>= attempts 0))
      (error "max-repeat-attempts 须为非负整数，实际为 ~S" attempts)))
  ;; 构造期就把 schema 归一化并校验其合法性，避免每次请求重复解析，
  ;; 也让 schema 写错时立刻暴露而不是等到第一次调用
  (setf (slot-value advisor 'json-schema)
        (ensure-json-schema (slot-value advisor 'json-schema))))

(defun make-structured-output-validation-advisor
    (&rest initargs &key json-schema max-repeat-attempts order)
  "创建结构化输出校验 Advisor。

参数：
  JSON-SCHEMA         - JSON Schema：字符串 / hash-table /
                        params->json-schema 的 plist（必填）
  MAX-REPEAT-ATTEMPTS - 校验失败后的最大重试次数（默认 3，0 表示不重试）
  ORDER               - 排序（默认最内侧）"
  (declare (ignore json-schema max-repeat-attempts order))
  (apply #'make-instance 'structured-output-validation-advisor initargs))

(defun structured-output-error-text (errors)
  "把校验错误列表渲染为追加给模型的纠正提示"
  (format nil "上一次输出的 JSON 未通过校验：~{~A~^；~}~@
请严格按 schema 重新输出 JSON，不要包含任何多余说明或 markdown 代码围栏。"
          errors))

(defun structured-output-validate (advisor chat-response)
  "校验 CHAT-RESPONSE 的文本是否符合 schema，返回错误列表（NIL 表示通过）"
  (let ((text (and chat-response (chat-response-text chat-response))))
    (cond
      ((null text)
       (list "响应缺少可校验的文本输出"))
      ((string= (string-trim '(#\Space #\Newline #\Return #\Tab) text) "")
       (list "响应文本为空"))
      (t (validate-json-text (strip-json-fences text)
                             (structured-output-schema advisor))))))

(defmethod advise-call ((advisor structured-output-validation-advisor) request chain)
  (let ((max-attempts (structured-output-max-repeat-attempts advisor))
        (current request))
    (loop for attempt from 0
          do (let* ((response (chain-next chain current))
                    (chat-response (client-response-chat-response response)))
               ;; 带 tool-calls 的响应不是最终输出：放行给外侧工具循环
               (when (and chat-response
                          (chat-response-has-tool-calls-p chat-response))
                 (return response))
               (let ((errors (structured-output-validate advisor chat-response)))
                 (when (null errors)
                   (return response))
                 ;; 重试用尽：返回最后一次响应而非发条件（对标 Spring）——
                 ;; 校验是尽力而为的增强，不应把原本可用的响应变成异常
                 (when (>= attempt max-attempts)
                   (log-warn "结构化输出校验失败，已用尽 ~A 次重试：~{~A~^；~}"
                             max-attempts errors)
                   (return response))
                 (log-warn "结构化输出校验失败，第 ~A 次重试：~{~A~^；~}"
                           (1+ attempt) errors)
                 ;; 每次都从*原始* request 重新增强，而不是在上一轮的
                 ;; 增强结果上继续追加——否则多轮重试会累积出一长串
                 ;; 互相矛盾的错误提示，反而干扰模型（对标 Spring）
                 (setf current
                       (client-request-copy
                        request
                        :prompt (prompt-augment-last-user-message
                                 (client-request-prompt request)
                                 (lambda (text)
                                   (format nil "~A~%~A" text
                                           (structured-output-error-text
                                            errors)))))))))))

(defmethod advise-stream ((advisor structured-output-validation-advisor)
                          request chain on-chunk)
  (declare (ignore advisor request chain on-chunk))
  (error 'structured-output-streaming-unsupported-error))
