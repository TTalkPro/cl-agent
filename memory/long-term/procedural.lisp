;;;; long-term/procedural.lisp
;;;; CL-Agent Memory - Procedural Memory
;;;;
;;;; Overview:
;;;;   Procedural memory stores skills, procedures, and how-to knowledge.
;;;;   It represents learned routines and patterns of behavior.
;;;;
;;;; Features:
;;;;   - Procedure/skill storage
;;;;   - Step-by-step instructions
;;;;   - Proficiency tracking
;;;;   - Usage statistics
;;;;
;;;; Reference:
;;;;   - Cognitive science: Procedural memory (Tulving, 1972)
;;;;   - MemGPT procedural memory patterns

(in-package #:cl-agent.memory)

;;; ============================================================
;;; Procedure Entry Class
;;; ============================================================

(defclass procedure-entry ()
  ((id
    :initarg :id
    :reader procedure-entry-id
    :type string
    :documentation "Unique procedure ID")

   (name
    :initarg :name
    :accessor procedure-entry-name
    :type string
    :documentation "Name of the procedure/skill")

   (description
    :initarg :description
    :accessor procedure-entry-description
    :initform nil
    :type (or null string)
    :documentation "Description of what the procedure does")

   (steps
    :initarg :steps
    :accessor procedure-entry-steps
    :initform nil
    :type list
    :documentation "List of step descriptions")

   (triggers
    :initarg :triggers
    :accessor procedure-entry-triggers
    :initform nil
    :type list
    :documentation "Conditions that trigger this procedure")

   (parameters
    :initarg :parameters
    :accessor procedure-entry-parameters
    :initform nil
    :type list
    :documentation "Required parameters (list of plists)")

   (embedding
    :initarg :embedding
    :accessor procedure-entry-embedding
    :initform nil
    :type (or null list)
    :documentation "Vector embedding for similarity search")

   (proficiency
    :initarg :proficiency
    :accessor procedure-entry-proficiency
    :initform 0.5
    :type float
    :documentation "Proficiency level (0.0-1.0)")

   (success-rate
    :initarg :success-rate
    :accessor procedure-entry-success-rate
    :initform nil
    :type (or null float)
    :documentation "Historical success rate")

   (execution-count
    :initarg :execution-count
    :accessor procedure-entry-execution-count
    :initform 0
    :type integer
    :documentation "Number of times executed")

   (success-count
    :initarg :success-count
    :accessor procedure-entry-success-count
    :initform 0
    :type integer
    :documentation "Number of successful executions")

   (last-used
    :initarg :last-used
    :accessor procedure-entry-last-used
    :initform nil
    :type (or null integer)
    :documentation "Timestamp of last use")

   (created-at
    :initarg :created-at
    :reader procedure-entry-created-at
    :initform (get-universal-time)
    :type integer)

   (related-procedures
    :initarg :related-procedures
    :accessor procedure-entry-related-procedures
    :initform nil
    :type list
    :documentation "List of related procedure IDs")

   (metadata
    :initarg :metadata
    :accessor procedure-entry-metadata
    :initform nil
    :type list))

  (:documentation "A procedural memory entry representing a skill or procedure."))

(defun make-procedure-entry (name &key id description steps triggers parameters
                                    embedding proficiency related-procedures metadata)
  "Create a procedure entry."
  (make-instance 'procedure-entry
                 :id (or id (format nil "proc-~A" (cl-agent.core:generate-uuid)))
                 :name name
                 :description description
                 :steps steps
                 :triggers triggers
                 :parameters parameters
                 :embedding embedding
                 :proficiency (or proficiency 0.5)
                 :related-procedures related-procedures
                 :metadata metadata))

(defmethod print-object ((entry procedure-entry) stream)
  (print-unreadable-object (entry stream :type t)
    (format stream "~A (~A steps, prof=~,2F)"
            (procedure-entry-name entry)
            (length (procedure-entry-steps entry))
            (procedure-entry-proficiency entry))))

;;; ============================================================
;;; Procedural Memory Class
;;; ============================================================

(defclass procedural-memory ()
  ((store
    :initarg :store
    :reader procedural-memory-store
    :documentation "Backend store for persistence")

   (vector-memory
    :initarg :vector-memory
    :reader procedural-memory-vector-memory
    :initform nil
    :documentation "Optional vector memory for similarity search")

   (embedder
    :initarg :embedder
    :reader procedural-memory-embedder
    :initform nil
    :documentation "Optional embedding provider")

   (namespace
    :initarg :namespace
    :reader procedural-memory-namespace
    :initform '("procedural")
    :type list
    :documentation "Store namespace for procedural entries")

   (name-index
    :initform (make-hash-table :test 'equal)
    :reader procedural-memory-name-index
    :documentation "Name -> entry ID index")

   (trigger-index
    :initform (make-hash-table :test 'equal)
    :reader procedural-memory-trigger-index
    :documentation "Trigger keyword -> entry IDs")

   (lock
    :initform (bt:make-lock "procedural-memory")
    :reader procedural-memory-lock))

  (:documentation "Procedural memory for storing skills and procedures.

This memory type is used for:
  - Learned procedures and workflows
  - Tool usage patterns
  - Problem-solving strategies
  - Behavioral routines"))

(defun make-procedural-memory (&key store vector-memory embedder (namespace '("procedural")))
  "Create a procedural memory instance.

Parameters:
  STORE         - Backend store (required)
  VECTOR-MEMORY - Optional vector memory for similarity search
  EMBEDDER      - Optional embedding provider
  NAMESPACE     - Store namespace (default: '(\"procedural\"))

Returns:
  procedural-memory instance"
  (unless store
    (error "store is required for procedural-memory"))
  (make-instance 'procedural-memory
                 :store store
                 :vector-memory vector-memory
                 :embedder embedder
                 :namespace namespace))

;;; ============================================================
;;; Memory Type Protocol Implementation
;;; ============================================================

(defmethod memory-type ((memory procedural-memory))
  :procedural)

(defmethod memory-store-entry ((memory procedural-memory) entry &key metadata)
  "Store a procedural entry."
  (bt:with-lock-held ((procedural-memory-lock memory))
    (let* ((procedure (if (typep entry 'procedure-entry)
                          entry
                          (make-procedure-entry entry :metadata metadata)))
           (id (procedure-entry-id procedure))
           (name (procedure-entry-name procedure))
           (description (or (procedure-entry-description procedure) name)))

      ;; Generate embedding if embedder available
      (when (and (procedural-memory-embedder memory)
                 (null (procedure-entry-embedding procedure)))
        (let ((text (format nil "~A ~A ~{~A~^ ~}"
                           name
                           (or description "")
                           (procedure-entry-steps procedure))))
          (setf (procedure-entry-embedding procedure)
                (embed-text (procedural-memory-embedder memory) text))))

      ;; Store in backend
      (store-put (procedural-memory-store memory)
                 (procedural-memory-namespace memory)
                 id
                 (procedure-entry-to-plist procedure)
                 :embedding (procedure-entry-embedding procedure)
                 :metadata metadata)

      ;; Add to vector memory if available
      (when (and (procedural-memory-vector-memory memory)
                 (procedure-entry-embedding procedure))
        (vector-memory-add (procedural-memory-vector-memory memory)
                          id
                          (procedure-entry-embedding procedure)
                          :metadata `(:name ,name)))

      ;; Update name index
      (setf (gethash (string-downcase name) (procedural-memory-name-index memory)) id)

      ;; Update trigger index
      (dolist (trigger (procedure-entry-triggers procedure))
        (pushnew id (gethash (string-downcase trigger)
                             (procedural-memory-trigger-index memory))
                 :test 'equal))

      id)))

(defmethod memory-retrieve ((memory procedural-memory) query &key (limit 10) (threshold 0.0))
  "Retrieve procedural entries."
  (bt:with-lock-held ((procedural-memory-lock memory))
    (cond
      ;; Search by trigger
      ((and (listp query) (getf query :trigger))
       (procedural-retrieve-by-trigger memory (getf query :trigger) :limit limit))

      ;; Vector similarity search
      ((and (procedural-memory-vector-memory memory)
            (procedural-memory-embedder memory)
            (stringp query))
       (let* ((query-embedding (embed-text (procedural-memory-embedder memory) query))
              (results (vector-memory-search (procedural-memory-vector-memory memory)
                                             query-embedding
                                             :limit limit
                                             :threshold threshold)))
         (mapcar (lambda (result)
                   (let* ((id (getf result :id))
                          (item (store-get (procedural-memory-store memory)
                                          (procedural-memory-namespace memory)
                                          id)))
                     (when item
                       (list :entry (plist-to-procedure-entry (store-item-value item))
                             :score (getf result :score)))))
                 results)))

      ;; Keyword search fallback
      (t
       (let ((items (store-search (procedural-memory-store memory)
                                  (procedural-memory-namespace memory)
                                  :query query
                                  :limit limit)))
         (mapcar (lambda (item)
                   (list :entry (plist-to-procedure-entry (store-item-value item))
                         :score 1.0))
                 items))))))

(defmethod memory-consolidate ((memory procedural-memory) &key strategy)
  "Consolidate procedural memory."
  (declare (ignore strategy))
  (bt:with-lock-held ((procedural-memory-lock memory))
    (let ((total 0)
          (consolidated 0))
      ;; Count entries
      (let ((items (store-search (procedural-memory-store memory)
                                 (procedural-memory-namespace memory)
                                 :limit 10000)))
        (setf total (length items)))

      `(:total-entries ,total
        :consolidated ,consolidated
        :strategy ,(or strategy :none)))))

(defmethod memory-decay ((memory procedural-memory) decay-fn)
  "Apply decay to procedural memory entries (affects proficiency)."
  (bt:with-lock-held ((procedural-memory-lock memory))
    (let ((affected 0))
      (let ((items (store-search (procedural-memory-store memory)
                                 (procedural-memory-namespace memory)
                                 :limit 10000)))
        (dolist (item items)
          (let* ((procedure (plist-to-procedure-entry (store-item-value item)))
                 (age (- (get-universal-time)
                        (or (procedure-entry-last-used procedure)
                            (procedure-entry-created-at procedure))))
                 (old-proficiency (procedure-entry-proficiency procedure))
                 (new-proficiency (funcall decay-fn procedure age)))
            (when (/= old-proficiency new-proficiency)
              (setf (procedure-entry-proficiency procedure) new-proficiency)
              (store-put (procedural-memory-store memory)
                        (procedural-memory-namespace memory)
                        (procedure-entry-id procedure)
                        (procedure-entry-to-plist procedure))
              (incf affected)))))
      affected)))

;;; ============================================================
;;; Procedural Memory Specific Operations
;;; ============================================================

(defgeneric procedural-add-skill (memory name steps &key description triggers parameters)
  (:documentation "Add a skill/procedure to procedural memory."))

(defmethod procedural-add-skill ((memory procedural-memory) name steps
                                 &key description triggers parameters)
  "Add a skill/procedure to procedural memory."
  (let ((procedure (make-procedure-entry name
                                         :description description
                                         :steps steps
                                         :triggers triggers
                                         :parameters parameters)))
    (memory-store-entry memory procedure)))

(defgeneric procedural-get-by-name (memory name)
  (:documentation "Get a procedure by exact name."))

(defmethod procedural-get-by-name ((memory procedural-memory) name)
  "Get a procedure by exact name."
  (bt:with-lock-held ((procedural-memory-lock memory))
    (let ((id (gethash (string-downcase name) (procedural-memory-name-index memory))))
      (when id
        (let ((item (store-get (procedural-memory-store memory)
                              (procedural-memory-namespace memory)
                              id)))
          (when item
            (plist-to-procedure-entry (store-item-value item))))))))

(defgeneric procedural-retrieve-by-trigger (memory trigger &key limit)
  (:documentation "Retrieve procedures by trigger."))

(defmethod procedural-retrieve-by-trigger ((memory procedural-memory) trigger
                                            &key (limit 10))
  "Retrieve procedures by trigger."
  (let ((ids (gethash (string-downcase trigger)
                      (procedural-memory-trigger-index memory)))
        (results '()))
    (dolist (id (if limit (subseq ids 0 (min limit (length ids))) ids))
      (let ((item (store-get (procedural-memory-store memory)
                            (procedural-memory-namespace memory)
                            id)))
        (when item
          (push (list :entry (plist-to-procedure-entry (store-item-value item))
                      :score 1.0)
                results))))
    (nreverse results)))

(defgeneric procedural-record-execution (memory id &key success)
  (:documentation "Record a procedure execution."))

(defmethod procedural-record-execution ((memory procedural-memory) id &key (success t))
  "Record a procedure execution."
  (bt:with-lock-held ((procedural-memory-lock memory))
    (let ((item (store-get (procedural-memory-store memory)
                          (procedural-memory-namespace memory)
                          id)))
      (when item
        (let ((procedure (plist-to-procedure-entry (store-item-value item))))
          ;; Update execution stats
          (incf (procedure-entry-execution-count procedure))
          (when success
            (incf (procedure-entry-success-count procedure)))
          (setf (procedure-entry-last-used procedure) (get-universal-time))

          ;; Calculate success rate
          (setf (procedure-entry-success-rate procedure)
                (if (> (procedure-entry-execution-count procedure) 0)
                    (/ (procedure-entry-success-count procedure)
                       (procedure-entry-execution-count procedure))
                    nil))

          ;; Update proficiency based on success rate
          (when (procedure-entry-success-rate procedure)
            (setf (procedure-entry-proficiency procedure)
                  (+ (* 0.9 (procedure-entry-proficiency procedure))
                     (* 0.1 (if success 1.0 0.0)))))

          ;; Save updated procedure
          (store-put (procedural-memory-store memory)
                    (procedural-memory-namespace memory)
                    id
                    (procedure-entry-to-plist procedure))

          procedure)))))

(defgeneric procedural-most-used (memory &key limit)
  (:documentation "Get most frequently used procedures."))

(defmethod procedural-most-used ((memory procedural-memory) &key (limit 10))
  "Get most frequently used procedures."
  (bt:with-lock-held ((procedural-memory-lock memory))
    (let ((items (store-search (procedural-memory-store memory)
                              (procedural-memory-namespace memory)
                              :limit 1000))
          (procedures '()))
      (dolist (item items)
        (push (plist-to-procedure-entry (store-item-value item)) procedures))

      ;; Sort by execution count
      (setf procedures (sort procedures #'>
                            :key #'procedure-entry-execution-count))

      (when (and limit (> (length procedures) limit))
        (setf procedures (subseq procedures 0 limit)))

      procedures)))

;;; ============================================================
;;; Serialization Helpers
;;; ============================================================

(defun procedure-entry-to-plist (entry)
  "Convert procedure entry to plist."
  `(:id ,(procedure-entry-id entry)
    :name ,(procedure-entry-name entry)
    :description ,(procedure-entry-description entry)
    :steps ,(procedure-entry-steps entry)
    :triggers ,(procedure-entry-triggers entry)
    :parameters ,(procedure-entry-parameters entry)
    :embedding ,(procedure-entry-embedding entry)
    :proficiency ,(procedure-entry-proficiency entry)
    :success-rate ,(procedure-entry-success-rate entry)
    :execution-count ,(procedure-entry-execution-count entry)
    :success-count ,(procedure-entry-success-count entry)
    :last-used ,(procedure-entry-last-used entry)
    :created-at ,(procedure-entry-created-at entry)
    :related-procedures ,(procedure-entry-related-procedures entry)
    :metadata ,(procedure-entry-metadata entry)))

(defun plist-to-procedure-entry (plist)
  "Convert plist to procedure entry."
  (make-instance 'procedure-entry
                 :id (getf plist :id)
                 :name (getf plist :name)
                 :description (getf plist :description)
                 :steps (getf plist :steps)
                 :triggers (getf plist :triggers)
                 :parameters (getf plist :parameters)
                 :embedding (getf plist :embedding)
                 :proficiency (or (getf plist :proficiency) 0.5)
                 :success-rate (getf plist :success-rate)
                 :execution-count (or (getf plist :execution-count) 0)
                 :success-count (or (getf plist :success-count) 0)
                 :last-used (getf plist :last-used)
                 :created-at (or (getf plist :created-at) (get-universal-time))
                 :related-procedures (getf plist :related-procedures)
                 :metadata (getf plist :metadata)))

