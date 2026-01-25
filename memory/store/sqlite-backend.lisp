;;;; store/sqlite-backend.lisp
;;;; CL-Agent Memory - SQLite Backend for Store
;;;;
;;;; Overview:
;;;;   SQLite implementation of the Store protocol
;;;;
;;;; Features:
;;;;   - 持久化存储
;;;;   - 支持大量数据
;;;;   - 线程安全（SQLite WAL 模式）
;;;;   - 自动创建表结构
;;;;
;;;; Usage:
;;;;   (make-sqlite-store-backend :db-path "/path/to/store.db")
;;;;
;;;; Table Schema:
;;;;   store_items (
;;;;     full_key TEXT PRIMARY KEY,
;;;;     namespace TEXT NOT NULL,
;;;;     key TEXT NOT NULL,
;;;;     value TEXT NOT NULL,      -- JSON 序列化
;;;;     embedding TEXT,           -- JSON 序列化数组
;;;;     metadata TEXT,            -- JSON 序列化
;;;;     created_at INTEGER NOT NULL,
;;;;     updated_at INTEGER NOT NULL
;;;;   )

(in-package #:cl-agent.memory)

;;; ============================================================
;;; SQLite Backend Class
;;; ============================================================

(defclass sqlite-store-backend ()
  ((db-path
    :initarg :db-path
    :reader sqlite-store-db-path
    :type string
    :documentation "SQLite 数据库文件路径")

   (connection
    :initarg :connection
    :accessor sqlite-store-connection
    :initform nil
    :documentation "数据库连接")

   (lock
    :initarg :lock
    :reader sqlite-store-lock
    :initform (bt:make-lock "sqlite-store")
    :documentation "线程锁")

   (auto-vacuum
    :initarg :auto-vacuum
    :reader sqlite-store-auto-vacuum
    :initform t
    :type boolean
    :documentation "是否自动清理")

   (busy-timeout
    :initarg :busy-timeout
    :reader sqlite-store-busy-timeout
    :initform 5000
    :type integer
    :documentation "忙等待超时（毫秒）"))

  (:documentation "SQLite Store Backend

SQLite 实现的 Store 协议，适用于：
- 持久化存储
- 单机部署
- 中等规模数据

特性：
- 使用 WAL 模式提高并发性能
- 自动创建表结构
- JSON 序列化存储值"))

(defun make-sqlite-store-backend (&key db-path
                                       (auto-vacuum t)
                                       (busy-timeout 5000))
  "创建 SQLite Store 后端实例

参数：
  DB-PATH      - 数据库文件路径（必需）
  AUTO-VACUUM  - 是否自动清理（默认 T）
  BUSY-TIMEOUT - 忙等待超时毫秒数（默认 5000）

返回：
  sqlite-store-backend 实例

示例：
  (make-sqlite-store-backend :db-path \"/tmp/store.db\")
  (make-sqlite-store-backend :db-path \":memory:\")  ; 内存数据库"
  (unless db-path
    (error "db-path is required for sqlite-store-backend"))

  (let ((backend (make-instance 'sqlite-store-backend
                                :db-path db-path
                                :auto-vacuum auto-vacuum
                                :busy-timeout busy-timeout)))
    ;; 初始化数据库
    (sqlite-init-db backend)
    backend))

(defmethod print-object ((backend sqlite-store-backend) stream)
  (print-unreadable-object (backend stream :type t)
    (format stream "~A" (sqlite-store-db-path backend))))

;;; ============================================================
;;; Database Initialization
;;; ============================================================

(defun sqlite-init-db (backend)
  "初始化数据库连接和表结构"
  (let ((conn (dbi:connect :sqlite3
                           :database-name (sqlite-store-db-path backend))))
    (setf (sqlite-store-connection backend) conn)

    ;; 设置 WAL 模式和其他优化
    (dbi:do-sql conn "PRAGMA journal_mode=WAL")
    (dbi:do-sql conn "PRAGMA synchronous=NORMAL")
    (dbi:do-sql conn (format nil "PRAGMA busy_timeout=~A"
                             (sqlite-store-busy-timeout backend)))

    ;; 创建表
    (dbi:do-sql conn "
      CREATE TABLE IF NOT EXISTS store_items (
        full_key TEXT PRIMARY KEY,
        namespace TEXT NOT NULL,
        key TEXT NOT NULL,
        value TEXT NOT NULL,
        embedding TEXT,
        metadata TEXT,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )")

    ;; 创建索引
    (dbi:do-sql conn "
      CREATE INDEX IF NOT EXISTS idx_store_namespace
      ON store_items(namespace)")
    (dbi:do-sql conn "
      CREATE INDEX IF NOT EXISTS idx_store_updated_at
      ON store_items(updated_at)")

    conn))

(defun sqlite-ensure-connection (backend)
  "确保数据库连接有效"
  (unless (sqlite-store-connection backend)
    (sqlite-init-db backend))
  (sqlite-store-connection backend))

(defgeneric sqlite-close (backend)
  (:documentation "关闭数据库连接"))

(defmethod sqlite-close ((backend sqlite-store-backend))
  "关闭 SQLite 连接"
  (when (sqlite-store-connection backend)
    (dbi:disconnect (sqlite-store-connection backend))
    (setf (sqlite-store-connection backend) nil)))

;;; ============================================================
;;; JSON Serialization Helpers
;;; ============================================================

(defun sqlite-serialize-value (value)
  "将值序列化为 JSON 字符串"
  (com.inuoe.jzon:stringify value))

(defun sqlite-deserialize-value (json-string)
  "将 JSON 字符串反序列化为值"
  (when json-string
    (com.inuoe.jzon:parse json-string)))

;;; ============================================================
;;; Store Protocol Implementation
;;; ============================================================

(defmethod store-put ((backend sqlite-store-backend) namespace key value
                      &key metadata embedding)
  "存储值到 SQLite"
  (bt:with-lock-held ((sqlite-store-lock backend))
    (let* ((conn (sqlite-ensure-connection backend))
           (fkey (full-key namespace key))
           (ns-string (namespace-to-string namespace))
           (now (get-universal-time))
           (value-json (sqlite-serialize-value value))
           (embedding-json (when embedding (sqlite-serialize-value embedding)))
           (metadata-json (when metadata (sqlite-serialize-value metadata))))

      ;; 使用 UPSERT（INSERT OR REPLACE）
      (dbi:do-sql conn
        "INSERT OR REPLACE INTO store_items
         (full_key, namespace, key, value, embedding, metadata, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?,
                 COALESCE((SELECT created_at FROM store_items WHERE full_key = ?), ?),
                 ?)"
        (list fkey ns-string key value-json embedding-json metadata-json
              fkey now now))

      ;; 返回 store-item
      (make-instance 'store-item
                     :namespace namespace
                     :key key
                     :value value
                     :embedding embedding
                     :metadata metadata
                     :created-at now
                     :updated-at now))))

(defmethod store-get ((backend sqlite-store-backend) namespace key)
  "从 SQLite 获取值"
  (bt:with-lock-held ((sqlite-store-lock backend))
    (let* ((conn (sqlite-ensure-connection backend))
           (fkey (full-key namespace key))
           (query (dbi:prepare conn
                    "SELECT namespace, key, value, embedding, metadata,
                            created_at, updated_at
                     FROM store_items WHERE full_key = ?"))
           (result (dbi:fetch (dbi:execute query (list fkey)))))

      (when result
        (make-instance 'store-item
                       :namespace (string-to-namespace (getf result :|namespace|))
                       :key (getf result :|key|)
                       :value (sqlite-deserialize-value (getf result :|value|))
                       :embedding (sqlite-deserialize-value (getf result :|embedding|))
                       :metadata (sqlite-deserialize-value (getf result :|metadata|))
                       :created-at (getf result :|created_at|)
                       :updated-at (getf result :|updated_at|))))))

(defmethod store-delete ((backend sqlite-store-backend) namespace key)
  "从 SQLite 删除值"
  (bt:with-lock-held ((sqlite-store-lock backend))
    (let* ((conn (sqlite-ensure-connection backend))
           (fkey (full-key namespace key)))

      ;; 检查是否存在
      (let* ((check-query (dbi:prepare conn
                            "SELECT 1 FROM store_items WHERE full_key = ?"))
             (exists (dbi:fetch (dbi:execute check-query (list fkey)))))

        (when exists
          (dbi:do-sql conn "DELETE FROM store_items WHERE full_key = ?"
                      (list fkey))
          t)))))

(defmethod store-search ((backend sqlite-store-backend) namespace-prefix
                         &key query limit filter)
  "在 SQLite 中搜索"
  (bt:with-lock-held ((sqlite-store-lock backend))
    (let* ((conn (sqlite-ensure-connection backend))
           (ns-prefix (if namespace-prefix
                         (concatenate 'string
                                      (namespace-to-string namespace-prefix)
                                      "%")
                         "%"))
           (sql (if limit
                   (format nil "SELECT namespace, key, value, embedding, metadata,
                                       created_at, updated_at
                                FROM store_items
                                WHERE namespace LIKE ?
                                ORDER BY updated_at DESC
                                LIMIT ~A" limit)
                   "SELECT namespace, key, value, embedding, metadata,
                           created_at, updated_at
                    FROM store_items
                    WHERE namespace LIKE ?
                    ORDER BY updated_at DESC"))
           (stmt (dbi:prepare conn sql))
           (result-set (dbi:execute stmt (list ns-prefix)))
           (results '()))

      ;; 收集结果
      (loop for row = (dbi:fetch result-set)
            while row
            do (let ((item (make-instance 'store-item
                             :namespace (string-to-namespace (getf row :|namespace|))
                             :key (getf row :|key|)
                             :value (sqlite-deserialize-value (getf row :|value|))
                             :embedding (sqlite-deserialize-value (getf row :|embedding|))
                             :metadata (sqlite-deserialize-value (getf row :|metadata|))
                             :created-at (getf row :|created_at|)
                             :updated-at (getf row :|updated_at|))))
                 ;; 应用 filter
                 (when (or (null filter) (funcall filter item))
                   (push item results))))

      ;; 如果有 query，进行简单的关键词匹配排序
      (when query
        (let ((keywords (extract-keywords query)))
          (setf results
                (sort results #'>
                      :key (lambda (item)
                             (let ((content (princ-to-string (store-item-value item))))
                               (count-if (lambda (kw)
                                          (search kw content :test #'char-equal))
                                        keywords)))))))

      (nreverse results))))

(defmethod store-list-namespaces ((backend sqlite-store-backend) prefix
                                   &key limit)
  "列出命名空间"
  (bt:with-lock-held ((sqlite-store-lock backend))
    (let* ((conn (sqlite-ensure-connection backend))
           (ns-prefix (if prefix
                         (concatenate 'string
                                      (namespace-to-string prefix)
                                      "%")
                         "%"))
           (sql (if limit
                   (format nil "SELECT DISTINCT namespace FROM store_items
                                WHERE namespace LIKE ?
                                ORDER BY namespace
                                LIMIT ~A" limit)
                   "SELECT DISTINCT namespace FROM store_items
                    WHERE namespace LIKE ?
                    ORDER BY namespace"))
           (stmt (dbi:prepare conn sql))
           (result-set (dbi:execute stmt (list ns-prefix)))
           (namespaces '()))

      (loop for row = (dbi:fetch result-set)
            while row
            do (push (string-to-namespace (getf row :|namespace|)) namespaces))

      (nreverse namespaces))))

(defmethod store-clear ((backend sqlite-store-backend) &optional namespace)
  "清空 SQLite 存储"
  (bt:with-lock-held ((sqlite-store-lock backend))
    (let ((conn (sqlite-ensure-connection backend)))
      (if namespace
          ;; 清空特定命名空间
          (let* ((ns-prefix (concatenate 'string
                                         (namespace-to-string namespace)
                                         "%"))
                 ;; 先计数
                 (count-query (dbi:prepare conn
                                "SELECT COUNT(*) as cnt FROM store_items
                                 WHERE namespace LIKE ?"))
                 (count-result (dbi:fetch (dbi:execute count-query (list ns-prefix))))
                 (count (getf count-result :|cnt|)))
            (dbi:do-sql conn "DELETE FROM store_items WHERE namespace LIKE ?"
                        (list ns-prefix))
            count)
          ;; 清空全部
          (let* ((count-query (dbi:prepare conn "SELECT COUNT(*) as cnt FROM store_items"))
                 (count-result (dbi:fetch (dbi:execute count-query nil)))
                 (count (getf count-result :|cnt|)))
            (dbi:do-sql conn "DELETE FROM store_items")
            count)))))

(defmethod store-count ((backend sqlite-store-backend) &optional namespace)
  "计数 SQLite 中的条目"
  (bt:with-lock-held ((sqlite-store-lock backend))
    (let ((conn (sqlite-ensure-connection backend)))
      (if namespace
          ;; 计数特定命名空间
          (let* ((ns-prefix (concatenate 'string
                                         (namespace-to-string namespace)
                                         "%"))
                 (query (dbi:prepare conn
                          "SELECT COUNT(*) as cnt FROM store_items
                           WHERE namespace LIKE ?"))
                 (result (dbi:fetch (dbi:execute query (list ns-prefix)))))
            (getf result :|cnt|))
          ;; 计数全部
          (let* ((query (dbi:prepare conn "SELECT COUNT(*) as cnt FROM store_items"))
                 (result (dbi:fetch (dbi:execute query nil))))
            (getf result :|cnt|))))))

(defmethod store-stats ((backend sqlite-store-backend))
  "获取 SQLite 存储统计"
  (bt:with-lock-held ((sqlite-store-lock backend))
    (let ((conn (sqlite-ensure-connection backend)))
      ;; 总条目数
      (let* ((count-query (dbi:prepare conn "SELECT COUNT(*) as cnt FROM store_items"))
             (count-result (dbi:fetch (dbi:execute count-query nil)))
             (total-items (getf count-result :|cnt|))

             ;; 命名空间数
             (ns-query (dbi:prepare conn
                         "SELECT COUNT(DISTINCT namespace) as cnt FROM store_items"))
             (ns-result (dbi:fetch (dbi:execute ns-query nil)))
             (total-namespaces (getf ns-result :|cnt|))

             ;; 时间戳范围
             (time-query (dbi:prepare conn
                           "SELECT MIN(updated_at) as oldest,
                                   MAX(updated_at) as newest
                            FROM store_items"))
             (time-result (dbi:fetch (dbi:execute time-query nil)))

             ;; 数据库文件大小
             (db-path (sqlite-store-db-path backend))
             (file-size (when (and (not (string= db-path ":memory:"))
                                   (probe-file db-path))
                         (with-open-file (s db-path)
                           (file-length s)))))

        `(:total-items ,total-items
          :total-namespaces ,total-namespaces
          :oldest-timestamp ,(getf time-result :|oldest|)
          :newest-timestamp ,(getf time-result :|newest|)
          :db-path ,db-path
          :file-size-bytes ,file-size
          :backend-type :sqlite)))))

;;; ============================================================
;;; Batch Operations
;;; ============================================================

(defmethod store-put-batch ((backend sqlite-store-backend) items)
  "批量存储到 SQLite（使用事务）"
  (bt:with-lock-held ((sqlite-store-lock backend))
    (let ((conn (sqlite-ensure-connection backend))
          (count 0))

      ;; 使用事务
      (dbi:do-sql conn "BEGIN TRANSACTION")

      (unwind-protect
          (progn
            (dolist (item items)
              (let* ((namespace (getf item :namespace))
                     (key (getf item :key))
                     (value (getf item :value))
                     (metadata (getf item :metadata))
                     (embedding (getf item :embedding))
                     (fkey (full-key namespace key))
                     (ns-string (namespace-to-string namespace))
                     (now (get-universal-time))
                     (value-json (sqlite-serialize-value value))
                     (embedding-json (when embedding (sqlite-serialize-value embedding)))
                     (metadata-json (when metadata (sqlite-serialize-value metadata))))

                (dbi:do-sql conn
                  "INSERT OR REPLACE INTO store_items
                   (full_key, namespace, key, value, embedding, metadata, created_at, updated_at)
                   VALUES (?, ?, ?, ?, ?, ?,
                           COALESCE((SELECT created_at FROM store_items WHERE full_key = ?), ?),
                           ?)"
                  (list fkey ns-string key value-json embedding-json metadata-json
                        fkey now now))
                (incf count)))

            (dbi:do-sql conn "COMMIT"))

        ;; 出错时回滚
        (when (< count (length items))
          (dbi:do-sql conn "ROLLBACK")))

      count)))

(defmethod store-get-batch ((backend sqlite-store-backend) keys)
  "批量获取"
  (bt:with-lock-held ((sqlite-store-lock backend))
    (let ((conn (sqlite-ensure-connection backend)))
      (mapcar
       (lambda (k)
         (let* ((namespace (getf k :namespace))
                (key (getf k :key))
                (fkey (full-key namespace key))
                (query (dbi:prepare conn
                         "SELECT namespace, key, value, embedding, metadata,
                                 created_at, updated_at
                          FROM store_items WHERE full_key = ?"))
                (result (dbi:fetch (dbi:execute query (list fkey)))))

           (when result
             (make-instance 'store-item
                            :namespace (string-to-namespace (getf result :|namespace|))
                            :key (getf result :|key|)
                            :value (sqlite-deserialize-value (getf result :|value|))
                            :embedding (sqlite-deserialize-value (getf result :|embedding|))
                            :metadata (sqlite-deserialize-value (getf result :|metadata|))
                            :created-at (getf result :|created_at|)
                            :updated_at (getf result :|updated_at|)))))
       keys))))

(defmethod store-delete-batch ((backend sqlite-store-backend) keys)
  "批量删除（使用事务）"
  (bt:with-lock-held ((sqlite-store-lock backend))
    (let ((conn (sqlite-ensure-connection backend))
          (count 0))

      (dbi:do-sql conn "BEGIN TRANSACTION")

      (unwind-protect
          (progn
            (dolist (k keys)
              (let* ((namespace (getf k :namespace))
                     (key (getf k :key))
                     (fkey (full-key namespace key)))

                ;; 检查是否存在
                (let* ((check-query (dbi:prepare conn
                                      "SELECT 1 FROM store_items WHERE full_key = ?"))
                       (exists (dbi:fetch (dbi:execute check-query (list fkey)))))
                  (when exists
                    (dbi:do-sql conn "DELETE FROM store_items WHERE full_key = ?"
                                (list fkey))
                    (incf count)))))

            (dbi:do-sql conn "COMMIT"))

        ;; 确保提交或回滚
        (ignore-errors
          (dbi:do-sql conn "COMMIT")))

      count)))
