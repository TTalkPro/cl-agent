;;;; search.lisp
;;;; CL-Agent - 搜索工具
;;;;
;;;; 概述：
;;;;   实现 Web 搜索功能
;;;;
;;;; 特性：
;;;;   - 多搜索引擎支持
;;;;   - 结果解析
;;;;   - 错误处理

(in-package :cl-agent.tools)

;;; ============================================================
;;; 动态配置变量（通过动态绑定传递）
;;; ============================================================

(defvar *default-search-engine* :duckduckgo
  "默认搜索引擎（动态变量，通过 provider 绑定）")

(defvar *search-results-limit* 10
  "默认搜索结果数量限制（动态变量，通过 provider 绑定）")

;;; ============================================================
;;; 搜索引擎配置
;;; ============================================================

(defun get-search-api-url (engine)
  "获取搜索引擎 API URL

  参数：
    ENGINE - 搜索引擎名称

  返回：
    API URL 字符串"
  (case engine
    (:duckduckgo "https://api.duckduckgo.com/")
    (:google "https://www.googleapis.com/customsearch/v1")
    (:bing "https://api.bing.microsoft.com/v7.0/search")
    (otherwise (error "Unknown search engine: ~A" engine))))

;;; ============================================================
;;; DuckDuckGo 搜索（无需 API Key）
;;; ============================================================

(defun duckduckgo-search (query &key (max-results *search-results-limit*))
  "使用 DuckDuckGo 进行搜索

  参数：
    QUERY       - 搜索查询
    MAX-RESULTS - 最大结果数量

  返回：
    结果列表

  说明：
    DuckDuckGo 不需要 API Key，适合快速测试"
  ;; DuckDuckGo Instant Answer API
  (let ((api-url "https://api.duckduckgo.com/")
        (params `(("q" . ,query)
                  ("format" . "json"))))

    (handler-case
        (let* ((url-string (cl-agent.core:build-url api-url params))
               (response (dex:get url-string))
               (data (cl-agent.core:json-parse response)))

          ;; 解析结果
          (let ((results '()))
            ;; Abstract（摘要）
            (when (gethash "Abstract" data)
              (push `(:title "Abstract"
                           :url ,(gethash "AbstractURL" data "")
                           :snippet ,(gethash "Abstract" data "")
                           :source :duckduckgo)
                    results))

            ;; Related Topics
            (when (gethash "RelatedTopics" data)
              (dolist (topic (gethash "RelatedTopics" data))
                (when (and (hash-table-p topic)
                           (gethash "Text" topic)
                           (gethash "FirstURL" topic))
                  (push `(:title ,(gethash "Text" topic "")
                               :url ,(gethash "FirstURL" topic "")
                               :snippet ,(gethash "Text" topic "")
                               :source :duckduckgo)
                        results)
                  (when (>= (length results) max-results)
                    (return)))))

            ;; 返回结果
            (nreverse results)))

      (error (e)
        (signal-error 'tool-execution-error
                      :message (format nil "DuckDuckGo search failed: ~A" e)
                      :tool-name :search
                      :cause e)))))

;;; ============================================================
;;; Google 搜索（需要 API Key）
;;; ============================================================

(defun google-search (query &key (max-results *search-results-limit*)
                                 (api-key nil)
                                 (search-engine-id nil))
  "使用 Google Custom Search API 进行搜索

  参数：
    QUERY            - 搜索查询
    MAX-RESULTS      - 最大结果数量
    API-KEY          - Google API Key
    SEARCH-ENGINE-ID - Custom Search Engine ID

  返回：
    结果列表

  说明：
    需要设置 Google API Key 和 Custom Search Engine ID"
  (let ((api-url "https://www.googleapis.com/customsearch/v1")
        (api-key (or api-key (cl-agent.core:get-env "GOOGLE_API_KEY")))
        (cx (or search-engine-id (cl-agent.core:get-env "GOOGLE_CSE_ID"))))

    (unless api-key
      (error "Google API Key required"))

    (unless cx
      (error "Google Custom Search Engine ID required"))

    (handler-case
        (let* ((params `(("key" . ,api-key)
                         ("cx" . ,cx)
                         ("q" . ,query)
                         ("num" . ,(princ-to-string max-results))))
               (url-string (cl-agent.core:build-url api-url params))
               (response (dex:get url-string))
               (data (cl-agent.core:json-parse response)))

          ;; 解析结果
          (let ((items (gethash "items" data)))
            (mapcar (lambda (item)
                      (let ((title (gethash "title" item ""))
                            (link (gethash "link" item ""))
                            (snippet (gethash "snippet" item "")))
                        `(:title ,title
                          :url ,link
                          :snippet ,snippet
                          :source :google)))
                    items)))

      (error (e)
        (signal-error 'tool-execution-error
                      :message (format nil "Google search failed: ~A" e)
                      :tool-name :search
                      :cause e)))))

;;; ============================================================
;;; 统一搜索接口
;;; ============================================================

(defun web-search (query &key
                         (engine *default-search-engine*)
                         (max-results *search-results-limit*)
                         &allow-other-keys)
  "统一的 Web 搜索接口

  参数：
    QUERY       - 搜索查询
    ENGINE      - 搜索引擎（:duckduckgo, :google, :bing）
    MAX-RESULTS - 最大结果数量

  返回：
    结果列表

  示例：
    (web-search \\"Common Lisp programming\\" :engine :duckduckgo)"
  (case engine
    (:duckduckgo
     (duckduckgo-search query :max-results max-results))
    (:google
     (google-search query :max-results max-results))
    (:bing
     (error "Bing search not implemented yet"))
    (otherwise
     (error "Unknown search engine: ~A" engine))))

;;; ============================================================
;;; 搜索工具注册
;;; ============================================================

(defun register-search-tools ()
  "注册搜索工具

  返回：
    注册的工具数量"
  (register-tool
   :search
   "Search the web for information using search engines"
   #'web-search
   :parameters '((:query
                  :type string
                  :description "Search query"
                  :required t)
                 (:engine
                  :type string
                  :description "Search engine (duckduckgo, google, bing)"
                  :required nil
                  :default "duckduckgo")
                 (:max-results
                  :type integer
                  :description "Maximum number of results"
                  :required nil
                  :default 10))
   :category :search
   :permissions '(:network-access))

  ;; 注册快速搜索工具（使用默认设置）
  (register-tool
   :quick-search
   "Quick web search with default settings"
   (lambda (query &key (max-results 5))
     (declare (ignore max-results))
     (web-search query))
   :parameters '((:query
                  :type string
                  :description "Search query"
                  :required t))
   :category :search
   :permissions '(:network-access))

  2)  ;; 返回注册的工具数量

;;; ============================================================
;;; 结果格式化
;;; ============================================================

(defun format-search-results (results)
  "格式化搜索结果为可读字符串

  参数：
    RESULTS - 搜索结果列表

  返回：
    格式化字符串"
  (with-output-to-string (s)
    (format s "Search Results:~%")
    (format s "================~%")
    (loop for result in results
          for i from 1
          do (format s "~A. ~A~%" i (getf result :title))
          do (format s "   URL: ~A~%" (getf result :url))
          do (format s "   ~A~%~%" (getf result :snippet)))))

(defun search-results-to-markdown (results)
  "将搜索结果转换为 Markdown 格式

  参数：
    RESULTS - 搜索结果列表

  返回：
    Markdown 字符串"
  (with-output-to-string (s)
    (format s "## Search Results~%~%")
    (loop for result in results
          for i from 1
          do (format s "~A. [~A](~A)~%~%"
                    i
                    (getf result :title)
                    (getf result :url))
          do (format s "   ~A~%~%~%" (getf result :snippet)))))

;;; ============================================================
;;; 搜索工具辅助函数
;;; ============================================================

(defun extract-urls (results)
  "从搜索结果中提取 URL 列表

  参数：
    RESULTS - 搜索结果列表

  返回：
    URL 列表"
  (mapcar (lambda (result)
            (getf result :url))
          results))

(defun extract-titles (results)
  "从搜索结果中提取标题列表

  参数：
    RESULTS - 搜索结果列表

  返回：
    标题列表"
  (mapcar (lambda (result)
            (getf result :title))
          results))

(defun filter-results-by-keyword (results keyword)
  "根据关键词过滤搜索结果

  参数：
    RESULTS - 搜索结果列表
    KEYWORD - 关键词

  返回：
    过滤后的结果列表"
  (remove-if-not (lambda (result)
                   (or (search keyword (getf result :title) :test #'equalp)
                       (search keyword (getf result :snippet) :test #'equalp)))
                 results))

;;; ============================================================
;;; 自动初始化
;;; ============================================================

;; 自动注册搜索工具（当加载此文件时）
;; (register-search-tools)  ; Temporarily disabled to test loading
