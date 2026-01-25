;;;; package-rag.lisp
;;;; CL-Agent RAG - Package Definition
;;;;
;;;; Overview:
;;;;   Package definition for the RAG (Retrieval-Augmented Generation)
;;;;   module with embeddings, vector storage, text splitting, and
;;;;   Kernel integration.

(defpackage #:cl-agent.rag
  (:use #:common-lisp)
  (:import-from #:cl-agent.core
   ;; Plugin protocol
   #:plugin-name #:plugin-description #:plugin-tools
   #:plugin-initialize #:plugin-shutdown
   ;; Message types
   #:make-message #:system-message #:user-message
   #:assistant-message #:tool-message #:message-role #:message-content
   ;; Tool spec
   #:make-tool
   ;; Utilities
   #:log-debug #:log-info #:log-warn #:log-error)
  (:import-from #:cl-agent.kernel
   ;; Filter system
   #:filter-type #:filter-name #:filter-apply
   ;; Context
   #:context-messages #:context-add-message)
  (:nicknames #:cla.rag #:rag)
  (:export

   ;; ==================== Utils ====================
   ;; Vector math
   #:cosine-similarity
   #:euclidean-distance
   #:dot-product
   #:vector-norm
   #:normalize-vector
   #:manhattan-distance
   #:weighted-average-vectors

   ;; Text utils
   #:word-count
   #:char-count
   #:sentence-split
   #:paragraph-split
   #:truncate-text
   #:clean-text
   #:extract-keywords

   ;; Scoring utils
   #:reciprocal-rank-fusion
   #:min-max-normalize
   #:softmax

   ;; Hash/ID utils
   #:content-hash
   #:generate-chunk-id

   ;; ==================== Splitters ====================
   ;; Protocol
   #:split
   #:splitter-metadata

   ;; Fixed size splitter
   #:fixed-size-splitter
   #:make-fixed-size-splitter
   #:splitter-chunk-size
   #:splitter-chunk-overlap

   ;; Sentence splitter
   #:sentence-splitter
   #:make-sentence-splitter

   ;; Paragraph splitter
   #:paragraph-splitter
   #:make-paragraph-splitter

   ;; Recursive splitter
   #:recursive-splitter
   #:make-recursive-splitter
   #:splitter-separators

   ;; Code splitter
   #:code-splitter
   #:make-code-splitter
   #:splitter-language

   ;; Markdown splitter
   #:markdown-splitter
   #:make-markdown-splitter
   #:splitter-heading-levels

   ;; Semantic splitter
   #:semantic-splitter
   #:make-semantic-splitter
   #:splitter-embedding-fn
   #:splitter-similarity-threshold

   ;; Factory
   #:make-splitter

   ;; ==================== Embeddings ====================
   ;; Protocol
   #:embed-text
   #:embed-batch

   ;; OpenAI embeddings
   #:openai-embeddings
   #:make-openai-embeddings
   #:openai-embeddings-model
   #:openai-embeddings-api-key

   ;; Local embeddings
   #:local-embeddings
   #:make-local-embeddings
   #:local-embeddings-dimension

   ;; Globals
   #:*default-embedding-model*
   #:*rag-verbose*
   #:get-default-embedding-model

   ;; Convenience
   #:embed-text*
   #:embed-batch*

   ;; ==================== Vector Store ====================
   ;; Document
   #:document
   #:make-document
   #:document-id
   #:document-content
   #:document-metadata
   #:document-embedding

   ;; Vector store
   #:vector-store
   #:make-vector-store
   #:vector-store-add-document
   #:vector-store-search
   #:vector-store-get-document
   #:vector-store-count
   #:vector-store-clear
   #:vector-store-documents

   ;; Globals
   #:*default-vector-store*
   #:get-default-vector-store

   ;; Convenience
   #:add-document
   #:search-documents

   ;; ==================== Pipeline ====================
   ;; Text splitter (legacy)
   #:text-splitter
   #:make-text-splitter
   #:split-text

   ;; Document loader
   #:document-loader
   #:make-document-loader
   #:load-document
   #:load-documents

   ;; RAG pipeline
   #:rag-pipeline
   #:make-rag-pipeline
   #:rag-pipeline-embeddings-model
   #:rag-pipeline-vector-store
   #:rag-pipeline-text-splitter
   #:rag-pipeline-llm-client
   #:rag-index-document
   #:rag-index-file
   #:rag-retrieve
   #:rag-generate

   ;; Globals
   #:*default-rag-pipeline*
   #:get-default-rag-pipeline

   ;; Convenience
   #:index-document
   #:index-file
   #:retrieve-documents
   #:rag-query

   ;; ==================== RAG Plugin ====================
   ;; Plugin class
   #:rag-plugin
   #:make-rag-plugin
   #:rag-plugin-name
   #:rag-plugin-description
   #:rag-plugin-pipeline
   #:rag-plugin-embedding-model
   #:rag-plugin-vector-store
   #:rag-plugin-splitter
   #:rag-plugin-top-k
   #:rag-plugin-min-score

   ;; Plugin operations
   #:rag-plugin-index
   #:rag-plugin-search
   #:rag-plugin-augment-prompt
   #:rag-plugin-clear
   #:rag-plugin-count
   #:rag-plugin-tools

   ;; Augmentation filter
   #:rag-augmentation-filter
   #:make-rag-augmentation-filter
   #:filter-plugin
   #:filter-auto-augment
   #:filter-top-k
   #:filter-min-score

   ;; Convenience factories
   #:create-rag-plugin-with-openai
   #:create-rag-plugin-for-code))

