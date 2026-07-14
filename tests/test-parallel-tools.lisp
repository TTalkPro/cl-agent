;;;; test-parallel-tools.lisp
;;;; CL-Agent - 并行工具执行测试（concurrent-tool-calling-manager）
;;;;
;;;; 覆盖：
;;;;   - 与顺序执行的语义等价（结果、顺序、return-direct、错误隔离）
;;;;   - 真并发（工具内 sleep，总耗时显著小于串行和）
;;;;   - 单/零工具短路顺序执行
;;;;   - 超时降级
;;;;   - 与 tool-calling-advisor 集成
;;;;   - kernel 生命周期（shutdown 幂等）

(in-package :cl-agent/tests)

(def-suite parallel-tools-suite :in cl-agent-suite
  :description "并行工具执行（concurrent-tool-calling-manager）")

(in-suite parallel-tools-suite)

;;; ============================================================
;;; 测试工具（含可控延迟与副作用）
;;; ============================================================

(cl-agent.chat:deftool pt-slow-a (&key)
  "慢工具 A（sleep 后返回）"
  (sleep 0.2)
  "A-done")

(cl-agent.chat:deftool pt-slow-b (&key)
  "慢工具 B"
  (sleep 0.2)
  "B-done")

(cl-agent.chat:deftool pt-slow-c (&key)
  "慢工具 C"
  (sleep 0.2)
  "C-done")

(cl-agent.chat:deftool pt-echo (&key text)
  "回显工具"
  (:param text :string "文本" :required t)
  (format nil "echo:~A" text))

(cl-agent.chat:deftool pt-direct (&key)
  "return-direct 工具"
  (:return-direct t)
  "direct-result")

(cl-agent.chat:deftool pt-boom (&key)
  "抛错工具"
  (error "炸了"))

(cl-agent.chat:deftool pt-never (&key)
  "永不返回（测超时）"
  (sleep 10)
  "unreachable")

(defun pt-response (&rest names)
  "构造携带多个 tool-call 的 chat-response（无参工具）"
  (cl-agent.chat:make-chat-response
   (cl-agent.chat:make-generation
    (cl-agent.chat:assistant-message
     ""
     :tool-calls (loop for name in names
                       for i from 1
                       collect (cl-agent.chat:make-tool-call
                                :id (format nil "id-~A" i) :name name)))
    :finish-reason :tool-call)))

(defun result-texts (result)
  "取 result 末尾 tool-response-message 的全部结果文本（按序）"
  (mapcar #'cl-agent.chat:tool-response-text
          (cl-agent.chat:tool-responses
           (cl-agent.chat:tool-execution-last-message result))))

;;; ============================================================
;;; 语义等价
;;; ============================================================

(test parallel-matches-sequential
  "并行结果与顺序结果一致（内容、顺序）"
  (let* ((prompt (cl-agent.chat:make-prompt "go"))
         (response (pt-response "pt_echo" "pt_echo" "pt_echo"))
         ;; 每个 echo 参数不同：改造 response
         (response2 (cl-agent.chat:make-chat-response
                     (cl-agent.chat:make-generation
                      (cl-agent.chat:assistant-message
                       ""
                       :tool-calls (list (cl-agent.chat:make-tool-call
                                          :id "1" :name "pt_echo" :arguments '(:text "x"))
                                         (cl-agent.chat:make-tool-call
                                          :id "2" :name "pt_echo" :arguments '(:text "y"))
                                         (cl-agent.chat:make-tool-call
                                          :id "3" :name "pt_echo" :arguments '(:text "z"))))
                      :finish-reason :tool-call)))
         (seq (cl-agent.chat:make-default-tool-calling-manager))
         (par (cl-agent.chat:make-concurrent-tool-calling-manager)))
    (declare (ignore response))
    (unwind-protect
         (let ((r-seq (cl-agent.chat:execute-tool-calls seq prompt response2))
               (r-par (cl-agent.chat:execute-tool-calls par prompt response2)))
           (is (equal '("echo:x" "echo:y" "echo:z") (result-texts r-seq)))
           ;; 并行保持原序
           (is (equal '("echo:x" "echo:y" "echo:z") (result-texts r-par))))
      (cl-agent.chat:shutdown-tool-calling-manager par))))

(test parallel-return-direct-union
  "任一 return-direct 工具 → result 标记 return-direct"
  (let* ((prompt (cl-agent.chat:make-prompt "go"))
         (response (pt-response "pt_echo" "pt_direct"))
         (par (cl-agent.chat:make-concurrent-tool-calling-manager)))
    (unwind-protect
         (let ((result (cl-agent.chat:execute-tool-calls par prompt
                        (cl-agent.chat:make-chat-response
                         (cl-agent.chat:make-generation
                          (cl-agent.chat:assistant-message
                           ""
                           :tool-calls (list (cl-agent.chat:make-tool-call
                                              :id "1" :name "pt_echo" :arguments '(:text "a"))
                                             (cl-agent.chat:make-tool-call
                                              :id "2" :name "pt_direct")))
                          :finish-reason :tool-call)))))
           (declare (ignore response))
           (is-true (cl-agent.chat:tool-execution-return-direct-p result)))
      (cl-agent.chat:shutdown-tool-calling-manager par))))

(test parallel-error-isolation
  "并行下单个工具报错不影响其他，错误转文本回传"
  (let* ((prompt (cl-agent.chat:make-prompt "go"))
         (response (pt-response "pt_boom" "pt_echo"))
         (response2 (cl-agent.chat:make-chat-response
                     (cl-agent.chat:make-generation
                      (cl-agent.chat:assistant-message
                       ""
                       :tool-calls (list (cl-agent.chat:make-tool-call
                                          :id "1" :name "pt_boom")
                                         (cl-agent.chat:make-tool-call
                                          :id "2" :name "pt_echo" :arguments '(:text "ok"))))
                      :finish-reason :tool-call)))
         (par (cl-agent.chat:make-concurrent-tool-calling-manager)))
    (declare (ignore response))
    (unwind-protect
         (let ((texts (result-texts
                       (cl-agent.chat:execute-tool-calls par prompt response2))))
           (is (search "错误" (first texts)))
           (is (string= "echo:ok" (second texts))))
      (cl-agent.chat:shutdown-tool-calling-manager par))))

;;; ============================================================
;;; 真并发
;;; ============================================================

(test parallel-actually-concurrent
  "三个各 sleep 0.2s 的工具并行执行，总耗时明显小于串行 0.6s"
  (let* ((prompt (cl-agent.chat:make-prompt "go"))
         (response (pt-response "pt_slow_a" "pt_slow_b" "pt_slow_c"))
         (par (cl-agent.chat:make-concurrent-tool-calling-manager :pool-size 3)))
    (unwind-protect
         (let* ((start (get-internal-real-time))
                (result (cl-agent.chat:execute-tool-calls par prompt response))
                (elapsed (/ (- (get-internal-real-time) start)
                            internal-time-units-per-second)))
           (is (equal '("A-done" "B-done" "C-done") (result-texts result)))
           ;; 串行需 ~0.6s；并行应在 0.4s 内（留足调度余量）
           (is (< elapsed 0.4)))
      (cl-agent.chat:shutdown-tool-calling-manager par))))

;;; ============================================================
;;; 短路 / 超时 / 生命周期
;;; ============================================================

(test parallel-single-tool-sequential
  "单个工具短路为顺序执行（不创建线程池）"
  (let* ((prompt (cl-agent.chat:make-prompt "go"))
         (response (pt-response "pt_echo"))
         (response2 (cl-agent.chat:make-chat-response
                     (cl-agent.chat:make-generation
                      (cl-agent.chat:assistant-message
                       "" :tool-calls (list (cl-agent.chat:make-tool-call
                                             :id "1" :name "pt_echo"
                                             :arguments '(:text "solo"))))
                      :finish-reason :tool-call)))
         (par (cl-agent.chat:make-concurrent-tool-calling-manager)))
    (declare (ignore response))
    (unwind-protect
         (progn
           (is (equal '("echo:solo")
                      (result-texts
                       (cl-agent.chat:execute-tool-calls par prompt response2))))
           ;; 单工具走 call-next-method，未触发内核创建
           (is (null (cl-agent.chat::manager-kernel par))))
      (cl-agent.chat:shutdown-tool-calling-manager par))))

(test parallel-timeout
  "超时工具返回错误文本，不阻塞其余工具"
  (let* ((prompt (cl-agent.chat:make-prompt "go"))
         (response (pt-response "pt_never" "pt_echo"))
         (response2 (cl-agent.chat:make-chat-response
                     (cl-agent.chat:make-generation
                      (cl-agent.chat:assistant-message
                       ""
                       :tool-calls (list (cl-agent.chat:make-tool-call
                                          :id "1" :name "pt_never")
                                         (cl-agent.chat:make-tool-call
                                          :id "2" :name "pt_echo" :arguments '(:text "fast"))))
                      :finish-reason :tool-call)))
         (par (cl-agent.chat:make-concurrent-tool-calling-manager
               :pool-size 2 :timeout 0.3)))
    (declare (ignore response))
    (unwind-protect
         (let ((texts (result-texts
                       (cl-agent.chat:execute-tool-calls par prompt response2))))
           (is (search "超时" (first texts)))
           (is (string= "echo:fast" (second texts))))
      (cl-agent.chat:shutdown-tool-calling-manager par))))

(test parallel-shutdown-idempotent
  "shutdown 幂等：创建后关闭返回 T，重复关闭返回 NIL"
  (let ((par (cl-agent.chat:make-concurrent-tool-calling-manager)))
    ;; 未使用时关闭无内核 → NIL
    (is-false (cl-agent.chat:shutdown-tool-calling-manager par))
    ;; 触发一次并行执行创建内核
    (cl-agent.chat:execute-tool-calls
     par (cl-agent.chat:make-prompt "go")
     (pt-response "pt_echo" "pt_echo"))
    (is-true (cl-agent.chat:shutdown-tool-calling-manager par))
    (is-false (cl-agent.chat:shutdown-tool-calling-manager par))))

;;; ============================================================
;;; 与 tool-calling-advisor 集成
;;; ============================================================

(defun pt-multi-tool-llm-response (&rest name-arg-pairs)
  "构造 SPI 级 llm-response，携带多个 tool-call
（NAME-ARG-PAIRS: (name (\"k\" . v)...) ...）"
  (cl-agent.core:make-llm-response
   :content ""
   :finish-reason :tool-call
   :model "seq-model"
   :tool-calls (loop for (name args) in name-arg-pairs
                     for i from 1
                     collect (let ((ht (make-hash-table :test #'equal)))
                               (loop for (k . v) in args do (setf (gethash k ht) v))
                               (list :id (format nil "id-~A" i)
                                     :name name :arguments ht)))))

(test parallel-via-advisor
  "并行 manager 经 tool-calling-advisor 驱动完整工具循环"
  (let* ((provider (make-seq-provider
                    ;; 一轮里请求两个工具
                    (pt-multi-tool-llm-response
                     '("pt_echo" (("text" . "p")))
                     '("pt_echo" (("text" . "q"))))
                    (text-response "汇总完成")))
         (par (cl-agent.chat:make-concurrent-tool-calling-manager))
         (client (cl-agent.client:make-chat-client
                  (cl-agent.chat:make-provider-chat-model provider)
                  :advisors (list (cl-agent.client:make-tool-calling-advisor
                                   :manager par)))))
    (unwind-protect
         (progn
           (is (string= "汇总完成"
                        (cl-agent.client:chat client
                          (:user "并行调两个工具")
                          (:tools 'pt-echo))))
           ;; 第二轮请求应包含两条工具结果
           (let* ((second-req (second (reverse (seq-provider-requests provider))))
                  (tool-msgs (remove-if-not
                              (lambda (m) (eq :tool (getf m :role)))
                              (getf second-req :messages))))
             (is (= 2 (length tool-msgs)))))
      (cl-agent.chat:shutdown-tool-calling-manager par))))
