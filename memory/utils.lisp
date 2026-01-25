;;;; utils.lisp
;;;; CL-Agent Memory - 辅助函数
;;;;
;;;; 概述：
;;;;   记忆管理系统的辅助函数

(in-package :cl-agent.memory)

;;; ============================================================
;;; Token 估算
;;; ============================================================

(defun estimate-tokens (text)
  "估算文本的 token 数量

参数：
  TEXT - 输入文本

返回：
  估算的 token 数

注意：
  - 英文：约 4 字符/token
  - 中文：约 2 字符/token
  - 代码：约 3-4 字符/token
  - 这里使用保守估计：4 字符/token"
  (declare (type string text)
           (optimize (speed 3) (safety 1)))
  (ceiling (/ (length text) 4.0)))

;;; ============================================================
;;; 关键词提取
;;; ============================================================

(defun extract-keywords (text)
  "从文本中提取关键词

参数：
  TEXT - 输入文本

返回：
  关键词列表（小写）"
  (let* ((words (cl-ppcre:split "\\s+" text))
         (stopwords '("the" "a" "an" "and" "or" "but" "in" "on" "at" "to" "for"
                     "of" "with" "by" "from" "is" "was" "are" "were" "be" "been"
                     "have" "has" "had" "do" "does" "did" "will" "would" "could"
                     "should" "may" "might" "must" "can" "this" "that" "it" "as"
                     "i" "you" "he" "she" "we" "they" "my" "your" "his" "her"
                     "our" "their" "what" "which" "who" "when" "where" "why" "how"))
         (filtered '()))

    (dolist (word words)
      (let ((clean-word (string-downcase
                        (cl-ppcre:regex-replace-all "[^a-zA-Z0-9]" word ""))))
        (when (and (> (length clean-word) 2)
                   (not (member clean-word stopwords :test #'string=)))
          (pushnew clean-word filtered :test #'string=))))

    filtered))

;;; ============================================================
;;; 向量相似度计算
;;; ============================================================

(defun cosine-similarity (vec1 vec2)
  "计算两个向量的余弦相似度

参数：
  VEC1 - 第一个向量
  VEC2 - 第二个向量

返回：
  相似度（0.0-1.0）"
  (declare (optimize (speed 3) (safety 1)))
  (let ((dot-product (reduce #'+ (mapcar #'* vec1 vec2) :initial-value 0.0))
        (norm1 (sqrt (reduce #'+ (mapcar (lambda (x) (* x x)) vec1) :initial-value 0.0)))
        (norm2 (sqrt (reduce #'+ (mapcar (lambda (x) (* x x)) vec2) :initial-value 0.0))))
    (if (or (zerop norm1) (zerop norm2))
        0.0
        (/ dot-product (* norm1 norm2)))))

;;; ============================================================
;;; 记忆存储协议（基础）
;;; ============================================================

(defgeneric memory-store-add (store item)
  (:documentation "添加项目到存储

参数：
  STORE - 存储实例
  ITEM  - 要添加的项目

返回：
  项目 ID 或项目本身"))

(defgeneric memory-store-get (store id)
  (:documentation "根据 ID 获取项目

参数：
  STORE - 存储实例
  ID    - 项目 ID

返回：
  项目或 NIL"))

(defgeneric memory-store-remove (store id)
  (:documentation "根据 ID 移除项目

参数：
  STORE - 存储实例
  ID    - 项目 ID

返回：
  T 表示成功，NIL 表示失败"))

(defgeneric memory-store-clear (store)
  (:documentation "清空存储

参数：
  STORE - 存储实例

返回：
  存储实例"))

(defgeneric memory-store-count (store)
  (:documentation "获取存储中的项目数量

参数：
  STORE - 存储实例

返回：
  项目数量（整数）"))

(defgeneric memory-store-list (store &key limit offset)
  (:documentation "列出存储中的项目

参数：
  STORE  - 存储实例
  LIMIT  - 返回数量限制（可选）
  OFFSET - 偏移量（可选）

返回：
  项目列表"))

;;; ============================================================
;;; 其他辅助函数
;;; ============================================================

(defun hash-table-to-alist (table)
  "将 hash-table 转换为 alist

参数：
  TABLE - hash-table

返回：
  alist"
  (let ((alist '()))
    (maphash (lambda (k v)
               (push (cons k v) alist))
             table)
    alist))

(defun alist-to-hash-table (alist &key (test #'equal))
  "从 alist 创建 hash-table

参数：
  ALIST - alist
  TEST  - 比较函数（默认 #'equal）

返回：
  hash-table"
  (let ((table (make-hash-table :test test)))
    (dolist (pair (or alist '()))
      (setf (gethash (car pair) table) (cdr pair)))
    table))

;;; 注：format-timestamp 和 truncate-string 已从 cl-agent.core 导出
;;; 使用 (cl-agent.core:format-timestamp ...) 和 (cl-agent.core:truncate-string ...)
