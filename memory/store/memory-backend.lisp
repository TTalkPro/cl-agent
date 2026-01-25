;;;; store/memory-backend.lisp
;;;; CL-Agent Memory - Memory Backend for Store
;;;;
;;;; Overview:
;;;;   In-memory implementation of the Store protocol
;;;;
;;;; Features:
;;;;   - Hash-table based storage
;;;;   - Thread-safe with locks
;;;;   - Suitable for testing and development
;;;;   - Optional size limits with eviction
;;;;
;;;; Reference:
;;;;   - Erlang agent_store_ets

(in-package #:cl-agent.memory)

;;; ============================================================
;;; Memory Backend Class
;;; ============================================================

(defclass memory-store-backend ()
  ((data
    :initarg :data
    :reader memory-store-data
    :initform (make-hash-table :test #'equal)
    :type hash-table
    :documentation "Main data storage (full-key -> store-item)")

   (namespace-index
    :initarg :namespace-index
    :reader memory-store-namespace-index
    :initform (make-hash-table :test #'equal)
    :type hash-table
    :documentation "Namespace index (namespace-string -> list of keys)")

   (lock
    :initarg :lock
    :reader memory-store-lock
    :initform (bt:make-lock "memory-store")
    :documentation "Thread lock for concurrent access")

   (max-size
    :initarg :max-size
    :reader memory-store-max-size
    :initform nil
    :type (or null integer)
    :documentation "Maximum number of items (nil = unlimited)")

   (eviction-policy
    :initarg :eviction-policy
    :reader memory-store-eviction-policy
    :initform :lru
    :type keyword
    :documentation "Eviction policy (:lru, :fifo, :lifo)"))

  (:documentation "Memory Store Backend

In-memory implementation of the Store protocol using hash-tables.

Suitable for:
- Testing and development
- Caching
- Short-term storage

Features:
- Thread-safe
- Optional size limits
- Multiple eviction policies"))

(defun make-memory-store-backend (&key (max-size nil) (eviction-policy :lru))
  "Create a memory store backend instance

Parameters:
  MAX-SIZE        - Maximum items (nil = unlimited)
  EVICTION-POLICY - Eviction policy (:lru, :fifo, :lifo)

Returns:
  memory-store-backend instance"
  (make-instance 'memory-store-backend
                 :max-size max-size
                 :eviction-policy eviction-policy))

(defmethod print-object ((backend memory-store-backend) stream)
  (print-unreadable-object (backend stream :type t)
    (format stream "~A items, max=~A"
            (hash-table-count (memory-store-data backend))
            (or (memory-store-max-size backend) "unlimited"))))

;;; ============================================================
;;; Store Protocol Implementation
;;; ============================================================

(defmethod store-put ((backend memory-store-backend) namespace key value
                      &key metadata embedding)
  "Store a value in memory backend"
  (bt:with-lock-held ((memory-store-lock backend))
    ;; Check size limit and evict if necessary
    (when (and (memory-store-max-size backend)
               (>= (hash-table-count (memory-store-data backend))
                   (memory-store-max-size backend)))
      (evict-store-item backend))

    (let* ((fkey (full-key namespace key))
           (existing (gethash fkey (memory-store-data backend)))
           (now (get-universal-time))
           (item (if existing
                     ;; Update existing item
                     (progn
                       (setf (store-item-value existing) value)
                       (setf (store-item-updated-at existing) now)
                       (when embedding
                         (setf (store-item-embedding existing) embedding))
                       (when metadata
                         (setf (store-item-metadata existing) metadata))
                       existing)
                     ;; Create new item
                     (make-instance 'store-item
                                    :namespace namespace
                                    :key key
                                    :value value
                                    :embedding embedding
                                    :metadata metadata
                                    :created-at now
                                    :updated-at now))))

      ;; Store the item
      (setf (gethash fkey (memory-store-data backend)) item)

      ;; Update namespace index
      (let ((ns-string (namespace-to-string namespace)))
        (pushnew key (gethash ns-string (memory-store-namespace-index backend))
                 :test #'string=))

      item)))

(defmethod store-get ((backend memory-store-backend) namespace key)
  "Retrieve a value from memory backend"
  (bt:with-lock-held ((memory-store-lock backend))
    (let ((fkey (full-key namespace key)))
      (gethash fkey (memory-store-data backend)))))

(defmethod store-delete ((backend memory-store-backend) namespace key)
  "Delete an item from memory backend"
  (bt:with-lock-held ((memory-store-lock backend))
    (let* ((fkey (full-key namespace key))
           (existed (nth-value 1 (gethash fkey (memory-store-data backend)))))
      (when existed
        ;; Remove from main storage
        (remhash fkey (memory-store-data backend))

        ;; Update namespace index
        (let ((ns-string (namespace-to-string namespace)))
          (setf (gethash ns-string (memory-store-namespace-index backend))
                (remove key
                        (gethash ns-string (memory-store-namespace-index backend))
                        :test #'string=))))
      existed)))

(defmethod store-search ((backend memory-store-backend) namespace-prefix
                         &key query limit filter)
  "Search items in memory backend"
  (bt:with-lock-held ((memory-store-lock backend))
    (let ((results '()))
      ;; Iterate through all items
      (maphash
       (lambda (fkey item)
         (declare (ignore fkey))
         (when (and (namespace-prefix-p namespace-prefix
                                        (store-item-namespace item))
                    (or (null filter)
                        (funcall filter item)))
           (push item results)))
       (memory-store-data backend))

      ;; If query provided and items have embeddings, sort by similarity
      (when (and query
                 (some #'store-item-embedding results))
        ;; Simple keyword matching for now
        ;; Full semantic search would require embedding the query
        (let ((keywords (extract-keywords query)))
          (setf results
                (sort results #'>
                      :key (lambda (item)
                             (let ((content (princ-to-string (store-item-value item))))
                               (count-if (lambda (kw)
                                          (search kw content :test #'char-equal))
                                        keywords)))))))

      ;; Sort by updated-at (newest first) if no query
      (unless query
        (setf results (sort results #'> :key #'store-item-updated-at)))

      ;; Apply limit
      (if limit
          (subseq results 0 (min limit (length results)))
          results))))

(defmethod store-list-namespaces ((backend memory-store-backend) prefix
                                  &key limit)
  "List namespaces under a prefix"
  (bt:with-lock-held ((memory-store-lock backend))
    (let ((namespaces '()))
      (maphash
       (lambda (ns-string keys)
         (declare (ignore keys))
         (let ((ns (string-to-namespace ns-string)))
           (when (namespace-prefix-p prefix ns)
             (pushnew ns namespaces :test #'equal))))
       (memory-store-namespace-index backend))

      ;; Sort alphabetically
      (setf namespaces (sort namespaces #'string<
                             :key #'namespace-to-string))

      ;; Apply limit
      (if limit
          (subseq namespaces 0 (min limit (length namespaces)))
          namespaces))))

(defmethod store-clear ((backend memory-store-backend) &optional namespace)
  "Clear the memory backend"
  (bt:with-lock-held ((memory-store-lock backend))
    (if namespace
        ;; Clear specific namespace
        (let ((count 0))
          (maphash
           (lambda (fkey item)
             (when (namespace-prefix-p namespace (store-item-namespace item))
               (remhash fkey (memory-store-data backend))
               (incf count)))
           (memory-store-data backend))

          ;; Update namespace index
          (let ((ns-string (namespace-to-string namespace)))
            (remhash ns-string (memory-store-namespace-index backend)))

          count)
        ;; Clear all
        (let ((count (hash-table-count (memory-store-data backend))))
          (clrhash (memory-store-data backend))
          (clrhash (memory-store-namespace-index backend))
          count))))

(defmethod store-count ((backend memory-store-backend) &optional namespace)
  "Count items in memory backend"
  (bt:with-lock-held ((memory-store-lock backend))
    (if namespace
        ;; Count in specific namespace
        (let ((count 0))
          (maphash
           (lambda (fkey item)
             (declare (ignore fkey))
             (when (namespace-prefix-p namespace (store-item-namespace item))
               (incf count)))
           (memory-store-data backend))
          count)
        ;; Count all
        (hash-table-count (memory-store-data backend)))))

(defmethod store-stats ((backend memory-store-backend))
  "Get memory backend statistics"
  (bt:with-lock-held ((memory-store-lock backend))
    (let ((total-items (hash-table-count (memory-store-data backend)))
          (total-namespaces (hash-table-count (memory-store-namespace-index backend)))
          (oldest nil)
          (newest nil))

      ;; Find oldest and newest
      (maphash
       (lambda (fkey item)
         (declare (ignore fkey))
         (let ((ts (store-item-updated-at item)))
           (when (or (null oldest) (< ts oldest))
             (setf oldest ts))
           (when (or (null newest) (> ts newest))
             (setf newest ts))))
       (memory-store-data backend))

      `(:total-items ,total-items
        :total-namespaces ,total-namespaces
        :oldest-timestamp ,oldest
        :newest-timestamp ,newest
        :max-size ,(memory-store-max-size backend)
        :eviction-policy ,(memory-store-eviction-policy backend)))))

;;; ============================================================
;;; Eviction
;;; ============================================================

(defun evict-store-item (backend)
  "Evict an item based on eviction policy

Parameters:
  BACKEND - memory-store-backend instance"
  (let ((policy (memory-store-eviction-policy backend))
        (data (memory-store-data backend)))
    (case policy
      (:fifo
       ;; Delete oldest (by created-at)
       (let ((oldest-key nil)
             (oldest-ts nil))
         (maphash
          (lambda (fkey item)
            (let ((ts (store-item-created-at item)))
              (when (or (null oldest-ts) (< ts oldest-ts))
                (setf oldest-ts ts)
                (setf oldest-key fkey))))
          data)
         (when oldest-key
           (let ((item (gethash oldest-key data)))
             (remhash oldest-key data)
             ;; Update namespace index
             (let ((ns-string (namespace-to-string (store-item-namespace item))))
               (setf (gethash ns-string (memory-store-namespace-index backend))
                     (remove (store-item-key item)
                             (gethash ns-string (memory-store-namespace-index backend))
                             :test #'string=)))))))

      (:lru
       ;; Delete least recently used (by updated-at)
       (let ((lru-key nil)
             (lru-ts nil))
         (maphash
          (lambda (fkey item)
            (let ((ts (store-item-updated-at item)))
              (when (or (null lru-ts) (< ts lru-ts))
                (setf lru-ts ts)
                (setf lru-key fkey))))
          data)
         (when lru-key
           (let ((item (gethash lru-key data)))
             (remhash lru-key data)
             (let ((ns-string (namespace-to-string (store-item-namespace item))))
               (setf (gethash ns-string (memory-store-namespace-index backend))
                     (remove (store-item-key item)
                             (gethash ns-string (memory-store-namespace-index backend))
                             :test #'string=)))))))

      (:lifo
       ;; Delete newest (by created-at)
       (let ((newest-key nil)
             (newest-ts nil))
         (maphash
          (lambda (fkey item)
            (let ((ts (store-item-created-at item)))
              (when (or (null newest-ts) (> ts newest-ts))
                (setf newest-ts ts)
                (setf newest-key fkey))))
          data)
         (when newest-key
           (let ((item (gethash newest-key data)))
             (remhash newest-key data)
             (let ((ns-string (namespace-to-string (store-item-namespace item))))
               (setf (gethash ns-string (memory-store-namespace-index backend))
                     (remove (store-item-key item)
                             (gethash ns-string (memory-store-namespace-index backend))
                             :test #'string=))))))))))

;;; ============================================================
;;; Batch Operations
;;; ============================================================

(defmethod store-put-batch ((backend memory-store-backend) items)
  "Store multiple items at once

Parameters:
  BACKEND - memory-store-backend instance
  ITEMS   - List of plists with :namespace :key :value [:metadata :embedding]

Returns:
  Number of items stored"
  (bt:with-lock-held ((memory-store-lock backend))
    (let ((count 0))
      (dolist (item items)
        (let ((namespace (getf item :namespace))
              (key (getf item :key))
              (value (getf item :value))
              (metadata (getf item :metadata))
              (embedding (getf item :embedding)))
          (store-put backend namespace key value
                     :metadata metadata
                     :embedding embedding)
          (incf count)))
      count)))

(defmethod store-get-batch ((backend memory-store-backend) keys)
  "Retrieve multiple items at once

Parameters:
  BACKEND - memory-store-backend instance
  KEYS    - List of plists with :namespace :key

Returns:
  List of store-items (or NIL for missing)"
  (bt:with-lock-held ((memory-store-lock backend))
    (mapcar
     (lambda (k)
       (let ((namespace (getf k :namespace))
             (key (getf k :key)))
         (gethash (full-key namespace key) (memory-store-data backend))))
     keys)))

(defmethod store-delete-batch ((backend memory-store-backend) keys)
  "Delete multiple items at once

Parameters:
  BACKEND - memory-store-backend instance
  KEYS    - List of plists with :namespace :key

Returns:
  Number of items deleted"
  (bt:with-lock-held ((memory-store-lock backend))
    (let ((count 0))
      (dolist (k keys)
        (let* ((namespace (getf k :namespace))
               (key (getf k :key))
               (fkey (full-key namespace key)))
          (when (remhash fkey (memory-store-data backend))
            (incf count)
            ;; Update namespace index
            (let ((ns-string (namespace-to-string namespace)))
              (setf (gethash ns-string (memory-store-namespace-index backend))
                    (remove key
                            (gethash ns-string (memory-store-namespace-index backend))
                            :test #'string=))))))
      count)))
