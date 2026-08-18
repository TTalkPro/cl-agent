;;;; test-embeddings.lisp
;;;; CL-Agent - 嵌入向量测试
;;;;
;;;; 覆盖：
;;;;   - 请求体：模型解析 / 可选参数「存在才发送」/ extra-params
;;;;   - 响应解析：按 index 排序、usage 归一、维度
;;;;   - 便捷 API：embed / embed-batch / embed-response
;;;;   - 能力声明：无嵌入服务的 provider 报 embedding-error
;;;;   - cosine-similarity

(in-package :cl-agent/tests)

(def-suite embeddings-suite :in cl-agent-suite
  :description "嵌入向量：请求构建 / 响应解析 / 便捷 API")

(in-suite embeddings-suite)

;;; ============================================================
;;; 测试夹具
;;; ============================================================

(defun openai-embed-provider ()
  (cl-agent.llm.providers:make-openai-provider :api-key "k"))

(defun embedding-json (&key (model "text-embedding-3-small") (shuffled nil))
  "构造 OpenAI 兼容的嵌入响应 JSON。

SHUFFLED 为真时把 data 逆序摆放（index 仍然正确），用来锁住
「按 index 排序」这一条契约。"
  (let ((items '("{\"index\":0,\"embedding\":[1.0,0.0]}"
                 "{\"index\":1,\"embedding\":[0.0,1.0]}")))
    (format nil "{\"object\":\"list\",\"model\":\"~A\",\"data\":[~{~A~^,~}],~
                 \"usage\":{\"prompt_tokens\":7,\"total_tokens\":7}}"
            model
            (if shuffled (reverse items) items))))

;;; ============================================================
;;; 请求构建
;;; ============================================================

(test embedding-request-uses-provider-default-model
  "未指定 :model 时取 provider 的默认嵌入模型（不是对话模型）"
  (let ((body (cl-agent.llm::build-embedding-request
               (openai-embed-provider) '("a" "b"))))
    (is (string= "text-embedding-3-small" (gethash "model" body)))
    ;; 对话默认模型是 gpt-4o —— 不能拿它去调 /embeddings
    (is (string/= "gpt-4o" (gethash "model" body)))
    (is (equalp #("a" "b") (gethash "input" body)))))

(test embedding-request-explicit-model-wins
  "显式 :model 覆盖默认"
  (let ((body (cl-agent.llm::build-embedding-request
               (openai-embed-provider) '("a") :model "text-embedding-3-large")))
    (is (string= "text-embedding-3-large" (gethash "model" body)))))

(test embedding-request-optional-params-absent-when-nil
  "dimensions / encoding_format 不传就不出现（存在才发送）"
  (let ((body (cl-agent.llm::build-embedding-request
               (openai-embed-provider) '("a"))))
    (is-false (nth-value 1 (gethash "dimensions" body)))
    (is-false (nth-value 1 (gethash "encoding_format" body)))))

(test embedding-request-optional-params-sent
  "显式传入的可选参数写入请求体"
  (let ((body (cl-agent.llm::build-embedding-request
               (openai-embed-provider) '("a")
               :dimensions 256 :encoding-format "float")))
    (is (= 256 (gethash "dimensions" body)))
    (is (string= "float" (gethash "encoding_format" body)))))

(test embedding-request-extra-params
  "extra-params 逃生通道：关键字转下划线风格并入顶层"
  (let ((body (cl-agent.llm::build-embedding-request
               (openai-embed-provider) '("a")
               :extra-params '(:user-id "u1" "verbatim" 1))))
    (is (string= "u1" (gethash "user_id" body)))
    (is (= 1 (gethash "verbatim" body)))))

(test embedding-request-without-model-signals
  "provider 无默认嵌入模型且未传 :model 时报 embedding-error"
  (let ((provider (cl-agent.llm.providers:make-openrouter-provider :api-key "k")))
    ;; OpenRouter 只做对话路由，没有嵌入端点
    (is-false (cl-agent.core:provider-default-embedding-model provider))
    (signals cl-agent.core:embedding-error
      (cl-agent.llm::build-embedding-request provider '("a")))))

;;; ============================================================
;;; 响应解析
;;; ============================================================

(test embedding-response-parsed
  "解析出向量 / 模型 / usage"
  (let ((response (cl-agent.llm::parse-embedding-response (embedding-json))))
    (is (cl-agent.core:embedding-response-p response))
    (is (= 2 (length (cl-agent.core:embedding-response-embeddings response))))
    (is (= 2 (cl-agent.core:embedding-dimensions response)))
    (is (string= "text-embedding-3-small"
                 (cl-agent.core:embedding-response-model response)))
    (is (= 7 (cl-agent.core:llm-usage-input-tokens
              (cl-agent.core:embedding-response-usage response))))))

(test embedding-vectors-are-single-float
  "向量元素归一为 single-float"
  (let* ((response (cl-agent.llm::parse-embedding-response (embedding-json)))
         (vec (cl-agent.core:embedding-response-first response)))
    (is (typep (aref vec 0) 'single-float))
    (is (= 1.0 (aref vec 0)))
    (is (= 0.0 (aref vec 1)))))

(test embedding-data-sorted-by-index
  "data 乱序到达时按 index 排序 —— 否则向量会配错文本"
  (let* ((response (cl-agent.llm::parse-embedding-response
                    (embedding-json :shuffled t)))
         (vectors (cl-agent.core:embedding-response-embeddings response)))
    (is (equalp #(1.0 0.0) (first vectors)))
    (is (equalp #(0.0 1.0) (second vectors)))))

;;; ============================================================
;;; DashScope 原生嵌入
;;; ============================================================

(defun dashscope-embed-provider ()
  (cl-agent.llm.providers:make-dashscope-provider :api-key "k"))

(test dashscope-embedding-request-shape
  "DashScope 是自家形状：input.texts + parameters.dimension"
  (let* ((body (cl-agent.llm::build-dashscope-embedding-request
                (dashscope-embed-provider) '("a" "b") :dimensions 1024))
         (input (gethash "input" body))
         (parameters (gethash "parameters" body)))
    (is (string= "text-embedding-v3" (gethash "model" body)))
    (is (equalp #("a" "b") (gethash "texts" input)))
    (is (= 1024 (gethash "dimension" parameters)))
    ;; 不是 OpenAI 那套顶层 input
    (is-false (nth-value 1 (gethash "texts" body)))))

(test dashscope-embedding-parameters-omitted-when-empty
  "没有任何可选参数时不发空的 parameters 对象"
  (let ((body (cl-agent.llm::build-dashscope-embedding-request
               (dashscope-embed-provider) '("a"))))
    (is-false (nth-value 1 (gethash "parameters" body)))))

(test dashscope-embedding-text-type-via-extra-params
  "text_type（query / document）经 extra-params 进 parameters"
  (let ((parameters (gethash "parameters"
                             (cl-agent.llm::build-dashscope-embedding-request
                              (dashscope-embed-provider) '("a")
                              :extra-params '(:text-type "query")))))
    (is (string= "query" (gethash "text_type" parameters)))))

(test dashscope-embedding-response-parsed
  "响应在 output.embeddings 下，索引字段叫 text_index"
  (let ((response (cl-agent.llm::parse-dashscope-embedding-response
                   "{\"output\":{\"embeddings\":[
                      {\"text_index\":1,\"embedding\":[0.0,1.0]},
                      {\"text_index\":0,\"embedding\":[1.0,0.0]}]},
                     \"usage\":{\"total_tokens\":7}}")))
    (is (= 2 (length (cl-agent.core:embedding-response-embeddings response))))
    ;; 同样必须按索引排序
    (is (equalp #(1.0 0.0)
                (first (cl-agent.core:embedding-response-embeddings response))))
    (is (equalp #(0.0 1.0)
                (second (cl-agent.core:embedding-response-embeddings response))))))

(test dashscope-embedding-endpoint-and-capability
  "DashScope 走自家嵌入端点，且声明支持嵌入"
  (let ((provider (dashscope-embed-provider)))
    (is-true (cl-agent.core:provider-supports-embedding-p provider))
    (is (string= "/api/v1/services/embeddings/text-embedding/text-embedding"
                 (cl-agent.llm:provider-embedding-endpoint provider)))))

;;; ============================================================
;;; 便捷 API（不打网络：特化一个假 provider 的 llm-embed）
;;; ============================================================

(defclass fake-embed-provider (cl-agent.llm:base-provider)
  ((requests :initform nil :accessor fake-embed-requests))
  (:documentation "记录调用参数的假嵌入 provider"))

(defmethod cl-agent.core:llm-embed ((provider fake-embed-provider) texts
                                    &key model dimensions encoding-format
                                         extra-params)
  (declare (ignore encoding-format extra-params))
  (push (list :texts texts :model model :dimensions dimensions)
        (fake-embed-requests provider))
  (cl-agent.core:make-embedding-response
   :embeddings (mapcar (lambda (text)
                         (vector (coerce (length text) 'single-float) 0.0))
                       texts)
   :model (or model "fake-embed")
   :usage (cl-agent.core:make-llm-usage :input-tokens 3 :output-tokens 0)))

(defun make-fake-embed-provider ()
  (make-instance 'fake-embed-provider
                 :name :fake-embed
                 :api-url "http://localhost"
                 :default-model "fake"
                 :chat-endpoint "/c"
                 :stream-endpoint "/c"))

(test embed-returns-single-vector
  "embed 取单个向量（而不是列表）"
  (let* ((provider (make-fake-embed-provider))
         (vec (cl-agent.llm:embed provider "abcd")))
    (is (vectorp vec))
    (is (= 4.0 (aref vec 0)))
    ;; 单文本也是按批量接口发出去的
    (is (equal '("abcd") (getf (first (fake-embed-requests provider)) :texts)))))

(test embed-batch-preserves-order
  "embed-batch 返回的向量顺序与输入一一对应"
  (let* ((provider (make-fake-embed-provider))
         (vectors (cl-agent.llm:embed-batch provider '("a" "bb" "ccc"))))
    (is (= 3 (length vectors)))
    (is (equalp '(1.0 2.0 3.0) (mapcar (lambda (v) (aref v 0)) vectors)))))

(test embed-response-exposes-usage
  "embed-response 返回完整响应（含 usage / model）"
  (let* ((provider (make-fake-embed-provider))
         (response (cl-agent.llm:embed-response provider '("a")
                                                :model "m1")))
    (is (string= "m1" (cl-agent.core:embedding-response-model response)))
    (is (= 3 (cl-agent.core:llm-usage-input-tokens
              (cl-agent.core:embedding-response-usage response))))))

(test embed-accepts-client
  "便捷 API 也接受 client（README 的用法就是传 client）"
  (let* ((provider (make-fake-embed-provider))
         (client (make-instance 'cl-agent.llm:client
                                :provider provider
                                :api-key "k"
                                :model "m"
                                :base-url "u"
                                :max-tokens 100)))
    (is (vectorp (cl-agent.llm:embed client "abc")))))

(test embed-passes-options-through
  "model / dimensions 透传到 SPI"
  (let ((provider (make-fake-embed-provider)))
    (cl-agent.llm:embed-batch provider '("a") :model "m2" :dimensions 128)
    (let ((request (first (fake-embed-requests provider))))
      (is (string= "m2" (getf request :model)))
      (is (= 128 (getf request :dimensions))))))

;;; ============================================================
;;; 能力声明
;;; ============================================================

(test embedding-unsupported-provider-signals
  "不支持嵌入的 provider 报 embedding-error，而不是 no-applicable-method"
  (let ((provider (cl-agent.llm.providers:make-anthropic-provider
                   :api-key "sk-ant-test")))
    (is-false (cl-agent.core:provider-supports-embedding-p provider))
    (signals cl-agent.core:embedding-error
      (cl-agent.core:llm-embed provider '("a")))))

(test embedding-capability-follows-default-model
  "OpenAI 兼容 provider 的嵌入能力以是否有默认嵌入模型为准"
  (is-true (cl-agent.core:provider-supports-embedding-p
            (openai-embed-provider)))
  (is-true (cl-agent.core:provider-supports-embedding-p
            (cl-agent.llm.providers:make-siliconflow-provider :api-key "k")))
  (is-false (cl-agent.core:provider-supports-embedding-p
             (cl-agent.llm.providers:make-openrouter-provider :api-key "k"))))

(test embedding-default-models-per-vendor
  "各厂商默认嵌入模型"
  (is (string= "text-embedding-3-small"
               (cl-agent.core:provider-default-embedding-model
                (openai-embed-provider))))
  (is (string= "BAAI/bge-m3"
               (cl-agent.core:provider-default-embedding-model
                (cl-agent.llm.providers:make-siliconflow-provider :api-key "k"))))
  (is (string= "embedding-3"
               (cl-agent.core:provider-default-embedding-model
                (cl-agent.llm.providers:make-zhipu-provider :api-key "k"))))
  (is (string= "nomic-embed-text"
               (cl-agent.core:provider-default-embedding-model
                (cl-agent.llm.providers:make-ollama-provider)))))

(test embedding-endpoint-default
  "嵌入端点默认 /embeddings"
  (is (string= "/embeddings"
               (cl-agent.llm:provider-embedding-endpoint
                (openai-embed-provider)))))

;;; ============================================================
;;; 向量工具
;;; ============================================================

(test cosine-similarity-basics
  "余弦相似度：同向 1，正交 0，反向 -1"
  (is (= 1.0 (cl-agent.llm:cosine-similarity #(1.0 0.0) #(2.0 0.0))))
  (is (= 0.0 (cl-agent.llm:cosine-similarity #(1.0 0.0) #(0.0 3.0))))
  (is (= -1.0 (cl-agent.llm:cosine-similarity #(1.0 0.0) #(-1.0 0.0))))
  ;; 零向量不除零
  (is (= 0.0 (cl-agent.llm:cosine-similarity #(0.0 0.0) #(1.0 0.0)))))

(test cosine-similarity-dimension-mismatch
  "维度不一致报错（多半是用错了嵌入模型）"
  (signals cl-agent.core:validation-error
    (cl-agent.llm:cosine-similarity #(1.0 0.0) #(1.0 0.0 0.0))))
