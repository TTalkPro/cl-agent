# RAG Module

[中文](README.md) | English

Retrieval-Augmented Generation module.

## Directory Structure

```
rag/
├── package-rag.lisp          # Package definition
├── utils.lisp                # Utility functions
├── splitter.lisp             # Text splitters
├── embeddings.lisp           # Embedding models
├── vector-store.lisp         # Vector storage
├── pipeline.lisp             # RAG pipeline
└── rag-plugin.lisp           # Kernel plugin integration
```

## RAG Flow

```
Document → Split → Embed → Vector Store
                         ↑
Query → Embed → Retrieve ─┘
                ↓
           Relevant Context
                ↓
         LLM Generates Answer
```

## Text Splitting

### Basic Splitter

```lisp
;; Split by character count
(defvar *splitter*
  (make-text-splitter
    :chunk-size 1000        ; Chunk size
    :chunk-overlap 200))    ; Overlap size

(split-text *splitter* "Long text content...")
;; => ("chunk1..." "chunk2..." "chunk3...")
```

### Splitting Strategies

```lisp
;; Split by paragraph
(make-text-splitter
  :strategy :paragraph
  :chunk-size 1000)

;; Split by sentence
(make-text-splitter
  :strategy :sentence
  :chunk-size 500)

;; Split by markers (Markdown)
(make-text-splitter
  :strategy :markdown
  :chunk-size 1000)

;; Recursive splitting (paragraph first, then sentence, then character)
(make-text-splitter
  :strategy :recursive
  :separators '("\n\n" "\n" ". " " ")
  :chunk-size 1000)
```

### Code Splitting

```lisp
;; Split code by function/class
(make-code-splitter
  :language :python
  :chunk-size 2000)

(make-code-splitter
  :language :lisp
  :chunk-size 1500)
```

## Embedding Models

### Local Embeddings

```lisp
;; Use local model
(defvar *embeddings*
  (make-local-embeddings
    :model "all-MiniLM-L6-v2"
    :dimension 384))

(embed *embeddings* "Hello, world!")
;; => #(0.123 0.456 ...)
```

### API Embeddings

```lisp
;; OpenAI embeddings
(defvar *openai-embeddings*
  (make-embedding-client
    :provider :openai
    :model "text-embedding-3-small"
    :api-key (uiop:getenv "OPENAI_API_KEY")))

;; ZhipuAI embeddings
(defvar *zhipu-embeddings*
  (make-embedding-client
    :provider :zhipu
    :model "embedding-2"
    :api-key (uiop:getenv "ZHIPU_API_KEY")))
```

### Batch Embeddings

```lisp
;; Embed multiple texts in single call
(embed-batch *embeddings*
  '("Text 1" "Text 2" "Text 3"))
;; => (#(...) #(...) #(...))
```

## Vector Store

### In-Memory Vector Store

```lisp
(defvar *store* (make-vector-store))

;; Add document
(vector-store-add-document *store*
  "Common Lisp is a programming language"
  (embed *embeddings* "Common Lisp is a programming language")
  :metadata '(:source "intro.txt" :page 1))

;; Search
(vector-store-search *store*
  (embed *embeddings* "What is Lisp?")
  :top-k 5)
;; => ((0.92 . document1) (0.85 . document2) ...)
```

### Persistent Vector Store

```lisp
;; SQLite vector store
(defvar *persistent-store*
  (make-persistent-vector-store
    :path "vectors.db"))

;; Save
(vector-store-save *persistent-store*)

;; Load
(vector-store-load *persistent-store*)
```

### Similarity Metrics

```lisp
;; Cosine similarity (default)
(make-vector-store :similarity :cosine)

;; Euclidean distance
(make-vector-store :similarity :euclidean)

;; Dot product
(make-vector-store :similarity :dot-product)
```

## Document Structure

```lisp
;; Document object
(defstruct document
  id          ; Unique identifier
  content     ; Text content
  embedding   ; Embedding vector
  metadata)   ; Metadata

;; Create document
(make-document
  :id "doc-001"
  :content "Document content..."
  :embedding #(0.1 0.2 ...)
  :metadata '(:source "file.txt"
              :created "2024-01-15"
              :author "Author"))
```

## RAG Pipeline

### Creating Pipeline

```lisp
(defvar *rag*
  (make-rag-pipeline
    :embeddings-model *embeddings*
    :vector-store *store*
    :splitter *splitter*
    :llm-client *llm*))
```

### Indexing Documents

```lisp
;; Index single document
(rag-index *rag* "Document content..."
  :metadata '(:source "doc.txt"))

;; Index file
(rag-index-file *rag* "/path/to/document.txt")

;; Batch indexing
(rag-index-directory *rag* "/path/to/docs/"
  :pattern "*.txt"
  :recursive t)
```

### Retrieval

```lisp
;; Retrieve relevant documents
(rag-retrieve *rag* "What is Common Lisp?"
  :top-k 5
  :threshold 0.7)  ; Minimum similarity threshold
;; => (document1 document2 ...)
```

### Query

```lisp
;; Retrieve + Generate
(rag-query *rag* "What are the features of Common Lisp?"
  :top-k 5
  :system-prompt "Answer questions based on provided context.")
;; => "According to the documents, Common Lisp features include..."
```

### Conversation

```lisp
;; Multi-turn RAG conversation
(rag-chat *rag*
  '((:role :user :content "What is SBCL?")
    (:role :assistant :content "SBCL is...")
    (:role :user :content "What are its advantages?")))
```

## Integration with Kernel

### RAG Filter

```lisp
;; Create RAG filter
(defvar *rag-filter*
  (make-rag-filter *rag*
    :top-k 5
    :inject-as :system))  ; Inject as system message

;; Add to Kernel
(defvar *kernel*
  (make-kernel
    :service *service*
    :filters (list *rag-filter*)))
```

### RAG Plugin

```lisp
;; Expose as tool
(defvar *rag-plugin*
  (make-rag-plugin *rag*
    :name "knowledge-base"
    :description "Search knowledge base"))

(defvar *kernel*
  (make-kernel
    :service *service*
    :plugins (list *rag-plugin*)))

;; Agent can actively call
(agent-chat *agent* "Search knowledge base for Lisp macros information")
```

## Advanced Configuration

### Reranking

```lisp
;; Use reranking model to improve precision
(make-rag-pipeline
  :embeddings-model *embeddings*
  :vector-store *store*
  :reranker (make-reranker
              :model "cross-encoder"
              :top-k 3))
```

### Hybrid Retrieval

```lisp
;; Combine keyword and semantic search
(make-rag-pipeline
  :retriever (make-hybrid-retriever
               :keyword-weight 0.3
               :semantic-weight 0.7))
```

### Context Compression

```lisp
;; Compress retrieved context
(make-rag-pipeline
  :context-compressor (make-context-compressor
                        :max-tokens 2000
                        :strategy :extractive))
```

## Usage Examples

### Document Q&A System

```lisp
;; Setup RAG
(defvar *qa-rag*
  (make-rag-pipeline
    :embeddings-model (make-embedding-client :provider :openai)
    :vector-store (make-vector-store)
    :splitter (make-text-splitter :chunk-size 500)))

;; Index documents
(rag-index-directory *qa-rag* "/docs/" :pattern "*.md")

;; Create QA Agent
(defvar *qa-agent*
  (make-kernel-agent
    (make-kernel
      :service *service*
      :filters (list (make-rag-filter *qa-rag*)))
    :system-prompt "Answer questions based on documents. If information is not in documents, say so."))

;; Use
(agent-chat *qa-agent* "How to configure the system?")
```

### Code Search

```lisp
;; RAG specialized for code
(defvar *code-rag*
  (make-rag-pipeline
    :embeddings-model *embeddings*
    :vector-store (make-vector-store)
    :splitter (make-code-splitter :language :lisp)))

;; Index codebase
(rag-index-directory *code-rag* "/src/"
  :pattern "*.lisp"
  :recursive t)

;; Search code
(rag-retrieve *code-rag* "HTTP request handling function")
```

### Knowledge Base Agent

```lisp
;; Combine multiple knowledge sources
(defvar *docs-store* (make-vector-store))
(defvar *faq-store* (make-vector-store))

;; Index different sources
(rag-index *docs-rag* docs :metadata '(:type :documentation))
(rag-index *faq-rag* faqs :metadata '(:type :faq))

;; Combined retrieval
(defun multi-source-retrieve (query)
  (append
    (rag-retrieve *docs-rag* query :top-k 3)
    (rag-retrieve *faq-rag* query :top-k 2)))
```
