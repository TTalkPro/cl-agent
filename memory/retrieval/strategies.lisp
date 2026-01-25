;;;; retrieval/strategies.lisp
;;;; CL-Agent Memory - Retrieval Strategies
;;;;
;;;; Overview:
;;;;   Different strategies for retrieving memories.
;;;;   Includes similarity-based, recency-based, and hybrid approaches.
;;;;
;;;; Strategies:
;;;;   - Semantic: Vector similarity search
;;;;   - Recency: Time-based retrieval
;;;;   - Frequency: Access-count based
;;;;   - Importance: Priority-based
;;;;   - Hybrid: Combination of multiple factors

(in-package #:cl-agent.memory)

;;; ============================================================
;;; Base Strategy Class
;;; ============================================================

(defclass retrieval-strategy ()
  ((name
    :initarg :name
    :reader retrieval-strategy-name
    :type string
    :documentation "Strategy name")

   (description
    :initarg :description
    :reader retrieval-strategy-description
    :initform nil
    :type (or null string)
    :documentation "Strategy description")

   (config
    :initarg :config
    :accessor retrieval-strategy-config
    :initform nil
    :type list
    :documentation "Strategy configuration plist"))

  (:documentation "Base class for retrieval strategies."))

;;; ============================================================
;;; Semantic Retrieval Strategy
;;; ============================================================

(defclass semantic-retrieval-strategy (retrieval-strategy)
  ((embedder
    :initarg :embedder
    :reader semantic-strategy-embedder
    :initform nil
    :documentation "Embedding provider")

   (similarity-fn
    :initarg :similarity-fn
    :reader semantic-strategy-similarity-fn
    :initform #'cosine-similarity
    :type function
    :documentation "Similarity function"))

  (:default-initargs :name "semantic")
  (:documentation "Retrieval strategy based on semantic similarity."))

(defun make-semantic-retrieval-strategy (&key embedder (similarity-fn #'cosine-similarity))
  "Create a semantic retrieval strategy."
  (make-instance 'semantic-retrieval-strategy
                 :embedder embedder
                 :similarity-fn similarity-fn))

(defmethod retrieval-execute ((strategy semantic-retrieval-strategy) memory query &key (limit 10))
  "Execute semantic retrieval."
  (if (semantic-strategy-embedder strategy)
      (let ((query-embedding (embed-text (semantic-strategy-embedder strategy)
                                         (if (stringp query) query (princ-to-string query)))))
        (vector-memory-search memory query-embedding :limit limit))
      ;; Fallback to keyword search if no embedder
      (store-search memory '() :query query :limit limit)))

(defmethod retrieval-rank ((strategy semantic-retrieval-strategy) entries query)
  "Rank entries by semantic similarity."
  (if (semantic-strategy-embedder strategy)
      (let ((query-embedding (embed-text (semantic-strategy-embedder strategy)
                                         (if (stringp query) query (princ-to-string query))))
            (sim-fn (semantic-strategy-similarity-fn strategy)))
        (let ((scored-entries
                (mapcar (lambda (entry)
                          (let ((embedding (if (listp entry)
                                              (getf entry :embedding)
                                              (slot-value entry 'embedding))))
                            (list :entry entry
                                  :score (if embedding
                                            (funcall sim-fn query-embedding embedding)
                                            0.0))))
                        entries)))
          (sort scored-entries #'> :key (lambda (e) (getf e :score)))))
      entries))

;;; ============================================================
;;; Recency Retrieval Strategy
;;; ============================================================

(defclass recency-retrieval-strategy (retrieval-strategy)
  ((decay-rate
    :initarg :decay-rate
    :reader recency-strategy-decay-rate
    :initform 0.1
    :type float
    :documentation "Decay rate per hour"))

  (:default-initargs :name "recency")
  (:documentation "Retrieval strategy based on recency."))

(defun make-recency-retrieval-strategy (&key (decay-rate 0.1))
  "Create a recency retrieval strategy."
  (make-instance 'recency-retrieval-strategy
                 :decay-rate decay-rate))

(defmethod retrieval-execute ((strategy recency-retrieval-strategy) memory query &key (limit 10))
  "Execute recency-based retrieval."
  (declare (ignore query))
  ;; Search and sort by timestamp
  (let ((items (store-search memory '() :limit (* limit 10))))
    (let ((sorted (sort items #'>
                       :key (lambda (item)
                              (store-item-updated-at item)))))
      (subseq sorted 0 (min limit (length sorted))))))

(defmethod retrieval-rank ((strategy recency-retrieval-strategy) entries query)
  "Rank entries by recency."
  (declare (ignore query))
  (let ((now (get-universal-time))
        (decay-rate (recency-strategy-decay-rate strategy)))
    (let ((scored-entries
            (mapcar (lambda (entry)
                      (let* ((timestamp (if (listp entry)
                                           (or (getf entry :updated-at)
                                               (getf entry :created-at)
                                               now)
                                           (or (slot-value entry 'updated-at)
                                               (slot-value entry 'created-at)
                                               now)))
                             (age-hours (/ (- now timestamp) 3600.0))
                             (score (exp (- (* decay-rate age-hours)))))
                        (list :entry entry :score score)))
                    entries)))
      (sort scored-entries #'> :key (lambda (e) (getf e :score))))))

;;; ============================================================
;;; Frequency Retrieval Strategy
;;; ============================================================

(defclass frequency-retrieval-strategy (retrieval-strategy)
  ()
  (:default-initargs :name "frequency")
  (:documentation "Retrieval strategy based on access frequency."))

(defun make-frequency-retrieval-strategy ()
  "Create a frequency retrieval strategy."
  (make-instance 'frequency-retrieval-strategy))

(defmethod retrieval-execute ((strategy frequency-retrieval-strategy) memory query &key (limit 10))
  "Execute frequency-based retrieval."
  (declare (ignore query))
  ;; This would need the memory to track access counts
  (store-search memory '() :limit limit))

(defmethod retrieval-rank ((strategy frequency-retrieval-strategy) entries query)
  "Rank entries by access frequency."
  (declare (ignore query))
  (let ((scored-entries
          (mapcar (lambda (entry)
                    (let ((count (if (listp entry)
                                    (or (getf entry :access-count) 0)
                                    (or (ignore-errors (slot-value entry 'access-count)) 0))))
                      (list :entry entry :score (float count))))
                  entries)))
    (sort scored-entries #'> :key (lambda (e) (getf e :score)))))

;;; ============================================================
;;; Importance Retrieval Strategy
;;; ============================================================

(defclass importance-retrieval-strategy (retrieval-strategy)
  ()
  (:default-initargs :name "importance")
  (:documentation "Retrieval strategy based on entry importance."))

(defun make-importance-retrieval-strategy ()
  "Create an importance retrieval strategy."
  (make-instance 'importance-retrieval-strategy))

(defmethod retrieval-execute ((strategy importance-retrieval-strategy) memory query &key (limit 10))
  "Execute importance-based retrieval."
  (declare (ignore query))
  (store-search memory '() :limit limit))

(defmethod retrieval-rank ((strategy importance-retrieval-strategy) entries query)
  "Rank entries by importance."
  (declare (ignore query))
  (let ((scored-entries
          (mapcar (lambda (entry)
                    (let ((importance (if (listp entry)
                                         (or (getf entry :importance)
                                             (getf entry :confidence)
                                             0.5)
                                         (or (ignore-errors (slot-value entry 'importance))
                                             (ignore-errors (slot-value entry 'confidence))
                                             0.5))))
                      (list :entry entry :score (float importance))))
                  entries)))
    (sort scored-entries #'> :key (lambda (e) (getf e :score)))))

;;; ============================================================
;;; Hybrid Retrieval Strategy
;;; ============================================================

(defclass hybrid-retrieval-strategy (retrieval-strategy)
  ((strategies
    :initarg :strategies
    :reader hybrid-strategy-strategies
    :initform nil
    :type list
    :documentation "List of (strategy . weight) pairs")

   (aggregation
    :initarg :aggregation
    :reader hybrid-strategy-aggregation
    :initform :weighted-sum
    :type keyword
    :documentation "Aggregation method (:weighted-sum, :max, :rank-fusion)"))

  (:default-initargs :name "hybrid")
  (:documentation "Retrieval strategy combining multiple strategies."))

(defun make-hybrid-retrieval-strategy (strategy-weights &key (aggregation :weighted-sum))
  "Create a hybrid retrieval strategy.

Parameters:
  STRATEGY-WEIGHTS - List of (strategy . weight) pairs
  AGGREGATION      - Aggregation method

Returns:
  hybrid-retrieval-strategy instance"
  (make-instance 'hybrid-retrieval-strategy
                 :strategies strategy-weights
                 :aggregation aggregation))

(defmethod retrieval-execute ((strategy hybrid-retrieval-strategy) memory query &key (limit 10))
  "Execute hybrid retrieval."
  ;; Execute first strategy and get candidates
  (when (hybrid-strategy-strategies strategy)
    (let ((first-strategy (car (first (hybrid-strategy-strategies strategy)))))
      (retrieval-execute first-strategy memory query :limit (* limit 5)))))

(defmethod retrieval-rank ((strategy hybrid-retrieval-strategy) entries query)
  "Rank entries using hybrid strategy."
  (let ((aggregation (hybrid-strategy-aggregation strategy))
        (strategies (hybrid-strategy-strategies strategy)))
    (case aggregation
      (:weighted-sum
       (hybrid-weighted-sum-rank strategies entries query))
      (:max
       (hybrid-max-rank strategies entries query))
      (:rank-fusion
       (hybrid-rank-fusion strategies entries query))
      (otherwise
       (hybrid-weighted-sum-rank strategies entries query)))))

(defun hybrid-weighted-sum-rank (strategies entries query)
  "Rank using weighted sum of strategy scores."
  (let ((total-weight (reduce #'+ strategies :key #'cdr :initial-value 0.0))
        (entry-scores (make-hash-table :test 'equal)))

    ;; Initialize scores
    (dolist (entry entries)
      (setf (gethash entry entry-scores) 0.0))

    ;; Accumulate weighted scores
    (dolist (sw strategies)
      (let* ((strat (car sw))
             (weight (/ (cdr sw) total-weight))
             (ranked (retrieval-rank strat entries query)))
        (dolist (r ranked)
          (let ((entry (getf r :entry))
                (score (* weight (getf r :score))))
            (incf (gethash entry entry-scores 0.0) score)))))

    ;; Build result
    (let ((results '()))
      (maphash (lambda (entry score)
                 (push (list :entry entry :score score) results))
               entry-scores)
      (sort results #'> :key (lambda (e) (getf e :score))))))

(defun hybrid-max-rank (strategies entries query)
  "Rank using max score across strategies."
  (let ((entry-scores (make-hash-table :test 'equal)))

    ;; Initialize scores
    (dolist (entry entries)
      (setf (gethash entry entry-scores) 0.0))

    ;; Take max score
    (dolist (sw strategies)
      (let* ((strat (car sw))
             (ranked (retrieval-rank strat entries query)))
        (dolist (r ranked)
          (let ((entry (getf r :entry))
                (score (getf r :score)))
            (setf (gethash entry entry-scores 0.0)
                  (max (gethash entry entry-scores 0.0) score))))))

    ;; Build result
    (let ((results '()))
      (maphash (lambda (entry score)
                 (push (list :entry entry :score score) results))
               entry-scores)
      (sort results #'> :key (lambda (e) (getf e :score))))))

(defun hybrid-rank-fusion (strategies entries query)
  "Rank using reciprocal rank fusion."
  (let ((k 60.0)  ; Standard RRF constant
        (entry-scores (make-hash-table :test 'equal)))

    ;; Initialize scores
    (dolist (entry entries)
      (setf (gethash entry entry-scores) 0.0))

    ;; Accumulate RRF scores
    (dolist (sw strategies)
      (let* ((strat (car sw))
             (weight (cdr sw))
             (ranked (retrieval-rank strat entries query)))
        (loop for r in ranked
              for rank from 1
              do (let ((entry (getf r :entry))
                       (rrf-score (* weight (/ 1.0 (+ k rank)))))
                   (incf (gethash entry entry-scores 0.0) rrf-score)))))

    ;; Build result
    (let ((results '()))
      (maphash (lambda (entry score)
                 (push (list :entry entry :score score) results))
               entry-scores)
      (sort results #'> :key (lambda (e) (getf e :score))))))

;;; ============================================================
;;; Convenience Functions
;;; ============================================================

(defun create-default-retrieval-strategy (&key embedder)
  "Create a default retrieval strategy.

If EMBEDDER is provided, creates a hybrid strategy with semantic + recency.
Otherwise, creates a recency-based strategy."
  (if embedder
      (make-hybrid-retrieval-strategy
       (list (cons (make-semantic-retrieval-strategy :embedder embedder) 0.7)
             (cons (make-recency-retrieval-strategy) 0.3))
       :aggregation :weighted-sum)
      (make-recency-retrieval-strategy)))

(defun create-rag-retrieval-strategy (&key embedder (top-k 5))
  "Create a retrieval strategy optimized for RAG.

Parameters:
  EMBEDDER - Embedding provider (required)
  TOP-K    - Number of results to return

Returns:
  Configured retrieval strategy"
  (unless embedder
    (error "embedder is required for RAG retrieval strategy"))
  (let ((strategy (make-semantic-retrieval-strategy :embedder embedder)))
    (setf (retrieval-strategy-config strategy) `(:top-k ,top-k))
    strategy))

