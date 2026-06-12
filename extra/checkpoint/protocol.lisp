;;;; checkpoint/protocol.lisp
;;;; CL-Agent Memory - Checkpoint Protocol
;;;;
;;;; Overview:
;;;;   Define the Checkpointer protocol for state snapshots
;;;;
;;;; Design:
;;;;   Following LangGraph's Checkpointer pattern:
;;;;   - Thread-scoped checkpoints
;;;;   - Branching and time-travel
;;;;   - Lineage tracking
;;;;
;;;; Reference:
;;;;   - Erlang agent_checkpointer behavior
;;;;   - LangGraph BaseCheckpointSaver

(in-package #:cl-agent.checkpoint)

;;; ============================================================
;;; Checkpoint Class
;;; ============================================================

(defclass checkpoint ()
  ((id
    :initarg :id
    :reader checkpoint-id
    :type string
    :documentation "Unique checkpoint ID")

   (thread-id
    :initarg :thread-id
    :reader checkpoint-thread-id
    :type string
    :documentation "Thread ID this checkpoint belongs to")

   (parent-id
    :initarg :parent-id
    :reader checkpoint-parent-id
    :initform nil
    :type (or null string)
    :documentation "Parent checkpoint ID (for lineage)")

   (channel-values
    :initarg :channel-values
    :accessor checkpoint-channel-values
    :initform (make-hash-table :test #'equal)
    :type hash-table
    :documentation "Channel values (state data)")

   (channel-versions
    :initarg :channel-versions
    :accessor checkpoint-channel-versions
    :initform (make-hash-table :test #'equal)
    :type hash-table
    :documentation "Channel version numbers")

   (timestamp
    :initarg :timestamp
    :reader checkpoint-timestamp
    :initform (get-universal-time)
    :type integer
    :documentation "Creation timestamp")

   (metadata
    :initarg :metadata
    :accessor checkpoint-metadata
    :initform nil
    :type list
    :documentation "Additional metadata (plist)"))

  (:documentation "Checkpoint - A state snapshot

Represents a point-in-time snapshot of graph state with:
- Unique ID for identification
- Thread ID for scoping
- Parent ID for lineage tracking
- Channel values for actual state data
- Metadata for additional info"))

(defun checkpoint-p (obj)
  "Check if OBJ is a checkpoint instance"
  (typep obj 'checkpoint))

(defun make-checkpoint (&key id thread-id parent-id channel-values
                          channel-versions metadata)
  "Create a checkpoint instance

Parameters:
  ID               - Checkpoint ID (string)
  THREAD-ID        - Thread ID (string)
  PARENT-ID        - Parent checkpoint ID (optional)
  CHANNEL-VALUES   - Hash-table of channel values
  CHANNEL-VERSIONS - Hash-table of channel versions
  METADATA         - Additional metadata (optional)

Returns:
  checkpoint instance"
  (make-instance 'checkpoint
                 :id (or id (generate-checkpoint-id))
                 :thread-id thread-id
                 :parent-id parent-id
                 :channel-values (or channel-values
                                     (make-hash-table :test #'equal))
                 :channel-versions (or channel-versions
                                       (make-hash-table :test #'equal))
                 :timestamp (get-universal-time)
                 :metadata metadata))

(defmethod print-object ((cp checkpoint) stream)
  (print-unreadable-object (cp stream :type t)
    (format stream "~A (thread: ~A, parent: ~A)"
            (checkpoint-id cp)
            (checkpoint-thread-id cp)
            (or (checkpoint-parent-id cp) "none"))))

;;; ============================================================
;;; Checkpoint Config Class
;;; ============================================================

(defclass checkpoint-config ()
  ((thread-id
    :initarg :thread-id
    :reader config-thread-id
    :type string
    :documentation "Thread ID")

   (checkpoint-id
    :initarg :checkpoint-id
    :reader config-checkpoint-id
    :initform nil
    :type (or null string)
    :documentation "Specific checkpoint ID (optional)")

   (namespace
    :initarg :namespace
    :reader config-namespace
    :initform nil
    :type (or null list)
    :documentation "Namespace for storage"))

  (:documentation "Checkpoint Config - Configuration for checkpoint operations"))

(defun checkpoint-config-p (obj)
  "Check if OBJ is a checkpoint-config instance"
  (typep obj 'checkpoint-config))

(defun make-checkpoint-config (&key thread-id checkpoint-id namespace)
  "Create a checkpoint-config instance"
  (make-instance 'checkpoint-config
                 :thread-id thread-id
                 :checkpoint-id checkpoint-id
                 :namespace namespace))

;;; ============================================================
;;; Checkpointer Protocol (Generic Functions)
;;; ============================================================
;;; 命名约定：使用 checkpoint-* 前缀以与 store-* 保持一致
;;; 保留 checkpointer-* 别名以保持向后兼容

(defgeneric checkpoint-save (checkpointer config checkpoint)
  (:documentation "Save a checkpoint

Parameters:
  CHECKPOINTER - Checkpointer instance
  CONFIG       - Checkpoint config (with thread-id)
  CHECKPOINT   - Checkpoint to save

Returns:
  Saved checkpoint (with ID assigned)"))

(defgeneric checkpoint-load (checkpointer config)
  (:documentation "Load a checkpoint

Parameters:
  CHECKPOINTER - Checkpointer instance
  CONFIG       - Checkpoint config (with thread-id and optional checkpoint-id)

Returns:
  Checkpoint or NIL if not found"))

(defgeneric checkpoint-list-all (checkpointer config &key limit before)
  (:documentation "List checkpoints for a thread

Parameters:
  CHECKPOINTER - Checkpointer instance
  CONFIG       - Checkpoint config (with thread-id)
  LIMIT        - Maximum number of results
  BEFORE       - Only return checkpoints before this timestamp

Returns:
  List of checkpoints (newest first)"))

(defgeneric checkpoint-delete (checkpointer config)
  (:documentation "Delete a checkpoint

Parameters:
  CHECKPOINTER - Checkpointer instance
  CONFIG       - Checkpoint config (with checkpoint-id)

Returns:
  T if deleted, NIL if not found"))

(defgeneric checkpoint-clear (checkpointer config)
  (:documentation "Clear all checkpoints for a thread

Parameters:
  CHECKPOINTER - Checkpointer instance
  CONFIG       - Checkpoint config (with thread-id)

Returns:
  Number of checkpoints deleted"))

;;; ============================================================
;;; 向后兼容别名
;;; ============================================================

(defgeneric checkpointer-save (checkpointer config checkpoint)
  (:documentation "DEPRECATED: Use checkpoint-save instead"))

(defgeneric checkpointer-load (checkpointer config)
  (:documentation "DEPRECATED: Use checkpoint-load instead"))

(defgeneric checkpointer-list (checkpointer config &key limit before)
  (:documentation "DEPRECATED: Use checkpoint-list-all instead"))

(defgeneric checkpointer-delete (checkpointer config)
  (:documentation "DEPRECATED: Use checkpoint-delete instead"))

(defgeneric checkpointer-clear (checkpointer config)
  (:documentation "DEPRECATED: Use checkpoint-clear instead"))

;;; ============================================================
;;; Extended Checkpoint Protocol (Time Travel)
;;; ============================================================

(defgeneric checkpoint-get-latest (checkpointer config)
  (:documentation "Get the latest checkpoint for a thread

Parameters:
  CHECKPOINTER - Checkpointer instance
  CONFIG       - Checkpoint config (with thread-id)

Returns:
  Latest checkpoint or NIL"))

(defgeneric checkpoint-get-lineage (checkpointer config)
  (:documentation "Get checkpoint lineage (ancestor chain)

Parameters:
  CHECKPOINTER - Checkpointer instance
  CONFIG       - Checkpoint config (with checkpoint-id)

Returns:
  List of checkpoints from oldest ancestor to current"))

(defgeneric checkpoint-branch (checkpointer config branch-id &key from-checkpoint-id)
  (:documentation "Create a new branch from a checkpoint

Parameters:
  CHECKPOINTER       - Checkpointer instance
  CONFIG             - Checkpoint config
  BRANCH-ID          - New branch ID
  FROM-CHECKPOINT-ID - Source checkpoint (optional, defaults to latest)

Returns:
  New checkpoint on the branch"))

(defgeneric checkpoint-list-branches (checkpointer config)
  (:documentation "List all branches for a thread

Parameters:
  CHECKPOINTER - Checkpointer instance
  CONFIG       - Checkpoint config (with thread-id)

Returns:
  List of branch IDs"))

;;; ============================================================
;;; Time Travel Protocol (统一命名)
;;; ============================================================

(defgeneric checkpoint-go-back (checkpointer config &key steps)
  (:documentation "Go back N steps in checkpoint history

Parameters:
  CHECKPOINTER - Checkpointer instance
  CONFIG       - Checkpoint config
  STEPS        - Number of steps to go back (default 1)

Returns:
  Target checkpoint or NIL"))

(defgeneric checkpoint-go-forward (checkpointer config &key steps)
  (:documentation "Go forward N steps in checkpoint history

Parameters:
  CHECKPOINTER - Checkpointer instance
  CONFIG       - Checkpoint config
  STEPS        - Number of steps to go forward (default 1)

Returns:
  Target checkpoint or NIL"))

(defgeneric checkpoint-goto (checkpointer config checkpoint-id)
  (:documentation "Go to a specific checkpoint

Parameters:
  CHECKPOINTER  - Checkpointer instance
  CONFIG        - Checkpoint config
  CHECKPOINT-ID - Target checkpoint ID

Returns:
  Target checkpoint or NIL"))

(defgeneric checkpoint-switch-branch (checkpointer config branch-id)
  (:documentation "Switch to a different branch

Parameters:
  CHECKPOINTER - Checkpointer instance
  CONFIG       - Checkpoint config
  BRANCH-ID    - Target branch ID

Returns:
  Latest checkpoint on target branch or NIL"))

(defgeneric checkpoint-delete-branch (checkpointer config branch-id)
  (:documentation "Delete a branch

Parameters:
  CHECKPOINTER - Checkpointer instance
  CONFIG       - Checkpoint config
  BRANCH-ID    - Branch to delete

Returns:
  T if deleted, NIL otherwise"))

;;; ============================================================
;;; 扩展协议向后兼容别名
;;; ============================================================

(defgeneric checkpointer-get-latest (checkpointer config)
  (:documentation "DEPRECATED: Use checkpoint-get-latest instead"))

(defgeneric checkpointer-get-lineage (checkpointer config)
  (:documentation "DEPRECATED: Use checkpoint-get-lineage instead"))

(defgeneric checkpointer-branch (checkpointer config branch-id &key from-checkpoint-id)
  (:documentation "DEPRECATED: Use checkpoint-branch instead"))

(defgeneric checkpointer-list-branches (checkpointer config)
  (:documentation "DEPRECATED: Use checkpoint-list-branches instead"))

;;; ============================================================
;;; Checkpoint ID Generation
;;; ============================================================

(defun generate-checkpoint-id (&optional prefix)
  "Generate a unique checkpoint ID

Parameters:
  PREFIX - Optional prefix string

Returns:
  Unique ID string"
  (let ((uuid (string-downcase (format nil "~A" (uuid:make-v4-uuid))))
        (ts (get-universal-time)))
    (if prefix
        (format nil "~A-~A-~A" prefix ts uuid)
        (format nil "cp-~A-~A" ts uuid))))

;;; ============================================================
;;; Checkpoint Utilities
;;; ============================================================

(defun checkpoint-get-channel (checkpoint channel-name)
  "Get a channel value from checkpoint

Parameters:
  CHECKPOINT   - Checkpoint instance
  CHANNEL-NAME - Channel name (string or keyword)

Returns:
  Channel value or NIL"
  (gethash (if (keywordp channel-name)
               (string-downcase (symbol-name channel-name))
               channel-name)
           (checkpoint-channel-values checkpoint)))

(defun checkpoint-set-channel (checkpoint channel-name value)
  "Set a channel value in checkpoint

Parameters:
  CHECKPOINT   - Checkpoint instance
  CHANNEL-NAME - Channel name
  VALUE        - Value to set

Returns:
  Value"
  (let ((key (if (keywordp channel-name)
                 (string-downcase (symbol-name channel-name))
                 channel-name)))
    (setf (gethash key (checkpoint-channel-values checkpoint)) value)
    ;; Increment version
    (incf (gethash key (checkpoint-channel-versions checkpoint) 0))
    value))

(defun checkpoint-get-messages (checkpoint)
  "Get messages from checkpoint (convenience function)

Parameters:
  CHECKPOINT - Checkpoint instance

Returns:
  Messages list or NIL"
  (checkpoint-get-channel checkpoint "messages"))

(defun checkpoint-set-messages (checkpoint messages)
  "Set messages in checkpoint (convenience function)

Parameters:
  CHECKPOINT - Checkpoint instance
  MESSAGES   - Messages list

Returns:
  Messages"
  (checkpoint-set-channel checkpoint "messages" messages))

(defun checkpoint-get-full-messages (checkpoint)
  "Get full-messages from checkpoint (convenience function)

Parameters:
  CHECKPOINT - Checkpoint instance

Returns:
  Full messages list or NIL

Description:
  full-messages contains the complete conversation history without
  any compression or summarization. Used for time-travel and avoiding
  repeated compression in stateless agents."
  (checkpoint-get-channel checkpoint "full-messages"))

(defun checkpoint-set-full-messages (checkpoint full-messages)
  "Set full-messages in checkpoint (convenience function)

Parameters:
  CHECKPOINT     - Checkpoint instance
  FULL-MESSAGES  - Full messages list (complete history)

Returns:
  Full-messages

Description:
  full-messages stores the complete uncompressed conversation history.
  This allows:
  - Time-travel to any point in conversation
  - Avoiding repeated compression when restoring from checkpoint
  - Keeping compressed messages separate from complete history"
  (checkpoint-set-channel checkpoint "full-messages" full-messages))

(defun checkpoint-to-plist (checkpoint)
  "Convert checkpoint to plist for serialization

Parameters:
  CHECKPOINT - Checkpoint instance

Returns:
  Plist representation"
  (let ((channels '())
        (versions '()))
    (maphash (lambda (k v)
               (push (cons k v) channels))
             (checkpoint-channel-values checkpoint))
    (maphash (lambda (k v)
               (push (cons k v) versions))
             (checkpoint-channel-versions checkpoint))
    `(:id ,(checkpoint-id checkpoint)
      :thread-id ,(checkpoint-thread-id checkpoint)
      :parent-id ,(checkpoint-parent-id checkpoint)
      :channel-values ,channels
      :channel-versions ,versions
      :timestamp ,(checkpoint-timestamp checkpoint)
      :metadata ,(checkpoint-metadata checkpoint))))

(defun plist-to-checkpoint (plist)
  "Convert plist to checkpoint

Parameters:
  PLIST - Plist representation

Returns:
  Checkpoint instance"
  (let ((channel-values (make-hash-table :test #'equal))
        (channel-versions (make-hash-table :test #'equal)))
    (dolist (pair (getf plist :channel-values))
      (setf (gethash (car pair) channel-values) (cdr pair)))
    (dolist (pair (getf plist :channel-versions))
      (setf (gethash (car pair) channel-versions) (cdr pair)))
    (make-instance 'checkpoint
                   :id (getf plist :id)
                   :thread-id (getf plist :thread-id)
                   :parent-id (getf plist :parent-id)
                   :channel-values channel-values
                   :channel-versions channel-versions
                   :timestamp (getf plist :timestamp)
                   :metadata (getf plist :metadata))))
