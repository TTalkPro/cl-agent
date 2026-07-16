;;;; utils.lisp
;;;; CL-Agent - 核心工具函数

(in-package :cl-agent.core)

;;; ============================================================
;;; ID 生成器 / 时间戳提供者
;;; ============================================================
;;;
;;; 这两个工厂原先住在独立的 cl-agent.core.protocols 包里（core/protocols/
;;; protocols.lisp）。那个包统共只导出这两个符号，却占着 `protocols` 这个
;;; 极宽泛的昵称——还容易与 protocols/ 子系统（A2A，另一回事）混淆。
;;; 它排在 utils 之后加载，于是下面的默认实现只能靠 find-package +
;;; find-symbol 动态查找来绕开加载顺序。合并进 core 后这层间接可以直接去掉。

(declaim (ftype (function () function) make-standard-id-generator))

(defun make-standard-id-generator ()
  "创建标准 ID 生成器（UUID v4）。

  返回一个无参函数，调用得到唯一 ID 字符串：

    (defparameter *id-gen* (make-standard-id-generator))
    (funcall *id-gen*)  ; => \"550e8400-e29b-41d4-a716-446655440000\""
  (lambda ()
    (princ-to-string (uuid:make-v4-uuid))))

(declaim (ftype (function () function) make-standard-timestamp-provider))

(defun make-standard-timestamp-provider ()
  "创建标准时间戳提供者（Unix 时间戳，整数秒）。

  返回一个无参函数，调用得到当前 Unix 时间戳：

    (defparameter *ts* (make-standard-timestamp-provider))
    (funcall *ts*)  ; => 1704067200

  整数存储，时区无关，便于序列化与比较。"
  (lambda ()
    (local-time:timestamp-to-unix (local-time:now))))

;;; ============================================================
;;; 协议默认实现（可替换：setf 这两个 defparameter 即可注入自定义实现）
;;; ============================================================

(defparameter *default-id-generator* nil
  "默认 ID 生成器实例（延迟初始化）")

(defparameter *default-timestamp-provider* nil
  "默认时间戳提供者实例（延迟初始化）")

(defun init-default-id-generator ()
  "初始化默认 ID 生成器"
  (unless *default-id-generator*
    (setf *default-id-generator* (make-standard-id-generator)))
  *default-id-generator*)

(defun init-default-timestamp-provider ()
  "初始化默认时间戳提供者"
  (unless *default-timestamp-provider*
    (setf *default-timestamp-provider* (make-standard-timestamp-provider)))
  *default-timestamp-provider*)

;;; ============================================================
;;; 环境变量
;;; ============================================================

(defun get-env (var-name &optional (default nil))
  "获取环境变量

  参数：
    VAR-NAME - 变量名
    DEFAULT  - 默认值（可选）

  返回：
    环境变量值或默认值

  示例：
    (get-env \"OPENAI_API_KEY\")
    (get-env \"PORT\" 8080)"
  (let ((value (uiop:getenv var-name)))
    (if (and value (string> value ""))
        value
        default)))

;;; ============================================================
;;; ID 生成
;;; ============================================================

(defun generate-uuid ()
  "生成 UUID 字符串（兼容性函数）

  默认实现，走标准 ID 生成器。要自定义，setf *default-id-generator*
  或直接 (funcall (make-standard-id-generator))。"
  (funcall (init-default-id-generator)))

;;; ============================================================
;;; 时间工具
;;; ============================================================

(defun timestamp-now ()
  "获取当前时间戳（兼容性函数）

  返回 Unix 时间戳（整数秒）。默认实现，走标准时间戳提供者。
  要自定义，setf *default-timestamp-provider*
  或直接 (funcall (make-standard-timestamp-provider))。"
  (funcall (init-default-timestamp-provider)))

;;; ============================================================
;;; JSON/Alist 操作
;;; ============================================================

(defun json-parse (string &key (as :alist))
  "解析 JSON 字符串

  参数：
    STRING - JSON 字符串
    AS     - :alist 或 :plist

  返回：
    Lisp 数据结构"
  (let ((parsed (com.inuoe.jzon:parse string)))
    (ecase as
      (:alist parsed)
      (:plist (alexandria:alist-plist parsed)))))

(defun json-stringify (object &key (pretty nil))
  "将 Lisp 对象转换为 JSON 字符串

  参数：
    OBJECT - Lisp 对象
    PRETTY - 是否美化输出"
  (if pretty
      (com.inuoe.jzon:stringify object :pretty t)
      (com.inuoe.jzon:stringify object)))

;;; 此处曾有一个 alist-get：名为 alist 访问器，函数体却是
;;; (getf alist key default)——getf 是 plist 访问器且以 eq 比较键，
;;; 用在真正的 alist 上，奇数长度直接抛 malformed property list，
;;; 偶数长度则恒返回 default（字符串键永不 eq）。它实际只对 plist 有效，
;;; 而那正是下面 plist-get 的功能，两者逐字等价。
;;; 它在 core 内零调用，且被 cl-agent.llm 中同名的真 alist 访问器
;;; （llm/providers.lisp，35 处调用）静默覆盖——那才是干活的那个。
;;; 故删除本副本并取消导出，让 alist-get 归 cl-agent.llm 私有。
;;; 需要 plist 访问直接用 getf（此处曾有 plist-get——对 getf 的逐字
;;; 包装，零调用，已删）。


;;; 注：此处曾有一个 build-url (base-url params)——零调用的死实现。
;;; 真正在用的是 cl-agent.http 那个 (base-url &optional path query-params)
;;; （被 http-get / http-get-async 调用）。两者同名不同签名，
;;; 合并 http 进 core 时必然撞车；删死留活。

;;; 注：此处曾有「字符串工具」（truncate-string / clean-whitespace /
;;; string-empty-p / ensure-string）、「列表工具」（take / drop /
;;; group-by）、「函数组合」（compose / pipe，其中 compose 生成的
;;; `#',result 展开本身就是坏的）与 Clojure 线程宏副本。全库零调用
;;; ——CL 自带 subseq/nthcdr/princ-to-string/alexandria:compose，
;;; 框架不重复发明。已整体删除。

;;; ============================================================
;;; 动态绑定继承（跨线程）
;;; ============================================================
;;; 特殊变量的绑定是每线程独立的：新线程只能看到全局值，看不到
;;; 创建它的线程用 let 建立的绑定。基于线程池的并行代码（工具并行
;;; 执行、异步 HTTP）因此存在一个隐患——lparallel:force 遇到尚未
;;; 被 worker 领走的任务时会由调用线程就地执行（task stealing），
;;; 于是同一个变量在任务体内的可见性取决于调度竞争：被窃取时看到
;;; 调用方的绑定，被 worker 领走时看到全局值。
;;;
;;; 这里提供「提交时快照 + 执行处重建」的机制来消除这种不确定性：
;;; 提交线程用 capture-special-bindings 拍快照，任务体用
;;; with-captured-special-bindings（progv）重建，无论任务最终落在
;;; 哪个线程、何时执行，看到的都是提交时刻的绑定。

(defvar *inherited-special-variables* '()
  "需要跨线程继承的特殊变量名列表（符号列表）。

被 cl-agent.chat 的并行工具执行与 cl-agent.http 的异步请求共用：
列入的变量会在提交线程快照当前值，并在任务实际执行处重新绑定。

  (defvar *request-id* nil)
  (with-inherited-specials (*request-id*)
    (let ((*request-id* \"req-42\"))
      ...))   ; 任务体内保证看到 \"req-42\"

不在列表中的变量，其在任务体内的可见性不确定（见上方说明），
不要依赖——需要什么就列什么。

快照的是值引用而非深拷贝：若值是可变对象（哈希表、可变列表），
多个任务仍共享同一实例，需自行加锁。")

(defmacro with-inherited-specials ((&rest symbols) &body body)
  "在 BODY 内把 SYMBOLS 追加进 *inherited-special-variables*。

SYMBOLS 不求值，直接写变量名即可：

  (with-inherited-specials (*request-id* *tenant*)
    (let ((*request-id* \"req-42\")) ...))"
  `(let ((*inherited-special-variables*
           (append ',symbols *inherited-special-variables*)))
     ,@body))

(defun capture-special-bindings (&optional (symbols *inherited-special-variables*))
  "在当前线程快照 SYMBOLS 的值，返回 (符号列表 . 值列表)，
供 with-captured-special-bindings 在别处重建。

必须在提交线程调用——在任务体内调用毫无意义（那里已经看不到
调用方的绑定了）。

跳过未绑定符号与常量：progv 绑定常量是未定义行为；而未绑定符号
若进了变量列表却没有对应值，会被绑成「无值」状态，反倒遮蔽全局值。"
  (loop for sym in symbols
        when (and (symbolp sym) (not (constantp sym)) (boundp sym))
          collect sym into syms
          and collect (symbol-value sym) into vals
        finally (return (cons syms vals))))

(defmacro with-captured-special-bindings ((capture) &body body)
  "在 CAPTURE（capture-special-bindings 的返回值）的绑定下执行 BODY。

CAPTURE 为空时退化为普通 progn（progv 空列表即无绑定）。"
  (let ((c (gensym "CAPTURE")))
    `(let ((,c ,capture))
       (progv (car ,c) (cdr ,c)
         ,@body))))

;;; 日志工具（log-debug / log-info / log-warn / log-error）定义在
;;; macros.lisp 的日志系统一节：带级别过滤与时间戳。
;;; 此处曾有一份无级别过滤的简易重复实现，因 macros.lisp 中 as-> 缺一个
;;; 右括号、导致其后全部定义（含整个日志系统）从未生效而长期顶替使用；
;;; 括号修复后已删除，以免覆盖真正的实现。

;;; 注：此处曾有 make-tool——plist 版工具规格构造器，早于
;;; tool-callback / deftool 体系，零调用。工具请用 deftool 定义。
