;;;; tool-search-advisor.lisp
;;;; CL-Agent Client - ToolSearchToolCallingAdvisor（渐进式工具披露）
;;;;
;;;; 概述（对标 Spring AI 2.0 ToolSearchToolCallingAdvisor）：
;;;;   工具集很大时，把全部工具 schema 每轮塞给模型既浪费 token
;;;;   又稀释模型注意力。本 Advisor 是 tool-calling-advisor 的
;;;;   drop-in 替代，实现"渐进式工具披露"：
;;;;
;;;;   1. 循环开始时索引全量工具（不发给模型），并在系统提示末尾
;;;;      追加后缀，告知模型 tool_search 的存在与用法
;;;;   2. 每轮只注入：内置的 tool_search 检索工具 + 已被发现的工具
;;;;   3. 模型需要能力时先调 tool_search(query) 按关键词检索，
;;;;      命中的工具加入"已发现集合"，下一轮起即可直接调用
;;;;
;;;;   会话级索引（对标 Spring 的 "index the full tool set once per session"）：
;;;;   索引按 session id 缓存在 advisor 实例上，并用工具集指纹判断
;;;;   是否需要重建——同一会话的后续请求若工具集未变则直接复用。
;;;;   session id 取自 request context 的会话 ID（与记忆类 Advisor 同源）。
;;;;
;;;;   发现集合仍是请求级状态（存于 request context），
;;;;   同一 advisor 实例可安全服务并发请求。
;;;;
;;;;   与 Spring 的实现差异：
;;;;   Spring 的"已发现集合"是扫描对话记录中出现过的工具名推导出来的
;;;;   （referenceToolNameAccumulation）；本实现用 context 里的显式集合，
;;;;   不依赖工具名在文本中原样出现，行为更确定。
;;;;
;;;;   实现完全建立在 tool-calling-advisor 的细粒度钩子之上：
;;;;   initialize-loop 建索引，before-call 逐轮收窄工具集。
;;;;
;;;; 用法（显式替换自动注册的默认 advisor）：
;;;;   (make-chat-client model
;;;;     :advisors (list (make-tool-search-tool-calling-advisor)))

(in-package #:cl-agent.client)

(defparameter *tool-search-system-message-suffix*
  "

你可以使用一个名为 tool_search 的特殊工具来按需发现其它工具。
当前上下文中只暴露了部分工具——当你需要完成某个动作但没有看到
合适的工具时，先用 tool_search 按能力关键词检索，检索到的工具
在后续轮次即可直接调用。"
  "追加到系统提示末尾的后缀，告知模型渐进式工具披露的存在
（对标 Spring 的 DEFAULT_SYSTEM_PROMPT_SUFFIX.md）。

没有这段说明时，模型往往不知道还有别的工具可以检索，
只会在已暴露的少量工具里打转。")

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
    :documentation "单次检索返回的工具数上限")
   (system-message-suffix
    :initarg :system-message-suffix
    :initform *tool-search-system-message-suffix*
    :reader tool-search-system-message-suffix
    :documentation "追加到系统提示末尾的后缀
（对标 systemMessageSuffix）。NIL 表示不追加。")
   (max-sessions
    :initarg :max-sessions
    :initform 100
    :reader tool-search-max-sessions
    :documentation "索引缓存保留的最大会话数，超出时淘汰最久未用的
（对标 ToolIndexEvictionStrategy）")
   (sessions
    :initform (make-hash-table :test #'equal)
    :reader tool-search-sessions
    :documentation "会话级索引缓存：session-id → tool-search-index-entry")
   (sessions-lock
    :initform (bt:make-lock "tool-search-sessions")
    :reader tool-search-sessions-lock
    :documentation "保护 sessions 的锁——同一 advisor 实例可被并发请求共享")
   (tick
    :initform 0
    :accessor tool-search-tick
    :documentation "单调递增的访问计数，用于 LRU 淘汰"))
  (:documentation "渐进式工具披露的工具循环 Advisor
（对标 ToolSearchToolCallingAdvisor）"))

(defstruct (tool-search-index-entry (:conc-name tool-search-entry-))
  "会话级索引缓存条目"
  (fingerprint "" :type string)
  (tools nil :type list)
  (last-access 0 :type integer))

(defun make-tool-search-tool-calling-advisor
    (&rest initargs
     &key match-mode max-results system-message-suffix max-sessions
          manager max-iterations order eligibility conversation-history-enabled)
  "创建 ToolSearch 工具循环 Advisor（tool-calling-advisor 的替代品）。

参数：
  MATCH-MODE            - :substring（默认）/ :regex
  MAX-RESULTS           - 单次检索返回上限（默认 5）
  SYSTEM-MESSAGE-SUFFIX - 系统提示后缀（默认
                          *tool-search-system-message-suffix*，NIL 表示不加）
  MAX-SESSIONS          - 索引缓存最大会话数（默认 100）
  其余参数与 make-tool-calling-advisor 一致。"
  (declare (ignore match-mode max-results system-message-suffix max-sessions
                   manager max-iterations order eligibility
                   conversation-history-enabled))
  (apply #'make-instance 'tool-search-tool-calling-advisor initargs))

;;; ============================================================
;;; 会话级索引缓存
;;; ============================================================

(defun tool-set-fingerprint (tools)
  "工具集指纹：按名排序后拼接。工具集变化时指纹随之变化，触发重建索引。"
  (format nil "~{~A~^,~}"
          (sort (mapcar #'tool-callback-name tools) #'string<)))

(defun tool-search-evict-if-needed (advisor)
  "超出 max-sessions 时淘汰最久未访问的会话。调用方须已持有锁。"
  (let ((sessions (tool-search-sessions advisor))
        (limit (tool-search-max-sessions advisor)))
    (loop while (> (hash-table-count sessions) limit)
          do (let ((oldest-key nil)
                   (oldest-tick nil))
               (maphash (lambda (key entry)
                          (let ((tick (tool-search-entry-last-access entry)))
                            (when (or (null oldest-tick) (< tick oldest-tick))
                              (setf oldest-key key
                                    oldest-tick tick))))
                        sessions)
               ;; 理论上 count > limit >= 0 时必有条目，防御性退出以免死循环
               (if oldest-key
                   (remhash oldest-key sessions)
                   (return))))))

(defun tool-search-index-tools (advisor session-id tools)
  "取会话 SESSION-ID 的索引：工具集指纹未变则复用缓存，否则重建。
返回索引到的工具列表。"
  (let ((fingerprint (tool-set-fingerprint tools)))
    (bt:with-lock-held ((tool-search-sessions-lock advisor))
      (let* ((sessions (tool-search-sessions advisor))
             (tick (incf (tool-search-tick advisor)))
             (entry (gethash session-id sessions)))
        (cond
          ;; 命中且工具集未变：复用
          ((and entry (string= (tool-search-entry-fingerprint entry) fingerprint))
           (setf (tool-search-entry-last-access entry) tick)
           (tool-search-entry-tools entry))
          ;; 未命中或工具集已变：重建
          (t
           (setf (gethash session-id sessions)
                 (make-tool-search-index-entry :fingerprint fingerprint
                                               :tools tools
                                               :last-access tick))
           (tool-search-evict-if-needed advisor)
           tools))))))

(defun tool-search-session-id (request)
  "本请求的 session id：取会话 ID（与记忆类 Advisor 同源）"
  (request-conversation-id request))

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

(defun tool-search-augment-system-message (prompt suffix)
  "把 SUFFIX 追加到首条 system 消息末尾；没有 system 消息时新建一条置顶
（对标 Prompt#augmentSystemMessage）"
  (if (null suffix)
      prompt
      (let* ((messages (copy-list (prompt-messages prompt)))
             (pos (position-if #'system-message-p messages)))
        (if pos
            (progn
              (setf (nth pos messages)
                    (system-message (concatenate 'string
                                                 (message-text (nth pos messages))
                                                 suffix)))
              (prompt-copy prompt :messages messages))
            (prompt-copy prompt
                         :messages (cons (system-message suffix) messages))))))

(defmethod tool-advisor-initialize-loop ((advisor tool-search-tool-calling-advisor)
                                         request)
  "索引全量工具（会话级缓存）；初始化发现集合与检索工具；追加系统提示后缀"
  (let* ((context (client-request-context request))
         (prompt (client-request-prompt request))
         (options (prompt-options prompt))
         (all-tools (append (chat-options-tool-callbacks options)
                            (resolve-tool-callbacks
                             (chat-options-tool-names options)))))
    ;; 未配置任何工具时不建索引、不改提示——退化为普通工具循环
    (when (null all-tools)
      (setf (gethash +tool-search-all-tools-key+ context) nil)
      (return-from tool-advisor-initialize-loop request))
    (let ((indexed (tool-search-index-tools advisor
                                            (tool-search-session-id request)
                                            all-tools)))
      (setf (gethash +tool-search-all-tools-key+ context) indexed
            (gethash +tool-search-discovered-key+ context) nil
            (gethash +tool-search-callback-key+ context)
            (make-tool-search-callback advisor context)))
    (client-request-copy
     request
     :prompt (tool-search-augment-system-message
              prompt (tool-search-system-message-suffix advisor)))))

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
