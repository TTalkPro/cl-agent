;;;; simpleagent-usage.lisp
;;;; CL-Agent SimpleAgent Usage Examples
;;;;
;;;; This example demonstrates comprehensive usage of SimpleAgent,
;;;; including:
;;;;   - Single-turn and multi-turn dialogue
;;;;   - Tool/function calling
;;;;   - Process agent with event injection
;;;;   - Human-in-the-loop workflows
;;;;   - Memory persistence

(in-package #:cl-user)

;;; ============================================================
;;; Setup
;;; ============================================================

(defpackage #:cl-agent.examples.simpleagent
  (:use #:cl)
  (:export #:run-simpleagent-examples
           #:run-with-mock-provider
           #:run-with-glm47-provider))

(in-package #:cl-agent.examples.simpleagent)

;;; ============================================================
;;; Example 1: Single-Turn Dialogue
;;; ============================================================

(defun example-single-turn (provider)
  "Demonstrate single-turn dialogue with kernel-agent."
  (format t "~%=== Example 1: Single-Turn Dialogue ===~%")

  ;; Create kernel with provider
  (let* ((kernel (cl-agent.kernel:make-kernel :provider provider))
         (agent (cl-agent.simpleagent:make-kernel-agent kernel
                  :name "single-turn-agent"
                  :system-prompt "You are a helpful assistant. Keep responses brief.")))

    ;; Single question/answer
    (let ((response (cl-agent.simpleagent:agent-chat agent
                      "What is the capital of France?")))
      (format t "Q: What is the capital of France?~%")
      (format t "A: ~A~%~%" response))

    ;; Another independent question (no context from previous)
    (cl-agent.simpleagent:agent-reset agent :keep-system-prompt t)
    (let ((response (cl-agent.simpleagent:agent-chat agent
                      "What is 2 + 2?")))
      (format t "Q: What is 2 + 2?~%")
      (format t "A: ~A~%" response))))

;;; ============================================================
;;; Example 2: Multi-Turn Dialogue with Context
;;; ============================================================

(defun example-multi-turn (provider)
  "Demonstrate multi-turn dialogue with conversation history."
  (format t "~%=== Example 2: Multi-Turn Dialogue ===~%")

  (let* ((kernel (cl-agent.kernel:make-kernel :provider provider))
         (agent (cl-agent.simpleagent:make-kernel-agent kernel
                  :name "multi-turn-agent"
                  :system-prompt "You are a helpful assistant. Remember the conversation context.")))

    ;; First turn - introduce topic
    (format t "Turn 1:~%")
    (let ((r1 (cl-agent.simpleagent:agent-chat agent
                "My name is Alice and I like programming in Lisp.")))
      (format t "User: My name is Alice and I like programming in Lisp.~%")
      (format t "Assistant: ~A~%~%" r1))

    ;; Second turn - reference previous context
    (format t "Turn 2:~%")
    (let ((r2 (cl-agent.simpleagent:agent-chat agent
                "What is my name?")))
      (format t "User: What is my name?~%")
      (format t "Assistant: ~A~%~%" r2))

    ;; Third turn - reference previous context again
    (format t "Turn 3:~%")
    (let ((r3 (cl-agent.simpleagent:agent-chat agent
                "What programming language did I mention?")))
      (format t "User: What programming language did I mention?~%")
      (format t "Assistant: ~A~%~%" r3))

    ;; Show conversation history
    (format t "Conversation History:~%")
    (let ((history (cl-agent.simpleagent:agent-get-history agent)))
      (dolist (msg history)
        (format t "  [~A] ~A~%"
                (getf msg :role)
                (let ((content (getf msg :content)))
                  (if (> (length content) 60)
                      (format nil "~A..." (subseq content 0 60))
                      content)))))))

;;; ============================================================
;;; Example 3: Tool/Function Calling
;;; ============================================================

(defun example-tool-calling (provider)
  "Demonstrate tool/function calling with kernel-agent."
  (format t "~%=== Example 3: Tool/Function Calling ===~%")

  (let* ((kernel (cl-agent.kernel:make-kernel :provider provider))
         (agent (cl-agent.simpleagent:make-kernel-agent kernel
                  :name "tool-agent"
                  :system-prompt "You are an assistant with access to tools. Use them when appropriate.")))

    ;; Add tools to kernel
    (cl-agent.kernel:kernel-add-function kernel
      :get-weather
      (lambda (city)
        (format nil "Weather in ~A: Sunny, 22°C, Humidity 45%" city))
      :description "Get current weather for a city"
      :parameters '((:name "city" :type "string" :description "City name")))

    (cl-agent.kernel:kernel-add-function kernel
      :calculate
      (lambda (expression)
        (let ((result (eval (read-from-string expression))))
          (format nil "~A = ~A" expression result)))
      :description "Evaluate a mathematical expression"
      :parameters '((:name "expression" :type "string" :description "Math expression like (+ 1 2)")))

    (cl-agent.kernel:kernel-add-function kernel
      :get-time
      (lambda ()
        (multiple-value-bind (sec min hour day month year)
            (get-decoded-time)
          (format nil "Current time: ~4,'0D-~2,'0D-~2,'0D ~2,'0D:~2,'0D:~2,'0D"
                  year month day hour min sec)))
      :description "Get current date and time")

    ;; Set up callbacks to see tool usage
    (cl-agent.simpleagent:agent-on-tool-call agent
      (lambda (name args)
        (format t "  [Tool Call] ~A with args: ~A~%" name args)))

    (cl-agent.simpleagent:agent-on-tool-result agent
      (lambda (name result)
        (format t "  [Tool Result] ~A: ~A~%" name result)))

    ;; List available tools
    (format t "Available tools:~%")
    (dolist (func (cl-agent.kernel:kernel-get-functions kernel))
      (format t "  - ~A: ~A~%"
              (cl-agent.kernel:kernel-function-name func)
              (cl-agent.kernel:kernel-function-description func)))

    ;; Ask questions that require tools
    (format t "~%Asking about weather:~%")
    (let ((r1 (cl-agent.simpleagent:agent-chat agent
                "What's the weather like in Tokyo?")))
      (format t "Response: ~A~%~%" r1))

    (format t "Asking for calculation:~%")
    (let ((r2 (cl-agent.simpleagent:agent-chat agent
                "Calculate 15 * 23 + 42")))
      (format t "Response: ~A~%~%" r2))

    (format t "Asking for time:~%")
    (let ((r3 (cl-agent.simpleagent:agent-chat agent
                "What time is it now?")))
      (format t "Response: ~A~%" r3))))

;;; ============================================================
;;; Example 4: Process Agent with Event Injection
;;; ============================================================

(defun example-process-agent (provider)
  "Demonstrate process agent with event injection."
  (format t "~%=== Example 4: Process Agent with Events ===~%")

  (let* ((kernel (cl-agent.kernel:make-kernel :provider provider))
         (agent (cl-agent.simpleagent:make-process-agent kernel
                  :name "event-agent"
                  :system-prompt "You are an event-aware assistant.")))

    ;; Subscribe to events
    (cl-agent.simpleagent:agent-subscribe-event agent :external
      (lambda (event)
        (format t "  [Event Handler] Received external event: ~A - ~A~%"
                (cl-agent.process:event-name event)
                (cl-agent.process:event-data event))))

    (cl-agent.simpleagent:agent-subscribe-event agent :notification
      (lambda (event)
        (format t "  [Event Handler] Notification: ~A~%"
                (cl-agent.process:event-data event))))

    ;; Start the agent
    (format t "Starting process agent...~%")
    (cl-agent.simpleagent:agent-start agent)
    (sleep 0.2)  ; Let agent start

    ;; Inject events
    (format t "~%Injecting events:~%")
    (cl-agent.simpleagent:agent-inject-event agent :external "data-ready"
      :data '(:source "sensor-1" :value 42))
    (sleep 0.1)

    (cl-agent.simpleagent:agent-inject-event agent :notification "alert"
      :data "Temperature threshold exceeded")
    (sleep 0.1)

    ;; Send a message
    (format t "~%Sending message to agent:~%")
    (cl-agent.simpleagent:agent-send agent "Process the incoming data")
    (sleep 0.5)

    ;; Receive response
    (let ((response (cl-agent.simpleagent:agent-receive agent :timeout 2)))
      (when response
        (format t "Agent response: ~A~%" response)))

    ;; Check agent state
    (format t "~%Agent state: ~A~%" (cl-agent.simpleagent:agent-state agent))
    (format t "Agent running: ~A~%" (cl-agent.simpleagent:agent-running-p agent))

    ;; Stop the agent
    (format t "~%Stopping agent...~%")
    (cl-agent.simpleagent:agent-stop agent)
    (format t "Agent stopped.~%")))

;;; ============================================================
;;; Example 5: Human-in-the-Loop
;;; ============================================================

(defun example-human-loop (provider)
  "Demonstrate human-in-the-loop interaction."
  (format t "~%=== Example 5: Human-in-the-Loop ===~%")

  (let* ((kernel (cl-agent.kernel:make-kernel :provider provider))
         (agent (cl-agent.simpleagent:make-process-agent kernel
                  :name "hitl-agent"
                  :system-prompt "You are an assistant that requires approval for important actions.")))

    ;; Start agent
    (cl-agent.simpleagent:agent-start agent)
    (sleep 0.1)

    ;; Simulate a scenario requiring approval
    (format t "Simulating approval workflow...~%")

    ;; Create an approval request
    (let ((request-id (cl-agent.simpleagent:agent-request-input agent
                        :type :approval
                        :prompt "Deploy to production?"
                        :description "This will update the live system"
                        :timeout 5)))
      (format t "Created approval request: ~A~%" request-id)

      ;; Show pending requests
      (format t "Pending requests: ~A~%"
              (length (cl-agent.simpleagent:agent-get-pending-inputs agent)))

      ;; Simulate user approval (in real usage, this would come from UI)
      (format t "Simulating user approval...~%")
      (bordeaux-threads:make-thread
        (lambda ()
          (sleep 0.3)
          (cl-agent.simpleagent:agent-submit-input agent request-id
            :value "approved"
            :approved-p t
            :comment "Looks good!")))

      ;; Wait for result
      (sleep 0.5)
      (format t "After approval, pending: ~A~%"
              (length (cl-agent.simpleagent:agent-get-pending-inputs agent))))

    ;; Stop agent
    (cl-agent.simpleagent:agent-stop agent)))

;;; ============================================================
;;; Example 6: Memory Persistence
;;; ============================================================

(defun example-memory-persistence (provider)
  "Demonstrate memory persistence with agent."
  (format t "~%=== Example 6: Memory Persistence ===~%")

  (let* ((kernel (cl-agent.kernel:make-kernel :provider provider))
         (context (cl-agent.kernel:make-context))
         (agent (cl-agent.simpleagent:make-kernel-agent kernel
                  :name "memory-agent"
                  :system-prompt "You are an assistant that remembers user preferences.")))

    ;; Store information in context
    (format t "Storing user preferences in context...~%")
    (cl-agent.kernel:context-set-variable context :user-name "Bob")
    (cl-agent.kernel:context-set-variable context :preferences
      '(:theme :dark :language :en :timezone "UTC"))
    (cl-agent.kernel:context-set-variable context :facts
      '("User likes coffee" "User works in tech" "User prefers concise answers"))

    ;; Set the context on agent
    (setf (cl-agent.simpleagent:agent-context agent) context)

    ;; First session
    (format t "~%First session:~%")
    (let ((r1 (cl-agent.simpleagent:agent-chat agent
                "Remember that my favorite color is blue.")))
      (format t "User: Remember that my favorite color is blue.~%")
      (format t "Assistant: ~A~%~%" r1))

    ;; Save state
    (let ((saved-history (cl-agent.simpleagent:agent-get-history agent :include-system t))
          (saved-vars (list
                       :user-name (cl-agent.kernel:context-get-variable context :user-name)
                       :preferences (cl-agent.kernel:context-get-variable context :preferences)
                       :facts (cl-agent.kernel:context-get-variable context :facts))))

      (format t "Saved state:~%")
      (format t "  History messages: ~A~%" (length saved-history))
      (format t "  User name: ~A~%" (getf saved-vars :user-name))
      (format t "  Preferences: ~A~%" (getf saved-vars :preferences))

      ;; Simulate "persistence" - create new agent and restore
      (format t "~%Simulating session restore...~%")
      (let* ((new-kernel (cl-agent.kernel:make-kernel :provider provider))
             (new-context (cl-agent.kernel:make-context))
             (new-agent (cl-agent.simpleagent:make-kernel-agent new-kernel
                          :name "memory-agent"
                          :system-prompt "You are an assistant that remembers user preferences.")))

        ;; Restore context variables
        (cl-agent.kernel:context-set-variable new-context :user-name
          (getf saved-vars :user-name))
        (cl-agent.kernel:context-set-variable new-context :preferences
          (getf saved-vars :preferences))
        (cl-agent.kernel:context-set-variable new-context :facts
          (getf saved-vars :facts))
        (setf (cl-agent.simpleagent:agent-context new-agent) new-context)

        ;; Restore history
        (setf (cl-agent.simpleagent:agent-history new-agent)
              (reverse saved-history))

        ;; Continue conversation
        (format t "~%Restored session:~%")
        (let ((r2 (cl-agent.simpleagent:agent-chat new-agent
                    "What is my favorite color?")))
          (format t "User: What is my favorite color?~%")
          (format t "Assistant: ~A~%" r2))))))

;;; ============================================================
;;; Example 7: Streaming Response
;;; ============================================================

(defun example-streaming (provider)
  "Demonstrate streaming response."
  (format t "~%=== Example 7: Streaming Response ===~%")

  (let* ((kernel (cl-agent.kernel:make-kernel :provider provider))
         (agent (cl-agent.simpleagent:make-kernel-agent kernel
                  :name "stream-agent"
                  :system-prompt "You are a helpful assistant.")))

    (format t "Streaming response:~%")
    (format t "User: Tell me a short story.~%")
    (format t "Assistant: ")

    (let ((response (cl-agent.simpleagent:agent-chat-stream agent
                      "Tell me a short story about a cat."
                      (lambda (chunk)
                        (format t "~A" chunk)
                        (force-output)))))
      (declare (ignore response))
      (format t "~%"))))

;;; ============================================================
;;; Example 8: Agent with Callbacks
;;; ============================================================

(defun example-callbacks (provider)
  "Demonstrate agent callbacks for events."
  (format t "~%=== Example 8: Agent Callbacks ===~%")

  (let* ((kernel (cl-agent.kernel:make-kernel :provider provider))
         (agent (cl-agent.simpleagent:make-kernel-agent kernel
                  :name "callback-agent"
                  :system-prompt "You are a helpful assistant."
                  :callbacks (list
                              :on-message (lambda (msg)
                                           (format t "  [Callback] Message received: ~A~%"
                                                   (subseq msg 0 (min 40 (length msg)))))
                              :on-response (lambda (resp)
                                            (format t "  [Callback] Response generated (~A chars)~%"
                                                    (length resp)))
                              :on-error (lambda (err)
                                         (format t "  [Callback] Error: ~A~%" err))))))

    ;; Add tools
    (cl-agent.kernel:kernel-add-function kernel
      :lookup
      (lambda (term)
        (format nil "Definition of ~A: A sample definition." term))
      :description "Look up a term")

    ;; Set tool callbacks
    (cl-agent.simpleagent:agent-on-tool-call agent
      (lambda (name args)
        (format t "  [Callback] Tool call: ~A(~A)~%" name args)))

    (cl-agent.simpleagent:agent-on-tool-result agent
      (lambda (name result)
        (format t "  [Callback] Tool result: ~A -> ~A~%" name
                (subseq result 0 (min 30 (length result))))))

    ;; Chat
    (format t "Sending message with callbacks:~%")
    (let ((response (cl-agent.simpleagent:agent-chat agent
                      "Look up the term 'recursion' and explain it.")))
      (format t "~%Final response: ~A~%" response))))

;;; ============================================================
;;; Run Examples with Mock Provider
;;; ============================================================

(defun run-with-mock-provider ()
  "Run all examples with mock provider."
  (let ((provider (cl-agent.llm.providers:make-mock-provider)))
    (run-all-examples provider)))

;;; ============================================================
;;; Run Examples with GLM-4.7 Provider
;;; ============================================================

(defun run-with-glm47-provider (&key api-key (api-type :anthropic))
  "Run all examples with GLM-4.7 provider.

Parameters:
  API-KEY  - ZhiPu API key
  API-TYPE - :anthropic or :openai (default :anthropic)"
  (let ((provider
          (case api-type
            (:anthropic
             (cl-agent.llm.providers:make-anthropic-provider
               :api-key api-key
               :base-url "https://open.bigmodel.cn/api/anthropic"
               :model "glm-4.7"))
            (:openai
             (cl-agent.llm.providers:make-openai-provider
               :api-key api-key
               :base-url "https://open.bigmodel.cn/api/coding/paas/v4"
               :model "glm-4.7"))
            (otherwise
             (error "Unknown API type: ~A" api-type)))))
    (run-all-examples provider)))

;;; ============================================================
;;; Run All Examples
;;; ============================================================

(defun run-all-examples (provider)
  "Run all simpleagent examples with given provider."
  (format t "~%========================================~%")
  (format t "CL-Agent SimpleAgent Examples~%")
  (format t "========================================~%")

  (handler-case
      (progn
        (example-single-turn provider)
        (example-multi-turn provider)
        (example-tool-calling provider)
        (example-process-agent provider)
        (example-human-loop provider)
        (example-memory-persistence provider)
        ;; Skip streaming for mock provider
        ;; (example-streaming provider)
        (example-callbacks provider))
    (error (e)
      (format t "~%Error: ~A~%" e)))

  (format t "~%========================================~%")
  (format t "SimpleAgent Examples Complete~%")
  (format t "========================================~%"))

(defun run-simpleagent-examples ()
  "Run all simpleagent examples with mock provider."
  (run-with-mock-provider))
