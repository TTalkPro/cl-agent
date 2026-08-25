;;;; live-provider-check.lisp
;;;; CL-Agent - Provider 层真实链路验证（手动运行，不进测试套件）
;;;;
;;;; 与 live-test.lisp 的分工：
;;;;   live-test.lisp      验证 agent 层行为（工具循环、记忆、HITL、
;;;;                       结构化输出……），用的是默认的对话链路。
;;;;   本脚本（provider 层）验证的是**离线测试证明不了的那部分**：
;;;;   base-url 对不对、鉴权头收不收、默认模型名在你的账号下存不存在、
;;;;   多模态分片厂商认不认、嵌入端点通不通、厂商专有参数会不会 400。
;;;;
;;;;   单元测试全部是针对构造出的请求体/响应体断言的——它能保证我们
;;;;   按文档拼对了 JSON，但保证不了文档与线上一致。这一段只能真打。
;;;;
;;;; 运行：
;;;;   SILICONFLOW_API_KEY=... sbcl --script scripts/live-provider-check.lisp \
;;;;     --provider siliconflow
;;;;
;;;;   XAI_API_KEY=... sbcl --script scripts/live-provider-check.lisp \
;;;;     --provider xai --model grok-4.5
;;;;
;;;;   MOONSHOT_API_KEY=... sbcl --script scripts/live-provider-check.lisp \
;;;;     --provider moonshot --vision-model moonshot-v1-8k-vision-preview
;;;;
;;;;   DASHSCOPE_API_KEY=... sbcl --script scripts/live-provider-check.lisp \
;;;;     --provider dashscope --vision-model qwen-vl-max
;;;;
;;;; 可选参数：
;;;;   --model            对话模型（默认取 provider 的默认模型）
;;;;   --vision-model     多模态模型（不给则跳过多模态检查）
;;;;   --embedding-model  嵌入模型（不给则取 provider 的默认嵌入模型）
;;;;   --image-url        测试图片 URL（默认一张公开的小图）
;;;;   --max-tokens       每次调用的输出上限（默认 2048）
;;;;                      不要为省钱调太小：推理模型（M2.7 / DeepSeek-R1 类）
;;;;                      的思维链也吃这个额度，给 256 会在正文刚起头就截断，
;;;;                      流式检查看到的分片数因此失真——那是额度不够，
;;;;                      不是厂商不增量。
;;;;
;;;; 退出码：0 全通过（跳过不算失败），1 有失败。

(require :asdf)
(let ((root (merge-pathnames "../" (directory-namestring *load-truename*))))
  (dolist (dir '("" "core/" "llm/" "mock/" "client/"))
    (pushnew (truename (merge-pathnames dir root))
             asdf:*central-registry* :test #'equal)))
(let ((ql (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname))))
  (when (probe-file ql) (load ql)))
(handler-bind ((warning #'muffle-warning))
  (asdf:load-system :cl-agent))

(defpackage :cl-agent/live-provider
  (:use :cl :cl-agent/core))
(in-package :cl-agent/live-provider)

;;; ============================================================
;;; 命令行参数
;;; ============================================================

(defun argv-value (flag default)
  (let ((rest (member flag (uiop:command-line-arguments) :test #'string=)))
    (if (and rest (second rest)) (second rest) default)))

(defparameter *provider-name*
  (intern (string-upcase (argv-value "--provider" "siliconflow")) :keyword))
(defparameter *model* (argv-value "--model" nil))
(defparameter *vision-model* (argv-value "--vision-model" nil))
(defparameter *embedding-model* (argv-value "--embedding-model" nil))
(defparameter *max-tokens*
  (parse-integer (argv-value "--max-tokens" "2048")))
(defparameter *image-url*
  (argv-value "--image-url"
              "https://upload.wikimedia.org/wikipedia/commons/thumb/4/4d/Cat_November_2010-1a.jpg/320px-Cat_November_2010-1a.jpg"))

;;; ============================================================
;;; 迷你测试框架
;;; ============================================================

(defvar *pass* 0)
(defvar *fail* 0)
(defvar *skip* 0)

(defmacro defcheck (name description &body body)
  "定义一项检查。BODY 返回 (values 状态 详情)，
状态为 T（通过）/ NIL（失败）/ :skip（条件不满足，不计失败）。"
  `(defun ,name ()
     (format t "~&  ~A ... " ,description)
     (force-output)
     (handler-case
         (multiple-value-bind (status detail) (progn ,@body)
           (cond
             ((eq status :skip)
              (incf *skip*) (format t "SKIP~@[  (~A)~]~%" detail))
             (status
              (incf *pass*) (format t "OK~@[  (~A)~]~%" detail))
             (t
              (incf *fail*) (format t "FAIL~@[  (~A)~]~%" detail))))
       (error (e)
         (incf *fail*)
         (format t "ERROR~%      ~A~%" e)))))

(defvar *provider*)

(defun chat-once (text &key model media tools extra-params)
  "向 provider 直接发一次 llm-chat（绕开 chat-client，验证的是 provider 层）"
  (let ((message (append (list :role :user :content text)
                         (when media (list :media media)))))
    (apply #'llm-chat *provider* (list message)
           :max-tokens *max-tokens*
           (append (when model (list :model model))
                   (when tools (list :tools tools))
                   (when extra-params (list :extra-params extra-params))))))

;;; ============================================================
;;; 检查项
;;; ============================================================

(defcheck check-provider-created "[1/8] provider 可创建（密钥就位、端点已解析）"
  (values (typep *provider* 'cl-agent/llm:base-provider)
          (format nil "~A → ~A~A"
                  (provider-name *provider*)
                  (cl-agent/llm:provider-api-url *provider*)
                  (cl-agent/llm:provider-chat-endpoint *provider*))))

(defcheck check-single-turn "[2/8] 单轮对话（base-url + 鉴权头 + 默认模型名）"
  (let* ((response (chat-once "只回答一个词，不要标点：法国的首都是？"
                              :model *model*))
         (text (llm-response-content response)))
    (values (and (stringp text) (plusp (length text)))
            (format nil "model=~A 答：~A"
                    (llm-response-model response)
                    (string-trim '(#\Space #\Newline) text)))))

(defcheck check-usage-normalized "[3/8] usage 归一（各家字段名不同，须落到同一处）"
  (let* ((response (chat-once "说「好」" :model *model*))
         (usage (llm-response-usage response)))
    (values (and usage
                 (integerp (llm-usage-input-tokens usage))
                 (plusp (llm-usage-input-tokens usage)))
            (when usage
              (format nil "in=~A out=~A"
                      (llm-usage-input-tokens usage)
                      (llm-usage-output-tokens usage))))))

(defcheck check-tool-call "[4/8] 工具调用（tools schema 厂商认不认）"
  (let* ((schema (let ((s (make-hash-table :test 'equal))
                       (props (make-hash-table :test 'equal))
                       (city (make-hash-table :test 'equal)))
                   (setf (gethash "type" city) "string")
                   (setf (gethash "description" city) "城市名称")
                   (setf (gethash "city" props) city)
                   (setf (gethash "type" s) "object")
                   (setf (gethash "properties" s) props)
                   (setf (gethash "required" s) #("city"))
                   s))
         (response (chat-once "东京现在天气怎么样？必须用工具查询。"
                              :model *model*
                              :tools (list (list :name "get_weather"
                                                 :description "查询指定城市的当前天气"
                                                 :input-schema schema))))
         (calls (llm-response-tool-calls response)))
    (values (and calls (plusp (length calls)))
            (format nil "~A 个工具调用" (length calls)))))

(defcheck check-streaming "[5/8] SSE 流式（分片拼接）"
  (if (not (provider-supports-streaming-p *provider*))
      (values :skip "该 provider 未声明流式支持")
      (let ((text-chunks 0) (reasoning-chunks 0))
        (let ((response
                (llm-chat-stream *provider*
                                 (list (list :role :user
                                             :content "从 1 数到 30，用空格分隔，只输出数字。"))
                                 (lambda (chunk)
                                   (cond ((getf chunk :delta) (incf text-chunks))
                                         ((getf chunk :reasoning-delta)
                                          (incf reasoning-chunks))))
                                 :max-tokens *max-tokens*
                                 :model *model*)))
          ;; 多个分片 ⇒ 确实是增量流式；末态 response 与非流式同构。
          ;; 推理模型的思维链也是增量流（:reasoning-delta），同样算数——
          ;; 否则思维链一长，正文的分片数就被 max-tokens 截没了，
          ;; 明明在增量却判成不增量。
          (values (and (> (+ text-chunks reasoning-chunks) 1)
                       (stringp (llm-response-content response))
                       (plusp (length (llm-response-content response))))
                  (format nil "~A 个正文分片~@[ + ~A 个思维链分片~]"
                          text-chunks
                          (when (plusp reasoning-chunks) reasoning-chunks)))))))

(defcheck check-multimodal "[6/8] 多模态输入（图片分片厂商认不认）"
  (if (null *vision-model*)
      (values :skip "未指定 --vision-model")
      (let* ((response (chat-once "这张图里是什么动物？只回答动物名。"
                                  :model *vision-model*
                                  :media (media-list->neutral
                                          (image-media :url *image-url*))))
             (text (llm-response-content response)))
        ;; 只断言「模型看懂了图并回了非空内容」——具体答什么由模型定
        (values (and (stringp text) (plusp (length (string-trim '(#\Space #\Newline) text))))
                (format nil "答：~A" (string-trim '(#\Space #\Newline) text))))))

(defcheck check-embedding "[7/8] 嵌入向量（端点 + 默认嵌入模型）"
  (if (not (provider-supports-embedding-p *provider*))
      (values :skip "该 provider 未声明嵌入支持")
      (let* ((response (apply #'llm-embed *provider* '("今天天气很好" "The weather is nice")
                              (when *embedding-model* (list :model *embedding-model*))))
             (vectors (embedding-response-embeddings response)))
        (values (and (= 2 (length vectors))
                     (plusp (length (first vectors)))
                     ;; 两句语义相近，相似度应明显高于 0
                     (> (cl-agent/llm:cosine-similarity (first vectors)
                                                        (second vectors))
                        0.3))
                (format nil "dim=~A 相似度=~,3F"
                        (embedding-dimensions response)
                        (cl-agent/llm:cosine-similarity (first vectors)
                                                        (second vectors)))))))

(defcheck check-error-message-surfaced "[8/8] 厂商错误原文透出（不是光一个状态码）"
  ;; 故意用一个不可能存在的模型名：期望 llm-error 的 message 里带上
  ;; 厂商说的原因，而不只是「HTTP 请求失败: 400」
  (handler-case
      (progn (chat-once "hi" :model "definitely-not-a-real-model-zzz")
             (values nil "预期报错却成功返回了"))
    (cl-agent/core:llm-error (e)
      (let ((message (cl-agent/core:error-message e)))
        (values (and (stringp message)
                     ;; 带了「-」分隔的厂商原话，说明 body 被解析出来了
                     (search " - " message))
                message)))))

;;; ============================================================
;;; 主流程
;;; ============================================================

(defun main ()
  (format t "~&=== CL-Agent Provider 层真实链路验证 ===~%")
  (format t "provider: ~A~@[  model: ~A~]~@[  vision: ~A~]  max-tokens: ~A~%~%"
          *provider-name* *model* *vision-model* *max-tokens*)
  (handler-case
      (setf *provider* (cl-agent/llm:create-provider *provider-name*))
    (error (e)
      (format t "无法创建 provider：~A~%~%~
                 提示：确认已设置对应的 API key 环境变量；~%~
                 已注册的 provider：~{~A~^ ~}~%"
              e (cl-agent/llm:list-providers))
      (uiop:quit 1)))
  (check-provider-created)
  (check-single-turn)
  (check-usage-normalized)
  (check-tool-call)
  (check-streaming)
  (check-multimodal)
  (check-embedding)
  (check-error-message-surfaced)
  (format t "~%--- 通过 ~A，失败 ~A，跳过 ~A ---~%" *pass* *fail* *skip*)
  (uiop:quit (if (zerop *fail*) 0 1)))

(main)
