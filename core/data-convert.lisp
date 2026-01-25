;;;; data-convert.lisp
;;;; CL-Agent Core - 数据转换工具
;;;;
;;;; 概述：
;;;;   提供 plist 和 hash-table 之间的统一转换函数
;;;;   内部协议使用 plist，JSON 序列化边界使用 hash-table
;;;;
;;;; 设计原则：
;;;;   - plist 用于小型固定结构（消息、配置等）
;;;;   - hash-table 用于 JSON 序列化
;;;;   - 提供双向转换

(in-package :cl-agent.core)

;;; ============================================================
;;; Plist <-> Hash-table 转换
;;; ============================================================

(defun plist-to-hash (plist &key (string-keys t) (test 'equal))
  "将 plist 转换为 hash-table

参数：
  PLIST       - 属性列表
  STRING-KEYS - 是否将键转换为字符串（默认 t，用于 JSON）
  TEST        - hash-table 测试函数（默认 equal）

返回：
  Hash-table

示例：
  (plist-to-hash '(:name \"John\" :age 30))
  => #<HASH-TABLE {\"name\" => \"John\", \"age\" => 30}>"
  (let ((ht (make-hash-table :test test)))
    (loop for (key value) on plist by #'cddr
          do (let ((k (if string-keys
                          (key-to-string key)
                          key)))
               (setf (gethash k ht)
                     (convert-value-for-hash value string-keys))))
    ht))

(defun hash-to-plist (ht &key (keyword-keys t))
  "将 hash-table 转换为 plist

参数：
  HT           - Hash-table
  KEYWORD-KEYS - 是否将键转换为关键字（默认 t）

返回：
  Plist

示例：
  (hash-to-plist ht) => (:name \"John\" :age 30)"
  (let ((result nil))
    (maphash (lambda (k v)
               (let ((key (if keyword-keys
                              (string-to-keyword k)
                              k)))
                 (push (convert-value-from-hash v keyword-keys) result)
                 (push key result)))
             ht)
    result))

;;; ============================================================
;;; 辅助函数
;;; ============================================================

(defun key-to-string (key)
  "将键转换为字符串（用于 JSON）

参数：
  KEY - 关键字、符号或字符串

返回：
  字符串"
  (etypecase key
    (keyword (string-downcase (symbol-name key)))
    (symbol (string-downcase (symbol-name key)))
    (string key)))

(defun string-to-keyword (str)
  "将字符串转换为关键字

参数：
  STR - 字符串

返回：
  关键字"
  (etypecase str
    (keyword str)
    (symbol (intern (symbol-name str) :keyword))
    (string (intern (string-upcase str) :keyword))))

(defun convert-value-for-hash (value string-keys)
  "递归转换值以用于 hash-table

参数：
  VALUE       - 任意值
  STRING-KEYS - 是否使用字符串键

返回：
  转换后的值"
  (cond
    ;; nil -> :null (用于 JSON)
    ((null value) :null)
    ;; plist -> hash-table
    ((plist-p value)
     (plist-to-hash value :string-keys string-keys))
    ;; list of plists -> vector of hash-tables
    ((and (listp value)
          (every #'plist-p value))
     (coerce (mapcar (lambda (v)
                       (plist-to-hash v :string-keys string-keys))
                     value)
             'vector))
    ;; 其他 list -> vector
    ((listp value)
     (coerce (mapcar (lambda (v)
                       (convert-value-for-hash v string-keys))
                     value)
             'vector))
    ;; 原样返回
    (t value)))

(defun convert-value-from-hash (value keyword-keys)
  "递归转换值从 hash-table

参数：
  VALUE        - 任意值
  KEYWORD-KEYS - 是否使用关键字键

返回：
  转换后的值"
  (cond
    ;; :null -> nil
    ((eq value :null) nil)
    ;; hash-table -> plist
    ((hash-table-p value)
     (hash-to-plist value :keyword-keys keyword-keys))
    ;; vector -> list
    ((vectorp value)
     (map 'list (lambda (v)
                  (convert-value-from-hash v keyword-keys))
          value))
    ;; 原样返回
    (t value)))

(defun plist-p (obj)
  "检查是否为 plist

参数：
  OBJ - 对象

返回：
  t 如果是 plist，nil 否则"
  (and (listp obj)
       (evenp (length obj))
       (loop for (k v) on obj by #'cddr
             always (or (keywordp k) (symbolp k)))))

;;; ============================================================
;;; with-json-hash 宏
;;; ============================================================

(defmacro with-json-hash (var &body key-value-pairs)
  "简化 JSON hash-table 构建

参数：
  VAR             - 绑定变量名
  KEY-VALUE-PAIRS - 键值对列表，每项可选 :when 条件

语法：
  (KEY VALUE)           - 无条件添加
  (KEY VALUE :when COND) - 条件添加

示例：
  (with-json-hash ht
    (\"model\" model-name)
    (\"temperature\" temp)
    (\"max_tokens\" max-tokens :when max-tokens)
    (\"tools\" tools :when tools))

展开为：
  (let ((ht (make-hash-table :test 'equal)))
    (setf (gethash \"model\" ht) model-name)
    (setf (gethash \"temperature\" ht) temp)
    (when max-tokens
      (setf (gethash \"max_tokens\" ht) max-tokens))
    (when tools
      (setf (gethash \"tools\" ht) tools))
    ht)"
  (let ((hash-var (gensym "HASH")))
    `(let ((,hash-var (make-hash-table :test 'equal)))
       ,@(loop for spec in key-value-pairs
               for key = (first spec)
               for value = (second spec)
               for when-clause = (getf (cddr spec) :when)
               collect (if when-clause
                           `(when ,when-clause
                              (setf (gethash ,key ,hash-var) ,value))
                           `(setf (gethash ,key ,hash-var) ,value)))
       (let ((,var ,hash-var))
         ,var))))

;;; ============================================================
;;; alist 转换
;;; ============================================================

(defun alist-to-hash (alist &key (test 'equal))
  "将 alist 转换为 hash-table

参数：
  ALIST - 关联列表
  TEST  - hash-table 测试函数

返回：
  Hash-table"
  (let ((ht (make-hash-table :test test)))
    (dolist (pair alist)
      (setf (gethash (car pair) ht) (cdr pair)))
    ht))

(defun hash-to-alist (ht)
  "将 hash-table 转换为 alist

参数：
  HT - Hash-table

返回：
  Alist"
  (let ((result nil))
    (maphash (lambda (k v)
               (push (cons k v) result))
             ht)
    (nreverse result)))

;;; ============================================================
;;; 深度合并
;;; ============================================================

(defun merge-plists (&rest plists)
  "合并多个 plist，后面的覆盖前面的

参数：
  PLISTS - 要合并的 plist 列表

返回：
  合并后的 plist

示例：
  (merge-plists '(:a 1 :b 2) '(:b 3 :c 4))
  => (:a 1 :b 3 :c 4)"
  (let ((result nil))
    (dolist (plist plists)
      (loop for (key value) on plist by #'cddr
            do (setf (getf result key) value)))
    result))

(defun deep-merge-plists (base overlay)
  "深度合并两个 plist，嵌套的 plist 也会被合并

参数：
  BASE    - 基础 plist
  OVERLAY - 覆盖 plist

返回：
  深度合并后的 plist"
  (let ((result (copy-list base)))
    (loop for (key value) on overlay by #'cddr
          do (let ((base-value (getf result key)))
               (setf (getf result key)
                     (if (and (plist-p base-value)
                              (plist-p value))
                         (deep-merge-plists base-value value)
                         value))))
    result))
