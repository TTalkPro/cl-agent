;;;; protocol.lisp
;;;; CL-Agent Model - 模型交互的抽象协议（ModelRequest / ModelResponse / ModelResult）
;;;;
;;;; 概述（对标 Spring AI 的 org.springframework.ai.model）：
;;;;
;;;;   Model<TReq, TRes>          → model-call
;;;;   ModelRequest<T>            → model-request：instructions + options
;;;;   ModelResponse<T>           → model-response：result / results / metadata
;;;;   ModelResult<T>             → model-result：output + metadata
;;;;   ModelOptions               → model-options
;;;;
;;;; 为什么要这一层：
;;;;   chat 之外还有 embedding（以后可能有 image / audio / moderation），
;;;;   它们的请求响应形状一致——「一份输入 + 一组选项」→「一组结果 + 一份
;;;;   元数据」。把这个形状显式写成协议，横切代码（观测、重试、日志、
;;;;   计费）才能对任意模态一视同仁地写一遍，而不是每加一种模态就复制
;;;;   一套 typecase。
;;;;
;;;;   此前 prompt / chat-response / generation 各自是独立的 defclass，
;;;;   彼此之间、与 embedding-response 之间没有任何类型关系。谁也无法写出
;;;;   「接受任意 model-response，取出 usage」这样的函数。
;;;;
;;;; 泛型而非槽位：
;;;;   这一层只定义**访问协议**，不定义存储。prompt 的 messages 存在
;;;;   prompt-messages 槽里，chat-response 的结果存在 generations 槽里——
;;;;   各自的槽名是各自领域里更贴切的名字，协议方法只是把它们映射到统一
;;;;   问法上。所以这里全是 defgeneric，抽象类不带任何槽。

(in-package #:cl-agent/core)

;;; ============================================================
;;; 抽象基类
;;; ============================================================
;;; 四个都不带槽，所以没有 definvariants——不变式是关于**槽的值**的，
;;; 无槽即无约束。具体类各自挂自己的（prompt / chat-response /
;;; generation / embedding-response 都有）。

(defclass model-options ()
  ()
  (:documentation "模型调用选项的抽象基类（对标 ModelOptions）。

  各模态的具体选项类继承它：chat-options / embedding-options…"))

(defclass model-request ()
  ()
  (:documentation "模型请求的抽象基类（对标 ModelRequest<T>）。

  两个协议方法：
    (request-instructions req) → 模型需要的输入本身
    (request-options req)      → 本次调用的选项（可为 NIL）"))

(defclass model-result ()
  ()
  (:documentation "单个模型输出的抽象基类（对标 ModelResult<T>）。

  一次调用可能产出多个候选（n>1），每个候选是一个 model-result。"))

(defclass model-response ()
  ()
  (:documentation "模型响应的抽象基类（对标 ModelResponse<T>）。

  三个协议方法：
    (response-result resp)   → 首个结果（最常用的那个）
    (response-results resp)  → 全部结果
    (response-metadata resp) → 响应级元数据（用量 / 模型名 / 原始体）"))

;;; ============================================================
;;; 请求协议
;;; ============================================================

(defgeneric request-instructions (request)
  (:documentation "取出模型所需的输入本身。

  chat：message 实例列表
  embedding：待嵌入的文本列表

  对标 ModelRequest#getInstructions。"))

(defgeneric request-options (request)
  (:documentation "取出本次调用的选项（model-options 实例或 NIL）。

  对标 ModelRequest#getOptions。"))

;;; ============================================================
;;; 响应协议
;;; ============================================================

(defgeneric response-result (response)
  (:documentation "取出首个结果（model-result 实例或 NIL）。

  对标 ModelResponse#getResult。多数调用只关心第一个候选。"))

(defgeneric response-results (response)
  (:documentation "取出全部结果（model-result 实例列表）。

  对标 ModelResponse#getResults。"))

(defgeneric response-metadata (response)
  (:documentation "取出响应级元数据。

  对标 ModelResponse#getMetadata。"))

;;; 缺省实现：首个结果 = 结果列表的头。
;;; 具体类只要实现 response-results 就自动获得 response-result；
;;; 有更快路径的（如直接持有首元素）可以覆盖。
(defmethod response-result ((response model-response))
  (first (response-results response)))

;;; ============================================================
;;; 结果协议
;;; ============================================================

(defgeneric result-output (result)
  (:documentation "取出这个结果承载的输出本身。

  chat：assistant-message 实例
  embedding：向量

  对标 ModelResult#getOutput。"))

(defgeneric result-metadata (result)
  (:documentation "取出结果级元数据（与响应级区分：这是**单个候选**的）。

  对标 ModelResult#getMetadata。缺省 NIL。"))

(defmethod result-metadata ((result model-result))
  nil)

;;; ============================================================
;;; 统一用量入口
;;; ============================================================

(defgeneric response-usage (response)
  (:documentation "取出响应的 token 用量（llm-usage 实例或 NIL）。

  这是「协议层带来什么」的最小例子：计费/配额代码写一遍，
  chat 与 embedding 都能用，不需要 typecase 分模态。"))

(defmethod response-usage ((response model-response))
  "缺省：从响应元数据里取。元数据类型不认识就返回 NIL。"
  (let ((metadata (response-metadata response)))
    (when metadata
      (metadata-usage metadata))))

(defgeneric metadata-usage (metadata)
  (:documentation "从元数据对象里取 llm-usage。缺省 NIL。"))

(defmethod metadata-usage ((metadata t))
  nil)
