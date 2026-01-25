;;;; anthropic.lisp
;;;; CL-Agent LLM - Anthropic Schema Converter
;;;;
;;;; Overview:
;;;;   Converts tool schemas to Anthropic Claude format.
;;;;   Anthropic uses input_schema instead of parameters.

(in-package #:cl-agent.llm)

;;; ============================================================
;;; Anthropic Tool Schema Format
;;; ============================================================
;;;
;;; Anthropic expects tools in this format:
;;; {
;;;   "name": "get_weather",
;;;   "description": "Get weather for a city",
;;;   "input_schema": {
;;;     "type": "object",
;;;     "properties": {
;;;       "city": {"type": "string", "description": "City name"}
;;;     },
;;;     "required": ["city"]
;;;   }
;;; }

(defun convert-tool-to-anthropic (tool)
  "Convert a tool schema to Anthropic format.

Parameters:
  TOOL - Tool plist (:name :description :input-schema)

Returns:
  Hash-table in Anthropic format"
  (let ((ht (make-hash-table :test 'equal))
        (name (getf tool :name))
        (description (getf tool :description))
        (schema (or (getf tool :input-schema)
                    (getf tool :parameters))))
    (setf (gethash "name" ht)
          (if (stringp name)
              name
              (string-downcase (string name))))
    (setf (gethash "description" ht) description)
    (setf (gethash "input_schema" ht)
          (cond
            ((hash-table-p schema) schema)
            ((and (listp schema) (keywordp (first schema)))
             (cl-agent.kernel:schema-to-hash-table schema))
            (t (let ((empty (make-hash-table :test 'equal)))
                 (setf (gethash "type" empty) "object")
                 (setf (gethash "properties" empty) (make-hash-table :test 'equal))
                 (setf (gethash "required" empty) #())
                 empty))))
    ht))

(defun convert-tools-to-anthropic-format (tools)
  "Convert a list of tools to Anthropic format.

Parameters:
  TOOLS - List of tool plists

Returns:
  Vector of Anthropic format tools"
  (coerce (mapcar #'convert-tool-to-anthropic tools) 'vector))

;;; ============================================================
;;; Anthropic Tool Call Parsing
;;; ============================================================

(defun parse-anthropic-tool-calls (content-blocks)
  "Parse tool calls from Anthropic response content blocks.

Parameters:
  CONTENT-BLOCKS - Content blocks from Anthropic response

Returns:
  Normalized tool call list"
  (let ((blocks (if (vectorp content-blocks)
                    (coerce content-blocks 'list)
                    content-blocks)))
    (loop for block in blocks
          for block-type = (if (hash-table-p block)
                               (gethash "type" block)
                               (getf block :type))
          when (string= block-type "tool_use")
          collect (let ((id (if (hash-table-p block)
                                (gethash "id" block)
                                (getf block :id)))
                        (name (if (hash-table-p block)
                                  (gethash "name" block)
                                  (getf block :name)))
                        (input (if (hash-table-p block)
                                   (gethash "input" block)
                                   (getf block :input))))
                    (list :id id
                          :name (intern (string-upcase name) :keyword)
                          :arguments input)))))

;;; ============================================================
;;; Anthropic Message Conversion
;;; ============================================================

(defun convert-message-to-anthropic (msg)
  "Convert a message to Anthropic format.

Parameters:
  MSG - Message plist

Returns:
  Hash-table in Anthropic format"
  (let ((ht (make-hash-table :test 'equal))
        (role (getf msg :role))
        (content (getf msg :content))
        (tool-calls (getf msg :tool-calls))
        (tool-call-id (getf msg :tool-call-id)))
    (cond
      ;; System messages are handled separately in Anthropic
      ((eq role :system)
       nil)  ; Return nil, handled by caller

      ;; Tool result messages become user messages with tool_result blocks
      ((eq role :tool)
       (setf (gethash "role" ht) "user")
       (let ((block (make-hash-table :test 'equal)))
         (setf (gethash "type" block) "tool_result")
         (setf (gethash "tool_use_id" block) tool-call-id)
         (setf (gethash "content" block) (or content ""))
         (setf (gethash "content" ht) (vector block)))
       ht)

      ;; Assistant messages with tool calls
      ((and (eq role :assistant) tool-calls)
       (setf (gethash "role" ht) "assistant")
       (let ((blocks nil))
         ;; Add text block if content exists
         (when (and content (not (string= content "")))
           (let ((text-block (make-hash-table :test 'equal)))
             (setf (gethash "type" text-block) "text")
             (setf (gethash "text" text-block) content)
             (push text-block blocks)))
         ;; Add tool_use blocks
         (dolist (tc tool-calls)
           (let ((tc-block (make-hash-table :test 'equal)))
             (setf (gethash "type" tc-block) "tool_use")
             (setf (gethash "id" tc-block) (or (getf tc :id) (cl-agent.core:generate-uuid)))
             (setf (gethash "name" tc-block)
                   (string-downcase (string (getf tc :name))))
             (setf (gethash "input" tc-block)
                   (let ((args (getf tc :arguments)))
                     (cond
                       ((hash-table-p args) args)
                       ((and (listp args) (keywordp (first args)))
                        ;; Convert plist to hash-table
                        (let ((args-ht (make-hash-table :test 'equal)))
                          (loop for (k v) on args by #'cddr
                                do (setf (gethash (string-downcase (symbol-name k)) args-ht) v))
                          args-ht))
                       (t (make-hash-table :test 'equal)))))
             (push tc-block blocks)))
         (setf (gethash "content" ht) (coerce (nreverse blocks) 'vector)))
       ht)

      ;; Regular messages
      (t
       (setf (gethash "role" ht)
             (case role
               (:user "user")
               (:assistant "assistant")
               (otherwise "user")))
       (setf (gethash "content" ht) (or content ""))
       ht))))

(defun convert-messages-to-anthropic (messages)
  "Convert messages to Anthropic format, extracting system message.

Parameters:
  MESSAGES - List of message plists

Returns:
  Plist (:system system-text :messages messages-vector)"
  (let ((system-parts nil)
        (converted nil))
    (dolist (msg messages)
      (if (eq (getf msg :role) :system)
          (push (getf msg :content) system-parts)
          (let ((converted-msg (convert-message-to-anthropic msg)))
            (when converted-msg
              (push converted-msg converted)))))
    (list :system (when system-parts
                    (format nil "~{~A~^~%~}" (nreverse system-parts)))
          :messages (coerce (nreverse converted) 'vector))))
