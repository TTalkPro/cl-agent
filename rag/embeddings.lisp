;;;; embeddings.lisp
;;;; CL-Agent - 嵌入模型接口
;;;;
;;;; 概述：
;;;;   实现文本嵌入功能
;;;;
;;;; 特性：
;;;;   - 嵌入接口定义
;;;;   - 多种嵌入模型支持
;;;;   - 批量嵌入

(in-package :cl-agent.rag)

;;; ============================================================
;;; 嵌入接口
;;; ============================================================

(defgeneric embed-text (embedding-model text &key)
  (:documentation "生成文本嵌入"))

(defgeneric embed-batch (embedding-model texts &key)
  (:documentation "批量生成文本嵌入"))

;;; ============================================================
;;; OpenAI 嵌入
;;; ============================================================

(defstruct (openai-embeddings (:constructor make-openai-embeddings-struct))
  "OpenAI 嵌入模型

  槽位说明：
    API-KEY    - API 密钥
    MODEL      - 模型名称
    BASE-URL   - API 基础 URL"
  api-key
  (model "text-embedding-3-small")
  (base-url "https://api.openai.com/v1"))

(defun make-openai-embeddings (&key (api-key nil) (model nil))
  "创建 OpenAI 嵌入模型实例

  参数：
    API-KEY - API 密钥（可选，默认从环境变量读取）
    MODEL   - 模型名称（可选）

  返回：
    OpenAI 嵌入实例"
  (let ((api-key (or api-key (cl-agent.core:get-env "OPENAI_API_KEY"))))
    (unless api-key
      (error "OpenAI API key is required"))
    (make-openai-embeddings-struct
     :api-key api-key
     :model (or model "text-embedding-3-small"))))

(defmethod embed-text ((model openai-embeddings) text &key)
  "使用 OpenAI 生成嵌入

  参数：
    MODEL - OpenAI 嵌入实例
    TEXT  - 输入文本

  返回：
    嵌入向量（列表）"
  (let* ((url (format nil "~A/embeddings"
                       (openai-embeddings-base-url model)))
         (payload `(("model" . ,(openai-embeddings-model model))
                   ("input" . ,text)))
         (response (dex:post url
                                   :headers `(("Authorization" . ,(format nil "Bearer ~A"
                                                                      (openai-embeddings-api-key model)))
                                               ("Content-Type" . "application/json"))
                                   :content (cl-agent.core:json-stringify payload)))
         (data (cl-agent.core:json-parse response)))

    (when *rag-verbose*
      (format t "[Embeddings] Generated embedding for text: ~A~%"
              (subseq text 0 (min 50 (length text)))))

    ;; 提取向量
    (let ((data-list (gethash "data" data)))
      (when (and data-list (> (length data-list) 0))
        (let ((embedding (gethash "embedding" (aref data-list 0))))
          embedding)))))

(defmethod embed-batch ((model openai-embeddings) texts &key)
  "批量生成嵌入

  参数：
    MODEL - OpenAI 嵌入实例
    TEXTS - 文本列表

  返回：
    嵌入向量列表"
  (mapcar (lambda (text)
            (embed-text model text))
          texts))

;;; ============================================================
;;; 本地嵌入（简化版）
;;; ============================================================

(defstruct (local-embeddings (:constructor make-local-embeddings-struct))
  "本地嵌入模型

  槽位说明：
    MODEL-PATH  - 模型路径
    DIMENSION   - 嵌入维度"
  model-path
  (dimension 384))

(defun make-local-embeddings (&key (model-path nil) (dimension 384))
  "创建本地嵌入模型实例"
  (make-local-embeddings-struct
   :model-path model-path
   :dimension dimension))

(defmethod embed-text ((model local-embeddings) text &key)
  "使用本地模型生成嵌入（简化实现）

  参数：
    MODEL - 本地嵌入实例
    TEXT  - 输入文本

  返回：
    嵌入向量（示例：简单 hash）

  说明：
    这是一个简化的实现，实际使用应该集成真正的嵌入模型
    如 sentence-transformers 或其他本地模型"
  ;; 简化实现：使用文本的 hash 作为伪嵌入
  ;; 实际应用中应该使用真正的嵌入模型
  (let* ((hash (sxhash text))
         (dimension (local-embeddings-dimension model))
         (vector (make-array dimension :initial-element 0.0)))
    ;; 简单的伪随机向量
    (loop for i from 0 below dimension
          do (setf (aref vector i)
                   (mod (* hash (1+ i)) 1000)))
    (coerce vector 'list)))

(defmethod embed-batch ((model local-embeddings) texts &key)
  "批量生成嵌入（本地模型）"
  (mapcar (lambda (text)
            (embed-text model text))
          texts))

;;; ============================================================
;;; 全局变量
;;; ============================================================

(defparameter *default-embedding-model* nil
  "默认嵌入模型")

(defparameter *rag-verbose* nil
  "是否输出 RAG 详细日志")

(defun get-default-embedding-model ()
  "获取或创建默认嵌入模型"
  (unless *default-embedding-model*
    (setf *default-embedding-model*
          (make-openai-embeddings)))
  *default-embedding-model*)

;;; ============================================================
;;; 便捷函数
;;; ============================================================

(defun embed-text* (text &key (model nil))
  "生成文本嵌入（使用默认模型）

  参数：
    TEXT  - 输入文本
    MODEL - 嵌入模型（可选）

  返回：
    嵌入向量"
  (let ((embedding-model (or model (get-default-embedding-model))))
    (embed-text embedding-model text)))

(defun embed-batch* (texts &key (model nil))
  "批量生成嵌入（便捷函数）

  参数：
    TEXTS - 文本列表
    MODEL - 嵌入模型（可选）

  返回：
    嵌入向量列表"
  (let ((embedding-model (or model (get-default-embedding-model))))
    (embed-batch embedding-model texts)))

;; cosine-similarity / euclidean-distance 定义在 utils.lisp，
;; 接受 list 或 vector；此处不要重复定义（vector-only 版本会覆盖它们）。
