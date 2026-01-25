# Plugin Module

[中文](README.md) | English

Enhanced tool system module providing security policies, resilience patterns, and built-in tools.

## Directory Structure

```
plugin/
├── package.lisp              # Package definition
├── security.lisp             # Security policies
├── resilience.lisp           # Resilience patterns
├── builtin/                  # Built-in tools
│   ├── file.lisp            # File operations
│   ├── http.lisp            # HTTP requests
│   ├── shell.lisp           # Shell execution
│   └── utility.lisp         # Utility tools
└── all.lisp                 # Aggregated exports
```

## Built-in Plugins

### File Plugin

File system operations:

```lisp
;; Load plugin
(use-plugin 'file-plugin)

;; Available tools
;; file-read    - Read file content
;; file-write   - Write to file
;; file-delete  - Delete file
;; file-list    - List directory contents
;; file-exists  - Check if file exists
;; file-info    - Get file information

;; Examples
(file-read "/path/to/file.txt")
(file-write "/path/to/file.txt" "content")
(file-list "/path/to/directory")
```

### HTTP Plugin

HTTP request tools:

```lisp
(use-plugin 'http-plugin)

;; Available tools
;; http-get     - GET request
;; http-post    - POST request
;; http-put     - PUT request
;; http-delete  - DELETE request

;; Examples
(http-get "https://api.example.com/data")
(http-post "https://api.example.com/data"
  :body '(:key "value")
  :headers '(("Content-Type" . "application/json")))
```

### Shell Plugin

Shell command execution (sandboxed):

```lisp
(use-plugin 'shell-plugin)

;; Available tools
;; shell-execute - Execute shell command

;; Examples (restricted by security policy)
(shell-execute "ls -la")
(shell-execute "echo 'Hello'")

;; Configure allowed commands
(configure-shell-plugin
  :allowed-commands '("ls" "cat" "echo" "grep")
  :blocked-commands '("rm" "sudo" "chmod"))
```

### Utility Plugin

General utilities:

```lisp
(use-plugin 'utility-plugin)

;; Available tools
;; calculate    - Mathematical calculation
;; format-date  - Date formatting
;; json-parse   - JSON parsing
;; json-format  - JSON formatting
;; uuid-generate - Generate UUID
;; base64-encode - Base64 encoding
;; base64-decode - Base64 decoding

;; Examples
(calculate "(+ 1 2 3)")
(format-date (get-universal-time) "YYYY-MM-DD")
(json-parse "{\"key\": \"value\"}")
```

## Security Policies

### Creating Security Policy

```lisp
(defvar *policy*
  (make-security-policy
    :rate-limit 60              ; Max requests per minute
    :timeout 30                 ; Timeout (seconds)
    :max-input-size 10000       ; Max input size (characters)
    :sandbox-enabled t          ; Enable sandbox
    :input-validation-fn #'validate-input))

;; Apply to plugin
(apply-security-policy 'file-plugin *policy*)
```

### Rate Limiting

```lisp
(defvar *rate-limiter*
  (make-rate-limiter
    :requests-per-minute 60
    :burst-size 10))

(with-rate-limit (*rate-limiter*)
  (execute-tool ...))
```

### Input Validation

```lisp
;; Define validation function
(defun validate-file-path (path)
  (and (stringp path)
       (not (search ".." path))           ; Prevent path traversal
       (not (search "~" path))            ; Forbid home directory
       (< (length path) 256)))            ; Length limit

;; Apply validation
(make-security-policy
  :input-validation-fn #'validate-file-path)
```

### Sandbox Execution

```lisp
;; Configure sandbox
(defvar *sandbox*
  (make-sandbox
    :allowed-paths '("/tmp/" "/data/")    ; Allowed access paths
    :blocked-paths '("/etc/" "/root/")    ; Blocked access paths
    :max-memory 100000000                  ; Max memory (bytes)
    :max-time 60))                         ; Max execution time (seconds)

(with-sandbox (*sandbox*)
  (file-read "/tmp/safe-file.txt"))
```

## Resilience Patterns

### Retry

```lisp
;; Basic retry
(with-retry (:attempts 3)
  (http-get url))

;; Exponential backoff
(with-retry (:attempts 5
             :backoff :exponential
             :initial-delay 1000
             :max-delay 30000)
  (external-api-call))

;; Custom retry conditions
(with-retry (:attempts 3
             :retry-on '(connection-error timeout-error)
             :on-retry (lambda (attempt error)
                         (format t "Retry #~A: ~A~%" attempt error)))
  (flaky-operation))
```

### Timeout

```lisp
;; Basic timeout
(with-timeout (30)
  (long-running-operation))

;; With callback
(with-timeout (30
               :on-timeout (lambda ()
                             (log-warning "Operation timed out")
                             :default-value))
  (long-running-operation))
```

### Circuit Breaker

```lisp
;; Create circuit breaker
(defvar *circuit-breaker*
  (make-circuit-breaker
    :failure-threshold 5        ; Failure threshold
    :success-threshold 3        ; Recovery threshold
    :timeout 60                 ; Circuit open duration (seconds)
    :on-open (lambda () (log-error "Circuit breaker opened"))
    :on-close (lambda () (log-info "Circuit breaker closed"))))

;; Use circuit breaker
(with-circuit-breaker (*circuit-breaker*)
  (external-service-call))

;; Check state
(circuit-breaker-state *circuit-breaker*)  ; => :closed / :open / :half-open
```

### Bulkhead Isolation

```lisp
;; Limit concurrency
(defvar *bulkhead*
  (make-bulkhead
    :max-concurrent 10
    :max-waiting 100))

(with-bulkhead (*bulkhead*)
  (concurrent-operation))
```

## Creating Custom Plugins

```lisp
;; Define tools
(deftool my-tool "My custom tool"
  ((param1 :string "Parameter 1" :required-p t)
   (param2 :int "Parameter 2" :default 0))
  ;; Tool implementation
  (format nil "Processing: ~A, ~A" param1 param2))

(deftool another-tool "Another tool"
  ((input :string "Input"))
  (string-upcase input))

;; Create plugin
(defplugin my-custom-plugin "My custom plugin"
  my-tool
  another-tool)

;; Apply security policy
(apply-security-policy 'my-custom-plugin
  (make-security-policy
    :rate-limit 30
    :timeout 10))

;; Use in Kernel
(make-kernel
  :service *service*
  :plugins '(my-custom-plugin file-plugin))
```

## Tool Decorators

Add functionality to existing tools:

```lisp
;; Add logging
(defun with-logging (tool-fn)
  (lambda (&rest args)
    (format t "Calling tool with args: ~A~%" args)
    (let ((result (apply tool-fn args)))
      (format t "Result: ~A~%" result)
      result)))

;; Add caching
(defun with-cache (tool-fn &key (ttl 300))
  (let ((cache (make-hash-table :test 'equal)))
    (lambda (&rest args)
      (let ((key (format nil "~A" args)))
        (or (gethash key cache)
            (setf (gethash key cache)
                  (apply tool-fn args)))))))

;; Apply decorators
(decorate-tool 'http-get
  (with-logging)
  (with-cache :ttl 60)
  (with-retry :attempts 3))
```

## Usage Examples

### Secure File Handling

```lisp
(defvar *file-policy*
  (make-security-policy
    :sandbox-enabled t
    :input-validation-fn
    (lambda (path)
      (and (stringp path)
           (uiop:subpathp path #p"/allowed/directory/")))))

(apply-security-policy 'file-plugin *file-policy*)

;; Now file operations are restricted to /allowed/directory/
(file-read "/allowed/directory/data.txt")  ; OK
(file-read "/etc/passwd")                   ; Error: path not allowed
```

### Resilient HTTP Calls

```lisp
(defvar *api-circuit-breaker*
  (make-circuit-breaker :failure-threshold 3))

(defun call-external-api (endpoint)
  (with-circuit-breaker (*api-circuit-breaker*)
    (with-retry (:attempts 3 :backoff :exponential)
      (with-timeout (30)
        (http-get endpoint)))))
```

### Combining Multiple Plugins

```lisp
(defvar *kernel*
  (make-kernel
    :service *service*
    :plugins '(file-plugin
               http-plugin
               utility-plugin
               my-custom-plugin)))

;; Agent can now use tools from all plugins
(agent-chat *agent* "Read /tmp/data.txt and send to API")
```
