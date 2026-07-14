;;;; tool-search-advisor.lisp
;;;; CL-Agent Client - ToolSearchToolCallingAdvisor（渐进式工具披露）
;;;;
;;;; 概述（对标 Spring AI 2.0 ToolSearchToolCallingAdvisor）：
;;;;   工具集很大时，把全部工具 schema 每轮塞给模型既浪费 token
;;;;   又稀释模型注意力。本 Advisor 是 tool-calling-advisor 的
;;;;   drop-in 替代，实现"渐进式工具披露"：
;;;;
;;;;   1. 循环开始时索引 prompt 配置的全量工具（不发给模型）
;;;;   2. 每轮只注入：内置的 tool_search 检索工具 + 已被发现的工具
;;;;   3. 模型需要能力时先调 tool_search(query) 按关键词检索，
;;;;      命中的工具加入"已发现集合"，下一轮起即可直接调用
;;;;
;;;;   发现集合是请求级状态（存于 request context），
;;;;   同一 advisor 实例可安全服务并发请求。
;;;;
;;;;   实现完全建立在 tool-calling-advisor 的细粒度钩子之上：
;;;;   initialize-loop 建索引，before-call 逐轮收窄工具集。
;;;;
;;;; 用法（显式替换自动注册的默认 advisor）：
;;;;   (make-chat-client model
;;;;     :advisors (list (make-tool-search-tool-calling-advisor)))

(in-package #:cl-agent.client)

(alexandria:define-constant +tool-search-all-tools-key+ "tool_search_all_tools"
  :test #'equal
  :documentation "request context 键：索引的全量工具")

(alexandria:define-constant +tool-search-discovered-key+ "tool_search_discovered"
  :test #'equal
  :documentation "request context 键：已发现（可直接调用）的工具")

(alexandria:define-constant +tool-search-callback-key+ "tool_search_callback"
  :test #'equal
  :documentation "request context 键：本请求的 tool_search callback 实例")

(defclass tool-search-tool-calling-advisor (tool-calling-advisor)
  ((match-mode
    :initarg :match-mode
    :initform :substring
    :reader tool-search-match-mode
    :documentation "检索匹配策略：:substring（多词计分，默认）/ :regex")
   (max-results
    :initarg :max-results
    :initform 5
    :reader tool-search-max-results
    :documentation "单次检索返回的工具数上限"))
  (:documentation "渐进式工具披露的工具循环 Advisor
（对标 ToolSearchToolCallingAdvisor）"))

(defun make-tool-search-tool-calling-advisor (&rest initargs
                                              &key match-mode max-results
                                                   manager max-iterations order)
  "创建 ToolSearch 工具循环 Advisor（tool-calling-advisor 的替代品）。

参数：
  MATCH-MODE     - :substring（默认）/ :regex
  MAX-RESULTS    - 单次检索返回上限（默认 5）
  其余参数与 make-tool-calling-advisor 一致。"
  (declare (ignore match-mode max-results manager max-iterations order))
  (apply #'make-instance 'tool-search-tool-calling-advisor initargs))

;;; ============================================================
;;; 工具检索
;;; ============================================================

(defun tool-search-text (callback)
  "工具的可检索文本：name + description"
  (let ((def (tool-callback-definition callback)))
    (string-downcase
     (format nil "~A ~A"
             (tool-definition-name def)
             (tool-definition-description def)))))

(defun rank-tools (tools query mode max-results)
  "按 QUERY 检索 TOOLS，返回按相关度排序的前 MAX-RESULTS 个"
  (ecase mode
    (:regex
     (let ((matches (remove-if-not
                     (lambda (cb)
                       (handler-case
                           (cl-ppcre:scan query (tool-search-text cb))
                         (error () nil)))
                     tools)))
       (subseq matches 0 (min max-results (length matches)))))
    (:substring
     (let* ((terms (remove "" (cl-ppcre:split "\\s+" (string-downcase query))
                           :test #'string=))
            (scored (loop for cb in tools
                          for text = (tool-search-text cb)
                          for score = (count-if (lambda (term)
                                                  (search term text))
                                                terms)
                          when (plusp score)
                            collect (cons score cb)))
            (sorted (mapcar #'cdr (sort scored #'> :key #'car))))
       (subseq sorted 0 (min max-results (length sorted)))))))

(defun make-tool-search-callback (advisor context)
  "构造本请求的 tool_search 工具（闭包捕获 request context：
检索命中即写入发现集合，下一轮生效）"
  (make-tool-callback
   (lambda (&key query)
     (let* ((all (gethash +tool-search-all-tools-key+ context))
            (matches (rank-tools all (or query "")
                                 (tool-search-match-mode advisor)
                                 (tool-search-max-results advisor))))
       (if matches
           (progn
             ;; 命中工具加入发现集合（按名去重）
             (setf (gethash +tool-search-discovered-key+ context)
                   (remove-duplicates
                    (append (gethash +tool-search-discovered-key+ context)
                            matches)
                    :key #'tool-callback-name :test #'string=))
             (format nil "找到 ~A 个匹配工具，现在可以直接调用：~%~{~A~^~%~}"
                     (length matches)
                     (mapcar (lambda (cb)
                               (let ((def (tool-callback-definition cb)))
                                 (format nil "- ~A: ~A"
                                         (tool-definition-name def)
                                         (tool-definition-description def))))
                             matches)))
           "未找到匹配的工具，请换一组关键词重试。")))
   :name "tool_search"
   :description "按关键词搜索可用工具。当前只暴露了部分工具；
当你需要完成任务但没有合适的工具时，先用本工具按能力关键词
（空格分隔多个词）检索，找到后即可在后续轮次直接调用。"
   :parameters '((query :string "能力关键词，空格分隔多个词" :required-p t))))

;;; ============================================================
;;; 钩子特化（建立在 tool-calling-advisor 的细粒度钩子上）
;;; ============================================================

(defmethod tool-advisor-initialize-loop ((advisor tool-search-tool-calling-advisor)
                                         request)
  "索引 prompt 配置的全量工具；初始化发现集合与检索工具"
  (let* ((context (client-request-context request))
         (options (prompt-options (client-request-prompt request)))
         (all-tools (append (chat-options-tool-callbacks options)
                            (resolve-tool-callbacks
                             (chat-options-tool-names options)))))
    (setf (gethash +tool-search-all-tools-key+ context) all-tools
          (gethash +tool-search-discovered-key+ context) nil
          (gethash +tool-search-callback-key+ context)
          (make-tool-search-callback advisor context)))
  request)

(defmethod tool-advisor-before-call ((advisor tool-search-tool-calling-advisor)
                                     request iteration)
  "每轮收窄工具集：只注入 tool_search + 已发现的工具"
  (declare (ignore iteration))
  (let* ((context (client-request-context request))
         (all-tools (gethash +tool-search-all-tools-key+ context)))
    (if (null all-tools)
        ;; 未配置任何工具：退化为普通行为
        request
        (let* ((prompt (client-request-prompt request))
               (exposed (cons (gethash +tool-search-callback-key+ context)
                              (gethash +tool-search-discovered-key+ context)))
               (narrowed (chat-options-with-tools (prompt-options prompt)
                                                  :tool-callbacks exposed)))
          (client-request-copy request
                               :prompt (prompt-copy prompt
                                                    :options narrowed))))))
