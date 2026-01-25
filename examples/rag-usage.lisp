;;;; rag-usage.lisp
;;;; CL-Agent - RAG 使用示例

;; 加载系统
(asdf:load-system :cl-agent)

;; 使用包
(in-package :cl-user)
(use-package :cl-agent)
(use-package :cl-agent.rag)

;;; ============================================================
;;; 示例 1：基本嵌入
;;; ============================================================

(defun example-1-basic-embeddings ()
  "基本嵌入使用"
  (format t "~%=== Example 1: Basic Embeddings ===~%")

  ;; 创建嵌入模型
  (let ((model (make-local-embeddings)))  ; 使用本地嵌入（无需 API key）
    ;; 生成嵌入
    (let ((embedding (embed model "Hello, world!")))
      (format t "Embedding dimension: ~A~%" (length embedding))
      (format t "First 5 values: ~A~%" (subseq embedding 0 5))))))

;;; ============================================================
;;; 示例 2：文本分割
;;; ============================================================

(defun example-2-text-splitting ()
  "文本分割"
  (format t "~%=== Example 2: Text Splitting ===~%")

  (let* ((text "This is the first paragraph.~%~%~
                This is the second paragraph.~%~%~
                This is the third paragraph.")
         (splitter (make-text-splitter
                     :chunk-size 50
                     :chunk-overlap 10))
         (chunks (split-text text splitter)))

    (format t "Original text length: ~A~%" (length text))
    (format t "Number of chunks: ~A~%~%" (length chunks))

    (dolist (chunk chunks)
      (format t "  Chunk: ~A~%~%" (subseq chunk 0 (min 40 (length chunk))))))

;;; ============================================================
;;; 示例 3：向量存储
;;; ============================================================

(defun example-3-vector-store ()
  "向量存储使用"
  (format t "~%=== Example 3: Vector Store ===~%")

  ;; 创建向量存储
  (let ((store (make-vector-store))
        (model (make-local-embeddings)))

    ;; 添加文档
    (let* ((content1 "Common Lisp is a programming language.")
           (content2 "Python is another popular programming language.")
           (embedding1 (embed model content1))
           (embedding2 (embed model content2)))

      (vector-store-add-document store content1 embedding1
                       :metadata (let ((meta (make-hash-table)))
                                (setf (gethash "source" meta) "example1")
                                meta))
      (vector-store-add-document store content2 embedding2
                       :metadata (let ((meta (make-hash-table)))
                                (setf (gethash "source" meta) "example2")
                                meta)))

    (format t "Total documents: ~A~%" (vector-store-count store))

    ;; 搜索
    (let* ((query "programming")
           (query-embedding (embed model query))
           (results (vector-store-search store query-embedding :top-k 2)))

      (format t "~%Search results for '~A':~%" query)
      (dolist (doc results)
        (format t "  - ~A~%" (document-content doc))))))

;;; ============================================================
;;; 示例 4：RAG 管道 - 索引
;;; ============================================================

(defun example-4-rag-indexing ()
  "RAG 管道 - 索引文档"
  (format t "~%=== Example 4: RAG Indexing ===~%")

  ;; 创建 RAG 管道（不使用 LLM）
  (let ((pipeline (make-rag-pipeline
                    :embeddings-model (make-local-embeddings)
                    :vector-store (make-vector-store)
                    :text-splitter (make-text-splitter
                                       :chunk-size 200
                                       :chunk-overlap 50))))

    ;; 索引文档
    (let ((document "Common Lisp is a dynamic, multi-paradigm programming language.
It was developed in the 1960s and has been used for AI research.
Lisp supports functional, imperative, and object-oriented programming."))

      (let ((doc-id (rag-index-document pipeline document
                                            :metadata (let ((meta (make-hash-table)))
                                                       (setf (gethash "title" meta) "Lisp Intro")
                                                       meta))))
        (format t "Indexed document: ~A~%" doc-id)

        ;; 统计
        (format t "Total chunks stored: ~A~%"
                (vector-store-count (rag-pipeline-vector-store pipeline))))))

;;; ============================================================
;;; 示例 5：RAG 检索
;;; ============================================================

(defun example-5-rag-retrieval ()
  "RAG 检索"
  (format t "~%=== Example 5: RAG Retrieval ===~%")

  (let ((pipeline (make-rag-pipeline
                    :embeddings-model (make-local-embeddings)
                    :vector-store (make-vector-store))))

    ;; 先索引一些文档
    (rag-index-document pipeline
                       "Lisp is known for its parentheses syntax.
It uses prefix notation for expressions.")
    (rag-index-document pipeline
                       "Python emphasizes readability with indentation.
It is widely used in data science and machine learning.")

    ;; 检索
    (let ((query "Lisp syntax")
          (results (rag-retrieve pipeline query :top-k 2)))

      (format t "~%Query: ~A~%" query)
      (format t "Retrieved ~A documents:~%" (length results))
      (dolist (doc results)
        (format t "  - ~A~%"
                (subseq (document-content doc)
                        0
                        (min 100 (length (document-content doc)))))))))

;;; ============================================================
;;; 示例 6：文档加载
;;; ============================================================

(defun example-6-document-loading ()
  "文档加载"
  (format t "~%=== Example 6: Document Loading ===~%")

  ;; 创建测试文件
  (let ((test-file "/tmp/test-doc.txt"))
    (with-open-file (out test-file :direction :output
                                :if-exists :supersede)
      (format out "This is a test document.
It has multiple lines.
We'll load it into the RAG pipeline."))

    ;; 加载文档
    (let* ((loader (make-document-loader))
           (content (load-document loader test-file)))

      (format t "Loaded content:~%")
      (format t "~A~%" content)

      ;; 删除测试文件
      (delete-file test-file))))

;;; ============================================================
;;; 示例 7：完整 RAG 管道
;;; ============================================================

(defun example-7-complete-rag ()
  "完整 RAG 管道"
  (format t "~%=== Example 7: Complete RAG Pipeline ===~%")

  (let ((pipeline (make-rag-pipeline
                    :embeddings-model (make-local-embeddings)
                    :vector-store (make-vector-store)
                    :text-splitter (make-text-splitter
                                       :chunk-size 300))))

    ;; 准备文档
    (let ((documents '("CL-Agent is an AI Agent framework in Common Lisp.
It supports multiple LLM providers including Anthropic and OpenAI.
The framework provides tools, memory, and workflow management."
                        "Common Lisp is known for its powerful macro system.
It allows code to be treated as data.
This metaprogramming capability is unique among programming languages."
                        "RAG stands for Retrieval-Augmented Generation.
It combines information retrieval with language model generation.
This improves accuracy and reduces hallucinations.")))

      ;; 索引所有文档
      (format t "~%Indexing ~A documents...~%" (length documents))
      (dolist (doc documents)
        (rag-index-document pipeline doc
                             :metadata (let ((meta (make-hash-table)))
                                       (setf (gethash "timestamp" meta)
                                             (cl-agent.core:timestamp-now))
                                       meta)))

      (format t "Total chunks indexed: ~A~%"
              (vector-store-count (rag-pipeline-vector-store pipeline)))

      ;; 查询
      (format t "~%~%Querying...~%")
      (let ((query "What is RAG?")
            (results (rag-retrieve pipeline query :top-k 3)))

        (format t "Top ~A results for '~A':~%" (length results) query)
        (dolist (doc results)
          (let ((content (subseq (document-content doc)
                                 0
                                 (min 150 (length (document-content doc))))))
            (format t "~%  ~A...~%" content))))))

;;; ============================================================
;;; 示例 8：相似度计算
;;; ============================================================

(defun example-8-similarity ()
  "相似度计算"
  (format t "~%=== Example 8: Similarity Calculation ===~%")

  (let ((model (make-local-embeddings)))
    (let ((embedding1 (embed model "similar text"))
          (embedding2 (embed model "similar text"))
          (embedding3 (embed model "different words")))

      (let ((sim-1-2 (cosine-similarity embedding1 embedding2))
            (sim-1-3 (cosine-similarity embedding1 embedding3)))

        (format t "Similarity (similar vs similar): ~A~%" sim-1-2)
        (format t "Similarity (similar vs different): ~A~%" sim-1-3))))

;;; ============================================================
;;; 示例 9：批量处理
;;; ============================================================

(defun example-9-batch-processing ()
  "批量嵌入处理"
  (format t "~%=== Example 9: Batch Processing ===~%")

  (let ((model (make-local-embeddings))
        (texts '("First text"
                "Second text"
                "Third text")))

    ;; 批量生成嵌入
    (let ((embeddings (embed-batch model texts)))

      (format t "Generated ~A embeddings~%" (length embeddings))
      (dolist (embedding embeddings)
        (format t "  Dimension: ~A~%" (length embedding))))))

;;; ============================================================
;;; 示例 10：自定义分割器
;;; ============================================================

(defun example-10-custom-splitter ()
  "自定义分割器"
  (format t "~%=== Example 10: Custom Splitter ===~%")

  (let* ((text "Line1|Line2|Line3|Line4")
         (splitter (make-text-splitter
                     :chunk-size 15
                     :separator #\|))
         (chunks (split-text text splitter)))

    (format t "Custom splitting with '|' separator:~%")
    (format t "Number of chunks: ~A~%" (length chunks))
    (dolist (chunk chunks)
      (format t "  ~A~%" chunk)))

;;; ============================================================
;;; 运行所有示例
;;; ============================================================

(defun run-rag-examples ()
  "运行所有 RAG 示例"
  (format t "~%========================================")
  (format t "~%  CL-Agent RAG Examples")
  (format t "~%========================================")

  (example-1-basic-embeddings)
  (example-2-text-splitting)
  (example-3-vector-store)
  (example-4-rag-indexing)
  (example-5-rag-retrieval)
  (example-6-document-loading)
  (example-7-complete-rag)
  (example-8-similarity)
  (example-9-batch-processing)
  (example-10-custom-splitter)

  (format t "~%========================================")
  (format t "~%  All RAG examples completed!")
  (format t "~%========================================~%"))

;; 运行示例（取消注释）
;; (run-rag-examples)
