;;;; validation.lisp
;;;; CL-Agent ChatClient Filters - 答案校验 (:turn, 递归重入)
;;;;
;;;; 概述（对标 clj-agent validation-turn-filter + Spring StructuredOutputValidationAdvisor）：
;;;;   校验最终回答，不合格 → 把原因作为反馈重入整个循环。
;;;;   闭包链天然支持递归重入：多次 (chain req) = 多次完整循环。

(in-package #:cl-agent/core)

;;; ============================================================
;;; validation-turn-filter
;;; ============================================================

(defun validation-turn-filter (validate-fn &key (max-retries 2))
  "创建 validation-turn-filter（:turn 链，递归重入）。

  参数：
  - validate-fn  (response) → (values ok-p feedback) 的校验函数
    - ok-p       T/NIL
    - feedback   不合格时的反馈文本（追加到 messages 重入循环）
  - max-retries  最大重试次数（缺省 2，即最多 3 次循环）

  行为：
  1. (chain req) → 第一次结果
  2. validate-fn 检查
  3. 不合格 → 把 feedback 追加到 messages → 再调 (chain req)
  4. 合格或耗尽重试 → 返回最后结果

  硬规则：:paused/:cancelled/:error 结果透传、不重入。"
  (make-filter
   :validation
   :turn (lambda (req chain)
           (labels ((try (attempt req)
                      (let ((result (funcall chain req)))
                        ;; 暂停/取消/错误 → 透传
                        (if (member (chat-client-response-status result) '(:paused :cancelled :error))
                            result
                            ;; 正常完成 → 校验
                            (multiple-value-bind (ok feedback)
                                (funcall validate-fn (chat-client-response-chat-response result))
                              (if ok
                                  result
                                  (if (>= attempt max-retries)
                                      result  ; 耗尽重试，原样返回
                                      ;; 重入：把 feedback 追加到 messages
                                      (try (1+ attempt)
                                           (chat-client-request-mutate
                                            req
                                            :messages
                                            (append (chat-client-request-messages req)
                                                    (list (cl-agent/core:user-message feedback))))))))))))
             (try 0 req)))))

;;; ============================================================
;;; structured-output 校验判据
;;; ============================================================

(defun structured-output-validate-fn (schema &key (parse-fn nil))
  "生成 JSON Schema 校验判据（喂给 validation-turn-filter）。

  参数：
  - schema    JSON Schema（hash-table 或 plist）
  - parse-fn  JSON 解析函数（如 #'cl-agent/core:json-parse）；
              缺省 NIL = 不解析，此时无从校验结构，一律放行

  返回：(lambda (response) → (values ok-p feedback))

  判定顺序（三种「解析不出值」的情形必须分开——曾经它们被挤在一个
  (if parsed ...) 里，结果「给了解析器但模型吐的不是 JSON」也照样放行，
  正是这个 filter 该拦的头号情况）：
  1. 文本为空            → 不合格
  2. 无 parse-fn         → 放行（拿不到结构化值，无从谈校验）
  3. 有 parse-fn 但解析失败 → 不合格（要的就是让模型重出合法 JSON）
  4. 解析成功            → 按 schema 校验，错误逐条回喂"

  (lambda (response)
    (let ((text (cl-agent/core:chat-response-text response)))
      (cond
        ;; 1. 空文本
        ((or (null text)
             (string= (string-trim '(#\Space #\Tab #\Newline #\Return) text) ""))
         (values nil "响应文本为空，请输出符合要求的 JSON。"))
        ;; 2. 无解析器 → 放行
        ((null parse-fn) (values t nil))
        (t
         (multiple-value-bind (parsed parsed-ok)
             (handler-case (values (funcall parse-fn (strip-json-fences text)) t)
               (error () (values nil nil)))
           (if (not parsed-ok)
               ;; 3. 解析失败
               (values nil "输出不是合法 JSON，请只输出 JSON 本身，不要任何多余说明或 markdown 代码围栏。")
               ;; 4. 校验：validate-json-schema 返回的是「错误消息列表」，
               ;;    NIL 才代表通过——不是 ok-p。
               (let ((errors (cl-agent/core:validate-json-schema parsed schema)))
                 (if (null errors)
                     (values t nil)
                     (values nil (format nil "输出不符合 Schema 要求（~{~A~^；~}），请修正后重新输出。"
                                         errors)))))))))))

(defun strip-json-fences (text)
  "剥离 markdown 代码围栏：```json ... ``` 与裸 ``` ... ``` 都吃。
无围栏时只做首尾空白裁剪。

注意 :start1 —— 要判的是「TEXT 的结尾是不是 ```」，start 索引属于
被切片的那一侧。这里曾写成 :start2（去 \"```\" 这个长度 3 的字面量里
取第 N 位），于是任何带 ```json 围栏的输入都直接报 bounding index 错。
而 LLM 恰恰最爱吐带围栏的 JSON。"
  (let* ((trimmed (string-trim '(#\Space #\Tab #\Newline #\Return) text))
         (header (cond ((and (>= (length trimmed) 7)
                             (string= trimmed "```json" :end1 7)) 7)
                       ((and (>= (length trimmed) 3)
                             (string= trimmed "```" :end1 3)) 3)
                       (t nil))))
    (if (null header)
        trimmed
        (let ((body (string-trim '(#\Space #\Tab #\Newline #\Return)
                                 (subseq trimmed header))))
          (string-trim '(#\Space #\Tab #\Newline #\Return)
                       (if (and (>= (length body) 3)
                                (string= body "```" :start1 (- (length body) 3)))
                           (subseq body 0 (- (length body) 3))
                           body))))))
