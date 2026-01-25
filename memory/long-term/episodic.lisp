;;;; long-term/episodic.lisp
;;;; CL-Agent Memory - Episodic Memory
;;;;
;;;; Overview:
;;;;   Episodic memory stores events and experiences with temporal context.
;;;;   It represents autobiographical memories tied to specific times and places.
;;;;
;;;; Features:
;;;;   - Event storage with timestamps
;;;;   - Temporal querying (time ranges)
;;;;   - Experience replay
;;;;   - Emotional tagging
;;;;
;;;; Reference:
;;;;   - Cognitive science: Episodic memory (Tulving, 1972)
;;;;   - MemGPT episodic memory patterns

(in-package #:cl-agent.memory)

;;; ============================================================
;;; Episode Entry Class
;;; ============================================================

(defclass episode-entry ()
  ((id
    :initarg :id
    :reader episode-entry-id
    :type string
    :documentation "Unique episode ID")

   (event
    :initarg :event
    :accessor episode-entry-event
    :type string
    :documentation "Description of the event/experience")

   (event-type
    :initarg :event-type
    :accessor episode-entry-event-type
    :initform :general
    :type keyword
    :documentation "Type of event (:conversation, :action, :observation, etc.)")

   (participants
    :initarg :participants
    :accessor episode-entry-participants
    :initform nil
    :type list
    :documentation "List of participants in the event")

   (location
    :initarg :location
    :accessor episode-entry-location
    :initform nil
    :type (or null string)
    :documentation "Location/context of the event")

   (embedding
    :initarg :embedding
    :accessor episode-entry-embedding
    :initform nil
    :type (or null list)
    :documentation "Vector embedding for similarity search")

   (emotional-valence
    :initarg :emotional-valence
    :accessor episode-entry-emotional-valence
    :initform 0.0
    :type float
    :documentation "Emotional valence (-1.0 negative to 1.0 positive)")

   (importance
    :initarg :importance
    :accessor episode-entry-importance
    :initform 0.5
    :type float
    :documentation "Importance score (0.0-1.0)")

   (occurred-at
    :initarg :occurred-at
    :reader episode-entry-occurred-at
    :initform (get-universal-time)
    :type integer
    :documentation "When the event occurred")

   (recalled-at
    :initarg :recalled-at
    :accessor episode-entry-recalled-at
    :initform nil
    :type (or null integer)
    :documentation "Last recall timestamp")

   (recall-count
    :initarg :recall-count
    :accessor episode-entry-recall-count
    :initform 0
    :type integer)

   (related-episodes
    :initarg :related-episodes
    :accessor episode-entry-related-episodes
    :initform nil
    :type list
    :documentation "List of related episode IDs")

   (metadata
    :initarg :metadata
    :accessor episode-entry-metadata
    :initform nil
    :type list))

  (:documentation "An episodic memory entry representing an event/experience."))

(defun make-episode-entry (event &key id event-type participants location
                                   embedding emotional-valence importance
                                   occurred-at related-episodes metadata)
  "Create an episode entry."
  (make-instance 'episode-entry
                 :id (or id (format nil "ep-~A" (cl-agent.core:generate-uuid)))
                 :event event
                 :event-type (or event-type :general)
                 :participants participants
                 :location location
                 :embedding embedding
                 :emotional-valence (or emotional-valence 0.0)
                 :importance (or importance 0.5)
                 :occurred-at (or occurred-at (get-universal-time))
                 :related-episodes related-episodes
                 :metadata metadata))

(defmethod print-object ((entry episode-entry) stream)
  (print-unreadable-object (entry stream :type t)
    (format stream "~A @~A: ~S"
            (episode-entry-id entry)
            (cl-agent.core:format-timestamp (episode-entry-occurred-at entry))
            (let ((event (episode-entry-event entry)))
              (if (> (length event) 30)
                  (concatenate 'string (subseq event 0 30) "...")
                  event)))))

;;; ============================================================
;;; Episodic Memory Class
;;; ============================================================

(defclass episodic-memory ()
  ((store
    :initarg :store
    :reader episodic-memory-store
    :documentation "Backend store for persistence")

   (vector-memory
    :initarg :vector-memory
    :reader episodic-memory-vector-memory
    :initform nil
    :documentation "Optional vector memory for similarity search")

   (embedder
    :initarg :embedder
    :reader episodic-memory-embedder
    :initform nil
    :documentation "Optional embedding provider")

   (namespace
    :initarg :namespace
    :reader episodic-memory-namespace
    :initform '("episodic")
    :type list
    :documentation "Store namespace for episodic entries")

   (timeline
    :initform (make-hash-table :test 'equal)
    :reader episodic-memory-timeline
    :documentation "Time-based index (date-string -> entry IDs)")

   (lock
    :initform (bt:make-lock "episodic-memory")
    :reader episodic-memory-lock))

  (:documentation "Episodic memory for storing events and experiences.

This memory type is used for:
  - Conversation history
  - User interactions
  - Task completion events
  - Temporal experiences"))

(defun make-episodic-memory (&key store vector-memory embedder (namespace '("episodic")))
  "Create an episodic memory instance.

Parameters:
  STORE         - Backend store (required)
  VECTOR-MEMORY - Optional vector memory for similarity search
  EMBEDDER      - Optional embedding provider
  NAMESPACE     - Store namespace (default: '(\"episodic\"))

Returns:
  episodic-memory instance"
  (unless store
    (error "store is required for episodic-memory"))
  (make-instance 'episodic-memory
                 :store store
                 :vector-memory vector-memory
                 :embedder embedder
                 :namespace namespace))

;;; ============================================================
;;; Memory Type Protocol Implementation
;;; ============================================================

(defmethod memory-type ((memory episodic-memory))
  :episodic)

(defmethod memory-store-entry ((memory episodic-memory) entry &key metadata)
  "Store an episodic entry."
  (bt:with-lock-held ((episodic-memory-lock memory))
    (let* ((episode (if (typep entry 'episode-entry)
                        entry
                        (make-episode-entry entry :metadata metadata)))
           (id (episode-entry-id episode))
           (event (episode-entry-event episode)))

      ;; Generate embedding if embedder available
      (when (and (episodic-memory-embedder memory)
                 (null (episode-entry-embedding episode)))
        (setf (episode-entry-embedding episode)
              (embed-text (episodic-memory-embedder memory) event)))

      ;; Store in backend
      (store-put (episodic-memory-store memory)
                 (episodic-memory-namespace memory)
                 id
                 (episode-entry-to-plist episode)
                 :embedding (episode-entry-embedding episode)
                 :metadata (append metadata `(:occurred-at ,(episode-entry-occurred-at episode))))

      ;; Add to vector memory if available
      (when (and (episodic-memory-vector-memory memory)
                 (episode-entry-embedding episode))
        (vector-memory-add (episodic-memory-vector-memory memory)
                          id
                          (episode-entry-embedding episode)
                          :metadata `(:event ,event
                                      :occurred-at ,(episode-entry-occurred-at episode))))

      ;; Update timeline index
      (let ((date-key (episode-date-key (episode-entry-occurred-at episode))))
        (pushnew id (gethash date-key (episodic-memory-timeline memory))
                 :test 'equal))

      id)))

(defmethod memory-retrieve ((memory episodic-memory) query &key (limit 10) (threshold 0.0))
  "Retrieve episodic entries.
   QUERY can be a string (for similarity search) or a plist with time range."
  (bt:with-lock-held ((episodic-memory-lock memory))
    (cond
      ;; Time range query
      ((and (listp query) (getf query :from))
       (episodic-retrieve-by-time memory
                                   (getf query :from)
                                   (getf query :to)
                                   :limit limit))

      ;; Event type query
      ((and (listp query) (getf query :event-type))
       (episodic-retrieve-by-type memory
                                   (getf query :event-type)
                                   :limit limit))

      ;; Vector similarity search
      ((and (episodic-memory-vector-memory memory)
            (episodic-memory-embedder memory)
            (stringp query))
       (let* ((query-embedding (embed-text (episodic-memory-embedder memory) query))
              (results (vector-memory-search (episodic-memory-vector-memory memory)
                                             query-embedding
                                             :limit limit
                                             :threshold threshold)))
         (mapcar (lambda (result)
                   (let* ((id (getf result :id))
                          (item (store-get (episodic-memory-store memory)
                                          (episodic-memory-namespace memory)
                                          id)))
                     (when item
                       (let ((episode (plist-to-episode-entry (store-item-value item))))
                         ;; Update recall stats
                         (setf (episode-entry-recalled-at episode) (get-universal-time))
                         (incf (episode-entry-recall-count episode))
                         (list :entry episode
                               :score (getf result :score))))))
                 results)))

      ;; Keyword search fallback
      (t
       (let ((items (store-search (episodic-memory-store memory)
                                  (episodic-memory-namespace memory)
                                  :query query
                                  :limit limit)))
         (mapcar (lambda (item)
                   (list :entry (plist-to-episode-entry (store-item-value item))
                         :score 1.0))
                 items))))))

(defmethod memory-consolidate ((memory episodic-memory) &key strategy)
  "Consolidate episodic memory."
  (declare (ignore strategy))
  (bt:with-lock-held ((episodic-memory-lock memory))
    (let ((total 0)
          (consolidated 0))
      ;; Count total entries
      (let ((items (store-search (episodic-memory-store memory)
                                 (episodic-memory-namespace memory)
                                 :limit 10000)))
        (setf total (length items)))

      `(:total-entries ,total
        :consolidated ,consolidated
        :strategy ,(or strategy :none)))))

(defmethod memory-decay ((memory episodic-memory) decay-fn)
  "Apply decay to episodic memory entries."
  (bt:with-lock-held ((episodic-memory-lock memory))
    (let ((affected 0))
      (let ((items (store-search (episodic-memory-store memory)
                                 (episodic-memory-namespace memory)
                                 :limit 10000)))
        (dolist (item items)
          (let* ((episode (plist-to-episode-entry (store-item-value item)))
                 (age (- (get-universal-time) (episode-entry-occurred-at episode)))
                 (old-importance (episode-entry-importance episode))
                 (new-importance (funcall decay-fn episode age)))
            (when (/= old-importance new-importance)
              (setf (episode-entry-importance episode) new-importance)
              (store-put (episodic-memory-store memory)
                        (episodic-memory-namespace memory)
                        (episode-entry-id episode)
                        (episode-entry-to-plist episode))
              (incf affected)))))
      affected)))

;;; ============================================================
;;; Episodic Memory Specific Operations
;;; ============================================================

(defgeneric episodic-add-event (memory event &key event-type participants location
                                         emotional-valence importance)
  (:documentation "Add an event to episodic memory."))

(defmethod episodic-add-event ((memory episodic-memory) event
                               &key event-type participants location
                                 emotional-valence importance)
  "Add an event to episodic memory."
  (let ((episode (make-episode-entry event
                                     :event-type event-type
                                     :participants participants
                                     :location location
                                     :emotional-valence emotional-valence
                                     :importance importance)))
    (memory-store-entry memory episode)))

(defun episode-date-key (timestamp)
  "Convert timestamp to date key string."
  (multiple-value-bind (sec min hour day month year)
      (decode-universal-time timestamp)
    (declare (ignore sec min hour))
    (format nil "~4D-~2,'0D-~2,'0D" year month day)))

(defgeneric episodic-retrieve-by-time (memory from-time to-time &key limit)
  (:documentation "Retrieve episodes within a time range."))

(defmethod episodic-retrieve-by-time ((memory episodic-memory) from-time to-time
                                       &key (limit 100))
  "Retrieve episodes within a time range."
  (let ((results '())
        (items (store-search (episodic-memory-store memory)
                            (episodic-memory-namespace memory)
                            :limit 10000)))
    (dolist (item items)
      (let* ((episode (plist-to-episode-entry (store-item-value item)))
             (occurred-at (episode-entry-occurred-at episode)))
        (when (and (>= occurred-at from-time)
                   (<= occurred-at (or to-time (get-universal-time))))
          (push (list :entry episode :score 1.0) results))))

    ;; Sort by time (newest first)
    (setf results (sort results #'>
                        :key (lambda (r) (episode-entry-occurred-at (getf r :entry)))))

    ;; Apply limit
    (when (and limit (> (length results) limit))
      (setf results (subseq results 0 limit)))

    results))

(defgeneric episodic-retrieve-by-type (memory event-type &key limit)
  (:documentation "Retrieve episodes by event type."))

(defmethod episodic-retrieve-by-type ((memory episodic-memory) event-type
                                       &key (limit 100))
  "Retrieve episodes by event type."
  (let ((results '())
        (items (store-search (episodic-memory-store memory)
                            (episodic-memory-namespace memory)
                            :limit 10000)))
    (dolist (item items)
      (let ((episode (plist-to-episode-entry (store-item-value item))))
        (when (eq (episode-entry-event-type episode) event-type)
          (push (list :entry episode :score 1.0) results))))

    ;; Sort by time (newest first)
    (setf results (sort results #'>
                        :key (lambda (r) (episode-entry-occurred-at (getf r :entry)))))

    (when (and limit (> (length results) limit))
      (setf results (subseq results 0 limit)))

    results))

(defgeneric episodic-recent (memory &key limit)
  (:documentation "Get recent episodes."))

(defmethod episodic-recent ((memory episodic-memory) &key (limit 10))
  "Get recent episodes."
  (bt:with-lock-held ((episodic-memory-lock memory))
    (let ((items (store-search (episodic-memory-store memory)
                              (episodic-memory-namespace memory)
                              :limit limit)))
      (mapcar (lambda (item)
                (plist-to-episode-entry (store-item-value item)))
              items))))

;;; ============================================================
;;; Serialization Helpers
;;; ============================================================

(defun episode-entry-to-plist (entry)
  "Convert episode entry to plist."
  `(:id ,(episode-entry-id entry)
    :event ,(episode-entry-event entry)
    :event-type ,(episode-entry-event-type entry)
    :participants ,(episode-entry-participants entry)
    :location ,(episode-entry-location entry)
    :embedding ,(episode-entry-embedding entry)
    :emotional-valence ,(episode-entry-emotional-valence entry)
    :importance ,(episode-entry-importance entry)
    :occurred-at ,(episode-entry-occurred-at entry)
    :recalled-at ,(episode-entry-recalled-at entry)
    :recall-count ,(episode-entry-recall-count entry)
    :related-episodes ,(episode-entry-related-episodes entry)
    :metadata ,(episode-entry-metadata entry)))

(defun plist-to-episode-entry (plist)
  "Convert plist to episode entry."
  (make-instance 'episode-entry
                 :id (getf plist :id)
                 :event (getf plist :event)
                 :event-type (or (getf plist :event-type) :general)
                 :participants (getf plist :participants)
                 :location (getf plist :location)
                 :embedding (getf plist :embedding)
                 :emotional-valence (or (getf plist :emotional-valence) 0.0)
                 :importance (or (getf plist :importance) 0.5)
                 :occurred-at (or (getf plist :occurred-at) (get-universal-time))
                 :recalled-at (getf plist :recalled-at)
                 :recall-count (or (getf plist :recall-count) 0)
                 :related-episodes (getf plist :related-episodes)
                 :metadata (getf plist :metadata)))

