;;;; load-test.lisp
;;;; Test loading all modules in SBCL and CCL

(require :asdf)

;; Get the base directory
(defparameter *base-dir*
  (make-pathname :directory (pathname-directory *load-truename*)))

(defparameter *project-root*
  (merge-pathnames "../" *base-dir*))

;; Load quicklisp if available
(let ((ql-setup (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname))))
  (when (probe-file ql-setup)
    (load ql-setup)))

;; Add paths
(dolist (dir '("" "core/" "llm/" "memory/" "extra/" "mock/" "mcp/" "rag/" "plugin/" "protocols/"))
  (let ((path (merge-pathnames dir *project-root*)))
    (when (probe-file path)
      (pushnew path asdf:*central-registry* :test #'equal))))

(handler-case
    (progn
      (format t "~%=== Loading CL-Agent Modules ===~%~%")

      (format t "Loading cl-agent-core...~%")
      (asdf:load-system :cl-agent-core)

      (format t "Loading cl-agent-llm...~%")
      (asdf:load-system :cl-agent-llm)

      (format t "Loading cl-agent-memory...~%")
      (asdf:load-system :cl-agent-memory)

      (format t "Loading cl-agent-extra...~%")
      (asdf:load-system :cl-agent-extra)


      (format t "~%=== Testing Process Framework Symbols ===~%")
      (format t "  make-event-bus: ~A~%" (fboundp (find-symbol "MAKE-EVENT-BUS" "CL-AGENT.PROCESS")))
      (format t "  make-event: ~A~%" (fboundp (find-symbol "MAKE-EVENT" "CL-AGENT.PROCESS")))
      (format t "  make-event-queue: ~A~%" (fboundp (find-symbol "MAKE-EVENT-QUEUE" "CL-AGENT.PROCESS")))
      (format t "  event-queue-push: ~A~%" (fboundp (find-symbol "EVENT-QUEUE-PUSH" "CL-AGENT.PROCESS")))
      (format t "  event-queue-pop: ~A~%" (fboundp (find-symbol "EVENT-QUEUE-POP" "CL-AGENT.PROCESS")))
      (format t "  event-matches-p: ~A~%" (fboundp (find-symbol "EVENT-MATCHES-P" "CL-AGENT.PROCESS")))
      (format t "  make-human-loop-manager: ~A~%" (fboundp (find-symbol "MAKE-HUMAN-LOOP-MANAGER" "CL-AGENT.PROCESS")))
      (format t "  step-completed: ~A~%" (fboundp (find-symbol "STEP-COMPLETED" "CL-AGENT.PROCESS")))
      (format t "  step-failed: ~A~%" (fboundp (find-symbol "STEP-FAILED" "CL-AGENT.PROCESS")))
      (format t "  defprocess: ~A~%" (not (null (macro-function (find-symbol "DEFPROCESS" "CL-AGENT.PROCESS")))))

      (format t "~%=== Testing SimpleAgent Symbols ===~%")
      (format t "  make-process-agent: ~A~%" (fboundp (find-symbol "MAKE-PROCESS-AGENT" "CL-AGENT.SIMPLEAGENT")))
      (format t "  agent-inject-event: ~A~%" (fboundp (find-symbol "AGENT-INJECT-EVENT" "CL-AGENT.SIMPLEAGENT")))
      (format t "  agent-subscribe-event: ~A~%" (fboundp (find-symbol "AGENT-SUBSCRIBE-EVENT" "CL-AGENT.SIMPLEAGENT")))
      (format t "  agent-request-input: ~A~%" (fboundp (find-symbol "AGENT-REQUEST-INPUT" "CL-AGENT.SIMPLEAGENT")))
      (format t "  agent-submit-input: ~A~%" (fboundp (find-symbol "AGENT-SUBMIT-INPUT" "CL-AGENT.SIMPLEAGENT")))
      (format t "  agent-wait-for-approval: ~A~%" (fboundp (find-symbol "AGENT-WAIT-FOR-APPROVAL" "CL-AGENT.SIMPLEAGENT")))
      (format t "  agent-wait-for-confirmation: ~A~%" (fboundp (find-symbol "AGENT-WAIT-FOR-CONFIRMATION" "CL-AGENT.SIMPLEAGENT")))
      (format t "  agent-get-pending-inputs: ~A~%" (fboundp (find-symbol "AGENT-GET-PENDING-INPUTS" "CL-AGENT.SIMPLEAGENT")))
      (format t "  agent-start-process: ~A~%" (fboundp (find-symbol "AGENT-START-PROCESS" "CL-AGENT.SIMPLEAGENT")))
      (format t "  agent-get-process-state: ~A~%" (fboundp (find-symbol "AGENT-GET-PROCESS-STATE" "CL-AGENT.SIMPLEAGENT")))

      (format t "~%=== Quick Functionality Test ===~%")

      ;; Test event bus
      (let* ((make-bus (find-symbol "MAKE-EVENT-BUS" "CL-AGENT.PROCESS"))
             (subscribe (find-symbol "EVENT-BUS-SUBSCRIBE" "CL-AGENT.PROCESS"))
             (publish (find-symbol "EVENT-BUS-PUBLISH" "CL-AGENT.PROCESS"))
             (make-evt (find-symbol "MAKE-EVENT" "CL-AGENT.PROCESS"))
             (bus (funcall make-bus))
             (received nil))
        (funcall subscribe bus :external
          (lambda (event)
            (setf received event)))
        (funcall publish bus
          (funcall make-evt :type :external :name "test" :data "hello"))
        (format t "  Event bus test: ~A~%" (if received "PASSED" "FAILED")))

      ;; Test event queue
      (let* ((make-queue (find-symbol "MAKE-EVENT-QUEUE" "CL-AGENT.PROCESS"))
             (push-fn (find-symbol "EVENT-QUEUE-PUSH" "CL-AGENT.PROCESS"))
             (pop-fn (find-symbol "EVENT-QUEUE-POP" "CL-AGENT.PROCESS"))
             (make-evt (find-symbol "MAKE-EVENT" "CL-AGENT.PROCESS"))
             (queue (funcall make-queue)))
        (funcall push-fn queue
          (funcall make-evt :type :external :name "q1"))
        (let ((e1 (funcall pop-fn queue :timeout 0)))
          (format t "  Event queue test: ~A~%" (if e1 "PASSED" "FAILED"))))

      (format t "~%=== Load Test: PASSED ===~%"))

  (error (e)
    (format t "~%=== Load Test: FAILED ===~%")
    (format t "Error: ~A~%" e)
    (format t "Type: ~A~%" (type-of e))))
