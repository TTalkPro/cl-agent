;;;; tool-search.lisp
;;;; CL-Agent Kernel Filters - 渐进式工具披露 (:chat)
;;;;
;;;; 概述（对标 clj-agent advisor/tool_search.clj + Spring ToolSearchToolCallingAdvisor）：
;;;;   工具多了以后，每轮把全部工具的 JSON Schema 发给模型很烧 token。
;;;;   渐进式披露的做法是：**首轮只给一个 search_tools 工具**，模型自己
;;;;   描述需求去检索，检索到什么才暴露什么。
;;;;
;;;;   三件套（缺一不可）：
;;;;   1. search_tools 内联工具：模型调它 → 检索 → 记下发现集合
;;;;   2. IToolIndex 协议：用户注入的检索器（内置零依赖的关键词实现）
;;;;   3. :chat filter：每轮把暴露的工具改写为 [search_tools] + 已发现的
;;;;
;;;;   发现集合按 conversation-id 隔离，filter 与 search_tools 共享同一份
;;;;   （闭包捕获）——所以两者必须成对创建：tool-search-filter 内部自建
;;;;   search_tools，调用方不用（也不该）自己往 :tools 里加它。
;;;;
;;;; 历史：此前这里是个**装饰品**——search_tools 只存在于注释里，
;;;; `:discovered-tools` 只有读没有写，于是 filter 永远走 no-op 分支，
;;;; 「渐进式披露」一次都没生效过；search-tools 本身还有 subseq 越界，
;;;; 只要匹配数 < min(limit, 工具总数) 就崩（几乎必崩）；注释承诺的
;;;; 「中文按二元组切分」也没写，中文查询恒 0 命中。三件全废，而 README
;;;; 一直把它列为内置 filter 之一、写着「省 78% token」。

(in-package #:cl-agent.core)

;;; ============================================================
;;; IToolIndex 协议
;;; ============================================================

(defgeneric search-tools (index query &key limit)
  (:documentation "工具检索接口。

  参数：
  - index   实现 search-tools 的对象
  - query   查询字符串（模型描述的需求）
  - limit   最大返回数

  返回：**tool-callback 列表**（按相关度降序，不含不相关的）"))

;;; ============================================================
;;; 分词（零依赖）
;;; ============================================================

(defun cjk-char-p (char)
  "是否 CJK 统一表意文字。"
  (let ((code (char-code char)))
    (or (<= #x4E00 code #x9FFF)      ; CJK 统一表意
        (<= #x3400 code #x4DBF))))   ; 扩展 A

(defun token-separator-p (char)
  (or (char= char #\Space) (char= char #\Tab) (char= char #\Newline)
      (char= char #\_) (char= char #\-) (char= char #\.) (char= char #\,)
      (char= char #\() (char= char #\)) (char= char #\/) (char= char #\:)
      (char= char #\；) (char= char #\，) (char= char #\。)))

(defun split-and-tokenize (text)
  "分词：ASCII 段按分隔符切，CJK 按**二元组**切。全部小写化。

  中文为什么要 bigram：中文不用空格分词，整段拿来比对等于要求整串相等——
  查询「天气」与描述「查询天气」永远交不上。切成二元组后
  「查询天气」→ (查询 询天 天气)、「天气」→ (天气)，就能交上。
  （此前注释承诺了二元组，代码里没有，于是中文检索恒 0 命中。）"
  (let ((lower (string-downcase (string text)))
        (tokens nil)
        (ascii-start nil))
    (flet ((flush-ascii (end)
             (when (and ascii-start (> end ascii-start))
               (push (subseq lower ascii-start end) tokens))
             (setf ascii-start nil)))
      (loop for i from 0 below (length lower)
            for c = (char lower i)
            do (cond
                 ((token-separator-p c) (flush-ascii i))
                 ((cjk-char-p c)
                  (flush-ascii i)
                  ;; 二元组：与下一个 CJK 字符组成词。末尾单字也收——
                  ;; 否则单字查询（如「税」）永远无法命中。
                  (if (and (< (1+ i) (length lower))
                           (cjk-char-p (char lower (1+ i))))
                      (push (subseq lower i (+ i 2)) tokens)
                      (push (subseq lower i (1+ i)) tokens)))
                 (t (unless ascii-start (setf ascii-start i)))))
      (flush-ascii (length lower)))
    (nreverse tokens)))

(defun count-matches (list-a list-b)
  "两个词列表的交集大小。"
  (length (intersection list-a list-b :test #'string=)))

;;; ============================================================
;;; 关键词索引（零依赖内置实现）
;;; ============================================================

(defclass keyword-tool-index ()
  ((tools :initarg :tools :reader keyword-tool-index-tools))
  (:documentation "关键词匹配索引（名称/描述分词重叠打分）。

  零依赖的兜底实现。要更好的召回就自己实现 search-tools
  （向量检索、BM25…），经协议注入——框架不引入检索依赖。"))

(defun make-keyword-tool-index (tools)
  "创建关键词工具索引。TOOLS 为工具引用列表（符号/名称/callback）。"
  (make-instance 'keyword-tool-index :tools (resolve-tool-callbacks tools)))

(defmethod search-tools ((index keyword-tool-index) query &key (limit 5))
  (let* ((query-words (split-and-tokenize query))
         (scored (loop for cb in (keyword-tool-index-tools index)
                       for name = (tool-callback-name cb)
                       for desc = (tool-definition-description
                                   (tool-callback-definition cb))
                       ;; 名称匹配权重 2，描述权重 1
                       for score = (+ (* 2 (count-matches (split-and-tokenize name)
                                                          query-words))
                                      (count-matches (split-and-tokenize desc)
                                                     query-words))
                       when (plusp score) collect (cons cb score)))
         (ranked (sort scored #'> :key #'cdr)))
    ;; 取前 limit 个——长度必须按**过滤后**的 ranked 算。
    ;; 此前写的是 (min limit (length scored))，scored 是过滤**前**的全量：
    ;; 匹配数 < min(limit, 工具总数) 时 subseq 直接越界报错，几乎每次都崩。
    (mapcar #'car (subseq ranked 0 (min limit (length ranked))))))

;;; ============================================================
;;; tool-search filter（内含 search_tools 内联工具）
;;; ============================================================

(defparameter *tool-search-instruction*
  "你能用的工具需要先检索：用 search_tools 描述你要做的事来找工具，
找到后直接调用它们。不要臆造未列出的工具。"
  "挂 tool-search-filter 时追加给模型的系统提示。")

(defun tool-search-filter (index &key (limit 5) (instruction *tool-search-instruction*)
                                 (max-sessions 256))
  "创建渐进式工具披露 filter（:chat 链）。

  参数：
  - index        实现 search-tools 的工具索引
  - limit        单次检索返回上限
  - instruction  追加的系统提示；nil = 不加
  - max-sessions  会话表上限（LRU 淘汰，防长驻服务内存泄漏）；0 = 不限

  行为：
  - 每轮把暴露给模型的工具改写为 **[search_tools] + 本会话已发现的工具**
  - 首轮只有 search_tools 一个 schema —— 这才是省 token 的来源
  - 模型调 search_tools(query) → 检索 → 记入本会话发现集合 → 下轮可直接调
  - instruction 系统消息**每会话只追加一次**（多轮循环里不重复膨胀）

  search_tools 由本函数内部创建并注入，**不要**自己往 build-kernel 的
  :tools 里加它。工具执行只认本次请求 options 里的工具
  （find-callback-for-call 的安全边界），而 filter 改写的正是那份 options，
  所以注入是生效的。

  发现集合按 conversation-id 隔离；无 conversation-id 时退化为单一默认会话。

  用法：
    (build-kernel :model m
                  :tools '(get-weather get-stock send-mail ...)   ; 全量
                  :filters (list (tool-search-filter
                                  (make-keyword-tool-index
                                   '(get-weather get-stock send-mail ...)))))"
  (let ((sessions (make-hash-table :test #'equal))   ; key -> (:discovered (names) :instructed t)
        (lock (bt:make-lock "tool-search-sessions"))
        (session-order nil))                          ; keys in insertion order (oldest last)
    (labels ((session-key (ctx) (or (getf ctx :conversation-id) :default))
             (ensure-session (key)
               "确保 KEY 在 sessions 里有一个 plist 条目；新会话时做淘汰。"
               (or (gethash key sessions)
                   (progn
                     (when (and (> max-sessions 0)
                                (>= (hash-table-count sessions) max-sessions))
                       ;; 淘汰最旧会话
                       (let ((old (car (last session-order))))
                         (remhash old sessions)
                         (setf session-order (butlast session-order))))
                     (push key session-order)
                     (setf (gethash key sessions) '(:discovered nil :instructed nil)))))
             (discovered (ctx)
               (bt:with-lock-held (lock)
                 (getf (gethash (session-key ctx) sessions) :discovered)))
             (record (ctx names)
               (bt:with-lock-held (lock)
                 (let ((key (session-key ctx)))
                   (ensure-session key)
                   (setf (getf (gethash key sessions) :discovered)
                         (union (getf (gethash key sessions) :discovered)
                                names :test #'string=)))))
             (consume-instruction (ctx)
               "返回该会话是否需要注入 instruction，并标记为已注入。首次返回 t。"
               (bt:with-lock-held (lock)
                 (let ((key (session-key ctx)))
                   (ensure-session key)
                   (let ((entry (gethash key sessions)))
                     (cond
                       ((getf entry :instructed) nil)
                       (t (setf (getf entry :instructed) t) t)))))))
      (let ((search-cb
              (make-tool-callback
               (lambda (&key query tool-context)
                 (let ((found (search-tools index (or query "") :limit limit)))
                   (if found
                       (progn
                         (record tool-context (mapcar #'tool-callback-name found))
                         (format nil "找到 ~D 个工具，现在可以直接调用：~%~{  - ~A~%~}"
                                 (length found)
                                 (mapcar (lambda (cb)
                                           (format nil "~A：~A"
                                                   (tool-callback-name cb)
                                                   (tool-definition-description
                                                    (tool-callback-definition cb))))
                                         found)))
                       "没有找到匹配的工具。换个说法再试，或告诉用户你做不到。")))
               :name "search_tools"
               :description "按需求检索可用工具。先用它找到工具，再调用找到的工具。"
               :parameters '((query :string "描述你要做什么（如「查天气」）" :required-p t)
                             (tool-context :object "宿主注入")))))
        (make-filter
         :tool-search
         :chat
         (lambda (prompt chain)
           (let* ((options (prompt-options prompt))
                  (ctx (chat-options-tool-context options))
                  (found-names (discovered ctx))
                  (all (chat-options-tool-callbacks options))
                  ;; 暴露集 = search_tools + 本会话已发现的
                  (exposed (cons search-cb
                                 (remove-if-not
                                  (lambda (cb)
                                    (member (tool-callback-name cb) found-names
                                            :test #'string=))
                                  all)))
                  (new-options (chat-options-with-tools options :tool-callbacks exposed))
                  (messages (prompt-messages prompt))
                  ;; instruction 每会话只追加一次（consume-instruction 标记后不再重复）
                  (new-messages
                    (if (and instruction (consume-instruction ctx))
                        (append messages (list (system-message instruction)))
                        messages)))
             (funcall chain (prompt-copy prompt
                                         :messages new-messages
                                         :options new-options)))))))))
