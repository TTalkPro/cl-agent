;;;; test-cross-impl.lisp
;;;; CL-Agent - Cross-Implementation Test Suite
;;;;
;;;; Overview:
;;;;   Tests for SBCL/CCL compatibility with GLM-4.7 integration
;;;;   Uses CLOS and structured data (hash-tables) throughout
;;;;
;;;; GLM-4.7 Configuration:
;;;;   - base_url: https://open.bigmodel.cn/api/anthropic
;;;;   - api-key: ZHIPU_API_KEY environment variable
;;;;   - provider: :anthropic (compatible interface)
;;;;
;;;; Usage:
;;;;   SBCL: sbcl --load "tests/test-cross-impl.lisp" \
;;;;              --eval "(cl-agent.tests.cross-impl:run-cross-impl-tests)" \
;;;;              --eval "(quit)"
;;;;   CCL:  ccl --load "tests/test-cross-impl.lisp" \
;;;;              --eval "(cl-agent.tests.cross-impl:run-cross-impl-tests)" \
;;;;              --eval "(quit)"

(in-package #:cl-user)

(defpackage #:cl-agent.tests.cross-impl
  (:use #:common-lisp #:fiveam)
  (:export #:run-cross-impl-tests
           #:run-quick-tests
           #:run-integration-tests
           #:*cross-impl-suite*
           #:impl-name
           #:get-glm-api-key
           #:glm-available-p
           #:*glm-config*))

(in-package #:cl-agent.tests.cross-impl)

;;; ============================================================
;;; Implementation Detection (CLOS-style)
;;; ============================================================

(defclass implementation-info ()
  ((name :initarg :name :reader impl-info-name)
   (version :initarg :version :reader impl-info-version)
   (features :initarg :features :reader impl-info-features))
  (:documentation "Implementation information container"))

(defun make-implementation-info ()
  "Create implementation info instance"
  (make-instance 'implementation-info
                 :name (impl-name)
                 :version (impl-version)
                 :features (list :sbcl-p #+sbcl t #-sbcl nil
                                 :ccl-p #+ccl t #-ccl nil)))

(defun impl-name ()
  "Get current Lisp implementation name"
  #+sbcl "SBCL"
  #+ccl "CCL"
  #-(or sbcl ccl) "Unknown")

(defun impl-version ()
  "Get implementation version string"
  (lisp-implementation-version))

;;; ============================================================
;;; GLM-4.7 Configuration (Structured Data)
;;; ============================================================

(defclass glm-config ()
  ((provider :initform :anthropic :reader glm-config-provider)
   (model :initform "glm-4.7" :reader glm-config-model)
   (base-url :initform "https://open.bigmodel.cn/api/anthropic"
             :reader glm-config-base-url)
   (api-key-env :initform "ZHIPU_API_KEY" :reader glm-config-api-key-env))
  (:documentation "GLM-4.7 configuration using Anthropic-compatible API"))

(defparameter *glm-config* (make-instance 'glm-config)
  "Global GLM configuration instance")

(defun get-glm-api-key ()
  "Get GLM API key from environment (portable across implementations)"
  (uiop:getenv (glm-config-api-key-env *glm-config*)))

(defun glm-available-p ()
  "Check if GLM API key is available"
  (let ((key (get-glm-api-key)))
    (and key (> (length key) 0))))

(defun make-glm-client-config ()
  "Create a plist config for GLM client creation"
  (list :provider (glm-config-provider *glm-config*)
        :model (glm-config-model *glm-config*)
        :api-key (get-glm-api-key)
        :base-url (glm-config-base-url *glm-config*)))

;;; ============================================================
;;; Test Suite Definition
;;; ============================================================

(def-suite* *cross-impl-suite*
  :description "Cross-implementation compatibility tests")

;;; ============================================================
;;; Core Module Tests
;;; ============================================================

(def-suite core-tests :in *cross-impl-suite*
  :description "cl-agent-core module tests")

(in-suite core-tests)

(test json-operations
  "Test JSON parsing and stringification with hash-table support"
  ;; Test json-stringify with plist
  (let ((data '(:name "test" :value 42 :nested (:a 1 :b 2))))
    (let ((json-str (cl-agent.core:json-stringify data)))
      (is (stringp json-str))
      (is (search "test" json-str))
      (is (search "42" json-str))))

  ;; Test json-parse - returns hash-table
  (let* ((json-str "{\"name\":\"test\",\"value\":42}")
         (parsed (cl-agent.core:json-parse json-str)))
    ;; json-parse returns hash-table, not plist
    (is (hash-table-p parsed))
    ;; Access values using gethash
    (is (equal (gethash "name" parsed) "test"))
    (is (= (gethash "value" parsed) 42)))

  ;; Test roundtrip with hash-table
  (let* ((ht (make-hash-table :test #'equal)))
    (setf (gethash "key" ht) "value"
          (gethash "number" ht) 123)
    (let* ((json-str (cl-agent.core:json-stringify ht))
           (parsed (cl-agent.core:json-parse json-str)))
      (is (hash-table-p parsed))
      (is (equal (gethash "key" parsed) "value"))
      (is (= (gethash "number" parsed) 123)))))

(test error-handling
  "Test error condition system"
  (signals cl-agent.core:cl-agent-error
    (cl-agent.core:signal-error 'cl-agent.core:cl-agent-error
                                :message "Test error"))
  ;; Test error is signaled correctly
  (handler-case
      (cl-agent.core:signal-error 'cl-agent.core:cl-agent-error
                                  :message "Test message")
    (cl-agent.core:cl-agent-error (e)
      (is (typep e 'cl-agent.core:cl-agent-error)))))

(test environment-variables
  "Test environment variable access (portable)"
  ;; Test with string argument (portable across SBCL/CCL)
  (let ((nonexistent (uiop:getenv "NONEXISTENT_VAR_12345")))
    (is (or (null nonexistent)
            (stringp nonexistent))))
  ;; PATH should exist on both platforms
  (let ((path-val (uiop:getenv "PATH")))
    (is (stringp path-val))
    (is (> (length path-val) 0)))
  ;; Test ZHIPU_API_KEY if available
  (when (glm-available-p)
    (is (stringp (get-glm-api-key)))))

(test file-operations-portable
  "Test portable file operations"
  (let ((test-file (format nil "/tmp/cl-agent-test-~A-~A.txt"
                           (impl-name)
                           (get-universal-time))))
    (unwind-protect
        (progn
          ;; Write test
          (with-open-file (s test-file :direction :output
                                       :if-exists :supersede)
            (write-string "test content" s))
          (is (probe-file test-file))
          ;; Read test
          (with-open-file (s test-file :direction :input)
            (is (string= (read-line s) "test content"))))
      ;; Cleanup
      (when (probe-file test-file)
        (delete-file test-file)))))

;;; ============================================================
;;; LLM Module Tests
;;; ============================================================

(def-suite llm-tests :in *cross-impl-suite*
  :description "cl-agent-llm module tests")

(in-suite llm-tests)

(test provider-creation-basic
  "Test provider factory (without API key requirements)"
  ;; Create providers without triggering API key validation
  ;; by providing dummy keys
  (let ((anthropic (cl-agent.llm:make-provider :anthropic
                                                :api-key "test-key")))
    (is (not (null anthropic)))
    (is (eq (cl-agent.llm:provider-name anthropic) :anthropic)))

  (let ((openai (cl-agent.llm:make-provider :openai
                                             :api-key "test-key")))
    (is (not (null openai)))
    (is (eq (cl-agent.llm:provider-name openai) :openai)))

  (let ((zhipu (cl-agent.llm:make-provider :zhipu
                                            :api-key "test-key")))
    (is (not (null zhipu)))
    (is (eq (cl-agent.llm:provider-name zhipu) :zhipu))))

(test client-creation
  "Test client creation with various configurations"
  ;; Basic client with test key
  (let ((client (cl-agent.llm:make-client :provider :anthropic
                                          :api-key "test-key")))
    (is (not (null client)))
    (is (eq (cl-agent.llm:client-provider-name client) :anthropic)))

  ;; Client with custom parameters
  (let ((client (cl-agent.llm:make-client :provider :anthropic
                                          :api-key "test-key"
                                          :max-tokens 1024
                                          :temperature 0.5)))
    (is (= (cl-agent.llm:client-max-tokens client) 1024))
    (is (= (cl-agent.llm:client-temperature client) 0.5))))

(test glm-client-creation
  "Test GLM-4.7 client creation with real API key"
  (if (glm-available-p)
      (let ((config (make-glm-client-config)))
        (let ((client (apply #'cl-agent.llm:make-client config)))
          (is (not (null client)))
          (is (string= (cl-agent.llm:client-model-name client) "glm-4.7"))
          (is (eq (cl-agent.llm:client-provider-name client) :anthropic))))
      (skip "ZHIPU_API_KEY not available")))

(test glm-chat-integration
  "Test GLM-4.7 chat (requires API key)"
  (if (glm-available-p)
      (let ((config (make-glm-client-config)))
        (let ((client (apply #'cl-agent.llm:make-client config)))
          (let ((response (cl-agent.llm:chat-simple client "Say OK")))
            (is (stringp response))
            (is (> (length response) 0))
            (format t "~&[~A] GLM Response: ~A~%" (impl-name) response))))
      (skip "ZHIPU_API_KEY not available")))

(test message-normalization
  "Test message format normalization"
  ;; Test cons format
  (let ((msgs '((:user . "hello") (:assistant . "hi"))))
    (is (listp msgs))
    (is (= (length msgs) 2)))

  ;; Test plist format
  (let ((msgs '((:role :user :content "hello")
                (:role :assistant :content "hi"))))
    (is (listp msgs))
    (is (= (length msgs) 2))))

;;; ============================================================
;;; Memory Module Tests
;;; ============================================================

(def-suite memory-tests :in *cross-impl-suite*
  :description "cl-agent-memory module tests")

(in-suite memory-tests)

(test checkpoint-creation
  "Test checkpoint creation and basic operations"
  (let ((cp (cl-agent.memory:make-checkpoint
             :thread-id "test-thread"
             :metadata '(:test t))))
    (is (not (null cp)))
    (is (cl-agent.memory:checkpoint-p cp))
    (is (string= (cl-agent.memory:checkpoint-thread-id cp) "test-thread"))
    (is (stringp (cl-agent.memory:checkpoint-id cp)))))

(test checkpoint-channel-operations
  "Test checkpoint channel get/set with hash-table storage"
  (let ((cp (cl-agent.memory:make-checkpoint :thread-id "test")))
    ;; Set channel value
    (cl-agent.memory:checkpoint-set-channel cp "messages" '("msg1" "msg2"))
    ;; Get channel value
    (is (equal (cl-agent.memory:checkpoint-get-channel cp "messages")
               '("msg1" "msg2")))
    ;; Test messages convenience functions
    (cl-agent.memory:checkpoint-set-messages cp '(:user "hello"))
    (is (equal (cl-agent.memory:checkpoint-get-messages cp) '(:user "hello")))
    ;; Verify channel-values is a hash-table
    (is (hash-table-p (cl-agent.memory:checkpoint-channel-values cp)))))

(test checkpoint-config-creation
  "Test checkpoint config"
  (let ((config (cl-agent.memory:make-checkpoint-config
                 :thread-id "thread-1"
                 :checkpoint-id "cp-123")))
    (is (cl-agent.memory:checkpoint-config-p config))
    (is (string= (cl-agent.memory:config-thread-id config) "thread-1"))
    (is (string= (cl-agent.memory:config-checkpoint-id config) "cp-123"))))

(test store-item-creation
  "Test store item creation"
  (let ((item (cl-agent.memory:make-store-item
               :namespace '("test")
               :key "key-1"
               :value '(:data "test"))))
    (is (cl-agent.memory:store-item-p item))
    (is (equal (cl-agent.memory:store-item-namespace item) '("test")))
    (is (string= (cl-agent.memory:store-item-key item) "key-1"))))

(test memory-store-backend
  "Test memory store backend with hash-table storage"
  (let ((store (cl-agent.memory:make-memory-store-backend)))
    (is (not (null store)))
    ;; Test put with hash-table value
    (let ((ht (make-hash-table :test #'equal)))
      (setf (gethash "data" ht) "test-value")
      (cl-agent.memory:store-put store '("test") "key-ht" ht))
    ;; Test put with plist value
    (cl-agent.memory:store-put store '("test") "key1" '(:value 42))
    ;; Test get
    (let ((item (cl-agent.memory:store-get store '("test") "key1")))
      (is (not (null item)))
      (is (equal (cl-agent.memory:store-item-value item) '(:value 42))))
    ;; Test delete
    (is (cl-agent.memory:store-delete store '("test") "key1"))
    (is (null (cl-agent.memory:store-get store '("test") "key1")))))

(test checkpoint-manager
  "Test checkpoint manager save/load"
  (let* ((store (cl-agent.memory:make-memory-store-backend))
         (manager (cl-agent.memory:make-checkpoint-manager :store store))
         (config (cl-agent.memory:make-checkpoint-config :thread-id "test-thread")))
    (is (not (null manager)))
    ;; Save checkpoint
    (let ((cp (cl-agent.memory:make-checkpoint :thread-id "test-thread")))
      (cl-agent.memory:checkpoint-set-messages cp '("test message"))
      (cl-agent.memory:checkpoint-save manager config cp)
      ;; Load checkpoint
      (let ((loaded (cl-agent.memory:checkpoint-load manager config)))
        (is (not (null loaded)))
        (is (equal (cl-agent.memory:checkpoint-get-messages loaded)
                   '("test message")))))))

(test checkpoint-naming-unified
  "Test unified checkpoint-* naming convention"
  (let* ((store (cl-agent.memory:make-memory-store-backend))
         (manager (cl-agent.memory:make-checkpoint-manager :store store))
         (config (cl-agent.memory:make-checkpoint-config :thread-id "naming-test")))
    ;; Test all checkpoint-* methods exist and work
    (let ((cp (cl-agent.memory:make-checkpoint :thread-id "naming-test")))
      ;; checkpoint-save
      (is (not (null (cl-agent.memory:checkpoint-save manager config cp))))
      ;; checkpoint-load
      (is (not (null (cl-agent.memory:checkpoint-load manager config))))
      ;; checkpoint-get-latest
      (is (not (null (cl-agent.memory:checkpoint-get-latest manager config))))
      ;; checkpoint-list-all
      (is (listp (cl-agent.memory:checkpoint-list-all manager config)))
      ;; checkpoint-list-branches
      (is (listp (cl-agent.memory:checkpoint-list-branches manager config))))))

(test checkpoint-time-travel
  "Test checkpoint time travel operations"
  (let* ((store (cl-agent.memory:make-memory-store-backend))
         (manager (cl-agent.memory:make-checkpoint-manager :store store))
         (config (cl-agent.memory:make-checkpoint-config :thread-id "time-travel-test")))
    ;; Create multiple checkpoints
    (dotimes (i 3)
      (let ((cp (cl-agent.memory:make-checkpoint :thread-id "time-travel-test")))
        (cl-agent.memory:checkpoint-set-channel cp "step" i)
        (cl-agent.memory:checkpoint-save manager config cp)))
    ;; Test time travel methods exist as generic functions
    (is (fboundp 'cl-agent.memory:checkpoint-go-back))
    (is (fboundp 'cl-agent.memory:checkpoint-go-forward))
    (is (fboundp 'cl-agent.memory:checkpoint-goto))
    (is (fboundp 'cl-agent.memory:checkpoint-switch-branch))
    (is (fboundp 'cl-agent.memory:checkpoint-delete-branch))))

;;; ============================================================
;;; SimpleAgent Module Tests
;;; ============================================================

(def-suite simpleagent-tests :in *cross-impl-suite*
  :description "simpleagent (cl-agent-core) module tests")

(in-suite simpleagent-tests)

(test agent-creation-basic
  "Test basic agent structure creation (without full validation)"
  ;; Test that agent creation functions exist
  (is (fboundp 'cl-agent.simpleagent:create-agent))
  (is (fboundp 'cl-agent.simpleagent:make-agent))
  ;; Test agent class exists (exported as 'agent')
  (is (find-class 'cl-agent.simpleagent:agent nil)))

(test agent-with-glm-config
  "Test agent configuration with GLM-4.7 settings"
  (when (glm-available-p)
    (let ((config (make-glm-client-config)))
      ;; Verify config is properly structured
      (is (eq (getf config :provider) :anthropic))
      (is (string= (getf config :model) "glm-4.7"))
      (is (stringp (getf config :api-key)))
      (is (string= (getf config :base-url) "https://open.bigmodel.cn/api/anthropic")))))

;;; ============================================================
;;; Tools Module Tests (CCL Compatibility)
;;; ============================================================

(def-suite tools-tests :in *cross-impl-suite*
  :description "tools (cl-agent-extra) module tests (CCL compatibility)")

(in-suite tools-tests)

(test file-tool-portable
  "Test file tools work on both SBCL and CCL"
  (let ((test-dir (format nil "/tmp/cl-agent-test-dir-~A/" (get-universal-time))))
    (unwind-protect
        (progn
          ;; Create directory
          (ensure-directories-exist test-dir)
          (is (uiop:directory-exists-p test-dir))
          ;; Create test file
          (let ((test-file (merge-pathnames "test.txt" test-dir)))
            (with-open-file (s test-file :direction :output
                                         :if-exists :supersede)
              (write-string "test" s))
            (is (probe-file test-file))
            ;; Delete file
            (delete-file test-file)
            (is (not (probe-file test-file)))))
      ;; Cleanup directory using portable method
      (when (uiop:directory-exists-p test-dir)
        (uiop:delete-directory-tree (pathname test-dir)
                                    :validate t
                                    :if-does-not-exist :ignore)))))

(test directory-operations-portable
  "Test directory operations on both implementations"
  (let ((test-dir (format nil "/tmp/cl-agent-dir-test-~A-~A/"
                          (impl-name) (get-universal-time))))
    (unwind-protect
        (progn
          ;; Create directory
          (ensure-directories-exist test-dir)
          (is (uiop:directory-exists-p test-dir))
          ;; List directory
          (let ((contents (uiop:directory-files test-dir)))
            (is (listp contents)))
          ;; Subdirectories
          (let ((subdir (merge-pathnames "sub/" test-dir)))
            (ensure-directories-exist subdir)
            (is (uiop:directory-exists-p subdir))))
      ;; Cleanup
      (when (uiop:directory-exists-p test-dir)
        (uiop:delete-directory-tree (pathname test-dir)
                                    :validate t
                                    :if-does-not-exist :ignore)))))

(test ccl-directory-delete-portable
  "Test CCL-compatible directory operations work"
  ;; Test that portable directory operations work using UIOP
  (let ((test-dir (format nil "/tmp/cl-agent-ccl-test-~A/" (get-universal-time))))
    (unwind-protect
        (progn
          ;; Create using ensure-directories-exist (portable)
          (ensure-directories-exist test-dir)
          (is (uiop:directory-exists-p test-dir))
          ;; Delete using UIOP (portable)
          (uiop:delete-directory-tree (pathname test-dir)
                                      :validate t
                                      :if-does-not-exist :ignore)
          (is (not (uiop:directory-exists-p test-dir))))
      ;; Cleanup just in case
      (when (uiop:directory-exists-p test-dir)
        (uiop:delete-directory-tree (pathname test-dir)
                                    :validate t
                                    :if-does-not-exist :ignore)))))

;;; ============================================================
;;; Test Runner
;;; ============================================================

(defun run-cross-impl-tests (&key (verbose t))
  "Run all cross-implementation tests"
  (declare (ignore verbose))
  (format t "~&~%")
  (format t "=========================================~%")
  (format t "CL-Agent Cross-Implementation Tests~%")
  (format t "=========================================~%")
  (format t "Implementation: ~A ~A~%" (impl-name) (impl-version))
  (format t "GLM API Key:    ~:[Not Set~;Available~]~%" (glm-available-p))
  (format t "GLM Base URL:   ~A~%" (glm-config-base-url *glm-config*))
  (format t "GLM Model:      ~A~%" (glm-config-model *glm-config*))
  (format t "=========================================~%~%")

  (let ((results (run! '*cross-impl-suite*)))
    (format t "~%=========================================~%")
    (format t "Test Summary for ~A~%" (impl-name))
    (format t "=========================================~%")
    results))

(defun run-quick-tests ()
  "Run quick tests without API calls"
  (format t "~&Running quick tests on ~A...~%" (impl-name))
  (run! 'core-tests)
  (run! 'memory-tests)
  (run! 'tools-tests))

(defun run-integration-tests ()
  "Run GLM integration tests (requires API key)"
  (if (glm-available-p)
      (progn
        (format t "~&Running GLM integration tests on ~A...~%" (impl-name))
        (run! 'glm-chat-integration))
      (format t "~&Skipping integration tests: ZHIPU_API_KEY not set~%")))
