;;;; rag.lisp
;;;; CL-Agent ChatClient Filters - RAG 问答增强 (:turn)
;;;;
;;;; 概述（对标 clj-agent qa-turn-filter + Spring QuestionAnswerAdvisor）：
;;;;   每 turn 注入一次：取入口最后一条 user 问题 → 检索 → 拼进消息。
;;;;   不引任何检索依赖（IRetriever 协议由用户注入）。
;;;;   检索为空时不注入（偏离 Spring 的严格 grounding 语义）。

(in-package #:cl-agent/core)

;;; ============================================================
;;; IRetriever 协议
;;; ============================================================

(defgeneric retrieve (retriever query &key top-k)
  (:documentation "检索接口（用户实现）。
  参数：
  - retriever  实现本协议的对象
  - query      查询字符串
  - top-k      最大返回数
  返回：字符串列表（检索到的文档/段落）"))

;;; ============================================================
;;; qa-turn-filter
;;; ============================================================

(defun qa-turn-filter (retriever &key (top-k 4) (inject-when-empty nil)
                                      (template nil))
  "创建 qa-turn-filter（:turn 链，每 turn 注入一次）。

  参数：
  - retriever          实现 retrieve 泛型函数的对象
  - top-k              检索返回上限（缺省 4）
  - inject-when-empty  检索为空时是否仍注入（缺省 NIL = 不注入）
  - template           自定义注入模板 (lambda (query docs) → new-text)；
                       缺省：标准问答模板

  行为：
  - 取入口最后一条 user 消息文本作为查询
  - 调 retrieve 获取文档列表
  - 非空 → 把文档拼进消息（模板：问题 + 上下文）
  - 空 + inject-when-empty → 注入空上下文 + grounding 指令
  - 空 + 非 inject-when-empty → 不注入（原样进循环）"
  (let ((default-template
          (lambda (query docs)
            (format nil "上下文信息：~%~{  ~A~%~}~%基于以上信息回答问题：~A"
                    docs query))))
    (let ((tmpl (or template default-template)))
      (make-filter
       :rag
       :turn (lambda (req chain)
               (let* ((messages (chat-client-request-messages req))
                      ;; 找最后一条 user 消息
                      (last-user (find-if (lambda (m)
                                            (typep m 'cl-agent/core:user-message))
                                          messages :from-end t)))
                 (if (and last-user (not (chat-client-request-resume-p req)))
                     (let* ((query (cl-agent/core:message-text last-user))
                            (docs (retrieve retriever query :top-k top-k)))
                       (if (or docs inject-when-empty)
                           ;; let*：new-messages 的初值引用 enhanced
                           (let* ((enhanced (funcall tmpl query docs))
                                  (new-messages
                                    (loop for m in messages
                                          collect (if (eq m last-user)
                                                      (cl-agent/core:user-message enhanced)
                                                      m))))
                             (funcall chain
                                      (chat-client-request-mutate
                                       req :messages new-messages)))
                           ;; 检索为空 → 不注入
                           (funcall chain req)))
                     ;; 无 user 消息 → 不注入
                     (funcall chain req))))))))
