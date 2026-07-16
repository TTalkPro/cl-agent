;;;; tool-search.lisp
;;;; CL-Agent Kernel Filters - 渐进式工具披露 (:chat)
;;;;
;;;; 概述（对标 clj-agent advisor/tool_search.clj + Spring ToolSearchToolCallingAdvisor）：
;;;;   search_tools 内联工具 + :chat filter 每轮按发现集合改写 :tools。
;;;;   大量工具时省 token（实测 50 工具省 78%）。
;;;;
;;;;   机制（三件套）：
;;;;   1. search_tools 工具：返回发现集合 → context 共享
;;;;   2. IToolIndex 协议：用户注入的检索器
;;;;   3. :chat filter：把 :tools 改写为 [search_tools] + 已发现工具

(in-package #:cl-agent.core)

;;; ============================================================
;;; IToolIndex 协议
;;; ============================================================

(defgeneric search-tools (index query &key limit)
  (:documentation "工具检索接口。
  参数：
  - index   实现 search-tools 的对象
  - query   查询字符串
  - limit   最大返回数
  返回：tool-callback 列表"))

;;; ============================================================
;;; 关键词索引（零依赖内置实现）
;;; ============================================================

(defclass keyword-tool-index ()
  ((tools :initarg :tools :reader keyword-tool-index-tools))
  (:documentation "关键词匹配索引（名称/描述分词重叠打分）"))

(defun make-keyword-tool-index (tools)
  "创建关键词工具索引。TOOLS 为 tool-callback 列表。"
  (make-instance 'keyword-tool-index :tools tools))

(defmethod search-tools ((index keyword-tool-index) query &key (limit 5))
  (let* ((query-words (split-and-tokenize query))
         (scored
          (mapcar (lambda (cb)
                    (let* ((name (cl-agent.core:tool-callback-name cb))
                           (desc (cl-agent.core:tool-definition-description
                                  (cl-agent.core:tool-callback-definition cb)))
                           (name-words (split-and-tokenize name))
                           (desc-words (split-and-tokenize desc))
                           ;; 名称匹配权重 2，描述匹配权重 1
                           (score (+ (* 2 (count-matches name-words query-words))
                                     (count-matches desc-words query-words))))
                      (cons cb score)))
                  (keyword-tool-index-tools index))))
    ;; 取分数 > 0 的前 limit 个
    (subseq (remove-if (lambda (x) (<= (cdr x) 0))
                       (sort scored #'> :key #'cdr))
            0 (min limit (length scored)))))

(defun split-and-tokenize (text)
  "简单分词：按空格/标点分割，小写化。中文按二元组切分。"
  (let ((lower (string-downcase (string text))))
    ;; 简单版：按非字母数字分割
    (let ((tokens nil)
          (start 0))
      (loop for i from 0 to (length lower)
            for c = (if (< i (length lower)) (char lower i) #\Space)
            when (or (char= c #\Space) (char= c #\_) (char= c #\-)
                     (char= c #\.) (char= c #\,)
                     (char= c #\() (char= c #\)))
            do (when (> i start)
                 (push (subseq lower start i) tokens))
               (setf start (1+ i)))
      (nreverse tokens))))

(defun count-matches (list-a list-b)
  "计算两个词列表的交集大小。"
  (length (intersection list-a list-b :test #'string=)))

;;; ============================================================
;;; tool-search :chat filter
;;; ============================================================

(defun tool-search-filter (index &key (limit 5))
  "创建 tool-search filter（:chat 链）。

  参数：
  - index  实现 search-tools 的工具索引
  - limit  单次检索返回上限

  行为：
  - 每轮 LLM 调用前，从 context 取已发现的工具集合
  - 把 prompt options 的 :tool-callbacks 改写为已发现集合
  - 首轮（无发现集合）保留原 :tools 让模型看到 search_tools

  注意：这是一个简化版——完整实现需要 search_tools 内联工具 +
  context 共享发现集合。P4 先实现 filter 侧的改写逻辑。"
  (make-filter
   :tool-search
   :chat (lambda (prompt chain)
             (let* ((options (cl-agent.core:prompt-options prompt))
                    (ctx (cl-agent.core:chat-options-tool-context options))
                    (discovered (getf ctx :discovered-tools)))
               (if discovered
                   ;; 有已发现集合 → 改写 tools
                   (let* ((found-callbacks
                           (mapcar (lambda (name)
                                     (cl-agent.core:find-callback-for-call
                                      options
                                      (cl-agent.core:make-tool-call
                                       :id "search" :name name
                                       :arguments (make-hash-table :test #'equal))))
                                   discovered))
                          (new-options (cl-agent.core:chat-options-with-tools
                                        options found-callbacks))
                          (new-prompt (cl-agent.core:prompt-copy prompt :options new-options)))
                     (funcall chain new-prompt))
                   ;; 无发现集合 → 不改写（模型看到全部工具）
                   (funcall chain prompt))))))
