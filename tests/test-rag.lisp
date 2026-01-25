;;;; test-rag.lisp
;;;; CL-Agent - RAG 管道测试

(in-package :cl-agent/tests)

;; RAG 测试套件
(def-suite rag-suite :in cl-agent-tests:lisp-in-agents-suite
  :description "RAG 管道测试")

(in-suite rag-suite)

;; ============================================================
;; 嵌入模型测试
;; ============================================================

(test make-local-embeddings
  "测试创建本地嵌入模型"
  (let ((model (cl-agent.rag:make-local-embeddings)))
    (is (not (null model)))
    (is (= (cl-agent.rag:local-embeddings-dimension model) 384))))

(test embed-text-local
  "测试本地嵌入生成"
  (let ((model (cl-agent.rag:make-local-embeddings)))
    (let ((embedding (cl-agent.rag:embed-text model "Hello, world!")))
      (is (listp embedding))
      (is (= (length embedding) 384)))))

(test embed-batch-local
  "测试批量嵌入生成"
  (let ((model (cl-agent.rag:make-local-embeddings))
        (texts '("Text 1" "Text 2" "Text 3")))
    (let ((embeddings (cl-agent.rag:embed-batch model texts)))
      (is (= (length embeddings) 3))
      (is (every (lambda (e) (= (length e) 384)) embeddings)))))

;; ============================================================
;; 相似度计算测试
;; ============================================================

(test cosine-similarity-identical
  "测试相同向量的余弦相似度"
  (let ((model (cl-agent.rag:make-local-embeddings)))
    (let ((embedding (cl-agent.rag:embed-text model "test")))
      ;; 相同向量应该有很高的相似度
      (let ((similarity (cl-agent.rag:cosine-similarity embedding embedding)))
        (is (= similarity 1.0))))))

(test cosine-similarity-different
  "测试不同文本的余弦相似度"
  (let ((model (cl-agent.rag:make-local-embeddings)))
    (let ((embedding1 (cl-agent.rag:embed-text model "similar text"))
          (embedding2 (cl-agent.rag:embed-text model "different words")))
      (let ((similarity (cl-agent.rag:cosine-similarity embedding1 embedding2)))
        (is (floatp similarity))
        (is (<= 0.0 similarity 1.0))))))

(test euclidean-distance
  "测试欧几里得距离"
  (let ((model (cl-agent.rag:make-local-embeddings)))
    (let ((embedding1 (cl-agent.rag:embed-text model "text 1"))
          (embedding2 (cl-agent.rag:embed-text model "text 2")))
      (let ((distance (cl-agent.rag:euclidean-distance embedding1 embedding2)))
        (is (floatp distance))
        (is (>= distance 0.0))))))

;; ============================================================
;; 向量存储测试
;; ============================================================

(test make-vector-store
  "测试创建向量存储"
  (let ((store (cl-agent.rag:make-vector-store)))
    (is (not (null store)))
    (is (zerop (cl-agent.rag:vector-store-count store)))))

(test vs-add-document
  "测试添加文档"
  (let ((store (cl-agent.rag:make-vector-store))
        (model (cl-agent.rag:make-local-embeddings)))
    (let* ((content "Test document")
           (embedding (cl-agent.rag:embed-text model content))
           (doc-id (cl-agent.rag:vector-store-add-document store content embedding)))
      (is (stringp doc-id))
      (is (= (cl-agent.rag:vector-store-count store) 1)))))

(test vs-search
  "测试搜索文档"
  (let ((store (cl-agent.rag:make-vector-store))
        (model (cl-agent.rag:make-local-embeddings)))
    ;; 添加文档
    (cl-agent.rag:vector-store-add-document store
                                   "Common Lisp is a programming language"
                                   (cl-agent.rag:embed-text model
                                                             "Common Lisp is a programming language"))
    (cl-agent.rag:vector-store-add-document store
                                   "Python is another programming language"
                                   (cl-agent.rag:embed-text model
                                                             "Python is another programming language"))

    ;; 搜索
    (let* ((query "programming")
           (query-embedding (cl-agent.rag:embed-text model query))
           (results (cl-agent.rag:vector-store-search store query-embedding :top-k 2)))
      (is (listp results))
      (is (<= (length results) 2))
      (is (every (lambda (d)
                   (typep d 'cl-agent.rag:document))
                 results)))))

(test vs-get-document
  "测试获取文档"
  (let ((store (cl-agent.rag:make-vector-store))
        (model (cl-agent.rag:make-local-embeddings)))
    (let* ((content "Test content")
           (embedding (cl-agent.rag:embed-text model content))
           (doc-id (cl-agent.rag:vector-store-add-document store content embedding
                                                 :metadata nil)))
      (let ((doc (cl-agent.rag:vector-store-get-document store doc-id)))
        (is (not (null doc)))
        (is (string= (cl-agent.rag:document-content doc) content))
        (is (string= (cl-agent.rag:document-id doc) doc-id))))))

(test vs-clear
  "测试清空向量存储"
  (let ((store (cl-agent.rag:make-vector-store))
        (model (cl-agent.rag:make-local-embeddings)))
    ;; 添加文档
    (cl-agent.rag:vector-store-add-document store "Test 1"
                                   (cl-agent.rag:embed-text model "Test 1"))
    (cl-agent.rag:vector-store-add-document store "Test 2"
                                   (cl-agent.rag:embed-text model "Test 2"))

    (is (= (cl-agent.rag:vector-store-count store) 2))

    ;; 清空
    (cl-agent.rag:vector-store-clear store)

    (is (zerop (cl-agent.rag:vector-store-count store)))))

;; ============================================================
;; 文本分割测试
;; ============================================================

(test make-text-splitter
  "测试创建文本分割器"
  (let ((splitter (cl-agent.rag:make-text-splitter)))
    (is (not (null splitter)))
    (is (= (cl-agent.rag:text-splitter-chunk-size splitter) 1000))
    (is (= (cl-agent.rag:text-splitter-chunk-overlap splitter) 200))))

(test split-text-basic
  "测试基本文本分割"
  (let* ((text "This is line 1.
This is line 2.
This is line 3.")
        (splitter (cl-agent.rag:make-text-splitter
                   :chunk-size 20
                   :chunk-overlap 5))
        (chunks (cl-agent.rag:split-text text splitter)))
    (is (> (length chunks) 0))
    (is (every (lambda (c) (stringp c)) chunks))))

(test split-text-custom-separator
  "测试自定义分隔符"
  (let* ((text "Line1|Line2|Line3|Line4")
        (splitter (cl-agent.rag:make-text-splitter
                   :chunk-size 10
                   :separator #\|))
        (chunks (cl-agent.rag:split-text text splitter)))
    (is (> (length chunks) 0))))

;; ============================================================
;; 文档加载测试
;; ============================================================

(test make-document-loader
  "测试创建文档加载器"
  (let ((loader (cl-agent.rag:make-document-loader)))
    (is (not (null loader)))))

(test load-document
  "测试加载文档"
  (let ((test-file "/tmp/test-rag-doc.txt")
        (loader (cl-agent.rag:make-document-loader)))
    ;; 创建测试文件
    (with-open-file (out test-file
                         :direction :output
                         :if-exists :supersede)
      (format out "This is a test document.
It has multiple lines.
We'll load it into the RAG pipeline."))

    ;; 加载文档
    (let ((content (cl-agent.rag:load-document loader test-file)))
      (is (stringp content))
      (is (search "test document" content)))

    ;; 删除测试文件
    (delete-file test-file)))

;; ============================================================
;; RAG 管道测试
;; ============================================================

(test make-rag-pipeline
  "测试创建 RAG 管道"
  (let ((pipeline (cl-agent.rag:make-rag-pipeline
                   :embeddings-model (cl-agent.rag:make-local-embeddings)
                   :vector-store (cl-agent.rag:make-vector-store))))
    (is (not (null pipeline)))
    (is (not (null (cl-agent.rag:rag-pipeline-embeddings-model pipeline))))
    (is (not (null (cl-agent.rag:rag-pipeline-vector-store pipeline))))))

(test rag-index-document
  "测试索引文档"
  (let ((pipeline (cl-agent.rag:make-rag-pipeline
                   :embeddings-model (cl-agent.rag:make-local-embeddings)
                   :vector-store (cl-agent.rag:make-vector-store)
                   :text-splitter (cl-agent.rag:make-text-splitter
                                   :chunk-size 50))))
    (let* ((content "Common Lisp is a dynamic programming language.
It supports multiple paradigms.")
           (doc-id (cl-agent.rag:rag-index-document pipeline content)))
      (is (stringp doc-id))
      (is (> (cl-agent.rag:vector-store-count
               (cl-agent.rag:rag-pipeline-vector-store pipeline))
             0)))))

(test rag-retrieve
  "测试检索文档"
  (let ((pipeline (cl-agent.rag:make-rag-pipeline
                   :embeddings-model (cl-agent.rag:make-local-embeddings)
                   :vector-store (cl-agent.rag:make-vector-store))))
    ;; 索引文档
    (cl-agent.rag:rag-index-document pipeline
                                      "Lisp is a programming language")
    (cl-agent.rag:rag-index-document pipeline
                                      "Python is another language")

    ;; 检索
    (let ((results (cl-agent.rag:rag-retrieve pipeline "programming" :top-k 2)))
      (is (listp results))
      (is (<= (length results) 2))
      (is (every (lambda (d)
                   (typep d 'cl-agent.rag:document))
                 results)))))

;; ============================================================
;; 便捷函数测试
;; ============================================================

(test index-document-convenience
  "测试 index-document 便捷函数"
  ;; 设置默认管道
  (setf cl-agent.rag:*default-rag-pipeline*
        (cl-agent.rag:make-rag-pipeline
         :embeddings-model (cl-agent.rag:make-local-embeddings)
         :vector-store (cl-agent.rag:make-vector-store)
         :text-splitter (cl-agent.rag:make-text-splitter :chunk-size 100)))

  (let ((doc-id (cl-agent.rag:index-document "Test document")))
    (is (stringp doc-id))))

(test retrieve-documents-convenience
  "测试 retrieve-documents 便捷函数"
  ;; 设置默认管道
  (setf cl-agent.rag:*default-rag-pipeline*
        (cl-agent.rag:make-rag-pipeline
         :embeddings-model (cl-agent.rag:make-local-embeddings)
         :vector-store (cl-agent.rag:make-vector-store)))

  ;; 索引文档
  (cl-agent.rag:index-document "Test content for retrieval")

  ;; 检索
  (let ((results (cl-agent.rag:retrieve-documents "test" :top-k 1)))
    (is (listp results))))

(test embed-convenience
  "测试 embed 便捷函数"
  (setf cl-agent.rag:*default-embedding-model*
        (cl-agent.rag:make-local-embeddings))

  (let ((embedding (cl-agent.rag:embed "test text")))
    (is (listp embedding))
    (is (= (length embedding) 384))))

;; ============================================================
;; 元数据测试
;; ============================================================

(test document-with-metadata
  "测试带元数据的文档"
  (let ((store (cl-agent.rag:make-vector-store))
        (model (cl-agent.rag:make-local-embeddings))
        (metadata (make-hash-table)))
    (setf (gethash "source" metadata) "test")
    (setf (gethash "category" metadata) "example")

    (cl-agent.rag:vector-store-add-document store
                                   "Test content"
                                   (cl-agent.rag:embed-text model "Test content")
                                   :metadata metadata)

    (let ((doc (first (cl-agent.rag:vector-store-documents store))))
      (is (not (null (cl-agent.rag:document-metadata doc))))
      (is (string= (gethash "source"
                            (cl-agent.rag:document-metadata doc))
                   "test")))))

;; ============================================================
;; 批量处理测试
;; ============================================================

(test batch-indexing
  "测试批量索引文档"
  (let ((pipeline (cl-agent.rag:make-rag-pipeline
                   :embeddings-model (cl-agent.rag:make-local-embeddings)
                   :vector-store (cl-agent.rag:make-vector-store)
                   :text-splitter (cl-agent.rag:make-text-splitter
                                   :chunk-size 50))))
    (let ((documents '("Document 1 content"
                       "Document 2 content"
                       "Document 3 content")))
      ;; 索引多个文档
      (dolist (doc documents)
        (cl-agent.rag:rag-index-document pipeline doc))

      ;; 验证
      (is (> (cl-agent.rag:vector-store-count
               (cl-agent.rag:rag-pipeline-vector-store pipeline))
             0)))))

;; ============================================================
;; 相似度排序测试
;; ============================================================

(test search-ranking
  "测试搜索结果排序"
  (let ((store (cl-agent.rag:make-vector-store))
        (model (cl-agent.rag:make-local-embeddings)))
    ;; 添加相关和不相关的文档
    (let* ((relevant-text "Common Lisp programming language")
           (irrelevant-text "The weather is nice today")
           (relevant-embedding (cl-agent.rag:embed-text model relevant-text))
           (irrelevant-embedding (cl-agent.rag:embed-text model irrelevant-text)))
      (cl-agent.rag:vector-store-add-document store relevant-text relevant-embedding)
      (cl-agent.rag:vector-store-add-document store irrelevant-text irrelevant-embedding)

      ;; 搜索
      (let* ((query "Lisp programming")
             (query-embedding (cl-agent.rag:embed-text model query))
             (results (cl-agent.rag:vector-store-search store query-embedding :top-k 2)))
        (is (listp results))
        (is (= (length results) 2))
        ;; 第一个结果应该包含 "Lisp"
        (is (search "Lisp"
                    (cl-agent.rag:document-content (first results))))))))

;; ============================================================
;; 运行 RAG 测试
;; ============================================================

(defun run-rag-tests ()
  "运行所有 RAG 测试"
  (run! 'rag-suite))
