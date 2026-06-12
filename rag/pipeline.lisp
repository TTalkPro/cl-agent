;;;; pipeline.lisp
;;;; CL-Agent - RAG 管道
;;;;
;;;; 概述：
;;;;   实现检索增强生成（RAG）管道
;;;;
;;;; 特性：
;;;;   - 文档加载
;;;;   - 文档分割
;;;;   - 嵌入和索引
;;;;   - 检索和生成

(in-package :cl-agent.rag)

;;; ============================================================
;;; 文档分割器
;;; ============================================================

(defstruct (text-splitter (:constructor make-text-splitter-struct))
  "文本分割器

  槽位说明：
    CHUNK-SIZE      - 块大小（字符数）
    CHUNK-OVERLAP   - 块重叠大小
    SEPARATOR       - 分隔符"
  (chunk-size 1000 :type integer)
  (chunk-overlap 200 :type integer)
  (separator #\Newline :type character))

(defun make-text-splitter (&key (chunk-size 1000) (chunk-overlap 200) (separator #\Newline))
  "创建文本分割器"
  (make-text-splitter-struct
   :chunk-size chunk-size
   :chunk-overlap chunk-overlap
   :separator separator))

(defun split-text (text splitter)
  "分割文本为块

  参数：
    TEXT     - 输入文本
    SPLITTER - 文本分割器

  返回：
    文本块列表"
  (let ((chunks '())
        (chunk-size (text-splitter-chunk-size splitter))
        (chunk-overlap (text-splitter-chunk-overlap splitter))
        (separator (text-splitter-separator splitter))
        (position 0)
        (text-length (length text)))

    (loop while (< position text-length)
          do (let ((end-position (min (+ position chunk-size) text-length)))
               (push (subseq text position end-position) chunks)
               (setf position (+ end-position (- chunk-overlap)))
               (when (and (< position text-length)
                          (>= (- text-length position) chunk-overlap))
                 (setf position text-length))))

    (nreverse chunks)))

;;; ============================================================
;;; 文档加载器
;;; ============================================================

(defstruct (document-loader (:constructor make-document-loader-struct))
  "文档加载器

  槽位说明：
    SUPPORTED-FORMATS - 支持的格式"
  (supported-formats '(:txt :md :lisp)))

(defun make-document-loader (&key (formats '(:txt :md :lisp)))
  "创建文档加载器"
  (make-document-loader-struct :supported-formats formats))

(defun load-document (loader filepath)
  "加载文档

  参数：
    LOADER   - 文档加载器
    FILEPATH - 文件路径

  返回：
    文档内容字符串"
  (let ((extension (pathname-type (parse-namestring filepath))))
    (unless (member (intern (string-upcase extension) :keyword)
                    (document-loader-supported-formats loader))
      (error "Unsupported file format: ~A" extension))

    (with-open-file (in filepath :direction :input)
      (let ((contents (make-string (file-length in))))
        (read-sequence contents in)
        contents))))

(defun load-documents (loader filepaths)
  "批量加载文档

  参数：
    LOADER    - 文档加载器
    FILEPATHS - 文件路径列表

  返回：
    文档内容列表"
  (mapcar (lambda (path)
            (load-document loader path))
          filepaths))

;;; ============================================================
;;; RAG 管道
;;; ============================================================

(defstruct (rag-pipeline (:constructor make-rag-pipeline-struct))
  "RAG 管道

  槽位说明：
    EMBEDDINGS-MODEL  - 嵌入模型
    VECTOR-STORE      - 向量存储
    TEXT-SPLITTER     - 文本分割器
    LLM-CLIENT        - LLM 客户端"
  embeddings-model
  vector-store
  text-splitter
  llm-client)

(defun make-rag-pipeline (&key (embeddings-model nil)
                             (vector-store nil)
                             (text-splitter nil)
                             (llm-client nil))
  "创建 RAG 管道

  参数：
    EMBEDDINGS-MODEL - 嵌入模型
    VECTOR-STORE     - 向量存储
    TEXT-SPLITTER    - 文本分割器
    LLM-CLIENT       - LLM 客户端

  返回：
    RAG 管道实例"
  (make-rag-pipeline-struct
   :embeddings-model (or embeddings-model (get-default-embedding-model))
   :vector-store (or vector-store (make-vector-store))
   :text-splitter (or text-splitter (make-text-splitter))
   :llm-client llm-client))

(defun rag-index-document (pipeline content &key metadata)
  "索引文档到 RAG 管道

  参数：
    PIPELINE - RAG 管道实例
    CONTENT  - 文档内容
    METADATA - 元数据

  返回：
    文档 ID"

  ;; 说明：
  ;;   1. 分割文档为块
  ;;   2. 生成每个块的嵌入
  ;;   3. 添加到向量存储
  (let* ((chunks (split-text content (rag-pipeline-text-splitter pipeline)))
         (embeddings (embed-batch (rag-pipeline-embeddings-model pipeline)
                                   chunks))
         (vector-store (rag-pipeline-vector-store pipeline))
         (doc-id (cl-agent.core:generate-uuid)))

    ;; 为每个块创建文档
    (dolist (chunk chunks)
      (let* ((embedding (pop embeddings))
             (chunk-metadata (let ((table (make-hash-table :test #'equal)))
                               (when metadata
                                 (maphash (lambda (k v)
                                            (setf (gethash k table) v))
                                          metadata))
                               table)))
        (setf (gethash "chunk-id" chunk-metadata)
              (cl-agent.core:generate-uuid))
        (setf (gethash "parent-id" chunk-metadata) doc-id)
        (vector-store-add-document vector-store chunk embedding
                                   :metadata chunk-metadata)))

    (when *rag-verbose*
      (format t "[RAG] Indexed document: ~A (~A chunks)~%"
              doc-id
              (length chunks)))

    doc-id))

(defun rag-index-file (pipeline filepath &key metadata)
  "索引文件到 RAG 管道

  参数：
    PIPELINE - RAG 管道实例
    FILEPATH - 文件路径
    METADATA - 元数据

  返回：
    文档 ID"
  (let* ((loader (make-document-loader))
         (content (load-document loader filepath)))
    (rag-index-document pipeline content
                             :metadata metadata)))

(defun rag-retrieve (pipeline query &key (top-k 5))
  "检索相关文档

  参数：
    PIPELINE - RAG 管道实例
    QUERY    - 查询文本
    TOP-K    - 返回数量

  返回：
    相关文档列表"
  (let* ((embeddings-model (rag-pipeline-embeddings-model pipeline))
         (query-embedding (embed-text embeddings-model query))
         (vector-store (rag-pipeline-vector-store pipeline)))
    (vector-store-search vector-store query-embedding :top-k top-k)))

(defun rag-generate (pipeline query &key (top-k 5))
  "生成增强回复

  参数：
    PIPELINE - RAG 管道实例
    QUERY    - 查询文本
    TOP-K    - 检索文档数量

  返回：
    生成的回复

  说明：
    1. 检索相关文档
    2. 构建增强提示
    3. 调用 LLM 生成回复"
  (unless (rag-pipeline-llm-client pipeline)
    (error "LLM client is required for generation"))

  ;; 检索相关文档
  (let ((documents (rag-retrieve pipeline query :top-k top-k)))

    (when *rag-verbose*
      (format t "[RAG] Retrieved ~A documents~%" (length documents)))

    ;; 构建上下文
    (let ((context (with-output-to-string (s)
                     (format s "~%Relevant documents:~%~%")
                     (loop for doc in documents
                           for i from 1
                           do (format s "~A. ~A~%~%"
                                        i
                                        (subseq (document-content doc)
                                                0
                                                (min 500
                                                     (length (document-content doc)))))))))))

      ;; 构建提示
      (let ((prompt (format nil "~A~%~%Context:~A~%~%Question: ~A~%~%Answer:"
                                 "Answer the question based on the context below."
                                 context
                                 query)))

        ;; 调用 LLM
        (let ((llm-client (rag-pipeline-llm-client pipeline)))
          (cl-agent.llm:chat-simple llm-client prompt))))

;;; ============================================================
;;; 全局变量
;;; ============================================================

(defparameter *default-rag-pipeline* nil
  "默认 RAG 管道实例")

(defun get-default-rag-pipeline ()
  "获取或创建默认 RAG 管道"
  (unless *default-rag-pipeline*
    (setf *default-rag-pipeline*
          (make-rag-pipeline)))
  *default-rag-pipeline*)

;;; ============================================================
;;; 便捷函数
;;; ============================================================

(defun index-document (content &key metadata)
  "索引文档到默认 RAG 管道"
  (rag-index-document (get-default-rag-pipeline)
                     content
                     :metadata metadata))

(defun index-file (filepath &key metadata)
  "索引文件到默认 RAG 管道"
  (rag-index-file (get-default-rag-pipeline)
                  filepath
                  :metadata metadata))

(defun retrieve-documents (query &key (top-k 5))
  "从默认 RAG 管道检索文档"
  (rag-retrieve (get-default-rag-pipeline)
               query
               :top-k top-k))

(defun rag-query (query &key (top-k 5))
  "使用默认 RAG 管道查询并生成回复"
  (rag-generate (get-default-rag-pipeline)
                query
                :top-k top-k))
