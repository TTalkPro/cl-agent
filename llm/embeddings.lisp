;;;; embeddings.lisp
;;;; CL-Agent LLM - 嵌入向量实现（OpenAI 兼容）
;;;;
;;;; 概述：
;;;;   core 定义 llm-embed SPI 与 embedding-response（core/llm/embedding.lisp），
;;;;   本文件提供 OpenAI 兼容端点的唯一实现——OpenAI、SiliconFlow、
;;;;   智谱、Ollama、Mistral、Gemini 全走同一条路径：
;;;;
;;;;     POST <base>/embeddings
;;;;     {"model": "...", "input": ["文本1", "文本2"], "dimensions": 1024}
;;;;     → {"data":[{"index":0,"embedding":[...]}, ...], "usage":{...}}
;;;;
;;;;   以及面向应用的两个便捷函数（README 一直在文档里承诺、
;;;;   此前并不存在的那两个）：
;;;;     (embed provider-or-client "文本")        → 单个向量
;;;;     (embed-batch provider-or-client '("a" "b")) → 向量列表
;;;;
;;;; 顺序契约：
;;;;   响应 data 数组按 index 排序后再产出向量，调用方可以靠位置
;;;;   把向量配回原文本。厂商不保证 data 的到达顺序。

(in-package :cl-agent.llm)

;;; ============================================================
;;; 端点与默认模型
;;; ============================================================

(defgeneric provider-embedding-endpoint (provider)
  (:documentation "provider 的嵌入端点路径。默认 /embeddings。")
  (:method ((provider t)) "/embeddings"))

;;; 各厂商的默认嵌入模型。
;;; 不给 base-provider 加一个 default-embedding-model 槽位，是因为
;;; 那会让每个 make-*-provider 都得多传一个参数；而默认嵌入模型是
;;; 厂商级常量，写成方法就够了，调用方需要别的模型时传 :model 即可。
(defmethod cl-agent.core:provider-default-embedding-model
    ((provider cl-agent.llm.providers::openai-provider))
  "text-embedding-3-small")

(defmethod cl-agent.core:provider-default-embedding-model
    ((provider cl-agent.llm.providers::siliconflow-provider))
  "BAAI/bge-m3")

(defmethod cl-agent.core:provider-default-embedding-model
    ((provider cl-agent.llm.providers::zhipu-provider))
  "embedding-3")

(defmethod cl-agent.core:provider-default-embedding-model
    ((provider cl-agent.llm.providers::mistral-provider))
  "mistral-embed")

(defmethod cl-agent.core:provider-default-embedding-model
    ((provider cl-agent.llm.providers::gemini-provider))
  "text-embedding-004")

(defmethod cl-agent.core:provider-default-embedding-model
    ((provider cl-agent.llm.providers::ollama-provider))
  "nomic-embed-text")

;;; OpenRouter 只做对话路由，没有嵌入端点；xai / moonshot / deepseek
;;; 亦未提供嵌入模型——不给它们方法，默认 NIL，调用时会明确报
;;; 「未指定嵌入模型」而不是拿对话模型去撞 400。

(defmethod cl-agent.core:provider-supports-embedding-p
    ((provider cl-agent.llm.providers::openai-compat-provider))
  "OpenAI 兼容端点是否提供嵌入服务，以是否有默认嵌入模型为准"
  (not (null (cl-agent.core:provider-default-embedding-model provider))))

;;; ============================================================
;;; 请求构建
;;; ============================================================

(defun build-embedding-request (provider texts &key model dimensions
                                                    encoding-format
                                                    extra-params)
  "构建 OpenAI 兼容的嵌入请求体（hash-table）。

可选字段「存在才发送」，与对话侧同一约定：dimensions 只有
text-embedding-3-* 等少数模型支持，强塞给别的模型会 400。"
  (let ((body (make-hash-table :test 'equal))
        (effective-model
          (or model
              (cl-agent.core:provider-default-embedding-model provider))))
    (unless effective-model
      (cl-agent.core:signal-error
       'cl-agent.core:embedding-error
       :message (format nil "未指定嵌入模型，且提供商 ~A 没有默认嵌入模型，请传 :model"
                        (cl-agent.core:provider-name provider))))
    (setf (gethash "model" body) effective-model)
    (setf (gethash "input" body) (coerce texts 'vector))
    (when dimensions
      (setf (gethash "dimensions" body) dimensions))
    (when encoding-format
      (setf (gethash "encoding_format" body) encoding-format))
    (when extra-params
      (loop for (key value) on extra-params by #'cddr
            do (setf (gethash (if (stringp key)
                                  key
                                  (substitute #\_ #\-
                                              (string-downcase (string key))))
                              body)
                     value)))
    body))

;;; ============================================================
;;; 响应解析
;;; ============================================================

(defun parse-embedding-vector (raw)
  "把一条 embedding 归一化为 single-float 向量。

jzon 把 JSON 数组解析为向量、数字解析为 double-float/整数；
统一降为 single-float——嵌入向量按元素存 double 是 8 倍内存换
零精度收益（厂商本身只给 6～7 位有效数字）。"
  (let ((items (cond ((vectorp raw) raw)
                     ((listp raw) (coerce raw 'vector))
                     (t #()))))
    (map 'vector (lambda (x) (coerce x 'single-float)) items)))

(defun parse-embedding-response (response)
  "解析 OpenAI 兼容的嵌入响应，产出统一的 embedding-response。

data 数组按 index 升序排列后再取向量——厂商不保证到达顺序，
不排序就会出现「向量配错文本」这种不报错也查不出的故障。"
  (let* ((parsed (parse-json-response response))
         (data (gethash "data" parsed))
         (items (cond ((null data) nil)
                      ((vectorp data) (coerce data 'list))
                      ((listp data) data)
                      (t nil)))
         (sorted (sort (copy-list items)
                       #'<
                       :key (lambda (item)
                              (or (and (hash-table-p item)
                                       (gethash "index" item))
                                  0)))))
    (cl-agent.core:make-embedding-response
     :embeddings (mapcar (lambda (item)
                           (parse-embedding-vector
                            (when (hash-table-p item)
                              (gethash "embedding" item))))
                         sorted)
     :model (gethash "model" parsed)
     :usage (cl-agent.core:normalize-usage (gethash "usage" parsed))
     :raw-response parsed)))

;;; ============================================================
;;; llm-embed 实现（OpenAI 兼容基座）
;;; ============================================================

(defmethod cl-agent.core:llm-embed
    ((provider cl-agent.llm.providers::openai-compat-provider) texts
     &key model dimensions encoding-format extra-params)
  "OpenAI 兼容端点的嵌入实现（openai / siliconflow / zhipu / ollama / ...）。

TEXTS 接受单个字符串或字符串列表；返回的 embeddings 顺序与输入一致。"
  (let* ((text-list (if (stringp texts) (list texts) texts))
         (request-body (build-embedding-request provider text-list
                                                :model model
                                                :dimensions dimensions
                                                :encoding-format encoding-format
                                                :extra-params extra-params))
         (url (build-api-url provider (provider-embedding-endpoint provider)))
         (headers (cl-agent.llm.providers::provider-request-headers provider))
         (response (make-http-request
                    url
                    headers
                    (cl-agent.core:json-stringify request-body)
                    :timeout (provider-timeout provider))))
    (parse-embedding-response response)))

;;; ============================================================
;;; 便捷 API
;;; ============================================================

(defun embedding-provider (provider-or-client)
  "取出 provider 实例：接受 provider 本身或 client。"
  (if (typep provider-or-client 'client)
      (client-provider provider-or-client)
      provider-or-client))

(defun embed (provider-or-client text &rest args
              &key model dimensions encoding-format extra-params)
  "为单条文本生成嵌入向量。

参数：
  PROVIDER-OR-CLIENT - provider 实例或 client
  TEXT               - 文本
  其余关键字参数同 llm-embed。

返回：
  single-float 向量

示例：
  (embed *gpt* \"Hello, world!\")
  => #(0.123 0.456 ...)"
  (declare (ignore model dimensions encoding-format extra-params))
  (cl-agent.core:embedding-response-first
   (apply #'cl-agent.core:llm-embed
          (embedding-provider provider-or-client)
          (list text)
          args)))

(defun embed-batch (provider-or-client texts &rest args
                    &key model dimensions encoding-format extra-params)
  "批量生成嵌入向量。

返回：
  向量列表，顺序与 TEXTS 一一对应。

示例：
  (embed-batch *gpt* '(\"文本1\" \"文本2\" \"文本3\"))
  => (#(...) #(...) #(...))"
  (declare (ignore model dimensions encoding-format extra-params))
  (cl-agent.core:embedding-response-embeddings
   (apply #'cl-agent.core:llm-embed
          (embedding-provider provider-or-client)
          texts
          args)))

(defun embed-response (provider-or-client texts &rest args
                       &key model dimensions encoding-format extra-params)
  "同 embed-batch，但返回完整的 embedding-response（含 usage / model）。"
  (declare (ignore model dimensions encoding-format extra-params))
  (apply #'cl-agent.core:llm-embed
         (embedding-provider provider-or-client)
         (if (stringp texts) (list texts) texts)
         args))

;;; ============================================================
;;; 向量工具
;;; ============================================================

(defun cosine-similarity (a b)
  "两个向量的余弦相似度（嵌入检索的标准度量）。

维度不一致时报 validation-error——静默返回一个数会让
「用错了模型」这类问题一路漂到检索结果排序里才被察觉。"
  (unless (= (length a) (length b))
    (cl-agent.core:signal-error
     'cl-agent.core:validation-error
     :message (format nil "向量维度不一致：~A vs ~A" (length a) (length b))
     :field "embedding"))
  (let ((dot 0.0) (norm-a 0.0) (norm-b 0.0))
    (dotimes (i (length a))
      (let ((x (aref a i)) (y (aref b i)))
        (incf dot (* x y))
        (incf norm-a (* x x))
        (incf norm-b (* y y))))
    (if (or (zerop norm-a) (zerop norm-b))
        0.0
        (/ dot (* (sqrt norm-a) (sqrt norm-b))))))
