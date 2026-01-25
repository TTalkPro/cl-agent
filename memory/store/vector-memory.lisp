;;;; store/vector-memory.lisp
;;;; CL-Agent Memory - Vector Memory Store
;;;;
;;;; Overview:
;;;;   In-memory vector store for similarity search.
;;;;   Uses cosine similarity for matching.
;;;;
;;;; Features:
;;;;   - Fast in-memory vector search
;;;;   - Thread-safe operations
;;;;   - Optional metadata storage
;;;;   - Configurable similarity threshold
;;;;
;;;; Usage:
;;;;   (let ((vm (make-vector-memory :dimensions 384)))
;;;;     (vector-memory-add vm "doc1" embedding :metadata '(:title "Hello"))
;;;;     (vector-memory-search vm query-embedding :limit 10))

(in-package #:cl-agent.memory)

;;; ============================================================
;;; Vector Entry Class
;;; ============================================================

(defclass vector-entry ()
  ((id
    :initarg :id
    :reader vector-entry-id
    :type string
    :documentation "Unique identifier")

   (vector
    :initarg :vector
    :accessor vector-entry-vector
    :type list
    :documentation "The vector (list of floats)")

   (metadata
    :initarg :metadata
    :accessor vector-entry-metadata
    :initform nil
    :documentation "Optional metadata plist")

   (created-at
    :initarg :created-at
    :reader vector-entry-created-at
    :initform (get-universal-time)
    :type integer
    :documentation "Creation timestamp")

   (updated-at
    :initarg :updated-at
    :accessor vector-entry-updated-at
    :initform (get-universal-time)
    :type integer
    :documentation "Last update timestamp")

   (access-count
    :initarg :access-count
    :accessor vector-entry-access-count
    :initform 0
    :type integer
    :documentation "Number of times accessed (for LRU)"))

  (:documentation "A single vector entry in the vector memory store."))

(defun make-vector-entry (id vector &key metadata)
  "Create a vector entry."
  (let ((now (get-universal-time)))
    (make-instance 'vector-entry
                   :id id
                   :vector vector
                   :metadata metadata
                   :created-at now
                   :updated-at now
                   :access-count 0)))

;;; ============================================================
;;; Vector Memory Store Class
;;; ============================================================

(defclass vector-memory ()
  ((entries
    :initform (make-hash-table :test 'equal)
    :reader vector-memory-entries
    :documentation "Hash table of ID -> vector-entry")

   (dimensions
    :initarg :dimensions
    :reader vector-memory-dimensions
    :initform nil
    :type (or null integer)
    :documentation "Expected vector dimensions (nil = auto-detect)")

   (max-size
    :initarg :max-size
    :reader vector-memory-max-size
    :initform nil
    :type (or null integer)
    :documentation "Maximum number of entries (nil = unlimited)")

   (similarity-fn
    :initarg :similarity-fn
    :reader vector-memory-similarity-fn
    :initform #'cosine-similarity
    :type function
    :documentation "Similarity function (vec1 vec2) -> score")

   (lock
    :initform (bt:make-lock "vector-memory")
    :reader vector-memory-lock
    :documentation "Thread lock"))

  (:documentation "In-memory vector store for similarity search.

Features:
  - Fast similarity search using configurable similarity function
  - Thread-safe operations
  - Optional size limits with LRU eviction
  - Metadata support"))

(defun make-vector-memory (&key dimensions max-size (similarity-fn #'cosine-similarity))
  "Create a vector memory store.

Parameters:
  DIMENSIONS    - Expected vector dimensions (optional)
  MAX-SIZE      - Maximum number of entries (optional)
  SIMILARITY-FN - Similarity function (default: cosine-similarity)

Returns:
  vector-memory instance"
  (make-instance 'vector-memory
                 :dimensions dimensions
                 :max-size max-size
                 :similarity-fn similarity-fn))

(defmethod print-object ((vm vector-memory) stream)
  (print-unreadable-object (vm stream :type t)
    (format stream "~A entries, dims=~A"
            (hash-table-count (vector-memory-entries vm))
            (or (vector-memory-dimensions vm) "auto"))))

;;; ============================================================
;;; Vector Memory Protocol Implementation
;;; ============================================================

(defmethod vector-memory-add ((vm vector-memory) id vector &key metadata)
  "Add a vector to the memory."
  (bt:with-lock-held ((vector-memory-lock vm))
    ;; Validate dimensions
    (when (and (vector-memory-dimensions vm)
               (/= (length vector) (vector-memory-dimensions vm)))
      (error "Vector dimension mismatch: expected ~A, got ~A"
             (vector-memory-dimensions vm) (length vector)))

    ;; Check size limit and evict if necessary
    (when (and (vector-memory-max-size vm)
               (>= (hash-table-count (vector-memory-entries vm))
                   (vector-memory-max-size vm)))
      (vector-memory-evict-lru vm))

    ;; Add or update entry
    (let ((entry (make-vector-entry id vector :metadata metadata)))
      (setf (gethash id (vector-memory-entries vm)) entry)
      id)))

(defmethod vector-memory-search ((vm vector-memory) query-vector
                                  &key (limit 10) (threshold 0.0))
  "Search for similar vectors."
  (bt:with-lock-held ((vector-memory-lock vm))
    (let ((results '())
          (sim-fn (vector-memory-similarity-fn vm)))

      ;; Calculate similarities
      (maphash (lambda (id entry)
                 (let ((score (funcall sim-fn query-vector
                                       (vector-entry-vector entry))))
                   (when (>= score threshold)
                     (push (list :id id
                                 :score score
                                 :metadata (vector-entry-metadata entry))
                           results))))
               (vector-memory-entries vm))

      ;; Sort by score (descending)
      (setf results (sort results #'> :key (lambda (r) (getf r :score))))

      ;; Apply limit
      (when (and limit (> (length results) limit))
        (setf results (subseq results 0 limit)))

      ;; Update access counts
      (dolist (result results)
        (let ((entry (gethash (getf result :id) (vector-memory-entries vm))))
          (when entry
            (incf (vector-entry-access-count entry)))))

      results)))

(defmethod vector-memory-remove ((vm vector-memory) id)
  "Remove a vector by ID."
  (bt:with-lock-held ((vector-memory-lock vm))
    (let ((existed (nth-value 1 (gethash id (vector-memory-entries vm)))))
      (remhash id (vector-memory-entries vm))
      existed)))

(defmethod vector-memory-update ((vm vector-memory) id vector &key metadata)
  "Update a vector."
  (bt:with-lock-held ((vector-memory-lock vm))
    (let ((entry (gethash id (vector-memory-entries vm))))
      (when entry
        (when (and (vector-memory-dimensions vm)
                   (/= (length vector) (vector-memory-dimensions vm)))
          (error "Vector dimension mismatch: expected ~A, got ~A"
                 (vector-memory-dimensions vm) (length vector)))
        (setf (vector-entry-vector entry) vector)
        (setf (vector-entry-updated-at entry) (get-universal-time))
        (when metadata
          (setf (vector-entry-metadata entry) metadata))
        t))))

;;; ============================================================
;;; Additional Methods
;;; ============================================================

(defgeneric vector-memory-get (vm id)
  (:documentation "Get a vector entry by ID."))

(defmethod vector-memory-get ((vm vector-memory) id)
  "Get a vector entry by ID."
  (bt:with-lock-held ((vector-memory-lock vm))
    (let ((entry (gethash id (vector-memory-entries vm))))
      (when entry
        (list :id id
              :vector (vector-entry-vector entry)
              :metadata (vector-entry-metadata entry)
              :created-at (vector-entry-created-at entry)
              :updated-at (vector-entry-updated-at entry))))))

(defgeneric vector-memory-count (vm)
  (:documentation "Get the number of entries."))

(defmethod vector-memory-count ((vm vector-memory))
  "Get the number of entries."
  (bt:with-lock-held ((vector-memory-lock vm))
    (hash-table-count (vector-memory-entries vm))))

(defgeneric vector-memory-clear (vm)
  (:documentation "Clear all entries."))

(defmethod vector-memory-clear ((vm vector-memory))
  "Clear all entries."
  (bt:with-lock-held ((vector-memory-lock vm))
    (let ((count (hash-table-count (vector-memory-entries vm))))
      (clrhash (vector-memory-entries vm))
      count)))

(defgeneric vector-memory-ids (vm)
  (:documentation "Get all entry IDs."))

(defmethod vector-memory-ids ((vm vector-memory))
  "Get all entry IDs."
  (bt:with-lock-held ((vector-memory-lock vm))
    (let ((ids '()))
      (maphash (lambda (id entry)
                 (declare (ignore entry))
                 (push id ids))
               (vector-memory-entries vm))
      (nreverse ids))))

;;; ============================================================
;;; LRU Eviction
;;; ============================================================

(defun vector-memory-evict-lru (vm)
  "Evict the least recently used entry.

Parameters:
  VM - vector-memory instance"
  (let ((lru-id nil)
        (lru-time nil)
        (lru-access nil))

    ;; Find LRU entry (least access count, then oldest updated-at)
    (maphash (lambda (id entry)
               (let ((access (vector-entry-access-count entry))
                     (time (vector-entry-updated-at entry)))
                 (when (or (null lru-id)
                           (< access lru-access)
                           (and (= access lru-access) (< time lru-time)))
                   (setf lru-id id)
                   (setf lru-time time)
                   (setf lru-access access))))
             (vector-memory-entries vm))

    ;; Remove LRU entry
    (when lru-id
      (remhash lru-id (vector-memory-entries vm)))))

;;; ============================================================
;;; Batch Operations
;;; ============================================================

(defgeneric vector-memory-add-batch (vm entries)
  (:documentation "Add multiple vectors at once."))

(defmethod vector-memory-add-batch ((vm vector-memory) entries)
  "Add multiple vectors at once.

Parameters:
  VM      - vector-memory instance
  ENTRIES - List of plists with :id :vector [:metadata]

Returns:
  Number of entries added"
  (let ((count 0))
    (dolist (entry entries)
      (let ((id (getf entry :id))
            (vector (getf entry :vector))
            (metadata (getf entry :metadata)))
        (vector-memory-add vm id vector :metadata metadata)
        (incf count)))
    count))

(defgeneric vector-memory-search-batch (vm query-vectors &key limit threshold)
  (:documentation "Search with multiple query vectors."))

(defmethod vector-memory-search-batch ((vm vector-memory) query-vectors
                                        &key (limit 10) (threshold 0.0))
  "Search with multiple query vectors.

Parameters:
  VM            - vector-memory instance
  QUERY-VECTORS - List of query vectors
  LIMIT         - Maximum results per query
  THRESHOLD     - Minimum similarity

Returns:
  List of result lists (one per query)"
  (mapcar (lambda (qv)
            (vector-memory-search vm qv :limit limit :threshold threshold))
          query-vectors))

;;; ============================================================
;;; Statistics
;;; ============================================================

(defgeneric vector-memory-stats (vm)
  (:documentation "Get vector memory statistics."))

(defmethod vector-memory-stats ((vm vector-memory))
  "Get vector memory statistics."
  (bt:with-lock-held ((vector-memory-lock vm))
    (let ((total-entries (hash-table-count (vector-memory-entries vm)))
          (oldest nil)
          (newest nil)
          (total-accesses 0))

      (maphash (lambda (id entry)
                 (declare (ignore id))
                 (let ((ts (vector-entry-updated-at entry)))
                   (when (or (null oldest) (< ts oldest))
                     (setf oldest ts))
                   (when (or (null newest) (> ts newest))
                     (setf newest ts))
                   (incf total-accesses (vector-entry-access-count entry))))
               (vector-memory-entries vm))

      `(:total-entries ,total-entries
        :dimensions ,(vector-memory-dimensions vm)
        :max-size ,(vector-memory-max-size vm)
        :oldest-timestamp ,oldest
        :newest-timestamp ,newest
        :total-accesses ,total-accesses
        :average-accesses ,(if (> total-entries 0)
                              (/ total-accesses total-entries)
                              0)))))

