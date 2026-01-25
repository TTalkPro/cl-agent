;;;; store/protocol.lisp
;;;; CL-Agent Memory - Store Protocol
;;;;
;;;; Overview:
;;;;   Define the Store protocol for persistent storage
;;;;
;;;; Design:
;;;;   Following LangGraph's Store pattern:
;;;;   - Namespace-based organization
;;;;   - Cross-thread persistence
;;;;   - Pluggable backends
;;;;
;;;; Reference:
;;;;   - Erlang agent_store behavior
;;;;   - LangGraph BaseStore

(in-package #:cl-agent.memory)

;;; ============================================================
;;; Store Item Class
;;; ============================================================

(defclass store-item ()
  ((namespace
    :initarg :namespace
    :reader store-item-namespace
    :type list
    :documentation "Namespace path (e.g., '(\"user\" \"123\" \"preferences\"))")

   (key
    :initarg :key
    :reader store-item-key
    :type string
    :documentation "Item key within namespace")

   (value
    :initarg :value
    :accessor store-item-value
    :documentation "Stored value (any Lisp object)")

   (embedding
    :initarg :embedding
    :accessor store-item-embedding
    :initform nil
    :type (or null list)
    :documentation "Vector embedding for semantic search")

   (created-at
    :initarg :created-at
    :reader store-item-created-at
    :initform (get-universal-time)
    :type integer
    :documentation "Creation timestamp")

   (updated-at
    :initarg :updated-at
    :accessor store-item-updated-at
    :initform (get-universal-time)
    :type integer
    :documentation "Last update timestamp")

   (metadata
    :initarg :metadata
    :accessor store-item-metadata
    :initform nil
    :type list
    :documentation "Additional metadata (plist)"))

  (:documentation "Store Item - A namespaced key-value entry

Represents a single item in the Store with:
- Hierarchical namespace for organization
- Key for identification within namespace
- Value for the actual data
- Optional embedding for semantic search
- Timestamps for tracking
- Metadata for additional info"))

(defun store-item-p (obj)
  "Check if OBJ is a store-item instance"
  (typep obj 'store-item))

(defun make-store-item (&key namespace key value embedding metadata)
  "Create a store-item instance

Parameters:
  NAMESPACE - Namespace path as list (e.g., '(\"user\" \"123\"))
  KEY       - Item key (string)
  VALUE     - Item value (any)
  EMBEDDING - Vector embedding (optional)
  METADATA  - Additional metadata (optional)

Returns:
  store-item instance"
  (let ((now (get-universal-time)))
    (make-instance 'store-item
                   :namespace namespace
                   :key key
                   :value value
                   :embedding embedding
                   :metadata metadata
                   :created-at now
                   :updated-at now)))

(defmethod print-object ((item store-item) stream)
  (print-unreadable-object (item stream :type t)
    (format stream "~{~A~^/~}:~A"
            (store-item-namespace item)
            (store-item-key item))))

;;; ============================================================
;;; Store Protocol (Generic Functions)
;;; ============================================================

(defgeneric store-put (store namespace key value &key metadata embedding)
  (:documentation "Store a value with namespace and key

Parameters:
  STORE     - Store backend instance
  NAMESPACE - Namespace path (list of strings)
  KEY       - Item key (string)
  VALUE     - Value to store
  METADATA  - Optional metadata (plist)
  EMBEDDING - Optional vector embedding

Returns:
  The stored store-item"))

(defgeneric store-get (store namespace key)
  (:documentation "Retrieve a value by namespace and key

Parameters:
  STORE     - Store backend instance
  NAMESPACE - Namespace path
  KEY       - Item key

Returns:
  store-item or NIL if not found"))

(defgeneric store-delete (store namespace key)
  (:documentation "Delete an item by namespace and key

Parameters:
  STORE     - Store backend instance
  NAMESPACE - Namespace path
  KEY       - Item key

Returns:
  T if deleted, NIL if not found"))

(defgeneric store-search (store namespace-prefix &key query limit filter)
  (:documentation "Search items within a namespace prefix

Parameters:
  STORE            - Store backend instance
  NAMESPACE-PREFIX - Namespace prefix to search within
  QUERY            - Optional search query (for semantic search)
  LIMIT            - Maximum number of results
  FILTER           - Optional filter function

Returns:
  List of matching store-items"))

(defgeneric store-list-namespaces (store prefix &key limit)
  (:documentation "List namespaces under a prefix

Parameters:
  STORE  - Store backend instance
  PREFIX - Namespace prefix
  LIMIT  - Maximum number of results

Returns:
  List of namespace paths"))

(defgeneric store-clear (store &optional namespace)
  (:documentation "Clear the store or a specific namespace

Parameters:
  STORE     - Store backend instance
  NAMESPACE - Optional namespace to clear (if nil, clear all)

Returns:
  Number of items cleared"))

(defgeneric store-count (store &optional namespace)
  (:documentation "Count items in store or namespace

Parameters:
  STORE     - Store backend instance
  NAMESPACE - Optional namespace to count

Returns:
  Number of items"))

(defgeneric store-stats (store)
  (:documentation "Get store statistics

Parameters:
  STORE - Store backend instance

Returns:
  Statistics plist"))

;;; ============================================================
;;; Namespace Utilities
;;; ============================================================

(defun namespace-to-string (namespace &optional (separator "/"))
  "Convert namespace list to string

Parameters:
  NAMESPACE - Namespace path (list)
  SEPARATOR - Separator string (default \"/\")

Returns:
  Namespace string"
  (format nil "~{~A~^~A~}" namespace
          (make-list (1- (length namespace)) :initial-element separator)))

(defun string-to-namespace (string &optional (separator "/"))
  "Convert string to namespace list

Parameters:
  STRING    - Namespace string
  SEPARATOR - Separator string (default \"/\")

Returns:
  Namespace list"
  (cl-ppcre:split separator string))

(defun namespace-prefix-p (prefix namespace)
  "Check if PREFIX is a prefix of NAMESPACE

Parameters:
  PREFIX    - Prefix namespace
  NAMESPACE - Full namespace

Returns:
  T if PREFIX is a prefix of NAMESPACE"
  (and (<= (length prefix) (length namespace))
       (every #'string= prefix (subseq namespace 0 (length prefix)))))

(defun full-key (namespace key)
  "Generate full key from namespace and key

Parameters:
  NAMESPACE - Namespace path
  KEY       - Item key

Returns:
  Full key string"
  (format nil "~{~A~^/~}/~A" namespace key))

(defun parse-full-key (full-key)
  "Parse full key into namespace and key

Parameters:
  FULL-KEY - Full key string

Returns:
  (values namespace key)"
  (let ((parts (cl-ppcre:split "/" full-key)))
    (values (butlast parts) (car (last parts)))))
