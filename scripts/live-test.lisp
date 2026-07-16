;;;; live-test.lisp
;;;; CL-Agent - 真实 provider 端到端验证（手动运行，不进测试套件）
;;;;
;;;; 为什么独立于 run-tests.lisp：
;;;;   run-tests.lisp 必须离线可跑、确定性、零 API 花费——它全用 mock。
;;;;   但 mock 永远证明不了「真实模型会不会按我们的 schema 发工具调用」
;;;;   「真实 SSE 分片能不能正确拼回」这类问题。这个脚本补的就是那一段。
;;;;
;;;; 运行：
;;;;   MINIMAX_API_KEY=... sbcl --script scripts/live-test.lisp
;;;;   sbcl --script scripts/live-test.lisp --provider anthropic --model claude-sonnet-4-20250514
;;;;
;;;; 退出码：0 全通过，1 有失败。

(require :asdf)
(let ((root (merge-pathnames "../" (directory-namestring *load-truename*))))
  (dolist (dir '("" "core/" "llm/" "mock/"))
    (pushnew (truename (merge-pathnames dir root))
             asdf:*central-registry* :test #'equal)))
(let ((ql (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname))))
  (when (probe-file ql) (load ql)))
(handler-bind ((warning #'muffle-warning))
  (asdf:load-system :cl-agent))

(defpackage :cl-agent/live
  (:use :cl :cl-agent.chat :cl-agent.kernel))
(in-package :cl-agent/live)

;;; ============================================================
;;; 命令行参数
;;; ============================================================

(defun argv-value (flag default)
  (let ((rest (member flag (uiop:command-line-arguments) :test #'string=)))
    (if (and rest (second rest)) (second rest) default)))

(defparameter *provider*
  (intern (string-upcase (argv-value "--provider" "minimax")) :keyword))

(defparameter *model-name* (argv-value "--model" nil))

;;; ============================================================
;;; 迷你测试框架（不引 fiveam：这里要的是可读的人工验证报告）
;;; ============================================================

(defvar *pass* 0)
(defvar *fail* 0)

(defmacro deflive (name description &body body)
  "定义一个 live 检查。BODY 返回 (values ok-p 详情)。"
  `(defun ,name ()
     (format t "~&  ~A ... " ,description)
     (force-output)
     (handler-case
         (multiple-value-bind (ok detail) (progn ,@body)
           (if ok
               (progn (incf *pass*) (format t "OK~@[  (~A)~]~%" detail))
               (progn (incf *fail*) (format t "FAIL~@[  (~A)~]~%" detail))))
       (error (e)
         (incf *fail*)
         (format t "ERROR~%      ~A~%" e)))))

(defun make-live-model ()
  (apply #'cl-agent.llm:create-chat-model *provider*
         (when *model-name* (list :model *model-name*))))

(defvar *model*)

;;; ============================================================
;;; 工具（真实模型自己决定要不要调）
;;; ============================================================

(deftool live-get-weather (&key city)
  "获取指定城市的当前天气"
  (:param city :string "城市名称" :required t)
  (format nil "~A：晴，22°C" city))

(defvar *tool-hits* 0
  "live-get-weather 实际被调用的次数——用来证明工具真的执行了，
而不是模型自己编了个天气。")

(deftool live-counted-weather (&key city)
  "获取指定城市的当前天气"
  (:param city :string "城市名称" :required t)
  (incf *tool-hits*)
  (format nil "~A：晴，22°C" city))

;;; ============================================================
;;; 检查项
;;; ============================================================

(deflive check-single-turn "[1/5] 单次问答"
  (let* ((k (build-kernel :model *model*))
         (text (chat k (:user "只回答一个词，不要标点：法国的首都是？"))))
    (values (and (stringp text) (search "巴黎" text))
            (string-trim '(#\Space #\Newline) text))))

(deflive check-tool-loop "[2/5] 真实工具循环（模型自主决定调用）"
  (let ((*tool-hits* 0))
    (let* ((k (build-kernel :model *model* :tools '(live-counted-weather)))
           (text (chat k
                   (:system "查天气必须用工具，不要凭空回答。")
                   (:user "东京现在天气怎么样？"))))
      ;; 关键断言是 *tool-hits*：证明工具真被执行，而非模型编造
      (values (and (> *tool-hits* 0) (search "22" text))
              (format nil "工具被调用 ~A 次" *tool-hits*)))))

(deflive check-memory-multi-turn "[3/5] memory-filter 多轮记忆"
  (let* ((mem (make-message-window-chat-memory))
         (k (build-kernel :model *model* :filters (list (memory-filter mem)))))
    (chat k (:user "记住：我的幸运数字是 42。") (:conversation "live-1"))
    (let ((text (chat k (:user "我的幸运数字是多少？只回答数字。")
                      (:conversation "live-1"))))
      ;; 模型答得出 42 ⇒ 第二轮确实拿到了第一轮的历史
      (values (search "42" text)
              (format nil "记忆 ~A 条，模型答：~A"
                      (length (memory-messages mem "live-1"))
                      (string-trim '(#\Space #\Newline) text))))))

(deflive check-structured-output "[4/5] 结构化输出 + schema 校验"
  (let* ((schema "{\"type\":\"object\",
                   \"properties\":{\"name\":{\"type\":\"string\"},
                                  \"population\":{\"type\":\"integer\"}},
                   \"required\":[\"name\",\"population\"]}")
         (k (build-kernel
             :model *model*
             :filters (list (validation-turn-filter
                             (structured-output-validate-fn
                              schema :parse-fn #'cl-agent.core:json-parse)
                             :max-retries 2))))
         (entity (chat k
                   (:user "用 JSON 给出东京的 name 和 population（整数）。")
                   (:call :entity))))
    (values (and (hash-table-p entity)
                 (gethash "name" entity)
                 (integerp (gethash "population" entity)))
            (format nil "name=~A population=~A"
                    (gethash "name" entity) (gethash "population" entity)))))

(deflive check-streaming "[5/5] 真实 SSE 流式（chat-model-stream）"
  ;; 提示要够长才能可靠地分片——「数到 5」这种模型一口就吐完了，
  ;; 断言 >1 分片会假失败（问的是回答长度，不是流式实现）。
  (let ((chunks nil))
    (chat-model-stream *model*
                       (make-prompt
                        (list (user-message
                               "从 1 数到 30，用空格分隔，只输出数字。")))
                       (lambda (delta) (push delta chunks)))
    (let ((full (apply #'concatenate 'string (reverse chunks))))
      ;; 多个 chunk ⇒ 确实是增量流式，不是攒完一次性回调
      (values (and (> (length chunks) 1) (search "30" full))
              (format nil "~A 个分片" (length chunks))))))

;;; ============================================================
;;; 主流程
;;; ============================================================

(defun main ()
  (format t "~&=== CL-Agent 真实链路验证 ===~%")
  (format t "provider: ~A~@[  model: ~A~]~%~%" *provider* *model-name*)
  (handler-case (setf *model* (make-live-model))
    (error (e)
      (format t "无法创建 model：~A~%~%提示：确认已设置对应的 API key 环境变量~%" e)
      (uiop:quit 1)))
  (check-single-turn)
  (check-tool-loop)
  (check-memory-multi-turn)
  (check-structured-output)
  (check-streaming)
  (format t "~%--- 通过 ~A，失败 ~A ---~%" *pass* *fail*)
  (uiop:quit (if (zerop *fail*) 0 1)))

(main)
