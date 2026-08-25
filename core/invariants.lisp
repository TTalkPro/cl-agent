;;;; invariants.lisp
;;;; CL-Agent - 类不变式的统一表达
;;;;
;;;; 为什么需要这一层：
;;;;   CL 里 `make-instance` 是永远可达的后门——(defun make-foo ...) 只是
;;;;   约定俗成的入口，没人拦得住调用方直接 (make-instance 'foo ...)。
;;;;   于是「一个 tool-callback 必须有名字」这种性质，如果只写在
;;;;   make-tool-callback 里，就不是类的性质，只是那个函数的礼貌。
;;;;
;;;;   本文件提供 definvariants 宏，把这类性质挂到 initialize-instance
;;;;   :after 上——无论从哪条路造出来都成立，且违反时**在构造点**报错，
;;;;   而不是等到几层调用之后表现为一个难懂的症状。
;;;;
;;;; 什么该写成不变式（A 类）：
;;;;   「这个对象只要存在，就必须满足 X」。
;;;;   典型：tool-call 必须有 id（模型靠它把结果对回请求）、
;;;;         chat-client-response(:paused) 必须带 loop-state（否则无法续跑）。
;;;;
;;;; 什么**不该**（B 类，留在构造函数里）：
;;;;   输入归一。make-prompt 接受 string / message / list 并统一成消息列表，
;;;;   那是**入口的贴心**，不是类的性质——prompt 的性质是「messages 槽里
;;;;   存 message 实例列表」。搬进 initialize-instance 反而会让
;;;;   make-instance 也吃字符串，模糊了「槽里到底存什么」。
;;;;
;;;; 什么不该（C 类）：
;;;;   纯缺省值。那是 :initform 的活，除非缺省值依赖别的槽
;;;;   （filter 的「没给名字就用类名」就属于这种，initform 表达不了）。
;;;;
;;;; 枚举校验的适用边界（踩过的坑）：
;;;;   require-member 适用于**我方控制取值空间**的槽——用户配置项
;;;;   （retry-config 的 backoff：写成 :fibonacci 时用户期待斐波那契退避、
;;;;   实际得到固定延迟，那是该报错的静默错误）、库内部产出的状态
;;;;   （chat-client-response 的 status）、有兜底分支收口的分类
;;;;   （tool-error-info 的 class 兜底 :semantic，media 的 kind 兜底
;;;;   :document——兜底值都在白名单内）。
;;;;
;;;;   **不适用于外部系统返回的值。** llm-response 的 finish-reason 一度挂了
;;;;   白名单，结果把 normalize-finish-reason 的容错设计变成硬失败：它的兜底
;;;;   分支刻意把未映射的厂商值原样转成 keyword（厂商随时会加 "safety"、
;;;;   "refusal" 这类新值，上层用 (eq reason :tool-call) 判断，未知值走 else
;;;;   分支是正确行为），而白名单让这种响应在构造时就崩。测试全是已知值所以
;;;;   照样绿，只有真实响应会炸。**白名单是「我们认识的值」，不是「合法值的
;;;;   全集」**——这类槽用 require-type 校验类型即可。
;;;;
;;;; 为什么 require-type 不能被槽的 :type 声明取代：
;;;;   **:type 在 CL 里不是可移植的运行时保证。** CCL 在槽赋值时就检查
;;;;   （抛它自己的 BAD-SLOT-TYPE-FROM-INITARG，时机早于
;;;;   initialize-instance :after），而 SBCL 在默认 safety 下**根本不检查**。
;;;;   只写 :type 的话，同一份坏数据在 SBCL 上会一路流下去，直到某个远处的
;;;;   访问点才炸。所以两者都要：:type 表达意图并供编译器优化，
;;;;   require-type 提供跨实现一致的拒绝。
;;;;
;;;;   代价是两种实现抛的条件类型不同（CCL 先撞它自己那道），所以测试断言
;;;;   这类校验时用 (signals error ...) 而不是具体的 invariant-violation。
;;;;
;;;; 刻意的例外——chat-options：
;;;;   它十几个槽全部没有 :initform，槽 unbound **就是**「未设置」的语义，
;;;;   merge-chat-options 靠 slot-boundp 实现覆盖链。给它加必填校验会直接
;;;;   毁掉这个设计。不是每个 unbound 槽都是漏洞。

(in-package #:cl-agent/core)

;;; ============================================================
;;; 条件
;;; ============================================================

(define-condition invariant-violation (validation-error)
  ((object-type :initarg :object-type :initform nil :reader invariant-object-type)
   (slot-name :initarg :slot-name :initform nil :reader invariant-slot-name))
  (:documentation "类不变式被违反。

继承 validation-error——按统一分类它不可重试（error-retryable-p 对
validation-error 返回 NIL），因为重试一个构造错误不会有不同结果。")
  (:report (lambda (condition stream)
             (format stream "~A" (error-message condition)))))

(defun invariant-error (object slot fmt &rest args)
  "报告 OBJECT 的不变式违反。SLOT 可为 NIL（跨槽约束）。"
  (error 'invariant-violation
         :object-type (type-of object)
         :slot-name slot
         :message (format nil "~A~@[ 的 ~A~]：~?"
                          (type-of object) slot fmt args)))

;;; ============================================================
;;; 校验原语
;;; ============================================================

(defun require-slot (object slot why)
  "SLOT 必须已绑定且非 NIL。WHY 说明「为什么它必填」——错误消息里带上它，
读到报错的人不必回头翻源码猜。"
  (unless (and (slot-boundp object slot)
               (slot-value object slot))
    (invariant-error object slot "必填（~A）" why))
  t)

(defun require-member (object slot allowed &optional why)
  "SLOT 的值必须属于 ALLOWED。用于枚举型的槽（status / class / backoff 等）。

枚举槽是最值得校验的一类：写错一个 keyword 不会报错，只会让依赖它分派的
代码静默走进 else 分支。"
  (let ((value (and (slot-boundp object slot) (slot-value object slot))))
    (unless (member value allowed)
      (invariant-error object slot "必须是 ~{~S~^ / ~} 之一，收到 ~S~@[（~A）~]"
                       allowed value why)))
  t)

(defun require-type (object slot type &optional why)
  "SLOT 已绑定时其值必须是 TYPE。未绑定或 NIL 不算违反——
「可选，但给了就得是这个类型」是最常见的形态。"
  (let ((value (and (slot-boundp object slot) (slot-value object slot))))
    (when (and value (not (typep value type)))
      (invariant-error object slot "应为 ~A，收到 ~S~@[（~A）~]" type value why)))
  t)

(defun require-callable (object slot &optional why)
  "SLOT 已绑定时其值必须可调用（函数或函数名）。"
  (let ((value (and (slot-boundp object slot) (slot-value object slot))))
    (when (and value (not (or (functionp value)
                              (and (symbolp value) (fboundp value)))))
      (invariant-error object slot "应为函数或函数名，收到 ~S~@[（~A）~]"
                       value why)))
  t)

(defun require-that (object test fmt &rest args)
  "任意跨槽约束。TEST 为真即通过。"
  (unless test
    (apply #'invariant-error object nil fmt args))
  t)

;;; ============================================================
;;; definvariants
;;; ============================================================

(defmacro definvariants (class (var) &body body)
  "为 CLASS 定义不变式校验，展开为 initialize-instance :after。

  (definvariants tool-call (self)
    (require-slot self 'id \"模型靠它把结果对回请求\")
    (require-slot self 'name \"工具分派靠它\"))

  用宏而不是每处手写 defmethod，是为了让六十来个类的写法完全一致：
  同一个位置、同一组原语、同一种错误消息格式。不变式散落成各写各的
  defmethod 时，读者无法一眼判断「这个类到底有没有约束」。"
  `(defmethod initialize-instance :after ((,var ,class) &key)
     ,@body
     (values)))
