# Memory Module

[中文](README.md) | English

Unified memory management module providing short-term checkpoints and long-term persistent storage.

## Directory Structure

```
memory/
├── package.lisp              # Package definition
├── protocol.lisp             # Unified protocol
├── utils.lisp                # Utility functions
├── store/                    # Long-term storage
│   ├── protocol.lisp         # Store protocol
│   ├── memory-backend.lisp   # Memory backend
│   ├── sqlite-backend.lisp   # SQLite backend
│   └── vector-memory.lisp    # Vector storage
├── checkpoint/               # Checkpoints
│   ├── protocol.lisp         # Checkpoint protocol
│   └── manager.lisp          # Checkpoint manager
├── long-term/                # Long-term memory types
│   ├── semantic.lisp         # Semantic memory
│   ├── episodic.lisp         # Episodic memory
│   └── procedural.lisp       # Procedural memory
├── retrieval/                # Retrieval strategies
│   └── strategies.lisp
└── api/                      # Unified API
    ├── message.lisp          # Message structure
    ├── agent-memory.lisp     # Agent Memory class
    └── summary-buffer.lisp   # Summary buffer
```

## Architecture Overview

```
┌─────────────────────────────────────────┐
│           Agent Memory API              │
└─────────────────────────────────────────┘
              │           │
    ┌─────────┴───┐   ┌───┴─────────┐
    │             │   │             │
    ▼             ▼   ▼             ▼
┌─────────┐  ┌─────────┐  ┌─────────────┐
│Checkpoint│  │ Message │  │   Store     │
│ (short)  │  │Structure│  │  (long)     │
└─────────┘  └─────────┘  └─────────────┘
                              │
              ┌───────────────┼───────────────┐
              │               │               │
              ▼               ▼               ▼
         ┌────────┐     ┌────────┐     ┌────────┐
         │ Memory │     │ SQLite │     │ Vector │
         │Backend │     │Backend │     │Backend │
         └────────┘     └────────┘     └────────┘
```

## Message Structure

```lisp
;; Create message
(make-memory-message :role :user :content "Hello")

;; Shortcuts
(make-user-message "Hello")
(make-assistant-message "Hi there!")
(make-system-message "You are helpful.")
(make-tool-message "Result" :tool-call-id "call_123")

;; Access properties
(memory-message-role msg)       ; => :USER
(memory-message-content msg)    ; => "Hello"
(memory-message-timestamp msg)  ; => "2024-01-15T10:30:00Z"
(memory-message-metadata msg)   ; => (:key "value")
```

## Store Backends

### Memory Backend

Fast, session-level storage:

```lisp
(defvar *store* (make-memory-store-backend))

;; Basic operations
(store-put *store* '("namespace") "key" "value")
(store-get *store* '("namespace") "key")  ; => "value"
(store-delete *store* '("namespace") "key")

;; List and count
(store-list-keys *store* '("namespace"))  ; => ("key1" "key2")
(store-count *store* '("namespace"))      ; => 2

;; Clear
(store-clear *store* '("namespace"))
```

### SQLite Backend

Persistent file storage:

```lisp
(defvar *store*
  (make-sqlite-store-backend
    :db-path "~/.cl-agent/memory.db"))

;; API same as memory backend
(store-put *store* '("facts") "lisp-creator" "John McCarthy")
(store-get *store* '("facts") "lisp-creator")

;; Data persists across application restarts
```

### Vector Store Backend

Supports semantic search:

```lisp
(defvar *vector-store*
  (make-vector-memory-backend
    :embedding-fn #'my-embedding-function))

;; Store data with embeddings
(store-put *vector-store* '("docs") "doc1"
  '(:content "Common Lisp is..."
    :embedding #(0.1 0.2 0.3 ...)))

;; Semantic search
(vector-search *vector-store* '("docs")
  :query-embedding #(0.15 0.25 0.35 ...)
  :top-k 5)
```

## Checkpoint System

Save and restore Agent state:

```lisp
(defvar *checkpointer* (make-checkpoint-manager *store*))

;; Save checkpoint
(let ((cp (save-checkpoint *checkpointer* "thread-1"
            '(:summary "User discussed travel plans"
              :facts ((:destination "Japan")
                      (:date "April"))
              :preferences (:style "culture")))))
  (format t "Checkpoint ID: ~A~%" (checkpoint-id cp)))

;; Load latest checkpoint
(let ((cp (load-checkpoint *checkpointer* "thread-1")))
  (when cp
    (format t "State: ~A~%" (checkpoint-state cp))))

;; List all checkpoints
(list-checkpoints *checkpointer* :thread-id "thread-1")

;; Delete checkpoint
(delete-checkpoint *checkpointer* checkpoint-id)

;; Create branch
(create-branch *checkpointer* "thread-1" "experiment-branch")
```

## Agent Memory

Unified memory interface:

```lisp
;; Create Agent Memory
(defvar *memory*
  (make-agent-memory
    :context-store (make-memory-store-backend)      ; Fast context
    :persistent-store (make-sqlite-store-backend    ; Persistent
                        :db-path "memory.db")
    :default-thread-id "default"
    :auto-archive t))                               ; Auto archive

;; Message operations
(am-add-message *memory* "thread-1" :user "Hello")
(am-add-message *memory* "thread-1" :assistant "Hi!")
(am-get-messages *memory* "thread-1")
(am-get-last-n-messages *memory* "thread-1" 5)
(am-clear-messages *memory* "thread-1")

;; Checkpoints
(am-save-checkpoint *memory* "thread-1" '(:state ...))
(am-load-checkpoint *memory* checkpoint-id)

;; Fact storage
(am-store-fact *memory* "user-name" "John")
(am-recall-facts *memory* "user-*")

;; Archive (move to persistent storage)
(am-archive-messages *memory* "thread-1")
```

## Long-term Memory Types

### Semantic Memory

Store facts and knowledge:

```lisp
(defvar *semantic* (make-semantic-memory *store*))

;; Store facts
(semantic-store *semantic* "lisp"
  '(:type :programming-language
    :created 1958
    :creator "John McCarthy"))

;; Recall
(semantic-recall *semantic* "lisp")

;; Associative search
(semantic-search *semantic* :type :programming-language)
```

### Episodic Memory

Store events and experiences:

```lisp
(defvar *episodic* (make-episodic-memory *store*))

;; Record event
(episodic-record *episodic*
  '(:event "User asked about weather"
    :context (:location "Beijing" :mood "curious")
    :outcome "Provided weather information"))

;; Retrieve by time
(episodic-recall *episodic*
  :from "2024-01-01"
  :to "2024-01-31")

;; Retrieve by context
(episodic-search *episodic* :location "Beijing")
```

### Procedural Memory

Store skills and procedures:

```lisp
(defvar *procedural* (make-procedural-memory *store*))

;; Store procedure
(procedural-store *procedural* "book-flight"
  '(:steps ("1. Confirm destination"
            "2. Select dates"
            "3. Search flights"
            "4. Complete booking")
    :preconditions (:has-destination t :has-dates t)
    :tools ("flight-search" "booking-api")))

;; Retrieve procedure
(procedural-recall *procedural* "book-flight")

;; Retrieve by tool
(procedural-search *procedural* :uses-tool "flight-search")
```

## Retrieval Strategies

```lisp
;; Semantic retrieval (vector similarity)
(make-retrieval-strategy :semantic
  :embedding-fn #'embed
  :top-k 5)

;; Recency retrieval (most recent first)
(make-retrieval-strategy :recency
  :decay-factor 0.9)

;; Frequency retrieval (access frequency)
(make-retrieval-strategy :frequency)

;; Importance retrieval (priority ranking)
(make-retrieval-strategy :importance
  :importance-fn #'calculate-importance)

;; Hybrid retrieval
(make-retrieval-strategy :hybrid
  :strategies '((:semantic :weight 0.5)
                (:recency :weight 0.3)
                (:importance :weight 0.2)))
```

## Summary Buffer

Auto-summarize long conversations:

```lisp
(defvar *buffer*
  (make-summary-buffer
    :max-messages 20
    :summarize-fn #'summarize-with-llm))

;; Add message (auto-summarizes)
(buffer-add *buffer* message)

;; Get context (includes summary)
(buffer-get-context *buffer*)
;; => ((:role :system :content "Previous conversation summary: ...")
;;     (:role :user :content "Recent message 1")
;;     (:role :assistant :content "Recent message 2")
;;     ...)
```

## Usage Examples

### Chatbot with Persistence

```lisp
(defvar *memory*
  (make-agent-memory
    :persistent-store (make-sqlite-store-backend :db-path "chat.db")))

(defvar *agent*
  (make-kernel-agent *kernel*
    :memory *memory*
    :system-prompt "Remember user preferences and conversation history."))

;; First session
(agent-chat *agent* "I'm John, I like programming")
(am-save-checkpoint *memory* "user-john"
  '(:name "John" :interests ("programming")))

;; After restart...
(let ((cp (am-load-checkpoint *memory* "user-john")))
  (format t "Welcome back, ~A!~%" (getf (checkpoint-state cp) :name)))
```

### Multi-user Support

```lisp
;; Use different thread-ids to separate users
(am-add-message *memory* "user-alice" :user "Hello")
(am-add-message *memory* "user-bob" :user "Hi")

;; Each has independent conversation history
(am-get-messages *memory* "user-alice")
(am-get-messages *memory* "user-bob")
```

### Knowledge Base Integration

```lisp
(defvar *knowledge* (make-semantic-memory *store*))

;; Import knowledge
(semantic-store *knowledge* "product-a"
  '(:name "Product A"
    :price 99.99
    :features ("Feature 1" "Feature 2")))

;; Agent can retrieve knowledge to answer questions
(let ((product (semantic-recall *knowledge* "product-a")))
  (format nil "~A costs ~A"
          (getf product :name)
          (getf product :price)))
```
