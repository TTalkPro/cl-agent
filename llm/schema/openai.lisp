;;;; openai.lisp
;;;; CL-Agent LLM - OpenAI Schema Converter
;;;;
;;;; Overview:
;;;;   Converts tool schemas to OpenAI function calling format.
;;;;   OpenAI uses a nested structure with "function" wrapper.

(in-package #:cl-agent.llm)

;;; ============================================================
;;; OpenAI Tool Schema Format
;;; ============================================================
;;;
;;; OpenAI expects tools in this format:
;;; {
;;;   "type": "function",
;;;   "function": {
;;;     "name": "get_weather",
;;;     "description": "Get weather for a city",
;;;     "parameters": {
;;;       "type": "object",
;;;       "properties": {
;;;         "city": {"type": "string", "description": "City name"}
;;;       },
;;;       "required": ["city"]
;;;     }
;;;   }
;;; }

(defun convert-tool-to-openai (tool)
  "Convert a tool schema to OpenAI format.

Parameters:
  TOOL - Tool plist (:name :description :input-schema)

Returns:
  Hash-table in OpenAI format"
  (let ((wrapper (make-hash-table :test 'equal))
        (function (make-hash-table :test 'equal))
        (name (getf tool :name))
        (description (getf tool :description))
        (schema (or (getf tool :input-schema)
                    (getf tool :parameters))))
    ;; Build function object
    (setf (gethash "name" function)
          (if (stringp name)
              name
              (string-downcase (string name))))
    (setf (gethash "description" function) description)
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
    ;; Build wrapper
    (setf (gethash "type" wrapper) "function")
    (setf (gethash "function" wrapper) function)
    wrapper))

(defun convert-tools-to-openai (tools)
  "Convert a list of tools to OpenAI format.

Parameters:
  TOOLS - List of tool plists

Returns:
  Vector of OpenAI format tools"
  (coerce (mapcar #'convert-tool-to-openai tools) 'vector))

;;; ============================================================
;;; OpenAI Tool Call Parsing
;;; ============================================================

(defun parse-openai-tool-calls (tool-calls)
  "Parse tool calls from OpenAI response.

Parameters:
  TOOL-CALLS - Tool calls from OpenAI response (vector or list)

Returns:
  Normalized tool call list"
  (let ((calls (if (vectorp tool-calls)
                   (coerce tool-calls 'list)
                   tool-calls)))
    (loop for tc in calls
          collect (let ((id (if (hash-table-p tc)
                                (gethash "id" tc)
                                (getf tc :id)))
                        (function (if (hash-table-p tc)
                                      (gethash "function" tc)
                                      (getf tc :function))))
                    (let ((name (if (hash-table-p function)
                                    (gethash "name" function)
                                    (getf function :name)))
                          (arguments (if (hash-table-p function)
                                         (gethash "arguments" function)
                                         (getf function :arguments))))
                      (list :id id
                            :name (intern (string-upcase name) :keyword)
                            :arguments (if (stringp arguments)
                                           (handler-case
                                               (cl-agent.core:json-parse arguments)
                                             (error () nil))
                                           arguments)))))))

;;; ============================================================
;;; OpenAI Message Conversion
;;; ============================================================

(defun convert-message-to-openai (msg)
  "Convert a message to OpenAI format.

Parameters:
  MSG - Message plist

Returns:
  Hash-table in OpenAI format"
  (let ((ht (make-hash-table :test 'equal))
        (role (getf msg :role))
        (content (getf msg :content))
        (tool-calls (getf msg :tool-calls))
        (tool-call-id (getf msg :tool-call-id)))
    ;; Set role
    (setf (gethash "role" ht)
          (string-downcase (string role)))
    ;; Set content
    (when content
      (setf (gethash "content" ht) content))
    ;; Handle tool calls (for assistant messages)
    (when (and (eq role :assistant) tool-calls)
      (setf (gethash "tool_calls" ht)
            (coerce
             (loop for tc in tool-calls
                   collect (let ((tc-ht (make-hash-table :test 'equal))
                                 (fn-ht (make-hash-table :test 'equal)))
                             (setf (gethash "id" tc-ht) (getf tc :id))
                             (setf (gethash "type" tc-ht) "function")
                             (setf (gethash "name" fn-ht)
                                   (string-downcase (string (getf tc :name))))
                             (setf (gethash "arguments" fn-ht)
                                   (let ((args (getf tc :arguments)))
                                     (if (stringp args)
                                         args
                                         (cl-agent.core:json-stringify args))))
                             (setf (gethash "function" tc-ht) fn-ht)
                             tc-ht))
             'vector)))
    ;; Handle tool result (for tool messages)
    (when (eq role :tool)
      (setf (gethash "tool_call_id" ht) tool-call-id))
    ht))

(defun convert-messages-to-openai (messages)
  "Convert messages to OpenAI format.

Parameters:
  MESSAGES - List of message plists

Returns:
  Vector of OpenAI format messages"
  (coerce (mapcar #'convert-message-to-openai messages) 'vector))
