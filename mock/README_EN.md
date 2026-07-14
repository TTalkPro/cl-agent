# Mock Module

[中文](README.md) | English

Testing Mock implementation module providing LLM and tool simulations.

## Directory Structure

```
mock/
├── package.lisp              # Package definition
├── llm.lisp                  # Mock LLM
└── tools.lisp                # Mock tools
```

## Mock LLM

### Basic Usage

```lisp
;; Create Mock LLM
(defvar *mock-llm* (make-mock-llm))

;; Set predefined responses
(mock-llm-set-response *mock-llm*
  "Hello"
  "Hello! How can I help you?")

;; Use
(mock-llm-chat *mock-llm* "Hello")
;; => "Hello! How can I help you?"
```

### Response Modes

```lisp
;; Fixed response
(make-mock-llm :mode :fixed
               :response "Fixed reply")

;; Echo mode
(make-mock-llm :mode :echo)
(mock-llm-chat *mock-llm* "Hello")
;; => "Echo: Hello"

;; Sequence response
(make-mock-llm :mode :sequence
               :responses '("First reply" "Second reply" "Third reply"))

;; Function response
(make-mock-llm :mode :function
               :handler (lambda (messages)
                          (format nil "Received ~A messages" (length messages))))
```

### Tool Call Simulation

```lisp
;; Set tool call response
(mock-llm-set-tool-call *mock-llm*
  "weather"
  '(:tool-calls ((:id "call_1"
                  :name "get-weather"
                  :arguments (:city "Beijing")))))

;; Use
(mock-llm-chat *mock-llm* "What's the weather in Beijing?")
;; => {:tool-calls [...]}
```

### Delay Simulation

```lisp
;; Simulate network delay
(make-mock-llm :delay 1000)  ; 1 second delay

;; Random delay
(make-mock-llm :delay '(500 . 2000))  ; 500-2000 ms
```

### Error Simulation

```lisp
;; Simulate errors
(mock-llm-set-error *mock-llm* "error-trigger"
  (make-condition 'llm-error :message "API Error"))

;; Random errors
(make-mock-llm :error-rate 0.1)  ; 10% error rate
```

## Mock Tools

### Creating Mock Tools

```lisp
;; Fixed return value
(defvar *mock-weather*
  (make-mock-tool "get-weather"
    :response "Sunny, 25°C"))

;; Function return value
(defvar *mock-calculator*
  (make-mock-tool "calculate"
    :handler (lambda (args)
               (eval (read-from-string (getf args :expression))))))
```

### Call Recording

```lisp
;; Get call history
(mock-tool-calls *mock-weather*)
;; => ((:args (:city "Beijing") :time "...")
;;     (:args (:city "Shanghai") :time "..."))

;; Clear records
(mock-tool-clear-calls *mock-weather*)

;; Verify calls
(mock-tool-called-p *mock-weather*)  ; => T
(mock-tool-called-with *mock-weather* '(:city "Beijing"))  ; => T
(mock-tool-call-count *mock-weather*)  ; => 2
```

## Using in Tests

```lisp
;; Adapt the mock LLM into a ChatModel
(deftest test-client-with-mock
  (let* ((mock-llm (cl-agent.mock:make-mock-llm))
         (model (cl-agent.chat:make-provider-chat-model mock-llm))
         (client (cl-agent.client:make-chat-client model)))
    (is (stringp (cl-agent.client:chat client "Hello")))))

;; For precise response sequencing, specialize llm-chat directly
;; (see seq-provider in tests/suite.lisp): each call pops a canned
;; llm-response, letting you assert tool-loop rounds and the exact
;; messages sent to the model.
```

## Examples

### Full test scenario (tool loop)

```lisp
(deftest test-weather-tools
  ;; First round returns a tool call, second the final text
  (let* ((provider (make-seq-provider
                    (tool-call-response "get_weather" '(("city" . "Beijing")))
                    (text-response "Sunny in Beijing, 25°C")))
         (model (cl-agent.chat:make-provider-chat-model provider))
         (client (cl-agent.client:make-chat-client model)))
    (is (search "25°C"
                (cl-agent.client:chat client
                  (:user "Weather in Beijing?")
                  (:tools 'get-weather))))))
```

### Streaming Response Simulation

```lisp
(make-mock-llm :mode :stream
               :tokens '("Hello" "!" " " "I" " am" " an" " assistant" "."))

(mock-llm-chat-stream *mock-llm* messages
  :on-token (lambda (token)
              (format t "~A" token)))
```
