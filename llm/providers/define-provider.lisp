;;;; define-provider.lisp
;;;; CL-Agent LLM - Provider 定义宏
;;;;
;;;; 概述：
;;;;   提供 define-provider 宏，消除 Provider 实现中的重复代码
;;;;   自动生成：类定义、工厂函数、llm-chat 方法等
;;;;
;;;; 设计原则：
;;;;   - 约定优于配置
;;;;   - 只覆盖需要自定义的部分
;;;;   - 保持与现有 API 的兼容性

(in-package :cl-agent.llm.providers)

;;; ============================================================
;;; 通用辅助函数
;;; ============================================================

(defun make-keyword (str)
  "将字符串转换为关键字"
  (intern (string-upcase str) :keyword))

(defun format-tool-for-openai (tool)
  "将工具格式化为 OpenAI 格式

返回 hash-table 用于正确的 JSON 序列化"
  (let ((wrapper (make-hash-table :test 'equal))
        (function (make-hash-table :test 'equal))
        (name (getf tool :name))
        (description (getf tool :description))
        (schema (or (getf tool :input-schema)
                    (getf tool :parameters))))
    ;; 构建 function 对象
    (setf (gethash "name" function)
          (if (stringp name)
              name
              (string-downcase (string name))))
    (setf (gethash "description" function) (or description ""))
    (setf (gethash "parameters" function)
          (cond
            ((hash-table-p schema) schema)
            ((and (listp schema) (keywordp (first schema)))
             (cl-agent.kernel:schema-to-hash-table schema))
            (t (let ((empty (make-hash-table :test 'equal)))
                 (setf (gethash "type" empty) "object")
                 (setf (gethash "properties" empty) (make-hash-table :test 'equal))
                 (setf (gethash "required" empty) #())
                 empty))))
    ;; 构建 wrapper
    (setf (gethash "type" wrapper) "function")
    (setf (gethash "function" wrapper) function)
    wrapper))

(defun parse-tool-calls-openai-style (tool-calls)
  "解析 OpenAI 风格的工具调用（也适用于 OpenAI 兼容 API）

支持 hash-table 和 plist 两种输入格式"
  (loop for call in (if (vectorp tool-calls)
                        (coerce tool-calls 'list)
                        tool-calls)
        for id = (if (hash-table-p call)
                     (gethash "id" call)
                     (getf call :id))
        for function = (if (hash-table-p call)
                           (gethash "function" call)
                           (getf call :function))
        for name = (when function
                     (if (hash-table-p function)
                         (gethash "name" function)
                         (getf function :name)))
        for arguments-raw = (when function
                              (if (hash-table-p function)
                                  (gethash "arguments" function)
                                  (getf function :arguments)))
        ;; 解析 arguments（可能是 JSON 字符串或已解析的对象）
        for arguments = (cond
                          ((null arguments-raw) nil)
                          ((hash-table-p arguments-raw) arguments-raw)
                          ((stringp arguments-raw)
                           (handler-case
                               (cl-agent.core:json-parse arguments-raw)
                             (error () arguments-raw)))
                          (t arguments-raw))
        collect (list :id id
                      :name (when name (make-keyword (string-upcase name)))
                      :arguments arguments
                      :raw call)))

;;; ============================================================
;;; OpenAI 兼容的通用函数
;;; ============================================================

(defun build-openai-compatible-request (provider messages &key
                                                   max-tokens
                                                   temperature
                                                   model
                                                   tools
                                                   (stream nil))
  "构建 OpenAI 兼容的请求体

适用于 OpenAI、智谱 AI 等兼容 API"
  (let ((model-name (or model (cl-agent.llm:provider-default-model provider)))
        (body (make-hash-table :test 'equal)))
    ;; 基础字段
    (setf (gethash "model" body) model-name)
    (setf (gethash "messages" body)
          (convert-messages-for-openai messages))
    ;; temperature 为 NIL 时不写入（避免序列化为 null 触发部分 API 400）
    (when temperature
      (setf (gethash "temperature" body) temperature))

    ;; 仅在启用流式时设置 stream: true
    ;; 不发送 stream: false 避免某些 API 的兼容性问题
    (when stream
      (setf (gethash "stream" body) t))

    ;; 可选字段
    (when max-tokens
      (setf (gethash "max_tokens" body) max-tokens))

    (when tools
      (setf (gethash "tools" body)
            (mapcar #'format-tool-for-openai tools)))

    body))

(defun convert-messages-for-openai (messages)
  "转换消息为 OpenAI 格式（返回 vector 用于 JSON 序列化）"
  (coerce
   (loop for msg in messages
         for role = (getf msg :role)
         for content = (getf msg :content)
         for tool-calls = (getf msg :tool-calls)
         for tool-call-id = (getf msg :tool-call-id)
         for msg-hash = (make-hash-table :test 'equal)
         do (progn
              (setf (gethash "role" msg-hash)
                    (if (keywordp role)
                        (string-downcase (symbol-name role))
                        role))
              (when content
                (setf (gethash "content" msg-hash) content))
              (when tool-calls
                (setf (gethash "tool_calls" msg-hash)
                      (convert-tool-calls-for-openai tool-calls)))
              (when tool-call-id
                (setf (gethash "tool_call_id" msg-hash) tool-call-id)))
         collect msg-hash)
   'vector))

(defun convert-tool-calls-for-openai (tool-calls)
  "转换工具调用为 OpenAI 格式

注意：OpenAI wire 格式要求 function.arguments 是 JSON **字符串**，
解析后的 hash-table/plist 在此处重新序列化（多轮工具回放的关键）。"
  (coerce
   (loop for tc in tool-calls
         for tc-hash = (make-hash-table :test 'equal)
         for fn-hash = (make-hash-table :test 'equal)
         do (progn
              (setf (gethash "id" tc-hash) (getf tc :id))
              (setf (gethash "type" tc-hash) "function")
              (setf (gethash "name" fn-hash)
                    (let ((name (getf tc :name)))
                      (if (keywordp name)
                          (string-downcase (symbol-name name))
                          name)))
              (setf (gethash "arguments" fn-hash)
                    (let ((args (getf tc :arguments)))
                      (cond
                        ((stringp args) args)
                        ((null args) "{}")
                        ((hash-table-p args)
                         (cl-agent.core:json-stringify args))
                        ((listp args)
                         (cl-agent.core:json-stringify
                          (cl-agent.core:plist-to-hash args)))
                        (t (cl-agent.core:json-stringify args)))))
              (setf (gethash "function" tc-hash) fn-hash))
         collect tc-hash)
   'vector))

(defun build-bearer-auth-headers (provider)
  "构建 Bearer Token 认证头"
  (let ((api-key (provider-api-key provider)))
    `(("Content-Type" . "application/json")
      ("Authorization" . ,(format nil "Bearer ~A" api-key)))))
