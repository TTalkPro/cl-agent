;;;; vector-store.lisp
;;;; CL-Agent - 向量存储
;;;;
;;;; 概述：
;;;;   实现向量数据库存储
;;;;
;;;; 特性：
;;;;   - 文档存储
;;;;   - 向量索引
;;;;   - 相似度搜索

(in-package :cl-agent.rag)

;;; ============================================================
;;; 文档结构
;;; ============================================================

(defstruct document
  "文档结构

  槽位说明：
    ID         - 文档 ID
    CONTENT    - 文档内容
    METADATA   - 元数据
    EMBEDDING  - 嵌入向量"
  id
  content
  (metadata nil :type (or null hash-table))
  (embedding nil :type (or null list)))

;;; ============================================================
;;; 向量存储
;;; ============================================================

(defstruct (vector-store (:constructor make-vector-store-struct))
  "向量存储

  槽位说明：
    DOCUMENTS   - 文档列表
    INDEX       - 向量索引"
  documents
  (index nil :type (or null hash-table)))

(defun make-vector-store ()
  "创建向量存储实例"
  (make-vector-store-struct
   :documents '()
   :index (make-hash-table :test #'equal)))

(defun vector-store-add-document (store content embedding &key metadata)
  "添加文档到向量存储

  参数：
    STORE     - 向量存储实例
    CONTENT   - 文档内容
    EMBEDDING - 嵌入向量
    METADATA  - 元数据（可选）

  返回：
    文档 ID

  示例：
    (vector-store-add-document store "文本内容" embedding-vector)"
  (let ((id (cl-agent.core:generate-uuid))
        (document (make-document
                  :id id
                  :content content
                  :embedding embedding
                  :metadata metadata)))
    (setf (vector-store-documents store)
          (append (vector-store-documents store)
                  (list document)))
    (when *rag-verbose*
      (format t "[VectorStore] Added document: ~A~%" id))
    id))

(defun vector-store-search (store query-embedding &key (top-k 5) (min-score 0.0))
  "搜索相似文档

  参数：
    STORE          - 向量存储实例
    QUERY-EMBEDDING - 查询嵌入向量
    TOP-K          - 返回文档数量
    MIN-SCORE      - 最小相似度阈值

  返回：
    匹配的文档列表（按相似度降序排序）

  说明：
    使用余弦相似度计算文档与查询的相似度，
    返回相似度最高的 top-k 个文档"
  (let ((results '()))
    (dolist (doc (vector-store-documents store))
      (when (document-embedding doc)
        (let ((score (cosine-similarity query-embedding
                                         (document-embedding doc))))
          (when (>= score min-score)
            (push (cons score doc) results)))))
    ;; 按相似度排序并返回 top-k
    (let ((sorted (sort results #'> :key #'car)))
      (loop for (score . doc) in (subseq sorted 0 (min top-k (length sorted)))
            collect doc))))

(defun vector-store-get-document (store id)
  "根据 ID 获取文档

  参数：
    STORE - 向量存储实例
    ID    - 文档 ID

  返回：
    文档实例或 NIL

  说明：
    根据 ID 查找并返回文档，如果未找到则返回 NIL"
  (find id (vector-store-documents store)
        :key #'document-id
        :test #'string=))

(defun vector-store-count (store)
  "获取向量存储中的文档数量

  参数：
    STORE - 向量存储实例

  返回：
    文档数量（整数）"
  (length (vector-store-documents store)))

(defun vector-store-clear (store)
  "清空向量存储

  参数：
    STORE - 向量存储实例

  返回：
    清空后的存储实例

  说明：
    删除所有文档和索引，释放存储空间"
  (setf (vector-store-documents store) '())
  (clrhash (vector-store-index store))
  (when *rag-verbose*
    (format t "[VectorStore] Cleared~%"))
  store)

;;; ============================================================
;;; 全局变量
;;; ============================================================

(defparameter *default-vector-store* nil
  "默认向量存储实例")

(defun get-default-vector-store ()
  "获取或创建默认向量存储"
  (unless *default-vector-store*
    (setf *default-vector-store*
          (make-vector-store)))
  *default-vector-store*)

;;; ============================================================
;;; 便捷函数
;;; ============================================================

(defun add-document (content embedding &key metadata)
  "添加文档到默认向量存储

  参数：
    CONTENT   - 文档内容
    EMBEDDING - 嵌入向量
    METADATA  - 元数据（可选）

  返回：
    文档 ID

  说明：
    使用全局默认向量存储实例"
  (vector-store-add-document (get-default-vector-store)
                            content
                            embedding
                            :metadata metadata))

(defun search-documents (query &key (top-k 5))
  "搜索默认向量存储中的文档

  参数：
    QUERY - 查询文本
    TOP-K - 返回文档数量

  返回：
    匹配的文档列表

  说明：
    先使用默认嵌入模型生成查询向量，
    然后在默认向量存储中搜索"
  (let* ((embedding-model (get-default-embedding-model))
         (query-embedding (embed-text embedding-model query)))
    (vector-store-search (get-default-vector-store)
                        query-embedding
                        :top-k top-k)))
