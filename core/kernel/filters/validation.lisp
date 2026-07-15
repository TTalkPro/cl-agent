;;;; validation.lisp
;;;; CL-Agent Kernel Filters - 答案校验 (:turn, 递归重入)
;;;;
;;;; 概述（对标 clj-agent validation-turn-filter + Spring StructuredOutputValidationAdvisor）：
;;;;   校验最终回答，不合格 → 把原因作为反馈重入整个循环。
;;;;   闭包链天然支持递归重入：多次 (chain req) = 多次完整循环。

(in-package #:cl-agent.kernel)

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
                        (if (member (turn-result-status result) '(:paused :cancelled :error))
                            result
                            ;; 正常完成 → 校验
                            (multiple-value-bind (ok feedback)
                                (funcall validate-fn (turn-result-response result))
                              (if ok
                                  result
                                  (if (>= attempt max-retries)
                                      result  ; 耗尽重试，原样返回
                                      ;; 重入：把 feedback 追加到 messages
                                      (try (1+ attempt)
                                           (make-turn-request
                                            (append (turn-request-messages req)
                                                    (list (cl-agent.chat:user-message feedback)))
                                            :context (turn-request-context req)
                                            :resume-p (turn-request-resume-p req))))))))))
             (try 0 req)))))

;;; ============================================================
;;; structured-output 校验判据
;;; ============================================================

(defun structured-output-validate-fn (schema &key (parse-fn nil))
  "生成 JSON Schema 校验判据（喂给 validation-turn-filter）。

  参数：
  - schema    JSON Schema（hash-table 或 plist）
  - parse-fn  JSON 解析函数（如 #'cl-agent.core:json-parse）；缺省不解析

  返回：(lambda (response) → (values ok-p feedback))"

  (lambda (response)
    (let* ((text (cl-agent.chat:chat-response-text response))
           (stripped (strip-json-fences text))
           (parsed (when parse-fn
                     (handler-case (funcall parse-fn stripped)
                       (error () nil)))))
      (if parsed
          (multiple-value-bind (ok path)
              (cl-agent.core:validate-json-schema parsed schema)
            (if ok
                (values t nil)
                (values nil (format nil "输出不符合 Schema 要求（~A），请修正后重新输出。"
                                    path))))
          ;; 无解析器或解析失败 → 检查是否是空文本
          (if (or (null text) (string= text ""))
              (values nil "响应文本为空，请输出符合要求的 JSON。")
              (values t nil))))))  ; 无解析器 → 放行

(defun strip-json-fences (text)
  "剥离 markdown 代码围栏（```json ... ```）。"
  (let ((trimmed (string-trim '(#\Space #\Tab #\Newline #\Return) text)))
    (if (and (> (length trimmed) 7)
             (string= trimmed "```json" :end1 7))
        ;; 去掉 ```json 头和 ``` 尾
        (let ((after-header (subseq trimmed 7)))
          (string-trim '(#\Space #\Tab #\Newline #\Return)
                       (if (and (> (length after-header) 3)
                                (string= after-header "```"
                                         :start2 (- (length after-header) 3)))
                           (subseq after-header 0 (- (length after-header) 3))
                           after-header)))
        trimmed)))
