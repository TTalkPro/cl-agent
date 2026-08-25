;;;; filter.lisp
;;;; CL-Agent ChatClient - Filter CLOS 类 + build-chain + defilter 宏
;;;;
;;;; 概述：
;;;;   Filter 是 chat-client 架构的核心可组合单元。对标 clj-agent 的 Filter
;;;;   协议：每个 filter 持有四个钩子（:chat/:tool/:turn/:token-xform），
;;;;   钩子是普通函数而非泛型方法，存放在 CLOS 槽里。
;;;;
;;;;   三个设计取舍：
;;;;   - 钩子存槽位、直接函数调用，不走泛型方法分发
;;;;   - 三条独立的链（chat/tool/turn），而非单一环绕链
;;;;   - 没有 order 字段：列表位置即层级（注册顺序 = 洋葱外→内）
;;;;
;;;;   build-chain（核心）：
;;;;     把 filters（注册顺序：靠前 = 最外层）折成洋葱，最内层为 terminal。
;;;;     通过 reverse + reduce 把 (req chain) → resp 的钩子层层嵌套，
;;;;     每层闭包只持有更内层 chain 的引用——天然"仅下游"，递归重入免费。
;;;;
;;;;   defilter 宏：
;;;;     一个表达式定义 filter 子类 + 构造函数。钩子体直接引用实例
;;;;     槽（make-NAME 通过 let 绑定 self，闭包捕获）。钩子是闭包，
;;;;     不需要泛型方法分发。

(in-package #:cl-agent/core)

;;; ============================================================
;;; Filter CLOS 类
;;; =========================================================;;;

(defclass filter ()
  ((name
    :initarg :name
    :initform nil
    :reader filter-name
    :documentation "Filter 标识（keyword 或 string）。缺省 nil 时按惯例用类名 downcase。")
   (tool
    :initarg :tool
    :initform nil
    :reader filter-tool-hook
    :documentation ":tool 钩子：(tool-request chain) → tool-result 或 nil")
   (chat
    :initarg :chat
    :initform nil
    :reader filter-chat-hook
    :documentation ":chat 钩子：(prompt chain) → chat-response 或 nil")
   (turn
    :initarg :turn
    :initform nil
    :reader filter-turn-hook
    :documentation ":turn 钩子：(chat-client-request chain) → chat-client-response 或 nil")
   (token-xform
    :initarg :token-xform
    :initform nil
    :reader filter-token-xform
    :documentation "流式 token 变换：(downstream-emit) → (values emit finish)。
   在流式 terminal（invoke-chat-stream / compose-token-xforms）内侧组装，
   不参与 build-chain。"))
  (:documentation "Filter 基类（四钩子：tool/chat/turn/token-xform）。

钩子是普通函数，存放在槽里；不需要 defgeneric/defmethod。
每条链只调用该链对应槽里非 nil 的钩子。"))

(defun filter-name-default (filter)
  "缺省名称：类名 downcase。"
  (string-downcase (symbol-name (type-of filter))))

(definvariants filter (self)
  ;; 缺省名依赖类型（类名 downcase），:initform 表达不了，所以是不变式
  ;; 而非缺省值。此前它只写在 filter-name-default 里、靠每个调用点记得问，
  ;; 于是 (filter-name f) 对没给名字的实例返回 NIL——日志里一个空名字。
  (unless (filter-name self)
    (setf (slot-value self 'name) (filter-name-default self))))

(defun make-filter (name &key chat tool turn token-xform)
  "Filter 通用工厂。

参数：
  - name        filter 标识（任意）
  - chat        (req chain) → resp  函数（可选）
  - tool        同上
  - turn        同上
  - token-xform transducer 风格函数（可选）

未提供的钩子槽位为 nil——build-chain 在构建对应链时会自动跳过。"
  (apply #'make-instance 'filter
         :name name
         (nconc (when chat (list :chat chat))
                (when tool (list :tool tool))
                (when turn (list :turn turn))
                (when token-xform (list :token-xform token-xform)))))

(defmethod print-object ((filter filter) stream)
  (print-unreadable-object (filter stream :type t)
    (format stream "~A"
            (or (filter-name filter)
                (filter-name-default filter)))))

;;; ============================================================
;;; build-chain：洋葱折叠
;;; =========================================================;;;

(defun build-chain (filters hook-key terminal)
  "把 filters（注册顺序：靠前 = 最外层）折成洋葱，最内层为 terminal。

  参数：
    - filters    filter 实例列表，靠前者在最外层
    - hook-key   访问器函数符号（如 #'filter-chat-hook），
                 用于选择每个 filter 的对应钩子；该钩子为 nil 的 filter
                 自动跳过
    - terminal   最内层函数：(req) → resp

  返回值：单参函数 (req) → resp。每层闭包只持有更内层的 filter
  引用，不可能重跑上游；递归重入是免费性质。"
  (let ((hooks (remove-if-not hook-key filters)))
    (reduce (lambda (downstream filter)
              (let ((hook (funcall hook-key filter)))
                (lambda (req) (funcall hook req downstream))))
            (reverse hooks)
            :initial-value terminal)))

;;; ============================================================
;;; defilter 宏
;;; =========================================================;;;

(defun %make-name-symbol (name)
  "生成 make-NAME 构造函数符号。
直接 intern \"MAKE-{NAME}\" 在 (symbol-package name) 中。"
  (intern (format nil "MAKE-~A" (symbol-name name))
          (symbol-package name)))

(defmacro defilter (name (&rest slots) &body hooks)
  "定义一个 filter 类 + 构造函数。

  语法：
    (defilter NAME (SLOTS...)
      (:chat (self req chain) body...)            ; 挂 :chat 链
      (:tool (self req chain) body...)            ; 挂 :tool 链
      (:turn (self req chain) body...)            ; 挂 :turn 链
      (:token-xform xform))                       ; 流式 token 变换

  钩子的 lambda-list 是 (SELF REQ CHAIN)，SELF 绑定到 filter 实例。"
    (let ((chat-spec (find :chat hooks :key #'first))
        (tool-spec (find :tool hooks :key #'first))
        (turn-spec (find :turn hooks :key #'first))
        (xform-spec (find :token-xform hooks :key #'first))
        (make-name (%make-name-symbol name)))
    `(progn
       (defclass ,name (filter)
         ,slots
         (:documentation ,(format nil "Filter 类（由 defilter 定义）：~A" name)))
       (defun ,make-name (&rest initargs)
         ,(format nil "创建 ~(~A~) 实例并挂载钩子闭包。" name)
         (let ((self (apply #'make-instance ',name initargs)))
           ,@(when chat-spec
               (destructuring-bind ((sp rp cp) &rest body) (rest chat-spec)
                 `((setf (slot-value self 'chat)
                         (lambda (,rp ,cp)
                           (declare (ignorable ,rp ,cp))
                           (let ((,sp self)) ,@body))))))
           ,@(when tool-spec
               (destructuring-bind ((sp rp cp) &rest body) (rest tool-spec)
                 `((setf (slot-value self 'tool)
                         (lambda (,rp ,cp)
                           (declare (ignorable ,rp ,cp))
                           (let ((,sp self)) ,@body))))))
           ,@(when turn-spec
               (destructuring-bind ((sp rp cp) &rest body) (rest turn-spec)
                 `((setf (slot-value self 'turn)
                         (lambda (,rp ,cp)
                           (declare (ignorable ,rp ,cp))
                           (let ((,sp self)) ,@body))))))
           ,@(when xform-spec
               `((setf (slot-value self 'token-xform) ,(second xform-spec))))
           self))
       ',name)))