;;;; cl-agent-rag.asd
;;;; CL-Agent RAG - Retrieval-Augmented Generation System
;;;;
;;;; Overview:
;;;;   RAG pipeline with embeddings, vector storage, text splitting,
;;;;   and Kernel plugin integration.
;;;;
;;;; Changelog:
;;;;   v2.0.0 - Added splitter module, utils, and RAG plugin for Kernel
;;;;   v1.0.0 - Initial implementation

(asdf:defsystem #:cl-agent-rag
  :description "CL-Agent RAG - Retrieval-Augmented Generation"
  :author "David"
  :license "MIT"
  :version "2.0.0"

  :depends-on (#:cl-agent-core
               #:cl-agent-llm
               #:cl-ppcre
               #:dexador)

  :serial t
  :components ((:file "package-rag")
               (:file "utils")
               (:file "splitter")
               (:file "embeddings")
               (:file "vector-store")
               (:file "pipeline")
               (:file "rag-plugin"))

  :in-order-to ((asdf:test-op (asdf:test-op #:cl-agent-test))))

