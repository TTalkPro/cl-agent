# Quick Start Guide

[中文](QUICKSTART_CN.md)

This guide will help you get started with CL-Agent quickly.

## Table of Contents

- [Installation](#installation)
- [Basic Usage](#basic-usage)
- [Agent Examples](#agent-examples)
  - [Simple Chat Agent](#simple-chat-agent)
  - [Agent with Tools](#agent-with-tools)
  - [ReAct Agent](#react-agent)
  - [Agent with Memory Persistence](#agent-with-memory-persistence)
  - [RAG-Enhanced Agent](#rag-enhanced-agent)
  - [Multi-Turn Conversation Agent](#multi-turn-conversation-agent)
- [Memory Persistence](#memory-persistence)
  - [In-Memory Storage](#in-memory-storage)
  - [SQLite Persistence](#sqlite-persistence)
  - [Checkpoints](#checkpoints)

---

## Installation

### Prerequisites

- SBCL (Steel Bank Common Lisp) or other CL implementation
- Quicklisp package manager

### Setup

```bash
# Clone the repository
git clone https://github.com/example/cl-agent.git

# Add to local-projects
ln -s /path/to/cl-agent ~/quicklisp/local-projects/cl-agent
```

Load in REPL:

```lisp
;; Load the system
(ql:quickload :cl-agent)

;; Or load specific modules
(ql:quickload :cl-agent-core)
(ql:quickload :cl-agent-llm)
(ql:quickload :cl-agent-simpleagent)
(ql:quickload :cl-agent-memory)
```

### Environment Setup

Set your API keys:

```bash
export ANTHROPIC_API_KEY="your-api-key"
export OPENAI_API_KEY="your-api-key"
export ZHIPU_API_KEY="your-api-key"
```

---

## Basic Usage

### Create LLM Client

```lisp
(defpackage :my-agent
  (:use :cl)
  (:import-from :cl-agent.llm
                :make-client
                :chat)
  (:import-from :cl-agent.core
                :get-env))

(in-package :my-agent)

;; Create client for Anthropic Claude
(defvar *client*
  (make-client
    :provider :anthropic
    :model "claude-3-5-sonnet-20241022"
    :api-key (get-env "ANTHROPIC_API_KEY")))

;; Simple chat
(chat *client* "What is Common Lisp?")
```

### Switch Providers

```lisp
;; OpenAI
(defvar *openai-client*
  (make-client
    :provider :openai
    :model "gpt-4o"
    :api-key (get-env "OPENAI_API_KEY")))

;; ZhipuAI (GLM)
(defvar *zhipu-client*
  (make-client
    :provider :zhipu
    :model "glm-4-turbo"
    :api-key (get-env "ZHIPU_API_KEY")))

;; Ollama (Local)
(defvar *ollama-client*
  (make-client
    :provider :ollama
    :model "llama2"
    :base-url "http://localhost:11434"))
```

---

## Agent Examples

### Simple Chat Agent

Basic agent without tools:

```lisp
(defpackage :example-simple
  (:use :cl)
  (:import-from :cl-agent.llm :make-client)
  (:import-from :cl-agent.kernel :make-kernel :make-service)
  (:import-from :cl-agent.simpleagent :make-kernel-agent :agent-chat))

(in-package :example-simple)

;; 1. Create LLM client
(defvar *client*
  (make-client
    :provider :anthropic
    :model "claude-3-5-sonnet-20241022"
    :api-key (uiop:getenv "ANTHROPIC_API_KEY")))

;; 2. Create service from client
(defvar *service*
  (make-service :provider *client*))

;; 3. Create kernel (no plugins)
(defvar *kernel*
  (make-kernel :service *service*))

;; 4. Create agent
(defvar *agent*
  (make-kernel-agent *kernel*
    :name "simple-bot"
    :system-prompt "You are a friendly assistant. Be concise and helpful."))

;; 5. Chat!
(agent-chat *agent* "Hello! What can you do?")
;; => "Hello! I can answer questions, help with information..."

(agent-chat *agent* "Tell me a joke")
;; => "Why do programmers prefer dark mode?..."
```

### Agent with Tools

Agent that can use tools:

```lisp
(defpackage :example-tools
  (:use :cl)
  (:import-from :cl-agent.kernel
                :deftool :defplugin
                :make-kernel :make-service)
  (:import-from :cl-agent.simpleagent
                :make-kernel-agent :agent-chat))

(in-package :example-tools)

;; Define tools
(deftool get-weather "Get current weather for a location"
  ((location :string "City or location name" :required-p t)
   (unit :string "Temperature unit (celsius/fahrenheit)" :default "celsius"))
  ;; In real app, call weather API here
  (format nil "Weather in ~A: 22°~A, partly cloudy, humidity 65%"
          location (if (string= unit "celsius") "C" "F")))

(deftool get-time "Get current time for a timezone"
  ((timezone :string "Timezone name" :default "UTC"))
  (format nil "Current time in ~A: ~A"
          timezone
          (multiple-value-bind (sec min hour)
              (get-decoded-time)
            (format nil "~2,'0D:~2,'0D:~2,'0D" hour min sec))))

(deftool calculate "Perform mathematical calculations"
  ((expression :string "Mathematical expression" :required-p t))
  (handler-case
      (format nil "Result: ~A" (eval (read-from-string expression)))
    (error (e) (format nil "Error: ~A" e))))

;; Create plugin grouping tools
(defplugin utility-plugin "Utility tools for weather, time, and math"
  get-weather
  get-time
  calculate)

;; Create kernel with plugin
(defvar *kernel*
  (make-kernel
    :service *service*
    :plugins '(utility-plugin)))

;; Create agent
(defvar *agent*
  (make-kernel-agent *kernel*
    :name "utility-bot"
    :system-prompt "You are a helpful assistant with access to weather, time, and calculation tools."))

;; Use the agent
(agent-chat *agent* "What's the weather in Tokyo?")
;; Agent will call get-weather tool and respond

(agent-chat *agent* "What's 15 * 23 + 7?")
;; Agent will call calculate tool and respond

(agent-chat *agent* "What time is it in New York?")
;; Agent will call get-time tool and respond
```

### ReAct Agent

Agent that thinks step-by-step:

```lisp
(defpackage :example-react
  (:use :cl)
  (:import-from :cl-agent.kernel
                :deftool :defplugin :make-kernel)
  (:import-from :cl-agent.simpleagent
                :make-kernel-agent :agent-chat))

(in-package :example-react)

;; Define research tools
(deftool web-search "Search the web for information"
  ((query :string "Search query" :required-p t))
  ;; Simulated search results
  (format nil "Search results for '~A':~%1. Wikipedia article...~%2. News article..."
          query))

(deftool read-url "Read content from a URL"
  ((url :string "URL to read" :required-p t))
  (format nil "Content from ~A: [Article content here...]" url))

(defplugin research-plugin "Web research tools"
  web-search
  read-url)

;; ReAct system prompt
(defvar *react-prompt*
  "You are a research assistant that thinks step-by-step.

For each question, follow this pattern:
1. Thought: Think about what you need to find
2. Action: Use a tool to gather information
3. Observation: Analyze the tool result
4. Repeat if needed
5. Final Answer: Provide your conclusion

Always explain your reasoning.")

;; Create ReAct agent
(defvar *react-agent*
  (make-kernel-agent *kernel*
    :name "react-researcher"
    :system-prompt *react-prompt*
    :settings '(:max-iterations 10)))

;; Use for research tasks
(agent-chat *react-agent*
  "What is the capital of France and what is its population?")
;; Agent will:
;; 1. Think about what to search
;; 2. Search for "capital of France"
;; 3. Search for "Paris population"
;; 4. Combine results and answer
```

### Agent with Memory Persistence

Agent that remembers conversations:

```lisp
(defpackage :example-memory
  (:use :cl)
  (:import-from :cl-agent.memory
                :make-agent-memory
                :make-memory-store-backend
                :make-sqlite-store-backend
                :am-add-message
                :am-get-messages
                :am-save-checkpoint
                :am-load-checkpoint)
  (:import-from :cl-agent.kernel :make-kernel)
  (:import-from :cl-agent.simpleagent
                :make-kernel-agent :agent-chat))

(in-package :example-memory)

;; ============================================
;; Example 1: In-Memory Storage (Session-based)
;; ============================================

(defvar *memory*
  (make-agent-memory
    :context-store (make-memory-store-backend)
    :default-thread-id "session-1"))

;; Create agent with memory
(defvar *agent*
  (make-kernel-agent *kernel*
    :name "memory-bot"
    :memory *memory*
    :system-prompt "You are a helpful assistant. Remember user preferences."))

;; Conversation with memory
(agent-chat *agent* "My name is Alice and I prefer formal language.")
(agent-chat *agent* "What's my name?")
;; => "Your name is Alice."

(agent-chat *agent* "How should you address me?")
;; => "I should address you formally, Alice."

;; ============================================
;; Example 2: SQLite Persistence (Long-term)
;; ============================================

(defvar *persistent-memory*
  (make-agent-memory
    :context-store (make-memory-store-backend)
    :persistent-store (make-sqlite-store-backend
                        :db-path "/path/to/agent-memory.db")
    :default-thread-id "user-123"
    :auto-archive t))

(defvar *persistent-agent*
  (make-kernel-agent *kernel*
    :name "persistent-bot"
    :memory *persistent-memory*
    :system-prompt "You remember all past conversations with this user."))

;; First session
(agent-chat *persistent-agent* "I'm learning Common Lisp")
(agent-chat *persistent-agent* "My favorite editor is Emacs")

;; Save state before closing
(am-save-checkpoint *persistent-memory* "user-123"
  '(:last-topic "Common Lisp"
    :preferences (:editor "Emacs")))

;; ... Application restarts ...

;; Later session - restore from checkpoint
(let ((checkpoint (am-load-checkpoint *persistent-memory* "user-123")))
  (format t "Last topic: ~A~%"
          (getf (checkpoint-state checkpoint) :last-topic)))

;; Continue conversation
(agent-chat *persistent-agent* "What was I learning?")
;; => "You were learning Common Lisp!"

;; ============================================
;; Example 3: Multi-Thread Memory
;; ============================================

;; Different threads for different contexts
(am-add-message *memory* "work-thread" :user "Discuss project deadlines")
(am-add-message *memory* "personal-thread" :user "Plan weekend activities")

;; Switch between threads
(agent-chat *agent* "Continue our work discussion"
  :thread-id "work-thread")

(agent-chat *agent* "What about my weekend plans?"
  :thread-id "personal-thread")

;; ============================================
;; Example 4: Checkpoint and Restore
;; ============================================

;; Save checkpoint with full state
(defvar *checkpoint-id*
  (am-save-checkpoint *memory* "session-1"
    '(:conversation-summary "User is Alice, prefers formal language"
      :user-facts ((:name "Alice")
                   (:preference "formal"))
      :last-interaction-time "2024-01-15T10:30:00Z")))

;; List all messages in thread
(let ((messages (am-get-messages *memory* "session-1")))
  (dolist (msg messages)
    (format t "~A: ~A~%"
            (memory-message-role msg)
            (memory-message-content msg))))

;; Restore from checkpoint
(let ((checkpoint (am-load-checkpoint *memory* *checkpoint-id*)))
  (format t "Restored state: ~A~%" (checkpoint-state checkpoint)))
```

### RAG-Enhanced Agent

Agent with document retrieval:

```lisp
(defpackage :example-rag
  (:use :cl)
  (:import-from :cl-agent.rag
                :make-rag-pipeline
                :make-text-splitter
                :make-vector-store
                :make-local-embeddings
                :vector-store-add-document
                :rag-query)
  (:import-from :cl-agent.kernel
                :make-kernel :make-filter)
  (:import-from :cl-agent.simpleagent
                :make-kernel-agent :agent-chat))

(in-package :example-rag)

;; 1. Setup RAG components
(defvar *embeddings* (make-local-embeddings))
(defvar *vector-store* (make-vector-store))
(defvar *splitter* (make-text-splitter :chunk-size 500 :chunk-overlap 50))

;; 2. Create RAG pipeline
(defvar *rag*
  (make-rag-pipeline
    :embeddings-model *embeddings*
    :vector-store *vector-store*
    :splitter *splitter*))

;; 3. Index some documents
(defun index-document (content metadata)
  (let ((embedding (embed *embeddings* content)))
    (vector-store-add-document *vector-store*
      content embedding :metadata metadata)))

;; Index sample documents
(index-document
  "Common Lisp is a dialect of the Lisp programming language.
   It was standardized by ANSI in 1994. Common Lisp is known for
   its powerful macro system and dynamic typing."
  '(:source "lisp-intro.txt" :topic "programming"))

(index-document
  "SBCL (Steel Bank Common Lisp) is a high-performance
   Common Lisp compiler. It is free software and runs on
   multiple platforms including Linux, macOS, and Windows."
  '(:source "sbcl-docs.txt" :topic "implementations"))

;; 4. Create RAG filter for kernel
(defvar *rag-filter*
  (make-filter
    :type :pre-chat
    :name "rag-context"
    :fn (lambda (ctx next)
          ;; Retrieve relevant context before LLM call
          (let* ((query (context-get-variable ctx "user-message"))
                 (results (rag-retrieve *rag* query :top-k 3)))
            (context-set-variable ctx "rag-context" results))
          (funcall next ctx))))

;; 5. Create kernel with RAG filter
(defvar *kernel*
  (make-kernel
    :service *service*
    :filters (list *rag-filter*)))

;; 6. Create RAG-enhanced agent
(defvar *rag-agent*
  (make-kernel-agent *kernel*
    :name "rag-assistant"
    :system-prompt "You are a helpful assistant. Use the provided context to answer questions accurately. If the context doesn't contain relevant information, say so."))

;; 7. Query with RAG
(agent-chat *rag-agent* "What is Common Lisp?")
;; Agent will retrieve relevant chunks and answer based on them

(agent-chat *rag-agent* "What is SBCL?")
;; Agent will find SBCL documentation and respond
```

### Multi-Turn Conversation Agent

Agent for complex multi-turn dialogues:

```lisp
(defpackage :example-multiturn
  (:use :cl)
  (:import-from :cl-agent.memory
                :make-agent-memory
                :make-memory-store-backend
                :am-add-message
                :am-get-last-n-messages)
  (:import-from :cl-agent.kernel :make-kernel)
  (:import-from :cl-agent.simpleagent
                :make-kernel-agent :agent-chat))

(in-package :example-multiturn)

;; Create memory with summary buffer for long conversations
(defvar *memory*
  (make-agent-memory
    :context-store (make-memory-store-backend)
    :default-thread-id "conversation-1"
    :config '(:max-messages 50
              :summarize-after 20)))

;; Create conversational agent
(defvar *conv-agent*
  (make-kernel-agent *kernel*
    :name "conversation-agent"
    :memory *memory*
    :system-prompt "You are having a natural conversation. Remember previous context and maintain coherent dialogue."))

;; Multi-turn conversation
(agent-chat *conv-agent* "I want to plan a trip to Japan")
;; => "That sounds exciting! When are you thinking of going?"

(agent-chat *conv-agent* "Maybe in April for cherry blossom season")
;; => "April is perfect for cherry blossoms! Have you decided on which cities?"

(agent-chat *conv-agent* "I'm thinking Tokyo and Kyoto")
;; => "Great choices! Tokyo for modern Japan and Kyoto for traditional culture..."

(agent-chat *conv-agent* "What should I see in the first city?")
;; => "In Tokyo, I'd recommend..." (Agent remembers "first city" = Tokyo)

;; Get conversation history
(let ((recent (am-get-last-n-messages *memory* "conversation-1" 5)))
  (dolist (msg recent)
    (format t "~A: ~A~%~%"
            (memory-message-role msg)
            (memory-message-content msg))))
```

---

## Memory Persistence

### In-Memory Storage

Fast, session-based storage:

```lisp
(defvar *memory-store* (make-memory-store-backend))

;; Store data
(store-put *memory-store* '("users") "alice" '(:name "Alice" :age 30))
(store-put *memory-store* '("users") "bob" '(:name "Bob" :age 25))

;; Retrieve
(store-get *memory-store* '("users") "alice")
;; => (:NAME "Alice" :AGE 30)

;; List keys
(store-list-keys *memory-store* '("users"))
;; => ("alice" "bob")

;; Delete
(store-delete *memory-store* '("users") "bob")
```

### SQLite Persistence

Durable, file-based storage:

```lisp
(defvar *sqlite-store*
  (make-sqlite-store-backend :db-path "~/.cl-agent/memory.db"))

;; Same API as memory store
(store-put *sqlite-store* '("facts") "lisp-creator" "John McCarthy")
(store-get *sqlite-store* '("facts") "lisp-creator")
;; => "John McCarthy"

;; Data persists across sessions!
```

### Checkpoints

Save and restore agent state:

```lisp
;; Save checkpoint
(let ((cp (save-checkpoint *checkpointer* "thread-1"
            '(:messages-count 50
              :summary "User discussed Japan trip planning"
              :preferences (:travel-style "cultural"
                           :budget "moderate")))))
  (format t "Saved checkpoint: ~A~%" (checkpoint-id cp)))

;; Load checkpoint
(let ((cp (load-checkpoint *checkpointer* "thread-1")))
  (when cp
    (format t "State: ~A~%" (checkpoint-state cp))
    (format t "Timestamp: ~A~%" (checkpoint-timestamp cp))))

;; List all checkpoints for a thread
(let ((checkpoints (list-checkpoints *checkpointer* :thread-id "thread-1")))
  (dolist (cp checkpoints)
    (format t "~A at ~A~%"
            (checkpoint-id cp)
            (checkpoint-timestamp cp))))

;; Create branch from checkpoint
(let ((branch-id (create-branch *checkpointer* "thread-1" "experiment-1")))
  (format t "Created branch: ~A~%" branch-id))
```

---

## Next Steps

- Read the [API Reference](API.md) for detailed documentation
- Explore the `examples/` directory for more code samples
- Check `tests/` for usage patterns
