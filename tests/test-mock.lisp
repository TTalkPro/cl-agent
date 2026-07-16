;;;; test-mock.lisp
;;;; CL-Agent - Mock LLM provider 测试
;;;;
;;;; 历史：本文件曾有 292 行、写于 plist 响应时代（cl-agent.llm:llm-chat、
;;;; (getf response :content)、cl-agent.tools 包……全都早已不存在），
;;;; 而且括号不平衡——因为它从未被列进 asd，一次都没编译过。
;;;; 现按 mock/llm.lisp 的**现行行为**重写：llm-chat 返回 llm-response
;;;; 对象，与真实 provider 同构。

(in-package :cl-agent/tests)

(def-suite mock-suite
  :in cl-agent-suite
  :description "Mock LLM provider（llm-chat SPI 实现）")

(in-suite mock-suite)

(test mock-llm-creation-and-accessors
  "创建 + 读取配置"
  (let ((mock (cl-agent.mock:make-mock-llm :response-delay 0.1 :error-rate 0.5)))
    (is (typep mock 'cl-agent.mock:mock-llm-provider))
    (is (= 0.1 (cl-agent.mock:mock-response-delay mock)))
    (is (= 0.5 (cl-agent.mock:mock-error-rate mock)))))

(test mock-llm-returns-llm-response
  "llm-chat 返回 llm-response 对象——与真实 provider 同构，
经 provider-chat-model 适配后可直接换用"
  (let* ((mock (cl-agent.mock:make-mock-llm))
         (resp (cl-agent.core:llm-chat
                mock '((:role :user :content "你好")))))
    (is (cl-agent.core:llm-response-p resp))
    (is (stringp (cl-agent.core:llm-response-content resp)))))

(test mock-llm-predefined-response
  "预定义响应：命中 prompt 时返回配置的内容"
  (let ((responses (make-hash-table :test #'equal)))
    (setf (gethash "测试提示" responses) "预定义响应")
    (let* ((mock (cl-agent.mock:make-mock-llm :responses responses))
           (resp (cl-agent.core:llm-chat
                  mock '((:role :user :content "测试提示")))))
      (is (string= "预定义响应" (cl-agent.core:llm-response-content resp))))))

(test mock-llm-predefined-tool-call
  "预定义 plist 响应可携带 tool-calls，finish-reason 自动置 :tool-call"
  (let ((responses (make-hash-table :test #'equal)))
    (setf (gethash "查天气" responses)
          (list :content ""
                :tool-calls (list (list :id "c1" :name "get_weather"
                                        :arguments "{\"city\":\"东京\"}"))))
    (let* ((mock (cl-agent.mock:make-mock-llm :responses responses))
           (resp (cl-agent.core:llm-chat
                  mock '((:role :user :content "查天气")))))
      (is (eq :tool-call (cl-agent.core:llm-response-finish-reason resp)))
      (is (= 1 (length (cl-agent.core:llm-response-tool-calls resp)))))))

(test mock-llm-error-rate-full
  "error-rate 1.0 → 稳定返回 finish-reason :error 的响应（不 signal）"
  (let* ((mock (cl-agent.mock:make-mock-llm :error-rate 1.0))
         (resp (cl-agent.core:llm-chat
                mock '((:role :user :content "任意")))))
    (is (eq :error (cl-agent.core:llm-response-finish-reason resp)))))

(test mock-llm-through-kernel
  "端到端：mock 经 provider-chat-model 直接驱动 kernel"
  (let ((responses (make-hash-table :test #'equal)))
    (setf (gethash "ping" responses) "pong")
    (let ((k (cl-agent.core:build-kernel
              :model (cl-agent.core:make-provider-chat-model
                      (cl-agent.mock:make-mock-llm :responses responses)))))
      (is (string= "pong" (cl-agent.core:kernel-chat-text k :user "ping"))))))
