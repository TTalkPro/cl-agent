;;;; long-term/semantic.lisp
;;;; CL-Agent Memory - Semantic Memory
;;;;
;;;; Overview:
;;;;   Semantic memory stores facts, concepts, and knowledge.
;;;;   It represents general world knowledge independent of personal experience.
;;;;
;;;; Features:
;;;;   - Fact storage with embedding support
;;;;   - Concept relationships
;;;;   - Knowledge retrieval by similarity
;;;;
;;;; Reference:
;;;;   - Cognitive science: Semantic memory (Tulving, 1972)
;;;;   - MemGPT semantic memory patterns

(in-package #:cl-agent.memory)

;;; ============================================================
;;; Semantic Entry Class
;;; ============================================================

(defclass semantic-entry ()
  ((id
    :initarg :id
    :reader semantic-entry-id
    :type string
    :documentation "Unique entry ID")

   (content
    :initarg :content
    :accessor semantic-entry-content
    :type string
    :documentation "The fact or knowledge content")

   (category
    :initarg :category
    :accessor semantic-entry-category
    :initform nil
    :type (or null string)
    :documentation "Category/topic classification")

   (embedding
    :initarg :embedding
    :accessor semantic-entry-embedding
    :initform nil
    :type (or null list)
    :documentation "Vector embedding for similarity search")

   (confidence
    :initarg :confidence
    :accessor semantic-entry-confidence
    :initform 1.0
    :type float
    :documentation "Confidence score (0.0-1.0)")

   (source
    :initarg :source
    :accessor semantic-entry-source
    :initform nil
    :type (or null string)
    :documentation "Source of the knowledge")

   (related-concepts
    :initarg :related-concepts
    :accessor semantic-entry-related-concepts
    :initform nil
    :type list
    :documentation "List of related concept IDs")

   (created-at
    :initarg :created-at
    :reader semantic-entry-created-at
    :initform (get-universal-time)
    :type integer)

   (accessed-at
    :initarg :accessed-at
    :accessor semantic-entry-accessed-at
    :initform (get-universal-time)
    :type integer)

   (access-count
    :initarg :access-count
    :accessor semantic-entry-access-count
    :initform 0
    :type integer)

   (metadata
    :initarg :metadata
    :accessor semantic-entry-metadata
    :initform nil
    :type list))

  (:documentation "A semantic memory entry representing a fact or concept."))

(defun make-semantic-entry (content &key id category embedding confidence source
                                      related-concepts metadata)
  "Create a semantic entry."
  (make-instance 'semantic-entry
                 :id (or id (format nil "sem-~A" (cl-agent.core:generate-uuid)))
                 :content content
                 :category category
                 :embedding embedding
                 :confidence (or confidence 1.0)
                 :source source
                 :related-concepts related-concepts
                 :metadata metadata))

(defmethod print-object ((entry semantic-entry) stream)
  (print-unreadable-object (entry stream :type t)
    (format stream "~A: ~S"
            (semantic-entry-id entry)
            (let ((content (semantic-entry-content entry)))
              (if (> (length content) 40)
                  (concatenate 'string (subseq content 0 40) "...")
                  content)))))

;;; ============================================================
;;; Semantic Memory Class
;;; ============================================================

(defclass semantic-memory ()
  ((store
    :initarg :store
    :reader semantic-memory-store
    :documentation "Backend store for persistence")

   (vector-memory
    :initarg :vector-memory
    :reader semantic-memory-vector-memory
    :initform nil
    :documentation "Optional vector memory for similarity search")

   (embedder
    :initarg :embedder
    :reader semantic-memory-embedder
    :initform nil
    :documentation "Optional embedding provider")

   (namespace
    :initarg :namespace
    :reader semantic-memory-namespace
    :initform '("semantic")
    :type list
    :documentation "Store namespace for semantic entries")

   (categories
    :initform (make-hash-table :test 'equal)
    :reader semantic-memory-categories
    :documentation "Category -> entry IDs index")

   (lock
    :initform (bt:make-lock "semantic-memory")
    :reader semantic-memory-lock))

  (:documentation "Semantic memory for storing facts and knowledge.

This memory type is used for:
  - General world knowledge
  - Facts and definitions
  - Concept relationships
  - Domain knowledge"))

(defun make-semantic-memory (&key store vector-memory embedder (namespace '("semantic")))
  "Create a semantic memory instance.

Parameters:
  STORE         - Backend store (required)
  VECTOR-MEMORY - Optional vector memory for similarity search
  EMBEDDER      - Optional embedding provider
  NAMESPACE     - Store namespace (default: '(\"semantic\"))

Returns:
  semantic-memory instance"
  (unless store
    (error "store is required for semantic-memory"))
  (make-instance 'semantic-memory
                 :store store
                 :vector-memory vector-memory
                 :embedder embedder
                 :namespace namespace))

;;; ============================================================
;;; Memory Type Protocol Implementation
;;; ============================================================

(defmethod memory-type ((memory semantic-memory))
  :semantic)

(defmethod memory-store-entry ((memory semantic-memory) entry &key metadata)
  "Store a semantic entry."
  (bt:with-lock-held ((semantic-memory-lock memory))
    (let* ((semantic-entry (if (typep entry 'semantic-entry)
                               entry
                               (make-semantic-entry entry :metadata metadata)))
           (id (semantic-entry-id semantic-entry))
           (content (semantic-entry-content semantic-entry)))

      ;; Generate embedding if embedder available and no embedding provided
      (when (and (semantic-memory-embedder memory)
                 (null (semantic-entry-embedding semantic-entry)))
        (setf (semantic-entry-embedding semantic-entry)
              (embed-text (semantic-memory-embedder memory) content)))

      ;; Store in backend
      (store-put (semantic-memory-store memory)
                 (semantic-memory-namespace memory)
                 id
                 (semantic-entry-to-plist semantic-entry)
                 :embedding (semantic-entry-embedding semantic-entry)
                 :metadata metadata)

      ;; Add to vector memory if available
      (when (and (semantic-memory-vector-memory memory)
                 (semantic-entry-embedding semantic-entry))
        (vector-memory-add (semantic-memory-vector-memory memory)
                          id
                          (semantic-entry-embedding semantic-entry)
                          :metadata `(:content ,content
                                      :category ,(semantic-entry-category semantic-entry))))

      ;; Update category index
      (when (semantic-entry-category semantic-entry)
        (pushnew id (gethash (semantic-entry-category semantic-entry)
                             (semantic-memory-categories memory))
                 :test 'equal))

      id)))

(defmethod memory-retrieve ((memory semantic-memory) query &key (limit 10) (threshold 0.0))
  "Retrieve semantic entries by query."
  (bt:with-lock-held ((semantic-memory-lock memory))
    (cond
      ;; Use vector search if available
      ((and (semantic-memory-vector-memory memory)
            (semantic-memory-embedder memory))
       (let* ((query-embedding (embed-text (semantic-memory-embedder memory) query))
              (results (vector-memory-search (semantic-memory-vector-memory memory)
                                             query-embedding
                                             :limit limit
                                             :threshold threshold)))
         (mapcar (lambda (result)
                   (let* ((id (getf result :id))
                          (item (store-get (semantic-memory-store memory)
                                          (semantic-memory-namespace memory)
                                          id)))
                     (when item
                       (let ((entry (plist-to-semantic-entry (store-item-value item))))
                         ;; Update access stats
                         (setf (semantic-entry-accessed-at entry) (get-universal-time))
                         (incf (semantic-entry-access-count entry))
                         (list :entry entry
                               :score (getf result :score))))))
                 results)))

      ;; Fallback to keyword search
      (t
       (let ((items (store-search (semantic-memory-store memory)
                                  (semantic-memory-namespace memory)
                                  :query query
                                  :limit limit)))
         (mapcar (lambda (item)
                   (list :entry (plist-to-semantic-entry (store-item-value item))
                         :score 1.0))
                 items))))))

(defmethod memory-consolidate ((memory semantic-memory) &key strategy)
  "Consolidate semantic memory."
  (declare (ignore strategy))
  (bt:with-lock-held ((semantic-memory-lock memory))
    (let ((total 0)
          (consolidated 0))
      ;; For now, just count entries
      ;; Future: merge similar entries, prune low-confidence entries
      (let ((items (store-search (semantic-memory-store memory)
                                 (semantic-memory-namespace memory)
                                 :limit 10000)))
        (setf total (length items)))

      `(:total-entries ,total
        :consolidated ,consolidated
        :strategy ,(or strategy :none)))))

(defmethod memory-decay ((memory semantic-memory) decay-fn)
  "Apply decay to semantic memory entries."
  (bt:with-lock-held ((semantic-memory-lock memory))
    (let ((affected 0))
      (let ((items (store-search (semantic-memory-store memory)
                                 (semantic-memory-namespace memory)
                                 :limit 10000)))
        (dolist (item items)
          (let* ((entry (plist-to-semantic-entry (store-item-value item)))
                 (age (- (get-universal-time) (semantic-entry-created-at entry)))
                 (old-confidence (semantic-entry-confidence entry))
                 (new-confidence (funcall decay-fn entry age)))
            (when (/= old-confidence new-confidence)
              (setf (semantic-entry-confidence entry) new-confidence)
              (store-put (semantic-memory-store memory)
                        (semantic-memory-namespace memory)
                        (semantic-entry-id entry)
                        (semantic-entry-to-plist entry))
              (incf affected)))))
      affected)))

;;; ============================================================
;;; Semantic Memory Specific Operations
;;; ============================================================

(defgeneric semantic-add-fact (memory content &key category source confidence embedding)
  (:documentation "Add a fact to semantic memory."))

(defmethod semantic-add-fact ((memory semantic-memory) content
                              &key category source confidence embedding)
  "Add a fact to semantic memory."
  (let ((entry (make-semantic-entry content
                                    :category category
                                    :source source
                                    :confidence confidence
                                    :embedding embedding)))
    (memory-store-entry memory entry)))

(defgeneric semantic-find-by-category (memory category &key limit)
  (:documentation "Find entries by category."))

(defmethod semantic-find-by-category ((memory semantic-memory) category &key (limit 100))
  "Find entries by category."
  (bt:with-lock-held ((semantic-memory-lock memory))
    (let ((ids (gethash category (semantic-memory-categories memory)))
          (results '()))
      (dolist (id (if limit (subseq ids 0 (min limit (length ids))) ids))
        (let ((item (store-get (semantic-memory-store memory)
                              (semantic-memory-namespace memory)
                              id)))
          (when item
            (push (plist-to-semantic-entry (store-item-value item)) results))))
      (nreverse results))))

(defgeneric semantic-link-concepts (memory id1 id2)
  (:documentation "Link two concepts as related."))

(defmethod semantic-link-concepts ((memory semantic-memory) id1 id2)
  "Link two concepts as related."
  (bt:with-lock-held ((semantic-memory-lock memory))
    (let ((item1 (store-get (semantic-memory-store memory)
                            (semantic-memory-namespace memory) id1))
          (item2 (store-get (semantic-memory-store memory)
                            (semantic-memory-namespace memory) id2)))
      (when (and item1 item2)
        (let ((entry1 (plist-to-semantic-entry (store-item-value item1)))
              (entry2 (plist-to-semantic-entry (store-item-value item2))))
          ;; Add bidirectional links
          (pushnew id2 (semantic-entry-related-concepts entry1) :test 'equal)
          (pushnew id1 (semantic-entry-related-concepts entry2) :test 'equal)
          ;; Save both
          (store-put (semantic-memory-store memory)
                     (semantic-memory-namespace memory)
                     id1 (semantic-entry-to-plist entry1))
          (store-put (semantic-memory-store memory)
                     (semantic-memory-namespace memory)
                     id2 (semantic-entry-to-plist entry2))
          t)))))

;;; ============================================================
;;; Serialization Helpers
;;; ============================================================

(defun semantic-entry-to-plist (entry)
  "Convert semantic entry to plist."
  `(:id ,(semantic-entry-id entry)
    :content ,(semantic-entry-content entry)
    :category ,(semantic-entry-category entry)
    :embedding ,(semantic-entry-embedding entry)
    :confidence ,(semantic-entry-confidence entry)
    :source ,(semantic-entry-source entry)
    :related-concepts ,(semantic-entry-related-concepts entry)
    :created-at ,(semantic-entry-created-at entry)
    :accessed-at ,(semantic-entry-accessed-at entry)
    :access-count ,(semantic-entry-access-count entry)
    :metadata ,(semantic-entry-metadata entry)))

(defun plist-to-semantic-entry (plist)
  "Convert plist to semantic entry."
  (make-instance 'semantic-entry
                 :id (getf plist :id)
                 :content (getf plist :content)
                 :category (getf plist :category)
                 :embedding (getf plist :embedding)
                 :confidence (or (getf plist :confidence) 1.0)
                 :source (getf plist :source)
                 :related-concepts (getf plist :related-concepts)
                 :created-at (or (getf plist :created-at) (get-universal-time))
                 :accessed-at (or (getf plist :accessed-at) (get-universal-time))
                 :access-count (or (getf plist :access-count) 0)
                 :metadata (getf plist :metadata)))

