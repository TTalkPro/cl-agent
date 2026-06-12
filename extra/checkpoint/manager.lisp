;;;; checkpoint/manager.lisp
;;;; CL-Agent Memory - Checkpoint Manager
;;;;
;;;; Overview:
;;;;   Checkpoint manager implementation using Store backend
;;;;
;;;; Design:
;;;;   - Uses Store protocol for persistence
;;;;   - Supports branching and time-travel
;;;;   - Thread-scoped checkpoints
;;;;
;;;; Reference:
;;;;   - Original checkpoint-manager.lisp from cl-agent-persistence
;;;;   - Erlang agent_checkpointer_ets

(in-package #:cl-agent.checkpoint)

;;; ============================================================
;;; Checkpoint Manager Class
;;; ============================================================

(defclass checkpoint-manager ()
  ((store
    :initarg :store
    :reader checkpoint-manager-store
    :documentation "Store backend for persistence")

   (current-branch
    :initarg :current-branch
    :accessor checkpoint-manager-current-branch
    :initform "main"
    :type string
    :documentation "Current branch ID")

   (branches
    :initarg :branches
    :reader checkpoint-manager-branches
    :initform (make-hash-table :test #'equal)
    :type hash-table
    :documentation "Branch metadata (branch-id -> branch-info)")

   (namespace-prefix
    :initarg :namespace-prefix
    :reader checkpoint-manager-namespace-prefix
    :initform '("checkpoints")
    :type list
    :documentation "Namespace prefix for checkpoints"))

  (:documentation "Checkpoint Manager

Manages checkpoints using a Store backend for persistence.

Features:
- Pluggable storage (via Store protocol)
- Branching support
- Time-travel (go back/forward)
- Lineage tracking"))

(defun make-checkpoint-manager (&key store (namespace-prefix '("checkpoints"))
                                      (initial-branch "main"))
  "Create a checkpoint manager instance

Parameters:
  STORE            - Store backend (required)
  NAMESPACE-PREFIX - Namespace prefix for checkpoints
  INITIAL-BRANCH   - Initial branch name (default \"main\")

Returns:
  checkpoint-manager instance"
  (let ((manager (make-instance 'checkpoint-manager
                                :store store
                                :namespace-prefix namespace-prefix
                                :current-branch initial-branch)))
    ;; Initialize main branch
    (setf (gethash initial-branch (checkpoint-manager-branches manager))
          (make-branch-info initial-branch))
    manager))

(defmethod print-object ((manager checkpoint-manager) stream)
  (print-unreadable-object (manager stream :type t)
    (format stream "branch: ~A, ~A branches"
            (checkpoint-manager-current-branch manager)
            (hash-table-count (checkpoint-manager-branches manager)))))

;;; ============================================================
;;; Branch Info Class
;;; ============================================================

(defclass branch-info ()
  ((branch-id
    :initarg :branch-id
    :reader branch-info-id
    :type string
    :documentation "Branch ID")

   (head-checkpoint-id
    :initarg :head-checkpoint-id
    :accessor branch-info-head-checkpoint-id
    :initform nil
    :type (or null string)
    :documentation "Head checkpoint ID")

   (checkpoint-count
    :initarg :checkpoint-count
    :accessor branch-info-checkpoint-count
    :initform 0
    :type integer
    :documentation "Number of checkpoints")

   (created-at
    :initarg :created-at
    :reader branch-info-created-at
    :initform (get-universal-time)
    :type integer
    :documentation "Creation timestamp"))

  (:documentation "Branch Info - Metadata about a branch"))

(defun make-branch-info (branch-id &key head-checkpoint-id checkpoint-count)
  "Create branch-info instance"
  (make-instance 'branch-info
                 :branch-id branch-id
                 :head-checkpoint-id head-checkpoint-id
                 :checkpoint-count (or checkpoint-count 0)
                 :created-at (get-universal-time)))

;;; ============================================================
;;; Namespace Helpers
;;; ============================================================

(defun checkpoint-namespace (manager thread-id)
  "Get namespace for checkpoints

Parameters:
  MANAGER   - Checkpoint manager
  THREAD-ID - Thread ID

Returns:
  Namespace list"
  (append (checkpoint-manager-namespace-prefix manager)
          (list thread-id)))

(defun checkpoint-storage-key (checkpoint-id)
  "Get storage key for checkpoint"
  checkpoint-id)

;;; ============================================================
;;; Checkpointer Protocol Implementation
;;; ============================================================

(defmethod checkpointer-save ((manager checkpoint-manager) config checkpoint)
  "Save a checkpoint"
  (let* ((thread-id (config-thread-id config))
         (branch-id (checkpoint-manager-current-branch manager))
         (branch-info (gethash branch-id (checkpoint-manager-branches manager)))
         (parent-id (when branch-info
                      (branch-info-head-checkpoint-id branch-info)))
         (checkpoint-id (or (checkpoint-id checkpoint)
                           (generate-checkpoint-id branch-id)))
         (namespace (checkpoint-namespace manager thread-id)))

    ;; Update checkpoint with proper IDs
    (when (null (checkpoint-id checkpoint))
      (setf (slot-value checkpoint 'id) checkpoint-id))
    (when (null (slot-value checkpoint 'thread-id))
      (setf (slot-value checkpoint 'thread-id) thread-id))
    (when parent-id
      (setf (slot-value checkpoint 'parent-id) parent-id))

    ;; Save to store
    (store-put (checkpoint-manager-store manager)
               namespace
               checkpoint-id
               (checkpoint-to-plist checkpoint)
               :metadata `(:type :checkpoint
                          :branch-id ,branch-id
                          :thread-id ,thread-id))

    ;; Update branch info
    (when branch-info
      (setf (branch-info-head-checkpoint-id branch-info) checkpoint-id)
      (incf (branch-info-checkpoint-count branch-info)))

    checkpoint))

(defmethod checkpointer-load ((manager checkpoint-manager) config)
  "Load a checkpoint"
  (let* ((thread-id (config-thread-id config))
         (checkpoint-id (config-checkpoint-id config))
         (namespace (checkpoint-namespace manager thread-id)))

    (if checkpoint-id
        ;; Load specific checkpoint
        (let ((item (store-get (checkpoint-manager-store manager)
                              namespace checkpoint-id)))
          (when item
            (plist-to-checkpoint (store-item-value item))))
        ;; Load latest
        (checkpointer-get-latest manager config))))

(defmethod checkpointer-list ((manager checkpoint-manager) config
                              &key limit before)
  "List checkpoints for a thread"
  (let* ((thread-id (config-thread-id config))
         (namespace (checkpoint-namespace manager thread-id))
         (items (store-search (checkpoint-manager-store manager)
                             namespace
                             :filter (when before
                                      (lambda (item)
                                        (let ((cp (plist-to-checkpoint
                                                  (store-item-value item))))
                                          (< (checkpoint-timestamp cp) before))))
                             :limit limit)))
    (mapcar (lambda (item)
              (plist-to-checkpoint (store-item-value item)))
            items)))

(defmethod checkpointer-delete ((manager checkpoint-manager) config)
  "Delete a checkpoint"
  (let* ((thread-id (config-thread-id config))
         (checkpoint-id (config-checkpoint-id config))
         (namespace (checkpoint-namespace manager thread-id)))
    (store-delete (checkpoint-manager-store manager)
                 namespace checkpoint-id)))

(defmethod checkpointer-clear ((manager checkpoint-manager) config)
  "Clear all checkpoints for a thread"
  (let* ((thread-id (config-thread-id config))
         (namespace (checkpoint-namespace manager thread-id)))
    (store-clear (checkpoint-manager-store manager) namespace)))

;;; ============================================================
;;; Extended Protocol Implementation
;;; ============================================================

(defmethod checkpointer-get-latest ((manager checkpoint-manager) config)
  "Get the latest checkpoint"
  (let* ((thread-id (config-thread-id config))
         (branch-id (checkpoint-manager-current-branch manager))
         (branch-info (gethash branch-id (checkpoint-manager-branches manager)))
         (head-id (when branch-info
                   (branch-info-head-checkpoint-id branch-info))))
    (when head-id
      (checkpointer-load manager
                        (make-checkpoint-config
                         :thread-id thread-id
                         :checkpoint-id head-id)))))

(defmethod checkpointer-get-lineage ((manager checkpoint-manager) config)
  "Get checkpoint lineage (ancestor chain).
   Starts from CONFIG's checkpoint-id, or the latest checkpoint when unspecified."
  (let* ((thread-id (config-thread-id config))
         (checkpoint-id (or (config-checkpoint-id config)
                            (let ((head (checkpointer-load
                                         manager
                                         (make-checkpoint-config :thread-id thread-id))))
                              (when head (checkpoint-id head)))))
         (lineage '()))

    ;; Walk the parent chain from the starting checkpoint
    (loop with current-id = checkpoint-id
          while current-id
          do (let ((cp (checkpointer-load
                       manager
                       (make-checkpoint-config
                        :thread-id thread-id
                        :checkpoint-id current-id))))
               (if cp
                   (progn
                     (push cp lineage)
                     (setf current-id (checkpoint-parent-id cp)))
                   (setf current-id nil))))

    lineage))

(defmethod checkpointer-branch ((manager checkpoint-manager) config branch-id
                                &key from-checkpoint-id)
  "Create a new branch"
  (let* ((thread-id (config-thread-id config))
         (current-branch (checkpoint-manager-current-branch manager))
         (current-branch-info (gethash current-branch
                                       (checkpoint-manager-branches manager)))

         ;; Determine source checkpoint
         (source-id (or from-checkpoint-id
                       (when current-branch-info
                         (branch-info-head-checkpoint-id current-branch-info))))
         (source-cp (when source-id
                     (checkpointer-load
                      manager
                      (make-checkpoint-config
                       :thread-id thread-id
                       :checkpoint-id source-id)))))

    (when (and source-cp
               (not (gethash branch-id (checkpoint-manager-branches manager))))
      ;; Create new branch
      (setf (gethash branch-id (checkpoint-manager-branches manager))
            (make-branch-info branch-id))

      ;; Create first checkpoint on new branch
      (let ((new-cp (make-checkpoint
                    :thread-id thread-id
                    :parent-id source-id
                    :channel-values (checkpoint-channel-values source-cp)
                    :channel-versions (checkpoint-channel-versions source-cp)
                    :metadata `(:branch-id ,branch-id
                               :branched-from ,source-id))))

        ;; Switch to new branch
        (setf (checkpoint-manager-current-branch manager) branch-id)

        ;; Save checkpoint
        (checkpointer-save manager config new-cp)

        new-cp))))

(defmethod checkpointer-list-branches ((manager checkpoint-manager) config)
  "List all branches"
  (declare (ignore config))
  (let ((branches '()))
    (maphash (lambda (branch-id branch-info)
               (push `(:branch-id ,branch-id
                       :head-checkpoint-id ,(branch-info-head-checkpoint-id branch-info)
                       :checkpoint-count ,(branch-info-checkpoint-count branch-info)
                       :created-at ,(branch-info-created-at branch-info))
                     branches))
             (checkpoint-manager-branches manager))
    (nreverse branches)))

;;; ============================================================
;;; Time Travel Operations
;;; ============================================================

(defmethod checkpointer-go-back ((manager checkpoint-manager) config &key (steps 1))
  "Go back N steps in history

Parameters:
  MANAGER - Checkpoint manager
  CONFIG  - Checkpoint config
  STEPS   - Number of steps to go back

Returns:
  Target checkpoint or NIL"
  (let* ((thread-id (config-thread-id config))
         (history (checkpointer-list manager config))
         (branch-id (checkpoint-manager-current-branch manager))
         (branch-info (gethash branch-id (checkpoint-manager-branches manager)))
         (current-id (when branch-info
                      (branch-info-head-checkpoint-id branch-info)))
         (current-index (position current-id history
                                 :key #'checkpoint-id
                                 :test #'string=)))

    (when current-index
      (let ((target-index (min (+ current-index steps)
                               (1- (length history)))))
        (when (< target-index (length history))
          (let ((target-cp (elt history target-index)))
            ;; Update branch head
            (setf (branch-info-head-checkpoint-id branch-info)
                  (checkpoint-id target-cp))
            target-cp))))))

(defmethod checkpointer-go-forward ((manager checkpoint-manager) config &key (steps 1))
  "Go forward N steps in history

Parameters:
  MANAGER - Checkpoint manager
  CONFIG  - Checkpoint config
  STEPS   - Number of steps to go forward

Returns:
  Target checkpoint or NIL"
  (let* ((history (checkpointer-list manager config))
         (branch-id (checkpoint-manager-current-branch manager))
         (branch-info (gethash branch-id (checkpoint-manager-branches manager)))
         (current-id (when branch-info
                      (branch-info-head-checkpoint-id branch-info)))
         (current-index (position current-id history
                                 :key #'checkpoint-id
                                 :test #'string=)))

    (when (and current-index (> current-index 0))
      (let ((target-index (max 0 (- current-index steps))))
        (let ((target-cp (elt history target-index)))
          ;; Update branch head
          (setf (branch-info-head-checkpoint-id branch-info)
                (checkpoint-id target-cp))
          target-cp)))))

(defmethod checkpointer-goto ((manager checkpoint-manager) config checkpoint-id)
  "Go to a specific checkpoint

Parameters:
  MANAGER       - Checkpoint manager
  CONFIG        - Checkpoint config
  CHECKPOINT-ID - Target checkpoint ID

Returns:
  Target checkpoint or NIL"
  (let* ((thread-id (config-thread-id config))
         (branch-id (checkpoint-manager-current-branch manager))
         (branch-info (gethash branch-id (checkpoint-manager-branches manager)))
         (target-cp (checkpointer-load
                    manager
                    (make-checkpoint-config
                     :thread-id thread-id
                     :checkpoint-id checkpoint-id))))

    (when target-cp
      ;; Update branch head
      (setf (branch-info-head-checkpoint-id branch-info) checkpoint-id)
      target-cp)))

;;; ============================================================
;;; Branch Operations
;;; ============================================================

(defmethod checkpointer-switch-branch ((manager checkpoint-manager) config branch-id)
  "Switch to a different branch

Parameters:
  MANAGER   - Checkpoint manager
  CONFIG    - Checkpoint config
  BRANCH-ID - Target branch ID

Returns:
  Latest checkpoint on target branch or NIL"
  (let ((branch-info (gethash branch-id (checkpoint-manager-branches manager))))
    (when branch-info
      (setf (checkpoint-manager-current-branch manager) branch-id)
      (checkpointer-get-latest manager config))))

(defmethod checkpointer-delete-branch ((manager checkpoint-manager) config branch-id)
  "Delete a branch

Parameters:
  MANAGER   - Checkpoint manager
  CONFIG    - Checkpoint config
  BRANCH-ID - Branch to delete

Returns:
  T if deleted, NIL otherwise"
  (let ((current-branch (checkpoint-manager-current-branch manager))
        (branch-count (hash-table-count (checkpoint-manager-branches manager))))

    ;; Cannot delete current branch or last branch
    (when (and (not (string= branch-id current-branch))
               (> branch-count 1))
      ;; Delete all checkpoints on branch
      ;; (In a full implementation, we'd track which checkpoints belong to which branch)
      (remhash branch-id (checkpoint-manager-branches manager))
      t)))

;;; ============================================================
;;; 统一命名 API (checkpoint-* 前缀)
;;; ============================================================
;;; 与 store-* API 保持命名一致

(defmethod checkpoint-save ((manager checkpoint-manager) config checkpoint)
  "Save a checkpoint (unified naming)"
  (checkpointer-save manager config checkpoint))

(defmethod checkpoint-load ((manager checkpoint-manager) config)
  "Load a checkpoint (unified naming)"
  (checkpointer-load manager config))

(defmethod checkpoint-list-all ((manager checkpoint-manager) config &key limit before)
  "List all checkpoints (unified naming)"
  (checkpointer-list manager config :limit limit :before before))

(defmethod checkpoint-delete ((manager checkpoint-manager) config)
  "Delete a checkpoint (unified naming)"
  (checkpointer-delete manager config))

(defmethod checkpoint-clear ((manager checkpoint-manager) config)
  "Clear all checkpoints (unified naming)"
  (checkpointer-clear manager config))

(defmethod checkpoint-get-latest ((manager checkpoint-manager) config)
  "Get latest checkpoint (unified naming)"
  (checkpointer-get-latest manager config))

(defmethod checkpoint-get-lineage ((manager checkpoint-manager) config)
  "Get checkpoint lineage (unified naming)"
  (checkpointer-get-lineage manager config))

(defmethod checkpoint-branch ((manager checkpoint-manager) config branch-id
                              &key from-checkpoint-id)
  "Create a branch (unified naming)"
  (checkpointer-branch manager config branch-id
                       :from-checkpoint-id from-checkpoint-id))

(defmethod checkpoint-list-branches ((manager checkpoint-manager) config)
  "List branches (unified naming)"
  (checkpointer-list-branches manager config))

;;; ============================================================
;;; Time Travel API (checkpoint-* 统一命名)
;;; ============================================================

(defmethod checkpoint-go-back ((manager checkpoint-manager) config &key (steps 1))
  "Go back N steps in history (unified naming)"
  (checkpointer-go-back manager config :steps steps))

(defmethod checkpoint-go-forward ((manager checkpoint-manager) config &key (steps 1))
  "Go forward N steps in history (unified naming)"
  (checkpointer-go-forward manager config :steps steps))

(defmethod checkpoint-goto ((manager checkpoint-manager) config checkpoint-id)
  "Go to a specific checkpoint (unified naming)"
  (checkpointer-goto manager config checkpoint-id))

(defmethod checkpoint-switch-branch ((manager checkpoint-manager) config branch-id)
  "Switch to a different branch (unified naming)"
  (checkpointer-switch-branch manager config branch-id))

(defmethod checkpoint-delete-branch ((manager checkpoint-manager) config branch-id)
  "Delete a branch (unified naming)"
  (checkpointer-delete-branch manager config branch-id))
