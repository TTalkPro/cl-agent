;;;; rag-plugin.lisp
;;;; CL-Agent RAG - Kernel Plugin Integration
;;;;
;;;; Overview:
;;;;   Exposes RAG functionality as a KernelPlugin for seamless
;;;;   integration with the agent framework.

(in-package :cl-agent.rag)

;;; ============================================================
;;; RAG Plugin Class
;;; ============================================================

(defclass rag-plugin ()
  ((name
    :initform "rag"
    :reader rag-plugin-name
    :documentation "Plugin name")

   (description
    :initform "Retrieval-Augmented Generation plugin"
    :reader rag-plugin-description
    :documentation "Plugin description")

   (pipeline
    :initarg :pipeline
    :accessor rag-plugin-pipeline
    :initform nil
    :documentation "RAG pipeline instance")

   (embedding-model
    :initarg :embedding-model
    :accessor rag-plugin-embedding-model
    :initform nil
    :documentation "Embedding model")

   (vector-store
    :initarg :vector-store
    :accessor rag-plugin-vector-store
    :initform nil
    :documentation "Vector store instance")

   (splitter
    :initarg :splitter
    :accessor rag-plugin-splitter
    :initform nil
    :documentation "Text splitter")

   (top-k
    :initarg :top-k
    :accessor rag-plugin-top-k
    :initform 5
    :type integer
    :documentation "Default number of documents to retrieve")

   (min-score
    :initarg :min-score
    :accessor rag-plugin-min-score
    :initform 0.0
    :type float
    :documentation "Minimum similarity score for retrieval"))

  (:documentation "RAG plugin for the agent kernel.
Provides document indexing, retrieval, and context augmentation."))

(defun make-rag-plugin (&key embedding-model vector-store splitter pipeline
                             (top-k 5) (min-score 0.0))
  "Create a RAG plugin instance.

Parameters:
  EMBEDDING-MODEL - Embedding model (optional, creates default)
  VECTOR-STORE    - Vector store (optional, creates default)
  SPLITTER        - Text splitter (optional, creates default)
  PIPELINE        - Pre-configured RAG pipeline (optional)
  TOP-K           - Default retrieval count
  MIN-SCORE       - Minimum similarity threshold

Returns:
  rag-plugin instance"
  (let* ((embed (or embedding-model (make-local-embeddings)))
         (store (or vector-store (make-vector-store)))
         (split (or splitter (make-recursive-splitter)))
         (pipe (or pipeline
                   (make-rag-pipeline
                    :embeddings-model embed
                    :vector-store store
                    :text-splitter split))))
    (make-instance 'rag-plugin
                   :pipeline pipe
                   :embedding-model embed
                   :vector-store store
                   :splitter split
                   :top-k top-k
                   :min-score min-score)))

;;; ============================================================
;;; Plugin Operations
;;; ============================================================

(defgeneric rag-plugin-index (plugin content &key metadata chunk)
  (:documentation "Index content into the RAG store."))

(defmethod rag-plugin-index ((plugin rag-plugin) content &key metadata (chunk t))
  "Index content into the RAG store.

Parameters:
  PLUGIN   - RAG plugin
  CONTENT  - Text content to index
  METADATA - Optional metadata
  CHUNK    - Whether to chunk the content (default: t)

Returns:
  List of document IDs"
  (let ((store (rag-plugin-vector-store plugin))
        (embed-model (rag-plugin-embedding-model plugin))
        (splitter (rag-plugin-splitter plugin)))

    (if chunk
        ;; Split and index chunks
        (let ((chunks (split splitter content))
              (ids nil))
          (dolist (chunk-text chunks)
            (let* ((embedding (embed-text embed-model chunk-text))
                   (id (vector-store-add-document store chunk-text embedding
                                                   :metadata metadata)))
              (push id ids)))
          (nreverse ids))
        ;; Index as single document
        (let* ((embedding (embed-text embed-model content))
               (id (vector-store-add-document store content embedding
                                               :metadata metadata)))
          (list id)))))

(defgeneric rag-plugin-search (plugin query &key top-k min-score)
  (:documentation "Search for relevant documents."))

(defmethod rag-plugin-search ((plugin rag-plugin) query &key top-k min-score)
  "Search for relevant documents.

Parameters:
  PLUGIN    - RAG plugin
  QUERY     - Search query text
  TOP-K     - Number of results (default: plugin setting)
  MIN-SCORE - Minimum score (default: plugin setting)

Returns:
  List of (document . score) pairs"
  (let ((store (rag-plugin-vector-store plugin))
        (embed-model (rag-plugin-embedding-model plugin))
        (k (or top-k (rag-plugin-top-k plugin)))
        (threshold (or min-score (rag-plugin-min-score plugin))))

    (let ((query-embedding (embed-text embed-model query)))
      (vector-store-search store query-embedding
                           :top-k k
                           :min-score threshold))))

(defgeneric rag-plugin-augment-prompt (plugin query &key top-k template)
  (:documentation "Augment a prompt with retrieved context."))

(defmethod rag-plugin-augment-prompt ((plugin rag-plugin) query
                                      &key top-k
                                           (template nil))
  "Augment a prompt with retrieved context.

Parameters:
  PLUGIN   - RAG plugin
  QUERY    - User query
  TOP-K    - Number of documents to retrieve
  TEMPLATE - Custom prompt template (uses default if nil)

Returns:
  Augmented prompt string"
  (let* ((docs (rag-plugin-search plugin query :top-k (or top-k (rag-plugin-top-k plugin))))
         (context (build-context-string docs))
         (tmpl (or template
                   "Use the following context to answer the question.

Context:
~A

Question: ~A

Answer:")))
    (format nil tmpl context query)))

(defun build-context-string (documents)
  "Build a context string from retrieved documents."
  (with-output-to-string (s)
    (loop for doc in documents
          for i from 1
          do (format s "~%[~A] ~A~%"
                     i
                     (truncate-text (document-content doc) 500)))))

(defgeneric rag-plugin-clear (plugin)
  (:documentation "Clear all indexed documents."))

(defmethod rag-plugin-clear ((plugin rag-plugin))
  "Clear all indexed documents."
  (vector-store-clear (rag-plugin-vector-store plugin)))

(defgeneric rag-plugin-count (plugin)
  (:documentation "Get number of indexed documents."))

(defmethod rag-plugin-count ((plugin rag-plugin))
  "Get the number of indexed documents."
  (vector-store-count (rag-plugin-vector-store plugin)))

;;; ============================================================
;;; Tool Definitions for Kernel Integration
;;; ============================================================

(defun rag-plugin-tools (plugin)
  "Get tool definitions for the RAG plugin.

Parameters:
  PLUGIN - RAG plugin instance

Returns:
  List of tool specifications"
  (list
   (cl-agent.core:make-tool
    :name "rag_index"
    :description "Index text content into the knowledge base for later retrieval"
    :parameters `((:name "content" :type :string :required t
                   :description "Text content to index")
                  (:name "metadata" :type :object
                   :description "Optional metadata for the document")
                  (:name "chunk" :type :boolean
                   :description "Whether to split into chunks (default: true)"))
    :handler (lambda (args)
               (let ((content (getf args :content))
                     (metadata (getf args :metadata))
                     (chunk (if (member :chunk args)
                                (getf args :chunk)
                                t)))
                 (let ((ids (rag-plugin-index plugin content
                                              :metadata metadata
                                              :chunk chunk)))
                   (list :indexed-ids ids
                         :count (length ids))))))

   (cl-agent.core:make-tool
    :name "rag_search"
    :description "Search the knowledge base for relevant documents"
    :parameters `((:name "query" :type :string :required t
                   :description "Search query")
                  (:name "top_k" :type :integer
                   :description "Number of results to return (default: 5)"))
    :handler (lambda (args)
               (let ((query (getf args :query))
                     (top-k (getf args :top-k)))
                 (let ((results (rag-plugin-search plugin query :top-k top-k)))
                   (mapcar (lambda (doc)
                             (list :content (truncate-text (document-content doc) 500)
                                   :id (document-id doc)
                                   :metadata (document-metadata doc)))
                           results)))))

   (cl-agent.core:make-tool
    :name "rag_context"
    :description "Get augmented context for a query (retrieves and formats relevant documents)"
    :parameters `((:name "query" :type :string :required t
                   :description "Query to augment with context")
                  (:name "top_k" :type :integer
                   :description "Number of documents to include"))
    :handler (lambda (args)
               (let ((query (getf args :query))
                     (top-k (getf args :top-k)))
                 (rag-plugin-augment-prompt plugin query :top-k top-k))))

   (cl-agent.core:make-tool
    :name "rag_stats"
    :description "Get statistics about the knowledge base"
    :parameters nil
    :handler (lambda (args)
               (declare (ignore args))
               (list :document-count (rag-plugin-count plugin)
                     :embedding-model (type-of (rag-plugin-embedding-model plugin))
                     :splitter (splitter-metadata (rag-plugin-splitter plugin)))))))

;;; ============================================================
;;; Kernel Plugin Protocol Implementation
;;; ============================================================

;; Implement the KernelPlugin protocol if it exists
(defmethod cl-agent.core:plugin-name ((plugin rag-plugin))
  (rag-plugin-name plugin))

(defmethod cl-agent.core:plugin-description ((plugin rag-plugin))
  (rag-plugin-description plugin))

(defmethod cl-agent.core:plugin-tools ((plugin rag-plugin))
  (rag-plugin-tools plugin))

(defmethod cl-agent.core:plugin-initialize ((plugin rag-plugin) context)
  "Initialize the RAG plugin."
  (declare (ignore context))
  ;; Nothing special to initialize
  t)

(defmethod cl-agent.core:plugin-shutdown ((plugin rag-plugin))
  "Shutdown the RAG plugin."
  ;; Clear resources if needed
  t)

;;; ============================================================
;;; Context Augmentation Filter
;;; ============================================================

(defclass rag-augmentation-filter ()
  ((plugin
    :initarg :plugin
    :accessor filter-plugin
    :documentation "RAG plugin reference")

   (auto-augment
    :initarg :auto-augment
    :accessor filter-auto-augment
    :initform nil
    :type boolean
    :documentation "Automatically augment all user messages")

   (top-k
    :initarg :top-k
    :accessor filter-top-k
    :initform 3
    :type integer
    :documentation "Number of documents to include")

   (min-score
    :initarg :min-score
    :accessor filter-min-score
    :initform 0.5
    :type float
    :documentation "Minimum relevance score"))

  (:documentation "Filter that augments messages with RAG context."))

(defun make-rag-augmentation-filter (plugin &key (auto-augment nil) (top-k 3) (min-score 0.5))
  "Create a RAG augmentation filter.

Parameters:
  PLUGIN       - RAG plugin instance
  AUTO-AUGMENT - Automatically augment all messages
  TOP-K        - Number of documents to retrieve
  MIN-SCORE    - Minimum similarity score

Returns:
  rag-augmentation-filter instance"
  (make-instance 'rag-augmentation-filter
                 :plugin plugin
                 :auto-augment auto-augment
                 :top-k top-k
                 :min-score min-score))

(defmethod filter-type ((filter rag-augmentation-filter))
  :pre-chat)

(defmethod filter-name ((filter rag-augmentation-filter))
  "rag-augmentation")

(defmethod filter-apply ((filter rag-augmentation-filter) context)
  "Apply RAG augmentation to context before chat."
  (when (filter-auto-augment filter)
    (let* ((messages (context-messages context))
           (last-user-msg (find :user messages :key #'cl-agent.core:message-role :from-end t)))
      (when last-user-msg
        (let* ((query (cl-agent.core:message-content last-user-msg))
               (docs (rag-plugin-search (filter-plugin filter) query
                                        :top-k (filter-top-k filter)
                                        :min-score (filter-min-score filter))))
          (when docs
            ;; Add context as a system message
            (let ((context-msg (cl-agent.core:system-message
                                (format nil "Relevant context from knowledge base:~%~A"
                                        (build-context-string docs)))))
              (context-add-message context context-msg)))))))

  ;; Return continue action
  (list :action :continue :context context))

;;; ============================================================
;;; Convenience Functions
;;; ============================================================

(defun create-rag-plugin-with-openai (&key (model "text-embedding-3-small")
                                            api-key
                                            (top-k 5))
  "Create a RAG plugin with OpenAI embeddings.

Parameters:
  MODEL   - OpenAI embedding model
  API-KEY - API key (or from env)
  TOP-K   - Default retrieval count

Returns:
  Configured rag-plugin"
  (make-rag-plugin
   :embedding-model (make-openai-embeddings :model model :api-key api-key)
   :top-k top-k))

(defun create-rag-plugin-for-code (&key (language :generic) (chunk-size 1500))
  "Create a RAG plugin optimized for code.

Parameters:
  LANGUAGE   - Programming language hint
  CHUNK-SIZE - Code chunk size

Returns:
  Configured rag-plugin for code"
  (make-rag-plugin
   :splitter (make-code-splitter :chunk-size chunk-size :language language)))

