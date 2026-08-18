;;;; embedding.lisp
;;;; CL-Agent Core LLM - 嵌入向量 SPI 与统一响应
;;;;
;;;; 概述（对标 ai-sdk 的 EmbeddingModel.doEmbed /
;;;;      Spring AI 的 EmbeddingModel）：
;;;;   与 llm-chat 同一套路数——协议定义在 core（避免循环依赖），
;;;;   各 provider 在 cl-agent-llm 里特化 llm-embed。
;;;;
;;;;   统一响应 embedding-response：
;;;;     embeddings - 向量列表，顺序与输入文本一一对应
;;;;     model      - 实际使用的模型名
;;;;     usage      - llm-usage（复用对话侧的归一化）
;;;;     raw        - provider 原始响应
;;;;
;;;;   「顺序一一对应」是硬契约：厂商返回的 data 数组带 index 字段，
;;;;   实现方必须按它排序后再产出，调用方才能靠位置把向量配回文本。

(in-package #:cl-agent.core)

;;; ============================================================
;;; 统一嵌入响应
;;; ============================================================

(defclass embedding-response ()
  ((embeddings
    :initarg :embeddings
    :initform nil
    :accessor embedding-response-embeddings
    :documentation "向量列表（每个元素是 single-float 向量），顺序同输入文本")
   (model
    :initarg :model
    :initform nil
    :accessor embedding-response-model
    :documentation "实际使用的嵌入模型名")
   (usage
    :initarg :usage
    :initform nil
    :accessor embedding-response-usage
    :documentation "token 用量（llm-usage 对象，可为 NIL）")
   (raw-response
    :initarg :raw-response
    :initform nil
    :accessor embedding-response-raw
    :documentation "provider 原始响应"))
  (:documentation "统一嵌入响应（对标 llm-response 在对话侧的地位）"))

(defun make-embedding-response (&key embeddings model usage raw-response)
  "创建 embedding-response"
  (make-instance 'embedding-response
                 :embeddings embeddings
                 :model model
                 :usage usage
                 :raw-response raw-response))

(defun embedding-response-p (obj)
  "是否为 embedding-response 实例"
  (typep obj 'embedding-response))

(defmethod print-object ((r embedding-response) stream)
  (print-unreadable-object (r stream :type t)
    (format stream "~A vectors~@[ dim=~A~]~@[ model=~A~]"
            (length (embedding-response-embeddings r))
            (let ((first-vec (first (embedding-response-embeddings r))))
              (when first-vec (length first-vec)))
            (embedding-response-model r))))

(defun embedding-response-first (response)
  "取第一个向量（单文本嵌入的便捷入口）"
  (first (embedding-response-embeddings response)))

(defun embedding-dimensions (response)
  "取向量维度；无向量时返回 NIL"
  (let ((first-vec (embedding-response-first response)))
    (when first-vec (length first-vec))))

;;; ============================================================
;;; 嵌入 SPI
;;; ============================================================

(defgeneric llm-embed (provider texts &key model dimensions encoding-format
                                           extra-params)
  (:documentation "为一批文本生成嵌入向量。

参数：
  PROVIDER        - provider 实例
  TEXTS           - 文本列表（也接受单个字符串）
  MODEL           - 嵌入模型名（可选，缺省取 provider 的默认嵌入模型）
  DIMENSIONS      - 降维后的维度（可选，仅部分模型支持，如
                    text-embedding-3-*）
  ENCODING-FORMAT - \"float\"（默认）或 \"base64\"（可选）
  EXTRA-PARAMS    - 厂商专有参数逃生通道（plist，直接并入请求体）

返回：
  embedding-response，其 embeddings 顺序与 TEXTS 一一对应。

约定与 llm-chat 一致：可选参数「存在才发送」，NIL 不写入请求体。

注：并非所有 provider 都提供嵌入服务（Anthropic 就没有）。
未实现该方法的 provider 调用时报 embedding-error——而不是
no-applicable-method，后者的报错读者看不出「这家没有嵌入服务」。")
  (:method ((provider t) texts &key model dimensions encoding-format
                                    extra-params)
    (declare (ignore texts model dimensions encoding-format extra-params))
    (signal-error 'embedding-error
                  :message (format nil "提供商 ~A 不支持嵌入向量"
                                   (handler-case (provider-name provider)
                                     (error () provider))))))

(defgeneric provider-supports-embedding-p (provider)
  (:documentation "provider 是否支持嵌入向量。默认 NIL。")
  (:method ((provider t)) nil))

(defgeneric provider-default-embedding-model (provider)
  (:documentation "provider 的默认嵌入模型名；无默认值时返回 NIL。

对话模型与嵌入模型是两套模型名，不能共用 base-provider 的
default-model——那个是对话模型，拿去调 /embeddings 必然 400。")
  (:method ((provider t)) nil))
