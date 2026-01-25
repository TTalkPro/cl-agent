;;;; protocol.lisp
;;;; CL-Agent Memory - Consolidated Memory Protocols
;;;;
;;;; Overview:
;;;;   Consolidated protocol definitions for the memory module.
;;;;   This file re-exports all protocol generic functions for convenience.
;;;;
;;;; Protocols:
;;;;   - Store Protocol: Persistent key-value storage
;;;;   - Checkpoint Protocol: State snapshots and time-travel
;;;;   - Memory Protocol: Unified memory interface
;;;;   - Long-term Memory Protocol: Semantic, episodic, procedural memory
;;;;   - Retrieval Protocol: Memory retrieval strategies
;;;;
;;;; Design:
;;;;   Following the Service abstraction pattern from Kernel.
;;;;   All protocols use CLOS generic functions.

(in-package #:cl-agent.memory)

;;; ============================================================
;;; Store Protocol (re-export from store/protocol.lisp)
;;; ============================================================
;;; See store/protocol.lisp for implementations

;; Store operations are defined in store/protocol.lisp:
;; - store-put
;; - store-get
;; - store-delete
;; - store-search
;; - store-list-namespaces
;; - store-clear
;; - store-count
;; - store-stats

;;; ============================================================
;;; Checkpoint Protocol (re-export from checkpoint/protocol.lisp)
;;; ============================================================
;;; See checkpoint/protocol.lisp for implementations

;; Checkpoint operations are defined in checkpoint/protocol.lisp:
;; - checkpoint-save
;; - checkpoint-load
;; - checkpoint-list-all
;; - checkpoint-delete
;; - checkpoint-clear
;; - checkpoint-get-latest
;; - checkpoint-get-lineage
;; - checkpoint-branch
;; - checkpoint-list-branches

;;; ============================================================
;;; Long-term Memory Protocol
;;; ============================================================
;;; Abstract protocols for semantic, episodic, and procedural memory

(defgeneric memory-type (memory)
  (:documentation "Get the type of long-term memory (:semantic, :episodic, :procedural)."))

(defgeneric memory-store-entry (memory entry &key metadata)
  (:documentation "Store an entry in long-term memory.

Parameters:
  MEMORY   - Long-term memory instance
  ENTRY    - Entry to store (type depends on memory type)
  METADATA - Optional metadata plist

Returns:
  Entry ID"))

(defgeneric memory-retrieve (memory query &key limit threshold)
  (:documentation "Retrieve entries from long-term memory.

Parameters:
  MEMORY    - Long-term memory instance
  QUERY     - Query (string for semantic, time range for episodic, etc.)
  LIMIT     - Maximum number of results
  THRESHOLD - Minimum relevance score (0.0-1.0)

Returns:
  List of matching entries"))

(defgeneric memory-consolidate (memory &key strategy)
  (:documentation "Consolidate memory (e.g., merge similar entries, prune old ones).

Parameters:
  MEMORY   - Long-term memory instance
  STRATEGY - Consolidation strategy

Returns:
  Statistics plist"))

(defgeneric memory-decay (memory decay-fn)
  (:documentation "Apply decay function to memory entries.

Parameters:
  MEMORY   - Long-term memory instance
  DECAY-FN - Function (entry age) -> new-strength

Returns:
  Number of entries affected"))

;;; ============================================================
;;; Retrieval Strategy Protocol
;;; ============================================================
;;; Different strategies for retrieving memories

(defgeneric retrieval-strategy-name (strategy)
  (:documentation "Get the name of the retrieval strategy."))

(defgeneric retrieval-execute (strategy memory query &key limit)
  (:documentation "Execute retrieval using this strategy.

Parameters:
  STRATEGY - Retrieval strategy instance
  MEMORY   - Memory to search
  QUERY    - Query parameters
  LIMIT    - Maximum results

Returns:
  List of retrieved entries with scores"))

(defgeneric retrieval-rank (strategy entries query)
  (:documentation "Rank entries according to this strategy.

Parameters:
  STRATEGY - Retrieval strategy instance
  ENTRIES  - List of candidate entries
  QUERY    - Query for ranking context

Returns:
  Sorted list of entries with scores"))

;;; ============================================================
;;; Vector Memory Protocol
;;; ============================================================
;;; Protocol for vector-based similarity search

(defgeneric vector-memory-add (memory id vector &key metadata)
  (:documentation "Add a vector to the memory.

Parameters:
  MEMORY   - Vector memory instance
  ID       - Unique identifier
  VECTOR   - Vector (list of floats)
  METADATA - Optional metadata

Returns:
  ID"))

(defgeneric vector-memory-search (memory query-vector &key limit threshold)
  (:documentation "Search for similar vectors.

Parameters:
  MEMORY       - Vector memory instance
  QUERY-VECTOR - Query vector
  LIMIT        - Maximum results
  THRESHOLD    - Minimum similarity (0.0-1.0)

Returns:
  List of (id score metadata) tuples"))

(defgeneric vector-memory-remove (memory id)
  (:documentation "Remove a vector by ID.

Parameters:
  MEMORY - Vector memory instance
  ID     - Vector ID

Returns:
  T if removed, NIL if not found"))

(defgeneric vector-memory-update (memory id vector &key metadata)
  (:documentation "Update a vector.

Parameters:
  MEMORY   - Vector memory instance
  ID       - Vector ID
  VECTOR   - New vector
  METADATA - New metadata (optional)

Returns:
  T if updated, NIL if not found"))

;;; ============================================================
;;; Embedding Protocol
;;; ============================================================
;;; Protocol for generating embeddings

(defgeneric embed-text (embedder text)
  (:documentation "Generate embedding for text.

Parameters:
  EMBEDDER - Embedding provider
  TEXT     - Text to embed

Returns:
  Vector (list of floats)"))

(defgeneric embed-batch (embedder texts)
  (:documentation "Generate embeddings for multiple texts.

Parameters:
  EMBEDDER - Embedding provider
  TEXTS    - List of texts

Returns:
  List of vectors"))

(defgeneric embedder-dimensions (embedder)
  (:documentation "Get the dimensionality of embeddings.

Parameters:
  EMBEDDER - Embedding provider

Returns:
  Integer dimension"))

;;; ============================================================
;;; Memory Index Protocol
;;; ============================================================
;;; Protocol for memory indexing

(defgeneric index-add (index key entry)
  (:documentation "Add an entry to the index."))

(defgeneric index-remove (index key)
  (:documentation "Remove an entry from the index."))

(defgeneric index-search (index query &key limit)
  (:documentation "Search the index."))

(defgeneric index-rebuild (index)
  (:documentation "Rebuild the index from scratch."))

